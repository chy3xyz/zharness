//! Thin libc bindings that Zig 0.17's `std.c` does not expose directly.
//!
//! `popen`/`pclose` are POSIX process-pipe helpers we rely on for shell
//! execution and the curl-backed chat client. They are declared as extern
//! C functions (linking libc, which the build already does via `link_libc`).

const std = @import("std");

pub const FILE = std.c.FILE;

extern fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn pclose(stream: *FILE) c_int;

/// Read one line from stdin (fd 0) without the trailing newline. Caller owns
/// the returned slice. Returns `null` at EOF with no data read. Uses the
/// POSIX `read` syscall directly since `std.c.stdin`/`fgets` are not exposed
/// by Zig 0.17's `std.c`.
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;

pub fn readLineStdin(alloc: std.mem.Allocator) !?[]u8 {
    var line = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer line.deinit(alloc);
    var buf: [1]u8 = undefined;
    while (true) {
        const n = read(0, &buf, 1);
        if (n <= 0) {
            if (line.items.len == 0) return null;
            break;
        }
        const ch = buf[0];
        if (ch == '\n') break;
        if (ch == '\r') continue;
        try line.append(alloc, ch);
        if (line.items.len >= 1024 * 1024) break; // safety cap
    }
    return try line.toOwnedSlice(alloc);
}

/// Current Unix timestamp in seconds (POSIX `time`).
extern fn time(tloc: ?*c_long) c_long;

/// Remove a file by path (POSIX `remove`).
extern fn remove(path: [*:0]const u8) c_int;

/// Current Unix time in seconds.
pub fn nowTimestamp() i64 {
    return @intCast(time(null));
}

/// Delete `path`; errors are ignored (e.g. file already gone).
pub fn removeFile(path: []const u8) void {
    const path_z = std.heap.page_allocator.dupeSentinel(u8, path, 0) catch return;
    defer std.heap.page_allocator.free(path_z);
    _ = remove(path_z.ptr);
}

/// Run `command` through `/bin/sh -c` and return a read pipe. Caller must
/// `pclosePipe` the returned handle.
pub fn popenRead(command_z: [*:0]const u8) ?*FILE {
    return popen(command_z, "r");
}

/// Close a pipe opened with `popenRead`. Returns the command's exit status.
pub fn pclosePipe(stream: *FILE) c_int {
    return pclose(stream);
}

// ── private temp files (security hardening) ────────────────────────────────

extern fn mkstemp(template: [*:0]u8) c_int;
extern fn close(fd: c_int) c_int;
extern fn unlink(path: [*:0]const u8) c_int;

/// Create a private (mode 0600, mkstemp(3)) temp file under $TMPDIR (or
/// /tmp). Returns the NUL-terminated path allocated with `alloc`; the caller
/// owns it and must `unlinkPath` it when done. Returns null when mkstemp
/// fails (errno-based; callers surface their own error).
pub fn createPrivateTemp(alloc: std.mem.Allocator, prefix: []const u8) !?[:0]u8 {
    const td = std.c.getenv("TMPDIR");
    const tmpdir: []const u8 = if (td) |p| std.mem.span(p) else "/tmp";
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, tmpdir);
    if (tmpdir.len == 0 or tmpdir[tmpdir.len - 1] != '/') try buf.append(alloc, '/');
    try buf.appendSlice(alloc, prefix);
    try buf.appendSlice(alloc, "XXXXXX");
    try buf.append(alloc, 0); // sentinel; not part of the template passed below
    const path: [:0]u8 = buf.items[0 .. buf.items.len - 1 :0];
    const fd = mkstemp(path.ptr); // mutates the XXXXXX suffix in place
    if (fd < 0) {
        buf.deinit(alloc);
        return null;
    }
    _ = close(fd);
    // Copy into an exact-size allocation before returning: `path` above is a
    // view into buf's over-capacity buffer, and callers free() the returned
    // slice by its own length — that mismatches the backing allocation and
    // trips the DebugAllocator ("Invalid free"). An exact-size sentinel alloc
    // keeps alloc/free symmetric.
    const out = try alloc.allocSentinel(u8, buf.items.len - 1, 0);
    errdefer alloc.free(out);
    @memcpy(out, buf.items[0 .. buf.items.len - 1]);
    buf.deinit(alloc);
    return out;
}

/// Best-effort unlink; errors ignored (file may already be gone).
pub fn unlinkPath(path: [:0]const u8) void {
    _ = unlink(path.ptr);
}

// ── atomic persistence ──────────────────────────────────────────────────────

extern fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) c_int;

/// Rename `old_path` to `new_path` (POSIX atomic on same filesystem).
/// Returns false when the syscall fails.
pub fn renamePath(old_path: []const u8, new_path: []const u8) bool {
    var oz: [4096:0]u8 = undefined;
    var nz: [4096:0]u8 = undefined;
    if (old_path.len >= oz.len or new_path.len >= nz.len) return false;
    @memcpy(oz[0..old_path.len], old_path);
    oz[old_path.len] = 0;
    @memcpy(nz[0..new_path.len], new_path);
    nz[new_path.len] = 0;
    // Explicit-end sentinel slices: validates the NUL we just wrote at len,
    // not the (undefined) tail of the buffer.
    return rename(oz[0..old_path.len :0].ptr, nz[0..new_path.len :0].ptr) == 0;
}
