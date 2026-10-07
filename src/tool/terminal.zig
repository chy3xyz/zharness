//! `terminal_*` — persistent shell sessions (alignment with upstream
//! dsh-terminal). One background \`/bin/sh\` per terminal with merged
//! stdout/stderr captured by a reader thread into a byte buffer.
//!
//! This is intentionally not a full PTY: no window-size, no job control, no
//! terminal emulation. It gives the model a long-lived shell whose cwd/env
//! survive across calls, plus an incremental read buffer.

const std = @import("std");
const model = @import("../model/model.zig");
const tool_reg = @import("registry.zig");
const builtin = @import("builtin.zig");

pub const ToolCall = builtin.ToolCall;
pub const ToolResult = builtin.ToolResult;
pub const freeResult = builtin.freeResult;

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

/// Minimal test-and-set spin lock with sleep backoff (codebase pattern;
/// std.Thread.Mutex is not in the 0.17 module set).
const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),
    fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins >= 16) {
                const req: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
                _ = nanosleep(&req, null);
            } else std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

const sigterm: c_int = 15;
const max_buffer: usize = 1 << 20; // 1 MiB per terminal

pub const Terminal = struct {
    alloc: std.mem.Allocator,
    id: []u8,
    label: []u8,
    pid: c_int,
    in_fd: c_int,
    out_fd: c_int,
    mutex: SpinLock = .{},
    out: std.ArrayList(u8) = .empty,
    alive: bool = true,
    thread: ?std.Thread = null,
};

var g_lock: SpinLock = .{};
var g_terms: ?std.StringHashMap(*Terminal) = null;
var g_seq: u64 = 0;

fn map() *std.StringHashMap(*Terminal) {
    if (g_terms == null) g_terms = std.StringHashMap(*Terminal).init(std.heap.page_allocator);
    return &g_terms.?;
}

fn sleepMs(ms: u64) void {
    const req: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = nanosleep(&req, null);
}

fn readerLoop(t: *Terminal) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = read(t.out_fd, &buf, buf.len);
        if (n <= 0) break;
        t.mutex.lock();
        defer t.mutex.unlock();
        if (t.out.items.len < max_buffer) {
            t.out.appendSlice(t.alloc, buf[0..@intCast(n)]) catch {};
        }
    }
    t.mutex.lock();
    t.alive = false;
    t.mutex.unlock();
}

/// Spawn a persistent shell. Returns the registry-owned terminal id.
pub fn open(alloc: std.mem.Allocator, label: []const u8) ![]const u8 {
    var in_pipe: [2]c_int = undefined;
    var out_pipe: [2]c_int = undefined;
    if (pipe(&in_pipe) != 0) return error.PipeFailed;
    if (pipe(&out_pipe) != 0) {
        _ = close(in_pipe[0]);
        _ = close(in_pipe[1]);
        return error.PipeFailed;
    }
    const pid = fork();
    if (pid < 0) {
        _ = close(in_pipe[0]);
        _ = close(in_pipe[1]);
        _ = close(out_pipe[0]);
        _ = close(out_pipe[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = dup2(in_pipe[0], 0);
        _ = dup2(out_pipe[1], 1);
        _ = dup2(out_pipe[1], 2);
        _ = close(in_pipe[0]);
        _ = close(in_pipe[1]);
        _ = close(out_pipe[0]);
        _ = close(out_pipe[1]);
        var argv = [_:null]?[*:0]const u8{ "/bin/sh", null };
        _ = execv("/bin/sh", &argv);
        _exit(127);
    }
    _ = close(in_pipe[0]);
    _ = close(out_pipe[1]);

    const t = try alloc.create(Terminal);
    errdefer alloc.destroy(t);
    g_lock.lock();
    g_seq += 1;
    const id = try std.fmt.allocPrint(alloc, "term-{d}", .{g_seq});
    const label_c = try alloc.dupe(u8, label);
    g_lock.unlock();
    t.* = .{
        .alloc = alloc,
        .id = id,
        .label = label_c,
        .pid = pid,
        .in_fd = in_pipe[1],
        .out_fd = out_pipe[0],
    };
    t.thread = std.Thread.spawn(.{}, readerLoop, .{t}) catch null;

    g_lock.lock();
    defer g_lock.unlock();
    map().put(id, t) catch {
        return error.OutOfMemory;
    };
    return id;
}

fn lookup(id: []const u8) ?*Terminal {
    g_lock.lock();
    defer g_lock.unlock();
    return (g_terms orelse return null).get(id);
}

pub fn send(id: []const u8, data: []const u8) !void {
    const t = lookup(id) orelse return error.UnknownTerminal;
    if (write(t.in_fd, data.ptr, data.len) < 0) return error.WriteFailed;
}

/// Drain buffered output (ownership transfers to the caller).
pub fn readOut(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    const t = lookup(id) orelse return error.UnknownTerminal;
    t.mutex.lock();
    defer t.mutex.unlock();
    const chunk = try alloc.dupe(u8, t.out.items);
    t.out.clearRetainingCapacity();
    return chunk;
}

pub fn listJson(alloc: std.mem.Allocator) ![]u8 {
    g_lock.lock();
    defer g_lock.unlock();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"terminals\":[");
    var first = true;
    if (g_terms) |*m| {
        var it = m.iterator();
        while (it.next()) |e| {
            const t = e.value_ptr.*;
            if (!first) try out.append(alloc, ',');
            first = false;
            try out.appendSlice(alloc, "{\"id\":\"");
            try out.appendSlice(alloc, t.id);
            try out.appendSlice(alloc, "\",\"label\":\"");
            try model.escape(alloc, t.label, &out);
            try out.appendSlice(alloc, "\",\"alive\":");
            try out.appendSlice(alloc, if (t.alive) "true" else "false");
            try out.appendSlice(alloc, "}");
        }
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

pub fn closeTerminal(id: []const u8) !void {
    g_lock.lock();
    const removed = if (g_terms) |*m| m.fetchRemove(id) else null;
    g_lock.unlock();
    const kv = removed orelse return error.UnknownTerminal;
    const t = kv.value;
    _ = kill(t.pid, sigterm);
    if (t.thread) |th| th.join();
    _ = close(t.in_fd);
    _ = close(t.out_fd);
    t.mutex.lock();
    t.out.deinit(t.alloc);
    t.mutex.unlock();
    t.alloc.free(t.id);
    t.alloc.free(t.label);
    t.alloc.destroy(t);
}

// ── tools ───────────────────────────────────────────────────────────────────

pub const definitions = [_]tool_reg.ToolDefinition{
    .{
        .name = "terminal_open",
        .description = "Start a persistent shell (/bin/sh). Returns a terminal id; state (cwd, env) persists across terminal_send calls.",
        .category = .shell,
        .parameters_json =
        \\{"type":"object","properties":{"label":{"type":"string","description":"Optional short label"}},"required":[]}
        ,
    },
    .{
        .name = "terminal_send",
        .description = "Write to a terminal's stdin (include a trailing newline to run a command).",
        .category = .shell,
        .parameters_json =
        \\{"type":"object","properties":{"id":{"type":"string"},"data":{"type":"string"}},"required":["id","data"]}
        ,
    },
    .{
        .name = "terminal_read",
        .description = "Drain output buffered since the last read.",
        .category = .shell,
        .parameters_json =
        \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}
        ,
    },
    .{
        .name = "terminal_list",
        .description = "List live terminals as JSON.",
        .category = .shell,
        .parameters_json =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .{
        .name = "terminal_close",
        .description = "Kill a terminal and free its resources.",
        .category = .shell,
        .parameters_json =
        \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}
        ,
    },
};

pub fn register(reg: *tool_reg.ToolRegistry) !void {
    for (definitions) |d| try reg.register(d);
}

pub fn isTerminalTool(name: []const u8) bool {
    for (definitions) |d| {
        if (std.mem.eql(u8, name, d.name)) return true;
    }
    return false;
}

fn fail(alloc: std.mem.Allocator, msg: []const u8) !ToolResult {
    return .{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, msg) };
}

pub fn execute(alloc: std.mem.Allocator, call: ToolCall) !ToolResult {
    const name = call.name;
    if (std.mem.eql(u8, name, "terminal_list")) {
        return .{ .success = true, .output = try listJson(alloc) };
    }
    if (std.mem.eql(u8, name, "terminal_open")) {
        const label = (try model.extractStringField(alloc, call.arguments, "label")) orelse
            try alloc.dupe(u8, "shell");
        defer alloc.free(label);
        const id = try open(std.heap.page_allocator, label);
        return .{ .success = true, .output = try std.fmt.allocPrint(alloc, "terminal {s} started", .{id}) };
    }
    if (std.mem.eql(u8, name, "terminal_send")) {
        const id = (try model.extractStringField(alloc, call.arguments, "id")) orelse
            return fail(alloc, "terminal_send: missing 'id'");
        defer alloc.free(id);
        const data = (try model.extractStringField(alloc, call.arguments, "data")) orelse
            return fail(alloc, "terminal_send: missing 'data'");
        defer alloc.free(data);
        send(id, data) catch |e| return fail(alloc, @errorName(e));
        return .{ .success = true, .output = try alloc.dupe(u8, "") };
    }
    if (std.mem.eql(u8, name, "terminal_read")) {
        const id = (try model.extractStringField(alloc, call.arguments, "id")) orelse
            return fail(alloc, "terminal_read: missing 'id'");
        defer alloc.free(id);
        const chunk = readOut(alloc, id) catch |e| return fail(alloc, @errorName(e));
        return .{ .success = true, .output = chunk };
    }
    if (std.mem.eql(u8, name, "terminal_close")) {
        const id = (try model.extractStringField(alloc, call.arguments, "id")) orelse
            return fail(alloc, "terminal_close: missing 'id'");
        defer alloc.free(id);
        closeTerminal(id) catch |e| return fail(alloc, @errorName(e));
        return .{ .success = true, .output = try std.fmt.allocPrint(alloc, "terminal {s} closed", .{id}) };
    }
    return fail(alloc, "unknown terminal tool");
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "terminal open/send/read/close round-trip" {
    const alloc = testing.allocator;
    const id = try open(alloc, "t");
    var closed = false;
    defer if (!closed) closeTerminal(id) catch {};

    try send(id, "echo zh-terminal-ok\n");
    var got: []u8 = try alloc.dupe(u8, "");
    defer alloc.free(got);
    var tries: usize = 0;
    while (tries < 60) : (tries += 1) {
        sleepMs(50);
        const chunk = readOut(alloc, id) catch break;
        if (chunk.len > 0) {
            const merged = try std.mem.concat(alloc, u8, &.{ got, chunk });
            alloc.free(got);
            alloc.free(chunk);
            got = merged;
        }
        if (std.mem.indexOf(u8, got, "zh-terminal-ok") != null) break;
    }
    try testing.expect(std.mem.indexOf(u8, got, "zh-terminal-ok") != null);

    closeTerminal(id) catch {};
    closed = true;
}
