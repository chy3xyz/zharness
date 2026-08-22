const std = @import("std");
const tokenizer_mod = @import("../utils/tokenizer.zig");
const ZeepError = @import("../utils/error.zig").ZeepError;

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    name: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    pinned: bool = false,
};

pub const FoldDecision = union(enum) {
    none,
    fold_normal: struct { tail_budget: usize },
    fold_aggressive: struct { tail_budget: usize },
    exit_with_summary,
    emergency_truncate: struct { target_tokens: usize },
};

pub const FoldResult = struct {
    messages_removed: usize,
    summary_tokens: usize,
    tokens_before: usize,
    tokens_after: usize,
    savings_ratio: f64,
};

pub const SemanticPinRule = struct {
    pattern: []const u8,
    weight: u8,
};

pub const ContextManager = struct {
    messages: std.ArrayList(Message),
    pinned_indices: std.ArrayList(usize),
    fold_history: std.ArrayList(FoldRecord),
    arena: std.heap.ArenaAllocator,
    version: u32 = 1,
    ctx_max_tokens: u32 = 64000,
    last_fold_tokens: usize = 0,
    total_folds: u32 = 0,
    total_saved_tokens: u64 = 0,

    pub const FoldRecord = struct {
        timestamp: i64,
        tokens_before: usize,
        tokens_after: usize,
        savings_ratio: f64,
        decision: []const u8,
    };

    pub const SummaryCallback = *const fn (
        ctx: *anyopaque,
        messages_to_summarize: []const Message,
    ) anyerror![]const u8;

    pub fn init(alloc: std.mem.Allocator) ContextManager {
        return .{
            .messages = .empty,
            .pinned_indices = .empty,
            .fold_history = .empty,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *ContextManager) void {
        self.messages.deinit(self.arena.allocator());
        self.pinned_indices.deinit(self.arena.allocator());
        self.fold_history.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn setContextMax(self: *ContextManager, max_tokens: u32) void {
        self.ctx_max_tokens = max_tokens;
    }

    pub fn addMessage(self: *ContextManager, msg: Message) !void {
        var mutable_msg = msg;
        if (!mutable_msg.pinned) {
            self.autoPin(&mutable_msg);
        }
        try self.messages.append(self.arena.allocator(), mutable_msg);
    }

    pub fn getMessages(self: *ContextManager) []const Message {
        return self.messages.items;
    }

    pub fn getMessagesMut(self: *ContextManager) []Message {
        return self.messages.items;
    }

    fn autoPin(self: *ContextManager, msg: *Message) void {
        const content = msg.content;
        const lower = self.arena.allocator().dupe(u8, content) catch return;
        defer self.arena.allocator().free(lower);

        for (lower, 0..) |byte, i| {
            if (byte >= 'A' and byte <= 'Z') {
                lower[i] = byte + 32;
            }
        }

        const pin_triggers = [_]struct { pattern: []const u8, weight: u8 }{
            .{ .pattern = "error:", .weight = 10 },
            .{ .pattern = "exception", .weight = 10 },
            .{ .pattern = "traceback", .weight = 10 },
            .{ .pattern = "failed", .weight = 8 },
            .{ .pattern = "decided", .weight = 6 },
            .{ .pattern = "conclusion", .weight = 6 },
            .{ .pattern = "summary:", .weight = 5 },
            .{ .pattern = "final decision", .weight = 10 },
            .{ .pattern = "important:", .weight = 9 },
            .{ .pattern = "key:", .weight = 5 },
            .{ .pattern = "architecture", .weight = 4 },
            .{ .pattern = "breaking", .weight = 7 },
            .{ .pattern = "critical", .weight = 8 },
            .{ .pattern = "warning:", .weight = 6 },
            .{ .pattern = "fix:", .weight = 7 },
            .{ .pattern = "workaround", .weight = 7 },
            .{ .pattern = "rollback", .weight = 8 },
            .{ .pattern = "deprecated", .weight = 6 },
            .{ .pattern = "api change", .weight = 6 },
            .{ .pattern = "security", .weight = 8 },
        };

        var score: u32 = 0;
        for (pin_triggers) |trigger| {
            if (std.mem.indexOf(u8, lower, trigger.pattern) != null) {
                score += trigger.weight;
            }
        }

        if (score >= 10) {
            msg.pinned = true;
        }
    }

    pub fn pinMessage(self: *ContextManager, index: usize) !void {
        if (index >= self.messages.items.len) return;
        self.messages.items[index].pinned = true;
        try self.pinned_indices.append(self.arena.allocator(), index);
    }

    pub fn unpinMessage(self: *ContextManager, index: usize) void {
        if (index >= self.messages.items.len) return;
        self.messages.items[index].pinned = false;
        const pinned_list = self.pinned_indices.items;
        for (pinned_list, 0..) |pinned_idx, i| {
            if (pinned_idx == index) {
                _ = self.pinned_indices.orderedRemove(i);
                return;
            }
        }
    }

    pub fn isPinned(self: *ContextManager, index: usize) bool {
        if (index >= self.messages.items.len) return false;
        return self.messages.items[index].pinned;
    }

    pub fn totalTokens(self: *ContextManager) usize {
        var total: usize = 0;
        for (self.messages.items) |msg| {
            total += tokenizer_mod.Tokenizer.count(msg.content);
            if (msg.name) |n| {
                total += tokenizer_mod.Tokenizer.count(n);
            }
        }
        return total;
    }

    pub fn contextFillRatio(self: *ContextManager) f64 {
        const total = self.totalTokens();
        if (self.ctx_max_tokens == 0) return 0.0;
        return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.ctx_max_tokens));
    }

    pub fn contextFillPercent(self: *ContextManager) u8 {
        const ratio = self.contextFillRatio();
        return @intFromFloat(@min(ratio * 100.0, 100.0));
    }

    pub fn withinBudget(self: *ContextManager, incoming_tokens: usize) bool {
        const current = self.totalTokens();
        const projected = current + incoming_tokens;
        const emergency_threshold = @as(f64, @floatFromInt(self.ctx_max_tokens)) * 0.95;
        return @as(f64, @floatFromInt(projected)) < emergency_threshold;
    }

    pub fn foldHistory(
        self: *ContextManager,
        _model: []const u8,
        fold_decision: FoldDecision,
        summary_callback: ?SummaryCallback,
        callback_ctx: ?*anyopaque,
    ) !FoldResult {
        _ = _model;
        const tokens_before = self.totalTokens();

        switch (fold_decision) {
            .none, .exit_with_summary, .emergency_truncate => {
                return FoldResult{
                    .messages_removed = 0,
                    .summary_tokens = 0,
                    .tokens_before = tokens_before,
                    .tokens_after = tokens_before,
                    .savings_ratio = 0.0,
                };
            },
            else => {},
        }

        if (self.messages.items.len <= 2) {
            return FoldResult{
                .messages_removed = 0,
                .summary_tokens = 0,
                .tokens_before = tokens_before,
                .tokens_after = tokens_before,
                .savings_ratio = 0.0,
            };
        }

        const tail_count = tailMessagesToKeepCount(fold_decision);
        if (tail_count >= self.messages.items.len) {
            return FoldResult{
                .messages_removed = 0,
                .summary_tokens = 0,
                .tokens_before = tokens_before,
                .tokens_after = tokens_before,
                .savings_ratio = 0.0,
            };
        }

        const fold_end = self.messages.items.len - tail_count;

        var to_remove = std.ArrayList(usize).empty;
        defer to_remove.deinit(self.arena.allocator());

        var fold_token_count: usize = 0;
        for (0..fold_end) |i| {
            const msg = self.messages.items[i];
            if (msg.pinned) continue;
            fold_token_count += tokenizer_mod.Tokenizer.count(msg.content);
            if (msg.name) |n| {
                fold_token_count += tokenizer_mod.Tokenizer.count(n);
            }
            to_remove.append(self.arena.allocator(), i) catch break;
        }

        if (to_remove.items.len == 0) {
            return FoldResult{
                .messages_removed = 0,
                .summary_tokens = 0,
                .tokens_before = tokens_before,
                .tokens_after = tokens_before,
                .savings_ratio = 0.0,
            };
        }

        const savings_ratio = @as(f64, @floatFromInt(fold_token_count)) / @as(f64, @floatFromInt(tokens_before));

        if (savings_ratio < 0.30) {
            return FoldResult{
                .messages_removed = 0,
                .summary_tokens = 0,
                .tokens_before = tokens_before,
                .tokens_after = tokens_before,
                .savings_ratio = savings_ratio,
            };
        }

        const messages_to_fold = self.messages.items[0..fold_end];

        var summary_content: []const u8 = "";
        if (summary_callback) |cb| {
            if (callback_ctx) |ctx| {
                summary_content = try cb(ctx, messages_to_fold);
            }
        }

        const summary_tokens = tokenizer_mod.Tokenizer.count(summary_content);

        const fold_messages_to_remove = to_remove.items.len;
        for (0..fold_messages_to_remove) |r| {
            const idx = to_remove.items[fold_messages_to_remove - 1 - r];
            _ = self.messages.orderedRemove(idx);
        }

        if (summary_content.len > 0) {
            try self.messages.insert(self.arena.allocator(), 0, .{
                .role = "system",
                .content = summary_content,
                .pinned = true,
            });
        }

        self.pinned_indices.clearRetainingCapacity();
        for (self.messages.items, 0..) |msg, i| {
            if (msg.pinned) {
                self.pinned_indices.append(self.arena.allocator(), i) catch continue;
            }
        }

        const tokens_after = self.totalTokens();
        const tokens_saved = tokens_before -| tokens_after;
        const actual_savings_ratio = @as(f64, @floatFromInt(tokens_saved)) /
            @as(f64, @floatFromInt(tokens_before));

        self.last_fold_tokens = tokens_saved;
        self.total_folds += 1;
        self.total_saved_tokens += tokens_saved;
        self.version += 1;

        const decision_label: []const u8 = switch (fold_decision) {
            .fold_normal => "fold_normal",
            .fold_aggressive => "fold_aggressive",
            else => "unknown",
        };

        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const timestamp = ts.sec;
        try self.fold_history.append(self.arena.allocator(), FoldRecord{
            .timestamp = timestamp,
            .tokens_before = tokens_before,
            .tokens_after = tokens_after,
            .savings_ratio = actual_savings_ratio,
            .decision = decision_label,
        });

        return FoldResult{
            .messages_removed = fold_messages_to_remove,
            .summary_tokens = summary_tokens,
            .tokens_before = tokens_before,
            .tokens_after = tokens_after,
            .savings_ratio = actual_savings_ratio,
        };
    }

    fn tailMessagesToKeepCount(decision: FoldDecision) usize {
        return switch (decision) {
            .fold_normal => |d| @min(@max(d.tail_budget, 3), 4),
            .fold_aggressive => |d| @min(d.tail_budget, 2),
            else => 2,
        };
    }

    fn getPinnedIndices(self: *ContextManager) []const usize {
        return self.pinned_indices.items;
    }

    fn shiftPinnedIndicesAfter(self: *ContextManager, after_idx: usize, shift: usize) void {
        for (self.pinned_indices.items) |*idx| {
            if (idx.* > after_idx) {
                if (idx.* > after_idx + shift) {
                    idx.* -= shift;
                } else {
                    idx.* = after_idx + 1;
                }
            }
        }
    }

    pub fn clear(self: *ContextManager) void {
        self.messages.clearAndFree(self.arena.allocator());
        self.pinned_indices.clearAndFree(self.arena.allocator());
        self.fold_history.clearAndFree(self.arena.allocator());
        self.total_folds = 0;
        self.total_saved_tokens = 0;
    }

    pub fn getFoldHistory(self: *ContextManager) []const FoldRecord {
        return self.fold_history.items;
    }

    pub fn stats(self: *ContextManager) ContextStats {
        return .{
            .total_messages = self.messages.items.len,
            .pinned_count = self.pinned_indices.items.len,
            .total_tokens = self.totalTokens(),
            .context_fill_percent = self.contextFillPercent(),
            .context_fill_ratio = self.contextFillRatio(),
            .ctx_max_tokens = self.ctx_max_tokens,
            .total_folds = self.total_folds,
            .total_saved_tokens = self.total_saved_tokens,
            .last_fold_tokens = self.last_fold_tokens,
            .version = self.version,
        };
    }

    pub const ContextStats = struct {
        total_messages: usize,
        pinned_count: usize,
        total_tokens: usize,
        context_fill_percent: u8,
        context_fill_ratio: f64,
        ctx_max_tokens: u32,
        total_folds: u32,
        total_saved_tokens: u64,
        last_fold_tokens: usize,
        version: u32,
    };
};

pub fn foldDecisionFromReasonix(r: anytype) FoldDecision {
    return switch (r) {
        .none => .none,
        .fold_normal => .{ .fold_normal = .{ .tail_budget = r.fold_normal.tail_budget } },
        .fold_aggressive => .{ .fold_aggressive = .{ .tail_budget = r.fold_aggressive.tail_budget } },
        .exit_with_summary => .exit_with_summary,
        .emergency_truncate => .{ .emergency_truncate = .{ .target_tokens = r.emergency_truncate.target_tokens } },
    };
}

pub const ImmutablePrefix = struct {
    system_prompt: []const u8,
    tools: []const u8,
    few_shots: []const u8,
    fingerprint: [32]u8,
    version: u32 = 1,
    change_counter: u32 = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        system_prompt: []const u8,
        tools: []const u8,
        few_shots: []const u8,
    ) ImmutablePrefix {
        const all = std.mem.concat(alloc, u8, &[_][]const u8{
            system_prompt,
            tools,
            few_shots,
        }) catch "";
        defer {
            if (all.len > 0) alloc.free(all);
        }

        var hash: [32]u8 = undefined;
        if (all.len > 0) {
            std.crypto.hash.sha2.Sha256.hash(all, &hash, .{});
        } else {
            @memset(&hash, 0);
        }

        return .{
            .system_prompt = system_prompt,
            .tools = tools,
            .few_shots = few_shots,
            .fingerprint = hash,
            .version = 1,
            .change_counter = 0,
        };
    }

    pub fn deinit(self: *ImmutablePrefix, alloc: std.mem.Allocator) void {
        alloc.free(self.system_prompt);
        alloc.free(self.tools);
        alloc.free(self.few_shots);
    }

    pub fn verify(self: *const ImmutablePrefix, other: [32]u8) bool {
        return std.mem.eql(u8, &self.fingerprint, &other);
    }

    pub fn version_(self: *const ImmutablePrefix) u32 {
        return self.version;
    }

    pub fn changed(self: *ImmutablePrefix, alloc: std.mem.Allocator) bool {
        self.change_counter += 1;
        const all = std.mem.concat(alloc, u8, &[_][]const u8{
            self.system_prompt,
            self.tools,
            self.few_shots,
        }) catch return false;
        defer alloc.free(all);

        var new_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(all, &new_hash, .{});

        const is_different = !std.mem.eql(u8, &self.fingerprint, &new_hash);
        self.fingerprint = new_hash;
        self.version += 1;
        return is_different;
    }

    pub fn cacheKey(self: *const ImmutablePrefix) [32]u8 {
        var combined: [64]u8 = undefined;
        @memcpy(combined[0..32], &self.fingerprint);
        std.mem.writeInt(u32, combined[32..36], self.version, .little);
        var key: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(combined[0..36], &key, .{});
        return key;
    }
};

test "context manager add message" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "Hello" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Hi there!" });

    try std.testing.expectEqual(@as(usize, 2), ctx.messages.items.len);
}

test "context manager pin message" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "Hello" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Hi there!" });
    try ctx.pinMessage(0);

    try std.testing.expectEqual(@as(usize, 1), ctx.pinned_indices.items.len);
    try std.testing.expect(ctx.messages.items[0].pinned);
}

test "context manager total tokens" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "Hello world" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Hi there!" });

    const tokens = ctx.totalTokens();
    try std.testing.expect(tokens > 0);
}

test "context manager fold history" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "Hello" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Hi there!" });
    try ctx.addMessage(.{ .role = "user", .content = "How are you?" });
    try ctx.addMessage(.{ .role = "assistant", .content = "I'm good!" });
    try ctx.pinMessage(0);

    const result = try ctx.foldHistory("deepseek-chat", .{ .fold_normal = .{ .tail_budget = 2 } }, null, null);
    try std.testing.expect(ctx.messages.items.len >= 2);
    _ = result;
}

test "context manager clear" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "Hello" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Hi!" });

    ctx.clear();
    try std.testing.expectEqual(@as(usize, 0), ctx.messages.items.len);
}

test "context manager auto pin on error keyword" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "assistant", .content = "Error: connection refused" });
    try ctx.addMessage(.{ .role = "user", .content = "Hello" });

    try std.testing.expect(ctx.messages.items[0].pinned);
    try std.testing.expect(!ctx.messages.items[1].pinned);
}

test "context manager auto pin on decision keyword" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "assistant", .content = "Final decision: use method A" });
    try std.testing.expect(ctx.messages.items[0].pinned);
}

test "context manager auto pin on critical keyword" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "assistant", .content = "Critical security fix applied" });
    try std.testing.expect(ctx.messages.items[0].pinned);
}

test "context manager auto pin no match" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "Hello how are you" });
    try std.testing.expect(!ctx.messages.items[0].pinned);
}

test "context manager context fill ratio" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    ctx.setContextMax(64000);
    try ctx.addMessage(.{ .role = "user", .content = "Hello world" });

    const ratio = ctx.contextFillRatio();
    try std.testing.expect(ratio > 0.0);
    try std.testing.expect(ratio < 1.0);

    const percent = ctx.contextFillPercent();
    try std.testing.expect(percent >= 0);
    try std.testing.expect(percent <= 100);
}

test "context manager within budget" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    ctx.setContextMax(1000);
    try ctx.addMessage(.{ .role = "user", .content = "Hi" });

    try std.testing.expect(ctx.withinBudget(100));
    try std.testing.expect(!ctx.withinBudget(100000));
}

test "context manager unpin" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "Test" });
    try ctx.pinMessage(0);
    try std.testing.expect(ctx.isPinned(0));

    ctx.unpinMessage(0);
    try std.testing.expect(!ctx.isPinned(0));
    try std.testing.expectEqual(@as(usize, 0), ctx.pinned_indices.items.len);
}

test "context manager fold preserves pinned" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "First" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Second" });
    try ctx.addMessage(.{ .role = "user", .content = "Third" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Fourth" });
    try ctx.addMessage(.{ .role = "user", .content = "Fifth" });
    try ctx.pinMessage(1);

    const result = try ctx.foldHistory("deepseek-chat", .{ .fold_aggressive = .{ .tail_budget = 2 } }, null, null);

    try std.testing.expect(ctx.messages.items[0].pinned);
    for (ctx.messages.items) |msg| {
        _ = msg;
    }
    _ = result;
}

test "context manager fold minimum 30pct savings" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "a" });
    try ctx.addMessage(.{ .role = "assistant", .content = "b" });
    try ctx.addMessage(.{ .role = "user", .content = "c" });
    try ctx.addMessage(.{ .role = "assistant", .content = "d" });

    const result = try ctx.foldHistory("deepseek-chat", .{ .fold_normal = .{ .tail_budget = 2 } }, null, null);
    try std.testing.expect(result.messages_removed == 0);
}

test "context manager fold with summary callback" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "Tell me about dogs" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Dogs are great pets." });
    try ctx.addMessage(.{ .role = "user", .content = "Tell me about cats" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Cats are independent animals." });
    try ctx.addMessage(.{ .role = "user", .content = "Tell me about birds" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Birds can fly." });
    try ctx.addMessage(.{ .role = "user", .content = "Tell me about fish" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Fish live in water." });

    var dummy_ctx: u8 = 0;
    const result = try ctx.foldHistory(
        "deepseek-chat",
        .{ .fold_aggressive = .{ .tail_budget = 2 } },
        struct {
            fn f(_: *anyopaque, _: []const Message) ![]const u8 {
                return "Conversation about animals: dogs, cats, birds, fish discussed.";
            }
        }.f,
        &dummy_ctx,
    );

    try std.testing.expect(result.summary_tokens > 0);
    try std.testing.expect(result.messages_removed > 0);

    const found_summary = for (ctx.messages.items) |msg| {
        if (std.mem.indexOf(u8, msg.content, "Conversation about animals") != null) {
            break true;
        }
    } else false;
    try std.testing.expect(found_summary);
}

test "context manager fold history record" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "A longer message that has enough content to trigger folding properly and produce good results" });
    try ctx.addMessage(.{ .role = "assistant", .content = "B longer response that adds more content to the conversation history window" });
    try ctx.addMessage(.{ .role = "user", .content = "C third message adding more tokens to ensure we have enough for folding to be worthwhile" });
    try ctx.addMessage(.{ .role = "assistant", .content = "D fourth message continuing the dialogue and increasing the token count significantly" });
    try ctx.addMessage(.{ .role = "user", .content = "E fifth message that pushes us further toward the folding threshold" });
    try ctx.addMessage(.{ .role = "assistant", .content = "F sixth message completing the set and making folding viable with proper savings" });

    _ = try ctx.foldHistory("deepseek-chat", .{ .fold_aggressive = .{ .tail_budget = 2 } }, null, null);

    try std.testing.expectEqual(@as(usize, 1), ctx.fold_history.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.total_folds);
}

test "context manager stats" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "Hello world test message" });
    try ctx.pinMessage(0);
    ctx.setContextMax(64000);

    const stats = ctx.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.total_messages);
    try std.testing.expectEqual(@as(usize, 1), stats.pinned_count);
    try std.testing.expect(stats.total_tokens > 0);
    try std.testing.expectEqual(@as(u32, 64000), stats.ctx_max_tokens);
    try std.testing.expectEqual(@as(u32, 1), stats.version);
}

test "context manager budget enforcement" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    ctx.setContextMax(1000);
    try ctx.addMessage(.{ .role = "user", .content = "x" });

    try std.testing.expect(ctx.withinBudget(500));
    try std.testing.expect(!ctx.withinBudget(95000));
}

test "immutable prefix version" {
    const alloc = std.testing.allocator;
    var prefix = ImmutablePrefix.init(alloc, "system prompt", "tools", "fewshots");

    try std.testing.expectEqual(@as(u32, 1), prefix.version_());

    _ = prefix.changed(alloc);
    try std.testing.expectEqual(@as(u32, 2), prefix.version_());

    const key = prefix.cacheKey();
    try std.testing.expect(key.len == 32);
}

test "immutable prefix cache key stable" {
    const alloc = std.testing.allocator;
    var prefix = ImmutablePrefix.init(alloc, "system", "", "");

    const key1 = prefix.cacheKey();
    _ = prefix.changed(alloc);
    const key2 = prefix.cacheKey();

    try std.testing.expect(!std.mem.eql(u8, &key1, &key2));
}

test "immutable prefix verify" {
    const alloc = std.testing.allocator;
    const prefix = ImmutablePrefix.init(alloc, "system", "tools", "");

    try std.testing.expect(prefix.verify(prefix.fingerprint));
    var other: [32]u8 = undefined;
    @memset(&other, 1);
    try std.testing.expect(!prefix.verify(other));
}

test "fold result fields" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    try ctx.addMessage(.{ .role = "user", .content = "Initial message with substantial content for folding" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Response with enough details to contribute significant tokens" });
    try ctx.addMessage(.{ .role = "user", .content = "Another message that adds more context to the conversation" });
    try ctx.addMessage(.{ .role = "assistant", .content = "Final response before we trigger the fold operation" });

    const result = try ctx.foldHistory(
        "deepseek-chat",
        .{ .fold_normal = .{ .tail_budget = 2 } },
        null,
        null,
    );

    try std.testing.expect(result.tokens_before >= result.tokens_after);
    try std.testing.expect(result.savings_ratio >= 0.0);
    try std.testing.expect(result.savings_ratio <= 1.0);
}
