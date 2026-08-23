//! Fuzz suite: protocol/jsonrpc.zig codec (SWARM wave-4, agent J-fuzz).
//!
//! Properties:
//! - ENCODE→DECODE round-trip: every encode* output decodes back to a
//!   Decoded carrying field-equal data (method/id/params verbatim) and
//!   deinits leak-free.
//! - DECODE-anything: mutated / hostile lines yield MalformedMessage or
//!   OutOfMemory — never a panic; successful decodes always deinit cleanly.
//! - unescapeInner over arbitrary string interiors: owned-or-error, with
//!   surrogate pairs combined and lone halves mapped to U+FFFD.
//!
//! Corpus: src/fuzz/corpus/jsonrpc_seeds.txt, embedded at compile time.

const std = @import("std");
const mutator = @import("mutator.zig");
const jsonrpc = @import("../protocol/jsonrpc.zig");

const corpus_raw = @embedFile("corpus/jsonrpc_seeds.txt");

const seed_jsonrpc = 0x2C0D;

test "fuzz: decodeMessage over mutated seeds never panics or leaks" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_jsonrpc);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| {
        var round: usize = 0;
        while (round < 10) : (round += 1) {
            try mutator.mutate(alloc, &out, &rnd, seed);
            if (jsonrpc.decodeMessage(alloc, out.items)) |decoded| {
                var d = decoded;
                d.deinit(alloc);
            } else |_| {}
        }
    }
}

fn expectRoundTrip(
    alloc: std.mem.Allocator,
    wire: []const u8,
    want_method: []const u8,
    want_params: []const u8,
    want_id: i64,
) !void {
    var decoded = try jsonrpc.decodeMessage(alloc, wire);
    defer decoded.deinit(alloc);
    try std.testing.expect(decoded == .request);
    try std.testing.expectEqual(want_id, decoded.request.id.number);
    try std.testing.expectEqualStrings(want_method, decoded.request.method);
    try std.testing.expectEqualStrings(want_params, decoded.request.params_json);
}

test "property: encodeRequest survives adversarial methods and params" {
    const alloc = std.testing.allocator;
    const methods = [_][]const u8{
        "",
        "tools/list",
        "méthöd\n\"quote\"",
        "\\",
        "\\\\\"",
        "\x01\x02 control\tchars",
        "emoji \xF0\x9F\x98\x80 tail\\",
        "\"method\":\"fake\",\"params\":{}",
    };
    const params = [_][]const u8{
        "",
        "{}",
        "{\"a\":{\"b\":[1,{\"c\":\"}]}\"]},\"deep\":{\"x\":\"\\\"q\\\"\"}}}",
        "[1,2,3]",
        "null",
        "7",
    };
    for (methods, 0..) |m, i| {
        for (params, 0..) |p, j| {
            const wire = try jsonrpc.encodeRequest(alloc, @intCast(i * 100 + j), m, p);
            defer alloc.free(wire);
            // Single-line framing invariant: no raw newline may survive.
            try std.testing.expect(std.mem.indexOfScalar(u8, wire, '\n') == null);
            try expectRoundTrip(alloc, wire, m, if (p.len == 0) "{}" else std.mem.trim(u8, p, " \t\r\n"), @intCast(i * 100 + j));
        }
    }
}

test "regression: oversized ids reject cleanly instead of wrapping" {
    const alloc = std.testing.allocator;
    // Encoder precondition pinned here: params_json must already be valid
    // JSON. Bare text is embedded verbatim (trimmed) and the DECODER then
    // rejects the whole line with MalformedMessage — clean, never a crash.
    const wire_bad = try jsonrpc.encodeRequest(alloc, 1, "m", "   spaced   ");
    defer alloc.free(wire_bad);
    try std.testing.expectError(error.MalformedMessage, jsonrpc.decodeMessage(alloc, wire_bad));

    const oversized = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":99999999999999999999,\"result\":{}}", // > i64 max
        "{\"jsonrpc\":\"2.0\",\"id\":-99999999999999999999,\"result\":{}}", // < i64 min
        "{\"jsonrpc\":\"2.0\",\"id\":9223372036854775808,\"result\":{}}", // exactly max+1
        "{\"jsonrpc\":\"2.0\",\"id\":1e99999,\"result\":{}}", // absurd exponent span
    };
    for (oversized) |line| {
        try std.testing.expectError(error.MalformedMessage, jsonrpc.decodeMessage(alloc, line));
    }
    // Boundary values inside i64 still decode.
    for ([_]i64{ -9223372036854775808, 9223372036854775807, 0 }) |v| {
        const wire = try jsonrpc.encodeResult(alloc, v, "null");
        defer alloc.free(wire);
        var d = try jsonrpc.decodeMessage(alloc, wire);
        defer d.deinit(alloc);
        try std.testing.expect(d == .response_ok);
        try std.testing.expectEqual(v, d.response_ok.id.number);
    }
}

test "fuzz: unescapeInner tolerates arbitrary interiors incl split escapes" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_jsonrpc ^ 0x00F1);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| {
        var round: usize = 0;
        while (round < 12) : (round += 1) {
            try mutator.mutate(alloc, &out, &rnd, seed);
            // Treat the raw bytes as a JSON string INTERIOR (span covers
            // everything): decode must yield an owned slice or an error.
            if (jsonrpc.unescapeInner(alloc, out.items, .{ .start = 0, .end = out.items.len })) |s| {
                alloc.free(s);
            } else |_| {}
        }
    }

    // Pinned escape semantics: pairs combine, lone halves replace.
    {
        const s = try jsonrpc.unescapeInner(alloc, "\\ud83d\\ude00", .{ .start = 0, .end = 12 });
        defer alloc.free(s);
        try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", s);
    }
    {
        const s = try jsonrpc.unescapeInner(alloc, "\\uD800x", .{ .start = 0, .end = 7 });
        defer alloc.free(s);
        try std.testing.expectEqualStrings("\u{FFFD}x", s);
    }
    // Truncated escape at the very end must be an error, not OOB.
    try std.testing.expectError(error.MalformedMessage, jsonrpc.unescapeInner(alloc, "tail\\u00", .{ .start = 0, .end = 8 }));
}

test "encodeError/Result decode back through the same gauntlet" {
    const alloc = std.testing.allocator;
    const wire_err = try jsonrpc.encodeError(alloc, -3, -32601, "boom \"quoted\"\nnewline");
    defer alloc.free(wire_err);
    var d = try jsonrpc.decodeMessage(alloc, wire_err);
    defer d.deinit(alloc);
    try std.testing.expect(d == .response_err);
    try std.testing.expectEqualStrings("boom \"quoted\"\nnewline", d.response_err.err.message);

    const wire_ok = try jsonrpc.encodeNotification(alloc, "notify/x", "{\"k\":[null,true]}");
    defer alloc.free(wire_ok);
    var n = try jsonrpc.decodeMessage(alloc, wire_ok);
    defer n.deinit(alloc);
    try std.testing.expect(n == .notification);
    try std.testing.expectEqualStrings("{\"k\":[null,true]}", n.notification.params_json);
}
