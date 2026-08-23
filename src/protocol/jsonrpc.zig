//! JSON-RPC 2.0 envelope codec — hand-rolled parsing in the model.zig style
//! (no JSON library anywhere in zharness, dev.md ground rule).
//!
//! Contract:
//! - Encoding produces single-line JSON envelopes (MCP stdio framing is
//!   newline-delimited; embedded newlines would corrupt the stream).
//! - `decodeMessage` parses exactly ONE envelope. Every returned string is
//!   freshly allocated and caller-owned (unescaped); object/array members
//!   (`params`, `result`, `error.data`) are duplicated VERBATIM so callers
//!   can rescan them after freeing the input buffer.
//! - Whitespace between tokens is tolerated. Malformed input yields
//!   `error.MalformedMessage` — never a panic.
//! - Batch arrays (`[...]`) are rejected: legal JSON-RPC, but unused by MCP
//!   and deliberately out of scope.

const std = @import("std");

/// Wire value of the `"jsonrpc"` member this codec accepts.
pub const version_string = "2.0";

/// JSON-RPC request id. Numbers cover everything zharness emits; strings and
/// `null` are decoded for spec-compliance when talking to foreign peers.
pub const Id = union(enum) {
    number: i64,
    string: []const u8,
    /// Literal JSON `null` id (allowed on error responses).
    none,

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .number => |n| b == .number and b.number == n,
            .string => |s| b == .string and std.mem.eql(u8, b.string, s),
            .none => b == .none,
        };
    }
};

pub const Request = struct {
    id: Id,
    method: []const u8,
    /// Raw JSON object/array text; empty when the peer omitted `params`.
    params_json: []const u8,
};

pub const Notification = struct {
    method: []const u8,
    /// Raw JSON object/array text; empty when the peer omitted `params`.
    params_json: []const u8,
};

pub const RpcError = struct {
    code: i64,
    message: []const u8,
    /// Raw JSON text of the optional `data` member, null when absent.
    data_json: ?[]const u8,
};

pub const Decoded = union(enum) {
    request: Request,
    notification: Notification,
    response_ok: struct { id: Id, result_json: []const u8 },
    response_err: struct { id: Id, err: RpcError },

    /// Frees every allocation owned by this value (pass the same allocator
    /// that was handed to `decodeMessage`).
    pub fn deinit(self: *Decoded, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .request => |r| {
                freeId(alloc, r.id);
                alloc.free(r.method);
                alloc.free(r.params_json);
            },
            .notification => |n| {
                alloc.free(n.method);
                alloc.free(n.params_json);
            },
            .response_ok => |r| {
                freeId(alloc, r.id);
                alloc.free(r.result_json);
            },
            .response_err => |r| {
                freeId(alloc, r.id);
                alloc.free(r.err.message);
                if (r.err.data_json) |d| alloc.free(d);
            },
        }
    }
};

fn freeId(alloc: std.mem.Allocator, id: Id) void {
    switch (id) {
        .string => |s| alloc.free(s),
        else => {},
    }
}

pub const DecodeError = error{
    MalformedMessage,
    OutOfMemory,
};

// ── encoding ────────────────────────────────────────────────────────────────

/// `{"jsonrpc":"2.0","id":N,"method":"…","params":…}`
pub fn encodeRequest(
    alloc: std.mem.Allocator,
    id: i64,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdNumber(alloc, &out, id);
    try out.appendSlice(alloc, ",\"method\":\"");
    try appendEscaped(alloc, &out, method);
    try out.appendSlice(alloc, "\",\"params\":");
    try appendParamsBody(alloc, &out, params_json);
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

/// `{"jsonrpc":"2.0","method":"…","params":…}`
pub fn encodeNotification(
    alloc: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"");
    try appendEscaped(alloc, &out, method);
    try out.appendSlice(alloc, "\",\"params\":");
    try appendParamsBody(alloc, &out, params_json);
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

/// `{"jsonrpc":"2.0","id":N,"result":…}` — result side, used by fake servers
/// and tests.
pub fn encodeResult(alloc: std.mem.Allocator, id: i64, result_json: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdNumber(alloc, &out, id);
    try out.appendSlice(alloc, ",\"result\":");
    try appendParamsBody(alloc, &out, result_json);
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

/// `{"jsonrpc":"2.0","id":N,"error":{"code":C,"message":"…"}}` — error side,
/// used by fake servers and tests.
pub fn encodeError(
    alloc: std.mem.Allocator,
    id: i64,
    code: i64,
    message: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdNumber(alloc, &out, id);
    try out.print(alloc, ",\"error\":{{\"code\":{d},\"message\":\"", .{code});
    try appendEscaped(alloc, &out, message);
    try out.appendSlice(alloc, "\"}}");
    return out.toOwnedSlice(alloc);
}

fn appendIdNumber(alloc: std.mem.Allocator, out: *std.ArrayList(u8), id: i64) !void {
    try out.print(alloc, "{d}", .{id});
}

/// Append the params payload: verbatim when non-empty, `{}` placeholder
/// otherwise (JSON-RPC makes `params` optional).
fn appendParamsBody(alloc: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8) !void {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) {
        try out.appendSlice(alloc, "{}");
    } else {
        try out.appendSlice(alloc, trimmed);
    }
}

/// Escape a UTF-8 string for embedding between JSON quotes. Control chars
/// become \uXXXX so the envelope stays a single line.
pub fn appendEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0x08 => try out.appendSlice(alloc, "\\b"),
            0x0C => try out.appendSlice(alloc, "\\f"),
            else => {
                if (ch < 0x20) {
                    try out.print(alloc, "\\u{x:0>4}", .{ch});
                } else {
                    try out.append(alloc, ch);
                }
            },
        }
    }
}

/// Convenience wrapper: returns an escaped copy of `s` (caller owns it).
pub fn escapeJsonString(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendEscaped(alloc, &out, s);
    return out.toOwnedSlice(alloc);
}

// ── decoding ────────────────────────────────────────────────────────────────

const ValueKind = enum { string, object, array, number, literal };

pub const Span = struct { start: usize, end: usize }; // end is exclusive

pub const ScannedValue = struct {
    kind: ValueKind,
    span: Span,
    /// Unquoted interior for strings (endpoints of the raw text).
    inner: Span = .{ .start = 0, .end = 0 },
};

/// Advance past whitespace. Shared with protocol/mcp.zig result parsing.
pub fn skipWs(text: []const u8, i_in: usize) usize {
    var i = i_in;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            ' ', '\t', '\r', '\n' => {},
            else => return i,
        }
    }
    return i;
}

/// Scan a JSON string starting at the opening quote. Returns the span
/// INCLUDING both quotes plus the unquoted interior. Unterminated input is
/// MalformedMessage.
fn scanString(text: []const u8, start: usize) DecodeError!ScannedValue {
    std.debug.assert(start < text.len and text[start] == '"');
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"' => return .{
                .kind = .string,
                .span = .{ .start = start, .end = i + 1 },
                .inner = .{ .start = start + 1, .end = i },
            },
            '\\' => i += 1, // skip escaped char (validated during unescape)
            else => {},
        }
    }
    return error.MalformedMessage;
}

/// Find the exclusive end of the container opening at `open`
/// ('{' or '['). String-aware; nested opposite-kind delimiters are inert
/// (same approach as model.zig's findMatchingBrace).
fn matchContainer(text: []const u8, open: usize) ?usize {
    const opener = text[open];
    const closer: u8 = switch (opener) {
        '{' => '}',
        '[' => ']',
        else => return null,
    };
    var depth: i32 = 1;
    var i = open + 1;
    while (i < text.len and depth > 0) : (i += 1) {
        const ch = text[i];
        if (ch == '"') {
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) {
                if (text[i] == '\\') i += 1;
            }
            if (i >= text.len) return null;
        } else if (ch == opener) {
            depth += 1;
        } else if (ch == closer) {
            depth -= 1;
        }
    }
    if (depth == 0) return i;
    return null;
}

/// Scan any JSON value starting at `start`. Returns its raw span.
pub fn scanValue(text: []const u8, start: usize) DecodeError!ScannedValue {
    if (start >= text.len) return error.MalformedMessage;
    switch (text[start]) {
        '"' => return scanString(text, start),
        '{', '[' => {
            const end = matchContainer(text, start) orelse return error.MalformedMessage;
            return .{
                .kind = if (text[start] == '{') .object else .array,
                .span = .{ .start = start, .end = end },
            };
        },
        't', 'f', 'n' => {
            const literals = [_][]const u8{ "true", "false", "null" };
            for (literals) |lit| {
                if (text.len - start >= lit.len and std.mem.eql(u8, text[start .. start + lit.len], lit)) {
                    return .{ .kind = .literal, .span = .{ .start = start, .end = start + lit.len } };
                }
            }
            return error.MalformedMessage;
        },
        '-',
        '0'...'9',
        => {
            var i = start + 1;
            while (i < text.len) : (i += 1) {
                switch (text[i]) {
                    '-', '+', '.', 'e', 'E', '0'...'9' => {},
                    else => break,
                }
            }
            // Require at least one digit somewhere (rejects a bare "-");
            // semantic validation happens in parseIntSpan / verbatim dupes.
            var saw_digit = false;
            for (text[start..i]) |ch| {
                if (ch >= '0' and ch <= '9') {
                    saw_digit = true;
                    break;
                }
            }
            if (!saw_digit) return error.MalformedMessage;
            return .{ .kind = .number, .span = .{ .start = start, .end = i } };
        },
        else => return error.MalformedMessage,
    }
}

/// One object member produced by `nextMember`.
pub const Member = struct {
    key_inner: Span,
    value: ScannedValue,
    /// Index of the next character after the member's separator.
    next: usize,
};

/// Parse the next `key : value` member inside the object whose body begins
/// at `i`. Handles separators; returns `next == i` sentinel via null at '}'.
pub fn nextMember(text: []const u8, i: usize) DecodeError!?Member {
    const j = skipWs(text, i);
    if (j >= text.len) return error.MalformedMessage;
    if (text[j] == '}') return null;
    if (text[j] != '"') return error.MalformedMessage;
    const key = try scanString(text, j);
    const k = skipWs(text, key.span.end);
    if (k >= text.len or text[k] != ':') return error.MalformedMessage;
    const v = try scanValue(text, skipWs(text, k + 1));
    const m = skipWs(text, v.span.end);
    if (m >= text.len) return error.MalformedMessage;
    return .{ .key_inner = key.inner, .value = v, .next = m };
}

/// Unescape the interior of a JSON string span (without quotes) into a
/// freshly allocated UTF-8 slice. Supports \" \\ \/ \b \f \n \r \t and
/// \uXXXX escapes including surrogate pairs (lone surrogates become U+FFFD).
pub fn unescapeInner(alloc: std.mem.Allocator, text: []const u8, inner: Span) DecodeError![]u8 {
    const raw = text[inner.start..inner.end];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\\') {
            try out.append(alloc, raw[i]);
            continue;
        }
        i += 1;
        if (i >= raw.len) return error.MalformedMessage;
        switch (raw[i]) {
            '"' => try out.append(alloc, '"'),
            '\\' => try out.append(alloc, '\\'),
            '/' => try out.append(alloc, '/'),
            'b' => try out.append(alloc, 0x08),
            'f' => try out.append(alloc, 0x0C),
            'n' => try out.append(alloc, '\n'),
            'r' => try out.append(alloc, '\r'),
            't' => try out.append(alloc, '\t'),
            'u' => {
                var cp = try parseHex4(raw, i + 1);
                i += 4;
                if (cp >= 0xD800 and cp <= 0xDBFF) {
                    // High surrogate: combine with a following low surrogate.
                    if (i + 7 <= raw.len and raw[i + 1] == '\\' and raw[i + 2] == 'u') {
                        const lo = try parseHex4(raw, i + 3);
                        if (lo >= 0xDC00 and lo <= 0xDFFF) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            i += 6; // consume the low surrogate's "\uXXXX"
                        } else {
                            cp = 0xFFFD;
                        }
                    } else {
                        cp = 0xFFFD; // lone high surrogate
                    }
                } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                    cp = 0xFFFD; // stray low surrogate
                }
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cp), &enc) catch blk: {
                    enc[0] = 0xEF;
                    enc[1] = 0xBF;
                    enc[2] = 0xBD;
                    break :blk 3;
                };
                try out.appendSlice(alloc, enc[0..n]);
            },
            else => return error.MalformedMessage,
        }
    }
    return out.toOwnedSlice(alloc);
}

fn parseHex4(raw: []const u8, start: usize) DecodeError!u21 {
    if (start + 4 > raw.len) return error.MalformedMessage;
    return std.fmt.parseInt(u21, raw[start .. start + 4], 16) catch error.MalformedMessage;
}

fn parseIntSpan(text: []const u8, span: Span) DecodeError!i64 {
    const raw = std.mem.trim(u8, text[span.start..span.end], " \t\r\n");
    return std.fmt.parseInt(i64, raw, 10) catch error.MalformedMessage;
}

fn spansEqual(text: []const u8, span: Span, needle: []const u8) bool {
    return std.mem.eql(u8, text[span.start..span.end], needle);
}

/// Materialize an id from its scanned value.
fn buildId(alloc: std.mem.Allocator, text: []const u8, v: ScannedValue) DecodeError!Id {
    return switch (v.kind) {
        .number => .{ .number = try parseIntSpan(text, v.span) },
        .string => .{ .string = try unescapeInner(alloc, text, v.inner) },
        .literal => if (spansEqual(text, v.span, "null")) Id.none else error.MalformedMessage,
        else => error.MalformedMessage,
    };
}

fn dupeValueText(alloc: std.mem.Allocator, text: []const u8, v: ScannedValue) DecodeError![]u8 {
    return alloc.dupe(u8, text[v.span.start..v.span.end]) catch error.OutOfMemory;
}

/// Fields harvested from one top-level scan.
const Fields = struct {
    jsonrpc: ?ScannedValue = null,
    id: ?ScannedValue = null,
    method: ?ScannedValue = null,
    params: ?ScannedValue = null,
    result: ?ScannedValue = null,
    @"error": ?ScannedValue = null,
};

/// Decode one newline-free JSON-RPC 2.0 envelope.
pub fn decodeMessage(alloc: std.mem.Allocator, text: []const u8) DecodeError!Decoded {
    var i = skipWs(text, 0);
    if (i >= text.len or text[i] != '{') return error.MalformedMessage;
    i = skipWs(text, i + 1);

    var f: Fields = .{};
    if (i < text.len and text[i] == '}') {
        i += 1;
    } else {
        while (true) {
            const member = (try nextMember(text, i)) orelse return error.MalformedMessage;
            const key = text[member.key_inner.start..member.key_inner.end];
            if (std.mem.eql(u8, key, "jsonrpc")) {
                f.jsonrpc = member.value;
            } else if (std.mem.eql(u8, key, "id")) {
                f.id = member.value;
            } else if (std.mem.eql(u8, key, "method")) {
                f.method = member.value;
            } else if (std.mem.eql(u8, key, "params")) {
                f.params = member.value;
            } else if (std.mem.eql(u8, key, "result")) {
                f.result = member.value;
            } else if (std.mem.eql(u8, key, "error")) {
                f.@"error" = member.value;
            }
            i = member.next;
            switch (text[i]) {
                ',' => i = skipWs(text, i + 1),
                '}' => {
                    i += 1;
                    break;
                },
                else => return error.MalformedMessage,
            }
        }
    }
    if (skipWs(text, i) != text.len) return error.MalformedMessage; // trailing garbage

    // Envelope validation.
    const jr = f.jsonrpc orelse return error.MalformedMessage;
    if (jr.kind != .string or !spansEqual(text, jr.inner, version_string)) {
        return error.MalformedMessage;
    }
    if (f.method) |m| {
        if (m.kind != .string) return error.MalformedMessage;
        const method = try unescapeInner(alloc, text, m.inner);
        errdefer alloc.free(method);
        var params_json: []u8 = undefined;
        if (f.params) |p| {
            params_json = try dupeValueText(alloc, text, p);
        } else {
            params_json = try alloc.dupe(u8, "");
        }
        errdefer alloc.free(params_json);
        if (f.id) |idv| {
            return .{ .request = .{
                .id = try buildId(alloc, text, idv),
                .method = method,
                .params_json = params_json,
            } };
        }
        return .{ .notification = .{ .method = method, .params_json = params_json } };
    }

    // No method ⇒ must be a response carrying exactly one of result/error.
    const idv = f.id orelse return error.MalformedMessage;
    const has_result = f.result != null;
    const has_error = f.@"error" != null;
    if (has_result and has_error) return error.MalformedMessage;
    if (has_result) {
        const result_json = try dupeValueText(alloc, text, f.result.?);
        const id = buildId(alloc, text, idv) catch |e| {
            alloc.free(result_json);
            return e;
        };
        return .{ .response_ok = .{ .id = id, .result_json = result_json } };
    }
    if (!has_error) return error.MalformedMessage;
    const err_obj = try parseErrorObject(alloc, text, f.@"error".?);
    const id = buildId(alloc, text, idv) catch |e| {
        alloc.free(err_obj.message);
        if (err_obj.data_json) |d| alloc.free(d);
        return e;
    };
    return .{ .response_err = .{ .id = id, .err = err_obj } };
}

/// Extract code/message/data from the `error` member's object span.
fn parseErrorObject(alloc: std.mem.Allocator, text: []const u8, v: ScannedValue) DecodeError!RpcError {
    if (v.kind != .object) return error.MalformedMessage;
    var code: ?i64 = null;
    var message: ?[]u8 = null;
    var data_json: ?[]u8 = null;
    errdefer {
        if (message) |m| alloc.free(m);
        if (data_json) |d| alloc.free(d);
    }

    var i = skipWs(text, v.span.start + 1);
    if (i < text.len and text[i] == '}') {
        // Empty error object: rejected below via missing fields.
    } else {
        while (true) {
            const member = (try nextMember(text, i)) orelse return error.MalformedMessage;
            const key = text[member.key_inner.start..member.key_inner.end];
            if (std.mem.eql(u8, key, "code") and member.value.kind == .number) {
                code = try parseIntSpan(text, member.value.span);
            } else if (std.mem.eql(u8, key, "message") and member.value.kind == .string) {
                message = try unescapeInner(alloc, text, member.value.inner);
            } else if (std.mem.eql(u8, key, "data")) {
                data_json = try dupeValueText(alloc, text, member.value);
            }
            i = member.next;
            switch (text[i]) {
                ',' => i = skipWs(text, i + 1),
                '}' => break,
                else => return error.MalformedMessage,
            }
        }
    }
    return .{
        .code = code orelse return error.MalformedMessage,
        .message = message orelse return error.MalformedMessage,
        .data_json = data_json,
    };
}

// ── scanning toolkit (shared with protocol/mcp.zig) ─────────────────────────

/// Find member `key` in the object whose opening '{' sits at `obj_open`.
/// Returns its raw scanned value, or null when the key is absent.
pub fn memberFind(
    text: []const u8,
    obj_open: usize,
    key: []const u8,
) DecodeError!?ScannedValue {
    var i = skipWs(text, obj_open + 1);
    if (i < text.len and text[i] == '}') return null;
    while (true) {
        const m = (try nextMember(text, i)) orelse return null;
        if (std.mem.eql(u8, text[m.key_inner.start..m.key_inner.end], key)) {
            return m.value;
        }
        i = m.next;
        switch (text[i]) {
            ',' => i = skipWs(text, i + 1),
            '}' => return null,
            else => return error.MalformedMessage,
        }
    }
}

/// Iterate the elements of the array whose opening '[' sits at `arr_open`,
/// yielding each element's scanned value.
pub const ArrayIter = struct {
    text: []const u8,
    i: usize,

    pub fn init(text: []const u8, arr_open: usize) ArrayIter {
        return .{ .text = text, .i = arr_open + 1 };
    }

    pub fn next(self: *ArrayIter) DecodeError!?ScannedValue {
        if (self.i >= self.text.len) return null; // already consumed the ']'
        const j = skipWs(self.text, self.i);
        if (j >= self.text.len) return error.MalformedMessage; // unclosed array
        if (self.text[j] == ']') {
            self.i = self.text.len;
            return null;
        }
        const v = try scanValue(self.text, j);
        const m = skipWs(self.text, v.span.end);
        if (m >= self.text.len) return error.MalformedMessage;
        switch (self.text[m]) {
            ',' => self.i = m + 1,
            ']' => self.i = self.text.len,
            else => return error.MalformedMessage,
        }
        return v;
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

test "memberFind and ArrayIter toolkit" {
    const obj = "{\"name\":\"echo\",\"inputSchema\":{\"type\":\"object\"}}";
    const name = (try memberFind(obj, 0, "name")).?;
    try testing.expectEqualStrings("echo", obj[name.inner.start..name.inner.end]);
    const schema = (try memberFind(obj, 0, "inputSchema")).?;
    try testing.expect(schema.kind == .object);
    try testing.expect((try memberFind(obj, 0, "missing")) == null);

    const arr = "[{\"text\":\"a\"},{\"text\":\"b\"},{\"n\":3}]";
    var it = ArrayIter.init(arr, 0);
    var count: usize = 0;
    var last_end: usize = 0;
    while (try it.next()) |elem| {
        count += 1;
        last_end = elem.span.end;
        try testing.expect(elem.kind == .object);
        try testing.expect(arr[elem.span.start] == '{');
    }
    try testing.expectEqual(@as(usize, 3), count);
    // Exclusive end of the last element lands ON the closing ']'.
    try testing.expectEqual(arr.len - 1, last_end);
    try testing.expect((try it.next()) == null); // iterator is finished
}

const testing = std.testing;

test "request encode/decode round-trip" {
    const alloc = testing.allocator;
    const wire = try encodeRequest(alloc, 42, "tools/list", "{\"cursor\":\"abc\"}");
    defer alloc.free(wire);
    var decoded = try decodeMessage(alloc, wire);
    defer decoded.deinit(alloc);
    try testing.expect(decoded == .request);
    const r = decoded.request;
    try testing.expectEqual(@as(i64, 42), r.id.number);
    try testing.expectEqualStrings("tools/list", r.method);
    try testing.expectEqualStrings("{\"cursor\":\"abc\"}", r.params_json);
}

test "request without params decodes to empty params" {
    const alloc = testing.allocator;
    // encodeNotification maps an empty params body to the `{}` placeholder,
    // so decoding it back yields "{}" (raw span preserved verbatim).
    const wire = try encodeNotification(alloc, "ping", "");
    defer alloc.free(wire);
    var decoded = try decodeMessage(alloc, wire);
    defer decoded.deinit(alloc);
    try testing.expect(decoded == .notification);
    try testing.expectEqualStrings("ping", decoded.notification.method);
    try testing.expectEqualStrings("{}", decoded.notification.params_json);
}

test "response_ok round-trip preserves raw result" {
    const alloc = testing.allocator;
    const wire = try encodeResult(alloc, 7, "{\"tools\":[{\"name\":\"echo\"}],\"more\":true}");
    defer alloc.free(wire);
    var decoded = try decodeMessage(alloc, wire);
    defer decoded.deinit(alloc);
    try testing.expect(decoded == .response_ok);
    try testing.expectEqual(@as(i64, 7), decoded.response_ok.id.number);
    try testing.expectEqualStrings(
        "{\"tools\":[{\"name\":\"echo\"}],\"more\":true}",
        decoded.response_ok.result_json,
    );
}

test "response_err round-trip carries code and message" {
    const alloc = testing.allocator;
    const wire = try encodeError(alloc, 3, -32601, "No such tool");
    defer alloc.free(wire);
    var decoded = try decodeMessage(alloc, wire);
    defer decoded.deinit(alloc);
    try testing.expect(decoded == .response_err);
    try testing.expectEqual(@as(i64, 3), decoded.response_err.id.number);
    try testing.expectEqual(@as(i64, -32601), decoded.response_err.err.code);
    try testing.expectEqualStrings("No such tool", decoded.response_err.err.message);
    try testing.expect(decoded.response_err.err.data_json == null);
}

test "decode tolerates whitespace everywhere" {
    const alloc = testing.allocator;
    const wire =
        \\ { "jsonrpc" : "2.0" , "id" : 9 ,
        \\   "method" : "tools/call" ,
        \\   "params" : { "name" : "echo" } }
    ;
    var decoded = try decodeMessage(alloc, wire);
    defer decoded.deinit(alloc);
    try testing.expect(decoded == .request);
    try testing.expectEqual(@as(i64, 9), decoded.request.id.number);
    try testing.expectEqualStrings("tools/call", decoded.request.method);
    try testing.expectEqualStrings("{ \"name\" : \"echo\" }", decoded.request.params_json);
}

test "decode rejects malformed envelopes without crashing" {
    const alloc = testing.allocator;
    const bad = [_][]const u8{
        "",
        "   ",
        "{",
        "{}",
        "[1,2]", // batch: unsupported by design
        "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"m\"}", // wrong version
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":1,\"message\":\"m\"}}",
        "{\"jsonrpc\":\"2.0\",\"result\":{}}", // response without id
        "{\"jsonrpc\":\"2.0\",\"id\":1}", // neither result nor error nor method
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}} extra",
        "{\"jsonrpc\":\"2.0\",\"id\":tru,\"method\":\"m\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":}",
        "not json at all",
    };
    for (bad) |input| {
        try testing.expectError(error.MalformedMessage, decodeMessage(alloc, input));
    }
    // A bare notification (method, no id) is VALID — decode it explicitly.
    var decoded = try decodeMessage(alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"m\"}");
    defer decoded.deinit(alloc);
    try testing.expect(decoded == .notification);
}

test "decode accepts null result and null id" {
    const alloc = testing.allocator;
    var decoded = try decodeMessage(alloc, "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":null}");
    defer decoded.deinit(alloc);
    try testing.expect(decoded == .response_ok);
    try testing.expect(decoded.response_ok.id == .none);
    try testing.expectEqualStrings("null", decoded.response_ok.result_json);
}

test "string escapes round-trip incl unicode" {
    const alloc = testing.allocator;
    const wire = try encodeRequest(alloc, 1, "méthöd\n\"quote\"", "");
    defer alloc.free(wire);
    var decoded = try decodeMessage(alloc, wire);
    defer decoded.deinit(alloc);
    try testing.expectEqualStrings("méthöd\n\"quote\"", decoded.request.method);

    // Direct escape forms: \u0041, \/, surrogate pair for 😀.
    var decoded2 = try decodeMessage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"\\u0041\\/\\ud83d\\ude00\\\\\\t\"}",
    );
    defer decoded2.deinit(alloc);
    try testing.expectEqualStrings("A/\xF0\x9F\x98\x80\\\t", decoded2.notification.method);
}

test "string id and error data survive decode" {
    const alloc = testing.allocator;
    const wire =
        \\{"jsonrpc":"2.0","id":"req-17","error":{"code":-32000,"message":"boom","data":{"hint":"try later"}}}
    ;
    var decoded = try decodeMessage(alloc, wire);
    defer decoded.deinit(alloc);
    try testing.expect(decoded == .response_err);
    const e = decoded.response_err;
    try testing.expect(e.id == .string);
    try testing.expectEqualStrings("req-17", e.id.string);
    try testing.expectEqualStrings("{\"hint\":\"try later\"}", e.err.data_json.?);
}

test "nested containers in params are kept verbatim" {
    const alloc = testing.allocator;
    const params = "{\"a\":{\"b\":[1,{\"c\":\"}]}\"]},\"deep\":{\"x\":\"\\\"q\\\"\"}}}";
    const wire = try encodeRequest(alloc, 0, "t", params);
    defer alloc.free(wire);
    var decoded = try decodeMessage(alloc, wire);
    defer decoded.deinit(alloc);
    try testing.expectEqualStrings(params, decoded.request.params_json);
}
