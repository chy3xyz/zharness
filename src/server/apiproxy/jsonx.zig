//! Minimal hand-rolled JSON scanning/serialization for the apiproxy modules.
//!
//! Style follows src/model/model.zig's pub helpers (escape, findMatchingBrace,
//! findMatchingBracket) — this module reuses those directly and adds only what
//! the wire layer needs beyond them:
//!
//! - `MemberIter`: iterates the TOP-LEVEL members of a JSON object with
//!   nesting-aware value slicing (model.zig's extractField scans naively and
//!   misfires on nested duplicates).
//! - `decodeString`: full unescape including `\uXXXX` (with surrogate pairs);
//!   model.unescape covers only the simple escapes zharness itself emits,
//!   while apiproxy consumes browser-produced JSON.
//! - `appendJsonString`: escaping for OUTPUT, including control characters
//!   (`\u00XX`) which model.escape passes through raw.
//!
//! Everything here is allocation-light, pure (except the two alloc-taking
//! helpers), and fully unit-tested below.

const std = @import("std");
const model = @import("../../model/model.zig");

// ── object scanning ─────────────────────────────────────────────────────────

/// Trim ASCII whitespace at both ends.
pub fn trimWs(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Given a JSON document, return the span strictly INSIDE its outermost
/// `{...}` object braces, or null when the document is not a JSON object.
pub fn objectBody(json: []const u8) ?[]const u8 {
    const t = trimWs(json);
    if (t.len < 2 or t[0] != '{') return null;
    const end = model.findMatchingBrace(t, 0) orelse return null;
    // findMatchingBrace returns the index PAST the closing brace.
    return t[1 .. end - 1];
}

/// Index PAST the '}' matching the '{' at `start` (model.findMatchingBrace
/// passthrough; keeps apiproxy modules from importing model directly).
pub fn matchBraceFrom(s: []const u8, start: usize) ?usize {
    return model.findMatchingBrace(s, start);
}

/// One top-level object member: raw slices into the source buffer.
pub const Member = struct {
    /// Raw key bytes WITHOUT surrounding quotes (keys are assumed escape-free;
    /// every key this protocol defines is plain ASCII).
    key: []const u8,
    /// Raw VALUE slice — quotes included for strings, braces included for
    /// objects/arrays. Not trimmed on either side beyond what scanning needs.
    value: []const u8,
};

/// Iterates top-level members of a JSON object BODY (as produced by
/// `objectBody`). Nesting-aware: nested objects/arrays and escaped quotes
/// inside strings never produce phantom members.
pub const MemberIter = struct {
    body: []const u8,
    i: usize = 0,

    pub fn init(body_span: []const u8) MemberIter {
        return .{ .body = body_span };
    }

    pub fn next(self: *MemberIter) ?Member {
        var i = self.i;
        const b = self.body;

        // Skip leading whitespace and commas between members.
        while (i < b.len and (b[i] == ' ' or b[i] == '\t' or b[i] == '\r' or b[i] == '\n' or b[i] == ',')) : (i += 1) {}
        if (i >= b.len) {
            self.i = i;
            return null;
        }
        if (b[i] != '"') {
            // Malformed: stop iterating (caller treats the document as bad).
            self.i = b.len;
            return null;
        }

        // Key string (scan respecting backslash escapes).
        i += 1;
        const key_start = i;
        while (i < b.len and b[i] != '"') : (i += 1) {
            if (b[i] == '\\' and i + 1 < b.len) i += 1;
        }
        if (i >= b.len) {
            self.i = b.len;
            return null;
        }
        const key = b[key_start..i];
        i += 1; // past closing quote

        // Colon.
        while (i < b.len and (b[i] == ' ' or b[i] == '\t' or b[i] == '\r' or b[i] == '\n')) : (i += 1) {}
        if (i >= b.len or b[i] != ':') {
            self.i = b.len;
            return null;
        }
        i += 1;
        while (i < b.len and (b[i] == ' ' or b[i] == '\t' or b[i] == '\r' or b[i] == '\n')) : (i += 1) {}

        // Value: string / object / array / literal.
        const value_start = i;
        switch (b[i]) {
            '"' => {
                i += 1;
                while (i < b.len and b[i] != '"') : (i += 1) {
                    if (b[i] == '\\' and i + 1 < b.len) i += 1;
                }
                if (i >= b.len) {
                    self.i = b.len;
                    return null;
                }
                i += 1; // past closing quote
            },
            '{' => {
                const end = model.findMatchingBrace(b, i) orelse {
                    self.i = b.len;
                    return null;
                };
                i = end;
            },
            '[' => {
                const end = model.findMatchingBracket(b, i) orelse {
                    self.i = b.len;
                    return null;
                };
                i = end;
            },
            else => {
                // number / true / false / null: until delimiter.
                while (i < b.len and b[i] != ',' and b[i] != '}' and b[i] != ']') : (i += 1) {}
                // Trim trailing whitespace off the literal.
                var ve = i;
                while (ve > value_start and (b[ve - 1] == ' ' or b[ve - 1] == '\t' or b[ve - 1] == '\r' or b[ve - 1] == '\n')) : (ve -= 1) {}
                self.i = i;
                return .{ .key = key, .value = b[value_start..ve] };
            },
        }

        self.i = i;
        return .{ .key = key, .value = b[value_start..i] };
    }
};

/// Raw value of a top-level member (untrimmed slice as scanned), or null.
pub fn getRaw(json: []const u8, key: []const u8) ?[]const u8 {
    const body = objectBody(json) orelse return null;
    var it = MemberIter.init(body);
    while (it.next()) |m| {
        if (std.mem.eql(u8, m.key, key)) return m.value;
    }
    return null;
}

/// Decoded (unescaped) string value of a top-level member, allocated with
/// `alloc`. Null when the member is absent or not a string.
pub fn getStringAlloc(alloc: std.mem.Allocator, json: []const u8, key: []const u8) !?[]const u8 {
    const raw = getRaw(json, key) orelse return null;
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return try decodeString(alloc, raw[1 .. raw.len - 1]);
}

/// Integer value of a top-level member. Null when absent or not numeric.
/// Floats truncate toward zero (wire integers never arrive fractional).
pub fn getInt(json: []const u8, key: []const u8) ?i64 {
    const raw = trimWs(getRaw(json, key) orelse return null);
    if (raw.len == 0) return null;
    // Reject quoted values and literals.
    if (raw[0] == '"' or std.ascii.isAlphabetic(raw[0])) return null;
    return std.fmt.parseInt(i64, raw, 10) catch blk: {
        const f = std.fmt.parseFloat(f64, raw) catch return null;
        break :blk @intFromFloat(@trunc(f));
    };
}

/// True when the raw value looks like a JSON string (starts with a quote).
pub fn isString(raw: []const u8) bool {
    return raw.len >= 2 and raw[0] == '"';
}

// ── string decoding ─────────────────────────────────────────────────────────

/// Decode a JSON string body (the bytes BETWEEN quotes) into a fresh
/// allocation. Full escape set: \" \\ \/ \b \f \n \r \t \uXXXX including
/// surrogate pairs. Unknown escapes degrade to the literal second byte
/// (same posture as model.unescape); truncated `\u` keeps the raw text.
pub fn decodeString(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    // Fast path: no backslash → verbatim copy.
    if (std.mem.indexOfScalar(u8, body, '\\') == null) return try alloc.dupe(u8, body);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, body.len);

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\\') {
            try out.append(alloc, body[i]);
            continue;
        }
        i += 1;
        if (i >= body.len) {
            try out.append(alloc, '\\');
            break;
        }
        switch (body[i]) {
            '"' => try out.append(alloc, '"'),
            '\\' => try out.append(alloc, '\\'),
            '/' => try out.append(alloc, '/'),
            'b' => try out.append(alloc, 0x08),
            'f' => try out.append(alloc, 0x0C),
            'n' => try out.append(alloc, '\n'),
            'r' => try out.append(alloc, '\r'),
            't' => try out.append(alloc, '\t'),
            'u' => {
                const cp = parseHex4(body, i + 1) orelse {
                    // Malformed \u: keep literally, continue after 'u'.
                    try out.appendSlice(alloc, "\\u");
                    continue;
                };
                i += 4;
                if (cp >= 0xD800 and cp <= 0xDBFF and i + 6 < body.len and
                    body[i + 1] == '\\' and body[i + 2] == 'u')
                {
                    if (parseHex4(body, i + 3)) |lo| {
                        if (lo >= 0xDC00 and lo <= 0xDFFF) {
                            i += 6;
                            const combined: u21 = 0x10000 +
                                (@as(u21, cp - 0xD800) << 10) + @as(u21, lo - 0xDC00);
                            var utf8_buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(combined, &utf8_buf) catch 1;
                            try out.appendSlice(alloc, utf8_buf[0..n]);
                            continue;
                        }
                    }
                }
                // Lone BMP code point (including unpaired surrogate — emit
                // U+FFFD replacement rather than crashing).
                var utf8_buf: [4]u8 = undefined;
                const final_cp: u21 = if (cp >= 0xD800 and cp <= 0xDFFF) 0xFFFD else cp;
                const n = std.unicode.utf8Encode(final_cp, &utf8_buf) catch 1;
                try out.appendSlice(alloc, utf8_buf[0..n]);
            },
            else => try out.append(alloc, body[i]),
        }
    }
    return out.toOwnedSlice(alloc);
}

fn parseHex4(s: []const u8, start: usize) ?u16 {
    if (start + 4 > s.len) return null;
    var v: u16 = 0;
    for (s[start .. start + 4]) |c| {
        const d = std.fmt.charToDigit(c, 16) catch return null;
        v = v * 16 + d;
    }
    return v;
}

// ── serialization ───────────────────────────────────────────────────────────

/// Append `s` as a complete JSON string literal (quotes included), escaping
/// `"`, `\`, and all C0 control characters (`\b \f \n \r \t` spelled out,
/// others as `\u00XX`). Multi-byte UTF-8 passes through untouched.
pub fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    try appendJsonStringBody(alloc, out, s);
    try out.append(alloc, '"');
}

/// Escape the body only (no surrounding quotes) — same rules as
/// `appendJsonString`.
pub fn appendJsonStringBody(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            0x08 => try out.appendSlice(alloc, "\\b"),
            0x0C => try out.appendSlice(alloc, "\\f"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [8]u8 = undefined;
                    try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}));
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
}

/// Append a decimal integer.
pub fn appendInt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), n: i64) !void {
    var buf: [24]u8 = undefined;
    try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "{d}", .{n}));
}

// ── time formatting (ISO-8601 Z, for workspace views) ──────────────────────

/// Render epoch milliseconds as `YYYY-MM-DDTHH:MM:SSZ` (UTC). Negative or
/// absurd inputs clamp to the epoch (defensive; real clocks are positive).
pub fn appendIso8601(alloc: std.mem.Allocator, out: *std.ArrayList(u8), epoch_ms: i64) !void {
    const ms = if (epoch_ms < 0) 0 else epoch_ms;
    const secs: i64 = @divFloor(ms, std.time.ms_per_s);
    const days: i64 = @divFloor(secs, std.time.s_per_day);
    const secs_of_day: u32 = @intCast(secs - days * std.time.s_per_day);

    const civ = civilFromDays(days);
    const hour: u32 = secs_of_day / 3600;
    const minute: u32 = (secs_of_day % 3600) / 60;
    const second: u32 = secs_of_day % 60;

    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(civ.year)), civ.month, civ.day, hour, minute, second,
    });
    try out.appendSlice(alloc, s);
}

/// Days-since-epoch → civil date (Howard Hinnant's algorithm).
fn civilFromDays(z_in: i64) struct { year: i64, month: u32, day: u32 } {
    const z = z_in + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097); // [0, 146096]
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    const mp: u64 = (5 * doy + 2) / 153; // [0, 11]
    const d: u32 = @intCast(doy - (153 * mp + 2) / 5 + 1); // [1, 31]
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9); // [1, 12]
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = m,
        .day = d,
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "objectBody and MemberIter slice top-level members nesting-aware" {
    const doc =
        \\{"a":"x,y","b":{"c":"}"},"arr":[{"k":1}],"n":42,"lit":true,"z":null}
    ;
    const body = objectBody(doc) orelse return error.TestUnexpectedResult;
    var it = MemberIter.init(body);

    const m1 = it.next().?;
    try testing.expectEqualStrings("a", m1.key);
    try testing.expectEqualStrings("\"x,y\"", m1.value);

    const m2 = it.next().?;
    try testing.expectEqualStrings("b", m2.key);
    try testing.expectEqualStrings("{\"c\":\"}\"}", m2.value);

    const m3 = it.next().?;
    try testing.expectEqualStrings("arr", m3.key);
    try testing.expectEqualStrings("[{\"k\":1}]", m3.value);

    const m4 = it.next().?;
    try testing.expectEqualStrings("n", m4.key);
    try testing.expectEqualStrings("42", m4.value);

    const m5 = it.next().?;
    try testing.expectEqualStrings("lit", m5.key);
    try testing.expectEqualStrings("true", m5.value);

    const m6 = it.next().?;
    try testing.expectEqualStrings("z", m6.key);
    try testing.expectEqualStrings("null", m6.value);

    try testing.expect(it.next() == null);
}

test "getters: string/int/raw lookups" {
    const doc = "{\"type\":\"client-request\",\"rpcId\":\"abc\\\"q\",\"n\":-17,\"big\":1755946500000,\"f\":2.75,\"s\":\"\\u00e9\\uD83D\\uDE00\"}";
    const t = (try getStringAlloc(testing.allocator, doc, "type")).?;
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("client-request", t);
    const rpc = (try getStringAlloc(testing.allocator, doc, "rpcId")).?;
    defer testing.allocator.free(rpc);
    try testing.expectEqualStrings("abc\"q", rpc);
    try testing.expectEqual(@as(?i64, -17), getInt(doc, "n"));
    try testing.expectEqual(@as(?i64, 1755946500000), getInt(doc, "big"));
    try testing.expectEqual(@as(?i64, 2), getInt(doc, "f")); // float truncates
    try testing.expect(getInt(doc, "type") == null); // quoted → not an int
    try testing.expect(getInt(doc, "absent") == null);

    const uni = (try getStringAlloc(testing.allocator, doc, "s")).?;
    defer testing.allocator.free(uni);
    try testing.expectEqualStrings("é😀", uni);
}

test "getStringAlloc rejects non-string values" {
    const doc = "{\"n\":12,\"o\":{\"a\":1}}";
    try testing.expect((try getStringAlloc(testing.allocator, doc, "n")) == null);
    try testing.expect((try getStringAlloc(testing.allocator, doc, "o")) == null);
    try testing.expect((try getStringAlloc(testing.allocator, doc, "missing")) == null);
}

test "decodeString simple escapes match model.unescape behavior" {
    const got = try decodeString(testing.allocator, "line1\\nline2 \\\"q\\\" \\\\ end");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("line1\nline2 \"q\" \\ end", got);
}

test "lone surrogate degrades to replacement char without crash" {
    const got = try decodeString(testing.allocator, "\\uD83D alone");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\u{FFFD} alone", got);
}

test "appendJsonString escapes control chars and passes UTF-8 through" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendJsonString(testing.allocator, &out, "a\"b\nc\u{00}\u{01F}é");
    try testing.expectEqualStrings("\"a\\\"b\\nc\\u0000\\u001fé\"", out.items);
}

test "objectBody rejects non-objects and truncated input" {
    try testing.expect(objectBody("null") == null);
    try testing.expect(objectBody("[1,2]") == null);
    try testing.expect(objectBody("{\"a\":") == null);
    try testing.expect(objectBody("") == null);
}

test "appendIso8601 formats UTC timestamps" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    // 2026-08-23T10:15:00Z == 1787480100 s == 1787480100000 ms.
    try appendIso8601(testing.allocator, &out, 1787480100000);
    try testing.expectEqualStrings("2026-08-23T10:15:00Z", out.items);

    out.clearRetainingCapacity();
    try appendIso8601(testing.allocator, &out, 0);
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", out.items);
}
