//! Goals RPC domain — wire truth:
//! `_ref/deepseek-harness/packages/host/apiproxy/src/api/goals{,.schema}.ts`
//! plus the durable vocabulary of `packages/goal/goal/src/{types,fold,domain}.ts`.
//!
//! ── CONTRACT ──────────────────────────────────────────────────────────────
//! Methods (rpc-map.ts): goal.create / goal.edit / goal.pause / goal.resume /
//! goal.complete / goal.clear. Every mutation payload carries {sessionId,
//! ref:{id,revision}} (create omits ref and takes {sessionId,objective,
//! maxGoalRounds?}); every non-clear mutation answers {"ref":{"id","revision"}}
//! and clear answers {"cleared":true}. There is NO goal.get: the read side is
//! exclusively the session's `'goal'` projection, carried by
//!
//!   1. the session.history tail-page projections block (key "goal"), and
//!   2. live `session/projection` mux frames, plus
//!   3. a whole-value `goal/change` session/event mux frame per mutation.
//!
//! Emitted frame payloads (ServerRequest full form applied by events_ws):
//!   method "session/event",       payload {"type":"session/event",
//!     "sessionId":…,"event":{"type":"goal/change","seq":N,"time":ms,
//!     "data":<GoalChangeMeta>}}
//!   method "session/projection",  payload {"type":"session/projection",
//!     "sessionId":…,"key":"goal","value":<GoalProjection|null>,"seq":N}
//!
//! GoalChangeMeta (goal/goal/src/domain.ts): snapshots carry
//!   {"kind":"goal/change","version":1,"operation":"create|edit|pause|resume|
//!    complete|block","goal":<GoalSnapshot>,"roundsStarted":N,"createdAt":ms,
//!    "updatedAt":ms}
//! and clear carries a tombstone
//!   {"kind":"goal/change","version":1,"operation":"clear",
//!    "cleared":{"id","revision"},"clearedAt":ms}.
//! GoalSnapshot = {"id","revision","objective","phase","maxGoalRounds"}
//! (+"blockedReason":{code,message} exactly while phase="blocked").
//! GoalProjection = {"goal":<GoalSnapshot>,"roundsStarted","createdAt",
//! "updatedAt"} — null before the first create and after a clear.
//!
//! ── STATE ─────────────────────────────────────────────────────────────────
//! NEW process-global store (singleton, events_ws.sharedHubs pattern): one
//! SpinLock-guarded table keyed by sessionId. Durable in-process ONLY —
//! zharness has no per-session event log yet, so goals do not survive a
//! restart (documented limitation; the fold-based replay above means a future
//! log automatically restores them). CAS discipline mirrors upstream: a ref
//! whose revision is not the current one fails the mutation.
//!
//! Threading: RPC handlers run on connection threads; every entry point locks
//! the store spinlock for the duration of one tiny critical section (copy out
//! + counter bumps). Frame publishing happens OUTSIDE the lock and never
//! fails the RPC (observability discipline).
//!
//! Sequencing deviation (documented): upstream seq is per-session-log; the
//! store emits a PROCESS-GLOBAL monotonic seq. Clients stitch per session by
//! monotonicity and resync via history refetch, so this stays compatible.
//!
//! INTEGRATOR HOOK (one line, main.zig / tool path): when the agent's
//! goal_set tool mutates the AgentLoop GoalBoard, call
//!   try goals_rpc.shared().agentObjective(session_id, objective_text);
//! which performs create-or-edit under the store lock AND publishes the two
//! mux frames, keeping the GUI goal bar in sync with the native board.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const events_ws = @import("events_ws.zig");
const router = @import("router.zig");

// ── lock (events_ws.zig design copy) ────────────────────────────────────────

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

fn backoffSleepMs(ms: u64) void {
    const req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
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

fn nowMs() i64 {
    // Seconds-resolution libc clock × 1000, matching router.nowMs().
    const clib = @import("../../clib.zig");
    return clib.nowTimestamp() * std.time.ms_per_s;
}

// ── domain types ────────────────────────────────────────────────────────────

/// Durable continuation phase (goal/goal/src/types.ts GoalPhase).
pub const Phase = enum {
    active,
    paused,
    blocked,
    complete,

    pub fn asStr(self: Phase) []const u8 {
        return @tagName(self);
    }
};

/// One durable goal snapshot (GoalSnapshot minus the blockedReason union —
/// rendered conditionally from the optional fields below).
pub const Snapshot = struct {
    id: []const u8,
    revision: u64,
    objective: []const u8,
    phase: Phase,
    /// Present exactly while phase == .blocked.
    blocked_code: ?[]const u8 = null,
    blocked_message: ?[]const u8 = null,
    max_goal_rounds: u64,
};

/// The `'goal'` projection value (GoalProjection in types.ts): current goal
/// plus replay counters. `snapshot == null` renders JSON `null`.
pub const Projection = struct {
    snapshot: ?Snapshot = null,
    rounds_started: u64 = 0,
    created_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
};

pub const MutationError = error{
    /// goal.create while a non-complete goal exists.
    GoalExists,
    /// Mutation addressed a session with no current goal.
    NoGoal,
    /// CAS failure: ref.id/revision does not match the current goal.
    RefMismatch,
    /// Phase machine rejection (pause of a paused goal, complete of a
    /// complete goal, resume with an exhausted round budget, …).
    BadPhase,
    OutOfMemory,
};

/// One committed mutation, ready for rendering + publication.
pub const Outcome = struct {
    ref_id: []const u8,
    revision: u64,
    /// GoalOperation recorded in the emitted goal/change event
    /// ("create"|"edit"|"pause"|"resume"|"complete"|"clear").
    operation: []const u8 = "edit",
    /// Whether this was goal.clear (answer {"cleared":true}, tombstone event).
    cleared: bool = false,
    /// Post-change projection (null snapshot for clears).
    projection: Projection,
};

// ── pure JSON builders (byte shapes vs upstream zod/fold decoder) ──────────

/// GoalSnapshot object bytes (fold.ts decodeSnapshot exact key sets).
pub fn appendSnapshotJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: *const Snapshot) !void {
    try out.appendSlice(alloc, "{\"id\":");
    try jsonx.appendJsonString(alloc, out, s.id);
    try out.appendSlice(alloc, ",\"revision\":");
    try jsonx.appendInt(alloc, out, @intCast(s.revision));
    try out.appendSlice(alloc, ",\"objective\":");
    try jsonx.appendJsonString(alloc, out, s.objective);
    try out.appendSlice(alloc, ",\"phase\":");
    try jsonx.appendJsonString(alloc, out, s.phase.asStr());
    if (s.phase == .blocked) {
        try out.appendSlice(alloc, ",\"blockedReason\":{\"code\":");
        try jsonx.appendJsonString(alloc, out, s.blocked_code orelse "blocked");
        try out.appendSlice(alloc, ",\"message\":");
        try jsonx.appendJsonString(alloc, out, s.blocked_message orelse "blocked");
        try out.appendSlice(alloc, "}");
    }
    try out.appendSlice(alloc, ",\"maxGoalRounds\":");
    try jsonx.appendInt(alloc, out, @intCast(s.max_goal_rounds));
    try out.appendSlice(alloc, "}");
}

/// GoalChangeMeta event-data bytes for a snapshot operation.
pub fn changeEventDataJson(
    alloc: std.mem.Allocator,
    operation: []const u8,
    s: *const Snapshot,
    rounds_started: u64,
    created_at_ms: i64,
    updated_at_ms: i64,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"kind\":\"goal/change\",\"version\":1,\"operation\":");
    try jsonx.appendJsonString(alloc, &out, operation);
    try out.appendSlice(alloc, ",\"goal\":");
    try appendSnapshotJson(alloc, &out, s);
    try out.appendSlice(alloc, ",\"roundsStarted\":");
    try jsonx.appendInt(alloc, &out, @intCast(rounds_started));
    try out.appendSlice(alloc, ",\"createdAt\":");
    try jsonx.appendInt(alloc, &out, created_at_ms);
    try out.appendSlice(alloc, ",\"updatedAt\":");
    try jsonx.appendInt(alloc, &out, updated_at_ms);
    try out.appendSlice(alloc, "}");
    return out.toOwnedSlice(alloc);
}

/// GoalChangeMeta clear-tombstone bytes.
pub fn clearEventDataJson(alloc: std.mem.Allocator, id: []const u8, revision: u64, cleared_at_ms: i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"kind\":\"goal/change\",\"version\":1,\"operation\":\"clear\",\"cleared\":{\"id\":");
    try jsonx.appendJsonString(alloc, &out, id);
    try out.appendSlice(alloc, ",\"revision\":");
    try jsonx.appendInt(alloc, &out, @intCast(revision));
    try out.appendSlice(alloc, "},\"clearedAt\":");
    try jsonx.appendInt(alloc, &out, cleared_at_ms);
    try out.appendSlice(alloc, "}");
    return out.toOwnedSlice(alloc);
}

/// GoalProjection value bytes (null when no snapshot).
pub fn projectionValueJson(alloc: std.mem.Allocator, p: *const Projection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (p.snapshot) |*s| {
        try out.appendSlice(alloc, "{\"goal\":");
        try appendSnapshotJson(alloc, &out, s);
        try out.appendSlice(alloc, ",\"roundsStarted\":");
        try jsonx.appendInt(alloc, &out, @intCast(p.rounds_started));
        try out.appendSlice(alloc, ",\"createdAt\":");
        try jsonx.appendInt(alloc, &out, p.created_at_ms);
        try out.appendSlice(alloc, ",\"updatedAt\":");
        try jsonx.appendInt(alloc, &out, p.updated_at_ms);
        try out.appendSlice(alloc, "}");
    } else {
        try out.appendSlice(alloc, "null");
    }
    return out.toOwnedSlice(alloc);
}

/// session/event mux-frame PAYLOAD bytes (full form added at publish).
pub fn eventFramePayloadJson(alloc: std.mem.Allocator, session_id: []const u8, seq: u64, time_ms: i64, event_data_json: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"session/event\",\"sessionId\":");
    try jsonx.appendJsonString(alloc, &out, session_id);
    try out.appendSlice(alloc, ",\"event\":{\"type\":\"goal/change\",\"seq\":");
    try jsonx.appendInt(alloc, &out, @intCast(seq));
    try out.appendSlice(alloc, ",\"time\":");
    try jsonx.appendInt(alloc, &out, time_ms);
    try out.appendSlice(alloc, ",\"data\":");
    try out.appendSlice(alloc, event_data_json);
    try out.appendSlice(alloc, "}}");
    return out.toOwnedSlice(alloc);
}

/// session/projection mux-frame PAYLOAD bytes.
pub fn projectionFramePayloadJson(alloc: std.mem.Allocator, session_id: []const u8, seq: u64, value_json: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"session/projection\",\"sessionId\":");
    try jsonx.appendJsonString(alloc, &out, session_id);
    try out.appendSlice(alloc, ",\"key\":\"goal\",\"value\":");
    try out.appendSlice(alloc, value_json);
    try out.appendSlice(alloc, ",\"seq\":");
    try jsonx.appendInt(alloc, &out, @intCast(seq));
    try out.appendSlice(alloc, "}");
    return out.toOwnedSlice(alloc);
}

/// Publish one committed mutation as the two mux frames. Never fails the
/// caller (fan-out failures stay invisible, obs.fanout discipline). Allocates
/// from the hub allocator (process-lifetime).
pub fn publishMutation(store: *GoalStore, session_id: []const u8, outcome: *const Outcome) void {
    const hubs = events_ws.sharedHubs() catch return;
    const alloc = hubs.mux.alloc;

    const seq = store.nextSeqLockedRead();
    const t = nowMs();

    const event_data = if (outcome.cleared)
        clearEventDataJson(alloc, outcome.ref_id, outcome.revision, t) catch return
    else
        changeEventDataJson(
            alloc,
            outcome.operation,
            &outcome.projection.snapshot.?,
            outcome.projection.rounds_started,
            outcome.projection.created_at_ms,
            outcome.projection.updated_at_ms,
        ) catch return;
    defer alloc.free(event_data);

    const proj_val = projectionValueJson(alloc, &outcome.projection) catch return;
    defer alloc.free(proj_val);

    const ev_payload = eventFramePayloadJson(alloc, session_id, seq, t, event_data) catch return;
    defer alloc.free(ev_payload);
    hubs.mux.publish("session/event", ev_payload);

    const pr_payload = projectionFramePayloadJson(alloc, session_id, seq, proj_val) catch return;
    defer alloc.free(pr_payload);
    hubs.mux.publish("session/projection", pr_payload);
}

// ── the store ───────────────────────────────────────────────────────────────

const Entry = struct {
    session_id: []u8,
    projection: Projection = .{},
};

pub const GoalStore = struct {
    alloc: std.mem.Allocator,
    lock: SpinLock = .{},
    entries: std.ArrayList(Entry) = .empty,
    goal_counter: u64 = 0,
    event_seq: u64 = 0,

    fn findLocked(self: *GoalStore, session_id: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.session_id, session_id)) return e;
        }
        return null;
    }

    fn nextSeqLockedRead(self: *GoalStore) u64 {
        self.lock.lock();
        defer self.lock.unlock();
        self.event_seq += 1;
        return self.event_seq;
    }

    /// Fresh minted goal id ("goal-<n>", process-local uniqueness is the only
    /// requirement — ids are opaque branded strings client-side).
    fn mintId(self: *GoalStore) ![]u8 {
        self.goal_counter += 1;
        return std.fmt.allocPrint(self.alloc, "goal-{d}", .{self.goal_counter});
    }

    /// goal.create: fresh active revision-one goal with zero rounds. Fails
    /// while a non-complete goal exists (upstream fold rule).
    pub fn create(self: *GoalStore, session_id: []const u8, objective: []const u8, max_rounds: ?u64) MutationError!Outcome {
        if (objective.len == 0) return error.RefMismatch; // zod min(1) → caller maps bad-request earlier
        self.lock.lock();
        defer self.lock.unlock();

        const t = nowMs();
        if (self.findLocked(session_id)) |e| {
            if (e.projection.snapshot) |s| {
                if (s.phase != .complete) return error.GoalExists;
                // Re-arm over a completed/tombstoned slot: release the old
                // snapshot, reset counters.
                var old = e.projection;
                freeProjection(self.alloc, &old);
                e.projection = .{};
            }
        }
        const id = self.mintId() catch return error.OutOfMemory;
        const obj_copy = self.alloc.dupe(u8, objective) catch return error.OutOfMemory;
        const snap = Snapshot{
            .id = id,
            .revision = 1,
            .objective = obj_copy,
            .phase = .active,
            .max_goal_rounds = max_rounds orelse 16,
        };
        const e = self.findLocked(session_id) orelse blk: {
            self.entries.append(self.alloc, .{
                .session_id = self.alloc.dupe(u8, session_id) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
            break :blk &self.entries.items[self.entries.items.len - 1];
        };
        e.projection = .{
            .snapshot = snap,
            .rounds_started = 0,
            .created_at_ms = t,
            .updated_at_ms = t,
        };
        return .{
            .ref_id = snap.id,
            .revision = 1,
            .operation = "create",
            .projection = dupeProjectionArena(&e.projection) orelse return error.OutOfMemory,
        };
    }

    /// Shared CAS guard: entry must exist, its snapshot must match id AND
    /// revision. Returns the entry pointer under the lock.
    fn casLocked(self: *GoalStore, session_id: []const u8, id: []const u8, revision: u64) MutationError!*Entry {
        const e = self.findLocked(session_id) orelse return error.NoGoal;
        const cur = e.projection.snapshot orelse return error.NoGoal;
        if (!std.mem.eql(u8, cur.id, id)) return error.RefMismatch;
        if (cur.revision != revision) return error.RefMismatch;
        return e;
    }

    fn bumpRevision(self: *GoalStore, e: *Entry, phase: Phase, objective_override: ?[]const u8, max_override: ?u64, t: i64) MutationError!void {
        var snap = e.projection.snapshot.?;
        snap.revision += 1;
        snap.phase = phase;
        if (objective_override) |o| {
            const copy = self.alloc.dupe(u8, o) catch return error.OutOfMemory;
            self.alloc.free(snap.objective);
            snap.objective = copy;
        }
        if (max_override) |m| snap.max_goal_rounds = m;
        if (phase != .blocked) {
            snap.blocked_code = null;
            snap.blocked_message = null;
        }
        e.projection.snapshot = snap;
        e.projection.updated_at_ms = t;
    }

    /// goal.edit: objective and/or round cap without changing phase.
    pub fn edit(self: *GoalStore, session_id: []const u8, id: []const u8, revision: u64, objective: ?[]const u8, max_rounds: ?u64) MutationError!Outcome {
        if (objective == null and max_rounds == null) return error.BadPhase; // refine: requires one
        self.lock.lock();
        defer self.lock.unlock();
        const e = try self.casLocked(session_id, id, revision);
        const t = nowMs();
        try self.bumpRevision(e, e.projection.snapshot.?.phase, objective, max_rounds, t);
        return .{
            .ref_id = e.projection.snapshot.?.id,
            .revision = e.projection.snapshot.?.revision,
            .operation = "edit",
            .projection = dupeProjectionArena(&e.projection) orelse return error.OutOfMemory,
        };
    }

    /// goal.pause: active → paused.
    pub fn pause(self: *GoalStore, session_id: []const u8, id: []const u8, revision: u64) MutationError!Outcome {
        self.lock.lock();
        defer self.lock.unlock();
        const e = try self.casLocked(session_id, id, revision);
        if (e.projection.snapshot.?.phase != .active) return error.BadPhase;
        const t = nowMs();
        try self.bumpRevision(e, .paused, null, null, t);
        return .{
            .ref_id = e.projection.snapshot.?.id,
            .revision = e.projection.snapshot.?.revision,
            .operation = "pause",
            .projection = dupeProjectionArena(&e.projection) orelse return error.OutOfMemory,
        };
    }

    /// goal.resume: paused/blocked/active → armed-active (upstream fold
    /// admits resume from those phases; exhausted budgets fail).
    pub fn resumeGoal(self: *GoalStore, session_id: []const u8, id: []const u8, revision: u64) MutationError!Outcome {
        self.lock.lock();
        defer self.lock.unlock();
        const e = try self.casLocked(session_id, id, revision);
        const cur = e.projection.snapshot.?;
        const resumable = [_]Phase{ .active, .paused, .blocked };
        var ok = false;
        for (resumable) |p| {
            if (cur.phase == p) ok = true;
        }
        if (!ok or e.projection.rounds_started >= cur.max_goal_rounds) return error.BadPhase;
        const t = nowMs();
        try self.bumpRevision(e, .active, null, null, t);
        return .{
            .ref_id = e.projection.snapshot.?.id,
            .revision = e.projection.snapshot.?.revision,
            .operation = "resume",
            .projection = dupeProjectionArena(&e.projection) orelse return error.OutOfMemory,
        };
    }

    /// goal.complete: any non-complete phase → complete.
    pub fn complete(self: *GoalStore, session_id: []const u8, id: []const u8, revision: u64) MutationError!Outcome {
        self.lock.lock();
        defer self.lock.unlock();
        const e = try self.casLocked(session_id, id, revision);
        if (e.projection.snapshot.?.phase == .complete) return error.BadPhase;
        const t = nowMs();
        try self.bumpRevision(e, .complete, null, null, t);
        return .{
            .ref_id = e.projection.snapshot.?.id,
            .revision = e.projection.snapshot.?.revision,
            .operation = "complete",
            .projection = dupeProjectionArena(&e.projection) orelse return error.OutOfMemory,
        };
    }

    /// goal.clear: tombstone the current goal; projection folds to null and
    /// counters reset (fold.ts applyGoalChange clear arm).
    pub fn clear(self: *GoalStore, session_id: []const u8, id: []const u8, revision: u64) MutationError!Outcome {
        self.lock.lock();
        defer self.lock.unlock();
        const e = try self.casLocked(session_id, id, revision);
        const cur = e.projection.snapshot.?;
        const out_revision = cur.revision;
        const kept_id = self.alloc.dupe(u8, cur.id) catch return error.OutOfMemory;
        e.projection = .{}; // null snapshot, zeroed counters
        return .{
            .ref_id = kept_id,
            .revision = out_revision,
            .operation = "clear",
            .cleared = true,
            .projection = .{},
        };
    }

    /// Current projection copy (for history tail-page projections blocks and
    /// the integrator's session.list assembly). Arena-owned result.
    pub fn projectionOf(self: *GoalStore, alloc: std.mem.Allocator, session_id: []const u8) !?Projection {
        self.lock.lock();
        defer self.lock.unlock();
        const e = self.findLocked(session_id) orelse return null;
        return try dupProjection(alloc, &e.projection);
    }

    /// Hydrate the process-global store from a durable snapshot (replay after
    /// restart). Replaces any existing projection for `session_id` without CAS.
    pub fn hydrate(self: *GoalStore, session_id: []const u8, snapshot: Snapshot, rounds_started: u64, created_at_ms: i64, updated_at_ms: i64) !void {
        self.lock.lock();
        defer self.lock.unlock();
        const e = self.findLocked(session_id) orelse blk: {
            self.entries.append(self.alloc, .{
                .session_id = try self.alloc.dupe(u8, session_id),
            }) catch return error.OutOfMemory;
            break :blk &self.entries.items[self.entries.items.len - 1];
        };
        if (e.projection.snapshot) |old| {
            var old_proj = e.projection;
            freeProjection(self.alloc, &old_proj);
            _ = old;
        }
        const id_copy = try self.alloc.dupe(u8, snapshot.id);
        const obj_copy = try self.alloc.dupe(u8, snapshot.objective);
        var blk_code: ?[]const u8 = null;
        var blk_msg: ?[]const u8 = null;
        if (snapshot.blocked_code) |c| blk_code = try self.alloc.dupe(u8, c);
        if (snapshot.blocked_message) |m| blk_msg = try self.alloc.dupe(u8, m);
        e.projection = .{
            .snapshot = .{
                .id = id_copy,
                .revision = snapshot.revision,
                .objective = obj_copy,
                .phase = snapshot.phase,
                .blocked_code = blk_code,
                .blocked_message = blk_msg,
                .max_goal_rounds = snapshot.max_goal_rounds,
            },
            .rounds_started = rounds_started,
            .created_at_ms = created_at_ms,
            .updated_at_ms = updated_at_ms,
        };
        // Keep event_seq monotonic for new hydration (no seq bump needed, but
        // ensure later mutations still increment).
        self.event_seq += 1;
    }
};

/// Copy a projection into the REQUEST arena (handlers render from these).
fn dupeProjectionArena(p: *const Projection) ?Projection {
    return dupProjection(std.heap.page_allocator, p) catch null;
}

fn dupProjection(alloc: std.mem.Allocator, p: *const Projection) !?Projection {
    const s = p.snapshot orelse return p.*;
    return .{
        .snapshot = .{
            .id = try alloc.dupe(u8, s.id),
            .revision = s.revision,
            .objective = try alloc.dupe(u8, s.objective),
            .phase = s.phase,
            .blocked_code = if (s.blocked_code) |c| try alloc.dupe(u8, c) else null,
            .blocked_message = if (s.blocked_message) |m| try alloc.dupe(u8, m) else null,
            .max_goal_rounds = s.max_goal_rounds,
        },
        .rounds_started = p.rounds_started,
        .created_at_ms = p.created_at_ms,
        .updated_at_ms = p.updated_at_ms,
    };
}

/// Release a projection copy owned by `alloc` (store-lifetime strings).
fn freeProjection(alloc: std.mem.Allocator, p: *const Projection) void {
    const s = p.snapshot orelse return;
    alloc.free(s.id);
    alloc.free(s.objective);
    if (s.blocked_code) |c| alloc.free(c);
    if (s.blocked_message) |m| alloc.free(m);
}

var g_store: ?*GoalStore = null;

/// Process-global singleton (serve mode). State outlives every request, so
/// the store deliberately allocates from std.heap.page_allocator — NEVER from
/// a per-connection arena.
pub fn shared() !*GoalStore {
    if (g_store) |s| return s;
    const s = try std.heap.page_allocator.create(GoalStore);
    s.* = .{ .alloc = std.heap.page_allocator };
    g_store = s;
    return s;
}

/// Test/integrator hook: detach the singleton (caller frees).
pub fn takeShared() ?*GoalStore {
    const s = g_store;
    g_store = null;
    return s;
}

/// INTEGRATOR HOOK: bridge from the agent's goal_set tool path. Creates the
/// session goal when none exists, otherwise CAS-free edits the objective to
/// the newest text (the native board holds single-writer authority; the GUI's
/// own writes go through the guarded RPC verbs). Publishes the two mux frames
/// on success; failures stay invisible (the native board remains truthful).
pub fn agentObjective(session_id: []const u8, objective: []const u8) void {
    const store = shared() catch return;
    var arena = std.heap.ArenaAllocator.init(store.alloc);
    defer arena.deinit();
    const snap = blk: {
        store.lock.lock();
        defer store.lock.unlock();
        const e = store.findLocked(session_id) orelse break :blk null;
        break :blk e.projection.snapshot;
    };
    var outcome: Outcome = undefined;
    if (snap) |cur| {
        outcome = store.edit(session_id, cur.id, cur.revision, objective, null) catch return;
    } else {
        outcome = store.create(session_id, objective, null) catch return;
    }
    defer freeOutcome(store.alloc, &outcome);
    publishMutation(store, session_id, &outcome);
}

fn freeOutcome(alloc: std.mem.Allocator, o: *Outcome) void {
    // For non-clear outcomes ref_id ALIASES projection.snapshot.id (single
    // allocation) — free it only in the clear case where it is distinct.
    if (o.cleared) alloc.free(o.ref_id);
    if (o.projection.snapshot) |s| {
        alloc.free(s.id);
        alloc.free(s.objective);
        if (s.blocked_code) |c| alloc.free(c);
        if (s.blocked_message) |m| alloc.free(m);
    }
}

// ── payload parsing (router-shaped helpers, local copies) ──────────────────

const PayloadError = error{ PayloadInvalid, OutOfMemory };

fn reqString(alloc: std.mem.Allocator, payload: []const u8, key: []const u8) PayloadError![]const u8 {
    const raw = jsonx.getRaw(payload, key) orelse return error.PayloadInvalid;
    if (!jsonx.isString(raw)) return error.PayloadInvalid;
    return jsonx.decodeString(alloc, raw[1 .. raw.len - 1]) catch return error.OutOfMemory;
}

fn optString(alloc: std.mem.Allocator, payload: []const u8, key: []const u8) PayloadError!?[]const u8 {
    const raw = jsonx.getRaw(payload, key) orelse return null;
    if (!jsonx.isString(raw)) return error.PayloadInvalid;
    return jsonx.decodeString(alloc, raw[1 .. raw.len - 1]) catch return error.OutOfMemory;
}

fn optU64(payload: []const u8, key: []const u8) PayloadError!?u64 {
    const raw = jsonx.getRaw(payload, key) orelse return null;
    if (jsonx.isString(raw)) return error.PayloadInvalid;
    const i = jsonx.getInt(payload, key) orelse return error.PayloadInvalid;
    if (i <= 0) return error.PayloadInvalid; // positive per zod
    return @intCast(i);
}

/// Parse {"id":…,"revision":…} (goalRefSchema). Strings decode into `alloc`.
fn parseRef(alloc: std.mem.Allocator, payload: []const u8) PayloadError!struct { id: []const u8, revision: u64 } {
    const raw = jsonx.getRaw(payload, "ref") orelse return error.PayloadInvalid;
    // getRaw expects a full JSON object (outer braces kept), so probe `raw`
    // directly instead of its stripped body.
    const id = try reqString(alloc, raw, "id");
    const rev_raw = jsonx.getRaw(raw, "revision") orelse return error.PayloadInvalid;
    if (jsonx.isString(rev_raw)) return error.PayloadInvalid;
    const rev = jsonx.getInt(raw, "revision") orelse return error.PayloadInvalid;
    if (rev <= 0) return error.PayloadInvalid;
    return .{ .id = id, .revision = @intCast(rev) };
}

// ── handlers (wired from router.dispatch; arena allocator throughout) ──────

fn answerRef(alloc: std.mem.Allocator, rpc_id: []const u8, o: *const Outcome) !router.UnaryResponse {
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"ref\":{\"id\":");
    try jsonx.appendJsonString(alloc, &value, o.ref_id);
    try value.appendSlice(alloc, ",\"revision\":");
    try jsonx.appendInt(alloc, &value, @intCast(o.revision));
    try value.appendSlice(alloc, "}}");
    return router.okValue(alloc, rpc_id, value.items);
}

fn finishMutation(alloc: std.mem.Allocator, rpc_id: []const u8, session_id: []const u8, outcome: *const Outcome) !router.UnaryResponse {
    publishMutation(shared() catch unreachable, session_id, outcome);
    if (outcome.cleared) {
        defer freeOutcome(std.heap.page_allocator, @constCast(outcome));
        return router.okValue(alloc, rpc_id, "{\"cleared\":true}");
    }
    defer freeOutcome(std.heap.page_allocator, @constCast(outcome));
    return answerRef(alloc, rpc_id, outcome);
}

fn mapGoalError(alloc: std.mem.Allocator, rpc_id: []const u8, e: anyerror) !router.UnaryResponse {
    switch (e) {
        error.GoalExists, error.NoGoal, error.RefMismatch, error.BadPhase => {
            const msg = switch (e) {
                error.GoalExists => "a goal already exists for this session",
                error.NoGoal => "no current goal for this session",
                error.RefMismatch => "goal ref does not match the current goal (stale revision)",
                else => "goal verb rejected by the phase machine",
            };
            // Deviation (documented): upstream's closed code union has no
            // goal-conflict code; state failures land on bad-request.
            return router.errValue(alloc, rpc_id, .bad_request, msg, "{\"issues\":[]}");
        },
        error.PayloadInvalid => return error.PayloadInvalid, // run() renders bad-request
        else => return e,
    }
}

/// Dispatch one goal.* method (called from router.dispatch). Payload
/// validation errors flow back as error.PayloadInvalid for run()'s renderer.
pub fn handle(method: []const u8, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !router.UnaryResponse {
    const store = shared() catch return error.OutOfMemory;
    const session_id = try reqString(alloc, payload, "sessionId");

    if (std.mem.eql(u8, method, "goal.create")) {
        const objective = try reqString(alloc, payload, "objective");
        const max_rounds = try optU64(payload, "maxGoalRounds");
        const outcome = store.create(session_id, objective, max_rounds) catch |e| return mapGoalError(alloc, rpc_id, e);
        return finishMutation(alloc, rpc_id, session_id, &outcome);
    }

    const ref = parseRef(alloc, payload) catch |e| return e;

    if (std.mem.eql(u8, method, "goal.edit")) {
        const objective = try optString(alloc, payload, "objective");
        const max_rounds = try optU64(payload, "maxGoalRounds");
        const outcome = store.edit(session_id, ref.id, ref.revision, objective, max_rounds) catch |e| return mapGoalError(alloc, rpc_id, e);
        return finishMutation(alloc, rpc_id, session_id, &outcome);
    }
    if (std.mem.eql(u8, method, "goal.pause")) {
        const outcome = store.pause(session_id, ref.id, ref.revision) catch |e| return mapGoalError(alloc, rpc_id, e);
        return finishMutation(alloc, rpc_id, session_id, &outcome);
    }
    if (std.mem.eql(u8, method, "goal.resume")) {
        const outcome = store.resumeGoal(session_id, ref.id, ref.revision) catch |e| return mapGoalError(alloc, rpc_id, e);
        return finishMutation(alloc, rpc_id, session_id, &outcome);
    }
    if (std.mem.eql(u8, method, "goal.complete")) {
        const outcome = store.complete(session_id, ref.id, ref.revision) catch |e| return mapGoalError(alloc, rpc_id, e);
        return finishMutation(alloc, rpc_id, session_id, &outcome);
    }
    if (std.mem.eql(u8, method, "goal.clear")) {
        const outcome = store.clear(session_id, ref.id, ref.revision) catch |e| return mapGoalError(alloc, rpc_id, e);
        return finishMutation(alloc, rpc_id, session_id, &outcome);
    }

    return error.PayloadInvalid; // unknown goal verb → bad-request upstream
}
