//! Broadcast hub for live observability envelopes (dev.md §XXX / §XXIII).
//!
//! The hub is a process-wide singleton that fans every published envelope
//! line out to all subscribers. Each subscriber is a handle bound to:
//!   1. a REPLAY snapshot — the last `replay_capacity` (128) envelopes
//!      published before it subscribed (seeded from the hub-wide ring), and
//!   2. a LIVE tail — its own bounded queue fed by subsequent publishes.
//!
//! Slow-subscriber policy: when a live queue is full the OLDEST queued
//! envelope is dropped and the subscriber's `dropped` counter increments.
//! Replay-ring overflow (oldest entries falling out of the hub's 128-slot
//! history) is cache eviction, NOT delivery loss, and is not counted.
//!
//! ── CONTRACT FOR THE INTEGRATOR (main.zig) ────────────────────────────────
//!
//!   const server_events = @import("server/events.zig");
//!   const obs_mod = @import("obs.zig");
//!
//!   // cmdServe(), BEFORE httpd.Server.init():
//!   try server_events.install(gpa);            // long-lived allocator
//!   obs_mod.fanout = &server_events.hubPublish;
//!
//!   var server = try httpd.Server.init(alloc, .{
//!       .ctx = deps,
//!       .call = api.handle,
//!   }, .{ .port = port, .threaded_connections = true });  // see below
//!
//!   ... // after stop(): all SSE connections closed first, then
//!   obs_mod.fanout = null;
//!   server_events.deinstall();
//!
//! CLI run/chat never call install(), so `hub()` stays null, `hubPublish`
//! degrades to an O(1) no-op, and logging stays pure-jsonl.
//!
//! ── THREADING CONTRACT ────────────────────────────────────────────────────
//!
//! Memory safety (always holds): ALL hub state sits behind one spin lock.
//! `publish` / `subscribe` / `unsubscribe` / `Subscriber.take` may run
//! concurrently from ANY threads. In particular publishing FROM the accept
//! thread WHILE a subscriber streams on its own connection thread is safe in
//! both httpd modes — the lock, not the threading mode, provides safety.
//! Lock hold times are tiny (bounded memcpys of ≤16 KiB lines), so the spin
//! design (no std.Io mutex — those need an Io handle this module must not
//! require) trades negligible CPU for zero dependency surface.
//!
//! Liveness (operational requirement): run httpd with
//! `Options.threaded_connections = true` whenever the hub has — or may get —
//! subscribers. In sequential mode one open /events stream monopolizes the
//! accept thread and every OTHER route starves until the stream closes.
//! Publishes remain safe there too; they merely serialize behind whatever
//! request happens to be running.
//!
//! Startup ordering: set `obs.fanout` and install() the hub before spawning
//! the accept loop. Both are plain memory writes; the thread-creation edge
//! makes them visible to connection threads. Tearing down mirrors that:
//! only after every subscriber handle is unsubscribed (streams closed).
//!
//! Ownership rules: the hub owns copies of everything it stores; each
//! subscriber owns its queue entries. `take()` hands out a BORROWED slice
//! owned by the subscriber, valid until the next `take()` on the same handle
//! or its `unsubscribe` — one consumer per handle, no concurrent takers.
//!
//! Bounds: replay ring ≤128 lines, live queues ≤256 lines each (tunable at
//! subscribe), lines >16 KiB rejected outright (counted in
//! `Hub.oversize_dropped`). Worst-case memory stays proportional to those
//! caps regardless of publisher speed.

const std = @import("std");
const httpd = @import("httpd.zig");

// ── limits ──────────────────────────────────────────────────────────────────

/// Hub-wide replay ring size: how many recent envelopes a fresh subscriber
/// receives before the live tail begins.
pub const replay_capacity: usize = 128;
/// Default per-subscriber live-queue capacity (slow-subscriber drop point).
pub const default_live_capacity: usize = 256;
/// Longest accepted envelope line. Longer publishes are refused (counted),
/// keeping worst-case per-slot memory bounded.
pub const max_line_bytes: usize = 16 * 1024;

// ── locking primitive ───────────────────────────────────────────────────────

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

fn backoffSleepMs(ms: u64) void {
    const req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&req, null);
}

/// Minimal test-and-set spin lock with sleep backoff. Short critical
/// sections only (queue pushes/pops); contended waiters park in 1 ms naps
/// instead of burning CPU. No allocator, no Io handle needed.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins >= 16) {
                backoffSleepMs(1);
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

// ── subscriber ──────────────────────────────────────────────────────────────

/// One live event feed consumer (an /events SSE stream). Created only via
/// `Hub.subscribe`; destroyed only via `Hub.unsubscribe`. Single consumer:
/// exactly one thread may call `take` on a given handle.
pub const Subscriber = struct {
    hub: *Hub,
    /// Owned queued lines, oldest first (`items[0]` is next to deliver).
    queue: std.ArrayList([]u8),
    capacity: usize,
    /// Envelopes lost to slow-consumer overflow or allocation failure.
    dropped: usize = 0,
    /// Line lent out by the last `take` (still owned HERE until reclaimed).
    loan: ?[]u8 = null,

    /// Pop the oldest queued envelope. The returned slice is owned by the
    /// SUBSCRIBER and stays valid only until the next `take` on this handle
    /// or `Hub.unsubscribe` — copy or write it out before calling again.
    /// Null when the queue is currently empty (non-blocking by design; the
    /// SSE loop polls between ticks).
    pub fn take(self: *Subscriber) ?[]const u8 {
        const h = self.hub;
        h.lock.lock();
        defer h.lock.unlock();

        if (self.loan) |old| {
            h.alloc.free(old);
            self.loan = null;
        }
        if (self.queue.items.len == 0) return null;
        const line = self.queue.orderedRemove(0);
        self.loan = line;
        return line;
    }

    /// Lines currently waiting in the live tail (plus seeded replay not yet
    /// taken). Lock-protected read for tests/introspection.
    pub fn pending(self: *const Subscriber) usize {
        const h = self.hub;
        h.lock.lock();
        defer h.lock.unlock();
        return self.queue.items.len;
    }

    pub fn droppedCount(self: *const Subscriber) usize {
        const h = self.hub;
        h.lock.lock();
        defer h.lock.unlock();
        return self.dropped;
    }

    /// Caller MUST hold the hub lock. Takes a copy of `line`; ownership of
    /// the copy passes to the queue. Overflow drops the OLDEST entry.
    fn enqueueLocked(self: *Subscriber, line: []const u8) void {
        const h = self.hub;
        if (self.queue.items.len >= self.capacity) {
            const evicted = self.queue.orderedRemove(0);
            h.alloc.free(evicted);
            self.dropped += 1;
        }
        const copy = h.alloc.dupe(u8, line) catch {
            self.dropped += 1; // allocation failure counts as a drop
            return;
        };
        self.queue.append(h.alloc, copy) catch {
            h.alloc.free(copy);
            self.dropped += 1;
        };
    }

    /// Caller MUST hold the hub lock. Frees queue + loan (not the handle).
    fn drainLocked(self: *Subscriber) void {
        const h = self.hub;
        for (self.queue.items) |line| h.alloc.free(line);
        self.queue.deinit(h.alloc);
        if (self.loan) |l| {
            h.alloc.free(l);
            self.loan = null;
        }
    }
};

// ── hub ─────────────────────────────────────────────────────────────────────

pub const SubscribeError = error{ OutOfMemory, InvalidCapacity };

pub const Hub = struct {
    alloc: std.mem.Allocator,
    lock: SpinLock = .{},
    /// Owned lines, oldest first; capped at `replay_capacity`.
    replay: std.ArrayList([]u8),
    /// Registered subscribers (unowned handles, freed by their creators'
    /// unsubscribe call path below).
    subs: std.ArrayList(*Subscriber),
    /// Publishes refused for exceeding `max_line_bytes`.
    oversize_dropped: usize = 0,

    /// Fan one envelope line out to the replay ring + every live queue.
    /// Copies per destination; never blocks on consumers (drops instead).
    /// Safe from any thread; a no-op cost-wise beyond ring maintenance when
    /// nobody is subscribed (history still accrues for future subscribers).
    pub fn publish(self: *Hub, line: []const u8) void {
        if (line.len > max_line_bytes) {
            self.lock.lock();
            defer self.lock.unlock();
            self.oversize_dropped += 1;
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        // Replay ring: push with oldest-eviction (not counted as loss).
        const hist = self.alloc.dupe(u8, line) catch return;
        if (self.replay.items.len >= replay_capacity) {
            const evicted = self.replay.orderedRemove(0);
            self.alloc.free(evicted);
        }
        self.replay.append(self.alloc, hist) catch {
            self.alloc.free(hist);
            return;
        };

        for (self.subs.items) |sub| sub.enqueueLocked(line);
    }

    /// Register a consumer seeded with the current replay history (oldest →
    /// newest), followed live by every later publish. Live queue uses
    /// `default_live_capacity`.
    pub fn subscribe(self: *Hub) SubscribeError!*Subscriber {
        return self.subscribeCapacity(default_live_capacity);
    }

    /// `subscribe` with an explicit live-queue bound (tests use small caps).
    /// Note: if `live_cap` is smaller than the current replay history, the
    /// oldest seeded entries overflow the queue immediately and count in the
    /// subscriber's `dropped` counter (the live queue is the single bound).
    pub fn subscribeCapacity(self: *Hub, live_cap: usize) SubscribeError!*Subscriber {
        if (live_cap == 0) return error.InvalidCapacity;

        const sub = try self.alloc.create(Subscriber);
        errdefer self.alloc.destroy(sub);
        sub.* = .{
            .hub = self,
            .queue = .empty,
            .capacity = live_cap,
        };
        errdefer sub.queue.deinit(self.alloc);

        self.lock.lock();
        defer self.lock.unlock();

        // Seed from history under the same lock that gates publishes, so
        // replayed entries are strictly OLDER than anything this subscriber
        // will receive live: no gaps, no duplicates across the seam.
        for (self.replay.items) |line| sub.enqueueLocked(line);
        try self.subs.append(self.alloc, sub);
        return sub;
    }

    /// Detach and destroy a subscriber handle. Any outstanding `take` loan
    /// is freed here — borrowed slices die with the handle. Idempotence is
    /// NOT provided: call exactly once per subscribed handle.
    pub fn unsubscribe(self: *Hub, sub: *Subscriber) void {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.subs.items, 0..) |s, i| {
            if (s == sub) {
                _ = self.subs.swapRemove(i);
                break;
            }
        }
        sub.drainLocked();
        self.alloc.destroy(sub);
    }

    pub fn subscriberCount(self: *Hub) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.subs.items.len;
    }
};

// ── module-level singleton ──────────────────────────────────────────────────

var g_hub: ?*Hub = null;

/// Create the process-wide hub. Fails if already installed (call `deinstall`
/// first). `alloc` must outlive the hub — typically the binary's long-lived
/// gpa; the testing allocator works when every handle is unsubscribed
/// before `deinstall`.
pub fn install(alloc: std.mem.Allocator) !void {
    if (g_hub != null) return error.AlreadyInstalled;
    const h = try alloc.create(Hub);
    errdefer alloc.destroy(h);
    h.* = .{
        .alloc = alloc,
        .replay = .empty,
        .subs = .empty,
    };
    errdefer h.replay.deinit(alloc);
    errdefer h.subs.deinit(alloc);
    g_hub = h;
}

/// The installed hub, or null when serve-mode wiring is absent (CLI paths).
pub fn hub() ?*Hub {
    return g_hub;
}

/// Destroy the singleton. EVERY subscriber must be unsubscribed first
/// (asserted). Frees history and the hub itself.
pub fn deinstall() void {
    const h = g_hub orelse return;
    const alloc = h.alloc;
    std.debug.assert(h.subscriberCount() == 0); // streams must close first
    for (h.replay.items) |line| alloc.free(line);
    h.replay.deinit(alloc);
    h.subs.deinit(alloc);
    alloc.destroy(h);
    g_hub = null;
}

/// `obs.fanout` target. Signature-fixed by the obs hook contract; safe to
/// leave wired even while uninstalled (cheap no-op). Thread-safe per the
/// hub threading contract above.
pub fn hubPublish(envelope_json: []const u8) void {
    const h = g_hub orelse return;
    h.publish(envelope_json);
}

// ── SSE data-frame helpers ──────────────────────────────────────────────────

/// libc send(2). Local extern (events.zig has no clashing method names —
/// the reason httpd.zig needs its @extern alias trick there).
extern "c" fn send(fd: c_int, buf: [*]const u8, n: usize, flags: c_int) isize;

/// MSG_NOSIGNAL exists on Linux; Darwin suppresses SIGPIPE per-socket via
/// SO_NOSIGPIPE (set by the httpd accept loop on real connections; socket-
/// pair-based tests must set it themselves). Mirrors httpd.send_flags.
const send_flags: c_int = if (@hasDecl(std.c.MSG, "NOSIGNAL")) std.c.MSG.NOSIGNAL else 0;

/// Pure SSE framing: one envelope as `data: <line>\n\n` (WHATWG default
/// event). Testable without sockets.
pub fn dataFrame(alloc: std.mem.Allocator, line: []const u8) ![]u8 {
    var frame: std.ArrayList(u8) = .empty;
    errdefer frame.deinit(alloc);
    try frame.appendSlice(alloc, "data: ");
    try frame.appendSlice(alloc, line);
    try frame.appendSlice(alloc, "\n\n");
    return frame.toOwnedSlice(alloc);
}

/// Write one data frame through the stream's socket. Failure handling
/// mirrors httpd.EventStream.writeFrame exactly: flag `responder.failed`
/// so `peerGone()` stays authoritative for disconnect detection, then
/// surface `error.WriteFailed` to break the streaming loop.
///
/// Why not `stream.event(...)`: that emits a named-event frame
/// ("event: x\ndata: y"), while the /events wire contract is bare
/// `data:` lines; EventStream exposes no data-only writer, so this sends
/// the frame directly over the same fd with identical failure semantics.
pub fn writeDataFrame(stream: *httpd.EventStream, line: []const u8) !void {
    const frame = try dataFrame(stream.responder.alloc, line);
    defer stream.responder.alloc.free(frame);

    var off: usize = 0;
    while (off < frame.len) {
        const n = send(stream.fd, frame.ptr + off, frame.len - off, send_flags);
        if (n <= 0) {
            stream.responder.failed = true;
            return error.WriteFailed;
        }
        off += @intCast(n);
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "dataFrame pure framing" {
    const frame = try dataFrame(testing.allocator, "{\"i\":1}");
    defer testing.allocator.free(frame);
    try testing.expectEqualStrings("data: {\"i\":1}\n\n", frame);

    const empty = try dataFrame(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("data: \n\n", empty);
}

test "subscribe-before-publish replay then live order" {
    try install(testing.allocator);
    defer deinstall();

    const e1 = "{\"i\":1}";
    const e2 = "{\"i\":2}";
    const e3 = "{\"i\":3}";
    const e4 = "{\"i\":4}";

    hubPublish(e1);
    hub().?.publish(e2); // direct publish path, pre-subscription

    const sub = try hub().?.subscribe();
    // Replay: strictly older events arrive first, oldest → newest.
    try testing.expectEqualStrings(e1, sub.take().?);
    try testing.expectEqualStrings(e2, sub.take().?);
    try testing.expectEqual(@as(usize, 0), sub.pending());

    // Live tail preserves publish order.
    hub().?.publish(e3);
    hub().?.publish(e4);
    try testing.expectEqualStrings(e3, sub.take().?);
    try testing.expectEqualStrings(e4, sub.take().?);
    try testing.expect(sub.take() == null);
    try testing.expectEqual(@as(usize, 0), sub.droppedCount());

    hub().?.unsubscribe(sub);
    try testing.expectEqual(@as(usize, 0), hub().?.subscriberCount());
}

test "live queue overflow drops oldest and counts" {
    try install(testing.allocator);
    defer deinstall();

    const cap = 8;
    const sub = try hub().?.subscribeCapacity(cap);
    const total = cap + 5; // 5 oldest lines must be dropped

    for (0..total) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{{\"i\":{d}}}", .{i});
        hub().?.publish(line);
    }

    try testing.expectEqual(@as(usize, 5), sub.droppedCount());
    try testing.expectEqual(cap, sub.pending());
    // Oldest survivors are i=5..12, in order.
    for (5..total) |i| {
        const got = sub.take().?;
        var want_buf: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, "{{\"i\":{d}}}", .{i});
        try testing.expectEqualStrings(want, got);
    }
    try testing.expectEqual(@as(usize, 0), sub.pending());

    hub().?.unsubscribe(sub);
}

test "replay ring caps at replay_capacity for late subscribers" {
    try install(testing.allocator);
    defer deinstall();

    const total = replay_capacity + 7;
    for (0..total) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{{\"i\":{d}}}", .{i});
        hub().?.publish(line);
    }

    // Late subscriber gets EXACTLY the newest 128, oldest-first.
    const late = try hub().?.subscribe();
    try testing.expectEqual(replay_capacity, late.pending());
    const first = late.take().?;
    var want_buf: [32]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&want_buf, "{{\"i\":{d}}}", .{total - replay_capacity}),
        first,
    );
    // Drain the rest; nothing was counted as delivery loss.
    var drained: usize = 1;
    while (late.take() != null) drained += 1;
    try testing.expectEqual(replay_capacity, drained);
    try testing.expectEqual(@as(usize, 0), late.droppedCount());
    hub().?.unsubscribe(late);
}

test "oversize publishes are refused and counted" {
    try install(testing.allocator);
    defer deinstall();

    const sub = try hub().?.subscribe();
    const big = try testing.allocator.alloc(u8, max_line_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    hub().?.publish(big);
    try testing.expectEqual(@as(usize, 1), hub().?.oversize_dropped);
    try testing.expectEqual(@as(usize, 0), sub.pending());

    hub().?.publish("{}"); // still works after a refusal
    try testing.expectEqualStrings("{}", sub.take().?);
    hub().?.unsubscribe(sub);
}

test "unsubscribe stops delivery" {
    try install(testing.allocator);
    defer deinstall();

    const keeper = try hub().?.subscribe();
    const dropper = try hub().?.subscribe();

    hub().?.publish("{\"i\":1}");
    try testing.expectEqualStrings("{\"i\":1}", keeper.take().?);
    try testing.expectEqualStrings("{\"i\":1}", dropper.take().?);

    // Detach one consumer; the other must keep receiving live events, and
    // publishing with fewer/no subscribers stays safe (the hub iterates its
    // live list only).
    hub().?.unsubscribe(dropper);
    try testing.expectEqual(@as(usize, 1), hub().?.subscriberCount());

    hub().?.publish("{\"i\":2}");
    try testing.expectEqualStrings("{\"i\":2}", keeper.take().?);
    try testing.expectEqual(@as(usize, 0), keeper.droppedCount());

    hub().?.unsubscribe(keeper);
    try testing.expectEqual(@as(usize, 0), hub().?.subscriberCount());
}

test "zero-subscriber publishes are safe and accrue replay history" {
    try install(testing.allocator);
    defer deinstall();

    hub().?.publish("{\"solo\":true}"); // nobody listening: must not crash

    const late = try hub().?.subscribe();
    try testing.expectEqualStrings("{\"solo\":true}", late.take().?);
    hub().?.unsubscribe(late);
}

test "multiple subscribers fan out independently" {
    try install(testing.allocator);
    defer deinstall();

    const a = try hub().?.subscribeCapacity(4);
    const b = try hub().?.subscribeCapacity(64);

    hub().?.publish("{\"i\":1}");
    hub().?.publish("{\"i\":2}");

    // b drains slowly; a floods and drops — counters independent.
    try testing.expectEqualStrings("{\"i\":1}", a.take().?);
    for (0..8) |_| hub().?.publish("{\"flood\":true}");
    try testing.expect(a.droppedCount() > 0);
    try testing.expectEqual(@as(usize, 4), a.pending());

    try testing.expectEqualStrings("{\"i\":1}", b.take().?);
    try testing.expectEqualStrings("{\"i\":2}", b.take().?);
    var flood_seen: usize = 0;
    while (b.take() != null) flood_seen += 1;
    try testing.expectEqual(@as(usize, 8), flood_seen);
    try testing.expectEqual(@as(usize, 0), b.droppedCount());

    hub().?.unsubscribe(a);
    hub().?.unsubscribe(b);
    try testing.expectEqual(@as(usize, 0), hub().?.subscriberCount());
}

test "install twice fails; deinstall without install is a no-op" {
    try install(testing.allocator);
    defer deinstall();
    try testing.expectError(error.AlreadyInstalled, install(testing.allocator));
}
