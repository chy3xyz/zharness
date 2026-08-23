//! Streaming agent runs over Server-Sent Events — the engine behind
//! POST /run/stream (wave 5, dev.md §XXIII extension).
//!
//! Contract:
//! - sse_run.zig owns FRAMING + PUMPING only. It never touches the agent
//!   runtime: the actual work arrives through a `RunStreamFn` dependency
//!   (installed on `ServerDeps.runStream` by main.zig), keeping this module
//!   decoupled from main/cordis and testable with fake runners.
//! - Wire format: one JSON object per bare `data:` line (WHATWG default
//!   event), flushed immediately per frame:
//!       {"type":"delta","text":"…"}                     assistant text chunk
//!       {"type":"thinking","text":"…"}                  reasoning chunk (optional passthrough)
//!       {"type":"tool_call","name":"…","args":"…"}
//!       {"type":"tool_result","name":"…","output":"…","truncated":bool}
//!       {"type":"done","answer":"…full final text…","session":"…"|null}
//!       {"type":"error","error":"…"}
//!   Clients MUST ignore frame types they do not know. Tool output is
//!   truncated to `tool_output_max_bytes` (2048) on a UTF-8 boundary and the
//!   `truncated` flag says so. Between frames, when nothing has been written
//!   for `StreamTuning.heartbeat_after_ms`, the pump emits a `: keep-alive`
//!   comment so proxies and clients can tell idle from dead.
//!
//! ── RUNEVENT CONTRACT FOR THE INTEGRATOR (main.zig) ───────────────────────
//!
//! Implement `ServerDeps.runStream` by driving ONE agent run and forwarding
//! its events through the callback. The bridge from AgentLoop's on_event
//! (src/agent/agent.zig EventKind) is mechanical — tags map 1:1:
//!
//!   fn runStreamBridge(kind: agent.AgentLoop.EventKind, payload: []const u8, ud: ?*anyopaque) void {
//!       const tag: sse_run.RunEventTag = switch (kind) {
//!           .turn_start  => .turn_start,   // dropped by the pump (see below)
//!           .thinking    => .thinking,
//!           .text        => .text,         // becomes the "delta" frame
//!           .tool_call   => .tool_call,
//!           .tool_result => .tool_result,
//!           .done        => .done,
//!           .err         => .err,
//!       };
//!       forwardToPump(tag, payload, ud);
//!   }
//!
//! Payload shapes (all BORROWED — valid only during the callback; the pump
//! copies what it forwards):
//!   turn_start  : "turn N" human label. Dropped by the pump today (the
//!                 frontend has no frame for it); forwarded anyway so the
//!                 bridge stays total and future-proof.
//!   thinking    : raw reasoning text chunk.
//!   text        : raw assistant text chunk (whole message when the transport
//!                 did not stream deltas).
//!   tool_call   : the EXACT composite AgentLoop.emit formats:
//!                 "<name>(<arguments>)". The pump splits it at the FIRST '('
//!                 and strips the trailing ')' — deterministic for tool names
//!                 (names cannot contain parens). Unparseable composites
//!                 degrade to name=<whole payload>, args="".
//!   tool_result : raw tool output text. The NAME is not present in the
//!                 agent's payload; the pump pairs each result with the most
//!                 recent preceding tool_call (AgentLoop executes calls
//!                 strictly sequentially: call A, result A, call B, …), so
//!                 the emitted tool_result frame carries that call's name.
//!   done        : the FULL final answer text. Emitted exactly once on
//!                 success, as the LAST event; nothing may follow it.
//!   err         : human-readable error message. After an err event the run
//!                 aborts; the stream therefore ends with the error frame and
//!                 NO done frame.
//!
//! If runStream returns an error WITHOUT having delivered a done/err frame,
//! the pump synthesizes {"type":"error","error":"<@errorName>"}; if it
//! returns normally without any terminal frame the synthesized message is
//! "run ended without a done event". This keeps half-wired integrations
//! honest instead of hanging the client.
//!
//! ── THREADING + ALLOCATOR CONTRACT (read before wiring!) ──────────────────
//!
//! SERIALIZATION: agent runs share process-global state (the DebugAllocator
//! is NOT thread-safe), while HTTP connections are concurrent
//! (threaded_connections = true). The runStream implementation MUST hold the
//! SAME process-wide run mutex that the buffered runTask path holds, e.g.:
//!
//!     var g_run_mutex: std.Thread.Mutex = .{};
//!
//!     fn serveRunStream(...) anyerror!void {
//!         g_run_mutex.lock();
//!         defer g_run_mutex.unlock();
//!         ... drive one AgentLoop run, forwarding events ...
//!     }
//!
//! Consequence (documented on the routes): /run and /run/stream QUEUE behind
//! each other — at most one agent run is active at a time; concurrent SSE
//! connections merely wait their turn. Heartbeats during the wait come from
//! the pump's idle timer, so queued clients stay visibly alive.
//!
//! CANCELLATION: when the HTTP peer disconnects, the pump sets a cancel flag
//! that suppresses further event forwarding BETWEEN events. A run blocked
//! inside a model request cannot be interrupted; runStream simply runs to
//! completion and its remaining events are dropped. Implementations may
//! consult nothing else — there is no abort channel by design.
//!
//! ALLOCATORS: the `alloc` argument handed to runStream is the connection's
//! short-lived arena — do NOT store it, do NOT use it for anything that
//! outlives the call. Real implementations should allocate run state from
//! their own long-lived allocator (mirror main.zig's ServeState pattern).
//! The pump's internal queue uses libc malloc (thread-safe, independent of
//! every arena) and frees every frame it creates.
//!
//! WIRING SKETCH (cmdServe):
//!     deps.* = .{
//!         .ctx = st,
//!         .runTask      = serveRunTask,       // unchanged buffered path
//!         .listSessions = serveListSessions,
//!         .getSession   = serveGetSession,
//!         .runStream      = serveRunStream,   // NEW — see contract above
//!         .deleteSession  = serveDeleteSession,
//!         .renameSession  = serveRenameSession,
//!         .createSession  = serveCreateSession,
//!     };
//!
//! deleteSession semantics for the integrator: unlink
//! `<cwd>/.zharness/sessions/<id>.json` (stat first so a missing file maps to
//! error.SessionNotFound → 404) and best-effort removeTree
//! `<cwd>/.zharness/checkpoints/<id>/` when present. Today's CheckpointStore
//! uses one flat shared directory, so the tree removal is usually a no-op —
//! it future-proofs per-session checkpoint dirs without harming anything.

const std = @import("std");
const httpd = @import("httpd.zig");
const events = @import("events.zig");

// ── limits + defaults ───────────────────────────────────────────────────────

/// Tool outputs longer than this are cut (UTF-8-safe) inside the tool_result
/// frame; the `truncated` flag tells the client.
pub const tool_output_max_bytes: usize = 2 * 1024;

// ── public surface ──────────────────────────────────────────────────────────

/// Mirror of AgentLoop.EventKind (see header for the 1:1 bridge).
pub const RunEventTag = enum {
    turn_start,
    thinking,
    text,
    tool_call,
    tool_result,
    done,
    err,
};

/// Per-run parameters parsed from the POST /run/stream JSON body.
/// All slices borrow the caller's memory for the duration of the run call.
pub const RunRequest = struct {
    prompt: []const u8,
    /// Optional persisted session to resume/persist (same semantics as the
    /// buffered /run `session` field).
    session: ?[]const u8 = null,
    /// Optional preset override; the implementation decides how (or whether)
    /// to honor it — api.zig only relays it.
    preset: ?[]const u8 = null,
    /// Optional sandbox-mode override relayed verbatim.
    sandbox: ?[]const u8 = null,
};

/// Free a RunRequest produced by `parseRunRequest`.
pub fn freeRunRequest(alloc: std.mem.Allocator, req: *RunRequest) void {
    alloc.free(req.prompt);
    if (req.session) |s| alloc.free(s);
    if (req.preset) |p| alloc.free(p);
    if (req.sandbox) |s| alloc.free(s);
    req.* = .{ .prompt = &.{} };
}

/// Event sink handed to RunStreamFn. Called synchronously on the runner's
/// thread, in emission order, before runStream returns. `payload` is
/// borrowed for the duration of the call only.
pub const OnEventFn = *const fn (tag: RunEventTag, payload: []const u8, userdata: ?*anyopaque) void;

/// Streaming twin of ServerDeps.runTask. See the header contract: serialize
/// behind the shared run mutex, forward events via `on_event`, return when
/// the run finished (after `done`/`err`).
pub const RunStreamFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    req: RunRequest,
    on_event: OnEventFn,
    userdata: ?*anyopaque,
) anyerror!void;

/// Cadence knobs. Production passes the defaults; tests shrink them.
pub const StreamTuning = struct {
    /// Consumer poll interval while the queue is empty.
    poll_ms: u64 = 50,
    /// Emit a `: keep-alive` comment after this much silence on the wire.
    heartbeat_after_ms: u64 = 15_000,
    /// Producer blocks (backpressure) once this many frames are queued.
    queue_high_water: usize = 256,
};

// ── pure frame encoders (unit-testable, no sockets) ─────────────────────────

/// delta / thinking frames: {"type":<kind>,"text":"<escaped>"}
pub fn encodeTextFrame(alloc: std.mem.Allocator, kind: []const u8, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"");
    try out.appendSlice(alloc, kind);
    try out.appendSlice(alloc, "\",\"text\":\"");
    try jsonEscape(alloc, text, &out);
    try out.appendSlice(alloc, "\"}");
    return out.toOwnedSlice(alloc);
}

/// tool_call frame from the split composite: {"type":"tool_call","name":…,"args":…}
pub fn encodeToolCallFrame(alloc: std.mem.Allocator, name: []const u8, args: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"tool_call\",\"name\":\"");
    try jsonEscape(alloc, name, &out);
    try out.appendSlice(alloc, "\",\"args\":\"");
    try jsonEscape(alloc, args, &out);
    try out.appendSlice(alloc, "\"}");
    return out.toOwnedSlice(alloc);
}

/// tool_result frame: name inherited from the paired tool_call, output cut
/// to `tool_output_max_bytes`.
pub fn encodeToolResultFrame(alloc: std.mem.Allocator, name: []const u8, output: []const u8) ![]u8 {
    const cut = truncateUtf8(output, tool_output_max_bytes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"tool_result\",\"name\":\"");
    try jsonEscape(alloc, name, &out);
    try out.appendSlice(alloc, "\",\"output\":\"");
    try jsonEscape(alloc, cut.slice, &out);
    try out.print(alloc, "\",\"truncated\":{}}}", .{cut.truncated});
    return out.toOwnedSlice(alloc);
}

/// Terminal success frame; echoes the session the run was bound to.
pub fn encodeDoneFrame(alloc: std.mem.Allocator, answer: []const u8, session: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"done\",\"answer\":\"");
    try jsonEscape(alloc, answer, &out);
    try out.appendSlice(alloc, "\",\"session\":");
    if (session) |sid| {
        try out.append(alloc, '"');
        try jsonEscape(alloc, sid, &out);
        try out.append(alloc, '"');
    } else {
        try out.appendSlice(alloc, "null");
    }
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

pub fn encodeErrorFrame(alloc: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"error\",\"error\":\"");
    try jsonEscape(alloc, message, &out);
    try out.appendSlice(alloc, "\"}");
    return out.toOwnedSlice(alloc);
}

/// Split AgentLoop's "<name>(<arguments>)" tool_call composite at the FIRST
/// '(' and strip ONE trailing ')'. Names cannot contain parens, so this is
/// deterministic; malformed composites degrade gracefully.
pub fn splitToolComposite(payload: []const u8) struct { name: []const u8, args: []const u8 } {
    const open = std.mem.indexOfScalar(u8, payload, '(') orelse
        return .{ .name = payload, .args = "" };
    const rest = payload[open + 1 ..];
    const args = if (std.mem.endsWith(u8, rest, ")")) rest[0 .. rest.len - 1] else rest;
    return .{ .name = payload[0..open], .args = args };
}

const Truncation = struct { slice: []const u8, truncated: bool };

/// Cut `s` to at most `max_bytes` WITHOUT splitting a UTF-8 sequence: back
/// off continuation bytes (10xxxxxx), then a lone multi-byte leader that
/// would lose its tail. ASCII inputs always cut exactly at max_bytes.
fn truncateUtf8(s: []const u8, max_bytes: usize) Truncation {
    if (s.len <= max_bytes) return .{ .slice = s, .truncated = false };
    var end = max_bytes;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    // A leader byte (11xxxxxx) immediately before the cut started a sequence
    // that no longer fits — drop it too.
    if (end > 0 and (s[end - 1] & 0xC0) == 0xC0) end -= 1;
    return .{ .slice = s[0..end], .truncated = true };
}

// ── request-body parsing (private copies of the api.zig helpers: keeps this
//    module import-clean — api.zig imports sse_run for ServerDeps types) ────

/// Parse a POST /run/stream JSON body. All string fields are freshly
/// allocated escape-decoded copies; release with `freeRunRequest`.
pub fn parseRunRequest(alloc: std.mem.Allocator, body: []const u8) !RunRequest {
    const prompt = (try jsonStringField(alloc, body, "prompt")) orelse return error.MissingPrompt;
    errdefer alloc.free(prompt);
    const session = try jsonStringField(alloc, body, "session");
    errdefer if (session) |s| alloc.free(s);
    const preset = try jsonStringField(alloc, body, "preset");
    errdefer if (preset) |p| alloc.free(p);
    const sandbox = try jsonStringField(alloc, body, "sandbox");
    errdefer if (sandbox) |s| alloc.free(s);
    return .{ .prompt = prompt, .session = session, .preset = preset, .sandbox = sandbox };
}

fn jsonEscape(alloc: std.mem.Allocator, input: []const u8, buf: *std.ArrayList(u8)) !void {
    for (input) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
}

/// Same extractor shape as server/api.zig's jsonStringField (kept local to
/// avoid a circular import; api.zig imports THIS file for ServerDeps types).
fn jsonStringField(alloc: std.mem.Allocator, obj: []const u8, key: []const u8) !?[]u8 {
    var nbuf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&nbuf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = pos + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) : (i += 1) {}
    if (i >= obj.len or obj[i] != '"') return null;
    i += 1;
    const vs = i;
    while (i < obj.len) : (i += 1) {
        if (obj[i] == '\\') {
            if (i + 1 >= obj.len) return null;
            i += 1;
            continue;
        }
        if (obj[i] == '"') {
            // Reuse the api-layer decoder via a tiny local unescape.
            return try unescapeSimple(alloc, obj[vs..i]);
        }
    }
    return null;
}

fn unescapeSimple(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            switch (input[i]) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                '/' => try out.append(alloc, '/'),
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                't' => try out.append(alloc, '\t'),
                'b' => try out.append(alloc, 0x08),
                'f' => try out.append(alloc, 0x0C),
                'u' => {
                    if (i + 4 < input.len) {
                        const cp = std.fmt.parseInt(u21, input[i + 1 .. i + 5], 16) catch {
                            try out.append(alloc, 'u');
                            continue;
                        };
                        var ub: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &ub) catch 0;
                        try out.appendSlice(alloc, ub[0..n]);
                        i += 4;
                    } else {
                        try out.append(alloc, 'u');
                    }
                },
                else => try out.append(alloc, input[i]),
            }
        } else {
            try out.append(alloc, input[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

// ── the pump: producer (run) → queue → consumer (socket) ────────────────────
//
// Why a queue at all: frames must flush immediately AND heartbeats must fire
// while the run sits quietly inside a model request. That needs two threads:
// the producer pushes encoded frames, the consumer owns the socket, writes
// frames as they arrive and injects keep-alive comments during silence.
//
// Queue memory comes from libc malloc (c_allocator): thread-safe and fully
// independent of httpd's per-connection arenas, which are NOT safe to touch
// from two threads at once. Every queued entry is freed exactly once — by
// the consumer after the write attempt, or by the drain on any early exit.

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

/// POSIX CLOCK_REALTIME (== 0 on both Linux and Darwin).
extern "c" fn clock_gettime(clk_id: c_int, tp: *std.c.timespec) c_int;

/// Wall-clock milliseconds without an Io handle (std.time.nanoTimestamp no
/// longer exists in 0.17; see obs.zig notes). Only used for IDLE timing, so
/// realtime-clock adjustments are harmless.
fn msNow() u64 {
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(0, &ts);
    const secs: i64 = @intCast(ts.sec);
    const msecs: i64 = @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
    return @intCast(secs *% 1000 +% msecs);
}

fn sleepMs(ms: u64) void {
    const req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&req, null);
}

/// Minimal test-and-set spin lock (same design as server/events.zig): tiny
/// critical sections, contended waiters nap 1 ms.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins >= 16) {
                sleepMs(1);
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

const Entry = union(enum) {
    /// Owned JSON line (one frame), freed by the receiver.
    frame: []u8,
    /// Producer finished; no more frames ever.
    end,
};

/// Shared producer/consumer state. Queue + run_err live behind `lock`;
/// `last_tool_name` is producer-thread-only (bridge sets it in tool_call and
/// reads it in tool_result — strictly sequential on one thread); `cancelled`
/// is atomic.
const PumpState = struct {
    lock: SpinLock = .{},
    qalloc: std.mem.Allocator,
    queue: std.ArrayList(Entry) = .empty,
    cancelled: std.atomic.Value(bool) = .init(false),
    high_water: usize,
    /// Set when runStream itself failed; consumed by the terminal synthesis.
    run_err: ?anyerror = null,
    /// Borrowed from the RunRequest for the lifetime of serve().
    req_session: ?[]const u8 = null,
    /// Producer-owned copy of the latest tool_call name (paired onto
    /// subsequent tool_result frames). Freed in deinit.
    last_tool_name: ?[]u8 = null,

    fn deinit(self: *PumpState) void {
        for (self.queue.items) |e| self.freeEntry(e);
        self.queue.deinit(self.qalloc);
        if (self.last_tool_name) |n| self.qalloc.free(n);
        self.last_tool_name = null;
    }

    fn freeEntry(self: *PumpState, e: Entry) void {
        switch (e) {
            .frame => |line| self.qalloc.free(line),
            .end => {},
        }
    }

    fn isCancelled(self: *PumpState) bool {
        return self.cancelled.load(.acquire);
    }

    /// Producer: enqueue a frame with bounded backpressure. Drops the frame
    /// (frees it) once cancelled — the consumer is gone, nobody will read it.
    fn pushFrame(self: *PumpState, line: []u8) void {
        self.lock.lock();
        while (self.queue.items.len >= self.high_water and !self.isCancelled()) {
            self.lock.unlock();
            sleepMs(2);
            self.lock.lock();
        }
        var drop = self.isCancelled();
        if (!drop) {
            self.queue.append(self.qalloc, .{ .frame = line }) catch {
                drop = true; // OOM: drop the frame rather than the run
            };
        }
        self.lock.unlock();
        if (drop) self.qalloc.free(line);
    }

    /// Producer: terminal marker. Never blocks (bypasses high water) — the
    /// consumer must learn the run ended even amid a backlog.
    fn pushEnd(self: *PumpState) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.isCancelled()) return;
        self.queue.append(self.qalloc, .end) catch {};
    }

    /// Consumer: pop the oldest entry (owned by the caller until freed).
    fn pop(self: *PumpState) ?Entry {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    /// Producer-side: record run failure for the terminal synthesis.
    fn setRunErr(self: *PumpState, e: anyerror) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.run_err = e;
    }

    fn getRunErr(self: *PumpState) ?anyerror {
        self.lock.lock();
        defer self.lock.unlock();
        return self.run_err;
    }

    fn setLastToolName(self: *PumpState, name: []const u8) void {
        const copy = self.qalloc.dupe(u8, name) catch return; // best-effort pairing
        if (self.last_tool_name) |old| self.qalloc.free(old);
        self.last_tool_name = copy;
    }
};

/// OnEventFn adapter installed into the runner. Runs on the PRODUCER thread.
fn pumpBridge(tag: RunEventTag, payload: []const u8, userdata: ?*anyopaque) void {
    const st: *PumpState = @ptrCast(@alignCast(userdata orelse return));
    if (st.isCancelled()) return; // peer gone: stop encoding work early

    switch (tag) {
        .turn_start => {}, // dropped by design (see header contract)
        .thinking => {
            const line = encodeTextFrame(st.qalloc, "thinking", payload) catch return;
            st.pushFrame(line);
        },
        .text => {
            const line = encodeTextFrame(st.qalloc, "delta", payload) catch return;
            st.pushFrame(line);
        },
        .tool_call => {
            const parts = splitToolComposite(payload);
            st.setLastToolName(parts.name);
            const line = encodeToolCallFrame(st.qalloc, parts.name, parts.args) catch return;
            st.pushFrame(line);
        },
        .tool_result => {
            const name: []const u8 = st.last_tool_name orelse "";
            const line = encodeToolResultFrame(st.qalloc, name, payload) catch return;
            st.pushFrame(line);
        },
        .done => {
            const line = encodeDoneFrame(st.qalloc, payload, st.req_session) catch return;
            st.pushFrame(line);
        },
        .err => {
            const line = encodeErrorFrame(st.qalloc, payload) catch return;
            st.pushFrame(line);
        },
    }
}

/// Producer main: drive one run, then post the end marker. Errors are
/// recorded for the consumer's terminal synthesis rather than propagated —
/// after the SSE head is written there is no status code left to send.
fn producerMain(
    run_fn: RunStreamFn,
    run_ctx: ?*anyopaque,
    run_req: RunRequest,
    st: *PumpState,
) void {
    // page_allocator here is deliberate: the run must not touch the
    // connection arena concurrently with the consumer thread (see header,
    // ALLOCATORS). Real implementations ignore it and use their own gpa.
    run_fn(run_ctx, std.heap.page_allocator, run_req, &pumpBridge, st) catch |e| {
        st.setRunErr(e);
    };
    st.pushEnd();
}

/// Consumer main: drain the queue onto the wire with idle heartbeats.
/// Returns when the end marker arrives or the peer goes away. Always leaves
/// the queue drained (all entries freed).
fn consume(
    stream: *httpd.EventStream,
    st: *PumpState,
    tuning: StreamTuning,
) void {
    defer {
        st.cancelled.store(true, .release); // unblock a high-water-blocked producer
        while (st.pop()) |e| st.freeEntry(e);
    }

    var saw_done = false;
    var saw_err = false;
    var last_write = msNow();

    while (true) {
        if (stream.peerGone()) return;
        const entry = st.pop() orelse {
            const now = msNow();
            if (now -% last_write >= tuning.heartbeat_after_ms) {
                stream.comment("keep-alive") catch return;
                last_write = now;
            }
            stream.sleepTicks(tuning.poll_ms, 5);
            continue;
        };
        switch (entry) {
            .end => break,
            .frame => |line| {
                defer st.freeEntry(entry);
                // Frame classification by substring is safe here: these
                // literals can only appear as our own type markers.
                if (std.mem.indexOf(u8, line, "\"type\":\"done\"") != null) saw_done = true;
                if (std.mem.indexOf(u8, line, "\"type\":\"error\"") != null) saw_err = true;
                events.writeDataFrame(stream, line) catch return; // peer gone
                last_write = msNow();
            },
        }
    }

    // Terminal synthesis: a stream that neither completed nor errored would
    // otherwise look like a hang to the client.
    if (!saw_done and !saw_err and !stream.peerGone()) {
        const msg: []const u8 = if (st.getRunErr()) |e|
            @errorName(e)
        else
            "run ended without a done event";
        const line = encodeErrorFrame(st.qalloc, msg) catch return;
        defer st.qalloc.free(line);
        events.writeDataFrame(stream, line) catch {};
    }
}

/// Serve one POST /run/stream connection: open the SSE stream, start the
/// producer, pump frames + heartbeats until the run ends or the peer leaves.
/// Only `startEventStream` errors propagate (headers were not yet sent);
/// everything after the head is best-effort, mirroring serveEvents().
pub fn serve(
    run_fn: RunStreamFn,
    run_ctx: ?*anyopaque,
    run_req: RunRequest,
    res: *httpd.Responder,
    tuning: StreamTuning,
) !void {
    var stream = try res.startEventStream();
    stream.comment("zharness run stream") catch {};

    var st = PumpState{
        .qalloc = std.heap.c_allocator,
        .high_water = @max(tuning.queue_high_water, 1),
        .req_session = run_req.session,
    };
    defer st.deinit();

    const worker = std.Thread.spawn(.{}, producerMain, .{ run_fn, run_ctx, run_req, &st }) catch null;
    if (worker == null) {
        // Spawn failure fallback: produce inline (no concurrency, no lost
        // frames), then consume normally.
        producerMain(run_fn, run_ctx, run_req, &st);
    }
    consume(&stream, &st, tuning);
    if (worker) |w| w.join();
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Comptime byte-fill (stand-in for the removed `str ** n` repetition).
fn comptimeFill(comptime n: usize, comptime byte: u8) [n]u8 {
    @setEvalBranchQuota(n + 1000);
    var a: [n]u8 = undefined;
    for (&a) |*c| c.* = byte;
    return a;
}

test "splitToolComposite splits at first paren and strips trailing paren" {
    const a = splitToolComposite("shell({\"cmd\":\"ls\"})");
    try testing.expectEqualStrings("shell", a.name);
    try testing.expectEqualStrings("{\"cmd\":\"ls\"}", a.args);

    // Args containing parens stay intact.
    const b = splitToolComposite("grep(\"foo(bar\")");
    try testing.expectEqualStrings("grep", b.name);
    try testing.expectEqualStrings("\"foo(bar\"", b.args);

    // Empty args and malformed composites degrade gracefully.
    const c = splitToolComposite("plan()");
    try testing.expectEqualStrings("", c.args);
    const d = splitToolComposite("no_parens");
    try testing.expectEqualStrings("no_parens", d.name);
    try testing.expectEqualStrings("", d.args);
    const e = splitToolComposite("broken(\"unterminated");
    try testing.expectEqualStrings("broken", e.name);
    try testing.expectEqualStrings("\"unterminated", e.args);
}

test "truncateUtf8 cuts ascii exactly and backs off utf-8 sequences" {
    const ascii = "abcdefgh";
    const t1 = truncateUtf8(ascii, 4);
    try testing.expect(t1.truncated);
    try testing.expectEqualStrings("abcd", t1.slice);
    try testing.expect(!truncateUtf8(ascii, 8).truncated);
    try testing.expect(!truncateUtf8(ascii, 100).truncated);

    // "é" is 2 bytes (C3 A9); cutting at an odd offset must not split it.
    // Built interleaved at runtime — a comptime C3-block ++ A9-block would
    // itself be invalid UTF-8.
    var accented: [21]u8 = undefined;
    accented[0] = 'a';
    for (0..10) |i| {
        accented[1 + i * 2] = 0xC3;
        accented[2 + i * 2] = 0xA9;
    }
    const t2 = truncateUtf8(&accented, 10);
    try testing.expect(t2.truncated);
    try testing.expectEqual(@as(usize, 9), t2.slice.len); // 'a' + 4×"é"
    try testing.expect(std.unicode.utf8ValidateSlice(t2.slice));

    // Cut landing exactly after a complete sequence keeps it whole:
    // 你好! = E4 BD A0 E5 A5 BD 21; max 3 → "你".
    const hello = "\xe4\xbd\xa0\xe5\xa5\xbd!";
    const t3 = truncateUtf8(hello, 3);
    try testing.expect(t3.truncated);
    try testing.expectEqualStrings("\xe4\xbd\xa0", t3.slice);
    try testing.expect(std.unicode.utf8ValidateSlice(t3.slice));

    // A lone leader before the cut is dropped as well.
    const t4 = truncateUtf8(hello, 1); // s[1] is a continuation → back off to 0
    try testing.expect(t4.truncated);
    try testing.expectEqual(@as(usize, 0), t4.slice.len);

    const xs = comptime comptimeFill(9999, 'x');
    try testing.expectEqual(tool_output_max_bytes, truncateUtf8(&xs, tool_output_max_bytes).slice.len);
}

test "frame encoders emit exact JSON shapes with escaping" {
    const alloc = testing.allocator;

    const d = try encodeTextFrame(alloc, "delta", "he said \"hi\"\nbye");
    defer alloc.free(d);
    try testing.expectEqualStrings("{\"type\":\"delta\",\"text\":\"he said \\\"hi\\\"\\nbye\"}", d);

    const th = try encodeTextFrame(alloc, "thinking", "hmm");
    defer alloc.free(th);
    try testing.expectEqualStrings("{\"type\":\"thinking\",\"text\":\"hmm\"}", th);

    const tc = try encodeToolCallFrame(alloc, "shell", "{\"cmd\":\"ls\"}");
    defer alloc.free(tc);
    try testing.expectEqualStrings("{\"type\":\"tool_call\",\"name\":\"shell\",\"args\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}", tc);

    const tr = try encodeToolResultFrame(alloc, "shell", "ok");
    defer alloc.free(tr);
    try testing.expectEqualStrings("{\"type\":\"tool_result\",\"name\":\"shell\",\"output\":\"ok\",\"truncated\":false}", tr);

    const big = try alloc.alloc(u8, tool_output_max_bytes + 100);
    defer alloc.free(big);
    @memset(big, 'x');
    const tr2 = try encodeToolResultFrame(alloc, "g", big);
    defer alloc.free(tr2);
    try testing.expect(std.mem.indexOf(u8, tr2, "\"truncated\":true") != null);
    // Encoded output stays bounded despite oversized input.
    try testing.expect(tr2.len < tool_output_max_bytes + 128);

    const dn = try encodeDoneFrame(alloc, "fin", "wk1");
    defer alloc.free(dn);
    try testing.expectEqualStrings("{\"type\":\"done\",\"answer\":\"fin\",\"session\":\"wk1\"}", dn);

    const dn2 = try encodeDoneFrame(alloc, "fin", null);
    defer alloc.free(dn2);
    try testing.expectEqualStrings("{\"type\":\"done\",\"answer\":\"fin\",\"session\":null}", dn2);

    const er = try encodeErrorFrame(alloc, "boom \"x\"");
    defer alloc.free(er);
    try testing.expectEqualStrings("{\"type\":\"error\",\"error\":\"boom \\\"x\\\"\"}", er);
}

test "parseRunRequest extracts all fields and frees cleanly" {
    const alloc = testing.allocator;
    var req = (try parseRunRequest(alloc,
        \\{"prompt":"do it","session":"s1","preset":"ptc","sandbox":"process"}
    )) ;
    defer freeRunRequest(alloc, &req);
    try testing.expectEqualStrings("do it", req.prompt);
    try testing.expectEqualStrings("s1", req.session.?);
    try testing.expectEqualStrings("ptc", req.preset.?);
    try testing.expectEqualStrings("process", req.sandbox.?);

    var minimal = (try parseRunRequest(alloc, "{\"prompt\":\"p\"}"));
    defer freeRunRequest(alloc, &minimal);
    try testing.expect(minimal.session == null);
    try testing.expect(minimal.preset == null);
    try testing.expect(minimal.sandbox == null);

    try testing.expectError(error.MissingPrompt, parseRunRequest(alloc, "{\"other\":1}"));

    // Escapes decode through the local extractor.
    var esc = (try parseRunRequest(alloc, "{\"prompt\":\"a\\nb\\\"c\"}"));
    defer freeRunRequest(alloc, &esc);
    try testing.expectEqualStrings("a\nb\"c", esc.prompt);
}

test "pump state push/pop preserves order; end bypasses high water" {
    var st = PumpState{ .qalloc = testing.allocator, .high_water = 2 };
    defer st.deinit();

    st.pushFrame(try testing.allocator.dupe(u8, "one"));
    st.pushFrame(try testing.allocator.dupe(u8, "two"));
    st.pushEnd(); // must not block despite full high-water

    const e1 = st.pop().?;
    try testing.expectEqualStrings("one", e1.frame);
    st.freeEntry(e1);
    const e2 = st.pop().?;
    try testing.expectEqualStrings("two", e2.frame);
    st.freeEntry(e2);
    const e3 = st.pop().?;
    try testing.expect(e3 == .end);
    try testing.expect(st.pop() == null);
}

test "cancelled pump drops pushed frames" {
    var st = PumpState{ .qalloc = testing.allocator, .high_water = 4 };
    defer st.deinit();
    st.cancelled.store(true, .release);
    st.pushFrame(try testing.allocator.dupe(u8, "ghost")); // must be freed, not queued
    try testing.expect(st.pop() == null);
    st.pushEnd();
    try testing.expect(st.pop() == null);
}
