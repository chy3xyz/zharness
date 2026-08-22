const std = @import("std");

pub const AIMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const UsageStats = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};

pub const AIResponse = struct {
    message: struct {
        content: []const u8,
    },
    usage: UsageStats,
    metadata: struct {
        stop_reason: ?[]const u8 = null,
    },
};

pub const RequestConfig = struct {
    model: []const u8,
    max_tokens: u32 = 65536,
    temperature: f32 = 1.0,
    system_prompt: []const u8 = "",
};

pub const StreamEvent = union(enum) {
    content_delta: []const u8,
    reasoning_delta: []const u8,
    done: void,
    err: []const u8,
};

pub const CacheConfig = struct {
    enabled: bool = true,
    cutoff_index: ?usize = null,
};

pub fn buildDeepSeekRequestBody(
    allocator: std.mem.Allocator,
    messages: []const AIMessage,
    model: []const u8,
    stream: bool,
    cache: CacheConfig,
    reasoning_effort: ?[]const u8,
) ![]u8 {
    var body = try std.ArrayList(u8).initCapacity(allocator, 512);
    errdefer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"model\":\"");
    try body.appendSlice(allocator, model);
    try body.appendSlice(allocator, "\",\"stream\":");
    try body.appendSlice(allocator, if (stream) "true" else "false");
    try body.appendSlice(allocator, ",\"messages\":[");

    for (messages, 0..) |msg, i| {
        if (i > 0) try body.append(allocator, ',');
        try body.append(allocator, '{');
        try body.appendSlice(allocator, "\"role\":\"");
        try body.appendSlice(allocator, msg.role);
        try body.appendSlice(allocator, "\",\"content\":\"");
        try escapeJsonString(allocator, msg.content, &body);
        try body.appendSlice(allocator, "\"}");

        if (cache.enabled and cache.cutoff_index != null and i == cache.cutoff_index.?) {
            try body.appendSlice(allocator, ",\"cache_control\":{\"type\":\"cache_cutoff\"}");
        }
    }

    try body.appendSlice(allocator, "]");

    if (reasoning_effort) |effort| {
        try body.appendSlice(allocator, ",\"reasoning_effort\":\"");
        try body.appendSlice(allocator, effort);
        try body.append(allocator, '"');
    }

    try body.append(allocator, '}');
    return body.toOwnedSlice(allocator);
}

fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8, output: *std.ArrayList(u8)) !void {
    for (input) |c| {
        switch (c) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            else => try output.append(allocator, c),
        }
    }
}

pub fn isRetryableError(status_code: u16) bool {
    return switch (status_code) {
        408, 429, 500, 502, 503, 504 => true,
        else => false,
    };
}

pub const RateLimiter = struct {
    rpm: u32,
    min_interval_ms: u64,
    last_request_ts: i64 = 0,
    arena: std.heap.ArenaAllocator,

    pub fn init(rpm: u32) RateLimiter {
        const min_interval_ms = if (rpm > 0) (60 * 1000) / @as(u64, rpm) else 60_000;
        return .{
            .rpm = rpm,
            .min_interval_ms = min_interval_ms,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.arena.deinit();
    }

    pub fn wait(self: *RateLimiter) !void {
        const now = monotonicTimestamp();
        if (self.last_request_ts != 0) {
            const elapsed_ms = (now - self.last_request_ts) * 1000;
            if (elapsed_ms < @as(i64, @intCast(self.min_interval_ms))) {
                const sleep_ms = self.min_interval_ms - @as(u64, @intCast(elapsed_ms));
                const ts = std.c.timespec{
                    .sec = @intCast(sleep_ms / 1000),
                    .nsec = @intCast((sleep_ms % 1000) * 1_000_000),
                };
                _ = std.c.nanosleep(&ts, null);
            }
        }
        self.last_request_ts = monotonicTimestamp();
    }
};

pub const CircuitBreaker = struct {
    state: enum { closed, open, half_open } = .closed,
    failure_count: u32 = 0,
    success_count: u32 = 0,
    threshold: u32 = 5,
    reset_timeout_s: u64 = 30,

    last_failure_ts: i64 = 0,

    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.failure_count = 0;
        self.success_count += 1;
        if (self.state == .half_open and self.success_count >= 3) {
            self.state = .closed;
            self.success_count = 0;
        }
    }

    pub fn recordFailure(self: *CircuitBreaker) void {
        self.failure_count += 1;
        self.last_failure_ts = wallTimestamp();
        if (self.failure_count >= self.threshold) {
            self.state = .open;
        }
    }

    pub fn isOpen(self: *CircuitBreaker) bool {
        if (self.state == .open) {
            const now = wallTimestamp();
            if (now - self.last_failure_ts > @as(i64, @intCast(self.reset_timeout_s))) {
                self.state = .half_open;
                self.success_count = 0;
                return false;
            }
            return true;
        }
        return false;
    }
};

fn wallTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn monotonicTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC_RAW, &ts);
    return ts.sec;
}

test "cache config defaults" {
    const cfg = CacheConfig{};
    try std.testing.expect(cfg.enabled);
    try std.testing.expectEqual(@as(?usize, null), cfg.cutoff_index);
}

test "is retryable error" {
    try std.testing.expect(isRetryableError(408));
    try std.testing.expect(isRetryableError(429));
    try std.testing.expect(isRetryableError(500));
    try std.testing.expect(!isRetryableError(200));
    try std.testing.expect(!isRetryableError(401));
}

test "build deepseek request body basic" {
    const alloc = std.testing.allocator;
    const messages = [_]AIMessage{
        .{ .role = "user", .content = "Hello" },
    };
    const body = try buildDeepSeekRequestBody(alloc, &messages, "deepseek-chat", false, .{}, null);
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "deepseek-chat") != null);
}

test "build deepseek request body with reasoning effort" {
    const alloc = std.testing.allocator;
    const messages = [_]AIMessage{
        .{ .role = "user", .content = "Hello" },
    };
    const body = try buildDeepSeekRequestBody(alloc, &messages, "deepseek-chat", false, .{}, "high");
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") != null);
}

test "escape json string" {
    const alloc = std.testing.allocator;
    var result = std.ArrayList(u8).empty;
    defer result.deinit(alloc);
    try escapeJsonString(alloc, "Hello \"world\"", &result);
    try std.testing.expectEqualSlices(u8, "Hello \\\"world\\\"", result.items);
}
