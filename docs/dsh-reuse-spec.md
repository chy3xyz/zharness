# Reusing the deepseek-harness Web GUI in zharness — Definitive Spec

Status: recon deliverable (read-only analysis of `_ref/deepseek-harness/`, MIT).
Scope: decide the smallest viable path to put that React GUI in front of the
Zig backend, and spec exactly what zharness must build.

Everything below was verified against source in this checkout. File paths are
relative to `_ref/deepseek-harness/` unless prefixed `src/` or `web/`
(zharness's own tree).

---

## 1. Verdict

**Recommendation: Option A — vendored frontend boots nearly unmodified;
zharness implements a minimal `/api` apiproxy subset in Zig.**

Concretely:

- Vendor (already present as `_ref/deepseek-harness`) and build its frontend
  with its own toolchain (Node 24 + pnpm). Ship the **built artifacts**
  (`apps/web/dist` + one `lib/client.js` per client plugin) inside zharness.
- Trim the browser plugin roster from ~40 rows to **15** (§5.1) by serving
  zharness's own boot manifest — the architecture explicitly supports this:
  the host composes `window.__DSH_BOOT__` (`packages/client/modules/src/client/manifest.ts`,
  `WebBootGraph`), and the web shell hard-fails only entries listed in the
  manifest (`boot.ts::assertEntriesActive`). Not listing a plugin is the
  supported degradation mechanism.
- Implement in Zig: the four-quadrant RPC envelope over `POST /api/<method>`
  for **13 unary methods**, two WebSocket downlinks (`/api/events.mux`,
  `/api/events.host`), an append-only session event log, and an agent-loop →
  SessionEvent bridge. Estimated **~2,900–4,300 LOC Zig**, ~20 half-day
  agent-tasks (§6).

Why not B / C:

- **B (thin custom shell importing vendored ui-\* components) is dominated by
  A.** The feature packages (ui-layout, ui-sidebar, ui-conversation) do not
  ship importable components: their `./client` export is a tsdown
  *closure-factory* bundle that registers into `window.__ModuleLoader__`
  (`packages/client/tsdown.client.ts`) — not an ES module a standalone Vite
  app can import. Importing them via the `./src/*` subpath pulls in the whole
  slot framework and the runtime object layer as *values*: ChatView reads
  `useSession(s => s.chat.order | .nodes | .timeline | .queue | .running |
  .openState | .hasMore | .loadingOlder)` — a snapshot produced by
  `SessionManager`/`Session`/`ConversationNodeAssembler` (~9,000 LOC,
  `packages/client/runtime/src/client/sessions/*`). Reimplementing that
  object layer to feed hand-picked components is strictly more work than
  implementing the wire protocol they already speak, and forks us from
  upstream forever.
- **C adds nothing A lacks.** The genuinely useful "hybrid" tactics are
  already available *inside* A at zero extra cost:
  - keep the existing vanilla `web/index.html` UI as a fallback page until
    the React shell boots (zharness already serves it);
  - frontend development against `?fixture` mode — the connection plugin
    swaps in a fully in-browser mock carrier when the page URL carries
    `?fixture` (`packages/client/connection/src/client/index.ts`,
    `FixtureApiClient`), no Zig server needed;
  - optional later phase: mount additional upstream plugins (trajectory view,
    model selection) by adding manifest rows + methods, without touching
    vendored code.

The decisive architectural facts (all verified):

1. Components are pure props. `ChatView` takes everything through the four
   shares (`PropsRuntime & PropsRenderSlots & PropsStore & InjectFace`,
   `ui-conversation/src/client/contract/slots.ts`); business components never
   touch ctx or contexts (`packages/client/AGENTS.md`, layering red lines).
2. All wire calls funnel through ONE interface: `IApiClient`
   (`packages/host/apiproxy/src/fetch/client.ts`). The protocol surface is
   small, closed, and zod-documented.
3. The transport is plain HTTP POST + two WebSocket GETs with JSON frames —
   no cookies, no auth handshake, no binary codecs.
4. Missing server features degrade gracefully where it matters: absent tool
   `view` → generic JSON card; absent projections → cwd-basename titles;
   absent queue/approval/jobs frames → empty surfaces; settings read failure
   → idle/retry mirror. Hard-fails happen only for entries actually listed in
   the manifest waiting on services we also control via the manifest.

---

## 2. Boot chain (research item 1)

Chain: `apps/web/src/main.ts` → `AppWebEntry` (`packages/client/web/src/boot.ts`)
→ module system (`packages/client/modules`) → cordis Loader → plugin tree →
`ctx.inject(['uiRenderer'])` mounts into `#root`.

Step by step:

1. Host serves `index.html` with three head injections composed by
   `bootInjections()` (`packages/client/modules/src/index.ts`):
   1. inline script installing the `window.__ModuleLoader__` **queue facade**
      (buffers `load({id, factory})` registrations until the module system
      boots);
   2. `<script src="/plugins/@deepseek-ai/dsh-client-modules/client.js?rev=…">`
      (and `dsh-client-runtime/client.js` — `PARSER_PRELOAD_IDS`);
   3. `window.__DSH_BOOT__ = { rev, entries: [{id, url, rev, inject?,
      immediately?, external?}] }`.
2. The dist bundle runs `new AppWebEntry(el).run()`:
   - builds the static module table from `seed.ts::getStaticModules()` —
     exactly `PLATFORM_MODULES` (`web/src/platform.ts`): `react`,
     `react/jsx-runtime`, `react-dom`, `react-dom/client`,
     `@deepseek-ai/cordis`, `…dsh-client-ui-slots`, `…dsh-client-ui-primitives`;
   - prefetches `immediately` rows, then fetches every manifest row's
     `url` (`/plugins/<id>/client.js?rev=<hash>`), executes it (registers a
     factory), creates all cordis Loader entries;
   - **failure posture**: any entry whose import failed or whose injected
     cordis service never resolves makes `runPluginBoot → assertEntriesActive`
     throw → boot page shows the failure list. Partial features do NOT
     degrade at boot level; degradation is achieved by trimming the manifest
     (our lever) plus `ctx.get()`-style optional services inside plugins.
3. After activation, `mountApp` renders `renderSlot('root')`; ui-layout's
   AppFrame occupies `root`, ui-sidebar occupies `sidebar`, ui-conversation
   occupies the conversation column, ui-renderer supplies outlets/hook
   binding.

Service graph the trimmed roster must satisfy (verified `inject` lists):
connection→[] · typert-registry→[] · api-gateway(client face)→[typert,
connection] · api-remotes→[remote] · client-runtime→[connection, typert,
remote, remote.commands] · locale→[slots, connection, remote, settingsScope]
· ui-theme→[slots, locale, connection, remote, settingsScope] ·
ui-layout→[slots, theme] · ui-renderer→[slots, sessions] · ui-sidebar→[slots,
layout, sessions, workspaces, locale] · ui-settings→[connection, remote]
(provides `settingsScope`) · ui-conversation→[slots, layout, sessions,
workspaces, locale, connection, remote, settingsScope, conversationEvents,
conversationViews] · ui-tool→[slots, connection] · ui-brand-official→[slots].
All resolvable within the roster of §5.1.

---

## 3. Chat data path (research item 2)

Send path (one hop through the object layer, zero component changes):

```
InputBar (Enter)                       ui-conversation/src/client/skeleton/InputBar.tsx
  → input machine submit               …/client/input/machine.ts
  → ConversationController.send        …/client/service.ts:132
      session.prompt([{type:'text',text}], 'queue')
  → Session.prompt                     runtime/src/client/sessions/session.ts:190
      api.sessions.prompt({sessionId, mode, content, clientTimeZone}, signal)
        = POST /api/session.prompt  body {type:'client-request', rpcId, method:'session.prompt', payload}
  ← RpcResult<{accepted:true}>         (promptError mirrored on rejection)
```

Receive path (server-pushed, mux WebSocket):

```
Zig emits ServerRequest frame on /api/events.mux:
  {type:'server-request', rpcId:<fresh>, method:'session/event',
   payload:{type:'session/event', sessionId, event:{type,seq,time,data}, view?}}
  → ConnectionController.pumpStream     connection/src/client/connection.ts
  → SessionManager.handleMuxEnvelope    runtime/src/client/sessions/manager.ts:683
      routes to resident Session by sessionId
  → Session folds event window          runtime/src/client/sessions/session.ts
      + ConversationNodeAssembler + conversation-nodes/* Definitions
  → snapshot publish (notifier markFrameDirty/markDirty)
  → useSession selector re-render → ChatNodeSeat row update
```

Events the client folds into chat nodes (verified fold sites in
`ui-conversation/src/client/conversation-nodes/*` and event map in
`packages/core/session/src/types.ts::SessionEventMap`):

| SessionEvent type | data shape (wire) | rendered as |
|---|---|---|
| `turn/start` | `{turn}` | turn boundary; running-turn clock anchor |
| `step/start` / `step/end` | `{turn,step}` | step grouping (assistant node id `${turn}:${step}`) |
| `user/message` | `{id, role:'user', content:[{type:'text',text}], source:{kind:'user'}}` | user bubble (+ sidebar activity bump) |
| `assistant/chunk` | `{turn,step,chunk:{type:'text-delta'|'reasoning-delta'|'block-start'|'block-end'|'tool-call-delta'|'usage', index, text?…}}` | streaming deltas |
| `assistant/message` | `{turn,step,message:{id,role:'assistant',content:ContentBlock[],source:{kind:'model',…}}, usage?, interrupted?}` | finalized markdown row |
| `tool/call` | `{turn,step,callId,name,arguments}` | tool card (generic fallback without `view`) |
| `tool/result` | `{turn,step,message:{role:'user',content:[{type:'tool-result',toolCallId,content:[TextBlock…],isError?}],source:{kind:'tool',callId}}, error?, meta?}` | result under call |
| `turn/end` | `{turn, reason:{kind:'completed'\|'cancelled'\|'error', error?:LlmFailure}}` | turn close; error card on `error` |

Unknown event types land on the registered unknown-surface fallback node —
safe to extend later. The optional `view` field (host-computed render intent,
`ToolEventView = {for:'call'|'result', view:{card,…}}`) may be omitted by
zharness; documented default is the generic JSON card.

Open-session flow: sidebar click → `sessions.open(id)` → `session.history`
(tail page, `maxMessages`=50, `projections` block rides tail page only) →
live mux events buffer during open and stitch by seq
(`session/subscribed {sessionId,lastSeq}` baselines gap detection).

---

## 4. Transport truth (research item 4)

Unary (C→S): `POST /api/<method>` (e.g. `POST /api/session.list`).

```jsonc
// request body
{ "type": "client-request", "rpcId": "<uuid>", "method": "session.list", "payload": { … } }
// response body — ALWAYS HTTP 200; business errors live in result.error
{ "type": "server-response", "rpcId": "<echoed>", "result":
   { "ok": true,  "value": … }
 | { "ok": false, "error": { "code": "<closed union>", "message": "...", "details": {...} } } }
```

Sources: `apiproxy/src/api/rpc.ts` (envelope, `RpcErrorDetailsMap` codes),
`fetch/handler.ts` (dispatch), `fetch/client.ts::callUnary` (mint/echo/parse).
Error codes zharness needs initially: `bad-request`, `internal`,
`session-not-found`, `workspace-not-found`.

Downstream (S→C): `GET /api/events.mux` and `GET /api/events.host`,
upgraded to **WebSocket** by the browser carrier
(`connection/src/client/web-api-client.ts`); host side pumps each frame as a
JSON text message of the `ServerRequest` full form
(`connection/src/websocket-downlink.ts`). Client→server messages on the
socket are a protocol violation (close 1008). SSE framing exists only for the
in-process Node carrier — irrelevant to zharness.

Answerable server pushes (approvals/questions) expect
`POST /api/respond {type:'client-response', rpcId, result}` →
`{accepted:true}|{accepted:false,reason}`. zharness emits none → endpoint can
return `{accepted:false, reason:'not-pending'}` stub.

### Minimal method set (exact payloads)

From `apiproxy/src/api/{sessions,host,workspace,settings}.schema.ts`:

| Method | Request payload | Response value |
|---|---|---|
| `host.describe` | `{}` | `{version:string, cwd:string, provider?, model?, attachedSessions:number, home:string, canOpenPath:boolean}` |
| `session.list` | `{cursor?}` (omit) | `{items:[{sessionId, updatedAt:number(ms), running:bool, blank:bool, parentSessionId?, origin?, cwd?, agentPreset?, projections?:{asOfSeq:int≥-1, values:record}}]}` |
| `session.create` | `{workspaceId?\|cwd?, sessionId?, agentPreset?}` | `{sessionId, agentPreset?}` |
| `session.history` | `{sessionId, beforeSeq?, maxMessages?}` | `{events:[{event:{type,seq,time,data}, view?}], hasMore:bool, projections?}` |
| `session.prompt` | `{sessionId, mode:'queue'\|'steer', content:[{type:'text',text}\|{type:'image',mediaType,data,name?}], clientTimeZone?}` | `{accepted:true, command?}` |
| `session.cancel` | `{sessionId}` | `{accepted:true}` |
| `session.rename` | `{sessionId, title}` | `{title, seq}` |
| `workspace.list` | `{}` | `{items:[{workspaceId,title,sessionIds[],createdAt:ISO-string,updatedAt:ISO-string}], archivedSessionIds?}` (verify archived field name against `workspace.schema.ts` at impl time) |
| `workspace.create` | `{path}` | `{workspace:{WorkspaceView}, created:bool}` |
| `workspace.rename` / `.delete` / `.insertBefore` / `.insertSessionBefore` / `.archiveSession` | see `workspace.schema.ts` | small acks/views |
| `settings.describe` | `{}` | document view `{namespaces:[…]}` — stub with an empty namespaces array suffices (mirror degrades; enter-behavior pref then inert) |
| `host.openPath` | `{path}` | `{opened:true}` or error (ChatView shows retry dialog on refusal) |
| `host.listDirectory` / `createDirectory` | only if directory-picker-browse row is mounted (see §5.1 variants) | `DirectoryListing` per `host.ts` |

### Minimal stream set

- `events.mux`: `session/subscribed {sessionId,lastSeq}` (per known session,
  on open); `session/event {sessionId, event, view?}`; optional later:
  `session/projection {sessionId,key,value,seq}` (key `'title'`),
  `stream/error`. Omitted families (approval/\*, question/\*, session/queue,
  session/jobs) simply never arrive → empty surfaces.
- `events.host`: `host/session-added {sessionId,blank,cwd?}`,
  `host/session-status {sessionId,running}`, `host/session-removed`,
  `host/agent-error {sessionId,message}`; optional later:
  `host/workspace-changed`. Without workspace push frames the sidebar
  refreshes on reconnect/refetch — acceptable v1, cheap to add.

Health/reconnect semantics come free: `ConnectionController` opens both
sockets + calls `host.describe` per generation (strict readiness handshake),
reconnects with jittered exponential backoff (500 ms–10 s); UI shows the
ConnectionBanner from `ui-primitives`.

---

## 5. Component dependency analysis (research item 3) & build reality (item 5)

### Per-package verdicts

| Package (LOC src) | Renders from plain props/stores we provide? | Blocking imports (value imports, beyond types) |
|---|---|---|
| **ui-theme** (726) | CSS tokens reusable as-is (`ui-theme/src/styles/*.css`, `--dsw-*`); its plugin half is a theme service + presenter | `ui-settings/client`, `runtime/client`, `locale/client`, `cordis` — plugin wiring only; **CSS is dependency-free** |
| **ui-layout** (678) | Yes — AppFrame + panel store via slots; needs `theme` service | `ui-theme/client`, `ui-slots`, `runtime/client` (types+services) — fine *inside* the roster; unusable standalone (closure bundle) |
| **ui-sidebar** (448) | Yes — pure registry over `sessions`/`workspaces` stores; New Session rides `workspaces.startSession` | `runtime/client`, `ui-slots`, `ui-primitives`, `locale/client`, `ui-layout/client` — same caveat |
| **ui-primitives** (6,870) | **Cleanest reuse target**: cordis-free by design ("copy arrives via props"), ordinary ESM `lib/index.js`, plain React props. MarkdownText/shiki/katex pipeline, JsonTree, DiffBlock, Modal, Toast, icons | none (`@deepseek-ai/cordis` appears only in comments/invariant) |
| **ui-conversation** (11,974) | Yes — but only through the slot system; consumes the runtime `ConversationSnapshot` vocabulary | `runtime/client` ×55, `cordis` ×19 (apply-world), `ui-slots` ×11, type-only: input-trigger/llm-retry/attachment/token-meter/compaction/tools/tool-todo/session-stats/plan-mode/permission-presets/goal/commands/ui-settings/connection/brand/agent |

Net: outside the roster nothing above ui-primitives is practically
importable; inside the roster everything composes with zero forks.

### Build reality

- Packages are private, `workspace:^` deps, ESM-only, built by tsdown with
  the shared preset `packages/client/tsdown.client.ts`: dynamic rows emit
  closure-factory `lib/client.js` (externals = `PLATFORM_MODULES` +
  `PRELOADED_CLIENT_EXTERNALS`, CSS Modules compiled by lightningcss into
  self-injecting style tags); static rows (ui-primitives, ui-slots) emit
  normal `lib/index.js`. ⇒ **Build inside the vendored monorepo; do not
  rebuild the graph elsewhere.**
- `apps/web/vite.config.ts` refuses dev/serve standalone ("bare Vite cannot
  inject `window.__DSH_BOOT__`") — `vite build` works and produces
  `dist/` expecting a host that serves `/plugins/<id>/client.js` and injects
  the head rows (§2).
- tsconfig `paths` map `@deepseek-ai/*` to sources repo-wide; irrelevant if
  we build in-place.
- Toolchain: repo pins `packageManager: pnpm@11.7.0`, engines
  `node ^22.19 || >=24`. Local Node v24.18 ✓; local pnpm 9.15 will install
  (lockfile v9 compatible) but pin pnpm 11 via corepack for reproducibility.
- No `node:*` imports in any client half (grep-asserted by their purity gate).

---

## 6. Implementation plan (Option A), sized in agent-tasks (≈half-day each)

### Phase 0 — Vendoring & build pipeline (2 tasks)
1. Decide vendor mechanics: keep `_ref/deepseek-harness` as the pinned source
   (record upstream commit in a VENDOR notice) or copy a pruned subtree
   (`apps/web`, `packages/client/*`, `packages/host/apiproxy`, `packages/api/
   {gateway,remotes}`, `packages/typert/{registry,protocol}`,
   `packages/core/session`, `packages/llm`, `vendor/*`, root configs) into
   `web/gui/`. Prefer keeping the full checkout: prunes drift silently.
2. Add `web/gui-build.sh`: corepack pnpm install → `pnpm --filter <each of
   the 15 packages> bundle` → `pnpm --filter @deepseek-ai/dsh-web-frontend
   build`; emit `build-artifacts/manifest.json` (rows: id, url, rev=sha256 of
   lib/client.js, inject, immediately, external — mirroring the modules
   node-half scan of `dsh.client` fields). Commit artifacts (or CI cache).

### Phase 1 — Static hosting + boot injection (2 tasks)
3. Extend `src/server/static.zig`: serve `apps/web/dist/**` at `/`, and
   `/plugins/<id>/client.js` (and `.map`) from build artifacts with `rev`
   cache-busting; correct `content-type` for JS.
4. Index transform: on `GET /` inject the three head rows (queue-facade
   script text copied verbatim from `bootInjections()`, preload script tags,
   `<script>globalThis['__DSH_BOOT__'] = <manifest.json></script>`), same
   technique as `host/webserver/src/injections.ts`.

### Phase 2 — Envelope RPC + read methods (3 tasks)
5. Envelope dispatcher: route `POST /api/<method>`, parse/validate
   ClientRequest, echo rpcId, always-200 responses, error codes
   (`bad-request`/`internal`/`session-not-found`). ~400 LOC.
6. `host.describe` + `session.list` (fold summaries from the event-log store;
   `running` from the turn runner; `blank` = no accepted prompt yet;
   `cwd` from process cwd) + `workspace.list` (single synthesized workspace
   containing all session ids). ~350 LOC.
7. `session.create` + `session.history` (paged log read, `hasMore`, tail-page
   `projections {asOfSeq, values:{title}}`). ~300 LOC.

### Phase 3 — Event log + agent-loop bridge (4 tasks)
8. Append-only per-session event log (seq monotonic from 0; JSONL under
   `.zharness/events/<id>.jsonl` or extend `src/session/session.zig`;
   in-memory ring for open sessions). ~600 LOC.
9. Bridge `AgentLoop.EventKind` (`src/agent/agent.zig:114`) → SessionEvents:
   turn_start→`turn/start`(+`step/start`), thinking→`assistant/chunk
   reasoning-delta`, text→`assistant/chunk text-delta`, done→`assistant/
   message`+`step/end`+`turn/end completed`, err→`turn/end error`;
   synthesize `user/message` on accepted prompts; tool_call/tool_result→
   `tool/call`/`tool/result` with `ToolResultMessage` wrapping
   ({source:{kind:'tool',callId}}). MessageIds = UUIDs. ~450 LOC.
10. Background turn runner for `serve` mode: accept `session.prompt`, run the
    loop off the request thread, flip `host/session-status` running flags,
    support one queued prompt (mode 'steer' → return `steer-unavailable` v1),
    `session.cancel` cancels the loop. ~500 LOC.
11. `session.rename` (updates title + settles `'title'` projection) +
    projection plumbing (history-tail values + optional `session/projection`
    frames). ~200 LOC.

### Phase 4 — WebSocket downlinks (3 tasks)
12. RFC6455 server upgrade on the existing httpd: handshake (SHA-1+base64
    accept), text-frame decode/encode, ping/pong, close; bypass the 10 s
    conn timeout for upgraded sockets. ~500 LOC.
13. Mux/host hubs: per-connection subscription, fan-out of `ServerRequest`
    envelopes, replay `session/subscribed` for all sessions on mux open,
    host-stream frames from the turn runner. Reuse patterns from
    `src/server/events.zig`. ~400 LOC.

### Phase 5 — Remaining domains + polish (3 tasks)
14. Workspace CRUD (create/rename/delete/reorder/archive over one JSON
    registry file) + `host/workspace-changed` pushes; `settings.describe`
    empty-document stub; `host.openPath` (macOS `open`, deny gracefully
    otherwise). ~400 LOC.
15. Robustness pass against the client's reconnect machine: kill server
    mid-stream → client must resync (subscribed lastSeq, history refetch);
    seq-gap stitching; double-tab behavior. Fix what breaks.
16. Sidebar titles via `'title'` projections (first-prompt prefix or cwd
    basename), `updatedAt` freshness on user/message frames.

### Phase 6 — License + docs (1 task)
17. Attribution (§8) and rewrite `docs/web.md` around the new stack.

Total ≈ 20 tasks. Critical path: 5→7→8→12→13; Phases 2–4 parallelize across
agents after Phase 1 lands.

### Vendor inventory (what ships to the browser)

Manifest rows (15): `@deepseek-ai/dsh-client-modules`,
`…dsh-client-connection`, `…dsh-typert-registry`, `…dsh-api-gateway`,
`…dsh-api-remotes`, `…dsh-client-runtime`, `…dsh-client-locale`,
`…dsh-client-ui-theme`, `…dsh-client-ui-layout`, `…dsh-client-ui-renderer`,
`…dsh-client-ui-sidebar`, `…dsh-client-ui-settings`,
`…dsh-client-ui-conversation`, `…dsh-client-ui-tool`,
`…dsh-client-ui-brand-official`.

Optional variant rows (add later, each costing only its methods):
`ui-workspace` (+`directory-picker-browse` → needs `host.listDirectory`/
`createDirectory`; hero workspace picker), `ui-trajectory` (second view tab,
no new wire calls), `ui-model-selection` (needs `session.models`/
`selectModel`), `ui-input-trigger`+`ui-commands` (slash pipeline).

Source kept in vendor (not shipped): all of the above packages' sources,
`packages/host/apiproxy` (contract truth), `vendor/cordis*`, root build
configs, `scripts/client-build-environment.ts`, `tsdown.client.ts`.

---

## 7. Explicit non-goals (deliberately dropped domains)

Dropped from the 13-domain apiproxy surface (methods we will NOT implement;
related plugins stay out of the manifest so their absence is silent):

- **subagents**: `subagent.list/history/prompt/interrupt`, `ui-subagent`,
  lineage breadcrumbs.
- **goals**: `goal.*`, `ui-goal` goal bar.
- **skills**: `skill.list`, `ui-skill`, `@`-skill references.
- **agentPresets**: `agentPreset.*`, preset chips/selectors,
  `ui-agent-preset`.
- **credentials** & **llm**: `credentials.*`, `llm.providers/models/
  discoverModels`, `ui-settings-models`, in-app model switching (model is a
  zharness config concern).
- **settings UI**: only the `settings.describe` stub ships; `settings.update/
  replace/mutate/openDocument` and `ui-settings-general/-models/-plugins/
  -plugin-inventory` are out (enter-behavior preference stays default).
- **downloads/export**: session log export dialog.
- **approvals/questions/respond**: no permission gates, no ask-user; the
  composer-takeover panels never trigger because those frames never arrive.
- **jobs/workflow**: `session/jobs` frames, `ui-jobs`, `ui-workflow-run`,
  dynamic cordis runner (`ui-cordis`, `cordis-client-runner`).
- **conversation extras**: attachments/images (prompt schema stays
  text-only), message feedback, plan-mode seat, permission-presets chip,
  slash-command/reference input triggers, compaction command cards, fork
  (`session.fork`), search (`session.search`), HMR reload chain.
- **Multi-workspace reality**: v1 synthesizes one workspace rooted at the
  server cwd; true per-directory workspaces are a phase-later extension via
  the existing `workspace.*` methods.

---

## 8. License attribution (MIT)

Both codebases are MIT (`_ref/deepseek-harness/LICENSE`: "Copyright (c) 2026
DeepSeek"; zharness LICENSE: "Copyright (c) 2026 zharness contributors").

Required:

1. Preserve upstream `LICENSE` files: ship `LICENSE` (DeepSeek) inside the
   vendored tree and alongside shipped artifacts
   (`zig-out/.../gui/LICENSE` or equivalent).
2. Add a `THIRD_PARTY_NOTICES.md` entry at zharness root: "deepseek-harness
   Web GUI — Copyright (c) 2026 DeepSeek — MIT" listing the vendored package
   names, plus a pointer to upstream's own `THIRD_PARTY_NOTICES.md` for its
   vendored Cordis libraries (also MIT, upstream licenses preserved per
   `vendor/README.md`).
3. Note the reuse in `README.md` (Web UI section): GUI derived from
   DeepSeek Harness (MIT), backend protocol implemented independently.
4. Do not strip `license: MIT` / repository metadata from vendored
   `package.json`s when pruning (if pruning at all).
5. If zharness is ever relicensed, the vendored GUI portions remain MIT per
   (1)–(2); record the split in NOTICE.

---

## Appendix A — Wire examples (copy-paste fixtures)

Unary success:

```
POST /api/session.list
{"type":"client-request","rpcId":"5f0c…","method":"session.list","payload":{}}

200 OK
{"type":"server-response","rpcId":"5f0c…","result":{"ok":true,"value":{"items":[
  {"sessionId":"web-20260823-101500","updatedAt":1755946500000,"running":false,
   "blank":true,"cwd":"/Users/n0x/w4_proj/dev_machine/zharness",
   "projections":{"asOfSeq":-1,"values":{}}}]}}}
```

Mux frame (WebSocket text message on `/api/events.mux`):

```json
{"type":"server-request","rpcId":"a1b2…","method":"session/event",
 "payload":{"type":"session/event","sessionId":"web-20260823-101500",
   "event":{"type":"assistant/chunk","seq":41,"time":1755946501123,
            "data":{"turn":1,"step":1,
                    "chunk":{"type":"text-delta","index":0,"text":"Hello"}}}}}
```

Prompt acceptance:

```
POST /api/session.prompt
{"type":"client-request","rpcId":"c3d4…","method":"session.prompt",
 "payload":{"sessionId":"web-20260823-101500","mode":"queue",
            "content":[{"type":"text","text":"fix the failing test"}],
            "clientTimeZone":"Asia/Shanghai"}}

200 OK
{"type":"server-response","rpcId":"c3d4…","result":{"ok":true,"value":{"accepted":true}}}
```

## Appendix B — Verified source-of-truth index

| Fact | Source |
|---|---|
| Boot kernel & hard-fail audit | `packages/client/web/src/boot.ts` (`assertEntriesActive`) |
| Module table seeds | `packages/client/web/src/{platform,seed}.ts` |
| Boot wire format | `packages/client/modules/src/client/manifest.ts` (`WebBootGraph`), `modules/src/index.ts` (`bootInjections`) |
| Envelope & error codes | `packages/host/apiproxy/src/api/rpc.ts`, `rpc.schema.ts` |
| Method registry | `packages/host/apiproxy/src/api/rpc-map.ts` |
| Payload schemas | `packages/host/apiproxy/src/api/{sessions,host,workspace,settings}.schema.ts` |
| Carrier client (mint/parse/SSE) | `packages/host/apiproxy/src/fetch/client.ts` |
| Browser WS carrier | `packages/client/connection/src/client/web-api-client.ts` |
| WS host pump | `packages/client/connection/src/websocket-downlink.ts` |
| Stream frame unions | `packages/host/apiproxy/src/api/events.{ts,schema.ts}` |
| Reconnect/health handshake | `packages/client/connection/src/client/connection.ts` |
| Prompt hop | `ui-conversation/src/client/service.ts` → `runtime/src/client/sessions/session.ts::prompt` |
| Frame routing/folding | `runtime/src/client/sessions/{manager,session,conversation-assembler}.ts` |
| Event vocabulary | `packages/core/session/src/types.ts::SessionEventMap`, chunk shapes in `packages/llm/llm/src/types.ts`, message/source shapes in `packages/llm/llm/src/message.ts` |
| Slot contracts | `packages/client/ui-slots/src/renderer.ts`, `ui-conversation/src/client/contract/slots.ts` |
| Bundle factory build | `packages/client/tsdown.client.ts` |
| Service inject lists | `export const inject` in each package's `src/client/index.ts` |
