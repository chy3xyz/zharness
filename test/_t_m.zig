//! M-backend (wave 5) self-test root — run with:
//!     zig test -lc --dep cordis -Mroot=test/_t_m.zig -Mcordis=../zcordis/src/cordis.zig
//!
//! Covers the wave-5 surface:
//!   - POST /run/stream: SSE frame ordering, tool_call composite splitting,
//!     tool_result truncation, idle heartbeats, error paths + terminal
//!     synthesis, peer-disconnect cancellation, queue backpressure — driven
//!     through the REAL sse_run.serve pump over AF_UNIX socketpairs.
//!   - Session management routes: create/delete/rename lifecycle against
//!     REAL temp-dir fs fakes (session.deleteFile / clib.renamePath), with
//!     404 / 409 / 400 / 501 paths and id-charset guards.
//!   - Regression: old routes untouched (inline api/httpd/session tests are
//!     pulled in via the comptime imports below).
//!
//! Handler-side code runs on worker threads with page_allocator (mirroring
//! httpd's per-connection arena shape; the pump's internal queue uses libc
//! malloc). Single-threaded test logic runs under std.testing.allocator so
//! leaks surface as failures. Top-level placement keeps `../` imports inside
//! the module path; the integrator folds these into src/tests.zig.

const std = @import("std");

comptime {
    _ = @import("../src/server/api.zig");
    _ = @import("../src/server/sse_run.zig");
    _ = @import("../src/server/httpd.zig");
    _ = @import("../src/server/events.zig");
    _ = @import("../src/session/session.zig");
}

const api = @import("../src/server/api.zig");
const sse_run = @import("../src/server/sse_run.zig");
const httpd = @import("../src/server/httpd.zig");
const session_mod = @import("../src/session/session.zig");
const clib = @import("clib.zig");

const testing = std.testing;

// ── socketpair plumbing (offline loopback stand-in for a TCP connection) ───

extern "c" fn read(fd: c_int, buf: [*]u8, nbyte: usize) isize;
extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

fn sleepMs(ms: u64) void {
    const req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&req, null);
}

fn setNoSigPipe(fd: std.posix.socket_t) void {
    if (@import("builtin").os.tag.isDarwin()) {
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

/// Accumulate from the socket until `needle` appears (bounded by RCVTIMEO).
fn readUntil(acc: *std.ArrayList(u8), sp: *const SocketPair, alloc: std.mem.Allocator, needle: []const u8) !void {
    var chunk: [4096]u8 = undefined;
    while (std.mem.indexOf(u8, acc.items, needle) == null) {
        const n = try sp.readSome(&chunk);
        try acc.appendSlice(alloc, chunk[0..n]);
    }
}

/// Assert `needle` occurs at-or-after `pos`, then advance pos past it.
fn assertProgress(body: []const u8, pos: *usize, needle: []const u8) !void {
    const at = std.mem.indexOfPos(u8, body, pos.*, needle) orelse {
        std.debug.print("\n--- received ---\n{s}\n--- missing: {s}\n", .{ body, needle });
        return error.MissingFrame;
    };
    pos.* = at + needle.len;
}

fn makeRequest(alloc: std.mem.Allocator, method: []const u8, target: []const u8, body: []const u8) !httpd.Request {
    var cl_buf: [16]u8 = undefined;
    const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{body.len});
    const raw = try std.fmt.allocPrint(alloc, "{s} {s} HTTP/1.1\r\nHost: t\r\nContent-Length: {s}\r\n\r\n{s}", .{ method, target, cl, body });
    defer alloc.free(raw);
    return httpd.parseRequest(alloc, raw);
}

// ── scripted fake runner (the "integrator side" of RunStreamFn) ────────────

const Step = struct { tag: sse_run.RunEventTag, payload: []const u8 };

const Script = struct {
    steps: []const Step,
    /// Sleep between steps (drives heartbeat/idle tests).
    gap_ms: u64 = 0,
    /// Error returned by runStream AFTER emitting all steps.
    fail_with: ?anyerror = null,
};

fn scriptRun(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    req: sse_run.RunRequest,
    on_event: sse_run.OnEventFn,
    userdata: ?*anyopaque,
) anyerror!void {
    _ = alloc;
    _ = req;
    const sc: *const Script = @ptrCast(@alignCast(ctx.?));
    for (sc.steps, 0..) |s, i| {
        on_event(s.tag, s.payload, userdata);
        // Gap AFTER each step except the last (silence BETWEEN events).
        if (sc.gap_ms > 0 and i + 1 < sc.steps.len) sleepMs(sc.gap_ms);
    }
    if (sc.fail_with) |e| return e;
}

/// Serve one connection on a worker thread (page_allocator like httpd's
/// per-connection arena) and join on scope exit. MUST live in the owning
/// test frame — the spawned thread keeps a pointer to it.
const ServeJob = struct {
    sp: *SocketPair,
    run_fn: sse_run.RunStreamFn,
    run_ctx: ?*anyopaque,
    run_req: sse_run.RunRequest,
    tuning: sse_run.StreamTuning,
    thread: ?std.Thread = null,

    fn body(self: *ServeJob) void {
        var res = httpd.Responder{ .fd = self.sp.w, .alloc = std.heap.page_allocator };
        sse_run.serve(self.run_fn, self.run_ctx, self.run_req, &res, self.tuning) catch {};
    }

    fn start(self: *ServeJob) !void {
        self.thread = try std.Thread.spawn(.{}, ServeJob.body, .{self});
    }

    fn joinAndCleanup(self: *ServeJob) void {
        if (self.thread) |t| t.join();
        self.thread = null;
    }
};

// ── /run/stream: framing + ordering through the real pump ──────────────────

test "run stream emits ordered frames: delta, tool_call, truncated tool_result, done" {
    const alloc = testing.allocator;
    var sp = try SocketPair.init();
    defer sp.deinit();
    sp.setReadTimeout(5);
    setNoSigPipe(sp.w);

    // Runtime-filled oversized output (> tool_output_max_bytes → truncated).
    const big_out = try testing.allocator.alloc(u8, 3072);
    defer testing.allocator.free(big_out);
    @memset(big_out, 'x');
    const steps = [_]Step{
        .{ .tag = .turn_start, .payload = "turn 1" }, // dropped by design
        .{ .tag = .text, .payload = "Hello" },
        .{ .tag = .tool_call, .payload = "shell({\"cmd\":\"ls\"})" },
        .{ .tag = .tool_result, .payload = big_out },
        .{ .tag = .done, .payload = "final answer" },
    };
    var script = Script{ .steps = &steps };

    var job = ServeJob{
        .sp = &sp,
        .run_fn = scriptRun,
        .run_ctx = &script,
        .run_req = .{ .prompt = "hi", .session = "wk1" },
        .tuning = .{ .poll_ms = 5, .heartbeat_after_ms = 60_000 },
    };
    try job.start();
    defer job.joinAndCleanup();

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    try readUntil(&acc, &sp, alloc, "\"answer\":\"final answer\"");

    const body = acc.items;
    try testing.expect(std.mem.startsWith(u8, body, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, body, "Content-Type: text/event-stream\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, ": zharness run stream\n\n") != null);

    var pos: usize = 0;
    // Strict wire order; turn_start produced no frame.
    try assertProgress(body, &pos, "data: {\"type\":\"delta\",\"text\":\"Hello\"}\n\n");
    try assertProgress(body, &pos, "data: {\"type\":\"tool_call\",\"name\":\"shell\",\"args\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}\n\n");

    const want_tr = try sse_run.encodeToolResultFrame(testing.allocator, "shell", big_out);
    defer testing.allocator.free(want_tr);
    var tr_frame_buf: [4200]u8 = undefined;
    const tr_frame = try std.fmt.bufPrint(&tr_frame_buf, "data: {s}\n\n", .{want_tr});
    try assertProgress(body, &pos, tr_frame);

    try assertProgress(body, &pos, "data: {\"type\":\"done\",\"answer\":\"final answer\",\"session\":\"wk1\"}\n\n");

    // No heartbeat within a busy run; nothing after done.
    try testing.expect(std.mem.indexOf(u8, body, ": keep-alive") == null);
    try testing.expect(std.mem.indexOfPos(u8, body, pos, "data: ") == null);
}

test "run stream heartbeats between frames when the run is silent" {
    const alloc = testing.allocator;
    var sp = try SocketPair.init();
    defer sp.deinit();
    sp.setReadTimeout(5);
    setNoSigPipe(sp.w);

    const steps = [_]Step{
        .{ .tag = .text, .payload = "before-gap" },
        .{ .tag = .text, .payload = "after-gap" },
    };
    var script = Script{ .steps = &steps, .gap_ms = 150 };

    var job = ServeJob{
        .sp = &sp,
        .run_fn = scriptRun,
        .run_ctx = &script,
        .run_req = .{ .prompt = "p" },
        .tuning = .{ .poll_ms = 5, .heartbeat_after_ms = 40 },
    };
    try job.start();
    defer job.joinAndCleanup();

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    try readUntil(&acc, &sp, alloc, "after-gap");

    const body = acc.items;
    const at_a = std.mem.indexOf(u8, body, "before-gap").?;
    const at_b = std.mem.indexOf(u8, body, "after-gap").?;
    try testing.expect(at_a < at_b);
    // At least one keep-alive strictly inside the gap window (extra beats
    // before the first frame are legal — the producer starts a beat late).
    const at_beat = std.mem.indexOfPos(u8, body, at_a, ": keep-alive\n\n") orelse return error.MissingHeartbeat;
    try testing.expect(at_beat < at_b);
}

test "err tag ends the stream with exactly one error frame and no done" {
    const alloc = testing.allocator;
    var sp = try SocketPair.init();
    defer sp.deinit();
    sp.setReadTimeout(5);
    setNoSigPipe(sp.w);

    const steps = [_]Step{
        .{ .tag = .text, .payload = "partial" },
        .{ .tag = .err, .payload = "model down" },
    };
    var script = Script{ .steps = &steps, .fail_with = error.ModelDown };

    var job = ServeJob{
        .sp = &sp,
        .run_fn = scriptRun,
        .run_ctx = &script,
        .run_req = .{ .prompt = "p" },
        .tuning = .{ .poll_ms = 5, .heartbeat_after_ms = 60_000 },
    };
    try job.start();
    defer job.joinAndCleanup();

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    try readUntil(&acc, &sp, alloc, "{\"type\":\"error\",\"error\":\"model down\"}");

    // Give the consumer a beat to finish, then count frames.
    sleepMs(50);
    const body = acc.items;
    try testing.expect(std.mem.indexOf(u8, body, "data: {\"type\":\"delta\",\"text\":\"partial\"}") != null);
    var err_frames: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, body, idx, "{\"type\":\"error\"")) |at| {
        err_frames += 1;
        idx = at + 1;
    }
    try testing.expectEqual(@as(usize, 1), err_frames); // no synthesized duplicate
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"done\"") == null);
}

test "silent successful run synthesizes an explanatory error frame" {
    const alloc = testing.allocator;
    var sp = try SocketPair.init();
    defer sp.deinit();
    sp.setReadTimeout(5);
    setNoSigPipe(sp.w);

    var script = Script{ .steps = &.{} };
    var job = ServeJob{
        .sp = &sp,
        .run_fn = scriptRun,
        .run_ctx = &script,
        .run_req = .{ .prompt = "p" },
        .tuning = .{ .poll_ms = 5, .heartbeat_after_ms = 60_000 },
    };
    try job.start();
    defer job.joinAndCleanup();

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    try readUntil(&acc, &sp, alloc, "run ended without a done event");
}

test "failing run without events synthesizes the error name" {
    const alloc = testing.allocator;
    var sp = try SocketPair.init();
    defer sp.deinit();
    sp.setReadTimeout(5);
    setNoSigPipe(sp.w);

    var script = Script{ .steps = &.{}, .fail_with = error.ModelDown };
    var job = ServeJob{
        .sp = &sp,
        .run_fn = scriptRun,
        .run_ctx = &script,
        .run_req = .{ .prompt = "p" },
        .tuning = .{ .poll_ms = 5, .heartbeat_after_ms = 60_000 },
    };
    try job.start();
    defer job.joinAndCleanup();

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    try readUntil(&acc, &sp, alloc, "data: {\"type\":\"error\",\"error\":\"ModelDown\"}\n\n");
}

test "peer disconnect cancels the producer and serve returns promptly" {
    const alloc = testing.allocator;
    var sp = try SocketPair.init();
    defer sp.deinit();
    sp.setReadTimeout(5);
    setNoSigPipe(sp.w);

    const steps = [_]Step{
        .{ .tag = .text, .payload = "one" },
        .{ .tag = .text, .payload = "two" },
        .{ .tag = .text, .payload = "three" },
        .{ .tag = .text, .payload = "four" },
        .{ .tag = .text, .payload = "five" },
        .{ .tag = .text, .payload = "six" },
    };
    var script = Script{ .steps = &steps, .gap_ms = 25 };

    var job = ServeJob{
        .sp = &sp,
        .run_fn = scriptRun,
        .run_ctx = &script,
        .run_req = .{ .prompt = "p" },
        .tuning = .{ .poll_ms = 5, .heartbeat_after_ms = 60_000 },
    };
    try job.start();
    defer job.joinAndCleanup(); // must return promptly after disconnect, not hang

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    try readUntil(&acc, &sp, alloc, "\"one\""); // first delta arrived

    sp.closeReader(); // client hangs up mid-run; cancel + drop path engages
}

test "queue backpressure under high water keeps every frame in order" {
    const alloc = testing.allocator;
    var sp = try SocketPair.init();
    defer sp.deinit();
    sp.setReadTimeout(5);
    setNoSigPipe(sp.w);

    var steps: [24]Step = undefined;
    for (&steps, 0..) |*s, i| {
        s.* = .{ .tag = .text, .payload = try std.fmt.bufPrint(&name_store[i], "chunk-{d}", .{i}) };
    }
    var script = Script{ .steps = &steps }; // rapid-fire, zero gaps

    var job = ServeJob{
        .sp = &sp,
        .run_fn = scriptRun,
        .run_ctx = &script,
        .run_req = .{ .prompt = "p" },
        .tuning = .{ .poll_ms = 5, .heartbeat_after_ms = 60_000, .queue_high_water = 2 },
    };
    try job.start();

    // Reader deliberately starts late: producer parks on high water meanwhile.
    sleepMs(80);
    defer job.joinAndCleanup();

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    try readUntil(&acc, &sp, alloc, "chunk-23");

    var pos: usize = 0;
    for (0..steps.len) |i| {
        var needle_buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "data: {{\"type\":\"delta\",\"text\":\"chunk-{d}\"}}\n\n", .{i});
        try assertProgress(acc.items, &pos, needle);
    }
}

var name_store: [24][16]u8 = undefined;

// ── /run/stream through the FULL api.handle dispatch ───────────────────────

test "api.handle dispatches POST /run/stream end-to-end; missing prompt is 400" {
    const heap = std.heap.page_allocator;

    const deps = try heap.create(api.ServerDeps);
    defer heap.destroy(deps);
    deps.* = .{
        .ctx = null,
        .runTask = neverBuffered,
        .listSessions = neverList,
        .getSession = neverGet,
        .runStream = scriptRunHandle,
    };

    var sp = try SocketPair.init();
    defer sp.deinit();
    sp.setReadTimeout(5);
    setNoSigPipe(sp.w);

    const raw_body = "{\"prompt\":\"say hi\",\"session\":\"sx\"}";
    var req = blk: {
        const raw = try std.fmt.allocPrint(heap, "POST /run/stream HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}", .{ raw_body.len, raw_body });
        defer heap.free(raw);
        break :blk try httpd.parseRequest(heap, raw);
    };
    defer req.deinit(heap);

    const Worker = struct {
        fn run(d: *api.ServerDeps, al: std.mem.Allocator, rq: *const httpd.Request, rs: *httpd.Responder) void {
            api.handle(d, al, rq, rs) catch {};
        }
    };
    var res = httpd.Responder{ .fd = sp.w, .alloc = heap };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{ deps, heap, &req, &res });

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(testing.allocator);
    try readUntil(&acc, &sp, testing.allocator, "\"answer\":\"echo:say hi\",\"session\":\"sx\"");
    worker.join();

    const body = acc.items;
    try testing.expect(std.mem.startsWith(u8, body, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, body, ": zharness run stream\n\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "data: {\"type\":\"delta\",\"text\":\"echo:say hi\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "data: {\"type\":\"done\",\"answer\":\"echo:say hi\",\"session\":\"sx\"}") != null);

    // Missing prompt: buffered 400 before any SSE head.
    var sp2 = try SocketPair.init();
    defer sp2.deinit();
    sp2.setReadTimeout(5);
    setNoSigPipe(sp2.w);
    const bad_body = "{}";
    var bad_req = blk: {
        const raw = try std.fmt.allocPrint(heap, "POST /run/stream HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}", .{ bad_body.len, bad_body });
        defer heap.free(raw);
        break :blk try httpd.parseRequest(heap, raw);
    };
    defer bad_req.deinit(heap);
    var res2 = httpd.Responder{ .fd = sp2.w, .alloc = heap };
    try api.handle(deps, heap, &bad_req, &res2);

    var acc2: std.ArrayList(u8) = .empty;
    defer acc2.deinit(testing.allocator);
    try readUntil(&acc2, &sp2, testing.allocator, "missing prompt");
    try testing.expect(std.mem.startsWith(u8, acc2.items, "HTTP/1.1 400 Bad Request\r\n"));
}

/// Handle-level runner: echoes the prompt as one delta then done.
fn scriptRunHandle(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    req: sse_run.RunRequest,
    on_event: sse_run.OnEventFn,
    userdata: ?*anyopaque,
) anyerror!void {
    _ = ctx;
    _ = alloc;
    const echoed = try std.fmt.allocPrint(std.heap.page_allocator, "echo:{s}", .{req.prompt});
    defer std.heap.page_allocator.free(echoed);
    on_event(.text, echoed, userdata);
    on_event(.done, echoed, userdata);
}

fn neverBuffered(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
    return error.UnreachableRoute;
}
fn neverList(_: ?*anyopaque, _: std.mem.Allocator) anyerror![]api.ServerDeps.SessionSummary {
    return error.UnreachableRoute;
}
fn neverGet(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?api.ServerDeps.SessionDetail {
    return error.UnreachableRoute;
}

// ── temp-dir environment for real-fs session lifecycle tests ───────────────

extern "c" fn time(tloc: ?*c_long) c_long;

var tm_counter: u32 = 0;

const TempRoot = struct {
    io_threaded: std.Io.Threaded,
    root: []u8,

    fn setup() !TempRoot {
        tm_counter += 1;
        var self = TempRoot{
            .io_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{}),
            .root = undefined,
        };
        errdefer self.teardown();
        self.root = try std.fmt.allocPrint(testing.allocator, "/tmp/zh_m_{d}_{d}", .{ time(null), tm_counter });
        // Create <root>/.zharness/sessions and <root>/.zharness/checkpoints.
        try self.mkdir(".zharness");
        try self.mkdir(".zharness/sessions");
        try self.mkdir(".zharness/checkpoints");
        return self;
    }

    fn io(self: *TempRoot) std.Io {
        return self.io_threaded.io();
    }

    fn mkdir(self: *TempRoot, rel: []const u8) !void {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.root, rel });
        defer testing.allocator.free(p);
        try std.Io.Dir.createDirPath(.cwd(), self.io(), p);
    }

    fn path(self: *TempRoot, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
        const rel = try std.fmt.allocPrint(alloc, fmt, args);
        defer alloc.free(rel);
        return self.join(alloc, rel);
    }

    fn join(self: *TempRoot, alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.root, rel });
    }

    fn exists(self: *TempRoot, p: []const u8) bool {
        _ = std.Io.Dir.statFile(.cwd(), self.io(), p, .{}) catch return false;
        return true;
    }

    fn teardown(self: *TempRoot) void {
        defer self.io_threaded.deinit();
        const slash = std.mem.lastIndexOfScalar(u8, self.root, '/') orelse return;
        const parent = std.Io.Dir.openDir(.cwd(), self.io(), self.root[0..slash], .{}) catch return;
        defer std.Io.Dir.close(parent, self.io());
        std.Io.Dir.deleteTree(parent, self.io(), self.root[slash + 1 ..]) catch {};
        testing.allocator.free(self.root);
    }
};

/// Fake session-management deps backed by the real filesystem — the same
/// shape main.zig will wire (stat-first 404s, session.deleteFile,
/// clib.renamePath, formatMintedSessionId minting).
const FsState = struct {
    io: std.Io,
    root: *TempRoot,

    fn sessionsPath(st: *FsState, alloc: std.mem.Allocator, id: []const u8) ![]u8 {
        return st.root.path(alloc, ".zharness/sessions/{s}.json", .{id});
    }

    fn fsCreate(ctx: ?*anyopaque, alloc: std.mem.Allocator, id: ?[]const u8) anyerror![]const u8 {
        const st: *FsState = @ptrCast(@alignCast(ctx.?));
        var chosen_buf: [40]u8 = undefined;
        const chosen: []const u8 = id orelse api.formatMintedSessionId(&chosen_buf, clib.nowTimestamp());
        if (!api.validSessionId(chosen)) return error.InvalidSessionId;
        const p = try st.sessionsPath(alloc, chosen);
        defer alloc.free(p);
        if (st.root.exists(p)) return error.SessionExists;
        std.Io.Dir.writeFile(.cwd(), st.io, .{ .sub_path = p, .data = "" }) catch return error.WriteFailed;
        return alloc.dupe(u8, chosen);
    }

    fn fsDelete(ctx: ?*anyopaque, alloc: std.mem.Allocator, id: []const u8) anyerror!void {
        const st: *FsState = @ptrCast(@alignCast(ctx.?));
        if (!api.validSessionId(id)) return error.InvalidSessionId;
        const p = try st.sessionsPath(alloc, id);
        defer alloc.free(p);
        if (!st.root.exists(p)) return error.SessionNotFound;
        if (!session_mod.Session.deleteFile(st.io, p)) return error.WriteFailed;
        // Best-effort per-session checkpoint dir removal (usually absent).
        const cp = try st.root.path(alloc, ".zharness/checkpoints/{s}", .{id});
        defer alloc.free(cp);
        deleteTreeBestEffort(st.io, cp);
    }

    fn fsRename(ctx: ?*anyopaque, alloc: std.mem.Allocator, old_id: []const u8, new_id: []const u8) anyerror!void {
        const st: *FsState = @ptrCast(@alignCast(ctx.?));
        if (!api.validSessionId(old_id) or !api.validSessionId(new_id)) return error.InvalidSessionId;
        const op = try st.sessionsPath(alloc, old_id);
        defer alloc.free(op);
        const np = try st.sessionsPath(alloc, new_id);
        defer alloc.free(np);
        if (!st.root.exists(op)) return error.SessionNotFound;
        if (st.root.exists(np)) return error.SessionExists;
        if (!clib.renamePath(op, np)) return error.WriteFailed;
    }
};

fn deleteTreeBestEffort(io: std.Io, abs_path: []const u8) void {
    const slash = std.mem.lastIndexOfScalar(u8, abs_path, '/') orelse return;
    const parent = std.Io.Dir.openDir(.cwd(), io, abs_path[0..slash], .{}) catch return;
    defer std.Io.Dir.close(parent, io);
    std.Io.Dir.deleteTree(parent, io, abs_path[slash + 1 ..]) catch {};
}

fn makeLifecycleDeps(fs: *FsState) api.ServerDeps {
    return .{
        .ctx = fs,
        .runTask = neverBuffered,
        .listSessions = neverList,
        .getSession = neverGet,
        .deleteSession = FsState.fsDelete,
        .renameSession = FsState.fsRename,
        .createSession = FsState.fsCreate,
    };
}

test "session lifecycle: create explicit + minted, delete removes file and checkpoint tree" {
    var root = try TempRoot.setup();
    defer root.teardown();
    var fs = FsState{ .io = root.io(), .root = &root };
    const deps = makeLifecycleDeps(&fs);
    const alloc = testing.allocator;

    // CREATE explicit id.
    var req_c = try makeRequest(alloc, "POST", "/sessions", "{\"id\":\"alpha\"}");
    defer req_c.deinit(alloc);
    var rc = try api.route(&deps, alloc, &req_c);
    defer rc.deinit(alloc);
    try testing.expectEqual(httpd.Status.ok, rc.status);
    try testing.expectEqualStrings("{\"ok\":true,\"id\":\"alpha\"}", rc.body);
    const alpha_path = try root.join(alloc, ".zharness/sessions/alpha.json");
    defer alloc.free(alpha_path);
    try testing.expect(root.exists(alpha_path));

    // CREATE minted id (web-YYYYMMDD-HHMMSS shape).
    var req_m = try makeRequest(alloc, "POST", "/sessions", "{}");
    defer req_m.deinit(alloc);
    var rm = try api.route(&deps, alloc, &req_m);
    defer rm.deinit(alloc);
    try testing.expectEqual(httpd.Status.ok, rm.status);
    try testing.expect(std.mem.startsWith(u8, rm.body, "{\"ok\":true,\"id\":\"web-"));
    try testing.expectEqual(@as(usize, "{\"ok\":true,\"id\":\"web-YYYYMMDD-HHMMSS\"}".len), rm.body.len);
    // Digits where digits belong.
    for (rm.body["{\"ok\":true,\"id\":\"web-".len .. rm.body.len - "\"}".len]) |c| {
        try testing.expect(c == '-' or std.ascii.isDigit(c));
    }

    // CREATE collision → 409.
    var rc2 = try api.route(&deps, alloc, &req_c);
    defer rc2.deinit(alloc);
    try testing.expectEqual(httpd.Status.conflict, rc2.status);

    // CREATE invalid id → 400 (dep rejects; route would too).
    var req_bad = try makeRequest(alloc, "POST", "/sessions", "{\"id\":\"a/b\"}");
    defer req_bad.deinit(alloc);
    var rb = try api.route(&deps, alloc, &req_bad);
    defer rb.deinit(alloc);
    try testing.expectEqual(httpd.Status.bad_request, rb.status);

    // Seed a per-session checkpoint artifact to prove DELETE clears it.
    const cp_dir = try root.join(alloc, ".zharness/checkpoints/alpha");
    defer alloc.free(cp_dir);
    try std.Io.Dir.createDirPath(.cwd(), root.io(), cp_dir);
    const cp_file = try root.join(alloc, ".zharness/checkpoints/alpha/000001.json");
    defer alloc.free(cp_file);
    try std.Io.Dir.writeFile(.cwd(), root.io(), .{ .sub_path = cp_file, .data = "[]" });

    // DELETE existing → ok, transcript AND checkpoint tree gone.
    var req_d = try makeRequest(alloc, "DELETE", "/sessions/alpha", "");
    defer req_d.deinit(alloc);
    var rd = try api.route(&deps, alloc, &req_d);
    defer rd.deinit(alloc);
    try testing.expectEqual(httpd.Status.ok, rd.status);
    try testing.expectEqualStrings("{\"ok\":true}", rd.body);
    try testing.expect(!root.exists(alpha_path));
    try testing.expect(!root.exists(cp_file));

    // DELETE missing → 404; DELETE bad id → 400.
    var rd2 = try api.route(&deps, alloc, &req_d);
    defer rd2.deinit(alloc);
    try testing.expectEqual(httpd.Status.not_found, rd2.status);
    try testing.expectEqualStrings("{\"ok\":false,\"error\":\"session not found\"}", rd2.body);

    var req_dbad = try makeRequest(alloc, "DELETE", "/sessions/no%2Fslash", "");
    defer req_dbad.deinit(alloc);
    var rdb = try api.route(&deps, alloc, &req_dbad);
    defer rdb.deinit(alloc);
    try testing.expectEqual(httpd.Status.bad_request, rdb.status);
}

test "session rename lifecycle incl 404 source, 409 collision, 400 ids" {
    var root = try TempRoot.setup();
    defer root.teardown();
    var fs = FsState{ .io = root.io(), .root = &root };
    const deps = makeLifecycleDeps(&fs);
    const alloc = testing.allocator;

    // Seed two sessions.
    for ([_][]const u8{ "old", "taken" }) |sid| {
        const p = try root.path(alloc, ".zharness/sessions/{s}.json", .{sid});
        defer alloc.free(p);
        try std.Io.Dir.writeFile(.cwd(), root.io(), .{ .sub_path = p, .data = "[]" });
    }

    const old_path = try root.join(alloc, ".zharness/sessions/old.json");
    defer alloc.free(old_path);
    const renamed_path = try root.join(alloc, ".zharness/sessions/renamed.json");
    defer alloc.free(renamed_path);

    // Happy rename.
    var req_r = try makeRequest(alloc, "PATCH", "/sessions/old", "{\"rename\":\"renamed\"}");
    defer req_r.deinit(alloc);
    var rr = try api.route(&deps, alloc, &req_r);
    defer rr.deinit(alloc);
    try testing.expectEqual(httpd.Status.ok, rr.status);
    try testing.expectEqualStrings("{\"ok\":true,\"id\":\"renamed\"}", rr.body);
    try testing.expect(!root.exists(old_path));
    try testing.expect(root.exists(renamed_path));

    // Re-running the same rename: source is gone now → 404.
    var rr2 = try api.route(&deps, alloc, &req_r);
    defer rr2.deinit(alloc);
    try testing.expectEqual(httpd.Status.not_found, rr2.status);

    var req_col = try makeRequest(alloc, "PATCH", "/sessions/renamed", "{\"rename\":\"taken\"}");
    defer req_col.deinit(alloc);
    var rc = try api.route(&deps, alloc, &req_col);
    defer rc.deinit(alloc);
    try testing.expectEqual(httpd.Status.conflict, rc.status);
    try testing.expectEqualStrings("{\"ok\":false,\"error\":\"session id already exists\"}", rc.body);

    // Same-id rename short-circuits to 409 at the route layer.
    var req_self = try makeRequest(alloc, "PATCH", "/sessions/renamed", "{\"rename\":\"renamed\"}");
    defer req_self.deinit(alloc);
    var rs = try api.route(&deps, alloc, &req_self);
    defer rs.deinit(alloc);
    try testing.expectEqual(httpd.Status.conflict, rs.status);

    // Missing rename field → 400.
    var req_nofield = try makeRequest(alloc, "PATCH", "/sessions/renamed", "{}");
    defer req_nofield.deinit(alloc);
    var rf = try api.route(&deps, alloc, &req_nofield);
    defer rf.deinit(alloc);
    try testing.expectEqual(httpd.Status.bad_request, rf.status);

    // Bad new id chars → 400.
    var req_badnew = try makeRequest(alloc, "PATCH", "/sessions/renamed", "{\"rename\":\"spa ce\"}");
    defer req_badnew.deinit(alloc);
    var rb = try api.route(&deps, alloc, &req_badnew);
    defer rb.deinit(alloc);
    try testing.expectEqual(httpd.Status.bad_request, rb.status);

    // Missing SOURCE id (route-valid charset, absent on disk) → 404.
    var req_missing = try makeRequest(alloc, "PATCH", "/sessions/ghost", "{\"rename\":\"fresh\"}");
    defer req_missing.deinit(alloc);
    var rg = try api.route(&deps, alloc, &req_missing);
    defer rg.deinit(alloc);
    try testing.expectEqual(httpd.Status.not_found, rg.status);
}

test "session routes without deps wired answer 501; GET validates id charset" {
    const alloc = testing.allocator;
    const plain = api.ServerDeps{
        .ctx = null,
        .runTask = neverBuffered,
        .listSessions = neverList,
        .getSession = neverGet,
    };

    var del = try makeRequest(alloc, "DELETE", "/sessions/whatever", "");
    defer del.deinit(alloc);
    var r1 = try api.route(&plain, alloc, &del);
    defer r1.deinit(alloc);
    try testing.expectEqual(httpd.Status.not_implemented, r1.status);

    var pat = try makeRequest(alloc, "PATCH", "/sessions/whatever", "{\"rename\":\"x\"}");
    defer pat.deinit(alloc);
    var r2 = try api.route(&plain, alloc, &pat);
    defer r2.deinit(alloc);
    try testing.expectEqual(httpd.Status.not_implemented, r2.status);

    var cre = try makeRequest(alloc, "POST", "/sessions", "{}");
    defer cre.deinit(alloc);
    var r3 = try api.route(&plain, alloc, &cre);
    defer r3.deinit(alloc);
    try testing.expectEqual(httpd.Status.not_implemented, r3.status);

    // GET keeps working but now hard-rejects path-traversal-ish ids.
    var evil = try makeRequest(alloc, "GET", "/sessions/..%2F..%2Fetc", "");
    defer evil.deinit(alloc);
    var r4 = try api.route(&plain, alloc, &evil);
    defer r4.deinit(alloc);
    try testing.expectEqual(httpd.Status.bad_request, r4.status);
}

test "Session.deleteFile true only when present" {
    var root = try TempRoot.setup();
    defer root.teardown();
    const io = root.io();
    const alloc = testing.allocator;

    const p = try root.join(alloc, "scratch.txt");
    defer alloc.free(p);
    try testing.expect(!session_mod.Session.deleteFile(io, p)); // absent → false

    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = p, .data = "bye" });
    try testing.expect(session_mod.Session.deleteFile(io, p)); // present → true
    try testing.expect(!root.exists(p));
    try testing.expect(!session_mod.Session.deleteFile(io, p)); // already gone
}
