const std = @import("std");

pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    api_style: ApiStyle,
    endpoint: []const u8,
    requires_model: bool,

    pub const ApiStyle = enum {
        openai,
        deepseek,
        anthropic,
        gemini,
    };
};

pub const providers = [_]Provider{
    .{
        .id = "deepseek",
        .name = "DeepSeek",
        .api_style = .deepseek,
        .endpoint = "https://api.deepseek.com/v1",
        .requires_model = true,
    },
    .{
        .id = "deepseek-chat",
        .name = "DeepSeek Chat",
        .api_style = .deepseek,
        .endpoint = "https://api.deepseek.com/chat",
        .requires_model = true,
    },
    .{
        .id = "openai",
        .name = "OpenAI",
        .api_style = .openai,
        .endpoint = "https://api.openai.com/v1",
        .requires_model = true,
    },
    .{
        .id = "openrouter",
        .name = "OpenRouter",
        .api_style = .openai,
        .endpoint = "https://openrouter.ai/api/v1",
        .requires_model = true,
    },
    .{
        .id = "nvidia",
        .name = "NVIDIA NIM",
        .api_style = .openai,
        .endpoint = "https://integrate.api.nvidia.com/v1",
        .requires_model = true,
    },
    .{
        .id = "ollama",
        .name = "Ollama (local)",
        .api_style = .openai,
        .endpoint = "http://localhost:11434/v1",
        .requires_model = true,
    },
    .{
        .id = "groq",
        .name = "Groq",
        .api_style = .openai,
        .endpoint = "https://api.groq.com/openai/v1",
        .requires_model = true,
    },
    .{
        .id = "fireworks",
        .name = "Fireworks AI",
        .api_style = .openai,
        .endpoint = "https://api.fireworks.ai/inference/v1",
        .requires_model = true,
    },
    .{
        .id = "sglang",
        .name = "SGLang",
        .api_style = .openai,
        .endpoint = "http://localhost:8080/v1",
        .requires_model = true,
    },
    .{
        .id = "vllm",
        .name = "vLLM",
        .api_style = .openai,
        .endpoint = "http://localhost:8000/v1",
        .requires_model = true,
    },
};

pub fn findProvider(id: []const u8) ?Provider {
    inline for (providers) |p| {
        if (std.mem.eql(u8, p.id, id)) {
            return p;
        }
    }
    return null;
}

pub fn listProviders() []const Provider {
    return &providers;
}
