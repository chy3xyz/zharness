//! Append-only session event log (alignment with upstream dsh session-format).
//!
//! One JSON object per line, newline-terminated. The first line of a log is a
//! version header:
//!
//!     {"v":1,"kind":"header","id":"<session id>"}
//!
//! and every later line is one message event:
//!
//!     {"v":1,"kind":"message","seq":N,"role":"user|assistant|tool|system",
//!      "content":"...","tool_call_id":<string|null>,
//!      "tool_calls_json":<string|null>}
//!
//! The log is the append-only substrate the report asks for: it is
//! seq-numbered, versioned, and read back by `readMessages`. Legacy
//! single-JSON transcripts remain readable (see session.zig), which is the
//! migration seam. `format_version` is bumped only when the event schema
//! changes incompatibly; readers reject unknown versions.

const std = @import("std");
const model_mod = @import("../model/model.zig");

pub const format_version: u32 = 1;

pub const Error = error{ UnsupportedFormatVersion, MalformedLog };

/// JSON fragment for the version header line (newline included).
pub fn headerLine(alloc: std.mem.Allocator, session_id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"v\":1,\"kind\":\"header\",\"id\":\"");
    try model_mod.escape(alloc, session_id, &out);
    try out.appendSlice(alloc, "\"}\n");
    return out.toOwnedSlice(alloc);
}

/// JSON line for one message event (newline included). Caller owns.
pub fn messageLine(alloc: std.mem.Allocator, seq: u64, m: model_mod.Message) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var nbuf: [32]u8 = undefined;
    const seq_s = std.fmt.bufPrint(&nbuf, "{d}", .{seq}) catch unreachable;
    try out.appendSlice(alloc, "{\"v\":1,\"kind\":\"message\",\"seq\":");
    try out.appendSlice(alloc, seq_s);
    try out.appendSlice(alloc, ",\"role\":\"");
    try out.appendSlice(alloc, m.role.asStr());
    try out.appendSlice(alloc, "\",\"content\":\"");
    try model_mod.escape(alloc, m.content, &out);
    try out.appendSlice(alloc, "\",\"tool_call_id\":");
    if (m.tool_call_id) |v| {
        try out.appendSlice(alloc, "\"");
        try model_mod.escape(alloc, v, &out);
        try out.appendSlice(alloc, "\"");
    } else try out.appendSlice(alloc, "null");
    try out.appendSlice(alloc, ",\"tool_calls_json\":");
    if (m.tool_calls_json) |v| {
        try out.appendSlice(alloc, "\"");
        try model_mod.escape(alloc, v, &out);
        try out.appendSlice(alloc, "\"");
    } else try out.appendSlice(alloc, "null");
    try out.appendSlice(alloc, "}\n");
    return out.toOwnedSlice(alloc);
}

/// Append bytes to `path`, creating parent directories. Not atomic; callers
/// serialize one event per call.
pub fn append(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var file: std.Io.File = undefined;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        const parent = path[0..slash];
        const name = path[slash + 1 ..];
        try std.Io.Dir.createDirPath(cwd, io, parent);
        var dir = try std.Io.Dir.openDir(cwd, io, parent, .{});
        defer std.Io.Dir.close(dir, io);
        file = try dir.createFile(io, name, .{ .truncate = false });
    } else {
        file = try cwd.createFile(io, path, .{ .truncate = false });
    }
    defer file.close(io);
    const end = try file.length(io);
    try file.writePositionalAll(io, bytes, end);
}

/// Replace `path` with `bytes` (used to (re)start a log after a clear).
pub fn overwrite(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var file: std.Io.File = undefined;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        const parent = path[0..slash];
        const name = path[slash + 1 ..];
        try std.Io.Dir.createDirPath(cwd, io, parent);
        var dir = try std.Io.Dir.openDir(cwd, io, parent, .{});
        defer std.Io.Dir.close(dir, io);
        file = try dir.createFile(io, name, .{ .truncate = true });
    } else {
        file = try cwd.createFile(io, path, .{ .truncate = true });
    }
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

fn parseRole(s: []const u8) ?model_mod.Role {
    if (std.mem.eql(u8, s, "system")) return .system;
    if (std.mem.eql(u8, s, "user")) return .user;
    if (std.mem.eql(u8, s, "assistant")) return .assistant;
    if (std.mem.eql(u8, s, "tool")) return .tool;
    return null;
}

fn freeMessage(alloc: std.mem.Allocator, m: *model_mod.Message) void {
    alloc.free(m.content);
    if (m.tool_call_id) |t| alloc.free(t);
    if (m.tool_calls_json) |t| alloc.free(t);
}

/// Read every message event from a log. `error.FileNotFound` propagates so
/// callers can fall back to a legacy transcript. Unknown header versions are
/// rejected; malformed lines are skipped (forward-compatible tolerance).
pub fn readMessages(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]model_mod.Message {
    const raw = try std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .unlimited);
    defer alloc.free(raw);

    var out: std.ArrayList(model_mod.Message) = .empty;
    errdefer {
        for (out.items) |*m| freeMessage(alloc, m);
        out.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] != '{') continue;
        if (std.mem.indexOf(u8, t, "\"kind\":\"header\"") != null) {
            const v = std.mem.indexOf(u8, t, "\"v\":") orelse continue;
            var i = v + 4;
            var n: u32 = 0;
            while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) n = n * 10 + (t[i] - '0');
            if (n != format_version) return Error.UnsupportedFormatVersion;
            continue;
        }
        if (std.mem.indexOf(u8, t, "\"kind\":\"message\"") == null) continue;

        const role_raw = try model_mod.extractStringField(alloc, t, "role");
        defer if (role_raw) |r| alloc.free(r);
        const role = parseRole(role_raw orelse "user") orelse .user;
        const content = (try model_mod.extractStringField(alloc, t, "content")) orelse
            try alloc.dupe(u8, "");
        errdefer alloc.free(content);
        const tcid = try model_mod.extractStringField(alloc, t, "tool_call_id");
        errdefer if (tcid) |x| alloc.free(x);
        const tcj = try model_mod.extractStringField(alloc, t, "tool_calls_json");
        errdefer if (tcj) |x| alloc.free(x);
        try out.append(alloc, .{
            .role = role,
            .content = content,
            .tool_call_id = tcid,
            .tool_calls_json = tcj,
        });
    }
    return out.toOwnedSlice(alloc);
}

/// One raw message-event line with its seq. `raw` is the JSON object text
/// (no trailing newline), owned by the reader.
pub const EventLine = struct {
    seq: i64,
    raw: []u8,
};

pub fn freeEventLines(alloc: std.mem.Allocator, lines: []EventLine) void {
    for (lines) |l| alloc.free(l.raw);
    alloc.free(lines);
}

/// Read the message events of a log as raw JSON objects (header skipped,
/// unknown versions rejected, malformed lines tolerated).
pub fn readEventLines(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]EventLine {
    const raw = try std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .unlimited);
    defer alloc.free(raw);

    var out: std.ArrayList(EventLine) = .empty;
    errdefer {
        for (out.items) |l| alloc.free(l.raw);
        out.deinit(alloc);
    }
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] != '{') continue;
        if (std.mem.indexOf(u8, t, "\"kind\":\"header\"") != null) {
            const v = std.mem.indexOf(u8, t, "\"v\":") orelse continue;
            var i = v + 4;
            var n: u32 = 0;
            while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) n = n * 10 + (t[i] - '0');
            if (n != format_version) return Error.UnsupportedFormatVersion;
            continue;
        }
        if (std.mem.indexOf(u8, t, "\"kind\":\"message\"") == null) continue;
        const seq = extractSeq(t) orelse continue;
        try out.append(alloc, .{ .seq = seq, .raw = try alloc.dupe(u8, t) });
    }
    return out.toOwnedSlice(alloc);
}

fn extractSeq(t: []const u8) ?i64 {
    const key = "\"seq\":";
    const i = std.mem.indexOf(u8, t, key) orelse return null;
    const rest = t[i + key.len ..];
    var end: usize = 0;
    while (end < rest.len and (rest[end] == '-' or (rest[end] >= '0' and rest[end] <= '9'))) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch null;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "header and message lines are well-formed and escape content" {
    const alloc = testing.allocator;
    const h = try headerLine(alloc, "s-1");
    defer alloc.free(h);
    try testing.expectEqualStrings("{\"v\":1,\"kind\":\"header\",\"id\":\"s-1\"}\n", h);

    const m = try messageLine(alloc, 7, .{ .role = .assistant, .content = "hi \"x\"", .tool_call_id = "t1" });
    defer alloc.free(m);
    try testing.expect(std.mem.indexOf(u8, m, "\"seq\":7") != null);
    try testing.expect(std.mem.indexOf(u8, m, "\"role\":\"assistant\"") != null);
    try testing.expect(std.mem.indexOf(u8, m, "\"tool_call_id\":\"t1\"") != null);
    try testing.expect(std.mem.indexOf(u8, m, "\"tool_calls_json\":null") != null);

    const n = try messageLine(alloc, 1, .{ .role = .user, .content = "x" });
    defer alloc.free(n);
    try testing.expect(std.mem.indexOf(u8, n, "\"tool_call_id\":null") != null);
}
