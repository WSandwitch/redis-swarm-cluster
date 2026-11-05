set -xe

#docker buildx build --platform linux/amd64 .
##docker buildx build --platform linux/386 .
#docker buildx build --platform linux/arm/v7 .
#docker buildx build --platform linux/arm64 .
#docker buildx build --platform linux/ppc64le .
#docker buildx build --platform linux/s390x .
#docker buildx build --platform linux/riscv64 .

docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7,linux/ppc64le,linux/s390x,linux/riscv64 -t wsandwitch/redis-cluster:7-alpine3.20 --push .
docker buildx imagetools create -t wsandwitch/redis-cluster:v1.4 wsandwitch/redis-cluster:7-alpine3.20
docker buildx imagetools create -t wsandwitch/redis-cluster:latest wsandwitch/redis-cluster:7-alpine3.20
docker pushrm wsandwitch/redis-cluster
#docker buildx build --platform linux/riscv64 .
#docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7,linux/ppc64le,linux/s390x,linux/riscv64 -t wsandwitch/nginx:1.25.5-alpine --push .
