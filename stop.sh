#!/bin/bash
echo "=== 停止后端/前端 ==="
pkill -f "ragflow_server.py|task_executor.py|umi dev" 2>/dev/null
echo "=== 停止 Docker ==="
cd "$(dirname "$0")/docker"
docker-compose -f docker-compose-base.yml down 2>/dev/null
echo "完成"
