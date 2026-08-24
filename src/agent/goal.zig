//! Goal tracking (dev.md §XVII): a single active goal with a lifecycle
//! status, owned by the agent loop and injected into context assembly.
//!
//! Integration contract:
//!   - AgentLoop owns a GoalBoard; main.zig may seed it from CLI flags later.
//!   - renderPrompt-style injection is handled by plan.zig's PlanBoard, which
//!     references the goal id.
//!   - Durable: each mutation bumps `revision` and logs a `GoalSnapshot`
//!     into `history` for session persistence.
//!
//! Self-contained and allocator-explicit; testable standalone via
//! `zig test src/agent/goal.zig`.

const std = @import("std");

pub const Status = enum {
    active,
    achieved,
    abandoned,

    pub fn asStr(self: Status) []const u8 {
        return @tagName(self);
    }
};

/// Durable continuation phase (mirrors goals_rpc Phase / upstream GoalPhase).
pub const Phase = enum {
    active,
    paused,
    blocked,
    complete,

    pub fn asStr(self: Phase) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) ?Phase {
        if (std.mem.eql(u8, s, "active")) return .active;
        if (std.mem.eql(u8, s, "paused")) return .paused;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        if (std.mem.eql(u8, s, "complete")) return .complete;
        return null;
    }
};

pub const Goal = struct {
    id: []const u8 = "",
    revision: u64 = 1,
    text: []const u8,
    status: Status = .active,
    phase: Phase = .active,
    max_goal_rounds: u64 = 16,
    created_at: i64 = 0,
    updated_at: i64 = 0,
    blocked_code: ?[]const u8 = null,
    blocked_message: ?[]const u8 = null,
    rounds_started: u64 = 0,
};

/// One logged revision (snapshot after each mutation) for durable restore.
pub const GoalSnapshot = struct {
    id: []const u8,
    revision: u64,
    objective: []const u8,
    phase: Phase,
    max_goal_rounds: u64,
    created_at: i64,
    updated_at: i64,
    blocked_code: ?[]const u8 = null,
    blocked_message: ?[]const u8 = null,
    rounds_started: u64 = 0,
};

pub const GoalBoard = struct {
    alloc: std.mem.Allocator,
    goal: ?Goal = null,
    history: std.ArrayList(GoalSnapshot) = .empty,
    next_id: u64 = 1,

    pub fn init(alloc: std.mem.Allocator) GoalBoard {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *GoalBoard) void {
        if (self.goal) |g| {
            self.alloc.free(g.text);
            self.alloc.free(g.id);
            if (g.blocked_code) |c| self.alloc.free(c);
            if (g.blocked_message) |m| self.alloc.free(m);
        }
        for (self.history.items) |h| {
            self.alloc.free(h.id);
            self.alloc.free(h.objective);
            if (h.blocked_code) |c| self.alloc.free(c);
            if (h.blocked_message) |m| self.alloc.free(m);
        }
        self.history.deinit(self.alloc);
    }

    fn nowMs() i64 {
        const clib = @import("../clib.zig");
        return clib.nowTimestamp() * std.time.ms_per_s;
    }

    fn mintId(self: *GoalBoard) ![]const u8 {
        const id = try std.fmt.allocPrint(self.alloc, "goal-{d}", .{self.next_id});
        self.next_id += 1;
        return id;
    }

    fn snapshotFromGoal(self: *GoalBoard, g: *const Goal) !GoalSnapshot {
        return .{
            .id = try self.alloc.dupe(u8, g.id),
            .revision = g.revision,
            .objective = try self.alloc.dupe(u8, g.text),
            .phase = g.phase,
            .max_goal_rounds = g.max_goal_rounds,
            .created_at = g.created_at,
            .updated_at = g.updated_at,
            .blocked_code = if (g.blocked_code) |c| try self.alloc.dupe(u8, c) else null,
            .blocked_message = if (g.blocked_message) |m| try self.alloc.dupe(u8, m) else null,
            .rounds_started = g.rounds_started,
        };
    }

    fn pushHistory(self: *GoalBoard) !void {
        if (self.goal) |*g| {
            const snap = try self.snapshotFromGoal(g);
            try self.history.append(self.alloc, snap);
        }
    }

    /// Replace the current goal (freeing the previous text). Durable: mints
    /// id/revision-1 when no goal exists, otherwise edits objective with a
    /// revision bump (preserving phase). Each mutation is logged.
    pub fn set(self: *GoalBoard, text: []const u8) !void {
        if (text.len == 0) return error.InvalidArgument;
        const t = nowMs();
        if (self.goal) |*g| {
            const copy = try self.alloc.dupe(u8, text);
            errdefer self.alloc.free(copy);
            self.alloc.free(g.text);
            g.text = copy;
            g.status = .active;
            // keep phase as-is (edit does not change phase)
            g.revision += 1;
            g.updated_at = t;
            try self.pushHistory();
            return;
        }
        const id = try self.mintId();
        errdefer self.alloc.free(id);
        const copy = try self.alloc.dupe(u8, text);
        self.goal = .{
            .id = id,
            .revision = 1,
            .text = copy,
            .status = .active,
            .phase = .active,
            .created_at = t,
            .updated_at = t,
        };
        try self.pushHistory();
    }

    pub fn current(self: *const GoalBoard) ?*const Goal {
        if (self.goal) |*g| return g;
        return null;
    }

    /// Transition the current goal's status (legacy surface). Also bumps
    /// revision and logs. Returns false when no goal.
    pub fn updateStatus(self: *GoalBoard, status: Status) bool {
        if (self.goal) |*g| {
            g.status = status;
            g.phase = switch (status) {
                .active => .active,
                .achieved => .complete,
                .abandoned => .blocked,
            };
            if (status == .abandoned and g.blocked_code == null) {
                g.blocked_code = self.alloc.dupe(u8, "abandoned") catch null;
                g.blocked_message = self.alloc.dupe(u8, "abandoned") catch null;
            }
            if (status != .abandoned) {
                if (g.blocked_code) |c| self.alloc.free(c);
                if (g.blocked_message) |m| self.alloc.free(m);
                g.blocked_code = null;
                g.blocked_message = null;
            }
            g.revision += 1;
            g.updated_at = nowMs();
            self.pushHistory() catch {};
            return true;
        }
        return false;
    }

    /// Phase transitions (durable, revision-bumped). Return false on illegal
    /// transition or no goal.
    pub fn pause(self: *GoalBoard) bool {
        const g = self.goal orelse return false;
        if (g.phase != .active) return false;
        var gg = &self.goal.?;
        gg.phase = .paused;
        gg.status = .active;
        gg.revision += 1;
        gg.updated_at = nowMs();
        self.pushHistory() catch {};
        return true;
    }

    pub fn @"resume"(self: *GoalBoard) bool {
        const g = self.goal orelse return false;
        if (g.phase != .paused and g.phase != .blocked and g.phase != .active) return false;
        if (g.rounds_started >= g.max_goal_rounds) return false;
        var gg = &self.goal.?;
        if (gg.blocked_code) |c| self.alloc.free(c);
        if (gg.blocked_message) |m| self.alloc.free(m);
        gg.blocked_code = null;
        gg.blocked_message = null;
        gg.phase = .active;
        gg.status = .active;
        gg.revision += 1;
        gg.updated_at = nowMs();
        self.pushHistory() catch {};
        return true;
    }

    pub fn complete(self: *GoalBoard) bool {
        const g = self.goal orelse return false;
        if (g.phase == .complete) return false;
        var gg = &self.goal.?;
        // clear blocked reason
        if (gg.blocked_code) |c| self.alloc.free(c);
        if (gg.blocked_message) |m| self.alloc.free(m);
        gg.blocked_code = null;
        gg.blocked_message = null;
        gg.phase = .complete;
        gg.status = .achieved;
        gg.revision += 1;
        gg.updated_at = nowMs();
        self.pushHistory() catch {};
        return true;
    }

    pub fn block(self: *GoalBoard, code: []const u8, message: []const u8) !bool {
        const g = self.goal orelse return false;
        if (g.phase != .active) return false;
        var gg = &self.goal.?;
        if (gg.blocked_code) |c| self.alloc.free(c);
        if (gg.blocked_message) |m| self.alloc.free(m);
        gg.blocked_code = try self.alloc.dupe(u8, code);
        gg.blocked_message = try self.alloc.dupe(u8, message);
        gg.phase = .blocked;
        gg.status = .abandoned;
        gg.revision += 1;
        gg.updated_at = nowMs();
        try self.pushHistory();
        return true;
    }

    pub fn clear(self: *GoalBoard) bool {
        const g = self.goal orelse return false;
        self.pushHistory() catch {};
        self.alloc.free(g.text);
        self.alloc.free(g.id);
        if (g.blocked_code) |c| self.alloc.free(c);
        if (g.blocked_message) |m| self.alloc.free(m);
        self.goal = null;
        return true;
    }

    /// Restore board from a snapshot (used by session hydration). Clears
    /// existing goal/history and installs the snapshot.
    pub fn restoreSnapshot(self: *GoalBoard, snap: GoalSnapshot) !void {
        if (self.goal) |g| {
            self.alloc.free(g.text);
            self.alloc.free(g.id);
            if (g.blocked_code) |c| self.alloc.free(c);
            if (g.blocked_message) |m| self.alloc.free(m);
            self.goal = null;
        }
        for (self.history.items) |h| {
            self.alloc.free(h.id);
            self.alloc.free(h.objective);
            if (h.blocked_code) |c| self.alloc.free(c);
            if (h.blocked_message) |m| self.alloc.free(m);
        }
        self.history.clearRetainingCapacity();
        const id = try self.alloc.dupe(u8, snap.id);
        const text = try self.alloc.dupe(u8, snap.objective);
        var blk_code: ?[]const u8 = null;
        var blk_msg: ?[]const u8 = null;
        if (snap.blocked_code) |c| blk_code = try self.alloc.dupe(u8, c);
        if (snap.blocked_message) |m| blk_msg = try self.alloc.dupe(u8, m);
        self.goal = .{
            .id = id,
            .revision = snap.revision,
            .text = text,
            .status = switch (snap.phase) {
                .active => .active,
                .paused => .active,
                .blocked => .abandoned,
                .complete => .achieved,
            },
            .phase = snap.phase,
            .max_goal_rounds = snap.max_goal_rounds,
            .created_at = snap.created_at,
            .updated_at = snap.updated_at,
            .blocked_code = blk_code,
            .blocked_message = blk_msg,
            .rounds_started = snap.rounds_started,
        };
        const hs = GoalSnapshot{
            .id = try self.alloc.dupe(u8, snap.id),
            .revision = snap.revision,
            .objective = try self.alloc.dupe(u8, snap.objective),
            .phase = snap.phase,
            .max_goal_rounds = snap.max_goal_rounds,
            .created_at = snap.created_at,
            .updated_at = snap.updated_at,
            .blocked_code = if (snap.blocked_code) |c| try self.alloc.dupe(u8, c) else null,
            .blocked_message = if (snap.blocked_message) |m| try self.alloc.dupe(u8, m) else null,
            .rounds_started = snap.rounds_started,
        };
        try self.history.append(self.alloc, hs);
        if (snap.id.len > 5 and std.mem.startsWith(u8, snap.id, "goal-")) {
            const num = std.fmt.parseInt(u64, snap.id[5..], 10) catch 0;
            if (num >= self.next_id) self.next_id = num + 1;
        }
    }

    /// Export current goal as a snapshot for session persistence (caller must
    /// not free returned slices; they alias board memory). Returns null when
    /// no goal.
    pub fn currentSnapshot(self: *const GoalBoard) ?GoalSnapshot {
        const g = self.goal orelse return null;
        return GoalSnapshot{
            .id = g.id,
            .revision = g.revision,
            .objective = g.text,
            .phase = g.phase,
            .max_goal_rounds = g.max_goal_rounds,
            .created_at = g.created_at,
            .updated_at = g.updated_at,
            .blocked_code = g.blocked_code,
            .blocked_message = g.blocked_message,
            .rounds_started = g.rounds_started,
        };
    }

    /// Sync current board state into a Session's durable sidecar (dupes
    /// strings into the session allocator).
    pub fn syncToSession(self: *const GoalBoard, sess: anytype) !void {
        // Clear old session projections (free)
        if (sess.stored_goal) |old| {
            sess.alloc.free(old.id);
            sess.alloc.free(old.objective);
            sess.alloc.free(old.phase);
            if (old.blocked_code) |c| sess.alloc.free(c);
            if (old.blocked_message) |m| sess.alloc.free(m);
            sess.stored_goal = null;
        }
        for (sess.goal_history.items) |g| {
            sess.alloc.free(g.id);
            sess.alloc.free(g.objective);
            sess.alloc.free(g.phase);
            if (g.blocked_code) |c| sess.alloc.free(c);
            if (g.blocked_message) |m| sess.alloc.free(m);
        }
        sess.goal_history.clearRetainingCapacity();

        if (self.goal) |*g| {
            const stored = @import("../session/session.zig").SessionGoal{
                .id = try sess.alloc.dupe(u8, g.id),
                .revision = g.revision,
                .objective = try sess.alloc.dupe(u8, g.text),
                .phase = try sess.alloc.dupe(u8, g.phase.asStr()),
                .max_goal_rounds = g.max_goal_rounds,
                .created_at = g.created_at,
                .updated_at = g.updated_at,
                .blocked_code = if (g.blocked_code) |c| try sess.alloc.dupe(u8, c) else null,
                .blocked_message = if (g.blocked_message) |m| try sess.alloc.dupe(u8, m) else null,
                .rounds_started = g.rounds_started,
            };
            sess.stored_goal = stored;
        } else {
            sess.stored_goal = null;
        }
        // Copy full history regardless of current goal (preserves log after clear)
        for (self.history.items) |h| {
            const hg = @import("../session/session.zig").SessionGoal{
                .id = try sess.alloc.dupe(u8, h.id),
                .revision = h.revision,
                .objective = try sess.alloc.dupe(u8, h.objective),
                .phase = try sess.alloc.dupe(u8, h.phase.asStr()),
                .max_goal_rounds = h.max_goal_rounds,
                .created_at = h.created_at,
                .updated_at = h.updated_at,
                .blocked_code = if (h.blocked_code) |c| try sess.alloc.dupe(u8, c) else null,
                .blocked_message = if (h.blocked_message) |m| try sess.alloc.dupe(u8, m) else null,
                .rounds_started = h.rounds_started,
            };
            try sess.goal_history.append(sess.alloc, hg);
        }
    }

    /// Restore board state from a Session sidecar.
    pub fn restoreFromSession(self: *GoalBoard, sess: anytype) !void {
        if (self.goal) |g| {
            self.alloc.free(g.text);
            self.alloc.free(g.id);
            if (g.blocked_code) |c| self.alloc.free(c);
            if (g.blocked_message) |m| self.alloc.free(m);
            self.goal = null;
        }
        for (self.history.items) |h| {
            self.alloc.free(h.id);
            self.alloc.free(h.objective);
            if (h.blocked_code) |c| self.alloc.free(c);
            if (h.blocked_message) |m| self.alloc.free(m);
        }
        self.history.clearRetainingCapacity();
        self.next_id = 1;

        // Rebuild history from session's durable history
        for (sess.goal_history.items) |h| {
            const p = Phase.fromStr(h.phase) orelse .active;
            const hs = GoalSnapshot{
                .id = try self.alloc.dupe(u8, h.id),
                .revision = h.revision,
                .objective = try self.alloc.dupe(u8, h.objective),
                .phase = p,
                .max_goal_rounds = h.max_goal_rounds,
                .created_at = h.created_at,
                .updated_at = h.updated_at,
                .blocked_code = if (h.blocked_code) |c| try self.alloc.dupe(u8, c) else null,
                .blocked_message = if (h.blocked_message) |m| try self.alloc.dupe(u8, m) else null,
                .rounds_started = h.rounds_started,
            };
            try self.history.append(self.alloc, hs);
            if (h.id.len > 5 and std.mem.startsWith(u8, h.id, "goal-")) {
                const num = std.fmt.parseInt(u64, h.id[5..], 10) catch 0;
                if (num >= self.next_id) self.next_id = num + 1;
            }
        }
        // Install current goal from stored_goal (or last history entry)
        const stored = sess.stored_goal orelse {
            // No stored goal but history may imply last entry is current
            if (self.history.items.len > 0) {
                const last = self.history.items[self.history.items.len - 1];
                const id = try self.alloc.dupe(u8, last.id);
                const text = try self.alloc.dupe(u8, last.objective);
                var blk_code: ?[]const u8 = null;
                var blk_msg: ?[]const u8 = null;
                if (last.blocked_code) |c| blk_code = try self.alloc.dupe(u8, c);
                if (last.blocked_message) |m| blk_msg = try self.alloc.dupe(u8, m);
                self.goal = .{
                    .id = id,
                    .revision = last.revision,
                    .text = text,
                    .status = switch (last.phase) {
                        .active => .active,
                        .paused => .active,
                        .blocked => .abandoned,
                        .complete => .achieved,
                    },
                    .phase = last.phase,
                    .max_goal_rounds = last.max_goal_rounds,
                    .created_at = last.created_at,
                    .updated_at = last.updated_at,
                    .blocked_code = blk_code,
                    .blocked_message = blk_msg,
                    .rounds_started = last.rounds_started,
                };
            }
            return;
        };
        // If we already rebuilt history which includes the current snapshot,
        // we still need to set goal to stored (which should match last history,
        // but we will ensure consistency).
        // Clear any existing goal (already cleared) and set from stored.
        const phase = Phase.fromStr(stored.phase) orelse .active;
        const id = try self.alloc.dupe(u8, stored.id);
        const text = try self.alloc.dupe(u8, stored.objective);
        var blk_code: ?[]const u8 = null;
        var blk_msg: ?[]const u8 = null;
        if (stored.blocked_code) |c| blk_code = try self.alloc.dupe(u8, c);
        if (stored.blocked_message) |m| blk_msg = try self.alloc.dupe(u8, m);
        self.goal = .{
            .id = id,
            .revision = stored.revision,
            .text = text,
            .status = switch (phase) {
                .active => .active,
                .paused => .active,
                .blocked => .abandoned,
                .complete => .achieved,
            },
            .phase = phase,
            .max_goal_rounds = stored.max_goal_rounds,
            .created_at = stored.created_at,
            .updated_at = stored.updated_at,
            .blocked_code = blk_code,
            .blocked_message = blk_msg,
            .rounds_started = stored.rounds_started,
        };
        if (stored.id.len > 5 and std.mem.startsWith(u8, stored.id, "goal-")) {
            const num = std.fmt.parseInt(u64, stored.id[5..], 10) catch 0;
            if (num >= self.next_id) self.next_id = num + 1;
        }
    }
};

test "set replace and free" {
    const alloc = std.testing.allocator;
    var b = GoalBoard.init(alloc);
    defer b.deinit();
    try b.set("ship zharness mvp2");
    try std.testing.expectEqual(Status.active, b.current().?.status);
    try std.testing.expectEqual(@as(u64, 1), b.current().?.revision);
    try std.testing.expectEqualStrings("goal-1", b.current().?.id);
    try b.set("ship mvp3");
    try std.testing.expectEqualStrings("ship mvp3", b.current().?.text);
    try std.testing.expectEqual(@as(u64, 2), b.current().?.revision);
    try std.testing.expectEqual(@as(usize, 2), b.history.items.len);
}

test "status transitions and empty board" {
    const alloc = std.testing.allocator;
    var b = GoalBoard.init(alloc);
    defer b.deinit();
    try std.testing.expect(!b.updateStatus(.achieved));
    try std.testing.expect(b.current() == null);
    try b.set("g");
    try std.testing.expect(b.updateStatus(.achieved));
    try std.testing.expectEqual(Status.achieved, b.current().?.status);
    try std.testing.expectEqual(Phase.complete, b.current().?.phase);
}

test "phase transitions and block" {
    const alloc = std.testing.allocator;
    var b = GoalBoard.init(alloc);
    defer b.deinit();
    try b.set("task");
    try std.testing.expect(b.pause());
    try std.testing.expectEqual(Phase.paused, b.current().?.phase);
    try std.testing.expect(b.@"resume"());
    try std.testing.expectEqual(Phase.active, b.current().?.phase);
    _ = try b.block("needs_input", "waiting");
    try std.testing.expectEqual(Phase.blocked, b.current().?.phase);
    try std.testing.expect(b.@"resume"());
    try std.testing.expectEqual(Phase.active, b.current().?.phase);
    try std.testing.expect(b.complete());
    try std.testing.expectEqual(Phase.complete, b.current().?.phase);
    try std.testing.expect(!b.pause());
    try std.testing.expect(b.clear());
    try std.testing.expect(b.current() == null);
}

test "restore snapshot roundtrip" {
    const alloc = std.testing.allocator;
    var b = GoalBoard.init(alloc);
    defer b.deinit();
    try b.set("original");
    _ = b.pause();
    const snap = b.currentSnapshot().?;
    var b2 = GoalBoard.init(alloc);
    defer b2.deinit();
    try b2.restoreSnapshot(snap);
    try std.testing.expectEqualStrings(snap.id, b2.current().?.id);
    try std.testing.expectEqual(snap.revision, b2.current().?.revision);
    try std.testing.expectEqual(snap.phase, b2.current().?.phase);
}
