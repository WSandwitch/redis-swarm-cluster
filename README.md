Docker Swarm configuration for a self-assembling Redis Cluster. It can be used as a distributed replacement for a common Redis caching service.

The stack includes two services:
- nodes - Redis Cluster nodes, including bootstrap, join and maintenance logic ([Dockerfile](Dockerfile) in this repo).
- app - [redis-cluster-proxy](https://github.com/j3k0/redis-cluster-proxy), configured to work with the internal Redis Cluster.

No external arbiter is required. Nodes discover each other through Swarm DNS and coordinate through the cluster itself.

### Main configuration

```yaml
x-common-variables:
  master-hostname: &master-hostname 'redis-node'
  master-nodes: &master-nodes 3
  redis-replicas: &redis-replicas 6
  redis-port: &redis-port 6389
  redis-mem: &redis-mem 2G
```

- master-nodes - number of master nodes in the cluster
- redis-replicas - number of all nodes in the cluster
- redis-port - internal port of redis-server on a node
- redis-mem - max memory available for a Redis node
- master-hostname - internal hostname prefix for Redis nodes

### Node behaviour

On startup each node:
1. discovers all current stack nodes via `tasks.nodes` and hostnames;
2. waits for enough peers;
3. the lowest alive node bootstraps the cluster and assigns slot ranges to the first `MASTERS_TOTAL` masters;
4. other nodes join as masters or replicas depending on the current master count;
5. joins and maintenance operations are serialized with locks stored in the cluster.

The maintenance loop:
- forces failover from an unreachable master to its replica;
- repairs missing slots and failed nodes;
- rebalances empty masters when needed;
- forgets stale disconnected nodes.

Nodes keep no persistent data; Redis is used as a cache. Redis writes only to `/tmp`, which is mounted as tmpfs, so no Redis data is written to the real disk. A restarted or newly added node starts clean and joins the existing cluster automatically. A full stack restart rebuilds the cluster from scratch.

### Node variables

- `MASTERS_TOTAL` - desired number of masters
- `SLOTS_TOTAL` - expected number of nodes, used for bootstrap and discovery fallback
- `CHECK_PERIOD` - maintenance loop interval in seconds
- `BOOTSTRAP_TIMEOUT` - how long to wait for peers before bootstrapping with available nodes
- `BOOTSTRAP_STABLE` - peer discovery stabilization delay before bootstrap
- `NODE_TIMEOUT` - Redis Cluster node timeout in milliseconds
- `REBALANCE` - enable automatic rebalancing of empty masters
- `LOCK_TTL` - distributed lock TTL in seconds
- `FORCE_REBUILD` - reset local Redis state on startup
- `DEBUG` - verbose logging

### Deploy

```bash
docker stack deploy -c docker-compose.redis-proxy.yml redis
```

After the deploy it takes a short time for the cluster to assemble. Access is available on port 6379 by default through the `app` service.
