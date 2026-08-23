//! Working memory (dev.md §XIV): bounded in-RAM scratchpad for the current
//! task, plan state, tool results and temporary facts.
//!
//! Integration contract:
//!   - AgentLoop owns one WorkingMemory; wiring pass updates it after tool
//!     results / final answers.
//!   - snapshotPrompt() output is appended to context assembly ("## Working
//!     memory" section) so the model sees its own scratchpad.
//!
//! Self-contained; standalone test via `zig test src/memory/working.zig`.

const std = @import("std");

pub const max_keys = 64;
pub const max_key_len = 128;
pub const max_value_len = 16 * 1024;

pub const WorkingMemory = struct {
    alloc: std.mem.Allocator,
    keys: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) WorkingMemory {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *WorkingMemory) void {
        for (self.keys.items) |k| self.alloc.free(k);
        for (self.values.items) |v| self.alloc.free(v);
        self.keys.deinit(self.alloc);
        self.values.deinit(self.alloc);
    }

    /// Upsert key→value. Insertion order is preserved; beyond `max_keys` the
    /// oldest entry is evicted. Oversized inputs are rejected.
    pub fn set(self: *WorkingMemory, key: []const u8, value: []const u8) !void {
        if (key.len == 0 or key.len > max_key_len) return error.InvalidKey;
        if (value.len > max_value_len) return error.ValueTooLarge;

        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                const copy = try self.alloc.dupe(u8, value);
                self.alloc.free(self.values.items[i]);
                self.values.items[i] = copy;
                return;
            }
        }

        if (self.keys.items.len >= max_keys) {
            // Evict oldest (index 0).
            const old_k = self.keys.orderedRemove(0);
            const old_v = self.values.orderedRemove(0);
            self.alloc.free(old_k);
            self.alloc.free(old_v);
        }
        try self.keys.append(self.alloc, try self.alloc.dupe(u8, key));
        try self.values.append(self.alloc, try self.alloc.dupe(u8, value));
    }

    pub fn get(self: *const WorkingMemory, key: []const u8) ?[]const u8 {
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return self.values.items[i];
        }
        return null;
    }

    pub fn count(self: *const WorkingMemory) usize {
        return self.keys.items.len;
    }

    /// Context-injection rendering; "" when empty so callers skip it.
    pub fn snapshotPrompt(self: *const WorkingMemory, alloc: std.mem.Allocator) ![]const u8 {
        if (self.keys.items.len == 0) return try alloc.dupe(u8, "");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "## Working memory\n");
        for (self.keys.items, self.values.items) |k, v| {
            try out.appendSlice(alloc, k);
            try out.appendSlice(alloc, ": ");
            try out.appendSlice(alloc, v);
            try out.append(alloc, '\n');
        }
        return out.toOwnedSlice(alloc);
    }
};

test "set get replace" {
    const alloc = std.testing.allocator;
    var m = WorkingMemory.init(alloc);
    defer m.deinit();
    try m.set("task", "fix tests");
    try std.testing.expectEqualStrings("fix tests", m.get("task").?);
    try m.set("task", "fix tests faster");
    try std.testing.expectEqualStrings("fix tests faster", m.get("task").?);
    try std.testing.expect(m.get("missing") == null);
    try std.testing.expectEqual(@as(usize, 1), m.count());
}

test "eviction keeps insertion-bounded newest" {
    const alloc = std.testing.allocator;
    var m = WorkingMemory.init(alloc);
    defer m.deinit();
    var buf: [16]u8 = undefined;
    for (0..max_keys + 5) |i| {
        const k = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable;
        try m.set(k, "v");
    }
    try std.testing.expectEqual(max_keys, m.count());
    try std.testing.expect(m.get("k0") == null); // evicted
    try std.testing.expect(m.get("k4") == null); // evicted
    try std.testing.expect(m.get("k68") != null); // newest survives
}

test "snapshotPrompt format and empty" {
    const alloc = std.testing.allocator;
    var m = WorkingMemory.init(alloc);
    defer m.deinit();
    const e = try m.snapshotPrompt(alloc);
    defer alloc.free(e);
    try std.testing.expectEqualStrings("", e);

    try m.set("goal", "win");
    const s = try m.snapshotPrompt(alloc);
    defer alloc.free(s);
    try std.testing.expect(std.mem.startsWith(u8, s, "## Working memory\ngoal: win\n"));
}
