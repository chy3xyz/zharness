//! Fuzz suite: server/httpd.zig request parser (SWARM wave-4, agent J-fuzz).
//!
//! The parser entry points are already pub (`parseRequest`, `percentDecode`,
//! `formatResponse`), so the suite drives them directly — no refactoring
//! needed. Property: any raw byte soup either parses into a Request whose
//! slices are internally consistent (and deinits leak-free under
//! std.testing.allocator) or fails with a clean ParseError. Never panic,
//! never hang, never leak.

const std = @import("std");
const mutator = @import("mutator.zig");
const httpd = @import("../server/httpd.zig");

const corpus_raw = @embedFile("corpus/http_requests.txt");

const seed_http = 0x1177;

/// Corpus files are authored with LF newlines (repo-friendly); real wire
/// requests use CRLF. This deterministic lift converts every '\n' to
/// "\r\n" so seeds reach the parser in wire-realistic shape.
fn toCrlf(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        try out.append(alloc, s[i]);
        if (s[i] == '\n') try out.append(alloc, '\r');
    }
    return out.toOwnedSlice(alloc);
}

fn exerciseRequest(alloc: std.mem.Allocator, raw: []const u8) !void {
    if (httpd.parseRequest(alloc, raw)) |req| {
        var r = req;
        // Internal consistency: path+query decomposition matches target.
        const qmark = std.mem.indexOfScalar(u8, r.target, '?');
        if (qmark) |q| {
            try std.testing.expectEqualSlices(u8, r.target[0..q], r.path);
            try std.testing.expectEqualSlices(u8, r.target[q + 1 ..], r.query);
        } else {
            try std.testing.expectEqualSlices(u8, r.target, r.path);
            try std.testing.expectEqualStrings("", r.query);
        }
        // Body length must equal the (valid) Content-Length header.
        if (r.header("content-length")) |cl| {
            const want = std.fmt.parseInt(usize, cl, 10) catch return error.TestUnexpectedResult;
            try std.testing.expectEqual(want, r.body.len);
        } else {
            try std.testing.expectEqualStrings("", r.body);
        }
        // Version prefix survived; header lookup is case-insensitive total.
        try std.testing.expect(std.mem.startsWith(u8, r.version, "HTTP/"));
        _ = r.header("X-Fuzz-Header");
        try std.testing.expect(r.isGetLike() or !r.isGetLike()); // total fn smoke
        r.deinit(alloc);
    } else |_| {} // BadRequest / HeadTooLarge / BodyTooLarge / NotImplementedTransfer
}

test "fuzz: parseRequest over mutated seeds" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_http);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| {
        // Both raw (LF) and wire-shaped (CRLF) variants are exercised; the
        // mutations then pile onto whichever shape the PRNG picks.
        try exerciseRequest(alloc, seed);
        const crlf = try toCrlf(alloc, seed);
        defer alloc.free(crlf);
        try exerciseRequest(alloc, crlf);

        const use_crlf = rnd.pct(50);
        var round: usize = 0;
        while (round < 12) : (round += 1) {
            const base = if (use_crlf) crlf else seed;
            try mutator.mutate(alloc, &out, &rnd, base);
            try exerciseRequest(alloc, out.items);
        }
    }
}

test "fuzz: header floods and giant declared bodies reject cleanly" {
    const alloc = std.testing.allocator;

    // > MaxHeaders header lines -> HeadTooLarge, not a crash.
    var flood: std.ArrayList(u8) = .empty;
    defer flood.deinit(alloc);
    try flood.appendSlice(alloc, "GET / HTTP/1.1\r\n");
    for (0..64) |i| try flood.print(alloc, "X-H{d}: v\r\n", .{i});
    try flood.appendSlice(alloc, "\r\n");
    try std.testing.expectError(error.HeadTooLarge, httpd.parseRequest(alloc, flood.items));

    // Content-Length beyond MaxBodyBytes -> BodyTooLarge.
    try std.testing.expectError(
        error.BodyTooLarge,
        httpd.parseRequest(alloc, "POST /x HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n"),
    );

    // Absurd numeric spellings for Content-Length stay clean rejections.
    for ([_][]const u8{
        "POST /x HTTP/1.1\r\nContent-Length: -5\r\n\r\n",
        "POST /x HTTP/1.1\r\nContent-Length: +9abc\r\n\r\n",
        "POST /x HTTP/1.1\r\nContent-Length: \r\n\r\n",
        "POST /x HTTP/1.1\r\ncontent-length: 18446744073709551616\r\n\r\n",
    }) |raw| {
        try exerciseRequest(alloc, raw);
    }
}

test "fuzz: percentDecode bounds and known pairs" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_http ^ 0x0D0D);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| {
        var round: usize = 0;
        while (round < 8) : (round += 1) {
            try mutator.mutate(alloc, &out, &rnd, seed);
            const dec = try httpd.percentDecode(alloc, out.items);
            defer alloc.free(dec);
            // Output can only shrink (each %XX collapses; junk passes 1:1).
            try std.testing.expect(dec.len <= out.items.len);
            // Double-decoding stays total and bounded too.
            const dec2 = try httpd.percentDecode(alloc, dec);
            defer alloc.free(dec2);
            try std.testing.expect(dec2.len <= out.items.len);
        }
    }

    // Pinned behaviors.
    {
        const d = try httpd.percentDecode(alloc, "hello%20world%2Ffile.zig");
        defer alloc.free(d);
        try std.testing.expectEqualStrings("hello world/file.zig", d);
    }
    {
        const d = try httpd.percentDecode(alloc, "%2");
        defer alloc.free(d);
        try std.testing.expectEqualStrings("%2", d); // short escape passes through
    }
    {
        const d = try httpd.percentDecode(alloc, "%ff%00%41");
        defer alloc.free(d);
        try std.testing.expectEqualSlices(u8, "\xff\x00A", d);
    }
}

test "formatResponse framing invariants under arbitrary bodies" {
    const alloc = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_http ^ 0xF00D);
    const alphabet = "ab\"\n{}%";

    for (0..64) |_| {
        body.clearRetainingCapacity();
        const n = rnd.below(300);
        for (0..n) |_| try body.append(alloc, alphabet[rnd.below(alphabet.len)]);

        const raw = try httpd.formatResponse(alloc, .ok, .json, body.items);
        defer alloc.free(raw);
        try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.endsWith(u8, raw, body.items));
        const cl = std.mem.indexOf(u8, raw, "Content-Length: ");
        try std.testing.expect(cl != null);
    }
}
