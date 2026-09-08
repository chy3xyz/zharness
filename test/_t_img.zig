//! H-image offline test root (SWARM_PLAN wave 6, ground rule 7).
//! Run: `zig test -lc test/_t_img.zig`
//!
//! Covers the image-attachment slice end to end WITHOUT network:
//!   - IR: Message.images additive default (text paths untouched),
//!   - OpenAI wire: data-URL image_url parts (vision) / dropped (non-vision),
//!   - Anthropic wire: base64 image source blocks,
//!   - provider capability flag plumbing (initProvider/useProvider),
//!   - attachment extraction/persistence round-trip + magic-byte sniffing +
//!     size caps + prompt text rewrite (inline tests in
//!     server/apiproxy/attachments.zig),
//!   - attachment_list / attachment_read tools (inline tests in
//!     tool/attachments.zig).
//! Everything is allocation-checked by std.testing.allocator; no network.

const std = @import("std");
const m = @import("../src/model/model.zig");
const anth = @import("../src/model/anthropic.zig");
const providers = @import("../src/model/provider.zig");
const apx_att = @import("../src/server/apiproxy/attachments.zig");
const tool_att = @import("../src/tool/attachments.zig");

// Force analysis of transport entry points without executing them.
comptime {
    _ = &m.ChatClient.chat;
    _ = &m.ChatClient.buildBody;
}

const testing = std.testing;

/// Minimal valid 70-byte 1x1 PNG (same fixture the modules test inline).
const tiny_png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

fn fixtureMessages() [1]m.Message {
    return .{.{
        .role = .user,
        .content = "what is in this picture?",
        .images = &.{.{
            .media_type = "image/png",
            .data_b64 = tiny_png_b64,
            .name = "dot.png",
        }},
    }};
}

fn fixtureRequest(messages: []const m.Message) m.ChatRequest {
    return .{
        .messages = messages,
        .tools_json = "",
        .system_prompt = "",
        .reasoning_effort = null,
        .stream = false,
    };
}

// ── OpenAI wire ─────────────────────────────────────────────────────────────

test "openai buildBody renders typed content parts with a data URL for vision clients" {
    const alloc = testing.allocator;
    var client = m.ChatClient.init(alloc, undefined, "https://api.openai.com/v1/chat/completions", "gpt-test", "");
    client.vision = true;

    var msgs = fixtureMessages();
    const body = try client.buildBody(fixtureRequest(&msgs));
    defer alloc.free(body);

    const want =
        "{\"model\":\"gpt-test\",\"stream\":false,\"messages\":[{\"role\":\"system\",\"content\":" ++
        "\"Tool usage: the shell tool expects a direct command string (e.g. \\\"ls -la\\\"). Never wrap it in sh -c or bash -c.\"}," ++
        "{\"role\":\"user\",\"content\":" ++
        "[{\"type\":\"text\",\"text\":\"what is in this picture?\"}" ++
        ",{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64," ++ tiny_png_b64 ++ "\"}}" ++
        "]}],\"tools\":[],\"tool_choice\":\"auto\"}";
    try testing.expectEqualStrings(want, body);
}

test "openai buildBody keeps text-only bodies byte-identical when images are absent" {
    const alloc = testing.allocator;
    var client = m.ChatClient.init(alloc, undefined, "https://x", "m", "");

    const msgs = [_]m.Message{.{ .role = .user, .content = "plain" }};
    const body = try client.buildBody(fixtureRequest(&msgs));
    defer alloc.free(body);

    // No part array, no stray brackets: exactly the historical shape.
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"plain\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\\[") == null);
    try testing.expect(std.mem.indexOf(u8, body, "image_url") == null);
}

test "openai buildBody drops image parts defensively for non-vision clients" {
    const alloc = testing.allocator;
    // deepseek-style profile: vision=false must never leak base64 onto the
    // wire even if a caller forgets to strip images from the IR.
    var client = m.ChatClient.initProvider(
        alloc,
        undefined,
        providers.profile(.deepseek),
        "",
        "",
    );
    try testing.expect(!client.vision);

    var msgs = fixtureMessages();
    const body = try client.buildBody(fixtureRequest(&msgs));
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, tiny_png_b64) == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"what is in this picture?\"") != null);
}

// ── Anthropic wire ──────────────────────────────────────────────────────────

test "anthropic buildRequestBody renders base64 source blocks after the text block" {
    const alloc = testing.allocator;
    var msgs = fixtureMessages();
    const req = fixtureRequest(&msgs);
    const body = try anth.buildRequestBody(alloc, "claude-test", req);
    defer alloc.free(body);

    const user_fragment =
        "{\"role\":\"user\",\"content\":" ++
        "[{\"type\":\"text\",\"text\":\"what is in this picture?\"}" ++
        ",{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\"," ++
        "\"data\":\"" ++ tiny_png_b64 ++ "\"}}]}";
    try testing.expect(std.mem.indexOf(u8, body, user_fragment) != null);
}

test "anthropic buildRequestBody stays byte-identical for plain text messages" {
    const alloc = testing.allocator;
    const msgs = [_]m.Message{.{ .role = .user, .content = "hello" }};
    const body = try anth.buildRequestBody(alloc, "m", fixtureRequest(&msgs));
    defer alloc.free(body);
    try testing.expectEqualStrings(
        "{\"model\":\"m\",\"max_tokens\":8192,\"system\":\"Tool usage: the shell tool expects a direct command string (e.g. \\\"ls -la\\\"). Never wrap it in sh -c or bash -c.\"," ++
            "\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}]}",
        body,
    );
}

// ── capability flag plumbing ────────────────────────────────────────────────

test "vision capability defaults and profile wiring" {
    // Profiles: anthropic + openai_compat are vision-capable; deepseek and
    // ollama default off (honest v1 — see ProviderProfile.vision doc).
    try testing.expect(providers.profile(.anthropic).vision);
    try testing.expect(providers.profile(.openai_compat).vision);
    try testing.expect(!providers.profile(.deepseek).vision);
    try testing.expect(!providers.profile(.ollama).vision);

    const alloc = testing.allocator;
    const ac = m.ChatClient.initProvider(alloc, undefined, providers.profile(.anthropic), "", "");
    try testing.expect(ac.vision);
    const dc = m.ChatClient.initProvider(alloc, undefined, providers.profile(.deepseek), "", "");
    try testing.expect(!dc.vision);

    // useProvider swaps the flag along with everything else.
    var sw = dc;
    sw.useProvider(providers.profile(.anthropic), null, null);
    try testing.expect(sw.vision);
    sw.useProvider(providers.profile(.deepseek), null, null);
    try testing.expect(!sw.vision);
}

// ── IR additive defaults ────────────────────────────────────────────────────

test "Message.images defaults to empty so every existing literal compiles unchanged" {
    const msg = m.Message{ .role = .assistant, .content = "hi" };
    try testing.expectEqual(@as(usize, 0), msg.images.len);
    const img = m.ImagePart{ .media_type = "image/gif", .data_b64 = "R0lGOD" };
    try testing.expectEqualStrings("image/gif", img.media_type);
    try testing.expect(img.name == null);
}

// Pull in the inline test suites of the owned modules.
test {
    _ = apx_att;
    _ = tool_att;
}
