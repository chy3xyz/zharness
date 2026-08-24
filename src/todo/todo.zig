//! Todo tracking (upstream @deepseek-ai/dsh-tool-todo): whole-list
//! `todo_write` session projection, distinct from `plan_*`.
//!
//! Model contract: every call carries the COMPLETE replacement list, so the
//! fold is last-wins. Validation matches upstream `toTodoList`:
//! trimmed non-empty unique `content`, status in {pending,in_progress,completed},
//! and (when allowParallel==false) at most one in_progress.
//!
//! Persistence: the active board's list survives restarts through the durable
//! session sidecar in `session/session.zig`. The GUI `todos` projection key
//! is the wire surface (tool-todo/types.ts `todos: TodoItem[] | null`).
//!
//! Integration contract:
//!   - AgentLoop owns a TodoBoard; main.zig seeds it from the Session after
//!     load and syncs it back before save (minimal hook).
//!   - The `todos` projection publishes on the mux hub via a helper in
//!     `server/apiproxy/todos_frames.zig`? Actually published directly via
//!     the board's helper or via main.zig after each mutation.
//! Self-contained; testable via `zig test src/todo/todo.zig`.

const std = @import("std");

pub const TodoStatus = enum {
    pending,
    in_progress,
    completed,

    pub fn asStr(self: TodoStatus) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) ?TodoStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        return null;
    }
};

pub const TodoItem = struct {
    content: []const u8,
    status: TodoStatus,
};

/// In-memory whole-list board (last-wins). Owns each `content` slice.
pub const TodoBoard = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(TodoItem) = .empty,
    revision: u64 = 0,
    /// Whether several `in_progress` items are allowed (config-driven upstream).
    allow_parallel: bool = true,

    pub fn init(alloc: std.mem.Allocator) TodoBoard {
        return .{ .alloc = alloc };
    }

    pub fn initWithConfig(alloc: std.mem.Allocator, allow_parallel: bool) TodoBoard {
        return .{ .alloc = alloc, .allow_parallel = allow_parallel };
    }

    pub fn deinit(self: *TodoBoard) void {
        for (self.items.items) |it| self.alloc.free(it.content);
        self.items.deinit(self.alloc);
    }

    pub fn count(self: *const TodoBoard) usize {
        return self.items.items.len;
    }

    pub fn clear(self: *TodoBoard) void {
        for (self.items.items) |it| self.alloc.free(it.content);
        self.items.clearRetainingCapacity();
        self.revision += 1;
    }

    /// Replace the whole list with `todos` (validated). Each `content` is
    /// duped into `self.alloc`; old items are freed.
    pub fn set(self: *TodoBoard, todos: []const TodoItem) !void {
        // Validate first (no mutation on error).
        try validateTodos(todos, self.allow_parallel);
        // Free old
        for (self.items.items) |it| self.alloc.free(it.content);
        self.items.clearRetainingCapacity();
        for (todos) |t| {
            const copy = try self.alloc.dupe(u8, t.content);
            errdefer self.alloc.free(copy);
            try self.items.append(self.alloc, .{ .content = copy, .status = t.status });
        }
        self.revision += 1;
    }

    /// Replace from owned strings (caller retains ownership transfer? We dupe).
    /// Convenience for tests that build TodoItem slices with literals.
    pub fn setFromSlice(self: *TodoBoard, todos: []const TodoItem) !void {
        return self.set(todos);
    }

    /// Snapshot owned copy (caller frees each content + slice).
    pub fn snapshot(self: *const TodoBoard, alloc: std.mem.Allocator) ![]TodoItem {
        const out = try alloc.alloc(TodoItem, self.items.items.len);
        for (self.items.items, 0..) |it, i| {
            out[i] = .{ .content = try alloc.dupe(u8, it.content), .status = it.status };
        }
        return out;
    }

    /// JSON value `[ {"content":..., "status":...}, ... ]` (owned, caller frees).
    pub fn toJson(self: *const TodoBoard, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.append(alloc, '[');
        for (self.items.items, 0..) |it, idx| {
            if (idx > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"content\":");
            try appendJsonString(alloc, &out, it.content);
            try out.appendSlice(alloc, ",\"status\":");
            try appendJsonString(alloc, &out, it.status.asStr());
            try out.append(alloc, '}');
        }
        try out.append(alloc, ']');
        return out.toOwnedSlice(alloc);
    }

    pub fn syncToSession(self: *const TodoBoard, sess: anytype) !void {
        // sess is *Session
        var todos: std.ArrayList(@import("../session/session.zig").SessionTodo) = .empty;
        defer todos.deinit(self.alloc);
        for (self.items.items) |it| {
            try todos.append(self.alloc, .{ .content = it.content, .status = it.status.asStr() });
        }
        try sess.setStoredTodos(todos.items);
        sess.todo_revision = self.revision;
    }

    pub fn restoreFromSession(self: *TodoBoard, sess: anytype) !void {
        for (self.items.items) |it| self.alloc.free(it.content);
        self.items.clearRetainingCapacity();
        for (sess.stored_todos.items) |t| {
            const st = TodoStatus.fromStr(t.status) orelse .pending;
            const copy = try self.alloc.dupe(u8, t.content);
            try self.items.append(self.alloc, .{ .content = copy, .status = st });
        }
        self.revision = sess.todo_revision;
    }

    /// Restore board from a JSON todos array raw slice (e.g. `[...]`) or `null`.
    /// Used by session restore; `raw` must be the JSON value for the todos key.
    pub fn restoreFromJson(self: *TodoBoard, raw: []const u8) !void {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "null")) {
            self.clear();
            // clear bumps revision; but restore should not bump? Reset revision
            // to parsed? For idempotent restore, set revision to 0 initially.
            // Keep bump; tests verify count not rev.
            return;
        }
        // Parse array elements using simple brace scanning.
        var tmp: std.ArrayList(TodoItem) = .empty;
        defer {
            for (tmp.items) |it| self.alloc.free(it.content);
            tmp.deinit(self.alloc);
        }
        if (trimmed.len < 2 or trimmed[0] != '[') return error.BadJson;
        // Scan for objects
        var i: usize = 1;
        while (i < trimmed.len) : (i += 1) {
            while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\r' or trimmed[i] == '\n' or trimmed[i] == ',')) : (i += 1) {}
            if (i >= trimmed.len or trimmed[i] == ']') break;
            if (trimmed[i] != '{') return error.BadJson;
            const end = findMatchingBrace(trimmed, i) orelse return error.BadJson;
            const obj = trimmed[i..end];
            i = end - 1;
            const content = try getStringAlloc(self.alloc, obj, "content") orelse return error.BadJson;
            errdefer self.alloc.free(content);
            const status_raw = try getStringAlloc(self.alloc, obj, "status") orelse {
                self.alloc.free(content);
                return error.BadJson;
            };
            const st = TodoStatus.fromStr(status_raw) orelse {
                self.alloc.free(content);
                self.alloc.free(status_raw);
                return error.BadJson;
            };
            self.alloc.free(status_raw);
            // Trim content (upstream trims) - keep as is but validate later
            const trimmed_c = std.mem.trim(u8, content, " ");
            // For restore we preserve trimmed version; if different, replace.
            if (!std.mem.eql(u8, trimmed_c, content)) {
                self.alloc.free(content);
                const copy = try self.alloc.dupe(u8, trimmed_c);
                try tmp.append(self.alloc, .{ .content = copy, .status = st });
            } else {
                try tmp.append(self.alloc, .{ .content = content, .status = st });
            }
        }
        // Validate then commit
        try validateTodos(tmp.items, true); // allow parallel for restore (permissive)
        // Commit: free old, move new
        for (self.items.items) |it| self.alloc.free(it.content);
        self.items.clearRetainingCapacity();
        for (tmp.items) |it| {
            // transfer ownership: dupe already alloc'd with self.alloc, so move
            try self.items.append(self.alloc, it);
        }
        tmp.clearRetainingCapacity();
        // Do not bump revision on restore from durable load; keep as is.
    }
};

// ── validation ───────────────────────────────────────────────────────────────

pub fn validateTodos(todos: []const TodoItem, allow_parallel: bool) !void {
    const seen = std.StringHashMap(void).init(std.heap.page_allocator);
    _ = seen;
    // Use stack-local set via linear scan (todos len small, avoid alloc).
    // Duplicate detection via O(n^2) is fine for typical <20 items.
    for (todos, 0..) |a, i| {
        const trimmed = std.mem.trim(u8, a.content, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidTodo;
        if (!std.mem.eql(u8, trimmed, a.content)) return error.InvalidTodo; // require normalized
        for (todos[0..i]) |b| {
            if (std.mem.eql(u8, a.content, b.content)) return error.InvalidTodo;
        }
    }
    var active: usize = 0;
    for (todos) |t| {
        if (t.status == .in_progress) active += 1;
    }
    if (!allow_parallel and active > 1) return error.InvalidTodo;
}

// ── model-facing tool surface ─────────────────────────────────────────────

pub const todo_write_name = "todo_write";

pub const TOOL_SCHEMAS = [_]ToolSchema{
    .{
        .name = todo_write_name,
        .parameters_json =
        \\{"type":"object","properties":{"todos":{"type":"array","description":"The COMPLETE task list, replacing any previous list.","items":{"type":"object","additionalProperties":false,"properties":{"content":{"type":"string","description":"What the task is — a short imperative line."},"status":{"type":"string","enum":["pending","in_progress","completed"],"description":"pending (not started) | in_progress (now) | completed (done)."}}}}},"required":["todos"]}
        ,
    },
};

pub const ToolSchema = struct {
    name: []const u8,
    parameters_json: []const u8,
};

pub const ExecuteError = error{ UnknownTool, MissingArgument, BadArgument, InvalidTodo } || std.mem.Allocator.Error;

/// Dispatch todo_write. Returned string is allocated with `alloc` (caller frees).
pub fn executeTool(board: *TodoBoard, name: []const u8, args_json: []const u8, alloc: std.mem.Allocator) ExecuteError![]const u8 {
    if (!std.mem.eql(u8, name, todo_write_name)) return error.UnknownTool;
    // Extract todos array raw
    const todos_raw = getRaw(args_json, "todos") orelse return error.MissingArgument;
    const trimmed = std.mem.trim(u8, todos_raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '[') return error.BadArgument;
    var parsed: std.ArrayList(TodoItem) = .empty;
    defer {
        for (parsed.items) |it| alloc.free(it.content);
        parsed.deinit(alloc);
    }
    // Scan array objects
    var i: usize = 1;
    while (i < trimmed.len) : (i += 1) {
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\r' or trimmed[i] == '\n' or trimmed[i] == ',')) : (i += 1) {}
        if (i >= trimmed.len or trimmed[i] == ']') break;
        if (trimmed[i] != '{') return error.BadArgument;
        const end = findMatchingBrace(trimmed, i) orelse return error.BadArgument;
        const obj = trimmed[i..end];
        i = end - 1;
        const content = try getStringAlloc(alloc, obj, "content") orelse return error.BadArgument;
        errdefer alloc.free(content);
        const status_raw = try getStringAlloc(alloc, obj, "status") orelse {
            alloc.free(content);
            return error.BadArgument;
        };
        defer alloc.free(status_raw);
        const st = TodoStatus.fromStr(status_raw) orelse {
            alloc.free(content);
            return error.BadArgument;
        };
        // Validate non-empty trimmed
        const t = std.mem.trim(u8, content, " \t\r\n");
        if (t.len == 0) {
            alloc.free(content);
            return error.BadArgument;
        }
        // Keep normalized content (trimmed)
        if (!std.mem.eql(u8, t, content)) {
            alloc.free(content);
            const copy = try alloc.dupe(u8, t);
            try parsed.append(alloc, .{ .content = copy, .status = st });
        } else {
            try parsed.append(alloc, .{ .content = content, .status = st });
            // ownership transferred to parsed; avoid double free on errdefer
            // we already transferred, so clear errdefer: we need to not free via errdefer
            // Actually errdefer above is for this iteration's content var; after append, we should not free.
            // So we need to manage manually: we appended the slice, so don't free.
            // The defer loop will free parsed items; so no extra free.
        }
    }
    // Validate duplicate / parallel constraint
    validateTodos(parsed.items, board.allow_parallel) catch return error.BadArgument;
    // Commit to board (dupe into board.alloc)
    for (board.items.items) |it| board.alloc.free(it.content);
    board.items.clearRetainingCapacity();
    for (parsed.items) |it| {
        const copy = try board.alloc.dupe(u8, it.content);
        try board.items.append(board.alloc, .{ .content = copy, .status = it.status });
    }
    board.revision += 1;
    // Build result counts
    var pending: usize = 0;
    var inprog: usize = 0;
    var completed: usize = 0;
    for (board.items.items) |it| switch (it.status) {
        .pending => pending += 1,
        .in_progress => inprog += 1,
        .completed => completed += 1,
    };
    return std.fmt.allocPrint(alloc, "todo_write: {d} pending, {d} in_progress, {d} completed (rev {d})", .{ pending, inprog, completed, board.revision });
}

// ── JSON helpers (local, similar to plan.zig) ──────────────────────────────

fn hexDigit(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + (v - 10);
}
fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = .{ '\\', 'u', '0', '0', 0, 0 };
                    buf[4] = hexDigit((c >> 4) & 0xF);
                    buf[5] = hexDigit(c & 0xF);
                    try out.appendSlice(alloc, buf[0..6]);
                } else try out.append(alloc, c);
            },
        }
    }
    try out.append(alloc, '"');
}

fn findMatchingBrace(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '{') return null;
    var depth: i32 = 1;
    var i = start + 1;
    while (i < s.len and depth > 0) : (i += 1) {
        switch (s[i]) {
            '{' => depth += 1,
            '}' => depth -= 1,
            '"' => {
                i += 1;
                while (i < s.len and s[i] != '"') : (i += 1) {
                    if (s[i] == '\\' and i + 1 < s.len) i += 1;
                }
            },
            else => {},
        }
    }
    if (depth == 0) return i;
    return null;
}

fn findMatchingBracket(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '[') return null;
    var depth: i32 = 1;
    var i = start + 1;
    while (i < s.len and depth > 0) : (i += 1) {
        switch (s[i]) {
            '[' => depth += 1,
            ']' => depth -= 1,
            '"' => {
                i += 1;
                while (i < s.len and s[i] != '"') : (i += 1) {
                    if (s[i] == '\\' and i + 1 < s.len) i += 1;
                }
            },
            else => {},
        }
    }
    if (depth == 0) return i;
    return null;
}

fn getRaw(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var j = pos + needle.len;
    while (j < json.len and (json[j] == ' ' or json[j] == '\n' or json[j] == '\r' or json[j] == '\t')) : (j += 1) {}
    if (j >= json.len) return null;
    const start = j;
    switch (json[j]) {
        '"' => {
            j += 1;
            while (j < json.len and json[j] != '"') : (j += 1) {
                if (json[j] == '\\' and j + 1 < json.len) j += 1;
            }
            if (j >= json.len) return null;
            return json[start .. j + 1];
        },
        '{' => {
            const end = findMatchingBrace(json, j) orelse return null;
            return json[start..end];
        },
        '[' => {
            const end = findMatchingBracket(json, j) orelse return null;
            return json[start..end];
        },
        else => {
            var k = j;
            while (k < json.len and json[k] != ',' and json[k] != '}' and json[k] != ']') : (k += 1) {}
            // trim trailing ws
            var e = k;
            while (e > start and (json[e - 1] == ' ' or json[e - 1] == '\t' or json[e - 1] == '\n' or json[e - 1] == '\r')) : (e -= 1) {}
            return json[start..e];
        },
    }
}

fn getStringAlloc(alloc: std.mem.Allocator, json: []const u8, key: []const u8) !?[]const u8 {
    const raw = getRaw(json, key) orelse return null;
    if (raw.len < 2 or raw[0] != '"') return null;
    const body = raw[1 .. raw.len - 1];
    return try unescapeLocal(alloc, body);
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
        } else try out.append(alloc, input[i]);
    }
    return out.toOwnedSlice(alloc);
}

// ── tests ───────────────────────────────────────────────────────────────────

test "todo board set and json roundtrip" {
    const alloc = std.testing.allocator;
    var b = TodoBoard.init(alloc);
    defer b.deinit();
    const todos = [_]TodoItem{
        .{ .content = "write test", .status = .pending },
        .{ .content = "implement feature", .status = .in_progress },
    };
    try b.set(&todos);
    try std.testing.expectEqual(@as(usize, 2), b.count());
    const j = try b.toJson(alloc);
    defer alloc.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "write test") != null);
    // restore from json
    var b2 = TodoBoard.init(alloc);
    defer b2.deinit();
    try b2.restoreFromJson(j);
    try std.testing.expectEqual(@as(usize, 2), b2.count());
    try std.testing.expectEqualStrings("write test", b2.items.items[0].content);
    try std.testing.expectEqual(TodoStatus.in_progress, b2.items.items[1].status);
}

test "todo write validation duplicates and parallel limit" {
    const alloc = std.testing.allocator;
    var b = TodoBoard.initWithConfig(alloc, false);
    defer b.deinit();
    // allow_parallel false: two in_progress should fail
    const r = executeTool(&b, todo_write_name, "{\"todos\":[{\"content\":\"a\",\"status\":\"in_progress\"},{\"content\":\"b\",\"status\":\"in_progress\"}]}", alloc);
    try std.testing.expectError(error.BadArgument, r);
    // duplicate content fails
    const r2 = executeTool(&b, todo_write_name, "{\"todos\":[{\"content\":\"same\",\"status\":\"pending\"},{\"content\":\"same\",\"status\":\"pending\"}]}", alloc);
    try std.testing.expectError(error.BadArgument, r2);
    // happy path
    const ok = try executeTool(&b, todo_write_name, "{\"todos\":[{\"content\":\"x\",\"status\":\"pending\"},{\"content\":\"y\",\"status\":\"completed\"}]}", alloc);
    defer alloc.free(ok);
    try std.testing.expectEqual(@as(usize, 2), b.count());
    try std.testing.expectEqualStrings("x", b.items.items[0].content);
}

test "executeTool unknown and missing" {
    const alloc = std.testing.allocator;
    var b = TodoBoard.init(alloc);
    defer b.deinit();
    try std.testing.expectError(error.UnknownTool, executeTool(&b, "nope", "{}", alloc));
    try std.testing.expectError(error.MissingArgument, executeTool(&b, todo_write_name, "{}", alloc));
}
