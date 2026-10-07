//! Interactive user-questions: the pending-question store + the REAL
//! /api/respond handler (wave 6, G3-interactive).
//!
//! Contract truth: `_ref/deepseek-harness/packages/host/apiproxy/src/api-proxy.ts`
//! (`pendingQuestions` map + `respond()`), `api/events.schema.ts`
//! (question/requested + question/resolved frames,
//! askUserQuestionItemSchema), and `api/questions.schema.ts`
//! (questionResponsePayloadSchema). Upstream flow:
//!
//!   1. host emits on the mux stream a ServerRequest whose rpcId IS the
//!      questionRpcId: {"type":"question/requested","sessionId","questions":[…]}
//!   2. browser answers with POST /api/respond
//!      {type:'client-response', rpcId:<echoed>,
//!       result:{ok:true, value:{sessionId, answer:{answers:[{id,selected[],custom?}]}}}}
//!      or result:{ok:false, error:{code:'cancelled',…}}
//!   3. respond routes by the echoed rpcId through the pending table,
//!      validates the answer batch against the EXACT question request
//!      (count, per-index ids, label membership, single/multi rules),
//!      settles the entry, and emits {"type":"question/resolved",
//!      "sessionId","questionRpcId","outcome":"answered"|"cancelled"}.
//!
//! zharness mapping: the waiting side is NOT a promise but a pollable
//! Pending entry — src/tool/ask_user.zig registers it via `ask`, publishes
//! the requested frame itself, then polls `Pending.state` (250 ms tick) and
//! finally claims the terminal outcome with `claimWaiter`. The claim is the
//! ONLY place entries are freed, so a timeout racing an in-flight respond is
//! serialized by the store lock (whoever takes the lock first wins; the
//! loser sees a settled entry or a not-pending receipt).
//!
//! ── Threading ──────────────────────────────────────────────────────────────
//! One SpinLock (server/events.zig design; std.Thread.Mutex lives under
//! std.Io in this toolchain). Critical sections are tiny (append/lookup/
//! validate); waiters sleep in nanosleep naps between atomic state polls —
//! events_ws spin+nap discipline. Entries allocate from the store allocator,
//! which must outlive every request thread (the singleton uses
//! page_allocator like events_ws.sharedHubs).

const std = @import("std");
const jsonx = @import("jsonx.zig");

// ── lock (same design as events_ws.zig / settings.zig private copies) ───────

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;
extern "c" fn clock_gettime(clk_id: c_int, tp: *std.c.timespec) c_int;

/// Monotonic wall milliseconds WITHOUT an Io handle (std.time.milliTimestamp
/// is gone in this toolchain; CLOCK_MONOTONIC via libc, which -lc links).
pub fn monoMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(@backingInt(std.c.CLOCK.MONOTONIC), &ts);
    return @as(i64, @intCast(ts.sec)) * @as(i64, std.time.ms_per_s) +
        @divTrunc(@as(i64, @intCast(ts.nsec)), @as(i64, std.time.ns_per_ms));
}

/// Sleep without an Io handle (std.Thread.sleep was removed in 0.17).
pub fn backoffSleepMs(ms: u64) void {
    const req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&req, null);
}

/// Minimal test-and-set spin lock with sleep backoff — the codebase's
/// server/events.zig design. Public so sibling modules/tests reuse one
/// implementation instead of copying it.
pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins >= 16) backoffSleepMs(1) else std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

// ── pending entry ───────────────────────────────────────────────────────────

pub const State = enum(u8) {
    waiting = 0,
    answered = 1,
    cancelled = 2,
};

/// One outstanding user question, addressed by its stable questionRpcId.
/// All strings are owned by the store allocator; freed only in remove().
pub const Pending = struct {
    /// Stable server-request id — minted here ("q-<n>"), carried in the
    /// question/requested frame, echoed back by POST /api/respond.
    rpc_id: []const u8,
    session_id: []const u8,
    /// JSON array of AskUserQuestionItem objects (exact upstream item shape:
    /// {id, question, header?, detail?, options?[{label,description?}],
    /// multiSelect?, intent?}).
    questions_json: []const u8,
    /// Terminal state; written under the store lock, polled acquire-side.
    state: std.atomic.Value(u8) = .init(@backingInt(State.waiting)),
    /// Set before state→answered (under the lock): the raw client-response
    /// `result.value` object {"sessionId":…,"answer":{"answers":[…]}}.
    answer_json: ?[]const u8 = null,

    pub fn getState(self: *const Pending) State {
        return @fromBackingInt(@intCast(self.state.load(.acquire)));
    }
};

// ── store ───────────────────────────────────────────────────────────────────

pub const Store = struct {
    alloc: std.mem.Allocator,
    lock: SpinLock = .{},
    pendings: std.ArrayList(*Pending) = .empty,
    counter: u64 = 0,

    /// Initialize IN PLACE. There is no deinit: settled entries are removed
    /// by their waiters, and the process owns release (events_ws posture).
    pub fn initInPlace(self: *Store, alloc: std.mem.Allocator) void {
        self.* = .{ .alloc = alloc };
    }

    pub fn count(self: *Store) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.pendings.items.len;
    }

    /// Register one new pending question. `session_id` and `questions_json`
    /// are duped into the store allocator. Mints a fresh rpc id.
    pub fn ask(self: *Store, session_id: []const u8, questions_json: []const u8) !*Pending {
        self.lock.lock();
        defer self.lock.unlock();

        self.counter += 1;
        var id_buf: [40]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "q-{d}", .{self.counter});

        const p = try self.alloc.create(Pending);
        errdefer self.alloc.destroy(p);
        p.* = .{
            .rpc_id = try self.alloc.dupe(u8, id),
            .session_id = try self.alloc.dupe(u8, session_id),
            .questions_json = try self.alloc.dupe(u8, questions_json),
        };
        errdefer self.alloc.free(p.session_id);
        try self.pendings.append(self.alloc, p);
        return p;
    }

    /// Waiter-side completion (timeout OR observed settle): atomically claims
    /// the terminal outcome and removes+frees the entry. If still `waiting`,
    /// the caller's timeout wins and the outcome reads as cancelled.
    pub const Claim = union(enum) {
        /// Ownership of the answer JSON transfers to the caller's `alloc`.
        answered: []const u8,
        cancelled,
    };

    pub fn claimWaiter(self: *Store, alloc: std.mem.Allocator, p: *Pending) Claim {
        self.lock.lock();
        defer self.lock.unlock();
        return self.claimLocked(alloc, p);
    }

    fn claimLocked(self: *Store, alloc: std.mem.Allocator, p: *Pending) Claim {
        const st = p.getState();
        var answer_copy: ?[]const u8 = null;
        if (st == .answered) {
            if (p.answer_json) |a| answer_copy = alloc.dupe(u8, a) catch null;
        }
        self.removeLocked(p);
        if (st == .answered) {
            if (answer_copy) |a| return .{ .answered = a };
        }
        return .cancelled;
    }

    fn findLocked(self: *Store, rpc_id: []const u8) ?*Pending {
        for (self.pendings.items) |p| {
            if (std.mem.eql(u8, p.rpc_id, rpc_id)) return p;
        }
        return null;
    }

    fn removeLocked(self: *Store, p: *Pending) void {
        for (self.pendings.items, 0..) |q, i| {
            if (q == p) {
                _ = self.pendings.swapRemove(i);
                break;
            }
        }
        self.alloc.free(p.rpc_id);
        self.alloc.free(p.session_id);
        self.alloc.free(p.questions_json);
        if (p.answer_json) |a| self.alloc.free(a);
        self.alloc.destroy(p);
    }

    /// Integrator hook (session.cancel / shutdown): cancel every still-waiting
    /// entry of `session_id` WITHOUT freeing — each waiter observes the
    /// cancelled state on its next poll and cleans its own entry up. Returns
    /// how many entries were flipped.
    pub fn cancelAllForSession(self: *Store, session_id: []const u8) usize {
        var flipped: usize = 0;
        self.lock.lock();
        defer self.lock.unlock();
        for (self.pendings.items) |p| {
            if (p.getState() != .waiting) continue;
            if (!std.mem.eql(u8, p.session_id, session_id)) continue;
            p.state.store(@backingInt(State.cancelled), .release);
            flipped += 1;
        }
        return flipped;
    }

    // ── /api/respond pipeline ───────────────────────────────────────────

    pub const Receipt = struct {
        accepted: bool,
        reason: []const u8 = "",

        pub const not_pending = Receipt{ .accepted = false, .reason = "not-pending" };
        pub const bad_response = Receipt{ .accepted = false, .reason = "bad-response" };
        pub const accepted_ok = Receipt{ .accepted = true };
    };

    /// Route one POST /api/respond body (ClientResponse full form) to its
    /// pending question and settle it. Mirrors upstream api-proxy.respond():
    /// route by echoed rpcId → not-pending when unknown; ok=false requires
    /// error.code 'cancelled' (any other code → bad-response); ok=true
    /// validates the value payload against the exact stored questions before
    /// settling answered. Never frees memory directly — the waiter claims.
    /// Resolve one pending question from the v0.1.6 `$events/result` route:
    /// outcome.kind 'result' carries the bare {answers:[…]} object (the GUI's
    /// AskUserQuestionAnswer), which is wrapped into the canonical respond
    /// value shape {"sessionId":…,"answer":…} before validation; 'rejected'
    /// and 'next' both cancel the request.
    pub fn respondEvent(self: *Store, event_id: []const u8, outcome_kind: []const u8, value_json: []const u8) Receipt {
        // Look up the pending entry first to correlate its session (the
        // canonical respond value carries "sessionId").
        const sid: []u8 = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            const p = self.findLocked(event_id) orelse return .not_pending;
            break :blk self.alloc.dupe(u8, p.session_id) catch return .bad_response;
        };
        defer self.alloc.free(sid);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.alloc);
        const ok_literal = if (std.mem.eql(u8, outcome_kind, "result")) "true" else "false";

        body.appendSlice(self.alloc, "{\"type\":\"client-response\",\"rpcId\":") catch return .bad_response;
        jsonx.appendJsonString(self.alloc, &body, event_id) catch return .bad_response;
        body.appendSlice(self.alloc, ",\"result\":{\"ok\":") catch return .bad_response;
        body.appendSlice(self.alloc, ok_literal) catch return .bad_response;
        if (std.mem.eql(u8, outcome_kind, "result")) {
            body.appendSlice(self.alloc, ",\"value\":{\"sessionId\":") catch return .bad_response;
            jsonx.appendJsonString(self.alloc, &body, sid) catch return .bad_response;
            body.appendSlice(self.alloc, ",\"answer\":") catch return .bad_response;
            body.appendSlice(self.alloc, value_json) catch return .bad_response;
            body.appendSlice(self.alloc, "}") catch return .bad_response;
        }
        body.appendSlice(self.alloc, "}}") catch return .bad_response;
        return self.respond(body.items);
    }

    pub fn respond(self: *Store, body: []const u8) Receipt {
        // Envelope check: only client-response full forms carry answers.
        const t = jsonx.getRaw(body, "type") orelse return .bad_response;
        if (!std.mem.eql(u8, jsonx.trimWs(t), "\"client-response\"")) return .bad_response;

        const rpc_raw = jsonx.getRaw(body, "rpcId") orelse return .bad_response;
        if (!jsonx.isString(rpc_raw)) return .bad_response;

        const result_raw = jsonx.getRaw(body, "result") orelse return .bad_response;

        self.lock.lock();
        defer self.lock.unlock();

        const p = self.findLocked(jsonx.trimWs(rpc_raw[1 .. rpc_raw.len - 1])) orelse
            return .not_pending;
        // Already settled but not yet claimed by its waiter: observably
        // gone from the routing table (upstream deletes entries on claim).
        if (p.getState() != .waiting) return .not_pending;

        const ok_raw = jsonx.getRaw(result_raw, "ok") orelse return .bad_response;
        const ok = std.mem.eql(u8, jsonx.trimWs(ok_raw), "true");

        if (!ok) {
            // Only an explicit user cancellation settles a failed response.
            const err_raw = jsonx.getRaw(result_raw, "error") orelse return .bad_response;
            const code = (jsonx.getStringAlloc(self.alloc, err_raw, "code") catch null) orelse
                return .bad_response;
            defer self.alloc.free(code);
            if (!std.mem.eql(u8, code, "cancelled")) return .bad_response;
            p.state.store(@backingInt(State.cancelled), .release);
            return .accepted_ok;
        }

        // Validate the answer batch against the exact question request
        // (upstream matchesQuestions): sessionId correlation, per-index ids,
        // label membership, duplicate/single/custom rules.
        const value_raw = jsonx.getRaw(result_raw, "value") orelse return .bad_response;
        // Validation allocates scratch from the store allocator (lock held;
        // tiny and bounded — same posture as settings.zig critical sections).
        if (!answerMatches(self.alloc, value_raw, p.session_id, p.questions_json)) return .bad_response;

        const answer_copy = self.alloc.dupe(u8, value_raw) catch return .bad_response;
        p.answer_json = answer_copy;
        p.state.store(@backingInt(State.answered), .release);
        return .accepted_ok;
    }
};

// ── approval state (fail-closed) ────────────────────────────────────────────
//
// Upstream dsh-user-approval: ApprovalPolicy ask|never, ApprovalOutcome
// allowed-once|rejected|cancelled|unavailable. `ask` delegates to answerers;
// with none it fails closed to `unavailable`. `never` deterministically
// rejects without prompting. zharness preserves the same fail-closed posture:
// before any dynamic/escalated operation (sandbox escalation, dynamic plugin
// run) the caller must check `ApprovalStore.check` — an unavailable answerer
// is a rejection, never a bypass.

pub const ApprovalPolicy = enum {
    ask,
    never,

    pub fn fromString(s: []const u8) ?ApprovalPolicy {
        if (std.mem.eql(u8, s, "ask")) return .ask;
        if (std.mem.eql(u8, s, "never")) return .never;
        return null;
    }
    pub fn asStr(self: ApprovalPolicy) []const u8 {
        return switch (self) {
            .ask => "ask",
            .never => "never",
        };
    }
};

pub const ApprovalOutcome = enum {
    allowed_once,
    rejected,
    cancelled,
    unavailable,

    pub fn asStr(self: ApprovalOutcome) []const u8 {
        return switch (self) {
            .allowed_once => "allowed-once",
            .rejected => "rejected",
            .cancelled => "cancelled",
            .unavailable => "unavailable",
        };
    }
    pub fn isAllowed(self: ApprovalOutcome) bool {
        return self == .allowed_once;
    }
};

/// Per-session approval policy store. Fail-closed: default `ask` with no
/// answerer yields `unavailable` (treated as rejection by callers). `never`
/// never consults an answerer. One SpinLock, small map — same discipline as
/// Store above.
pub const ApprovalStore = struct {
    alloc: std.mem.Allocator,
    lock: SpinLock = .{},
    /// session_id (dupe) -> policy. Missing entry = default `ask`.
    policies: std.StringHashMap(ApprovalPolicy) = undefined,
    /// Whether an interactive answerer is currently wired (mux publisher
    /// present). When false, `ask` requests fail closed to `unavailable`.
    has_answerer: bool = false,
    /// Pending approval requests keyed by approval id. Value is an atomic
    /// state byte: 0 waiting, 1 allowed-once, 2 rejected, 3 cancelled.
    pending: std.StringHashMap(std.atomic.Value(u8)) = undefined,

    pub fn initInPlace(self: *ApprovalStore, alloc: std.mem.Allocator) void {
        self.* = .{
            .alloc = alloc,
            .policies = std.StringHashMap(ApprovalPolicy).init(alloc),
            .pending = std.StringHashMap(std.atomic.Value(u8)).init(alloc),
            .has_answerer = false,
        };
    }

    pub fn deinit(self: *ApprovalStore) void {
        var it = self.policies.iterator();
        while (it.next()) |e| self.alloc.free(e.key_ptr.*);
        self.policies.deinit();
        var pit = self.pending.iterator();
        while (pit.next()) |e| self.alloc.free(e.key_ptr.*);
        self.pending.deinit();
    }

    /// Whether an interactive answerer is currently wired.
    pub fn hasAnswerer(self: *ApprovalStore) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.has_answerer;
    }

    /// Register a pending approval request (idempotent per id; resets state).
    pub fn openRequest(self: *ApprovalStore, id: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.pending.getEntry(id)) |e| {
            e.value_ptr.store(0, .release);
            return;
        }
        const key = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(key);
        try self.pending.put(key, std.atomic.Value(u8).init(0));
    }

    /// Settle a pending request. False when the id is unknown.
    pub fn resolve(self: *ApprovalStore, id: []const u8, outcome: ApprovalOutcome) bool {
        self.lock.lock();
        defer self.lock.unlock();
        const e = self.pending.getEntry(id) orelse return false;
        const v: u8 = switch (outcome) {
            .allowed_once => 1,
            .rejected => 2,
            .cancelled => 3,
            .unavailable => 0,
        };
        e.value_ptr.store(v, .release);
        return true;
    }

    /// Drop a pending request (caller owns the id string).
    pub fn drop(self: *ApprovalStore, id: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.pending.fetchRemove(id)) |kv| self.alloc.free(kv.key);
    }

    /// Poll a pending request until settled or `timeout_ms` elapses.
    pub fn await(self: *ApprovalStore, id: []const u8, timeout_ms: u64, poll_ms: u64) ApprovalOutcome {
        const deadline = monoMs() + @as(i64, @intCast(timeout_ms));
        while (monoMs() < deadline) {
            self.lock.lock();
            const st: u8 = if (self.pending.get(id)) |p| p.load(.acquire) else 0;
            self.lock.unlock();
            switch (st) {
                1 => return .allowed_once,
                2 => return .rejected,
                3 => return .cancelled,
                else => {},
            }
            backoffSleepMs(poll_ms);
        }
        return .unavailable;
    }

    /// Settle a pending approval from a gateway `$events.result` payload.
    pub fn resolveEvent(self: *ApprovalStore, event_id: []const u8, kind: []const u8, value_json: []const u8) bool {
        if (std.mem.eql(u8, kind, "cancelled")) return self.resolve(event_id, .cancelled);
        const outcome = parseOutcomeValue(value_json) orelse return false;
        return self.resolve(event_id, outcome);
    }

    pub fn setHasAnswerer(self: *ApprovalStore, v: bool) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.has_answerer = v;
    }

    pub fn setPolicy(self: *ApprovalStore, session_id: []const u8, policy: ApprovalPolicy) !void {
        self.lock.lock();
        defer self.lock.unlock();
        const existing = self.policies.getEntry(session_id);
        if (existing) |e| {
            e.value_ptr.* = policy;
            return;
        }
        const key = try self.alloc.dupe(u8, session_id);
        errdefer self.alloc.free(key);
        try self.policies.put(key, policy);
    }

    pub fn effectivePolicy(self: *ApprovalStore, session_id: []const u8) ApprovalPolicy {
        self.lock.lock();
        defer self.lock.unlock();
        return self.policies.get(session_id) orelse .ask;
    }

    /// Fail-closed check before a dynamic/escalated operation.
    /// `never` => rejected immediately. `ask` with no answerer => unavailable.
    /// `ask` with an answerer => caller must issue a real approval/request
    /// frame (паний outside this store); this helper returns `ask` as a
    /// signal to proceed to prompting. Callers that need a synchronous
    /// decision treat `unavailable` as denial.
    pub fn check(self: *ApprovalStore, session_id: []const u8) ApprovalOutcome {
        const pol = self.effectivePolicy(session_id);
        if (pol == .never) return .rejected;
        self.lock.lock();
        const has = self.has_answerer;
        self.lock.unlock();
        if (!has) return .unavailable;
        return .allowed_once; // answerer present — caller may prompt; for
        // synchronous callers without a prompt loop this counts as "ask
        // required" (treated as unavailable until answered). Minimal helper:
        // escalated operations without a prompt round-trip should consider
        // ask==rejected for fail-closed safety; use `checkOrPrompt` below if
        // a real question round-trip is needed.
    }

    /// Synchronous fail-closed gate for non-interactive call sites: `ask`
    /// without a prompt round-trip is treated as denial (fail-closed). Use
    /// when the operation cannot block for a human answer.
    pub fn checkFailClosed(self: *ApprovalStore, session_id: []const u8) bool {
        const outcome = self.check(session_id);
        return outcome.isAllowed();
    }
};

fn outcomeFromStr(s: []const u8) ?ApprovalOutcome {
    if (std.mem.eql(u8, s, "allowed-once")) return .allowed_once;
    if (std.mem.eql(u8, s, "rejected")) return .rejected;
    if (std.mem.eql(u8, s, "cancelled")) return .cancelled;
    if (std.mem.eql(u8, s, "unavailable")) return .unavailable;
    return null;
}

/// Parse an approval outcome from either a quoted string or an object with an
/// `outcome` field. Null when unrecognized.
fn parseOutcomeValue(value_json: []const u8) ?ApprovalOutcome {
    const t = std.mem.trim(u8, value_json, " \t\r\n");
    if (t.len > 0 and t[0] == '{') {
        const needle = "\"outcome\"";
        const p = std.mem.indexOf(u8, t, needle) orelse return null;
        var i = p + needle.len;
        while (i < t.len and (t[i] == ':' or t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i >= t.len or t[i] != '"') return null;
        i += 1;
        const s = i;
        while (i < t.len and t[i] != '"') i += 1;
        return outcomeFromStr(t[s..i]);
    }
    if (t.len >= 2 and t[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, t, 1, '"') orelse return null;
        return outcomeFromStr(t[1..end]);
    }
    return null;
}

var g_approval_store: ?*ApprovalStore = null;

pub fn sharedApprovalStore() !*ApprovalStore {
    if (g_approval_store) |s| return s;
    const s = try std.heap.page_allocator.create(ApprovalStore);
    s.initInPlace(std.heap.page_allocator);
    g_approval_store = s;
    return s;
}

pub fn takeSharedApprovalStore() ?*ApprovalStore {
    const s = g_approval_store;
    g_approval_store = null;
    return s;
}

/// Approval mux payloads — mirrors question payload builders for a future
/// approval/requested frame when an interactive adapter needs it.
pub fn buildApprovalRequestedPayload(
    alloc: std.mem.Allocator,
    session_id: []const u8,
    approval_id: []const u8,
    tool_name: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"approval/requested\",\"sessionId\":");
    try jsonx.appendJsonString(alloc, &out, session_id);
    try out.appendSlice(alloc, ",\"approvalId\":");
    try jsonx.appendJsonString(alloc, &out, approval_id);
    try out.appendSlice(alloc, ",\"toolName\":");
    try jsonx.appendJsonString(alloc, &out, tool_name);
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

pub fn buildApprovalResolvedPayload(
    alloc: std.mem.Allocator,
    session_id: []const u8,
    approval_id: []const u8,
    outcome: ApprovalOutcome,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"approval/resolved\",\"sessionId\":");
    try jsonx.appendJsonString(alloc, &out, session_id);
    try out.appendSlice(alloc, ",\"approvalId\":");
    try jsonx.appendJsonString(alloc, &out, approval_id);
    try out.appendSlice(alloc, ",\"outcome\":");
    try jsonx.appendJsonString(alloc, &out, outcome.asStr());
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

// ── answer validation (port of upstream matchesQuestions) ───────────────────

/// One parsed AskUserQuestionItem: slices point INTO `questions_json`.
const QMeta = struct {
    id: []const u8,
    multi_select: bool,
    labels: []const []const u8,
};

/// Parse the per-question metadata needed for answer validation.
fn parseQMetas(alloc: std.mem.Allocator, questions_json: []const u8) ![]QMeta {
    var metas: std.ArrayList(QMeta) = .empty;
    errdefer {
        for (metas.items) |m| alloc.free(m.labels);
        metas.deinit(alloc);
    }

    var elems = ElemIter.init(questions_json);
    while (elems.next()) |el| {
        var labels: std.ArrayList([]const u8) = .empty;
        errdefer labels.deinit(alloc);

        const id_raw = jsonx.getRaw(el, "id") orelse return error.BadQuestions;
        if (!jsonx.isString(id_raw)) return error.BadQuestions;
        var multi = false;
        if (jsonx.getRaw(el, "multiSelect")) |ms| {
            multi = std.mem.eql(u8, jsonx.trimWs(ms), "true");
        }
        if (jsonx.getRaw(el, "options")) |opts_raw| {
            var opts = ElemIter.init(opts_raw);
            while (opts.next()) |opt| {
                const lraw = jsonx.getRaw(opt, "label") orelse continue;
                if (!jsonx.isString(lraw)) continue;
                try labels.append(alloc, lraw[1 .. lraw.len - 1]);
            }
        }
        try metas.append(alloc, .{
            .id = id_raw[1 .. id_raw.len - 1],
            .multi_select = multi,
            .labels = try labels.toOwnedSlice(alloc),
        });
    }
    return try metas.toOwnedSlice(alloc);
}

fn freeQMetas(alloc: std.mem.Allocator, metas: []QMeta) void {
    for (metas) |m| alloc.free(m.labels);
    alloc.free(metas);
}

/// Validate the `value` slot ({sessionId, answer:{answers:[…]}}) against a
/// pending entry's session + stored questions array. Same rules as upstream
/// matchesQuestions (api-proxy.ts): sessionId correlation, one answer per
/// question in order, ids echoed exactly, no duplicate labels, labels must be
/// offered options, custom text trims to non-empty when present, and a
/// single-select question takes EITHER ≤1 label OR custom text — not both.
pub fn answerMatches(
    alloc: std.mem.Allocator,
    value_json: []const u8,
    session_id: []const u8,
    questions_json: []const u8,
) bool {
    // Session correlation: decode-free comparison against the pending entry's
    // plain session id (session ids are escape-free ASCII on this wire).
    const sid_raw = jsonx.trimWs(jsonx.getRaw(value_json, "sessionId") orelse return false);
    if (!jsonx.isString(sid_raw)) return false;
    if (!std.mem.eql(u8, sid_raw[1 .. sid_raw.len - 1], session_id)) return false;

    const answer_raw = jsonx.getRaw(value_json, "answer") orelse return false;
    const answers_raw = jsonx.getRaw(answer_raw, "answers") orelse return false;

    const metas = parseQMetas(alloc, questions_json) catch return false;
    defer freeQMetas(alloc, metas);

    var idx: usize = 0;
    var elems = ElemIter.init(answers_raw);
    while (elems.next()) |el| : (idx += 1) {
        if (idx >= metas.len) return false; // more answers than questions
        const m = metas[idx];

        const aid = jsonx.getRaw(el, "id") orelse return false;
        if (!jsonx.isString(aid)) return false;
        if (!std.mem.eql(u8, aid[1 .. aid.len - 1], m.id)) return false;

        // Collect selected labels (decoded, so escaped wire bytes compare
        // against decoded option labels fairly).
        var picked: std.ArrayList([]const u8) = .empty;
        defer {
            for (picked.items) |s| alloc.free(s);
            picked.deinit(alloc);
        }
        if (jsonx.getRaw(el, "selected")) |sel_raw| {
            var sel = ElemIter.init(sel_raw);
            while (sel.next()) |sraw| {
                if (!jsonx.isString(sraw)) return false;
                const label = jsonx.decodeString(alloc, sraw[1 .. sraw.len - 1]) catch return false;
                picked.append(alloc, label) catch return false;
            }
        } else return false; // selected is required by the upstream schema

        // No duplicate selections.
        for (picked.items, 0..) |a, i| {
            for (picked.items[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a, b)) return false;
            }
        }

        // Custom text: present-but-blank is malformed (upstream trims and
        // rejects ""); decode into scratch for the emptiness check.
        var has_custom = false;
        if (jsonx.getRaw(el, "custom")) |craw| {
            if (!jsonx.isString(craw)) return false;
            const c = jsonx.decodeString(alloc, craw[1 .. craw.len - 1]) catch return false;
            defer alloc.free(c);
            const trimmed = std.mem.trim(u8, c, " \t\r\n");
            if (trimmed.len == 0) return false;
            has_custom = true;
        }

        if (!m.multi_select) {
            if (has_custom and picked.items.len > 0) return false;
            if (picked.items.len > 1) return false;
        }

        // Every selected label must be one of the offered options. A question
        // with NO options accepts only free text (labels can't match).
        for (picked.items) |label| {
            var found = false;
            for (m.labels) |offered| {
                if (std.mem.eql(u8, label, offered)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
    }
    return idx == metas.len; // exact count match, order-sensitive ids above
}

// ── JSON array element iterator (top-level elements of a [...] span) ────────

const ElemIter = struct {
    body: []const u8, // inside the brackets
    i: usize = 0,

    fn init(array_json: []const u8) ElemIter {
        const t = jsonx.trimWs(array_json);
        if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
            return .{ .body = t[1 .. t.len - 1] };
        }
        return .{ .body = "" };
    }

    /// Next top-level element span (objects only are yielded intact; scalars
    /// come through as raw literal spans), or null at the end / malformed.
    fn next(self: *ElemIter) ?[]const u8 {
        var i = self.i;
        const b = self.body;
        while (i < b.len and (b[i] == ' ' or b[i] == '\t' or b[i] == '\r' or b[i] == '\n' or b[i] == ',')) : (i += 1) {}
        if (i >= b.len) {
            self.i = i;
            return null;
        }
        const start = i;
        switch (b[i]) {
            '{' => {
                const end = jsonx.matchBraceFrom(b, i) orelse {
                    self.i = b.len;
                    return null;
                };
                i = end;
            },
            '[' => {
                // Nested arrays: reuse brace matcher logic via a manual scan.
                var depth: usize = 0;
                while (i < b.len) : (i += 1) {
                    switch (b[i]) {
                        '[', '{' => depth += 1,
                        ']', '}' => {
                            depth -= 1;
                            if (depth == 0) {
                                i += 1;
                                break;
                            }
                        },
                        '"' => {
                            i += 1;
                            while (i < b.len and b[i] != '"') : (i += 1) {
                                if (b[i] == '\\' and i + 1 < b.len) i += 1;
                            }
                        },
                        else => {},
                    }
                }
            },
            '"' => {
                i += 1;
                while (i < b.len and b[i] != '"') : (i += 1) {
                    if (b[i] == '\\' and i + 1 < b.len) i += 1;
                }
                if (i < b.len) i += 1;
            },
            else => {
                while (i < b.len and b[i] != ',') : (i += 1) {}
            },
        }
        self.i = i;
        return jsonx.trimWs(b[start..i]);
    }
};

// ── singleton (events_ws.sharedHubs pattern) ────────────────────────────────

var g_store: ?*Store = null;

/// Process-wide pending-question store, created on first use. Question state
/// outlives every request/tool thread, so the store deliberately allocates
/// from `std.heap.page_allocator` — NEVER from a caller's per-request arena.
pub fn sharedStore() !*Store {
    if (g_store) |s| return s;
    const s = try std.heap.page_allocator.create(Store);
    s.initInPlace(std.heap.page_allocator);
    g_store = s;
    return s;
}

/// Test/integrator hook: detach the current singleton (caller destroys it).
pub fn takeSharedStore() ?*Store {
    const s = g_store;
    g_store = null;
    return s;
}

// ── the REAL /api/respond handler ───────────────────────────────────────────

/// Full /api/respond endpoint body for router.handleApiRequest — this REPLACES
/// the `{"accepted":false,"reason":"not-pending"}` stub at integrator time.
/// The returned receipt JSON is allocated with `alloc` (the router's request
/// arena; no deinit needed, matching every other RPC handler).
///
/// Integrator splice (router.zig is NOT owned by G3):
///
///     if (std.mem.eql(u8, seg, "respond")) {
///         const store = try questions.sharedStore();
///         const receipt = questions.handleRespond(store, alloc, req.body);
///         return res.send(.ok, .json, receipt);
///     }
///
/// Receipts always ride HTTP 200 with {"accepted":true} |
/// {"accepted":false,"reason":"not-pending"|"bad-response"} — exactly the
/// upstream RpcReceipt shape the connection plugin's respond() call parses.
pub fn handleRespond(store: *Store, alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    const receipt = store.respond(body);
    if (receipt.accepted) {
        return try alloc.dupe(u8, "{\"accepted\":true}");
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"accepted\":false,\"reason\":");
    try jsonx.appendJsonString(alloc, &out, receipt.reason);
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

// ── mux frame payload builders (upstream events.schema.ts shapes) ───────────

/// question/requested PAYLOAD:
///   {"type":"question/requested","sessionId":"…","questions":[<items>]}
/// The ServerRequest full form around it is applied by the publisher via
/// events_ws.wrapServerRequestWithId with the pending entry's rpc_id as the
/// frame rpcId — that echoed id is what routes POST /api/respond back here.
pub fn buildRequestedPayload(
    alloc: std.mem.Allocator,
    session_id: []const u8,
    questions_json: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"question/requested\",\"sessionId\":");
    try jsonx.appendJsonString(alloc, &out, session_id);
    try out.appendSlice(alloc, ",\"questions\":");
    try out.appendSlice(alloc, questions_json);
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

/// question/resolved PAYLOAD:
///   {"type":"question/resolved","sessionId":"…","questionRpcId":"…",
///    "outcome":"answered"|"cancelled"}
/// Upstream has no timeout outcome: an unanswered question the host gives up
/// on resolves as "cancelled" (ASK_ABORTED family), so zharness timeouts emit
/// cancelled too.
pub fn buildResolvedPayload(
    alloc: std.mem.Allocator,
    session_id: []const u8,
    question_rpc_id: []const u8,
    answered: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"question/resolved\",\"sessionId\":");
    try jsonx.appendJsonString(alloc, &out, session_id);
    try out.appendSlice(alloc, ",\"questionRpcId\":");
    try jsonx.appendJsonString(alloc, &out, question_rpc_id);
    try out.appendSlice(alloc, ",\"outcome\":");
    try jsonx.appendJsonString(alloc, &out, if (answered) "answered" else "cancelled");
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const fixture_questions =
    \\[{"id":"q1","question":"Which database?","options":[{"label":"Postgres"},{"label":"SQLite"}]}]
;

/// Quote an rpc id into its wire form (ids are escape-free ASCII).
fn qid(alloc: std.mem.Allocator, rpc_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "\"{s}\"", .{rpc_id});
}

fn respondBodyOk(alloc: std.mem.Allocator, rpc_raw: []const u8, sid: []const u8, answer: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"type\":\"client-response\",\"rpcId\":{s},\"result\":{{\"ok\":true,\"value\":{{\"sessionId\":\"{s}\",\"answer\":{{\"answers\":{s}}}}}}}}}", .{ rpc_raw, sid, answer });
}

test "approval store: request/await/resolve closed outcomes" {
    const alloc = std.testing.allocator;
    var store: ApprovalStore = undefined;
    store.initInPlace(alloc);
    defer store.deinit();

    try store.openRequest("a-1");
    try std.testing.expect(store.resolve("a-1", .allowed_once));
    try std.testing.expectEqual(ApprovalOutcome.allowed_once, store.await("a-1", 200, 5));

    try store.openRequest("a-2");
    try std.testing.expect(store.resolve("a-2", .rejected));
    try std.testing.expectEqual(ApprovalOutcome.rejected, store.await("a-2", 200, 5));

    // Unknown id never resolves; await times out to unavailable.
    try std.testing.expect(!store.resolve("missing", .allowed_once));
    try std.testing.expectEqual(ApprovalOutcome.unavailable, store.await("missing", 20, 5));

    // Gateway value forms.
    try store.openRequest("a-3");
    try std.testing.expect(store.resolveEvent("a-3", "accepted", "\"allowed-once\""));
    try std.testing.expectEqual(ApprovalOutcome.allowed_once, store.await("a-3", 200, 5));
    try store.openRequest("a-4");
    try std.testing.expect(store.resolveEvent("a-4", "cancelled", "null"));
    try std.testing.expectEqual(ApprovalOutcome.cancelled, store.await("a-4", 200, 5));
    try store.openRequest("a-5");
    try std.testing.expect(store.resolveEvent("a-5", "accepted", "{\"outcome\":\"rejected\"}"));
    try std.testing.expectEqual(ApprovalOutcome.rejected, store.await("a-5", 200, 5));

    store.drop("a-1");
    store.drop("a-2");
    store.drop("a-3");
    store.drop("a-4");
    store.drop("a-5");
}

test "ask registers; respond settles answered; claimWaiter transfers answer" {
    const alloc = testing.allocator;
    var store: Store = undefined;
    store.initInPlace(alloc);
    defer store.pendings.deinit(alloc);

    const p = try store.ask("web-1", fixture_questions);
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expectEqual(State.waiting, p.getState());
    try testing.expect(std.mem.startsWith(u8, p.rpc_id, "q-"));

    // Respond from ANOTHER thread, like the httpd connection thread would.
    const Responder = struct {
        fn run(s: *Store, a: std.mem.Allocator, pp: *Pending) void {
            const rpc = qid(a, pp.rpc_id) catch unreachable;
            defer a.free(rpc);
            const body = respondBodyOk(a, rpc, "web-1",
                \\[{"id":"q1","selected":["SQLite"]}]
            ) catch unreachable;
            defer a.free(body);
            const r = s.respond(body);
            std.debug.assert(r.accepted);
        }
    };
    const th = try std.Thread.spawn(.{}, Responder.run, .{ &store, alloc, p });
    // Wait for the settle (bounded spin so a regression can't hang CI).
    var waited: usize = 0;
    while (p.getState() == .waiting and waited < 5000) : (waited += 1) backoffSleepMs(1);
    th.join();

    try testing.expectEqual(State.answered, p.getState());
    const claim = store.claimWaiter(alloc, p);
    try testing.expect(claim == .answered);
    try testing.expectEqual(@as(usize, 0), store.count());
    defer alloc.free(claim.answered);
    try testing.expect(std.mem.indexOf(u8, claim.answered, "\"selected\":[\"SQLite\"]") != null);
}

test "respond rejects unknown ids, bad envelopes, mismatched answers" {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var store: Store = undefined;
    store.initInPlace(a);

    // Unknown rpc id → not-pending.
    const b1 = try respondBodyOk(a, "\"nope\"", "web-1", "[]");
    try testing.expectEqual(Store.Receipt.not_pending, store.respond(b1));

    const p = try store.ask("web-1", fixture_questions);

    // Wrong envelope type → bad-response.
    const b2 = try std.fmt.allocPrint(a, "{{\"type\":\"client-request\",\"rpcId\":\"{s}\",\"method\":\"x\",\"payload\":{{}}}}", .{p.rpc_id});
    try testing.expectEqual(Store.Receipt.bad_response, store.respond(b2));

    // Wrong sessionId → bad-response.
    const b3 = try respondBodyOk(a, "\"q-1\"", "web-9", "[{\"id\":\"q1\",\"selected\":[\"SQLite\"]}]");
    try testing.expectEqual(Store.Receipt.bad_response, store.respond(b3));

    // Label not offered → bad-response.
    const b4 = try respondBodyOk(a, "\"q-1\"", "web-1", "[{\"id\":\"q1\",\"selected\":[\"Mongo\"]}]");
    try testing.expectEqual(Store.Receipt.bad_response, store.respond(b4));

    // Wrong count / wrong id order → bad-response.
    const b5 = try respondBodyOk(a, "\"q-1\"", "web-1", "[{\"id\":\"other\",\"selected\":[\"SQLite\"]}]");
    try testing.expectEqual(Store.Receipt.bad_response, store.respond(b5));

    // Single-select with custom AND label → bad-response (covered in the
    // dedicated rules test below).

    // ok:false with a non-cancelled error code → bad-response.
    const b7 = try std.fmt.allocPrint(a, "{{\"type\":\"client-response\",\"rpcId\":\"{s}\",\"result\":{{\"ok\":false,\"error\":{{\"code\":\"internal\",\"message\":\"boom\",\"details\":{{}}}}}}}}", .{p.rpc_id});
    try testing.expectEqual(Store.Receipt.bad_response, store.respond(b7));
    try testing.expectEqual(State.waiting, p.getState());

    // Still pending after all the failures; clean cancel settles it.
    try testing.expectEqual(@as(usize, 1), store.count());
    const b8 = try std.fmt.allocPrint(a, "{{\"type\":\"client-response\",\"rpcId\":\"{s}\",\"result\":{{\"ok\":false,\"error\":{{\"code\":\"cancelled\",\"message\":\"user cancelled\",\"details\":{{}}}}}}}}", .{p.rpc_id});
    try testing.expectEqual(Store.Receipt.accepted_ok, store.respond(b8));
    try testing.expectEqual(State.cancelled, p.getState());
    try testing.expectEqual(Store.Receipt.not_pending, store.respond(b8)); // double settle
}

test "single-select rules: custom+label rejected, multiSelect allows both" {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var store: Store = undefined;
    store.initInPlace(a);

    // multiSelect question.
    const mq = "[{\"id\":\"m1\",\"multiSelect\":true,\"options\":[{\"label\":\"A\"},{\"label\":\"B\"}]}]";
    _ = try store.ask("s", mq);
    const good_multi = try respondBodyOk(a, "\"q-1\"", "s",
        \\[{"id":"m1","selected":["A","B"],"custom":"also this"}]
    );
    try testing.expectEqual(Store.Receipt.accepted_ok, store.respond(good_multi));

    // Single-select: custom text alone is fine.
    const sq = "[{\"id\":\"s1\",\"options\":[{\"label\":\"A\"},{\"label\":\"B\"}]}]";
    _ = try store.ask("s", sq);
    const good_custom = try respondBodyOk(a, "\"q-2\"", "s",
        \\[{"id":"s1","selected":[],"custom":"use crdb actually"}]
    );
    try testing.expectEqual(Store.Receipt.accepted_ok, store.respond(good_custom));

    // Single-select: two labels rejected.
    _ = try store.ask("s", sq);
    const bad_two = try respondBodyOk(a, "\"q-3\"", "s",
        \\[{"id":"s1","selected":["A","B"]}]
    );
    try testing.expectEqual(Store.Receipt.bad_response, store.respond(bad_two));

    // Blank custom text rejected.
    _ = try store.ask("s", sq);
    const blank = try respondBodyOk(a, "\"q-4\"", "s",
        \\[{"id":"s1","selected":[],"custom":"   "}]
    );
    try testing.expectEqual(Store.Receipt.bad_response, store.respond(blank));

    // Optionless question accepts only free text.
    const oq = "[{\"id\":\"o1\"}]";
    _ = try store.ask("s", oq);
    const free_text = try respondBodyOk(a, "\"q-5\"", "s",
        \\[{"id":"o1","selected":[],"custom":"42"}]
    );
    try testing.expectEqual(Store.Receipt.accepted_ok, store.respond(free_text));
}

test "multiple concurrent pendings resolve independently" {
    const alloc = testing.allocator;
    var store: Store = undefined;
    store.initInPlace(alloc);
    defer store.pendings.deinit(alloc);

    const p1 = try store.ask("web-1", fixture_questions);
    const p2 = try store.ask("web-2", fixture_questions);
    const p3 = try store.ask("web-9", fixture_questions);
    try testing.expectEqual(@as(usize, 3), store.count());
    try testing.expect(!std.mem.eql(u8, p1.rpc_id, p2.rpc_id));
    try testing.expect(!std.mem.eql(u8, p2.rpc_id, p3.rpc_id));

    // Answer p2 first, then p1; p3 stays waiting then gets cancelled wholesale.
    const rpc2 = try qid(alloc, p2.rpc_id);
    defer alloc.free(rpc2);
    const r2 = try respondBodyOk(alloc, rpc2, "web-2",
        \\[{"id":"q1","selected":["Postgres"]}]
    );
    defer alloc.free(r2);
    try testing.expectEqual(Store.Receipt.accepted_ok, store.respond(r2));
    try testing.expectEqual(State.answered, p2.getState());
    try testing.expectEqual(State.waiting, p1.getState());

    const c1 = store.claimWaiter(alloc, p2);
    defer alloc.free(c1.answered);
    try testing.expect(std.mem.indexOf(u8, c1.answered, "Postgres") != null);

    try testing.expectEqual(@as(usize, 1), store.cancelAllForSession("web-1"));
    try testing.expectEqual(State.cancelled, p1.getState());
    try testing.expectEqual(State.waiting, p3.getState()); // other session untouched

    const c3 = store.claimWaiter(alloc, p3);
    try testing.expect(c3 == .cancelled);
    const c1late = store.claimWaiter(alloc, p1);
    try testing.expect(c1late == .cancelled);
    try testing.expectEqual(@as(usize, 0), store.count());
}
