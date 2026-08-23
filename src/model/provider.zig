//! Provider matrix (dev.md §VI): the catalog of supported backend dialects.
//!
//! Pure data + pure functions — no IO, no allocation. A `ProviderProfile` is
//! everything `ChatClient` needs to talk to a backend: the endpoint to POST
//! to, the model to request when the caller didn't pick one, how credentials
//! ride the HTTP headers (`AuthStyle`), and which wire protocol the body
//! speaks (`WireFormat`).
//!
//! Selection: `fromString` maps CLI/config spellings onto providers; unknown
//! names return null so callers can keep their legacy behaviour instead of
//! failing hard (config.zig falls back to the historical DeepSeek default).

const std = @import("std");

pub const Provider = enum {
    deepseek,
    /// Any OpenAI `/v1/chat/completions`-compatible gateway (OpenAI itself,
    /// OpenRouter, vLLM, …).
    openai_compat,
    /// Anthropic Messages API (`/v1/messages`).
    anthropic,
    /// Local Ollama server speaking its OpenAI-compatible surface.
    ollama,

    /// Parse a provider spelling. Accepted names:
    ///   deepseek | openai | openai-compat | anthropic | claude | ollama
    /// Null for anything else (unknown spellings stay the caller's problem —
    /// see config.zig, which preserves its legacy permissive fallback).
    pub fn fromString(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "deepseek")) return .deepseek;
        if (std.mem.eql(u8, s, "openai")) return .openai_compat;
        if (std.mem.eql(u8, s, "openai-compat")) return .openai_compat;
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, s, "claude")) return .anthropic;
        if (std.mem.eql(u8, s, "ollama")) return .ollama;
        return null;
    }
};

/// How credentials attach to the HTTP request.
pub const AuthStyle = enum {
    /// `Authorization: Bearer <key>` — DeepSeek, OpenAI-compatible gateways.
    bearer,
    /// `x-api-key: <key>` + `anthropic-version` header — Anthropic.
    x_api_key,
    /// No credential header at all — local Ollama.
    none,
};

/// Which JSON dialect the request/response bodies speak.
pub const WireFormat = enum {
    /// OpenAI `/v1/chat/completions` shape (DeepSeek shares it).
    openai_chat,
    /// Anthropic Messages shape: top-level `system`, content blocks,
    /// tool_use/tool_result blocks.
    anthropic_messages,
};

/// Everything a transport client needs to serve one provider. Static data —
/// endpoints/models here are defaults; callers may override either.
pub const ProviderProfile = struct {
    provider: Provider,
    /// Default endpoint (full URL including the JSON-RPC-ish resource path).
    endpoint: []const u8,
    /// Model requested when the caller didn't pin one (`--model`).
    default_model: []const u8,
    auth: AuthStyle,
    wire: WireFormat,
};

/// Anthropic requires a version tag on every request.
pub const anthropic_version = "2023-06-01";

/// The per-provider defaults. Returned slices are static — no ownership.
pub fn profile(p: Provider) ProviderProfile {
    return switch (p) {
        .deepseek => .{
            .provider = .deepseek,
            .endpoint = "https://api.deepseek.com/chat/completions",
            .default_model = "deepseek-v4-flash",
            .auth = .bearer,
            .wire = .openai_chat,
        },
        .openai_compat => .{
            .provider = .openai_compat,
            .endpoint = "https://api.openai.com/v1/chat/completions",
            .default_model = "gpt-4o-mini",
            .auth = .bearer,
            .wire = .openai_chat,
        },
        .anthropic => .{
            .provider = .anthropic,
            .endpoint = "https://api.anthropic.com/v1/messages",
            .default_model = "claude-sonnet-4-20250514",
            .auth = .x_api_key,
            .wire = .anthropic_messages,
        },
        .ollama => .{
            .provider = .ollama,
            .endpoint = "http://localhost:11434/v1/chat/completions",
            .default_model = "qwen2.5-coder",
            .auth = .none,
            .wire = .openai_chat,
        },
    };
}

test "fromString accepts the documented spellings" {
    try std.testing.expectEqual(Provider.deepseek, Provider.fromString("deepseek").?);
    try std.testing.expectEqual(Provider.openai_compat, Provider.fromString("openai").?);
    try std.testing.expectEqual(Provider.openai_compat, Provider.fromString("openai-compat").?);
    try std.testing.expectEqual(Provider.anthropic, Provider.fromString("anthropic").?);
    try std.testing.expectEqual(Provider.anthropic, Provider.fromString("claude").?);
    try std.testing.expectEqual(Provider.ollama, Provider.fromString("ollama").?);
    // Unknown spellings are rejected (caller decides the fallback).
    try std.testing.expect(Provider.fromString("openrouter") == null);
    try std.testing.expect(Provider.fromString("") == null);
    try std.testing.expect(Provider.fromString("DeepSeek") == null);
}

test "profiles carry the right dialect defaults" {
    const dp = profile(.deepseek);
    try std.testing.expectEqual(AuthStyle.bearer, dp.auth);
    try std.testing.expectEqual(WireFormat.openai_chat, dp.wire);
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", dp.endpoint);
    try std.testing.expectEqualStrings("deepseek-v4-flash", dp.default_model);

    const ap = profile(.anthropic);
    try std.testing.expectEqual(AuthStyle.x_api_key, ap.auth);
    try std.testing.expectEqual(WireFormat.anthropic_messages, ap.wire);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", ap.endpoint);

    const op = profile(.ollama);
    try std.testing.expectEqual(AuthStyle.none, op.auth);
    try std.testing.expectEqual(WireFormat.openai_chat, op.wire);
    try std.testing.expectEqualStrings("http://localhost:11434/v1/chat/completions", op.endpoint);
    try std.testing.expectEqual(WireFormat.openai_chat, profile(.openai_compat).wire);
}
