//! Model-facing session query tools (upstream dsh session-query family).
//! session_search greps transcripts for a query; session_read returns one
//! session's messages. Both are read-only.

const std = @import("std");
const model = @import("../model/model.zig");
const tool_reg = @import("registry.zig");
const builtin = @import("builtin.zig");
const jsonx = @import("../server/apiproxy/jsonx.zig");
const search_rpc = @import("../server/apiproxy/search_rpc.zig");
const apx_sessions = @import("../server/apiproxy/sessions.zig");

pub const ToolCall = builtin.ToolCall;
pub const ToolResult = builtin.ToolResult;
pub const freeResult = builtin.freeResult;

pub const definitions = [_]tool_reg.ToolDefinition{
    .{
        .name = "session_search",
        .description = "Search past session transcripts for a case-insensitive substring. Returns matching session ids with snippets.",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Text to search for"}},"required":["query"]}
        ,
    },
    .{
        .name = "session_read",
        .description = "Read one past session transcript by id (messages with role and content).",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"sessionId":{"type":"string","description":"Session id from session_search or the session list"}},"required":["sessionId"]}
        ,
    },
};

pub fn register(reg: *tool_reg.ToolRegistry) !void {
    for (definitions) |d| try reg.register(d);
}

pub fn isSessionQueryTool(name: []const u8) bool {
    for (definitions) |d| {
        if (std.mem.eql(u8, name, d.name)) return true;
    }
    return false;
}

fn fail(alloc: std.mem.Allocator, msg: []const u8) !ToolResult {
    return .{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, msg) };
}

pub fn execute(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    if (std.mem.eql(u8, call.name, "session_search")) return search(alloc, io, cwd, call.arguments);
    if (std.mem.eql(u8, call.name, "session_read")) return read(alloc, io, cwd, call.arguments);
    return fail(alloc, "unknown session query tool");
}

fn search(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const u8) !ToolResult {
    const query = (try model.extractStringField(alloc, args, "query")) orelse
        return fail(alloc, "session_search: missing 'query'");
    defer alloc.free(query);

    const page = search_rpc.searchIn(io, alloc, cwd, query) catch |e|
        return fail(alloc, @errorName(e));
    defer {
        for (page.items) |it| {
            alloc.free(it.session_id);
            alloc.free(it.snippet);
        }
        alloc.free(page.items);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"query\":");
    try jsonx.appendJsonString(alloc, &out, query);
    try out.appendSlice(alloc, ",\"items\":[");
    for (page.items, 0..) |it, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"sessionId\":");
        try jsonx.appendJsonString(alloc, &out, it.session_id);
        try out.appendSlice(alloc, ",\"snippet\":");
        try jsonx.appendJsonString(alloc, &out, it.snippet);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "],\"hasMore\":");
    try out.appendSlice(alloc, if (page.has_more) "true" else "false");
    try out.append(alloc, '}');
    return .{ .success = true, .output = try out.toOwnedSlice(alloc) };
}

fn read(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const u8) !ToolResult {
    const sid = (try model.extractStringField(alloc, args, "sessionId")) orelse
        return fail(alloc, "session_read: missing 'sessionId'");
    defer alloc.free(sid);

    const path = try apx_sessions.transcriptPath(alloc, cwd, sid);
    defer alloc.free(path);
    const msgs = apx_sessions.loadTranscript(io, alloc, path) catch |e| switch (e) {
        error.FileNotFound => return fail(alloc, "session_read: unknown session id"),
        else => return fail(alloc, @errorName(e)),
    };
    defer {
        for (msgs) |m| {
            alloc.free(m.role);
            alloc.free(m.content);
            if (m.tool_call_id) |t| alloc.free(t);
            if (m.tool_calls_json) |t| alloc.free(t);
        }
        alloc.free(msgs);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"sessionId\":");
    try jsonx.appendJsonString(alloc, &out, sid);
    try out.appendSlice(alloc, ",\"messages\":[");
    for (msgs, 0..) |m, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"role\":");
        try jsonx.appendJsonString(alloc, &out, m.role);
        try out.appendSlice(alloc, ",\"content\":");
        try jsonx.appendJsonString(alloc, &out, m.content);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]}");
    return .{ .success = true, .output = try out.toOwnedSlice(alloc) };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "session query tools search and read transcripts" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = "/tmp/zh_sq_test";
    try std.Io.Dir.createDirPath(.cwd(), io, cwd ++ "/.zharness/sessions");
    const path = cwd ++ "/.zharness/sessions/zh_sq_a.json";
    try std.Io.Dir.writeFile(.cwd(), io, .{
        .sub_path = path,
        .data = "[{\"role\":\"user\",\"content\":\"please fix the login bug\"}]",
    });
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    var r = try execute(alloc, io, cwd, .{ .name = "session_search", .arguments = "{\"query\":\"login\"}" });
    defer freeResult(alloc, &r);
    try testing.expect(r.success);
    try testing.expect(std.mem.indexOf(u8, r.output, "zh_sq_a") != null);

    var r2 = try execute(alloc, io, cwd, .{ .name = "session_read", .arguments = "{\"sessionId\":\"zh_sq_a\"}" });
    defer freeResult(alloc, &r2);
    try testing.expect(r2.success);
    try testing.expect(std.mem.indexOf(u8, r2.output, "login bug") != null);

    var r3 = try execute(alloc, io, cwd, .{ .name = "session_read", .arguments = "{\"sessionId\":\"zh_sq_absent\"}" });
    defer freeResult(alloc, &r3);
    try testing.expect(!r3.success);
}
