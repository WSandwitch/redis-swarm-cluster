Docker swarm config for distributed redis cache. It can be used as distributed replacement for common redis caching service.

#
Stack includes 3 services:
- nodes - redis server node, ([Dockerfile](https://github.com/WSandwitch/redis-swarm-cluster/blob/dev/Dockerfile) in this repo).
- app - [redis proxy](https://github.com/j3k0/redis-cluster-proxy), configured to work with internal redis cluster.
 - arbiter(optional) - redis instance for syncronise nodes initialisation (can be included in stack, or used external service)
###
Main configuration options moved to x-common-variables block:
```yaml
x-common-variables:
  master-hostname: &master-hostname 'redis-node'
  master-nodes: &master-nodes 3
  redis-replicas: &redis-replicas 6
  redis-port: &redis-port 6389
  redis-mem: &redis-mem 2G

```

- master-nodes - number of master nodes in cluster (other nodes are added as slaves)
- redis-replicas - number of all nodes in cluster
- redis-port - internal port of redis-server on redis node
- redis-mem -  max mem size available for redis node
- master-hostname - internal hostnames for redis nodes (usually not necessary to change)
  
If you want, you can change the most right value. If you will change hostname, you need also change it in nodes service config (in one line).
#
### Easy deploy:
```bash
wget https://raw.githubusercontent.com/WSandwitch/redis-swarm-cluster/master/docker-compose.yml
docker stack deploy -c docker-compose.yml redis
```
After that it takes several minutes for cluster to start and get ready, and then you can access it on 6379 port (by default).

