//! Goal tracking (dev.md §XVII): a single active goal with a lifecycle
//! status, owned by the agent loop and injected into context assembly.
//!
//! Integration contract:
//!   - AgentLoop owns a GoalBoard; main.zig may seed it from CLI flags later.
//!   - renderPrompt-style injection is handled by plan.zig's PlanBoard, which
//!     references the goal id.
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

pub const Goal = struct {
    text: []const u8,
    status: Status,
};

pub const GoalBoard = struct {
    alloc: std.mem.Allocator,
    goal: ?Goal = null,

    pub fn init(alloc: std.mem.Allocator) GoalBoard {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *GoalBoard) void {
        if (self.goal) |g| self.alloc.free(g.text);
    }

    /// Replace the current goal (freeing the previous text).
    pub fn set(self: *GoalBoard, text: []const u8) !void {
        if (self.goal) |g| self.alloc.free(g.text);
        const copy = try self.alloc.dupe(u8, text);
        self.goal = .{ .text = copy, .status = .active };
    }

    pub fn current(self: *const GoalBoard) ?*const Goal {
        if (self.goal) |*g| return g;
        return null;
    }

    /// Transition the current goal's status. False when no goal is set.
    pub fn updateStatus(self: *GoalBoard, status: Status) bool {
        if (self.goal) |*g| {
            g.status = status;
            return true;
        }
        return false;
    }
};

test "set replace and free" {
    const alloc = std.testing.allocator;
    var b = GoalBoard.init(alloc);
    defer b.deinit();
    try b.set("ship zharness mvp2");
    try std.testing.expectEqual(Status.active, b.current().?.status);
    try b.set("ship mvp3");
    try std.testing.expectEqualStrings("ship mvp3", b.current().?.text);
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
}
