//! Model layer — the zharness internal Model IR (dev.md §VI) and the
//! DeepSeek/OpenAI-compatible client that talks to it.
//!
//! The agent runtime only deals with the IR (`Message`, `ChatRequest`,
//! `ChatResponse`, `ToolCall`). The client translates IR <-> the provider's
//! OpenAI-style JSON, so a new provider is just another `client` impl.

const std = @import("std");
const clib = @import("../clib.zig");

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

pub const Message = struct {
    role: Role,
    content: []const u8,
    /// For tool messages: the id of the tool call they answer.
    tool_call_id: ?[]const u8 = null,
    /// For assistant messages that requested tools: the raw tool_calls JSON
    /// echoed back to the provider on the next request so it accepts results.
    tool_calls_json: ?[]const u8 = null,
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
pub const ChatClient = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    endpoint: []const u8,
    model: []const u8,
    api_key: []const u8,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, endpoint: []const u8, model: []const u8, api_key: []const u8) ChatClient {
        return .{
            .alloc = alloc,
            .io = io,
            .endpoint = endpoint,
            .model = model,
            .api_key = api_key,
        };
    }

    pub fn chat(self: *ChatClient, req: ChatRequest) !ChatResponse {
        const body = try self.buildBody(req);
        defer self.alloc.free(body);

        // Write the JSON body to a temp file, then POST it via curl with a
        // read pipe to capture stdout. This reuses the libc popen path the
        // shell tool relies on and is the most reliable HTTPS method from Zig
        // 0.17 on macOS (the std.http request API is intricate to get right).
        const c = std.c;
        const tmp_path = "/tmp/zharness_req.json";
        const tmp_z = try self.alloc.dupeSentinel(u8, tmp_path, 0);
        defer self.alloc.free(tmp_z);
        const wf = c.fopen(tmp_z.ptr, "wb") orelse return error.HttpError;
        _ = c.fwrite(body.ptr, 1, body.len, wf);
        _ = c.fclose(wf);

        const cmd = try std.fmt.allocPrint(
            self.alloc,
            "curl -sS -X POST {s} -H \"Authorization: Bearer {s}\" -H \"Content-Type: application/json\" -d @{s}",
            .{ self.endpoint, self.api_key, tmp_path },
        );
        defer self.alloc.free(cmd);
        const cmd_z = try self.alloc.dupeSentinel(u8, cmd, 0);
        defer self.alloc.free(cmd_z);

        const fp = clib.popenRead(cmd_z.ptr) orelse return error.HttpError;
        var out = try std.ArrayList(u8).initCapacity(self.alloc, 0);
        errdefer out.deinit(self.alloc);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = c.fread(&buf, 1, buf.len, fp);
            if (n == 0) break;
            try out.appendSlice(self.alloc, buf[0..n]);
        }
        _ = clib.pclosePipe(fp);
        if (out.items.len == 0) return error.HttpError;

        const resp_body = try out.toOwnedSlice(self.alloc);
        defer self.alloc.free(resp_body);

        return self.parseResponse(resp_body);
    }

    fn buildBody(self: *ChatClient, req: ChatRequest) ![]const u8 {
        var body = try std.ArrayList(u8).initCapacity(self.alloc, 0);
        errdefer body.deinit(self.alloc);
        try body.appendSlice(self.alloc, "{\"model\":\"");
        try body.appendSlice(self.alloc, self.model);
        try body.appendSlice(self.alloc, "\",\"stream\":false,\"messages\":[");

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
            } else {
                try body.appendSlice(self.alloc, "\",\"content\":\"");
                try escape(self.alloc, m.content, &body);
                try body.appendSlice(self.alloc, "\"}");
            }
        }
        try body.appendSlice(self.alloc, "],\"tools\":[");
        try body.appendSlice(self.alloc, req.tools_json);
        try body.appendSlice(self.alloc, "],\"tool_choice\":\"auto\"");
        if (req.reasoning_effort) |eff| {
            try body.appendSlice(self.alloc, ",\"reasoning_effort\":\"");
            try body.appendSlice(self.alloc, eff);
            try body.appendSlice(self.alloc, "\"}");
        } else {
            try body.appendSlice(self.alloc, "}");
        }
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
            res.has_tools = true;
            res.tool_calls = try self.parseToolCalls(json);
        }
        // Extract message content + reasoning.
        if (std.mem.indexOf(u8, json, "\"message\"")) |mi| {
            const brace = std.mem.indexOfScalarPos(u8, json, mi, '{') orelse return error.MalformedResponse;
            const end = findMatchingBrace(json, brace) orelse return error.MalformedResponse;
            const msg = json[brace..end];
            if (std.mem.indexOf(u8, msg, "\"content\":\"")) |ci| {
                const vs = ci + 11;
                if (std.mem.indexOfScalarPos(u8, msg, vs, '"')) |ve| {
                    self.alloc.free(res.content);
                    res.content = try unescape(msg[vs..ve]);
                }
            }
            if (std.mem.indexOf(u8, msg, "\"reasoning_content\":\"")) |ri| {
                const vs = ri + 22;
                if (std.mem.indexOfScalarPos(u8, msg, vs, '"')) |ve| {
                    self.alloc.free(res.reasoning);
                    res.reasoning = try unescape(msg[vs..ve]);
                }
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
        errdefer {
            for (calls.items) |tc| {
                self.alloc.free(tc.id);
                self.alloc.free(tc.name);
                self.alloc.free(tc.arguments);
            }
            calls.deinit(self.alloc);
        }
        while (std.mem.indexOf(u8, json, "\"tool_calls\":[")) |pos| {
            const arr_start = pos + 14;
            // Arrays use brackets, so match with the bracket matcher.
            const bracket_end = findMatchingBracket(json, arr_start) orelse break;
            const arr = json[arr_start..bracket_end + 1];
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
        const args = extractNestedField(obj, "function", "arguments") orelse "";
        return ToolCall{
            .id = try self.alloc.dupe(u8, id),
            .name = try self.alloc.dupe(u8, name),
            .arguments = try self.alloc.dupe(u8, args),
        };
    }
};

fn extractField(obj: []const u8, field: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{field}) catch return null;
    const pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = pos + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '"')) : (i += 1) {}
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

fn extractNestedField(obj: []const u8, outer: []const u8, inner: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{outer}) catch return null;
    const pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    const obj_end = findMatchingBrace(obj, pos) orelse return null;
    return extractField(obj[pos..obj_end], inner);
}

fn escape(alloc: std.mem.Allocator, input: []const u8, out: *std.ArrayList(u8)) !void {
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

fn unescape(input: []const u8) ![]const u8 {
    // Lightweight unescape for content/reasoning (backslash escapes only).
    var out = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, 0);
    errdefer out.deinit(std.heap.page_allocator);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            switch (input[i]) {
                '"' => try out.append(std.heap.page_allocator, '"'),
                '\\' => try out.append(std.heap.page_allocator, '\\'),
                'n' => try out.append(std.heap.page_allocator, '\n'),
                'r' => try out.append(std.heap.page_allocator, '\r'),
                't' => try out.append(std.heap.page_allocator, '\t'),
                else => try out.append(std.heap.page_allocator, input[i]),
            }
        } else {
            try out.append(std.heap.page_allocator, input[i]);
        }
    }
    return out.toOwnedSlice(std.heap.page_allocator);
}

fn findMatchingBrace(json: []const u8, start: usize) ?usize {
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
                // nested object — skip it
                if (findMatchingBrace(json, i)) |be| {
                    i = be;
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

/// Build the assistant message's tool_calls_json echo from a response that had
/// tool calls. `json` is the raw response body.
pub fn toolCallsEcho(alloc: std.mem.Allocator, json: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, json, "\"tool_calls\":[")) |pos| {
        const arr_start = pos + 13;
        if (findMatchingBracket(json, arr_start)) |be| {
            return try alloc.dup(u8, json[arr_start - 1 .. be + 1]);
        }
    }
    return try alloc.dupe(u8, "");
}

test "findMatchingBrace basic" {
    try std.testing.expectEqual(@as(?usize, 13), findMatchingBrace("{\"a\":{\"b\":1}}", 0));
}
