//! WebSocket downlink hubs — the apiproxy event bridge (spec §4 stream set).
//!
//! Two downstream-only streams, upgraded by router.handleApiRequest:
//!   GET /api/events.mux   → mux hub  (session/* frames)
//!   GET /api/events.host  → host hub (host/* frames)
//! Each frame is ONE JSON text message in the ServerRequest full form:
//!   {"type":"server-request","rpcId":"<fresh>","method":"<payload.type>","payload":{…}}
//! Client→server data frames are a protocol violation → close 1008
//! (websocket-downlink.ts contract); pings are answered automatically inside
//! httpd.WsConn.readMessage; close frames complete the closing handshake.
//!
//! ── MAPPING TABLE: zharness envelopes → DSH frames ────────────────────────
//!
//! The server/events.zig hub carries obs.zig envelope LINES
//! ({timestamp_unix_ms,trace_id,span_id,session_id,agent_id,event_type,payload})
//! whose shape is unrelated to SessionEventMap, so the mapping lives HERE.
//! `mapObsEnvelope` translates the unambiguous lifecycle subset onto the
//! events.host vocabulary:
//!
//!   zharness obs event_type      → host frame payload
//!   ──────────────────────────────────────────────────────────────────────
//!   session.created              → host/session-added {sessionId,blank:true}
//!   session.resumed              → host/session-added {sessionId,blank:false}
//!   agent.started                → host/session-status {sessionId,running:true}
//!   agent.stopped                → host/session-status {sessionId,running:false}
//!   everything else              → null (no clean mapping yet)
//!
//! The full AgentLoop→SessionEvent bridge (turn/start, assistant/chunk,
//! tool/call, … per spec §3) is spec phase-3 task 9 and lands in main.zig
//! wiring: it publishes PRE-RENDERED session/event payloads through
//! `FrameHub.publish("session/event", payload_json)` on the mux hub. This
//! module owns only transport + wrapping + the lifecycle mapping above.
//!
//! `publishObsEnvelope` is a drop-in for `obs.fanout` once serve mode boots
//! the shared hubs (fanout failures stay invisible, matching the obs hook
//! contract).
//!
//! ── THREADING CONTRACT ────────────────────────────────────────────────────
//! - Pump threads block in WsConn.readMessage; publishes arrive from any
//!   emitter thread. Hub state sits behind one spin lock (server/events.zig
//!   design); sends run under the same lock because loopback writes are
//!   bounded by WsConn's 2 s SO_SNDTIMEO — worst case one wedged client
//!   delays fan-out briefly before being dropped as dead.
//! - Requires httpd Options.threaded_connections = true, like every SSE/WS
//!   stream route.
//! - rpcId minting: process-local monotonic counter under the hub lock
//!   ("push-<n>"). Push ids are opaque to the client (it never correlates
//!   them), so no CSPRNG is needed.

const std = @import("std");
const httpd = @import("../httpd.zig");
const jsonx = @import("jsonx.zig");

// ── lock (same design as server/events.zig's private copy) ─────────────────

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

fn backoffSleepMs(ms: u64) void {
    const req: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = nanosleep(&req, null);
}

const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins >= 16) backoffSleepMs(1) else std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

// ── subscriber ──────────────────────────────────────────────────────────────

pub const Sub = struct {
    conn: *httpd.WsConn,
};

// ── hub ─────────────────────────────────────────────────────────────────────

/// Fans pre-rendered frame payloads out to every subscribed connection as
/// ServerRequest text frames. One instance per stream (/api/events.mux and
/// /api/events.host).
pub const FrameHub = struct {
    alloc: std.mem.Allocator,
    lock: SpinLock = .{},
    subs: std.ArrayList(*Sub) = .empty,
    push_counter: u64 = 0,
    /// Publishes refused because no subscriber list could be built etc.
    dropped: usize = 0,

    /// Wrap `payload_json` into the full form and send to all subscribers.
    /// Failures (write errors) drop the dead subscriber; they never surface.
    pub fn publish(self: *FrameHub, method: []const u8, payload_json: []const u8) void {
        std.debug.print("[host-hub] {s} {s}\n", .{ method, payload_json });
        const frame = self.wrapServerRequest(method, payload_json) catch return;
        defer self.alloc.free(frame);

        self.lock.lock();
        defer self.lock.unlock();

        var i: usize = 0;
        while (i < self.subs.items.len) {
            const sub = self.subs.items[i];
            sub.conn.writeText(frame) catch {
                // Dead peer: drop it. swapRemove keeps iteration safe.
                _ = self.subs.swapRemove(i);
                self.dropped += 1;
                continue;
            };
            i += 1;
        }
        self.push_counter += 1;
    }

    /// ServerRequest full form around a payload (fresh minted rpcId).
    fn wrapServerRequest(self: *FrameHub, method: []const u8, payload_json: []const u8) ![]u8 {
        var id_buf: [40]u8 = undefined;
        self.lock.lock();
        const n = self.push_counter +% 1;
        self.lock.unlock();
        const id = std.fmt.bufPrint(&id_buf, "push-{d}", .{n}) catch "push";
        return wrapServerRequestWithId(self.alloc, id, method, payload_json);
    }

    pub fn subscribe(self: *FrameHub, conn: *httpd.WsConn) !*Sub {
        const sub = try self.alloc.create(Sub);
        errdefer self.alloc.destroy(sub);
        sub.* = .{ .conn = conn };

        self.lock.lock();
        defer self.lock.unlock();
        try self.subs.append(self.alloc, sub);
        return sub;
    }

    pub fn unsubscribe(self: *FrameHub, sub: *Sub) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.subs.items, 0..) |s, i| {
            if (s == sub) {
                _ = self.subs.swapRemove(i);
                break;
            }
        }
        self.alloc.destroy(sub);
    }

    pub fn subscriberCount(self: *FrameHub) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.subs.items.len;
    }
};

/// Pure full-form builder (public for tests/integrators).
pub fn wrapServerRequestWithId(
    alloc: std.mem.Allocator,
    rpc_id: []const u8,
    method: []const u8,
    payload_json: []const u8,
) ![]u8 {
    // The client's zod discriminated union validates the payload's OWN
    // "type" field (upstream frame() embeds it). Inject the discriminator
    // when a caller passed a bare payload.
    const payload_final = if (std.mem.indexOf(u8, payload_json, "\"type\"") == null) blk: {
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(alloc); // allocPrint copies; the scratch buffer dies here
        try jsonx.appendJsonString(alloc, &tmp, method);
        const with_type = try std.fmt.allocPrint(alloc, "{{\"type\":{s},", .{tmp.items});
        // splice out the leading '{' of payload_json into with_type + rest
        const rest = if (payload_json.len > 0 and payload_json[0] == '{')
            payload_json[1..]
        else
            payload_json;
        const joined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ with_type, rest });
        alloc.free(with_type);
        break :blk joined;
    } else payload_json;
    defer if (payload_final.ptr != payload_json.ptr) alloc.free(payload_final);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"server-request\",\"rpcId\":");
    try jsonx.appendJsonString(alloc, &out, rpc_id);
    try out.appendSlice(alloc, ",\"method\":");
    try jsonx.appendJsonString(alloc, &out, method);
    try out.appendSlice(alloc, ",\"payload\":");
    try out.appendSlice(alloc, payload_final);
    try out.appendSlice(alloc, "}");
    return out.toOwnedSlice(alloc);
}

// ── the two streams ────────────────────────────────────────────────────────

pub const Hubs = struct {
    mux: FrameHub,
    host: FrameHub,

    pub fn create(alloc: std.mem.Allocator) !*Hubs {
        const h = try alloc.create(Hubs);
        h.* = .{
            .mux = .{ .alloc = alloc },
            .host = .{ .alloc = alloc },
        };
        return h;
    }

    pub fn destroy(self: *Hubs) void {
        std.debug.assert(self.mux.subscriberCount() == 0);
        std.debug.assert(self.host.subscriberCount() == 0);
        self.mux.subs.deinit(self.mux.alloc);
        self.host.subs.deinit(self.host.alloc);
        self.mux.alloc.destroy(self);
    }
};

var g_hubs: ?*Hubs = null;

/// Process-wide pair of hubs, created on first use (serve mode). Hub state
/// outlives every request, so the hubs deliberately allocate from
/// `std.heap.page_allocator` — NEVER from the caller's (possibly per-
/// connection arena) allocator, whose memory dies with the request.
pub fn sharedHubs() !*Hubs {
    if (g_hubs) |h| return h;
    g_hubs = try Hubs.create(std.heap.page_allocator);
    return g_hubs.?;
}

/// Test/integrator hook: detach the current singleton (caller destroys it).
pub fn takeSharedHubs() ?*Hubs {
    const h = g_hubs;
    g_hubs = null;
    return h;
}

/// Pump for GET /api/events.mux: subscribe to the mux hub, then read until
/// the peer closes. Any client-originated DATA frame violates the downstream-
/// only contract → close 1008. Pings are answered inside readMessage; close
/// completes the handshake there too. Runs on the connection thread until the
/// stream ends.
/// Integrator hook: invoked right after a mux subscriber attaches, BEFORE the
/// pump loop. Use it to write per-session baseline frames (session/subscribed)
/// directly to the connection. Failures are ignored (peer may vanish mid-write).

/// Integrator hook: invoked right after a mux subscriber attaches, BEFORE the
/// pump loop. Use it to write per-session baseline frames (session/subscribed)
/// directly to the connection. Failures are ignored (peer may vanish mid-write).
pub var on_mux_open: ?*const fn (conn: *httpd.WsConn) void = null;

pub fn serveMuxStream(alloc: std.mem.Allocator, conn: *httpd.WsConn) anyerror!void {
    const hubs = try sharedHubs();
    const sub = try hubs.mux.subscribe(conn);
    defer hubs.mux.unsubscribe(sub);
    if (on_mux_open) |hook| hook(conn);
    return pumpStream(.mux, &hubs.mux, alloc, conn, sub);
}

/// Pump for GET /api/events.host: same contract over the host hub. v1 pushes
/// lifecycle/status frames from main.zig via hubs.host.publish.
pub fn serveHostStream(alloc: std.mem.Allocator, conn: *httpd.WsConn) anyerror!void {
    const hubs = try sharedHubs();
    const sub = try hubs.host.subscribe(conn);
    defer hubs.host.unsubscribe(sub);
    return pumpStream(.host, &hubs.host, alloc, conn, sub);
}

const WhichHub = enum { mux, host };

fn pumpStream(which: WhichHub, hub: *FrameHub, alloc: std.mem.Allocator, conn: *httpd.WsConn, sub: *Sub) anyerror!void {
    _ = which;
    _ = hub;
    _ = sub; // frames are written via hub.publish fan-out

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    while (true) {
        const opcode = conn.readMessage(&buf) catch |e| switch (e) {
            error.ConnectionClosed => return, // clean end of stream
            else => return e, // ProtocolError/MessageTooLarge already closed
        };
        switch (opcode) {
            .text, .binary => {
                conn.writeClose(1008, "client-to-server frames are not allowed") catch {};
                return;
            },
            else => {}, // unreachable via readMessage, kept for exhaustiveness
        }
    }
}

// ── obs envelope → host frame mapping ──────────────────────────────────────

pub const MappedHostFrame = struct {
    /// Pre-rendered host-frame PAYLOAD JSON (the ServerRequest wrapper is
    /// applied at publish time).
    payload_json: []const u8,
};

/// Map one serialized obs.zig envelope line onto a DSH host frame per the
/// module header table. Returns null when the event has no mapping yet.
/// Allocator-owned result; parse failures degrade to null (observability
/// never breaks the run).
pub fn mapObsEnvelope(alloc: std.mem.Allocator, line: []const u8) !?MappedHostFrame {
    const session_id = (jsonx.getStringAlloc(alloc, line, "session_id") catch null) orelse return null;
    defer alloc.free(session_id);
    const event_type = (jsonx.getStringAlloc(alloc, line, "event_type") catch null) orelse return null;
    defer alloc.free(event_type);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    if (std.mem.eql(u8, event_type, "session.created") or
        std.mem.eql(u8, event_type, "session.resumed"))
    {
        const blank = std.mem.eql(u8, event_type, "session.created");
        try out.appendSlice(alloc, "{\"type\":\"host/session-added\",\"sessionId\":");
        try jsonx.appendJsonString(alloc, &out, session_id);
        try out.appendSlice(alloc, ",\"blank\":");
        try out.appendSlice(alloc, if (blank) "true" else "false");
        try out.appendSlice(alloc, "}");
        return .{ .payload_json = try out.toOwnedSlice(alloc) };
    }

    if (std.mem.eql(u8, event_type, "agent.started") or
        std.mem.eql(u8, event_type, "agent.stopped"))
    {
        const running = std.mem.eql(u8, event_type, "agent.started");
        try out.appendSlice(alloc, "{\"type\":\"host/session-status\",\"sessionId\":");
        try jsonx.appendJsonString(alloc, &out, session_id);
        try out.appendSlice(alloc, ",\"running\":");
        try out.appendSlice(alloc, if (running) "true" else "false");
        try out.appendSlice(alloc, "}");
        return .{ .payload_json = try out.toOwnedSlice(alloc) };
    }

    return null;
}

/// `obs.fanout` trampoline: map an envelope line and push it on the HOST hub
/// with method = the frame's own type (fullFrame discipline). Failures are
/// swallowed (obs.fanout contract). No-op until serve mode created the hubs.
pub fn publishObsEnvelope(envelope_line: []const u8) void {
    const hubs = g_hubs orelse return;
    const mapped_opt = mapObsEnvelope(hubs.mux.alloc, envelope_line) catch return;
    const mapped = mapped_opt orelse return;
    defer hubs.mux.alloc.free(mapped.payload_json);

    const method = jsonx.getStringAlloc(hubs.mux.alloc, mapped.payload_json, "type") catch null orelse return;
    defer hubs.mux.alloc.free(method);
    hubs.host.publish(method, mapped.payload_json);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "wrapServerRequestWithId produces the exact full-form bytes" {
    const frame = try wrapServerRequestWithId(
        testing.allocator,
        "a1b2c3d4",
        "session/event",
        "{\"type\":\"session/event\",\"sessionId\":\"s\",\"event\":{\"type\":\"assistant/chunk\",\"seq\":41,\"time\":1755946501123,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"Hello\"}}}}",
    );
    defer testing.allocator.free(frame);
    try testing.expectEqualStrings(
        "{\"type\":\"server-request\",\"rpcId\":\"a1b2c3d4\",\"method\":\"session/event\",\"payload\":{\"type\":\"session/event\",\"sessionId\":\"s\",\"event\":{\"type\":\"assistant/chunk\",\"seq\":41,\"time\":1755946501123,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"Hello\"}}}}}",
        frame,
    );
}

test "mapObsEnvelope maps the documented lifecycle table" {
    const Case = struct {
        line: []const u8,
        want: ?[]const u8,
    };
    const cases = [_]Case{
        .{
            .line = "{\"timestamp_unix_ms\":1755946500000,\"trace_id\":\"aabbccddeeff0011\",\"span_id\":\"11223344\",\"session_id\":\"web-1\",\"agent_id\":\"main\",\"event_type\":\"session.created\",\"payload\":{}}",
            .want = "{\"type\":\"host/session-added\",\"sessionId\":\"web-1\",\"blank\":true}",
        },
        .{
            .line = "{\"timestamp_unix_ms\":1,\"trace_id\":\"t\",\"span_id\":\"s\",\"session_id\":\"web-1\",\"agent_id\":\"main\",\"event_type\":\"session.resumed\",\"payload\":{}}",
            .want = "{\"type\":\"host/session-added\",\"sessionId\":\"web-1\",\"blank\":false}",
        },
        .{
            .line = "{\"timestamp_unix_ms\":1,\"trace_id\":\"t\",\"span_id\":\"s\",\"session_id\":\"web-2\",\"agent_id\":\"main\",\"event_type\":\"agent.started\",\"payload\":{}}",
            .want = "{\"type\":\"host/session-status\",\"sessionId\":\"web-2\",\"running\":true}",
        },
        .{
            .line = "{\"timestamp_unix_ms\":1,\"trace_id\":\"t\",\"span_id\":\"s\",\"session_id\":\"web-2\",\"agent_id\":\"main\",\"event_type\":\"agent.stopped\",\"payload\":{}}",
            .want = "{\"type\":\"host/session-status\",\"sessionId\":\"web-2\",\"running\":false}",
        },
        .{
            // Unmapped vocabulary → null.
            .line = "{\"timestamp_unix_ms\":1,\"trace_id\":\"t\",\"span_id\":\"s\",\"session_id\":\"web-2\",\"agent_id\":\"main\",\"event_type\":\"tool.completed\",\"payload\":{}}",
            .want = null,
        },
        .{
            // Missing session_id → null.
            .line = "{\"timestamp_unix_ms\":1,\"event_type\":\"agent.started\",\"payload\":{}}",
            .want = null,
        },
    };

    for (cases) |c| {
        const got = try mapObsEnvelope(testing.allocator, c.line);
        if (c.want) |w| {
            const m = got orelse return error.TestUnexpectedResult;
            defer testing.allocator.free(m.payload_json);
            try testing.expectEqualStrings(w, m.payload_json);
        } else {
            try testing.expect(got == null);
        }
    }
}

test "frame hub fans out to subscribers and drops dead ones" {
    // Stand-in conns are impossible without sockets; the socket-level test
    // lives in src/_t_apiproxy.zig over real loopback. Here: subscribe/
    // unsubscribe bookkeeping with a null-fd conn that never gets written to.
    // (The shared-hubs singleton lifecycle has no standalone unit test: its
    // teardown races detached pump threads, so integration tests own it and
    // the process owns release.)
    var conn = httpd.WsConn.init(-1, testing.allocator);
    var hub = FrameHub{ .alloc = testing.allocator };
    _ = &hub;
    defer hub.subs.deinit(testing.allocator);

    const sub = try hub.subscribe(&conn);
    try testing.expectEqual(@as(usize, 1), hub.subscriberCount());
    hub.unsubscribe(sub);
    try testing.expectEqual(@as(usize, 0), hub.subscriberCount());

    // Publishing with zero subscribers is safe.
    hub.publish("session/event", "{}");
    try testing.expectEqual(@as(usize, 0), hub.dropped);
}
