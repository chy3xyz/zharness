//! Session store adapter — maps zharness `.zharness/sessions/<id>.json`
//! transcripts (session/session.zig save format) INTO the DSH apiproxy DTOs
//! (spec §4): session.list summaries and session.history event pages.
//!
//! Read-only over the store: nothing here writes transcripts. Pure builders
//! are separated from thin IO wrappers so both are testable.
//!
//! ── MAPPING (spec §3 SessionEventMap subset; history reconstruction) ──────
//!
//!   transcript message (role)      → history entry event
//!   ─────────────────────────────────────────────────────────────────────────
//!   user                           → user/message  {id,role,content:[text],
//!                                                    source:{kind:'user'}}
//!   assistant                      → assistant/message {turn,step,message:
//!                                                    {…,source:{kind:'model'}}}
//!   assistant + tool_calls_json    → one tool/call BEFORE the assistant
//!                                    message per call slot
//!                                    {turn,step,callId,name,arguments}
//!   tool (tool_call_id)            → tool/result wrapping a ToolResultMessage
//!                                    {message:{role:'user',content:[
//!                                     {type:'tool-result',toolCallId,
//!                                      content:[{type:'text',text}]}],
//!                                     source:{kind:'tool',callId}}}
//!   system                         → skipped (no chat-node surface)
//!
//! Documented v1 simplifications: turn=1 and step=seq+1 (the live streaming
//! bridge owns real turns); `time` is the file mtime for every event of that
//! transcript (transcripts carry no per-message clocks); ids are deterministic
//! "u<seq>"/"a<seq>"/"t<seq>" strings (stable across page refetches, which is
//! what the client needs). The tail-page `'title'` projection uses the caller-
//! supplied title (integrators pass the cwd basename or a stored title).
//!
//! All allocations go to the caller's allocator — in production the request
//! arena, freed wholesale when the connection ends.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const router = @import("router.zig");

// ── records ────────────────────────────────────────────────────────────────

/// One decoded transcript message (mirrors model.Message loosely; role stays
/// a raw string so unknown roles degrade visibly instead of crashing).
pub const MsgRec = struct {
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_calls_json: ?[]const u8 = null,
};

// ── IO wrappers ────────────────────────────────────────────────────────────

/// `<cwd>/.zharness/sessions` directory path.
pub fn transcriptDir(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/.zharness/sessions", .{cwd});
}

/// Path of one transcript file.
pub fn transcriptPath(alloc: std.mem.Allocator, cwd: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/.zharness/sessions/{s}.json", .{ cwd, id });
}

/// Load and decode a transcript. A missing file yields an empty slice (an
/// empty session), matching session.Session.load semantics. Malformed JSON
/// degrades to whatever prefix parses (per-object best effort).
pub fn loadTranscript(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]MsgRec {
    // Skip very large session files (>50MB) — parsing them would take too
    // long and the GUI can't render thousands of events meaningfully.
    const stat = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch {
        return error.FileNotFound;
    };
    if (stat.size > 50 * 1024 * 1024) return error.FileNotFound;
    const raw = std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return try alloc.alloc(MsgRec, 0),
        else => return e,
    };
    defer alloc.free(raw);
    return parseTranscript(alloc, raw);
}

/// Parse a serialized transcript array (pure half of loadTranscript).
pub fn parseTranscript(alloc: std.mem.Allocator, raw: []const u8) ![]MsgRec {
    var out: std.ArrayList(MsgRec) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '{') continue;
        const end = jsonx.matchBraceFrom(raw, i) orelse break;
        const obj = raw[i..end];
        i = end - 1;

        const role = blk: {
            const s = jsonx.getStringAlloc(alloc, obj, "role") catch null orelse
                break :blk try alloc.dupe(u8, "user");
            break :blk s;
        };
        const content = blk: {
            const s = jsonx.getStringAlloc(alloc, obj, "content") catch null orelse
                break :blk try alloc.dupe(u8, "");
            break :blk s;
        };
        const tool_call_id = try jsonx.getStringAlloc(alloc, obj, "tool_call_id");
        // getStringAlloc already decodes the JSON-string escapes once, which
        // restores the raw tool_calls JSON text exactly as session.Session
        // stored it (inner argument strings stay escaped — they are strings
        // INSIDE that JSON value).
        const tool_calls_json = try jsonx.getStringAlloc(alloc, obj, "tool_calls_json");

        try out.append(alloc, .{
            .role = role,
            .content = content,
            .tool_call_id = tool_call_id,
            .tool_calls_json = tool_calls_json,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// List session ids (*.json stems) under `dir_path`, sorted ascending for
/// determinism. Missing directory → empty list.
pub fn listSessionIds(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);

    const root = std.Io.Dir.cwd();
    const dir = std.Io.Dir.openDir(root, io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return try out.toOwnedSlice(alloc),
        else => return e,
    };
    defer std.Io.Dir.close(dir, io);

    var it = std.Io.Dir.iterate(dir);
    while (it.next(io) catch null) |entry| {
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        try out.append(alloc, try alloc.dupe(u8, name[0 .. name.len - ".json".len]));
    }
    std.mem.sort([]const u8, out.items, {}, lessStr);
    return out.toOwnedSlice(alloc);
}

/// File mtime in epoch milliseconds (0 when stat fails).
pub fn mtimeMs(io: std.Io, path: []const u8) i64 {
    const st = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch return 0;
    return @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
}

// ── pure builders ──────────────────────────────────────────────────────────

pub const SummaryOptions = struct {
    session_id: []const u8,
    updated_at_ms: i64,
    message_count: usize,
    cwd: ?[]const u8 = null,
};

/// Build ONE session.list item row from store facts. `running` is false (a
/// history-only adapter cannot know liveness; the turn runner flips it live
/// via host frames); `blank` = zero messages.
pub fn buildSummaryJson(alloc: std.mem.Allocator, opts: SummaryOptions) ![]u8 {
    const s = router.SessionSummary{
        .session_id = opts.session_id,
        .updated_at_ms = opts.updated_at_ms,
        .running = false,
        .blank = opts.message_count == 0,
        .cwd = opts.cwd,
        // Empty-log convention: asOfSeq -1 until events exist (§4).
        .projections_json = "{\"asOfSeq\":-1,\"values\":{}}",
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try router.appendSessionSummaryJson(alloc, &out, &s);
    return out.toOwnedSlice(alloc);
}

/// Strict SessionEvent envelope around pre-rendered data JSON.
fn appendEventEnvelope(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ev_type: []const u8,
    seq: usize,
    time_ms: i64,
    data_json: []const u8,
) !void {
    try out.appendSlice(alloc, "{\"type\":");
    try jsonx.appendJsonString(alloc, out, ev_type);
    try out.appendSlice(alloc, ",\"seq\":");
    try jsonx.appendInt(alloc, out, @intCast(seq));
    try out.appendSlice(alloc, ",\"time\":");
    try jsonx.appendInt(alloc, out, time_ms);
    try out.appendSlice(alloc, ",\"data\":");
    try out.appendSlice(alloc, data_json);
    try out.appendSlice(alloc, "}");
}

/// One tool-call slot extracted from stored tool_calls_json (accepts either
/// an array of slots or a single object — the store has seen both shapes).
/// All strings are allocated with `alloc`; release with `freeToolCallSlots`.
pub const ToolCallSlot = struct {
    id: []const u8,
    name: []const u8,
    /// Raw arguments JSON ('{}' when absent).
    arguments_json: []const u8,
};

pub fn parseToolCallSlots(alloc: std.mem.Allocator, tool_calls_json: []const u8) ![]ToolCallSlot {
    var out: std.ArrayList(ToolCallSlot) = .empty;
    errdefer out.deinit(alloc);

    const trimmed = std.mem.trim(u8, tool_calls_json, " \t\r\n");
    if (trimmed.len == 0) return out.toOwnedSlice(alloc);

    if (trimmed[0] != '[') {
        try appendSlot(alloc, &out, trimmed); // single-object shape
        return out.toOwnedSlice(alloc);
    }

    var i: usize = 1;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] == '{') {
            const end = jsonx.matchBraceFrom(trimmed, i) orelse break;
            try appendSlot(alloc, &out, trimmed[i..end]);
            i = end - 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn appendSlot(alloc: std.mem.Allocator, out: *std.ArrayList(ToolCallSlot), obj: []const u8) !void {
    // All three fields are heap-allocated with `alloc` (never static slices)
    // so freeToolCallSlots can release them uniformly.
    const id = (jsonx.getStringAlloc(alloc, obj, "id") catch null) orelse
        (jsonx.getStringAlloc(alloc, obj, "callId") catch null) orelse
        try alloc.dupe(u8, "");
    const name = (jsonx.getStringAlloc(alloc, obj, "name") catch null) orelse
        try alloc.dupe(u8, "");
    // Arguments may be stored as a nested object or as an escaped string.
    const args: []const u8 = blk: {
        if (jsonx.getRaw(obj, "arguments")) |raw| {
            if (jsonx.isString(raw)) {
                break :blk jsonx.decodeString(alloc, raw[1 .. raw.len - 1]) catch try alloc.dupe(u8, "{}");
            }
            break :blk try alloc.dupe(u8, raw);
        }
        break :blk try alloc.dupe(u8, "{}");
    };
    try out.append(alloc, .{ .id = id, .name = name, .arguments_json = args });
}

/// Release a parseToolCallSlots result (slices AND their contents).
pub fn freeToolCallSlots(alloc: std.mem.Allocator, slots: []ToolCallSlot) void {
    for (slots) |s| {
        alloc.free(s.id);
        alloc.free(s.name);
        alloc.free(s.arguments_json);
    }
    if (slots.len > 0) alloc.free(slots);
}

// ── history page builder ───────────────────────────────────────────────────

/// Build the session.history value pieces from a decoded transcript.
/// `max_messages` pages the TAIL (most recent messages); `has_more` reports
/// whether older messages exist beyond the page. Seq numbers index the FULL
/// transcript so tail pages stay consistent across refetches.
/// Replace control chars (< 0x20 except \n) with spaces and invalid UTF-8
/// continuation bytes with '?'. Returns the input unchanged if already clean.
fn sanitizeContent(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var needs_fix = false;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c < 0x20 and c != '\n') { needs_fix = true; break; }
        if (c >= 0x80 and c <= 0xBF) { needs_fix = true; break; } // orphan continuation
        if (c >= 0xF8) { needs_fix = true; break; }
        if (c >= 0xC0) {
            const len: usize = if (c >= 0xF0) 4 else if (c >= 0xE0) 3 else 2;
            var ok = i + len <= input.len;
            var j: usize = 1;
            while (j < len and ok) : (j += 1) {
                if (input[i + j] & 0xC0 != 0x80) ok = false;
            }
            if (!ok) { needs_fix = true; break; }
            i += len;
            continue;
        }
        i += 1;
    }
    if (!needs_fix) return input;
    var out = try alloc.alloc(u8, input.len);
    var oi: usize = 0;
    i = 0;
    while (i < input.len) {
        const c = input[i];
        if (c < 0x20 and c != '\n') {
            out[oi] = ' '; oi += 1; i += 1;
        } else if (c >= 0x80 and c <= 0xBF) {
            out[oi] = '?'; oi += 1; i += 1;
        } else if (c >= 0xF8) {
            out[oi] = '?'; oi += 1; i += 1;
        } else if (c >= 0xC0) {
            const len: usize = if (c >= 0xF0) 4 else if (c >= 0xE0) 3 else 2;
            if (i + len <= input.len) {
                @memcpy(out[oi..oi+len], input[i..i+len]);
                oi += len; i += len;
            } else {
                out[oi] = '?'; oi += 1; i += 1;
            }
        } else {
            out[oi] = c; oi += 1; i += 1;
        }
    }
    return out[0..oi];
}

pub fn buildHistoryPage(
    alloc: std.mem.Allocator,
    msgs: []const MsgRec,
    updated_at_ms: i64,
    max_messages: ?u32,
    title: []const u8,
) !router.HistoryPage {
    var start: usize = 0;
    var has_more = false;
    if (max_messages) |mm| {
        if (msgs.len > mm) {
            start = msgs.len - mm;
            has_more = true;
        }
    }

    var entries: std.ArrayList(router.HistoryEntry) = .empty;
    errdefer entries.deinit(alloc);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);

    for (msgs[start..], start..) |m, seq| {
        const safe_content = m.content;
        if (std.mem.eql(u8, m.role, "system")) continue; // no chat surface
        const step: usize = seq + 1;

        if (std.mem.eql(u8, m.role, "user")) {
            data.clearRetainingCapacity();
            try data.appendSlice(alloc, "{\"id\":\"u");
            try jsonx.appendInt(alloc, &data, @intCast(seq));
            try data.appendSlice(alloc, "\",\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
            try jsonx.appendJsonString(alloc, &data, safe_content);
            try data.appendSlice(alloc, "}],\"source\":{\"kind\":\"user\"}}");
            try pushEntry(alloc, &entries, "user/message", seq, updated_at_ms, data.items);
            continue;
        }

        if (std.mem.eql(u8, m.role, "assistant")) {
            // tool/call slots precede the finalized assistant message.
            if (m.tool_calls_json) |tcj| {
            const tcj_clean = sanitizeContent(alloc, tcj) catch tcj;
                const slots = try parseToolCallSlots(alloc, tcj_clean);
                defer freeToolCallSlots(alloc, slots);
                for (slots) |slot| {
                    data.clearRetainingCapacity();
                    try data.appendSlice(alloc, "{\"turn\":1,\"step\":");
                    try jsonx.appendInt(alloc, &data, @intCast(step));
                    try data.appendSlice(alloc, ",\"callId\":");
                    try jsonx.appendJsonString(alloc, &data, slot.id);
                    try data.appendSlice(alloc, ",\"name\":");
                    try jsonx.appendJsonString(alloc, &data, slot.name);
                    try data.appendSlice(alloc, ",\"arguments\":");
                    try data.appendSlice(alloc, slot.arguments_json);
                    try data.appendSlice(alloc, "}");
                    try pushEntry(alloc, &entries, "tool/call", seq, updated_at_ms, data.items);
                }
            }

            data.clearRetainingCapacity();
            try data.appendSlice(alloc, "{\"turn\":1,\"step\":");
            try jsonx.appendInt(alloc, &data, @intCast(step));
            try data.appendSlice(alloc, ",\"message\":{\"id\":\"a");
            try jsonx.appendInt(alloc, &data, @intCast(seq));
            try data.appendSlice(alloc, "\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":");
            try jsonx.appendJsonString(alloc, &data, safe_content);
            try data.appendSlice(alloc, "}],\"source\":{\"kind\":\"model\"}}}");
            try pushEntry(alloc, &entries, "assistant/message", seq, updated_at_ms, data.items);
            continue;
        }

        if (std.mem.eql(u8, m.role, "tool")) {
            const call_id = m.tool_call_id orelse "";
            data.clearRetainingCapacity();
            try data.appendSlice(alloc, "{\"turn\":1,\"step\":");
            try jsonx.appendInt(alloc, &data, @intCast(step));
            try data.appendSlice(alloc, ",\"message\":{\"id\":\"t");
            try jsonx.appendInt(alloc, &data, @intCast(seq));
            try data.appendSlice(alloc, "\",\"role\":\"user\",\"content\":[{\"type\":\"tool-result\",\"toolCallId\":");
            try jsonx.appendJsonString(alloc, &data, call_id);
            try data.appendSlice(alloc, ",\"content\":[{\"type\":\"text\",\"text\":");
            try jsonx.appendJsonString(alloc, &data, safe_content);
            try data.appendSlice(alloc, "]}],\"source\":{\"kind\":\"tool\",\"callId\":");
            try jsonx.appendJsonString(alloc, &data, call_id);
            try data.appendSlice(alloc, "}}}");
            try pushEntry(alloc, &entries, "tool/result", seq, updated_at_ms, data.items);
            continue;
        }
        // Unknown roles degrade silently (client folds unknown types onto its
        // documented fallback node).
    }

    // Projections block (title only), safe on any page for this adapter.
    var proj: std.ArrayList(u8) = .empty;
    errdefer proj.deinit(alloc);
    const last_seq: i64 = if (msgs.len == 0) -1 else @intCast(msgs.len - 1);
    try proj.appendSlice(alloc, "{\"asOfSeq\":");
    try jsonx.appendInt(alloc, &proj, last_seq);
    try proj.appendSlice(alloc, ",\"values\":{\"title\":");
    // Friendly title: first user message's first line, truncated to 40 chars.
    // Falls back to the session_id if no user message exists.
    var friendly_title: ?[]const u8 = null;
    for (msgs) |m| {
        if (std.mem.eql(u8, m.role, "user") and m.content.len > 0) {
            const first_line_end = std.mem.indexOfScalar(u8, m.content, '\n') orelse m.content.len;
            const line = std.mem.trim(u8, m.content[0..first_line_end], " \t\r");
            if (line.len > 0) {
                const trunc_len = @min(line.len, 40);
                friendly_title = try alloc.dupe(u8, line[0..trunc_len]);
                break;
            }
        }
    }
    if (friendly_title) |ft| {
        try jsonx.appendJsonString(alloc, &proj, ft);
    } else {
        try jsonx.appendJsonString(alloc, &proj, title);
    }
    try proj.appendSlice(alloc, "}}");

    const result = try entries.toOwnedSlice(alloc);
    // Drop events containing NUL bytes (indicates binary corruption from
    // old sessions written before the tool_mod_echo fix).
    var write_idx: usize = 0;
    for (result) |entry| {
        if (std.mem.indexOf(u8, entry.event_json, "\x00") == null) {
            result[write_idx] = entry;
            write_idx += 1;
        } else {
            alloc.free(entry.event_json);
            if (entry.view_json) |v| alloc.free(v);
        }
    }
    return .{
        .entries = result[0..write_idx],
        .has_more = has_more,
        .projections_json = try proj.toOwnedSlice(alloc),
    };
}

fn pushEntry(
    alloc: std.mem.Allocator,
    entries: *std.ArrayList(router.HistoryEntry),
    ev_type: []const u8,
    seq: usize,
    time_ms: i64,
    data_json: []const u8,
) !void {
    var ev: std.ArrayList(u8) = .empty;
    errdefer ev.deinit(alloc);
    try appendEventEnvelope(alloc, &ev, ev_type, seq, time_ms, data_json);
    try entries.append(alloc, .{ .event_json = try ev.toOwnedSlice(alloc) });
}
