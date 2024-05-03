set -e
export MASTER_PORT=${MASTER_PORT:-6389}
export REDIS_PORT=${REDIS_PORT:-$MASTER_PORT}

sh /boot.sh&

redis-server --port $REDIS_PORT --loglevel ${REDIS_LOGLEVEL:-warning} --save "" --appendonly no --maxmemory ${REDIS_MAXMEM:-2gb} --maxmemory-policy ${REDIS_POLICY:-allkeys-lru} --protected-mode no --cluster-enabled yes --enable-debug-command local --cluster-config-file /tmp/nodes.conf

