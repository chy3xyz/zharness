# zharness

**Native Agent Runtime for Composable Intelligence**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig 0.17](https://img.shields.io/badge/Zig-0.17-orange.svg)](https://ziglang.org/)
[![Tests](https://img.shields.io/badge/Tests-431%20passing-brightgreen.svg)](#testing)
[![CI](https://github.com/chy3xyz/zharness/actions/workflows/ci.yml/badge.svg)](https://github.com/chy3xyz/zharness/actions/workflows/ci.yml)

---

`zharness` is a high-performance, native coding agent harness written in **Zig 0.17**. Built on the [zcordis](https://github.com/chy3xyz/zcordis) runtime kernel, it drives LLMs through an agent loop with filesystem, shell, and git tools — following the "Everything is a Plugin" philosophy of the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).

```bash
# Quick example
zh run "analyze this repo and fix the build"
```

## Features

### 🤖 Agent Capabilities
- **Multi-turn agent loop** with streaming responses
- **Tool calling** — filesystem, shell, git, search, web fetch, MCP
- **Persistent sessions** — resume conversations across runs
- **Skill system** — load specialized instructions dynamically
- **Memory system** — working memory + persistent key-value store
- **Plan & Goal tracking** — structured task management
- **SubAgent support** — spawn isolated child agents
- **Workflow execution** — multi-step DAG-based runs

### 🔌 Plugin Architecture
- **Native Zig plugins** (dylib)
- **C ABI v1** — plugins in Rust, C, C++, Go
- **WASM plugins** — sandboxed execution via zcordis
- **MCP integration** — Model Context Protocol stdio servers

### 🛡️ Security & Sandboxing
- **`native`** — OS-level confinement (macOS Seatbelt / Linux bubblewrap) with the deny-list pre-filter; writes are limited to the workspace and temp
- **`process`** — deny-list + env allowlist + watchdog (defense in depth, not a kernel boundary)
- **`none`** — no shell sandbox (trusted / danger mode)
- **WASM plugin sandbox** — via the zcordis runtime

### 🌐 Server & Web UI
- **HTTP API** — RESTful endpoints for sessions, prompts, health
- **WebSocket/SSE** — real-time streaming events
- **Web GUI** — vendored DeepSeek Harness React client
- **Legacy JSON API** — backward-compatible `/run`, `/sessions`, `/healthz`

### 🧩 Model Support
- **DeepSeek** (default)
- **OpenAI / OpenAI-compatible**
- **Anthropic**
- **Ollama** (local models)
- Custom providers via configuration

## Quick Start

### Prerequisites

- **Zig 0.17.0** (stable) — install via [zigup](https://github.com/marler8997/zigup)
- **curl** on PATH (for HTTPS requests)
- A **zcordis** checkout at `../zcordis`:

```bash
git clone https://github.com/chy3xyz/zcordis.git ../zcordis
```

### Build & Install

```bash
git clone https://github.com/chy3xyz/zharness.git zharness
cd zharness
zig build                    # builds ./zig-out/bin/zh
```

### Set API Key

```bash
export ZHARNESS_API_KEY="sk-..."     # or DEEPSEEK_API_KEY
```

### Run Your First Task

```bash
./zig-out/bin/zh run "list the files in this repo and summarize what it does"
```

## Usage

### `run` — Single Task

Execute one agent task and exit. The final answer is printed to stdout.

```bash
# Basic task
zh run "analyze this repo and fix the build"

# Override model / provider
zh run "refactor src/tool" --model deepseek-v4-flash --provider deepseek

# Disable streaming (useful when piping output)
zh run "summarize the git log" --no-stream

# Presets narrow the toolset (standard | minimal | ptc | creative)
zh run "quick edit" --preset minimal

# Shell sandboxing (native | process | none — deny-list + env allowlist + watchdog)
zh run "clean the build" --sandbox process

# Permission preset bundles sandbox + approval (read-only blocks mutations)
zh run "audit the repo" --permission-preset read-only

# Attach MCP stdio servers (repeatable; tools appear as mcp_<srv>_<tool>)
zh run "use the remote tools" --mcp "npx -y @modelcontextprotocol/server-filesystem /tmp"
```

### `chat` — Interactive REPL

Start an interactive session. Type `exit` or `quit` to leave.

```bash
zh chat
zh chat --session notes      # resume / persist a named session
```

### `serve` — HTTP API + Web UI

```bash
zh serve --port 3080
open http://127.0.0.1:3080        # dsh GUI: sessions sidebar, streaming chat
```

The GUI speaks the upstream `/api` RPC protocol (unary POST + two
WebSocket event streams), implemented natively in Zig by
`src/server/apiproxy/`. A legacy minimal JSON API remains available on the same port:

```bash
curl -sS localhost:3080/healthz
curl -sS -X POST localhost:3080/run -d '{"prompt":"analyze this repo"}'
curl -sS localhost:3080/sessions          # list persisted sessions
curl -sS localhost:3080/events            # SSE stream
```

### `workflow` — Multi-step Agent Runs

```bash
cat > wf.json <<'JSON'
{"name":"triage","steps":[
  {"id":"recon","prompt":"List the failing tests"},
  {"id":"fix","prompt":"Fix the failures described below","depends_on":["recon"]}
]}
JSON
zh workflow wf.json     # topological execution + .zharness/runs report
```

### `plugin` — Native dylib Tools (ABI v1)

```bash
zh plugin list [--dir X]              # discover ~/.zharness/plugins, ./plugins
zh plugin exec p_hello_hello_echo '{"name":"x"}' --dir examples/plugin-hello/build
```

See [docs/plugins.md](docs/plugins.md) for the C ABI contract.

## Configuration

zharness reads configuration from environment variables and an optional
`~/.zharness/config.toml`.

| Setting    | Default                                  | Notes |
|------------|------------------------------------------|-------|
| Provider   | `deepseek`                               | `deepseek`, `openai` / `openai-compat`, `anthropic`, `ollama` |
| Model      | `deepseek-v4-flash`                      | override with `--model` |
| Endpoint   | `https://api.deepseek.com/chat/completions` | resolved from provider id |
| Reasoning effort | `medium`                          | passed through when supported |
| Max turns  | `64`                                     | agent loop iteration cap |
| Stream     | `true`                                   | disabled with `--no-stream` |

**API key** (precedence order):

1. `ZHARNESS_API_KEY` environment variable
2. `DEEPSEEK_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` environment variable
3. `api_key` under `[model]` in `~/.zharness/config.toml`

## Tools

The coding agent has access to:

| Tool         | Purpose |
|--------------|---------|
| `file_read`  | Read a file from the workspace |
| `file_write` | Write/overwrite a file |
| `file_edit`  | Exact old→new string replacement |
| `glob`       | Find files by glob pattern (`**/*.zig`) |
| `grep`       | Search file contents with a regex |
| `shell`      | Run a command via `/bin/sh -c` in the workspace |
| `git_status` | Git working-tree status (porcelain) |
| `git_diff`   | Git diff (optional `--staged`) |
| `git_log`    | Recent commit history |
| `git_commit` | Stage all changes and commit with a message |
| `web_fetch`  | Fetch web pages via curl |
| `web_search` | Search the web |
| `spawn_agent` | Spawn isolated child agents |
| `run_code`   | Execute code snippets |
| `skill_use` / `skill` | Load specialized instructions |
| `memory_get` / `memory_set` | Persistent key-value memory |
| `plan_add` / `plan_update` / `plan_set` | Task planning |
| `goal_set`   | Goal tracking |
| `present`    | Declare the final files this turn delivers (deliverables) |
| `read_image` | Attach a workspace image so a vision model sees it next request |
| `terminal_open` / `terminal_send` / `terminal_read` / `terminal_list` / `terminal_close` | Persistent shells (`/bin/sh`) whose cwd/env survive across calls |
| `session_search` / `session_read` | Search past session transcripts and read one session |
| `team_task_create` / `team_task_list` / `team_task_get` / `team_task_update` | Shared task board with CAS revisions, ownership and dependencies |
| `list_agents` | List subagent runs from the process registry |
| `schedule_create` / `schedule_list` / `schedule_update` / `schedule_delete` | One-shot reminders surfaced in the system prompt |
| `lsp_diagnostics` | Run a language server (e.g. clangd) and return its diagnostics for a file |
| `job_list` / `job_output` / `job_kill` | Inspect/read/stop background jobs (live registry + workflow runs) |
| `mcp_*`      | MCP server tools (projected as `mcp_<srv>_<tool>`) |
| `list_mcp_resources` / `list_mcp_resource_templates` / `read_mcp_resource` | Inspect and read MCP server resources |

Tools only touch paths inside the workspace root (`cwd`). The shell tool
expects a direct command string (e.g. `"ls -la"`) — do not wrap it in
`sh -c` or `bash -c`.

## Sessions

Conversations can be persisted and resumed with `--session <id>`. The
transcript is stored as JSON under `.zharness/sessions/<id>.json` in the
current working directory.

```bash
# Turn 1: teach something
zh run "My favorite color is cobalt blue. Remember this." --session live

# Turn 2: resume the same conversation later / in another process
zh run "What is my favorite color?" --session live
```

The system prompt is never persisted — only the user / assistant / tool
messages make up the transcript, and it is re-seeded into the agent loop on
resume. The `.zharness/` directory is git-ignored.

## Presets

Presets constrain the agent's toolset for different use cases:

| Preset      | Description |
|-------------|-------------|
| `standard`  | Full agent with all tools, skills, memory, planning |
| `minimal`   | Bare essentials: shell, editor, filesystem |
| `ptc`       | Code Mode with tool SDK for batch operations |
| `creative`  | Full agent + plugin inspector + runtime debugger |

```bash
zh run "quick edit" --preset minimal
```

## Repository Layout

```
zharness/
├── src/
│   ├── main.zig              # CLI entry (run / chat / serve), session wiring
│   ├── config.zig            # Config + provider resolution + API-key precedence
│   ├── model/
│   │   └── model.zig         # Internal Model IR + ChatClient (IR ⇄ OpenAI JSON over curl)
│   ├── tool/
│   │   ├── registry.zig      # Tool registry + OpenAI tools schema serialization
│   │   └── builtin.zig       # Tool executors
│   ├── agent/
│   │   ├── agent.zig         # Agent + AgentLoop driver, events, session seed/sync
│   │   ├── subagent.zig      # Isolated child agent runs
│   │   ├── plan.zig          # Plan checklist
│   │   └── goal.zig          # Goal tracker
│   ├── skill/                # SKILL.md discovery + registry
│   ├── memory/
│   │   ├── working.zig       # Working scratchpad
│   │   └── persistent.zig    # Persistent KV store
│   ├── session/
│   │   ├── session.zig       # JSON message store (persistence)
│   │   └── checkpoint.zig    # Turn-boundary snapshots
│   ├── sandbox/
│   │   └── sandbox.zig       # Level-1 process sandbox
│   ├── server/
│   │   ├── httpd.zig         # Minimal HTTP/1.1 server
│   │   ├── api.zig           # JSON routes (run/chat/sessions/healthz)
│   │   ├── events.zig        # SSE hub
│   │   ├── static.zig        # Static file serving
│   │   └── apiproxy/         # DeepSeek Harness API protocol
│   ├── protocol/
│   │   ├── jsonrpc.zig       # JSON-RPC 2.0 codec
│   │   └── mcp.zig           # MCP stdio client
│   ├── workflow/              # JSON workflow parse/validate/execute
│   ├── pluginabi/             # dlopen plugin loader (C ABI v1)
│   ├── obs.zig                # Event envelopes → JSONL log
│   └── presets.zig            # standard/minimal/ptc/creative capability table
├── test/                      # Standalone test roots (_t_*.zig)
├── webui/                     # Vendored DeepSeek Harness web GUI (React)
├── docs/                      # Architecture, plugins, web, settings
├── examples/                  # Plugin and usage examples
├── build.zig                  # Build script
└── build.zig.zon              # Package manifest
```

## Testing

```bash
zig build test                             # full suite (431 tests)
zig build test -Dtest-filter="shell echo"  # a single test by name
```

Tests live inline in each module as `test { ... }` blocks, pulled into the
build by `src/tests.zig`. The `test/_t_*.zig` files are the original per-area
swarm roots; their modules are already folded into `zig build test`, so they
are not runnable standalone (Zig's module path disallows `../src` imports
from `test/`).

## Architecture

For a deep dive into the data flow and module responsibilities, see
[docs/architecture.md](docs/architecture.md).

```
CLI (main.zig)
  → Config (config.zig)
    → AgentLoop (agent/agent.zig)
      → ChatClient (model/model.zig)   ⇄  provider (OpenAI-style JSON over curl)
      → ToolRegistry / executors (tool/registry.zig, tool/builtin.zig)
  ↔ Session (session/session.zig)       persisted transcript
```

The runtime kernel is **zcordis** (also Zig 0.17, at `../zcordis`). zharness
imports it as `@import("cordis")` and uses its `Context`, `Scope`, `EventBus`,
and `Scheduler`.

## Roadmap

### MVP-1 ✅
- Agent loop with DeepSeek model
- Filesystem + shell + git tools
- Persistent sessions
- CLI interface

### MVP-2 ✅
- Web UI (vendored DeepSeek Harness client)
- HTTP API + WebSocket streaming
- MCP integration
- Skills & memory system
- Plan & goal tracking

### MVP-3 ✅
- SubAgent orchestration
- Workflow execution
- WASM plugin sandbox
- Dynamic Cordis runtime (model-defined JS plugin halves)
- Enhanced observability

### Production 📋
- OpenTelemetry integration
- Advanced sandboxing
- Plugin marketplace
- Multi-agent coordination

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License — see [LICENSE](LICENSE).

## Acknowledgments

- [zcordis](https://github.com/chy3xyz/zcordis) — Composable Runtime Kernel
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — "Everything is a Plugin" philosophy
- [Zig](https://ziglang.org/) — Fast, reliable, and maintainable code
