//! Per-preset agent-instructions loader (upstream agent-instructions parity).
//!
//! Upstream loads an optional instruction file per preset and appends its
//! content to the system prompt after the persona. zharness mirrors that:
//!
//!   1. `<cwd>/.zharness/instructions/<preset>.md`   (workspace-scoped)
//!   2. `$HOME/.zharness/instructions/<preset>.md`   (user-global fallback)
//!
//! The first existing file wins. Files larger than `max_bytes` (64 KiB) are
//! rejected with error.InstructionsTooLarge rather than truncated — a silent
//! cut would ship half a policy to the model. Content is whitespace-trimmed;
//! a file that is empty after trimming counts as absent (null).
//!
//! Contract: `loadFor` returns an OWNED slice the caller must free, or null
//! when no instructions exist. File IO goes through libc stdio
//! (`fopen`/`fread`) so the signature stays `(alloc, cwd, preset_name)`
//! without threading a `std.Io` handle — same rationale as clib.zig's popen
//! helpers. Tests run offline against /tmp fixtures.
//!
//! Integrator hook: call after the preset fragment is appended in
//! main.zig::buildLoop and append to the effective system prompt:
//!
//!     const instr = try instructions.loadFor(alloc, cfg.cwd, preset_name);
//!     if (instr) |text| {
//!         defer alloc.free(text);
//!         system_prompt = try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ system_prompt, text });
//!     }

const std = @import("std");

/// Hard ceiling per upstream: instruction files above 64 KiB are refused.
pub const max_bytes: usize = 64 * 1024;

/// Load instructions for `preset_name`, workspace file first, then the
/// user-global fallback under $HOME. Returns null when neither exists.
/// Caller frees the returned slice.
pub fn loadFor(
    alloc: std.mem.Allocator,
    cwd: []const u8,
    preset_name: []const u8,
) !?[]const u8 {
    const file_name = try std.fmt.allocPrint(alloc, "{s}.md", .{preset_name});
    defer alloc.free(file_name);
    if (cwd.len > 0) {
        const ws_path = try std.fs.path.join(alloc, &.{ cwd, ".zharness", "instructions", file_name });
        defer alloc.free(ws_path);
        if (try readCapped(alloc, ws_path)) |content| return content;
    }
    const home_c = std.c.getenv("HOME") orelse return null;
    const home = std.mem.sliceTo(home_c, 0);
    if (home.len == 0) return null;
    const home_path = try std.fs.path.join(alloc, &.{ home, ".zharness", "instructions", file_name });
    defer alloc.free(home_path);
    return readCapped(alloc, home_path);
}

/// Read up to max_bytes from `path`; oversize → error.InstructionsTooLarge,
/// unreadable/missing → null, empty-after-trim → null. Caller owns success.
fn readCapped(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (path.len >= 4096) return null;
    const path_z = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(path_z);

    const f = std.c.fopen(path_z.ptr, "rb") orelse return null;
    // fclose runs on every exit path; the error below must not leak the stream.
    var closed = false;
    defer if (!closed) {
        _ = std.c.fclose(f);
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, f);
        if (n == 0) break; // EOF (read errors surface as short reads too)
        if (out.items.len + n > max_bytes) return error.InstructionsTooLarge;
        try out.appendSlice(alloc, buf[0..n]);
    }
    closed = true;
    _ = std.c.fclose(f);

    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    if (trimmed.len == 0) {
        out.deinit(alloc);
        return null;
    }
    // Move into an exact-size allocation: `out` may hold spare capacity and
    // the trimmed view aliases it, which would make free(out.items) wrong.
    const owned = try alloc.dupe(u8, trimmed);
    out.deinit(alloc);
    return owned;
}

// ── tests ───────────────────────────────────────────────────────────────────

var env_counter: u32 = 0;

pub const TestEnv = struct {
    t: std.Io.Threaded,
    dir: []u8,

    /// Threaded must own a threadsafe allocator for its worker machinery
    /// (same caveat as session/checkpoint.zig's TestEnv); the dir itself is
    /// allocated with the testing allocator.
    pub fn setup(alloc: std.mem.Allocator) !TestEnv {
        env_counter += 1;
        var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
        const dir = try std.fmt.allocPrint(alloc, "/tmp/zh_instr_{d}_{d}", .{ nowSecs(), env_counter });
        errdefer alloc.free(dir);
        const cwd = std.Io.Dir.cwd();
        try std.Io.Dir.createDirPath(cwd, t.io(), dir);
        return .{ .t = t, .dir = dir };
    }

    pub fn teardown(self: *TestEnv, alloc: std.mem.Allocator) void {
        defer self.t.deinit();
        defer alloc.free(self.dir);
        const slash = std.mem.lastIndexOfScalar(u8, self.dir, '/') orelse return;
        const cwd = std.Io.Dir.cwd();
        var parent = std.Io.Dir.openDir(cwd, self.t.io(), self.dir[0..slash], .{}) catch return;
        defer parent.close(self.t.io());
        std.Io.Dir.deleteTree(parent, self.t.io(), self.dir[slash + 1 ..]) catch {};
    }

    pub fn io(self: *TestEnv) std.Io {
        return self.t.io();
    }
};

extern "c" fn time(tloc: ?*c_long) c_long;

fn nowSecs() i64 {
    return @intCast(time(null));
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Saved HOME for the override/restore pair below.
var saved_home_buf: [4096]u8 = undefined;
var saved_home_len: usize = 0;
var saved_home_valid = false;

fn overrideHome(fake_home: []const u8) !void {
    const old = std.c.getenv("HOME");
    saved_home_valid = old != null;
    if (old) |h| {
        const hs = std.mem.sliceTo(h, 0);
        saved_home_len = @min(hs.len, saved_home_buf.len);
        @memcpy(saved_home_buf[0..saved_home_len], hs[0..saved_home_len]);
    }
    if (fake_home.len >= 4096) return error.NameTooLong;
    var buf: [4096:0]u8 = undefined;
    @memcpy(buf[0..fake_home.len], fake_home);
    buf[fake_home.len] = 0;
    if (setenv("HOME", buf[0..fake_home.len :0].ptr, 1) != 0) return error.Unexpected;
}

fn restoreHome() void {
    if (saved_home_valid) {
        saved_home_buf[saved_home_len] = 0;
        _ = setenv("HOME", saved_home_buf[0..saved_home_len :0].ptr, 1);
    } else {
        _ = unsetenv("HOME");
    }
}

/// Write `data` to `<dir>/<rel>` creating parents. Uses the Threaded io from
/// the env so tests never depend on process-cwd state.
pub fn writeFile(env: *TestEnv, rel: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const full = try std.fs.path.join(std.heap.page_allocator, &.{ env.dir, rel });
    defer std.heap.page_allocator.free(full);
    if (std.fs.path.dirname(full)) |parent| {
        std.Io.Dir.createDirPath(cwd, env.io(), parent) catch {};
    }
    try std.Io.Dir.writeFile(cwd, env.io(), .{ .sub_path = full, .data = data });
}

test "workspace instructions exist, load, and trim" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);
    try writeFile(&env, ".zharness/instructions/ptc.md", "\n  batch tool calls aggressively \n\n");

    const got = (try loadFor(alloc, env.dir, "ptc")) orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("batch tool calls aggressively", got);
}

test "missing files yield null" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);
    // Neither workspace nor HOME copy exists for this name.
    try std.testing.expect((try loadFor(alloc, env.dir, "no_such_preset")) == null);
}

test "empty-after-trim file counts as absent" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);
    try writeFile(&env, ".zharness/instructions/minimal.md", "  \n\t\r\n");
    try std.testing.expect((try loadFor(alloc, env.dir, "minimal")) == null);
}

test "workspace file wins over home fallback" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);

    const fake_home = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/fakehome", .{env.dir});
    defer std.heap.page_allocator.free(fake_home);
    try writeFile(&env, ".zharness/instructions/dup.md", "workspace version");
    {
        var home_env = TestEnv{ .t = env.t, .dir = @constCast(fake_home) };
        try writeFile(&home_env, ".zharness/instructions/dup.md", "home version");
    }

    try overrideHome(fake_home);
    defer restoreHome();

    const got = (try loadFor(alloc, env.dir, "dup")) orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("workspace version", got);
}

test "home fallback used when workspace has no file" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);

    // HOME points at <env.dir>/fakehome; workspace dir has no instructions.
    const fake_home = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/fakehome", .{env.dir});
    defer std.heap.page_allocator.free(fake_home);
    {
        var sub_env = TestEnv{ .t = env.t, .dir = @constCast(fake_home) };
        try writeFile(&sub_env, ".zharness/instructions/creative.md", "user-global policy");
    }

    try overrideHome(fake_home);
    defer restoreHome();

    const got = (try loadFor(alloc, env.dir, "creative")) orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("user-global policy", got);
}

test "oversize file rejected with InstructionsTooLarge" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);

    const big = try alloc.alloc(u8, max_bytes + 1);
    defer alloc.free(big);
    @memset(big, 'x');
    try writeFile(&env, ".zharness/instructions/huge.md", big);
    try std.testing.expectError(error.InstructionsTooLarge, loadFor(alloc, env.dir, "huge"));

    // Exactly at the cap is fine.
    const exact = big[0..max_bytes];
    try writeFile(&env, ".zharness/instructions/exact.md", exact);
    const got = (try loadFor(alloc, env.dir, "exact")) orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try std.testing.expectEqual(max_bytes, got.len);
}
