# 任务执行系统

## 任务提交流程

```
前端 / API
  ├── POST /canvas/completion     Canvas 内调试运行
  ├── POST /document/change_status  知识库中点击"开始解析"
  ├── POST /canvas/rerun         重跑已完成文档
  ├── POST /v1/documents         HTTP API 上传文档
  └── POST /sdk/doc              Python SDK 上传
           ↓
  queue_dataflow()  或  queue_tasks()
           ↓
  Redis Stream 消息队列
           ↓
  task_executor worker 消费执行
```

### 各接口调用方式

| 接口 | 场景 | 函数 | task_type |
|------|------|------|-----------|
| `POST /canvas/completion` | 画布点击调试运行 | `queue_dataflow(rerun=False)` | `dataflow` |
| `POST /document/change_status` | 文档列表点开始解析 | 有 pipeline_id → `queue_dataflow()` / 无 → `queue_tasks()` | `dataflow` / 空 |
| `POST /canvas/rerun` | 重跑已完成文档 | `queue_dataflow(rerun=True)` | `dataflow_rerun` |
| `POST /v1/documents` | HTTP API 上传 | `queue_tasks()` | 空 |
| `POST /sdk/doc` | Python SDK 上传 | `queue_tasks()` | 空 |
| `PUT /canvas/cancel/<task_id>` | 取消运行中任务 | 写 Redis 取消信号 | — |

### queue_dataflow()（task_service.py:497）

构造 task dict，写入 MySQL Task 表，再 push 到 Redis Stream：

```python
task = {
    "id": get_uuid(),
    "doc_id": doc_id,
    "task_type": "dataflow" if not rerun else "dataflow_rerun",
    "priority": priority,
    "kb_id": ...,
    "tenant_id": tenant_id,
    "dataflow_id": flow_id,   # Canvas UUID（非 rerun）或 PipelineOperationLog UUID（rerun）
    "file": {...},            # 仅 Canvas 调试时有值
}
# 清理该文档的旧 Task
TaskService.model.delete().where(TaskService.model.doc_id == doc_id).execute()
# 写 MySQL + Redis
bulk_insert_into_db(model=Task, data_source=[task], replace_on_conflict=True)
REDIS_CONN.queue_product(get_svr_queue_name(priority), task)
```

同一时刻一个文档最多一条 Task。

### queue_tasks()（task_service.py:326）

旧版解析路径。PDF 按页拆分（每 12 页一个 task），Excel 按行拆分。不走 Pipeline，直接调用内部解析器。

---

## Redis 使用全景

所有数据都在 Redis DB 1。

### 消息队列（Streams）

| Key | 用途 |
|------|------|
| `rag_flow_svr_queue` | 普通优先级任务队列 |
| `rag_flow_svr_queue_1` | 高优先级任务队列 |

消费者组名：`rag_flow_svr_task_broker`

### 执行日志（String，存 JSON）

| Key | 用途 | 写入方 | 读取方 |
|------|------|------|------|
| `{flow_id}-{task_id}-logs` | Pipeline 执行进度日志 | `Pipeline.callback()` | `/canvas/trace` 接口轮询 |
| `{canvas_id}-{message_id}-logs` | Agent Canvas 执行日志 | Canvas 运行 | `/canvas/trace` 接口 |

`Pipeline.callback()` 的数据结构：
```json
[
  {
    "component_id": "File",
    "trace": [
      {"progress": 0.05, "message": "File fetched.", "datetime": "14:30:01", ...}
    ]
  },
  {
    "component_id": "Parser",
    "trace": [...]
  }
]
```

TTL：初始写入 10 分钟，每次更新重置为 30 分钟。

### 辅助键

| Key | 类型 | 用途 |
|------|------|------|
| `{task_id}-cancel` | String | 取消信号，值为 "x"。`has_canceled()` 检查 |
| `TASKEXE` | Set | 活跃 worker 名集合（如 `myhost-12345`） |
| `{consumer_name}` | Sorted Set | worker 心跳时间戳（score=时间戳, member=心跳标记）。超时 30 分钟自动清理 |
| `{email}_captcha` | String | 登录验证码，TTL 60s |

### 其他 Redis 用途

- **嵌入并发控制**：`embed_limiter` 信号量限制同时 embedding 的请求数
- **Canvas 重置**：`Graph.reset()` 删除 `{task_id}-logs`

---

## Worker 消费循环（task_executor.py:199-250）

```
while True:
    redis_msg = queue_consumer(queue_name, group_name, consumer_name)
    msg = redis_msg.get_message()
    task = TaskService.get_task(msg["id"])    # 从 MySQL 补全任务信息
    if has_canceled(task["id"]):
        skip
    dispatch(task)
```

按 `task_type` 分流：

```python
if task_type in ["dataflow", "dataflow_rerun"]:
    await run_dataflow(task)     # Pipeline.run()
elif task_type == "raptor":
    await run_raptor(task)       # RAPTOR 层次化摘要
elif task_type == "graphrag":
    await run_graphrag(task)     # 知识图谱提取
elif task_type == "mindmap":
    await run_mindmap(task)      # 思维导图
else:
    await run_document_parse(task)  # 旧版解析
```

### 健康检查（task_executor.py:996-1040）

1. 启动时 `SADD TASKEXE {consumer_name}` 注册
2. 每 30s 执行 `ZADD {consumer_name} heartbeat timestamp` 更新心跳
3. 清理逻辑：`ZCOUNT` 找出超时（30min+）的 consumer → `SREM TASKEXE` + `DELETE` 对应 key

### 并发控制

Redis Streams 的 Consumer Group 天然支持负载均衡，多个 worker 不会消费同一条消息。关键命令：

| 命令 | 作用 |
|------|------|
| `XADD` | 生产者将消息追加到 Stream |
| `XREADGROUP` | 消费者从 Stream 取消息（同组内竞争，一条消息只分配一个消费者） |
| `XACK` | 消费者确认处理完毕，从 Pending 列表移除 |
| `XGROUP CREATE` | 创建消费者组（程序启动时自动创建） |
| `XPENDING` / `XCLAIM` | 查看/认领未确认的消息（超时接管用） |

消息体结构极简——整个 `task` dict 序列化为 JSON 字符串，存入单一的 `message` 字段：

```python
# 入队
payload = {"message": json.dumps(task)}
self.REDIS.xadd(queue, payload)

# 出队
self.__message = json.loads(message["message"])
```

因此不需要分布式锁来防止重复消费——Redis Consumer Group 做了仲裁。唯一可能重复的场景：worker 处理到一半挂了没 `XACK`，消息留在 Pending 列表被其他 worker 通过 `get_unacked_iterator` 认领重执行。对 pipeline 而言后果可控：同文档旧 Task 先被删除，向量库写入靠 `xxhash` 确定的 chunk ID 覆盖。

`DOC_BULK_SIZE`（默认 4）控制单个 worker 同时处理的 task 数。其他需要限流的地方（如 embedding 调用）通过 `embed_limiter` 信号量单独控制。

---

## run_dataflow() 执行流程（task_executor.py:513-670）

```
1. 取 DSL
   task_type == "dataflow"  → UserCanvasService.get_by_id(dataflow_id).dsl
   task_type == "dataflow_rerun" → PipelineOperationLogService.get_by_id(dataflow_id).dsl
                                   dataflow_id = log.pipeline_id  （还原真实 Canvas ID）

2. 构造 Pipeline
   pipeline = Pipeline(dsl, tenant_id, doc_id, task_id, flow_id)

3. 执行
   chunks = await pipeline.run(file=task["file"]) if task.get("file") else await pipeline.run()

4. 写入 MySQL（三处）
   ├── Task 表: set_progress() 更新 progress / progress_msg / process_duration
   ├── PipelineOperationLog 表: create() 写入 DSL 快照（含运行结果、状态、时间戳）
   └── Document 表: increment_chunk_num() 写 chunk 数和 token 数
                       update_by_id() 写 meta_fields（如有提取到元数据）

5. 写入向量库
   解析 chunks → 批量写入 Elasticsearch / Infinity（非 MySQL）
```

Pipeline.run() 执行过程中，`set_progress()` 会持续更新 MySQL Task 表的进度，而非只在完成时写一次。`Pipeline.callback()` 则同时写 Redis 日志供前端轮询，两者并行不冲突。

### Canvas 调试 vs 正式文档

| | Canvas 调试 | 正式文档解析 |
|------|------|------|
| doc_id | `CANVAS_DEBUG_DOC_ID` | 真实文档 UUID |
| file | `task["file"]` 临时传入 | 无（组件从存储加载） |
| 结果写入 | 不写向量库 | 写向量库 + ES |
| PipelineOperationLog | 不创建 | 创建 |

### Chunk 入库前的标准化（task_executor.py:618-648）

`pipeline.run()` 返回后，`run_dataflow()` 对 chunk 做最后清理再入库：

- `questions` → 拆为 `question_kwd` 数组 + `question_tks` 分词 → 删除 `questions` 字符串
- `keywords` → 拆为 `important_kwd` 数组 + `important_tks` 分词 → 删除 `keywords` 字符串
- `summary` → 替代 text 作为正文分词源 → 删除 `summary` 字符串
- `metadata` → 合并到文档级元数据 → 删除
- `text` → `content_with_weight = text` → 删除 `text`
- `positions` → 写入结构化位置字段 → 删除原始数组
- 补充 `doc_id`、`kb_id`、`docnm_kwd`、`create_time`、`id = xxhash(text + doc_id)`

目的：Token 化所有文本字段，删除冗余原始字符串，统一入库格式。Tokenizer 已做过的分词不重复（`if "xxx_tks" not in ck` 判断）。

### ES 索引结构

同一租户下所有知识库的所有文档共享同一个 ES 索引 `{tenant_id}`，通过 `kb_id` 字段过滤隔离：

```
索引: "tenant-xxx"
  ├── kb_id = "kb-A"      ← 检索时按此过滤
  │   ├── doc_id = "doc-1"  chunk1, chunk2...
  │   └── doc_id = "doc-2"  chunk3, chunk4...
  └── kb_id = "kb-B"
      └── doc_id = "doc-3"  chunk5...
```

### Chunk 去重与重跑

每次重跑同文档前会先删除旧向量：

- **doc_id 级删除**：`settings.docStoreConn.delete({"doc_id": id}, ...)` — 重跑/rerun 前执行
- **chunk ID 确定性**：`xxhash(text + doc_id)` — 内容相同生成相同 `_id`，ES upsert 自动覆盖

不会出现同一文档多次处理的向量累积。

### 进度监控全景

| 存储 | 写入时机 | 内容 | 前端消费 |
|------|------|------|------|
| Redis `{flow_id}-{task_id}-logs` | `Pipeline.callback()` 每步 | 组件级 trace 时间线（timestamp, message, elapsed_time 数组） | `/canvas/trace` 3s 轮询（react-query `refetchInterval`） |
| MySQL Task 表 | `set_progress()` → `TaskService.update_progress()` | progress 百分比 + 最新 progress_msg | `/v1/document/list` 15s 轮询 |
| MySQL Document 表 | `increment_chunk_num()` | chunk 数 + token 消耗 + 总耗时 | 文档详情页 |

列表页的进度条来自 MySQL，点进去的详细时间线来自 Redis。

### 进程崩溃处理

- 消息不丢失：未 ACK 的消息留在 Redis Stream Pending 列表
- 心跳超时（30min）：zset 心跳过期 → 从 `TASKEXE` 移除 → Pending 消息可被其他 worker 通过 `get_unacked_iterator` 认领
- MySQL Task 状态卡在半中间，不会自动复位
- Redis 日志 key TTL 30min，超时消失

需人工重新发起运行，或 30 分钟内重启 worker 触发自动认领。

### 并发控制

多文档上传不会同时处理所有。限流层次：

| 层次 | 机制 | 限制 |
|------|------|------|
| 进程级 | 单 worker 循环消费 Redis Stream | 一次只取一条 |
| 协程级 | `DOC_BULK_SIZE`（默认 4） | 单 worker 同时处理数 |
| 外部 API | `embed_limiter` / `minio_limiter` 信号量 | 防打爆 embedding 和对象存储 |

---

## Rerun 机制

### 首次运行

`run_dataflow()` 完成后创建 `PipelineOperationLog`：

```python
PipelineOperationLogService.create(
    document_id=doc_id,
    pipeline_id=dataflow_id,    # Canvas UUID
    dsl=str(pipeline),          # 运行后的 DSL 快照
)
```

### 重跑（`POST /canvas/rerun`）

```python
# 前端传入 rerun 的记录 ID + DSL + 起始组件
PipelineOperationLogService.update_by_id(req["id"], {"dsl": dsl})
dsl["path"] = [req["component_id"]]   # 从指定组件开始
queue_dataflow(flow_id=req["id"], rerun=True)
#              ↑ flow_id 是 PipelineOperationLog 的 ID
```

`run_dataflow()` 根据 `task_type == "dataflow_rerun"` 走 else 分支：

```python
pipeline_log = PipelineOperationLogService.get_by_id(dataflow_id)
dsl = pipeline_log.dsl                    # 冻结的 DSL 快照（非最新 Canvas 定义）
dataflow_id = pipeline_log.pipeline_id    # 还原 Canvas UUID
```

每次 `create()` 都是 `force_insert=True` + `get_uuid()`，所以同个文档会产生多条历史记录。旧记录有数量上限保护（`PIPELINE_OPERATION_LOG_LIMIT`，默认 1000）。

### 取消机制

```python
# api/apps/canvas_app.py:211
REDIS_CONN.set(f"{task_id}-cancel", "x")

# task_service.py:490 / has_canceled()
return REDIS_CONN.get(f"{task_id}-cancel")

# Pipeline.callback() 中检查
if has_canceled(self.task_id):
    raise TaskCanceledException(message)
```

取消信号通过 Redis 传递——前端 → HTTP → Redis → 心跳循环中的 worker 看到后跳过，或运行中的 Pipeline.callback() 检测到后抛异常中止。
