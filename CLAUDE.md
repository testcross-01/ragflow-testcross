# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RAGFlow is an open-source RAG (Retrieval-Augmented Generation) engine based on deep document understanding. Full-stack: Python backend (Flask) + React/TypeScript frontend (UmiJS) + Docker microservices.

## Quick Start Commands

```bash
# Backend (source)
./start_backend.sh         # Docker middleware + backend from source
source .venv/bin/activate && export PYTHONPATH=$(pwd) && export HF_ENDPOINT=https://hf-mirror.com && bash docker/launch_backend_service.sh

# Frontend (source)
./start_frontend.sh        # requires Node.js 20

# Stop all
./stop.sh
```

## Architecture

### Backend (`/api/`)
- `api/ragflow_server.py` - Flask entry point (port 9380)
- `api/apps/` - Flask blueprints (kb, document, dialog, canvas, file, etc.)
- `api/db/db_models.py` - Peewee ORM models (User, Tenant, Knowledgebase, Document, etc.)
- `api/db/services/` - Service layer

### RAG Pipeline (`/rag/`)
- `rag/nlp/search.py` - `Dealer` class: central retrieval engine
- `rag/llm/` - Embedding, reranking, chat model abstractions (30+ providers)
- `rag/flow/` - Pipeline components (Parser → Splitter → Tokenizer)
- `rag/app/` - Document-type-specific parsers (naive, paper, book, laws, etc.)
- `rag/utils/es_conn.py`, `infinity_conn.py` - Vector DB connectors

### DeepDoc (`/deepdoc/`)
- `deepdoc/vision/` - ONNX-based OCR, layout recognition, table structure recognition
- `deepdoc/parser/` - Format parsers (PDF, DOCX, Excel, PPT, HTML, Markdown)

### Agent Framework (`/agent/`)
- `agent/canvas.py` - `Canvas(Graph)`: DAG execution engine with streaming
- `agent/component/` - Workflow nodes (LLM, Agent/ReAct, Categorize, Switch, Message, etc.)
- `agent/tools/` - External tools (Retrieval, CodeExec, Crawler, Tavily, Wikipedia, SQL, etc.)

### Frontend (`/web/`)
- React 18 + UmiJS 4 + TypeScript + Ant Design 5 + Tailwind CSS
- State: @tanstack/react-query (server), zustand (client), react-hook-form + zod
- Proxy: `/api` and `/v1` → `http://127.0.0.1:9380/`

## Backend Auth Flow

1. Login → backend generates `access_token` (UUID), signs via `Serializer` (itsdangerous), returns as `Authorization` response header
2. Frontend stores in localStorage, sends `Authorization` header on every request
3. `_load_user()` decodes signed token → finds `User` by `access_token`
4. `User.get_id()` returns signed token: `jwt.dumps(str(self.access_token))`

## Infrastructure

| Service | Port | Config |
|---------|------|--------|
| MySQL 8.0 | 5455 | `docker/.env` |
| Elasticsearch 8.11 | 1200 | `docker/.env` → `DOC_ENGINE` |
| Valkey/Redis 8 | 6379 | `docker/.env` |
| MinIO | 9000/9001 | `docker/.env` |
| Sandbox Executor | 9385 | gVisor-secured code execution |

Config: `conf/service_conf.yaml` + `docker/.env`. Key env vars: `DOC_ENGINE`, `DB_TYPE`, `STORAGE_IMPL`, `HF_ENDPOINT`.
