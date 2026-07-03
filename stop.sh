#!/bin/bash
# 停止 RAGFlow 所有开发服务

echo "=== 停止后端 ==="
pkill -f "ragflow_server.py|task_executor.py" 2>/dev/null && echo "   后端已停止" || echo "   后端未运行"

echo "=== 停止前端 ==="
pkill -f "umi dev" 2>/dev/null && echo "   前端已停止" || echo "   前端未运行"

echo "=== 停止 Docker 中间件 ==="
cd "$(dirname "$0")/docker"
docker-compose -f docker-compose-base.yml down 2>/dev/null && echo "   Docker 已停止" || echo "   Docker 未运行"
