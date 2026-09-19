//! remote.mux session streams (upstream gateway stream-protocol.ts): the
//! bidirectional `/api/remote.mux` socket multiplexes per-stream frames.
//! This module owns the SERVER side of the logical streams zharness serves:
//!
//!   session.follow  — journal frames for one session address:
//!                       {type:'snapshot', header, cursor, records, hasMore,
//!                        projections}
//!                       {type:'event', event:{type,seq,time,data}}
//!   session.control — host-wide live control: {type:'baseline', value}
//!
//! The agent loop's live publishers (main.zig followEmit) call publishEvent;
//! each matching stream receives its own item frame
//! {type:'item', streamId, value} because the streamId differs per open
//! stream. Connections are owned by their pump threads (events_ws
//! serveRemoteMux); register/unregister happen under the pump's control and
//! publish takes the same lock, so a stream whose pump just exited is
//! unregistered before any further publish can reach a dead conn.
//!
//! Stream records live for the process lifetime (any thread may publish into
//! them at any time), so everything allocates from the C allocator like the
//! router's shared singletons — never from a connection arena.

const std = @import("std");
const httpd = @import("../httpd.zig");
const jsonx = @import("jsonx.zig");

const c_alloc = std.heap.c_allocator;

extern "c" fn clock_gettime(clk_id: c_int, tp: *std.c.timespec) c_int;

/// Wall-clock milliseconds (CLOCK_REALTIME = 0), the std.time.milliTimestamp
/// equivalent for this toolchain generation.
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(0, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

// ── lock (events_ws/settings.zig SpinLock design; std.Thread.Mutex lives
// under std.Io in this toolchain). Critical sections are tiny. ──────────────
var g_locked = std.atomic.Value(bool).init(false);

fn lock() void {
    var spins: u32 = 0;
    while (g_locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        spins += 1;
        if (spins >= 16) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
    }
}

fn unlock() void {
    g_locked.store(false, .release);
}
var g_streams: std.ArrayListUnmanaged(*Stream) = .empty;

pub const Kind = enum { follow, control, workspace, events };

pub const Stream = struct {
    stream_id: []u8,
    /// Owning session id for follow streams; empty otherwise.
    session_id: []u8,
    kind: Kind,
    conn: *httpd.WsConn,
};

pub fn register(stream_id: []const u8, session_id: []const u8, kind: Kind, conn: *httpd.WsConn) !*Stream {
    const s = try c_alloc.create(Stream);
    errdefer c_alloc.destroy(s);
    s.* = .{
        .stream_id = try c_alloc.dupe(u8, stream_id),
        .session_id = try c_alloc.dupe(u8, session_id),
        .kind = kind,
        .conn = conn,
    };
    lock();
    defer unlock();
    try g_streams.append(c_alloc, s);
    return s;
}

pub fn unregister(stream_id: []const u8) void {
    lock();
    defer unlock();
    var i: usize = 0;
    while (i < g_streams.items.len) : (i += 1) {
        const s = g_streams.items[i];
        if (std.mem.eql(u8, s.stream_id, stream_id)) {
            _ = g_streams.swapRemove(i);
            c_alloc.free(s.stream_id);
            c_alloc.free(s.session_id);
            c_alloc.destroy(s);
            return;
        }
    }
}

/// Send one `{type:'item', streamId, value}` frame to one stream. Caller
/// holds no lock (writeText is called under g_lock from the publishers, and
/// pump threads only reach this through register-time sends before any
/// publisher knows the stream).
fn sendItem(alloc: std.mem.Allocator, s: *Stream, value_json: []const u8) void {
    var id_json: std.ArrayList(u8) = .empty;
    defer id_json.deinit(alloc);
    jsonx.appendJsonString(alloc, &id_json, s.stream_id) catch return;
    const frame = std.fmt.allocPrint(alloc, "{{\"type\":\"item\",\"streamId\":{s},\"value\":{s}}}", .{ id_json.items, value_json }) catch return;
    defer alloc.free(frame);
    s.conn.writeText(frame) catch {};
}

/// Current journal cursor (last seq handed to a routed entry; -1 before the
/// first). Reconnect snapshots replay the live window through this cursor, so
/// the client's `follows = right === left + 1` continuity holds across
/// reconnects instead of re-opening at -1 behind already-published entries.
pub fn cursor() i64 {
    lock();
    defer unlock();
    return g_last_seq;
}

/// Next durable journal seq. Client journal streams require consecutive seqs
/// from the snapshot cursor, so EVERY routed journal event allocates here and
/// non-journal frames (assistant-stream notifications, legacy $events) never
/// touch this counter.
var g_journal_seq = std.atomic.Value(u64).init(0);

pub fn nextJournalSeq() u64 {
    return g_journal_seq.fetchAdd(1, .monotonic);
}

/// Live window of routed journal entries (wrapped SessionEventEntry values,
/// oldest first, tagged by owning session) replayed by reconnect snapshots.
const win_cap = 512;
var g_win: [win_cap]?[]const u8 = @splat(null);
var g_win_sid: [win_cap]?[]u8 = @splat(null);
var g_win_seq: [win_cap]u64 = @splat(0);
var g_win_next: usize = 0;
var g_win_count: usize = 0;
var g_last_seq: i64 = -1;

/// Assistant-stream presentation revision. Snapshot baselines carry the
/// current value; every assistant-stream frame allocates the next one, so the
/// client's `revision === last + 1` check holds across reconnects.
var g_assistant_rev = std.atomic.Value(u64).init(0);

pub fn assistantRevision() u64 {
    return g_assistant_rev.load(.monotonic);
}

pub fn nextAssistantRevision() u64 {
    return g_assistant_rev.fetchAdd(1, .monotonic) + 1;
}

/// Send the follow opening snapshot for `session_id` on a freshly opened
/// stream. Replays the in-memory live window for this session (records +
/// matching cursor) so reconnects stay continuous; a cold session opens at
/// cursor -1 with no records. Older history pages still go through
/// session.history / session.page.
pub fn sendSnapshot(alloc: std.mem.Allocator, s: *Stream, session_id: []const u8) void {
    var id_json: std.ArrayList(u8) = .empty;
    defer id_json.deinit(alloc);
    jsonx.appendJsonString(alloc, &id_json, session_id) catch return;

    lock();
    var records: std.ArrayList(u8) = .empty;
    defer records.deinit(alloc);
    var cur: i64 = -1;
    if (g_win_count > 0) {
        const oldest = g_win_next - g_win_count + win_cap;
        var i: usize = 0;
        while (i < g_win_count) : (i += 1) {
            const slot = (oldest + i) % win_cap;
            const sid = g_win_sid[slot] orelse continue;
            if (!std.mem.eql(u8, sid, session_id)) continue;
            if (records.items.len != 0) records.appendSlice(alloc, ",") catch break;
            records.appendSlice(alloc, g_win[slot] orelse continue) catch break;
            cur = @intCast(g_win_seq[slot]);
        }
    }
    const rev = g_assistant_rev.load(.monotonic);
    unlock();

    const value = std.fmt.allocPrint(alloc, "{{\"type\":\"snapshot\",\"header\":{{\"version\":1,\"id\":{s},\"createdAt\":{d},\"isSeeded\":false}},\"cursor\":{d},\"records\":[{s}],\"hasMore\":false,\"assistantStream\":{{\"revision\":{d}}},\"projections\":{{\"asOfSeq\":-1,\"values\":{{\"modelSelection\":{{\"lastUsed\":null,\"pending\":null}}}}}}}}", .{ id_json.items, nowMs(), cur, records.items, rev }) catch return;
    defer alloc.free(value);
    sendItem(alloc, s, value);
}

/// Publish one control frame value to every control stream (session.control
/// generations open with exactly one baseline).
pub fn publishControl(alloc: std.mem.Allocator, value_json: []const u8) void {
    const frame = std.fmt.allocPrint(alloc, "{{\"type\":\"baseline\",\"value\":{s}}}", .{value_json}) catch return;
    defer alloc.free(frame);

    lock();
    defer unlock();
    for (g_streams.items) |s| {
        if (s.kind != .control) continue;
        sendItem(alloc, s, frame);
    }
}

/// Send the workspace.follow opening baseline: one synthesized Workspace
/// covering the server cwd (zharness has a single implicit workspace).
pub fn sendWorkspaceBaseline(alloc: std.mem.Allocator, s: *Stream) void {
    // CWD via getcwd(3): std.process lost getCwdAlloc in this toolchain
    // generation and events_ws carries no Io handle.
    var buf: [4096]u8 = undefined;
    const path: []u8 = blk: {
        const n = std.c.getcwd(&buf, buf.len);
        if (n != null) break :blk c_alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&buf)))) catch return;
        break :blk c_alloc.dupe(u8, ".") catch return;
    };
    defer c_alloc.free(path);
    var path_json: std.ArrayList(u8) = .empty;
    defer path_json.deinit(alloc);
    jsonx.appendJsonString(alloc, &path_json, path) catch return;
    const ids_json = sessionIdsJson(alloc) catch return;
    defer alloc.free(ids_json);
    const value = std.fmt.allocPrint(alloc, "{{\"type\":\"baseline\",\"value\":{{\"items\":[{{\"workspaceId\":\"ws-zharness\",\"path\":{s},\"title\":\"zharness\",\"sessionIds\":{s},\"createdAt\":\"2026-01-01T00:00:00.000Z\",\"updatedAt\":\"2026-01-01T00:00:00.000Z\"}}],\"archivedSessionIds\":[]}}}}", .{ path_json.items, ids_json }) catch return;
    defer alloc.free(value);
    sendItem(alloc, s, value);
}

/// Forward one Gateway-internal event/waterfall frame value to every
/// `$events` stream (user-questions waterfalls and future cordis fan-out).
pub fn publishEvents(alloc: std.mem.Allocator, value_json: []const u8) void {
    _ = alloc;
    var id_json: std.ArrayList(u8) = .empty;
    defer id_json.deinit(c_alloc);

    lock();
    defer unlock();
    if (std.c.getenv("ZH_DEBUG_RPC") != null)
        std.debug.print("[publishEvents] streams={d}\n", .{g_streams.items.len});
    for (g_streams.items) |s| {
        if (s.kind != .events) continue;
        id_json.clearRetainingCapacity();
        jsonx.appendJsonString(c_alloc, &id_json, s.stream_id) catch continue;
        const frame = std.fmt.allocPrint(c_alloc, "{{\"type\":\"item\",\"streamId\":{s},\"value\":{s}}}", .{ id_json.items, value_json }) catch continue;
        defer c_alloc.free(frame);
        s.conn.writeText(frame) catch {};
    }
}

/// Publish one pre-built control-stream frame (projection / queue / jobs)
/// to every control stream, bypassing the baseline wrapper.
pub fn publishControlRaw(frame_json: []const u8) void {
    if (std.c.getenv("ZH_DEBUG_RPC") != null)
        std.debug.print("[proj] {s}\n", .{frame_json[0..@min(frame_json.len, 200)]});
    lock();
    defer unlock();
    for (g_streams.items) |s| {
        if (s.kind != .control) continue;
        var id_json: std.ArrayList(u8) = .empty;
        defer id_json.deinit(c_alloc);
        jsonx.appendJsonString(c_alloc, &id_json, s.stream_id) catch continue;
        const item = std.fmt.allocPrint(c_alloc, "{{\"type\":\"item\",\"streamId\":{s},\"value\":{s}}}", .{ id_json.items, frame_json }) catch continue;
        defer c_alloc.free(item);
        s.conn.writeText(item) catch {};
    }
}

/// Publish one workspace.follow increment frame to every workspace stream.
/// `value_json` is the WorkspaceFollowIncrement object verbatim.
pub fn publishWorkspaceIncrement(alloc: std.mem.Allocator, value_json: []const u8) void {
    _ = alloc;
    var id_json: std.ArrayList(u8) = .empty;
    defer id_json.deinit(c_alloc);

    lock();
    defer unlock();
    for (g_streams.items) |s| {
        if (s.kind != .workspace) continue;
        id_json.clearRetainingCapacity();
        jsonx.appendJsonString(c_alloc, &id_json, s.stream_id) catch continue;
        const frame = std.fmt.allocPrint(c_alloc, "{{\"type\":\"item\",\"streamId\":{s},\"value\":{s}}}", .{ id_json.items, value_json }) catch continue;
        defer c_alloc.free(frame);
        s.conn.writeText(frame) catch {};
    }
}

// ── workspace membership (single-cwd host model) ────────────────────────────

const CDirIterator = struct {
    dir: ?*std.c.DIR,

    fn init(path: []const u8) ?CDirIterator {
        var buf: [512]u8 = undefined;
        if (path.len > buf.len - 1) return null;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const d = std.c.opendir(@ptrCast(&buf)) orelse return null;
        return .{ .dir = d };
    }
    fn deinit(self: *CDirIterator) void {
        if (self.dir) |d| _ = std.c.closedir(d);
        self.dir = null;
    }
    fn next(self: *CDirIterator) ?[]const u8 {
        const entry = std.c.readdir(self.dir orelse return null) orelse return null;
        // macOS dirent: d_name sits at a non-zero offset inside the struct.
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.*.name)), 0);
        return name;
    }
};

/// Session ids (JSON array) for the workspace view: every session file under
/// `<cwd>/.zharness/sessions` (index.json excluded). Caller owns the memory.
fn sessionIdsJson(alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '[');
    var it = CDirIterator.init(".zharness/sessions") orelse {
        try out.append(alloc, ']');
        return out.toOwnedSlice(alloc);
    };
    defer it.deinit();
    var first = true;
    while (it.next()) |name| {
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        if (std.mem.eql(u8, name, "index.json")) continue;
        if (!first) try out.append(alloc, ',');
        first = false;
        const stem = name[0 .. name.len - 5];
        try out.append(alloc, '"');
        try out.appendSlice(alloc, stem);
        try out.append(alloc, '"');
    }
    try out.append(alloc, ']');
    return out.toOwnedSlice(alloc);
}

/// workspace.follow upsert increment: the synthesized workspace with its
/// CURRENT member list. Broadcast after every session.create so connected
/// pages see workspace.sessionIds grow (the picker/composer gate reads it).
pub fn publishWorkspaceUpsertFromDir(alloc: std.mem.Allocator) void {
    const ids = sessionIdsJson(alloc) catch return;
    defer alloc.free(ids);
    if (std.c.getenv("ZH_DEBUG_RPC") != null)
        std.debug.print("[ws-upsert] sessionIds={s}\n", .{ids});

    var id_json: std.ArrayList(u8) = .empty;
    defer id_json.deinit(c_alloc);

    lock();
    defer unlock();
    for (g_streams.items) |s| {
        if (s.kind != .workspace) continue;
        id_json.clearRetainingCapacity();
        jsonx.appendJsonString(c_alloc, &id_json, s.stream_id) catch continue;
        const frame = std.fmt.allocPrint(c_alloc, "{{\"type\":\"item\",\"streamId\":{s},\"value\":{{\"type\":\"upsert\",\"workspace\":{{\"workspaceId\":\"ws-zharness\",\"path\":\".\",\"title\":\"zharness\",\"sessionIds\":{s},\"createdAt\":\"2026-01-01T00:00:00.000Z\",\"updatedAt\":\"2026-01-01T00:00:00.000Z\"}}}}}}", .{ id_json.items, ids }) catch continue;
        defer c_alloc.free(frame);
        s.conn.writeText(frame) catch {};
    }
}

pub fn streamCount() usize {
    lock();
    defer unlock();
    return g_streams.items.len;
}

/// Publish one PRE-BUILT SessionWireEvent envelope line (the exact event JSON
/// the caller built with its `nextJournalSeq()` seq) to every follow stream
/// bound to `session_id`. The value is wrapped in the client's
/// SessionEventEntry shape {type:'event', event:<envelope>} — the journal
/// transport asserts event lives one level down — recorded in the reconnect
/// window, and sent per stream under the lock (FrameHub.publishFrame
/// precedent — WsConn writes tolerate the foreign thread).
pub fn publishLine(session_id: []const u8, seq: u64, value_json: []const u8) void {
    const entry = std.fmt.allocPrint(c_alloc, "{{\"type\":\"event\",\"event\":{s}}}", .{value_json}) catch return;
    defer c_alloc.free(entry);

    lock();
    defer unlock();
    g_last_seq = @intCast(seq);
    const slot = g_win_next;
    if (g_win[slot]) |old| c_alloc.free(old);
    if (g_win_sid[slot]) |old| c_alloc.free(old);
    g_win[slot] = c_alloc.dupe(u8, entry) catch null;
    g_win_sid[slot] = c_alloc.dupe(u8, session_id) catch null;
    g_win_seq[slot] = seq;
    g_win_next = (slot + 1) % win_cap;
    if (g_win_count < win_cap) g_win_count += 1;

    var id_json: std.ArrayList(u8) = .empty;
    defer id_json.deinit(c_alloc);
    for (g_streams.items) |s| {
        if (s.kind != .follow) continue;
        if (s.session_id.len != 0 and !std.mem.eql(u8, s.session_id, session_id)) continue;
        id_json.clearRetainingCapacity();
        jsonx.appendJsonString(c_alloc, &id_json, s.stream_id) catch continue;
        const frame = std.fmt.allocPrint(c_alloc, "{{\"type\":\"item\",\"streamId\":{s},\"value\":{s}}}", .{ id_json.items, entry }) catch continue;
        defer c_alloc.free(frame);
        s.conn.writeText(frame) catch {};
    }
}

/// Publish one assistant-stream presentation frame ({type:'start'|'chunk'|
/// 'end', ...} JSON built by the caller with its `nextAssistantRevision()`
/// revision) to every follow stream bound to `session_id`. Transient by
/// design: never enters the journal window or the seq counter.
pub fn publishAssistantLine(session_id: []const u8, frame_json: []const u8) void {
    const value = std.fmt.allocPrint(c_alloc, "{{\"type\":\"assistant-stream\",\"frame\":{s}}}", .{frame_json}) catch return;
    defer c_alloc.free(value);

    lock();
    defer unlock();
    var id_json: std.ArrayList(u8) = .empty;
    defer id_json.deinit(c_alloc);
    for (g_streams.items) |s| {
        if (s.kind != .follow) continue;
        if (s.session_id.len != 0 and !std.mem.eql(u8, s.session_id, session_id)) continue;
        id_json.clearRetainingCapacity();
        jsonx.appendJsonString(c_alloc, &id_json, s.stream_id) catch continue;
        const frame = std.fmt.allocPrint(c_alloc, "{{\"type\":\"item\",\"streamId\":{s},\"value\":{s}}}", .{ id_json.items, value }) catch continue;
        defer c_alloc.free(frame);
        s.conn.writeText(frame) catch {};
    }
}
