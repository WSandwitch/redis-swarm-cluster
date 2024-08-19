MASTER_NUM=$SLOT_NUM
IAMMASTER=1
echo "Redis node (arbiter version) started"

if [ "$DEBUG" = "1" ]; then sleep 3; fi	#debug

#wait self to start
while [ ! "$(redis-cli -p $REDIS_PORT --raw keys '*' >/dev/null && echo 1 || echo 0)" = "1" ]; do
	sleep 3
done

#if [ ! "$(redis-cli -p $REDIS_PORT cluster nodes | wc -l || echo 1)" = "1" ]; then 
#	echo "Node is already in cluster";
#	redis-cli -p $REDIS_PORT FLUSHALL;
#	redis-cli -p $REDIS_PORT CLUSTER RESET;
#fi

#wait for arbiter
while [ ! "$(redis-cli -h $ARBITER_HOST --raw keys '*' >/dev/null && echo 1 || echo 0)" = "1" ]; do
	sleep 5
done


#try to lock
while [ ! "$(redis-cli --raw -h $ARBITER_HOST SETNX lock 1)" = "1" ]; do
	sleep 1
done
	echo "Lock set"

	function cleanup {
		while [ ! "$(redis-cli --raw -h $ARBITER_HOST DEL lock)" = "1" ]; do
			sleep 1
		done
		echo "Lock released"
	}
	trap cleanup EXIT
	
	if [ "$DEBUG" = "1" ]; then sleep 3; fi	#debug

	#try to set self as primary master
	if [ ! "$(redis-cli --raw -h $ARBITER_HOST SETNX master $SLOT_NUM)" = "1" ]; then
		#othervise get already declared one
		MASTER_NUM=$(redis-cli --raw -h $ARBITER_HOST GET master)
	fi

	#if we are not primary master
	if [ ! "$MASTER_NUM" = "$SLOT_NUM" ]; then
		#check wether primary master is alive 
		if [ ! "$(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT --raw keys '*' >/dev/null && echo 1 || echo 0)" = "1" ]; then
			echo "Could not connect to master" 
			exit 1;
			#add fix for master not found
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
		fi


		redis-cli --cluster check $MASTER_HOST$MASTER_NUM:$REDIS_PORT || yes yes|redis-cli --cluster fix $MASTER_HOST$MASTER_NUM:$REDIS_PORT --cluster-fix-with-unreachable-masters

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
	#		redis-cli --cluster check $MASTER_HOST$MASTER_NUM:$REDIS_PORT || sleep 250 # sleep to allow master finish rebalance
		fi

		redis-cli --cluster add-node $(hostname):$REDIS_PORT $MASTER_HOST$MASTER_NUM:$REDIS_PORT $SLAVE || pkill redis-server
		sleep 3

		if [ ! -n "$SLAVE" ]; then

			if [ "$(redis-cli -h $MASTER_HOST$MASTER_NUM -p $REDIS_PORT cluster nodes | grep master | wc -l)" = "$MASTERS_TOTAL" ]; then
				echo "Cluster is full, lets rebalance"
				redis-cli --cluster rebalance $MASTER_HOST$MASTER_NUM:$REDIS_PORT --cluster-use-empty-masters || pkill redis-server
			fi

		fi

	fi
	echo "I am Master($SLOT_NUM)"



echo Done


