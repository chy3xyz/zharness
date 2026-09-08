# zharness Web UI

The web UI is the vendored **DeepSeek Harness** React client, served by
`zh serve`. The frontend lives under `webui/dist/` and speaks
the upstream `/api` RPC protocol (unary POST + two WebSocket event streams),
implemented natively in Zig by `src/server/apiproxy/`.

## Run

```sh
zig build && ./zig-out/bin/zh serve        # from the repository root
# then open http://127.0.0.1:3080/
```

The static handler resolves `/` against `webui/dist/` relative
to the process CWD, so run the server from the repository root.

## Files

| Path                                          | Purpose                                        |
|-----------------------------------------------|------------------------------------------------|
| `webui/dist/index.html`                   | Main entry point (React SPA)                   |
| `webui/dist/assets/`                      | Built JS/CSS bundles                           |
| `webui/dist/plugins/`                     | Client plugin manifests                        |
| `src/server/apiproxy/`                        | Zig apiproxy (RPC + WebSocket hubs)            |
| `src/server/static.zig`                       | Static file server                             |
| `test/_t_static.zig`                          | Pure routing tests                             |

## API endpoints consumed

The GUI speaks the upstream DeepSeek Harness protocol:

| Endpoint               | Method | Used for                                    |
|------------------------|--------|---------------------------------------------|
| `/api/session.list`    | POST   | Sidebar session list                        |
| `/api/session.history` | POST   | Read-only transcript view                   |
| `/api/session.prompt`  | POST   | Send prompt and stream response             |
| `/api/events.mux`      | WS     | Real-time session events (streaming, tool calls) |
| `/api/events.host`     | WS     | Workspace/session list liveness             |
| `/healthz`             | GET    | Health check                                |

A legacy minimal JSON API (`POST /run`, `GET /sessions`, `/healthz`, `/events`)
remains available on the same port for scripts.

## Design tokens

The design language is extracted from DeepSeek Harness's theme package
(`packages/client/ui-theme`) and conversation CSS modules — the tokens and
layout rules were adopted, the React/pnpm toolchain was deliberately not
(dev.md: UI lives outside zharness; the HTTP API is the contract surface).

See the token reuse mapping in `docs/dsh-reuse-spec.md` for the full
var → value table (surfaces, text, borders, shape, rhythm, motion).

## Limitations

- Settings/subagents/goals degrade gracefully per upstream's own
  missing-feature rules.
- Single-user local tool: no auth, no TLS, binds loopback only.
