# Dynamic Cordis Runtime — P3 Spec

Status: IMPLEMENTED. `src/dynamic/{types,registry,sandbox,lifecycle,wire,preset_tools}.zig` realizes this spec; the server half is dispatched by `src/server/apiproxy/router.zig` (`dynamic.getClientCode`, `dynamic.invoke`, the cordis leg of `/api/respond`) and the model-facing `cordis_*` tools are wired into the agent loop by `src/main.zig` (registerExtensionTools + the `sharedDynamicLifecycle` wiring slot). Reference design source of truth: `_ref/deepseek-harness/packages/extensions/{tool-cordis,cordis-host-runner,cordis-client-runner}` (READMEs + `src/*`). Verified in this checkout 2026-08-24. `ABI v1` (`src/pluginabi/capi.zig`, `ffi.zig`, `loader.zig`, `wasm_loader.zig`, `docs/plugins.md`) stays narrow and is not broadened to imitate this.

---

## 1. Goals / non-goals vs ABI v1

**Goals (dynamic runtime):** model-defines JS plugin halves at runtime, runs a host half in a cooperative sandbox, delivers a browser half to every open page, versions immutably, requires human approval for client-affecting packages, reports diagnostics, and cleans up on stop/undefine. Stateful, session-scoped, process-volatile.

**ABI v1 stays (non-goals for this spec):**

- Native discovery `~/.zharness/plugins` + `<workspace>/plugins` (`*.so`/`*.dylib`), sorted, dlopen `RTLD_NOW|RTLD_LOCAL`, 4-symbol contract (`zh_plugin_abi_version==1`, `zh_plugin_manifest` static JSON, `zh_tool_execute(tool,args)->malloc JSON or NULL`, `zh_string_free`), copy-before-free, `p_<plugin>_<tool>` sanitized namespace, skip-report never panic (`docs/plugins.md:16`, `src/pluginabi/capi.zig:64`, `loader.zig:91`).
- WASM discovery `plugins-wasm` (`*.wasm`), `hasMemoryExport` scan, `EXP_*` signature gate (`() -> i64` / `(i64,i64,i64,i64)->i64`), packed `ptr<<32|len` transport, 64 KiB reused scratch window, `w_<module>_<tool>` namespace, `Limits` step budget / 256-page cap (`src/pluginabi/wasm_loader.zig:6,74,367`).
- No lifecycle hooks, no `init/start/stop`, no IPC, no approval, no revisions, no browser half. ABI v1 file-system plugins remain the durable, operator-installed path.
- This spec does not add symbols, hooks, or manifest fields to ABI v1 and does not make `PluginRegistry`/`WasmRegistry` speak dynamic package ids.

**Dynamic runtime non-goals (phase-bound):**

- Persisting dynamic packages to disk or session JSON; promoting to a file plugin; `!js` in `cordis.yml`; cross-process migration; hot-reload of ABI plugins.
- True security isolation — same cooperative stance as DSH: host-realm helpers make escape possible; treat like `bash` (`tool-cordis/README.md:21`, `cordis-host-runner/README.md:29`, `sandbox.ts:7`).
- Slot allow/deny per deployment, workspace-scoped sharing, multi-agent fan-out (see §7).

---

## 2. Decision matrix — execution for the host half

zharness is Zig 0.17 + `zcordis` (`docs/architecture.md:21`). DSH host half runs as an `async () => { code }` body in `node:vm` (`cordis-host-runner/src/sandbox.ts:254`, `precheckCode:212`). Three options evaluated for zharness:

| Dimension | A. Native in-process (reuse ABI v1) | B. WASM (reuse `wasm_loader.zig`) | C. JS closure in child Node `vm` (DSH twin) |
|---|---|---|---|
| Language | Zig/C/Rust/Go -> `.so/.dylib` | `wat`/`wasm` MVP | plain JS function body returning a Cordis plugin |
| Isolation | none — segfault downs host (`docs/plugins.md:170`) | `sandbox.Limits` step + memory cap, imports denied, scratch copy-out (`wasm_loader.zig:59,649`) | `node:vm` context per package, tagged console, timer/network traps, but `host-realm helpers` escape remains (`sandbox.ts:7,84`) |
| Teachability | dlopen error text only | trap/budget diagnostics | syntax precheck with line+caret + TS-removal hint (`sandbox.ts:162,179`) |
| Browser half | none | none | symmetric `clientCode` string evaluated in page closure |
| Startup | dlopen+resolve+manifest | load+sig gate+version+manifest | compile-only precheck at `define`, evaluate at `run` |
| Use for dynamic | rejected — breaks "model writes code now" latency and safety | rejected as primary — useful for untrusted compute toys but cannot express `ctx.on/provide/tools`; keep for `w_*` tools only | **chosen for dynamic runtime** — matches DSH surface the model is taught, instant iteration, same guard idioms |

**Decision:** Dynamic host halves use **C (Node child) + resource caps**, not native dlopen nor WASM. Native and WASM stay as they are for installed plugins. If Zig ever embeds `quickjs`/`boa`, replace the Node child with in-process evaluator under the same `sandbox.ts` contract; the wire and lifecycle are unchanged.

Consequence for zharness: `cordis-host-runner` owns a short-lived `node --input-type=module` child per package *or* a pooled worker. Host Zig spawns, pipes `code` + `vmTimeoutMs` (sync bound 5000 ms default, `cordis-host-runner/README.md:37`), reads back `provide`/`tools` registrations via JSON, and tears down the fiber on stop. No ABI v1 file touches disk.

---

## 3. Service facade allowlist

Twin of DSH `guard.ts` / `client/guard.ts`. Both halves share the rule set; the two proxy implementations stay separate because each tests `instanceof Context` of its own realm (`guard.ts:663`).

**`ctx` verbs (lifecycle-safe, fiber effects, unwind on `dispose`):**

`effect`, `on`, `once`, `provide`, `timeout`, `interval`, `setTimeout`, `setInterval`, `throttle`, `debounce` — `CTX_VERBS` (`sandbox.ts:37`, `cordis-host-runner/src/guard.ts:636`). Timer verbs additionally require `inject: ['timer']` or they throw the `TIMER_REDIRECT` teaching error.

**`harness` (host only, never in browser closure — `harnessTrap`):**

`harness.handle(method, handler)`, `harness.defineTool(def)`, `harness.registerTool(ctx, tool)` (`sandbox.ts:30`, `guard.ts:31,603`). `defineTool` parameters are normalized via `normalizeParameterSchemaSpec` (raw wrapper vs DSL, `required` mapping, `additionalProperties` openness) and cloned cross-realm with `cloneJson` (`guard.ts:99,213`). `registerTool` accepts only `DYNAMIC_TOOL`-marked defs (`guard.ts:497`).

**`tools` seat:** `register` (marker-guarded), `schemas()` (scope-aware `ctx.tools.schemas(scopeOf(ctx))`), `get(name)` returns schema view not the live `execute` (`guard.ts:648`).

**`ctx.get(name)` vs `ctx.<name>`:** `ctx.get` is optional lookup; property access requires declaration in the plugin's `inject` (object or array form collapsed to `fiber.inject` keys, `guard.ts:709`). Undeclared but existing service → "not injected, declare `inject: ['x']`" ; withheld framework key → "does not expose `root/fiber/registry/extend/plugin`" (`guard.ts:729,781`).

**Denied:** `ctx` values returned by any injected service (`denyContext` → fail loud, `guard.ts:669,684`), writes to facade (`set` trap), `globalThis` persistence (write-through console only), `require`/`fetch`/`process`/`Buffer` (traps with redirects `NODE_API_REDIRECTS`, `DYNAMIC_CLIENT_REDIRECTS`), raw `ctx.tools` definitions (no `execute` escape).

**zharness allowlist (maps to existing services):**

- Always: `tools`, `events` (cordis `EventBus`), `session` (append-only log, title projection), `config` (read-only view), `workspace` (cwd), `memory` (KV scratchpad), `skill` (read-only).
- Opt-in via `inject`: `timer`, `fs` (policy-gated), `web` (fetch/search), `shell`/`subprocess` (sandbox-gated), `slots`/`theme` (browser only), `connection` (presence).
- Withheld: `cordis` internals (`root`, `fiber`, `registry`, `loader`, `scope`), raw `Agent`/`Session`, provider secrets.

`ctx.get` existence is topology-sensitive; tests must assert through the executor, not schema omission.

---

## 4. Approval flow

Mirrors `cordis-host-runner/README.md:11` and `types.ts:143` (`DynamicCordisPendingRequest`, `ApprovalRequestId`, `RequestRunOutcome`).

```
define ──► run(mode=run|update) ──► requiresApproval?
                                    ├─ no (host-only): runHostHalf → starting → running
                                    └─ yes (has client half, not yet granted):
                                         emit cordis/request-run {requestId, agentId, pluginId, packageId, mode, name, purpose}
                                         suspend; tool returns {status:'awaiting-approval', requestId}
                                         ─► Browser page answers approve(requestId) | decline(requestId)
                                            → resolveRequestRun {requestId, outcome:'approved'|'rejected'|'failed'}
                                            → broadcast cordis/request-run-resolved so other pages drop affordance
                                         ─► first answer wins; late/unknown → {accepted:false} ignored
                                         ─► stale revision (registry moved) → {accepted:false}, request stays suspended
                                         ─► AbortSignal (model turn cancelled) → outcome 'cancelled', disarmRequest, broadcast
```

- Only `cordis_run` creates the pending request; `define` never crosses the wire.
- `runHostHalf` is idempotent per `(pluginId, packageId, pluginRunId)` and serialized per plugin (queue per id); concurrent calls for same package coalesce, `startedHere` names the winner (`cordis-host-runner/README.md:14`).
- `getClientCode` is the only way code reaches the browser — never in the announcement.
- Host-only packages never suspend for a page; they resolve synchronously or with `host-half-failed`.

**zharness transport mapping:** four forwarded events are the api-remotes allowlist (`cordis-host-runner/README.md:24`, `cordis-client-runner/README.md:5`):

`cordis/request-run` (approval), `cordis/request-run-resolved`, `dynamicCordisRunner/package` `{id,name,rev}`, `dynamicCordisRunner/retract` `{id,rev}`.

A deployment with no page connected suspends until cancelled — headless/ACP auto-approval is future work, not v1.

---

## 5. Revisioning

Stable instance + immutable versions, lifted from `cordis-host-runner/src/registry.ts:51,72` and `tool-cordis/src/index.ts:149,240`.

```
Plugin  ::=  pluginId = "<prefix>-<n>"   // prefix = [a-z]{3,6} proposed by model, host mints suffix, monotonic, never reused
Package ::=  packageId = "pkg-<n>"       // immutable source version, define order
Run     ::=  pluginRunId = "run-<n>"     // exact activation identity

Plugin { pluginId, sessionId, packages: Map<packageId, {name,purpose,hostCode?,clientCode?}>,
         approvedClientPackages: Set<packageId>,
         clientVersionUpdatesApproved: bool,
         currentPackageId?, nextPackageId?, run?, latestRun? }
latestRun: DynamicCordisRunAttempt { pluginRunId, packageId, mode, status, approvalRequestId?, requiresApproval?, host, client, error? }
status: awaiting-approval | starting-host | client-pending | running | waiting | rejected | failed | cancelled | stopped
host/client half: { status: absent|pending|stopped|running|waiting|failed, waitingFor: string[], error? }
```

Rules:

- `cordis_define` with `plugin:{kind:'new', idPrefix}` mints `pluginId` + `pkg-1`; with `kind:'existing', pluginId` appends `pkg-N` to that plugin (ownership check). At least one half required. Both halves are syntax-prechecked (`precheckCode` via `new Function` + `vm.Script` caret, `sandbox.ts:212`) before an id is minted — unparseable input never enters the registry.
- `cordis_run {pluginId, packageId, mode:'run'|'update'}` validates mode vs `currentPackageId` (`run` = first/restart/rollback, `update` = switch from current). `currentPackageId` moves only on complete success; failures set `nextPackageId` and preserve `error` diagnostics. `cordis_stop` disposes `fiber` + handlers + retract broadcast but retains all packages and pointers (idempotent). `cordis_undefine` stops then deletes all packages/grants — `@pluginId` becomes "Plugin removed".
- Browser convergence by `(pluginId, rev)`; re-delivering a running package re-binds live version (page reload recovery) rather than failing (`tool-cordis/README.md:13`, `cordis-client-runner/src/client/runtime.ts:288`). `nextPriority--` for slot shadowing, newer run wins.
- `renderFailure` is stored twice with different lifetimes: host keeps last per definition across pages for the model (`reportRenderFailure` fire-and-forget, no settle authority); page keeps last per definition for its own row (`renderFailures` per `cordis-client-runner/src/client/runtime.ts:228`). A fresh `run`/`stop`/`undefine` clears the host copy.

---

## 6. Persistence — session vs process

**Decision: session-scoped visibility, process-local durability.** Matches DSH `tool-cordis/README.md:19` and `cordis-host-runner/README.md:26`.

- Registry lives in the DSH/zharness process heap; no write to `.zharness/sessions/<id>.json`, `cordis.yml`, or disk plugins. The session log carries only `cordis_define` metadata (`name`, `purpose`, `pluginId`, `packageId`) — never source — so a restarted process legitimately has no definitions and a card renders "unloaded/Plugin removed" rather than pretending it can run.
- Acting verbs are ownership-checked: a definition is visible and controllable only in the session that defined it (`sessionId` on `DynamicCordisPlugin`). `inventory`/`listPlugins` reads global rows with `agentId` for display, but `run/stop/undefine` still enforce owner. Cross-session leakage reads as absent, not forbidden. `invoke`/`resolveRequestRun` carry no session — they are page-global facts.
- `keepAlive`/`projections` are not persisted; reload discards them. "Keep an experiment" path is explicit: operator promotes the package to a durable plugin via the normal file workflow (new `plugins/*.so` or `plugins-wasm/*.wasm` build), not an automatic promotion flag.

zharness extension: the `session/checkpoint.zig` turn boundary should snapshot the dynamic plugin table per session (seq 0-based) in memory only, pruned when the session ends; the on-disk session file remains tool-call history only.

---

## 7. Browser transport — WebSocket vs postMessage

**Decision: WebSocket (existing `POST /api/*` + `/api/events.mux` downlink), not `postMessage`.** Verified in `docs/dsh-reuse-spec.md:4,12` (`POST /api/<method>` with `client-request` envelope, two WS GETs upgraded by browser carrier `connection/src/client/web-api-client.ts`).

- `cordis/request-run` / `cordis/request-run-resolved` / `dynamicCordisRunner/package` / `retract` ride as `ServerRequest` JSON frames on `/api/events.mux` (and `events.host` for status) plus the `events.jsonl` append path (`docs/architecture.md:135`, `dsh-reuse-spec.md:13`). Mutations are buffered live-stream events stitched by `seq`; reconnect uses `session/subscribed {sessionId,lastSeq}` + `host/session-status`.
- `cordis_inspect_query` for a Client provider waits for the first valid page response on the same mux (tool-cordis `cordis_inspect_query` description). `invoke` (package-internal RPC `host.call -> harness.handle`) is a unary `POST /api/dynamic.invoke {pluginId, pluginRunId, method, args}` returning `{ok,value}` or `{code,message}` (`types.ts:356`); no host-to-browser direction exists.
- `reportRenderFailure` is a separate fire-and-forget unary (`POST /api/dynamic.reportRenderFailure`), never a run settlement.

`postMessage` is rejected for this path: it requires a same-origin iframe/window handle, cannot fan out to every open tab without a SharedWorker bridge, and would bypass the session `seq`/`connection` generation and the typert `IApiClient` envelope that every other feature already speaks. `postMessage` remains valid only inside a loaded browser half's own iframe sandbox, not for host↔browser orchestration.

---

## 8. Security boundary — host-realm helpers

Restate `sandbox.ts:7`, `guard.ts:14`, `tool-cordis/README.md:21`.

- Globals are isolated per `createSandbox`/`evaluateClientHalf` (`btoa/atob/TextEncoder/Decoder` supplied, `console` is tagged write-through, `process`/`Buffer` are `undefined` so `typeof process` probes stay safe). Dual-realm `instanceof` is patched for `Object/Array/Function/Error/Promise/RegExp/Date/Map/Set` (`sandbox.ts:62`).
- Withheld Node/browser APIs trap with teaching redirects (`NODE_API_REDIRECTS`, `DYNAMIC_CLIENT_REDIRECTS`: `require`, `fetch`, `setTimeout`/`setInterval`/`clear*`/`setImmediate` → redirect to `ctx.fs/web/bash/timer` or `host.call`). `console.log` is the only freeform host I/O; `console.error` additionally mirrors into the load report slice (500 chars, `evaluator.ts:130`).
- Escapes remain: any `host-realm helper` reachable from the sandbox (real service method, `ctx` verb, `harness` helper) is Node-capable; `guardedService` only denies `Context`-valued returns and proxies method application so effects land on the calling fiber (`guard.ts:70,196,317`). Mounted plugins receive a façade without framework internals, yet allowed services affect the live runtime (`session`, `fs`, `web`, `bash`). Treat as `bash` grant.

Enforcement posture:

- Enforce in the operation that makes it: schema omission / prompt filtering is not a boundary; test denial through the executor.
- Apply bounds where the complete value is known: `default_max_result_bytes` 4 MiB, `client` slot catalog budget, `RETURN_PREVIEW_LIMIT` 120, `cloneJson` depth/width bounded by iterative stacks (no recursion bomb, `guard.ts:93,293,330`).

---

## 9. Concrete file / interface sketches (no implementation)

**Host Zig (new under `src/dynamic/`):**

```
src/dynamic/
  registry.zig   // DynamicRegistry { plugins: Map<PluginId, Plugin>, next: {plugin,package,run,approval} }
                 //   define(sessionId, plugin{p.new|existing}, name, purpose, code{host?,client?}) -> DefineReceipt
                 //   run(agent, pluginId, packageId, mode, signal) -> RunReceipt  (arming + WebSocket broadcast)
                 //   stop(agent, pluginId) / undefine(agent, pluginId) / listPlugins(agent) / inspect*(...)
                 //   peekManifest, snapshot, inventory (global), reference(agent, pluginId) for @-mentions
  sandbox.zig    // precheckCode(half, code) — new Function gate + Script caret prelude
                 //   createSandbox(id, harnessExtras) -> vm Context; evaluateHostCode(sandbox, code, id, timeout)
                 //   guardedPlugin, denyContext, sandboxContext facade helpers (Zig port of guard.ts verbs)
  lifecycle.zig  // startHostHalf(groupFiber, plugin) -> Fiber  (await group, guard, await fiber, dispose on fail)
                 //   missingServices(ctx, fiber) -> []string
  wire.zig       // WS envelopes + RPC maps for cordis/* and dynamic invoke/report, seq handling, generation handshake
```

Key types (Zig sketch, branded strings):

```zig
pub const PluginId = []const u8;   // "<prefix>-<n>"
pub const PackageId = []const u8;  // "pkg-<n>"
pub const RunId = []const u8;      // "run-<n>"
pub const ApprovalId = []const u8; // "approval-<n>"
pub const RunMode = enum { run, update };
pub const RunStatus = enum { awaiting_approval, starting_host, client_pending, running, waiting, rejected, failed, cancelled, stopped };
pub const HalfState = struct { status: enum { absent, pending, stopped, running, waiting, failed }, waitingFor: []const []const u8, err: ?[]const u8 };

// Mirrors registry.ts:51
pub const Plugin = struct {
    plugin_id: PluginId, session_id: SessionId,
    packages: std.StringHashMap(Package),
    approved_client_packages: std.StringHashMap(void),
    client_version_updates_approved: bool,
    current_package_id: ?PackageId, next_package_id: ?PackageId,
    run: ?Run, latest_run: ?RunAttempt,
};
pub const DefineRequest = struct { session_id: SessionId, plugin: union(enum){ new: struct{ idPrefix: []const u8 }, existing: PluginId }, name: []const u8, purpose: []const u8, code: struct{ host: ?[]const u8, client: ?[]const u8 } };
pub const DefineReceipt = struct { plugin_id: PluginId, package_id: PackageId, name: []const u8, purpose: []const u8, has_host: bool, has_client: bool };
```

Host config (validates like every other plugin, no `DEFAULT_*` constant):

```zig
pub const DynamicConfig = struct {
    vmTimeoutMs: u32 = 5000,          // sync bound for host half (cordis-host-runner README:37)
    maxClientSourceBytes: u32 = 256_000,
    maxInvokeBytes: u32 = 64_000,
    // no approval timeout — AbortSignal is the only exit (cordis-host-runner README:12)
};
```

**Web client (new `web/dynamic/` — mirrors `cordis-client-runner/src/client/`):**

```
web/dynamic/
  evaluator.ts  // evaluateClientHalf(pluginId, code, {invoke, noteError}, styles) -> Plugin
                //   closure params: React, console(tagged), styles, host{call}, harness(trap), setTimeout/fetch/require traps, process/Buffer undefined
                //   DYNAMIC_CLIENT_REDIRECTS; DynamicCordisStyles { insert(css)->dispose, count }
  guard.ts      // dynamicCordisContext(ctx, {pkg, ledger, claim, allocatePriority, reportFailure}) -> Context facade
                //   guardedSlots (priority--, ledger, claim(component)), guardedTheme (source pinned to pkg id), denyContext
  runtime.ts    // DynamicCordisPackageRunner { live: Map<PluginId, Live>, queues per id, owners WeakMap<object,{pluginId,runId,agentId}>, failures }
                //   load(half)->LoadResult, retract(id,runId), isLoaded(id), subscribe(fn), renderFailures observable
                //   slots.onEntryError -> reportRenderFailure(agentId,pluginId,runId,{slot,message,abdicated}) + page map
  orchestrator.ts // cordis/request-run subscription → approve/decline/startUserRun, runHostHalf→getClientCode→load order, stale-rev handling
  boot.ts       // ctx.remote.$on allowlist for the four events + dynamic.invoke/reportRemote, loader wiring
```

Wire types (share with host, mirror `cordis-host-runner/src/types.ts:176`):

```ts
type ApprovalRequestId = Branded<'ApprovalRequestId'>;
type CordisDynamicPluginId = Branded<'CordisDynamicPluginId'>;
interface DynamicCordisRunRequest { requestId: ApprovalRequestId; agentId: SessionId; pluginId: CordisDynamicPluginId; packageId: CordisDynamicPackageId; mode:'run'|'update'; name:string; purpose:string; requiresApproval:boolean; }
interface DynamicCordisRequestResolved { requestId: ApprovalRequestId; outcome: RequestRunOutcome; } // approved|completed|rejected|cancelled|failed
interface DynamicCordisPackage { pluginId, packageId, pluginRunId, name }
interface DynamicCordisClientSource { code:string; name:string; pluginId, packageId, pluginRunId }
```

**Tools (new `src/tool/cordis.zig` + web slots, mirror `tool-cordis/src/index.ts:28` `inject: [tools, systemPrompt, dynamicCordisRunner, cordisInspect]`):**

- `cordis_inspect_list` / `cordis_inspect_query {platform:host|client, provider, method, input?}` (client query waits for first page answer, cancellable) — `tool-cordis/src/index.ts:42,60`.
- `cordis_inspect_self {pluginId?, packageId?}` (layered: list → plugin → package source+diagnostics, `packageId` requires `pluginId`).

> **zharness status.** `cordis_inspect` was zharness's original name; it now
aliases `cordis_inspect_list`. zharness has no host/client Inspect provider
registry, so `cordis_inspect_query` keys on `{pluginId}` and returns that
plugin's packages and live status, and `cordis_inspect_self` reports the
calling session id plus its plugin count — a pragmatic subset of the
platform/provider/method contract above.
- `cordis_define {plugin:{kind:new{idPrefix:[a-z]{3,6}} | existing{pluginId}}, name, purpose, code:{host?,client?}}` — syntax-only, returns `{pluginId, packageId, hasHostHalf, hasClientHalf}` with presentationMeta.
- `cordis_run {pluginId, packageId, mode:run|update}` — returns `{status:awaiting-approval|starting|running, pluginRunId, waitingFor?, clientWaitingFor?, currentPackageId?, nextPackageId?}`.
- `cordis_stop {pluginId}` idempotent, `cordis_undefine {pluginId}` destructive.
- `present*` and prompt section `tool:cordis` are pure functions of args.

No `abiVersion` change, no new `hostToolName` prefix — tools stay as listed above, not `p_*`/`w_*`.

---

## 10. Verification before build

- `zig test src/pluginabi/loader.zig src/pluginabi/wasm_loader.zig` stays green — no ABI v1 regression.
- Define refusal fixtures: `as`-annotation TypeScript, missing `return`, `});` bracket trap, non-plain `host` payload (prototype pollution) — each yields the teaching text from `sandbox.ts:185,192` and `guard.ts:123,449`.
- Lifecycle coverage: host-only `run->running->stop` (sync), client-bearing `run->awaiting-approval->approve->starting->client-pending->running->retract` over a loopback WS, stale-rev `accepted:false` stays suspended, concurrent `run` coalesces to one `startedHere=true`.
- `verify-package-invariants` after wiring: dynamic registry is process-local, not a service-presence check; empty inventories carry `No runtime invariant:` doc.
- Manual: reload browser tab, re-`cordis_run` same `(pluginId, packageId)` → re-delivers live version without re-evaluation (converges by `pluginRunId`).

---

## 11. Open questions (resolve before coding — no broadening of ABI v1 until answered)

1) JS runner process model: pooled Node worker vs per-run child — measure `vmTimeoutMs` enforcement + `console` tagging + `Buffer` closure semantics under each.
2) API scope for zharness `ctx` services: finalize `fs`/`shell` policy strings and whether `theme`/`slots` need real `settingsScope` wiring or remain stubs until `dsh-reuse-spec.md:6` Phase 6.
3) Inspect catalog generation: `tsdown` path vs reusing `_ref` prebuilt `lib/client.js` — impacts `verify-client-catalog` freshness gate placement.
