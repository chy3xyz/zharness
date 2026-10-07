//! Model-facing shared team task board (upstream dsh-tool-agent-team), minimal
//! slice: create/list/get/update with revision CAS, ownership, dependencies
//! and readiness. Process-global and in memory.

const std = @import("std");
const model = @import("../model/model.zig");
const tool_reg = @import("registry.zig");
const builtin = @import("builtin.zig");
const jsonx = @import("../server/apiproxy/jsonx.zig");

pub const ToolCall = builtin.ToolCall;
pub const ToolResult = builtin.ToolResult;
pub const freeResult = builtin.freeResult;

pub const default_limit: usize = 50;
pub const max_limit: usize = 100;
pub const max_tasks: usize = 512;

const Status = enum {
    pending,
    in_progress,
    completed,

    fn asStr(self: Status) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
        };
    }
};

const Task = struct {
    id: []u8,
    revision: u64,
    status: Status = .pending,
    subject: []u8,
    description: []u8,
    owner: ?[]u8 = null,
    blocked_by: [][]u8 = &.{},
    write_scopes: [][]u8 = &.{},
};

const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),
    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

var g_tasks: std.ArrayList(Task) = .empty;
var g_lock: SpinLock = .{};
var g_seq: u64 = 0;

fn alloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn freeStrings(a: std.mem.Allocator, items: [][]u8) void {
    for (items) |s| a.free(s);
    a.free(items);
}

fn freeTask(a: std.mem.Allocator, t: *Task) void {
    a.free(t.id);
    a.free(t.subject);
    a.free(t.description);
    if (t.owner) |o| a.free(o);
    freeStrings(a, t.blocked_by);
    freeStrings(a, t.write_scopes);
}

fn findLocked(id: []const u8) ?*Task {
    for (g_tasks.items) |*t| {
        if (std.mem.eql(u8, t.id, id)) return t;
    }
    return null;
}

fn findLockedConst(id: []const u8) ?*Task {
    for (g_tasks.items) |*t| {
        if (std.mem.eql(u8, t.id, id)) return t;
    }
    return null;
}

fn indexOfLocked(id: []const u8) ?usize {
    for (g_tasks.items, 0..) |t, i| {
        if (std.mem.eql(u8, t.id, id)) return i;
    }
    return null;
}

fn isCompleted(id: []const u8) bool {
    const t = findLockedConst(id) orelse return false;
    return t.status == .completed;
}

fn readyLocked(t: *const Task) bool {
    if (t.status == .completed) return false;
    for (t.blocked_by) |b| {
        if (!isCompleted(b)) return false;
    }
    return true;
}

fn parseStringArray(a: std.mem.Allocator, json: []const u8, key: []const u8) !?[][]u8 {
    const raw = jsonx.getRaw(json, key) orelse return null;
    if (raw.len < 2 or raw[0] != '[') return null;
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| a.free(s);
        out.deinit(a);
    }
    var i: usize = 1;
    while (i < raw.len) {
        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\n' or raw[i] == '\r' or raw[i] == ',')) i += 1;
        if (i >= raw.len or raw[i] == ']') break;
        if (raw[i] != '"') break;
        const start = i + 1;
        i = start;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\') {
                i += 1;
                continue;
            }
            if (raw[i] == '"') break;
        }
        if (i >= raw.len) break;
        const body = raw[start..i];
        i += 1;
        try out.append(a, @constCast(try jsonx.decodeString(a, body)));
    }
    return try out.toOwnedSlice(a);
}

fn appendView(a: std.mem.Allocator, out: *std.ArrayList(u8), t: *const Task) !void {
    try out.appendSlice(a, "{\"id\":");
    try jsonx.appendJsonString(a, out, t.id);
    try out.appendSlice(a, ",\"revision\":");
    try jsonx.appendInt(a, out, @intCast(t.revision));
    try out.appendSlice(a, ",\"status\":\"");
    try out.appendSlice(a, t.status.asStr());
    try out.appendSlice(a, "\",\"subject\":");
    try jsonx.appendJsonString(a, out, t.subject);
    try out.appendSlice(a, ",\"description\":");
    try jsonx.appendJsonString(a, out, t.description);
    try out.appendSlice(a, ",\"owner\":");
    if (t.owner) |o| try jsonx.appendJsonString(a, out, o) else try out.appendSlice(a, "null");
    try out.appendSlice(a, ",\"blockedBy\":[");
    for (t.blocked_by, 0..) |b, i| {
        if (i > 0) try out.append(a, ',');
        try jsonx.appendJsonString(a, out, b);
    }
    try out.appendSlice(a, "],\"writeScopes\":[");
    for (t.write_scopes, 0..) |w, i| {
        if (i > 0) try out.append(a, ',');
        try jsonx.appendJsonString(a, out, w);
    }
    try out.appendSlice(a, "],\"ready\":");
    try out.appendSlice(a, if (readyLocked(t)) "true" else "false");
    try out.append(a, '}');
}

pub fn definitions() [4]tool_reg.ToolDefinition {
    return .{
        .{
            .name = "team_task_create",
            .description = "Create one unowned pending task on the shared team task board.",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{"subject":{"type":"string"},"description":{"type":"string"},"blocked_by":{"type":"array","items":{"type":"string"}},"write_scopes":{"type":"array","items":{"type":"string"}}},"required":["subject","description"]}
            ,
        },
        .{
            .name = "team_task_list",
            .description = "List shared tasks with readiness, owner, revision and blockers.",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{"status":{"type":"string","enum":["pending","in_progress","completed"]},"owner":{"type":"string"},"ready":{"type":"boolean"},"cursor":{"type":"integer"},"limit":{"type":"integer"}},"required":[]}
            ,
        },
        .{
            .name = "team_task_get",
            .description = "Read the complete latest value of one shared task.",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{"task_id":{"type":"string"}},"required":["task_id"]}
            ,
        },
        .{
            .name = "team_task_update",
            .description = "Compare-and-set a shared task action using the latest revision.",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{"task_id":{"type":"string"},"expected_revision":{"type":"integer"},"action":{"type":"string","enum":["claim","release","edit","set_dependencies","complete","reopen","reassign","delete"]},"subject":{"type":"string"},"description":{"type":"string"},"blocked_by":{"type":"array","items":{"type":"string"}},"write_scopes":{"type":"array","items":{"type":"string"}},"owner":{"type":"string"}},"required":["task_id","expected_revision","action"]}
            ,
        },
    };
}

pub fn register(reg: *tool_reg.ToolRegistry) !void {
    const defs = definitions();
    for (defs) |d| try reg.register(d);
}

pub fn isTeamTaskTool(name: []const u8) bool {
    const defs = definitions();
    for (defs) |d| {
        if (std.mem.eql(u8, name, d.name)) return true;
    }
    return false;
}

fn fail(a: std.mem.Allocator, msg: []const u8) !ToolResult {
    return .{ .success = false, .output = "", .err_msg = try a.dupe(u8, msg) };
}

fn okJson(a: std.mem.Allocator, out: *std.ArrayList(u8)) !ToolResult {
    return .{ .success = true, .output = try out.toOwnedSlice(a) };
}

fn parseStatus(s: []const u8) ?Status {
    if (std.mem.eql(u8, s, "pending")) return .pending;
    if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, s, "completed")) return .completed;
    return null;
}

pub fn execute(a: std.mem.Allocator, call: ToolCall) !ToolResult {
    if (std.mem.eql(u8, call.name, "team_task_create")) return create(a, call.arguments);
    if (std.mem.eql(u8, call.name, "team_task_list")) return list(a, call.arguments);
    if (std.mem.eql(u8, call.name, "team_task_get")) return get(a, call.arguments);
    if (std.mem.eql(u8, call.name, "team_task_update")) return update(a, call.arguments);
    return fail(a, "unknown team task tool");
}

fn create(a: std.mem.Allocator, args: []const u8) !ToolResult {
    const subject = (try model.extractStringField(a, args, "subject")) orelse
        return fail(a, "team_task_create: missing 'subject'");
    defer a.free(subject);
    const description = (try model.extractStringField(a, args, "description")) orelse
        return fail(a, "team_task_create: missing 'description'");
    defer a.free(description);
    if (std.mem.trim(u8, subject, " \t\r\n").len == 0) return fail(a, "team_task_create: subject must be non-empty");

    // Stored arrays must use the store allocator so freeTask matches.
    const blocked = (try parseStringArray(alloc(), args, "blocked_by")) orelse try alloc().alloc([]u8, 0);
    errdefer freeStrings(alloc(), blocked);
    const scopes = (try parseStringArray(alloc(), args, "write_scopes")) orelse try alloc().alloc([]u8, 0);
    errdefer freeStrings(alloc(), scopes);

    g_lock.lock();
    defer g_lock.unlock();
    if (g_tasks.items.len >= max_tasks) return fail(a, "team_task_create: task board is full");
    g_seq += 1;
    const pa = alloc();
    const id = try std.fmt.allocPrint(pa, "tt-{d}", .{g_seq});
    errdefer pa.free(id);
    try g_tasks.append(pa, .{
        .id = id,
        .revision = 1,
        .subject = try pa.dupe(u8, subject),
        .description = try pa.dupe(u8, description),
        .blocked_by = blocked,
        .write_scopes = scopes,
    });
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try appendView(a, &out, &g_tasks.items[g_tasks.items.len - 1]);
    return try okJson(a, &out);
}

fn list(a: std.mem.Allocator, args: []const u8) !ToolResult {
    const status_filter: ?Status = blk: {
        const s = (try model.extractStringField(a, args, "status")) orelse break :blk null;
        defer a.free(s);
        break :blk parseStatus(s);
    };
    const owner = try model.extractStringField(a, args, "owner");
    defer if (owner) |o| a.free(o);
    const ready_raw = jsonx.getRaw(args, "ready");
    const ready_filter: ?bool = if (ready_raw) |r| std.mem.eql(u8, std.mem.trim(u8, r, " "), "true") else null;
    var cursor: usize = 0;
    if (jsonx.getInt(args, "cursor")) |c| {
        if (c > 0) cursor = @intCast(c);
    }
    var limit: usize = default_limit;
    if (jsonx.getInt(args, "limit")) |l| {
        if (l < 1 or l > max_limit) return fail(a, "team_task_list: limit must be 1..100");
        limit = @intCast(l);
    }

    g_lock.lock();
    defer g_lock.unlock();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "{\"tasks\":[");
    var shown: usize = 0;
    var seen: usize = 0;
    var more = false;
    for (g_tasks.items) |*t| {
        if (status_filter) |s| {
            if (t.status != s) continue;
        }
        if (owner) |o| {
            if (std.mem.eql(u8, o, "unowned")) {
                if (t.owner != null) continue;
            } else if (t.owner == null or !std.mem.eql(u8, t.owner.?, o)) continue;
        }
        if (ready_filter) |rf| {
            if (readyLocked(t) != rf) continue;
        }
        if (seen < cursor) {
            seen += 1;
            continue;
        }
        if (shown >= limit) {
            more = true;
            break;
        }
        if (shown > 0) try out.append(a, ',');
        try appendView(a, &out, t);
        shown += 1;
    }
    try out.appendSlice(a, "]");
    if (more) {
        try out.appendSlice(a, ",\"nextCursor\":");
        try jsonx.appendInt(a, &out, @intCast(cursor + shown));
    }
    try out.append(a, '}');
    return try okJson(a, &out);
}

fn get(a: std.mem.Allocator, args: []const u8) !ToolResult {
    const id = (try model.extractStringField(a, args, "task_id")) orelse
        return fail(a, "team_task_get: missing 'task_id'");
    defer a.free(id);
    g_lock.lock();
    defer g_lock.unlock();
    const t = findLocked(id) orelse return fail(a, "team_task_get: unknown task_id");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try appendView(a, &out, t);
    return try okJson(a, &out);
}

fn update(a: std.mem.Allocator, args: []const u8) !ToolResult {
    const id = (try model.extractStringField(a, args, "task_id")) orelse
        return fail(a, "team_task_update: missing 'task_id'");
    defer a.free(id);
    const expected = jsonx.getInt(args, "expected_revision") orelse
        return fail(a, "team_task_update: missing 'expected_revision'");
    const action = (try model.extractStringField(a, args, "action")) orelse
        return fail(a, "team_task_update: missing 'action'");
    defer a.free(action);
    const new_subject = try model.extractStringField(a, args, "subject");
    defer if (new_subject) |s| a.free(s);
    const new_desc = try model.extractStringField(a, args, "description");
    defer if (new_desc) |s| a.free(s);
    const new_owner = try model.extractStringField(a, args, "owner");
    defer if (new_owner) |o| a.free(o);
    const new_blocked = try parseStringArray(alloc(), args, "blocked_by");
    defer if (new_blocked) |b| freeStrings(alloc(), b);
    const new_scopes = try parseStringArray(alloc(), args, "write_scopes");
    defer if (new_scopes) |s| freeStrings(alloc(), s);

    g_lock.lock();
    defer g_lock.unlock();
    const t = findLocked(id) orelse return fail(a, "team_task_update: unknown task_id");
    if (@as(i64, @intCast(t.revision)) != expected)
        return fail(a, "team_task_update: revision conflict (current revision differs)");

    const pa = alloc();
    if (std.mem.eql(u8, action, "delete")) {
        const idx = indexOfLocked(id) orelse return fail(a, "team_task_update: unknown task_id");
        var snapshot = g_tasks.items[idx];
        _ = g_tasks.swapRemove(idx);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        // Render from the detached snapshot, then free it.
        try appendView(a, &out, &snapshot);
        freeTask(pa, &snapshot);
        return try okJson(a, &out);
    }

    if (std.mem.eql(u8, action, "claim")) {
        if (t.owner) |o| pa.free(o);
        t.owner = try pa.dupe(u8, new_owner orelse "agent");
        t.status = .in_progress;
    } else if (std.mem.eql(u8, action, "release")) {
        if (t.owner) |o| pa.free(o);
        t.owner = null;
        if (t.status != .completed) t.status = .pending;
    } else if (std.mem.eql(u8, action, "complete")) {
        t.status = .completed;
    } else if (std.mem.eql(u8, action, "reopen")) {
        t.status = .pending;
    } else if (std.mem.eql(u8, action, "reassign")) {
        if (t.owner) |o| pa.free(o);
        t.owner = if (new_owner) |o| try pa.dupe(u8, o) else null;
    } else if (std.mem.eql(u8, action, "edit")) {
        if (new_subject) |s| {
            pa.free(t.subject);
            t.subject = try pa.dupe(u8, s);
        }
        if (new_desc) |d| {
            pa.free(t.description);
            t.description = try pa.dupe(u8, d);
        }
        if (new_scopes) |s| {
            freeStrings(pa, t.write_scopes);
            t.write_scopes = s;
        }
    } else if (std.mem.eql(u8, action, "set_dependencies")) {
        if (new_blocked) |b| {
            freeStrings(pa, t.blocked_by);
            t.blocked_by = b;
        }
    } else {
        return fail(a, "team_task_update: unknown action");
    }
    t.revision += 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try appendView(a, &out, t);
    return try okJson(a, &out);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "team task create/list/get/update CAS round-trip" {
    const a = testing.allocator;
    var c = try execute(a, .{ .name = "team_task_create", .arguments = "{\"subject\":\"Build\",\"description\":\"Make it\",\"blocked_by\":[\"tt-0\"]}" });
    defer freeResult(a, &c);
    try testing.expect(c.success);
    try testing.expect(std.mem.indexOf(u8, c.output, "\"status\":\"pending\"") != null);
    try testing.expect(std.mem.indexOf(u8, c.output, "\"ready\":false") != null);

    const sp = std.mem.indexOf(u8, c.output, "tt-").?;
    const ep = std.mem.indexOfScalarPos(u8, c.output, sp, '"').?;
    const id = c.output[sp..ep];

    var buf: [160]u8 = undefined;
    const getargs = try std.fmt.bufPrint(&buf, "{{\"task_id\":\"{s}\"}}", .{id});
    var g = try execute(a, .{ .name = "team_task_get", .arguments = getargs });
    defer freeResult(a, &g);
    try testing.expect(g.success);

    var cbuf: [200]u8 = undefined;
    const claim = try std.fmt.bufPrint(&cbuf, "{{\"task_id\":\"{s}\",\"expected_revision\":1,\"action\":\"claim\"}}", .{id});
    var cl = try execute(a, .{ .name = "team_task_update", .arguments = claim });
    defer freeResult(a, &cl);
    try testing.expect(cl.success);
    try testing.expect(std.mem.indexOf(u8, cl.output, "\"revision\":2") != null);
    try testing.expect(std.mem.indexOf(u8, cl.output, "\"owner\":\"agent\"") != null);

    // Stale CAS is rejected.
    var stale = try execute(a, .{ .name = "team_task_update", .arguments = claim });
    defer freeResult(a, &stale);
    try testing.expect(!stale.success);

    var dbuf: [240]u8 = undefined;
    const done = try std.fmt.bufPrint(&dbuf, "{{\"task_id\":\"{s}\",\"expected_revision\":2,\"action\":\"complete\"}}", .{id});
    var d = try execute(a, .{ .name = "team_task_update", .arguments = done });
    defer freeResult(a, &d);
    try testing.expect(d.success);

    var l = try execute(a, .{ .name = "team_task_list", .arguments = "{\"status\":\"completed\"}" });
    defer freeResult(a, &l);
    try testing.expect(std.mem.indexOf(u8, l.output, id) != null);
}
