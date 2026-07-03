#!/bin/bash
# RAGFlow 后端开发启动脚本
# 自动启动 Docker 中间件 + 源码后端

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== 1. 启动 Docker 中间件 ==="
COMPOSE_PROFILES=elasticsearch,sandbox docker-compose -f docker/docker-compose-base.yml up -d

echo "=== 2. 等待服务健康检查 ==="
until [ "$(docker ps --filter "health=healthy" --format '{{.Names}}' | wc -l)" -ge 5 ]; do
    echo "  等待中..."
    sleep 5
done
echo "   所有服务已就绪"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo "=== 3. 激活虚拟环境 ==="
if [ ! -d ".venv" ]; then
    echo "   .venv 不存在，请先运行: uv sync --all-extras"
    exit 1
fi
source .venv/bin/activate
export PYTHONPATH=$(pwd)
export HF_ENDPOINT=${HF_ENDPOINT:-https://hf-mirror.com}

echo "=== 4. 启动后端服务 ==="
bash docker/launch_backend_service.sh &

echo ""
echo "=== 后端启动中，监听 http://localhost:9380 ==="
echo "    查看日志: tail -f logs/ragflow_server.log"
echo "    停止服务: pkill -f 'ragflow_server.py|task_executor.py'"
