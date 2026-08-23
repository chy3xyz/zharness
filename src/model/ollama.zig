//! Ollama profile (dev.md §VI): a local Ollama server speaks OpenAI's
//! `/v1/chat/completions` dialect, so it reuses the existing `ChatClient`
//! transport UNCHANGED — no new wire code, just defaults:
//!
//!   - endpoint  http://localhost:11434/v1/chat/completions
//!               (overridable via the OLLAMA_HOST env var, see
//!               config.zig / endpointFromHost)
//!   - auth      none: Ollama ignores Authorization headers, so the profile
//!               carries `.none` and ChatClient emits no credential header.
//!   - streaming works exactly as on DeepSeek (SSE path is shared).
//!
//! Nothing here talks to the network; everything is offline-pure.

const std = @import("std");
const model = @import("model.zig");
const providers = @import("provider.zig");

pub const default_host = "localhost:11434";
pub const default_endpoint = "http://localhost:11434/v1/chat/completions";

/// Normalize an `OLLAMA_HOST` value into a full chat-completions URL.
/// Accepted shapes: "host:port", "127.0.0.1:11434", "http://host:port",
/// "https://host" — trailing slashes are trimmed. Empty input falls back to
/// the default local endpoint. Caller frees.
pub fn endpointFromHost(alloc: std.mem.Allocator, host: []const u8) ![]u8 {
    const h = std.mem.trim(u8, host, " \t\r\n/");
    if (h.len == 0) return alloc.dupe(u8, default_endpoint);
    const base = if (std.mem.startsWith(u8, h, "http://") or std.mem.startsWith(u8, h, "https://"))
        h
    else
        try std.fmt.allocPrint(alloc, "http://{s}", .{h});
    defer if (base.ptr != h.ptr) alloc.free(base);
    return std.fmt.allocPrint(alloc, "{s}/v1/chat/completions", .{base});
}

/// Convenience constructor proving the "thin profile over the existing
/// client" story: this is plain `ChatClient.initProvider` with the Ollama
/// defaults filled in (empty key — `.none` auth emits no header anyway).
///
/// Ownership follows the usual ChatClient convention: `endpoint_override`
/// (when given) is BORROWED and must outlive the client, like every other
/// slice stored on ChatClient. Pass null for the local default.
pub fn initClient(
    alloc: std.mem.Allocator,
    io: std.Io,
    model_name: []const u8,
    endpoint_override: ?[]const u8,
) model.ChatClient {
    var p = providers.profile(.ollama);
    if (endpoint_override) |e| p.endpoint = e;
    return model.ChatClient.initProvider(
        alloc,
        io,
        p,
        model_name,
        "", // no credentials on a local server
    );
}

test "endpointFromHost normalizes host spellings" {
    const alloc = std.testing.allocator;
    const cases = .{
        .{ "", default_endpoint },
        .{ "   ", default_endpoint },
        .{ "192.168.1.5:11434", "http://192.168.1.5:11434/v1/chat/completions" },
        .{ "http://box.lan:11434", "http://box.lan:11434/v1/chat/completions" },
        .{ "https://ollama.corp/", "https://ollama.corp/v1/chat/completions" },
    };
    inline for (cases) |c| {
        const got = try endpointFromHost(alloc, c[0]);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "initClient wires the ollama profile onto the shared client" {
    const alloc = std.testing.allocator;
    // io is unused by construction-time code paths; tests never call chat().
    const client = initClient(alloc, undefined, "llama3", "http://127.0.0.1:11434/v1/chat/completions");
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1/chat/completions", client.endpoint);
    try std.testing.expectEqualStrings("llama3", client.model);
    try std.testing.expectEqualStrings("", client.api_key);
    try std.testing.expectEqual(providers.AuthStyle.none, client.auth_style);
    try std.testing.expectEqual(providers.WireFormat.openai_chat, client.wire_format);

    // No override → local default endpoint.
    const local = initClient(alloc, undefined, "", null);
    try std.testing.expectEqualStrings(default_endpoint, local.endpoint);
    try std.testing.expectEqualStrings(providers.profile(.ollama).default_model, local.model);
}
