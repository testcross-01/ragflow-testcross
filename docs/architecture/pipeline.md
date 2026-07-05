# Pipeline 架构分析

## 整体架构

```
File → Parser → Splitter → Tokenizer
                ↘ Extractor         (LLM 提取结构化字段)
                ↘ HierarchicalMerger (按标题层级重组 chunks)
```

核心代码位于 `rag/flow/`，每个组件 = 参数类 `XxxParam` + 执行类 `Xxx(ProcessBase)`。

| 组件 | 类名 | 作用 | 输出格式 |
|------|------|------|----------|
| 文件加载 | `File` | 从 DB 或上传参数获取文档名和二进制内容 | name, file |
| 解析 | `Parser` | 按文件扩展名路由到不同解析器（PDF/Word/Excel/图片/音频等 9 种） | json / markdown / text / html |
| 切分 | `Splitter` | 按分隔符 + token 数切分文本为 chunks，支持重叠 | chunks |
| 分词+向量化 | `Tokenizer` | 对 chunks 做分词 + embedding，支持 title 加权 | chunks（带向量） |
| 提取 | `Extractor` | 用 LLM 从每个 chunk 中提取字段（summary/keywords/questions） | chunks |
| 层级合并 | `HierarchicalMerger` | 按正则匹配标题层级，将 chunks 合并为层级化文档 | chunks |

---

## 1. 自动组件注册

### `rag/flow/__init__.py`

启动时自动扫描 `rag/flow/` 下所有子模块（排除 `__init__`、`base` 等），找到所有公开类，注入到 `rag.flow` 的 `globals()` 中。

**为什么需要注册？**

`Graph.load()` 调用 `component_class(class_name)` 将 DSL 中的字符串转换为真实的 Python 类。`component_class()` 在 `agent/component/__init__.py:52-58`：

```python
def component_class(class_name):
    for mdl in ["agent.component", "agent.tools", "rag.flow"]:
        try:
            return getattr(importlib.import_module(mdl), class_name)
        except Exception:
            pass
```

这就要求 `Parser`、`Splitter` 等类必须在 `rag.flow` 模块的命名空间中（即 `getattr(rag.flow, "Parser")` 能找到），而普通 Python 子模块不会自动暴露类到父包。自动注册解决了这个"字符串→类"映射问题，新增组件时无需手动维护 `__init__.py`。

Python 没有 Java `Class.forName()` 那样 JVM 内置的 classloader 索引机制，所以需要自己写这十几行来实现。

---

## 2. 基类设计

### `rag/flow/base.py`

```
ProcessParamBase  (参数基类)
  ├── check()         校验参数合法性
  └── get_input_form()  前端表单渲染

ProcessBase(ComponentBase)  (组件执行基类)
  ├── invoke()        外层封装：超时保护（trio.fail_after）+ 错误兜底 + 回调通知
  └── _invoke()       子类实现真正的业务逻辑
```

关键设计点：
- **双层超时**：`invoke()` 的 `trio.fail_after` + `_invoke()` 的 `@timeout` 装饰器，双重保障
- **错误兜底**：`get_exception_default_value()` 机制允许组件出错时不中断整条流水线
- **回调通知**：`self.callback(progress, message)` 将进度和日志写入 Redis，供前端轮询

### Xxx 与 XxxParam 的绑定方式

Parser 类和 ParserParam 类之间没有显式引用，而是通过 `Graph.load()` 中的**命名约定**自动匹配（`canvas.py:91`）：

```python
param = component_class(cpn["obj"]["component_name"] + "Param")()
#                       "Parser"                     + "Param"
#                       "Splitter"                   + "Param"
```

就是字符串拼接。`rag/flow/__init__.py` 自动注册时已经把两者都注入命名空间，`load()` 在运行时通过约定找到对应 Param 类。这是一种**约定优于配置**的设计——先验参（构造 Param → check），后建实例（构造组件对象），`load()` 不依赖任何具体类名就能反序列化所有组件。

### callback 的来源

组件中 `self.callback` 来自 `ProcessBase.__init__`（`base.py:34-39`）：

```python
if hasattr(self._canvas, "callback"):
    self.callback = partial(self._canvas.callback, id)
else:
    self.callback = partial(lambda *args, **kwargs: None, id)
```

`partial` 把组件的 `id` 固定为第一个参数，后续组件只需 `self.callback(progress, msg)`，实际调用变成 `Pipeline.callback(component_name, progress, msg)`。Agent Canvas 没有 callback（空函数），因为走 SSE 流式推送。

### partial() 的其他用法

在 Splitter/Tokenizer 中 `partial(STORAGE_IMPL.put, tenant_id=...)` 把存储层的租户 ID 提前固定，使得回调函数签名与 `image2id` 的参数要求匹配，免去写 lambda 的冗余。

---

## 3. Pipeline 核心流程

### `rag/flow/pipeline.py`

`Pipeline(Graph)` 继承自 agent 框架的 DAG 引擎。

```python
class Pipeline(Graph):
    def __init__(self, dsl, tenant_id, doc_id, task_id, flow_id):
        super().__init__(dsl, tenant_id, task_id)  # → self.load()
```

**执行流程 `run()`**：

1. 初始路径 `path = ["File"]`，执行 File 组件
2. 获取 File 的下游组件，追加到 path
3. 循环：取上一个组件的 output → 传给下一个组件的 invoke()
4. 每个完成后追加下游，直到没有下游
5. 最终输出最后一个组件的 output

**日志系统**：每次回调将 progress/message/timestamp 写入 Redis（key: `{flow_id}-{task_id}-logs`），前端通过 `fetch_logs()` 拉取实时进度。`component_name == "END"` 时特殊处理。

---

## 4. DSL 序列化与反序列化

### 反序列化（JSON → 对象）

`Graph.__init__` → `self.load()`（`agent/canvas.py:83-98`）：

```
DSL JSON 中 "component_name": "Parser"
  → component_class("Parser") → getattr(rag.flow, "Parser")  # 查注册表
  → component_class("ParserParam") → ParserParam(params)
  → param.check()  # 校验参数
  → Parser(canvas, id, param)  # 实例化，存入 self.components
```

### 序列化（对象 → JSON）

`Graph.__str__()`（`agent/canvas.py:102-121`）：

遍历 `self.components`，将运行后的组件对象重新转回 JSON，通过 `json.loads(str(cpn["obj"]))` 调用 `ComponentBase.__str__()` 带上运行时的 outputs。

### 保存流程

前端拼好 DSL JSON → `POST /canvas/save` → `api/apps/canvas_app.py:save()` → 存入 MySQL。后端只做 JSON 合法性校验，不做业务逻辑处理。

### DSL 实例 ID 生成规则

组件 key 格式为 `{component_name}:{humanId()}`，如 `Splitter:EveryBarsRead`。前端 `use-add-node.ts:171`：

```typescript
import humanId from 'human-id';
id: `${type}:${humanId()}`
```

`human-id` 生成形容词+名词组合的可读随机 ID（如 `EveryBarsRead`）。`component_name` 确定"是什么类"，`humanId` 保证多实例唯一性。图拓扑（上游/下游引用）全靠这个 ID 串联。

### Pydantic 组件间契约

`schema.py` 文件（如 `SplitterFromUpstream`、`TokenizerFromUpstream`）定义组件间的接口契约：

```python
class SplitterFromUpstream(BaseModel):
    name: str
    output_format: str
    json_result: list[dict] | None = None
    ...

from_upstream = SplitterFromUpstream.model_validate(kwargs)  # 校验+转换
```

做的是**运行时接口契约检查**——直接用裸 dict 也可以，但 `model_validate` 后 IDE 有类型补全，且上游改了输出字段会当场报错，不会静默传播到深层逻辑导致难以定位的 KeyError。

---

## 5. 各组件详解

### File（起点）

输出 `name`（文档名）和 `file`（二进制对象），后续组件从这两个字段获取输入。内部分两条路径：

- **正式文档**（有 doc_id）：通过 `DocumentService` 查表获取文档信息
- **Canvas 调试**（无 doc_id）：从 `kwargs.get("file")` 取前端上传的临时文件

### Parser

核心路由逻辑在 `_invoke()`：

```python
function_map = {
    "pdf": self._pdf,     "text&markdown": self._markdown,
    "spreadsheet": self._spreadsheet,  "slides": self._slides,
    "word": self._word,   "image": self._image,
    "audio": self._audio, "video": self._video, "email": self._email,
}
# 按文件名后缀匹配 setups 中的配置，路由到对应 method
for p_type, conf in self._param.setups.items():
    if name.split(".")[-1].lower() in conf.get("suffix", []):
        await trio.to_thread.run_sync(function_map[p_type], name, blob)
```

PDF 解析有三种路径：DeepDoc（默认）、PlainText、MinerU。PDF 解析结果中的图片通过 `image2id` 上传到对象存储。

**文档二进制获取双路径**：

```
有 doc_id（正式文档）：
  File2DocumentService.get_storage_address(doc_id)
    → 查 file2document 关联表 → 查 File 表拿到 bucket + location
    → STORAGE_IMPL.get(bucket, location)
    → MinIO 桶 = kb_id, 路径 = doc.location

无 doc_id（Canvas 调试）：
  FileService.get_blob(file["created_by"], file["id"])
    → bucket = f"{user_id}-downloads"
    → STORAGE_IMPL.get(bucket, location)
    → MinIO 桶 = 用户上传桶, 路径 = file.location
```

两路径最终都到同一个 MinIO（通过 `STORAGE_IMPL` 封装），只是桶名和路径不同。

**为什么输出 JSON 而非纯文本？**

JSON 是流传到 Splitter 的结构化格式，保留了每个 section 的 `position_tag`（版面位置）、`img_id`（配图引用）等元数据。Splitter 切分时走 `naive_merge_with_images` 而非 `naive_merge`，保留图片和位置关联。Excel 的多 sheet、Word 的表格、PDF 的版面布局在 markdown/text 输出中都会丢失这些信息。

### Splitter

- `json` 输出：走 `naive_merge_with_images`（保留版面位置和图片）
- `markdown/text/html` 输出：走 `naive_merge`（纯文本切分）
- 参数：`chunk_token_size`、`delimiters`、`overlapped_percent`

**图片处理方式**：`naive_merge_with_images` 中图片是文本的属性，每个 bbox 的文本被分隔符拆成多个片段后，每个片段都携带同一张完整图片进入 `add_chunk`。同一 chunk 内合并多个 bbox 时，调用 `concat_img` 将图片垂直拼接（PIL Image 上下 paste）。像素相同的图去重跳过。图片不能被截断——如果文本跨 chunk，两个 chunk 各拿到原图的一份完整引用。

**为什么不在 Parser 阶段就合并图片？** Parser 不知道下游 Splitter 的参数（chunk_token_size、分隔符、重叠比例），无法预先判断哪些 region 会被分到同一个 chunk。所以 Parser 保持最小粒度（每个 bbox 独立裁剪），Splitter 负责分组和图片拼接。

### Tokenizer

- **full_text（关键词检索）**：不调外部 API，纯分词。对 title 分词产出 `title_tks`，对 content 分词产出 `content_ltks`（粗）和 `content_sm_ltks`（细），写入 ES 倒排索引
- **embedding（语义检索）**：调用外部 embedding 模型，将文本转为稠密向量 `q_*_vec`。title 向量与 content 向量加权合并：`title_w * tts + (1-title_w) * cnts`。维度取决于模型（BGE-M3 1024，ada-002 1536 等），无硬编码默认值
- 两种检索方式可独立启用或同时开，同时开时混合打分
- **三种输入格式都会进 embedding**：full_text 块先处理三种格式产出 `chunks`，embedding 块在之后统一遍历所有 chunk 调模型
- 分词两级粒度：`_tks` / `_ltks` 粗粒（jieba 词级 + NLTK 词形还原），`_sm_tks` 细粒（中文字级二元切分 + 英文 `/` 子词切分）。粗粒精准匹配，细粒模糊召回

### Extractor

Pipeline 组件中的异类——唯一同时继承 `ProcessBase` 和 `LLM` 的组件。MRO 为 `Extractor → ProcessBase → LLM → ComponentBase`，`super().__init__()` 链串起四个类的初始化。

输入机制走 `LLM.get_input_elements()`：扫描 prompt 模板中的 `{组件@字段}` 变量引用，解析后替换为实际值。不依赖上游的 output_format，不关心是 json 还是 chunks——只按名取值。

处理逻辑硬编码取 `ck["text"]`（`extractor.py:51`），结果写入 `ck[self._param.field_name]`。`field_name` 决定追加的属性名：

| field_name | chunk 新增字段 |
|------|------|
| `summary` | `ck["summary"]` |
| `keywords` | `ck["keywords"]` |
| `questions` | `ck["questions"]` |

原有 `text`、`image`、`positions` 不动，只在 chunk 上追加 LLM 生成的字段。

### HierarchicalMerger

本质是**章节合并器**——将 Splitter 按 token 盲切出的碎片按文档标题层级重组为完整章节单元。

1. 用正则 `levels`（如 `^#[^#]`、`^##[^#]`）匹配每行文本的层级
2. 构建树结构：父子关系由 **层级数值 + 出现顺序** 判定——`m == b["level"] + 1` 是子节点，`m == 0` 是新根级兄弟，沿 `children[-1]` 右侧深入找父节点，容忍跨级
3. 按 `hierarchy` 参数决定合并深度：`depth < hierarchy` 时 copy 新路径分叉，`depth == hierarchy` 时拍快照产出 chunk，`depth > hierarchy` 时合并进父级

上游限制为 `json` 或 `chunks`（`Literal["json", "chunks"]`），markdown 路径因 schema 约束不可达——结构化元素比字符串拆分行做层级判断更可靠。

产出：markdown 路径仅 `{"text": "..."}`；json 路径产出 `{"text", "image", "positions", "img_id"}`。注意 json 图片合并有个 bug：`concat_img` 返回值未捕获，导致 `image` 始终为 `None`。

### 图片在整个流水线中的流转

Parser 的 `parse_into_bboxes` 对每个版面 region（标题、正文、表格、图表）都调用 `crop()` 裁剪出图片，因此 json 输出中每个元素都同时有 `text` 和 `image`。图片不会在 Parser 阶段被丢弃——即使 OCR 提取了文字，原图仍保留，用于：

- 多模态 LLM 理解图表、公式、架构图等 OCR 无法准确抽取的内容
- 检索时 chunk 同时带有文本和配图，前端展示时不仅返回文字还包括图片
- 向量库存储 chunk 时图片以 `img_id` 引用形式保存

### Chunks 属性的流水线演进

Chunk 不是固定 schema，随着流水线推进不断追加字段：

| 阶段 | 新增字段 |
|------|------|
| Splitter | `text`, `image`, `positions`, `img_id` |
| Extractor | `summary` / `keywords` / `questions` |
| HierarchicalMerger | 同 Splitter 格式，合并后重新设置 |
| Tokenizer | `title_tks`, `title_sm_tks`, `content_ltks`, `content_sm_ltks`, `question_kwd`, `important_kwd`, `q_*_vec` |
| run_dataflow 清理 | 删除 `image`, `positions`, `questions`, `keywords` 等中间字段，设置 `content_with_weight` |

最终入库向量库的核心字段：`text`, `content_ltks`, `content_sm_ltks`, `title_tks`, `q_*_vec`, `img_id`, `doc_id`, `kb_id`, `positions`（`positions` 保留入库，用于检索结果按页码排序和高亮定位）。

---

## 6. 前端双 Canvas 架构

前端有两套独立的 canvas 页面：

| Canvas 类型 | 目录 | 用途 | 组件数量 |
|-------------|------|------|----------|
| Agent | `web/src/pages/agent/canvas/` | 对话式 AI 工作流 | 40+ |
| Dataflow | `web/src/pages/data-flow/canvas/` | 文档处理流水线 | 6 |

### 枚举定义（`web/src/constants/agent.ts`）

```typescript
enum DataflowOperator {
  Begin = 'File', Parser = 'Parser', Tokenizer = 'Tokenizer',
  Splitter = 'Splitter', HierarchicalMerger = 'HierarchicalMerger',
  Extractor = 'Extractor',
}

enum Operator {
  // 40+ Agent 组件 ...
  // + 6 个 Pipeline 组件（也包含在 Operator 中）
}
```

### 区分机制

- `canvas_category` 字段（`AgentCategory.DataflowCanvas` vs `AgentCategory.Agent`）存入数据库
- 创建时选类型 → 加载不同默认 DSL（`EmptyDsl` vs `DataflowEmptyDsl`）
- 打开时根据 `canvas_category` 路由到对应页面
- 各自独立的 `RestrictedUpstreamMap` 限制连线规则
- Dataflow 画布的 `SingleOperators` 标记某些组件只能有一个实例
