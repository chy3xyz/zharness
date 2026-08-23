//! dlopen/dlsym/dlclose wrappers for the zharness Plugin ABI.
//!
//! Thin extern-"c" bindings over the platform dynamic loader (macOS dyld /
//! Linux glibc) plus a RAII-ish `LoadedPlugin` that owns the library handle,
//! its resolved vtable, and the borrowed manifest pointer. `deinit` unloads
//! (dlclose); nothing here allocates beyond the stored path string, so
//! cleanup is trivially leak-free.
//!
//! The loader never lets a dl error escape as a panic: every failure mode is
//! an error union consumed by loader.zig and turned into a report entry.

const std = @import("std");
const capi = @import("capi.zig");

// ── raw dynamic-loader bindings ──────────────────────────────────────────

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: *anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn dlclose(handle: *anyopaque) c_int;
extern "c" fn dlerror() ?[*:0]u8;

/// RTLD_NOW | RTLD_LOCAL — resolve all symbols up front (fail fast on
/// plugins missing dependencies) and keep plugin symbols out of the global
/// namespace so two plugins cannot shadow each other.
const RTLD_MODE: c_int = 2; // RTLD_NOW (RTLD_LOCAL == 0 on macOS and glibc)

/// Errors surfaced by the dynamic-loader layer. `OutOfMemory` comes from the
/// path sentinel copy in `LoadedPlugin.load`.
pub const LoadError = error{
    /// dlopen failed — file missing, wrong arch, undefined deps, …
    OpenFailed,
    /// dlsym failed — one of the four ABI symbols is not exported.
    SymbolMissing,
    OutOfMemory,
};

/// Resolve one symbol; dlsym returns NULL both for "missing" and for a
/// symbol whose value is NULL — neither is acceptable for ABI functions.
fn lookup(handle: *anyopaque, symbol: [*:0]const u8) LoadError!*anyopaque {
    return dlsym(handle, symbol) orelse LoadError.SymbolMissing;
}

/// Best-effort copy of the most recent loader diagnostic (dlerror(3)) into
/// `buf`. Returns the copied slice (possibly empty). The dl message is
/// thread-local and invalidated by the next loader call — copy it if you
/// need to keep it.
pub fn lastErrorText(buf: []u8) []const u8 {
    const msg = dlerror() orelse return buf[0..0];
    const s = std.mem.span(msg);
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

// ── RAII-ish loaded plugin ───────────────────────────────────────────────

pub const LoadedPlugin = struct {
    /// Allocator used for `path`; also the identity of the owner scope.
    alloc: std.mem.Allocator,
    /// dlopen handle. Valid until `deinit`.
    handle: *anyopaque,
    /// Path the plugin was loaded from (NUL-terminated, host-owned).
    path: [:0]u8,
    /// The four resolved ABI entry points.
    vtable: capi.VTable,
    /// Borrowed pointer to the plugin's manifest JSON (plugin-owned static
    /// storage). Only valid while the plugin stays loaded; callers that need
    /// the text after unload must copy it first.
    manifest_ptr: [*:0]const u8,

    /// Open `path` with the platform loader and resolve all four ABI symbols.
    /// Does NOT validate abi version / manifest content — that belongs to
    /// loader.zig so it can be exercised without dlopen where possible.
    pub fn load(alloc: std.mem.Allocator, path: []const u8) LoadError!LoadedPlugin {
        const path_z = try alloc.dupeSentinel(u8, path, 0);
        errdefer alloc.free(path_z);

        const handle = dlopen(path_z.ptr, RTLD_MODE) orelse return LoadError.OpenFailed;
        errdefer _ = dlclose(handle);

        const vtable = capi.VTable{
            .abi_version = @ptrCast(@alignCast(try lookup(handle, capi.SYM_ABI_VERSION))),
            .manifest = @ptrCast(@alignCast(try lookup(handle, capi.SYM_MANIFEST))),
            .execute = @ptrCast(@alignCast(try lookup(handle, capi.SYM_EXECUTE))),
            .string_free = @ptrCast(@alignCast(try lookup(handle, capi.SYM_STRING_FREE))),
        };

        return .{
            .alloc = alloc,
            .handle = handle,
            .path = path_z,
            .vtable = vtable,
            .manifest_ptr = vtable.manifest(),
        };
    }

    /// Unload the library and free the owned path. Idempotent-safe when
    /// called once from the owning registry; do not touch other fields after.
    pub fn deinit(self: *LoadedPlugin) void {
        _ = dlclose(self.handle);
        self.alloc.free(self.path);
        self.handle = undefined;
    }

    /// Manifest JSON view into plugin memory (borrowed — see field doc).
    pub fn manifest(self: *const LoadedPlugin) []const u8 {
        return std.mem.span(self.manifest_ptr);
    }

    /// Path as a plain (non-sentinel) slice.
    pub fn pathSlice(self: *const LoadedPlugin) []const u8 {
        return self.path;
    }
};
