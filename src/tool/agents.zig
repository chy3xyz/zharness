//! Model-facing agent control tools. list_agents reads the process-global
//! subagent run registry (server/apiproxy/subagents_rpc.zig) so the model can
//! see subagent runs it or the GUI started.

const std = @import("std");
const tool_reg = @import("registry.zig");
const builtin = @import("builtin.zig");
const jsonx = @import("../server/apiproxy/jsonx.zig");
const subagents_rpc = @import("../server/apiproxy/subagents_rpc.zig");

pub const ToolCall = builtin.ToolCall;
pub const ToolResult = builtin.ToolResult;
pub const freeResult = builtin.freeResult;

pub const definition = tool_reg.ToolDefinition{
    .name = "list_agents",
    .description = "List subagent runs (id, status, label, parent session, start time and duration).",
    .category = .general,
    .parameters_json =
    \\{"type":"object","properties":{},"required":[]}
    ,
};

pub fn register(reg: *tool_reg.ToolRegistry) !void {
    try reg.register(definition);
}

pub fn isAgentTool(name: []const u8) bool {
    return std.mem.eql(u8, name, definition.name);
}

fn fail(a: std.mem.Allocator, msg: []const u8) !ToolResult {
    return .{ .success = false, .output = "", .err_msg = try a.dupe(u8, msg) };
}

pub fn execute(a: std.mem.Allocator, call: ToolCall) !ToolResult {
    if (!std.mem.eql(u8, call.name, definition.name))
        return fail(a, "unknown agent tool");
    const reg = subagents_rpc.shared() catch return fail(a, "subagent registry unavailable");
    const snaps = reg.list(a, null) catch |e| return fail(a, @errorName(e));
    defer subagents_rpc.Snapshot.freeSnapshots(a, snaps);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "{\"agents\":[");
    for (snaps, 0..) |s, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, "{\"id\":");
        try jsonx.appendJsonString(a, &out, s.id);
        try out.appendSlice(a, ",\"status\":\"");
        try out.appendSlice(a, s.status.asStr());
        try out.appendSlice(a, "\",\"label\":");
        try jsonx.appendJsonString(a, &out, s.label);
        try out.appendSlice(a, ",\"parentSessionId\":");
        try jsonx.appendJsonString(a, &out, s.parent_session_id);
        try out.appendSlice(a, ",\"prompt\":");
        try jsonx.appendJsonString(a, &out, s.prompt);
        try out.appendSlice(a, ",\"startedAtMs\":");
        try jsonx.appendInt(a, &out, s.started_at_ms);
        try out.appendSlice(a, ",\"durationMs\":");
        if (s.duration_ms) |d| try jsonx.appendInt(a, &out, d) else try out.appendSlice(a, "null");
        try out.append(a, '}');
    }
    try out.appendSlice(a, "]}");
    return .{ .success = true, .output = try out.toOwnedSlice(a) };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "list_agents renders registry rows" {
    const a = testing.allocator;
    const reg = try subagents_rpc.shared();
    try reg.recordStart(.{
        .id = "subagent-unit-1",
        .parent_session_id = "sess-1",
        .label = "probe",
        .prompt = "do the thing",
        .started_at_ms = 5,
    });
    _ = reg.recordEnd("subagent-unit-1", .completed, "ok", 7);

    var r = try execute(a, .{ .name = "list_agents", .arguments = "{}" });
    defer freeResult(a, &r);
    try testing.expect(r.success);
    try testing.expect(std.mem.indexOf(u8, r.output, "subagent-unit-1") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "\"status\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "\"label\":\"probe\"") != null);
}
