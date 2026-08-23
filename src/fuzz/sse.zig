//! Fuzz suite: model/model.zig SseParser (SWARM wave-4, agent J-fuzz).
//!
//! Properties over arbitrary byte streams fed in arbitrary chunkings:
//! - feed() accepts anything (partial lines, split escape sequences, garbage
//!   events, CRLF mixtures, [DONE] storms) without panicking or hanging;
//! - finish() assembles a ChatResponse whose buffers are fully owned
//!   (deinit frees everything — leak property under testing.allocator);
//! - content assembly equals the exact concatenation of content deltas
//!   REGARDLESS of how stream bytes were chunked across feeds.
//!
//! Corpus: src/fuzz/corpus/sse_streams.txt, embedded at compile time.

const std = @import("std");
const mutator = @import("mutator.zig");
const model = @import("../model/model.zig");

const corpus_raw = @embedFile("corpus/sse_streams.txt");

const seed_sse = 0x55E0;

/// Feed `stream` in deterministic random chunks (1–8 bytes).
fn feedChunked(p: *model.SseParser, rnd: *mutator.Rnd, stream: []const u8) !void {
    var off: usize = 0;
    while (off < stream.len and !p.done) {
        const step = 1 + rnd.below(8);
        const end = @min(off + step, stream.len);
        try p.feed(stream[off..end]);
        off = end;
    }
}

/// Panic/leak-freedom gauntlet shared by every case.
fn runParser(rnd: *mutator.Rnd, stream: []const u8, chunked: bool) !void {
    const alloc = std.testing.allocator;
    var p = model.SseParser.init(alloc);
    defer p.deinit();
    if (chunked) {
        try feedChunked(&p, rnd, stream);
    } else {
        try p.feed(stream);
    }
    if (p.finish()) |resp| {
        var r = resp;
        r.deinit(alloc);
    } else |_| {}
}

test "fuzz: mutated streams survive arbitrary chunkings" {
    var rnd = mutator.Rnd.init(seed_sse);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| {
        try runParser(&rnd, seed, false);

        var round: usize = 0;
        while (round < 10) : (round += 1) {
            try mutator.mutate(std.testing.allocator, &out, &rnd, seed);
            try runParser(&rnd, out.items, rnd.pct(70));
        }
    }
}

test "property: content assembly is chunking-independent" {
    const alloc = std.testing.allocator;

    // Wire fragments built from parts so every escape stays legible.
    const q_esc = "\\\""; // bytes: backslash, quote

    const ev = struct {
        fn data(alloc2: std.mem.Allocator, inner: []const u8) ![]u8 {
            return std.fmt.allocPrint(alloc2, "data: {s}\n\n", .{inner});
        }
        fn delta(alloc2: std.mem.Allocator, field: []const u8, value: []const u8) ![]u8 {
            return std.fmt.allocPrint(
                alloc2,
                "{{\"choices\":[{{\"delta\":{{\"{s}\":\"{s}\"}},\"finish_reason\":null}}]}}",
                .{ field, value },
            );
        }
    };

    // Case 1: simple two-delta word.
    {
        const d1 = try ev.delta(alloc, "content", "He");
        defer alloc.free(d1);
        const d2 = try ev.delta(alloc, "content", "llo");
        defer alloc.free(d2);
        const stream = try std.fmt.allocPrint(alloc, "data: {s}\ndata: {s}\ndata: [DONE]\n", .{ d1, d2 });
        defer alloc.free(stream);
        try expectAcrossChunkings(alloc, stream, "Hello", "");
    }

    // Case 2: reasoning + content carrying escaped quotes.
    {
        const quoted = try std.fmt.allocPrint(alloc, "es{s}c{s}ape", .{ q_esc, q_esc });
        defer alloc.free(quoted);
        const d1 = try ev.delta(alloc, "reasoning_content", "th");
        defer alloc.free(d1);
        const d2 = try ev.delta(alloc, "content", quoted);
        defer alloc.free(d2);
        // CRLF framing variant this time.
        const stream = try std.fmt.allocPrint(alloc, "data: {s}\r\ndata: {s}\r\n\r\n", .{ d1, d2 });
        defer alloc.free(stream);
        try expectAcrossChunkings(alloc, stream, "es\"c\"ape", "th");
    }

    // Case 3: a lone backslash before the closing quote (split-escape bait).
    {
        const d1 = try ev.delta(alloc, "content", "a\\\\"); // bytes: a\
        defer alloc.free(d1);
        const stream = try ev.data(alloc, d1);
        defer alloc.free(stream);
        try expectAcrossChunkings(alloc, stream, "a\\", "");
    }
}

fn expectAcrossChunkings(
    alloc: std.mem.Allocator,
    stream: []const u8,
    want_content: []const u8,
    want_reasoning: []const u8,
) !void {
    var mode: usize = 0;
    while (mode < 3) : (mode += 1) {
        var p = model.SseParser.init(alloc);
        defer p.deinit();
        switch (mode) {
            0 => try p.feed(stream),
            1 => for (stream) |b| try p.feed(&.{b}),
            else => {
                var rnd = mutator.Rnd.init(seed_sse +% mode *% 7919);
                try feedChunked(&p, &rnd, stream);
            },
        }
        var r = try p.finish();
        defer r.deinit(alloc);
        try std.testing.expectEqualStrings(want_content, r.content);
        try std.testing.expectEqualStrings(want_reasoning, r.reasoning);
    }
}

test "regression: hostile events stay inert" {
    var rnd = mutator.Rnd.init(seed_sse ^ 0xBAD);

    // Long-finish-reason and many-event cases are built at runtime (this
    // toolchain rejects whitespace around the comptime `**` operator).
    const alloc = std.testing.allocator;
    var long_reason: std.ArrayList(u8) = .empty;
    defer long_reason.deinit(alloc);
    try long_reason.appendSlice(alloc, "data: {\"finish_reason\":\"");
    try long_reason.appendNTimes(alloc, 'x', 64);
    try long_reason.appendSlice(alloc, "\",\"choices\":[]}");

    var many_events: std.ArrayList(u8) = .empty;
    defer many_events.deinit(alloc);
    const one =
        "data: {\"choices\":[{\"delta\":{\"content\":\"z\"}}]}\n";
    for (0..128) |_| try many_events.appendSlice(alloc, one);

    const hostiles = [_][]const u8{
        "",
        "\n\n\n",
        ": comment only",
        "event: ping\rdata: x\r\r",
        "data:",
        "data: [DONE]",
        "data: not json",
        "data: {}",
        "data: {\"choices\":[{}]}",
        "data: {\"choices\":[],\"x\":1}",
        "data: {\"choices\":[{\"delta\":{\"content\":\"unterminated\"}}",
        "data: {\"choices\":[{\"tool_calls\":[{\"index\":99999999,\"function\":{\"arguments\":\"x\"}}]}]}",
        "data: {\"choices\":[{\"tool_calls\":[{\"index\":7},{\"index\":8},{\"index\":9}]}]}",
        long_reason.items,
        many_events.items,
    };
    for (hostiles) |h| try runParser(&rnd, h, true);
    for (hostiles) |h| try runParser(&rnd, h, false);
}

test "regression: streamed tool-call args reassemble exactly across splits" {
    const alloc = std.testing.allocator;
    // Parser contract: tool-call arguments accumulate in RAW escaped form
    // (byte-identical to the non-streaming extractor).
    const want_args = "{\\\"command\\\":\\\"ls\\\"}";

    // Line assembled from plain literals (no fmt brace escaping to miscount):
    // outer{ choices:[ choice{ delta{ tool_calls:[ entry{ function{ args } } ] }, finish_reason } ] }
    const part1 =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c9\",\"function\":{\"name\":\"shell\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}\n";
    const prefix =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"";
    const suffix =
        "\"}}]},\"finish_reason\":null}]}\n";
    const args_line = try std.mem.concat(alloc, u8, &.{ prefix, want_args, suffix });
    defer alloc.free(args_line);
    const done_line = "data: [DONE]\n";
    const stream = try std.mem.concat(alloc, u8, &.{ part1, args_line, done_line });
    defer alloc.free(stream);

    var p = model.SseParser.init(alloc);
    defer p.deinit();
    try p.feed(stream);
    var resp = try p.finish();
    defer resp.deinit(alloc);
    try std.testing.expect(resp.has_tools);
    try std.testing.expectEqual(@as(usize, 1), resp.tool_calls.len);
    try std.testing.expectEqualStrings("c9", resp.tool_calls[0].id);
    try std.testing.expectEqualStrings("shell", resp.tool_calls[0].name);
    try std.testing.expectEqualStrings(want_args, resp.tool_calls[0].arguments);
}
