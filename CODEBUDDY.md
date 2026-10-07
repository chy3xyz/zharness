# CODEBUDDY.md

This file provides guidance to CodeBuddy Code when working with code in this repository.

`zharness` is a native coding-agent harness written in **Zig 0.17**, ported from the DeepSeek Harness ("everything is a plugin") philosophy. It runs on top of the **zcordis** runtime kernel (also Zig 0.17, located at `../zcordis`). It now ships a full CLI + HTTP/GUI harness: `zh run "..."` drives a model (DeepSeek by default) plus filesystem/shell/git/web/MCP tools through an agent loop.

## Build / Run / Test commands

Zig is the only toolchain. Requires Zig `0.17.0` stable (the project pins `minimum_zig_version = "0.17.0"`).

```bash
# Build the zharness executable (installs to zig-out/bin/zh)
zig build

# Run a task via the coding agent (needs ZHARNESS_API_KEY or DEEPSEEK_API_KEY)
ZHARNESS_API_KEY=... zig build run -- run "analyze this repo and fix the build"

# Run the unit test suite
zig build test

# Run a single test by name
zig build test -Dtest-filter="shell echo"

# Clean
zig build --help
```

`build.zig` defines two steps: install the `zh` executable, and `zig build test` (builds a test executable from `src/tests.zig` linking the `cordis` module). Tests live inline in each module (`test { ... }` blocks); the suite is currently **437 tests**.

## Dependencies and module layout

- `build.zig.zon` depends on `zcordis` via a **relative path** (`../zcordis`). zcordis is the runtime kernel providing `Context`, `Scope`, `EventBus`, `Scheduler`, `PluginManager`. zharness imports it as `@import("cordis")`.
- The whole `src/` tree shares **one module namespace** (single root module `src/main.zig`), so files cross-import with relative paths like `@import("agent/agent.zig")` or `@import("model/model.zig")`. Do not add a separate `addModule` per subdirectory — match the zcordis/zeepseek pattern.
- Nearby reference material lives in `_ref/` (do NOT compile it): `_ref/deepseek-harness` (the original TS project) and `_ref/zeepseek` (a complete Zig 0.17 implementation, the primary source of reused patterns for model I/O, process execution, and tools). `dev.md` is the design spec; `todo.md` is the one-line task ("port deepseek-harness to zharness, reuse deepseek + zcordis code, don't reinvent wheels").

## Module architecture (the big picture)

The data flows: `CLI → Config → AgentLoop → ChatClient (model IR) ⇄ tools`, all owned under a `cordis.Context`.

- **`src/config.zig`** — `Config` (provider, model, api_key, endpoint, reasoning_effort, cwd, max_turns, sandbox_mode). API key precedence: `ZHARNESS_API_KEY` → `DEEPSEEK_API_KEY`. `applyOverrides` handles CLI flags (--model, --provider, --no-stream). Endpoints are resolved by provider id in `providerEndpoint`.
- **`src/model/model.zig`** — the **internal Model IR** (dev.md §VI) that the runtime uses instead of the OpenAI wire schema. Key types: `Role`, `Message` (role/content with `tool_call_id` and `tool_calls_json` for echoing assistant tool calls back to the provider), `ChatRequest`, `ChatResponse`, `ToolCall`. `ChatClient.chat` translates IR ⇄ OpenAI-style JSON over `std.http` + `std.Io` (non-streaming is the reliable macOS path; SSE streaming has known EOF issues, per zeepseek notes). JSON parsing here is a hand-rolled brace/bracket matcher (`findMatchingBrace`, `findMatchingBracket`) — there is no JSON library.
- **`src/tool/registry.zig`** — `ToolRegistry` + `ToolDefinition` is the **single source of truth** for capabilities. Each tool carries its OpenAI function-schema `parameters_json`. `buildToolsJson` serializes all definitions for the model request, so the wire schema can never drift from the executor. `registerBuiltins` declares the coding-agent tools.
- **`src/tool/builtin.zig`** — the **executors** that `ToolRegistry` declares. `execute(alloc, cwd, ToolCall) !ToolResult` dispatches by name. Tools: `file_read`, `file_write`, `file_edit` (exact old→new string replace), `glob` (hand-rolled `**`/`*`/`?` matcher), `grep` (std.Regex), `shell` (libc `popen "/bin/sh -c"`, cwd-prefixed, 2>&1 merged, 256 KiB cap), `git_status/diff/log/commit`. Paths are resolved via `std.fs.path.resolve` against cwd and rejected if outside the workspace (`isInsideWorkspace`). `freeResult` frees the allocator-owned slices; `parseArgs` is a flat JSON string/number/boolean extractor.
- **`src/agent/agent.zig`** — `Agent` (thin: id, state, scope, config) + `AgentLoop` (the driver). The loop alternates: append user msg → `ChatClient.chat` → if `resp.has_tools`, echo assistant `tool_calls_json` and run each tool via `tool_builtin.execute`, feeding results back as `tool` messages → else treat content as the final answer. `AgentState` is the state machine (dev.md §XXXIV). Events (`ToolCallEvent`, `ToolResultEvent`, `AgentDoneEvent`) are emitted onto the cordis bus so the runtime stays decoupled from concrete tools/providers (dev.md §VIII).

## Key invariants / gotchas

- **No JSON or HTTP library** — zeepseek deliberately used `std.http` + hand-rolled JSON. Keep new parsing in the same style; don't pull in deps.
- **Memory ownership**: tool/result/model slices are allocator-owned; callers must `free` (`tool_builtin.freeResult`, `ChatResponse.deinit`, `Config.deinit`). `Message` content is duped into the loop's allocator.
- **Tool-call echo**: when the model emits `tool_calls`, the assistant message must include `tool_calls_json` (rebuilt by `tool_mod_echo`) so the next request is accepted by the provider. Missing this breaks multi-turn tool use.
- **Sandbox / permissions**: filesystem tools only touch paths inside `cwd`; the `shell` tool runs under `sandbox_mode` (deny-list + env allowlist + watchdog at `.process`). `dispatchTool` additionally gates every tool through the permission preset + approval policy (see `src/sandbox/sandbox.zig`, `src/agent/agent.zig`).
- **zcordis coupling**: `AgentLoop` holds a `*cordis.Context`; services/events follow the zcordis API (`ctx.emit`, `scope.on`, `ctx.provide`). Consult `../zcordis/src/cordis.zig` for the public surface.

## Project status

MVP-1 (CLI agent), MVP-2 (HTTP server + Web GUI + MCP + skills/memory/plan/goal) and
MVP-3 (subagents, workflows, WASM plugin sandbox, dynamic Cordis runtime,
observability) are implemented — `zig build` and `zig build test` are green
(437/437). Remaining roadmap items live under "Production" in `README.md`
(OpenTelemetry, advanced sandboxing, plugin marketplace, multi-agent
coordination). See `AGENTS.md` for the operational cheat-sheet.
