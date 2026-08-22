//! Zeepseek Test Runner
//! Imports all modules with inline tests so `zig build test` discovers them.
//!
//! NOTE (Zig 0.17-dev): a plain top-level `const _m = @import(...)` does NOT
//! register a module's tests in this compiler build — the import must be
//! referenced from a `comptime` block for test collection to see it.

const std = @import("std");

comptime {
    _ = @import("net/http_client.zig");
    _ = @import("net/h2_client_test.zig");
    _ = @import("net/vendor/raw_io_test.zig");
    _ = @import("net/vendor/tls_compile_test.zig");
    _ = @import("net/vendor/h2_compile_test.zig");
    _ = @import("storage/keyspace.zig");
    _ = @import("storage/store_api.zig");
    _ = @import("storage/migrations.zig");
    _ = @import("storage/recovery.zig");
    _ = @import("utils/dangerous.zig");
    _ = @import("utils/dangerous_patterns.zig");
    _ = @import("i18n/manager.zig");
    _ = @import("i18n/strings.zig");
    _ = @import("providers/models.zig");
    _ = @import("providers/manager.zig");
    _ = @import("acp/mod.zig");
    _ = @import("acp/zed_adapter.zig");
    _ = @import("utils/config.zig");
    _ = @import("tools/mod.zig");
    _ = @import("tools/process.zig");
    _ = @import("tools/file.zig");
    _ = @import("tools/shell.zig");
    _ = @import("skills/manifest.zig");
    _ = @import("skills/installer.zig");
    _ = @import("skills/registry.zig");
    _ = @import("utils/tokenizer.zig");
    _ = @import("utils/validation.zig");
    _ = @import("utils/exec_policy.zig");
    _ = @import("utils/tool_registry.zig");
    _ = @import("utils/notifications.zig");
    _ = @import("utils/sandbox.zig");
    _ = @import("cache/reasonix.zig");
    _ = @import("dispatch/context_manager.zig");
    _ = @import("dispatch/cache_first_loop.zig");
    _ = @import("storage/store.zig");
    _ = @import("storage/session_manager.zig");
    _ = @import("storage/session_format.zig");
    _ = @import("storage/mmap_store.zig");
    _ = @import("agent/subagent.zig");
    _ = @import("agent/sub_worker.zig");
    _ = @import("net/stream_client.zig");
    _ = @import("ui/app.zig");
    _ = @import("ui/slash_command_dispatcher.zig");
    _ = @import("net/mcp_client.zig");
    _ = @import("net/mcp_runner.zig");
}
