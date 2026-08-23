# zharness Swarm Plan — drive dev.md panorama to ≥95%

Mission: implement the remaining dev.md roadmap (Phases 5–12 + Plugin ABI +
Presets + Observability) with parallel agents working on **disjoint file sets**
in one shared working tree.

## Ground rules for EVERY agent (non-negotiable)

1. **Zig 0.17 idioms** (`0.17.0-dev.1567`). Read these exemplars FIRST and
   copy their patterns:
   - `src/model/model.zig` — ArrayList(u8) unmanaged style (`.empty` +
     allocator-passing methods), hand-rolled JSON via `findMatchingBrace` /
     `findMatchingBracket`, curl subprocess transport, mkstemp private temps.
   - `src/session/checkpoint.zig` — atomic file publish (tmp+rename), stateless
     id derivation, tolerant loading.
   - `src/clib.zig` — popen / libc helpers. `-lc` is linked; use these helpers
     instead of std.process Child where a shell pipeline is needed.
   - `docs/architecture.md` — single module namespace rooted at `src/main.zig`,
     relative imports only, no JSON library, no std.http client (use curl).
2. **No new package deps.** `build.zig.zon` must not change.
3. **No network / API key in tests.** All tests offline (parsers, fakes,
   fixtures). Never call live provider endpoints from tests.
4. **Leak-free**: binary uses DebugAllocator → every allocation freed. Tests
   must pass under `std.testing.allocator`.
5. **File ownership** (see matrix): touch ONLY your files. NEVER edit
   `main.zig`, `agent/agent.zig`, `tests.zig`, `tool/builtin.zig`,
   `tool/registry.zig`, `config.zig`, or `model/model.zig` unless your row
   explicitly owns them. Never run `git commit`.
6. **Decouple from cordis**: modules take plain params (allocators, io, fn
   pointers/sinks). The integrator wires cordis Context/EventBus later.
7. **Self-test root**: create `src/_t_<area>.zig` at TOP-LEVEL src/ (so `..`
   imports stay inside the module path) importing your module files, then run:
   `zig test -lc src/_t_<area>.zig`. All inline `test` blocks must pass. Leave
   the `_t_` file in place — the integrator folds it into `tests.zig`.
8. **Style**: `//!` doc-comment header explaining contract (see sandbox.zig),
   English comments, error names PascalCase after `error.`, atomic writes.

## Ownership matrix

| Agent | Owns (exclusive write access) |
|-------|-------------------------------|
| W1-integration | `sandbox/sandbox.zig`, `tool/builtin.zig`, `agent/agent.zig`, `main.zig`, `tests.zig`, wiring of checkpoint/skill/memory |
| A-providers | `config.zig`, `model/provider.zig`, `model/anthropic.zig`, `model/ollama.zig`, small additive edits to `model/model.zig` |
| B-net | `server/httpd.zig`, `server/api.zig`, `tool/webfetch.zig` |
| C-subagent | `agent/subagent.zig`, `tool/spawn_agent.zig` |
| D-workflow | `workflow/*.zig` |
| E-mcp | `protocol/jsonrpc.zig`, `protocol/mcp.zig`, `tool/mcp_bridge.zig` |
| F-obs-preset | `obs.zig`, `presets.zig` |
| G-pluginabi | `pluginabi/*.zig`, `examples/plugin-hello/*` |

## Task specs

### W1-integration — wire the six orphan modules
- Fix `sandbox/sandbox.zig` compile errors: line ~326 "local variable is never
  mutated"; remove/correct the bogus standalone-test claim (its `../clib.zig`
  import only resolves when compiled from a src/-root test root — that is what
  `_t_w1.zig` is for).
- Wire sandbox: in `builtin.zig` shell executor route through
  `sandbox.run()` when `cfg.sandbox_mode == .process`; denied results become
  failed ToolResults carrying the reason. Plumb config through without editing
  `config.zig` (SandboxMode already exists there).
- Wire checkpoint: AgentLoop saves a checkpoint at turn boundaries and after
  each tool batch (`CheckpointStore.save`) wired by main.zig-owned store
  instance passed into the loop.
- Wire skill + memory into main.zig: discover skills (workspace `skills/` +
  `~/.zharness/skills`), render prompt section, register optional `skill_use`
  tool; open PersistentStore at `~/.zharness/memory`, register `memory_get` /
  `memory_set` tools; WorkingMemory available to loop (task/plan scratchpad).
- Surface plan/goal: minimal integration — GoalTracker + PlanState rendered as
  a system-prompt section and updated via tools `plan_set` / `goal_set`.
- Add ALL orphan modules + their tests to `tests.zig` imports.
- Acceptance: `zig build && zig build test` green, zero leaks, CLI still runs.

### A-providers — provider matrix (dev.md §VI)
- `model/provider.zig`: Provider enum {deepseek, openai_compat, anthropic,
  ollama} + per-provider defaults (endpoint/base-url, model names, auth header
  shape) + `fromString`.
- `model/anthropic.zig`: translate internal IR ⇄ Anthropic Messages API JSON
  (system top-level, content blocks, tool_use/tool_result blocks). Hand-rolled
  JSON like model.zig. Non-streaming first; streaming optional stretch.
- `model/ollama.zig`: OpenAI-compatible `/v1/chat/completions` on
  `http://localhost:11434` — thin defaults over existing ChatClient.
- Extend `config.zig`: `provider` parses new values; env keys
  ANTHROPIC_API_KEY / OLLAMA_HOST; keep ZHARNESS_API_KEY precedence intact.
- Tests: IR⇄wire translation round-trips with fixture strings; no network.

### B-net — serve HTTP API + web tools (dev.md §XI/§XXII/§XXIII)
- `server/httpd.zig`: minimal HTTP/1.1 server on std.posix sockets (accept
  loop, parse request line + headers + Content-Length body, write responses).
  No std.http.Server (API churn). Support keep-alive=false (Connection:
  close) to keep it simple.
- `server/api.zig`: JSON routes — POST /run {prompt, session?}, POST /chat,
  GET /sessions, GET /sessions/:id, GET /events (SSE stream stub that emits
  heartbeats; real event feed arrives at integration), GET /healthz.
  Handlers receive a `ServerDeps` struct of fn pointers (run task, list
  sessions) so api.zig stays decoupled from agent/main.
- `tool/webfetch.zig`: `web_fetch` (curl -sSL, size-capped, content-type
  guard) + `web_search` (DuckDuckGo html endpoint, parse result links/titles)
  built on clib popen helpers; registerable ToolDefinitions matching registry
  schema style.
- Tests: request parsing round-trip, route dispatch with fake deps, search
  parser against fixture HTML.

### C-subagent — SubAgent support (dev.md §XVIII)
- `agent/subagent.zig`: spawn child AgentLoop-like runs with isolated message
  list + own system prompt, shared tool registry reference, turn cap + output
  cap; parent gets final text back. Plain params, no cordis import.
- `tool/spawn_agent.zig`: `spawn_agent` ToolDefinition + executor bridging to
  subagent.run (deps injected via struct pointer stored in executor ctx slot —
  follow how builtin executors receive context, adapt minimally WITHOUT
  editing registry.zig: if registry has no ctx slot, expose
  `registerWithContext` in YOUR file wrapping the registry call).
- Tests: nested run with a fake model fn (inject transport), caps enforced.

### D-workflow — Workflow engine (dev.md §XIX)
- `workflow/workflow.zig`: JSON-defined workflow {name, steps:[{id, prompt,
  tool?, depends_on[]}]} parser + validation (cycles rejected).
- `workflow/executor.zig`: topological execution; steps map to agent tasks
  (fn-pointer dep injected); per-step artifact capture; failure policy
  stop-first default.
- Tests: DAG topo order, cycle detection, artifact accumulation.

### E-mcp — MCP client (dev.md §XX)
- `protocol/jsonrpc.zig`: JSON-RPC 2.0 envelope encode/decode (hand-rolled).
- `protocol/mcp.zig`: stdio-transport MCP client: spawn server process via
  clib helpers, initialize handshake, `tools/list` → ToolDefinition list,
  `tools/call` passthrough, notification drain. Line-delimited JSON framing.
- `tool/mcp_bridge.zig`: bridge remote MCP tools into local naming
  (`mcp_<server>_<tool>`) with definitions translated to registry schema.
- Tests: framing codec round-trip, fake-server two-way exchange using an in-
  process pipe pair (no real network).

### F-obs-preset — Observability + Presets (dev.md §XXVIII/§XXX)
- `obs.zig`: EventEnvelope{timestamp, trace_id, span_id, session_id, agent_id,
  event_type, payload_json}; trace/span id generation (random hex); JSONL sink
  appending to `.zharness/logs/events.jsonl` (atomic append + fsync-less);
  helper `emit(event_type, payload)`; level filter.
- `presets.zig`: preset table standard/minimal/ptc/creative → allowed tool
  subsets + system-prompt fragments + default max_turns; `resolve(name)` +
  `fromString`; pure data, no imports beyond std.
- Tests: envelope round-trip + jsonl append/read; preset resolution incl.
  unknown-name error.

### G-pluginabi — dynamic plugin ABI (dev.md §XXV–XXVI)
- `pluginabi/capi.zig`: C ABI contract — exported fns
  `zh_plugin_abi_version()`, `zh_plugin_manifest() -> const char*` (JSON:
  name/version/kind/tools[]), `zh_tool_execute(args_json) -> char*` +
  `zh_string_free(char*)`. Loader via dlopen/dlsym through clib (add helpers
  in YOUR scope if missing — do NOT edit clib.zig; put dlopen wrappers in
  pluginabi/ffi.zig).
- `pluginabi/loader.zig`: scan `~/.zharness/plugins` + workspace `plugins/`
  for `*.so|*.dylib`, load, validate manifest (abi version match, kind=tool),
  produce ToolDefinitions whose executors call zh_tool_execute with JSON
  args, marshal results, unload on deinit. Malformed plugin ⇒ skip with
  logged reason, never crash.
- `examples/plugin-hello/`: tiny C plugin (hello_tool.c + build.sh producing
  .dylib on macOS) used as loader fixture.
- Tests: manifest JSON validation; loader against built example dylib
  (build.sh invoked from test via zig run? NO — commit prebuilt? Instead test
  loader logic with a stub: factor pure parts (manifest parse, name mapping)
  so they are testable without dlopen; dlopen path covered by example build
  script smoke test documented in README section you add under docs/notes).

## Integration protocol (integrator = ox-alpha, wave 3)

After all agents report done:
1. Fold every `src/_t_*.zig` into `tests.zig`, delete the `_t_` files.
2. main.zig: `serve` → B.api; `--preset` flag → F.presets; `zharness plugin
   list/install` → G.loader; `--mcp <cmd>` → E.bridge; obs.emit hooked at
   agent-loop emit points (small agent.zig edit — W1 finished by then);
   register webfetch/spawn_agent/mcp tools.
3. `zig build && zig build test` gate; fix pass; update docs/architecture.md +
   README; final commits per area.

## 95% checklist (definition of done)

- [ ] P0 orphan modules wired (sandbox/checkpoint/skill/memory/plan/goal)
- [ ] P1 providers: deepseek + openai-compat + anthropic + ollama selectable
- [ ] P2 `serve` real HTTP API (+SSE endpoint scaffold)
- [ ] P3 subagent tool works end-to-end offline (fake model test)
- [ ] P4 workflow engine (sequential+DAG, validated)
- [ ] P5 MCP stdio client bridges remote tools into registry
- [ ] P6 plugin ABI loads native dylib tools
- [ ] P7 presets selectable via CLI
- [ ] P8 structured event envelopes persisted to JSONL log
- [ ] P9 web_fetch/web_search tools registered
- [ ] P10 docs current, full suite green, zero leaks

Remaining ≤5% (explicitly out of scope now): L2 WASM sandbox (needs zcordis
wasm runtime exposure), production hardening/fuzz, real browser UI (per
dev.md §XXII UI lives outside zharness; serve API is our contract surface).
