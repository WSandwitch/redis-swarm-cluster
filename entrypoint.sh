set -e
export MASTER_PORT=${MASTER_PORT:-6389}
export REDIS_PORT=${REDIS_PORT:-$MASTER_PORT}

rm -f /tmp/nodes.conf /tmp/dump.rdb
rm -rf /tmp/appendonlydir

sh /boot.sh&

redis-server --port $REDIS_PORT --loglevel ${REDIS_LOGLEVEL:-warning} --dir /tmp --save "" --appendonly no --maxmemory ${REDIS_MAXMEM:-2gb} --maxmemory-policy ${REDIS_POLICY:-allkeys-lru} --protected-mode no --cluster-enabled yes --enable-debug-command local --cluster-config-file /tmp/nodes.conf --cluster-node-timeout ${NODE_TIMEOUT:-15000}

