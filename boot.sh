#!/bin/sh

set -u

REDIS_PORT="${REDIS_PORT:-6389}"
SLOT_NUM="${SLOT_NUM:-0}"
MASTER_HOST="${MASTER_HOST:-redis-node}"
MASTERS_TOTAL="${MASTERS_TOTAL:-1}"
SLOTS_TOTAL="${SLOTS_TOTAL:-$MASTERS_TOTAL}"
CHECK_PERIOD="${CHECK_PERIOD:-15}"
BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-120}"
BOOTSTRAP_STABLE="${BOOTSTRAP_STABLE:-10}"
JOIN_TIMEOUT="${JOIN_TIMEOUT:-300}"
REBALANCE="${REBALANCE:-1}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
LOCK_TTL="${LOCK_TTL:-120}"
DEBUG="${DEBUG:-0}"

LOCK_KEY_JOIN="{redis-cluster}:join"
LOCK_KEY_MAINT="{redis-cluster}:maintenance"
LOCK_TOKEN="$(hostname 2>/dev/null || echo node)-$$-$(date +%s 2>/dev/null || echo 0)"
START_TS=$(date +%s 2>/dev/null || echo 0)
SELF_IP=""
LOCK_HOST=""
LOCK_KEY_CURRENT=""
REFRESH_PID=""

log() { echo "{INFO} $*"; }
dbg() { [ "$DEBUG" = "1" ] && echo "{DEBUG} $*"; }
warn() { echo "{WARN} $*"; }
err() { echo "{ERROR} $*" >&2; }

rcli() {
	_host=$1
	shift
	timeout 5 redis-cli -h "$_host" -p "$REDIS_PORT" "$@" 2>/dev/null
}

rcli_c() {
	_host=$1
	shift
	timeout 10 redis-cli -c -h "$_host" -p "$REDIS_PORT" "$@" 2>/dev/null
}

resolve_one() {
	getent ahostsv4 "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

resolve_all() {
	getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1 }' | sort -u
}

peer_ips() {
	_found=$(resolve_all tasks.nodes)
	if [ -z "$_found" ]; then
		_i=1
		while [ "$_i" -le "$SLOTS_TOTAL" ]; do
			_ip=$(resolve_one "$MASTER_HOST$_i")
			[ -n "$_ip" ] && _found="$_found $_ip"
			_i=$((_i + 1))
		done
	fi
	{
		printf '%s\n' "$_found" | tr ' ' '\n'
		echo "$SELF_IP"
	} | awk 'NF && !seen[$0]++'
}

alive_ips() {
	for _ip in $(peer_ips); do
		if rcli "$_ip" ping | grep -q PONG; then
			echo "$_ip"
		fi
	done
}

cluster_info_value() {
	rcli "$1" cluster info | awk -F: -v k="$2" '
		{
			gsub(/[ \r]/, "", $1)
			if ($1 == k) {
				gsub(/[ \r]/, "", $2)
				print $2
			}
		}'
}

has_cluster() {
	_known=$(cluster_info_value "$1" cluster_known_nodes)
	_slots=$(cluster_info_value "$1" cluster_slots_assigned)
	[ "${_known:-0}" -gt 1 ] 2>/dev/null || [ "${_slots:-0}" -gt 0 ] 2>/dev/null
}

find_cluster_peer() {
	for _ip in $(alive_ips); do
		if has_cluster "$_ip"; then
			echo "$_ip"
			return 0
		fi
	done
	return 1
}

cluster_ok() {
	_state=$(cluster_info_value "$1" cluster_state)
	_slots=$(cluster_info_value "$1" cluster_slots_ok)
	[ "$_state" = "ok" ] && [ "$_slots" = "16384" ]
}

wait_cluster_ok() {
	_end=$(( $(date +%s) + ${2:-60} ))
	while [ "$(date +%s)" -lt "$_end" ]; do
		cluster_ok "$1" && return 0
		sleep 2
	done
	return 1
}

is_self_member() {
	_id=$(rcli "$SELF_IP" cluster myid)
	[ -n "$_id" ] || return 1
	rcli "$1" cluster nodes | awk -v id="$_id" '$1 == id { found = 1 } END { exit !found }'
}

count_masters() {
	rcli "$1" cluster nodes | awk '
		$3 ~ /master/ && $3 !~ /fail/ && $8 == "connected" { c++ }
		END { print c + 0 }'
}

unreachable_master_exists() {
	rcli "$1" cluster nodes | awk '
		$3 ~ /master/ && ($3 ~ /fail/ || $3 ~ /noaddr/ || $8 == "disconnected") && NF >= 9 {
			found = 1
		}
		END { exit !found }'
}

takeover_unreachable_masters() {
	_did=0
	for _master_id in $(rcli "$1" cluster nodes | awk '
		$3 ~ /master/ && ($3 ~ /fail/ || $3 ~ /noaddr/ || $8 == "disconnected") && NF >= 9 {
			print $1
		}'); do
		_replica=$(rcli "$1" cluster nodes | awk -v m="$_master_id" '
			$3 ~ /slave/ && $3 !~ /fail/ && $8 == "connected" && $4 == m {
				print $2
				exit
			}')
		if [ -n "$_replica" ]; then
			_replica_ip=${_replica%%:*}
			log "forcing failover of unreachable master $_master_id to $_replica"
			rcli "$_replica_ip" CLUSTER FAILOVER TAKEOVER >/dev/null
			_did=1
		fi
	done
	if [ "$_did" = "1" ]; then
		wait_cluster_ok "$1" 60 || true
	fi
}

empty_master() {
	rcli "$1" cluster nodes | awk '
		$3 ~ /master/ && $3 !~ /fail/ && $8 == "connected" && NF < 9 {
			print $1
			exit
		}'
}

choose_master_for_replica() {
	rcli "$1" cluster nodes | awk '
		$3 ~ /master/ && $3 !~ /fail/ && $8 == "connected" && NF >= 9 {
			masters[$1] = 1
			next
		}
		$3 ~ /slave/ && $3 !~ /fail/ && $8 == "connected" {
			replicas[$4]++
		}
		END {
			best = ""
			best_count = -1
			for (id in masters) {
				n = replicas[id] + 0
				if (best == "" || n < best_count) {
					best = id
					best_count = n
				}
			}
			print best
		}'
}

is_coordinator() {
	_me=$(rcli "$SELF_IP" cluster myid)
	_lowest=$(rcli "$1" cluster nodes | awk '
		$3 !~ /fail/ && $8 == "connected" { print $1 }' | sort | head -n 1)
	[ -n "$_me" ] && [ "$_me" = "$_lowest" ]
}

lock_acquire() {
	_out=$(rcli_c "$1" SET "$2" "$LOCK_TOKEN" NX PX $(( LOCK_TTL * 1000 )))
	[ "$_out" = "OK" ]
}

lock_refresh() {
	rcli_c "$1" SET "$2" "$LOCK_TOKEN" XX PX $(( LOCK_TTL * 1000 )) >/dev/null
}

lock_release() {
	rcli_c "$1" EVAL "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end" 1 "$2" "$LOCK_TOKEN" >/dev/null
}

start_refresher() {
	touch /tmp/coord.refresh
	(
		while [ -f /tmp/coord.refresh ]; do
			sleep $(( LOCK_TTL / 3 ))
			lock_refresh "$1" "$2"
		done
	) &
	REFRESH_PID=$!
}

stop_refresher() {
	rm -f /tmp/coord.refresh
	if [ -n "${REFRESH_PID:-}" ]; then
		kill "$REFRESH_PID" 2>/dev/null
		wait "$REFRESH_PID" 2>/dev/null
		REFRESH_PID=""
	fi
}

cleanup() {
	stop_refresher
	if [ -n "${LOCK_HOST:-}" ]; then
		lock_release "$LOCK_HOST" "$LOCK_KEY_CURRENT"
	fi
}

trap cleanup EXIT INT TERM

bootstrap_cluster() {
	_alive=$(alive_ips | sort -u)
	_count=$(printf '%s\n' "$_alive" | grep -c .)
	[ "$_count" -ge 1 ] || return 1

	_want=$MASTERS_TOTAL
	[ "$_want" -gt "$SLOTS_TOTAL" ] && _want=$SLOTS_TOTAL
	[ "$_want" -lt 1 ] && _want=1

	if [ "$_count" -lt "$_want" ]; then
		_elapsed=$(( $(date +%s) - START_TS ))
		if [ "$_elapsed" -lt "$BOOTSTRAP_TIMEOUT" ]; then
			dbg "waiting for peers: alive=$_count want=$_want"
			return 1
		fi
	fi

	_lowest=$(printf '%s\n' "$_alive" | sort | head -n 1)
	[ "$_lowest" = "$SELF_IP" ] || return 1

	sleep "$BOOTSTRAP_STABLE"

	if find_cluster_peer >/dev/null 2>&1; then
		return 1
	fi

	_alive=$(alive_ips | sort -u)
	_lowest=$(printf '%s\n' "$_alive" | sort | head -n 1)
	[ "$_lowest" = "$SELF_IP" ] || return 1

	_count=$(printf '%s\n' "$_alive" | grep -c .)
	_masters=$_want
	[ "$_masters" -gt "$_count" ] && _masters=$_count

	_master_ips=$(printf '%s\n' "$_alive" | head -n "$_masters")
	for _ip in $_master_ips; do
		_known=$(cluster_info_value "$_ip" cluster_known_nodes)
		_slots=$(cluster_info_value "$_ip" cluster_slots_assigned)
		if [ "${_known:-1}" -gt 1 ] 2>/dev/null || [ "${_slots:-0}" -gt 0 ] 2>/dev/null; then
			return 1
		fi
	done

	for _ip in $_master_ips; do
		[ "$_ip" = "$SELF_IP" ] && continue
		rcli "$SELF_IP" CLUSTER MEET "$_ip" "$REDIS_PORT" >/dev/null
	done

	for _ip in $_master_ips; do
		_end=$(( $(date +%s) + 30 ))
		_known=0
		while [ "$(date +%s)" -lt "$_end" ]; do
			_known=$(cluster_info_value "$_ip" cluster_known_nodes)
			[ "${_known:-0}" -ge "$_masters" ] && break
			sleep 1
		done
		if [ "${_known:-0}" -lt "$_masters" ]; then
			err "node $_ip did not join the bootstrap cluster"
			return 1
		fi
	done

	_total=16384
	_base=$(( _total / _masters ))
	_rem=$(( _total % _masters ))
	_start=0
	_k=0
	for _ip in $_master_ips; do
		_size=$_base
		if [ "$_k" -lt "$_rem" ]; then
			_size=$(( _size + 1 ))
		fi
		_end_slot=$(( _start + _size - 1 ))
		log "assigning slots $_start-$_end_slot to $_ip"
		rcli "$_ip" CLUSTER ADDSLOTSRANGE "$_start" "$_end_slot" >/dev/null
		_rc=$?
		if [ "$_rc" -ne 0 ]; then
			err "failed to assign slots $_start-$_end_slot to $_ip"
			return 1
		fi
		_start=$(( _start + _size ))
		_k=$(( _k + 1 ))
	done

	wait_cluster_ok "$SELF_IP" 120 || warn "cluster created but is not ready yet"
	return 0
}

join_cluster() {
	_target=$1
	_me=$(rcli "$SELF_IP" cluster myid)

	if [ -n "$_me" ] && rcli "$_target" cluster nodes | awk -v id="$_me" '$1 == id { found = 1 } END { exit !found }'; then
		dbg "already a cluster member"
		return 0
	fi

	if ! cluster_ok "$_target"; then
		dbg "cluster is not ready for joins"
		return 1
	fi

	_locked=0
	if lock_acquire "$_target" "$LOCK_KEY_JOIN"; then
		_locked=1
		LOCK_HOST=$_target
		LOCK_KEY_CURRENT=$LOCK_KEY_JOIN
		start_refresher "$_target" "$LOCK_KEY_JOIN"
	else
		if unreachable_master_exists "$_target"; then
			warn "joining without lock: an unreachable master is present"
		else
			dbg "join postponed: coordinator lock is busy or cluster is not ready"
			return 1
		fi
	fi

	_masters=$(count_masters "$_target")
	if [ "$_masters" -lt "$MASTERS_TOTAL" ]; then
		log "joining cluster as master (masters=$_masters/$MASTERS_TOTAL)"
		_out=$(timeout "$JOIN_TIMEOUT" redis-cli --cluster add-node "$SELF_IP:$REDIS_PORT" "$_target:$REDIS_PORT" --cluster-yes 2>&1)
	else
		_master_id=$(choose_master_for_replica "$_target")
		if [ -z "$_master_id" ]; then
			warn "no master found for replica, joining as master"
			_out=$(timeout "$JOIN_TIMEOUT" redis-cli --cluster add-node "$SELF_IP:$REDIS_PORT" "$_target:$REDIS_PORT" --cluster-yes 2>&1)
		else
			log "joining cluster as replica of $_master_id"
			_out=$(timeout "$JOIN_TIMEOUT" redis-cli --cluster add-node "$SELF_IP:$REDIS_PORT" "$_target:$REDIS_PORT" --cluster-slave --cluster-master-id "$_master_id" --cluster-yes 2>&1)
		fi
	fi
	_rc=$?
	[ -n "$_out" ] && printf '%s\n' "$_out" | tail -n 20

	if [ "$_rc" -ne 0 ]; then
		case "$_out" in
			*"already known"*|*"is already in the cluster"*|*"is already"*)
				dbg "node is already known by cluster" ;;
			*)
				err "join failed"
				stop_refresher
				if [ "$_locked" = "1" ]; then
					lock_release "$_target" "$LOCK_KEY_JOIN"
				fi
				LOCK_HOST=""
				LOCK_KEY_CURRENT=""
				return 1 ;;
		esac
	fi

	stop_refresher
	if [ "$_locked" = "1" ]; then
		lock_release "$_target" "$LOCK_KEY_JOIN"
	fi
	LOCK_HOST=""
	LOCK_KEY_CURRENT=""

	_end=$(( $(date +%s) + 60 ))
	while [ "$(date +%s)" -lt "$_end" ]; do
		has_cluster "$SELF_IP" && break
		sleep 2
	done

	wait_cluster_ok "$SELF_IP" 120 || wait_cluster_ok "$_target" 60 || true
	return 0
}

ensure_role() {
	_target=$1
	_me=$(rcli "$SELF_IP" cluster myid)
	[ -n "$_me" ] || return 0

	_line=$(rcli "$_target" cluster nodes | awk -v id="$_me" '$1 == id { print; exit }')
	[ -n "$_line" ] || return 0

	_flags=$(printf '%s\n' "$_line" | awk '{ print $3 }')
	_nf=$(printf '%s\n' "$_line" | awk '{ print NF }')

	case "$_flags" in
		*master*)
			if [ "$_nf" -lt 9 ]; then
				_masters=$(count_masters "$_target")
				if [ "$_masters" -gt "$MASTERS_TOTAL" ]; then
					_master_id=$(choose_master_for_replica "$_target")
					[ -n "$_master_id" ] || return 0
					if lock_acquire "$_target" "$LOCK_KEY_JOIN"; then
						LOCK_HOST=$_target
						LOCK_KEY_CURRENT=$LOCK_KEY_JOIN
						start_refresher "$_target" "$LOCK_KEY_JOIN"
						log "extra empty master; replicating $_master_id"
						rcli "$SELF_IP" CLUSTER REPLICATE "$_master_id" >/dev/null
						stop_refresher
						lock_release "$_target" "$LOCK_KEY_JOIN"
						LOCK_HOST=""
						LOCK_KEY_CURRENT=""
						wait_cluster_ok "$_target" 60 || true
					fi
				fi
			fi
			;;
	esac
}

forget_failed_nodes() {
	_me=$(rcli "$SELF_IP" cluster myid)
	rcli "$1" cluster nodes | awk -v me="$_me" '
		$1 != me && ($3 ~ /fail/ || $3 ~ /noaddr/ || ($8 == "disconnected" && $2 ~ /^:/)) {
			print $1, $2
		}' | while read -r _id _addr; do
		_host=${_addr%%:*}
		if [ -z "$_host" ] || ! rcli "$_host" ping | grep -q PONG; then
			log "forgetting stale node $_id ($_addr)"
			rcli "$1" cluster forget "$_id" >/dev/null
		fi
	done
}

repair_cluster() {
	takeover_unreachable_masters "$1"

	_state=$(cluster_info_value "$1" cluster_state)
	_slots=$(cluster_info_value "$1" cluster_slots_ok)

	if [ "$_state" != "ok" ] || [ "$_slots" != "16384" ]; then
		log "cluster unhealthy (state=${_state:-?}, slots=${_slots:-?}); running fix"
		_out=$(timeout "${REPAIR_TIMEOUT:-300}" redis-cli --cluster fix "$1:$REDIS_PORT" --cluster-yes --cluster-fix-with-unreachable-masters 2>&1)
		[ -n "$_out" ] && printf '%s\n' "$_out" | tail -n 30
		wait_cluster_ok "$1" 60 || warn "cluster is still not healthy after fix"
	fi

	if [ "$REBALANCE" = "1" ]; then
		_masters_now=$(count_masters "$1")
		_empty=""
		if [ "$_masters_now" -le "$MASTERS_TOTAL" ]; then
			_empty=$(empty_master "$1")
		fi
		if [ -n "$_empty" ]; then
			log "empty master $_empty found; rebalancing"
			_out=$(timeout "${REBALANCE_TIMEOUT:-600}" redis-cli --cluster rebalance "$1:$REDIS_PORT" --cluster-use-empty-masters --cluster-pipeline 100 --cluster-yes 2>&1)
			[ -n "$_out" ] && printf '%s\n' "$_out" | tail -n 30
			wait_cluster_ok "$1" 120 || warn "cluster is not healthy after rebalance"
		fi
	fi

	if cluster_ok "$1"; then
		forget_failed_nodes "$1"
	fi
}

run_coordinator() {
	_target=$1
	_locked=0

	if lock_acquire "$_target" "$LOCK_KEY_MAINT"; then
		_locked=1
		LOCK_HOST=$_target
		LOCK_KEY_CURRENT=$LOCK_KEY_MAINT
		start_refresher "$_target" "$LOCK_KEY_MAINT"
	elif [ "$(cluster_info_value "$_target" cluster_state)" != "ok" ] || unreachable_master_exists "$_target"; then
		warn "coordinator lock unavailable; continuing without it"
	else
		dbg "coordinator lock is busy"
		return 0
	fi

	repair_cluster "$_target"

	stop_refresher
	if [ "$_locked" = "1" ]; then
		lock_release "$_target" "$LOCK_KEY_MAINT"
	fi
	LOCK_HOST=""
	LOCK_KEY_CURRENT=""
}

monitor() {
	while :; do
		_target=$(find_cluster_peer)

		if [ -z "$_target" ]; then
			dbg "cluster not found"
			sleep "$CHECK_PERIOD"
			continue
		fi

		if ! is_self_member "$_target"; then
			join_cluster "$_target" || true
		else
			ensure_role "$_target"
			if is_coordinator "$_target"; then
				run_coordinator "$_target"
			fi
		fi

		sleep "$CHECK_PERIOD"
	done
}

init_self() {
	SELF_IP=$(resolve_one "$(hostname)")
	if [ -z "$SELF_IP" ]; then
		SELF_IP=$(hostname -i 2>/dev/null | awk '{ print $1 }')
	fi
	[ -n "$SELF_IP" ] || SELF_IP="127.0.0.1"
}

init_self
log "starting node slot=$SLOT_NUM ip=$SELF_IP"

until rcli 127.0.0.1 ping | grep -q PONG; do
	sleep 1
done

if [ "$FORCE_REBUILD" = "1" ]; then
	log "FORCE_REBUILD: resetting local redis state"
	rcli 127.0.0.1 FLUSHALL >/dev/null 2>&1 || true
	rcli 127.0.0.1 CLUSTER RESET HARD >/dev/null 2>&1 || true
fi

_target=$(find_cluster_peer)
if [ -n "$_target" ] && is_self_member "$_target" && cluster_ok "$_target"; then
	log "already in a healthy cluster"
else
	log "joining or bootstrapping cluster"
	_end=$(( $(date +%s) + JOIN_TIMEOUT ))
	while [ "$(date +%s)" -lt "$_end" ]; do
		_target=$(find_cluster_peer)
		if [ -n "$_target" ]; then
			if is_self_member "$_target"; then
				log "cluster member"
				break
			fi
			if join_cluster "$_target"; then
				log "joined cluster"
				break
			fi
		else
			if bootstrap_cluster; then
				log "cluster bootstrap complete"
				break
			fi
		fi
		sleep 2
	done
fi

monitor
