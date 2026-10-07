//! Anthropic Messages API translator (dev.md §VI): zharness Model IR ⇄ the
//! `/v1/messages` wire format.
//!
//! Contract (mirrors model.zig's hand-rolled JSON style):
//!   - `buildRequestBody` renders a ChatRequest as a Messages-API body:
//!       * `system_prompt` becomes the top-level `system` param (with the
//!         same tool-rules suffix the OpenAI path appends, so behaviour is
//!         provider-independent),
//!       * user/assistant turns become content-block arrays,
//!       * an assistant message carrying `tool_calls_json` (the OpenAI-shaped
//!         echo the agent loop stores) is translated into `tool_use` blocks,
//!       * consecutive `.tool` role messages merge into ONE following user
//!         message of `tool_result` blocks (Anthropic's required shape),
//!       * `tools_json` entries are converted from the OpenAI
//!         `{type,function:{name,description,parameters}}` wrapper to
//!         `{name,description,input_schema}`.
//!   - `parseResponse` maps a non-streaming response back into IR:
//!       text/thinking blocks → content/reasoning, `tool_use` → ToolCall,
//!       stop_reason → OpenAI-style finish_reason vocabulary
//!       ("tool_calls"/"length"/"stop").
//!
//! ToolCall.arguments keep the SAME contract as the OpenAI parser: the RAW
//! source slice of the argument payload (escape sequences intact), so
//! builtin.parseArgs and the echo round-trip work unchanged across dialects.
//!
//! Non-streaming only: streaming is deferred (see SWARM_PLAN A-providers);
//! ChatClient degrades stream=true to a buffered request for this dialect.

const std = @import("std");
const m = @import("model.zig");
const providers = @import("provider.zig");

/// Anthropic rejects requests without a bounded generation length; the agent
/// loop has no per-request knob yet, so one generous default applies.
pub const max_tokens: usize = 8192;

/// Same suffix the OpenAI body builder appends — keeps prompts identical
/// across providers (duplicated because the OpenAI constant is fn-local).
const tool_rules = "Tool usage: the shell tool expects a direct command string (e.g. \"ls -la\"). Never wrap it in sh -c or bash -c.";

// ── Request direction: IR → Messages API ───────────────────────────────────

pub fn buildRequestBody(alloc: std.mem.Allocator, model_name: []const u8, req: m.ChatRequest) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "{\"model\":\"");
    try m.escape(alloc, model_name, &out);
    try out.appendSlice(alloc, "\",\"max_tokens\":");
    try out.appendSlice(alloc, std.fmt.comptimePrint("{d}", .{max_tokens}));

    // Top-level system param (Anthropic has no system ROLE in messages).
    const full_system = if (req.system_prompt.len > 0)
        try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ req.system_prompt, tool_rules })
    else
        tool_rules;
    defer if (req.system_prompt.len > 0) alloc.free(full_system);
    try out.appendSlice(alloc, ",\"system\":\"");
    try m.escape(alloc, full_system, &out);
    try out.appendSlice(alloc, "\"");

    try out.appendSlice(alloc, ",\"messages\":[");
    try appendMessages(alloc, req.messages, &out);
    try out.appendSlice(alloc, "]");

    // Tools converted to {name,description,input_schema}; omitted entirely
    // when empty (an empty array is legal but noisy).
    if (req.tools_json.len > 0) {
        try out.appendSlice(alloc, ",\"tools\":[");
        try appendConvertedTools(alloc, req.tools_json, &out);
        try out.appendSlice(alloc, "]");
    }

    try out.appendSlice(alloc, "}");
    return out.toOwnedSlice(alloc);
}

fn appendMessages(alloc: std.mem.Allocator, messages: []const m.Message, out: *std.ArrayList(u8)) !void {
    var first = true;
    var i: usize = 0;
    while (i < messages.len) : (i += 1) {
        const msg = messages[i];
        switch (msg.role) {
            // System is carried by the top-level param, never in messages.
            .system => continue,
            .user => {
                try sepMsg(alloc, out, &first);
                try appendUserTextMessage(alloc, msg, out);
            },
            .assistant => {
                try sepMsg(alloc, out, &first);
                try appendAssistantMessage(alloc, msg.content, msg.tool_calls_json, out);
            },
            .tool => {
                // Consecutive tool results merge into one trailing user turn.
                try sepMsg(alloc, out, &first);
                try out.appendSlice(alloc, "{\"role\":\"user\",\"content\":[");
                var j = i;
                var first_block = true;
                while (j < messages.len and messages[j].role == .tool) : (j += 1) {
                    if (!first_block) try out.append(alloc, ',');
                    first_block = false;
                    try appendToolResultBlock(alloc, messages[j], out);
                }
                try out.appendSlice(alloc, "]}");
                i = j - 1; // outer loop increment lands past the group
            },
        }
    }
}

fn sepMsg(alloc: std.mem.Allocator, out: *std.ArrayList(u8), first: *bool) !void {
    if (!first.*) try out.append(alloc, ',');
    first.* = false;
}

/// User turn: one text block, optionally followed by one base64 image source
/// block per attached image (wave 6 H-image). Messages without images render
/// exactly as before — the additive blocks only appear when `msg.images` is
/// non-empty (capability gating happens in the caller: ChatClient.vision).
fn appendUserTextMessage(alloc: std.mem.Allocator, msg: m.Message, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(alloc, "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"");
    try m.escape(alloc, msg.content, out);
    try out.appendSlice(alloc, "\"}");
    for (msg.images) |img| {
        try out.appendSlice(alloc, ",{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"");
        try m.escape(alloc, img.media_type, out);
        try out.appendSlice(alloc, "\",\"data\":\"");
        // Base64 alphabet carries no quote/backslash bytes; escape() is used
        // anyway for uniformity with every other field on this wire.
        try m.escape(alloc, img.data_b64, out);
        try out.appendSlice(alloc, "\"}}");
    }
    try out.appendSlice(alloc, "]}");
}

/// Assistant turn: optional text block plus one tool_use block per echoed
/// call. The echo is the OpenAI fragment the agent loop stores:
///   [{"id":..,"type":"function","function":{"name":..,"arguments":<raw>}}]
/// (arguments ride RAW-escaped; see module doc). Empty content with calls
/// emits only the tool_use blocks; nothing at all falls back to one empty
/// text block because Anthropic rejects zero-length content arrays.
fn appendAssistantMessage(alloc: std.mem.Allocator, content: []const u8, tool_calls_json: ?[]const u8, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(alloc, "{\"role\":\"assistant\",\"content\":[");

    var wrote_any = false;
    if (content.len > 0) {
        try out.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"");
        try m.escape(alloc, content, out);
        try out.appendSlice(alloc, "\"}");
        wrote_any = true;
    }

    if (tool_calls_json) |echo| {
        const parsed = try parseEchoedToolCalls(alloc, echo);
        defer alloc.free(parsed);
        for (parsed) |call| {
            if (wrote_any) try out.append(alloc, ',');
            wrote_any = true;
            try out.appendSlice(alloc, "{\"type\":\"tool_use\",\"id\":\"");
            try m.escape(alloc, call.id, out);
            try out.appendSlice(alloc, "\",\"name\":\"");
            try m.escape(alloc, call.name, out);
            try out.appendSlice(alloc, "\",\"input\":");
            const decoded = try decodeArgumentsToObject(alloc, call.arguments);
            defer alloc.free(decoded);
            try out.appendSlice(alloc, decoded);
            try out.append(alloc, '}');
        }
    }

    if (!wrote_any) {
        try out.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"\"}");
    }
    try out.appendSlice(alloc, "]}");
}

fn appendToolResultBlock(alloc: std.mem.Allocator, msg: m.Message, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(alloc, "{\"type\":\"tool_result\",\"tool_use_id\":\"");
    try m.escape(alloc, msg.tool_call_id orelse "", out);
    try out.appendSlice(alloc, "\",\"content\":\"");
    try m.escape(alloc, msg.content, out);
    try out.appendSlice(alloc, "\"}");
}

const EchoedCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// Walk the bracketed echo array and pull id/name/arguments from each entry,
/// tolerating BOTH argument encodings seen in practice: the loop's echo puts
/// the raw escaped string bytes after `"arguments":` without surrounding
/// quotes (lexically invalid JSON!), while session-replayed JSON uses a
/// proper escaped string.
fn parseEchoedToolCalls(alloc: std.mem.Allocator, echo: []const u8) ![]EchoedCall {
    var calls: std.ArrayList(EchoedCall) = .empty;
    errdefer calls.deinit(alloc);
    var i: usize = 0;
    while (i < echo.len) : (i += 1) {
        if (echo[i] != '{') continue;
        const end = findMatchingBraceLenient(echo, i) orelse break;
        const obj = echo[i..end];
        const id = m.extractField(obj, "id") orelse "";
        // Nested lookup must use the lenient matcher: the function object
        // contains the raw-escaped arguments payload that breaks the strict
        // one. extractField inside is safe — values there are plain strings.
        const fname_obj = topLevelObjectSliceLenient(obj, "function");
        const name = if (fname_obj) |fo| (m.extractField(fo, "name") orelse "") else "";
        const args = extractRawValueAfterKey(obj, "arguments") orelse "";
        try calls.append(alloc, .{ .id = id, .name = name, .arguments = args });
        i = end - 1; // loop increment resumes right after this object
    }
    return calls.toOwnedSlice(alloc);
}

/// Brace matcher for the agent loop's echo shape. Unlike findMatchingBrace,
/// it treats a backslash as starting an escape pair EVERYWHERE — including
/// outside string context — so the echo's raw escaped argument payload
/// (`"arguments":{\"cmd\":\"pwd\"}`, no enclosing quotes) cannot derail the
/// depth count: every escaped quote is consumed as a pair and never opens a
/// phantom string. Valid JSON matches identically to the strict matcher.
fn findMatchingBraceLenient(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '{') return null;
    var depth: usize = 1;
    var i = start + 1;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => i += 1, // skip the escaped character wholesale
            '"' => {
                i += 1;
                while (i < s.len) : (i += 1) {
                    if (s[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (s[i] == '"') break;
                }
                if (i >= s.len) return null;
            },
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i + 1; // exclusive, like findMatchingBrace
            },
            else => {},
        }
    }
    return null;
}

/// Arguments arrive as escape-layered text; the wire wants the decoded object
/// body verbatim. Falls back to `{}` when the payload is not brace-balanced
/// (Anthropic requires input to be an object).
fn decodeArgumentsToObject(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const txt = try m.unescape(alloc, raw);
    defer alloc.free(txt);
    const trimmed = std.mem.trim(u8, txt, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        return alloc.dupe(u8, trimmed);
    }
    return alloc.dupe(u8, "{}");
}

/// Convert the registry's OpenAI tools fragment (comma-separated objects, no
/// brackets) into Anthropic tool descriptors.
fn appendConvertedTools(alloc: std.mem.Allocator, tools_json: []const u8, out: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    var first = true;
    while (i < tools_json.len) : (i += 1) {
        if (tools_json[i] != '{') continue;
        const end = m.findMatchingBrace(tools_json, i) orelse break;
        const obj = tools_json[i..end];
        const name = m.extractNestedField(obj, "function", "name") orelse "";
        const desc = m.extractNestedField(obj, "function", "description") orelse "";
        const params = topLevelObjectSlice(obj, "parameters") orelse "{}";
        if (!first) try out.append(alloc, ',');
        first = false;
        try out.appendSlice(alloc, "{\"name\":\"");
        try m.escape(alloc, name, out);
        try out.appendSlice(alloc, "\",\"description\":\"");
        try m.escape(alloc, desc, out);
        try out.appendSlice(alloc, "\",\"input_schema\":");
        try out.appendSlice(alloc, params);
        try out.append(alloc, '}');
        i = end - 1;
    }
}

// ── Response direction: Messages API → IR ──────────────────────────────────

pub fn parseResponse(alloc: std.mem.Allocator, json: []const u8) !m.ChatResponse {
    var text_acc: std.ArrayList(u8) = .empty;
    errdefer text_acc.deinit(alloc);
    var think_acc: std.ArrayList(u8) = .empty;
    errdefer think_acc.deinit(alloc);
    var calls: std.ArrayList(m.ToolCall) = .empty;
    errdefer {
        for (calls.items) |tc| {
            alloc.free(tc.id);
            alloc.free(tc.name);
            alloc.free(tc.arguments);
        }
        calls.deinit(alloc);
    }

    var has_tools = false;
    if (topLevelArraySlice(json, "content")) |blocks| {
        var i: usize = 1; // skip '['
        while (i + 1 < blocks.len) : (i += 1) {
            if (blocks[i] != '{') continue;
            const end = m.findMatchingBrace(blocks, i) orelse break;
            const blk = blocks[i..end];
            const ty = m.extractField(blk, "type") orelse "";
            if (std.mem.eql(u8, ty, "text")) {
                if (try m.extractStringField(alloc, blk, "text")) |piece| {
                    defer alloc.free(piece);
                    try text_acc.appendSlice(alloc, piece);
                }
            } else if (std.mem.eql(u8, ty, "thinking")) {
                if (try m.extractStringField(alloc, blk, "thinking")) |piece| {
                    defer alloc.free(piece);
                    try think_acc.appendSlice(alloc, piece);
                }
            } else if (std.mem.eql(u8, ty, "tool_use")) {
                has_tools = true;
                // id/name precede the args object canonically; bound the
                // search to the head so an arg literally named "id" or
                // "name" can never shadow the block fields.
                const head_end = std.mem.indexOf(u8, blk, "\"input\":") orelse blk.len;
                const head = blk[0..head_end];
                const id = m.extractField(head, "id") orelse "";
                const name = m.extractField(head, "name") orelse "";
                const input = topLevelObjectSlice(blk, "input") orelse "{}";
                try calls.append(alloc, .{
                    .id = try alloc.dupe(u8, id),
                    .name = try alloc.dupe(u8, name),
                    // Raw source slice: same escaped-form contract as the
                    // OpenAI extractor (builtin.parseArgs unescapes values).
                    .arguments = try alloc.dupe(u8, input),
                });
            }
            i = end - 1; // loop increment resumes after this block
        }
    }

    const fr_raw = extractStopReason(json) orelse "end_turn";
    const fr_mapped = mapStopReason(fr_raw);

    return .{
        .content = try text_acc.toOwnedSlice(alloc),
        .reasoning = try think_acc.toOwnedSlice(alloc),
        .tool_calls = try calls.toOwnedSlice(alloc),
        .finish_reason = try alloc.dupe(u8, fr_mapped),
        .has_tools = has_tools,
        .usage = m.parseUsage(json),
    };
}

/// Anthropic stop_reason → OpenAI finish_reason vocabulary the agent loop
/// already understands. Unknown values pass through untouched.
fn mapStopReason(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "end_turn")) return "stop";
    if (std.mem.eql(u8, raw, "stop_sequence")) return "stop";
    if (std.mem.eql(u8, raw, "tool_use")) return "tool_calls";
    if (std.mem.eql(u8, raw, "max_tokens")) return "length";
    return raw;
}

fn extractStopReason(json: []const u8) ?[]const u8 {
    const needle = "\"stop_reason\":";
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = pos + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const vs = i;
    while (i < json.len and json[i] != '"') : (i += 1) {}
    if (i > json.len) return null;
    return json[vs..i];
}

// ── Error envelopes ────────────────────────────────────────────────────────

/// True when `body` is an Anthropic error envelope:
///   {"type":"error","error":{"type":"…","message":"…"}}
/// (The OpenAI checker in model.zig looks for a FIRST field named "error",
/// which does not match Anthropic's shape.)
pub fn isErrorEnvelope(body: []const u8) bool {
    var i: usize = 0;
    while (i < body.len and (body[i] == ' ' or body[i] == '\n' or body[i] == '\r' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len or body[i] != '{') return false;
    const obj = body[i..];
    const first_key = firstTopLevelKey(obj) orelse return false;
    if (!std.mem.eql(u8, first_key, "type")) return false;
    // The envelope's FIRST field is `"type":"error"`; a normal response's
    // first field is "id". (Prose mentioning "error" elsewhere stays clean.)
    const ty = m.extractField(obj, "type") orelse return false;
    return std.mem.eql(u8, ty, "error");
}

/// Extract error.message from an Anthropic error envelope. Caller frees.
pub fn errorMessage(alloc: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, body, "\"error\"") orelse return null;
    const brace = std.mem.indexOfScalarPos(u8, body, pos, '{') orelse return null;
    const end = m.findMatchingBrace(body, brace) orelse return null;
    return m.extractStringField(alloc, body[brace..end], "message") catch null;
}

fn firstTopLevelKey(obj: []const u8) ?[]const u8 {
    var i: usize = 1; // skip '{'
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\n' or obj[i] == '\r' or obj[i] == '\t')) : (i += 1) {}
    if (i >= obj.len or obj[i] != '"') return null;
    i += 1;
    const ks = i;
    while (i < obj.len and obj[i] != '"') : (i += 1) {
        if (obj[i] == '\\' and i + 1 < obj.len) i += 1;
    }
    if (i > obj.len) return null;
    return obj[ks..i];
}

// ── Slice helpers over raw JSON ────────────────────────────────────────────

/// Inclusive slice of the ARRAY value under `"key":`, or null.
fn topLevelArraySlice(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const bracket = std.mem.indexOfScalarPos(u8, json, pos, '[') orelse return null;
    // findMatchingBracket returns one-past-']' (exclusive) — slice as-is.
    const end = m.findMatchingBracket(json, bracket) orelse return null;
    return json[bracket..end];
}

/// Inclusive slice of the OBJECT value directly under `"key":`, or null.
pub fn topLevelObjectSlice(obj: []const u8, key: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = pos + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) : (i += 1) {}
    if (i >= obj.len or obj[i] != '{') return null;
    // findMatchingBrace returns one-past-'}' (exclusive) — slice as-is.
    const end = m.findMatchingBrace(obj, i) orelse return null;
    return obj[i..end];
}

/// Same as topLevelObjectSlice but tolerating raw-escaped payloads inside
/// the value object (agent-loop echo shape).
fn topLevelObjectSliceLenient(obj: []const u8, key: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = pos + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) : (i += 1) {}
    if (i >= obj.len or obj[i] != '{') return null;
    const end = findMatchingBraceLenient(obj, i) orelse return null;
    return obj[i..end];
}

/// Value bytes after `"key":` in RAW form: between the quotes (escapes kept)
/// for strings, brace-inclusive for objects. Null otherwise.
fn extractRawValueAfterKey(obj: []const u8, key: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = pos + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) : (i += 1) {}
    if (i >= obj.len) return null;
    if (obj[i] == '"') {
        i += 1;
        const vs = i;
        while (i < obj.len and obj[i] != '"') : (i += 1) {
            if (obj[i] == '\\' and i + 1 < obj.len) i += 1;
        }
        if (i > obj.len) return null;
        return obj[vs..i];
    }
    if (obj[i] == '{') {
        const end = findMatchingBraceLenient(obj, i) orelse return null;
        return obj[i..end]; // lenient matcher already returns one-past-'}
    }
    return null;
}
