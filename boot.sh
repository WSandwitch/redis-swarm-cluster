ARBITER_PORT=${ARBITER_PORT:-6379}
CHECK_PERIOD=${CHECK_PERIOD:-30}
MASTER_NUM=$SLOT_NUM
IN_LOCK=0

sleep 10

function lock_set {
	#if container was killed before
	if [ "$(redis-cli --raw -h $ARBITER_HOST -p $ARBITER_PORT GET lock)" = "$SLOT_NUM" ]; then
		redis-cli --raw -h $ARBITER_HOST -p $ARBITER_PORT DEL lock >/dev/null
	fi
	while [ ! "$(redis-cli --raw -h $ARBITER_HOST -p $ARBITER_PORT SETNX lock $SLOT_NUM)" = "1" ]; do
		sleep 1
	done
	IN_LOCK=1
	if [ "$DEBUG" = "1" ]; then echo "{INFO} Lock set"; fi
	
}

function lock_unset {
	if [ "${IN_LOCK}" -eq 1 ]; then
		while [ ! "$(redis-cli --raw -h $ARBITER_HOST -p $ARBITER_PORT DEL lock)" = "1" ]; do
			sleep 1
		done
		IN_LOCK=0;
		if [ "$DEBUG" = "1" ]; then echo "{INFO} Lock released"; fi
	else
		echo "{INFO} Lock not set"
	fi
}

function check_and_fix {
	if [ ! "$(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster nodes | grep "fail?" | wc -l || echo 0)" = "0" ]; then 
		echo "{INFO} Found failed master";
		#master failed lets wait while slave become master
		sleep 15;
	fi

	if [ "$DEBUG" = "1" ]; then 
		redis-cli --cluster check $MASTER_HOST$MASTER_NUM:$REDIS_PORT || yes yes | redis-cli --cluster fix $MASTER_HOST$MASTER_NUM:$REDIS_PORT --cluster-yes --cluster-fix-with-unreachable-masters
	else
		redis-cli --cluster check $MASTER_HOST$MASTER_NUM:$REDIS_PORT 2>&1 > /dev/null || yes yes | redis-cli --cluster fix $MASTER_HOST$MASTER_NUM:$REDIS_PORT --cluster-yes --cluster-fix-with-unreachable-masters
	fi

	sleep 3
	
	#check for failed nodes
	if [ ! "$(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster nodes | grep fail | wc -l || echo 0)" = "0" ]; then 
		echo "{INFO} Found failed nodes, need to clean up";
		for i in $(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster nodes | grep fail | awk '{print $1}'); do
			echo "{INFO} Foget about node $i"
			redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster forget $i
		done
		sleep 3
	fi
}

#"$MASTER_NUM" = "0" if master not found
function check_master {
	if [ ! "$(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT --raw keys '*' >/dev/null && echo 1 || echo 0)" = "1" ]; then
		echo "{INFO} Could not connect to master" 
		#lets try to find another master
		MASTER_NUM=0

		for i in $(seq 1 $SLOTS_TOTAL); do  
			if  [ ! "$( (redis-cli -h $MASTER_HOST$i -p $REDIS_PORT cluster nodes || echo 1) | wc -l )" = "1" ]; then
				echo "{INFO} Node $i is in cluster, select it"
				MASTER_NUM=$i
				break
			fi
		done

		if [ "$MASTER_NUM" = "0" ]; then
			echo "{INFO} Node in cluster not found, searching for first running node" #TODO: add check for slot range
			for i in $(seq 1 $SLOTS_TOTAL); do  
					if [ ! "$(redis-cli -h $MASTER_HOST$i -p $REDIS_PORT cluster nodes | wc -l || echo 0 )" = "0" ]; then
							echo "{INFO} $i is alive, select it"
							MASTER_NUM=$i     
							break 
					fi
			done
		fi
	fi
}

echo "{INFO} Redis node (arbiter version) started"
sleep 3 #wait redis-server to be ready
if [ "$DEBUG" = "1" ]; then sleep 3; fi	#debug

#wait self to start
while [ ! "$(redis-cli -p $REDIS_PORT --raw keys '*' >/dev/null && echo 1 || echo 0)" = "1" ]; do
	sleep 3
done

#if [ ! "$(redis-cli -p $REDIS_PORT cluster nodes | wc -l || echo 1)" = "1" ]; then 
#	echo "Node is already in cluster";
	redis-cli -p $REDIS_PORT FLUSHALL >/dev/null
	redis-cli -p $REDIS_PORT CLUSTER RESET >/dev/null
#fi

#wait for arbiter
while [ ! "$(redis-cli -h $ARBITER_HOST -p $ARBITER_PORT --raw keys '*' >/dev/null && echo 1 || echo 0)" = "1" ]; do
	sleep 5
done

redis-cli --raw -h $ARBITER_HOST -p $ARBITER_PORT SETNX init_done 0


#try to lock
lock_set

	trap lock_unset EXIT

	if [ "$DEBUG" = "1" ]; then sleep 3; fi	#debug

	#try to set self as primary master
	if [ ! "$(redis-cli --raw -h $ARBITER_HOST -p $ARBITER_PORT SETNX master $SLOT_NUM)" = "1" ]; then
		#othervise get already declared one
		MASTER_NUM=$(redis-cli --raw -h $ARBITER_HOST -p $ARBITER_PORT GET master)
		echo "{INFO} Master already declared, lets use $MASTER_NUM"
	fi

	#check whether there is no node already in cluster (if arbiter restarted)
	if [ "$MASTER_NUM" = "$SLOT_NUM" ]; then
		for i in $(seq 1 $SLOTS_TOTAL); do  
			if [ ! "$( (redis-cli -h $MASTER_HOST$i -p $REDIS_PORT cluster nodes || echo 1) | wc -l )" = "1" ]; then
				echo "{INFO} Node $i is already in cluster, select it as primary"
				MASTER_NUM=$i
				break
			fi
		done
	fi

	#if we are not primary master
	if [ ! "$MASTER_NUM" = "$SLOT_NUM" ]; then
		#check wether primary master is alive 
		check_master

		if [ "$MASTER_NUM" = "0" ]; then
			echo "{INFO} node in cluster not found, I will be Master"
			MASTER_NUM=$SLOT_NUM
		fi
		redis-cli --raw -h $ARBITER_HOST -p $ARBITER_PORT DEL master >/dev/null
		redis-cli --raw -h $ARBITER_HOST -p $ARBITER_PORT SETNX master $MASTER_NUM >/dev/null

		check_and_fix

		#another check whether we become primary master
		if [ ! "$MASTER_NUM" = "$SLOT_NUM" ]; then
			if [ "$(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster nodes | grep master | wc -l)" = "$MASTERS_TOTAL" ]; then
				echo "{INFO} Masters full, lets connect as slave"
				SLAVE="--cluster-slave";
			fi

			redis-cli --cluster add-node $(hostname):$REDIS_PORT $MASTER_HOST$MASTER_NUM:$REDIS_PORT $SLAVE || pkill redis-server
			sleep 3

			if [ ! -n "$SLAVE" ]; then

				if [ "$(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster nodes | grep master | wc -l)" = "$MASTERS_TOTAL" ]; then
					echo "{INFO} Cluster becomes full, lets rebalance"
					redis-cli --cluster rebalance $MASTER_HOST$MASTER_NUM:$REDIS_PORT --cluster-use-empty-masters || pkill redis-server
				fi
				redis-cli --raw -h $ARBITER_HOST -p $ARBITER_PORT SET init_done 1
			fi
		fi
	else
		redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT CLUSTER ADDSLOTSRANGE 0 16383;
		echo "{INFO} I am Master"
	fi

lock_unset

echo Init done

echo Waiting while cluster becomes ready
while [ ! "$(redis-cli --raw -h $ARBITER_HOST -p $ARBITER_PORT GET init_done)" = "1" ]; do
	sleep 5
done

echo Starting checker loop
while [ 1 -eq 1 ]; do
	lock_set
		check_master
		if [ "$MASTER_NUM" = "0" ]; then
			echo "{INFO} Could not found primary master, exiting"
			lock_unset
			pkill redis-server
			exit 1
		fi
		check_and_fix
		if [ "$(redis-cli -p $REDIS_PORT cluster nodes | wc -l)" = "1" ]; then
		        sleep 3
		fi
	lock_unset
	sleep $CHECK_PERIOD
done;
