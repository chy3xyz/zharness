# Zeepseek — Agent Guide

Zeepseek is a minimal, high-performance terminal AI client for the DeepSeek API, written in **Zig**. It is a TUI (terminal UI) application built on the **ZigZag Elm Architecture** framework (Model-Update-View). It produces a single static binary with no runtime dependencies.

---

## Technology Stack

| Component | Details |
|-----------|---------|
| Language | Zig (minimum version **0.17.0**) |
| Build System | Native `zig build` (`build.zig` + `build.zig.zon`) |
| TUI Framework | [ZigZag](https://github.com/chy3xyz/zigzag) (Elm Architecture) |
| Terminal Library | [libvaxis](https://github.com/rockorager/libvaxis) (declared as dependency) |
| C Interop | `translateC` on `src/zeepseek_c.h` (dirent, sandbox, socket, stat, unistd, stdio) |
| Target | Single static binary; cross-platform (macOS, Linux, Windows) |

### External Dependencies

Declared in `build.zig.zon`:
- `zigzag` — Elm Architecture TUI framework
- `vaxis` — Terminal UI primitives

These are fetched automatically by the Zig package manager on first build.

---

## Build and Run Commands

```bash
# Debug build
zig build

# Optimized release binary (recommended)
zig build -Doptimize=ReleaseFast

# Run the TUI directly
zig build run

# Run all unit tests
zig build test

# The executable artifact is installed to:
./zig-out/bin/zeepseek
```

---

## Architecture Overview

The codebase follows a **five-layer architecture** (inner layers do not depend on outer layers):

```
Utils ──────────────────────────────────────────────► UI
  │                                                       ▲
  │                                                       │
 Storage ────────► Network ─────► Dispatch ───────────────┘
```

| Layer | Directory | Responsibility |
|-------|-----------|----------------|
| **Utils** | `src/utils/` | Config, tokenizer, sandbox, validation, error definitions, notifications |
| **Storage** | `src/storage/` | mmap-based KV store (TurboDB), WAL, crash recovery, migrations, session manager |
| **Network** | `src/net/` | HTTP client, SSE parsing, rate limiter, circuit breaker, streaming client |
| **Dispatch** | `src/dispatch/` | Cache-first agent loop, context folding/compaction |
| **UI** | `src/ui/` | ZigZag Elm Architecture TUI rendering |

### Data Flow

```
User Input → UI (onKey) → semantic cache (reasonix replay) →
  network (stream_client) → SSE stream →
  UI (onStreamContent) → Terminal
```
The `dispatch/cache_first_loop` agent loop is constructed at startup but not yet
driven; `submit` calls `streamMessage` directly (auto-fold runs through the
ContextManager first).

### Module Inventory

| Directory | Key Files | Purpose |
|-----------|-----------|---------|
| `src/ui/` | `app.zig` (main entry + App struct), `agent_flow.zig`, `render_text.zig`, `render_ui.zig`, `sessions.zig`, `slash_command_dispatcher.zig`, `slash_commands.zig`, `stream_flow.zig`, `tools_run.zig`, `theme.zig` | Full TUI implementation |
| `src/net/` | `stream_client.zig`, `http_client.zig`, `http_client2.zig`, `h2_client.zig`, `mcp_client.zig` + `mcp_runner.zig` | API communication, streaming, resilience (SSE parsing, rate limiting and circuit breaking live inline in `stream_client.zig`/`http_client.zig`), MCP JSON-RPC over stdio |
| `src/cache/` | `reasonix.zig` | Semantic cache with LIRS eviction, 3-tier TTL, similarity matching |
| `src/dispatch/` | `cache_first_loop.zig`, `context_manager.zig` | Orchestrates cache → API → stream, context budget tracking |
| `src/storage/` | `store.zig`, `mmap_store.zig`, `session_manager.zig`, `recovery.zig`, `migrations.zig`, `keyspace.zig` | Persistent storage |
| `src/agent/` | `subagent.zig`, `sub_worker.zig` | Multi-agent scheduler with state machine |
| `src/providers/` | `mod.zig`, `manager.zig`, `models.zig` | LLM provider abstraction (DeepSeek, OpenAI, Ollama, Groq, vLLM, etc.) |
| `src/tools/` | `shell.zig`, `file.zig`, `git.zig`, `web.zig`, `process.zig`, `mod.zig` | Tool execution for the LLM |
| `src/skills/` | `manifest.zig`, `registry.zig`, `installer.zig`, `builtin.zig`, `skill.zig` | Skill system with YAML/JSON manifest parsing |
| `src/i18n/` | `manager.zig`, `strings.zig` | Internationalization (en, ja, zh-Hans, pt-BR) |
| `src/utils/` | `config.zig`, `sandbox.zig`, `tokenizer.zig`, `validation.zig`, `error.zig`, `exec_policy.zig`, `git_worker.zig`, `notifications.zig`, `dangerous.zig`, `dangerous_patterns.zig`, `tool_registry.zig` | Shared infrastructure |
| `src/acp/` | `mod.zig`, `zed_adapter.zig` | ACP / Zed adapter (compiles + tests; not yet spawned by the runtime) |
| `src/integration_runner.zig` | `integration_runner.zig` | Offline acceptance sweep used by CI (see `.github/workflows/ci.yml`) |

---

## Code Style Guidelines

### Naming Conventions

| Construct | Convention | Example |
|-----------|------------|---------|
| Source files | `snake_case.zig` | `cache_first_loop.zig` |
| Structs / Enums / Unions | `PascalCase` | `CacheFirstLoop`, `SubAgentState` |
| Functions / Methods | `camelCase` | `streamMessage`, `initWithLocaleName` |
| Module-level constants | `PascalCase` or `UPPERCASE` short abbreviations | `Pal.fg`, `R`, `B` (ANSI codes) |
| Local variables | `snake_case` | `start_idx`, `code_lang` |
| Error sets | `PascalCase` ending in `Error` | `ZeepError`, `ReasonixError` |

### Documentation Style

- **Module-level docs** use `//!` at the top of the file.
- **Item-level docs** use `///` (used sparingly; most logic is self-documenting).
- **Section dividers** in large files use ASCII art lines of `═` or `─` with comments.

Example from `src/ui/app.zig`:
```zig
//! Zeepseek TUI — ZigZag Elm Architecture
//!
//! New main entry point using ZigZag's Model-Update-View pattern.

// ═══════════════════════════════════════════════════════════════════════
// ANSI helpers — Zenburn Noir palette
// ═══════════════════════════════════════════════════════════════════════
```

### Imports

- Every `.zig` file starts with `@import("std")`.
- C bindings are imported as `@import("c")` (produced by `translateC`).
- ZigZag is imported as `@import("zigzag")`.
- Cross-directory imports use relative paths: `@import("../utils/config.zig")`.
- `mod.zig` files re-export public members of their submodules.

### Memory Management

- **Arena allocators** are preferred for long-lived objects (e.g., `Store`, `Sandbox`, `ExecPolicy`).
- **General-purpose allocators** (`std.mem.Allocator`) are passed explicitly into structs.
- **errdefer** is used aggressively to free temporary resources on error paths.
- `std.ArrayList` is the primary growable buffer type.

### Error Handling

- A central `ZeepError` error set lives in `src/utils/error.zig`.
- Functions return error unions (`!T`) rather than result structs.
- `formatError` in `src/utils/error.zig` provides human-readable mappings.

### Compile-Time Validation

`comptime` blocks validate configuration thresholds to fail the build immediately if constants are inconsistent:

```zig
comptime {
    const cfg = CacheConfig{};
    if (cfg.fold_threshold >= cfg.fold_aggressive_threshold) {
        @compileError("fold_threshold must be < fold_aggressive_threshold");
    }
}
```

---

## Testing Instructions

### Test Organization

- **There are no tests in `tests/`** — that directory is empty.
- All tests are **inline** inside the source files they validate, using `test "description" { ... }`.
- `src/test_runner.zig` imports every module that contains inline tests so that `zig build test` discovers them.

### Adding New Tests

When you create a new module with tests, add the import to the `comptime` block in `src/test_runner.zig`:

```zig
comptime {
    _ = @import("path/to/my_module.zig");
}
```

> **Zig 0.17 gotcha (verified):** a plain top-level `const _m = @import("path.zig");` does **NOT** register the module's tests in this compiler build — `zig build test` then runs zero of them silently. The import must appear inside a `comptime` block (or be referenced) for test collection to see it. A regression in this area shows up as `All 0 tests passed.`

### Test Patterns

Use `std.testing.allocator` for allocations in tests:
```zig
test "my feature" {
    const alloc = std.testing.allocator;
    var obj = try MyStruct.init(alloc);
    defer obj.deinit();
    try std.testing.expectEqual(@as(usize, 3), obj.count());
}
```

---

## Configuration and Runtime Behavior

### API Key Resolution

The DeepSeek API key is resolved in this order:
1. `/apikey <key>` command within the running session
2. `DEEPSEEK_API_KEY` environment variable
3. `~/.zeepseek/apikey` file (created automatically by `/apikey`)

### Runtime Data Directories

| Data | Location |
|------|----------|
| Session files | `~/.zeepseek/sessions/` |
| KV store data | `.zeepseek_data/` (relative to CWD) or configurable via `StoreOptions` |

### Environment Variables

| Variable | Effect |
|----------|--------|
| `DEEPSEEK_API_KEY` | Default API key |
| `ZEEPSEEK_CACHE_MAX_HOT` | Hot cache entry limit |
| `ZEEPSEEK_CACHE_MAX_COLD` | Cold cache entry limit |
| `ZEEPSEEK_CACHE_TTL` | Default cache TTL in seconds |
| `ZEEPSEEK_SEMANTIC_ENABLED` | Enable semantic cache (`1` or `true`) |

---

## Security Considerations

### Sandbox System (`src/utils/sandbox.zig`)

- **Platform-specific policies**: Seatbelt (macOS), Landlock (Linux), Job Objects (Windows).
- Restricted shell operators are hard-coded: `&&`, `||`, `;`, `| sh`, `eval`, `sudo`, `mkfs`, `dd if=`, etc.
- Dangerous command patterns are rejected before execution.

### Approval Modes (`src/utils/exec_policy.zig`)

Each tool class has an `ApprovalMode`:
- `auto_allow` — execute immediately
- `auto_deny` — reject immediately
- `prompt` — require user confirmation (UI prompt)

Defaults:
| Tool Class | Default Mode |
|------------|--------------|
| `shell` | `prompt` |
| `file_read`, `glob`, `grep` | `auto_allow` |
| `file_write`, `file_edit` | `prompt` |
| `git_commit` | `prompt` |

### SideGit (`src/workspace/side_git.zig`)

> **Not present in this codebase.** The workspace snapshot rollback described here
> is not implemented. The actual safety model is:
> 1. **Approval gates** (ABOVE): every shell/file-write/file-edit/git-commit call
>    runs through a per-call user-confirmation overlay by default, and fails
>    closed if the platform sandbox is unavailable.
> 2. **Dangerous-command rejection** (`src/utils/dangerous.zig` +
>    `src/utils/dangerous_patterns.zig`): blacklisted shell operators/commands are
>    rejected before execution.
> 3. **Platform sandbox** (`src/utils/sandbox.zig`): Seatbelt (macOS), Landlock
>    (Linux), Job Objects (Windows) with a workspace allow-list.

---

## Key Commands Inside the App

These are slash commands available in the TUI input area:

| Command | Description |
|---------|-------------|
| `/model <name>` | Switch LLM model |
| `/apikey <key>` | Set API key persistently |
| `/clear` | Clear conversation |
| `/compact` | Summarize old messages to reduce token usage |
| `/save` | Save current session to disk |
| `/load` | Load a saved session |
| `/status` | Show context usage and budget |
| `/mcp` | (Re)load MCP servers from `~/.zeepseek/mcp.json` and expose their tools |
| `/skill <name>` | Activate a skill (prompt injection) |
| `/skill install <owner>/<repo>` | Clone + register a GitHub-hosted skill |
| `/new` | Start a fresh session |

---

## File Reference

| File | Role |
|------|------|
| `build.zig` | Build definition — executable, test runner, module graph |
| `build.zig.zon` | Package manifest — dependency URLs and hashes |
| `src/zeepseek_c.h` | C header for `translateC` (POSIX + sandbox APIs) |
| `src/test_runner.zig` | Aggregates all inline tests for `zig build test` |
| `src/ui/app.zig` | **Main entry point** — root Model, Update, View |
| `readme.md` | Human-facing quick-start guide |
| `docs/ARCHITECTURE.md` | High-level architecture diagram and layer descriptions |

---

## Notes for Agents

- **Do not assume a `tests/` directory** exists for new tests. Put inline tests in the source file and register the import in `src/test_runner.zig`.
- **Do not change `build.zig.zon` hashes** unless you have verified the new tarball hash with the Zig package manager.
- **Respect the layer boundaries**: `utils` imports nothing; `storage` only imports `utils`; `net` imports `utils` and `storage`; `dispatch` imports everything below it; `ui` imports all lower layers.
- **Config thresholds** are validated at `comptime` in multiple modules. If you change one threshold, ensure the ordering invariants (e.g., `fold_warn < fold_aggressive < fold_exit < fold_emergency`) are preserved everywhere.
- **The TUI uses a custom Zenburn Noir palette** with 24-bit truecolor ANSI codes. Any new UI rendering should respect the `Pal` constants in `src/ui/app.zig` or `src/ui/theme.zig`.
