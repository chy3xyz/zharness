//! Model layer — the zharness internal Model IR (dev.md §VI) and the
//! DeepSeek/OpenAI-compatible client that talks to it.
//!
//! The agent runtime only deals with the IR (`Message`, `ChatRequest`,
//! `ChatResponse`, `ToolCall`). The client translates IR <-> the provider's
//! OpenAI-style JSON, so a new provider is just another `client` impl.

const std = @import("std");
const clib = @import("../clib.zig");

// Provider matrix (dev.md §VI). The import cycle with anthropic.zig is
// intentional and lazily analyzed: it uses the IR types below, while
// ChatClient.chatAnthropic calls its translate functions.
pub const providers = @import("provider.zig");
const anthropic_wire = @import("anthropic.zig");
pub const Provider = providers.Provider;
pub const ProviderProfile = providers.ProviderProfile;
pub const AuthStyle = providers.AuthStyle;
pub const WireFormat = providers.WireFormat;

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn asStr(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

/// One image attached to a message (wave 6 H-image). Pure data: the base64
/// payload is borrowed from wherever it was parsed (prompt content_json or a
/// stored attachment), so no deinit is needed — slices must outlive the
/// Message. Only vision-capable provider profiles (`ProviderProfile.vision`)
/// put these on the wire; text-only providers degrade to a path note in the
/// prompt text instead (see server/apiproxy/attachments.zig).
pub const ImagePart = struct {
    /// Canonical IANA media type: "image/png" | "image/jpeg" | "image/webp"
    /// | "image/gif" (the same union upstream's prompt wire accepts).
    media_type: []const u8,
    /// Standard-alphabet base64 payload WITHOUT the data-URL prefix.
    data_b64: []const u8,
    /// Optional client-supplied display name.
    name: ?[]const u8 = null,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
    /// For tool messages: the id of the tool call they answer.
    tool_call_id: ?[]const u8 = null,
    /// For assistant messages that requested tools: the raw tool_calls JSON
    /// echoed back to the provider on the next request so it accepts results.
    tool_calls_json: ?[]const u8 = null,
    /// Optional image parts riding this message (user turns today). Default
    /// empty: every existing text-only path stays byte-identical.
    images: []const ImagePart = &.{},
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const ChatRequest = struct {
    messages: []const Message,
    tools_json: []const u8, // pre-serialized OpenAI tools fragment (no brackets)
    system_prompt: []const u8,
    reasoning_effort: ?[]const u8,
    stream: bool,
};

pub const ChatResponse = struct {
    content: []const u8,
    reasoning: []const u8,
    tool_calls: []ToolCall,
    finish_reason: []const u8,
    /// True when the model requested tool calls (vs. a final answer).
    has_tools: bool,

    pub fn deinit(self: *ChatResponse, alloc: std.mem.Allocator) void {
        alloc.free(self.content);
        alloc.free(self.reasoning);
        alloc.free(self.finish_reason);
        for (self.tool_calls) |tc| {
            alloc.free(tc.id);
            alloc.free(tc.name);
            alloc.free(tc.arguments);
        }
        alloc.free(self.tool_calls);
    }
};

const ApiError = error{
    HttpError,
    InvalidUri,
    BodyTooLarge,
    MalformedResponse,
};

/// OpenAI/DeepSeek-compatible chat client. Uses `std.http` + `std.Io` with a
/// non-streaming JSON request (this path is reliable on macOS; see zeepseek
/// notes about chunked SSE EOF). Streaming is supported via the SSE path.
///
/// Security posture: the request body and the curl config (which carries the
/// API key) live in mode-0600 mkstemp files under $TMPDIR, so the key never
/// appears in argv (invisible to ps(1)) and predictable /tmp paths are gone.
pub const ChatClient = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    endpoint: []const u8,
    model: []const u8,
    api_key: []const u8,

    /// Credential-header dialect (default: the historical Bearer behaviour).
    auth_style: AuthStyle = .bearer,
    /// Wire dialect; `.anthropic_messages` routes chat() through the
    /// Messages-API translator (non-streaming; stream=true degrades).
    wire_format: WireFormat = .openai_chat,

    /// Whether image parts on messages may be rendered onto the wire
    /// (wave 6 H-image). Mirrors `ProviderProfile.vision` via initProvider /
    /// useProvider; when false, image parts are dropped defensively and only
    /// the message text is sent (the prompt-rewrite layer already replaced
    /// them with path notes for text-only providers — this is a second gate,
    /// so a mis-set profile can never produce a rejected multimodal body).
    vision: bool = false,

    /// Optional live-delta sink for streamed requests. Set before the client
    /// value is copied into the agent loop; invoked per content/reasoning
    /// delta while a stream is in flight.
    stream_sink: ?*const fn (kind: StreamKind, delta: []const u8) void = null,

    /// Human-readable detail about the most recent failure (provider error
    /// message when available). Fixed buffer: no allocation ownership dance;
    /// cleared at the start of every request.
    last_err_buf: [512]u8 = undefined,
    last_err_len: usize = 0,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, endpoint: []const u8, model: []const u8, api_key: []const u8) ChatClient {
        return .{
            .alloc = alloc,
            .io = io,
            .endpoint = endpoint,
            .model = model,
            .api_key = api_key,
        };
    }

    /// Provider-aware constructor (dev.md §VI): fills endpoint/auth/wire
    /// dialects from a resolved profile. `model_name` overrides the profile's
    /// default model when non-empty; `api_key` may be empty for keyless
    /// providers (`.none` auth). Endpoint/model/key slices are borrowed —
    /// keep them alive as long as the client (same contract as init()).
    pub fn initProvider(alloc: std.mem.Allocator, io: std.Io, prof: ProviderProfile, model_name: []const u8, api_key: []const u8) ChatClient {
        var self = ChatClient.init(alloc, io, prof.endpoint, if (model_name.len > 0) model_name else prof.default_model, api_key);
        self.auth_style = prof.auth;
        self.wire_format = prof.wire;
        self.vision = prof.vision;
        return self;
    }

    /// Switch an existing client to another provider in place: replaces the
    /// endpoint/model/key plus both dialects. Optional arguments win over the
    /// profile defaults when non-null — this is the one-liner a caller needs
    /// to re-point a running loop at a different backend.
    pub fn useProvider(self: *ChatClient, prof: ProviderProfile, model_name: ?[]const u8, api_key: ?[]const u8) void {
        self.endpoint = prof.endpoint;
        self.model = model_name orelse prof.default_model;
        if (api_key) |k| self.api_key = k;
        self.auth_style = prof.auth;
        self.wire_format = prof.wire;
        self.vision = prof.vision;
    }

    /// Detail text for the most recent failed request ("" when none).
    pub fn lastError(self: *const ChatClient) []const u8 {
        return self.last_err_buf[0..self.last_err_len];
    }

    fn setLastError(self: *ChatClient, src: []const u8) void {
        const n = @min(src.len, self.last_err_buf.len);
        // Trim trailing whitespace/newlines from provider bodies.
        var s = src[0..n];
        while (s.len > 0 and (s[s.len - 1] == '\n' or s[s.len - 1] == '\r' or s[s.len - 1] == ' ')) s = s[0 .. s.len - 1];
        @memcpy(self.last_err_buf[0..s.len], s);
        self.last_err_len = s.len;
    }

    pub const MaxRequestSeconds: usize = 300;
    pub const ConnectTimeoutSeconds: usize = 15;

    pub fn chat(self: *ChatClient, req: ChatRequest) !ChatResponse {
        self.last_err_len = 0;

        // Anthropic dialect: non-streaming translator only (streaming is
        // deferred); a stream request degrades to a buffered call.
        if (self.wire_format == .anthropic_messages) {
            var buffered = req;
            buffered.stream = false;
            return self.chatAnthropic(buffered);
        }

        if (req.stream) return self.chatStreaming(req);

        const body = try self.buildBody(req);
        defer self.alloc.free(body);

        if (std.c.getenv("ZH_DEBUG_BODY") != null) {
            std.debug.print("[body] {s}\n", .{body});
        }

        // Private temp files (mkstemp, 0600): the JSON body and a curl config
        // file carrying url + auth header. The key stays out of argv entirely.
        const body_path = (try clib.createPrivateTemp(self.alloc, "zharness_req_")) orelse return error.HttpError;
        defer self.alloc.free(body_path);
        defer clib.unlinkPath(body_path);
        if (!writePrivateFile(body_path, body)) return error.HttpError;

        const cfg_path = (try clib.createPrivateTemp(self.alloc, "zharness_curl_")) orelse return error.HttpError;
        defer self.alloc.free(cfg_path);
        defer clib.unlinkPath(cfg_path);
        const curl_cfg = try self.buildCurlConfig(false);
        defer self.alloc.free(curl_cfg);
        if (!writePrivateFile(cfg_path, curl_cfg)) return error.HttpError;

        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(self.alloc);
        try cmd.appendSlice(self.alloc, "curl --silent --show-error --config ");
        try appendShellQuoted(self.alloc, &cmd, cfg_path);
        try cmd.appendSlice(self.alloc, " -d @");
        try appendShellQuoted(self.alloc, &cmd, body_path);

        const cmd_z = try self.alloc.dupeSentinel(u8, cmd.items, 0);
        defer self.alloc.free(cmd_z);

        const fp = clib.popenRead(cmd_z.ptr) orelse return error.HttpError;
        var out = try std.ArrayList(u8).initCapacity(self.alloc, 0);
        errdefer out.deinit(self.alloc);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = std.c.fread(&buf, 1, buf.len, fp);
            if (n == 0) break;
            try out.appendSlice(self.alloc, buf[0..n]);
        }
        _ = clib.pclosePipe(fp);

        const resp_body = try out.toOwnedSlice(self.alloc);
        if (std.c.getenv("ZH_DEBUG_RESP") != null) std.debug.print("[resp] {s}\n", .{resp_body[0..@min(resp_body.len,2000)]});
        defer self.alloc.free(resp_body);

        // Classify failures precisely instead of substring-guessing: only a
        // JSON object whose FIRST top-level field is "error" is a provider
        // rejection. Prose that merely contains the word "error" parses fine.
        if (resp_body.len == 0 or resp_body[0] != '{') {
            self.setLastError("provider returned an empty or non-JSON body");
            return error.HttpError;
        }
        if (isErrorEnvelope(resp_body)) {
            if (errorMessage(self.alloc, resp_body)) |m| {
                self.setLastError(m);
                self.alloc.free(m);
            } else {
                self.setLastError("provider rejected the request");
            }
            return error.HttpError;
        }

        return self.parseResponse(resp_body);
    }

    /// SSE transport: same mkstemp + curl-config security posture as the
    /// buffered path, plus no-buffer so deltas arrive live. Raw bytes feed an
    /// SseParser which reports each delta through `stream_sink` and assembles
    /// the final ChatResponse.
    fn chatStreaming(self: *ChatClient, req: ChatRequest) !ChatResponse {
        const body = try self.buildBody(req);
        defer self.alloc.free(body);

        const body_path = (try clib.createPrivateTemp(self.alloc, "zharness_req_")) orelse return error.HttpError;
        defer self.alloc.free(body_path);
        defer clib.unlinkPath(body_path);
        if (!writePrivateFile(body_path, body)) return error.HttpError;

        const cfg_path = (try clib.createPrivateTemp(self.alloc, "zharness_curl_")) orelse return error.HttpError;
        defer self.alloc.free(cfg_path);
        defer clib.unlinkPath(cfg_path);
        const curl_cfg = try self.buildCurlConfig(true);
        defer self.alloc.free(curl_cfg);
        if (!writePrivateFile(cfg_path, curl_cfg)) return error.HttpError;

        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(self.alloc);
        try cmd.appendSlice(self.alloc, "curl --silent --show-error --config ");
        try appendShellQuoted(self.alloc, &cmd, cfg_path);
        try cmd.appendSlice(self.alloc, " -d @");
        try appendShellQuoted(self.alloc, &cmd, body_path);

        const cmd_z = try self.alloc.dupeSentinel(u8, cmd.items, 0);
        defer self.alloc.free(cmd_z);

        var parser = SseParser.init(self.alloc);
        defer parser.deinit();
        parser.sink = self.stream_sink;

        const fp = clib.popenRead(cmd_z.ptr) orelse return error.HttpError;
        var buf: [8192]u8 = undefined;
        var raw_first: ?[]u8 = null; // first 512B of raw stream for error diagnosis
        while (true) {
            const n = std.c.fread(&buf, 1, buf.len, fp);
            if (n == 0) break;
            if (raw_first == null and n > 0) {
                const cap: usize = @min(n, 512);
                raw_first = try self.alloc.dupe(u8, buf[0..cap]);
            }
            try parser.feed(buf[0..n]);
            if (parser.done) break;
        }
        _ = clib.pclosePipe(fp);

        // Guard against a connection that died before delivering anything.
        if (!parser.done and parser.content.items.len == 0 and
            parser.reasoning.items.len == 0 and parser.finish_reason_len == 0)
        {
            // Surface the first bytes of the raw stream so the operator can
            // distinguish rate limits, auth failures, and empty 200s.
            if (raw_first) |rf| {
                const msg = std.fmt.allocPrint(self.alloc,
                    "stream ended without any data (first bytes: {s})", .{rf}) catch
                    "stream ended without any data from the provider";
                self.setLastError(msg);
                self.alloc.free(msg);
                self.alloc.free(rf);
            } else {
                self.setLastError("stream ended without any data from the provider");
            }
            return error.HttpError;
        }
        if (raw_first) |rf| self.alloc.free(rf);

        return parser.finish();
    }

    /// curl config-file contents (curl --config): endpoint, timeouts, and the
    /// Authorization header — so the API key never touches the command line.
    /// Streaming adds no-buffer (unbuffered -N behaviour) and the SSE accept
    /// header.
    pub fn buildCurlConfig(self: *const ChatClient, stream: bool) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "silent\nshow-error\nrequest = POST\n");
        if (stream) {
            try out.appendSlice(self.alloc, "no-buffer\nheader = \"Accept: text/event-stream\"\n");
        }
        try out.appendSlice(self.alloc, "max-time = ");
        try out.appendSlice(self.alloc, std.fmt.comptimePrint("{d}", .{MaxRequestSeconds}));
        try out.appendSlice(self.alloc, "\nconnect-timeout = ");
        try out.appendSlice(self.alloc, std.fmt.comptimePrint("{d}", .{ConnectTimeoutSeconds}));
        try out.appendSlice(self.alloc, "\nurl = ");
        try out.appendSlice(self.alloc, self.endpoint);
        try out.appendSlice(self.alloc, "\nheader = \"Content-Type: application/json\"\n");
        switch (self.auth_style) {
            .bearer => {
                try out.appendSlice(self.alloc, "header = \"Authorization: Bearer ");
                for (self.api_key) |ch| {
                    if (ch == '"' or ch == '\\') try out.append(self.alloc, '\\');
                    try out.append(self.alloc, ch);
                }
                try out.appendSlice(self.alloc, "\"\n");
            },
            .x_api_key => {
                try out.appendSlice(self.alloc, "header = \"x-api-key: ");
                for (self.api_key) |ch| {
                    if (ch == '"' or ch == '\\') try out.append(self.alloc, '\\');
                    try out.append(self.alloc, ch);
                }
                try out.appendSlice(self.alloc, "\"\nheader = \"anthropic-version: " ++ providers.anthropic_version ++ "\"\n");
            },
            // Local servers (Ollama) need no credential header at all.
            .none => {},
        }
        return out.toOwnedSlice(self.alloc);
    }

    /// Anthropic Messages-API transport (non-streaming). Same security
    /// posture as the buffered OpenAI path — mkstemp body + curl config
    /// carrying the credential — with the wire translation swapped for the
    /// anthropic.zig translator.
    fn chatAnthropic(self: *ChatClient, req: ChatRequest) !ChatResponse {
        const body = try anthropic_wire.buildRequestBody(self.alloc, self.model, req);
        defer self.alloc.free(body);

        const body_path = (try clib.createPrivateTemp(self.alloc, "zharness_req_")) orelse return error.HttpError;
        defer self.alloc.free(body_path);
        defer clib.unlinkPath(body_path);
        if (!writePrivateFile(body_path, body)) return error.HttpError;

        const cfg_path = (try clib.createPrivateTemp(self.alloc, "zharness_curl_")) orelse return error.HttpError;
        defer self.alloc.free(cfg_path);
        defer clib.unlinkPath(cfg_path);
        const curl_cfg = try self.buildCurlConfig(false);
        defer self.alloc.free(curl_cfg);
        if (!writePrivateFile(cfg_path, curl_cfg)) return error.HttpError;

        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(self.alloc);
        try cmd.appendSlice(self.alloc, "curl --silent --show-error --config ");
        try appendShellQuoted(self.alloc, &cmd, cfg_path);
        try cmd.appendSlice(self.alloc, " -d @");
        try appendShellQuoted(self.alloc, &cmd, body_path);

        const cmd_z = try self.alloc.dupeSentinel(u8, cmd.items, 0);
        defer self.alloc.free(cmd_z);

        const fp = clib.popenRead(cmd_z.ptr) orelse return error.HttpError;
        var out = try std.ArrayList(u8).initCapacity(self.alloc, 0);
        errdefer out.deinit(self.alloc);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = std.c.fread(&buf, 1, buf.len, fp);
            if (n == 0) break;
            try out.appendSlice(self.alloc, buf[0..n]);
        }
        _ = clib.pclosePipe(fp);

        const resp_body = try out.toOwnedSlice(self.alloc);
        defer self.alloc.free(resp_body);

        if (resp_body.len == 0 or resp_body[0] != '{') {
            self.setLastError("provider returned an empty or non-JSON body");
            return error.HttpError;
        }
        if (anthropic_wire.isErrorEnvelope(resp_body)) {
            if (anthropic_wire.errorMessage(self.alloc, resp_body)) |msg| {
                self.setLastError(msg);
                self.alloc.free(msg);
            } else {
                self.setLastError("provider rejected the request");
            }
            return error.HttpError;
        }

        return anthropic_wire.parseResponse(self.alloc, resp_body);
    }

    /// Render the OpenAI-compatible request body for `req`. Public so test
    /// roots can assert byte-level wire shapes without spawning curl.
    pub fn buildBody(self: *ChatClient, req: ChatRequest) ![]const u8 {
        var body = try std.ArrayList(u8).initCapacity(self.alloc, 0);
        errdefer body.deinit(self.alloc);
        try body.appendSlice(self.alloc, "{\"model\":\"");
        try body.appendSlice(self.alloc, self.model);
        try body.appendSlice(self.alloc, if (req.stream)
            "\",\"stream\":true,\"messages\":["
        else
            "\",\"stream\":false,\"messages\":[");

        const tool_rules = "Tool usage: the shell tool expects a direct command string (e.g. \"ls -la\"). Never wrap it in sh -c or bash -c.";
        const full_system = if (req.system_prompt.len > 0)
            try std.fmt.allocPrint(self.alloc, "{s}\n\n{s}", .{ req.system_prompt, tool_rules })
        else
            tool_rules;
        defer if (req.system_prompt.len > 0) self.alloc.free(full_system);
        try body.appendSlice(self.alloc, "{\"role\":\"system\",\"content\":\"");
        try escape(self.alloc, full_system, &body);
        try body.appendSlice(self.alloc, "\"}");

        for (req.messages) |m| {
            try body.append(self.alloc, ',');
            try body.appendSlice(self.alloc, "{\"role\":\"");
            try body.appendSlice(self.alloc, m.role.asStr());
            if (m.role == .tool and m.tool_call_id != null) {
                try body.appendSlice(self.alloc, "\",\"tool_call_id\":\"");
                try escape(self.alloc, m.tool_call_id.?, &body);
                try body.appendSlice(self.alloc, "\",\"content\":\"");
                try escape(self.alloc, m.content, &body);
                try body.appendSlice(self.alloc, "\"}");
            } else if (m.tool_calls_json != null) {
                try body.appendSlice(self.alloc, "\",\"content\":null,\"tool_calls\":");
                try body.appendSlice(self.alloc, m.tool_calls_json.?);
                try body.appendSlice(self.alloc, "}");
            } else if (m.images.len > 0 and self.vision) {
                // OpenAI multimodal shape: content becomes a typed part
                // array — one text part plus one data-URL image_url part per
                // attached image. Only reached when the profile is
                // vision-capable; otherwise the plain-string path below
                // keeps text-only bodies byte-identical.
                try body.appendSlice(self.alloc, "\",\"content\":[{\"type\":\"text\",\"text\":\"");
                try escape(self.alloc, m.content, &body);
                try body.appendSlice(self.alloc, "\"}");
                for (m.images) |img| {
                    try body.appendSlice(self.alloc, ",{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
                    try escape(self.alloc, img.media_type, &body);
                    try body.appendSlice(self.alloc, ";base64,");
                    // Base64 alphabet carries no quote/backslash bytes, so a
                    // raw append is safe and avoids a full payload copy.
                    try body.appendSlice(self.alloc, img.data_b64);
                    try body.appendSlice(self.alloc, "\"}}");
                }
                try body.appendSlice(self.alloc, "]");
                try body.appendSlice(self.alloc, "}");
            } else {
                try body.appendSlice(self.alloc, "\",\"content\":\"");
                try escape(self.alloc, m.content, &body);
                try body.appendSlice(self.alloc, "\"}");
            }
        }
        try body.appendSlice(self.alloc, "],\"tools\":[");
        try body.appendSlice(self.alloc, req.tools_json);
        try body.appendSlice(self.alloc, "],\"tool_choice\":\"auto\"");
        // Persisted garbage (the GUI once stored "reasoningEffort") must not
        // reject the whole request server-side: only documented variants go out.
        var effort_sent = false;
        if (req.reasoning_effort) |eff| {
            if (validEffort(eff)) {
                try body.appendSlice(self.alloc, ",\"reasoning_effort\":\"");
                try body.appendSlice(self.alloc, eff);
                try body.appendSlice(self.alloc, "\"}");
                effort_sent = true;
            }
        }
        if (!effort_sent) try body.appendSlice(self.alloc, "}");
        return body.toOwnedSlice(self.alloc);
    }

    fn parseResponse(self: *ChatClient, json: []const u8) !ChatResponse {
        var res = ChatResponse{
            .content = try self.alloc.dupe(u8, ""),
            .reasoning = try self.alloc.dupe(u8, ""),
            .tool_calls = &.{},
            .finish_reason = try self.alloc.dupe(u8, "stop"),
            .has_tools = false,
        };
        // Detect tool calls anywhere in the body.
        if (std.mem.indexOf(u8, json, "\"tool_calls\"") != null or
            std.mem.indexOf(u8, json, "\"tool_call\"") != null)
        {
            res.tool_calls = try self.parseToolCalls(json);
            res.has_tools = res.tool_calls.len > 0;
        }
        // Extract message content + reasoning. extractStringField is
        // escape-aware, so content containing \" sequences survives intact.
        if (std.mem.indexOf(u8, json, "\"message\"")) |mi| {
            const brace = std.mem.indexOfScalarPos(u8, json, mi, '{') orelse return error.MalformedResponse;
            const end = findMatchingBrace(json, brace) orelse return error.MalformedResponse;
            const msg = json[brace..end];
            if (try extractStringField(self.alloc, msg, "content")) |v| {
                self.alloc.free(res.content);
                res.content = v;
            }
            if (try extractStringField(self.alloc, msg, "reasoning_content")) |v| {
                self.alloc.free(res.reasoning);
                res.reasoning = v;
            }
        }
        if (std.mem.indexOf(u8, json, "\"finish_reason\":")) |fi| {
            const vs = fi + 16;
            var ve = vs;
            while (ve < json.len and json[ve] != '"') ve += 1;
            if (ve > vs) {
                self.alloc.free(res.finish_reason);
                res.finish_reason = try self.alloc.dupe(u8, json[vs..ve]);
            }
        }
        return res;
    }

    fn parseToolCalls(self: *ChatClient, json: []const u8) ![]ToolCall {
        // Find the first "tool_calls":[ ... ] array and parse each entry.
        var calls = try std.ArrayList(ToolCall).initCapacity(self.alloc, 0);
        if (std.c.getenv("ZH_DEBUG_ARGS") != null) {
            const found = std.mem.indexOf(u8, json, "\"tool_calls\":[");
            std.debug.print("[parseTC] found=\"tool_calls\":[ : {}\n", .{found != null});
        }
        errdefer {
            for (calls.items) |tc| {
                self.alloc.free(tc.id);
                self.alloc.free(tc.name);
                self.alloc.free(tc.arguments);
            }
            calls.deinit(self.alloc);
        }
        while (std.mem.indexOf(u8, json, "\"tool_calls\":[")) |pos| {
            const arr_start = pos + 13; // point AT the '[' (not past it)
            // Arrays use brackets, so match with the bracket matcher.
            const bracket_end = findMatchingBracket(json, arr_start) orelse {
                if (std.c.getenv("ZH_DEBUG_ARGS") != null) std.debug.print("[parseTC] bracket_end=null\n", .{});
                break;
            };
            const arr = json[arr_start .. bracket_end + 1];
            if (std.c.getenv("ZH_DEBUG_ARGS") != null) std.debug.print("[parseTC] arr_len={d} arr={s}\n", .{ arr.len, arr[0..@min(arr.len,200)] });
            var i: usize = 1; // skip '['
            while (i < arr.len) : (i += 1) {
                if (arr[i] == '{') {
                    const obj_end = findMatchingBrace(arr, i) orelse break;
                    const obj = arr[i..obj_end];
                    if (try self.extractToolCall(obj)) |tc| {
                        try calls.append(self.alloc, tc);
                    }
                    i = obj_end;
                }
            }
            break; // only the first tool_calls array matters
        }
        return calls.toOwnedSlice(self.alloc);
    }

    fn extractToolCall(self: *ChatClient, obj: []const u8) !?ToolCall {
        const id = extractField(obj, "id") orelse "";
        const name = extractNestedField(obj, "function", "name") orelse return null;
        const raw_args = extractNestedField(obj, "function", "arguments") orelse "";
        // Decode JSON escape sequences (\" → ", \\ → \, etc.) so the
        // tool executor receives clean JSON it can parse.
        const args = try decodeJsonEscapes(self.alloc, raw_args);
        return ToolCall{
            .id = try self.alloc.dupe(u8, id),
            .name = try self.alloc.dupe(u8, name),
            .arguments = try self.alloc.dupe(u8, args),
        };
    }

    /// Decode JSON escape sequences in a string (" → ", \\ → \, etc.).
    /// Returns an owned copy; caller frees.
    fn decodeJsonEscapes(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            if (input[i] == '\\' and i + 1 < input.len) {
                i += 1;
                switch (input[i]) {
                    '"' => try out.append(alloc, '"'),
                    '\\' => try out.append(alloc, '\\'),
                    '/' => try out.append(alloc, '/'),
                    'n' => try out.append(alloc, '\n'),
                    't' => try out.append(alloc, '\t'),
                    'r' => try out.append(alloc, '\r'),
                    else => {
                        try out.append(alloc, '\\');
                        try out.append(alloc, input[i]);
                    },
                }
            } else {
                try out.append(alloc, input[i]);
            }
        }
        return out.toOwnedSlice(alloc);
    }
};

/// DeepSeek API's documented reasoning_effort variants. Values outside this
/// set make the provider reject the whole request body, so anything else
/// persisted in config (e.g. a GUI enum key) is silently omitted.
pub fn validEffort(v: []const u8) bool {
    const variants = [_][]const u8{ "none", "minimal", "low", "medium", "high", "xhigh", "max" };
    for (variants) |want| if (std.mem.eql(u8, v, want)) return true;
    return false;
}

pub fn extractField(obj: []const u8, field: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{field}) catch return null;
    const pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = pos + needle.len;
    // Skip whitespace only — the value's opening quote is a delimiter and
    // must survive to the check below (it used to be eaten here, making
    // every quoted field unreadable).
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) : (i += 1) {}
    if (i >= obj.len) return null;
    if (obj[i] == '"') {
        i += 1;
        const vs = i;
        while (i < obj.len and obj[i] != '"') : (i += 1) {
            if (obj[i] == '\\' and i + 1 < obj.len) i += 1;
        }
        return obj[vs..i];
    }
    return null;
}

pub fn extractNestedField(obj: []const u8, outer: []const u8, inner: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{outer}) catch return null;
    const pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    // pos points at the KEY's opening quote; findMatchingBrace requires a
    // brace start, so advance to the value object's '{' first (passing pos
    // directly used to reject every lookup — tool name/arguments included).
    const brace = std.mem.indexOfScalarPos(u8, obj, pos, '{') orelse return null;
    const obj_end = findMatchingBrace(obj, brace) orelse return null;
    return extractField(obj[brace..obj_end], inner);
}

pub fn escape(alloc: std.mem.Allocator, input: []const u8, out: *std.ArrayList(u8)) !void {
    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
}

pub fn unescape(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Lightweight unescape for content/reasoning (backslash escapes only).
    // Must allocate with the caller's allocator so deinit can free it.
    var out = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            switch (input[i]) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                't' => try out.append(alloc, '\t'),
                else => try out.append(alloc, input[i]),
            }
        } else {
            try out.append(alloc, input[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn findMatchingBrace(json: []const u8, start: usize) ?usize {
    if (start >= json.len or json[start] != '{') return null;
    var count: i32 = 1;
    var i = start + 1;
    while (i < json.len and count > 0) : (i += 1) {
        switch (json[i]) {
            '{' => count += 1,
            '}' => count -= 1,
            '"' => {
                i += 1;
                while (i < json.len and json[i] != '"') : (i += 1) {
                    if (json[i] == '\\') i += 1;
                }
            },
            else => {},
        }
    }
    if (count == 0) return i;
    return null;
}

pub fn findMatchingBracket(json: []const u8, start: usize) ?usize {
    if (start >= json.len or json[start] != '[') return null;
    var count: i32 = 1;
    var i = start + 1;
    while (i < json.len and count > 0) : (i += 1) {
        switch (json[i]) {
            '[' => count += 1,
            ']' => count -= 1,
            '{' => {
                // nested object — skip it. findMatchingBrace returns the
                // index PAST '}', and this loop's continue-expression does
                // another +1; back off by one so the character right after
                // the object (often the array's own ']') gets examined.
                if (findMatchingBrace(json, i)) |be| {
                    i = be - 1;
                    continue;
                }
                return null;
            },
            '"' => {
                i += 1;
                while (i < json.len and json[i] != '"') : (i += 1) {
                    if (json[i] == '\\') i += 1;
                }
            },
            else => {},
        }
    }
    if (count == 0) return i;
    return null;
}

/// True when `body` is a provider error envelope: a JSON object whose FIRST
/// top-level field is "error" (DeepSeek/OpenAI convention). Prose containing
/// the word "error" elsewhere does NOT match.
pub fn isErrorEnvelope(body: []const u8) bool {
    var i: usize = 0;
    while (i < body.len and (body[i] == ' ' or body[i] == '\n' or body[i] == '\r' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len or body[i] != '{') return false;
    i += 1;
    while (i < body.len and (body[i] == ' ' or body[i] == '\n' or body[i] == '\r' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return false;
    i += 1;
    const ks = i;
    while (i < body.len and body[i] != '"') : (i += 1) {
        if (body[i] == '\\' and i + 1 < body.len) i += 1;
    }
    if (i > body.len) return false;
    return std.mem.eql(u8, body[ks..i], "error");
}

/// Extract error.message from a provider error envelope. Caller frees.
pub fn errorMessage(alloc: std.mem.Allocator, body: []const u8) ?[]const u8 {
    return extractStringField(alloc, body, "message") catch null;
}

/// Escape-aware string field extractor: finds `"key":"…"`, scans to the real
/// closing quote (skipping backslash escape pairs), returns the DECODED value.
/// Null when the key is absent or its value is not a plain string.
pub fn extractStringField(alloc: std.mem.Allocator, obj: []const u8, key: []const u8) !?[]const u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = pos + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) : (i += 1) {}
    if (i >= obj.len or obj[i] != '"') return null;
    i += 1;
    const vs = i;
    while (i < obj.len) : (i += 1) {
        if (obj[i] == '\\') {
            if (i + 1 >= obj.len) return null;
            i += 1;
            continue;
        }
        if (obj[i] == '"') return try unescape(alloc, obj[vs..i]);
    }
    return null;
}

/// Append `s` single-quoted for /bin/sh consumption ('\'' escaping).
pub fn appendShellQuoted(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '\'');
    for (s) |ch| {
        if (ch == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, ch);
        }
    }
    try out.append(alloc, '\'');
}

/// Write `data` to an existing (mkstemp-created) private file. Returns false
/// on short writes or close failure.
fn writePrivateFile(path: [:0]const u8, data: []const u8) bool {
    const f = std.c.fopen(path.ptr, "wb") orelse return false;
    const written = std.c.fwrite(data.ptr, 1, data.len, f);
    const closed = std.c.fclose(f) == 0;
    return written == data.len and closed;
}

// ── SSE streaming ───────────────────────────────────────────────────────────

pub const StreamKind = enum { text, reasoning };

/// Incremental SSE parser for OpenAI-style chat streams. Feed raw bytes as
/// they arrive from `curl --no-buffer`; it buffers partial lines, accumulates
/// content / reasoning / tool-call fragments, reports each decoded delta
/// through the optional `sink`, and assembles a ChatResponse in `finish()`.
///
/// Tool-call arguments accumulate in RAW escaped form — byte-identical to
/// what the non-streaming extractor returns — so `parseArgs` and the
/// tool_calls echo keep working unchanged across both transports.
pub const SseParser = struct {
    alloc: std.mem.Allocator,
    line_buf: std.ArrayList(u8),
    content: std.ArrayList(u8),
    reasoning: std.ArrayList(u8),
    slots: [8]?ToolCallSlot = .{ null, null, null, null, null, null, null, null },
    finish_reason_buf: [32]u8 = undefined,
    finish_reason_len: usize = 0,
    done: bool = false,
    sink: ?*const fn (kind: StreamKind, delta: []const u8) void = null,

    pub const ToolCallSlot = struct {
        id: [64]u8 = undefined,
        id_len: usize = 0,
        name: [96]u8 = undefined,
        name_len: usize = 0,
        args: std.ArrayList(u8),
    };

    pub fn init(alloc: std.mem.Allocator) SseParser {
        return .{
            .alloc = alloc,
            .line_buf = .empty,
            .content = .empty,
            .reasoning = .empty,
        };
    }

    pub fn deinit(self: *SseParser) void {
        self.line_buf.deinit(self.alloc);
        self.content.deinit(self.alloc);
        self.reasoning.deinit(self.alloc);
        for (&self.slots) |*slot| {
            if (slot.*) |*s| s.args.deinit(self.alloc);
        }
    }

    /// Consume raw network bytes. Partial lines are buffered until complete.
    pub fn feed(self: *SseParser, bytes: []const u8) !void {
        if (self.done) return;
        for (bytes) |ch| {
            if (ch == '\n') {
                var line = self.line_buf.items;
                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                try self.processLine(line);
                self.line_buf.clearRetainingCapacity();
                if (self.done) return;
            } else {
                try self.line_buf.append(self.alloc, ch);
            }
        }
    }

    fn processLine(self: *SseParser, line: []const u8) !void {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0 or t[0] == ':') return; // event boundary / SSE comment
        if (!std.mem.startsWith(u8, t, "data:")) return; // event:/id:/retry: ignored
        const payload = std.mem.trimStart(u8, t["data:".len..], " \t");
        if (std.mem.eql(u8, payload, "[DONE]")) {
            self.done = true;
            return;
        }
        if (payload.len == 0 or payload[0] != '{') return; // non-JSON keep-alive
        try self.processDelta(payload);
    }

    fn processDelta(self: *SseParser, json: []const u8) !void {
        // Locate choices[0]'s object.
        const cpos = std.mem.indexOf(u8, json, "\"choices\"") orelse return;
        const abrace = std.mem.indexOfScalarPos(u8, json, cpos, '[') orelse return;
        const obj_start = abrace + 1;
        if (obj_start >= json.len or json[obj_start] != '{') return; // empty choices
        const obj_end = findMatchingBrace(json, obj_start) orelse return; // exclusive
        const choice = json[obj_start..obj_end];

        // finish_reason: last non-null value wins.
        if (try extractStringField(self.alloc, choice, "finish_reason")) |fr| {
            defer self.alloc.free(fr);
            const n = @min(fr.len, self.finish_reason_buf.len);
            @memcpy(self.finish_reason_buf[0..n], fr[0..n]);
            self.finish_reason_len = n;
        }

        const dpos = std.mem.indexOf(u8, choice, "\"delta\"") orelse return;
        const dstart = std.mem.indexOfScalarPos(u8, choice, dpos, '{') orelse return;
        const dend = findMatchingBrace(choice, dstart) orelse return; // exclusive
        const delta = choice[dstart..dend];

        if (try extractStringField(self.alloc, delta, "content")) |piece| {
            defer self.alloc.free(piece);
            try self.content.appendSlice(self.alloc, piece);
            if (self.sink) |cb| cb(.text, piece);
        }
        if (try extractStringField(self.alloc, delta, "reasoning_content")) |piece| {
            defer self.alloc.free(piece);
            try self.reasoning.appendSlice(self.alloc, piece);
            if (self.sink) |cb| cb(.reasoning, piece);
        }

        if (std.mem.indexOf(u8, delta, "\"tool_calls\"")) |tcpos| {
            const tab = std.mem.indexOfScalarPos(u8, delta, tcpos, '[') orelse return;
            const tend = findMatchingBracket(delta, tab) orelse return; // exclusive
            var i = tab + 1;
            while (i < tend - 1) {
                if (delta[i] != '{') {
                    i += 1;
                    continue;
                }
                const oe = findMatchingBrace(delta, i) orelse break; // exclusive
                try self.processToolFragment(delta[i..oe]);
                i = oe;
            }
        }
    }

    fn processToolFragment(self: *SseParser, frag: []const u8) !void {
        const idx: usize = extractIntField(frag, "index") orelse 0;
        if (idx >= self.slots.len) return; // cap concurrent streamed calls
        if (self.slots[idx] == null) self.slots[idx] = ToolCallSlot{ .args = .empty };
        const slot = &(self.slots[idx].?);

        // id/name ride the opening fragment only; blank them defensively so a
        // repeated id never truncates against stale bytes.
        if (extractField(frag, "id")) |v| slot.id_len = copyBounded(&slot.id, v);
        if (extractNestedField(frag, "function", "name")) |v| slot.name_len = copyBounded(&slot.name, v);
        if (extractNestedField(frag, "function", "arguments")) |v| {
            try slot.args.appendSlice(self.alloc, v);
        }
    }

    /// Assemble the final response. The parser's buffers are consumed; the
    /// instance must not be fed or finished again afterwards.
    pub fn finish(self: *SseParser) !ChatResponse {
        var has_tools = false;
        for (self.slots) |slot| {
            if (slot != null) has_tools = true;
        }
        var calls = try std.ArrayList(ToolCall).initCapacity(self.alloc, 0);
        errdefer {
            for (calls.items) |tc| {
                self.alloc.free(tc.id);
                self.alloc.free(tc.name);
                self.alloc.free(tc.arguments);
            }
            calls.deinit(self.alloc);
        }
        for (&self.slots) |*slot| {
            const s = &(slot.* orelse continue);
            const args = try s.args.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(args);
            try calls.append(self.alloc, .{
                .id = try self.alloc.dupe(u8, s.id[0..s.id_len]),
                .name = try self.alloc.dupe(u8, s.name[0..s.name_len]),
                .arguments = args,
            });
        }
        const fr = if (self.finish_reason_len > 0)
            try self.alloc.dupe(u8, self.finish_reason_buf[0..self.finish_reason_len])
        else
            try self.alloc.dupe(u8, "stop");
        return .{
            .content = try self.content.toOwnedSlice(self.alloc),
            .reasoning = try self.reasoning.toOwnedSlice(self.alloc),
            .tool_calls = try calls.toOwnedSlice(self.alloc),
            .finish_reason = fr,
            .has_tools = has_tools,
        };
    }
};

fn copyBounded(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// Extract a non-negative integer field (`"key":42`). Null when absent or
/// not a bare number.
fn extractIntField(obj: []const u8, key: []const u8) ?usize {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = pos + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) : (i += 1) {}
    var v: usize = 0;
    var any = false;
    while (i < obj.len and std.ascii.isDigit(obj[i])) : (i += 1) {
        v = v * 10 + (obj[i] - '0');
        any = true;
        if (v > 9999) return null;
    }
    return if (any) v else null;
}

// Regression: arrays whose elements contain nested objects (every real
// tool_calls payload!) must bracket-match correctly. The old skip logic
// jumped past the closing brace AND the next character, so the array's own
// ']' went unseen and the matcher returned null.
// Regression: extractField must treat the value's OPENING quote as a
// delimiter, not consume it. It used to swallow the quote in the whitespace
// skip loop and then bail on the non-quote first value character, returning
// null for every quoted field.
test "extractField reads quoted values" {
    if (extractField("{\"id\":\"call_1\",\"type\":\"function\"}", "id")) |v| {
        try std.testing.expectEqualStrings("call_1", v);
    } else {
        return error.TestUnexpectedResult;
    }
    // Absent keys stay null.
    try std.testing.expect(extractField("{\"id\":\"x\"}", "absent") == null);
}

// Regression: extractNestedField must locate the nested VALUE object's '{'
// after the key — it used to hand the key's opening-quote position straight
// to findMatchingBrace, which rejects non-brace starts, so every nested
// lookup (tool name/arguments!) returned null forever.
test "extractNestedField reads into nested objects" {
    if (extractNestedField("{\"function\":{\"name\":\"shell\",\"arguments\":\"{}\"}}", "function", "name")) |v| {
        try std.testing.expectEqualStrings("shell", v);
    } else {
        return error.TestUnexpectedResult;
    }
    if (extractNestedField(
        "{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}",
        "function",
        "arguments",
    )) |v| {
        // RAW escaped form is the contract (see SseParser note below).
        try std.testing.expectEqualStrings("{\\\"command\\\":\\\"pwd\\\"}", v);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "findMatchingBracket handles nested objects" {
    const arr = "[{\"index\":0,\"function\":{\"name\":\"shell\",\"arguments\":\"\"}}]";
    try std.testing.expectEqual(@as(?usize, arr.len), findMatchingBracket(arr, 0));
}

test "findMatchingBrace basic" {
    try std.testing.expectEqual(@as(?usize, 13), findMatchingBrace("{\"a\":{\"b\":1}}", 0));
}

// Regression: message content containing escaped quotes (\") must survive
// parsing intact. The extractor used to stop at the first '"' BYTE, slicing
// mid-content at the escape sequence instead of the real closing quote.
test "parseResponse keeps escaped quotes in content" {
    const alloc = std.testing.allocator;
    var client = ChatClient.init(alloc, undefined, "https://example.invalid", "m", "");
    const body =
        "{\"choices\":[{\"message\":{\"role\":\"assistant\"," ++
        "\"content\":\"she said \\\"hi\\\" and \\\"bye\\\"\"}," ++
        "\"finish_reason\":\"stop\"}],\"usage\":{}}";
    var res = try client.parseResponse(body);
    defer res.deinit(alloc);
    try std.testing.expectEqualStrings("she said \"hi\" and \"bye\"", res.content);
}

test "isErrorEnvelope distinguishes provider errors from prose" {
    try std.testing.expect(isErrorEnvelope("{\"error\":{\"message\":\"bad key\",\"type\":\"auth_error\"}}"));
    try std.testing.expect(isErrorEnvelope(" \n\r\t{\"error\":{\"message\":\"x\"}}"));
    // Prose that merely mentions "error" is a valid chat response.
    try std.testing.expect(!isErrorEnvelope("{\"choices\":[{\"message\":{\"content\":\"we handle error cases\"}}]}"));
    try std.testing.expect(!isErrorEnvelope("{\"usage\":{\"error_count\":2}}"));
    // Plain-text 400 bodies are rejected by the first-byte check instead.
    try std.testing.expect(!isErrorEnvelope("Failed to parse the request body as JSON: unexpected token"));
}

test "errorMessage extracts provider message" {
    const alloc = std.testing.allocator;
    const m = errorMessage(alloc, "{\"error\":{\"message\":\"Incorrect API key provided\",\"type\":\"auth\"}}") orelse return error.TestUnexpectedResult;
    defer alloc.free(m);
    try std.testing.expectEqualStrings("Incorrect API key provided", m);
}

test "buildCurlConfig carries auth header and timeouts; key stays off argv" {
    const alloc = std.testing.allocator;
    const client = ChatClient.init(alloc, undefined, "https://api.example.com/v1/chat", "m", "sk-secret123");
    const cfg = try client.buildCurlConfig(false);
    defer alloc.free(cfg);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "url = https://api.example.com/v1/chat") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "Authorization: Bearer sk-secret123") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "max-time = 300") != null);
    // Buffered mode carries no SSE-specific lines.
    try std.testing.expect(std.mem.indexOf(u8, cfg, "no-buffer") == null);

    // Streaming mode adds unbuffered delivery + the event-stream accept.
    const scfg = try client.buildCurlConfig(true);
    defer alloc.free(scfg);
    try std.testing.expect(std.mem.indexOf(u8, scfg, "no-buffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, scfg, "Accept: text/event-stream") != null);

    // The command line built by chat() contains only --config '<path>': the
    // key must never appear in argv (ps(1) visibility).
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(alloc);
    try cmd.appendSlice(alloc, "curl --silent --show-error --config ");
    try appendShellQuoted(alloc, &cmd, "/tmp/zharness_curl_abc123");
    try std.testing.expectEqualStrings("curl --silent --show-error --config '/tmp/zharness_curl_abc123'", cmd.items);
    try std.testing.expect(std.mem.indexOf(u8, cmd.items, "sk-secret123") == null);
}

test "extractStringField decodes escapes and skips non-strings" {
    const alloc = std.testing.allocator;
    const v = (try extractStringField(alloc, "{\"a\":\"line\\nbreak \\\"q\\\" end\"}", "a")).?;
    defer alloc.free(v);
    try std.testing.expectEqualStrings("line\nbreak \"q\" end", v);
    try std.testing.expect((try extractStringField(alloc, "{\"a\":null}", "a")) == null);
    try std.testing.expect((try extractStringField(alloc, "{\"b\":\"x\"}", "a")) == null);
}

// ── SSE streaming (Wave F) ─────────────────────────────────────────────────

test "SseParser accumulates streamed deltas" {
    const alloc = std.testing.allocator;
    var p = SseParser.init(alloc);
    defer p.deinit();
    try p.feed("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n");
    try p.feed("data: {\"choices\":[{\"delta\":{\"content\":\"He\"},\"finish_reason\":null}]}\n");
    try p.feed("data: {\"choices\":[{\"delta\":{\"content\":\"llo\"},\"finish_reason\":null}]}\n\n");
    try p.feed("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"},\"finish_reason\":null}]}\n\n");
    try p.feed("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n");
    try p.feed("data: [DONE]\n\n");
    var r = try p.finish();
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("Hello", r.content);
    try std.testing.expectEqualStrings("think", r.reasoning);
    try std.testing.expect(!r.has_tools);
    try std.testing.expectEqualStrings("stop", r.finish_reason);
}

test "SseParser buffers partial lines across feeds" {
    const alloc = std.testing.allocator;
    var p = SseParser.init(alloc);
    defer p.deinit();
    // One data line split mid-JSON across three feeds.
    try p.feed("data: {\"choices\":[{\"del");
    try p.feed("ta\":{\"content\":\"wor");
    try p.feed("ld\"},\"finish_reason\":null}]}\n");
    try p.feed("data: [DONE]\n");
    var r = try p.finish();
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("world", r.content);
}

test "SseParser reassembles streamed tool_calls" {
    const alloc = std.testing.allocator;
    var p = SseParser.init(alloc);
    defer p.deinit();
    // First fragment carries id/name; arguments arrive split across chunks.
    try p.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}\n\n");
    try p.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"command\\\":\"}}]},\"finish_reason\":null}]}\n\n");
    try p.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"pwd\\\"}\"}}]},\"finish_reason\":null}]}\n\n");
    try p.feed("data: [DONE]\n\n");
    var r = try p.finish();
    defer r.deinit(alloc);
    try std.testing.expect(r.has_tools);
    try std.testing.expectEqual(@as(usize, 1), r.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", r.tool_calls[0].id);
    try std.testing.expectEqualStrings("shell", r.tool_calls[0].name);
    // Arguments stay RAW (escaped source form) — same contract as the
    // non-streaming parser, so parseArgs/tool echo keep working unchanged.
    try std.testing.expectEqualStrings("{\\\"command\\\":\\\"pwd\\\"}", r.tool_calls[0].arguments);
}

test "SseParser ignores non-data lines and CRLF" {
    const alloc = std.testing.allocator;
    var p = SseParser.init(alloc);
    defer p.deinit();
    try p.feed(": keep-alive\n\n");
    try p.feed("event: ping\r\n\r\n");
    try p.feed("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\r\n\r\n");
    try p.feed("data: [DONE]\r\n\r\n");
    var r = try p.finish();
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("ok", r.content);
}
