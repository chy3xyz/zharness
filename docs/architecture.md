# Architecture

This document explains how zharness is put together. It is the deep-dive
companion to `README.md` and is aimed at contributors who want to understand
the data flow before changing code.

## Big picture

zharness is a thin CLI coding agent. A request flows through a small set of
layers, all owned under a single `cordis.Context`:

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
and `Scheduler`. The design follows the "everything is a plugin" philosophy of
the DeepSeek Harness.

## Module layout

`src/` is a **single module namespace** rooted at `src/main.zig`. Files import
each other with relative paths (`@import("agent/agent.zig")`). Do not add a
per-directory `addModule`; the pattern matches zcordis/zeepseek.

| File / dir | Responsibility |
|------------|----------------|
| `main.zig` | CLI entry (`run` / `chat` / `serve` / `workflow` / `plugin`), flag parsing, session wiring, loop extensions, observability setup |
| `cli_flags.zig` | Strict subcommand flag parser (`--model/--provider/--no-stream/--session/--preset/--sandbox/--approval/--permission-preset/--port/--mcp`) |
| `config.zig` | `Config` (provider, model, key, endpoint, cwd, max_turns, sandbox_mode). API-key precedence: `ZHARNESS_API_KEY` → provider env (`DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`, …) → `~/.zharness/config.toml`. |
| `model/provider.zig` | Provider profiles: endpoint/auth/wire-format defaults for deepseek, openai-compat, anthropic, ollama |
| `model/model.zig` | The internal **Model IR** and `ChatClient.chat` (buffered + SSE via curl), dispatching on wire format |
| `model/anthropic.zig` | IR ⇄ Anthropic Messages-API translation (tool_use/tool_result blocks) |
| `tool/registry.zig` | `ToolRegistry` — single source of truth for capabilities; preset filtering removes entries |
| `tool/builtin.zig` | Built-in executors (fs/grep/glob/shell/git); shell routes through the sandbox in `.process` mode |
| `tool/webfetch.zig` | `web_fetch` / `web_search` (curl-backed) |
| `tool/spawn_agent.zig` | `spawn_agent` tool bridging to the SubAgent runner (recursion-guarded) |
| `tool/mcp_bridge.zig` | Remote MCP tools projected into local naming (`mcp_<srv>_<tool>`) |
| `agent/agent.zig` | `Agent` + `AgentLoop`: turn loop, checkpoints at boundaries, Extensions vtable (context rendering + tool dispatch), cordis event emission |
| `agent/subagent.zig` | Isolated child agent runs (turn/output caps, injected transport) |
| `agent/plan.zig`, `goal.zig` | Plan checklist + goal tracker rendered into per-turn context |
| `skill/` | SKILL.md discovery + registry (`skill_use` tool) |
| `memory/` | Working scratchpad + persistent KV store (`memory_get/set` tools) |
| `session/session.zig` | Transcript store: legacy JSON array + append-only `<id>.jsonl` event log; `save` / `load` / resume |
| `session/checkpoint.zig` | Turn-boundary snapshots (atomic publish, pruning) |
| `sandbox/sandbox.zig` | Level-1 process sandbox: policy classify, env allowlist, watchdog timeout |
| `server/httpd.zig` | Minimal HTTP/1.1 server (libc sockets, poll-gated stop) |
| `server/api.zig` | JSON routes over injected `ServerDeps` (run/chat/sessions/healthz/events) |
| `workflow/` | JSON workflow parse/validate/cycle-check, topological executor, run reports |
| `protocol/jsonrpc.zig`, `mcp.zig` | JSON-RPC 2.0 codec + MCP stdio client |
| `obs.zig` | Event envelopes (trace/span ids) → JSONL log |
| `presets.zig` | standard/minimal/ptc/creative capability table |
| `pluginabi/` | dlopen plugin loader: C ABI v1 contract, manifest validation, skip reports |
| `tests.zig` | Test root for `zig build test` (all modules join the suite) |

## The Model IR

`model/model.zig` deliberately does **not** use the OpenAI wire schema directly.
Instead the runtime works with an internal IR (dev.md §VI) and `ChatClient.chat`
translates both ways:

- A `Message` carries `role` and `content`, plus `tool_call_id` (to echo tool
  results back) and `tool_calls_json` (to echo assistant tool calls back to the
  provider).
- `ChatRequest` bundles the message list, `tools_json`, `system_prompt`, and
  optional `reasoning_effort`.
- `ChatResponse` exposes `content`, `reasoning`, `tool_calls`, and
  `has_tools`.

Translation is hand-rolled: there is no JSON library. `findMatchingBrace` /
`findMatchingBracket` locate objects/arrays; `escape` / `unescape` handle the
minimal string escaping. Keep new parsing in this style.

### Why curl, not std.http

Requests are written to `/tmp/zharness_req.json` and posted with
`curl -sS -X POST ... -d @<file>`. The zeepseek reference notes that the
`std.http` request API is intricate to get right on Zig 0.17 / macOS and that
SSE streaming has known EOF issues. Non-streaming via curl is the reliable
path, so it is what zharness uses. Note `model.zig` rejects any response that
is not a well-formed JSON object starting with `{` (this surfaces provider
error envelopes and malformed-request bodies instead of yielding an empty
answer).

## The agent loop

`AgentLoop.run` alternates until `max_turns` or a final answer:

1. Append the user message.
2. `ChatClient.chat` → `ChatResponse`.
3. Emit `thinking` / `text` events; record the assistant message, echoing
   `tool_calls_json` when the model emitted tool calls.
4. If `has_tools` is false, treat `content` as the final answer and stop.
5. Otherwise execute each tool call via `tool_builtin.execute`, feeding results
   back as `tool` messages, and loop.

Events (`ToolCallEvent`, `ToolResultEvent`, `AgentDoneEvent`) are emitted onto
the cordis bus so the runtime stays decoupled from concrete tools/providers.

### Tool-call echo (invariant)

When the model emits `tool_calls`, the assistant message **must** include
`tool_calls_json` (rebuilt by `tool_mod_echo`) so the next request is accepted
by the provider. Omitting this breaks multi-turn tool use.

## Sessions

A session is a persisted transcript stored as JSON under
`.zharness/sessions/<id>.json` relative to the workspace `cwd`. The CLI loads a
session (if `--session <id>` is given), seeds the loop's message list, runs the
turn, then mirrors the loop transcript back into the session and saves it. The
system prompt is intentionally **not** part of the transcript — it is supplied
fresh on each run from `SYSTEM_PROMPT` in `main.zig`.

Alongside the legacy JSON array, `save` maintains an append-only JSONL event
log at `.zharness/sessions/<id>.jsonl` with a format-version header (see
[session-format.md](session-format.md)); `load` prefers the log and falls back
to the legacy JSON, which is the migration seam.

## Memory ownership

Tool / result / model slices are allocator-owned; callers must free them:
`tool_builtin.freeResult`, `ChatResponse.deinit`, `Config.deinit`, and
`AgentLoop.deinit`. The binary enables the DebugAllocator, so leaks panic at
exit. Be careful that `unescape` and friends allocate with the same allocator
used to free.

## Known limitations

- Anthropic streaming degrades to buffered requests (SSE is OpenAI-dialect
  only); `reasoning_effort` is ignored on the Anthropic wire format.
- The `/events` SSE endpoint emits heartbeats only; wiring live agent events
  through it is pending (JSONL envelopes already land in
  `.zharness/logs/events.jsonl`).
- MCP servers attach per invocation via repeated `--mcp "<cmd>"` flags
  (space-split argv, max 4, no quote handling).
- Presets constrain the classic builtin toolset only; harness capabilities
  (plan/goal/memory/skill/web/mcp/plugin/spawn_agent) always stay available.
- L2 WASM sandboxing awaits the zcordis wasm runtime; the process sandbox is
  Level-1 (deny-list + env allowlist + watchdog), not a security boundary.
