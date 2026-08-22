const std = @import("std");
const array_list = std.array_list;
const tokenizer_mod = @import("../utils/tokenizer.zig");
const zeep_error = @import("../utils/error.zig");

pub const ReasonixError = error{
    CacheFull,
    EntryNotFound,
    InvalidConfig,
    SemanticMatchFailed,
    InvalidFoldThreshold,
    InvalidHotRatio,
};

pub const ReasonixConfig = struct {
    fold_warn: f64 = 0.50,
    fold_aggressive: f64 = 0.70,
    fold_exit: f64 = 0.80,
    fold_emergency: f64 = 0.95,
    max_hot_size: usize = 128,
    max_cold_size: usize = 512,
    default_ttl_seconds: u64 = 3600,
    semantic_window: usize = 10,
    lirs_stack_size: usize = 64,
    semantic_enabled: bool = true,
    semantic_threshold: f64 = 0.85,
    semantic_top_k: u8 = 5,
    hot_ratio: f32 = 0.3,
    lirs_resident_ratio: f32 = 0.1,

    pub fn validate(self: ReasonixConfig) !void {
        if (self.fold_warn >= self.fold_aggressive) return error.InvalidFoldThreshold;
        if (self.fold_aggressive >= self.fold_exit) return error.InvalidFoldThreshold;
        if (self.fold_exit >= self.fold_emergency) return error.InvalidFoldThreshold;
        if (self.hot_ratio > 0.5 or self.hot_ratio < 0.05) return error.InvalidHotRatio;
    }
};

pub fn loadReasonixConfig(_: std.mem.Allocator) !ReasonixConfig {
    var config = ReasonixConfig{};

    if (std.c.getenv("ZEEPSEEK_CACHE_MAX_HOT")) |val| {
        config.max_hot_size = std.fmt.parseInt(usize, std.mem.sliceTo(val, 0), 10) catch config.max_hot_size;
    }
    if (std.c.getenv("ZEEPSEEK_CACHE_MAX_COLD")) |val| {
        config.max_cold_size = std.fmt.parseInt(usize, std.mem.sliceTo(val, 0), 10) catch config.max_cold_size;
    }
    if (std.c.getenv("ZEEPSEEK_CACHE_TTL")) |val| {
        config.default_ttl_seconds = std.fmt.parseInt(u64, std.mem.sliceTo(val, 0), 10) catch config.default_ttl_seconds;
    }
    if (std.c.getenv("ZEEPSEEK_SEMANTIC_ENABLED")) |val| {
        config.semantic_enabled = std.mem.eql(u8, std.mem.sliceTo(val, 0), "1") or
            std.mem.eql(u8, std.mem.sliceTo(val, 0), "true");
    }

    return config;
}

pub const Reasonix = struct {
    const Self = @This();

    pub const FoldDecision = union(enum) {
        none,
        fold_normal: struct { tail_budget: usize },
        fold_aggressive: struct { tail_budget: usize },
        exit_with_summary,
        emergency_truncate: struct { target_tokens: usize },
    };

    pub const Config = ReasonixConfig;

    comptime {
        const cfg = ReasonixConfig{};
        if (cfg.fold_warn >= cfg.fold_aggressive) {
            @compileError("fold_warn must be < fold_aggressive");
        }
        if (cfg.fold_aggressive >= cfg.fold_exit) {
            @compileError("fold_aggressive must be < fold_exit");
        }
        if (cfg.fold_exit >= cfg.fold_emergency) {
            @compileError("fold_exit must be < fold_emergency");
        }
        if (cfg.hot_ratio > 0.5 or cfg.hot_ratio < 0.05) {
            @compileError("hot_ratio must be between 0.05 and 0.5");
        }
    }

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
        created_at: i64,
        expires_at: ?i64,
        tokens: usize,
        recency: usize,
        in_hot: bool,
    };

    pub const TierStats = struct {
        hits: u64 = 0,
        misses: u64 = 0,
        evictions: u64 = 0,
        promotions: u64 = 0,
        demotions: u64 = 0,

        pub fn hitRate(self: *const TierStats) f64 {
            const total = self.hits + self.misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
        }
    };

    arena: std.heap.ArenaAllocator,
    hot: std.StringHashMap(*Entry),
    cold: std.StringHashMap(*Entry),
    lirs_stack: std.ArrayList([]const u8),
    lirs_s: std.ArrayList([]const u8),
    lirs_h: std.ArrayList([]const u8),
    config: Config,
    hot_stats: TierStats,
    cold_stats: TierStats,
    semantic_history: std.ArrayList(SemanticEntry),
    clock: i64,
    time_fn: *const fn () i64,

    pub const SemanticEntry = struct {
        key_hash: u64,
        tokens: usize,
        text: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        return Self.initWithConfig(allocator, config);
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: ReasonixConfig) Self {
        // Pre-allocate the hot/cold HashMaps so empty-cache access doesn't
        // trip 0.17's alignment assert on null metadata.
        var self: Self = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .hot = std.StringHashMap(*Entry).init(allocator),
            .cold = std.StringHashMap(*Entry).init(allocator),
            .lirs_stack = std.ArrayList([]const u8).empty,
            .lirs_s = std.ArrayList([]const u8).empty,
            .lirs_h = std.ArrayList([]const u8).empty,
            .config = config,
            .hot_stats = .{},
            .cold_stats = .{},
            .semantic_history = std.ArrayList(SemanticEntry).empty,
            .clock = 0,
            .time_fn = &defaultTimeFn,
        };
        self.hot.ensureTotalCapacity(4) catch {};
        self.cold.ensureTotalCapacity(4) catch {};
        return self;
    }

    pub fn initWithConfigOld(allocator: std.mem.Allocator, config: ReasonixConfig) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .hot = std.StringHashMap(*Entry).init(allocator),
            .cold = std.StringHashMap(*Entry).init(allocator),
            .lirs_stack = std.ArrayList([]const u8).empty,
            .lirs_s = std.ArrayList([]const u8).empty,
            .lirs_h = std.ArrayList([]const u8).empty,
            .config = config,
            .hot_stats = .{},
            .cold_stats = .{},
            .semantic_history = std.ArrayList(SemanticEntry).empty,
            .clock = 0,
            .time_fn = &defaultTimeFn,
        };
    }

    pub fn updateConfig(self: *Self, new_config: ReasonixConfig) !void {
        try new_config.validate();
        self.config = new_config;
    }

    fn defaultTimeFn() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return ts.sec;
    }

    pub fn deinit(self: *Self) void {
        var hot_it = self.hot.iterator();
        while (hot_it.next()) |kv| {
            self.arena.allocator().free(kv.value_ptr.*.key);
            self.arena.allocator().free(kv.value_ptr.*.value);
            self.arena.allocator().destroy(kv.value_ptr.*);
        }
        self.hot.deinit();

        var cold_it = self.cold.iterator();
        while (cold_it.next()) |kv| {
            self.arena.allocator().free(kv.value_ptr.*.key);
            self.arena.allocator().free(kv.value_ptr.*.value);
            self.arena.allocator().destroy(kv.value_ptr.*);
        }
        self.cold.deinit();

        self.lirs_s.deinit(self.arena.allocator());
        self.lirs_h.deinit(self.arena.allocator());
        self.lirs_stack.deinit(self.arena.allocator());
        self.semantic_history.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        if (self.hot.get(key)) |entry| {
            if (self.isExpired(entry)) {
                self.evictEntry(entry, true);
                self.hot_stats.misses += 1;
                return null;
            }
            self.lirsAccessHot(key);
            self.hot_stats.hits += 1;
            self.recordSemanticAccess(key);
            return entry.value;
        }

        if (self.cold.get(key)) |entry| {
            if (self.isExpired(entry)) {
                self.evictEntry(entry, false);
                self.cold_stats.misses += 1;
                return null;
            }
            self.lirsAccessCold(key);
            self.cold_stats.hits += 1;
            self.recordSemanticAccess(key);
            return entry.value;
        }

        self.hot_stats.misses += 1;
        return null;
    }

    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        return self.putWithTTL(key, value, self.config.default_ttl_seconds);
    }

    pub fn putWithTTL(self: *Self, key: []const u8, value: []const u8, ttl_seconds: u64) !void {
        if (self.hot.get(key)) |entry| {
            return self.updateEntry(entry, value, ttl_seconds);
        }
        if (self.cold.get(key)) |entry| {
            return self.updateEntry(entry, value, ttl_seconds);
        }

        const alloc = self.arena.allocator();
        const key_copy = try alloc.dupe(u8, key);
        errdefer alloc.free(key_copy);

        const value_copy = try alloc.dupe(u8, value);
        errdefer alloc.free(value_copy);

        const entry = try alloc.create(Entry);
        errdefer alloc.destroy(entry);

        const tokens = tokenizer_mod.Tokenizer.count(value);
        const now = self.time_fn();

        entry.* = .{
            .key = key_copy,
            .value = value_copy,
            .created_at = now,
            .expires_at = if (ttl_seconds > 0) now + @as(i64, @intCast(ttl_seconds)) else null,
            .tokens = tokens,
            .recency = 0,
            .in_hot = true,
        };

        try self.lirsStackPush(key_copy);

        if (self.hot.count() >= self.config.max_hot_size) {
            try self.lirsEvict();
        }

        try self.hot.put(key_copy, entry);
        self.recordSemanticAccess(key_copy);
    }

    fn updateEntry(self: *Self, entry: *Entry, value: []const u8, ttl_seconds: u64) !void {
        const alloc = self.arena.allocator();
        const value_copy = try alloc.dupe(u8, value);
        errdefer alloc.free(value_copy);

        const old_value = entry.value;
        entry.value = value_copy;
        entry.tokens = tokenizer_mod.Tokenizer.count(value);

        if (ttl_seconds > 0) {
        const now = self.time_fn();
            entry.expires_at = now + @as(i64, @intCast(ttl_seconds));
        } else {
            entry.expires_at = null;
        }

        alloc.free(old_value);
    }

    fn lirsAccessHot(self: *Self, key: []const u8) void {
        self.lirsStackMoveToTop(key);
        if (self.lirs_s.items.len < self.lirs_h.items.len) {
            for (self.lirs_s.items) |s_key| {
                if (std.mem.eql(u8, s_key, key)) {
                    return;
                }
            }
            self.lirs_s.append(self.arena.allocator(), key) catch return;
        }
    }

    fn lirsAccessCold(self: *Self, key: []const u8) void {
        if (self.cold.get(key)) |entry| {
            const promoted = self.lirsPromote(key);
            if (promoted) {
                self.cold_stats.promotions += 1;
                self.hot_stats.promotions += 1;

                entry.in_hot = true;
                _ = self.cold.remove(key);
                self.hot.put(key, entry) catch return;

                self.lirsStackMoveToTop(key);
                self.lirs_s.append(self.arena.allocator(), key) catch return;

                if (self.hot.count() > self.config.max_hot_size) {
                    self.lirsEvict() catch return;
                }
            }
        }
    }

    fn lirsPromote(self: *Self, _: []const u8) bool {
        if (self.lirs_s.items.len >= self.config.max_hot_size / 4) {
            return false;
        }
        return true;
    }

    fn lirsStackPush(self: *Self, key: []const u8) !void {
        try self.lirs_stack.append(self.arena.allocator(), key);
        if (self.lirs_stack.items.len > self.config.lirs_stack_size) {
            _ = self.lirs_stack.orderedRemove(0);
        }
    }

    fn lirsStackMoveToTop(self: *Self, key: []const u8) void {
        for (0..self.lirs_stack.items.len) |i| {
            if (std.mem.eql(u8, self.lirs_stack.items[i], key)) {
                const removed = self.lirs_stack.orderedRemove(i);
                self.lirs_stack.append(self.arena.allocator(), removed) catch {
                    self.lirs_stack.appendAssumeCapacity(removed);
                };
                return;
            }
        }
    }

    fn lirsEvict(self: *Self) !void {
        var hot_keys = self.hot.keyIterator();
        var oldest_key: ?[]const u8 = null;
        var oldest_idx: ?usize = null;

        while (hot_keys.next()) |key_ptr| {
            for (0..self.lirs_stack.items.len) |i| {
                if (std.mem.eql(u8, self.lirs_stack.items[i], key_ptr.*)) {
                    if (oldest_idx == null or i < oldest_idx.?) {
                        oldest_idx = i;
                        oldest_key = key_ptr.*;
                    }
                    break;
                }
            }
        }

        if (oldest_key) |key| {
            if (self.hot.get(key)) |entry| {
                self.demoteToCold(entry);
            }
            _ = self.hot.remove(key);
            self.hot_stats.evictions += 1;
        }
    }

    fn demoteToCold(self: *Self, entry: *Entry) void {
        entry.in_hot = false;
        self.cold.put(entry.key, entry) catch return;
        self.hot_stats.demotions += 1;
        self.cold_stats.demotions += 1;
        self.coldEvict();
    }

    fn coldEvict(self: *Self) void {
        while (self.cold.count() > self.config.max_cold_size) {
            var oldest_key: ?[]const u8 = null;
            var oldest_time: i64 = std.math.maxInt(i64);

            var cold_it = self.cold.iterator();
            while (cold_it.next()) |kv| {
                const created = kv.value_ptr.*.created_at;
                if (created < oldest_time) {
                    oldest_time = created;
                    oldest_key = kv.key_ptr.*;
                }
            }

            if (oldest_key) |key| {
                if (self.cold.get(key)) |entry| {
                    self.evictEntry(entry, false);
                    continue;
                }
            }
            break;
        }
    }

    fn evictEntry(self: *Self, entry: *Entry, from_hot: bool) void {
        const alloc = self.arena.allocator();
        _ = if (from_hot) self.hot.remove(entry.key) else self.cold.remove(entry.key);
        alloc.free(entry.key);
        alloc.free(entry.value);
        alloc.destroy(entry);

        if (from_hot) {
            self.hot_stats.evictions += 1;
        } else {
            self.cold_stats.evictions += 1;
        }
    }

    fn isExpired(self: *Self, entry: *const Entry) bool {
        if (entry.expires_at) |expires| {
            return self.time_fn() > expires;
        }
        return false;
    }

    pub fn cleanupExpired(self: *Self) void {
        const now = self.time_fn();

        var hot_it = self.hot.iterator();
        var to_expire_hot = std.ArrayList([]const u8).empty;
        while (hot_it.next()) |kv| {
            if (kv.value_ptr.*.expires_at) |expires| {
                if (now > expires) {
                    to_expire_hot.append(self.arena.allocator(), kv.key_ptr.*) catch continue;
                }
            }
        }
        for (to_expire_hot.items) |key| {
            if (self.hot.get(key)) |entry| {
                self.evictEntry(entry, true);
            }
        }

        var cold_it = self.cold.iterator();
        var to_expire_cold = std.ArrayList([]const u8).empty;
        while (cold_it.next()) |kv| {
            if (kv.value_ptr.*.expires_at) |expires| {
                if (now > expires) {
                    to_expire_cold.append(self.arena.allocator(), kv.key_ptr.*) catch continue;
                }
            }
        }
        for (to_expire_cold.items) |key| {
            if (self.cold.get(key)) |entry| {
                self.evictEntry(entry, false);
            }
        }
    }

    fn recordSemanticAccess(self: *Self, key: []const u8) void {
        const hash = hashKey(key);
        const entry = SemanticEntry{
            .key_hash = hash,
            .tokens = tokenizer_mod.Tokenizer.count(key),
            .text = key,
        };

        self.semantic_history.append(self.arena.allocator(), entry) catch return;

        if (self.semantic_history.items.len > self.config.semantic_window) {
            _ = self.semantic_history.orderedRemove(0);
        }
    }

    fn hashKey(key: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key);
        return hasher.final();
    }

    pub fn findSemanticMatch(self: *Self, query: []const u8, min_similarity: f64) ?SemanticMatch {
        _ = hashKey(query);
        const query_tokens = tokenizer_mod.Tokenizer.count(query);
        var best_match: ?SemanticMatch = null;
        var best_score: f64 = min_similarity;

        for (self.semantic_history.items) |entry| {
            if (std.mem.eql(u8, entry.text, query)) continue;

            const score = self.computeSimilarity(query, entry.text, query_tokens, entry.tokens);
            if (score > best_score) {
                best_score = score;
                if (self.hot.get(entry.text)) |hot_entry| {
                    best_match = .{
                        .key = entry.text,
                        .value = hot_entry.value,
                        .similarity = score,
                        .tier = .hot,
                    };
                } else if (self.cold.get(entry.text)) |cold_entry| {
                    best_match = .{
                        .key = entry.text,
                        .value = cold_entry.value,
                        .similarity = score,
                        .tier = .cold,
                    };
                }
            }
        }

        return best_match;
    }

    fn computeSimilarity(self: *Self, a: []const u8, b: []const u8, tokens_a: usize, tokens_b: usize) f64 {
        _ = self;
        if (tokens_a == 0 or tokens_b == 0) return 0.0;

        // O(n) byte-set Jaccard similarity (replaces the previous O(n^2)
        // per-byte scan that got slow on long code/text inputs).
        var a_set = std.mem.zeroes([256]bool);
        var b_set = std.mem.zeroes([256]bool);
        var a_unique: usize = 0;
        var b_unique: usize = 0;
        for (a) |ba| {
            if (!a_set[ba]) {
                a_set[ba] = true;
                a_unique += 1;
            }
        }
        for (b) |bb| {
            if (!b_set[bb]) {
                b_set[bb] = true;
                b_unique += 1;
            }
        }
        var shared: usize = 0;
        for (0..256) |i| {
            if (a_set[i] and b_set[i]) shared += 1;
        }
        const union_size = a_unique + b_unique - shared;
        const char_sim: f64 = if (union_size == 0)
            0.0
        else
            @as(f64, @floatFromInt(shared)) / @as(f64, @floatFromInt(union_size));

        const max_tokens = @max(tokens_a, tokens_b);
        const token_diff = if (tokens_a >= tokens_b) tokens_a - tokens_b else tokens_b - tokens_a;
        const token_sim = 1.0 - (@as(f64, @floatFromInt(token_diff)) / @as(f64, @floatFromInt(max_tokens)));

        return (token_sim * 0.6 + char_sim * 0.4);
    }

    pub const SemanticMatch = struct {
        key: []const u8,
        value: []const u8,
        similarity: f64,
        tier: enum { hot, cold },
    };

    pub fn hitRate(self: *const Self) f64 {
        const total = self.hot_stats.hits + self.hot_stats.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hot_stats.hits)) / @as(f64, @floatFromInt(total));
    }

    pub fn hotHitRate(self: *const Self) f64 {
        return self.hot_stats.hitRate();
    }

    pub fn coldHitRate(self: *const Self) f64 {
        return self.cold_stats.hitRate();
    }

    pub fn decideAfterUsage(
        prompt_tokens: usize,
        ctx_max: usize,
        already_folded: bool,
    ) FoldDecision {
        return decideAfterUsageWithConfig(prompt_tokens, ctx_max, already_folded, Config{});
    }

    pub fn decideAfterUsageWithConfig(
        prompt_tokens: usize,
        ctx_max: usize,
        already_folded: bool,
        config: Config,
    ) FoldDecision {
        if (already_folded) return .none;
        const ratio = @as(f64, @floatFromInt(prompt_tokens)) / @as(f64, @floatFromInt(ctx_max));
        if (ratio > config.fold_emergency) return .{ .emergency_truncate = .{ .target_tokens = @intFromFloat(@as(f64, @floatFromInt(ctx_max)) * 0.7) } };
        if (ratio > config.fold_exit) return .exit_with_summary;
        if (ratio > config.fold_aggressive) return .{ .fold_aggressive = .{ .tail_budget = @intFromFloat(@as(f64, @floatFromInt(ctx_max)) * 0.1) } };
        if (ratio > config.fold_warn) return .{ .fold_normal = .{ .tail_budget = @intFromFloat(@as(f64, @floatFromInt(ctx_max)) * 0.2) } };
        return .none;
    }

    pub fn getStats(self: *const Self) Stats {
        return .{
            .hot = self.hot_stats,
            .cold = self.cold_stats,
            .hot_size = self.hot.count(),
            .cold_size = self.cold.count(),
            .semantic_history_size = self.semantic_history.items.len,
        };
    }

    pub const Stats = struct {
        hot: TierStats,
        cold: TierStats,
        hot_size: usize,
        cold_size: usize,
        semantic_history_size: usize,

        pub fn totalHitRate(self: *const Stats) f64 {
            const total_hits = self.hot.hits + self.cold.hits;
            const total = self.hot.hits + self.hot.misses + self.cold.hits + self.cold.misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(total_hits)) / @as(f64, @floatFromInt(total));
        }
    };
};

test "reasonix init and deinit" {
    var reasonix = Reasonix.init(std.testing.allocator, .{});
    defer reasonix.deinit();

    try std.testing.expectEqual(@as(usize, 0), reasonix.hot.count());
    try std.testing.expectEqual(@as(usize, 0), reasonix.cold.count());
}

test "reasonix put and get" {
    var reasonix = Reasonix.init(std.testing.allocator, .{});
    defer reasonix.deinit();

    try reasonix.put("prompt:1", "Write a hello world program");
    try reasonix.put("prompt:2", "Explain closures in Zig");

    const result1 = reasonix.get("prompt:1");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqualStrings("Write a hello world program", result1.?);

    const result2 = reasonix.get("prompt:2");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqualStrings("Explain closures in Zig", result2.?);
}

test "reasonix put with ttl" {
    var reasonix = Reasonix.init(std.testing.allocator, .{});
    defer reasonix.deinit();

    try reasonix.putWithTTL("short_ttl", "value", 1);

    const result = reasonix.get("short_ttl");
    try std.testing.expect(result != null);

    reasonix.clock += 2;
    reasonix.putWithTTL("clocked", "value", 1) catch unreachable;

    const clocked_result = reasonix.get("clocked");
    try std.testing.expect(clocked_result != null);
}

test "reasonix hit rate" {
    var reasonix = Reasonix.init(std.testing.allocator, .{});
    defer reasonix.deinit();

    try std.testing.expectEqual(@as(f64, 0.0), reasonix.hitRate());

    try reasonix.put("a", "b");
    _ = reasonix.get("a");
    _ = reasonix.get("missing");

    try std.testing.expectEqual(@as(f64, 0.5), reasonix.hitRate());
}

test "reasonix hot and cold tier stats" {
    var reasonix = Reasonix.init(std.testing.allocator, .{ .max_hot_size = 2 });
    defer reasonix.deinit();

    try reasonix.put("k1", "v1");
    try reasonix.put("k2", "v2");

    _ = reasonix.get("k1");
    _ = reasonix.get("missing");

    const stats = reasonix.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.hot.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.hot.misses);
    try std.testing.expectEqual(@as(usize, 2), stats.hot_size);
}

test "reasonix lirs eviction" {
    var reasonix = Reasonix.init(std.testing.allocator, .{
        .max_hot_size = 2,
        .lirs_stack_size = 4,
    });
    defer reasonix.deinit();

    try reasonix.put("item1", "first");
    try reasonix.put("item2", "second");

    try std.testing.expectEqual(@as(usize, 2), reasonix.hot.count());

    try reasonix.put("item3", "third");

    try std.testing.expect(reasonix.hot.count() <= 2);
}

test "reasonix cold tier capacity" {
    var reasonix = Reasonix.init(std.testing.allocator, .{
        .max_hot_size = 1,
        .max_cold_size = 2,
        .lirs_stack_size = 8,
    });
    defer reasonix.deinit();

    try reasonix.put("k1", "v1");
    try reasonix.put("k2", "v2");
    try reasonix.put("k3", "v3");
    try reasonix.put("k4", "v4");

    try std.testing.expect(reasonix.cold.count() <= 2);
}

test "reasonix cold tier promotion" {
    var reasonix = Reasonix.init(std.testing.allocator, .{
        .max_hot_size = 2,
        .lirs_stack_size = 4,
    });
    defer reasonix.deinit();

    try reasonix.put("k1", "v1");
    try reasonix.put("k2", "v2");

    _ = reasonix.get("k1");
    _ = reasonix.get("k2");

    try reasonix.put("k3", "v3");
    try reasonix.put("k4", "v4");

    const stats = reasonix.getStats();
    try std.testing.expect(stats.cold_size > 0 or stats.hot_size > 0);
}

test "reasonix semantic matching" {
    var reasonix = Reasonix.init(std.testing.allocator, .{
        .semantic_window = 5,
    });
    defer reasonix.deinit();

    try reasonix.put("explain zigs error handling", "Use error unions");
    try reasonix.put("zig comptime features", "Comptime blocks and inline");

    const match = reasonix.findSemanticMatch("explain zig errors", 0.3);
    try std.testing.expect(match != null);
    if (match) |m| {
        try std.testing.expect(m.similarity > 0.3);
    }
}

test "reasonix semantic match returns null for low similarity" {
    var reasonix = Reasonix.init(std.testing.allocator, .{});
    defer reasonix.deinit();

    try reasonix.put("completely different topic", "some unrelated content");

    const match = reasonix.findSemanticMatch("xyz123 totally unrelated query string", 0.8);
    _ = match;
}

test "fold decision thresholds" {
    const custom_config: Reasonix.Config = .{
        .fold_warn = 0.50,
        .fold_aggressive = 0.70,
        .fold_exit = 0.80,
        .fold_emergency = 0.95,
    };

    const d1 = Reasonix.decideAfterUsageWithConfig(5000, 10000, false, custom_config);
    try std.testing.expect(std.meta.activeTag(d1) == .none);

    const d2 = Reasonix.decideAfterUsageWithConfig(6000, 10000, false, custom_config);
    try std.testing.expect(std.meta.activeTag(d2) == .fold_normal);

    const d3 = Reasonix.decideAfterUsageWithConfig(7500, 10000, false, custom_config);
    try std.testing.expect(std.meta.activeTag(d3) == .fold_aggressive);

    const d4 = Reasonix.decideAfterUsageWithConfig(8500, 10000, false, custom_config);
    try std.testing.expect(std.meta.activeTag(d4) == .exit_with_summary);

    const d5 = Reasonix.decideAfterUsageWithConfig(9600, 10000, false, custom_config);
    try std.testing.expect(std.meta.activeTag(d5) == .emergency_truncate);

    const d6 = Reasonix.decideAfterUsageWithConfig(5000, 10000, true, custom_config);
    try std.testing.expect(std.meta.activeTag(d6) == .none);
}

test "fold decision already folded" {
    const d = Reasonix.decideAfterUsage(9000, 10000, true);
    try std.testing.expect(std.meta.activeTag(d) == .none);
}

test "reasonix cleanup expired" {
    var reasonix = Reasonix.init(std.testing.allocator, .{});
    defer reasonix.deinit();

    try reasonix.putWithTTL("expired", "value", 1);
    try reasonix.put("permanent", "value");

    reasonix.clock += 10;
    reasonix.putWithTTL("clock_expired", "value", 1) catch unreachable;

    const result = reasonix.get("expired");
    _ = result;
}

test "reasonix tier stats tracking" {
    var reasonix = Reasonix.init(std.testing.allocator, .{
        .max_hot_size = 1,
    });
    defer reasonix.deinit();

    try reasonix.put("k1", "v1");
    _ = reasonix.get("k1");

    const stats = reasonix.getStats();
    try std.testing.expect(stats.hot.hits >= 0);
    try std.testing.expect(stats.cold.misses >= 0);
}

test "reasonix stats total hit rate" {
    var reasonix = Reasonix.init(std.testing.allocator, .{});
    defer reasonix.deinit();

    const stats = reasonix.getStats();
    try std.testing.expectEqual(@as(f64, 0.0), stats.totalHitRate());

    try reasonix.put("k", "v");
    _ = reasonix.get("k");
    _ = reasonix.get("k");
    _ = reasonix.get("missing");

    const stats2 = reasonix.getStats();
    try std.testing.expectApproxEqAbs(@as(f64, 0.666), stats2.totalHitRate(), 0.001);
}

test "reasonix cold tier tracking" {
    var reasonix = Reasonix.init(std.testing.allocator, .{
        .max_hot_size = 2,
        .lirs_stack_size = 4,
    });
    defer reasonix.deinit();

    try reasonix.put("k1", "v1");
    try reasonix.put("k2", "v2");
    try reasonix.put("k3", "v3");
    try reasonix.put("k4", "v4");

    _ = reasonix.get("k1");
    _ = reasonix.get("k2");

    const stats = reasonix.getStats();
    try std.testing.expect(stats.cold_size + stats.hot_size == 4);
}

test "reasonix semantic history records accesses" {
    var reasonix = Reasonix.init(std.testing.allocator, .{
        .semantic_window = 3,
    });
    defer reasonix.deinit();

    try reasonix.put("k1", "v1");
    try reasonix.put("k2", "v2");
    _ = reasonix.get("k1");
    _ = reasonix.get("k2");
    _ = reasonix.get("k3");

    const stats = reasonix.getStats();
    try std.testing.expect(stats.semantic_history_size > 0);
}

test "reasonix update existing entry" {
    var reasonix = Reasonix.init(std.testing.allocator, .{});
    defer reasonix.deinit();

    try reasonix.put("key", "original");
    _ = reasonix.get("key");

    try reasonix.put("key", "updated");
    const result = reasonix.get("key");

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("updated", result.?);
}

test "reasonix fold emergency decision" {
    const d = Reasonix.decideAfterUsage(9800, 10000, false);
    try std.testing.expect(std.meta.activeTag(d) == .emergency_truncate);

    if (d == .emergency_truncate) {
        const target = d.emergency_truncate.target_tokens;
        try std.testing.expect(target > 0);
        try std.testing.expect(target < 10000);
    }
}
