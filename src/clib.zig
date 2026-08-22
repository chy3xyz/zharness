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
