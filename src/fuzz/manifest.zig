//! Fuzz suite: pluginabi/loader.zig PURE manifest functions (SWARM wave-4,
//! agent J-fuzz). No dlopen anywhere — only parseManifest /
//! validateManifest / hostToolName / abiVersionOk.
//!
//! Property: for ANY manifest document, parseManifest yields an owned
//! Manifest (deinit frees all) or a clean ParseError; validateManifest then
//! yields a granular ValidateError or success; hostToolName always produces
//! [a-z0-9_] output for arbitrary inputs. Never panic / leak / hang.
//!
//! Corpus: src/fuzz/corpus/manifest_seeds.txt, embedded at compile time.

const std = @import("std");
const mutator = @import("mutator.zig");
const loader = @import("../pluginabi/loader.zig");
const capi = @import("../pluginabi/capi.zig");

const corpus_raw = @embedFile("corpus/manifest_seeds.txt");

const seed_manifest = 0x4A2B;

fn exerciseDocument(alloc: std.mem.Allocator, doc: []const u8) !void {
    if (loader.parseManifest(alloc, doc)) |m| {
        var owned = m;
        // Whatever parsed must free cleanly (the leak property).
        loader.validateManifest(&owned) catch {};
        owned.deinit();
    } else |_| {}
}

test "fuzz: parseManifest over mutated seeds" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_manifest);

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

// Regression for a bug FOUND BY THIS SUITE (fixed in pluginabi/loader.zig):
// MemberIter.nextMember recursed once per leading ',' inside an object. A
// hostile manifest containing a long comma run drove ~200k stack frames and
// crashed the process (SIGSEGV) instead of returning InvalidJson. The
// iterator now consumes separator runs iteratively.
test "regression: comma flood cannot recurse the stack" {
    const alloc = std.testing.allocator;
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(alloc);
    try doc.appendSlice(alloc, "{\"name\":\"p\",\"version\":\"1\",\"kind\":\"tool\",\"tools\":[],");
    for (0..200_000) |_| try doc.append(alloc, ',');
    try doc.appendSlice(alloc, "\"x\":1}");

    // Pre-fix this line died with a stack overflow; post-fix it is either
    // rejected or parsed — both fine.
    try exerciseDocument(alloc, doc.items);
}

test "hostToolName output alphabet bounded for adversarial input" {
    const alloc = std.testing.allocator;
    const names = [_][]const u8{
        "",
        "A",
        "..",
        "///..\\\\",
        "\x00\x01\xff\xfe",
        "Ünïcödé-plüg",
        "-",
        "x",
        "very_long_name_that_goes_on_and_on_and_on_and_on_forever_beyond_limits",
        "🚀",
    };
    for (names) |n| {
        const host = try loader.hostToolName(alloc, n, "T!o@o#l");
        defer alloc.free(host);
        try std.testing.expect(std.mem.startsWith(u8, host, "p_"));
        for (host) |c| {
            try std.testing.expect(c == '_' or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'));
        }
    }
}

test "abiVersionOk matches the compiled contract exactly" {
    try std.testing.expect(loader.abiVersionOk(capi.ABI_VERSION));
    try std.testing.expect(!loader.abiVersionOk(0));
    try std.testing.expect(!loader.abiVersionOk(capi.ABI_VERSION +% 1));
}
