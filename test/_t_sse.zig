//! I-sse self-test root — run with:
//!     zig test -lc test/_t_sse.zig
//!
//! Covers the Wave-4 SSE surface: server/events.zig broadcast hub (replay +
//! live tail + drop policy), the obs.zig fan-out hook wiring, and the
//! server/api.zig /events route (real `data:` frames vs heartbeat fallback).
//!
//! End-to-end framing tests run over an AF_UNIX socketpair driving the REAL
//! httpd.Responder/EventStream code paths — no TCP, no network. Page
//! allocator is used where the handler runs on a second thread (mirroring
//! httpd's per-connection arena shape); everything single-threaded runs
//! under std.testing.allocator so leaks surface as failures.
//!
//! Top-level placement keeps every `@import("../src/../…")` inside the module path.
//! The integrator folds these modules into src/tests.zig at wave end.

const std = @import("std");

comptime {
    _ = @import("../src/server/events.zig");
    _ = @import("../src/server/api.zig");
    _ = @import("../src/server/httpd.zig");
    _ = @import("obs.zig");
}

const builtin = @import("builtin");
const events = @import("../src/server/events.zig");
const httpd = @import("../src/server/httpd.zig");
const api = @import("../src/server/api.zig");
const obs_mod = @import("obs.zig");

// ── socketpair plumbing (offline loopback stand-in for a TCP connection) ───

extern "c" fn read(fd: c_int, buf: [*]u8, nbyte: usize) isize;

/// Set SO_NOSIGPIPE so a dead peer yields EPIPE instead of killing the test
/// process (Darwin; Linux httpd passes MSG_NOSIGNAL on every send).
fn setNoSigPipe(fd: std.posix.socket_t) void {
    if (builtin.os.tag.isDarwin()) {
        const one: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
    }
}

const SocketPair = struct {
    w: std.posix.socket_t,
    r: std.posix.socket_t,

    fn init() !SocketPair {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
            return error.SocketPairFailed;
        }
        return .{ .w = fds[0], .r = fds[1] };
    }

    /// Bound reader waits so a misbehaving handler fails the test instead of
    /// hanging it.
    fn setReadTimeout(self: *const SocketPair, secs: u32) void {
        const tv: std.c.timeval = .{ .sec = @intCast(secs), .usec = 0 };
        _ = std.c.setsockopt(self.r, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &tv, @sizeOf(std.c.timeval));
    }

    /// One read; error.WouldBlock maps to error.Timeout (RCVTIMEO expiry).
    fn readSome(self: *const SocketPair, buf: []u8) !usize {
        const n = read(self.r, buf.ptr, buf.len);
        if (n < 0) return error.Timeout;
        if (n == 0) return error.PeerClosed;
        return @intCast(n);
    }

    fn closeReader(self: *SocketPair) void {
        if (self.r >= 0) {
            _ = std.c.close(self.r);
            self.r = -1;
        }
    }

    fn deinit(self: *SocketPair) void {
        _ = std.c.close(self.w);
        self.w = -1;
        self.closeReader();
    }
};

/// Accumulate from the socket until `needle` appears (or timeout).
fn readUntil(acc: *std.ArrayList(u8), sp: *const SocketPair, alloc: std.mem.Allocator, needle: []const u8) !void {
    var chunk: [2048]u8 = undefined;
    while (std.mem.indexOf(u8, acc.items, needle) == null) {
        const n = try sp.readSome(&chunk);
        try acc.appendSlice(alloc, chunk[0..n]);
    }
}

// ── fake ServerDeps (never invoked on the /events path) ─────────────────────

fn depsRunFails(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
    return error.UnreachableRoute;
}
fn depsListFails(_: ?*anyopaque, _: std.mem.Allocator) anyerror![]api.ServerDeps.SessionSummary {
    return error.UnreachableRoute;
}
fn depsGetFails(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?api.ServerDeps.SessionDetail {
    return error.UnreachableRoute;
}

fn makeDeps(alloc: std.mem.Allocator) !*api.ServerDeps {
    const deps = try alloc.create(api.ServerDeps);
    deps.* = .{
        .ctx = null,
        .runTask = depsRunFails,
        .listSessions = depsListFails,
        .getSession = depsGetFails,
    };
    return deps;
}

fn makeEventsRequest(alloc: std.mem.Allocator) !httpd.Request {
    const raw = "GET /events HTTP/1.1\r\nHost: t\r\nAccept: text/event-stream\r\n\r\n";
    return httpd.parseRequest(alloc, raw);
}

// ── heartbeat fallback over a socketpair ────────────────────────────────────

test "fallback stream sends SSE head, intro comment, heartbeats, honors disconnect" {
    const alloc = std.testing.allocator;
    var sp = try SocketPair.init();
    defer sp.deinit();
    sp.setReadTimeout(5);
    setNoSigPipe(sp.w);

    var res = httpd.Responder{ .fd = sp.w, .alloc = std.heap.page_allocator };

    const Worker = struct {
        fn run(r: *httpd.Responder) void {
            // Shrunk cadence: production constants are 15s/lifetime-capped.
            api.serveHeartbeatStream(r, 20, 10_000) catch {};
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&res});
    defer worker.join(); // runs before sp.deinit (reverse defer order)

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    try readUntil(&acc, &sp, alloc, ": heartbeat");

    const body = acc.items;
    try std.testing.expect(std.mem.startsWith(u8, body, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: text/event-stream\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ": zharness events (no feed installed); heartbeats\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ": heartbeat\n\n") != null);

    // Client disconnect: next comment write must fail and end the handler.
    sp.closeReader();
}

// ── live hub feed through the full api.handle dispatch ──────────────────────

test "handle /events streams real data frames from the hub, then disconnect ends it" {
    const alloc = std.testing.allocator;

    // Handler runs on its own thread: hub + request memory use the page
    // allocator (same shape as httpd's per-connection arenas).
    try events.install(std.heap.page_allocator);
    defer events.deinstall();

    const deps = try makeDeps(std.heap.page_allocator);
    defer std.heap.page_allocator.destroy(deps);
    var req = try makeEventsRequest(std.heap.page_allocator);
    defer req.deinit(std.heap.page_allocator);

    var sp = try SocketPair.init();
    defer sp.deinit();
    sp.setReadTimeout(5);
    setNoSigPipe(sp.w);

    var res = httpd.Responder{ .fd = sp.w, .alloc = std.heap.page_allocator };

    const Worker = struct {
        fn run(d: *api.ServerDeps, heap: std.mem.Allocator, rq: *const httpd.Request, rs: *httpd.Responder) void {
            api.handle(d, heap, rq, rs) catch {};
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{ deps, std.heap.page_allocator, &req, &res });
    defer worker.join();

    // Intro comment proves the HUB branch was taken (not the stub).
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    try readUntil(&acc, &sp, alloc, ": zharness event stream");

    // Publish three envelopes. Whether they land before or after the
    // handler's subscribe, replay-seam ordering guarantees oldest-first
    // delivery, so exact frame order is asserted below either way.
    const lines = [_][]const u8{
        "{\"i\":1,\"event_type\":\"a\"}",
        "{\"i\":2,\"event_type\":\"b\"}",
        "{\"i\":3,\"event_type\":\"c\"}",
    };
    for (lines) |line| events.hub().?.publish(line);

    try readUntil(&acc, &sp, alloc, "\"i\":3");

    const body = acc.items;
    var pos: usize = 0;
    for (lines) |want_frame| {
        // Exact SSE data frame, in publish order.
        var frame_buf: [256]u8 = undefined;
        const frame = try std.fmt.bufPrint(&frame_buf, "data: {s}\n\n", .{want_frame});
        const at = std.mem.indexOfPos(u8, body, pos, frame) orelse {
            std.debug.print("\n--- received ---\n{s}\n----------------\nmissing frame: {s}\n", .{ body, frame });
            return error.MissingFrame;
        };
        pos = at + frame.len;
    }

    // Force disconnect handling: closing the peer makes the NEXT write fail.
    // One extra publish guarantees the handler attempts a write promptly
    // instead of idling until the 15s keep-alive.
    sp.closeReader();
    events.hub().?.publish("{\"i\":4,\"bye\":true}");
}

test "route /events stays a pure SSE marker with and without the hub" {
    const alloc = std.testing.allocator;
    const deps = try makeDeps(alloc);
    defer alloc.destroy(deps);

    // Hub absent: still SSE (heartbeat fallback at handle time).
    try std.testing.expect(events.hub() == null);
    var req = try makeEventsRequest(alloc);
    defer req.deinit(alloc);
    var r = try api.route(deps, alloc, &req);
    defer r.deinit(alloc);
    try std.testing.expect(r.sse);
    try std.testing.expectEqual(@as(usize, 0), r.body.len);

    // Hub installed: unchanged pure route decision.
    try events.install(alloc);
    defer events.deinstall();
    var r2 = try api.route(deps, alloc, &req);
    defer r2.deinit(alloc);
    try std.testing.expect(r2.sse);
}

// ── obs.zig ⇆ events.zig fan-out wiring ─────────────────────────────────────

extern "c" fn time(tloc: ?*c_long) c_long;

var tse_counter: u32 = 0;

/// Per-test scratch directory (same pattern as src/obs.zig's TestEnv).
const TempEnv = struct {
    t: std.Io.Threaded,
    dir: []u8,

    fn setup(alloc: std.mem.Allocator) !TempEnv {
        tse_counter += 1;
        return .{
            .t = std.Io.Threaded.init(std.heap.page_allocator, .{}),
            .dir = try std.fmt.allocPrint(alloc, "/tmp/zh_sse_{d}_{d}", .{ time(null), tse_counter }),
        };
    }
    fn io(self: *TempEnv) std.Io {
        return self.t.io();
    }
    fn teardown(self: *TempEnv, alloc: std.mem.Allocator) void {
        defer self.t.deinit();
        defer alloc.free(self.dir);
        const slash = std.mem.lastIndexOfScalar(u8, self.dir, '/') orelse return;
        const cwd = std.Io.Dir.cwd();
        const parent = std.Io.Dir.openDir(cwd, self.io(), self.dir[0..slash], .{}) catch return;
        defer std.Io.Dir.close(parent, self.io());
        std.Io.Dir.deleteTree(parent, self.io(), self.dir[slash + 1 ..]) catch {};
    }
};

test "obs.fanout feeds emitAt envelopes to hub subscribers byte-identically" {
    const alloc = std.testing.allocator;
    var tenv = try TempEnv.setup(alloc);
    defer tenv.teardown(alloc);
    const io = tenv.io();

    try events.install(alloc);
    defer events.deinstall();
    const sub = try events.hub().?.subscribe();

    // Serve-mode wiring exactly as the integrator will set it.
    obs_mod.fanout = &events.hubPublish;
    defer obs_mod.fanout = null;

    const path = try std.fmt.allocPrint(alloc, "{s}/logs/events.jsonl", .{tenv.dir});
    defer alloc.free(path);
    var sink = try obs_mod.JsonlSink.init(alloc, path);
    defer sink.deinit();

    var trace = obs_mod.TraceCtx.start(io, "sess-9", "agent-main");

    // 1) Live delivery of a normal emit, byte-identical to the jsonl line.
    sink.emitAt(io, &trace, .info, "tool.completed", "{\"tool\":\"grep\"}");
    try std.testing.expectEqual(@as(usize, 0), sink.dropped_events);

    const live = sub.take().?;
    var parsed = try obs_mod.parseEnvelope(alloc, live);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("tool.completed", parsed.event_type);
    try std.testing.expectEqualStrings("{\"tool\":\"grep\"}", parsed.payload_json);

    // The durable copy is THE SAME line plus '\n' (one shared serialization).
    const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
    const cwd = std.Io.Dir.cwd();
    const dir = try std.Io.Dir.openDir(cwd, io, path[0..slash], .{});
    defer std.Io.Dir.close(dir, io);
    const raw = try std.Io.Dir.readFileAlloc(dir, io, path[slash + 1 ..], alloc, .limited(1 << 20));
    defer alloc.free(raw);
    const nl = std.mem.indexOfScalar(u8, raw, '\n').?;
    try std.testing.expectEqualStrings(live, raw[0..nl]);

    // 2) Filtered-out events are invisible to BOTH sinks.
    sink.type_filters = &.{"model."};
    sink.emitAt(io, &trace, .info, "tool.started", "{}");
    try std.testing.expect(sub.take() == null);

    // 3) Level gate behaves identically for the fan-out path.
    sink.min_level = .err;
    sink.emitAt(io, &trace, .info, "agent.stopped", "{}");
    try std.testing.expect(sub.take() == null);

    events.hub().?.unsubscribe(sub);
}

test "fanout left null keeps CLI logging pure-jsonl (no hub traffic)" {
    const alloc = std.testing.allocator;
    var tenv = try TempEnv.setup(alloc);
    defer tenv.teardown(alloc);
    const io = tenv.io();

    try events.install(alloc);
    defer events.deinstall();
    const sub = try events.hub().?.subscribe();

    // CLI run/chat never assign the hook.
    obs_mod.fanout = null;

    const path = try std.fmt.allocPrint(alloc, "{s}/events.jsonl", .{tenv.dir});
    defer alloc.free(path);
    var sink = try obs_mod.JsonlSink.init(alloc, path);
    defer sink.deinit();
    var trace = obs_mod.TraceCtx.start(io, "s", "a");

    sink.emitAt(io, &trace, .info, "agent.started", "{}");
    try std.testing.expectEqual(@as(usize, 0), sink.dropped_events);

    // File written; hub untouched.
    const raw = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        path,
        alloc,
        .limited(1 << 20),
    );
    defer alloc.free(raw);
    try std.testing.expect(std.mem.startsWith(u8, raw, "{\"timestamp_unix_ms\":"));
    try std.testing.expect(sub.take() == null);
    try std.testing.expectEqual(@as(usize, 0), sub.pending());

    events.hub().?.unsubscribe(sub);
}

test "hubPublish without install is a safe no-op" {
    // Singleton currently uninstalled (or torn down by earlier tests).
    events.hubPublish("{\"ghost\":true}");
    try std.testing.expect(events.hub() == null);
}
