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

---

# Wave 4 — close the final 5% (+ Web UI)

Same ground rules as above. Ownership this round:

| Agent | Owns (exclusive) |
|-------|------------------|
| H-wasm | `sandbox/wasm.zig`, `pluginabi/wasm_loader.zig`, `_t_wasm.zig` |
| I-sse | `server/events.zig`, `server/api.zig`, `obs.zig` (additive only), `_t_sse.zig` |
| J-fuzz | `fuzz/*.zig`, `_t_fuzz.zig`; bug-fix reports for other files |
| K-webui | `web/**`, `docs/web.md`, `server/static.zig`, `_t_static.zig` |

Integrator keeps: `main.zig`, `agent/agent.zig`, `tests.zig`, `builtin.zig`,
`config.zig`, `model/model.zig`.

## Task specs

### H-wasm — L2 WASM sandbox (dev.md §XII)
Kernel: `../zcordis/src/abi/wasm.zig` (`Module.load`, `Instance` w/
`step_budget` + `setStepBudget`, `callExport(name, []const i64) !i64`,
host memory access). Build the WASM twin of pluginabi/capi:
- `pluginabi/wasm_loader.zig`: load `.wasm` files from
  `~/.zharness/plugins-wasm` + workspace `plugins-wasm/`. WASM ABI v1
  (documented in-file): required exports `memory`, `zh_abi_version() -> i64`
  (== 1), `zh_manifest() -> i64` (packed ptr<<32|len into linear memory,
  UTF-8 JSON identical shape to the C ABI manifest), `zh_tool_call(name_ptr:
  i64, name_len: i64, args_ptr: i64, args_len: i64) -> i64` (same packing;
  result JSON written by the module INTO its own memory before returning).
  Host reads results through the `memory` export. NULL-equivalent (len==0)
  means failure.
- `sandbox/wasm.zig`: hardening wrapper — per-instance step budget
  (default 10M), memory growth cap, fuel/gas style deadline check, deny
  imports beyond a minimal allowlist (`env.*` none or whitelisted fns),
  malformed module -> clean error never crash.
- Loader projects tools into registry naming `w_<module>_<tool>`.
- Tests: hand-assembled minimal wasm modules (see zcordis abi tests for
  byte-level module fixtures you can copy) covering: happy call, bad version,
  truncated module, budget exhaustion, oversized memory request.

### I-sse — live event feed on /events (dev.md §XXX)
- `server/events.zig`: broadcast hub — subscribe(handle) -> ring buffer of
  last N envelopes + live tail; publish(envelope_json); bounded queue,
  slow-subscriber drop policy (oldest-first), thread-safe if httpd runs
  threaded_connections, else document single-thread contract.
- `obs.zig`: ADDITIVE — optional fan-out hook (fn pointer set post-init);
  existing pub API must not break (main.zig calls emitAt already).
- `server/api.zig`: replace the /events heartbeat stub: when the hub is
  installed (module-level install fn), stream real envelopes as SSE `data:`
  lines; fall back to heartbeats when no hub. Keep ServerDeps unchanged.
- Contract for integrator: one `events.hub.publish` call inside main's
  obsEmit path (I will wire it).

### J-fuzz — production hardening (dev.md §XXXIV-adjacent)
- `fuzz/`: corpus-driven robustness suites over every parser surface:
  model JSON helpers (findMatchingBrace/escape/unescape), jsonrpc codec,
  mcp framing, httpd request parsing, workflow parser, skill front-matter,
  sse parser, checkpoint/session loaders, pluginabi manifest parser,
  events envelope parser.
  Method: structured mutators over seed corpora checked into `fuzz/corpus/`;
  each case must error cleanly or round-trip, NEVER crash/leak/hang (guard
  with iteration caps). If std.testing.fuzz is available and stable on this
  toolchain add entry points behind a build option; suite must stay green
  without fuzzing enabled.
- Any bug found in another agent's file: MINIMAL fix allowed ONLY in files
  outside {H,I,K} owned sets this round; otherwise file a report entry.

### K-webui — Web UI reusing deepseek-harness design language
Recon verdict (integrator-verified): `_ref/deepseek-harness` apps/web is a
heavy React18/pnpm client (packages/client/**, 252+ tsx). Adopting the
toolchain contradicts zharness zero-dep ethos. REUSE STRATEGY: extract the
design language, not the framework.
- Read `_ref/deepseek-harness/packages/client/ui-theme/src/**` (tokens, css
  vars) + ui-conversation css modules for spacing/type/color language.
- Build `web/`: ZERO-BUILD vanilla HTML/CSS/JS chat client (single index.html
  + app.js + styles.css, no imports map, no CDN) implementing:
  POST /run (streaming text via polling or /events when available), session
  picker (GET /sessions), transcript rendering, tool-call badges, composer
  with stop-less UX, health indicator. Match deepseek theme: dark palette,
  type scale, radii, spacing rhythm extracted from their tokens.
- `server/static.zig`: HandlerFn-compatible static file server
  (GET / -> index.html, /assets/* from `<cwd>/web`, content-type map,
  path-traversal guard, size cap). Document the one-line api.handle splice
  needed (integrator applies it).
- `docs/web.md`: what was reused (token mapping table) vs reimplemented.

---

# Wave 6 — full GUI feature parity (Tiers 1+2+3, 14 packages)

Ground rules: same as wave 4/5. Integrator owns main.zig + router.zig
dispatch splices EXCEPT where a row grants router.zig explicitly.

## Ownership

| Agent | Owns |
|-------|------|
| V-vendor | webui/** (all 14 package vendoring + single rebuild chain + roster) |
| G1-tier1 | router.zig, apiproxy/{goals_rpc,skills_rpc,models_rpc,presets_rpc,perms_rpc}.zig |
| G2-sessions | apiproxy/{search_rpc,export_rpc,subagents_rpc}.zig, sessions.zig (additive) |
| G3-interactive | tool/ask_user.zig, apiproxy/questions.zig |
| G4-views | apiproxy/{plan_frames,jobs_rpc,trajectory,wf_replay}.zig |
| H-image | model/model.zig (additive content-parts), model/anthropic.zig (additive), tool/attachments.zig (new) |

## Task specs (contract truth: docs/dsh-reuse-spec.md §4 + upstream zod schemas)

- V-vendor: vendor ui-{goal,skill,model-selection,agent-preset,permission-presets,subagent,plan,trajectory,user-questions,jobs,workflow-run,commands,message-feedback,reference} as available (skip hmr/directory-picker-native/deliverables); roster += all that build; ONE rebuild chain; link+inject. Report per-package build status.
- G1-tier1: goals.{edit,clear,pause,resume,list} over a NEW process-global goal store (goals_store pattern; report the one-line main.zig hook so buildLoop's GoalBoard shares it); skills.list over a fresh SkillRegistry disk scan; sessions.models/selectModel + llm.providers over the provider matrix (selectModel persists via SettingsStore llm-deepseek ns); agentPresets.list/select over presets.zig (select persists per-session via settings or config); permission presets mapping sandbox_mode (native/process/none ↔ upstream permission levels).
- G2-sessions: session.search (grep transcripts, snippet+score); session export (upstream session-export shape → GET download); subagents registry (process-global log of spawn_agent runs: id/parent/status/summary; subagent.list/openSubagent shapes; spawn-side hook reported for integrator).
- G3-interactive: ask_user tool (agent asks; publishes question/requested frame; waits with timeout → cancelled answer); /api/respond full flow (resolve pending by questionRpcId); questions state file with SpinLock (events_ws pattern).
- G4-views: plan frames (plan board state → session/projection or plan event frames; report emit-point contract); jobs (workflow runs + background tasks as jobs list); trajectory (aggregate obs/checkpoints into upstream trajectory views — recon exact shape first); workflow-run replay (read .zharness/runs/*.json → upstream workflow-run view shapes).
- H-image: accept image content parts end-to-end: IR ContentBlock image support (openai_chat image_url + anthropic image source blocks), promptSession no longer rejects them (persist to .zharness/attachments/, reference by path in text context for non-vision providers), additive only.

## Integration (wave B, integrator)
Router dispatch lines for G2/G3/G4 handlers; main.zig hooks (goals store share, subagent log, ask_user emit); roster already done by V; full gates; smokes; commits.
