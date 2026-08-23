# zharness Web UI

A zero-build, dependency-free chat client served by `zharness serve`. The
design language is extracted from `_ref/deepseek-harness`'s theme package
(`packages/client/ui-theme`) and conversation CSS modules — the tokens and
layout rules were adopted, the React/pnpm toolchain was deliberately not
(dev.md: UI lives outside zharness; the HTTP API is the contract surface).

## Run

```sh
zig build && ./zig-out/bin/zharness serve        # from the repository root
# then open http://127.0.0.1:3080/
```

The static handler resolves `/` against `web/index.html` relative to the
process CWD, so run the server from the repository root (or set `.root` in
the splice below).

## Files

| Path                  | Purpose                                        |
|-----------------------|------------------------------------------------|
| `web/index.html`      | Single-page shell (sidebar + transcript + composer) |
| `web/assets/styles.css` | Design tokens + layout (dark palette)        |
| `web/assets/app.js`   | Vanilla ES2020 client, no imports, no CDN      |
| `web/assets/favicon.svg` | Inline-SVG favicon                          |
| `src/server/static.zig` | HandlerFn-compatible static file server      |
| `src/_t_static.zig`   | Pure routing tests (`zig test -lc src/_t_static.zig`) |

## API endpoints consumed

All same-origin; the server binds 127.0.0.1 only.

| Endpoint             | Method | Used for                                    |
|----------------------|--------|---------------------------------------------|
| `/run`               | POST   | `{prompt, session}` → answer text rendering |
| `/sessions`          | GET    | sidebar session list                        |
| `/sessions/:id`      | GET    | read-only transcript view                   |
| `/healthz`           | GET    | health dot + offline banner (15s polling)   |
| `/events`            | GET    | SSE activity ticker (tolerates heartbeat-only stubs) |
| `/`, `/assets/*`     | GET    | this client itself, via `static.zig`        |

Client behaviors worth knowing:

- Fresh conversations mint a client-side id (`web-YYYYMMDD-HHMMSS`) passed as
  `session` so runs persist under a name the sidebar can list.
- Transcripts render `role` values `user` / `assistant` / `tool` /
  `system`; history views are read-only by design.
- `{"ok":false}` responses (any HTTP status) render as a red error card;
  network failures additionally flip the offline banner via the next
  `/healthz` poll.
- SSE envelopes are read defensively: any of `event_type`/`type`/`event`
  plus `payload_json`/`payload`/`detail`/`data` drive a one-line ticker that
  fades after 6s. Heartbeat-only servers emit only `:` comments, which
  EventSource never surfaces — the ticker simply stays hidden.

## Static server contract (`src/server/static.zig`)

- Same signature as `api.handle` (`httpd.HandlerFn`), so it can be installed
  as the httpd handler directly or wrapped around it.
- Claims exactly two URL spaces: `/` → `<root>/index.html`,
  `/assets/<path>` → `<root>/assets/<path>`. Everything else delegates to
  `api.handle` (fallback) so the JSON route table stays authoritative.
- Security: paths are percent-decoded **before** validation; `.`, `..`,
  empty segments (`//`), NUL, and backslash are rejected (403); reads are
  capped at 5 MB (413); directories and all other filesystem misses return a
  uniform JSON 404. Content types map html/css/js/svg/png/ico; anything else
  is `application/octet-stream`.
- Pure core is IO-free and unit-tested: `claims(path)` +
  `resolvePath(root, url_path)` in `src/_t_static.zig`.
- File access uses direct libc shims (`fopen`/`fread`), the same precedent
  `httpd.zig` sets with sockets — handlers receive no `std.Io`.

### The splice (apply EXACTLY ONE)

Option A — inside `api.handle`, per the swarm spec. Two lines at the top of
`handle` in `server/api.zig`, before routing:

```zig
const static = @import("static.zig"); // top of api.zig

pub fn handle(ctx: ?*anyopaque, alloc: std.mem.Allocator,
              req: *const httpd.Request, res: *httpd.Responder) anyerror!void {
    if (req.isGetLike() and static.claims(req.path)) {
        return static.handle(null, alloc, req, res); // defaults: root "web"
    }
    …existing body unchanged…
}
```

Option B — in `main.zig cmdServe`, zero edits to api.zig:

```zig
const web = try alloc.create(static.Ctx);
web.* = .{ .root = "web", .fallback = .{ .ctx = deps, .call = api.handle } };
var server = try httpd.Server.init(alloc, .{ .ctx = web, .call = static.handle },
                                   .{ .port = port });
```

## Reuse mapping: deepseek design language → zharness client

Adopted from `ui-theme/src/styles/{base,design-platform}.css` (dark-theme
values) and the spacing/type/radius language of `ui-conversation`'s CSS
modules. Their var → our value:

### Surfaces

| deepseek token (dark)                     | ours                | value            |
|-------------------------------------------|---------------------|------------------|
| `--dsw-static-neutral-bluish-950` (`--dsw-alias-bg-base`)      | `--zh-bg-base`    | `rgb(21,21,23)`  |
| `--dsw-specific-sidebar-fill` (`…-900`)   | `--zh-bg-sidebar`   | `rgb(27,27,28)`  |
| `--dsw-alias-bg-layer-1` (`…-875`)        | `--zh-bg-layer-1`   | `rgb(35,35,36)`  |
| `--dsw-alias-bg-layer-2` (`…-850`), also `--dsw-specific-bubble` / `-input-major` | `--zh-bg-layer-2` | `rgb(44,44,46)` |
| `--dsw-alias-bg-layer-3` (`…-800`)        | `--zh-bg-layer-3`   | `rgb(53,54,56)`  |
| `--dsw-alias-interactive-bg-hover`        | `--zh-hover`        | `rgba(255,255,255,0.08)` |

### Text

| deepseek token                            | ours                    | value            |
|-------------------------------------------|-------------------------|------------------|
| `--dsw-alias-label-primary` (`…-50`)      | `--zh-label-primary`    | `rgb(249,250,251)` |
| `--dsw-alias-label-secondary` (`…-300`)   | `--zh-label-secondary`  | `rgb(207,211,214)` |
| `--dsw-alias-label-tertiary` (`…-400`)    | `--zh-label-tertiary`   | `rgb(173,178,184)` |
| `--dsw-alias-label-caption` (`…-600`)     | `--zh-label-caption`    | `rgb(129,133,140)` |
| system font stack (their base.css)        | `--zh-font`             | identical stack  |
| code font stack (`--ds-font-family-code`) | `--zh-font-code`        | identical stack  |
| type roles xs-13 / s-strong-14 / base-16  | 13 / 14 / 16px scale    | chat body 16/24, chrome 14, captions 12/18 |

### Borders & state

| deepseek token                                  | ours               | value                       |
|-------------------------------------------------|--------------------|-----------------------------|
| `--dsw-alias-border-l1/l2/l3`                   | `--zh-border-l1/2/3` | `rgba(255,255,255,0.06/0.12/0.16)` |
| `--dsw-static-deepseek-400/450` (brand blue)    | `--zh-accent(-strong)` | `rgb(103,158,254)` / `rgb(86,134,254)` |
| `--dsw-state-error-primary` (red-400)           | `--zh-error`       | `rgb(242,90,90)`            |
| `--dsw-state-success-primary` (green-500)       | `--zh-success`     | `rgb(34,197,94)`            |
| `--dsw-state-warn-primary` (amber-500)          | `--zh-warn`        | `rgb(245,158,11)`           |

### Shape, rhythm, motion, layout

| Pattern (source)                                     | ours                          |
|------------------------------------------------------|-------------------------------|
| Radii 6 / 8 / 22 / pill-999 (module.css census)      | `--zh-radius-sm/md/bubble/pill` (+12 for cards) |
| Spacing steps 4·8·12·16 with one 16px column rhythm (ChatView.module.css) | `--zh-space-1..4`, `.msg-column gap:16px` |
| User bubble: right-aligned, `min(525px, 82%)` cap, r22, `10px 16px`, 16/24 type (MessageItem.module.css) | `.bubble-user` verbatim |
| Assistant messages on canvas without bubbles         | `.row-assistant`              |
| Centered shared column width (~736px, `--dsh-chat-content-width`) | `--zh-chat-width` |
| Turn-status shimmer: brand-blue gradient text sweep, 1.8s linear, reduced-motion static fallback (ChatView.module.css) | `.turn-status` + `@keyframes shimmer` |
| Easing/durations `cubic-bezier(0.4,0,0.2,1)`, 0.1/0.2s (base.css) | `--zh-ease/fast/med` |
| Thin rounded scrollbars (scrollbar.css tones)        | `::-webkit-scrollbar*`        |

Reimplemented rather than reused: the React component/slot architecture,
CSS-module pipeline, markdown/code-highlight renderer (answers render as
pre-wrapped plain text), and their RPC/websocket transport (we speak the
plain REST/SSE API above).

## Limitations

- No streaming of answers: `POST /run` is single-shot; the busy indicator is
  cosmetic until a streaming endpoint exists.
- History views are read-only; resuming a saved session through `/run` works
  (pass its id) but the UI does not offer it yet.
- Tool-call badges are heuristic (line-shaped traces like `[tool]`, `⚙`,
  `tool_use …` in assistant text, plus dedicated `role:"tool"` entries).
- `created_at` currently arrives as `0` from the server (see
  `serveGetSession`), so relative timestamps show nothing until that is
  populated upstream.
- The composer's Enter-to-send mirrors chat convention; there is no stop
  control because the API exposes no cancellation.
- Single-user local tool: no auth, no TLS, binds loopback only.
