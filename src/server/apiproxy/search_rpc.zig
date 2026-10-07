//! session.search DATA layer — greps zharness `.zharness/sessions/<id>.json`
//! transcripts for one case-insensitive substring query (wave-6 task spec;
//! wire truth `_ref/deepseek-harness/packages/host/apiproxy/src/api/
//! {sessions.schema.ts,session-search.ts}` + ui-sidebar's Search affordance).
//!
//! The ROUTER already owns the envelope: router.zig dispatches
//! `session.search` through `ApiProxyDeps.searchSessions` and renders
//! `{items:[{sessionId,snippet}],hasMore}` (router.SearchItem/SearchPage).
//! This module provides that dep implementation plus its config singleton.
//!
//! ── CONTRACT (upstream sessionSearchRequestSchema/ValueSchema) ────────────
//!   request  {query}            1..500 chars after trim, no NUL
//!   response {items:[{sessionId,snippet}], hasMore}
//!     - items: at most SESSION_SEARCH_RESULT_LIMIT = 20 sessions
//!     - snippet: plain text, at most 240 Unicode code points
//!   Upstream ranks by "strongest matching visible message"; v1 scores by
//!   TOTAL match count across user+assistant message contents (the upstream
//!   "user/assistant/steering message surface"; tool results are excluded to
//!   match upstream's searchable surface — documented deviation candidate).
//!   Snippet: ±60 chars around the FIRST match of the best message window,
//!   match wrapped in «guillemets», cut back to whole UTF-8 scalars.
//!
//! ── INTEGRATOR WIRING (one-time, serve startup) ───────────────────────────
//!   const apiproxy = @import("server/apiproxy/router.zig");
//!   const search_rpc = @import("server/apiproxy/search_rpc.zig");
//!   _ = try search_rpc.installDefault(cfg.cwd);          // idempotent
//!   deps.searchSessions = search_rpc.searchSessionsFn;    // ctx stays null
//! Until installDefault runs, deps.searchSessions stays null and the router
//! answers "not implemented" exactly as today.
//!
//! Threading: scans are stateless reads over the transcript dir; the only
//! shared state is the immutable Config singleton. Requires httpd Options
//! .threaded_connections = true like every route in this server.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const router = @import("router.zig");
const sessions = @import("sessions.zig");
const clib = @import("../../clib.zig");

/// Upstream SESSION_SEARCH_RESULT_LIMIT.
pub const result_limit: usize = 20;
/// Upstream SESSION_SEARCH_SNIPPET_MAX_CODE_POINTS.
pub const snippet_max_code_points: usize = 240;
/// Upstream SESSION_SEARCH_QUERY_MAX_CHARS.
pub const query_max_chars: usize = 500;
/// Snippet context radius around the first match (chars ≈ bytes pre-boundary-fix).
const snippet_radius: usize = 60;

// ── config singleton (router.installDefaultSettings pattern) ────────────────

pub const Config = struct {
    /// Server cwd; transcripts live under `<cwd>/.zharness/sessions`.
    cwd: []u8,
    io: std.Io,
    threaded: *std.Io.Threaded,
};

var g_config: ?*Config = null;

/// Create the process-wide search config rooted at `cwd`. Idempotent;
/// returns the existing config on re-entry. Process-lifetime singleton on
/// the C allocator (it outlives any request arena and must never leak into
/// one). There is no deinit by design, matching settings.zig's Store.
pub fn installDefault(cwd: []const u8) !*Config {
    if (g_config) |c| return c;
    const c = try std.heap.c_allocator.create(Config);
    errdefer std.heap.c_allocator.destroy(c);
    const threaded = try std.heap.c_allocator.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(std.heap.c_allocator, .{});
    errdefer std.heap.c_allocator.destroy(threaded);
    c.* = .{
        .cwd = try std.heap.c_allocator.dupe(u8, cwd),
        .io = threaded.io(),
        .threaded = threaded,
    };
    g_config = c;
    return c;
}

/// Test/integrator hook: detach the current singleton (caller frees nothing;
/// process-lifetime by design).
pub fn takeConfig() ?*Config {
    const c = g_config;
    g_config = null;
    return c;
}

// ── scoring + snippets ──────────────────────────────────────────────────────

/// Total number of case-insensitive occurrences of `needle` in `haystack`.
pub fn countMatchesCI(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var rest = haystack;
    while (std.ascii.findIgnoreCase(rest, needle)) |at| {
        count += 1;
        rest = rest[at + needle.len ..];
    }
    return count;
}

/// Back `i` to the start of the UTF-8 scalar containing byte `i`.
fn scalarStart(s: []const u8, i: usize) usize {
    var start = @min(i, s.len);
    while (start > 0 and (s[start] & 0xC0) == 0x80) start -= 1;
    return start;
}

/// Advance past continuation bytes so `i` starts a fresh scalar.
fn scalarEnd(s: []const u8, i: usize) usize {
    var end = @min(i, s.len);
    while (end < s.len and (s[end] & 0xC0) == 0x80) end += 1;
    return end;
}

/// Count Unicode code points.
fn codePointCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += l;
        n += 1;
    }
    return n;
}

/// Longest prefix containing at most `max` code points (upstream
/// truncateUnicodeCodePoints).
pub fn truncateCodePoints(alloc: std.mem.Allocator, value: []const u8, max: usize) ![]const u8 {
    if (codePointCount(value) <= max) return alloc.dupe(u8, value);
    var i: usize = 0;
    var n: usize = 0;
    while (n < max) : (n += 1) {
        i += std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
    }
    return alloc.dupe(u8, value[0..i]);
}

/// Build the display snippet for `content`: ±60 chars around the FIRST
/// case-insensitive occurrence of `needle`, the match wrapped in «…»,
/// scalar-aligned on both sides, capped at 240 code points. Null when the
/// content carries no match (callers pick their own empty-window policy).
pub fn buildSnippet(alloc: std.mem.Allocator, content: []const u8, needle: []const u8) !?[]const u8 {
    const mi = std.ascii.findIgnoreCase(content, needle) orelse return null;
    const m_end = @min(mi + needle.len, content.len);
    const win_start = scalarStart(content, mi -| snippet_radius);
    const win_end = scalarEnd(content, m_end +| snippet_radius);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, content[win_start..mi]);
    try out.appendSlice(alloc, "\u{00AB}"); // «
    try out.appendSlice(alloc, content[mi..m_end]);
    try out.appendSlice(alloc, "\u{00BB}"); // »
    try out.appendSlice(alloc, content[m_end..win_end]);

    if (codePointCount(out.items) <= snippet_max_code_points)
        return try out.toOwnedSlice(alloc);

    // Oversized marked window (huge needle): fall back to a plain
    // code-point-capped window without markers.
    out.deinit(alloc);
    const plain_start = scalarStart(content, mi -| snippet_radius);
    return @as(?[]const u8, try truncateCodePoints(alloc, content[plain_start..], snippet_max_code_points));
}

// ── scanning ────────────────────────────────────────────────────────────────

pub const Hit = struct {
    session_id: []const u8,
    snippet: []const u8,
    score: usize,
    updated_at_ms: i64,
};

fn lessHit(_: void, a: Hit, b: Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.updated_at_ms != b.updated_at_ms) return a.updated_at_ms > b.updated_at_ms;
    return std.mem.lessThan(u8, a.session_id, b.session_id);
}

/// Score one decoded transcript: total matches over user+assistant contents.
/// Returns the score and (when > 0) the first matching message's content.
fn scoreTranscript(msgs: []const sessions.MsgRec, needle: []const u8) struct { score: usize, first_match: ?[]const u8 } {
    var score: usize = 0;
    var first: ?[]const u8 = null;
    for (msgs) |m| {
        const searchable = std.mem.eql(u8, m.role, "user") or std.mem.eql(u8, m.role, "assistant");
        if (!searchable) continue;
        const n = countMatchesCI(m.content, needle);
        if (n == 0) continue;
        score += n;
        if (first == null) first = m.content;
    }
    return .{ .score = score, .first_match = first };
}

/// Scan every `*.json` transcript under `dir_path`. Sorted hits: score desc,
/// then updatedAt desc, then sessionId asc (deterministic order). A missing
/// directory yields zero hits (fresh workspace), mirroring sessions.zig IO
/// conventions. All returned slices are allocated with `alloc`.
pub fn scanTranscripts(
    io: std.Io,
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    query: []const u8,
) !struct { hits: []Hit, has_more: bool } {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(alloc);

    const ids = try sessions.listSessionIds(io, alloc, dir_path);
    defer alloc.free(ids);
    for (ids) |id| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir_path, id });
        defer alloc.free(path);
        const msgs = sessions.loadTranscript(io, alloc, path) catch continue;
        defer {
            for (msgs) |m| {
                alloc.free(m.role);
                alloc.free(m.content);
                if (m.tool_call_id) |v| alloc.free(v);
                if (m.tool_calls_json) |v| alloc.free(v);
            }
            alloc.free(msgs);
        }

        const st = scoreTranscript(msgs, query);
        if (st.score == 0) continue;
        const snippet: []const u8 = if (try buildSnippet(alloc, st.first_match.?, query)) |s| s else try alloc.dupe(u8, "");
        try hits.append(alloc, .{
            .session_id = id, // borrowed from ids (owned above)
            .snippet = snippet,
            .score = st.score,
            .updated_at_ms = sessions.mtimeMs(io, path),
        });
    }

    std.mem.sort(Hit, hits.items, {}, lessHit);
    const has_more = hits.items.len > result_limit;
    return .{
        .hits = try hits.toOwnedSlice(alloc),
        .has_more = has_more,
    };
}

// ── deps surface (SearchSessionsFn-shaped) ──────────────────────────────────

/// Validate the upstream zod refinements: trim, min 1, max 500 chars, no NUL.
fn validatedQuery(alloc: std.mem.Allocator, raw: []const u8) error{ PayloadInvalid, OutOfMemory }![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.PayloadInvalid;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.PayloadInvalid;
    if (codePointCount(trimmed) > query_max_chars) return error.PayloadInvalid;
    return alloc.dupe(u8, trimmed);
}

/// ApiProxyDeps.searchSessions implementation (`router.SearchSessionsFn`
/// shape; ctx ignored — the Config singleton carries the cwd). Errors map
/// through router.run(): PayloadInvalid → bad-request (the upstream zod
/// rejections), anything else → internal.
pub fn searchSessionsFn(ctx: ?*anyopaque, alloc: std.mem.Allocator, query: []const u8) anyerror!router.SearchPage {
    _ = ctx;
    // Query validation runs BEFORE the config probe so bad requests render
    // bad-request even on an unwired host (upstream zod validates first).
    const q = try validatedQuery(alloc, query);
    alloc.free(q);
    const cfg = g_config orelse return error.SessionSearchUnavailable;
    return searchIn(cfg.io, alloc, cfg.cwd, query);
}

/// Dep-free scan of the cwd transcripts. Used by the model-facing
/// session_search tool and by searchSessionsFn (which supplies the config
/// singleton io and cwd).
pub fn searchIn(io: std.Io, alloc: std.mem.Allocator, cwd: []const u8, query: []const u8) !router.SearchPage {
    const q = try validatedQuery(alloc, query);
    defer alloc.free(q);
    const dir = try sessions.transcriptDir(alloc, cwd);
    defer alloc.free(dir);
    const res = try scanTranscripts(io, alloc, dir, q);
    defer alloc.free(res.hits);

    const take = @min(res.hits.len, result_limit);
    const items = try alloc.alloc(router.SearchItem, take);
    // Transfer ownership of the kept hits strings into items; release the
    // rest so the hits slice itself can be freed.
    for (res.hits, 0..) |h, i| {
        if (i < take) {
            items[i] = .{ .session_id = h.session_id, .snippet = h.snippet };
        } else {
            alloc.free(h.session_id);
            alloc.free(h.snippet);
        }
    }
    return .{ .items = items, .has_more = res.has_more };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "countMatchesCI counts overlapping-free occurrences" {
    try testing.expectEqual(@as(usize, 0), countMatchesCI("hello world", "xyz"));
    try testing.expectEqual(@as(usize, 3), countMatchesCI("Ab ab aB", "ab"));
    try testing.expectEqual(@as(usize, 0), countMatchesCI("anything", ""));
}

test "buildSnippet marks the match inside a bounded window" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = "prefix padding padding padding NEEDLE and some trailing context here";
    const snip = (try buildSnippet(alloc, content, "needle")).?;
    try testing.expect(std.mem.indexOf(u8, snip, "\u{00AB}NEEDLE\u{00BB}") != null);
    try testing.expect(codePointCount(snip) <= snippet_max_code_points);

    // No match → null.
    try testing.expect((try buildSnippet(alloc, content, "zzz")) == null);
}

test "buildSnippet stays scalar-aligned on multibyte content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // é is 2 bytes; pad so the ±60 window lands mid-sequence.
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    for (0..80) |_| try content.appendSlice(alloc, "é");
    try content.appendSlice(alloc, "target");
    for (0..80) |_| try content.appendSlice(alloc, "é");
    const snip = (try buildSnippet(alloc, content.items, "target")).?;
    try testing.expect(std.unicode.utf8ValidateSlice(snip));
}

test "truncateCodePoints caps multibyte text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const five_e = "ééééé";
    try testing.expectEqualStrings(five_e, try truncateCodePoints(alloc, five_e, 5));
    try testing.expectEqualStrings("ééé", try truncateCodePoints(alloc, five_e, 3));
    try testing.expectEqualStrings("", try truncateCodePoints(alloc, five_e, 0));
}

fn writeFixture(io: std.Io, alloc: std.mem.Allocator, dir_abs: []const u8, id: []const u8, body: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir_abs, id });
    defer alloc.free(path);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = body });
}

test "scanTranscripts scores, sorts, limits, and reports hasMore" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Unique absolute scratch dir under the system temp.
    var name_buf: [64]u8 = undefined;
    const uniq = clib.nowTimestamp();
    const dir_abs = try std.fmt.bufPrint(&name_buf, "/tmp/zh_g2_search_{d}", .{uniq});
    const threaded = try alloc.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(alloc, .{});
    const io = threaded.io();
    try std.Io.Dir.createDirPath(.cwd(), io, dir_abs);
    defer {
        // Best-effort cleanup of the whole tree (while `io` is still live).
        if (std.Io.Dir.openDir(.cwd(), io, "/tmp", .{})) |tmp_dir_res| {
            var tmp_dir = tmp_dir_res;
            defer std.Io.Dir.close(tmp_dir, io);
            tmp_dir.deleteTree(io, std.fs.path.basename(dir_abs)) catch {};
        } else |_| {}
        threaded.deinit();
        alloc.destroy(threaded);
    }

    // aaa: 2 matches; bbb: 3 matches (tool role excluded from scoring);
    // ccc: 0 → absent. Distinct scores keep the order mtime-independent.
    try writeFixture(io, alloc, dir_abs, "aaa", "[{\"role\":\"user\",\"content\":\"please fix the login bug\"},{\"role\":\"assistant\",\"content\":\"the login bug is fixed\"}]");
    try writeFixture(io, alloc, dir_abs, "bbb", "[{\"role\":\"user\",\"content\":\"login\"},{\"role\":\"assistant\",\"content\":\"login again\"},{\"role\":\"assistant\",\"content\":\"login once more\"},{\"role\":\"tool\",\"content\":\"login tool noise must NOT score\"}]");
    try writeFixture(io, alloc, dir_abs, "ccc", "[{\"role\":\"user\",\"content\":\"unrelated topic\"}]");

    const res = try scanTranscripts(io, alloc, dir_abs, "LOGIN");
    try testing.expectEqual(@as(usize, 2), res.hits.len);
    try testing.expect(!res.has_more);

    try testing.expectEqualStrings("bbb", res.hits[0].session_id);
    try testing.expectEqual(@as(usize, 3), res.hits[0].score);
    try testing.expect(std.mem.indexOf(u8, res.hits[0].snippet, "\u{00AB}login\u{00BB}") != null);
    try testing.expectEqualStrings("aaa", res.hits[1].session_id);

    // No-match query across all fixtures.
    const none = try scanTranscripts(io, alloc, dir_abs, "quantumflux");
    try testing.expectEqual(@as(usize, 0), none.hits.len);

    // Missing directory degrades to zero hits.
    const empty = try scanTranscripts(io, alloc, "/tmp/zh_g2_missing_dir_zz", "x");
    try testing.expectEqual(@as(usize, 0), empty.hits.len);
}

test "searchSessionsFn validates the query refinements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Unwired singleton → internal-class error (integrator forgot install).
    _ = takeConfig();
    try testing.expectError(error.SessionSearchUnavailable, searchSessionsFn(null, a, "q"));

    const big = try a.alloc(u8, query_max_chars + 1);
    @memset(big, 'a');
    inline for (.{ "", "   ", "bad\x00nul" }) |q| {
        try testing.expectError(error.PayloadInvalid, searchSessionsFn(null, a, q));
    }
    try testing.expectError(error.PayloadInvalid, searchSessionsFn(null, a, big));
}
