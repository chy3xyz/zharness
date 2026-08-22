# zeepseek

A terminal (TUI) DeepSeek client built with Zig and [zigzag](https://github.com/chy3xyz/zigzag). Streams chat completions, runs tools (shell/file/git/web) with an approval flow, manages sessions and long-term memory, and can talk to MCP servers.

> ⚠️ **Compiler**: built and tested against Zig `0.17.0-dev.1422+e863bf3be` (the only version that builds this tree today). `zigzag` is vendored at `vendor/zigzag` with a small patch (`addPassthruArgs`) for that compiler. See **[BUILDING.md](BUILDING.md)** for the exact reproducible build steps.

## Build & run

```sh
zig build            # debug build
zig build test       # unit tests (test_runner)
zig build -Doptimize=ReleaseFast

DEEPSEEK_API_KEY=sk-... ./zig-out/bin/zeepseek
```

## Usage

Type a message and press Enter. `/` lists commands.

| Command | What it does |
|---|---|
| `/save <name>` / `/load <name>` / `/sessions` | session persistence (length-prefixed format, survives newlines/colons) |
| `/compact` | LLM summarization of conversation history (background thread) |
| `/clear` / `/rewind` | reset chat / drop one turn |
| `/mode auto\|plan\|yolo` (Ctrl+Tab) | tool approval: auto (heuristic) / plan (always ask) / yolo (never ask) |
| `/skill <name>` / `/skills` | activate / list skills |
| `/memory <fact>` / `/memory recall <q>` | long-term memory (auto-injected context) |
| `/mcp` | load `~/.zeepseek/mcp.json`, spawn the first MCP server, list its tools, and register them so the model can call them |
| `/copy` (Ctrl+Y) | copy conversation to the clipboard (via the git worker process) |
| `/subagent <goal>` / `/subagents` | background sub-agent runs |
| `/model` / `/apikey` / `/provider` | provider configuration |

Keys: `Ctrl+P` palette · `Ctrl+F` search · `Ctrl+S` subagents · `Ctrl+N` thinking · `Ctrl+C` quit · `Ctrl+Tab` cycle mode.

## Architecture

```
src/
  ui/
    app.zig             App state, event loop, init/deinit
    render_text.zig     markdown -> ANSI rendering (pure)
    render_ui.zig       renderClaude* views + ANSI layout helpers
    slash_commands.zig  slash-command dispatch + executeSlashCommand
    tools_run.zig       tool-execution pipeline (parse/approve/run/MCP forward)
    sessions.zig        session save/load/list
    stream_flow.zig     SSE streaming consumption + /compact flow
    agent_flow.zig      sub-agent start/poll/update
  net/                  HTTP client (http_client2), h2 over TLS (h2_client),
                        SSE parsing, streaming client, MCP client + runner
  tools/                shell / file / git / web tools, sandbox policy,
                        approval model, command validator
  storage/              session format, mmap store
  cache/                semantic cache (reasonix) + long-term memory
  providers/            model/provider registry
  utils/                git worker (independent subprocess), dangerous-pattern
                        detection, sandbox (Seatbelt/Landlock), config
```
The UI modules import each other via Zig's lazy circular imports
(`@import("app.zig").App`) — the codebase is split by responsibility while
`App` remains the single state container.

## Safety model

- Tools execute with an approval flow (Enter allow / Esc deny); `plan` mode always asks, `yolo` never asks, `auto` uses the sandbox policy.
- If the platform sandbox fails to initialize, mutating tools degrade to *always require approval* (fail-closed).
- Dangerous shell patterns and sensitive paths are refused before execution.
- Long-running shell commands run in an independent worker process (pipe I/O, timeout, kill-on-hang) so the UI never freezes.
- Network reads have timeouts; the git/MCP workers run outside the zigzag runtime (no fork-in-multithreaded-interaction issues).

## MCP

Create `~/.zeepseek/mcp.json`:

```json
{"servers":[{"name":"my-server","command":"/path/to/server","args":["--flag"]}]}
```

Then run `/mcp` in the app: it spawns the server (stdio), completes the
JSON-RPC handshake (initialize → tools/list), registers the tools with the
model, and forwards model tool calls via `tools/call`.

## Known limitations

- `memory.md` facts are loaded at startup and injected into the system prompt (no per-session scoping yet).
- MCP `inputSchema` is advertised as a generic object (0.17 std.json has no serializer).
- Tool calls block the UI thread briefly (network reads are bounded by timeouts).
