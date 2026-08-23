# zharness

A native coding-agent harness written in **Zig 0.17**, built on the
[zcordis](https://github.com/) runtime kernel. `zharness` drives an LLM plus
filesystem / shell / git tools through an agent loop — "everything is a
plugin". The first working target (MVP-1) is a CLI coding agent.

➡️ **New here?** Start with [QUICKSTART.md](QUICKSTART.md) for a copy-paste
getting-started in under five minutes.

## Requirements

- **Zig `0.17.0-dev`** (the project pins `minimum_zig_version = "0.17.0"`).
- An API key for a supported provider (DeepSeek by default). `curl` must be
  available on `PATH` — HTTPS requests are issued via `curl` (the most
  reliable path from Zig 0.17 on macOS).

## Build

```bash
zig build            # builds ./zig-out/bin/zharness
zig build test       # runs the unit test suite (177 tests)
```

## Configuration

zharness reads configuration from environment variables and an optional
`~/.zharness/config.toml`.

| Setting    | Default                                  | Notes |
|------------|------------------------------------------|-------|
| Provider   | `deepseek`                               | `deepseek`, `openai` / `openai-compat`, `anthropic`, `ollama` (legacy spellings like `openrouter` fall back to OpenAI-compat) |
| Model      | `deepseek-v4-flash`                      | override with `--model` |
| Endpoint   | `https://api.deepseek.com/chat/completions` | resolved from provider id |
| Reasoning effort | `medium`                          | passed through when supported |
| Max turns  | `64`                                     | agent loop iteration cap |
| Stream     | `true`                                   | disabled with `--no-stream` |

**API key** (precedence order):

1. `ZHARNESS_API_KEY` environment variable
2. `DEEPSEEK_API_KEY` environment variable
3. `api_key` under `[model]` in `~/.zharness/config.toml`

```bash
export ZHARNESS_API_KEY="sk-..."
```

## Usage

### `run` — single task

Run one agent task and exit. The final answer is printed to stdout.

```bash
# Basic task
ZHARNESS_API_KEY=... zig build run -- run "analyze this repo and fix the build"

# Override model / provider
zharness run "refactor src/tool" --model deepseek-v4-flash --provider deepseek

# Disable streaming (useful when piping output)
zharness run "summarize the git log" --no-stream

# Presets narrow the toolset (standard | minimal | ptc | creative)
zharness run "quick edit" --preset minimal

# Shell sandboxing (off | process — deny-list + env allowlist + watchdog)
zharness run "clean the build" --sandbox process

# Attach MCP stdio servers (repeatable; tools appear as mcp_<srv>_<tool>)
zharness run "use the remote tools" --mcp "npx -y @modelcontextprotocol/server-filesystem /tmp"
```

### `serve` — HTTP API

```bash
zharness serve --port 3080
curl -sS localhost:3080/healthz
curl -sS -X POST localhost:3080/run -d '{"prompt":"analyze this repo"}'
curl -sS localhost:3080/sessions          # list persisted sessions
curl -sS localhost:3080/events            # SSE stream (heartbeat stub)
```

### `workflow` — multi-step agent runs

```bash
cat > wf.json <<'JSON'
{"name":"triage","steps":[
  {"id":"recon","prompt":"List the failing tests"},
  {"id":"fix","prompt":"Fix the failures described below","depends_on":["recon"]}
]}
JSON
zharness workflow wf.json     # topological execution + .zharness/runs report
```

### `plugin` — native dylib tools (ABI v1)

```bash
zharness plugin list [--dir X]              # discover ~/.zharness/plugins, ./plugins
zharness plugin exec p_hello_hello_echo '{"name":"x"}' --dir examples/plugin-hello/build
```
See [docs/plugins.md](docs/plugins.md) for the C ABI contract.

### `chat` — interactive REPL

Start an interactive session. Type `exit` or `quit` to leave.

```bash
zharness chat
zharness chat --session notes      # resume / persist a named session
```

### `serve` — (not yet implemented)

Reserved per the design spec (dev.md §XXIII). Currently prints a notice and
exits.

## Web UI (vendored DeepSeek Harness client)

`zharness serve` ships the full **deepseek-harness web GUI** (React,
vendored under `webui/dsh/` — MIT, see `THIRD-PARTY_NOTICES.md`):

```bash
zharness serve --port 3080
open http://127.0.0.1:3080        # dsh GUI: sessions sidebar, streaming chat
```

The GUI speaks the upstream `/api` RPC protocol (unary POST + two
WebSocket event streams), implemented natively in Zig by
`src/server/apiproxy/`. The protocol surface is the minimal chat subset —
sessions, history, prompt streaming, health; settings/subagents/goals
degrade gracefully per upstream's own missing-feature rules. A legacy
minimal JSON API (`POST /run`, `GET /sessions`, `/healthz`, `/events`)
remains available on the same port for scripts.

Rebuild the frontend: `webui/BUILD.md`. Design-token reuse map:
`docs/web.md`. Protocol spec: `docs/dsh-reuse-spec.md`.

## Sessions

Conversations can be persisted and resumed with `--session <id>`. The
transcript is stored as JSON under `.zharness/sessions/<id>.json` in the
current working directory, so sessions are scoped per workspace.

```bash
# Turn 1: teach something
zharness run "My favorite color is cobalt blue. Remember this." --session live

# Turn 2: resume the same conversation later / in another process
zharness run "What is my favorite color?" --session live
```

The system prompt is never persisted — only the user / assistant / tool
messages make up the transcript, and it is re-seeded into the agent loop on
resume. The `.zharness/` directory is git-ignored.

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

Tools only touch paths inside the workspace root (`cwd`). The shell tool
expects a direct command string (e.g. `"ls -la"`) — do not wrap it in
`sh -c` or `bash -c`.

## Repository layout

```
src/
  main.zig          CLI entry (run / chat / serve), session wiring
  config.zig        Config + provider resolution + API-key precedence
  model/model.zig   Internal Model IR + ChatClient (IR ⇄ OpenAI JSON over curl)
  tool/registry.zig Tool registry + OpenAI tools schema serialization
  tool/builtin.zig  Tool executors
  agent/agent.zig   Agent + AgentLoop driver, events, session seed/sync
  session/session.zig  JSON message store (persistence)
  tests.zig         Test root (build with `zig build test`)
```

## Notes / limitations (MVP-1)

- No JSON or HTTP library is used — requests are hand-rolled JSON posted via
  `curl` (per the zeepseek reference design).
- `SandboxMode` exists in config but is not yet wired into `builtin.zig`
  (tool approval is stubbed).
- `serve` (HTTP/WebSocket), MCP client, skills, and subagents are planned but
  not implemented.

## Testing

```bash
zig build test                              # full suite
zig test src/tool/registry.zig              # a single module's inline tests
```
