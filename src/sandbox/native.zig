//! OS-level sandbox confinement — the kernel/OS boundary behind
//! `sandbox.Level.native`.
//!
//! - macOS: `/usr/bin/sandbox-exec` (Seatbelt) with a generated profile that
//!   allows writes only under the workspace cwd, temp areas and /dev.
//! - Linux: `bwrap` (bubblewrap) when present, binding the root read-only and
//!   the workspace read-write.
//!
//! When neither is available `detect()` returns `.none` and callers fall back
//! to the deny-list + env-allowlist pre-filter (which is explicitly *not* a
//! security boundary).

const std = @import("std");

pub const seatbelt_path = "/usr/bin/sandbox-exec";
pub const bwrap_paths = [_][*:0]const u8{ "/usr/bin/bwrap", "/usr/local/bin/bwrap" };

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
const x_ok: c_int = 1;

pub const Kind = enum { none, seatbelt, bwrap };

/// Probe the host (cheap: a couple of `access` syscalls).
pub fn detect() Kind {
    if (access(seatbelt_path, x_ok) == 0) return .seatbelt;
    for (bwrap_paths) |p| {
        if (access(p, x_ok) == 0) return .bwrap;
    }
    return .none;
}

pub fn available() bool {
    return detect() != .none;
}

fn appendSbString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(alloc, '\\');
        try out.append(alloc, c);
    }
    try out.append(alloc, '"');
}

fn appendShellQuoted(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else try out.append(alloc, c);
    }
    try out.append(alloc, '\'');
}

/// Seatbelt profile: allow defaults, deny all writes, then re-allow writes
/// under the workspace cwd, temp areas and device nodes.
pub fn seatbeltProfile(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "(version 1)\n(allow default)\n(deny file-write*)\n");
    const writable = [_][]const u8{ cwd, "/tmp", "/private/tmp", "/private/var/folders", "/dev" };
    for (writable) |p| {
        try out.appendSlice(alloc, "(allow file-write* (subpath ");
        try appendSbString(alloc, &out, p);
        try out.appendSlice(alloc, "))\n");
    }
    return out.toOwnedSlice(alloc);
}

/// Wrap shell command `inner` so it runs confined. Returns null when no OS
/// mechanism is available; caller frees the returned string.
pub fn confine(alloc: std.mem.Allocator, cwd: []const u8, inner: []const u8) !?[]u8 {
    switch (detect()) {
        .none => return null,
        .seatbelt => {
            const profile = try seatbeltProfile(alloc, cwd);
            defer alloc.free(profile);
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            try out.appendSlice(alloc, seatbelt_path);
            try out.appendSlice(alloc, " -p ");
            try appendShellQuoted(alloc, &out, profile);
            try out.appendSlice(alloc, " /bin/sh -c ");
            try appendShellQuoted(alloc, &out, inner);
            return try out.toOwnedSlice(alloc);
        },
        .bwrap => {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            try out.appendSlice(alloc, "bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --bind ");
            try appendShellQuoted(alloc, &out, cwd);
            try out.appendSlice(alloc, " ");
            try appendShellQuoted(alloc, &out, cwd);
            try out.appendSlice(alloc, " /bin/sh -c ");
            try appendShellQuoted(alloc, &out, inner);
            return try out.toOwnedSlice(alloc);
        },
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "seatbelt profile denies writes and names the workspace" {
    const alloc = testing.allocator;
    const p = try seatbeltProfile(alloc, "/tmp/ws");
    defer alloc.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "(deny file-write*)") != null);
    try testing.expect(std.mem.indexOf(u8, p, "(allow file-write* (subpath \"/tmp/ws\"))") != null);
    try testing.expect(std.mem.indexOf(u8, p, "/private/var/folders") != null);
}

test "confine wraps only when a mechanism is available" {
    const alloc = testing.allocator;
    if (try confine(alloc, "/tmp/ws", "echo hi")) |w| {
        defer alloc.free(w);
        try testing.expect(std.mem.indexOf(u8, w, "/bin/sh -c") != null);
    }
}
