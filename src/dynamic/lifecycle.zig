//! Dynamic Cordis lifecycle orchestration — docs/dynamic-cordis-spec.md §4-5.
//!
//! Connects registry.zig (revision pointers + pending approvals) and
//! sandbox.zig (Node `vm` child host-half evaluation) behind one actor:
//!
//!   - define: sandbox `precheckCode` gate on BOTH halves BEFORE
//!     registry.define mints ids (spec §5 — unparseable input never enters
//!     the registry); a refusal carries the teaching text from
//!     sandbox.precheckTeachingMessage.
//!   - run: host-only packages resolve synchronously (runHostHalf → commit).
//!     Client-bearing packages arm the registry pending request, emit
//!     cordis/request-run on the mux hub, and SUSPEND until the page answers
//!     approve(requestId) | decline(requestId) via resolveRequestRun — first
//!     answer wins, late/unknown requests report accepted:false, stale
//!     revisions leave the request suspended. On approve the grant is
//!     recorded, runHostHalf executes, and the activation commits
//!     (currentPackageId moves only on complete success; failures set
//!     diagnostics and preserve nextPackageId).
//!   - stop / undefine: idempotent teardown with dynamicCordisRunner/retract
//!     broadcast; session ownership enforced by the registry.
//!   - invoke: unary harness.handle RPC through the ACTIVE run's host half
//!     ({ok,value} or {code,message}, spec §7), plus tool listing for the
//!     harness.defineTool registrations captured at start.
//!
//! Session scoping (spec §6): define/run/stop/undefine carry sessionId and
//! enforce ownership through the registry (cross-session reads as absent,
//! never forbidden). resolveRequestRun/invoke are page-global facts and take
//! no session.
//!
//! Transport (spec §4): frames ride /api/events.mux as ServerRequest texts
//! via events_ws.sharedHubs().mux.publishFrame, pre-wrapped with
//! wrapServerRequestWithId so the frame rpcId doubles as the correlation id:
//!   cordis/request-run · cordis/request-run-resolved ·
//!   dynamicCordisRunner/package · dynamicCordisRunner/retract
//! Publish failures stay invisible (hub unavailable / no subscribers).
//!
//! Threading: one SpinLock serializes registry mutations and claims. The
//! suspended run() waiter polls WITHOUT holding the lock so a page thread
//! can always deliver its decision; runHostHalf (a node child spawn)
//! also runs unlocked — only commits re-lock. Per-plugin serialization comes
//! from the registry's TransitionInFlight checks plus the stale-revision
//! guard in resolveRequestRun. The registry must share this lifecycle's
//! allocator (claimed PendingRequest strings are freed with self.alloc).

const std = @import("std");
const types = @import("types.zig");
const registry_mod = @import("registry.zig");
const sandbox_mod = @import("sandbox.zig");
const events_ws = @import("../server/apiproxy/events_ws.zig");
const jsonx = @import("../server/apiproxy/jsonx.zig");
// Reuse the shared sync primitives (events_ws.zig design; documented public
// for sibling reuse instead of one more private copy).
const sync = @import("../server/apiproxy/questions.zig");

const DynamicRegistry = registry_mod.DynamicRegistry;

pub const LifecycleError = error{
    PluginNotFound,
    NotRunning,
    NoHostHalf,
    StaleRevision,
    ArgsTooLarge,
    OutOfMemory,
};

// ── define ───────────────────────────────────────────────────────────────────

/// Teaching refusal from the precheck gate (or a registry validation error).
pub const Refusal = struct {
    /// "empty-code" | "oversize" | "syntax" | "registry"
    kind: []const u8,
    /// Owned teaching text (sandbox.precheckTeachingMessage shape).
    message: []const u8,

    pub fn deinit(self: *const Refusal, alloc: std.mem.Allocator) void {
        alloc.free(self.message);
    }
};

pub const DefineResult = union(enum) {
    receipt: types.DefineReceipt,
    refused: Refusal,

    pub fn deinit(self: *const DefineResult, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .refused => |r| r.deinit(alloc),
            .receipt => {},
        }
    }
};

// ── run outcomes ─────────────────────────────────────────────────────────────

/// Terminal result of a run() call. status is one of running | rejected |
/// failed | cancelled (awaiting_approval/starting_host never escape).
pub const RunOutcome = struct {
    status: types.RunStatus,
    plugin_run_id: []const u8 = "",
    package_id: []const u8 = "",
    approval_request_id: ?[]const u8 = null,
    err: ?[]const u8 = null,

    pub fn deinit(self: *const RunOutcome, alloc: std.mem.Allocator) void {
        if (self.plugin_run_id.len > 0) alloc.free(self.plugin_run_id);
        if (self.package_id.len > 0) alloc.free(self.package_id);
        if (self.approval_request_id) |r| alloc.free(r);
        if (self.err) |e| alloc.free(e);
    }
};

// ── active half registrations ────────────────────────────────────────────────

/// Tools/handles/provides captured from a successful host-half evaluation of
/// the ACTIVE run. Replaced on re-run; dropped on stop/undefine.
pub const ActiveHalf = struct {
    plugin_run_id: []u8,
    package_id: []u8,
    provides: [][]const u8 = &.{},
    tools: []sandbox_mod.ToolRegistration = &.{},
    handles: [][]const u8 = &.{},

    fn adopt(alloc: std.mem.Allocator, run_id: []const u8, package_id: []const u8, res: *sandbox_mod.RunResult) !ActiveHalf {
        const half = ActiveHalf{
            .plugin_run_id = try alloc.dupe(u8, run_id),
            .package_id = try alloc.dupe(u8, package_id),
            // Steal the parsed arrays: the RunResult is about to be deinit'd,
            // so blank its handles to keep ownership single.
            .provides = res.provides,
            .tools = res.tools,
            .handles = res.handles,
        };
        res.provides = &.{};
        res.tools = &.{};
        res.handles = &.{};
        return half;
    }

    fn deinit(self: *const ActiveHalf, alloc: std.mem.Allocator) void {
        alloc.free(self.plugin_run_id);
        alloc.free(self.package_id);
        for (self.provides) |p| alloc.free(p);
        if (self.provides.len > 0) alloc.free(self.provides);
        for (self.tools) |*t| t.deinit(alloc);
        if (self.tools.len > 0) alloc.free(self.tools);
        for (self.handles) |h| alloc.free(h);
        if (self.handles.len > 0) alloc.free(self.handles);
    }
};

// ── invoke ───────────────────────────────────────────────────────────────────

/// Unary invoke result (spec §7): {ok,value} or {code,message}. All string
/// fields are owned; free with deinit.
pub const InvokeResult = struct {
    ok: bool,
    value_json: []const u8 = "",
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    /// Transport-level failure (node missing/crashed), distinct from a
    /// handler-level {code,message} failure.
    transport_err: ?[]const u8 = null,

    pub fn deinit(self: *const InvokeResult, alloc: std.mem.Allocator) void {
        if (self.value_json.len > 0) alloc.free(self.value_json);
        if (self.code) |c| alloc.free(c);
        if (self.message) |m| alloc.free(m);
        if (self.transport_err) |t| alloc.free(t);
    }
};

// ── lifecycle ────────────────────────────────────────────────────────────────

pub const Lifecycle = struct {
    alloc: std.mem.Allocator,
    reg: *DynamicRegistry,
    sbx: sandbox_mod.Sandbox,
    lock: sync.SpinLock = .{},
    poll_ms: u64 = 25,
    /// No timeout by default (spec §5: AbortSignal is the only exit; here the
    /// abort-equivalent is stop()/cancel). Tests may set a small budget.
    approval_timeout_ms: ?u64 = null,
    frame_counter: std.atomic.Value(u64) = .init(0),
    halves: std.StringHashMap(ActiveHalf),

    pub fn init(alloc: std.mem.Allocator, reg: *DynamicRegistry, sbx: sandbox_mod.Sandbox) Lifecycle {
        return .{
            .alloc = alloc,
            .reg = reg,
            .sbx = sbx,
            .halves = std.StringHashMap(ActiveHalf).init(alloc),
        };
    }

    pub fn deinit(self: *Lifecycle) void {
        var it = self.halves.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            e.value_ptr.deinit(self.alloc);
        }
        self.halves.deinit();
    }

    // ── define ───────────────────────────────────────────────────────────────

    /// Syntax-precheck both halves via the sandbox BEFORE any id mints
    /// (spec §5), then hand to registry.define (which repeats its own cheap
    /// gate and does the revisioning).
    pub fn define(self: *Lifecycle, req: types.DefineRequest) !DefineResult {
        if (req.code.host) |c| {
            self.sbx.precheckCode(c, .host) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .refused = try self.refusalFor(c, .host, e) },
            };
        }
        if (req.code.client) |c| {
            self.sbx.precheckCode(c, .client) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .refused = try self.refusalFor(c, .client, e) },
            };
        }
        self.lock.lock();
        defer self.lock.unlock();
        const receipt = self.reg.define(req) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const msg = try std.fmt.allocPrint(self.alloc, "define refused: {s}", .{@errorName(e)});
                errdefer self.alloc.free(msg);
                return .{ .refused = .{ .kind = "registry", .message = msg } };
            },
        };
        return .{ .receipt = receipt };
    }

    fn refusalFor(self: *Lifecycle, code: []const u8, half: sandbox_mod.Half, e: sandbox_mod.SandboxError) !Refusal {
        const kind: []const u8 = switch (e) {
            error.EmptyCode => "empty-code",
            error.Oversize => "oversize",
            else => "syntax",
        };
        const msg = try self.sbx.precheckMessage(self.alloc, code, half);
        errdefer self.alloc.free(msg);
        return .{ .kind = kind, .message = msg };
    }

    // ── run ──────────────────────────────────────────────────────────────────

    /// cordis_run (spec §4): validates mode vs currentPackageId, evaluates
    /// the host half immediately for host-only packages, suspends for page
    /// approval when a client half needs it.
    pub fn run(
        self: *Lifecycle,
        sessionId: []const u8,
        pluginId: []const u8,
        packageId: []const u8,
        mode: types.RunMode,
    ) !RunOutcome {
        var request_id: ?[]u8 = null;
        defer if (request_id) |r| self.alloc.free(r);
        var run_id: []u8 = "";
        defer if (run_id.len > 0) self.alloc.free(run_id);

        self.lock.lock();
        const receipt = self.reg.run(sessionId, pluginId, packageId, mode) catch |e| {
            self.lock.unlock();
            return e;
        };
        run_id = try self.alloc.dupe(u8, receipt.pluginRunId);
        self.alloc.free(receipt.pluginRunId);
        if (receipt.approvalRequestId) |a| {
            request_id = try self.alloc.dupe(u8, a);
            self.alloc.free(a);
        }
        const requires_approval = receipt.requiresApproval orelse false;
        const committed_by_registry = receipt.status == .running;
        // Free the remaining owned receipt strings (pluginId is borrowed).
        self.alloc.free(receipt.packageId);
        self.alloc.free(receipt.nextPackageId);
        if (receipt.currentPackageId) |c| self.alloc.free(c);
        self.lock.unlock();

        if (!requires_approval) {
            // Host-only (already committed synchronously) or revision already
            // granted by an earlier approval: evaluate now, no suspension.
            return self.startApproved(pluginId, run_id, packageId, request_id, !committed_by_registry);
        }

        // Client-bearing, not yet granted: arm done by the registry — emit
        // cordis/request-run and SUSPEND until resolved/stopped/cancelled.
        var payload: []u8 = undefined;
        {
            self.lock.lock();
            defer self.lock.unlock();
            const meta = self.reg.packageMeta(pluginId, packageId);
            payload = try buildRequestRunPayload(
                self.alloc,
                request_id.?,
                sessionId,
                pluginId,
                packageId,
                mode,
                if (meta) |m| m.name else "",
                if (meta) |m| m.purpose else "",
            );
        }
        defer self.alloc.free(payload);
        self.publishMux("cordis/request-run", payload);

        // Poll loop (events_ws spin+nap discipline): waits WITHOUT the lock
        // while resolveRequestRun settles the decision on another thread.
        const deadline: ?i64 = if (self.approval_timeout_ms) |t|
            sync.monoMs() + @as(i64, @intCast(t))
        else
            null;
        while (true) {
            sync.backoffSleepMs(self.poll_ms);

            var settled: ?types.RunStatus = null;
            var err_copy: ?[]u8 = null;
            errdefer if (err_copy) |e| self.alloc.free(e);
            {
                self.lock.lock();
                defer self.lock.unlock();
                if (self.reg.latestRunIdentity(pluginId)) |ident| {
                    switch (ident.status) {
                        // Still suspended (or resolver mid-runHostHalf).
                        .awaiting_approval, .starting_host => {},
                        else => {
                            settled = ident.status;
                            if (ident.status == .failed) {
                                if (ident.err) |msg| err_copy = try self.alloc.dupe(u8, msg);
                            }
                        },
                    }
                } else {
                    settled = .stopped; // plugin undefined underneath us
                }
            }

            if (settled) |st| {
                return try self.outcomeFrom(run_id, packageId, request_id, st, err_copy);
            }

            if (deadline) |d| {
                if (sync.monoMs() >= d) {
                    // Abort-signal equivalent: disarm + mark cancelled +
                    // broadcast so pages drop the affordance.
                    self.lock.lock();
                    if (request_id) |rid| self.reg.disarmRequest(rid);
                    self.reg.cancelLatestRun(pluginId, run_id);
                    self.lock.unlock();
                    if (request_id) |rid| self.publishResolved(rid, "cancelled");
                    return .{
                        .status = .cancelled,
                        .plugin_run_id = try self.alloc.dupe(u8, run_id),
                        .package_id = try self.alloc.dupe(u8, packageId),
                        .approval_request_id = if (request_id) |rid| try self.alloc.dupe(u8, rid) else null,
                    };
                }
            }
        }
    }

    fn outcomeFrom(
        self: *Lifecycle,
        run_id: []const u8,
        package_id: []const u8,
        request_id: ?[]const u8,
        settled: types.RunStatus,
        err_copy: ?[]u8,
    ) !RunOutcome {
        const status: types.RunStatus = switch (settled) {
            .running, .client_pending, .waiting => .running,
            .rejected => .rejected,
            .failed => .failed,
            else => .cancelled,
        };
        return .{
            .status = status,
            .plugin_run_id = try self.alloc.dupe(u8, run_id),
            .package_id = try self.alloc.dupe(u8, package_id),
            .approval_request_id = if (request_id) |r| try self.alloc.dupe(u8, r) else null,
            .err = err_copy,
        };
    }

    /// Evaluate the host half for an approved/host-only activation, then
    /// commit pointers, register tools/handles, and broadcast the package.
    /// Runs WITHOUT holding the lock except for short critical sections.
    fn startApproved(
        self: *Lifecycle,
        pluginId: []const u8,
        run_id: []const u8,
        packageId: []const u8,
        request_id: ?[]const u8,
        commit_needed: bool,
    ) !RunOutcome {
        var name_copy: ?[]u8 = null;
        var code: ?[]u8 = null;
        defer {
            if (name_copy) |v| self.alloc.free(v);
            if (code) |v| self.alloc.free(v);
        }
        {
            self.lock.lock();
            defer self.lock.unlock();
            const meta = self.reg.packageMeta(pluginId, packageId) orelse return error.PluginNotFound;
            const raw = meta.host_code orelse return error.NoHostHalf;
            code = try self.alloc.dupe(u8, raw);
            name_copy = try self.alloc.dupe(u8, meta.name);
        }

        var res = self.sbx.runHostHalf(packageId, code.?) catch |e| {
            return self.failStart(pluginId, run_id, packageId, request_id, "host-half spawn failed", @errorName(e));
        };
        defer res.deinit(self.alloc);

        if (!res.ok) {
            const reason = res.err orelse "host-half evaluation failed";
            return self.failStart(pluginId, run_id, packageId, request_id, reason, "");
        }

        // Commit activation + adopt the produced registrations.
        {
            self.lock.lock();
            defer self.lock.unlock();
            if (commit_needed) {
                self.reg.grantClientPackage(pluginId, packageId) catch {};
                self.reg.commitApprovedRun(pluginId, run_id, packageId) catch |e| return e;
            }
            // Replace any previous half for this plugin.
            if (self.halves.fetchRemove(pluginId)) |kv| {
                kv.value.deinit(self.alloc);
                self.alloc.free(kv.key);
            }
            const key = try self.alloc.dupe(u8, pluginId);
            errdefer self.alloc.free(key);
            const half = try ActiveHalf.adopt(self.alloc, run_id, packageId, &res);
            errdefer half.deinit(self.alloc);
            try self.halves.put(key, half);
        }

        if (request_id) |rid| self.publishResolved(rid, "approved");
        self.publishPackage(pluginId, packageId, run_id, name_copy.?);

        return .{
            .status = .running,
            .plugin_run_id = try self.alloc.dupe(u8, run_id),
            .package_id = try self.alloc.dupe(u8, packageId),
            .approval_request_id = if (request_id) |r| try self.alloc.dupe(u8, r) else null,
        };
    }

    fn failStart(
        self: *Lifecycle,
        pluginId: []const u8,
        run_id: []const u8,
        packageId: []const u8,
        request_id: ?[]const u8,
        reason: []const u8,
        detail: []const u8,
    ) !RunOutcome {
        const msg = if (detail.len > 0)
            try std.fmt.allocPrint(self.alloc, "{s}: {s}", .{ reason, detail })
        else
            try self.alloc.dupe(u8, reason);
        defer self.alloc.free(msg);

        self.lock.lock();
        self.reg.failRun(pluginId, run_id, "starting-host", msg);
        self.lock.unlock();
        if (request_id) |rid| self.publishResolved(rid, "failed");

        return .{
            .status = .failed,
            .plugin_run_id = try self.alloc.dupe(u8, run_id),
            .package_id = try self.alloc.dupe(u8, packageId),
            .approval_request_id = if (request_id) |r| try self.alloc.dupe(u8, r) else null,
            .err = try self.alloc.dupe(u8, msg),
        };
    }

    // ── approval resolution (page-global) ────────────────────────────────────

    pub const RequestDecision = enum {
        approved,
        rejected,
        cancelled,
        failed,

        pub fn asStr(self: RequestDecision) []const u8 {
            return switch (self) {
                .approved => "approved",
                .rejected => "rejected",
                .cancelled => "cancelled",
                .failed => "failed",
            };
        }
    };

    pub const ResolveResult = struct {
        accepted: bool,
    };

    /// resolveRequestRun (spec §4): FIRST answer wins. Late/unknown request
    /// ids report accepted:false and are ignored; a stale revision leaves
    /// the request suspended (accepted:false, still armed).
    pub fn resolveRequestRun(self: *Lifecycle, requestId: []const u8, decision: RequestDecision) ResolveResult {
        {
            self.lock.lock();
            defer self.lock.unlock();
            const peeked = self.reg.peekRequest(requestId) orelse return .{ .accepted = false };
            // Stale-revision guard: only settle while this request is still
            // the plugin's live attempt identity (spec §4 stays suspended).
            if (self.reg.latestRunIdentity(peeked.pluginId)) |ident| {
                if (!std.mem.eql(u8, ident.plugin_run_id, peeked.pluginRunId) or
                    !std.mem.eql(u8, ident.package_id, peeked.packageId))
                {
                    return .{ .accepted = false };
                }
            }
        }

        // Claim atomically under the lock (first answer wins), then settle
        // outside it — approved decisions spawn a node child.
        const pending: types.PendingRequest = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            break :blk self.reg.claimRequest(requestId) orelse return .{ .accepted = false };
        };
        // Claim transfers ownership of the four strings (same allocator).
        defer {
            self.alloc.free(pending.agentId);
            self.alloc.free(pending.pluginId);
            self.alloc.free(pending.packageId);
            self.alloc.free(pending.pluginRunId);
        }

        switch (decision) {
            .approved => {
                var oc = self.startApproved(pending.pluginId, pending.pluginRunId, pending.packageId, requestId, true) catch {
                    return .{ .accepted = true }; // decision applied; attempt marked failed inside
                };
                defer oc.deinit(self.alloc);
                return .{ .accepted = true };
            },
            .rejected, .cancelled, .failed => {
                self.lock.lock();
                switch (decision) {
                    .rejected => self.reg.rejectRun(pending.pluginId, pending.pluginRunId),
                    .cancelled => self.reg.cancelLatestRun(pending.pluginId, pending.pluginRunId),
                    .failed => self.reg.failRun(pending.pluginId, pending.pluginRunId, "request-failed", "page reported failure"),
                    else => unreachable,
                }
                self.lock.unlock();
                self.publishResolved(requestId, decision.asStr());
                return .{ .accepted = true };
            },
        }
    }

    // ── stop / undefine ──────────────────────────────────────────────────────

    /// cordis_stop: idempotent teardown; retains packages/pointers. Broadcasts
    /// retract (active run) + request-run-resolved cancelled (open request).
    pub fn stop(self: *Lifecycle, sessionId: []const u8, pluginId: []const u8) !types.StopResult {
        var retract_pkg: ?[]u8 = null;
        var retract_run: ?[]u8 = null;
        var pending_dup: ?[]u8 = null;
        defer {
            if (retract_pkg) |v| self.alloc.free(v);
            if (retract_run) |v| self.alloc.free(v);
            if (pending_dup) |v| self.alloc.free(v);
        }

        self.lock.lock();
        // Capture broadcast inputs BEFORE teardown frees them.
        if (self.reg.getPlugin(pluginId)) |p| {
            if (std.mem.eql(u8, p.session_id, sessionId)) {
                if (p.run) |r| {
                    retract_pkg = try self.alloc.dupe(u8, r.packageId);
                    retract_run = try self.alloc.dupe(u8, r.pluginRunId);
                }
                if (self.reg.pendingRequestFor(pluginId)) |pid| {
                    pending_dup = try self.alloc.dupe(u8, pid);
                }
            }
        }
        const result = self.reg.stop(sessionId, pluginId) catch |e| {
            self.lock.unlock();
            return e;
        };
        self.dropHalfLocked(pluginId);
        self.lock.unlock();

        if (result == .ok) {
            if (retract_pkg != null and retract_run != null) {
                self.publishRetract(pluginId, retract_pkg.?, retract_run.?);
            }
            if (pending_dup) |pd| self.publishResolved(pd, "cancelled");
        }
        return result;
    }

    /// cordis_undefine: stops then deletes all packages/grants —
    /// `@pluginId` becomes "Plugin removed".
    pub fn undefine(self: *Lifecycle, sessionId: []const u8, pluginId: []const u8) !types.UndefineResult {
        var retract_pkg: ?[]u8 = null;
        var retract_run: ?[]u8 = null;
        var pending_dup: ?[]u8 = null;
        defer {
            if (retract_pkg) |v| self.alloc.free(v);
            if (retract_run) |v| self.alloc.free(v);
            if (pending_dup) |v| self.alloc.free(v);
        }

        self.lock.lock();
        if (self.reg.getPlugin(pluginId)) |p| {
            if (std.mem.eql(u8, p.session_id, sessionId)) {
                if (p.run) |r| {
                    retract_pkg = try self.alloc.dupe(u8, r.packageId);
                    retract_run = try self.alloc.dupe(u8, r.pluginRunId);
                }
                if (self.reg.pendingRequestFor(pluginId)) |pid| {
                    pending_dup = try self.alloc.dupe(u8, pid);
                }
            }
        }
        const result = self.reg.undefine(sessionId, pluginId) catch |e| {
            self.lock.unlock();
            return e;
        };
        self.dropHalfLocked(pluginId);
        self.lock.unlock();

        if (result.wasRunning) {
            if (retract_pkg != null and retract_run != null) {
                self.publishRetract(pluginId, retract_pkg.?, retract_run.?);
            }
            if (pending_dup) |pd| self.publishResolved(pd, "cancelled");
        }
        return result;
    }

    fn dropHalfLocked(self: *Lifecycle, pluginId: []const u8) void {
        if (self.halves.fetchRemove(pluginId)) |kv| {
            kv.value.deinit(self.alloc);
            self.alloc.free(kv.key);
        }
    }

    // ── invoke / tool listing ────────────────────────────────────────────────

    /// Unary invoke through the ACTIVE run's registered handlers (page-global
    /// fact per spec §6 — carries no session). Bounds args by
    /// maxInvokeBytes. `pluginRunId` pins the exact activation identity when
    /// provided (stale callers get StaleRevision).
    pub fn invoke(
        self: *Lifecycle,
        pluginId: []const u8,
        pluginRunId: ?[]const u8,
        method: []const u8,
        args_json: []const u8,
    ) !InvokeResult {
        if (args_json.len > self.sbx.config.maxInvokeBytes) return error.ArgsTooLarge;

        var code: ?[]u8 = null;
        var pkg_id: ?[]u8 = null;
        defer {
            if (code) |c| self.alloc.free(c);
            if (pkg_id) |p| self.alloc.free(p);
        }
        {
            self.lock.lock();
            defer self.lock.unlock();
            const p = self.reg.getPlugin(pluginId) orelse return error.PluginNotFound;
            const r = p.run orelse return error.NotRunning;
            if (pluginRunId) |want| {
                if (!std.mem.eql(u8, want, r.pluginRunId)) return error.StaleRevision;
            }
            const pkg = p.packages.get(r.packageId) orelse return error.PluginNotFound;
            const raw = pkg.hostCode orelse return error.NoHostHalf;
            code = try self.alloc.dupe(u8, raw);
            pkg_id = try self.alloc.dupe(u8, r.packageId);
        }

        var res = self.sbx.invokeHostHalf(pkg_id.?, code.?, method, args_json) catch |e| {
            const t = try std.fmt.allocPrint(self.alloc, "invoke transport failed: {s}", .{@errorName(e)});
            errdefer self.alloc.free(t);
            return .{ .ok = false, .transport_err = t };
        };
        defer res.deinit(self.alloc);

        // Steal the owned strings off the RunResult before its deinit.
        const out = InvokeResult{
            .ok = res.ok,
            .value_json = res.value_json,
            .code = res.code,
            .message = res.message,
            .transport_err = res.err,
        };
        res.value_json = "";
        res.code = null;
        res.message = null;
        res.err = null;
        return out;
    }

    /// Snapshot of harness.defineTool registrations captured by the active
    /// run (deep copies; caller frees each element + the slice).
    pub fn toolsFor(self: *Lifecycle, alloc: std.mem.Allocator, pluginId: []const u8) ![]sandbox_mod.ToolRegistration {
        self.lock.lock();
        defer self.lock.unlock();
        const half = self.halves.get(pluginId) orelse return try alloc.alloc(sandbox_mod.ToolRegistration, 0);
        var out: std.ArrayList(sandbox_mod.ToolRegistration) = .empty;
        errdefer {
            for (out.items) |*t| t.deinit(alloc);
            out.deinit(alloc);
        }
        for (half.tools) |t| {
            try out.append(alloc, .{
                .name = try alloc.dupe(u8, t.name),
                .description = try alloc.dupe(u8, t.description),
                .raw_json = try alloc.dupe(u8, t.raw_json),
            });
        }
        return out.toOwnedSlice(alloc);
    }

    /// Registered handle method names of the active run (deep copies).
    pub fn handlesFor(self: *Lifecycle, alloc: std.mem.Allocator, pluginId: []const u8) ![][]const u8 {
        self.lock.lock();
        defer self.lock.unlock();
        const half = self.halves.get(pluginId) orelse return try alloc.alloc([]const u8, 0);
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| alloc.free(s);
            out.deinit(alloc);
        }
        for (half.handles) |h| try out.append(alloc, try alloc.dupe(u8, h));
        return out.toOwnedSlice(alloc);
    }

    // ── mux publishing (cordis/request-run family, spec §4) ─────────────────

    /// Publish one pre-wrapped ServerRequest frame on the mux hub. Frame rpcId
    /// is a fresh opaque id ("cordis-<n>"); payloads carry their own "type"
    /// discriminator like every other DSH-frame publisher here. Failures stay
    /// invisible (no subscribers / hub unavailable).
    fn publishMux(self: *Lifecycle, method: []const u8, payload_json: []const u8) void {
        const hubs = events_ws.sharedHubs() catch return;
        const n = self.frame_counter.fetchAdd(1, .monotonic) +% 1;
        var buf: [48]u8 = undefined;
        const id = std.fmt.bufPrint(&buf, "cordis-{d}", .{n}) catch "cordis";
        const frame = events_ws.wrapServerRequestWithId(self.alloc, id, method, payload_json) catch return;
        defer self.alloc.free(frame);
        hubs.mux.publishFrame(frame);
    }

    fn publishResolved(self: *Lifecycle, requestId: []const u8, outcome: []const u8) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        out.appendSlice(self.alloc, "{\"type\":\"cordis/request-run-resolved\",\"requestId\":") catch return;
        jsonx.appendJsonString(self.alloc, &out, requestId) catch return;
        out.appendSlice(self.alloc, ",\"outcome\":") catch return;
        jsonx.appendJsonString(self.alloc, &out, outcome) catch return;
        out.append(self.alloc, '}') catch return;
        self.publishMux("cordis/request-run-resolved", out.items);
    }

    fn publishPackage(self: *Lifecycle, pluginId: []const u8, packageId: []const u8, runId: []const u8, name: []const u8) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        out.appendSlice(self.alloc, "{\"type\":\"dynamicCordisRunner/package\",\"pluginId\":") catch return;
        jsonx.appendJsonString(self.alloc, &out, pluginId) catch return;
        out.appendSlice(self.alloc, ",\"packageId\":") catch return;
        jsonx.appendJsonString(self.alloc, &out, packageId) catch return;
        out.appendSlice(self.alloc, ",\"pluginRunId\":") catch return;
        jsonx.appendJsonString(self.alloc, &out, runId) catch return;
        out.appendSlice(self.alloc, ",\"name\":") catch return;
        jsonx.appendJsonString(self.alloc, &out, name) catch return;
        out.append(self.alloc, '}') catch return;
        self.publishMux("dynamicCordisRunner/package", out.items);
    }

    fn publishRetract(self: *Lifecycle, pluginId: []const u8, packageId: []const u8, runId: []const u8) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        out.appendSlice(self.alloc, "{\"type\":\"dynamicCordisRunner/retract\",\"pluginId\":") catch return;
        jsonx.appendJsonString(self.alloc, &out, pluginId) catch return;
        out.appendSlice(self.alloc, ",\"packageId\":") catch return;
        jsonx.appendJsonString(self.alloc, &out, packageId) catch return;
        out.appendSlice(self.alloc, ",\"pluginRunId\":") catch return;
        jsonx.appendJsonString(self.alloc, &out, runId) catch return;
        out.append(self.alloc, '}') catch return;
        self.publishMux("dynamicCordisRunner/retract", out.items);
    }
};

/// cordis/request-run PAYLOAD (DynamicCordisRunRequest, spec §9 wire types):
/// {"type":"cordis/request-run","requestId","agentId","pluginId","packageId",
///  "mode","name","purpose"} — code NEVER rides the announcement (getClientCode
/// is the only path to the browser, spec §4).
fn buildRequestRunPayload(
    alloc: std.mem.Allocator,
    request_id: []const u8,
    agent_id: []const u8,
    plugin_id: []const u8,
    package_id: []const u8,
    mode: types.RunMode,
    name: []const u8,
    purpose: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"cordis/request-run\",\"requestId\":");
    try jsonx.appendJsonString(alloc, &out, request_id);
    try out.appendSlice(alloc, ",\"agentId\":");
    try jsonx.appendJsonString(alloc, &out, agent_id);
    try out.appendSlice(alloc, ",\"pluginId\":");
    try jsonx.appendJsonString(alloc, &out, plugin_id);
    try out.appendSlice(alloc, ",\"packageId\":");
    try jsonx.appendJsonString(alloc, &out, package_id);
    try out.appendSlice(alloc, ",\"mode\":");
    try jsonx.appendJsonString(alloc, &out, mode.asStr());
    try out.appendSlice(alloc, ",\"name\":");
    try jsonx.appendJsonString(alloc, &out, name);
    try out.appendSlice(alloc, ",\"purpose\":");
    try jsonx.appendJsonString(alloc, &out, purpose);
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn nodeAvailable(sbx: *const sandbox_mod.Sandbox) bool {
    var r = sbx.runHostHalf("pkg-lifecycle-probe", "return {};") catch return false;
    defer r.deinit(testing.allocator);
    return r.ok;
}

test "define refuses TypeScript and empty halves with teaching text" {
    const alloc = testing.allocator;
    var reg = DynamicRegistry.init(alloc);
    defer reg.deinit();
    var lc = Lifecycle.init(alloc, &reg, sandbox_mod.Sandbox.initDefault(alloc));
    defer lc.deinit();

    var bad = try lc.define(.{
        .session_id = "s1",
        .plugin = .{ .new = .{ .idPrefix = "demo" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "const x = y as const;" },
    });
    defer bad.deinit(alloc);
    try testing.expect(bad == .refused);
    try testing.expectEqualStrings("syntax", bad.refused.kind);
    try testing.expect(std.mem.indexOf(u8, bad.refused.message, "TypeScript") != null);

    var empty = try lc.define(.{
        .session_id = "s1",
        .plugin = .{ .new = .{ .idPrefix = "demo" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "   " },
    });
    defer empty.deinit(alloc);
    try testing.expect(empty == .refused);
    try testing.expectEqualStrings("empty-code", empty.refused.kind);

    // Unbalanced bracket trap refused too.
    var trap = try lc.define(.{
        .session_id = "s1",
        .plugin = .{ .new = .{ .idPrefix = "demo" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "return { apply(ctx){} });" },
    });
    defer trap.deinit(alloc);
    try testing.expect(trap == .refused);
    try testing.expectEqualStrings("syntax", trap.refused.kind);

    // Valid plain JS mints ids.
    var ok = try lc.define(.{
        .session_id = "s1",
        .plugin = .{ .new = .{ .idPrefix = "demo" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "return {}" },
    });
    defer ok.deinit(alloc);
    try testing.expect(ok == .receipt);
    try testing.expect(std.mem.startsWith(u8, ok.receipt.plugin_id, "demo-"));
}

test "host-only run resolves synchronously, registers tools, invokes, stops" {
    const alloc = testing.allocator;
    var reg = DynamicRegistry.init(alloc);
    defer reg.deinit();
    const sbx = sandbox_mod.Sandbox.initDefault(alloc);
    if (!nodeAvailable(&sbx)) return; // node unavailable → skip live half
    var lc = Lifecycle.init(alloc, &reg, sbx);
    defer lc.deinit();

    var d = try lc.define(.{
        .session_id = "sess-a",
        .plugin = .{ .new = .{ .idPrefix = "abc" } },
        .name = "counter",
        .purpose = "demo",
        .code = .{ .host =
        \\harness.handle('ping', () => 'pong');
        \\harness.defineTool({ name: 'count', description: 'counts' });
        \\return {};
        },
    });
    defer d.deinit(alloc);
    try testing.expect(d == .receipt);
    const pid = d.receipt.plugin_id;
    const pkg = d.receipt.package_id;

    // Cross-session acting verbs read as absent (PluginNotFound).
    try testing.expectError(error.PluginNotFound, lc.stop("sess-b", pid));
    try testing.expectError(error.PluginNotFound, lc.run("sess-b", pid, pkg, .run));

    const outcome = try lc.run("sess-a", pid, pkg, .run);
    defer outcome.deinit(alloc);
    try testing.expectEqual(types.RunStatus.running, outcome.status);

    // Registry committed current pointer; physical run installed.
    const p = reg.getPlugin(pid).?;
    try testing.expectEqualStrings(pkg, p.current_package_id.?);
    try testing.expect(p.run != null);

    // Registrations adopted from the sandbox child.
    const tools = try lc.toolsFor(alloc, pid);
    defer {
        for (tools) |*t| t.deinit(alloc);
        alloc.free(tools);
    }
    try testing.expectEqual(@as(usize, 1), tools.len);
    try testing.expectEqualStrings("count", tools[0].name);
    const handles = try lc.handlesFor(alloc, pid);
    defer {
        for (handles) |h| alloc.free(h);
        alloc.free(handles);
    }
    try testing.expectEqual(@as(usize, 1), handles.len);

    // Invoke through the registered handler.
    var inv = try lc.invoke(pid, null, "ping", "{}");
    defer inv.deinit(alloc);
    try testing.expect(inv.ok);
    try testing.expectEqualStrings("\"pong\"", inv.value_json);
    // Stale run id rejected.
    try testing.expectError(error.StaleRevision, lc.invoke(pid, "run-999", "ping", "{}"));

    // Restart same package allowed (mode=run); switching needs mode=update.
    const again = try lc.run("sess-a", pid, pkg, .run);
    defer again.deinit(alloc);
    try testing.expectEqual(types.RunStatus.running, again.status);

    var d2 = try lc.define(.{
        .session_id = "sess-a",
        .plugin = .{ .existing = pid },
        .name = "counter2",
        .purpose = "second revision",
        .code = .{ .host = "return {}" },
    });
    defer d2.deinit(alloc);
    try testing.expectError(error.InvalidMode, lc.run("sess-a", pid, d2.receipt.package_id, .run));
    const upd = try lc.run("sess-a", pid, d2.receipt.package_id, .update);
    defer upd.deinit(alloc);
    try testing.expectEqual(types.RunStatus.running, upd.status);

    // Stop is idempotent.
    const st = try lc.stop("sess-a", pid);
    try testing.expect(st == .ok);
    const st2 = try lc.stop("sess-a", pid);
    try testing.expect(st2 == .not_running);
    try testing.expect(reg.getPlugin(pid).?.run == null);
    // Packages retained until undefine; undefine reports not-running.
    const ud = try lc.undefine("sess-a", pid);
    try testing.expect(!ud.wasRunning);
    try testing.expect(reg.getPlugin(pid) == null);
}

test "client-bearing run suspends, decline wins, late resolve ignored" {
    const alloc = testing.allocator;
    var reg = DynamicRegistry.init(alloc);
    defer reg.deinit();
    const sbx = sandbox_mod.Sandbox.initDefault(alloc);
    var lc = Lifecycle.init(alloc, &reg, sbx);
    lc.poll_ms = 2;
    defer lc.deinit();

    var d = try lc.define(.{
        .session_id = "sess-a",
        .plugin = .{ .new = .{ .idPrefix = "xyz" } },
        .name = "panel",
        .purpose = "needs approval",
        .code = .{ .host = "return {}", .client = "return {}" },
    });
    defer d.deinit(alloc);
    const pid = d.receipt.plugin_id;
    const pkg = d.receipt.package_id;

    const Ctx = struct {
        lc: *Lifecycle,
        pid: []const u8,
        pkg: []const u8,
        started: std.atomic.Value(bool) = .init(false),
        outcome: ?RunOutcome = null,
        fn body(ctx: *@This()) void {
            ctx.started.store(true, .release);
            ctx.outcome = ctx.lc.run("sess-a", ctx.pid, ctx.pkg, .run) catch null;
        }
    };
    var ctx = Ctx{ .lc = &lc, .pid = pid, .pkg = pkg };
    const th = try std.Thread.spawn(.{}, Ctx.body, .{&ctx});

    // Wait for suspension.
    var waited: usize = 0;
    while (waited < 5000) : (waited += 1) {
        {
            lc.lock.lock();
            defer lc.lock.unlock();
            if (reg.pendingRequestFor(pid) != null) break;
        }
        sync.backoffSleepMs(2);
    }
    const req_id = try alloc.dupe(u8, blk: {
        lc.lock.lock();
        defer lc.lock.unlock();
        break :blk reg.pendingRequestFor(pid).?;
    });
    defer alloc.free(req_id);

    // Decline (first answer wins) — no node needed, rejection precedes eval.
    const rr = lc.resolveRequestRun(req_id, .rejected);
    try testing.expect(rr.accepted);
    // Late/duplicate answer ignored.
    try testing.expect(!lc.resolveRequestRun(req_id, .approved).accepted);
    try testing.expect(!lc.resolveRequestRun("approval-99999", .approved).accepted);

    th.join();
    const oc = ctx.outcome.?;
    defer oc.deinit(alloc);
    try testing.expectEqual(types.RunStatus.rejected, oc.status);
    // latestRun records rejection; no activation committed.
    const ident = blk: {
        lc.lock.lock();
        defer lc.lock.unlock();
        break :blk reg.latestRunIdentity(pid).?;
    };
    try testing.expectEqual(types.RunStatus.rejected, ident.status);
    try testing.expect(reg.getPlugin(pid).?.current_package_id == null);
}

test "approve path runs host half and grants revision (needs node)" {
    const alloc = testing.allocator;
    var reg = DynamicRegistry.init(alloc);
    defer reg.deinit();
    const sbx = sandbox_mod.Sandbox.initDefault(alloc);
    if (!nodeAvailable(&sbx)) return;
    var lc = Lifecycle.init(alloc, &reg, sbx);
    lc.poll_ms = 2;
    defer lc.deinit();

    var d = try lc.define(.{
        .session_id = "sess-a",
        .plugin = .{ .new = .{ .idPrefix = "qrs" } },
        .name = "widget",
        .purpose = "approved flow",
        .code = .{ .host = "harness.handle('hi', () => 42); return {};", .client = "return {}" },
    });
    defer d.deinit(alloc);
    const pid = d.receipt.plugin_id;
    const pkg = d.receipt.package_id;

    const Ctx = struct {
        lc: *Lifecycle,
        pid: []const u8,
        pkg: []const u8,
        started: std.atomic.Value(bool) = .init(false),
        outcome: ?RunOutcome = null,
        fn body(ctx: *@This()) void {
            ctx.started.store(true, .release);
            ctx.outcome = ctx.lc.run("sess-a", ctx.pid, ctx.pkg, .run) catch null;
        }
    };
    var ctx = Ctx{ .lc = &lc, .pid = pid, .pkg = pkg };
    const th = try std.Thread.spawn(.{}, Ctx.body, .{&ctx});

    var waited: usize = 0;
    var req_id: ?[]u8 = null;
    defer if (req_id) |r| alloc.free(r);
    while (waited < 5000) : (waited += 1) {
        {
            lc.lock.lock();
            defer lc.lock.unlock();
            if (reg.pendingRequestFor(pid)) |rq| {
                req_id = try alloc.dupe(u8, rq);
                break;
            }
        }
        sync.backoffSleepMs(2);
    }
    try testing.expect(req_id != null);
    try testing.expect(lc.resolveRequestRun(req_id.?, .approved).accepted);

    th.join();
    const oc = ctx.outcome.?;
    defer oc.deinit(alloc);
    try testing.expectEqual(types.RunStatus.running, oc.status);

    const p = blk: {
        lc.lock.lock();
        defer lc.lock.unlock();
        break :blk reg.getPlugin(pid).?;
    };
    try testing.expectEqualStrings(pkg, p.current_package_id.?);
    try testing.expect(p.approved_client_packages.contains(pkg));
    // Second run of the SAME revision skips suspension entirely (grant held).
    const again = try lc.run("sess-a", pid, pkg, .run);
    defer again.deinit(alloc);
    try testing.expectEqual(types.RunStatus.running, again.status);
}

test "approval timeout cancels suspension and disarms the request" {
    const alloc = testing.allocator;
    var reg = DynamicRegistry.init(alloc);
    defer reg.deinit();
    const sbx = sandbox_mod.Sandbox.initDefault(alloc);
    var lc = Lifecycle.init(alloc, &reg, sbx);
    lc.poll_ms = 2;
    lc.approval_timeout_ms = 40;
    defer lc.deinit();

    var d = try lc.define(.{
        .session_id = "sess-a",
        .plugin = .{ .new = .{ .idPrefix = "tuv" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "return {}", .client = "return {}" },
    });
    defer d.deinit(alloc);
    const pid = d.receipt.plugin_id;
    const pkg = d.receipt.package_id;

    const req_before = blk: {
        const oc = try lc.run("sess-a", pid, pkg, .run);
        defer oc.deinit(alloc);
        try testing.expectEqual(types.RunStatus.cancelled, oc.status);
        break :blk try alloc.dupe(u8, oc.approval_request_id.?);
    };
    defer alloc.free(req_before);

    // Request disarmed; late decision ignored.
    {
        lc.lock.lock();
        defer lc.lock.unlock();
        try testing.expect(reg.pendingRequestFor(pid) == null);
    }
    try testing.expect(!lc.resolveRequestRun(req_before, .approved).accepted);
    try testing.expectEqual(types.RunStatus.cancelled, reg.latestRunIdentity(pid).?.status);
}

test "stop during suspension cancels the waiting run" {
    const alloc = testing.allocator;
    var reg = DynamicRegistry.init(alloc);
    defer reg.deinit();
    const sbx = sandbox_mod.Sandbox.initDefault(alloc);
    var lc = Lifecycle.init(alloc, &reg, sbx);
    lc.poll_ms = 2;
    defer lc.deinit();

    var d = try lc.define(.{
        .session_id = "sess-a",
        .plugin = .{ .new = .{ .idPrefix = "wxy" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "return {}", .client = "return {}" },
    });
    defer d.deinit(alloc);
    const pid = d.receipt.plugin_id;
    const pkg = d.receipt.package_id;

    const Ctx = struct {
        lc: *Lifecycle,
        pid: []const u8,
        pkg: []const u8,
        outcome: ?RunOutcome = null,
        fn body(ctx: *@This()) void {
            ctx.outcome = ctx.lc.run("sess-a", ctx.pid, ctx.pkg, .run) catch null;
        }
    };
    var ctx = Ctx{ .lc = &lc, .pid = pid, .pkg = pkg };
    const th = try std.Thread.spawn(.{}, Ctx.body, .{&ctx});

    var waited: usize = 0;
    while (waited < 5000) : (waited += 1) {
        {
            lc.lock.lock();
            defer lc.lock.unlock();
            if (reg.pendingRequestFor(pid) != null) break;
        }
        sync.backoffSleepMs(2);
    }
    const st = try lc.stop("sess-a", pid);
    try testing.expect(st == .ok);

    th.join();
    const oc = ctx.outcome.?;
    defer oc.deinit(alloc);
    try testing.expectEqual(types.RunStatus.cancelled, oc.status);
}
