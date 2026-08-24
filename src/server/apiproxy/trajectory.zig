//! Trajectory aggregate — the server-side "alternate views of agent
//! activity" subset for ui-trajectory (contract truth:
//! `_ref/deepseek-harness/packages/client/ui-trajectory/src/client/
//! {trajectory-contract.ts,trajectory-snapshot-builder.ts}`).
//!
//! ── RECON VERDICT (read upstream first) ────────────────────────────────────
//!
//! The upstream Trajectory view is a CLIENT-SIDE fold: every conversation
//! event (assistant requests, tool blocks, compactions, turn endings) feeds
//! TrajectorySnapshotBuilder, which assembles RequestViews (turn/step,
//! status, startSeq/completedAt, prompt config) and renders the stage table.
//! There is NO trajectory RPC method and NO trajectory frame family — the
//! data channel is the ordinary session log. A faithful replay therefore
//! needs, per request: seq, wall times, prompt snapshot, token usage, and
//! per-step durations.
//!
//! zharness stores none of those: transcripts (.zharness/sessions/<id>.json)
//! carry role/content/tool_calls only, and obs envelopes (main.zig obsEmit)
//! embed just `{"detail":"…"}` — no timings, no token counts.
//!
//! HONEST SUBSET implemented here: a deterministic turn/step aggregation of
//! the transcript (the same rows TrajectoryTable shows: prompts, assistant
//! output, tool calls with names), exposed via the zharness-only unary
//! method `zharness.trajectory.get`. Documented GAPS vs upstream:
//!   - no per-request durations / startSeq-completedAt (not stored),
//!   - no token usage or model config snapshots (not stored),
//!   - no compaction requests (no compaction capability).
//! The vendored GUI never calls this method; it keeps building its own
//! snapshot from session events, which remain the contract surface.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const router = @import("router.zig");
const sessions = @import("sessions.zig");

/// Preview cap in bytes (byte-safe: backs off to a UTF-8 boundary).
pub const preview_max_bytes = 160;

/// One aggregated row inside a turn. kind mirrors what the trajectory table
/// renders per stage; previews are single-line truncated content.
pub const TrajStep = struct {
    kind: Kind,
    preview: []const u8,
    /// Tool name for .tool_call rows; null otherwise.
    tool_name: ?[]const u8 = null,

    pub const Kind = enum { prompt, assistant, tool_call, tool_result };
};

pub const TrajTurn = struct {
    turn: usize,
    steps: []TrajStep,
};

fn truncatePreview(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    // Collapse newlines so rows stay one line like the upstream table cells.
    var flat: std.ArrayList(u8) = .empty;
    errdefer flat.deinit(alloc);
    for (text) |c| try flat.append(alloc, if (c == '\n' or c == '\r' or c == '\t') ' ' else c);

    if (flat.items.len <= preview_max_bytes) return flat.toOwnedSlice(alloc);
    var end: usize = preview_max_bytes;
    // Do not split a multi-byte UTF-8 sequence.
    while (end > 0 and (flat.items[end] & 0xC0) == 0x80) end -= 1;
    flat.shrinkRetainingCapacity(end);
    return flat.toOwnedSlice(alloc);
}

/// One tool-call slot name out of a serialized call object: top-level
/// "name" (the zharness store shape, cf. session.zig's save format)
/// preferred, nested {"function":{"name":…}} fallback.
fn slotName(alloc: std.mem.Allocator, obj: []const u8) ![]const u8 {
    if (jsonx.getStringAlloc(alloc, obj, "name") catch null) |n| {
        if (n.len > 0) return n;
        alloc.free(n);
    }
    if (jsonx.getRaw(obj, "function")) |f| {
        if (jsonx.getStringAlloc(alloc, f, "name") catch null) |n| {
            if (n.len > 0) return n;
            alloc.free(n);
        }
    }
    return try alloc.dupe(u8, "unknown");
}

/// Append one tool_call step per call slot in a serialized tool_calls array.
/// Own object scan (both the zharness flat shape and OpenAI's nested form).
fn appendToolCalls(
    alloc: std.mem.Allocator,
    steps: *std.ArrayList(TrajStep),
    arr_raw: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, arr_raw, " \t\r\n");
    if (trimmed.len == 0) return;

    // Collect object spans first (array of slots or one bare object).
    var spans: std.ArrayList([]const u8) = .empty;
    defer spans.deinit(alloc);
    if (trimmed[0] == '{') {
        try spans.append(alloc, trimmed);
    } else if (trimmed[0] == '[') {
        var i: usize = 1;
        while (i < trimmed.len) : (i += 1) {
            if (trimmed[i] == '{') {
                const end = jsonx.matchBraceFrom(trimmed, i) orelse break;
                try spans.append(alloc, trimmed[i..end]);
                i = end - 1;
            }
        }
    } else return;

    for (spans.items) |obj| {
        const name = try slotName(alloc, obj);
        errdefer alloc.free(name);
        try steps.append(alloc, .{
            .kind = .tool_call,
            // GAP: argument previews are not surfaced v1.
            .preview = try alloc.dupe(u8, ""),
            .tool_name = name,
        });
    }
}

/// Aggregate a decoded transcript into turns. Turn numbers increment at each
/// user message (an upgrade over sessions.zig's turn=1 history simplification,
/// which stays there for wire compat). Caller owns everything (arena use is
/// expected); frees with freeTurns.
pub fn buildTurns(alloc: std.mem.Allocator, msgs: []const sessions.MsgRec) ![]TrajTurn {
    var turns: std.ArrayList(TrajTurn) = .empty;
    var cur_steps: std.ArrayList(TrajStep) = .empty;
    errdefer {
        for (turns.items) |*t| freeSteps(alloc, t.steps);
        turns.deinit(alloc);
        freeSteps(alloc, cur_steps.items);
        cur_steps.deinit(alloc);
    }

    var cur_turn: usize = 0;

    for (msgs) |*m| {
        const is_tool_result = m.role.len == 4 and std.mem.eql(u8, m.role, "tool");
        const is_user_prompt = m.role.len == 4 and std.mem.eql(u8, m.role, "user") and !is_tool_result;

        if (m.role.len == 6 and std.mem.eql(u8, m.role, "system")) continue; // no chat surface

        if (is_user_prompt) {
            // Close the previous turn (if any) and open a new one.
            if (cur_steps.items.len > 0 or cur_turn > 0) {
                try turns.append(alloc, .{ .turn = cur_turn, .steps = try cur_steps.toOwnedSlice(alloc) });
                cur_steps = .empty;
            }
            cur_turn += 1;
            try cur_steps.append(alloc, .{
                .kind = .prompt,
                .preview = try truncatePreview(alloc, m.content),
            });
            continue;
        }

        if (std.mem.eql(u8, m.role, "assistant")) {
            if (m.tool_calls_json) |tc| try appendToolCalls(alloc, &cur_steps, tc);
            if (m.content.len > 0) {
                try cur_steps.append(alloc, .{
                    .kind = .assistant,
                    .preview = try truncatePreview(alloc, m.content),
                });
            }
            continue;
        }

        if (is_tool_result) {
            try cur_steps.append(alloc, .{
                .kind = .tool_result,
                .preview = try truncatePreview(alloc, m.content),
            });
        }
        // Unknown roles degrade visibly by being skipped (same posture as the
        // sessions adapter's system skip).
    }
    if (cur_steps.items.len > 0 or (cur_turn > 0 and turns.items.len > 0)) {
        try turns.append(alloc, .{ .turn = cur_turn, .steps = try cur_steps.toOwnedSlice(alloc) });
    } else {
        cur_steps.deinit(alloc);
    }
    return turns.toOwnedSlice(alloc);
}

fn freeSteps(alloc: std.mem.Allocator, steps: []TrajStep) void {
    for (steps) |s| {
        alloc.free(s.preview);
        if (s.tool_name) |n| alloc.free(n);
    }
    alloc.free(steps);
}

/// Free what buildTurns returned.
pub fn freeTurns(alloc: std.mem.Allocator, turns: []TrajTurn) void {
    for (turns) |*t| freeSteps(alloc, t.steps);
    alloc.free(turns);
}

/// Build the aggregate VALUE JSON:
///
///   {"turns":[{"turn":1,"steps":[{"kind":"prompt","preview":"…"},
///     {"kind":"tool_call","preview":"","toolName":"shell"}, …]}, …],
///    "totals":{"turns":2,"steps":7,"toolCalls":3}}
pub fn trajectoryValue(alloc: std.mem.Allocator, msgs: []const sessions.MsgRec) ![]u8 {
    const turns = try buildTurns(alloc, msgs);
    defer freeTurns(alloc, turns);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"turns\":[");

    var total_steps: usize = 0;
    var total_tools: usize = 0;
    for (turns, 0..) |*t, ti| {
        if (ti > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"turn\":");
        try jsonx.appendInt(alloc, &out, @intCast(t.turn));
        try out.appendSlice(alloc, ",\"steps\":[");
        for (t.steps, 0..) |*s, si| {
            if (si > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"kind\":");
            try jsonx.appendJsonString(alloc, &out, @tagName(s.kind));
            try out.appendSlice(alloc, ",\"preview\":");
            try jsonx.appendJsonString(alloc, &out, s.preview);
            if (s.tool_name) |n| {
                try out.appendSlice(alloc, ",\"toolName\":");
                try jsonx.appendJsonString(alloc, &out, n);
            }
            try out.append(alloc, '}');
            total_steps += 1;
            if (s.kind == .tool_call) total_tools += 1;
        }
        try out.appendSlice(alloc, "]}");
    }
    try out.appendSlice(alloc, "],\"totals\":{\"turns\":");
    try jsonx.appendInt(alloc, &out, @intCast(turns.len));
    try out.appendSlice(alloc, ",\"steps\":");
    try jsonx.appendInt(alloc, &out, @intCast(total_steps));
    try out.appendSlice(alloc, ",\"toolCalls\":");
    try jsonx.appendInt(alloc, &out, @intCast(total_tools));
    try out.appendSlice(alloc, "}}");
    return out.toOwnedSlice(alloc);
}

// ── optional unary handler (zharness extension `zharness.trajectory.get`) ──

pub const GetError = error{ SessionNotFound, OutOfMemory };

/// Handler body behind `zharness.trajectory.get` ({sessionId}). G1 wires:
///   if (std.mem.eql(u8, m, "zharness.trajectory.get"))
///       return run(alloc, env, trajectory.handleGet(deps, alloc, env.rpc_id, p));
/// where handleGet parses sessionId, loads the transcript, and renders the
/// value below router.okValue. Missing session → error.SessionNotFound (the
/// router maps it onto the closed code union).
pub fn valueForSession(
    deps_cwd: []const u8,
    io: std.Io,
    alloc: std.mem.Allocator,
    session_id: []const u8,
) GetError![]u8 {
    const path = sessions.transcriptPath(alloc, deps_cwd, session_id) catch return error.OutOfMemory;
    defer alloc.free(path);
    const msgs = sessions.loadTranscript(io, alloc, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SessionNotFound,
    };
    defer freeMsgs(alloc, msgs);
    return trajectoryValue(alloc, msgs) catch return error.OutOfMemory;
}

/// Free a parseTranscript result (all four optional/required string fields
/// are arena-or-testing-allocator owned copies).
fn freeMsgs(alloc: std.mem.Allocator, msgs: []sessions.MsgRec) void {
    for (msgs) |m| {
        alloc.free(m.role);
        alloc.free(m.content);
        if (m.tool_call_id) |v| alloc.free(v);
        if (m.tool_calls_json) |v| alloc.free(v);
    }
    alloc.free(msgs);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "buildTurns groups by user message and labels tool calls" {
    const alloc = testing.allocator;
    const transcript =
        \\[{"role":"user","content":"list files\nplease"},
        \\{"role":"assistant","content":"Calling shell.","tool_calls_json":"[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}]"},
        \\{"role":"tool","tool_call_id":"c1","content":"a.txt"},
        \\{"role":"assistant","content":"Done."},
        \\{"role":"user","content":"thanks"},
        \\{"role":"assistant","content":""},
        \\{"role":"system","content":"invisible"}]
    ;
    const msgs = try sessions.parseTranscript(alloc, transcript);
    defer freeMsgs(alloc, msgs);

    const turns = try buildTurns(alloc, msgs);
    defer freeTurns(alloc, turns);

    try testing.expectEqual(@as(usize, 2), turns.len);
    // Turn 1 (tool calls precede the assistant text, matching the history
    // adapter's ordering): prompt + tool_call(shell) + assistant note +
    // tool_result + final assistant.
    try testing.expectEqual(@as(usize, 5), turns[0].steps.len);
    try testing.expectEqual(TrajStep.Kind.prompt, turns[0].steps[0].kind);
    try testing.expectEqualStrings("list files please", turns[0].steps[0].preview);
    try testing.expectEqual(TrajStep.Kind.tool_call, turns[0].steps[1].kind);
    try testing.expectEqualStrings("shell", turns[0].steps[1].tool_name.?);
    try testing.expectEqual(TrajStep.Kind.assistant, turns[0].steps[2].kind);
    try testing.expectEqual(TrajStep.Kind.tool_result, turns[0].steps[3].kind);
    // Turn 2: user thanks; empty assistant contributes nothing.
    try testing.expectEqual(@as(usize, 1), turns[1].steps.len);

    const value = try trajectoryValue(alloc, msgs);
    defer alloc.free(value);
    try testing.expect(std.mem.indexOf(u8, value, "\"toolName\":\"shell\"") != null);
    try testing.expect(std.mem.indexOf(u8, value, "\"totals\":{\"turns\":2,\"steps\":6,\"toolCalls\":1}") != null);
}

test "truncatePreview collapses whitespace and respects utf-8 boundaries" {
    const alloc = testing.allocator;
    const short = try truncatePreview(alloc, "a\nb\tc");
    defer alloc.free(short);
    try testing.expectEqualStrings("a b c", short);

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(alloc);
    try big.appendNTimes(alloc, 'é', preview_max_bytes); // é is 2 bytes each
    const cut = try truncatePreview(alloc, big.items);
    defer alloc.free(cut);
    try testing.expect(cut.len <= preview_max_bytes);
    try testing.expect((cut[cut.len - 1] & 0xC0) != 0x80); // ends on a boundary
}
