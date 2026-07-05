# Pipeline 代码节点方案

## 需求背景

当前 Pipeline 节点（File / Parser / Splitter / Tokenizer 等）提供了标准化的文档处理能力，但用户在处理异构文档、特殊格式、自定义后处理等场景时，仍需要注入定制化逻辑。Agent 流程中已有 `CodeExec` 节点，允许用户编写 Python/JavaScript 脚本在沙箱中执行。本方案将其能力移植到 Dataflow / Pipeline 体系。

---

## 现状：Agent 中的 Executor（CodeExec）

Agent 侧已有可参考的代码节点实现：

| 层面 | 位置 | 说明 |
|------|------|------|
| 后端执行 | `agent/tools/code_exec.py` | `CodeExec(ToolBase)`，继承 Agent 工具体系 |
| 前端表单 | `web/src/pages/agent/form/code-form/` | Monaco 编辑器 + 语言选择 + 变量绑定 |
| 注册 | `agent/tools/__init__.py` 自动扫描 | 自动注入 `agent.tools` 命名空间 |
| 枚举 | `web/src/constants/agent.ts` | `Operator.Code = 'CodeExec'` |
| 沙箱 | Docker 容器（gVisor + seccomp） | `sandbox-executor-manager:9385` |

关键差异：Agent Tool 通过变量引用（`{上游@输出}`）获取输入，在 Agent Canvas 的 DAG 中作为工具节点插入。Pipeline 组件通过 Pydantic schema 接收上游 output，在 Dataflow Canvas 的 DAG 中作为流水线节点运行。

---

## 方案设计

### 1. 整体架构

```
前端（Dataflow Canvas）
  └── ExecutorForm（基于 Agent 版 CodeForm 调整）
       └── Monaco 编辑器 + 输入/输出配置

DSL
  └── component_name: "Executor"
       params: { lang, script, inputs_mapping, outputs }

后端
  └── rag/flow/executor/executor.py
       ├── ExecutorParam(ProcessParamBase)   ← 参数定义
       └── Executor(ProcessBase)              ← 执行逻辑
            ↓  POST {SANDBOX_HOST}:9385/run
            ↓  复用 agent/tools/code_exec.py 中的沙箱调用逻辑
```

### 2. 后端实现

#### 2.1 文件结构

```
rag/flow/executor/
  ├── __init__.py
  ├── executor.py          # Executor + ExecutorParam
  └── schema.py        # ExecutorFromUpstream（Pydantic 契约）
```

`rag/flow/__init__.py` 的自动扫描会将其注册到 `rag.flow` 命名空间，`component_class("Executor")` 可用。

#### 2.2 ExecutorParam

```python
class ExecutorParam(ProcessParamBase):
    def __init__(self):
        super().__init__()
        self.lang = "python"         # "python" | "javascript"
        self.script = ""             # 用户编写的代码
        self.inputs = {}             # { var_name: type }
        self.outputs = {}            # { var_name: type }
```

校验逻辑：检查 `lang` 为合法值，`script` 非空。

#### 2.3 Executor._invoke()

```
1. from_upstream = ExecutorFromUpstream.model_validate(kwargs)
    → 拿上游的 chunks / json / text 等

2. 沙箱执行（复用 agent/tools/code_exec.py 的 _execute_code 逻辑）：
   - 提取 inputs 参数（从上游 chunks 取值）
   - Base64 编码 script
   - POST http://{SANDBOX_HOST}:9385/run
   - 解析返回 stdout → 映射到 outputs

3. 输出：
   - 如果上游是 chunks：对每个 chunk 执行代码，结果追加为 chunk 新字段
   - 如果上游是文本/markdown：对整个文本执行一次
```

#### 2.4 schema.py（ExecutorFromUpstream）

```python
class ExecutorFromUpstream(BaseModel):
    name: str
    output_format: Literal["json", "chunks", "markdown", "text", "html"]
    chunks: list[dict] | None = None
    json_result: list[dict] | None = Field(None, alias="json")
    markdown_result: str | None = Field(None, alias="markdown")
    text_result: str | None = Field(None, alias="text")
    html_result: str | None = Field(None, alias="html")
```

不同 output_format 取不同字段，保持与 Splitter/Tokenizer 一致的契约模式。

#### 2.5 执行模式

与 Agent 版的关键差异：Agent 只执行一次脚本，Pipeline 需要处理**批量 chunk**：

```
模式 A：逐 chunk 执行（默认，上游是 chunks）
  for ck in chunks:
      result = sandbox_run(script, ck["text"])
      ck[output_field] = result

模式 B：整文本执行（上游是 markdown/text/html）
  result = sandbox_run(script, payload)
  self.set_output("chunks", [{"text": result}])
```

模式 A 中，脚本签名为：

```python
def main(text: str) -> str:
    # 用户对每个 chunk 文本进行处理
    return processed_text
```

### 3. 前端实现

#### 3.1 文件结构（新增）

```
web/src/pages/data-flow/
  canvas/node/executor-node.tsx       # 可选，如渲染样式需特殊处理
  form/executor-form/index.tsx         # 代码编辑表单（参考 Agent 版）
  form/executor-form/schema.ts
  form/executor-form/use-values.ts
```

#### 3.2 注册

`web/src/constants/agent.ts`：
```typescript
enum DataflowOperator {
  // ...existing...
  Executor = 'Executor',     // 新增
}
```

`web/src/pages/data-flow/constant.tsx`：
```typescript
// RestrictedUpstreamMap
[Operator.Executor]: [Operator.Begin],  // 不能跟在 File 后面

// NodeMap
[Operator.Executor]: 'ragNode',

// initialExecutorValues
export const initialExecutorValues = {
  ...initialLlmBaseValues,
  lang: 'python',
  script: CodeTemplateStrMap['python'],
  inputs: {},
  outputs: {},
};
```

#### 3.3 表单设计

表单结构（参考 Agent 版 ExecutorForm）：

| 区域 | 说明 |
|------|------|
| 语言选择 | Python / JavaScript 下拉 |
| 代码编辑 | Monaco Editor |
| 输入绑定 | 从上游 chunk 取值的字段映射 |
| 输出字段名 | 结果写入 chunk 的哪个 key（如 "custom_field"） |

注：Agent 版中 Code 放在 `agent/tools/` 因此走 `@token_required` + API Key 鉴权，Dataflow 版走 `@login_required` + session。但两者实际执行都在沙箱中，与鉴权无关。

### 4. 沙箱复用

直接复用现有沙箱基础设施，无需改动：

```
Executor._invoke()
  → base64(script)
  → POST http://{SANDBOX_HOST}:9385/run
    {
      "code_b64": "...",
      "language": "python" | "nodejs",
      "arguments": { "text": "...", ... }
    }
  → { "stdout": "...", "stderr": "..." }
```

复用 `agent/tools/code_exec.py` 中的 `CodeExecutionRequest` Pydantic 模型和序列化逻辑。提取为公共工具函数放置在 `rag/utils/sandbox_conn.py` 可避免代码重复。

### 5. DSL 示例

```json
{
  "components": {
    "Executor:BlueFishSwim": {
      "obj": {
        "component_name": "Executor",
        "params": {
          "lang": "python",
          "script": "def main(text: str) -> str:\n    return text.upper()",
          "inputs": { "text": "string" },
          "outputs": { "result": "string" }
        }
      },
      "downstream": ["Tokenizer:RedDogBark"],
      "upstream": ["Splitter:GreenCatRun"]
    }
  }
}
```

### 6. 执行流程

```
Splitter 产出 chunks
  → Executor._invoke(kwargs)
    → ExecutorFromUpstream.model_validate(kwargs)
    → 根据 output_format 取上游数据
    → 对每个 chunk：
        arguments = { k: chunk[k] for k in inputs }
        result = sandbox.run(script, lang, arguments)
        chunk[output_field] = result
    → set_output("chunks", chunks)
    → Tokenizer 继续处理
```

### 7. 改动清单

| 层面 | 文件 | 动作 |
|------|------|------|
| 后端 | `rag/flow/executor/__init__.py` | 新建 |
| 后端 | `rag/flow/executor/executor.py` | 新建，Executor + ExecutorParam |
| 后端 | `rag/flow/executor/schema.py` | 新建，ExecutorFromUpstream |
| 后端 | `rag/utils/sandbox_conn.py` | 新建（或直接复用 agent/tools/code_exec.py 的工具函数），提取公共沙箱调用 |
| 前端 | `web/src/constants/agent.ts` | DataflowOperator 添加 `Executor = 'Executor'` |
| 前端 | `web/src/pages/data-flow/constant.tsx` | 添加 initialExecutorValues、NodeMap、RestrictedUpstreamMap 条目 |
| 前端 | `web/src/pages/data-flow/form/executor-form/` | 新建代码编辑表单（可大量复用 Agent 版 CodeForm） |
| 前端 | `web/src/pages/data-flow/form-sheet/form-config-map.tsx` | 注册 ExecutorForm |
| 沙箱 | 无 | 无需改动 |
