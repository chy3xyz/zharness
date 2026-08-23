//! Plan / Task tracking (dev.md §XVII, §XXXIV planning state).
//!
//! The model mutates the plan through `plan_add` / `plan_update` tools; the
//! rendered checklist is injected into context assembly each turn so the
//! agent can self-track multi-step work.
//!
//! Integration contract:
//!   - AgentLoop owns a PlanBoard; renderPrompt() output is appended to the
//!     system prompt area by the wiring pass.
//!   - TOOL_SCHEMAS carries OpenAI-style parameter fragments for
//!     registry.registerBuiltins-style registration; executeTool dispatches
//!     parsed flat-JSON args and returns a human-readable result the caller
//!     frees.
//!
//! Self-contained; testable standalone via `zig test src/agent/plan.zig`.

const std = @import("std");

pub const TaskStatus = enum {
    pending,
    in_progress,
    done,
    blocked,

    pub fn asStr(self: TaskStatus) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) ?TaskStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "done")) return .done;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        return null;
    }

    fn marker(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "[ ]",
            .in_progress => "[~]",
            .done => "[x]",
            .blocked => "[!]",
        };
    }
};

pub const Task = struct {
    id: u32,
    text: []const u8,
    status: TaskStatus = .pending,
    note: ?[]const u8 = null,
};

pub const PlanBoard = struct {
    alloc: std.mem.Allocator,
    tasks: std.ArrayList(Task) = .empty,
    next_id: u32 = 1,

    pub fn init(alloc: std.mem.Allocator) PlanBoard {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *PlanBoard) void {
        for (self.tasks.items) |t| {
            self.alloc.free(t.text);
            if (t.note) |n| self.alloc.free(n);
        }
        self.tasks.deinit(self.alloc);
    }

    pub fn addTask(self: *PlanBoard, text: []const u8) !u32 {
        const copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(copy);
        const id = self.next_id;
        self.next_id += 1;
        try self.tasks.append(self.alloc, .{ .id = id, .text = copy });
        return id;
    }

    /// Transition a task's status. False when the id is unknown.
    pub fn updateStatus(self: *PlanBoard, id: u32, status: TaskStatus) bool {
        for (self.tasks.items) |*t| {
            if (t.id == id) {
                t.status = status;
                return true;
            }
        }
        return false;
    }

    /// Attach/replace an optional note. False when the id is unknown.
    pub fn setNote(self: *PlanBoard, id: u32, note: ?[]const u8) !bool {
        for (self.tasks.items) |*t| {
            if (t.id == id) {
                if (t.note) |n| self.alloc.free(n);
                t.note = if (note) |n| try self.alloc.dupe(u8, n) else null;
                return true;
            }
        }
        return false;
    }

    pub fn count(self: *const PlanBoard) usize {
        return self.tasks.items.len;
    }

    /// Markdown checklist for context injection. Empty board renders "" so
    /// callers can skip the section entirely.
    pub fn renderPrompt(self: *const PlanBoard, alloc: std.mem.Allocator) ![]const u8 {
        if (self.tasks.items.len == 0) return try alloc.dupe(u8, "");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "## Plan\n");
        for (self.tasks.items) |t| {
            var idb: [16]u8 = undefined;
            const ids = std.fmt.bufPrint(&idb, "{d}", .{t.id}) catch unreachable;
            try out.appendSlice(alloc, ids);
            try out.appendSlice(alloc, ". ");
            try out.appendSlice(alloc, t.status.marker());
            try out.appendSlice(alloc, " ");
            try out.appendSlice(alloc, t.text);
            if (t.note) |n| {
                try out.appendSlice(alloc, " — ");
                try out.appendSlice(alloc, n);
            }
            try out.append(alloc, '\n');
        }
        return out.toOwnedSlice(alloc);
    }
};

// ── model-facing tool surface ───────────────────────────────────────────────

pub const plan_add_name = "plan_add";
pub const plan_update_name = "plan_update";

/// OpenAI-style parameter fragments (no surrounding envelope), matching
/// src/tool/registry.zig conventions.
pub const TOOL_SCHEMAS = [_]ToolSchema{
    .{
        .name = plan_add_name,
        .parameters_json =
        \\{"type":"object","properties":{"text":{"type":"string","description":"Task description"}},"required":["text"]}
        ,
    },
    .{
        .name = plan_update_name,
        .parameters_json =
        \\{"type":"object","properties":{"task_id":{"type":"integer","description":"Task id"},"status":{"type":"string","enum":["pending","in_progress","done","blocked"]},"note":{"type":"string","description":"Optional progress note"}},"required":["task_id","status"]}
        ,
    },
};

pub const ToolSchema = struct {
    name: []const u8,
    parameters_json: []const u8,
};

pub const ExecuteError = error{ UnknownTool, MissingArgument, BadArgument } || std.mem.Allocator.Error;

/// Dispatch a plan tool call. Returned string is allocated with `alloc`
/// (caller frees).
pub fn executeTool(board: *PlanBoard, name: []const u8, args_json: []const u8, alloc: std.mem.Allocator) ExecuteError![]const u8 {
    // Local flat-object arg scanner — adapted from src/tool/builtin.zig
    // parseArgs (string/number tokens only, escape-aware).
    var map = std.StringHashMap([]const u8).init(alloc);
    defer {
        var it = map.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        map.deinit();
    }
    var i: usize = 0;
    while (i < args_json.len) : (i += 1) {
        if (args_json[i] != '"') continue;
        i += 1;
        const ks = i;
        while (i < args_json.len and args_json[i] != '"') : (i += 1) {
            if (args_json[i] == '\\' and i + 1 < args_json.len) i += 1;
        }
        if (i >= args_json.len) break;
        const key_raw = args_json[ks..i];
        const key = try unescapeLocal(alloc, key_raw);
        errdefer alloc.free(key);
        i += 1;
        while (i < args_json.len and args_json[i] != ':') : (i += 1) {}
        if (i >= args_json.len) break;
        i += 1;
        while (i < args_json.len and (args_json[i] == ' ' or args_json[i] == '\t')) : (i += 1) {}
        if (i >= args_json.len) break;
        var value: []const u8 = "";
        if (args_json[i] == '"') {
            i += 1;
            const vs = i;
            while (i < args_json.len and args_json[i] != '"') : (i += 1) {
                if (args_json[i] == '\\' and i + 1 < args_json.len) i += 1;
            }
            value = try unescapeLocal(alloc, args_json[vs..i]);
        } else {
            const vs = i;
            while (i < args_json.len and (std.ascii.isAlphanumeric(args_json[i]) or args_json[i] == '.' or args_json[i] == '-')) : (i += 1) {}
            value = try alloc.dupe(u8, args_json[vs..i]);
        }
        try map.put(key, value);
    }

    if (std.mem.eql(u8, name, plan_add_name)) {
        const text = map.get("text") orelse return error.MissingArgument;
        const id = try board.addTask(text);
        return std.fmt.allocPrint(alloc, "task {d} added", .{id});
    }
    if (std.mem.eql(u8, name, plan_update_name)) {
        const id_s = map.get("task_id") orelse return error.MissingArgument;
        const status_s = map.get("status") orelse return error.MissingArgument;
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, id_s, " "), 10) catch return error.BadArgument;
        const status = TaskStatus.fromStr(status_s) orelse return error.BadArgument;
        if (!board.updateStatus(id, status)) return error.BadArgument;
        if (map.get("note")) |n| _ = try board.setNote(id, n);
        return std.fmt.allocPrint(alloc, "task {d} -> {s}", .{ id, status.asStr() });
    }
    return error.UnknownTool;
}

fn unescapeLocal(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            switch (input[i]) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                't' => try out.append(alloc, '\t'),
                else => try out.append(alloc, input[i]),
            }
        } else {
            try out.append(alloc, input[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

// ── tests ───────────────────────────────────────────────────────────────────

test "task lifecycle and unknown ids" {
    const alloc = std.testing.allocator;
    var b = PlanBoard.init(alloc);
    defer b.deinit();
    const id = try b.addTask("write failing test");
    try std.testing.expectEqual(@as(u32, 1), id);
    try std.testing.expect(b.updateStatus(id, .done));
    try std.testing.expect(!b.updateStatus(99, .done));
    try std.testing.expect(try b.setNote(id, "green"));
    try std.testing.expect(!try b.setNote(99, "nope"));
    try std.testing.expectEqual(@as(usize, 1), b.count());
}

test "renderPrompt formats checklist" {
    const alloc = std.testing.allocator;
    var b = PlanBoard.init(alloc);
    defer b.deinit();
    const empty = try b.renderPrompt(alloc);
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const id1 = try b.addTask("first");
    const id2 = try b.addTask("second \"quoted\"");
    _ = b.updateStatus(id1, .done);
    _ = b.updateStatus(id2, .in_progress);
    const s = try b.renderPrompt(alloc);
    defer alloc.free(s);
    try std.testing.expect(std.mem.startsWith(u8, s, "## Plan\n"));
    try std.testing.expect(std.mem.indexOf(u8, s, "1. [x] first") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "2. [~] second \"quoted\"") != null);
}

test "executeTool add update note and errors" {
    const alloc = std.testing.allocator;
    var b = PlanBoard.init(alloc);
    defer b.deinit();

    const r1 = try executeTool(&b, plan_add_name, "{\"text\":\"step one\"}", alloc);
    defer alloc.free(r1);
    try std.testing.expectEqualStrings("task 1 added", r1);

    const r2 = try executeTool(
        &b,
        plan_update_name,
        "{\"task_id\":1,\"status\":\"done\",\"note\":\"verified\"}",
        alloc,
    );
    defer alloc.free(r2);
    try std.testing.expectEqualStrings("task 1 -> done", r2);
    try std.testing.expectEqualStrings("verified", b.tasks.items[0].note.?);

    try std.testing.expectError(error.MissingArgument, executeTool(&b, plan_add_name, "{}", alloc));
    try std.testing.expectError(error.BadArgument, executeTool(&b, plan_update_name, "{\"task_id\":42,\"status\":\"done\"}", alloc));
    try std.testing.expectError(error.UnknownTool, executeTool(&b, "nope", "{}", alloc));
}
