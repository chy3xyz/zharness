//! Subagent run registry + RPC data plane (wave-6 task spec).
//!
//! zharness's spawn_agent tool (tool/spawn_agent.zig → agent/subagent.zig)
//! runs isolated one-shot mini-loops WITHOUT durable child sessions, so the
//! vendored ui-subagent panel has nothing to list. This module is the missing
//! DATA PLANE: a process-global registry of subagent runs plus the two RPC
//! handlers upstream's subagent domain needs (`subagent.list`,
//! `subagent.history` — wire truth `_ref/deepseek-harness/packages/host/
//! apiproxy/src/api/subagents{,.schema}.ts` + ui-subagent/src/client).
//!
//! ── Registry row ────────────────────────────────────────────────────────────
//!   {id, parent_session_id, status(running|completed|failed), prompt,
//!    final_text, started_at_ms, duration_ms} (+ optional label).
//!   ids are registry-minted "subagent-<n>" strings (spawn_agent creates no
//!   child session id of its own). All rows live on the C allocator for the
//!   process lifetime (bounded by actual spawn volume); reads return deep
//!   copies into the CALLER's allocator so no handler can race the store.
//!
//! ── INTEGRATOR WIRING ──────────────────────────────────────────────────────
//! 1. Router dispatch lines (router.zig dispatch, integrator applies):
//!      if (std.mem.eql(u8, m, "subagent.list"))
//!          return run(alloc, env, okValue(alloc, env.rpc_id,
//!              try subagents_rpc.handleList(alloc, p)));
//!      if (std.mem.eql(u8, m, "subagent.history"))
//!          return run(alloc, env, okValue(alloc, env.rpc_id,
//!              try subagents_rpc.handleHistory(alloc, p)));
//!    (error.SessionNotFound out of handleHistory renders session-not-found
//!    through run()/mapDepsError exactly like session.history.)
//!
//! 2. Spawn-path hooks (tool/spawn_agent.zig execute, integrator applies —
//!    SpawnEnv needs ONE additive field `parent_session_id: []const u8 = ""`
//!    plumbed from the agent loop's current session id):
//!      // before subagent.runSubagent:
//!      const child_id = try subagents_rpc.beginRun(
//!          env.parent_session_id, spec.name, task); // caller frees child_id
//!      defer alloc.free(child_id);
//!      // after a successful runSubagent:
//!      subagents_rpc.endRun(child_id, true, outcome.text);
//!      // on the failure path (runSubagent error / missing task AFTER start):
//!      subagents_rpc.endRun(child_id, false, null);
//!    Until wired, the registry simply stays empty and both RPCs answer
//!    honestly-empty values — the panel shows an empty catalog.
//!
//! 3. Mux-frame emission points (optional but recommended, main.zig wiring;
//!    the client ALSO re-fetches catalogs on menu-open/selection/reconnect,
//!    so frames only make rows update without user action):
//!      after beginRun  → hubs.host.publish("host/session-status",
//!          '{"type":"host/session-status","sessionId":"<child>","running":true}')
//!      after endRun    → same frame with "running":false
//!    Do NOT invent new frame families; host/session-status is already in the
//!    vendored manager's vocabulary (events_ws.zig mapping table).
//!
//! ── v1 DEGRADATION (honest limits) ────────────────────────────────────────
//! - openSubagent/subagent.history returns a SUMMARY transcript: the recorded
//!   prompt as one user message + the final text as one assistant message.
//!   Upstream serves full child transcripts with real seq/time/pagination;
//!   zharness does not persist child transcripts yet, so intermediate turns
//!   and tool calls inside the child are NOT reconstructable. The shape is
//!   byte-compatible (sessions.zig history envelopes), the content is not.
//! - mode is always "one-shot"; continuable children do not exist here.
//! - parentAvailable is always true (hint-only field upstream; we cannot
//!   know parent liveness from the registry).
//! - beforeSeq pagination is accepted and ignored (tail paging by maxMessages
//!   works over the 1–2 synthesized events).

const std = @import("std");
const jsonx = @import("jsonx.zig");
const sessions = @import("sessions.zig");
const clib = @import("../../clib.zig");

// ── lock (events_ws.zig design copy) ───────────────────────────────────────

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins >= 16) {
                const req: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                _ = nanosleep(&req, null);
            } else std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

fn nowMs() i64 {
    return clib.nowTimestamp() * std.time.ms_per_s;
}

// ── records ─────────────────────────────────────────────────────────────────

pub const Status = enum {
    running,
    completed,
    failed,

    pub fn asStr(self: Status) []const u8 {
        return switch (self) {
            .running => "running",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

/// Arguments for recordStart. All slices are BORROWED — the registry dupes
/// them into its own allocator.
pub const StartSpec = struct {
    /// Child id ("subagent-<n>" from beginRun, or any caller-chosen opaque id).
    id: []const u8,
    parent_session_id: []const u8,
    /// Human-readable name (spec.name from spawn_agent; "" when unnamed).
    label: []const u8 = "",
    prompt: []const u8,
    started_at_ms: i64,
};

/// Internal owned row.
const Run = struct {
    id: []u8,
    parent_session_id: []u8,
    label: []u8,
    prompt: []u8,
    final_text: ?[]u8 = null,
    status: Status = .running,
    started_at_ms: i64,
    duration_ms: ?i64 = null,

    fn deinit(self: *Run, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.parent_session_id);
        gpa.free(self.label);
        gpa.free(self.prompt);
        if (self.final_text) |t| gpa.free(t);
    }
};

/// Deep-copy view handed to readers (allocated with the READER's allocator).
pub const Snapshot = struct {
    id: []const u8,
    parent_session_id: []const u8,
    label: []const u8,
    prompt: []const u8,
    final_text: ?[]const u8,
    status: Status,
    started_at_ms: i64,
    duration_ms: ?i64,

    pub fn free(self: *const Snapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.parent_session_id);
        alloc.free(self.label);
        alloc.free(self.prompt);
        if (self.final_text) |t| alloc.free(t);
    }

    pub fn freeSnapshots(alloc: std.mem.Allocator, snaps: []const Snapshot) void {
        for (snaps) |s| s.free(alloc);
        if (snaps.len > 0) alloc.free(snaps);
    }
};

fn dupInto(alloc: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error![]u8 {
    const out = try alloc.alloc(u8, src.len);
    @memcpy(out, src);
    return out;
}

fn dupeSnapshot(alloc: std.mem.Allocator, r: *const Run) !Snapshot {
    var final_copy: ?[]const u8 = null;
    if (r.final_text) |t| final_copy = try dupInto(alloc, t);
    errdefer if (final_copy) |t| alloc.free(t);
    return .{
        .id = try dupInto(alloc, r.id),
        .parent_session_id = try dupInto(alloc, r.parent_session_id),
        .label = try dupInto(alloc, r.label),
        .prompt = try dupInto(alloc, r.prompt),
        .final_text = final_copy,
        .status = r.status,
        .started_at_ms = r.started_at_ms,
        .duration_ms = r.duration_ms,
    };
}

// ── registry ────────────────────────────────────────────────────────────────

pub const EndStatus = enum { completed, failed };

pub const Registry = struct {
    gpa: std.mem.Allocator,
    lock: SpinLock = .{},
    runs: std.ArrayList(*Run) = .empty,
    counter: u64 = 0,

    /// Record the start of one run. A duplicate id replaces nothing — it is
    /// appended like any other row (ids are registry-minted; collisions are
    /// a caller bug surfaced by list() showing two rows).
    pub fn recordStart(self: *Registry, spec: StartSpec) !void {
        const run = try self.gpa.create(Run);
        errdefer self.gpa.destroy(run);
        run.* = .{
            .id = try dupInto(self.gpa, spec.id),
            .parent_session_id = try dupInto(self.gpa, spec.parent_session_id),
            .label = try dupInto(self.gpa, spec.label),
            .prompt = try dupInto(self.gpa, spec.prompt),
            .started_at_ms = spec.started_at_ms,
        };
        errdefer run.deinit(self.gpa);

        self.lock.lock();
        defer self.lock.unlock();
        try self.runs.append(self.gpa, run);
    }

    /// Finalize one run by id: flips status and stores the final text +
    /// duration. Returns false when the id is unknown (no-op).
    pub fn recordEnd(
        self: *Registry,
        id: []const u8,
        status: EndStatus,
        final_text: ?[]const u8,
        duration_ms: ?i64,
    ) bool {
        const text_copy: ?[]u8 = if (final_text) |t| dupInto(self.gpa, t) catch null else null;
        self.lock.lock();
        defer self.lock.unlock();
        for (self.runs.items) |run| {
            if (!std.mem.eql(u8, run.id, id)) continue;
            if (text_copy) |t| {
                if (run.final_text) |old| self.gpa.free(old);
                run.final_text = t;
            }
            run.status = switch (status) {
                .completed => .completed,
                .failed => .failed,
            };
            run.duration_ms = duration_ms;
            return true;
        }
        if (text_copy) |t| self.gpa.free(t);
        return false;
    }

    /// List runs (insertion order), optionally filtered by exact parent id.
    /// Snapshots are deep copies owned by `alloc`.
    pub fn list(self: *Registry, alloc: std.mem.Allocator, parent_filter: ?[]const u8) ![]Snapshot {
        self.lock.lock();
        defer self.lock.unlock();
        var out: std.ArrayList(Snapshot) = .empty;
        errdefer out.deinit(alloc);
        for (self.runs.items) |run| {
            if (parent_filter) |pf| {
                if (!std.mem.eql(u8, run.parent_session_id, pf)) continue;
            }
            try out.append(alloc, try dupeSnapshot(alloc, run));
        }
        return out.toOwnedSlice(alloc);
    }

    /// One run by id, or null. Deep copy owned by `alloc`.
    pub fn get(self: *Registry, alloc: std.mem.Allocator, id: []const u8) !?Snapshot {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.runs.items) |run| {
            if (std.mem.eql(u8, run.id, id)) return try dupeSnapshot(alloc, run);
        }
        return null;
    }

    pub fn deinit(self: *Registry) void {
        for (self.runs.items) |run| {
            run.deinit(self.gpa);
            self.gpa.destroy(run);
        }
        self.runs.deinit(self.gpa);
    }
};

// ── process-global singleton (events_ws.sharedHubs pattern) ────────────────

var g_registry: ?*Registry = null;

/// Process-wide registry on the C allocator. Idempotent; never torn down
/// (rows must survive across requests by definition).
pub fn shared() !*Registry {
    if (g_registry) |r| return r;
    const r = try std.heap.c_allocator.create(Registry);
    r.* = .{ .gpa = std.heap.c_allocator };
    g_registry = r;
    return r;
}

/// Test/integrator hook: detach the singleton (caller owns teardown).
pub fn takeShared() ?*Registry {
    const r = g_registry;
    g_registry = null;
    return r;
}

/// Test/integrator hook: replace the singleton wholesale (returns the
/// previous one, possibly null). Never used in production paths.
pub fn swapShared(replacement: ?*Registry) ?*Registry {
    const old = g_registry;
    g_registry = replacement;
    return old;
}

// ── spawn-path convenience wrappers ─────────────────────────────────────────

/// Mint a fresh child id, record a running row, and hand the id back
/// (allocated with `alloc` — the caller frees it once the run ends).
/// Registry failures propagate; the caller decides whether a spawn can
/// proceed untracked (recommended: yes — tracking must never break spawning).
pub fn beginRun(alloc: std.mem.Allocator, parent_session_id: []const u8, label: []const u8, prompt: []const u8) ![]u8 {
    const reg = try shared();
    var buf: [40]u8 = undefined;
    reg.lock.lock();
    reg.counter +%= 1;
    const n = reg.counter;
    reg.lock.unlock();
    const id = std.fmt.bufPrint(&buf, "subagent-{d}", .{n}) catch unreachable;
    const owned_id = try dupInto(alloc, id);
    errdefer alloc.free(owned_id);
    try reg.recordStart(.{
        .id = id,
        .parent_session_id = parent_session_id,
        .label = label,
        .prompt = prompt,
        .started_at_ms = nowMs(),
    });
    return owned_id;
}

/// Finalize a begun run with wall-clock duration (now − started_at, floored
/// at 0). Unknown ids are ignored.
pub fn endRun(id: []const u8, success: bool, final_text: ?[]const u8) void {
    const reg = g_registry orelse return;
    const started: ?i64 = blk: {
        reg.lock.lock();
        defer reg.lock.unlock();
        for (reg.runs.items) |run| {
            if (std.mem.eql(u8, run.id, id)) break :blk run.started_at_ms;
        }
        break :blk null;
    };
    const dur: ?i64 = if (started) |s| @max(nowMs() - s, 0) else null;
    _ = reg.recordEnd(id, if (success) .completed else .failed, final_text, dur);
}

// ── RPC handlers (VALUE builders; router wraps them in okValue) ─────────────

/// subagent.list value: {"entries":[…],"parentAvailable":true}.
/// Payload: {parentSessionId} (required per subagentListRequestSchema).
pub fn handleList(alloc: std.mem.Allocator, payload_json: []const u8) anyerror![]u8 {
    const parent_id = blk: {
        const raw = jsonx.getRaw(payload_json, "parentSessionId") orelse return error.PayloadInvalid;
        if (!jsonx.isString(raw)) return error.PayloadInvalid;
        break :blk try jsonx.decodeString(alloc, raw[1 .. raw.len - 1]);
    };

    const snaps = try (try shared()).list(alloc, parent_id);
    defer Snapshot.freeSnapshots(alloc, snaps);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"entries\":[");
    for (snaps, 0..) |s, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"kind\":\"child\",\"id\":");
        try jsonx.appendJsonString(alloc, &out, s.id);
        try out.appendSlice(alloc, ",\"mode\":\"one-shot\",\"activity\":");
        try jsonx.appendJsonString(alloc, &out, if (s.status == .running) "running" else "inactive");
        try out.appendSlice(alloc, ",\"hasChildren\":false");
        if (s.label.len > 0) {
            try out.appendSlice(alloc, ",\"label\":");
            try jsonx.appendJsonString(alloc, &out, s.label);
        }
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "],\"parentAvailable\":true}");
    return out.toOwnedSlice(alloc);
}

/// subagent.history value: the SAME envelope session.history renders
/// ({"events":[…],"hasMore":…,"projections":…}) built over the recorded
/// summary events. Payload: {parentSessionId, childSessionId, mode,
/// beforeSeq?, maxMessages?}. Errors: PayloadInvalid (bad shape/mode),
/// SessionNotFound (unknown child or parent mismatch).
pub fn handleHistory(alloc: std.mem.Allocator, payload_json: []const u8) anyerror![]u8 {
    const parent_id = try reqField(alloc, payload_json, "parentSessionId");
    const child_id = try reqField(alloc, payload_json, "childSessionId");

    const mode_raw = blk: {
        const raw = jsonx.getRaw(payload_json, "mode") orelse return error.PayloadInvalid;
        if (!jsonx.isString(raw)) return error.PayloadInvalid;
        break :blk try jsonx.decodeString(alloc, raw[1 .. raw.len - 1]);
    };
    if (!std.mem.eql(u8, mode_raw, "one-shot")) return error.PayloadInvalid;

    const max_i = jsonx.getInt(payload_json, "maxMessages"); // beforeSeq ignored (header note)
    if (max_i) |v| {
        if (v <= 0) return error.PayloadInvalid;
    }
    const max_messages: ?u32 = if (max_i) |v| @intCast(v) else null;

    const snap_opt = try (try shared()).get(alloc, child_id);
    const snap = snap_opt orelse return error.SessionNotFound;
    defer snap.free(alloc);
    if (!std.mem.eql(u8, snap.parent_session_id, parent_id)) return error.SessionNotFound;

    // Synthesized summary transcript: [user prompt] + [assistant answer].
    var msgs: [2]sessions.MsgRec = undefined;
    var msg_count: usize = 1;
    msgs[0] = .{ .role = "user", .content = snap.prompt };
    if (snap.status != .running) {
        if (snap.final_text) |ft| {
            if (ft.len > 0) {
                msgs[1] = .{ .role = "assistant", .content = ft };
                msg_count = 2;
            }
        } else if (snap.status == .failed) {
            msgs[1] = .{ .role = "assistant", .content = "[subagent failed]" };
            msg_count = 2;
        }
    }

    const title: []const u8 = if (snap.label.len > 0) snap.label else snap.id;
    const page = try sessions.buildHistoryPage(alloc, msgs[0..msg_count], snap.started_at_ms, max_messages, title);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"events\":[");
    for (page.entries, 0..) |e, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"event\":");
        try out.appendSlice(alloc, e.event_json);
        if (e.view_json) |v| {
            try out.appendSlice(alloc, ",\"view\":");
            try out.appendSlice(alloc, v);
        }
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "],\"hasMore\":");
    try out.appendSlice(alloc, if (page.has_more) "true" else "false");
    if (page.projections_json) |p| {
        try out.appendSlice(alloc, ",\"projections\":");
        try out.appendSlice(alloc, p);
    }
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

fn reqField(alloc: std.mem.Allocator, payload: []const u8, key: []const u8) ![]const u8 {
    const raw = jsonx.getRaw(payload, key) orelse return error.PayloadInvalid;
    if (!jsonx.isString(raw)) return error.PayloadInvalid;
    return jsonx.decodeString(alloc, raw[1 .. raw.len - 1]);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "registry lifecycle: start → list running → end → list completed" {
    var reg = Registry{ .gpa = testing.allocator };
    defer reg.deinit();

    try reg.recordStart(.{
        .id = "subagent-1",
        .parent_session_id = "parent-a",
        .label = "researcher",
        .prompt = "find the answer",
        .started_at_ms = 1000,
    });
    try reg.recordStart(.{
        .id = "subagent-2",
        .parent_session_id = "parent-b",
        .prompt = "other task",
        .started_at_ms = 2000,
    });

    // Running rows visible per parent filter.
    const pa = try reg.list(testing.allocator, "parent-a");
    defer Snapshot.freeSnapshots(testing.allocator, pa);
    try testing.expectEqual(@as(usize, 1), pa.len);
    try testing.expectEqual(Status.running, pa[0].status);
    try testing.expectEqualStrings("researcher", pa[0].label);

    // get() while running.
    const got = (try reg.get(testing.allocator, "subagent-1")).?;
    defer got.free(testing.allocator);
    try testing.expect(got.final_text == null);

    // End one run.
    try testing.expect(reg.recordEnd("subagent-1", .completed, "the answer is 42", 150));
    try testing.expect(!reg.recordEnd("ghost", .completed, null, 10)); // unknown id

    const all = try reg.list(testing.allocator, null);
    defer Snapshot.freeSnapshots(testing.allocator, all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqual(Status.completed, all[0].status);
    try testing.expectEqualStrings("the answer is 42", all[0].final_text.?);
    try testing.expectEqual(@as(?i64, 150), all[0].duration_ms);
    try testing.expectEqual(Status.running, all[1].status);
}

test "beginRun/endRun wrappers mint ids and finalize with wall-clock duration" {
    const prev = takeShared();
    defer {
        if (takeShared()) |r| {
            r.deinit();
            std.heap.c_allocator.destroy(r);
        }
        g_registry = prev;
    }

    const id1 = try beginRun(testing.allocator, "sess-p", "", "task one");
    defer testing.allocator.free(id1);
    const id2 = try beginRun(testing.allocator, "sess-p", "named", "task two");
    defer testing.allocator.free(id2);
    try testing.expect(!std.mem.eql(u8, id1, id2));

    endRun(id1, true, "done");
    endRun(id2, false, null);

    const reg = g_registry.?;
    const s1 = (try reg.get(testing.allocator, id1)).?;
    defer s1.free(testing.allocator);
    try testing.expectEqual(Status.completed, s1.status);
    try testing.expect(s1.duration_ms != null); // wall-clock, >= 0
    const s2 = (try reg.get(testing.allocator, id2)).?;
    defer s2.free(testing.allocator);
    try testing.expectEqual(Status.failed, s2.status);
}

test "handleList renders the upstream catalog value" {
    var reg = Registry{ .gpa = testing.allocator };
    defer reg.deinit();
    try reg.recordStart(.{
        .id = "subagent-7",
        .parent_session_id = "sess-x",
        .label = "scout",
        .prompt = "look around",
        .started_at_ms = 5,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prev_g = g_registry;
    g_registry = &reg;
    defer g_registry = prev_g;

    const value = try handleList(a,
        \\{"parentSessionId":"sess-x"}
    );
    try testing.expectEqualStrings(
        "{\"entries\":[{\"kind\":\"child\",\"id\":\"subagent-7\",\"mode\":\"one-shot\",\"activity\":\"running\",\"hasChildren\":false,\"label\":\"scout\"}],\"parentAvailable\":true}",
        value,
    );

    // Wrong parent → empty catalog, still valid value.
    const empty = try handleList(a,
        \\{"parentSessionId":"other"}
    );
    try testing.expectEqualStrings("{\"entries\":[],\"parentAvailable\":true}", empty);

    // Missing required field → PayloadInvalid (router maps bad-request).
    try testing.expectError(error.PayloadInvalid, handleList(a, "{}"));
}

test "handleHistory synthesizes summary events with the session.history envelope" {
    var reg = Registry{ .gpa = testing.allocator };
    defer reg.deinit();
    try reg.recordStart(.{
        .id = "subagent-3",
        .parent_session_id = "p",
        .label = "worker",
        .prompt = "do it",
        .started_at_ms = 1755946500000,
    });
    _ = reg.recordEnd("subagent-3", .completed, "it is done", 42);

    const prev_g = g_registry;
    g_registry = &reg;
    defer g_registry = prev_g;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const value = try handleHistory(a,
        \\{"parentSessionId":"p","childSessionId":"subagent-3","mode":"one-shot"}
    );

    // Two entries (user/message then assistant/message), tail-page projections
    // carrying the label as title — byte shapes come from sessions.zig.
    try testing.expect(std.mem.indexOf(u8, value, "\"events\":[{\"event\":{\"type\":\"user/message\"") != null);
    try testing.expect(std.mem.indexOf(u8, value, "\"type\":\"assistant/message\"") != null);
    try testing.expect(std.mem.indexOf(u8, value, "\"text\":\"do it\"") != null);
    try testing.expect(std.mem.indexOf(u8, value, "\"hasMore\":false") != null);
    try testing.expect(std.mem.indexOf(u8, value, "\"title\":") != null); // title is now first user msg, not session id

    // Continuable mode rejected; unknown child → SessionNotFound.
    try testing.expectError(error.PayloadInvalid, handleHistory(a,
        \\{"parentSessionId":"p","childSessionId":"subagent-3","mode":"continuable"}
    ));
    try testing.expectError(error.SessionNotFound, handleHistory(a,
        \\{"parentSessionId":"p","childSessionId":"subagent-999","mode":"one-shot"}
    ));

    // Parent mismatch hides the child entirely.
    try testing.expectError(error.SessionNotFound, handleHistory(a,
        \\{"parentSessionId":"wrong","childSessionId":"subagent-3","mode":"one-shot"}
    ));

    // Running child renders ONLY the prompt message.
    try reg.recordStart(.{
        .id = "subagent-4",
        .parent_session_id = "p",
        .prompt = "still going",
        .started_at_ms = 1,
    });
    const running_value = try handleHistory(a,
        \\{"parentSessionId":"p","childSessionId":"subagent-4","mode":"one-shot"}
    );
    try testing.expect(std.mem.indexOf(u8, running_value, "\"user/message\"") != null);
    try testing.expect(std.mem.indexOf(u8, running_value, "\"assistant/message\"") == null);
}
