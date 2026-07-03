#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "=== 1. 启动 Docker 中间件 ==="
COMPOSE_PROFILES=elasticsearch,sandbox docker-compose -f docker/docker-compose-base.yml up -d

echo "=== 2. 等待服务健康 ==="
until [ "$(docker ps --filter "health=healthy" --format '{{.Names}}' | wc -l)" -ge 5 ]; do
    sleep 5
done
docker ps --format "table {{.Names}}\t{{.Status}}"

echo "=== 3. 启动后端 ==="
source .venv/bin/activate
export PYTHONPATH=$(pwd)
export HF_ENDPOINT=${HF_ENDPOINT:-https://hf-mirror.com}
bash docker/launch_backend_service.sh &
echo "后端: http://localhost:9380"
