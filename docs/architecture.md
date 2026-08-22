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
| `main.zig` | CLI entry (`run` / `chat` / `serve`), flag parsing, session wiring |
| `config.zig` | `Config` (provider, model, key, endpoint, cwd, max_turns). API-key precedence: `ZHARNESS_API_KEY` → `DEEPSEEK_API_KEY` → `~/.zharness/config.toml`. `applyOverrides` applies CLI flags. |
| `model/model.zig` | The internal **Model IR** (`Role`, `Message`, `ChatRequest`, `ChatResponse`, `ToolCall`) and `ChatClient.chat`, which translates IR ⇄ OpenAI-style JSON. |
| `tool/registry.zig` | `ToolRegistry` + `ToolDefinition` — single source of truth for capabilities. `buildToolsJson` serializes all definitions for the request. |
| `tool/builtin.zig` | The executors behind each tool. `execute(alloc, io, cwd, call)` dispatches by name. |
| `agent/agent.zig` | `Agent` (identity/state) + `AgentLoop` (the driver). Emits events onto the cordis bus. |
| `session/session.zig` | JSON message store; `save(io, path)` / `load(io, path)`. |
| `tests.zig` | Test root for `zig build test`. |

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

## Memory ownership

Tool / result / model slices are allocator-owned; callers must free them:
`tool_builtin.freeResult`, `ChatResponse.deinit`, `Config.deinit`, and
`AgentLoop.deinit`. The binary enables the DebugAllocator, so leaks panic at
exit. Be careful that `unescape` and friends allocate with the same allocator
used to free.

## Known limitations (MVP-1)

- `SandboxMode` exists in config but is not wired into `builtin.zig`; tool
  approval is stubbed.
- `serve` (HTTP/WebSocket), the MCP client, skills, and subagents are planned
  (dev.md §XV/§XIX/§XX/§XXIII) but not implemented.
- `buildToolsJson` serializes the tools array with no surrounding brackets; the
  caller wraps it in the request body.
