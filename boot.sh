

sleep 5;

if [ ! "$(redis-cli -p $REDIS_PORT cluster nodes | wc -l || echo 1)" = "1" ]; then 
	echo "Node is already in cluster";
#	redis-cli -p $REDIS_PORT FLUSHALL;
#	redis-cli -p $REDIS_PORT CLUSTER RESET;
fi

sleep $(((SLOT_NUM-1)*20))

#if [ ! "$SLOT_NUM" = "1" ]; then 
#	sleep $((RANDOM % 60)); #aviod race condition
#fi
MASTER_NUM=0


for i in $(seq 1 $SLOTS_TOTAL); do  
	if [ ! "$(redis-cli -h $MASTER_HOST$i -p $REDIS_PORT cluster nodes | wc -l || echo 1)" = "1" ]; then
		echo "Node $i in cluster, select it"
		MASTER_NUM=$i
		break
	fi
done

if [ "$MASTER_NUM" = "0" ]; then
	echo "Node in cluster not found, searching for first running node"
	for i in $(seq 1 $SLOTS_TOTAL); do  
        	if [ ! "$(redis-cli -h $MASTER_HOST$i -p $REDIS_PORT cluster nodes | wc -l || echo 0)" = "0" ]; then
        	        echo "$i is alive, select it"
        	        MASTER_NUM=$i     
        	        break 
        	fi
	done
	redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT CLUSTER ADDSLOTSRANGE 0 16383;
fi

#check for cluster status and fix if necessary
redis-cli --cluster check $MASTER_HOST$MASTER_NUM:$REDIS_PORT ||\
  redis-cli --cluster check $MASTER_HOST$MASTER_NUM:$REDIS_PORT | grep "WARN" ||\
  yes yes|redis-cli --cluster fix $MASTER_HOST$MASTER_NUM:$REDIS_PORT --cluster-fix-with-unreachable-masters

sleep 3

if [ ! "$(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster nodes | grep fail | wc -l || echo 0)" = "0" ]; then 
        echo "Found failed nodes, need to clean up";
	for i in $(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster nodes |grep fail| awk '{print $1}'); do
		echo "Foget about node $i"
		redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster forget $i
	done
	sleep 3
fi

if [ "$(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster nodes | grep master | wc -l)" = "$MASTERS_TOTAL" ]; then
	echo "Masters full, lets connect as slave"
	SLAVE="--cluster-slave";
#	redis-cli --cluster check $MASTER_HOST$MASTER_NUM:$REDIS_PORT || 
	sleep 250 # sleep to allow master finish rebalance
fi


redis-cli --cluster add-node $(hostname):$REDIS_PORT $MASTER_HOST$MASTER_NUM:$REDIS_PORT $SLAVE || pkill redis-server
sleep 3

if [ ! -n "$SLAVE" ]; then

	if [ "$(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster nodes | grep master | wc -l)" = "$MASTERS_TOTAL" ]; then
		echo "Cluster is full, lets rebalance"
		redis-cli --cluster rebalance $MASTER_HOST$MASTER_NUM:$REDIS_PORT --cluster-use-empty-masters || pkill redis-server
	fi

fi

echo Done
#else #SLAVE

#sh -c "sleep 10;\
#redis-cli -p $REDIS_PORT FLUSHALL;\
#redis-cli -p $REDIS_PORT CLUSTER RESET;\
#until redis-cli --cluster check $MASTER_HOST:$MASTER_PORT;do sleep 3;done;\
#until redis-cli --cluster add-node $(hostname):$REDIS_PORT $MASTER_HOST:$MASTER_PORT $SLAVE;do sleep 5;done;"&

