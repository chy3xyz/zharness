const std = @import("std");
const Provider = @import("mod.zig").Provider;

pub const ModelFamily = enum {
    deepseek,
    gpt4,
    gpt35,
    claude,
    gemini,
    llama,
    mistral,
    mixtral,
    qwen,
    custom,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8,
    family: ModelFamily,
    context_window: u32,
    supports_cache: bool,
    supports_streaming: bool,
    supports_functions: bool,
    input_cost_per_1m: f64,
    output_cost_per_1m: f64,
    cache_discount: f64,

    pub fn estimatedCost(self: Model, input_tokens: u32, output_tokens: u32, cache_hit_ratio: f64) f64 {
        const input_cost = @as(f64, @floatFromInt(input_tokens)) * self.input_cost_per_1m / 1_000_000.0;
        const output_cost = @as(f64, @floatFromInt(output_tokens)) * self.output_cost_per_1m / 1_000_000.0;

        if (self.supports_cache and cache_hit_ratio > 0.0) {
            const cached_ratio = cache_hit_ratio;
            const uncached_ratio = 1.0 - cached_ratio;
            const effective_input = input_cost * (cached_ratio * self.cache_discount + uncached_ratio);
            return effective_input + output_cost;
        }
        return input_cost + output_cost;
    }
};

pub const model_catalog = [_]Model{
    .{
        .id = "deepseek-chat",
        .name = "DeepSeek Chat",
        .provider = "deepseek",
        .family = .deepseek,
        .context_window = 64000,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.27,
        .output_cost_per_1m = 1.10,
        .cache_discount = 0.10,
    },
    .{
        .id = "deepseek-coder",
        .name = "DeepSeek Coder",
        .provider = "deepseek",
        .family = .deepseek,
        .context_window = 160000,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.27,
        .output_cost_per_1m = 1.10,
        .cache_discount = 0.10,
    },
    .{
        .id = "deepseek-v4-pro",
        .name = "DeepSeek V4 Pro",
        .provider = "deepseek",
        .family = .deepseek,
        .context_window = 256000,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 1.10,
        .output_cost_per_1m = 3.50,
        .cache_discount = 0.10,
    },
    .{
        .id = "deepseek-v4-flash",
        .name = "DeepSeek V4 Flash",
        .provider = "deepseek",
        .family = .deepseek,
        .context_window = 256000,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.55,
        .output_cost_per_1m = 1.10,
        .cache_discount = 0.10,
    },
    .{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .provider = "openai",
        .family = .gpt4,
        .context_window = 128000,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 5.00,
        .output_cost_per_1m = 15.00,
        .cache_discount = 0.10,
    },
    .{
        .id = "gpt-4o-mini",
        .name = "GPT-4o Mini",
        .provider = "openai",
        .family = .gpt4,
        .context_window = 128000,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.15,
        .output_cost_per_1m = 0.60,
        .cache_discount = 0.10,
    },
    .{
        .id = "gpt-4-turbo",
        .name = "GPT-4 Turbo",
        .provider = "openai",
        .family = .gpt4,
        .context_window = 128000,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 10.00,
        .output_cost_per_1m = 30.00,
        .cache_discount = 0.10,
    },
    .{
        .id = "gpt-3.5-turbo",
        .name = "GPT-3.5 Turbo",
        .provider = "openai",
        .family = .gpt35,
        .context_window = 16385,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.50,
        .output_cost_per_1m = 1.50,
        .cache_discount = 0.10,
    },
    .{
        .id = "claude-3-5-sonnet",
        .name = "Claude 3.5 Sonnet",
        .provider = "anthropic",
        .family = .claude,
        .context_window = 200000,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = false,
        .input_cost_per_1m = 3.00,
        .output_cost_per_1m = 15.00,
        .cache_discount = 0.10,
    },
    .{
        .id = "claude-3-opus",
        .name = "Claude 3 Opus",
        .provider = "anthropic",
        .family = .claude,
        .context_window = 200000,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = false,
        .input_cost_per_1m = 15.00,
        .output_cost_per_1m = 75.00,
        .cache_discount = 0.10,
    },
    .{
        .id = "gemini-1.5-pro",
        .name = "Gemini 1.5 Pro",
        .provider = "gemini",
        .family = .gemini,
        .context_window = 1000000,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 1.25,
        .output_cost_per_1m = 5.00,
        .cache_discount = 0.50,
    },
    .{
        .id = "gemini-1.5-flash",
        .name = "Gemini 1.5 Flash",
        .provider = "gemini",
        .family = .gemini,
        .context_window = 1000000,
        .supports_cache = true,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.075,
        .output_cost_per_1m = 0.30,
        .cache_discount = 0.50,
    },
    .{
        .id = "llama-3.1-70b",
        .name = "Llama 3.1 70B",
        .provider = "openrouter",
        .family = .llama,
        .context_window = 128000,
        .supports_cache = false,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.65,
        .output_cost_per_1m = 2.75,
        .cache_discount = 0.0,
    },
    .{
        .id = "llama-3.1-8b",
        .name = "Llama 3.1 8B",
        .provider = "openrouter",
        .family = .llama,
        .context_window = 128000,
        .supports_cache = false,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.20,
        .output_cost_per_1m = 0.20,
        .cache_discount = 0.0,
    },
    .{
        .id = "mixtral-8x7b",
        .name = "Mixtral 8x7B",
        .provider = "openrouter",
        .family = .mixtral,
        .context_window = 32000,
        .supports_cache = false,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.24,
        .output_cost_per_1m = 0.24,
        .cache_discount = 0.0,
    },
    .{
        .id = "mistral-large",
        .name = "Mistral Large",
        .provider = "openrouter",
        .family = .mistral,
        .context_window = 128000,
        .supports_cache = false,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 2.00,
        .output_cost_per_1m = 6.00,
        .cache_discount = 0.0,
    },
    .{
        .id = "qwen-2.5-72b",
        .name = "Qwen 2.5 72B",
        .provider = "openrouter",
        .family = .qwen,
        .context_window = 32768,
        .supports_cache = false,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.90,
        .output_cost_per_1m = 0.90,
        .cache_discount = 0.0,
    },
    .{
        .id = "nvidia/llama-3.1-nemotron-70b",
        .name = "NVIDIA Llama 3.1 Nemotron 70B",
        .provider = "nvidia",
        .family = .llama,
        .context_window = 128000,
        .supports_cache = false,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.00,
        .output_cost_per_1m = 0.00,
        .cache_discount = 0.0,
    },
    .{
        .id = "groq/llama-3.3-70b",
        .name = "Groq Llama 3.3 70B",
        .provider = "groq",
        .family = .llama,
        .context_window = 128000,
        .supports_cache = false,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.00,
        .output_cost_per_1m = 0.59,
        .cache_discount = 0.0,
    },
    .{
        .id = "groq/mixtral-8x7b",
        .name = "Groq Mixtral 8x7B",
        .provider = "groq",
        .family = .mixtral,
        .context_window = 32000,
        .supports_cache = false,
        .supports_streaming = true,
        .supports_functions = true,
        .input_cost_per_1m = 0.00,
        .output_cost_per_1m = 0.24,
        .cache_discount = 0.0,
    },
};

pub fn findModel(id: []const u8) ?Model {
    inline for (model_catalog) |m| {
        if (std.mem.eql(u8, m.id, id)) {
            return m;
        }
    }
    return null;
}

pub fn listModelsByProvider(provider_id: []const u8) []const Model {
    var result: [model_catalog.len]Model = undefined;
    var count: usize = 0;

    inline for (model_catalog) |m| {
        if (std.mem.eql(u8, m.provider, provider_id)) {
            result[count] = m;
            count += 1;
        }
    }

    return result[0..count];
}

pub fn estimateCost(model: Model, input_tokens: u32, output_tokens: u32, cache_hit_ratio: f64) f64 {
    return model.estimatedCost(input_tokens, output_tokens, cache_hit_ratio);
}
