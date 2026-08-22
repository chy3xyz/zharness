const std = @import("std");
const builtin = @import("builtin");
const array_list = std.array_list;

const error_mod = @import("error.zig");
const ZeepError = error_mod.ZeepError;

/// Source-level default DeepSeek API key. Resolution order:
/// 1. `/apikey` command (persisted to ~/.zeepseek/apikey)
/// 2. DEEPSEEK_API_KEY environment variable
/// 3. ~/.zeepseek/apikey file
/// 4. This constant (final fallback so the app works out of the box)
pub const DEFAULT_DEEPSEEK_API_KEY: []const u8 = "sk-bcca3074de084ebea039e08b2ec0a09b";

pub const ModelType = enum {
    deepseek_chat,
    deepseek_coder,
    deepseek_v4_pro,
    deepseek_v4_flash,
    deepseek_flash,
    auto,

    pub fn apiName(self: ModelType) []const u8 {
        return switch (self) {
            .deepseek_chat => "deepseek-chat",
            .deepseek_coder => "deepseek-coder",
            .deepseek_v4_pro => "deepseek-v4-pro",
            .deepseek_v4_flash => "deepseek-v4-flash",
            .deepseek_flash => "deepseek-flash",
            .auto => "deepseek-chat",
        };
    }

    pub fn fromApiName(name: []const u8) ModelType {
        if (std.mem.eql(u8, name, "deepseek-coder")) return .deepseek_coder;
        if (std.mem.eql(u8, name, "deepseek-v4-pro")) return .deepseek_v4_pro;
        if (std.mem.eql(u8, name, "deepseek-v4-flash")) return .deepseek_v4_flash;
        if (std.mem.eql(u8, name, "deepseek-flash")) return .deepseek_flash;
        return .deepseek_chat;
    }

    pub fn contextWindow(self: ModelType) u32 {
        return switch (self) {
            .deepseek_chat => 64000,
            .deepseek_coder => 128000,
            .deepseek_v4_pro => 256000,
            .deepseek_v4_flash => 256000,
            .deepseek_flash => 64000,
            .auto => 64000,
        };
    }

    pub fn supportsStreaming(_: ModelType) bool {
        return true;
    }

    pub fn supportsCache(self: ModelType) bool {
        return switch (self) {
            .deepseek_chat, .deepseek_coder, .deepseek_v4_pro, .deepseek_v4_flash, .deepseek_flash => true,
            .auto => false,
        };
    }

    pub fn supportsFunctions(_: ModelType) bool {
        return true;
    }

    pub fn isReasoningEnabled(self: ModelType) bool {
        return switch (self) {
            .deepseek_coder, .deepseek_v4_pro, .deepseek_v4_flash => true,
            else => false,
        };
    }

    pub fn costPerMtok(self: ModelType) CostTier {
        return switch (self) {
            .deepseek_chat => .{ .input = 0.27, .output = 1.10 },
            .deepseek_coder => .{ .input = 0.55, .output = 2.20 },
            .deepseek_v4_pro => .{ .input = 1.10, .output = 3.50 },
            .deepseek_v4_flash => .{ .input = 0.55, .output = 1.10 },
            .deepseek_flash => .{ .input = 0.10, .output = 0.50 },
            .auto => .{ .input = 0.27, .output = 1.10 },
        };
    }
};

pub const CostTier = struct {
    input: f64,
    output: f64,
};

pub const ReasoningEffort = enum {
    off,
    low,
    medium,
    high,
    auto,
};

pub const ModelSelection = struct {
    model: ModelType,
    reasoning_effort: ReasoningEffort,
};

pub fn selectModelForTask(task_description: []const u8, context_size_hint: usize) ModelSelection {
    var buf: [1024]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, task_description);
    defer {
        if (lower.ptr != &buf) {
            std.heap.page_allocator.free(lower);
        }
    }

    const is_code_task = std.mem.indexOf(u8, lower, "code") != null or
        std.mem.indexOf(u8, lower, "bug") != null or
        std.mem.indexOf(u8, lower, "refactor") != null or
        std.mem.indexOf(u8, lower, "implement") != null or
        std.mem.indexOf(u8, lower, "function") != null or
        std.mem.indexOf(u8, lower, "test ") != null;

    const is_simple_question = context_size_hint < 500 and
        (std.mem.indexOf(u8, lower, "what ") != null or
            std.mem.indexOf(u8, lower, "how ") != null or
            std.mem.indexOf(u8, lower, "define") != null);

    if (is_simple_question and !is_code_task) {
        return .{ .model = .deepseek_flash, .reasoning_effort = .off };
    }

    if (is_code_task) {
        if (context_size_hint > 100000) {
            return .{ .model = .deepseek_coder, .reasoning_effort = .high };
        }
        return .{ .model = .deepseek_coder, .reasoning_effort = .medium };
    }

    if (context_size_hint > 50000) {
        return .{ .model = .deepseek_chat, .reasoning_effort = .high };
    }

    return .{ .model = .deepseek_chat, .reasoning_effort = .auto };
}

pub const ProviderEntry = struct {
    id: []const u8,
    api_key: []const u8,
    base_url: ?[]const u8 = null,
    default_model: []const u8,
};

pub const ProviderConfig = struct {
    providers: []ProviderEntry = &.{},
    active_provider: []const u8 = "deepseek",
};

pub const CacheConfig = struct {
    max_memory_bytes: comptime_int = 16 * 1024 * 1024,
    fold_threshold: f64 = 0.5,
    fold_aggressive_threshold: f64 = 0.7,
    fold_exit_threshold: f64 = 0.8,
    emergency_threshold: f64 = 0.95,
    emergency_target: f64 = 0.7,
    ttl_system_seconds: u64 = 0,
    ttl_shared_seconds: u64 = 86400,
    ttl_temp_seconds: u64 = 300,
};

pub const NetworkConfig = struct {
    base_url: []const u8 = "https://api.deepseek.com",
    rpm_limit: u32 = 60,
    connect_timeout_ms: u32 = 10000,
    request_timeout_ms: u32 = 660000,
    max_retries: u32 = 3,
    max_connections: u32 = 32,
};

pub const AgentConfig = struct {
    max_concurrent: u32 = 10,
    default_role: []const u8 = "general",
};

pub const StorageConfig = struct {
    data_dir: []const u8 = "",
};

pub const Config = struct {
    cache: CacheConfig = .{},
    network: NetworkConfig = .{},
    agents: AgentConfig = .{},
    storage: StorageConfig = .{},
    providers: ProviderConfig = .{},
    default_model: ModelType = .deepseek_chat,
};

pub fn resolveApiKey() error_mod.ZeepError![]const u8 {
    if (std.c.getenv("DEEPSEEK_API_KEY")) |key| {
        return std.mem.sliceTo(key, 0);
    }
    if (std.c.getenv("OPENAI_API_KEY")) |key| {
        return std.mem.sliceTo(key, 0);
    }
    if (std.c.getenv("OPENROUTER_API_KEY")) |key| {
        return std.mem.sliceTo(key, 0);
    }
    if (std.c.getenv("NVIDIA_API_KEY")) |key| {
        return std.mem.sliceTo(key, 0);
    }
    if (std.c.getenv("ANTHROPIC_API_KEY")) |key| {
        return std.mem.sliceTo(key, 0);
    }
    if (std.c.getenv("GOOGLE_API_KEY")) |key| {
        return std.mem.sliceTo(key, 0);
    }
    return DEFAULT_DEEPSEEK_API_KEY;
}

pub fn resolveApiKeyForProvider(provider_id: []const u8) error_mod.ZeepError![]const u8 {
    const env_var = switch (provider_id[0]) {
        'd' => if (std.mem.eql(u8, provider_id, "deepseek")) "DEEPSEEK_API_KEY" else null,
        'o' => if (std.mem.eql(u8, provider_id, "openai")) "OPENAI_API_KEY" else if (std.mem.eql(u8, provider_id, "openrouter")) "OPENROUTER_API_KEY" else null,
        'n' => if (std.mem.eql(u8, provider_id, "nvidia")) "NVIDIA_API_KEY" else null,
        'a' => if (std.mem.eql(u8, provider_id, "anthropic")) "ANTHROPIC_API_KEY" else null,
        'g' => if (std.mem.eql(u8, provider_id, "gemini")) "GOOGLE_API_KEY" else null,
        else => null,
    };

    if (env_var) |env| {
        if (std.c.getenv(env)) |key| {
            return std.mem.sliceTo(key, 0);
        }
    }

    if (std.c.getenv("DEEPSEEK_API_KEY")) |key| {
        return std.mem.sliceTo(key, 0);
    }
    if (std.c.getenv("OPENAI_API_KEY")) |key| {
        return std.mem.sliceTo(key, 0);
    }

    return error_mod.ZeepError.ApiKeyMissing;
}

pub fn getDataDir(alloc: std.mem.Allocator) ![]const u8 {
    if (comptime builtin.target.os.tag == .windows) {
        return try std.fs.getAppDataDir(alloc, "zeepseek");
    } else if (comptime builtin.target.os.tag == .macos) {
        const home_ptr = std.c.getenv("HOME") orelse return error.InvalidConfig;
        const home = std.mem.sliceTo(home_ptr, 0);
        return try std.fs.path.join(alloc, &.{ home, "Library", "Application Support", "zeepseek" });
    } else {
        const home_ptr = std.c.getenv("HOME") orelse return error.InvalidConfig;
        const home = std.mem.sliceTo(home_ptr, 0);
        return try std.fs.path.join(alloc, &.{ home, ".local", "share", "zeepseek" });
    }
}

pub fn loadConfig(alloc: std.mem.Allocator) !Config {
    const data_dir = try getDataDir(alloc);
    defer alloc.free(data_dir);

    const config_path = try std.fs.path.join(alloc, &.{ data_dir, "config.toml" });
    defer alloc.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return Config{};
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 4096);
    defer alloc.free(content);

    var result = Config{};
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "fold_threshold=")) {
            const val_str = trimmed[15..];
            result.cache.fold_threshold = std.fmt.parseFloat(f64, val_str) catch result.cache.fold_threshold;
        } else if (std.mem.startsWith(u8, trimmed, "fold_aggressive_threshold=")) {
            const val_str = trimmed[25..];
            result.cache.fold_aggressive_threshold = std.fmt.parseFloat(f64, val_str) catch result.cache.fold_aggressive_threshold;
        } else if (std.mem.startsWith(u8, trimmed, "rpm_limit=")) {
            const val_str = trimmed[10..];
            result.network.rpm_limit = std.fmt.parseInt(u32, val_str, 10) catch result.network.rpm_limit;
        } else if (std.mem.startsWith(u8, trimmed, "max_concurrent=")) {
            const val_str = trimmed[15..];
            result.agents.max_concurrent = std.fmt.parseInt(u32, val_str, 10) catch result.agents.max_concurrent;
        }
    }

    return result;
}

pub fn saveConfig(alloc: std.mem.Allocator, config: *const Config) !void {
    const data_dir = try getDataDir(alloc);
    defer alloc.free(data_dir);

    std.fs.makeDirAbsolute(data_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const config_path = try std.fs.path.join(alloc, &.{ data_dir, "config.toml" });
    defer alloc.free(config_path);

    var content = array_list.AlignedManaged(u8, null).init(alloc);
    defer content.deinit();

    try content.appendSlice(
        \\# Zeepseek Configuration
        \\
    );

    try appendConfigLine(alloc, &content, .{ .key = "fold_threshold", .value = config.cache.fold_threshold });
    try appendConfigLine(alloc, &content, .{ .key = "fold_aggressive_threshold", .value = config.cache.fold_aggressive_threshold });
    try appendConfigLine(alloc, &content, .{ .key = "rpm_limit", .value = config.network.rpm_limit });
    try appendConfigLine(alloc, &content, .{ .key = "max_concurrent", .value = config.agents.max_concurrent });

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();

    try file.writeAll(content.items);
}

fn appendConfigLine(alloc: std.mem.Allocator, content: *array_list.AlignedManaged(u8, null), key: []const u8, value: anytype) !void {
    const formatted = try std.fmt.allocPrint(alloc, "{s}={d}\n", .{ key, value });
    defer alloc.free(formatted);
    try content.appendSlice(formatted);
}

test "model type api name" {
    try std.testing.expectEqualSlices(u8, "deepseek-chat", ModelType.deepseek_chat.apiName());
    try std.testing.expectEqualSlices(u8, "deepseek-coder", ModelType.deepseek_coder.apiName());
    try std.testing.expectEqualSlices(u8, "deepseek-v4-pro", ModelType.deepseek_v4_pro.apiName());
    try std.testing.expectEqualSlices(u8, "deepseek-v4-flash", ModelType.deepseek_v4_flash.apiName());
    try std.testing.expectEqualSlices(u8, "deepseek-flash", ModelType.deepseek_flash.apiName());
    try std.testing.expectEqualSlices(u8, "deepseek-chat", ModelType.auto.apiName());
}

test "model type context window" {
    try std.testing.expectEqual(@as(u32, 64000), ModelType.deepseek_chat.contextWindow());
    try std.testing.expectEqual(@as(u32, 128000), ModelType.deepseek_coder.contextWindow());
    try std.testing.expectEqual(@as(u32, 256000), ModelType.deepseek_v4_pro.contextWindow());
    try std.testing.expectEqual(@as(u32, 256000), ModelType.deepseek_v4_flash.contextWindow());
    try std.testing.expectEqual(@as(u32, 64000), ModelType.deepseek_flash.contextWindow());
}

test "model type from api name" {
    try std.testing.expectEqual(ModelType.deepseek_chat, ModelType.fromApiName("deepseek-chat"));
    try std.testing.expectEqual(ModelType.deepseek_coder, ModelType.fromApiName("deepseek-coder"));
    try std.testing.expectEqual(ModelType.deepseek_v4_pro, ModelType.fromApiName("deepseek-v4-pro"));
    try std.testing.expectEqual(ModelType.deepseek_v4_flash, ModelType.fromApiName("deepseek-v4-flash"));
    try std.testing.expectEqual(ModelType.deepseek_flash, ModelType.fromApiName("deepseek-flash"));
    try std.testing.expectEqual(ModelType.deepseek_chat, ModelType.fromApiName("unknown-model"));
}

test "model type supports cache" {
    try std.testing.expect(ModelType.deepseek_chat.supportsCache());
    try std.testing.expect(ModelType.deepseek_coder.supportsCache());
    try std.testing.expect(ModelType.deepseek_v4_pro.supportsCache());
    try std.testing.expect(ModelType.deepseek_v4_flash.supportsCache());
    try std.testing.expect(ModelType.deepseek_flash.supportsCache());
    try std.testing.expect(!ModelType.auto.supportsCache());
}

test "model type is reasoning enabled" {
    try std.testing.expect(!ModelType.deepseek_chat.isReasoningEnabled());
    try std.testing.expect(ModelType.deepseek_coder.isReasoningEnabled());
    try std.testing.expect(ModelType.deepseek_v4_pro.isReasoningEnabled());
    try std.testing.expect(ModelType.deepseek_v4_flash.isReasoningEnabled());
    try std.testing.expect(!ModelType.deepseek_flash.isReasoningEnabled());
}

test "model type cost per mtok" {
    const chat_cost = ModelType.deepseek_chat.costPerMtok();
    try std.testing.expectEqual(@as(f64, 0.27), chat_cost.input);
    try std.testing.expectEqual(@as(f64, 1.10), chat_cost.output);

    const flash_cost = ModelType.deepseek_flash.costPerMtok();
    try std.testing.expectEqual(@as(f64, 0.10), flash_cost.input);
    try std.testing.expectEqual(@as(f64, 0.50), flash_cost.output);
}

test "select model for task code" {
    const sel = selectModelForTask("write code for me", 1000);
    try std.testing.expectEqual(ModelType.deepseek_coder, sel.model);
}

test "select model for task bug" {
    const sel = selectModelForTask("fix this bug", 500);
    try std.testing.expectEqual(ModelType.deepseek_coder, sel.model);
}

test "select model for task simple question" {
    const sel = selectModelForTask("what is zig", 100);
    try std.testing.expectEqual(ModelType.deepseek_flash, sel.model);
    try std.testing.expectEqual(ReasoningEffort.off, sel.reasoning_effort);
}

test "select model for task long context" {
    const sel = selectModelForTask("analyze this text", 60000);
    try std.testing.expectEqual(ModelType.deepseek_chat, sel.model);
    try std.testing.expectEqual(ReasoningEffort.high, sel.reasoning_effort);
}

test "select model for task default" {
    const sel = selectModelForTask("tell me about programming", 5000);
    try std.testing.expectEqual(ModelType.deepseek_chat, sel.model);
    try std.testing.expectEqual(ReasoningEffort.auto, sel.reasoning_effort);
}

test "select model for task high context coder" {
    const sel = selectModelForTask("implement this feature", 150000);
    try std.testing.expectEqual(ModelType.deepseek_coder, sel.model);
    try std.testing.expectEqual(ReasoningEffort.high, sel.reasoning_effort);
}
