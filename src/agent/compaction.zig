//! Context compaction — truncation-based window shrinking for long agent
//! conversations (dev.md context-management slot; wave 7 A-advanced).
//!
//! Contract: when the accumulated conversation content crosses a character
//! budget (`shouldCompact`), `compact` replaces every message OLDER than the
//! most recent `keep_recent` messages with ONE synthetic user message:
//!
//!     "[Context compacted: N messages summarized. Key topics: <t1> | <t2> ...]"
//!
//! where each topic is the first `topic_char_cap` (50) characters of a
//! summarized user prompt (trimmed). This is deliberately dumb truncation —
//! NO LLM summarization pass — so it is deterministic, offline, and free.
//! The `keep_recent` tail stays byte-for-byte verbatim so open tool-call /
//! tool-result pairs are never broken mid-pair.
//!
//! Shape: `CompactedMessage` IS `model.Message` (same fields, same ownership
//! rules). Returned slices own deep copies of `content`, `tool_call_id`, and
//! `tool_calls_json`; `images` stays a borrowed slice reference exactly like
//! `model.Message` documents. Free everything with `freeCompacted`.
//!
//! Decoupling: pure functions over plain `model.Message` values — no agent,
//! cordis, or provider imports beyond the message IR.

const std = @import("std");
const model = @import("../model/model.zig");

/// Same shape as model.Message (alias — single source of truth for the IR).
pub const CompactedMessage = model.Message;

/// Characters retained per summarized user prompt in the Key topics list.
pub const topic_char_cap: usize = 50;

/// True when the conversation should be compacted before the next model turn.
/// Convention: compaction fires at `total >= threshold` (the budget is an
/// upper bound on tolerated context size, so reaching it triggers).
pub fn shouldCompact(total_content_chars: usize, threshold: usize) bool {
    return total_content_chars >= threshold;
}

/// Sum of `content` lengths across the conversation — the cheap proxy the
/// caller feeds into `shouldCompact` (images/tool_calls JSON excluded by
/// design; they ride provider-side limits separately).
pub fn totalContentChars(messages: []const model.Message) usize {
    var sum: usize = 0;
    for (messages) |m| sum += m.content.len;
    return sum;
}

/// Compact `messages`: older messages become one summary user message, the
/// newest `keep_recent` stay verbatim. When `keep_recent >= messages.len`
/// nothing is summarized — a full deep copy is returned so callers always
/// own the result uniformly.
///
/// Errors: OutOfMemory only.
pub fn compact(
    alloc: std.mem.Allocator,
    messages: []const model.Message,
    keep_recent: usize,
) ![]CompactedMessage {
    var out: std.ArrayList(CompactedMessage) = .empty;
    errdefer {
        for (out.items) |*m| freeDuped(alloc, m);
        out.deinit(alloc);
    }

    const summarize_count = if (keep_recent >= messages.len) 0 else messages.len - keep_recent;

    if (summarize_count > 0) {
        const summary = try buildSummary(alloc, messages[0..summarize_count]);
        errdefer alloc.free(summary);
        try out.append(alloc, .{ .role = .user, .content = summary });
    }

    for (messages[summarize_count..]) |m| {
        try out.append(alloc, try dupeMessage(alloc, m));
    }
    return out.toOwnedSlice(alloc);
}

/// Free a slice returned by `compact` (all strings it owns).
pub fn freeCompacted(alloc: std.mem.Allocator, msgs: []CompactedMessage) void {
    for (msgs) |*m| freeDuped(alloc, m);
    alloc.free(msgs);
}

/// In-place transcript compaction for a live message list (the agent loop).
///
/// When `threshold` is non-zero and `totalContentChars(list.items)` reaches it,
/// the list is replaced by `compact`'s output: older messages collapse into one
/// synthetic summary, the newest `keep_recent` stay verbatim, and the old
/// elements are freed. Returns true iff compaction ran.
///
/// Best-effort by design: on OOM the list is left untouched and false is
/// returned, so a compaction failure can never break an agent turn.
pub fn compactList(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(model.Message),
    threshold: usize,
    keep_recent: usize,
) bool {
    if (threshold == 0) return false;
    if (!shouldCompact(totalContentChars(list.items), threshold)) return false;

    const compacted = compact(alloc, list.items, keep_recent) catch return false;

    // Free the old elements; keep the list capacity for the append below.
    for (list.items) |*m| freeDuped(alloc, m);
    list.clearRetainingCapacity();

    list.appendSlice(alloc, compacted) catch {
        freeCompacted(alloc, compacted);
        return false;
    };
    alloc.free(compacted);
    return true;
}

// ── internals ────────────────────────────────────────────────────────────────

/// "[Context compacted: N messages summarized. Key topics: a… | b…]"
/// Topics are the first 50 chars of each summarized USER prompt; when the
/// summarized range holds no non-empty user prompt the topic list reads
/// "none". Always produces an owned, NUL-free UTF-8-safe slice.
fn buildSummary(alloc: std.mem.Allocator, summarized: []const model.Message) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var nbuf: [32]u8 = undefined;
    const nstr = std.fmt.bufPrint(&nbuf, "{d}", .{summarized.len}) catch unreachable;

    try out.appendSlice(alloc, "[Context compacted: ");
    try out.appendSlice(alloc, nstr);
    try out.appendSlice(alloc, " messages summarized. Key topics:");

    var topics: usize = 0;
    for (summarized) |m| {
        if (m.role != .user) continue;
        const t = topicOf(m.content);
        if (t.len == 0) continue;
        try out.appendSlice(alloc, if (topics == 0) " " else " | ");
        try out.appendSlice(alloc, t);
        topics += 1;
    }
    if (topics == 0) try out.appendSlice(alloc, " none");
    try out.appendSlice(alloc, "]");
    return out.toOwnedSlice(alloc);
}

/// First `topic_char_cap` bytes of the trimmed content, cut on a UTF-8
/// sequence boundary so multibyte prompts are never sliced mid-codepoint.
fn topicOf(content: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len <= topic_char_cap) return trimmed;
    var end: usize = topic_char_cap;
    while (end > 0 and (trimmed[end] & 0xC0) == 0x80) : (end -= 1) {}
    return trimmed[0..end];
}

fn dupeMessage(alloc: std.mem.Allocator, m: model.Message) !CompactedMessage {
    return .{
        .role = m.role,
        .content = try alloc.dupe(u8, m.content),
        .tool_call_id = if (m.tool_call_id) |v| try alloc.dupe(u8, v) else null,
        .tool_calls_json = if (m.tool_calls_json) |v| try alloc.dupe(u8, v) else null,
        // Borrowed reference, matching model.Message image ownership rules.
        .images = m.images,
    };
}

fn freeDuped(alloc: std.mem.Allocator, m: *const CompactedMessage) void {
    alloc.free(m.content);
    if (m.tool_call_id) |v| alloc.free(v);
    if (m.tool_calls_json) |v| alloc.free(v);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "shouldCompact fires at and above threshold only" {
    try testing.expect(!shouldCompact(0, 100));
    try testing.expect(!shouldCompact(99, 100));
    try testing.expect(shouldCompact(100, 100));
    try testing.expect(shouldCompact(1000, 100));
}

test "compact keeps recent tail verbatim and summarizes older messages" {
    const alloc = testing.allocator;
    const msgs = [_]model.Message{
        .{ .role = .system, .content = "you are helpful" },
        .{ .role = .user, .content = "first question about zig allocators" },
        .{ .role = .assistant, .content = "answer one" },
        .{ .role = .user, .content = "second question about wasm sandboxes" },
        .{ .role = .assistant, .content = "answer two", .tool_calls_json = "[{\"id\":\"t1\"}]" },
        .{ .role = .user, .content = "third question about http servers" },
        .{ .role = .assistant, .content = "final answer" },
    };

    const out = try compact(alloc, &msgs, 2);
    defer freeCompacted(alloc, out);

    try testing.expectEqual(@as(usize, 3), out.len);
    // Summary replaces the five older messages; topics come from the two
    // summarized user prompts only (the third user prompt stays verbatim).
    try testing.expectEqual(model.Role.user, out[0].role);
    try testing.expectEqualStrings(
        "[Context compacted: 5 messages summarized. Key topics: first question about zig allocators | second question about wasm sandboxes]",
        out[0].content,
    );
    // Tail stays verbatim; the summarized tool metadata does not survive.
    try testing.expectEqualStrings("third question about http servers", out[1].content);
    try testing.expectEqualStrings("final answer", out[2].content);
    try testing.expect(out[2].tool_calls_json == null);
}

test "compact truncates topics at 50 chars on utf8 boundary" {
    const alloc = testing.allocator;
    // 60 'a's built at runtime (no `**` repeat needed).
    var long_buf: [60]u8 = undefined;
    @memset(&long_buf, 'a');
    var prefix_buf: [53]u8 = undefined; // 50 a's + " | " for the expectation
    @memset(prefix_buf[0..50], 'a');
    @memcpy(prefix_buf[50..], " | ");

    const multibyte = "héllo wörld — ünicode prompt that is definitely longer than fifty bytes total!!";
    const msgs = [_]model.Message{
        .{ .role = .user, .content = &long_buf },
        .{ .role = .assistant, .content = "ok" },
        .{ .role = .user, .content = multibyte },
        .{ .role = .assistant, .content = "ok2" },
        .{ .role = .user, .content = "recent" },
    };
    const out = try compact(alloc, &msgs, 1);
    defer freeCompacted(alloc, out);

    try testing.expect(std.mem.indexOf(u8, out[0].content, &prefix_buf) != null);
    // The multibyte topic decodes cleanly after boundary-safe truncation.
    if (std.mem.indexOf(u8, out[0].content, "héllo")) |idx| {
        const topic_start = idx;
        var end = topic_start;
        while (end < out[0].content.len and out[0].content[end] != '|' and out[0].content[end] != ']') : (end += 1) {}
        const topic = std.mem.trim(u8, out[0].content[topic_start..end], " ");
        try testing.expect(std.unicode.utf8ValidateSlice(topic));
        try testing.expect(topic.len <= topic_char_cap); // boundary-safe cut never exceeds the cap
    } else return error.TestUnexpectedResult;
}

test "compact with no user prompts reports none and empty range is a full copy" {
    const alloc = testing.allocator;
    const assistant_only = [_]model.Message{
        .{ .role = .assistant, .content = "one" },
        .{ .role = .tool, .content = "result", .tool_call_id = "tc-9" },
    };
    {
        const out = try compact(alloc, &assistant_only, 1);
        defer freeCompacted(alloc, out);
        try testing.expectEqualStrings(
            "[Context compacted: 1 messages summarized. Key topics: none]",
            out[0].content,
        );
        try testing.expectEqualStrings("result", out[1].content);
        try testing.expectEqualStrings("tc-9", out[1].tool_call_id.?);
    }
    // keep_recent >= len → nothing summarized, everything copied.
    {
        const out = try compact(alloc, &assistant_only, 5);
        defer freeCompacted(alloc, out);
        try testing.expectEqual(@as(usize, 2), out.len);
        try testing.expectEqualStrings("one", out[0].content);
        try testing.expect(out[0].content.ptr != assistant_only[0].content.ptr);
    }
    // keep_recent == 0 → single summary message only.
    {
        const out = try compact(alloc, &assistant_only, 0);
        defer freeCompacted(alloc, out);
        try testing.expectEqual(@as(usize, 1), out.len);
    }
}

test "totalContentChars sums contents" {
    const msgs = [_]model.Message{
        .{ .role = .system, .content = "12345" }, // 5
        .{ .role = .user, .content = "abc" }, // 3
        .{ .role = .assistant, .content = "" },
    };
    try testing.expectEqual(@as(usize, 8), totalContentChars(&msgs));
}

test "compactList rewrites an over-budget transcript in place" {
    const alloc = testing.allocator;
    var list: std.ArrayList(model.Message) = .empty;
    defer {
        for (list.items) |*m| freeDuped(alloc, m);
        list.deinit(alloc);
    }

    var big: [100]u8 = undefined;
    @memset(&big, 'x');
    for (0..3) |_| {
        try list.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, &big) });
        try list.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "ok") });
    }
    // Content total: 3*100 + 3*2 = 306.

    // threshold 0 disables compaction; below budget is a no-op.
    try testing.expect(!compactList(alloc, &list, 0, 2));
    try testing.expect(!compactList(alloc, &list, 1_000, 2));
    try testing.expectEqual(@as(usize, 6), list.items.len);

    // At budget with a 2-message tail, the 4 older messages collapse into one.
    try testing.expect(compactList(alloc, &list, 300, 2));
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqual(model.Role.user, list.items[0].role);
    try testing.expect(std.mem.startsWith(u8, list.items[0].content, "[Context compacted: 4 messages summarized."));
    try testing.expectEqualStrings("ok", list.items[2].content);

    // Now well under budget: idempotent no-op.
    try testing.expect(!compactList(alloc, &list, 1_000, 2));
}
