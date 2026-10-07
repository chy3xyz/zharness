//! Model-facing agent control tools. list_agents reads the process-global
//! subagent run registry (server/apiproxy/subagents_rpc.zig) so the model can
//! see subagent runs it or the GUI started.

const std = @import("std");
const model = @import("../model/model.zig");
const tool_reg = @import("registry.zig");
const builtin = @import("builtin.zig");
const jsonx = @import("../server/apiproxy/jsonx.zig");
const subagents_rpc = @import("../server/apiproxy/subagents_rpc.zig");

extern "c" fn usleep(usec: c_uint) c_int;

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

pub const wait_definition = tool_reg.ToolDefinition{
    .name = "wait_agent",
    .description = "Wait for a subagent run to finish, then return its row. On timeout it returns the still-running row with a note.",
    .category = .general,
    .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string"},"timeout_ms":{"type":"integer"}},"required":["id"]}
    ,
};

pub const interrupt_definition = tool_reg.ToolDefinition{
    .name = "interrupt_agent",
    .description = "Request cooperative cancellation of a subagent run; it stops at its next turn boundary.",
    .category = .general,
    .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}
    ,
};

pub const send_definition = tool_reg.ToolDefinition{
    .name = "send_message",
    .description = "Queue a message for a running subagent; it is appended to the run before its next turn.",
    .category = .general,
    .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string"},"message":{"type":"string"}},"required":["id","message"]}
    ,
};

pub fn register(reg: *tool_reg.ToolRegistry) !void {
    try reg.register(definition);
    try reg.register(wait_definition);
    try reg.register(interrupt_definition);
    try reg.register(send_definition);
}

pub fn isAgentTool(name: []const u8) bool {
    return std.mem.eql(u8, name, definition.name) or std.mem.eql(u8, name, wait_definition.name) or
        std.mem.eql(u8, name, interrupt_definition.name) or std.mem.eql(u8, name, send_definition.name);
}

fn fail(a: std.mem.Allocator, msg: []const u8) !ToolResult {
    return .{ .success = false, .output = "", .err_msg = try a.dupe(u8, msg) };
}

fn appendSnapshot(a: std.mem.Allocator, out: *std.ArrayList(u8), s: *const subagents_rpc.Snapshot) !void {
    try out.appendSlice(a, "{\"id\":");
    try jsonx.appendJsonString(a, out, s.id);
    try out.appendSlice(a, ",\"status\":\"");
    try out.appendSlice(a, s.status.asStr());
    try out.appendSlice(a, "\",\"label\":");
    try jsonx.appendJsonString(a, out, s.label);
    try out.appendSlice(a, ",\"parentSessionId\":");
    try jsonx.appendJsonString(a, out, s.parent_session_id);
    try out.appendSlice(a, ",\"prompt\":");
    try jsonx.appendJsonString(a, out, s.prompt);
    try out.appendSlice(a, ",\"startedAtMs\":");
    try jsonx.appendInt(a, out, s.started_at_ms);
    try out.appendSlice(a, ",\"durationMs\":");
    if (s.duration_ms) |d| try jsonx.appendInt(a, out, d) else try out.appendSlice(a, "null");
    try out.append(a, '}');
}

/// Wait for a run to leave the running state (or time out).
fn waitAgent(a: std.mem.Allocator, args: []const u8) !ToolResult {
    const id = (try model.extractStringField(a, args, "id")) orelse
        return fail(a, "wait_agent: missing 'id'");
    defer a.free(id);
    var timeout_ms: u64 = 30_000;
    const t = model.extractU64Field(args, "timeout_ms");
    if (t > 0) timeout_ms = t;
    const reg = subagents_rpc.shared() catch return fail(a, "subagent registry unavailable");
    var waited: u64 = 0;
    while (true) {
        const snap = (reg.get(a, id) catch |e| return fail(a, @errorName(e))) orelse
            return fail(a, "wait_agent: unknown agent id");
        const still_running = snap.status == .running;
        if (!still_running or waited >= timeout_ms) {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(a);
            try appendSnapshot(a, &out, &snap);
            snap.free(a);
            if (still_running) {
                const body = try out.toOwnedSlice(a);
                defer a.free(body);
                return .{ .success = true, .output = try std.fmt.allocPrint(a, "{s}\n[wait_agent: timed out after {d}ms; the run is still going]", .{ body, timeout_ms }) };
            }
            return .{ .success = true, .output = try out.toOwnedSlice(a) };
        }
        snap.free(a);
        _ = usleep(50_000);
        waited += 50;
    }
}

fn interruptAgent(a: std.mem.Allocator, args: []const u8) !ToolResult {
    const id = (try model.extractStringField(a, args, "id")) orelse
        return fail(a, "interrupt_agent: missing 'id'");
    defer a.free(id);
    const reg = subagents_rpc.shared() catch return fail(a, "subagent registry unavailable");
    if (!reg.requestCancel(id)) return fail(a, "interrupt_agent: unknown agent id");
    return .{ .success = true, .output = try std.fmt.allocPrint(a, "cancellation requested for {s}", .{id}) };
}

fn sendMessage(a: std.mem.Allocator, args: []const u8) !ToolResult {
    const id = (try model.extractStringField(a, args, "id")) orelse
        return fail(a, "send_message: missing 'id'");
    defer a.free(id);
    const msg = (try model.extractStringField(a, args, "message")) orelse
        return fail(a, "send_message: missing 'message'");
    defer a.free(msg);
    const reg = subagents_rpc.shared() catch return fail(a, "subagent registry unavailable");
    if (!reg.enqueueMessage(id, msg)) return fail(a, "send_message: unknown agent id");
    return .{ .success = true, .output = try std.fmt.allocPrint(a, "message queued for {s}", .{id}) };
}

pub fn execute(a: std.mem.Allocator, call: ToolCall) !ToolResult {
    if (std.mem.eql(u8, call.name, wait_definition.name)) return waitAgent(a, call.arguments);
    if (std.mem.eql(u8, call.name, interrupt_definition.name)) return interruptAgent(a, call.arguments);
    if (std.mem.eql(u8, call.name, send_definition.name)) return sendMessage(a, call.arguments);
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
        try appendSnapshot(a, &out, &s);
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

test "wait_agent returns a finished run and times out a running one" {
    const a = testing.allocator;
    const reg = try subagents_rpc.shared();
    try reg.recordStart(.{ .id = "subagent-wait-1", .parent_session_id = "s", .label = "w", .prompt = "p", .started_at_ms = 1 });
    _ = reg.recordEnd("subagent-wait-1", .failed, "nope", 3);

    var r = try execute(a, .{ .name = "wait_agent", .arguments = "{\"id\":\"subagent-wait-1\"}" });
    defer freeResult(a, &r);
    try testing.expect(r.success);
    try testing.expect(std.mem.indexOf(u8, r.output, "\"status\":\"failed\"") != null);

    try reg.recordStart(.{ .id = "subagent-wait-2", .parent_session_id = "s", .label = "w2", .prompt = "p", .started_at_ms = 1 });
    var t = try execute(a, .{ .name = "wait_agent", .arguments = "{\"id\":\"subagent-wait-2\",\"timeout_ms\":100}" });
    defer freeResult(a, &t);
    try testing.expect(t.success);
    try testing.expect(std.mem.indexOf(u8, t.output, "timed out") != null);
}

test "send_message and interrupt_agent act on the registry" {
    const a = testing.allocator;
    const reg = try subagents_rpc.shared();
    try reg.recordStart(.{ .id = "subagent-msg-1", .parent_session_id = "s", .label = "m", .prompt = "p", .started_at_ms = 1 });

    var s = try execute(a, .{ .name = "send_message", .arguments = "{\"id\":\"subagent-msg-1\",\"message\":\"ping\"}" });
    defer freeResult(a, &s);
    try testing.expect(s.success);
    const drained = try reg.drainInbox(a, "subagent-msg-1");
    defer if (drained) |d| a.free(d);
    try testing.expect(drained != null);
    try testing.expectEqualStrings("ping", drained.?);

    var i = try execute(a, .{ .name = "interrupt_agent", .arguments = "{\"id\":\"subagent-msg-1\"}" });
    defer freeResult(a, &i);
    try testing.expect(i.success);
    try testing.expect(reg.cancelRequested("subagent-msg-1"));

    var bad = try execute(a, .{ .name = "send_message", .arguments = "{\"id\":\"absent\",\"message\":\"x\"}" });
    defer freeResult(a, &bad);
    try testing.expect(!bad.success);
}
