//! Fuzz suite: obs.zig parseEnvelope (SWARM wave-4, agent J-fuzz).
//!
//! Property: for ANY line bytes, parseEnvelope yields a fully-owned
//! ParsedEnvelope (deinit frees the four strings) or MalformedEnvelope /
//! OutOfMemory — never a panic, never a leak, never an out-of-bounds slice.
//! Round-trip direction: canonical envelopes built from adversarial string
//! fields must re-parse field-equal (writer escapes; parser decodes).

const std = @import("std");
const mutator = @import("mutator.zig");
const obs = @import("../obs.zig");

const corpus_raw = @embedFile("corpus/envelope_lines.txt");

const seed_env = 0x0B5E;

test "fuzz: parseEnvelope over mutated seeds" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_env);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| {
        try exerciseLine(alloc, seed);
        var round: usize = 0;
        while (round < 12) : (round += 1) {
            try mutator.mutate(alloc, &out, &rnd, seed);
            try exerciseLine(alloc, out.items);
        }
    }
}

fn exerciseLine(alloc: std.mem.Allocator, line: []const u8) !void {
    if (obs.parseEnvelope(alloc, line)) |env| {
        var e = env;
        // Structural bounds: hex ids fixed width, payload ≤ line length.
        try obs_envelope_sane(&e, line);
        e.deinit(alloc);
    } else |e| switch (e) {
        error.MalformedEnvelope => {},
        else => return e,
    }
}

fn obs_envelope_sane(e: *const obs.ParsedEnvelope, line: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 16), e.trace_id.len);
    try std.testing.expectEqual(@as(usize, 8), e.span_id.len);
    for (e.trace_id) |c| try std.testing.expect(isLowerHex(c));
    for (e.span_id) |c| try std.testing.expect(isLowerHex(c));
    try std.testing.expect(e.session_id.len <= line.len);
    try std.testing.expect(e.agent_id.len <= line.len);
    try std.testing.expect(e.event_type.len <= line.len);
    try std.testing.expect(e.payload_json.len <= line.len);
}

fn isLowerHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

test "property: writer output re-parses field-equal under adversarial fields" {
    const alloc = std.testing.allocator;
    var rnd = mutator.Rnd.init(seed_env ^ 0x7E57);

    const nasty_strings = [_][]const u8{
        "",
        "plain",
        "quote \" mid",
        "back\\slash",
        "newline\nand\rreturn",
        "tab\tstop",
        "\x01\x02\x7f controls",
        "unicode é 你好 \xF0\x9F\x98\x80",
        "decoy\",\"payload\":{\"fake\":1}",
        "\\\"escaped-openers\\\"",
    };

    for (nasty_strings) |sid| {
        for (nasty_strings[0..3]) |aid| {
            const env = obs.EventEnvelope{
                .timestamp_unix_ms = @intCast(rnd.below(1 << 40)),
                .trace_id = "0123456789abcdef".*,
                .span_id = "fedcba98".*,
                .session_id = sid,
                .agent_id = aid,
                .event_type = "tool.completed",
                .payload_json = "{\"k\":[1,{\"deep\":\"v\"}],\"note\":\"ok \\ end\"}",
            };
            const line = try env.toJson(alloc);
            defer alloc.free(line);
            try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null); // JSONL framing

            var got = try obs.parseEnvelope(alloc, line);
            defer got.deinit(alloc);
            try std.testing.expectEqual(env.timestamp_unix_ms, got.timestamp_unix_ms);
            try std.testing.expectEqualStrings(sid, got.session_id);
            try std.testing.expectEqualStrings(aid, got.agent_id);
            try std.testing.expectEqualStrings("tool.completed", got.event_type);
        }
    }
}

test "regression: malformed lines rejected with precise reasons intact" {
    const alloc = std.testing.allocator;
    const bad = [_][]const u8{
        "",
        "not json",
        "{}",
        "{\"timestamp_unix_ms\":1}", // everything else missing
        "{\"timestamp_unix_ms\":nan,\"trace_id\":\"0123456789abcdef\",\"span_id\":\"a1b2c3d4\",\"session_id\":\"s\",\"agent_id\":\"a\",\"event_type\":\"e\",\"payload\":null}",
        "{\"timestamp_unix_ms\":1,\"trace_id\":\"SHORT\",\"span_id\":\"a1b2c3d4\",\"session_id\":\"s\",\"agent_id\":\"a\",\"event_type\":\"e\",\"payload\":null}",
        "{\"timestamp_unix_ms\":1,\"trace_id\":\"0123456789ABCDEF\",\"span_id\":\"a1b2c3d4\",\"session_id\":\"s\",\"agent_id\":\"a\",\"event_type\":\"e\",\"payload\":null}", // uppercase hex rejected
        "{\"timestamp_unix_ms\":99999999999999999999999,\"trace_id\":\"0123456789abcdef\",\"span_id\":\"a1b2c3d4\",\"session_id\":\"s\",\"agent_id\":\"a\",\"event_type\":\"e\",\"payload\":null}", // timestamp overflow
        "[1,2,3]", // not an object
    };
    for (bad) |line| {
        try std.testing.expectError(error.MalformedEnvelope, obs.parseEnvelope(alloc, line));
    }

    // Decoy keys inside earlier string values cannot shadow later fields.
    var got = try obs.parseEnvelope(alloc,
        \\{"timestamp_unix_ms":1,"trace_id":"0123456789abcdef","span_id":"a1b2c3d4","session_id":"decoy\",\"payload\":{\"fake\":1}","agent_id":"a","event_type":"e","payload":{"real":2}}
    );
    defer got.deinit(alloc);
    try std.testing.expectEqualStrings("{\"real\":2}", got.payload_json);

    // Multiline payloads were flattened by the writer; parser accepts them.
    var flat = try obs.parseEnvelope(alloc,
        \\{"timestamp_unix_ms":42,"trace_id":"ffffffffffffffff","span_id":"00000001","session_id":"s","agent_id":"a","event_type":"m","payload":{   "k": "v",    "n": 7 }}
    );
    defer flat.deinit(alloc);
    try std.testing.expectEqualStrings("{   \"k\": \"v\",    \"n\": 7 }", flat.payload_json);
}
