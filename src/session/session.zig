//! Session — a simple in-memory message store with JSON file persistence
//! for the zharness MVP-1 coding agent.
//!
//! Holds the conversation transcript (the model IR `Message`s) plus a few
//! bookkeeping fields. Persistence is a minimal hand-rolled JSON file (no
//! SQLite dependency) so the module stays dependency-free.
//!
//! Durable extension (P1 backlog item 6): goal revisions / phase transitions
//! and the `todo_write` whole-list projection are persisted alongside the
//! transcript via a sidecar file `<path>.projections`. This keeps the primary
//! `*.json` transcript array compatible with the legacy session-query adapter
//! (`server/apiproxy/sessions.zig`) while still surviving restarts. `save`
//! writes the sidecar atomically; `load` restores it best-effort.

const std = @import("std");
const clib = @import("../clib.zig");
const cordis = @import("cordis");
const model_mod = @import("../model/model.zig");

/// Durable goal snapshot stored in the session sidecar (mirrors
/// `agent/goal.zig` GoalSnapshot but owns strings via `Session.alloc`).
pub const SessionGoal = struct {
    id: []const u8,
    revision: u64,
    objective: []const u8,
    phase: []const u8,
    max_goal_rounds: u64,
    created_at: i64,
    updated_at: i64,
    blocked_code: ?[]const u8 = null,
    blocked_message: ?[]const u8 = null,
    rounds_started: u64 = 0,
};

/// Durable todo item stored in the session sidecar.
pub const SessionTodo = struct {
    content: []const u8,
    status: []const u8,
};

pub const Session = struct {
    id: []const u8,
    alloc: std.mem.Allocator,
    messages: std.ArrayList(model_mod.Message),
    created_at: i64,
    metadata: std.StringHashMap([]const u8),

    // ── durable projections (sidecar) ────────────────────────────────────
    stored_goal: ?SessionGoal = null,
    goal_history: std.ArrayList(SessionGoal) = .empty,
    stored_todos: std.ArrayList(SessionTodo) = .empty,
    todo_revision: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, id: []const u8) !Session {
        const now = clib.nowTimestamp();
        return Session{
            .id = try alloc.dupe(u8, id),
            .alloc = alloc,
            .messages = try std.ArrayList(model_mod.Message).initCapacity(alloc, 0),
            .created_at = now,
            .metadata = std.StringHashMap([]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *Session) void {
        self.freeMessages();
        self.messages.deinit(self.alloc);
        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
        self.alloc.free(self.id);
        self.freeProjections();
    }

    fn freeMessages(self: *Session) void {
        for (self.messages.items) |m| {
            self.alloc.free(m.content);
            if (m.tool_call_id) |v| self.alloc.free(v);
            if (m.tool_calls_json) |v| self.alloc.free(v);
        }
    }

    fn freeProjections(self: *Session) void {
        if (self.stored_goal) |g| {
            self.alloc.free(g.id);
            self.alloc.free(g.objective);
            self.alloc.free(g.phase);
            if (g.blocked_code) |c| self.alloc.free(c);
            if (g.blocked_message) |m| self.alloc.free(m);
        }
        for (self.goal_history.items) |g| {
            self.alloc.free(g.id);
            self.alloc.free(g.objective);
            self.alloc.free(g.phase);
            if (g.blocked_code) |c| self.alloc.free(c);
            if (g.blocked_message) |m| self.alloc.free(m);
        }
        self.goal_history.deinit(self.alloc);
        for (self.stored_todos.items) |t| {
            self.alloc.free(t.content);
            self.alloc.free(t.status);
        }
        self.stored_todos.deinit(self.alloc);
    }

    pub fn addUser(self: *Session, text: []const u8) !void {
        try self.messages.append(self.alloc, model_mod.Message{
            .role = .user,
            .content = try self.alloc.dupe(u8, text),
        });
    }

    pub fn addAssistant(self: *Session, text: []const u8, tool_calls_json: ?[]const u8) !void {
        try self.messages.append(self.alloc, model_mod.Message{
            .role = .assistant,
            .content = try self.alloc.dupe(u8, text),
            .tool_calls_json = if (tool_calls_json) |v| try self.alloc.dupe(u8, v) else null,
        });
    }

    pub fn addToolResult(self: *Session, call_id: []const u8, text: []const u8) !void {
        try self.messages.append(self.alloc, model_mod.Message{
            .role = .tool,
            .content = try self.alloc.dupe(u8, text),
            .tool_call_id = try self.alloc.dupe(u8, call_id),
        });
    }

    pub fn clear(self: *Session) void {
        self.freeMessages();
        self.messages.clearRetainingCapacity();
    }

    pub fn count(self: *const Session) usize {
        return self.messages.items.len;
    }

    pub fn lastContent(self: *const Session) []const u8 {
        var i: usize = self.messages.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.messages.items[i].content;
            if (c.len > 0) return c;
        }
        return "";
    }

    // ── goal/todo projection API (generic, no board import) ───────────────

    pub fn setStoredGoal(self: *Session, goal: SessionGoal) !void {
        // free old
        if (self.stored_goal) |old| {
            self.alloc.free(old.id);
            self.alloc.free(old.objective);
            self.alloc.free(old.phase);
            if (old.blocked_code) |c| self.alloc.free(c);
            if (old.blocked_message) |m| self.alloc.free(m);
        }
        const dup = SessionGoal{
            .id = try self.alloc.dupe(u8, goal.id),
            .revision = goal.revision,
            .objective = try self.alloc.dupe(u8, goal.objective),
            .phase = try self.alloc.dupe(u8, goal.phase),
            .max_goal_rounds = goal.max_goal_rounds,
            .created_at = goal.created_at,
            .updated_at = goal.updated_at,
            .blocked_code = if (goal.blocked_code) |c| try self.alloc.dupe(u8, c) else null,
            .blocked_message = if (goal.blocked_message) |m| try self.alloc.dupe(u8, m) else null,
            .rounds_started = goal.rounds_started,
        };
        self.stored_goal = dup;
        // append history entry (dup again)
        const hist = SessionGoal{
            .id = try self.alloc.dupe(u8, goal.id),
            .revision = goal.revision,
            .objective = try self.alloc.dupe(u8, goal.objective),
            .phase = try self.alloc.dupe(u8, goal.phase),
            .max_goal_rounds = goal.max_goal_rounds,
            .created_at = goal.created_at,
            .updated_at = goal.updated_at,
            .blocked_code = if (goal.blocked_code) |c| try self.alloc.dupe(u8, c) else null,
            .blocked_message = if (goal.blocked_message) |m| try self.alloc.dupe(u8, m) else null,
            .rounds_started = goal.rounds_started,
        };
        try self.goal_history.append(self.alloc, hist);
    }

    pub fn putStoredGoal(self: *Session, stored: SessionGoal) !void {
        try self.setStoredGoal(stored);
    }

    pub fn clearStoredGoal(self: *Session) void {
        if (self.stored_goal) |g| {
            self.alloc.free(g.id);
            self.alloc.free(g.objective);
            self.alloc.free(g.phase);
            if (g.blocked_code) |c| self.alloc.free(c);
            if (g.blocked_message) |m| self.alloc.free(m);
            self.stored_goal = null;
        }
    }

    pub fn setStoredTodos(self: *Session, todos: []const SessionTodo) !void {
        for (self.stored_todos.items) |t| {
            self.alloc.free(t.content);
            self.alloc.free(t.status);
        }
        self.stored_todos.clearRetainingCapacity();
        for (todos) |t| {
            try self.stored_todos.append(self.alloc, .{
                .content = try self.alloc.dupe(u8, t.content),
                .status = try self.alloc.dupe(u8, t.status),
            });
        }
        self.todo_revision += 1;
    }

    /// Direct replace without bumping revision (used during load/restore).
    pub fn restoreStoredTodos(self: *Session, todos: []const SessionTodo, rev: u64) !void {
        for (self.stored_todos.items) |t| {
            self.alloc.free(t.content);
            self.alloc.free(t.status);
        }
        self.stored_todos.clearRetainingCapacity();
        for (todos) |t| {
            try self.stored_todos.append(self.alloc, .{
                .content = try self.alloc.dupe(u8, t.content),
                .status = try self.alloc.dupe(u8, t.status),
            });
        }
        self.todo_revision = rev;
    }

    /// Restore goal state wholesale (used after sidecar load); clears history
    /// and installs the single snapshot as current + history seed.
    pub fn restoreStoredGoal(self: *Session, goal: SessionGoal) !void {
        // clear existing
        self.clearStoredGoal();
        for (self.goal_history.items) |g| {
            self.alloc.free(g.id);
            self.alloc.free(g.objective);
            self.alloc.free(g.phase);
            if (g.blocked_code) |c| self.alloc.free(c);
            if (g.blocked_message) |m| self.alloc.free(m);
        }
        self.goal_history.clearRetainingCapacity();
        const dup = SessionGoal{
            .id = try self.alloc.dupe(u8, goal.id),
            .revision = goal.revision,
            .objective = try self.alloc.dupe(u8, goal.objective),
            .phase = try self.alloc.dupe(u8, goal.phase),
            .max_goal_rounds = goal.max_goal_rounds,
            .created_at = goal.created_at,
            .updated_at = goal.updated_at,
            .blocked_code = if (goal.blocked_code) |c| try self.alloc.dupe(u8, c) else null,
            .blocked_message = if (goal.blocked_message) |m| try self.alloc.dupe(u8, m) else null,
            .rounds_started = goal.rounds_started,
        };
        self.stored_goal = dup;
        const hist = SessionGoal{
            .id = try self.alloc.dupe(u8, goal.id),
            .revision = goal.revision,
            .objective = try self.alloc.dupe(u8, goal.objective),
            .phase = try self.alloc.dupe(u8, goal.phase),
            .max_goal_rounds = goal.max_goal_rounds,
            .created_at = goal.created_at,
            .updated_at = goal.updated_at,
            .blocked_code = if (goal.blocked_code) |c| try self.alloc.dupe(u8, c) else null,
            .blocked_message = if (goal.blocked_message) |m| try self.alloc.dupe(u8, m) else null,
            .rounds_started = goal.rounds_started,
        };
        try self.goal_history.append(self.alloc, hist);
    }

    // ---- Persistence ----------------------------------------------------

    fn projectionsPath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}.projections", .{path});
    }

    pub fn save(self: *const Session, io: std.Io, path: []const u8) !void {
        var buf = try std.ArrayList(u8).initCapacity(self.alloc, 0);
        errdefer buf.deinit(self.alloc);

        try buf.appendSlice(self.alloc, "[");
        for (self.messages.items, 0..) |m, idx| {
            if (idx > 0) try buf.appendSlice(self.alloc, ",");
            try buf.appendSlice(self.alloc, "{\"role\":\"");
            try buf.appendSlice(self.alloc, m.role.asStr());
            try buf.appendSlice(self.alloc, "\",\"content\":\"");
            try escapeInto(self.alloc, m.content, &buf);
            try buf.appendSlice(self.alloc, "\",\"tool_call_id\":");
            if (m.tool_call_id) |v| {
                try buf.appendSlice(self.alloc, "\"");
                try escapeInto(self.alloc, v, &buf);
                try buf.appendSlice(self.alloc, "\"");
            } else {
                try buf.appendSlice(self.alloc, "null");
            }
            try buf.appendSlice(self.alloc, ",\"tool_calls_json\":");
            if (m.tool_calls_json) |v| {
                try buf.appendSlice(self.alloc, "\"");
                try escapeInto(self.alloc, v, &buf);
                try buf.appendSlice(self.alloc, "\"");
            } else {
                try buf.appendSlice(self.alloc, "null");
            }
            try buf.appendSlice(self.alloc, "}");
        }
        try buf.appendSlice(self.alloc, "]");

        const out = try buf.toOwnedSlice(self.alloc);
        defer self.alloc.free(out);

        const tmp_path = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{path});
        defer self.alloc.free(tmp_path);
        const tmp_z = try self.alloc.dupeSentinel(u8, tmp_path, 0);
        defer self.alloc.free(tmp_z);
        std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = tmp_path, .data = out }) catch |e| {
            clib.unlinkPath(tmp_z);
            return e;
        };
        if (!clib.renamePath(tmp_path, path)) {
            clib.unlinkPath(tmp_z);
            return error.WriteFailed;
        }
        // Sidecar: durable goal/todo projections
        try self.saveProjections(io, path);
    }

    fn saveProjections(self: *const Session, io: std.Io, path: []const u8) !void {
        // Only write sidecar when there is durable state; otherwise remove any stale file.
        if (self.stored_goal == null and self.goal_history.items.len == 0 and self.stored_todos.items.len == 0 and self.todo_revision == 0) {
            const pp = try projectionsPath(self.alloc, path);
            defer self.alloc.free(pp);
            const z = self.alloc.dupeSentinel(u8, pp, 0) catch return;
            defer self.alloc.free(z);
            clib.unlinkPath(z);
            return;
        }
        var buf = try std.ArrayList(u8).initCapacity(self.alloc, 256);
        errdefer buf.deinit(self.alloc);
        try buf.appendSlice(self.alloc, "{\"goal\":");
        if (self.stored_goal) |g| {
            try buf.appendSlice(self.alloc, "{\"id\":");
            try appendJsonString(self.alloc, &buf, g.id);
            try buf.appendSlice(self.alloc, ",\"revision\":");
            try appendInt(self.alloc, &buf, @intCast(g.revision));
            try buf.appendSlice(self.alloc, ",\"objective\":");
            try appendJsonString(self.alloc, &buf, g.objective);
            try buf.appendSlice(self.alloc, ",\"phase\":");
            try appendJsonString(self.alloc, &buf, g.phase);
            try buf.appendSlice(self.alloc, ",\"maxGoalRounds\":");
            try appendInt(self.alloc, &buf, @intCast(g.max_goal_rounds));
            try buf.appendSlice(self.alloc, ",\"createdAt\":");
            try appendInt(self.alloc, &buf, g.created_at);
            try buf.appendSlice(self.alloc, ",\"updatedAt\":");
            try appendInt(self.alloc, &buf, g.updated_at);
            try buf.appendSlice(self.alloc, ",\"roundsStarted\":");
            try appendInt(self.alloc, &buf, @intCast(g.rounds_started));
            if (g.blocked_code) |c| {
                try buf.appendSlice(self.alloc, ",\"blockedCode\":");
                try appendJsonString(self.alloc, &buf, c);
            }
            if (g.blocked_message) |m| {
                try buf.appendSlice(self.alloc, ",\"blockedMessage\":");
                try appendJsonString(self.alloc, &buf, m);
            }
            try buf.appendSlice(self.alloc, "}");
        } else {
            try buf.appendSlice(self.alloc, "null");
        }
        try buf.appendSlice(self.alloc, ",\"goalHistory\":[");
        for (self.goal_history.items, 0..) |g, idx| {
            if (idx > 0) try buf.appendSlice(self.alloc, ",");
            try buf.appendSlice(self.alloc, "{\"id\":");
            try appendJsonString(self.alloc, &buf, g.id);
            try buf.appendSlice(self.alloc, ",\"revision\":");
            try appendInt(self.alloc, &buf, @intCast(g.revision));
            try buf.appendSlice(self.alloc, ",\"objective\":");
            try appendJsonString(self.alloc, &buf, g.objective);
            try buf.appendSlice(self.alloc, ",\"phase\":");
            try appendJsonString(self.alloc, &buf, g.phase);
            try buf.appendSlice(self.alloc, ",\"maxGoalRounds\":");
            try appendInt(self.alloc, &buf, @intCast(g.max_goal_rounds));
            try buf.appendSlice(self.alloc, ",\"createdAt\":");
            try appendInt(self.alloc, &buf, g.created_at);
            try buf.appendSlice(self.alloc, ",\"updatedAt\":");
            try appendInt(self.alloc, &buf, g.updated_at);
            try buf.appendSlice(self.alloc, ",\"roundsStarted\":");
            try appendInt(self.alloc, &buf, @intCast(g.rounds_started));
            if (g.blocked_code) |c| {
                try buf.appendSlice(self.alloc, ",\"blockedCode\":");
                try appendJsonString(self.alloc, &buf, c);
            }
            if (g.blocked_message) |m| {
                try buf.appendSlice(self.alloc, ",\"blockedMessage\":");
                try appendJsonString(self.alloc, &buf, m);
            }
            try buf.appendSlice(self.alloc, "}");
        }
        try buf.appendSlice(self.alloc, "],\"todos\":[");
        for (self.stored_todos.items, 0..) |t, idx| {
            if (idx > 0) try buf.appendSlice(self.alloc, ",");
            try buf.appendSlice(self.alloc, "{\"content\":");
            try appendJsonString(self.alloc, &buf, t.content);
            try buf.appendSlice(self.alloc, ",\"status\":");
            try appendJsonString(self.alloc, &buf, t.status);
            try buf.appendSlice(self.alloc, "}");
        }
        try buf.appendSlice(self.alloc, "],\"todoRev\":");
        try appendInt(self.alloc, &buf, @intCast(self.todo_revision));
        try buf.appendSlice(self.alloc, "}");

        const out = try buf.toOwnedSlice(self.alloc);
        defer self.alloc.free(out);
        const pp = try projectionsPath(self.alloc, path);
        defer self.alloc.free(pp);
        const tmp = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{pp});
        defer self.alloc.free(tmp);
        const tmp_z = try self.alloc.dupeSentinel(u8, tmp, 0);
        defer self.alloc.free(tmp_z);
        std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = tmp, .data = out }) catch |e| {
            clib.unlinkPath(tmp_z);
            return e;
        };
        if (!clib.renamePath(tmp, pp)) {
            clib.unlinkPath(tmp_z);
            return error.WriteFailed;
        }
    }

    pub fn load(self: *Session, io: std.Io, path: []const u8) !void {
        const raw = std.Io.Dir.readFileAlloc(.cwd(), io, path, self.alloc, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return, // empty session, OK
            else => return e,
        };
        defer self.alloc.free(raw);

        var it = JsonArrayIter.init(raw);
        while (it.next()) |obj| {
            const role = parseRole(obj.get("role") orelse "") orelse .user;
            const content: []const u8 = if (obj.get("content")) |v|
                try unescapeJson(self.alloc, v)
            else
                try self.alloc.dupe(u8, "");
            errdefer self.alloc.free(content);
            const tool_call_id: ?[]const u8 = if (obj.get("tool_call_id")) |v|
                try unescapeJson(self.alloc, v)
            else
                null;
            errdefer if (tool_call_id) |t| self.alloc.free(t);
            const tool_calls_json: ?[]const u8 = if (obj.get("tool_calls_json")) |v|
                try unescapeJson(self.alloc, v)
            else
                null;
            errdefer if (tool_calls_json) |t| self.alloc.free(t);
            try self.messages.append(self.alloc, model_mod.Message{
                .role = role,
                .content = content,
                .tool_call_id = tool_call_id,
                .tool_calls_json = tool_calls_json,
            });
        }
        // Restore durable projections sidecar (best-effort)
        self.loadProjections(io, path) catch {};
    }

    fn loadProjections(self: *Session, io: std.Io, path: []const u8) !void {
        const pp = try projectionsPath(self.alloc, path);
        defer self.alloc.free(pp);
        const raw = std.Io.Dir.readFileAlloc(.cwd(), io, pp, self.alloc, .limited(1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer self.alloc.free(raw);
        // Clear existing projections before repopulating
        self.clearStoredGoal();
        for (self.goal_history.items) |g| {
            self.alloc.free(g.id);
            self.alloc.free(g.objective);
            self.alloc.free(g.phase);
            if (g.blocked_code) |c| self.alloc.free(c);
            if (g.blocked_message) |m| self.alloc.free(m);
        }
        self.goal_history.clearRetainingCapacity();
        for (self.stored_todos.items) |t| {
            self.alloc.free(t.content);
            self.alloc.free(t.status);
        }
        self.stored_todos.clearRetainingCapacity();

        // goal
        const goal_raw = getRawValue(raw, "goal");
        if (goal_raw) |gr| {
            const trimmed = std.mem.trim(u8, gr, " \t\r\n");
            if (!std.mem.eql(u8, trimmed, "null")) {
                const g = try parseGoalAlloc(self.alloc, trimmed);
                self.stored_goal = g;
            }
        }
        // goalHistory
        const hist_raw = getRawValue(raw, "goalHistory");
        if (hist_raw) |hr| {
            var arr = std.mem.trim(u8, hr, " \t\r\n");
            if (arr.len >= 2 and arr[0] == '[') {
                var idx: usize = 1;
                while (idx < arr.len) {
                    while (idx < arr.len and (arr[idx] == ' ' or arr[idx] == '\t' or arr[idx] == '\r' or arr[idx] == '\n' or arr[idx] == ',')) : (idx += 1) {}
                    if (idx >= arr.len or arr[idx] == ']') break;
                    if (arr[idx] != '{') break;
                    const end = findMatchingBrace(arr, idx) orelse break;
                    const obj = arr[idx..end];
                    idx = end;
                    const g = try parseGoalAlloc(self.alloc, obj);
                    try self.goal_history.append(self.alloc, g);
                }
            }
        }
        // todos
        const todos_raw = getRawValue(raw, "todos");
        if (todos_raw) |tr| {
            var arr = std.mem.trim(u8, tr, " \t\r\n");
            if (arr.len >= 2 and arr[0] == '[') {
                var idx: usize = 1;
                while (idx < arr.len) {
                    while (idx < arr.len and (arr[idx] == ' ' or arr[idx] == '\t' or arr[idx] == '\r' or arr[idx] == '\n' or arr[idx] == ',')) : (idx += 1) {}
                    if (idx >= arr.len or arr[idx] == ']') break;
                    if (arr[idx] != '{') break;
                    const end = findMatchingBrace(arr, idx) orelse break;
                    const obj = arr[idx..end];
                    idx = end;
                    const content = try extractStringField(self.alloc, obj, "content") orelse continue;
                    errdefer self.alloc.free(content);
                    const status = try extractStringField(self.alloc, obj, "status") orelse {
                        self.alloc.free(content);
                        continue;
                    };
                    try self.stored_todos.append(self.alloc, .{ .content = content, .status = status });
                }
            }
        }
        // todoRev
        const rev_raw = getRawValue(raw, "todoRev");
        if (rev_raw) |rv| {
            const t = std.mem.trim(u8, rv, " \t\r\n");
            self.todo_revision = std.fmt.parseInt(u64, t, 10) catch 0;
        }
    }

    fn parseGoalAlloc(alloc: std.mem.Allocator, obj: []const u8) !SessionGoal {
        const id = try extractStringField(alloc, obj, "id") orelse return error.BadGoal;
        errdefer alloc.free(id);
        const rev_raw = getRawValue(obj, "revision") orelse return error.BadGoal;
        const rev = std.fmt.parseInt(u64, std.mem.trim(u8, rev_raw, " \t"), 10) catch return error.BadGoal;
        const objective = try extractStringField(alloc, obj, "objective") orelse return error.BadGoal;
        errdefer alloc.free(objective);
        const phase = try extractStringField(alloc, obj, "phase") orelse return error.BadGoal;
        errdefer alloc.free(phase);
        const max_raw = getRawValue(obj, "maxGoalRounds") orelse "16";
        const maxr = std.fmt.parseInt(u64, std.mem.trim(u8, max_raw, " \t"), 10) catch 16;
        const ca_raw = getRawValue(obj, "createdAt") orelse "0";
        const ca = std.fmt.parseInt(i64, std.mem.trim(u8, ca_raw, " \t"), 10) catch 0;
        const ua_raw = getRawValue(obj, "updatedAt") orelse "0";
        const ua = std.fmt.parseInt(i64, std.mem.trim(u8, ua_raw, " \t"), 10) catch 0;
        const rs_raw = getRawValue(obj, "roundsStarted") orelse "0";
        const rs = std.fmt.parseInt(u64, std.mem.trim(u8, rs_raw, " \t"), 10) catch 0;
        const blocked_code = try extractStringField(alloc, obj, "blockedCode");
        errdefer if (blocked_code) |c| alloc.free(c);
        const blocked_message = try extractStringField(alloc, obj, "blockedMessage");
        errdefer if (blocked_message) |m| alloc.free(m);
        return .{
            .id = id,
            .revision = rev,
            .objective = objective,
            .phase = phase,
            .max_goal_rounds = maxr,
            .created_at = ca,
            .updated_at = ua,
            .blocked_code = blocked_code,
            .blocked_message = blocked_message,
            .rounds_started = rs,
        };
    }

    fn extractStringField(alloc: std.mem.Allocator, obj: []const u8, key: []const u8) !?[]const u8 {
        const raw = getRawValue(obj, key) orelse return null;
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (t.len < 2 or t[0] != '"') return null;
        const body = t[1 .. t.len - 1];
        return try unescapeJson(alloc, body);
    }

    fn getRawValue(json: []const u8, key: []const u8) ?[]const u8 {
        var buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
        const pos = std.mem.indexOf(u8, json, needle) orelse return null;
        var j = pos + needle.len;
        while (j < json.len and (json[j] == ' ' or json[j] == '\t' or json[j] == '\r' or json[j] == '\n')) : (j += 1) {}
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
                var e = k;
                while (e > start and (json[e - 1] == ' ' or json[e - 1] == '\t' or json[e - 1] == '\r' or json[e - 1] == '\n')) : (e -= 1) {}
                return json[start..e];
            },
        }
    }

    fn findMatchingBracket(json: []const u8, start: usize) ?usize {
        if (start >= json.len or json[start] != '[') return null;
        var depth: i32 = 1;
        var i = start + 1;
        while (i < json.len and depth > 0) : (i += 1) {
            switch (json[i]) {
                '[' => depth += 1,
                ']' => depth -= 1,
                '"' => {
                    i += 1;
                    while (i < json.len and json[i] != '"') : (i += 1) {
                        if (json[i] == '\\') i += 1;
                    }
                },
                else => {},
            }
        }
        if (depth == 0) return i;
        return null;
    }

    // ---- filesystem helpers (wave 5: session-management routes) --------

    /// Best-effort delete of a file relative to the process cwd. Returns
    /// true only when the file existed and was removed; false when it was
    /// absent OR could not be removed. Callers that must distinguish
    /// not-found from failure (e.g. DELETE /sessions/:id → 404) should stat
    /// first (std.Io.Dir.statFile) and treat false-after-stat as an error.
    pub fn deleteFile(io: std.Io, path: []const u8) bool {
        std.Io.Dir.deleteFile(.cwd(), io, path) catch return false;
        // also delete sidecar
        const pp = projectionsPath(std.heap.page_allocator, path) catch return true;
        defer std.heap.page_allocator.free(pp);
        std.Io.Dir.deleteFile(.cwd(), io, pp) catch {};
        return true;
    }

    /// Decode the simple JSON string escapes zharness emits (\" \\ \n \r \t)
    /// into a fresh allocation owned by `alloc`.
    pub fn unescapeJson(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
        var out = try std.ArrayList(u8).initCapacity(alloc, 0);
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

    // ---- small JSON helpers (no library) -------------------------------

    /// Append a JSON-escaped copy of `input` to `buf`.
    fn escapeInto(alloc: std.mem.Allocator, input: []const u8, buf: *std.ArrayList(u8)) !void {
        for (input) |c| {
            switch (c) {
                '"' => try buf.appendSlice(alloc, "\\\""),
                '\\' => try buf.appendSlice(alloc, "\\\\"),
                '\n' => try buf.appendSlice(alloc, "\\n"),
                '\r' => try buf.appendSlice(alloc, "\\r"),
                '\t' => try buf.appendSlice(alloc, "\\t"),
                else => try buf.append(alloc, c),
            }
        }
    }

    fn appendJsonString(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
        try buf.append(alloc, '"');
        try escapeInto(alloc, s, buf);
        try buf.append(alloc, '"');
    }

    fn appendInt(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), v: i64) !void {
        var tmp: [24]u8 = undefined;
        const str = try std.fmt.bufPrint(&tmp, "{d}", .{v});
        try buf.appendSlice(alloc, str);
    }

    fn parseRole(s: []const u8) ?model_mod.Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return null;
    }
};

/// Iterates top-level objects of a JSON array: `[ {...}, {...}, ... ]`.
/// Nested arrays/objects are skipped whole. Each yielded `Obj` exposes
/// `get(field)` -> raw quoted slice (excludes quotes) and `unescape(raw)`
/// to decode the simple escape sequences we emit.
const JsonArrayIter = struct {
    src: []const u8,
    i: usize,

    fn init(src: []const u8) JsonArrayIter {
        return .{ .src = src, .i = 0 };
    }

    fn next(self: *JsonArrayIter) ?Obj {
        // advance to the next '{'
        while (self.i < self.src.len) : (self.i += 1) {
            if (self.src[self.i] == '{') {
                const start = self.i;
                const end = findMatchingBrace(self.src, start) orelse return null;
                self.i = end; // resume after this object
                return Obj{ .text = self.src[start..end] };
            }
        }
        return null;
    }
};

const Obj = struct {
    text: []const u8,

    /// Returns the raw quoted value of `field` (without surrounding quotes),
    /// or null if the field is absent / not a string.
    fn get(self: Obj, field: []const u8) ?[]const u8 {
        var buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{field}) catch return null;
        const pos = std.mem.indexOf(u8, self.text, needle) orelse return null;
        var j = pos + needle.len;
        while (j < self.text.len and (self.text[j] == ' ' or self.text[j] == '\n')) : (j += 1) {}
        if (j >= self.text.len or self.text[j] != '"') return null;
        j += 1;
        const vs = j;
        while (j < self.text.len and self.text[j] != '"') : (j += 1) {
            if (self.text[j] == '\\' and j + 1 < self.text.len) j += 1;
        }
        return self.text[vs..j];
    }
};

fn findMatchingBrace(json: []const u8, start: usize) ?usize {
    if (start >= json.len or json[start] != '{') return null;
    var count: i32 = 1;
    var i = start + 1;
    while (i < json.len and count > 0) : (i += 1) {
        switch (json[i]) {
            '{' => count += 1,
            '}' => count -= 1,
            '"' => {
                i += 1;
                while (i < json.len and json[i] != '"') : (i += 1) {
                    if (json[i] == '\\') i += 1;
                }
            },
            else => {},
        }
    }
    if (count == 0) return i;
    return null;
}

test "session add and roundtrip" {
    const alloc = std.testing.allocator;
    var s1 = try Session.init(alloc, "test-session");
    defer s1.deinit();

    try s1.addUser("hello world");
    try s1.addAssistant("thinking...", "{\"id\":\"1\",\"name\":\"shell\"}");
    try s1.addToolResult("1", "done");

    try std.testing.expectEqual(@as(usize, 3), s1.count());

    const tmp = "zharness_session_test.json";

    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};
    defer std.Io.Dir.deleteFile(.cwd(), io, "zharness_session_test.json.projections") catch {};

    try s1.save(io, tmp);

    var s2 = try Session.init(alloc, "other");
    defer s2.deinit();
    try s2.load(io, tmp);

    try std.testing.expectEqual(@as(usize, 3), s2.count());
    try std.testing.expectEqualStrings("hello world", s2.messages.items[0].content);
    try std.testing.expectEqual(model_mod.Role.tool, s2.messages.items[2].role);
    try std.testing.expectEqualStrings("1", s2.messages.items[2].tool_call_id.?);
    try std.testing.expectEqualStrings("{\"id\":\"1\",\"name\":\"shell\"}", s2.messages.items[1].tool_calls_json.?);
}

// Characterization baseline: quotes and newlines in message content must
// round-trip through save/load unchanged. This pins current observable
// behavior BEFORE the unescape-allocation refactor so the refactor can be
// verified behavior-neutral.
test "session roundtrip preserves quotes and newlines" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();
    const path = "/tmp/zharness_escape_test.json";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    defer std.Io.Dir.deleteFile(.cwd(), io, "/tmp/zharness_escape_test.json.projections") catch {};

    var s1 = try Session.init(alloc, "esc");
    defer s1.deinit();
    try s1.addUser("line1\nline2 with \"quotes\" and backslash \\ here");
    try s1.addAssistant("done", null);
    try s1.save(io, path);

    var s2 = try Session.init(alloc, "esc");
    defer s2.deinit();
    try s2.load(io, path);

    try std.testing.expectEqual(@as(usize, 2), s2.count());
    try std.testing.expectEqualStrings(
        "line1\nline2 with \"quotes\" and backslash \\ here",
        s2.messages.items[0].content,
    );
}

test "session goal and todo projections survive restart" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();
    const path = "/tmp/zharness_goal_todo_test.json";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    defer std.Io.Dir.deleteFile(.cwd(), io, "/tmp/zharness_goal_todo_test.json.projections") catch {};

    var s1 = try Session.init(alloc, "g1");
    defer s1.deinit();
    try s1.addUser("hi");
    // goal revision 1
    try s1.setStoredGoal(.{
        .id = "goal-1",
        .revision = 1,
        .objective = "ship feature",
        .phase = "active",
        .max_goal_rounds = 8,
        .created_at = 1,
        .updated_at = 2,
        .rounds_started = 0,
    });
    // bump to revision 2 (paused)
    try s1.setStoredGoal(.{
        .id = "goal-1",
        .revision = 2,
        .objective = "ship feature",
        .phase = "paused",
        .max_goal_rounds = 8,
        .created_at = 1,
        .updated_at = 3,
        .rounds_started = 1,
    });
    try s1.setStoredTodos(&[_]SessionTodo{
        .{ .content = "task A", .status = "pending" },
        .{ .content = "task B", .status = "in_progress" },
    });
    try s1.save(io, path);

    var s2 = try Session.init(alloc, "g1");
    defer s2.deinit();
    try s2.load(io, path);

    try std.testing.expectEqual(@as(usize, 1), s2.count());
    try std.testing.expect(s2.stored_goal != null);
    try std.testing.expectEqualStrings("goal-1", s2.stored_goal.?.id);
    try std.testing.expectEqual(@as(u64, 2), s2.stored_goal.?.revision);
    try std.testing.expectEqualStrings("paused", s2.stored_goal.?.phase);
    try std.testing.expectEqual(@as(usize, 2), s2.goal_history.items.len);
    try std.testing.expectEqual(@as(usize, 2), s2.stored_todos.items.len);
    try std.testing.expectEqualStrings("task A", s2.stored_todos.items[0].content);
    try std.testing.expectEqualStrings("in_progress", s2.stored_todos.items[1].status);
    try std.testing.expectEqual(@as(u64, 1), s2.todo_revision);
}
