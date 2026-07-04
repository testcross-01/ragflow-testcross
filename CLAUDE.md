# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

RAGFlow 是一个基于深度文档理解的开源 RAG 引擎。全栈：Python 后端 (Flask) + React/TypeScript 前端 (UmiJS) + Docker 微服务。

## 快速启动

```bash
# 后端（源码启动）
./start_backend.sh
# 或手动：source .venv/bin/activate && export PYTHONPATH=$(pwd) && bash docker/launch_backend_service.sh

# 前端（Node.js 20）
./start_frontend.sh

# 停止全部
./stop.sh
```

## 架构

### 后端 (`/api/`)
- `api/ragflow_server.py` — Flask 入口（端口 9380）
- `api/apps/` — Flask Blueprint 路由（kb, document, dialog, canvas, file 等）
- `api/db/db_models.py` — Peewee ORM 模型（User, Tenant, Knowledgebase, Document 等）
- `api/db/services/` — 业务服务层

### RAG 流水线 (`/rag/`)
- `rag/nlp/search.py` — `Dealer` 类：核心检索引擎
- `rag/llm/` — 模型抽象层：Chat / Embedding / Rerank（30+ 厂商，LiteLLM + OpenAI SDK 双路径）
- `rag/flow/` — 文档处理流水线（Parser → Splitter → Tokenizer）
- `rag/app/` — 按文档类型的解析器（naive, paper, book, laws 等）
- `rag/utils/es_conn.py`, `infinity_conn.py` — 向量数据库连接器

### DeepDoc 文档解析 (`/deepdoc/`)
- `deepdoc/vision/` — ONNX 模型的 OCR、版面识别、表格结构识别
- `deepdoc/parser/` — 格式解析器（PDF, DOCX, Excel, PPT, HTML, Markdown）

### Agent 框架 (`/agent/`)
- `agent/canvas.py` — `Canvas(Graph)`：DAG 执行引擎，支持流式输出
- `agent/component/` — 工作流节点（Begin, LLM, Agent/ReAct, Categorize, Switch, Message 等）
- `agent/tools/` — 外部工具（Retrieval, CodeExec, Crawler, Tavily, Wikipedia, SQL 等 20+ 个）

### 模型层 (`/rag/llm/`)
- `__init__.py` — 自动发现注册，`ChatModel["DeepSeek"]` 即用
- `chat_model.py` — OpenAI SDK 路径 (`Base`) + LiteLLM 路径 (`LiteLLMBase`)，DeepSeek 走 LiteLLM
- `embedding_model.py` — 每个厂商一个类，继承 `Base`
- `rerank_model.py` — 同上模式
- 调用链：`TenantLLMService.model_instance()` → `ChatModel[factory](key, model, url)`

### 前端 (`/web/`)
- React 18 + UmiJS 4 + TypeScript + Ant Design 5 + Tailwind CSS
- 状态管理：`@tanstack/react-query`（服务端）+ `zustand`（客户端）+ `react-hook-form` + `zod`
- 代理：`/api` 和 `/v1` 转发到 `http://127.0.0.1:9380/`

## 认证流程

1. 登录 → 后端生成 `access_token` (UUID)，通过 `Serializer` (itsdangerous) 签名，作为 `Authorization` 响应头返回
2. 前端存入 localStorage，每个请求带上 `Authorization` 头
3. `_load_user()` 解码签名 → 用 `access_token` 查找 User
4. `User.get_id()` 返回签名后的 token：`jwt.dumps(str(self.access_token))`

## 基础设施

| 服务 | 端口 | 说明 |
|------|------|------|
| MySQL 8.0 | 5455 | 关系数据库 |
| Elasticsearch 8.11 | 1200 | 全文+向量检索（可通过 `DOC_ENGINE` 切换） |
| Valkey/Redis 8 | 6379 | 缓存 + 消息队列 |
| MinIO | 9000/9001 | S3 兼容对象存储 |
| Sandbox Executor | 9385 | gVisor + seccomp 安全代码执行 |

配置：`conf/service_conf.yaml` + `docker/.env`。关键环境变量：`DOC_ENGINE`、`DB_TYPE`、`STORAGE_IMPL`、`HF_ENDPOINT`。

## 已发现的问题

1. **WSL 环境 tailwindcss 超时** — `node_modules/@umijs/plugins/dist/tailwindcss.js` 第 29 行 `CHECK_TIMEOUT_UNIT_SECOND = 5` 改为 30
2. **TokenizerParam import 失败** — 需设 `NLTK_DATA` 环境变量指向项目 `nltk_data` 目录，另需安装 `exceptiongroup`
3. **RAPTOR 处理 chunk 缺少 text 字段** — `task_executor.py` 第 624 行 `ck["text"]` 应在 RAPTOR 合并后做 fallback
4. **前端 `useFetchKnowledgeList`** — `data?.data ?? []` 兜不住 `data: false`，需 `Array.isArray()` 判断
5. **DeepSeek 新模型** — 已在 `llm_factories.json` 添加 `deepseek-v4-pro` / `deepseek-v4-flash`
