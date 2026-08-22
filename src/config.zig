//! zharness configuration.
//!
//! Loads model/provider/api-key/workspace settings from environment and an
//! optional `~/.zharness/config.toml`. Kept minimal — the runtime resolves a
//! provider by id and an endpoint, then the model layer talks to it.

const std = @import("std");

pub const Config = struct {
    alloc: std.mem.Allocator,
    provider: []const u8 = "deepseek",
    model: []const u8 = "deepseek-chat",
    api_key: []const u8 = "",
    endpoint: []const u8 = "https://api.deepseek.com/chat/completions",
    reasoning_effort: []const u8 = "medium",
    stream: bool = true,
    cwd: []const u8 = ".",
    max_turns: usize = 64,
    sandbox_mode: SandboxMode = .process,

    pub const SandboxMode = enum {
        native,
        process,
        none,

        pub fn fromString(s: []const u8) SandboxMode {
            if (std.mem.eql(u8, s, "native")) return .native;
            if (std.mem.eql(u8, s, "none")) return .none;
            return .process;
        }
    };

    pub fn deinit(self: *Config) void {
        self.alloc.free(self.provider);
        self.alloc.free(self.model);
        self.alloc.free(self.api_key);
        self.alloc.free(self.endpoint);
        self.alloc.free(self.reasoning_effort);
        self.alloc.free(self.cwd);
    }

    /// Apply CLI overrides (e.g. --model, --provider, --no-stream).
    pub fn applyOverrides(self: *Config, model: ?[]const u8, provider: ?[]const u8, no_stream: bool) !void {
        const a = self.alloc;
        if (model) |m| {
            a.free(self.model);
            self.model = try a.dupe(u8, m);
        }
        if (provider) |p| {
            a.free(self.provider);
            self.provider = try a.dupe(u8, p);
            // Reset endpoint to the provider default unless the caller set it.
            const ep = providerEndpoint(p);
            a.free(self.endpoint);
            self.endpoint = try a.dupe(u8, ep);
        }
        if (no_stream) self.stream = false;
    }
};

/// Resolve credentials and defaults. API key precedence:
///   1. ZHARNESS_API_KEY / DEEPSEEK_API_KEY env
///   2. ~/.zharness/config.toml [model] api_key
pub fn load(alloc: std.mem.Allocator) !Config {
    var cfg = Config{ .alloc = alloc };

    // Provider defaults.
    cfg.provider = try alloc.dupe(u8, "deepseek");
    cfg.model = try alloc.dupe(u8, "deepseek-chat");
    cfg.endpoint = try alloc.dupe(u8, "https://api.deepseek.com/chat/completions");
    cfg.reasoning_effort = try alloc.dupe(u8, "medium");
    cfg.cwd = try alloc.dupe(u8, ".");

    // API key from env (libc getenv — valid for process lifetime; we dupe it).
    var env_key: []const u8 = "";
    if (std.c.getenv("ZHARNESS_API_KEY")) |p| {
        env_key = std.mem.span(p);
    } else if (std.c.getenv("DEEPSEEK_API_KEY")) |p| {
        env_key = std.mem.span(p);
    }
    if (env_key.len > 0) {
        cfg.api_key = try alloc.dupe(u8, env_key);
    } else {
        cfg.api_key = try alloc.dupe(u8, "");
    }

    // Workspace cwd: honor ZHARNESS_CWD, else process cwd.
    if (std.c.getenv("ZHARNESS_CWD")) |p| {
        const env_cwd = std.mem.span(p);
        if (env_cwd.len > 0) {
            alloc.free(cfg.cwd);
            cfg.cwd = try alloc.dupe(u8, env_cwd);
        }
    }

    return cfg;
}

fn providerEndpoint(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "openai")) return "https://api.openai.com/v1/chat/completions";
    if (std.mem.eql(u8, provider, "ollama")) return "http://localhost:11434/v1/chat/completions";
    if (std.mem.eql(u8, provider, "openrouter")) return "https://openrouter.ai/api/v1/chat/completions";
    return "https://api.deepseek.com/chat/completions";
}
