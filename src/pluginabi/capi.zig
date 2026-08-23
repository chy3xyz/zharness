//! zharness Plugin ABI — the C contract every native plugin implements
//! (dev.md §XXV–XXVI).
//!
//! A plugin is a shared library (.dylib on macOS, .so on Linux) exporting
//! exactly these C symbols:
//!
//!   ┌────────────────────────┬──────────────────────────────────────────┐
//!   │ Symbol                 │ Contract                                 │
//!   ├────────────────────────┼──────────────────────────────────────────┤
//!   │ zh_plugin_abi_version  │ uint32_t (*)(void)                       │
//!   │                        │ Must return 1 (ABI_VERSION). Plugins     │
//!   │                        │ built against a different major ABI are  │
//!   │                        │ rejected before their manifest is read.  │
//!   ├────────────────────────┼──────────────────────────────────────────┤
//!   │ zh_plugin_manifest     │ const char* (*)(void)                    │
//!   │                        │ Returns a NUL-terminated UTF-8 JSON      │
//!   │                        │ document describing the plugin           │
//!   │                        │ ({"name","version","kind","tools":[…]}). │
//!   │                        │ The string lives in the plugin's own     │
//!   │                        │ static storage; the host copies it and   │
//!   │                        │ never frees it.                          │
//!   ├────────────────────────┼──────────────────────────────────────────┤
//!   │ zh_tool_execute        │ char* (*)(const char* tool_name,         │
//!   │                        │            const char* args_json)        │
//!   │                        │ Runs one tool exported by the plugin.    │
//!   │                        │ `tool_name` is the plugin-local tool     │
//!   │                        │ name from the manifest; `args_json` is   │
//!   │                        │ the model-supplied arguments verbatim    │
//!   │                        │ (an empty call arrives as "{}").         │
//!   │                        │ Returns a NUL-terminated UTF-8 JSON      │
//!   │                        │ result, or NULL on failure (the host     │
//!   │                        │ turns NULL into a failed tool result).   │
//!   │                        │ Ownership transfers to the host, which   │
//!   │                        │ MUST release it via zh_string_free.      │
//!   ├────────────────────────┼──────────────────────────────────────────┤
//!   │ zh_string_free         │ void (*)(char* s)                        │
//!   │                        │ Frees a buffer previously returned by    │
//!   │                        │ this plugin. May be called with NULL.    │
//!   └────────────────────────┴──────────────────────────────────────────┘
//!
//! Memory ownership summary:
//!   - Strings RETURNED by the plugin belong to the caller (host) and are
//!     released through zh_string_free — the host always copies what it
//!     needs into its own allocations BEFORE freeing the plugin-side buffer,
//!     so a misbehaving free can never corrupt host state.
//!   - Strings PASSED IN (tool_name, args_json) are borrowed: valid for the
//!     duration of the call only, freed by the host afterwards.
//!   - The manifest string is borrowed static storage owned by the plugin.
//!
//! Threading: calls into one plugin are made from the agent loop thread
//! only; plugins do not need internal locking beyond that guarantee.
//!
//! Lifecycle (dev.md §XXVI): Discover → Load (this module + ffi.zig) →
//! Resolve/Create/Register (loader.zig validates the manifest and projects
//! tools into the host registry) → Start/Running (zh_tool_execute calls) →
//! Stop → Destroy Scope → Unload (dlclose via LoadedPlugin.deinit /
//! PluginRegistry.deinit). init/start/stop hooks are intentionally NOT part
//! of ABI v1; stateless tools keep the surface minimal and crash-safe.

const std = @import("std");

/// Current plugin ABI version. Bump on any breaking change to the contract
/// above; the loader rejects plugins reporting anything else.
pub const ABI_VERSION: u32 = 1;

// ── exported symbol names ────────────────────────────────────────────────

pub const SYM_ABI_VERSION = "zh_plugin_abi_version";
pub const SYM_MANIFEST = "zh_plugin_manifest";
pub const SYM_EXECUTE = "zh_tool_execute";
pub const SYM_STRING_FREE = "zh_string_free";

// ── function-pointer types (C calling convention) ────────────────────────

/// `uint32_t zh_plugin_abi_version(void)`
pub const AbiVersionFn = *const fn () callconv(.c) u32;

/// `const char* zh_plugin_manifest(void)`
pub const ManifestFn = *const fn () callconv(.c) [*:0]const u8;

/// `char* zh_tool_execute(const char* tool_name, const char* args_json)`
pub const ExecuteFn = *const fn (
    tool_name: [*:0]const u8,
    args_json: [*:0]const u8,
) callconv(.c) ?[*:0]u8;

/// `void zh_string_free(char* s)`
pub const StringFreeFn = *const fn (s: ?[*:0]u8) callconv(.c) void;

/// The four entry points resolved from a loaded plugin, ready to call.
pub const VTable = struct {
    abi_version: AbiVersionFn,
    manifest: ManifestFn,
    execute: ExecuteFn,
    string_free: StringFreeFn,
};

comptime {
    // Reference the std import so the file keeps compiling standalone even
    // though the contract above is pure declaration.
    _ = std;
}
