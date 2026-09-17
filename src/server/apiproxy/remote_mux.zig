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
var g_seq: u64 = 0;

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

/// Current journal cursor (monotonic; zharness keeps no durable seq store in
/// this generation, so live frames number from 1 per process).
pub fn cursor() u64 {
    lock();
    defer unlock();
    return g_seq;
}

/// Publish one durable-shaped journal event to every follow stream bound to
/// `session_id`. `data_json` is embedded verbatim (must be JSON-safe).
pub fn publishEvent(alloc: std.mem.Allocator, session_id: []const u8, event_type: []const u8, data_json: []const u8) void {
    var type_json: std.ArrayList(u8) = .empty;
    defer type_json.deinit(alloc);
    jsonx.appendJsonString(alloc, &type_json, event_type) catch return;

    lock();
    g_seq += 1;
    const seq = g_seq;
    unlock();

    const event = std.fmt.allocPrint(alloc, "{{\"type\":{s},\"seq\":{d},\"time\":{d},\"data\":{s}}}", .{ type_json.items, seq, nowMs(), data_json }) catch return;
    defer alloc.free(event);
    const entry = std.fmt.allocPrint(alloc, "{{\"type\":\"event\",\"event\":{s}}}", .{event}) catch return;
    defer alloc.free(entry);

    lock();
    defer unlock();
    for (g_streams.items) |s| {
        if (s.control) continue;
        if (s.session_id.len != 0 and !std.mem.eql(u8, s.session_id, session_id)) continue;
        sendItem(alloc, s, entry.items);
    }
}

/// Send the follow opening snapshot for `session_id` on a freshly opened
/// stream. Records stay empty (cold reads go through session.history /
/// session.page); the cursor reports the live-frame sequence origin.
pub fn sendSnapshot(alloc: std.mem.Allocator, s: *Stream, session_id: []const u8) void {
    var id_json: std.ArrayList(u8) = .empty;
    defer id_json.deinit(alloc);
    jsonx.appendJsonString(alloc, &id_json, session_id) catch return;
    const head = std.fmt.allocPrint(alloc, "{{\"type\":\"snapshot\",\"header\":{{\"version\":1,\"id\":{s},\"createdAt\":{d},\"isSeeded\":false}},\"cursor\":-1,\"records\":[],\"hasMore\":false,\"assistantStream\":{{\"revision\":0,\"attempts\":[]}},\"projections\":{{\"asOfSeq\":-1,\"values\":{{\"modelSelection\":{{\"lastUsed\":null,\"pending\":null}}}}}},", .{ id_json.items, nowMs() }) catch return;
    defer alloc.free(head);
    const value = std.fmt.allocPrint(alloc, "{s}\"projections\":{{\"asOfSeq\":0,\"values\":{{}}}}}}", .{head}) catch return;
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
    const value = std.fmt.allocPrint(alloc, "{{\"type\":\"baseline\",\"value\":{{\"items\":[{{\"workspaceId\":\"ws-zharness\",\"path\":{s},\"title\":\"zharness\",\"sessionIds\":[],\"createdAt\":\"2026-01-01T00:00:00.000Z\",\"updatedAt\":\"2026-01-01T00:00:00.000Z\"}}],\"archivedSessionIds\":[]}}}}", .{path_json.items}) catch return;
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

pub fn streamCount() usize {
    lock();
    defer unlock();
    return g_streams.items.len;
}

/// Publish one PRE-BUILT event envelope line (the exact SessionWireEvent
/// JSON produced by main.zig's muxPublishEvent) to every follow stream bound
/// to `session_id`. Called from the run thread per live frame; item frames
/// are built and written per stream under the lock (FrameHub.publishFrame
/// precedent — WsConn writes tolerate the foreign thread).
pub fn publishLine(session_id: []const u8, value_json: []const u8) void {
    var id_json: std.ArrayList(u8) = .empty;
    defer id_json.deinit(c_alloc);

    lock();
    defer unlock();
    for (g_streams.items) |s| {
        if (s.kind != .follow) continue;
        if (s.session_id.len != 0 and !std.mem.eql(u8, s.session_id, session_id)) continue;
        id_json.clearRetainingCapacity();
        jsonx.appendJsonString(c_alloc, &id_json, s.stream_id) catch continue;
        const frame = std.fmt.allocPrint(c_alloc, "{{\"type\":\"item\",\"streamId\":{s},\"value\":{s}}}", .{ id_json.items, value_json }) catch continue;
        defer c_alloc.free(frame);
        s.conn.writeText(frame) catch {};
    }
}
