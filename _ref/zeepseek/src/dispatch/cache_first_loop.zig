const std = @import("std");
const stream_client = @import("../net/stream_client.zig");
const http_client_mod = @import("../net/http_client.zig");
const config_mod = @import("../utils/config.zig");
const tokenizer_mod = @import("../utils/tokenizer.zig");

const RateLimiter = http_client_mod.RateLimiter;
const CircuitBreaker = http_client_mod.CircuitBreaker;

const reasonix_mod = @import("../cache/reasonix.zig");
const context_mod = @import("context_manager.zig");
const ContextManager = context_mod.ContextManager;
const ImmutablePrefix = context_mod.ImmutablePrefix;
const FoldDecision = context_mod.FoldDecision;

comptime {
    const cfg = config_mod.CacheConfig{};
    if (cfg.fold_threshold >= cfg.fold_aggressive_threshold) {
        @compileError("fold_threshold must be < fold_aggressive_threshold");
    }
    if (cfg.fold_aggressive_threshold >= cfg.fold_exit_threshold) {
        @compileError("fold_aggressive_threshold must be < fold_exit_threshold");
    }
    if (cfg.fold_exit_threshold >= cfg.emergency_threshold) {
        @compileError("fold_exit_threshold must be < emergency_threshold");
    }
}

pub const PromptCacheDecision = enum {
    none,
    hit,
    miss,
};

pub const CacheFirstLoop = struct {
    prefix: ImmutablePrefix,
    context: *ContextManager,
    reasonix: *reasonix_mod.Reasonix,
    model_type: config_mod.ModelType,
    model_name: []const u8,
    reasoning_effort: []const u8,
    stream: bool,
    budget_usd: ?f64,
    turn: u32 = 0,
    io: std.Io,
    api_key: []const u8 = "",
    provider_id: []const u8 = "deepseek",
    endpoint: []const u8 = "https://api.deepseek.com",
    rate_limiter: ?*RateLimiter = null,
    circuit_breaker: ?*CircuitBreaker = null,

    arena: std.heap.ArenaAllocator,

    abort_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    budget: SessionBudget = .{},
    auto_switch: bool = true,

    pub const Options = struct {
        prefix: ImmutablePrefix,
        context: *ContextManager,
        reasonix: *reasonix_mod.Reasonix,
        model: config_mod.ModelType = .deepseek_chat,
        reasoning_effort: []const u8 = "high",
        stream: bool = false,
        budget_usd: ?f64 = null,
        io: std.Io,
        api_key: []const u8 = "",
        provider_id: []const u8 = "deepseek",
        endpoint: []const u8 = "https://api.deepseek.com",
        rate_limiter: ?*RateLimiter = null,
        circuit_breaker: ?*CircuitBreaker = null,
        auto_switch: bool = true,
    };

    pub fn init(alloc: std.mem.Allocator, options: Options) CacheFirstLoop {
        return .{
            .prefix = options.prefix,
            .context = options.context,
            .reasonix = options.reasonix,
            .model_type = options.model,
            .model_name = options.model.apiName(),
            .reasoning_effort = options.reasoning_effort,
            .stream = options.stream,
            .budget_usd = options.budget_usd,
            .io = options.io,
            .api_key = options.api_key,
            .provider_id = options.provider_id,
            .endpoint = options.endpoint,
            .rate_limiter = options.rate_limiter,
            .circuit_breaker = options.circuit_breaker,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .auto_switch = options.auto_switch,
        };
    }

    pub fn selectModelForTask(self: *CacheFirstLoop, task_description: []const u8) config_mod.ModelSelection {
        const total_tokens = self.context.totalTokens();
        return config_mod.selectModelForTask(task_description, total_tokens);
    }

    pub fn applyModelSelection(self: *CacheFirstLoop, selection: config_mod.ModelSelection) void {
        self.model_type = selection.model;
        self.model_name = selection.model.apiName();
        self.reasoning_effort = switch (selection.reasoning_effort) {
            .off => "off",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .auto => "auto",
        };
    }

    pub fn setReasoningEffort(self: *CacheFirstLoop, effort: []const u8) void {
        self.reasoning_effort = effort;
    }

    fn reasoningEffortFromTokens(total_tokens: usize) []const u8 {
        if (total_tokens < 10000) return "low";
        if (total_tokens < 50000) return "medium";
        return "high";
    }

    pub fn deinit(self: *CacheFirstLoop) void {
        self.abort();
        self.arena.deinit();
    }

    pub fn abort(self: *CacheFirstLoop) void {
        self.abort_flag.store(true, .seq_cst);
    }

    fn decide(self: *CacheFirstLoop) FoldDecision {
        const total_tokens = self.context.totalTokens();
        const ctx_max = self.contextWindow();
        const raw = reasonix_mod.Reasonix.decideAfterUsage(total_tokens, ctx_max, false);
        return context_mod.foldDecisionFromReasonix(raw);
    }

    pub fn steer(self: *CacheFirstLoop, message: []const u8) void {
        if (self.auto_switch and !isModelSwitchDirective(message)) {
            const selection = self.selectModelForTask(message);
            self.applyModelSelection(selection);
        }
        const decision = self.decide();
        switch (decision) {
            .none => {},
            .fold_normal, .fold_aggressive => {
                // steer() cannot propagate errors; a fold failure is
                // non-fatal (the request proceeds on the full context).
                _ = self.context.foldHistory(self.model_name, decision, null, null) catch {};
            },
            .exit_with_summary => {},
            .emergency_truncate => {
                self.context.clear();
            },
        }
    }

    pub fn setModel(self: *CacheFirstLoop, model: config_mod.ModelType) void {
        self.model_type = model;
        self.model_name = model.apiName();
    }

    pub fn contextWindow(self: *const CacheFirstLoop) u32 {
        return self.model_type.contextWindow();
    }

    pub fn stepStream(self: *CacheFirstLoop, user_input: []const u8) !StreamState {
        if (self.abort_flag.load(.seq_cst)) return error.LoopAborted;

        self.turn += 1;
        self.abort_flag.store(false, .seq_cst);

        try self.context.addMessage(.{
            .role = "user",
            .content = user_input,
        });

        const messages = self.context.getMessages();
        const total_tokens = self.context.totalTokens();
        const ctx_max = self.contextWindow();

        const already_folded = false;
        const raw_decision = reasonix_mod.Reasonix.decideAfterUsage(
            total_tokens,
            ctx_max,
            already_folded,
        );
        const decision = context_mod.foldDecisionFromReasonix(raw_decision);

        switch (decision) {
            .none => {},
            .fold_normal, .fold_aggressive => {
                _ = try self.context.foldHistory(self.model_name, decision, null, null);
            },
            .exit_with_summary => {
                return error.BudgetExhausted;
            },
            .emergency_truncate => {
                self.context.clear();
            },
        }

        if (self.abort_flag.load(.seq_cst)) return error.LoopAborted;

        try self.checkBudget();

        const ctx = try self.arena.allocator().alloc(stream_client.CtxItem, messages.len - 1);
        for (messages[0 .. messages.len - 1], 0..) |msg, i| {
            ctx[i] = stream_client.CtxItem{ .role = msg.role, .content = msg.content };
        }

        const cache_decision = self.promptCacheDecision();

        var stream_client_inst = stream_client.DeepSeekStreamClient.init(
            self.arena.allocator(),
            self.io,
            self.rate_limiter,
            self.circuit_breaker,
        );
        stream_client_inst.endpoint = self.endpoint;
        const iterator = try stream_client_inst.streamMessage(
            self.api_key,
            user_input,
            ctx,
            self.model_name,
            cache_decision,
            self.prefix.system_prompt,
            self.reasoning_effort,
        );

        return StreamState{
            .iterator = iterator,
            .loop = self,
            .user_input = user_input,
            .turn = self.turn,
        };
    }

    pub fn step(self: *CacheFirstLoop, user_input: []const u8) !LoopEventStream {
        if (self.abort_flag.load(.seq_cst)) return error.LoopAborted;

        self.turn += 1;
        self.abort_flag.store(false, .seq_cst);

        try self.context.addMessage(.{
            .role = "user",
            .content = user_input,
        });

        const messages = self.context.getMessages();
        const total_tokens = self.context.totalTokens();
        const ctx_max = self.contextWindow();

        const already_folded = false;
        const raw_decision = reasonix_mod.Reasonix.decideAfterUsage(
            total_tokens,
            ctx_max,
            already_folded,
        );
        const decision = context_mod.foldDecisionFromReasonix(raw_decision);

        switch (decision) {
            .none => {},
            .fold_normal, .fold_aggressive => {
                _ = try self.context.foldHistory(self.model_name, decision, null, null);
            },
            .exit_with_summary => {
                return error.BudgetExhausted;
            },
            .emergency_truncate => {
                self.context.clear();
            },
        }

        if (self.abort_flag.load(.seq_cst)) return error.LoopAborted;

        try self.checkBudget();

        var non_stream_client = http_client_mod.DeepSeekClient.init(
            self.arena.allocator(),
            self.io,
            self.api_key,
        );
        non_stream_client.endpoint = self.endpoint;
        defer non_stream_client.deinit();

        const config = http_client_mod.RequestConfig{
            .model = self.model_name,
            .max_tokens = 65536,
            .temperature = 1.0,
            .system_prompt = self.prefix.system_prompt,
        };
        const ctx = try self.arena.allocator().alloc(http_client_mod.AIMessage, messages.len - 1);
        for (messages[0 .. messages.len - 1], 0..) |msg, i| {
            ctx[i] = .{
                .role = msg.role,
                .content = msg.content,
            };
        }
        const response = try non_stream_client.sendMessageWithContext(
            user_input,
            ctx,
            config,
        );

        self.budget.recordResponse(&response, self.model_type);

        try self.context.addMessage(.{
            .role = "assistant",
            .content = response.message.content,
        });

        const finish_reason = response.metadata.stop_reason orelse "stop";

        return LoopEventStream{
            .content = response.message.content,
            .reasoning = null,
            .finish_reason = finish_reason,
        };
    }

    fn checkBudget(self: *const CacheFirstLoop) !void {
        if (self.budget_usd) |limit| {
            if (self.budget.total_cost_usd >= limit) {
                return error.BudgetExhausted;
            }
        }
    }

    fn promptCacheDecision(self: *CacheFirstLoop) PromptCacheDecision {
        if (self.prefix.system_prompt.len == 0) return .none;

        const cache_key = self.prefix.fingerprint;
        const cached = self.reasonix.get(&cache_key);
        if (cached != null) {
            self.budget.cache_hits += 1;
            return .hit;
        }
        self.budget.cache_misses += 1;
        return .miss;
    }
};

fn isModelSwitchDirective(message: []const u8) bool {
    var buf: [256]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, message);
    defer {
        if (lower.ptr != &buf) std.heap.page_allocator.free(lower);
    }
    const needles = [_][]const u8{ "switch to", "use model", "/model", "change model" };
    for (needles) |n| {
        if (std.mem.indexOf(u8, lower, n) != null) return true;
    }
    return false;
}

pub const StreamState = struct {
    iterator: stream_client.StreamIterator,
    loop: *CacheFirstLoop,
    user_input: []const u8,
    turn: u32,
    finish_reason: []const u8 = "stop",

    pub fn nextChunk(self: *StreamState) !?stream_client.StreamChunk {
        if (self.loop.abort_flag.load(.seq_cst)) return null;
        return self.iterator.nextChunk() catch null;
    }

    pub fn hasToolCalls(self: *const StreamState) bool {
        return self.iterator.has_tool_calls;
    }

    pub fn getToolCallJson(self: *const StreamState) []const u8 {
        return self.iterator.tool_call_json.items;
    }

    pub fn deinit(self: *StreamState) void {
        self.iterator.deinit();
    }
};

pub const LoopEventStream = struct {
    content: []const u8,
    reasoning: ?[]const u8 = null,
    finish_reason: []const u8 = "stop",
};

pub const SessionBudget = struct {
    total_prompt_tokens: u64 = 0,
    total_completion_tokens: u64 = 0,
    total_cost_usd: f64 = 0.0,
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,
    turns: u32 = 0,

    pub fn cacheHitRatio(self: *const SessionBudget) f64 {
        const total = @as(u64, self.cache_hits) + @as(u64, self.cache_misses);
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total));
    }

    pub fn recordResponse(self: *SessionBudget, response: *const http_client_mod.AIResponse, model: config_mod.ModelType) void {
        self.total_prompt_tokens += response.usage.input_tokens;
        self.total_completion_tokens += response.usage.output_tokens;
        self.total_cost_usd += estimateCost(response.usage.input_tokens, response.usage.output_tokens, model);
        self.turns += 1;
    }

    pub fn estimateCost(prompt_tokens: u64, completion_tokens: u64, model: config_mod.ModelType) f64 {
        const tier = model.costPerMtok();
        const prompt_cost = @as(f64, @floatFromInt(prompt_tokens)) * tier.input / 1_000_000.0;
        const completion_cost = @as(f64, @floatFromInt(completion_tokens)) * tier.output / 1_000_000.0;
        return prompt_cost + completion_cost;
    }

    pub fn cacheSavingsUsd(self: *const SessionBudget) f64 {
        if (self.cache_hits == 0) return 0.0;
        const total_tokens = self.total_prompt_tokens;
        if (total_tokens == 0) return 0.0;
        const cacheable_ratio = 1.0 - 0.2;
        const cached_tokens = @as(f64, @floatFromInt(self.cache_hits)) * cacheable_ratio;
        const cacheable_cost_per_mtok = 0.27;
        return cached_tokens * cacheable_cost_per_mtok / 1_000_000.0;
    }
};

test "session budget cache hit ratio" {
    var budget = SessionBudget{};
    try std.testing.expectEqual(@as(f64, 0.0), budget.cacheHitRatio());

    budget.cache_hits = 9;
    budget.cache_misses = 1;
    try std.testing.expectEqual(@as(f64, 0.9), budget.cacheHitRatio());
}

test "session budget cost estimation" {
    const cost = SessionBudget.estimateCost(1000, 500, .deepseek_chat);
    try std.testing.expect(cost > 0.0);
}

test "session budget cache savings" {
    var budget = SessionBudget{};
    budget.total_prompt_tokens = 10000;
    budget.cache_hits = 5;
    const savings = budget.cacheSavingsUsd();
    try std.testing.expect(savings >= 0.0);
}

test "comptime fold threshold ordering" {
    const cfg = config_mod.CacheConfig{};
    try std.testing.expect(cfg.fold_threshold < cfg.fold_aggressive_threshold);
    try std.testing.expect(cfg.fold_aggressive_threshold < cfg.fold_exit_threshold);
    try std.testing.expect(cfg.fold_exit_threshold < cfg.emergency_threshold);
}

test "cache first loop init" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    var reasonix = reasonix_mod.Reasonix.init(alloc, .{});
    defer reasonix.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const prefix = ImmutablePrefix.init(alloc, "You are helpful.", "", "");

    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    _ = CacheFirstLoop.init(alloc, .{
        .prefix = prefix,
        .context = &ctx,
        .reasonix = &reasonix,
        .io = io,
    });
}

test "cache first loop abort sets flag" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    var reasonix = reasonix_mod.Reasonix.init(alloc, .{});
    defer reasonix.deinit();

    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const prefix = ImmutablePrefix.init(alloc, "", "", "");
    var loop = CacheFirstLoop.init(alloc, .{
        .prefix = prefix,
        .context = &ctx,
        .reasonix = &reasonix,
        .io = io,
    });
    defer loop.deinit();

    try std.testing.expect(!loop.abort_flag.load(.seq_cst));
    loop.abort();
    try std.testing.expect(loop.abort_flag.load(.seq_cst));
}

test "cache first loop steer updates model" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    var reasonix = reasonix_mod.Reasonix.init(alloc, .{});
    defer reasonix.deinit();

    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const prefix = ImmutablePrefix.init(alloc, "", "", "");
    var loop = CacheFirstLoop.init(alloc, .{
        .prefix = prefix,
        .context = &ctx,
        .reasonix = &reasonix,
        .model = .deepseek_chat,
        .io = io,
    });
    defer loop.deinit();

    try std.testing.expectEqualSlices(u8, "deepseek-chat", loop.model_name);
    loop.steer("switch to coder");
    try std.testing.expectEqualSlices(u8, "deepseek-chat", loop.model_name);
}

test "cache first loop setModel" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    var reasonix = reasonix_mod.Reasonix.init(alloc, .{});
    defer reasonix.deinit();

    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const prefix = ImmutablePrefix.init(alloc, "", "", "");
    var loop = CacheFirstLoop.init(alloc, .{
        .prefix = prefix,
        .context = &ctx,
        .reasonix = &reasonix,
        .model = .deepseek_chat,
        .io = io,
    });
    defer loop.deinit();

    try std.testing.expectEqualSlices(u8, "deepseek-chat", loop.model_name);
    loop.setModel(.deepseek_coder);
    try std.testing.expectEqualSlices(u8, "deepseek-coder", loop.model_name);
    try std.testing.expectEqual(@as(u32, 128000), loop.contextWindow());
}

test "cache first loop contextWindow" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    var reasonix = reasonix_mod.Reasonix.init(alloc, .{});
    defer reasonix.deinit();

    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const prefix = ImmutablePrefix.init(alloc, "", "", "");
    var loop = CacheFirstLoop.init(alloc, .{
        .prefix = prefix,
        .context = &ctx,
        .reasonix = &reasonix,
        .model = .deepseek_chat,
        .io = io,
    });
    defer loop.deinit();

    try std.testing.expectEqual(@as(u32, 64000), loop.contextWindow());
}

test "budget tracking per turn" {
    const budget = SessionBudget{};
    try std.testing.expectEqual(@as(u32, 0), budget.turns);
    try std.testing.expectEqual(@as(f64, 0.0), budget.total_cost_usd);
    try std.testing.expectEqual(@as(u64, 0), budget.total_prompt_tokens);
}

test "prompt cache decision on empty prefix" {
    const alloc = std.testing.allocator;
    var ctx = ContextManager.init(alloc);
    defer ctx.deinit();

    var reasonix = reasonix_mod.Reasonix.init(alloc, .{});
    defer reasonix.deinit();

    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const prefix = ImmutablePrefix.init(alloc, "", "", "");
    var loop = CacheFirstLoop.init(alloc, .{
        .prefix = prefix,
        .context = &ctx,
        .reasonix = &reasonix,
        .io = io,
    });
    defer loop.deinit();

    try std.testing.expectEqual(@as(u32, 0), loop.budget.cache_hits);
    try std.testing.expectEqual(@as(u32, 0), loop.budget.cache_misses);
}
