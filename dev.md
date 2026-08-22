**你现在不是从零重写 DeepSeek Harness，而是已经把最关键的 Cordis Runtime 用 Zig 0.17 做完了，下一步应该把 DeepSeek Harness 的“Agent 能力层”整体迁移到 zcordis 上。**

我核对了你现在的两个仓库：`zcordis` 已经实现了 Cordis 的 8 个核心概念，并且已经有 Native / C ABI / WASM 三种插件形态，以及一个 DeepSeek-Harness-style agent example；而 DeepSeek Harness 本身明确采用“Everything is a Plugin”，模型、工具、技能、会话、沙箱、存储、循环、调度、UI 都作为插件能力。([GitHub][1])

所以我建议 **不要做 `dsh -> Zig` 的机械翻译，而是做 `DeepSeek Harness Semantic Port -> zharness`**。

# 一、总体定位

建议最终形成：

```text
                         zharness
              Zig 0.17 Native Agent Harness
                         │
             ┌───────────┴───────────┐
             │                       │
          zcordis                 zharness
       Runtime Kernel            Agent Runtime
             │                       │
     ┌───────┼────────┐      ┌───────┼────────────┐
     │       │        │      │       │            │
 Context   Plugin   Event   Model   Tool        Session
 Scope     Service  Effect  Skill   Sandbox     Memory
 Dependency Lifecycle      Loop    Scheduler   Workflow
             │
       ┌─────┴──────┐
       │            │
   Zig Native    C/WASM
    Plugins      Plugins
```

核心原则：

> **zcordis = Agent Operating System Kernel**
> **zharness = Agent Runtime / Agent OS Userland**

而不是把所有东西继续塞进 Cordis。

DeepSeek 官方目前也是这个分层：Cordis Kernel 只负责插件加载、卸载和依赖关系，Agent 具体能力由插件提供。([深度求索][2])

---

# 二、建议的最终架构

我建议把 `zharness` 分成 **7 层**。

```text
┌──────────────────────────────────────────────┐
│                  zharness UI                 │
│ Web / TUI / CLI / API / WebSocket / SSE     │
├──────────────────────────────────────────────┤
│                Agent Presets                 │
│ Standard / PTC / Minimal / Creative         │
├──────────────────────────────────────────────┤
│               Agent Runtime                  │
│ Loop / Goal / Plan / SubAgent / Workflow    │
├──────────────────────────────────────────────┤
│              Capability Plugins              │
│ Model / Tool / Skill / Memory / Session      │
│ Sandbox / Search / Browser / Files / Shell  │
├──────────────────────────────────────────────┤
│               Protocol Layer                 │
│ OpenAI / Anthropic / DeepSeek / MCP / A2A   │
├──────────────────────────────────────────────┤
│                  zcordis                    │
│ Context / Scope / Plugin / Service / Event  │
│ Effect / Dependency / Lifecycle             │
├──────────────────────────────────────────────┤
│                  Zig 0.17                    │
│ allocator / async / io / net / fs / process│
└──────────────────────────────────────────────┘
```

其中最重要的是：

**不要把 Model、Tool、Skill、Memory 做成 zharness 核心类型。**

全部做成：

```text
Plugin
  ├── ModelPlugin
  ├── ToolPlugin
  ├── SkillPlugin
  ├── MemoryPlugin
  ├── SessionPlugin
  ├── SandboxPlugin
  ├── SchedulerPlugin
  └── UIPlugin
```

这样才真正继承 DeepSeek Harness 的设计思想。DeepSeek 官方仓库目前已经是一个规模很大的 monorepo，包含 `apps`、`native`、`packages`、`python`、`website` 等多个层次，因此直接逐文件翻译会把大量 JS/TS 生态包袱带进 Zig。([GitHub][3])

---

# 三、zcordis 与 zharness 的边界

这是整个项目最重要的设计。

## zcordis

只负责：

```text
Context
Scope
Plugin
Service
Event
Effect
Dependency
Lifecycle
```

也就是：

```text
Runtime Kernel
```

你现在的 zcordis 已经基本达到这个定位，而且 README 明确说明这 8 个核心子系统以及 Native/C ABI/WASM plugin phase 已经实现。([GitHub][1])

## zharness

负责：

```text
Agent
Conversation
Model
Tool
Skill
Memory
Goal
Plan
Loop
SubAgent
Workflow
Sandbox
Session
Scheduler
UI
```

也就是说：

```text
zcordis
    ↓
提供运行时
    ↓
zharness
    ↓
提供 Agent
```

---

# 四、核心 Agent Model

建议不要把 Agent 设计成一个巨大 struct。

而是：

```zig
pub const Agent = struct {
    id: AgentId,
    scope: cordis.Scope,
    config: AgentConfig,
    state: AgentState,
};
```

Agent 本身只负责：

```text
Identity
State
Scope
Configuration
```

真正执行由插件完成。

---

# 五、Agent Loop

这是 DeepSeek Harness -> zharness 的核心。

建议定义：

```text
Input
  ↓
Context Assembly
  ↓
Model Inference
  ↓
Response Classification
  ↓
Tool Call?
 ┌───────┴───────┐
 No              Yes
 │                │
Final          Tool Executor
 │                │
 │            Tool Result
 │                │
 └───────←────────┘
```

进一步：

```text
AgentLoop
│
├── before_turn
├── build_context
├── model_request
├── model_response
├── parse_actions
├── execute_tools
├── observe
├── update_memory
├── check_goal
├── check_stop
└── next_iteration
```

在 zcordis 中全部事件化：

```zig
ctx.emit(.agent_turn_start, ...)
ctx.emit(.model_request, ...)
ctx.emit(.model_response, ...)
ctx.emit(.tool_call, ...)
ctx.emit(.tool_result, ...)
ctx.emit(.agent_turn_end, ...)
```

这样 Agent Loop 不需要知道具体 Tool。

---

# 六、Model Plugin

第一批至少实现：

```text
DeepSeek
OpenAI-compatible
Anthropic
Ollama
OpenAI
```

统一抽象：

```zig
pub const Model = struct {
    id: []const u8,
    capabilities: ModelCapabilities,

    pub fn complete(
        self: *Model,
        request: *const ModelRequest,
        writer: *ResponseWriter,
    ) !void;
};
```

请求：

```zig
pub const ModelRequest = struct {
    messages: []Message,
    tools: []ToolDefinition,
    system: ?[]const u8,
    temperature: ?f32,
    max_tokens: ?u32,
    stream: bool,
};
```

响应：

```zig
pub const ModelResponse = struct {
    id: []const u8,
    content: []ContentBlock,
    finish_reason: FinishReason,
    usage: Usage,
};
```

特别建议：

**不要把 OpenAI API schema 当作内部 schema。**

内部使用：

```text
zharness Model IR
```

然后：

```text
zharness Model IR
        ↓
OpenAI Adapter
DeepSeek Adapter
Anthropic Adapter
Ollama Adapter
```

这样以后模型协议变化，不会污染 Agent Runtime。

---

# 七、Tool 系统

Tool 是 zharness 最重要的插件之一。

建议：

```zig
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    schema: JsonSchema,

    execute: *const fn (
        ctx: *ToolContext,
        args: JsonValue,
    ) anyerror!ToolResult,
};
```

内置：

```text
filesystem
shell
grep
glob
read_file
write_file
edit_file
web_search
web_fetch
browser
git
python
```

但这些都不是 Agent Core。

例如：

```text
tool.fs
tool.shell
tool.git
tool.web
```

全部 Plugin。

---

# 八、Tool 调用必须事件化

不要：

```text
Agent → Tool.execute()
```

而应该：

```text
Agent
  ↓
ToolCall Event
  ↓
Tool Registry
  ↓
Permission
  ↓
Sandbox
  ↓
Tool
  ↓
ToolResult Event
  ↓
Agent
```

这样才能实现：

```text
权限
审计
取消
重试
超时
并发
沙箱
成本统计
Tracing
```

---

# 九、Shell / Coding Agent 是第一优先级

如果目标是复刻 DeepSeek Harness，我建议**第一阶段不要做 Web UI**。

先实现：

```text
zharness
  └── coding agent
       ├── read
       ├── write
       ├── edit
       ├── grep
       ├── glob
       ├── shell
       ├── git
       └── model
```

做到：

```bash
zharness run "分析这个项目并修复 bug"
```

能够：

```text
读取项目
   ↓
理解
   ↓
制定计划
   ↓
修改文件
   ↓
运行测试
   ↓
发现错误
   ↓
继续修改
   ↓
最终报告
```

这个闭环跑通，zharness 才算真正成立。

---

# 十、Filesystem Tool

Coding Agent 最基础的是：

```text
read_file
write_file
edit_file
list_dir
glob
grep
```

其中 `edit_file` 不建议直接复制 JS 版的字符串替换实现。

可以做：

```text
EditOperation
├── Replace
├── Insert
├── Delete
├── Patch
└── ApplyUnifiedDiff
```

最终统一：

```zig
pub const FileEdit = union(enum) {
    replace: ReplaceEdit,
    insert: InsertEdit,
    delete: DeleteEdit,
    patch: PatchEdit,
};
```

这会比简单的：

```text
str_replace(old, new)
```

更加适合生产级 Coding Agent。

---

# 十一、Shell Sandbox

这是 Zig 版本最值得增强的部分。

建议：

```text
Shell
 │
 ├── Command Parser
 │
 ├── Permission
 │
 ├── Resource Limit
 │
 ├── Working Directory
 │
 ├── Environment Policy
 │
 ├── Timeout
 │
 ├── stdout/stderr streaming
 │
 └── Process Supervisor
```

执行模型：

```text
Tool
 ↓
Sandbox
 ↓
Process
 ↓
stdout/stderr
 ↓
ToolResult
```

不要让模型直接拿到宿主 OS 的：

```text
fork/exec
filesystem
network
environment
```

---

# 十二、Sandbox 分三级

我建议 zharness 做：

### Level 0

```text
Native trusted
```

用于本机开发。

### Level 1

```text
Process sandbox
```

限制：

```text
cwd
env
timeout
memory
CPU
network
filesystem
```

### Level 2

```text
WASM sandbox
```

直接利用你 zcordis 已经完成的 WASM runtime。

这会成为你的一个巨大优势：

```text
zharness
      │
      ├── trusted native plugin
      │
      ├── process plugin
      │
      └── WASM plugin
```

而 zcordis 当前已经有 WASM interpreter，并且设计上要求 malformed input 返回 error 而不是 crash，同时有 execution-step budget 和 fuzz harness。([GitHub][1])

---

# 十三、Skill 系统

DeepSeek Harness 的一个重要能力是 Skill。

zharness 建议：

```text
skills/
├── coding/
├── debugging/
├── git/
├── testing/
├── security/
├── research/
└── custom/
```

每个 Skill：

```text
SKILL.md
manifest.json
resources/
scripts/
```

Plugin：

```text
SkillPlugin
```

运行时：

```text
Agent
 ↓
Skill Registry
 ↓
Skill Resolver
 ↓
Skill
 ↓
Prompt / Tools / Instructions
```

---

# 十四、Memory

不要一开始做复杂向量数据库。

先做：

```text
Memory
├── Session Memory
├── Working Memory
├── Persistent Memory
└── Artifact Memory
```

其中：

```text
Working Memory
```

保存：

```text
当前任务
当前计划
当前状态
工具结果
临时变量
```

Persistent Memory：

```text
~/.zharness/memory/
```

可以使用：

```text
SQLite
```

第一版足够。

后面再扩展：

```text
PostgreSQL
PGlite
Vector DB
```

---

# 十五、Session

Session 是：

```text
Agent
+
Conversation
+
State
+
Memory
+
Artifacts
```

建议：

```zig
pub const Session = struct {
    id: SessionId,
    agent_id: AgentId,
    messages: MessageStore,
    state: SessionState,
    metadata: Metadata,
};
```

存储：

```text
SQLite
```

结构：

```text
sessions
messages
tool_calls
tool_results
artifacts
events
checkpoints
```

---

# 十六、Checkpoint

这是我建议你在 zharness 中**比 DeepSeek Harness 更进一步**的地方。

Agent Loop 每次重要状态变化：

```text
checkpoint
```

例如：

```text
Turn 1
 ↓
checkpoint
 ↓
Tool
 ↓
checkpoint
 ↓
Turn 2
 ↓
checkpoint
```

这样可以：

```text
resume
rollback
replay
fork
debug
```

最终形成：

```text
Session
   │
   ├── checkpoint 001
   ├── checkpoint 002
   ├── checkpoint 003
   │
   └── fork
         ├── branch A
         └── branch B
```

这非常适合你的 Agent Mesh / 创意变现研究方向。

---

# 十七、Plan / Goal

建议分成三个层次。

```text
Goal
 ↓
Plan
 ↓
Task
```

例如：

```text
Goal:
重写 Cordis

Plan:
1. 分析 TS API
2. 实现 Runtime
3. 实现 Plugin
4. 实现测试

Task:
read package/plugin.ts
```

Agent 可以动态修改 Plan。

因此：

```zig
GoalPlugin
PlanPlugin
TaskPlugin
```

---

# 十八、SubAgent

zharness 应该原生支持：

```text
Agent
 │
 ├── Agent A
 ├── Agent B
 └── Agent C
```

每个 SubAgent：

```text
独立 Scope
独立 Session
共享部分 Services
独立 Memory
```

例如：

```text
Main Agent
│
├── Research Agent
├── Coding Agent
├── Test Agent
└── Review Agent
```

zcordis Scope 非常适合承载这种生命周期。

---

# 十九、Workflow

再往上一层：

```text
Agent
 ↓
Workflow
```

定义：

```text
workflow.yaml
```

例如：

```text
research
   ↓
architecture
   ↓
implementation
   ↓
test
   ↓
review
   ↓
merge
```

以后可以进一步形成：

```text
Agent DAG
```

而不是单一 Agent Loop。

---

# 二十、MCP

建议 MCP 不要成为核心 Tool。

做：

```text
MCP Client Plugin
```

结构：

```text
zharness
  │
  ├── Native Tool
  ├── WASM Tool
  └── MCP Tool
```

统一进入：

```text
ToolRegistry
```

因此 Agent 不知道 Tool 来自哪里。

---

# 二十一、协议层

建议建立：

```text
zharness/protocol/
```

```text
protocol/
├── openai.zig
├── anthropic.zig
├── deepseek.zig
├── mcp.zig
├── sse.zig
├── websocket.zig
└── jsonrpc.zig
```

内部统一：

```text
Agent IR
```

外部：

```text
OpenAI
Anthropic
DeepSeek
MCP
```

---

# 二十二、UI 不要用 Zig 做

这是一个非常明确的建议：

**不要尝试用 Zig 重写 DeepSeek Harness 的 Web UI。**

正确架构：

```text
              Browser
                 │
              React/
              Svelte
                 │
          WebSocket / SSE
                 │
              zharness
                 │
              zcordis
```

甚至：

```text
zharness
   ↓
HTTP API
   ↓
Next.js / SvelteKit
```

这样可以保持：

```text
Native Agent Runtime
+
Modern Web UI
```

---

# 二十三、CLI

CLI 应该是第一入口：

```bash
zharness
```

命令：

```bash
zharness run
zharness chat
zharness agent
zharness session
zharness plugin
zharness skill
zharness tool
zharness model
zharness workflow
zharness serve
```

例如：

```bash
zharness chat
```

```bash
zharness run "分析当前项目"
```

```bash
zharness agent create coder
```

```bash
zharness plugin install git
```

```bash
zharness serve --port 3080
```

---

# 二十四、推荐目录结构

最终建议：

```text
zharness/
│
├── build.zig
├── build.zig.zon
│
├── src/
│   │
│   ├── main.zig
│   │
│   ├── harness.zig
│   │
│   ├── agent/
│   │   ├── agent.zig
│   │   ├── loop.zig
│   │   ├── state.zig
│   │   ├── goal.zig
│   │   ├── plan.zig
│   │   └── subagent.zig
│   │
│   ├── model/
│   │   ├── model.zig
│   │   ├── request.zig
│   │   ├── response.zig
│   │   ├── deepseek.zig
│   │   ├── openai.zig
│   │   ├── anthropic.zig
│   │   └── ollama.zig
│   │
│   ├── tool/
│   │   ├── tool.zig
│   │   ├── registry.zig
│   │   ├── filesystem.zig
│   │   ├── shell.zig
│   │   ├── git.zig
│   │   ├── search.zig
│   │   └── browser.zig
│   │
│   ├── skill/
│   │   ├── skill.zig
│   │   ├── loader.zig
│   │   └── registry.zig
│   │
│   ├── memory/
│   │   ├── memory.zig
│   │   ├── working.zig
│   │   ├── persistent.zig
│   │   └── sqlite.zig
│   │
│   ├── session/
│   │   ├── session.zig
│   │   ├── message.zig
│   │   ├── checkpoint.zig
│   │   └── artifact.zig
│   │
│   ├── sandbox/
│   │   ├── sandbox.zig
│   │   ├── process.zig
│   │   ├── wasm.zig
│   │   └── policy.zig
│   │
│   ├── protocol/
│   │   ├── openai.zig
│   │   ├── anthropic.zig
│   │   ├── deepseek.zig
│   │   ├── mcp.zig
│   │   └── jsonrpc.zig
│   │
│   ├── workflow/
│   │   ├── workflow.zig
│   │   ├── executor.zig
│   │   └── dag.zig
│   │
│   ├── scheduler/
│   │   ├── scheduler.zig
│   │   └── queue.zig
│   │
│   └── plugins/
│       ├── builtin.zig
│       ├── model.zig
│       ├── tools.zig
│       ├── memory.zig
│       └── coding.zig
│
├── plugins/
│   ├── model-deepseek/
│   ├── tool-shell/
│   ├── tool-filesystem/
│   ├── tool-git/
│   ├── skill-coding/
│   └── mcp-client/
│
├── tests/
│
├── examples/
│   ├── basic.zig
│   ├── coding_agent.zig
│   ├── subagent.zig
│   └── workflow.zig
│
└── docs/
    ├── architecture.md
    ├── plugin.md
    ├── agent.md
    ├── model.md
    ├── tools.md
    ├── sandbox.md
    └── workflow.md
```

---

# 二十五、Plugin ABI

这是 zharness 最值得认真设计的地方。

建议：

```text
zcordis ABI
      ↓
zharness Plugin ABI
```

定义：

```c
zh_plugin_init()
zh_plugin_manifest()
zh_plugin_start()
zh_plugin_stop()
zh_plugin_deinit()
```

Manifest：

```json
{
  "name": "tool.shell",
  "version": "0.1.0",
  "kind": "tool",
  "dependencies": [
    "cordis",
    "zharness"
  ]
}
```

这样：

```text
Zig
Rust
C
C++
Go
WASM
```

都可以写 Plugin。

---

# 二十六、Plugin 生命周期

统一：

```text
Discover
   ↓
Load
   ↓
Resolve Dependencies
   ↓
Create Scope
   ↓
Register Services
   ↓
Register Events
   ↓
Start
   ↓
Running
   ↓
Stop
   ↓
Destroy Scope
   ↓
Unload
```

这直接复用 zcordis 的生命周期系统，而不是再造一套。

---

# 二十七、配置系统

建议：

```text
~/.zharness/
├── config.toml
├── agents/
├── models/
├── plugins/
├── skills/
├── sessions/
├── memory/
├── cache/
└── logs/
```

配置：

```toml
[model]
provider = "deepseek"
model = "deepseek-chat"

[agent]
preset = "coding"

[sandbox]
mode = "process"

[workspace]
root = "."
```

---

# 二十八、Preset

直接复刻 DeepSeek Harness 的理念，但做成 Zig-native：

```text
presets/
├── standard
├── ptc
├── minimal
└── creative
```

其中：

### Standard

```text
Model
Tool
Skill
Memory
Planning
Goal
```

### Minimal

```text
Model
bash
editor
```

### PTC

```text
Model
Code Mode
Tool SDK
```

### Creative

```text
完整 Agent
+
Plugin Inspector
+
Runtime Debugger
```

DeepSeek 官方目前也明确提供 Standard、PTC、Minimal、Creative 等不同模式，因此这个抽象值得直接保留。([深度求索][2])

---

# 二十九、PTC 是值得重点重构的

我反而建议：

**不要简单复制 DeepSeek PTC。**

做成：

```text
Model
 ↓
Code Mode
 ↓
zharness SDK
 ↓
multiple tool calls
 ↓
runtime
```

即：

```text
传统：

LLM
 ↓
tool_call
 ↓
tool
 ↓
LLM
 ↓
tool_call
```

PTC：

```text
LLM
 ↓
生成程序
 ↓
zharness Tool SDK
 ↓
一次执行多个操作
 ↓
结果
 ↓
LLM
```

对于 Zig runtime，这会非常漂亮。

---

# 三十、Observability

生产级必须从第一天设计。

事件：

```text
agent.started
agent.stopped

model.request
model.chunk
model.response

tool.started
tool.stdout
tool.stderr
tool.completed
tool.failed

session.created
session.resumed

plugin.loaded
plugin.unloaded

sandbox.started
sandbox.killed
```

统一：

```text
Event
{
    timestamp,
    trace_id,
    span_id,
    session_id,
    agent_id,
    plugin_id,
    event_type,
    payload
}
```

之后可以接：

```text
OpenTelemetry
Prometheus
Jaeger
Loki
```

---

# 三十一、Cancellation

Agent Runtime 必须支持：

```text
Cancel
Timeout
Pause
Resume
Retry
Abort
```

例如：

```text
Agent
 ↓
Task
 ↓
Effect
 ↓
CancellationToken
```

这里正好利用 zcordis 的 Effect / Scheduler / Task / scope-bound cancellation 能力；zcordis 的现有文档已经把 Effect/Scheduler/Task 和 scope cancellation 作为独立能力。([GitHub][1])

---

# 三十二、并发模型

不要：

```text
一个 Agent = 一个 OS Thread
```

而采用：

```text
Agent
 ↓
Scope
 ↓
Effect
 ↓
Scheduler
 ↓
Async I/O
```

并发：

```text
Agent
 ├── Tool A
 ├── Tool B
 ├── Tool C
 └── SubAgent
```

例如搜索：

```text
search github
search web
search local
```

可以并行。

最终：

```text
join
 ↓
Model
```

---

# 三十三、核心事件模型

我建议定义一个统一的：

```zig
pub const HarnessEvent = union(enum) {
    agent_start: AgentStart,
    agent_stop: AgentStop,

    turn_start: TurnStart,
    turn_end: TurnEnd,

    model_request: ModelRequest,
    model_delta: ModelDelta,
    model_response: ModelResponse,

    tool_call: ToolCall,
    tool_result: ToolResult,

    plan_created: PlanCreated,
    plan_updated: PlanUpdated,

    task_start: TaskStart,
    task_end: TaskEnd,

    checkpoint: Checkpoint,

    error: HarnessError,
};
```

然后全部进入 zcordis Event。

这会让整个 zharness 非常“Cordis”。

---

# 三十四、最关键的状态机

Agent 不应该靠一堆 boolean。

建议：

```zig
pub const AgentState = enum {
    idle,
    preparing,
    thinking,
    awaiting_tool,
    executing_tool,
    observing,
    planning,
    waiting,
    completed,
    failed,
    cancelled,
};
```

状态转换：

```text
idle
 ↓
preparing
 ↓
thinking
 ↓
awaiting_tool
 ↓
executing_tool
 ↓
observing
 ↓
thinking
```

或者：

```text
thinking
 ↓
planning
 ↓
executing_tool
 ↓
observing
 ↓
completed
```

---

# 三十五、迁移策略

我不建议：

```text
DeepSeek Harness TS
       ↓
逐文件
       ↓
Zig
```

应该：

```text
DeepSeek Harness
       ↓
Architecture extraction
       ↓
Semantic specification
       ↓
zcordis mapping
       ↓
Zig implementation
```

也就是：

### Phase 1

提取：

```text
API
Events
Plugin
Services
Agent Loop
Model
Tool
Skill
Session
Sandbox
```

### Phase 2

建立：

```text
zharness-spec
```

### Phase 3

用 zcordis 实现。

---

# 三十六、推荐开发顺序

我建议严格按这个顺序。

```text
Phase 0
zcordis compatibility
        ↓
Phase 1
Agent Core
        ↓
Phase 2
Model
        ↓
Phase 3
Tool
        ↓
Phase 4
Coding Agent
        ↓
Phase 5
Session / Memory
        ↓
Phase 6
Sandbox
        ↓
Phase 7
Skill
        ↓
Phase 8
SubAgent
        ↓
Phase 9
Workflow
        ↓
Phase 10
MCP
        ↓
Phase 11
HTTP / WebSocket
        ↓
Phase 12
Web UI
```

---

# 三十七、MVP-1

第一阶段不要超过：

```text
zcordis
+
Agent
+
DeepSeek Model
+
filesystem
+
shell
+
session
```

最终：

```bash
zharness run "修复当前项目中的测试错误"
```

实现：

```text
Prompt
 ↓
DeepSeek
 ↓
read
 ↓
edit
 ↓
shell
 ↓
test
 ↓
error
 ↓
edit
 ↓
test
 ↓
done
```

**这一阶段跑通，就已经是一个真正可用的 Coding Agent。**

---

# 三十八、MVP-2

加入：

```text
Git
Search
Skill
Memory
Plan
Checkpoint
```

形成：

```text
Coding Agent
+
Persistent Session
+
Long-running Task
```

---

# 三十九、MVP-3

加入：

```text
SubAgent
Workflow
MCP
WASM Plugins
```

这时开始超过传统 DeepSeek Harness。

---

# 四十、Production 版本

最终：

```text
                    zharness
                       │
       ┌───────────────┼────────────────┐
       │               │                │
     Agent          Workflow          PTC
       │               │                │
       └───────────────┼────────────────┘
                       │
                 Plugin Runtime
                       │
                     zcordis
                       │
      ┌────────────────┼─────────────────┐
      │                │                 │
   Native             C ABI             WASM
      │                │                 │
     Zig          Rust/C/C++          Sandbox
```

---

# 四十一、我认为这个项目真正的价值

这个项目如果只是：

> **“DeepSeek Harness 用 Zig 重写一遍”**

价值其实有限。

真正应该把它定义成：

> **zharness = Native Agent Runtime for Composable Intelligence**

也就是：

```text
Cordis
    ↓
Composable Runtime

zharness
    ↓
Composable Agent Runtime

Agent
    ↓
Composable Intelligence
```

这样你后面可以自然扩展：

```text
zharness
├── Coding Agent
├── Research Agent
├── Trading Agent
├── Crypto Agent
├── RWA Agent
├── DAO Agent
├── Creative Agent
└── Life Agent
```

而这些 Agent **不需要修改 Kernel**。

只需要：

```text
Plugin
+
Preset
+
Skill
+
Workflow
```

这才是 zcordis + zharness 组合最大的战略价值。

---

## 四十二、我建议最终形成三层产品

```text
┌─────────────────────────────────────┐
│          zharness ecosystem         │
│ Agent / Skill / Workflow / Plugin   │
└─────────────────────────────────────┘
                    │
┌─────────────────────────────────────┐
│             zharness                │
│      Native Agent Operating System  │
└─────────────────────────────────────┘
                    │
┌─────────────────────────────────────┐
│              zcordis                │
│       Composable Runtime Kernel     │
└─────────────────────────────────────┘
                    │
┌─────────────────────────────────────┐
│              Zig 0.17               │
└─────────────────────────────────────┘
```

**其中 zcordis 已经基本把最难的 Kernel 打通了。** 目前仓库甚至已经存在 `examples/harness.zig` 和 `docs/harness-example.md`，说明它已经具备承接 zharness 的雏形，而不是一个纯粹的 Cordis 底层库。([GitHub][1])

因此下一步我会把重点放在 **“DeepSeek Harness → zharness 的模块级映射表 + API/ABI 定义”**，而不是继续改 zcordis。具体就是把 DeepSeek Harness 现有 `packages / apps / native / python` 中哪些模块保留语义、哪些重新设计、哪些彻底删除 Node/TS 依赖，逐一映射成 `src/agent / model / tool / skill / session / sandbox / workflow`，然后直接进入 Zig 0.17 编码阶段。([GitHub][3])

[zcordis 源码](https://github.com/chy3xyz/zcordis?utm_source=chatgpt.com)
[DeepSeek Harness 源码](https://github.com/deepseek-ai/deepseek-harness?utm_source=chatgpt.com)

[1]: https://github.com/chy3xyz/zcordis "GitHub - chy3xyz/zcordis: a zig cordis meta framework · GitHub"
[2]: https://www.deepseek.com/harness/?utm_source=chatgpt.com "DeepSeek Harness 开发者预览版：一切皆插件"
[3]: https://github.com/deepseek-ai/deepseek-harness "GitHub - deepseek-ai/deepseek-harness: DeepSeek Harness: Everything is a Plugin. · GitHub"
