//! Shared deterministic mutation engine for the zharness fuzz suites
//! (SWARM wave-4, agent J-fuzz).
//!
//! Design contract:
//! - DETERMINISTIC: every suite seeds its own xorshift64* generator with a
//!   fixed constant; identical code + corpus always produce identical cases.
//!   No wall clock, no OS entropy, no global state — `zig build test` stays
//!   reproducible and hermetic.
//! - HERMETIC: mutators only transform in-memory seed bytes into a caller-
//!   provided ArrayList. No filesystem, no network, no fuzzer toolchain.
//! - BOUNDED: every mutation respects `max_case_bytes`; repeat/nest counts
//!   are capped so a hostile case can never turn the suite itself into a
//!   hang or an OOM. The property under test is always "parser returns
//!   cleanly OR errors cleanly — never panic / leak / hang".
//!
//! Corpus format: seed documents separated by a line containing exactly
//! `%%%%`. Blank seeds are skipped. Files live in `corpus/` next to this
//! module and are embedded at compile time by each suite (`@embedFile`), so
//! no cwd assumptions anywhere.

const std = @import("std");

/// Hard upper bound for any single generated case (keeps suites fast and
/// allocation-friendly under std.testing.allocator).
pub const max_case_bytes: usize = 64 * 1024;

const seed_sep = "\n%%%%\n";

/// Allocation-free iterator over corpus seeds (skips blank entries).
pub const SeedIter = struct {
    inner: std.mem.SplitIterator(u8, .sequence),

    pub fn init(raw: []const u8) SeedIter {
        return .{ .inner = std.mem.splitSequence(u8, raw, seed_sep) };
    }

    pub fn next(self: *SeedIter) ?[]const u8 {
        while (self.inner.next()) |s| {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len == 0) continue;
            return s; // original slice; interior layout preserved
        }
        return null;
    }
};

/// Count non-empty seeds (suites use this to size iteration budgets).
pub fn countSeeds(raw: []const u8) usize {
    var it = SeedIter.init(raw);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

// ── deterministic PRNG ──────────────────────────────────────────────────────

/// xorshift64* — tiny, fast, fully reproducible across platforms.
pub const Rnd = struct {
    state: u64,

    pub fn init(seed: u64) Rnd {
        // Zero is a fixed point; mix to escape it.
        return .{ .state = if (seed == 0) 0x9E3779B97F4A7C15 else seed };
    }

    pub fn next(self: *Rnd) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    /// Uniform value in [0, bound). bound must be > 0.
    pub fn below(self: *Rnd, bound: usize) usize {
        return @intCast(self.next() % @as(u64, @intCast(bound)));
    }

    /// True with probability p percent.
    pub fn pct(self: *Rnd, p: u8) bool {
        return self.below(100) < p;
    }
};

// ── interesting bytes for substitutions ─────────────────────────────────────

const interesting = [_]u8{
    '"', '\\', '{', '}', '[', ']', ':', ',', '\n', '\r', '\t', 0x00, 0xFF, ' ', '-', 'e',
};

const unicode_junk = [_][]const u8{
    "\u{FFFD}", // replacement char
    "\xED\xA0\x80", // raw UTF-8-encoded surrogate half D800 (invalid)
    "\xF0\x9F\x98\x80", // emoji (valid 4-byte)
    "\xC3\xA9", // é
    "\\uD83D\\uDE00", // escaped surrogate pair
    "\\uD800", // lone high surrogate escape
    "\\uZZZZ", // malformed hex escape
    "\\u00", // truncated escape
    "\\/",
    "\x01\x02\x7f", // control chars
    "caf\xc3\xa9 \xe4\xbd\xa0\xe5\xa5\xbd", // multibyte words
};

/// Mutator limits — deliberately small so mutated cases exercise parser edge
/// paths without stressing runtime or memory.
pub const Limits = struct {
    pub const max_repeat: usize = 256; // huge-count injection cap
    pub const max_nest: usize = 512; // deep-nesting injection cap
    pub const max_dup_bytes: usize = 256; // chunk-duplication cap
    pub const max_insert_reps: usize = 64; // unicode-junk repetition cap
};

pub const Mutation = enum {
    bit_flip,
    substitute,
    truncate,
    delete_chunk,
    duplicate_chunk,
    insert_unicode,
    insert_deep_nest,
    repeat_pattern,
    append_separator,

    pub const all = [_]Mutation{
        .bit_flip,
        .substitute,
        .truncate,
        .delete_chunk,
        .duplicate_chunk,
        .insert_unicode,
        .insert_deep_nest,
        .repeat_pattern,
        .append_separator,
    };
};

fn appendDeepNest(alloc: std.mem.Allocator, out: *std.ArrayList(u8), rnd: *Rnd) !void {
    const open = if (rnd.pct(50)) "{" else "[";
    const close = if (open[0] == '{') "}" else "]";
    const depth = 1 + rnd.below(Limits.max_nest);
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(alloc, open);
    try out.appendSlice(alloc, "\"d\"");
    i = 0;
    while (i < depth) : (i += 1) try out.appendSlice(alloc, close);
}

/// Produce one mutated variant of `seed` by applying 1–3 random mutations.
/// Output replaces the previous contents of `out` (caller reuses the list).
/// Respects `max_case_bytes`; later mutations are skipped when the budget is
/// exhausted (the result is still a valid case).
pub fn mutate(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rnd: *Rnd,
    seed: []const u8,
) !void {
    out.clearRetainingCapacity();
    const n_mutations = 1 + rnd.below(3);

    try out.appendSlice(alloc, seed[0..@min(seed.len, max_case_bytes)]);
    var remaining_budget: usize = max_case_bytes -| @min(seed.len, max_case_bytes);

    var m: usize = 0;
    while (m < n_mutations) : (m += 1) {
        const kind = Mutation.all[rnd.below(Mutation.all.len)];
        switch (kind) {
            .bit_flip => {
                if (out.items.len == 0) continue;
                const idx = rnd.below(out.items.len);
                const bit: u3 = @intCast(rnd.below(8));
                out.items[idx] ^= @as(u8, 1) << bit;
            },
            .substitute => {
                if (out.items.len == 0) continue;
                const idx = rnd.below(out.items.len);
                out.items[idx] = interesting[rnd.below(interesting.len)];
            },
            .truncate => {
                if (out.items.len == 0) continue;
                out.shrinkRetainingCapacity(rnd.below(out.items.len + 1));
            },
            .delete_chunk => {
                if (out.items.len < 2) continue;
                const start = rnd.below(out.items.len);
                const len = 1 + rnd.below(@min(out.items.len - start, Limits.max_dup_bytes));
                const tail = out.items[start + len ..];
                std.mem.copyForwards(u8, out.items[start .. start + tail.len], tail);
                out.shrinkRetainingCapacity(out.items.len - len);
            },
            .duplicate_chunk => {
                if (out.items.len == 0) continue;
                const start = rnd.below(out.items.len);
                const len = 1 + rnd.below(@min(out.items.len - start, Limits.max_dup_bytes));
                if (len >= remaining_budget) continue;
                const chunk = try alloc.dupe(u8, out.items[start .. start + len]);
                defer alloc.free(chunk);
                const at = rnd.below(out.items.len + 1);
                try out.insertSlice(alloc, at, chunk);
                remaining_budget -= len;
            },
            .insert_unicode => {
                const piece = unicode_junk[rnd.below(unicode_junk.len)];
                const reps = 1 + rnd.below(Limits.max_insert_reps);
                const total = piece.len * reps;
                if (total >= remaining_budget or total > 1024) continue;
                var buf: [1024]u8 = undefined;
                var n: usize = 0;
                var r: usize = 0;
                while (r < reps and n + piece.len <= buf.len) : (r += 1) {
                    @memcpy(buf[n .. n + piece.len], piece);
                    n += piece.len;
                }
                const at = rnd.below(out.items.len + 1);
                try out.insertSlice(alloc, at, buf[0..n]);
                remaining_budget -= total;
            },
            .insert_deep_nest => {
                var tmp: std.ArrayList(u8) = .empty;
                defer tmp.deinit(alloc);
                try appendDeepNest(alloc, &tmp, rnd);
                if (tmp.items.len >= remaining_budget) continue;
                const at = rnd.below(out.items.len + 1);
                try out.insertSlice(alloc, at, tmp.items);
                remaining_budget -= tmp.items.len;
            },
            .repeat_pattern => {
                const pat_len = 1 + rnd.below(8);
                var pat: [8]u8 = undefined;
                for (pat[0..pat_len]) |*b| b.* = interesting[rnd.below(interesting.len)];
                const reps = 2 + rnd.below(Limits.max_repeat);
                const total = pat_len * reps;
                if (total >= remaining_budget) continue;
                var r: usize = 0;
                while (r < reps) : (r += 1) try out.appendSlice(alloc, pat[0..pat_len]);
                remaining_budget -= total;
            },
            .append_separator => {
                const seps = [_][]const u8{ ",", ":", "\"x\":", "{}", "[]", "\\\"", "\n", "\r\n" };
                const s = seps[rnd.below(seps.len)];
                if (s.len >= remaining_budget) continue;
                try out.appendSlice(alloc, s);
                remaining_budget -= s.len;
            },
        }
    }
}

test "rnd deterministic across instances" {
    var a = Rnd.init(42);
    var b = Rnd.init(42);
    for (0..64) |_| {
        try std.testing.expectEqual(a.next(), b.next());
    }
    var c = Rnd.init(43);
    var differs = false;
    for (0..8) |_| {
        if (a.next() != c.next()) differs = true;
    }
    try std.testing.expect(differs);
}

test "mutate output bounded and varies" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = Rnd.init(7);
    var saw_diff = false;
    for (0..32) |_| {
        try mutate(alloc, &out, &rnd, "{\"a\":[1,2,3]}");
        try std.testing.expect(out.items.len <= max_case_bytes);
        if (!std.mem.eql(u8, out.items, "{\"a\":[1,2,3]}")) saw_diff = true;
    }
    try std.testing.expect(saw_diff);
}

test "seed iter skips blanks" {
    const raw = "\nalpha\n%%%%\n\n%%%% beta2 %%%%\n%%%%\n   \n%%%%\nlast";
    var it = SeedIter.init(raw);
    try std.testing.expectEqualStrings("\nalpha", it.next().?);
    const second = it.next().?;
    try std.testing.expect(std.mem.indexOf(u8, second, "beta2") != null);
    try std.testing.expectEqualStrings("last", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "countSeeds ignores empty documents" {
    try std.testing.expectEqual(@as(usize, 2), countSeeds("one\n%%%%\n\n%%%%\ntwo\n"));
    // Blank/whitespace-only seeds are not counted.
    try std.testing.expectEqual(@as(usize, 0), countSeeds(" \n%%%%\n\t\n%%%%\n  \n"));
}
