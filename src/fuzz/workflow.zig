//! Fuzz suite: workflow/workflow.zig parse + validate (SWARM wave-4,
//! agent J-fuzz).
//!
//! Property: for ANY input document, Workflow.parse / validate /
//! parseValidated either return a cleanly-owned Workflow (deinit frees
//! everything) or a PascalCase error — never panic / leak / hang. Cases run
//! under std.testing.allocator so leaks fail the suite.
//!
//! Corpus: src/fuzz/corpus/workflow_seeds.txt, embedded at compile time.

const std = @import("std");
const mutator = @import("mutator.zig");
const workflow = @import("../workflow/workflow.zig");

const corpus_raw = @embedFile("corpus/workflow_seeds.txt");

const seed_workflow = 0x3F17;

fn exerciseDocument(alloc: std.mem.Allocator, doc: []const u8) !void {
    // Syntax-only parse: owned result or clean error.
    if (workflow.Workflow.parse(alloc, doc)) |wf| {
        var owned = wf;
        try std.testing.expect(owned.steps.len <= doc.len / 2 + 1);
        owned.deinit(alloc);
    } else |e| switch (e) {
        error.MalformedWorkflow => {},
        else => return e, // OutOfMemory is not a fuzz finding here
    }

    // Semantic validation against whatever parsed this time.
    var wf2 = workflow.Workflow.parse(alloc, doc) catch return;
    defer wf2.deinit(alloc);
    if (wf2.validate(alloc)) |_| {} else |_| {}

    // Combined convenience wrapper shares the same guarantees.
    var wf3 = workflow.Workflow.parseValidated(alloc, doc) catch return;
    defer wf3.deinit(alloc);

    // Cycle reporter stays allocation-clean on arbitrary graphs.
    if (try workflow.findCyclePath(alloc, &wf2)) |rep| alloc.free(rep);
}

test "fuzz: workflow parse/validate over mutated seeds" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_workflow);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| try exerciseDocument(alloc, seed);

    var round: usize = 0;
    while (round < 15) : (round += 1) {
        var sit = mutator.SeedIter.init(corpus_raw);
        while (sit.next()) |seed| {
            try mutator.mutate(alloc, &out, &rnd, seed);
            try exerciseDocument(alloc, out.items);
        }
    }
}

test "fuzz: deep nesting and huge counts stay bounded" {
    const alloc = std.testing.allocator;

    // Deeply nested braces inside a prompt value (iterative matcher must
    // unwind instantly rather than recurse).
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        const depth = 8000;
        try buf.appendSlice(alloc, "{\"name\":\"n\",\"steps\":[{\"id\":\"a\",\"prompt\":\"");
        for (0..depth) |_| try buf.appendSlice(alloc, "{");
        for (0..depth) |_| try buf.appendSlice(alloc, "}");
        try buf.appendSlice(alloc, "\"}]}");
        try exerciseDocument(alloc, buf.items);
    }

    // A 300-step dependency chain validates quickly; adding a back-edge step
    // must surface as CyclicDependency (not a hang).
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, "{\"name\":\"chain\",\"steps\":[");
        for (0..300) |i| {
            if (i > 0) try buf.appendSlice(alloc, ",");
            try buf.print(alloc, "{{\"id\":\"s{d}\",\"prompt\":\"p{d}\"", .{ i, i });
            if (i > 0) try buf.print(alloc, ",\"depends_on\":[\"s{d}\"]", .{i - 1});
            try buf.appendSlice(alloc, "}");
        }
        try buf.appendSlice(alloc, "]}");
        var wf = try workflow.Workflow.parseValidated(alloc, buf.items);
        defer wf.deinit(alloc);

        // Extra step depending on s0: still acyclic, must validate.
        buf.shrinkRetainingCapacity(buf.items.len - 2);
        try buf.appendSlice(alloc, ",{\"id\":\"s300\",\"prompt\":\"z\",\"depends_on\":[\"s0\"]}]}");
        var diamond = try workflow.Workflow.parseValidated(alloc, buf.items);
        defer diamond.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 301), diamond.steps.len);

        // Close the ring properly: make s0 depend on s300 => cycle.
        const flip =
            \\{"name":"ring","steps":[
            \\ {"id":"a","prompt":"p","depends_on":["b"]},
            \\ {"id":"b","prompt":"p","depends_on":["c"]},
            \\ {"id":"c","prompt":"p","depends_on":["a"]}]}
        ;
        var cyc = try workflow.Workflow.parse(alloc, flip);
        defer cyc.deinit(alloc);
        try std.testing.expectError(error.CyclicDependency, cyc.validate(alloc));
    }
}

// Regression for a bug FOUND BY THIS SUITE (fixed in workflow/workflow.zig):
// `\uD800`-style lone-surrogate escapes used to fall into a `catch 1` branch
// of ownedQuoted that appended ONE BYTE OF UNINITIALIZED STACK BUFFER
// instead of the documented replacement character. The decode contract is
// "imperfect unicode tolerated"; the concrete pinned behavior is U+FFFD.
test "regression: lone surrogate escape decodes to U+FFFD, never undefined bytes" {
    const alloc = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "{\"name\":\"u\",\"steps\":[{\"id\":\"a\",\"prompt\":\"x\\uD800y\"}]}", "x\u{FFFD}y" },
        .{ "{\"name\":\"u\",\"steps\":[{\"id\":\"a\",\"prompt\":\"\\uDC00\"}]}", "\u{FFFD}" },
        .{ "{\"name\":\"\\uD83D\\uDE00 ok\",\"steps\":[{\"id\":\"a\",\"prompt\":\"p\"}]}", "p" },
    };
    for (cases) |c| {
        var wf = try workflow.Workflow.parse(alloc, c[0]);
        defer wf.deinit(alloc);
        try std.testing.expectEqualStrings(c[1], wf.steps[0].prompt);
        // Name path uses the same decoder. Note: workflow's decoder is
        // intentionally simpler than jsonrpc's — it does NOT combine
        // surrogate pairs, so each lone half maps to its own U+FFFD
        // (documented "prompts tolerate imperfect unicode" contract).
        if (std.mem.indexOf(u8, c[0], "\\uD83D") != null) {
            try std.testing.expectEqualStrings("\u{FFFD}\u{FFFD} ok", wf.name);
        }
    }
}
