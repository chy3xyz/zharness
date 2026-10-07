//! Model-facing schedule tools (upstream dsh-tool-schedule), minimal slice:
//! one-shot reminders waiting \`after_seconds\`, listed/updated/deleted by id,
//! and surfaced into the dynamic system prompt while active.
//!
//! The store is process-global and in memory (no durable host-wide schedule
//! yet); delivery is by context surfacing, not session activation.

const std = @import("std");
const model = @import("../model/model.zig");
const tool_reg = @import("registry.zig");
const builtin = @import("builtin.zig");

pub const ToolCall = builtin.ToolCall;
pub const ToolResult = builtin.ToolResult;
pub const freeResult = builtin.freeResult;

extern "c" fn time(tloc: ?*c_long) c_long;

pub const max_title_len: usize = 120;
pub const max_active: usize = 64;

const Status = enum { active, inactive };
const Kind = enum { after };

const Record = struct {
    id: []u8,
    kind: Kind = .after,
    title: []u8,
    prompt: []u8,
    scheduled_at_ms: i64,
    status: Status = .active,
};

const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),
    fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

var g_items: std.ArrayList(Record) = .empty;
var g_lock: SpinLock = .{};
var g_seq: u64 = 0;

fn appendI64(a: std.mem.Allocator, out: *std.ArrayList(u8), v: i64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    try out.appendSlice(a, s);
}

fn nowMs() i64 {
    return @as(i64, @intCast(time(null))) * @as(i64, 1000);
}

fn alloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

pub fn definitions() [4]tool_reg.ToolDefinition {
    return .{
        .{
            .name = "schedule_create",
            .description = "Create a one-shot reminder that becomes due after 'after_seconds'. Requires 'title' and 'prompt'.",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{"title":{"type":"string"},"prompt":{"type":"string"},"after_seconds":{"type":"integer"}},"required":["title","prompt","after_seconds"]}
            ,
        },
        .{
            .name = "schedule_list",
            .description = "List scheduled reminders as JSON.",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{},"required":[]}
            ,
        },
        .{
            .name = "schedule_update",
            .description = "Change a reminder in place (title, prompt, and/or after_seconds).",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{"id":{"type":"string"},"title":{"type":"string"},"prompt":{"type":"string"},"after_seconds":{"type":"integer"}},"required":["id"]}
            ,
        },
        .{
            .name = "schedule_delete",
            .description = "Delete a scheduled reminder by id.",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}
            ,
        },
    };
}

pub fn register(reg: *tool_reg.ToolRegistry) !void {
    const defs = definitions();
    for (defs) |d| try reg.register(d);
}

pub fn isScheduleTool(name: []const u8) bool {
    const defs = definitions();
    for (defs) |d| {
        if (std.mem.eql(u8, name, d.name)) return true;
    }
    return false;
}

fn fail(a: std.mem.Allocator, msg: []const u8) !ToolResult {
    return .{ .success = false, .output = "", .err_msg = try a.dupe(u8, msg) };
}

fn create(title: []const u8, prompt: []const u8, after_seconds: u64) !?[]const u8 {
    g_lock.lock();
    defer g_lock.unlock();
    var active: usize = 0;
    for (g_items.items) |r| {
        if (r.status == .active) active += 1;
    }
    if (active >= max_active) return null;
    g_seq += 1;
    const a = alloc();
    const id = try std.fmt.allocPrint(a, "sch-{d}", .{g_seq});
    errdefer a.free(id);
    const rec = Record{
        .id = id,
        .title = try a.dupe(u8, title),
        .prompt = try a.dupe(u8, prompt),
        .scheduled_at_ms = nowMs() + @as(i64, @intCast(after_seconds)) * 1000,
    };
    try g_items.append(a, rec);
    return id;
}

fn findLocked(id: []const u8) ?*Record {
    for (g_items.items) |*r| {
        if (std.mem.eql(u8, r.id, id)) return r;
    }
    return null;
}

fn listJson(a: std.mem.Allocator) ![]u8 {
    g_lock.lock();
    defer g_lock.unlock();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "{\"items\":[");
    var first = true;
    for (g_items.items) |r| {
        if (!first) try out.append(a, ',');
        first = false;
        try out.appendSlice(a, "{\"id\":\"");
        try out.appendSlice(a, r.id);
        try out.appendSlice(a, "\",\"kind\":\"after\",\"title\":\"");
        try model.escape(a, r.title, &out);
        try out.appendSlice(a, "\",\"prompt\":\"");
        try model.escape(a, r.prompt, &out);
        try out.appendSlice(a, "\",\"status\":\"");
        try out.appendSlice(a, if (r.status == .active) "active" else "inactive");
        try out.appendSlice(a, "\",\"scheduledAtMs\":");
        try appendI64(a, &out, r.scheduled_at_ms);
        try out.append(a, '}');
    }
    try out.appendSlice(a, "]}");
    return out.toOwnedSlice(a);
}

fn delete(id: []const u8) bool {
    g_lock.lock();
    defer g_lock.unlock();
    for (g_items.items, 0..) |r, i| {
        if (!std.mem.eql(u8, r.id, id)) continue;
        const a = alloc();
        a.free(r.id);
        a.free(r.title);
        a.free(r.prompt);
        _ = g_items.swapRemove(i);
        return true;
    }
    return false;
}

fn update(id: []const u8, title: ?[]const u8, prompt: ?[]const u8, after_seconds: u64) bool {
    g_lock.lock();
    defer g_lock.unlock();
    const r = findLocked(id) orelse return false;
    const a = alloc();
    if (title) |t| {
        const nt = a.dupe(u8, t) catch return false;
        a.free(r.title);
        r.title = nt;
    }
    if (prompt) |p| {
        const np = a.dupe(u8, p) catch return false;
        a.free(r.prompt);
        r.prompt = np;
    }
    if (after_seconds > 0) r.scheduled_at_ms = nowMs() + @as(i64, @intCast(after_seconds)) * 1000;
    r.status = .active;
    return true;
}

/// Dynamic system-prompt section: active reminders, due ones flagged. "" when
/// none. Caller frees.
pub fn renderSection(a: std.mem.Allocator) ![]u8 {
    g_lock.lock();
    defer g_lock.unlock();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var any = false;
    for (g_items.items) |r| {
        if (r.status != .active) continue;
        if (!any) try out.appendSlice(a, "## Scheduled reminders\n");
        any = true;
        const remain = r.scheduled_at_ms - nowMs();
        try out.appendSlice(a, "- ");
        try out.appendSlice(a, r.id);
        try out.appendSlice(a, " ");
        try out.appendSlice(a, r.title);
        if (remain <= 0) {
            try out.appendSlice(a, " [DUE] ");
        } else {
            try out.appendSlice(a, " [in ~");
            try appendI64(a, &out, @divTrunc(remain, 1000));
            try out.appendSlice(a, "s] ");
        }
        try out.appendSlice(a, r.prompt);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

pub fn execute(a: std.mem.Allocator, call: ToolCall) !ToolResult {
    if (std.mem.eql(u8, call.name, "schedule_list")) {
        return .{ .success = true, .output = try listJson(a) };
    }
    if (std.mem.eql(u8, call.name, "schedule_create")) {
        const title = (try model.extractStringField(a, call.arguments, "title")) orelse
            return fail(a, "schedule_create: missing 'title'");
        defer a.free(title);
        const prompt = (try model.extractStringField(a, call.arguments, "prompt")) orelse
            return fail(a, "schedule_create: missing 'prompt'");
        defer a.free(prompt);
        if (std.mem.trim(u8, title, " \t\r\n").len == 0) return fail(a, "schedule_create: title must be non-empty");
        if (title.len > max_title_len) return fail(a, "schedule_create: title too long");
        if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) return fail(a, "schedule_create: prompt must be non-empty");
        const after = model.extractU64Field(call.arguments, "after_seconds");
        if (after == 0) return fail(a, "schedule_create: after_seconds must be a positive integer");
        const id = (try create(title, prompt, after)) orelse return fail(a, "schedule_create: too many active reminders");
        return .{ .success = true, .output = try std.fmt.allocPrint(a, "scheduled {s} (due in {d}s)", .{ id, after }) };
    }
    if (std.mem.eql(u8, call.name, "schedule_delete")) {
        const id = (try model.extractStringField(a, call.arguments, "id")) orelse
            return fail(a, "schedule_delete: missing 'id'");
        defer a.free(id);
        if (!delete(id)) return fail(a, "schedule_delete: unknown id");
        return .{ .success = true, .output = try std.fmt.allocPrint(a, "deleted {s}", .{id}) };
    }
    if (std.mem.eql(u8, call.name, "schedule_update")) {
        const id = (try model.extractStringField(a, call.arguments, "id")) orelse
            return fail(a, "schedule_update: missing 'id'");
        defer a.free(id);
        const title = try model.extractStringField(a, call.arguments, "title");
        defer if (title) |t| a.free(t);
        const prompt = try model.extractStringField(a, call.arguments, "prompt");
        defer if (prompt) |p| a.free(p);
        const after = model.extractU64Field(call.arguments, "after_seconds");
        if (!update(id, title, prompt, after)) return fail(a, "schedule_update: unknown id");
        return .{ .success = true, .output = try std.fmt.allocPrint(a, "updated {s}", .{id}) };
    }
    return fail(a, "unknown schedule tool");
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "schedule create/list/update/delete round-trip" {
    const a = testing.allocator;
    var r = try execute(a, .{ .name = "schedule_create", .arguments = "{\"title\":\"Check\",\"prompt\":\"look now\",\"after_seconds\":1}" });
    defer freeResult(a, &r);
    try testing.expect(r.success);

    var l = try execute(a, .{ .name = "schedule_list", .arguments = "{}" });
    defer freeResult(a, &l);
    try testing.expect(std.mem.indexOf(u8, l.output, "Check") != null);

    const section = try renderSection(a);
    defer a.free(section);
    try testing.expect(std.mem.indexOf(u8, section, "Check") != null);

    const sp = std.mem.indexOf(u8, r.output, "sch-").?;
    const ep = std.mem.indexOfScalarPos(u8, r.output, sp, ' ').?;
    const id = r.output[sp..ep];

    var buf: [160]u8 = undefined;
    const up = try std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"title\":\"Renamed\"}}", .{id});
    var u = try execute(a, .{ .name = "schedule_update", .arguments = up });
    defer freeResult(a, &u);
    try testing.expect(u.success);

    var buf2: [160]u8 = undefined;
    const del = try std.fmt.bufPrint(&buf2, "{{\"id\":\"{s}\"}}", .{id});
    var d = try execute(a, .{ .name = "schedule_delete", .arguments = del });
    defer freeResult(a, &d);
    try testing.expect(d.success);
    var d2 = try execute(a, .{ .name = "schedule_delete", .arguments = del });
    defer freeResult(a, &d2);
    try testing.expect(!d2.success);
}

test "schedule_create rejects a non-positive delay" {
    const a = testing.allocator;
    var r = try execute(a, .{ .name = "schedule_create", .arguments = "{\"title\":\"x\",\"prompt\":\"y\",\"after_seconds\":0}" });
    defer freeResult(a, &r);
    try testing.expect(!r.success);
}
