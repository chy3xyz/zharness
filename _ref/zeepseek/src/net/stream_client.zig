const std = @import("std");
const http = std.http;

const RateLimiter = @import("http_client.zig").RateLimiter;
const CircuitBreaker = @import("http_client.zig").CircuitBreaker;
const CacheConfig = @import("http_client.zig").CacheConfig;
const http2 = @import("http_client2.zig");
const h2_client = @import("h2_client.zig");
const tool_registry = @import("../utils/tool_registry.zig");

fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8, output: *std.ArrayList(u8)) !void {
    for (input) |c| {
        switch (c) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            else => try output.append(allocator, c),
        }
    }
}

pub const CtxItem = struct { role: []const u8, content: []const u8, tool_call_id: []const u8 = "", tool_calls_json: []const u8 = "" };

pub const ThinkingConfig = struct {
    enabled: bool = true,
    render_inline: bool = true,
};

fn unescapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            if (input[i] == '\\' and i + 1 < input.len) {
                i += 1;
                switch (input[i]) {
                    '"' => try result.append(allocator, '"'),
                    '\\' => try result.append(allocator, '\\'),
                    'n' => try result.append(allocator, '\n'),
                    'r' => try result.append(allocator, '\r'),
                    't' => try result.append(allocator, '\t'),
                    else => {
                        try result.append(allocator, '\\');
                        try result.append(allocator, input[i]);
                    },
                }
            } else {
                try result.append(allocator, input[i]);
            }
        }
        return result.toOwnedSlice(allocator);
    }
/// Parse an OpenAI/DeepSeek API error body (JSON) into a concise
/// human-readable detail string. Falls back to the raw body if the JSON
/// does not contain an expected message field or cannot be parsed.
pub fn formatHttpErrorDetail(allocator: std.mem.Allocator, status: u16, body: []const u8) []const u8 {
    if (std.json.parseFromSlice(std.json.Value, allocator, body, .{})) |parsed| {
        defer parsed.deinit();
        const root = parsed.value;
        var msg: ?[]const u8 = null;
        if (root == .object) {
            const o = root.object;
            if (o.get("error")) |e| {
                if (e == .object) {
                    if (e.object.get("message")) |m| {
                        msg = switch (m) {
                            .string => |s| s,
                            else => null,
                        };
                    }
                }
            }
            if (msg == null) {
                if (o.get("message")) |m| {
                    msg = switch (m) {
                        .string => |s| s,
                        else => null,
                    };
                }
            }
            if (msg == null) {
                if (o.get("detail")) |d| {
                    msg = switch (d) {
                        .string => |s| s,
                        else => null,
                    };
                }
            }
        }
        if (msg) |m| {
            const trimmed = std.mem.trim(u8, m, " \t\r\n");
            if (trimmed.len > 0) {
                return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, trimmed }) catch "";
            }
        }
    } else |_| {}

    // No parseable JSON message — surface the raw payload so the cause is visible.
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, body }) catch "";
}

pub const DeepSeekStreamClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    rate_limiter: ?*RateLimiter = null,
    circuit_breaker: ?*CircuitBreaker = null,
    endpoint: []const u8 = "https://api.deepseek.com/chat/completions",
    /// Extra OpenAI-format tool definitions (comma-separated fragments, no
    /// brackets) appended after the built-in tools — used for MCP tools.
    extra_tools: []const u8 = "",
    last_http_status: u16 = 0,
    last_http_body: ?[]u8 = null,
    request: ?http.Client.Request = null,
    response: ?http.Client.Response = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        rate_limiter: ?*RateLimiter,
        circuit_breaker: ?*CircuitBreaker,
    ) DeepSeekStreamClient {
        return .{
            .allocator = allocator,
            .io = io,
            .rate_limiter = rate_limiter,
            .circuit_breaker = circuit_breaker,
        };
    }

    pub fn deinit(_: *DeepSeekStreamClient) void {}

    pub const StreamEvent = struct {
        content: []const u8,
        done: bool = false,
    };

    pub fn streamMessage(
        self: *DeepSeekStreamClient,
        api_key: []const u8,
        prompt: []const u8,
        context: []const CtxItem,
        model: []const u8,
        cache_decision: anytype,
        system_prompt: []const u8,
        reasoning_effort: ?[]const u8,
    ) !StreamIterator {
        if (self.circuit_breaker) |cb| {
            if (cb.isOpen()) return error.CircuitOpen;
        }

        if (self.rate_limiter) |rl| {
            try rl.wait();
        }

        // endpoint is the full request URL (e.g.
        // "https://api.deepseek.com/chat/completions"). Use its path as-is.
        const uri = std.Uri.parse(self.endpoint) catch return error.InvalidUri;

        const body = try self.buildRequestBody(prompt, context, model, cache_decision, system_prompt, reasoning_effort, false);
        defer self.allocator.free(body);

        const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
        defer self.allocator.free(auth_value);

        const headers = [_]http2.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "text/event-stream" },
        };

        // Unified client: HTTPS -> std.http (TLS), plain HTTP -> raw socket
        // with read timeout (L3). Matches the zigmodu approach.
        const scheme = uri.scheme;
        const host = uri.host.?.percent_encoded;
        const port: u16 = uri.port orelse if (std.mem.eql(u8, scheme, "https")) 443 else 80;

        var h2 = http2.HttpClient.init(self.allocator, self.io);
        h2.config = .{ .read_timeout_ms = 60_000 };
        var path_buf: [256]u8 = undefined;
        const base_path = uri.path.percent_encoded;
        const req_path = if (std.mem.endsWith(u8, base_path, "/chat/completions"))
            base_path
        else
            std.fmt.bufPrint(&path_buf, "{s}/chat/completions", .{base_path}) catch base_path;
        var resp = h2.open(scheme, host, port, "POST", req_path, &headers, body) catch return error.HttpError;
        errdefer resp.deinit();
        self.last_http_status = @intCast(resp.status);
        if (resp.status < 200 or resp.status >= 300) {
            if (self.circuit_breaker) |cb| {
                cb.recordFailure();
            }

            // Capture the response body so the UI can show *why* the request failed.
            var err_buf: [4096]u8 = undefined;
            const n = resp.readBody(&err_buf) catch 0;
            if (self.last_http_body) |old| self.allocator.free(old);
            self.last_http_body = self.allocator.dupe(u8, err_buf[0..n]) catch null;

            return error.HttpError;
        }

        return StreamIterator{
            .allocator = self.allocator,
            .resp = resp,
            .buffer = try std.ArrayList(u8).initCapacity(self.allocator, 4096),
            .line_accumulator = try std.ArrayList(u8).initCapacity(self.allocator, 4096),
            .tool_call_json = .empty,
        };
    }

    fn buildRequestBody(
        self: *DeepSeekStreamClient,
        prompt: []const u8,
        context: []const CtxItem,
        model: []const u8,
        cache_decision: anytype,
        system_prompt: []const u8,
        reasoning_effort: ?[]const u8,
        stream: bool,
    ) ![]u8 {
        var body = try std.ArrayList(u8).initCapacity(self.allocator, 2048);
        errdefer body.deinit(self.allocator);

        try body.appendSlice(self.allocator, "{\"model\":\"");
        try body.appendSlice(self.allocator, model);
        try body.appendSlice(self.allocator, "\",\"stream\":");
        try body.appendSlice(self.allocator, if (stream) "true" else "false");
        try body.appendSlice(self.allocator, ",\"messages\":[");

        const tool_rules = "Tool usage: the shell tool expects a direct command string (e.g. \"ls -la\"). Never wrap it in sh -c or bash -c (those are blocked).";
        const full_system = if (system_prompt.len > 0)
            try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ system_prompt, tool_rules })
        else
            tool_rules;
        defer if (system_prompt.len > 0) self.allocator.free(full_system);
        {
            const cache_tag = switch (cache_decision) {
                .hit => "(cache)",
                .miss => "",
                .none => "",
            };
            try body.appendSlice(self.allocator, "{\"role\":\"system\",\"content\":\"");
            try escapeJsonString(self.allocator, full_system, &body);
            if (cache_tag.len > 0) {
                try body.appendSlice(self.allocator, " ");
                try body.appendSlice(self.allocator, cache_tag);
            }
            try body.appendSlice(self.allocator, "\"}");
        }

        for (context) |ctx| {
            if (body.items.len > 0 and body.items[body.items.len - 1] != '[') {
                try body.appendSlice(self.allocator, ",");
            }
            try body.appendSlice(self.allocator, "{\"role\":\"");
            try body.appendSlice(self.allocator, ctx.role);
            if (std.mem.eql(u8, ctx.role, "tool") and ctx.tool_call_id.len > 0) {
                try body.appendSlice(self.allocator, "\",\"tool_call_id\":\"");
                try escapeJsonString(self.allocator, ctx.tool_call_id, &body);
                try body.appendSlice(self.allocator, "\",\"content\":\"");
                try escapeJsonString(self.allocator, ctx.content, &body);
                try body.appendSlice(self.allocator, "\"}");
            } else if (ctx.tool_calls_json.len > 0) {
                // Assistant message that requested tool calls: echo the
                // tool_calls array (and null content) so the API accepts the
                // subsequent tool `role` results. Without this the native
                // function-calling loop is rejected.
                try body.appendSlice(self.allocator, "\",\"content\":null,\"tool_calls\":");
                try body.appendSlice(self.allocator, ctx.tool_calls_json);
                try body.appendSlice(self.allocator, "}");
            } else {
                try body.appendSlice(self.allocator, "\",\"content\":\"");
                try escapeJsonString(self.allocator, ctx.content, &body);
                try body.appendSlice(self.allocator, "\"}");
            }
        }

        if (body.items.len > 0 and body.items[body.items.len - 1] != '[') {
            try body.appendSlice(self.allocator, ",");
        }
        try body.appendSlice(self.allocator, "{\"role\":\"user\",\"content\":\"");
        try escapeJsonString(self.allocator, prompt, &body);
        try body.appendSlice(self.allocator, "\"}");

        try body.appendSlice(self.allocator, "],\"tools\":[");
        // Native function-calling declarations generated from the single source
        // of truth (ToolRegistry) so request schemas can never drift from what
        // the executor actually knows. Comma-joined, no outer brackets.
        const tools_json = try tool_registry.buildToolsJson(self.allocator);
        defer self.allocator.free(tools_json);
        const has_native = tools_json.len > 0;
        const has_mcp = self.extra_tools.len > 0;
        // Join native + MCP fragments with a comma only when both are present,
        // so an empty native registry degrades to the MCP fragment alone
        // instead of emitting the invalid `[, <mcp>]`.
        if (has_native) {
            try body.appendSlice(self.allocator, tools_json);
            if (has_mcp) try body.appendSlice(self.allocator, ",");
        }
        if (has_mcp) {
            try body.appendSlice(self.allocator, self.extra_tools);
        }
        try body.appendSlice(self.allocator, "],\"tool_choice\":\"auto\"");

        if (reasoning_effort) |effort| {
            try body.appendSlice(self.allocator, ",\"reasoning_effort\":\"");
            try body.appendSlice(self.allocator, effort);
            try body.appendSlice(self.allocator, "\"}");
        } else {
            try body.appendSlice(self.allocator, "}");
        }

        return body.toOwnedSlice(self.allocator);
    }
};

pub const StreamChunk = union(enum) {
    content: []const u8,
    reasoning: []const u8,
};

pub const StreamIterator = struct {
    allocator: std.mem.Allocator,
    resp: http2.StreamingResponse,
    buffer: std.ArrayList(u8),
    line_accumulator: std.ArrayList(u8),
    done: bool = false,
    content_buffer: []const u8 = &.{},
    reasoning_buffer: []const u8 = &.{},
    tool_call_json: std.ArrayList(u8),
    has_tool_calls: bool = false,

    /// Non-streaming response mode (stream:false). std.http + Threaded io
    /// mis-report EOF on chunked streaming bodies on macOS (see zigmodu's
    /// sockread notes), so we request a complete JSON response instead and
    /// parse message.content here.
    fn extractMessageContent(self: *StreamIterator, json: []const u8) !struct { content: []const u8, reasoning: []const u8 } {
        var content_result: []const u8 = "";
        var reasoning_result: []const u8 = "";
        // tool_calls detection
        if (std.mem.indexOf(u8, json, "\"tool_calls\"") != null or
            std.mem.indexOf(u8, json, "\"tool_call\"") != null)
        {
            self.has_tool_calls = true;
            try self.tool_call_json.appendSlice(self.allocator, json);
        }
        // find "message":{ ... }
        if (std.mem.indexOf(u8, json, "\"message\"")) |mi| {
            const brace = std.mem.indexOfScalarPos(u8, json, mi, '{') orelse return .{ .content = content_result, .reasoning = reasoning_result };
            const end = try self.findMatchingBrace(json, brace) orelse return .{ .content = content_result, .reasoning = reasoning_result };
            const msg = json[brace..end];
            if (std.mem.indexOf(u8, msg, "\"content\":\"")) |ci| {
                const vs = ci + 11;
                if (std.mem.indexOfScalarPos(u8, msg, vs, '"')) |ve| {
                    content_result = try unescapeJsonString(self.allocator, msg[vs..ve]);
                }
            }
            if (std.mem.indexOf(u8, msg, "\"reasoning_content\":\"")) |ri| {
                const vs = ri + 22;
                if (std.mem.indexOfScalarPos(u8, msg, vs, '"')) |ve| {
                    reasoning_result = try unescapeJsonString(self.allocator, msg[vs..ve]);
                }
            }
        }
        return .{ .content = content_result, .reasoning = reasoning_result };
    }

    pub fn nextChunk(self: *StreamIterator) !?StreamChunk {
        if (self.done) return null;
        // Read the complete body (non-streaming JSON).
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = self.resp.readBody(&read_buf) catch |err| return err;
            if (n == 0) break;
            try body.appendSlice(self.allocator, read_buf[0..n]);
        }
        self.done = true;

        const parsed = try self.extractMessageContent(body.items);
        if (parsed.reasoning.len > 0) {
            const r = parsed.reasoning;
            return StreamChunk{ .reasoning = r };
        }
        if (parsed.content.len > 0) {
            return StreamChunk{ .content = parsed.content };
        }
        return null;
    }

    pub fn nextChunkStreaming(self: *StreamIterator) !?StreamChunk {
        if (self.done and self.content_buffer.len == 0 and self.reasoning_buffer.len == 0) return null;
        if (self.reasoning_buffer.len > 0) {
            const chunk = self.reasoning_buffer;
            self.reasoning_buffer = &.{};
            return StreamChunk{ .reasoning = chunk };
        }
        if (self.content_buffer.len > 0) {
            const chunk = self.content_buffer;
            self.content_buffer = &.{};
            return StreamChunk{ .content = chunk };
        }

        while (true) {
            // Process every complete line already buffered before reading more,
            // so an EOF (read -> 0) never drops trailing SSE events.
            while (true) {
                const nl = std.mem.indexOfScalar(u8, self.line_accumulator.items, '\n');
                if (nl == null) break;
                const newline_idx = nl.?;
                // NOTE: `line`/`data_value` alias line_accumulator.items, so all
                // decisions and any needed copy must happen BEFORE the buffer is
                // cleared/rewritten with the remainder.
                const line = self.line_accumulator.items[0 .. newline_idx + 1];
                const remainder_len = self.line_accumulator.items.len - (newline_idx + 1);
                const remainder = self.line_accumulator.items[newline_idx + 1 ..];

                const trimmed = std.mem.trim(u8, line, "\r\n");
                if (trimmed.len == 0 or trimmed[0] == ':' or
                    !std.mem.startsWith(u8, trimmed, "data:"))
                {
                    // Not a data line: keep the remainder for the next line.
                    self.line_accumulator.clearRetainingCapacity();
                    if (remainder_len > 0) {
                        const owned = try self.allocator.dupe(u8, remainder);
                        defer self.allocator.free(owned);
                        try self.line_accumulator.appendSlice(self.allocator, owned);
                    }
                    continue;
                }

                // Duplicate the payload so it survives the buffer rewrite.
                const data_value = std.mem.trim(u8, trimmed[5..], " ");
                const data_owned = try self.allocator.dupe(u8, data_value);
                defer self.allocator.free(data_owned);

                self.line_accumulator.clearRetainingCapacity();
                if (remainder_len > 0) {
                    const owned = try self.allocator.dupe(u8, remainder);
                    defer self.allocator.free(owned);
                    try self.line_accumulator.appendSlice(self.allocator, owned);
                }

                if (data_owned.len == 0) continue;
                if (std.mem.eql(u8, data_owned, "[DONE]")) {
                    self.done = true;
                    return null;
                }

                const extracted = try self.extractContentAndReasoning(data_owned);
                // Chunks are caller-owned once returned; free any unconsumed
                // buffer before overwriting it with a newer extraction.
                if (self.reasoning_buffer.len > 0) self.allocator.free(self.reasoning_buffer);
                if (self.content_buffer.len > 0) self.allocator.free(self.content_buffer);
                self.reasoning_buffer = extracted.reasoning;
                self.content_buffer = extracted.content;
                if (self.reasoning_buffer.len > 0 or self.content_buffer.len > 0) {
                    return self.nextChunk();
                }
            }

            var read_buf: [4096]u8 = undefined;
            const n = self.resp.readBody(&read_buf) catch |err| return err;
            if (n == 0) {
                self.done = true;
                return null;
            }
            try self.line_accumulator.appendSlice(self.allocator, read_buf[0..n]);

            if (std.mem.indexOfScalar(u8, self.line_accumulator.items, '\n')) |newline_idx| {
                const line = self.line_accumulator.items[0 .. newline_idx + 1];
                const remainder = self.line_accumulator.items[newline_idx + 1 ..];
                const remainder_copy = try self.allocator.dupe(u8, remainder);
                defer self.allocator.free(remainder_copy);
                self.line_accumulator.clearRetainingCapacity();
                if (remainder_copy.len > 0) {
                    try self.line_accumulator.appendSlice(self.allocator, remainder_copy);
                }
                const trimmed = std.mem.trim(u8, line, "\r\n");
                if (trimmed.len == 0) continue;
                if (trimmed[0] == ':') continue;
                if (!std.mem.startsWith(u8, trimmed, "data:")) continue;

                const data_value = std.mem.trim(u8, trimmed[5..], " ");
                if (data_value.len == 0) continue;
                if (std.mem.eql(u8, data_value, "[DONE]")) {
                    self.done = true;
                    return null;
                }

                const extracted = try self.extractContentAndReasoning(data_value);
                if (extracted.reasoning.len > 0) {
                    self.reasoning_buffer = extracted.reasoning;
                }
                if (extracted.content.len > 0) {
                    self.content_buffer = extracted.content;
                }
                if (self.reasoning_buffer.len > 0 or self.content_buffer.len > 0) {
                    return self.nextChunk();
                }
                continue;
            }
        }
    }



    fn extractContentAndReasoning(self: *StreamIterator, json_data: []const u8) !struct { content: []const u8, reasoning: []const u8 } {
        var content_result: []const u8 = "";
        var reasoning_result: []const u8 = "";
        var i: usize = 0;

        // First, check for tool_calls anywhere in the JSON
        if (std.mem.indexOf(u8, json_data, "\"tool_calls\"") != null or
            std.mem.indexOf(u8, json_data, "\"tool_call\"") != null)
        {
            self.has_tool_calls = true;
            try self.tool_call_json.appendSlice(self.allocator, json_data);
            try self.tool_call_json.appendSlice(self.allocator, "\n");
        }

        while (i < json_data.len) : (i += 1) {
            if (i + 7 <= json_data.len and std.mem.eql(u8, json_data[i..i+7], "\"delta\"")) {
                i += 7;
                while (i < json_data.len and json_data[i] != '{') : (i += 1) {}
                if (i < json_data.len) {
                    const brace_count = try self.findMatchingBrace(json_data, i);
                    if (brace_count) |end| {
                        const delta_json = json_data[i..end];

                        var ci: usize = 0;
                        while (ci < delta_json.len) : (ci += 1) {
                            if (ci + 10 <= delta_json.len and std.mem.eql(u8, delta_json[ci..ci+10], "\"content\":")) {
                                ci += 10;
                                while (ci < delta_json.len and delta_json[ci] == ' ') : (ci += 1) {}
                                if (ci < delta_json.len and delta_json[ci] == '"') {
                                    ci += 1;
                                    const value_start = ci;
                                    while (ci < delta_json.len and delta_json[ci] != '"') : (ci += 1) {
                                        if (delta_json[ci] == '\\' and ci + 1 < delta_json.len) ci += 1;
                                    }
                                    content_result = try unescapeJsonString(self.allocator, delta_json[value_start..ci]);
                                }
                            }

                            if (ci + 20 <= delta_json.len and std.mem.eql(u8, delta_json[ci..ci+20], "\"reasoning_content\":")) {
                                ci += 20;
                                while (ci < delta_json.len and delta_json[ci] == ' ') : (ci += 1) {}
                                if (ci < delta_json.len and delta_json[ci] == '"') {
                                    ci += 1;
                                    const value_start = ci;
                                    while (ci < delta_json.len and delta_json[ci] != '"') : (ci += 1) {
                                        if (delta_json[ci] == '\\' and ci + 1 < delta_json.len) ci += 1;
                                    }
                                    reasoning_result = try unescapeJsonString(self.allocator, delta_json[value_start..ci]);
                                }
                            }
                        }
                    }
                }
            }
        }
        return .{ .content = content_result, .reasoning = reasoning_result };
    }

    fn findMatchingBrace(self: *StreamIterator, json_data: []const u8, start: usize) !?usize {
        _ = self;
        if (start >= json_data.len or json_data[start] != '{') return null;
        var count: i32 = 1;
        var i = start + 1;
        while (i < json_data.len and count > 0) : (i += 1) {
            switch (json_data[i]) {
                '{' => count += 1,
                '}' => count -= 1,
                '"' => {
                    i += 1;
                    while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                        if (json_data[i] == '\\') i += 1;
                    }
                },
                else => {},
            }
        }
        if (count == 0) return i;
        return null;
    }

    pub fn deinit(self: *StreamIterator) void {
        if (self.content_buffer.len > 0) self.allocator.free(self.content_buffer);
        if (self.reasoning_buffer.len > 0) self.allocator.free(self.reasoning_buffer);
        self.resp.deinit();
        self.buffer.deinit(self.allocator);
        self.line_accumulator.deinit(self.allocator);
        self.tool_call_json.deinit(self.allocator);
    }
};

pub const ToolCallRepairPipeline = struct {
    allocator: std.mem.Allocator,
    seen_signatures: std.StringHashMap(void),
    accumulators: std.AutoHashMap(usize, []u8),
    max_accumulators: usize = 8,
    last_seen_names: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) ToolCallRepairPipeline {
        return .{
            .allocator = allocator,
            .seen_signatures = std.StringHashMap(void).init(allocator),
            .accumulators = std.AutoHashMap(usize, []u8).init(allocator),
            .last_seen_names = .empty,
        };
    }

    pub fn deinit(self: *ToolCallRepairPipeline) void {
        var sig_iter = self.seen_signatures.keyIterator();
        while (sig_iter.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.seen_signatures.deinit();
        var acc_iter = self.accumulators.iterator();
        while (acc_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.accumulators.deinit();
        for (self.last_seen_names.items) |name| {
            self.allocator.free(name);
        }
        self.last_seen_names.deinit(self.allocator);
    }

    pub const ToolCallResult = struct {
        calls: []ToolCallExtracted,
        content_delta: []const u8,
        done: bool,
    };

    pub const ToolCallExtracted = struct {
        index: usize,
        id: []const u8,
        name: []const u8,
        arguments: []const u8,
        signature: []const u8,
    };

    pub fn processChunk(
        self: *ToolCallRepairPipeline,
        json_data: []const u8,
    ) !ToolCallResult {
        var content_buf: []const u8 = "";
        var extracted_calls: std.ArrayList(ToolCallExtracted) = .empty;
        var i: usize = 0;

        while (i < json_data.len) : (i += 1) {
            if (i + 5 <= json_data.len and std.mem.eql(u8, json_data[i..i+5], "\"tool")) {
                const tc_result = try self.parseToolCallsFromDelta(json_data, &i);
                if (tc_result) |calls| {
                    defer self.allocator.free(calls);
                    for (calls) |call| {
                        try extracted_calls.append(self.allocator, call);
                    }
                }
            } else if (i + 9 <= json_data.len and std.mem.eql(u8, json_data[i..i+9], "\"content\":")) {
                i += 9;
                while (i < json_data.len and (json_data[i] == ' ' or json_data[i] == '"')) : (i += 1) {}
                if (i < json_data.len and json_data[i] == '"') {
                    i += 1;
                    const value_start = i;
                    while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                        if (json_data[i] == '\\' and i + 1 < json_data.len) i += 1;
                    }
                    content_buf = json_data[value_start..i];
                }
            } else if (i + 18 <= json_data.len and std.mem.eql(u8, json_data[i..i+18], "\"reasoning_content\":")) {
                i += 18;
                while (i < json_data.len and (json_data[i] == ' ' or json_data[i] == '"')) : (i += 1) {}
                if (i < json_data.len and json_data[i] == '"') {
                    i += 1;
                    while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                        if (json_data[i] == '\\' and i + 1 < json_data.len) i += 1;
                    }
                }
            }
        }

        return .{
            .calls = try extracted_calls.toOwnedSlice(self.allocator),
            .content_delta = content_buf,
            .done = extracted_calls.items.len > 0,
        };
    }

    fn parseToolCallsFromDelta(
        self: *ToolCallRepairPipeline,
        json_data: []const u8,
        inout_i: *usize,
    ) !?[]ToolCallExtracted {
        var calls: std.ArrayList(ToolCallExtracted) = .empty;
        var i = inout_i.*;


        if (std.mem.startsWith(u8, json_data[i..], "\"tool_calls\":")) {
            i += 13;
            while (i < json_data.len and json_data[i] == ' ') : (i += 1) {}

            if (i < json_data.len and json_data[i] == '[') {
                i += 1;
                while (i < json_data.len and json_data[i] == ' ') : (i += 1) {}

                while (i < json_data.len and json_data[i] != ']') {
                    while (i < json_data.len and json_data[i] == ' ') : (i += 1) {}
                    if (i >= json_data.len or json_data[i] == ']') break;

                    if (json_data[i] == '{') {
                        const obj_end = findMatchingBrace(json_data, i);
                        const obj_data = if (obj_end) |end|
                            json_data[i..end + 1]
                        else
                            json_data[i..];
                        if (try self.extractSingleToolCall(obj_data)) |e| try calls.append(self.allocator, e);
                        if (obj_end == null) break;
                        i = obj_end.? + 1;
                    } else {
                        i += 1;
                    }
                    while (i < json_data.len and (json_data[i] == ' ' or json_data[i] == ',')) : (i += 1) {}
                }
                if (i < json_data.len and json_data[i] == ']') i += 1;
            }
        } else if (std.mem.startsWith(u8, json_data[i..], "\"tool_call\":")) {
            i += 12;
            while (i < json_data.len and json_data[i] == ' ') : (i += 1) {}
            if (i < json_data.len and json_data[i] == '{') {
                const obj_end = findMatchingBrace(json_data, i);
                const obj_data = if (obj_end) |end|
                    json_data[i..end + 1]
                else
                    json_data[i..];
                if (try self.extractSingleToolCall(obj_data)) |e| try calls.append(self.allocator, e);
                if (obj_end == null) {
                    inout_i.* = json_data.len;
                } else {
                    inout_i.* = obj_end.? + 1;
                }
                if (calls.items.len > 0) return try calls.toOwnedSlice(self.allocator);
                return null;
            }
        }

        inout_i.* = i;
        if (calls.items.len > 0) return try calls.toOwnedSlice(self.allocator);
        return null;
    }

    fn findMatchingBrace(json_data: []const u8, start: usize) ?usize {
        if (start >= json_data.len or json_data[start] != '{') return null;
        var count: i32 = 1;
        var i = start + 1;
        while (i < json_data.len and count > 0) : (i += 1) {
            switch (json_data[i]) {
                '{' => count += 1,
                '}' => {
                    count -= 1;
                    if (count == 0) return i;
                },
                '"' => {
                    i += 1;
                    while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                        if (json_data[i] == '\\' and i + 1 < json_data.len) i += 1;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    const ToolCallJson = struct {
    id: ?[]const u8 = null,
        index: usize = 0,
        function: struct {
            name: []const u8 = "",
            arguments: []const u8 = "",
        } = .{},
    };

    fn extractSingleToolCall(self: *ToolCallRepairPipeline, obj_data: []const u8) !?ToolCallExtracted {
        const parsed = std.json.parseFromSlice(ToolCallJson, self.allocator, obj_data, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        if (parsed.value.function.name.len == 0) return null;
        return ToolCallExtracted{
            .index = parsed.value.index,
            .id = if (parsed.value.id) |cid|
                try self.allocator.dupe(u8, cid)
            else
                try self.allocator.dupe(u8, ""),
            .name = try self.allocator.dupe(u8, parsed.value.function.name),
            .arguments = try self.allocator.dupe(u8, parsed.value.function.arguments),
            .signature = try self.allocator.dupe(u8, ""),
        };
    }

    pub fn suppressRepeats(self: *ToolCallRepairPipeline, calls: []const ToolCallExtracted) ![]ToolCallExtracted {
        var kept: std.ArrayList(ToolCallExtracted) = .empty;
        for (calls) |call| {
            const sig = try std.fmt.allocPrint(self.allocator, "{d}:{s}", .{ call.index, call.name });
            defer self.allocator.free(sig);
            const gop = try self.seen_signatures.getOrPut(sig);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, sig);
                gop.value_ptr.* = {};
                try kept.append(self.allocator, call);
            }
        }
        return kept.toOwnedSlice(self.allocator);
    }

    pub fn balanceJson(self: *ToolCallRepairPipeline, text: []const u8) ![]const u8 {
        var open_braces: i32 = 0;
        var open_brackets: i32 = 0;
        var in_string: bool = false;
        var escaped: bool = false;

        for (text) |c| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') {
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;

            switch (c) {
                '{' => open_braces += 1,
                '}' => open_braces -= 1,
                '[' => open_brackets += 1,
                ']' => open_brackets -= 1,
                else => {},
            }
        }

        var balanced = std.ArrayList(u8).empty;
        defer balanced.deinit(self.allocator);
        try balanced.appendSlice(self.allocator, text);

        if (in_string) {
            try balanced.append(self.allocator, '"');
        }
        while (open_brackets > 0) {
            try balanced.append(self.allocator, ']');
            open_brackets -= 1;
        }
        while (open_braces > 0) {
            try balanced.append(self.allocator, '}');
            open_braces -= 1;
        }

        return balanced.toOwnedSlice(self.allocator);
    }

    pub fn repairAndParse(self: *ToolCallRepairPipeline, raw_json: []const u8) !?ToolCallExtracted {
        const balanced = try self.balanceJson(raw_json);
        defer self.allocator.free(balanced);

        const repaired = try self.repairJsonFragment(balanced);
        defer self.allocator.free(repaired);

        return try self.extractSingleToolCall(repaired);
    }

    fn repairJsonFragment(self: *ToolCallRepairPipeline, text: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len) {
                try result.append(self.allocator, text[i]);
                try result.append(self.allocator, text[i + 1]);
                i += 1;
                continue;
            }
            if (text[i] == '"') {
                try result.append(self.allocator, text[i]);
                i += 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '\\') {
                        try result.append(self.allocator, text[i]);
                        if (i + 1 < text.len) {
                            try result.append(self.allocator, text[i + 1]);
                            i += 1;
                        }
                    } else if (text[i] == '"') {
                        try result.append(self.allocator, text[i]);
                        break;
                    } else {
                        try result.append(self.allocator, text[i]);
                    }
                }
            } else {
                try result.append(self.allocator, text[i]);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};

fn freeToolCalls(alloc: std.mem.Allocator, calls: []const ToolCallRepairPipeline.ToolCallExtracted) void {
    for (calls) |call| {
        if (call.id.len > 0) alloc.free(call.id);
        if (call.name.len > 0) alloc.free(call.name);
        if (call.arguments.len > 0) alloc.free(call.arguments);
        if (call.signature.len > 0) alloc.free(call.signature);
    }
}

test "tool call repair pipeline init and deinit" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();
    try std.testing.expect(pipeline.seen_signatures.count() == 0);
}

test "tool call repair pipeline basic parse" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    const json = "{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}";
    const result = try pipeline.processChunk(json);
    defer std.testing.allocator.free(result.calls);
    defer freeToolCalls(std.testing.allocator, result.calls);

    try std.testing.expect(result.calls.len == 1);
    try std.testing.expectEqualSlices(u8, "bash", result.calls[0].name);
    try std.testing.expectEqualSlices(u8, "{\"command\":\"ls\"}", result.calls[0].arguments);
    try std.testing.expectEqual(@as(usize, 0), result.calls[0].index);
}

test "tool call repair pipeline suppress repeats" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    const json1 = "{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}";
    const json2 = "{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}";
    const json3 = "{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"ls\",\"arguments\":\"{}\"}}]}";

    const result1 = try pipeline.processChunk(json1);
    defer std.testing.allocator.free(result1.calls);
    defer freeToolCalls(std.testing.allocator, result1.calls);
    const result2 = try pipeline.processChunk(json2);
    defer std.testing.allocator.free(result2.calls);
    defer freeToolCalls(std.testing.allocator, result2.calls);
    const result3 = try pipeline.processChunk(json3);
    defer std.testing.allocator.free(result3.calls);
    defer freeToolCalls(std.testing.allocator, result3.calls);

    try std.testing.expectEqual(@as(usize, 1), result1.calls.len);
    try std.testing.expectEqual(@as(usize, 1), result2.calls.len);
    try std.testing.expectEqual(@as(usize, 1), result3.calls.len);

    const filtered = try pipeline.suppressRepeats(&[_]ToolCallRepairPipeline.ToolCallExtracted{ result1.calls[0], result2.calls[0], result3.calls[0] });
    defer std.testing.allocator.free(filtered);
    try std.testing.expectEqual(@as(usize, 2), filtered.len);
}

test "tool call repair pipeline balance json" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    const unbalanced = "{[";
    const balanced = try pipeline.balanceJson(unbalanced);
    defer pipeline.allocator.free(balanced);
    try std.testing.expectEqualSlices(u8, "{[]}", balanced);
}

test "tool call repair pipeline extract single call" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    const obj = "{\"index\":2,\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}";
    const extracted = try pipeline.extractSingleToolCall(obj);
    const call = extracted orelse return error.TestUnexpectedResult;
    defer freeToolCalls(std.testing.allocator, &.{call});
    try std.testing.expectEqual(@as(usize, 2), call.index);
    try std.testing.expectEqualSlices(u8, "read_file", call.name);
    try std.testing.expectEqualSlices(u8, "{\"path\":\"a.txt\"}", call.arguments);
}

test "tool call repair pipeline repair and parse" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    const truncated = "{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command";
    const result = try pipeline.repairAndParse(truncated);
    const call = result orelse return error.TestUnexpectedResult;
    defer freeToolCalls(std.testing.allocator, &.{call});
    try std.testing.expectEqualSlices(u8, "bash", call.name);
}


// ── SSE delta parsing tests ──────────────────────────────────────────────

fn makeTestIterator(alloc: std.mem.Allocator) StreamIterator {
    return .{
        .allocator = alloc,
        .resp = undefined,
        .buffer = .empty,
        .line_accumulator = .empty,
        .done = false,
        .tool_call_json = .empty,
    };
}

fn deinitTestIterator(iter: *StreamIterator, alloc: std.mem.Allocator) void {
    iter.line_accumulator.deinit(alloc);
    iter.buffer.deinit(alloc);
    iter.tool_call_json.deinit(alloc);
}

test "extract plain content from delta" {
    const alloc = std.testing.allocator;
    var iter = makeTestIterator(alloc);
    defer deinitTestIterator(&iter, alloc);

    const json = "{\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}";
    const result = try iter.extractContentAndReasoning(json);
    defer if (result.content.len > 0) alloc.free(result.content);
    defer if (result.reasoning.len > 0) alloc.free(result.reasoning);
    try std.testing.expectEqualSlices(u8, "Hello", result.content);
}

test "extract deepseek real chunk format" {
    const alloc = std.testing.allocator;
    var iter = makeTestIterator(alloc);
    defer deinitTestIterator(&iter, alloc);

    // Real DeepSeek SSE chunk: delta carries role + content.
    const json = "{\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\\u4f60\\u597d\"},\"logprobs\":null,\"finish_reason\":null}]}";
    const result = try iter.extractContentAndReasoning(json);
    defer if (result.content.len > 0) alloc.free(result.content);
    defer if (result.reasoning.len > 0) alloc.free(result.reasoning);
    try std.testing.expect(result.content.len > 0);
}

test "extract reasoning from delta" {
    const alloc = std.testing.allocator;
    var iter = makeTestIterator(alloc);
    defer deinitTestIterator(&iter, alloc);

    const json = "{\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking hard\"}}]}";
    const result = try iter.extractContentAndReasoning(json);
    defer if (result.content.len > 0) alloc.free(result.content);
    defer if (result.reasoning.len > 0) alloc.free(result.reasoning);
    try std.testing.expectEqualSlices(u8, "thinking hard", result.reasoning);
}

test "detect tool_calls in delta" {
    const alloc = std.testing.allocator;
    var iter = makeTestIterator(alloc);
    defer deinitTestIterator(&iter, alloc);

    const json = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"name\":\"shell\"}}]}}]}";
    const result = try iter.extractContentAndReasoning(json);
    defer if (result.content.len > 0) alloc.free(result.content);
    defer if (result.reasoning.len > 0) alloc.free(result.reasoning);
    try std.testing.expect(iter.has_tool_calls);
}

// ── h2-over-TLS streaming (H2Client + SSE line parsing) ───────────────

pub const ChunkKind = enum { content, reasoning, tool };

pub const ChunkSink = struct {
    ctx: *anyopaque,
    on_chunk: *const fn (ctx: *anyopaque, kind: ChunkKind, data: []const u8) void,
};

fn findMatchingBracePlain(json_data: []const u8, start: usize) !?usize {
    if (start >= json_data.len or json_data[start] != '{') return null;
    var count: i32 = 1;
    var i = start + 1;
    while (i < json_data.len and count > 0) : (i += 1) {
        switch (json_data[i]) {
            '{' => count += 1,
            '}' => count -= 1,
            '"' => {
                i += 1;
                while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                    if (json_data[i] == '\\') i += 1;
                }
            },
            else => {},
        }
    }
    if (count == 0) return i;
    return null;
}

/// Module-level delta extraction (content/reasoning only; tool_calls handled
/// separately by the buffered StreamIterator path).
pub fn extractContentAndReasoningPlain(allocator: std.mem.Allocator, json_data: []const u8) !struct { content: []const u8, reasoning: []const u8, tool: []const u8 } {
    var content_result: []const u8 = "";
    var reasoning_result: []const u8 = "";
    var tool_result: []const u8 = "";
    if (std.mem.indexOf(u8, json_data, "\"tool_calls\"") != null or
        std.mem.indexOf(u8, json_data, "\"tool_call\"") != null)
    {
        tool_result = try allocator.dupe(u8, json_data);
    }
    var i: usize = 0;
    while (i < json_data.len) : (i += 1) {
        if (i + 7 <= json_data.len and std.mem.eql(u8, json_data[i..i+7], "\"delta\"")) {
            i += 7;
            while (i < json_data.len and json_data[i] != '{') : (i += 1) {}
            if (i < json_data.len) {
                const brace_count = try findMatchingBracePlain(json_data, i);
                if (brace_count) |end| {
                    const delta_json = json_data[i..end];
                            var ci: usize = 0;
                    while (ci < delta_json.len) : (ci += 1) {
                        if (ci + 10 <= delta_json.len and std.mem.eql(u8, delta_json[ci..ci+10], "\"content\":")) {
                            ci += 10;
                            while (ci < delta_json.len and delta_json[ci] == ' ') : (ci += 1) {}
                            if (ci < delta_json.len and delta_json[ci] == '"') {
                                ci += 1;
                                const value_start = ci;
                                while (ci < delta_json.len and delta_json[ci] != '"') : (ci += 1) {
                                    if (delta_json[ci] == '\\' and ci + 1 < delta_json.len) ci += 1;
                                }
                                content_result = try unescapeJsonString(allocator, delta_json[value_start..ci]);
                            }
                        }
                        if (ci + 20 <= delta_json.len and std.mem.eql(u8, delta_json[ci..ci+20], "\"reasoning_content\":")) {
                            ci += 20;
                            while (ci < delta_json.len and delta_json[ci] == ' ') : (ci += 1) {}
                            if (ci < delta_json.len and delta_json[ci] == '"') {
                                ci += 1;
                                const value_start = ci;
                                while (ci < delta_json.len and delta_json[ci] != '"') : (ci += 1) {
                                    if (delta_json[ci] == '\\' and ci + 1 < delta_json.len) ci += 1;
                                }
                                reasoning_result = try unescapeJsonString(allocator, delta_json[value_start..ci]);
                            }
                        }
                    }
                }
            }
        }
    }
    return .{ .content = content_result, .reasoning = reasoning_result, .tool = tool_result };
}

const H2SseCtx = struct {
    alloc: std.mem.Allocator,
    buf: [16384]u8,
    buf_len: usize,
    done: bool,
    sink: ChunkSink,

    fn onData(ctx_ptr: *anyopaque, data: []const u8) void {
        const c: *H2SseCtx = @ptrCast(@alignCast(ctx_ptr));
        // Append, compacting when full.
        if (c.buf_len + data.len > c.buf.len) {
            // Drop already-consumed prefix if any (should not normally happen).
            if (c.buf_len > 0) {
                const kept = c.buf[0..c.buf_len];
                c.buf_len = 0;
                _ = kept;
            }
            return;
        }
        @memcpy(c.buf[c.buf_len..][0..data.len], data);
        c.buf_len += data.len;

        var consumed: usize = 0;
        while (!c.done) {
            const nl = std.mem.indexOfScalar(u8, c.buf[consumed..c.buf_len], '\n') orelse break;
            const line_end = consumed + nl + 1; // inclusive of '\n'
            const line = c.buf[consumed..line_end];
            consumed = line_end;
            const trimmed = std.mem.trim(u8, line, "\r\n");
            if (trimmed.len == 0 or trimmed[0] == ':' or
                !std.mem.startsWith(u8, trimmed, "data:"))
            {
                continue;
            }
            const data_value = std.mem.trim(u8, trimmed[5..], " ");
            if (data_value.len == 0) continue;
            if (std.mem.eql(u8, data_value, "[DONE]")) {
                c.done = true;
                break;
            }
            const extracted = extractContentAndReasoningPlain(c.alloc, data_value) catch continue;
            defer {
                if (extracted.content.len > 0) c.alloc.free(extracted.content);
                if (extracted.reasoning.len > 0) c.alloc.free(extracted.reasoning);
                if (extracted.tool.len > 0) c.alloc.free(extracted.tool);
            }
            if (extracted.tool.len > 0) c.sink.on_chunk(c.sink.ctx, .tool, extracted.tool);
            if (extracted.reasoning.len > 0) c.sink.on_chunk(c.sink.ctx, .reasoning, extracted.reasoning);
            if (extracted.content.len > 0) c.sink.on_chunk(c.sink.ctx, .content, extracted.content);
        }
        // Compact consumed bytes.
        if (consumed > 0) {
            const remaining = c.buf_len - consumed;
            std.mem.copyForwards(u8, c.buf[0..remaining], c.buf[consumed..c.buf_len]);
            c.buf_len = remaining;
        }
    }
};

/// Synchronous h2-over-TLS streaming request: the caller provides an
/// on_chunk sink; each extracted delta (content/reasoning) is delivered as it
/// arrives. Blocks until the stream completes or fails.
pub fn streamMessageH2(
    self: *DeepSeekStreamClient,
    api_key: []const u8,
    prompt: []const u8,
    context: []const CtxItem,
    model: []const u8,
    cache_decision: anytype,
    system_prompt: []const u8,
    reasoning_effort: ?[]const u8,
    sink: ChunkSink,
) !void {
    const uri = std.Uri.parse(self.endpoint) catch return error.InvalidUri;
    const body = try self.buildRequestBody(prompt, context, model, cache_decision, system_prompt, reasoning_effort, true);
    defer self.allocator.free(body);
    const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
    defer self.allocator.free(auth_value);
    const host = uri.host.?.percent_encoded;
    const port: u16 = uri.port orelse 443;
    var path_buf: [256]u8 = undefined;
    const base_path = uri.path.percent_encoded;
    const path = if (std.mem.endsWith(u8, base_path, "/chat/completions"))
        base_path
    else
        std.fmt.bufPrint(&path_buf, "{s}/chat/completions", .{base_path}) catch base_path;

    const headers = [_]struct { []const u8, []const u8 }{
        .{ "authorization", auth_value },
        .{ "content-type", "application/json" },
        .{ "accept", "text/event-stream" },
    };

    var ctx = H2SseCtx{ .alloc = self.allocator, .buf = undefined, .buf_len = 0, .done = false, .sink = sink };
    var h2sink = h2_client.StreamSink{ .ctx = &ctx, .on_data = H2SseCtx.onData };

    var h2c = h2_client.H2Client.init(self.allocator, self.io);
    var resp = try h2c.request(host, port, path, &headers, body, &h2sink);
    defer resp.deinit();
    if (resp.status < 200 or resp.status >= 300) return error.HttpError;
}

test "build body registers all tools and echoes assistant tool_calls" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    var client = DeepSeekStreamClient.init(alloc, threaded.io(), null, null);
    defer client.deinit();

    const CacheDecision = enum { none, hit, miss };
    const ctx = [_]CtxItem{
        .{ .role = "user", .content = "do it" },
        .{ .role = "assistant", .content = "", .tool_calls_json = "[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]" },
        .{ .role = "tool", .content = "ok", .tool_call_id = "call_1" },
    };
    const body = try client.buildRequestBody("proceed", &ctx, "deepseek-chat", CacheDecision.none, "", null, true);
    defer alloc.free(body);

    // Native tool_calls are echoed so the following tool result is valid.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\":[{\"id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"tool\",\"tool_call_id\":\"call_1\"") != null);

    // Tool declarations come from the single source of truth (registry), so
    // every registered tool is visible to the model.
    const tools = [_][]const u8{ "shell", "file_read", "file_write", "file_edit", "git_status", "git_log", "git_diff", "git_commit", "glob", "grep", "web_search", "web_scrape" };
    for (tools) |t| {
        const needle = std.fmt.allocPrint(alloc, "\"name\":\"{s}\"", .{t}) catch return;
        defer alloc.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, body, needle) != null);
    }
}

test "build body appends MCP tools fragment and stays valid JSON" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    var client = DeepSeekStreamClient.init(alloc, threaded.io(), null, null);
    defer client.deinit();

    // Simulate the MCP tools/list → OpenAI fragment the /mcp handler builds:
    // names/descriptions may contain quotes, and inputSchema is passed through.
    client.extra_tools =
        \\{"type":"function","function":{"name":"db_query","description":"run \"SQL\"","parameters":{"type":"object","properties":{"q":{"type":"string"}}}}}
    ;

    const CacheDecision = enum { none, hit, miss };
    const ctx = [_]CtxItem{
        .{ .role = "user", .content = "query db" },
    };
    const body = try client.buildRequestBody("proceed", &ctx, "deepseek-chat", CacheDecision.none, "", null, true);
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "db_query") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"SQL\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"properties\"") != null);
    try std.testing.expect(try std.json.validate(alloc, body));
}
