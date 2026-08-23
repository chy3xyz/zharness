//! zharness configuration.
//!
//! Loads model/provider/api-key/workspace settings from environment and an
//! optional `~/.zharness/config.toml`. Kept minimal — the runtime resolves a
//! provider by id and an endpoint, then the model layer talks to it.
//!
//! Environment keys (dev.md §VI provider matrix):
//!   ZHARNESS_API_KEY   global harness credential — wins for EVERY provider
//!   DEEPSEEK_API_KEY   DeepSeek fallback when the global key is unset
//!   ANTHROPIC_API_KEY  Anthropic credential (swapped in by applyOverrides
//!                      when the anthropic/claude provider is selected,
//!                      unless the global key is present)
//!   OLLAMA_HOST        Ollama server host[:port][/path] or full URL;
//!                      becomes http://<host>/v1/chat/completions
//!   ZHARNESS_ENDPOINT  explicit endpoint override (testability/gateways)
//!   ZHARNESS_CWD       workspace override
//!
//! Endpoint precedence (highest last): --provider default <
//! ZHARNESS_ENDPOINT at load < explicit endpoint argument to applyOverrides.

const std = @import("std");
const providers = @import("model/provider.zig");
const ollama = @import("model/ollama.zig");

pub const ProviderProfile = providers.ProviderProfile;

/// Historical default model — used to detect "the user never picked a model"
/// so a provider switch can install that provider's own default.
pub const default_model = "deepseek-v4-flash";

pub const Config = struct {
    alloc: std.mem.Allocator,
    provider: []const u8 = "deepseek",
    model: []const u8 = default_model,
    api_key: []const u8 = "",
    endpoint: []const u8 = "https://api.deepseek.com/chat/completions",
    reasoning_effort: []const u8 = "medium",
    stream: bool = true,
    cwd: []const u8 = ".",
    max_turns: usize = 64,
    sandbox_mode: SandboxMode = .process,

    /// Anthropic credential from ANTHROPIC_API_KEY ("" when absent).
    anthropic_key: []const u8 = "",
    /// Raw OLLAMA_HOST value ("" when absent); consumed on provider switch.
    ollama_host: []const u8 = "",
    /// True when the active api_key came from ZHARNESS_API_KEY (global).
    api_key_is_global: bool = false,

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
        self.alloc.free(self.anthropic_key);
        self.alloc.free(self.ollama_host);
    }

    /// Apply CLI overrides (e.g. --model, --provider, --no-stream). Existing
    /// three-argument callers compile unchanged; see `applyOverridesFull`
    /// for the per-provider --endpoint support.
    pub fn applyOverrides(
        self: *Config,
        model: ?[]const u8,
        provider: ?[]const u8,
        no_stream: bool,
    ) !void {
        return self.applyOverridesFull(.{ .model = model, .provider = provider, .no_stream = no_stream });
    }

    pub const Overrides = struct {
        model: ?[]const u8 = null,
        provider: ?[]const u8 = null,
        no_stream: bool = false,
        /// Per-provider endpoint override (a future --endpoint flag).
        endpoint: ?[]const u8 = null,
    };

    /// Full override application.
    ///
    /// Precedence inside this function: an explicit endpoint beats the
    /// provider default; the provider default beats anything loaded from
    /// ZHARNESS_ENDPOINT (historical behaviour, documented at load()).
    pub fn applyOverridesFull(self: *Config, o: Overrides) !void {
        const a = self.alloc;
        if (o.model) |mo| {
            a.free(self.model);
            self.model = try a.dupe(u8, mo);
        }
        if (o.provider) |p| {
            a.free(self.provider);
            self.provider = try a.dupe(u8, p);

            // Default endpoint for the named provider. Known profiles may
            // refine it (Ollama host override); unknown spellings keep the
            // legacy permissive table (e.g. "openrouter") untouched.
            var ep: []const u8 = providerEndpoint(p);
            var owned_ep: ?[]u8 = null;
            defer if (owned_ep) |own| a.free(own);

            if (providers.Provider.fromString(p)) |prov| {
                const prof = providers.profile(prov);
                ep = prof.endpoint;
                switch (prov) {
                    .ollama => {
                        if (self.ollama_host.len > 0) {
                            owned_ep = try ollama.endpointFromHost(a, self.ollama_host);
                            ep = owned_ep.?;
                        }
                        // Ollama needs no credentials, but callers gate on a
                        // non-empty key before building a client; use an
                        // inert placeholder (no header is emitted anyway).
                        if (self.api_key.len == 0) {
                            a.free(self.api_key);
                            self.api_key = try a.dupe(u8, "ollama-local");
                        }
                    },
                    .anthropic => {
                        // Per-provider key wins unless the GLOBAL harness key
                        // was set explicitly (ZHARNESS_API_KEY precedence).
                        if (self.anthropic_key.len > 0 and
                            !(self.api_key_is_global and self.api_key.len > 0))
                        {
                            a.free(self.api_key);
                            self.api_key = try a.dupe(u8, self.anthropic_key);
                        }
                    },
                    else => {},
                }
                // First switch away from a stock model installs the
                // provider's own default (a user-pinned --model always wins
                // because it lands in the branch above).
                if (o.model == null and std.mem.eql(u8, self.model, default_model)) {
                    a.free(self.model);
                    self.model = try a.dupe(u8, prof.default_model);
                }
            }

            a.free(self.endpoint);
            self.endpoint = try a.dupe(u8, ep);
        }
        if (o.endpoint) |e| {
            a.free(self.endpoint);
            self.endpoint = try a.dupe(u8, e);
        }
        if (o.no_stream) self.stream = false;
    }

    /// Resolved profile for the CURRENT provider string with this config's
    /// endpoint layered on top. Null for legacy permissive spellings the
    /// matrix does not know (e.g. "openrouter") — those stay plain
    /// OpenAI-style clients. This plus ChatClient.initProvider is the whole
    /// provider-selection story:
    ///
    ///   var client = if (cfg.resolvedProfile()) |prof|
    ///       model.ChatClient.initProvider(alloc, io, prof, cfg.model, cfg.api_key)
    ///   else
    ///       model.ChatClient.init(alloc, io, cfg.endpoint, cfg.model, cfg.api_key);
    pub fn resolvedProfile(self: *const Config) ?ProviderProfile {
        const p = providers.Provider.fromString(self.provider) orelse return null;
        var prof = providers.profile(p);
        prof.endpoint = self.endpoint; // explicit/env override already applied
        return prof;
    }
};

/// Injectable environment snapshot so config behaviour is testable offline.
/// load() fills it from libc getenv; tests pass literals.
pub const EnvSnapshot = struct {
    zharness_api_key: ?[]const u8 = null,
    deepseek_api_key: ?[]const u8 = null,
    anthropic_api_key: ?[]const u8 = null,
    ollama_host: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

fn optSpan(p: ?[*:0]const u8) ?[]const u8 {
    const ptr = p orelse return null;
    const s = std.mem.span(ptr);
    return if (s.len > 0) s else null;
}

/// Resolve credentials and defaults. API key precedence:
///   1. ZHARNESS_API_KEY / DEEPSEEK_API_KEY env (global first)
///   2. ~/.zharness/config.toml [model] api_key (not read yet)
/// Per-provider keys land in dedicated fields and are swapped in by
/// applyOverrides when their provider is selected.
pub fn load(alloc: std.mem.Allocator) !Config {
    return loadFromSnapshot(alloc, .{
        .zharness_api_key = optSpan(std.c.getenv("ZHARNESS_API_KEY")),
        .deepseek_api_key = optSpan(std.c.getenv("DEEPSEEK_API_KEY")),
        .anthropic_api_key = optSpan(std.c.getenv("ANTHROPIC_API_KEY")),
        .ollama_host = optSpan(std.c.getenv("OLLAMA_HOST")),
        .endpoint = optSpan(std.c.getenv("ZHARNESS_ENDPOINT")),
        .cwd = optSpan(std.c.getenv("ZHARNESS_CWD")),
    });
}

/// Pure core of load(): same result, environment supplied by the caller.
pub fn loadFromSnapshot(alloc: std.mem.Allocator, env: EnvSnapshot) !Config {
    var cfg = Config{ .alloc = alloc };

    // Provider defaults.
    cfg.provider = try alloc.dupe(u8, "deepseek");
    cfg.model = try alloc.dupe(u8, default_model);
    cfg.endpoint = try alloc.dupe(u8, "https://api.deepseek.com/chat/completions");
    cfg.reasoning_effort = try alloc.dupe(u8, "medium");
    cfg.cwd = try alloc.dupe(u8, ".");

    // API key from the snapshot (dupe immediately; snapshots may be stack
    // literals in tests).
    if (env.zharness_api_key) |k| {
        cfg.api_key = try alloc.dupe(u8, k);
        cfg.api_key_is_global = true;
    } else if (env.deepseek_api_key) |k| {
        cfg.api_key = try alloc.dupe(u8, k);
    } else {
        cfg.api_key = try alloc.dupe(u8, "");
    }
    cfg.anthropic_key = try alloc.dupe(u8, env.anthropic_api_key orelse "");
    cfg.ollama_host = try alloc.dupe(u8, env.ollama_host orelse "");

    // Workspace cwd: honor ZHARNESS_CWD, else process cwd.
    if (env.cwd) |cwd| {
        alloc.free(cfg.cwd);
        cfg.cwd = try alloc.dupe(u8, cwd);
    }

    // Endpoint override (testability + self-hosted gateways): applied after
    // provider defaults so an explicit ZHARNESS_ENDPOINT always wins there.
    // An explicit --provider later still resets it (documented precedence).
    if (env.endpoint) |ep| {
        alloc.free(cfg.endpoint);
        cfg.endpoint = try alloc.dupe(u8, ep);
    }

    return cfg;
}

fn providerEndpoint(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "openai")) return "https://api.openai.com/v1/chat/completions";
    if (std.mem.eql(u8, provider, "ollama")) return "http://localhost:11434/v1/chat/completions";
    if (std.mem.eql(u8, provider, "openrouter")) return "https://openrouter.ai/api/v1/chat/completions";
    return "https://api.deepseek.com/chat/completions";
}
