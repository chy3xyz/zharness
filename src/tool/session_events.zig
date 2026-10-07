//! Model-facing session event query tools (upstream session_event_read /
//! session_event_search), reading the append-only JSONL session log.

const std = @import("std");
const model = @import("../model/model.zig");
const tool_reg = @import("registry.zig");
const builtin = @import("builtin.zig");
const jsonx = @import("../server/apiproxy/jsonx.zig");
const log_mod = @import("../session/log.zig");
const apx_sessions = @import("../server/apiproxy/sessions.zig");

pub const ToolCall = builtin.ToolCall;
pub const ToolResult = builtin.ToolResult;
pub const freeResult = builtin.freeResult;

pub const default_limit: usize = 50;
pub const max_limit: usize = 200;

pub const definitions = [_]tool_reg.ToolDefinition{
    .{
        .name = "session_event_read",
        .description = "Read a session's event log by seq range (raw events in order).",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"sessionId":{"type":"string"},"from_seq":{"type":"integer"},"limit":{"type":"integer"}},"required":["sessionId"]}
        ,
    },
    .{
        .name = "session_event_search",
        .description = "Search session event logs for a case-insensitive substring; returns matching events with session id and seq.",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"query":{"type":"string"},"sessionId":{"type":"string"},"limit":{"type":"integer"}},"required":["query"]}
        ,
    },
};

pub fn register(reg: *tool_reg.ToolRegistry) !void {
    for (definitions) |d| try reg.register(d);
}

pub fn isSessionEventTool(name: []const u8) bool {
    for (definitions) |d| {
        if (std.mem.eql(u8, name, d.name)) return true;
    }
    return false;
}

fn fail(a: std.mem.Allocator, msg: []const u8) !ToolResult {
    return .{ .success = false, .output = "", .err_msg = try a.dupe(u8, msg) };
}

fn logPath(a: std.mem.Allocator, cwd: []const u8, sid: []const u8) ![]u8 {
    const base = try apx_sessions.transcriptPath(a, cwd, sid);
    defer a.free(base);
    return std.fmt.allocPrint(a, "{s}.jsonl", .{base});
}

/// Parse a positive limit (default when absent). Returns null on an invalid
/// value so callers can fail cleanly.
fn parseLimit(args: []const u8) ?usize {
    const l = jsonx.getInt(args, "limit") orelse return default_limit;
    if (l < 1 or l > max_limit) return null;
    return @intCast(l);
}

pub fn execute(a: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    if (std.mem.eql(u8, call.name, "session_event_read")) return readEvents(a, io, cwd, call.arguments);
    if (std.mem.eql(u8, call.name, "session_event_search")) return searchEvents(a, io, cwd, call.arguments);
    return fail(a, "unknown session event tool");
}

fn readEvents(a: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const u8) !ToolResult {
    const sid = (try model.extractStringField(a, args, "sessionId")) orelse
        return fail(a, "session_event_read: missing 'sessionId'");
    defer a.free(sid);
    const limit = parseLimit(args) orelse return fail(a, "session_event_read: limit must be 1..200");
    var from_seq: i64 = 0;
    if (jsonx.getInt(args, "from_seq")) |v| from_seq = v;

    const path = try logPath(a, cwd, sid);
    defer a.free(path);
    const lines = log_mod.readEventLines(a, io, path) catch |e| switch (e) {
        error.FileNotFound => return fail(a, "session_event_read: unknown session id"),
        else => return fail(a, @errorName(e)),
    };
    defer log_mod.freeEventLines(a, lines);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "{\"sessionId\":");
    try jsonx.appendJsonString(a, &out, sid);
    try out.appendSlice(a, ",\"events\":[");
    var shown: usize = 0;
    var more = false;
    var last_seq: i64 = 0;
    for (lines) |ln| {
        if (ln.seq < from_seq) continue;
        if (shown >= limit) {
            more = true;
            break;
        }
        if (shown > 0) try out.append(a, ',');
        try out.appendSlice(a, ln.raw);
        last_seq = ln.seq;
        shown += 1;
    }
    try out.append(a, ']');
    if (more) {
        try out.appendSlice(a, ",\"nextSeq\":");
        try jsonx.appendInt(a, &out, last_seq + 1);
    }
    try out.append(a, '}');
    return .{ .success = true, .output = try out.toOwnedSlice(a) };
}

fn searchEvents(a: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const u8) !ToolResult {
    const query = (try model.extractStringField(a, args, "query")) orelse
        return fail(a, "session_event_search: missing 'query'");
    defer a.free(query);
    if (query.len == 0) return fail(a, "session_event_search: query must be non-empty");
    const sid = try model.extractStringField(a, args, "sessionId");
    defer if (sid) |s| a.free(s);
    const limit = parseLimit(args) orelse return fail(a, "session_event_search: limit must be 1..200");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "{\"query\":");
    try jsonx.appendJsonString(a, &out, query);
    try out.appendSlice(a, ",\"matches\":[");
    var shown: usize = 0;
    var more = false;

    if (sid) |s| {
        more = try scanSession(a, io, cwd, s, query, limit, &out, &shown);
    } else {
        const dir = try apx_sessions.transcriptDir(a, cwd);
        defer a.free(dir);
        const ids = apx_sessions.listSessionIds(io, a, dir) catch &[_][]const u8{};
        defer {
            for (ids) |id| a.free(id);
            if (ids.len > 0) a.free(ids);
        }
        for (ids) |id| {
            if (try scanSession(a, io, cwd, id, query, limit, &out, &shown)) {
                more = true;
                break;
            }
        }
    }
    try out.appendSlice(a, "],\"hasMore\":");
    try out.appendSlice(a, if (more) "true" else "false");
    try out.append(a, '}');
    return .{ .success = true, .output = try out.toOwnedSlice(a) };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and std.ascii.toLower(haystack[i + j]) == std.ascii.toLower(needle[j])) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

/// Append matches from one session. Returns true when the limit was reached
/// with more events remaining.
fn scanSession(
    a: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    sid: []const u8,
    query: []const u8,
    limit: usize,
    out: *std.ArrayList(u8),
    shown: *usize,
) !bool {
    const path = try logPath(a, cwd, sid);
    defer a.free(path);
    const lines = log_mod.readEventLines(a, io, path) catch return false;
    defer log_mod.freeEventLines(a, lines);
    for (lines) |ln| {
        if (!containsIgnoreCase(ln.raw, query)) continue;
        if (shown.* >= limit) return true;
        if (shown.* > 0) try out.append(a, ',');
        try out.appendSlice(a, "{\"sessionId\":");
        try jsonx.appendJsonString(a, out, sid);
        try out.appendSlice(a, ",\"seq\":");
        try jsonx.appendInt(a, out, ln.seq);
        try out.appendSlice(a, ",\"event\":");
        try out.appendSlice(a, ln.raw);
        try out.append(a, '}');
        shown.* += 1;
    }
    return false;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "session event read and search decode the JSONL log" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = "/tmp/zh_evt_test";
    try std.Io.Dir.createDirPath(.cwd(), io, cwd ++ "/.zharness/sessions");
    const path = cwd ++ "/.zharness/sessions/zh_evt_a.json.jsonl";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    // The all-sessions search lists *.json stems, so a stub legacy transcript
    // must exist for the id to be discovered.
    const legacy = cwd ++ "/.zharness/sessions/zh_evt_a.json";
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = legacy, .data = "[]" });
    defer std.Io.Dir.deleteFile(.cwd(), io, legacy) catch {};

    const h = try log_mod.headerLine(a, "zh_evt_a");
    defer a.free(h);
    try log_mod.append(io, path, h);
    const m1 = try log_mod.messageLine(a, 1, .{ .role = .user, .content = "find the needle" });
    defer a.free(m1);
    try log_mod.append(io, path, m1);
    const m2 = try log_mod.messageLine(a, 2, .{ .role = .assistant, .content = "irrelevant" });
    defer a.free(m2);
    try log_mod.append(io, path, m2);

    var r = try execute(a, io, cwd, .{ .name = "session_event_read", .arguments = "{\"sessionId\":\"zh_evt_a\"}" });
    defer freeResult(a, &r);
    try testing.expect(r.success);
    try testing.expect(std.mem.indexOf(u8, r.output, "\"seq\":1") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "\"seq\":2") != null);

    var s = try execute(a, io, cwd, .{ .name = "session_event_search", .arguments = "{\"query\":\"needle\"}" });
    defer freeResult(a, &s);
    try testing.expect(s.success);
    try testing.expect(std.mem.indexOf(u8, s.output, "zh_evt_a") != null);
    try testing.expect(std.mem.indexOf(u8, s.output, "\"seq\":1") != null);
    try testing.expect(std.mem.indexOf(u8, s.output, "irrelevant") == null);
}
