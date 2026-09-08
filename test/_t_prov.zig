//! A-providers offline test root (SWARM_PLAN ground rule 7).
//! Run: `zig test -lc test/_t_prov.zig`
//!
//! Covers: provider.fromString table, Anthropic IR⇄wire round-trips
//! (request build + response parse incl. tool_use round-trip), Ollama host
//! normalization, config env precedence via loadFromSnapshot (no process env
//! access), ChatClient dialect wiring (initProvider/useProvider/curl config).
//! Everything is allocation-checked by std.testing.allocator; no network.

const std = @import("std");
const config = @import("config.zig");
const providers = @import("../src/model/provider.zig");
const anth = @import("../src/model/anthropic.zig");
const ollama = @import("../src/model/ollama.zig");
const m = @import("../src/model/model.zig");

// Force full semantic analysis of the transport paths without executing
// them (chat() would spawn curl — never call it from tests).
comptime {
    _ = &m.ChatClient.chat;
    _ = &m.ChatClient.buildCurlConfig;
    _ = &m.ChatClient.initProvider;
    _ = &m.ChatClient.useProvider;
    _ = &config.Config.resolvedProfile;
}

const testing = std.testing;

// ── Provider matrix ────────────────────────────────────────────────────────

test "provider table resolves every documented spelling" {
    const t3 = [_]struct { name: []const u8, want: providers.Provider }{
        .{ .name = "deepseek", .want = .deepseek },
        .{ .name = "openai", .want = .openai_compat },
        .{ .name = "openai-compat", .want = .openai_compat },
        .{ .name = "anthropic", .want = .anthropic },
        .{ .name = "claude", .want = .anthropic },
        .{ .name = "ollama", .want = .ollama },
    };
    for (t3) |c| {
        try testing.expectEqual(c.want, providers.Provider.fromString(c.name).?);
    }
    try testing.expect(providers.Provider.fromString("openrouter") == null);
    try testing.expect(providers.Provider.fromString("") == null);
}

// ── Anthropic request direction ────────────────────────────────────────────

// Byte-exact fixture. The assistant message carries the SAME echo shape the
// agent loop stores (agent.zig tool_mod_echo): arguments ride RAW-escaped,
// without surrounding quotes.
const tools_json_fixture =
    "{\"type\":\"function\",\"function\":{\"name\":\"shell\",\"description\":\"run a shell command\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}}";

test "buildRequestBody maps IR to Messages API exactly" {
    const alloc = testing.allocator;
    const messages = [_]m.Message{
        .{ .role = .user, .content = "list the files" },
        .{
            .role = .assistant,
            .content = "",
            .tool_calls_json = "[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":{\\\"command\\\":\\\"ls -la\\\"}}}]",
        },
        .{ .role = .tool, .content = "total 0", .tool_call_id = "call_1" },
    };
    const req = m.ChatRequest{
        .messages = &messages,
        .tools_json = tools_json_fixture,
        .system_prompt = "be brief",
        .reasoning_effort = null,
        .stream = false,
    };

    const got = try anth.buildRequestBody(alloc, "claude-test", req);
    defer alloc.free(got);

    const want =
        "{\"model\":\"claude-test\",\"max_tokens\":" ++ std.fmt.comptimePrint("{d}", .{anth.max_tokens}) ++
        ",\"system\":\"be brief\\n\\nTool usage: the shell tool expects a direct command string (e.g. \\\"ls -la\\\"). Never wrap it in sh -c or bash -c.\"" ++
        ",\"messages\":[" ++
        "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"list the files\"}]}" ++
        "," ++
        // tool_calls_json echo decoded into a tool_use block with a real
        // input OBJECT (the escaped layer is unwrapped exactly once).
        "{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"shell\",\"input\":{\"command\":\"ls -la\"}}]}" ++
        "," ++
        // Consecutive tool results merge into ONE trailing user turn.
        "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"call_1\",\"content\":\"total 0\"}]}" ++
        "]," ++
        "\"tools\":[{\"name\":\"shell\",\"description\":\"run a shell command\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}]" ++
        "}";
    try testing.expectEqualStrings(want, got);
}

test "buildRequestBody merges consecutive tool results and skips system role" {
    const alloc = testing.allocator;
    const messages = [_]m.Message{
        .{ .role = .system, .content = "inline system must be ignored" },
        .{ .role = .tool, .content = "first", .tool_call_id = "t1" },
        .{ .role = .tool, .content = "second", .tool_call_id = "t2" },
    };
    const req = m.ChatRequest{
        .messages = &messages,
        .tools_json = "",
        .system_prompt = "",
        .reasoning_effort = null,
        .stream = false,
    };
    const got = try anth.buildRequestBody(alloc, "m", req);
    defer alloc.free(got);

    // Parity with the OpenAI path: even an empty prompt emits the system
    // param carrying the tool-rules suffix.
    const sys_pos = std.mem.indexOf(u8, got, "\"system\":\"").?;
    try testing.expect(std.mem.startsWith(u8, got[sys_pos..], "\"system\":\"Tool usage:"));
    // Consecutive tool results merge into ONE user turn of two blocks.
    const want_msgs =
        "\"messages\":[{\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"first\"}," ++
        "{\"type\":\"tool_result\",\"tool_use_id\":\"t2\",\"content\":\"second\"}]}]";
    try testing.expect(std.mem.indexOf(u8, got, want_msgs) != null);
    // Empty tools fragment omits the tools param entirely.
    try testing.expect(std.mem.indexOf(u8, got, "\"tools\"") == null);
}

test "buildRequestBody keeps assistant text alongside tool_use and escapes quotes" {
    const alloc = testing.allocator;
    const messages = [_]m.Message{
        .{
            .role = .assistant,
            .content = "she said \"hi\"",
            .tool_calls_json = "[{\"id\":\"c2\",\"type\":\"function\",\"function\":{\"name\":\"noop\",\"arguments\":{}}}]",
        },
    };
    const req = m.ChatRequest{
        .messages = &messages,
        .tools_json = "",
        .system_prompt = "",
        .reasoning_effort = null,
        .stream = false,
    };
    const got = try anth.buildRequestBody(alloc, "m", req);
    defer alloc.free(got);
    try testing.expect(
        std.mem.indexOf(u8, got, "{\"type\":\"text\",\"text\":\"she said \\\"hi\\\"\"},{\"type\":\"tool_use\",\"id\":\"c2\",\"name\":\"noop\",\"input\":{}}") != null,
    );
}

// ── Anthropic response direction ───────────────────────────────────────────

test "parseResponse decodes text, thinking, tool_use and stop_reason" {
    const alloc = testing.allocator;
    const body =
        "{\"id\":\"msg_01\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-test\"," ++
        "\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"checking \\\"now\\\"\\nnext\"}," ++
        "{\"type\":\"thinking\",\"thinking\":\"ponder\"}," ++
        "{\"type\":\"tool_use\",\"id\":\"toolu_9\",\"name\":\"file_read\",\"input\":{\"path\":\"/tmp/a b.txt\",\"flag\":true}}" ++
        "]," ++
        "\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}";

    var res = try anth.parseResponse(alloc, body);
    defer res.deinit(alloc);

    try testing.expectEqualStrings("checking \"now\"\nnext", res.content);
    try testing.expectEqualStrings("ponder", res.reasoning);
    try testing.expect(res.has_tools);
    try testing.expectEqualStrings("tool_calls", res.finish_reason);
    try testing.expectEqual(@as(usize, 1), res.tool_calls.len);
    try testing.expectEqualStrings("toolu_9", res.tool_calls[0].id);
    try testing.expectEqualStrings("file_read", res.tool_calls[0].name);
    // RAW source-slice contract: escape sequences intact for parseArgs.
    try testing.expectEqualStrings("{\"path\":\"/tmp/a b.txt\",\"flag\":true}", res.tool_calls[0].arguments);
}

test "parseResponse maps stop reasons into OpenAI vocabulary" {
    const alloc = testing.allocator;
    const cases = .{
        .{ "\"end_turn\"", "stop" },
        .{ "\"stop_sequence\"", "stop" },
        .{ "\"max_tokens\"", "length" },
        .{ "\"exotic_new_reason\"", "exotic_new_reason" }, // passthrough
    };
    inline for (cases) |c| {
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(
            &buf,
            "{{\"type\":\"message\",\"content\":[{{\"type\":\"text\",\"text\":\"x\"}}],\"stop_reason\":{s}}}",
            .{c[0]},
        );
        var res = try anth.parseResponse(alloc, body);
        defer res.deinit(alloc);
        try testing.expectEqualStrings(c[1], res.finish_reason);
    }
    // Missing stop_reason defaults to stop (end_turn mapping).
    var res = try anth.parseResponse(alloc, "{\"type\":\"message\",\"content\":[]}");
    defer res.deinit(alloc);
    try testing.expectEqualStrings("stop", res.finish_reason);
}

// ── Round-trip: wire → IR → echo → wire ────────────────────────────────────

/// Rebuilds the OpenAI-shaped echo exactly like agent.zig's tool_mod_echo:
/// arguments inserted RAW after `"arguments":`.
fn echoLikeAgentLoop(alloc: std.mem.Allocator, resp: m.ChatResponse) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "[");
    for (resp.tool_calls, 0..) |tc, i| {
        if (i > 0) try buf.append(alloc, ',');
        const piece = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
            .{ tc.id, tc.name, tc.arguments },
        );
        defer alloc.free(piece);
        try buf.appendSlice(alloc, piece);
    }
    try buf.appendSlice(alloc, "]");
    return buf.toOwnedSlice(alloc);
}

test "tool_use round-trip: response parse -> agent echo -> request rebuild" {
    const alloc = testing.allocator;
    const wire_response =
        "{\"type\":\"message\",\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"let me check\"}," ++
        "{\"type\":\"tool_use\",\"id\":\"toolu_ab\",\"name\":\"shell\",\"input\":{\"command\":\"git status --short\"}}" ++
        "],\"stop_reason\":\"tool_use\"}";

    var resp = try anth.parseResponse(alloc, wire_response);
    defer resp.deinit(alloc);

    const echo = try echoLikeAgentLoop(alloc, resp);
    defer alloc.free(echo);

    // The loop stores this echo on an assistant Message and replays it.
    const messages = [_]m.Message{
        .{ .role = .user, .content = "status?" },
        .{ .role = .assistant, .content = resp.content, .tool_calls_json = echo },
        .{ .role = .tool, .content = "M src/main.zig", .tool_call_id = "toolu_ab" },
    };
    const req = m.ChatRequest{
        .messages = &messages,
        .tools_json = tools_json_fixture,
        .system_prompt = "",
        .reasoning_effort = null,
        .stream = false,
    };
    const rebuilt = try anth.buildRequestBody(alloc, "claude-test", req);
    defer alloc.free(rebuilt);

    const want_block =
        "{\"type\":\"tool_use\",\"id\":\"toolu_ab\",\"name\":\"shell\",\"input\":{\"command\":\"git status --short\"}}";
    try testing.expect(std.mem.indexOf(u8, rebuilt, want_block) != null);
    try testing.expect(std.mem.indexOf(u8, rebuilt, "{\"type\":\"text\",\"text\":\"let me check\"}") != null);
    try testing.expect(std.mem.indexOf(u8, rebuilt, "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_ab\",\"content\":\"M src/main.zig\"}") != null);
}

// ── Anthropic error envelopes ──────────────────────────────────────────────

test "anthropic error envelope detection and message extraction" {
    const alloc = testing.allocator;
    try testing.expect(anth.isErrorEnvelope(
        "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"max_tokens: field required\"}}",
    ));
    try testing.expect(anth.isErrorEnvelope("\r\n {\"type\":\"error\",\"error\":{\"message\":\"auth\"}}"));
    // Normal responses and prose stay clean.
    try testing.expect(!anth.isErrorEnvelope(
        "{\"id\":\"m\",\"type\":\"message\",\"content\":[{\"type\":\"text\",\"text\":\"error handling is hard\"}]}",
    ));
    try testing.expect(!anth.isErrorEnvelope("plain gateway timeout text"));

    const msg = anth.errorMessage(
        alloc,
        "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"max_tokens: field required\"}}",
    ).?;
    defer alloc.free(msg);
    try testing.expectEqualStrings("max_tokens: field required", msg);
    try testing.expect(anth.errorMessage(alloc, "{}") == null);

    // Regression guard: the OpenAI checker in model.zig keeps its contract.
    try testing.expect(m.isErrorEnvelope("{\"error\":{\"message\":\"bad key\"}}"));
}

// ── Ollama profile ─────────────────────────────────────────────────────────

test "ollama host normalization and client wiring" {
    const alloc = testing.allocator;
    const ep = try ollama.endpointFromHost(alloc, "192.168.1.5:11434");
    defer alloc.free(ep);
    try testing.expectEqualStrings("http://192.168.1.5:11434/v1/chat/completions", ep);

    const client = ollama.initClient(alloc, undefined, "", null);
    try testing.expectEqual(providers.AuthStyle.none, client.auth_style);
    try testing.expectEqualStrings(ollama.default_endpoint, client.endpoint);

    // `.none` clients emit no credential header at all.
    const cfg = try client.buildCurlConfig(false);
    defer alloc.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "Authorization:") == null);
    try testing.expect(std.mem.indexOf(u8, cfg, "x-api-key") == null);
}

// ── Config: env precedence via injectable snapshot ─────────────────────────

test "api key precedence: ZHARNESS_API_KEY > DEEPSEEK_API_KEY > empty" {
    const alloc = testing.allocator;
    var c1 = try config.loadFromSnapshot(alloc, .{ .zharness_api_key = "glob", .deepseek_api_key = "dk" });
    defer c1.deinit();
    try testing.expectEqualStrings("glob", c1.api_key);
    try testing.expect(c1.api_key_is_global);

    var c2 = try config.loadFromSnapshot(alloc, .{ .deepseek_api_key = "dk" });
    defer c2.deinit();
    try testing.expectEqualStrings("dk", c2.api_key);
    try testing.expect(!c2.api_key_is_global);

    var c3 = try config.loadFromSnapshot(alloc, .{});
    defer c3.deinit();
    try testing.expectEqualStrings("", c3.api_key);
}

test "per-provider env fallbacks land in dedicated fields" {
    const alloc = testing.allocator;
    var cfg = try config.loadFromSnapshot(alloc, .{
        .anthropic_api_key = "sk-ant-1",
        .ollama_host = "box.lan:11434/",
        .endpoint = "https://gateway.internal/v1/chat/completions",
        .cwd = "/tmp/ws",
    });
    defer cfg.deinit();
    try testing.expectEqualStrings("sk-ant-1", cfg.anthropic_key);
    try testing.expectEqualStrings("box.lan:11434/", cfg.ollama_host);
    try testing.expectEqualStrings("https://gateway.internal/v1/chat/completions", cfg.endpoint);
    try testing.expectEqualStrings("/tmp/ws", cfg.cwd);
    // DeepSeek provider/model defaults untouched.
    try testing.expectEqualStrings("deepseek", cfg.provider);
    try testing.expectEqualStrings(config.default_model, cfg.model);
}

test "provider switch installs anthropic key, endpoint and default model" {
    const alloc = testing.allocator;
    var cfg = try config.loadFromSnapshot(alloc, .{ .anthropic_api_key = "sk-ant-1" });
    defer cfg.deinit();

    try cfg.applyOverrides(null, "anthropic", false);
    try testing.expectEqualStrings("sk-ant-1", cfg.api_key);
    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", cfg.endpoint);
    try testing.expectEqualStrings(providers.profile(.anthropic).default_model, cfg.model);

    const prof = cfg.resolvedProfile().?;
    try testing.expectEqual(providers.WireFormat.anthropic_messages, prof.wire);
    try testing.expectEqual(providers.AuthStyle.x_api_key, prof.auth);
}

test "global ZHARNESS_API_KEY survives an anthropic switch" {
    const alloc = testing.allocator;
    var cfg = try config.loadFromSnapshot(alloc, .{ .zharness_api_key = "glob", .anthropic_api_key = "sk-ant" });
    defer cfg.deinit();
    try cfg.applyOverrides(null, "claude", false);
    try testing.expectEqualStrings("glob", cfg.api_key);
}

test "explicit endpoint override beats provider default" {
    const alloc = testing.allocator;
    var cfg = try config.loadFromSnapshot(alloc, .{});
    defer cfg.deinit();
    try cfg.applyOverridesFull(.{ .provider = "anthropic", .endpoint = "http://proxy.corp:8080/v1/messages" });
    try testing.expectEqualStrings("http://proxy.corp:8080/v1/messages", cfg.endpoint);

    // Also applies without a provider switch.
    try cfg.applyOverridesFull(.{ .endpoint = "http://other:9/v1/messages" });
    try testing.expectEqualStrings("http://other:9/v1/messages", cfg.endpoint);
}

test "ollama switch rewrites endpoint from OLLAMA_HOST and stubs the key gate" {
    const alloc = testing.allocator;
    var cfg = try config.loadFromSnapshot(alloc, .{ .ollama_host = "192.168.1.5:11434" });
    defer cfg.deinit();
    try testing.expectEqualStrings("", cfg.api_key);

    try cfg.applyOverrides(null, "ollama", false);
    try testing.expectEqualStrings("http://192.168.1.5:11434/v1/chat/completions", cfg.endpoint);
    // Placeholder keeps main.zig's non-empty-key gate happy; no header sent.
    try testing.expect(cfg.api_key.len > 0);
    try testing.expectEqualStrings(providers.profile(.ollama).default_model, cfg.model);
}

test "legacy permissive spellings keep historical behaviour" {
    const alloc = testing.allocator;
    var cfg = try config.loadFromSnapshot(alloc, .{});
    defer cfg.deinit();
    try cfg.applyOverrides(null, "openrouter", false);
    try testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", cfg.endpoint);
    // Unknown to the matrix → no default-model swap, plain client.
    try testing.expectEqualStrings(config.default_model, cfg.model);
    try testing.expect(cfg.resolvedProfile() == null);
}

test "pinned model wins over the provider default-model heuristic" {
    const alloc = testing.allocator;
    var cfg = try config.loadFromSnapshot(alloc, .{});
    defer cfg.deinit();
    try cfg.applyOverrides("my-claude", "anthropic", false);
    try testing.expectEqualStrings("my-claude", cfg.model);

    // And once pinned, a second switch keeps the pin.
    try cfg.applyOverrides(null, "ollama", true);
    try testing.expectEqualStrings("my-claude", cfg.model);
    try testing.expect(!cfg.stream);
}

// ── ChatClient dialect wiring ──────────────────────────────────────────────

test "initProvider wires anthropic dialect; curl config carries x-api-key" {
    const alloc = testing.allocator;
    var client = m.ChatClient.initProvider(
        alloc,
        undefined,
        providers.profile(.anthropic),
        "",
        "sk-secret",
    );
    try testing.expectEqual(m.WireFormat.anthropic_messages, client.wire_format);
    try testing.expectEqual(m.AuthStyle.x_api_key, client.auth_style);
    try testing.expectEqualStrings(providers.profile(.anthropic).default_model, client.model);

    const cfg = try client.buildCurlConfig(false);
    defer alloc.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "x-api-key: sk-secret") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "anthropic-version: 2023-06-01") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "Authorization") == null);
    try testing.expect(std.mem.indexOf(u8, cfg, "url = https://api.anthropic.com/v1/messages") != null);
}

test "legacy init keeps bearer behaviour untouched" {
    const alloc = testing.allocator;
    var client = m.ChatClient.init(alloc, undefined, "https://api.example.com/v1/chat", "m", "k");
    try testing.expectEqual(m.AuthStyle.bearer, client.auth_style);
    try testing.expectEqual(m.WireFormat.openai_chat, client.wire_format);
    const cfg = try client.buildCurlConfig(false);
    defer alloc.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "Authorization: Bearer k") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "x-api-key") == null);
}

test "useProvider re-points a live client in place" {
    const alloc = testing.allocator;
    var client = m.ChatClient.init(alloc, undefined, "https://old", "old-m", "");
    client.useProvider(providers.profile(.ollama), "llama3", null);
    try testing.expectEqualStrings("http://localhost:11434/v1/chat/completions", client.endpoint);
    try testing.expectEqualStrings("llama3", client.model);
    try testing.expectEqual(m.AuthStyle.none, client.auth_style);
    client.useProvider(providers.profile(.anthropic), null, "sk-1");
    try testing.expectEqualStrings(providers.profile(.anthropic).endpoint, client.endpoint);
    try testing.expectEqualStrings("sk-1", client.api_key);
    try testing.expectEqual(m.WireFormat.anthropic_messages, client.wire_format);
}
