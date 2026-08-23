//! Fuzz suite: model/model.zig hand-rolled JSON helpers (SWARM wave-4,
//! agent J-fuzz).
//!
//! Surfaces (all pub, allocation-light):
//! - findMatchingBrace / findMatchingBracket: total functions over arbitrary
//!   bytes. Property: result is null OR an index in (start, len] pointing
//!   just past the matching closer; never out-of-bounds, never a panic.
//! - escape / unescape round-trip: for ANY input bytes,
//!   unescape(escape(x)) == x byte-for-byte.
//! - isErrorEnvelope / errorMessage / extractStringField against malformed
//!   provider bodies: boolean verdicts and owned-or-null strings only.
//!
//! Corpus: src/fuzz/corpus/json_seeds.txt, embedded at compile time.

const std = @import("std");
const mutator = @import("mutator.zig");
const model = @import("../model/model.zig");

const corpus_raw = @embedFile("corpus/json_seeds.txt");

const seed_json = 0x0550;

/// Brace/bracket matcher bounds property over arbitrary bytes at every
/// plausible start position (bounded sample for long inputs).
fn checkMatchers(doc: []const u8) !void {
    var i: usize = 0;
    while (i < doc.len) : (i += 1) {
        if (doc[i] != '{' and doc[i] != '[') continue;
        const open = doc[i];
        const r = if (open == '{')
            model.findMatchingBrace(doc, i)
        else
            model.findMatchingBracket(doc, i);
        try std.testing.expect(r == null or (r.? > i and r.? <= doc.len));
        // A reported match must end just past the corresponding closer.
        if (r) |end| {
            try std.testing.expect(end >= 1);
            const closer: u8 = if (open == '{') '}' else ']';
            try std.testing.expectEqual(closer, doc[end - 1]);
        }
        // Sample stride on very long docs keeps the O(n^2) sweep bounded.
        if (doc.len > 4096) i += 64;
    }
    // Out-of-range starts are clean nulls, never UB.
    try std.testing.expect(model.findMatchingBrace(doc, doc.len + 7) == null);
    try std.testing.expect(model.findMatchingBracket(doc, doc.len + 7) == null);
}

test "fuzz: matchers over mutated seeds" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_json);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| {
        try checkMatchers(seed);
        try mutator.mutate(alloc, &out, &rnd, seed);
        try checkMatchers(out.items);
    }

    // Pathological nesting depth stays iterative and instant.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(alloc);
    for (0..10_000) |_| try deep.appendSlice(alloc, "{\"a\":");
    try deep.appendSlice(alloc, "1");
    for (0..10_000) |_| try deep.appendSlice(alloc, "}");
    try checkMatchers(deep.items);

    // Unterminated escapes inside strings must not run off the buffer.
    try checkMatchers("{\"k\":\"tail\\");
    try checkMatchers("[\"a\\\",\"b\"]");
}

test "property: unescape inverts escape for arbitrary bytes" {
    const alloc = std.testing.allocator;
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_json ^ 0xABCD);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| {
        var round: usize = 0;
        while (round < 20) : (round += 1) {
            try mutator.mutate(alloc, &out, &rnd, seed);
            escaped.clearRetainingCapacity();
            try model.escape(alloc, out.items, &escaped);
            const back = try model.unescape(alloc, escaped.items);
            defer alloc.free(back);
            try std.testing.expectEqualSlices(u8, out.items, back);
        }
    }

    // Fixed adversarial bytes incl. NULs and 0xFF.
    const nasty = "\x00\x01\"\\ \n\r\t\xff\xfe end\\";
    escaped.clearRetainingCapacity();
    try model.escape(alloc, nasty, &escaped);
    const back2 = try model.unescape(alloc, escaped.items);
    defer alloc.free(back2);
    try std.testing.expectEqualSlices(u8, nasty, back2);
}

test "fuzz: error-envelope classification over mutated bodies" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_json ^ 0xE001);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| {
        var round: usize = 0;
        while (round < 12) : (round += 1) {
            try mutator.mutate(alloc, &out, &rnd, seed);
            const body = out.items;
            _ = model.isErrorEnvelope(body); // total: any bool is fine

            // errorMessage / extractStringField return owned-or-null only.
            if (model.errorMessage(alloc, body)) |m| alloc.free(m);
            if (try model.extractStringField(alloc, body, "message")) |m| alloc.free(m);
            _ = model.extractField(body, "message");
            _ = model.extractNestedField(body, "error", "message");
            checkMatchers(body) catch return error.TestUnexpectedResult;
        }
    }
}

test "regression: envelope verdicts stay precise under mutation pressure" {
    // Pinned semantics from model.zig's own tests, re-checked against a few
    // mutation-adjacent shapes so future edits cannot quietly regress them.
    try std.testing.expect(model.isErrorEnvelope("{\"error\":{\"message\":\"m\"}}"));
    try std.testing.expect(!model.isErrorEnvelope("{ \"x\": \"e\", \"error\": 1 }")); // not first field
    try std.testing.expect(model.isErrorEnvelope("  \t\r\n{\"error\":{}}")); // leading ws tolerated
    try std.testing.expect(!model.isErrorEnvelope("{\"err\\u006fr\":{\"message\":\"m\"}}")); // key must be exact
    try std.testing.expect(!model.isErrorEnvelope(""));
}
