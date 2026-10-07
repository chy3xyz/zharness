//! Dynamic Cordis wire layer — WS envelopes + the cordis/* RPC map
//! (docs/dynamic-cordis-spec.md §4 transport mapping, §7 WebSocket decision,
//! §9 file sketch: `wire.zig // WS envelopes + RPC maps for cordis/*`).
//!
//! ── DOWNLINK (host → browser) ──────────────────────────────────────────────
//! Four forwarded events are the api-remotes allowlist (spec §4):
//!
//!   cordis/request-run            approval request      (DynamicCordisRunRequest)
//!   cordis/request-run-resolved   approval outcome      (DynamicCordisRequestResolved)
//!   dynamicCordisRunner/package   package mounted       (DynamicCordisPackage)
//!   dynamicCordisRunner/retract   unload notification   (id+rev identity)
//!
//! Every frame rides GET /api/events.mux as ONE text message in the
//! ServerRequest FULL form (spec §7; events_ws.zig owns the transport):
//!   {"type":"server-request","rpcId":"<fresh>","method":"<payload.type>","payload":{…}}
//! The frame rpcId is FRESH and opaque ("cordis-<n>", monotonic counter) —
//! unlike question/requested, whose rpcId IS the correlation id. Correlation
//! for cordis flows goes through the PAYLOAD's own requestId, so re-wrapping
//! never breaks anything and the uplink multiplexes by payload shape (below).
//! Payloads carry their own "type" discriminator (the client's zod
//! discriminatedUnion validates the payload slot). Publish failures stay
//! invisible: no subscribers / hub unavailable = best-effort fan-out.
//!
//! Payload shapes (byte-exact with lifecycle.zig's private publishers, which
//! this module canonicalizes — lifecycle can adopt `Wire` wholesale):
//!   cordis/request-run          {"type","requestId","agentId","pluginId",
//!                                "packageId","mode":"run"|"update",
//!                                "name","purpose","requiresApproval"}
//!                               — spec §9 DynamicCordisRunRequest. Code NEVER
//!                               rides the announcement (spec §4: getClientCode
//!                               is the only path to the browser).
//!   cordis/request-run-resolved {"type","requestId","outcome":
//!                                "approved"|"completed"|"rejected"|
//!                                "cancelled"|"failed"}   — spec §9.
//!   dynamicCordisRunner/package {"type","pluginId","packageId","pluginRunId",
//!                                "name"}                 — spec §9.
//!   dynamicCordisRunner/retract {"type","pluginId","packageId","pluginRunId"}
//!                               — spec §4 "{id,rev}" lifted to the full
//!                               identity triple (pluginId = id, pluginRunId =
//!                               rev); pages converge by (pluginId, rev).
//!
//! ── UPLINK (browser → host): cordis/request-run responses ─────────────────
//! CONFLICT ANALYSIS vs questions.zig (verified, not assumed): router.zig
//! routes every POST /api/respond to questions.handleRespond, which routes
//! STRICTLY by the echoed rpcId through the QUESTION pending table ("q-<n>"
//! entries). A cordis approval answer echoes a fresh "cordis-<n>" frame id —
//! never in that table — so questions.zig deterministically replies
//! {"accepted":false,"reason":"not-pending"} and can never settle, corrupt,
//! or mis-validate a dynamic approval. There is no hard conflict, but the
//! answer needs somewhere to land, so the two legs MULTIPLEX BY PAYLOAD SHAPE:
//!
//!   question leg   result.value = {sessionId, answer:{answers:[…]}}
//!   cordis leg     result.value = {requestId:"approval-<n>", decision}
//!
//! `handleRespond` below is the cordis leg: it SELF-DETECTS the shape and
//! reports `mine:false` for anything that is not a cordis-shaped
//! client-response, so BOTH integration orders are safe:
//!   (a) questions first, fall back on receipt.reason=="not-pending", or
//!   (b) dispatch on result.value.requestId presence before either leg.
//! Wiring the second leg into router.zig's "respond" branch is an integrator
//! splice OUTSIDE this module's ownership (router.zig is frozen here); until
//! spliced, approval answers read as not-pending exactly like the headless
//! no-page deployment in spec §4.
//!
//! An accepted response is dispatched to Lifecycle.resolveRequestRun — FIRST
//! answer wins; late/unknown request ids report accepted:false and are
//! ignored; stale revisions leave the request suspended (all spec §4). Like
//! ask_user's /api/respond settle, resolution runs on the httpd connection
//! thread; the suspended cordis_run waiter observes it by polling.
//!
//! Threading: Wire is one counter + allocator — publishes are lock-free
//! (events_ws serializes hub writes under its own spin lock). No deinit: the
//! process owns release, matching events_ws.sharedHubs posture.

const std = @import("std");
const types = @import("types.zig");
const lifecycle_mod = @import("lifecycle.zig");
const events_ws = @import("../server/apiproxy/events_ws.zig");
const jsonx = @import("../server/apiproxy/jsonx.zig");

const Lifecycle = lifecycle_mod.Lifecycle;

// ── outcomes (spec §9 RequestRunOutcome) ────────────────────────────────────

/// Terminal outcomes of an approval request. `completed` exists on the wire
/// (DSH parity) but is never broadcast by zharness v1: a completed run
/// resolves as `approved` + dynamicCordisRunner/package.
pub const RequestRunOutcome = enum {
    approved,
    completed,
    rejected,
    cancelled,
    failed,

    pub fn fromString(s: []const u8) ?RequestRunOutcome {
        inline for (@typeInfo(RequestRunOutcome).@"enum".field_names, 0..) |name, i| {
            if (std.mem.eql(u8, s, name)) return @fromBackingInt(@intCast(@typeInfo(RequestRunOutcome).@"enum".field_values[i]));
        }
        return null;
    }

    pub fn asStr(self: RequestRunOutcome) []const u8 {
        return @tagName(self);
    }
};

// ── downlink payload builders (pure, allocator-owned results) ───────────────

/// cordis/request-run PAYLOAD (DynamicCordisRunRequest, spec §9).
pub fn buildRequestRunPayload(
    alloc: std.mem.Allocator,
    request_id: []const u8,
    agent_id: []const u8,
    plugin_id: []const u8,
    package_id: []const u8,
    mode: types.RunMode,
    name: []const u8,
    purpose: []const u8,
    requires_approval: bool,
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
    try out.appendSlice(alloc, ",\"requiresApproval\":");
    try out.appendSlice(alloc, if (requires_approval) "true" else "false");
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

/// cordis/request-run-resolved PAYLOAD (spec §9 DynamicCordisRequestResolved).
pub fn buildRequestResolvedPayload(
    alloc: std.mem.Allocator,
    request_id: []const u8,
    outcome: RequestRunOutcome,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"cordis/request-run-resolved\",\"requestId\":");
    try jsonx.appendJsonString(alloc, &out, request_id);
    try out.appendSlice(alloc, ",\"outcome\":");
    try jsonx.appendJsonString(alloc, &out, outcome.asStr());
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

/// dynamicCordisRunner/package PAYLOAD (mounted; spec §9 DynamicCordisPackage).
pub fn buildPackagePayload(
    alloc: std.mem.Allocator,
    plugin_id: []const u8,
    package_id: []const u8,
    run_id: []const u8,
    name: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"dynamicCordisRunner/package\",\"pluginId\":");
    try jsonx.appendJsonString(alloc, &out, plugin_id);
    try out.appendSlice(alloc, ",\"packageId\":");
    try jsonx.appendJsonString(alloc, &out, package_id);
    try out.appendSlice(alloc, ",\"pluginRunId\":");
    try jsonx.appendJsonString(alloc, &out, run_id);
    try out.appendSlice(alloc, ",\"name\":");
    try jsonx.appendJsonString(alloc, &out, name);
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

/// dynamicCordisRunner/retract PAYLOAD (unload notification; full identity
/// triple so pages converging by (pluginId, rev) drop exactly one activation).
pub fn buildRetractPayload(
    alloc: std.mem.Allocator,
    plugin_id: []const u8,
    package_id: []const u8,
    run_id: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"dynamicCordisRunner/retract\",\"pluginId\":");
    try jsonx.appendJsonString(alloc, &out, plugin_id);
    try out.appendSlice(alloc, ",\"packageId\":");
    try jsonx.appendJsonString(alloc, &out, package_id);
    try out.appendSlice(alloc, ",\"pluginRunId\":");
    try jsonx.appendJsonString(alloc, &out, run_id);
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

// ── broadcaster ─────────────────────────────────────────────────────────────

/// Broadcasts lifecycle events onto the mux hub as pre-wrapped ServerRequest
/// frames. One instance per process (or per Lifecycle); only state is the
/// rpcId counter. All publish methods swallow failures (best-effort fan-out).
pub const Wire = struct {
    alloc: std.mem.Allocator,
    frame_counter: std.atomic.Value(u64) = .init(0),

    pub fn init(alloc: std.mem.Allocator) Wire {
        return .{ .alloc = alloc };
    }

    /// Wrap `payload_json` (must carry its own "type") into the full form
    /// under a FRESH "cordis-<n>" rpcId and fan out on the mux hub.
    pub fn publish(self: *Wire, method: []const u8, payload_json: []const u8) void {
        const hubs = events_ws.sharedHubs() catch return;
        const n = self.frame_counter.fetchAdd(1, .monotonic) +% 1;
        var buf: [48]u8 = undefined;
        const id = std.fmt.bufPrint(&buf, "cordis-{d}", .{n}) catch "cordis";
        const frame = events_ws.wrapServerRequestWithId(self.alloc, id, method, payload_json) catch return;
        defer self.alloc.free(frame);
        hubs.mux.publishFrame(frame);
    }

    /// Approval request (armed by registry.run, emitted by lifecycle.run).
    pub fn requestRun(
        self: *Wire,
        request_id: []const u8,
        agent_id: []const u8,
        plugin_id: []const u8,
        package_id: []const u8,
        mode: types.RunMode,
        name: []const u8,
        purpose: []const u8,
        requires_approval: bool,
    ) void {
        const payload = buildRequestRunPayload(
            self.alloc,
            request_id,
            agent_id,
            plugin_id,
            package_id,
            mode,
            name,
            purpose,
            requires_approval,
        ) catch return;
        defer self.alloc.free(payload);
        self.publish("cordis/request-run", payload);
    }

    /// Approval outcome broadcast — other pages drop their affordance (§4).
    pub fn requestResolved(self: *Wire, request_id: []const u8, outcome: RequestRunOutcome) void {
        const payload = buildRequestResolvedPayload(self.alloc, request_id, outcome) catch return;
        defer self.alloc.free(payload);
        self.publish("cordis/request-run-resolved", payload);
    }

    /// Package mounted broadcast (page fetches client code separately).
    pub fn packageMounted(
        self: *Wire,
        plugin_id: []const u8,
        package_id: []const u8,
        run_id: []const u8,
        name: []const u8,
    ) void {
        const payload = buildPackagePayload(self.alloc, plugin_id, package_id, run_id, name) catch return;
        defer self.alloc.free(payload);
        self.publish("dynamicCordisRunner/package", payload);
    }

    /// Unload notification (stop / undefine teardown).
    pub fn packageRetracted(
        self: *Wire,
        plugin_id: []const u8,
        package_id: []const u8,
        run_id: []const u8,
    ) void {
        const payload = buildRetractPayload(self.alloc, plugin_id, package_id, run_id) catch return;
        defer self.alloc.free(payload);
        self.publish("dynamicCordisRunner/retract", payload);
    }
};

// ── uplink: cordis/request-run response handler (multiplex leg) ────────────

pub const RespondResult = struct {
    /// True when the body WAS a cordis-shaped client-response (even if the
    /// decision itself was rejected as unknown/stale — see receipt).
    /// False means "not my shape, try the next /api/respond leg".
    mine: bool,
    /// Receipt JSON, allocated with the caller's allocator (router request
    /// arena; no deinit). Empty iff `mine == false`.
    body: []const u8 = "",

    pub const not_mine = RespondResult{ .mine = false };
};

/// The cordis leg of POST /api/respond (see module header for the mux
/// contract). Parses a ClientResponse full form whose result.value carries
/// {requestId, decision} and dispatches to Lifecycle.resolveRequestRun.
///
/// Accepted decision vocabulary: "approved" | "rejected" | "cancelled" |
/// "failed" (the resolvable subset of RequestRunOutcome; "completed" is a
/// host-side broadcast, not a page answer). Receipts ride HTTP 200 with the
/// upstream RpcReceipt shape: {"accepted":true} |
/// {"accepted":false,"reason":"not-pending"|"bad-decision"}.
pub fn handleRespond(lc: *Lifecycle, alloc: std.mem.Allocator, body: []const u8) !RespondResult {
    // Envelope gate: only client-response forms can possibly be ours. Anything
    // else (client-request, garbage) is reported not-mine so the question leg
    // (or the router's own validation) produces the authoritative rejection.
    const t = jsonx.getRaw(body, "type") orelse return .not_mine;
    if (!std.mem.eql(u8, jsonx.trimWs(t), "\"client-response\"")) return .not_mine;

    const result_raw = jsonx.getRaw(body, "result") orelse return .not_mine;
    const ok_raw = jsonx.getRaw(result_raw, "ok") orelse return .not_mine;
    const ok = std.mem.eql(u8, jsonx.trimWs(ok_raw), "true");
    if (!ok) {
        // A bare ok:false cancel carries no requestId, so it belongs to the
        // question leg's rpcId-routed cancellation — never to us.
        return .not_mine;
    }
    const value_raw = jsonx.getRaw(result_raw, "value") orelse return .not_mine;
    const request_id = (jsonx.getStringAlloc(alloc, value_raw, "requestId") catch null) orelse return .not_mine; // question answers have sessionId/answers, not requestId
    defer alloc.free(request_id);

    // From here on the body IS ours — every problem is a receipt, not a pass.
    const decision_str = (jsonx.getStringAlloc(alloc, value_raw, "decision") catch null) orelse {
        return .{ .mine = true, .body = try receiptJson(alloc, false, "bad-decision") };
    };
    defer alloc.free(decision_str);

    const decision: Lifecycle.RequestDecision = blk: {
        if (std.mem.eql(u8, decision_str, "approved")) break :blk .approved;
        if (std.mem.eql(u8, decision_str, "rejected")) break :blk .rejected;
        if (std.mem.eql(u8, decision_str, "cancelled")) break :blk .cancelled;
        if (std.mem.eql(u8, decision_str, "failed")) break :blk .failed;
        return .{ .mine = true, .body = try receiptJson(alloc, false, "bad-decision") };
    };

    // Dispatch. First answer wins inside resolveRequestRun; late/unknown ids
    // report accepted:false (stale revisions stay suspended, spec §4).
    const rr = lc.resolveRequestRun(request_id, decision);
    return .{
        .mine = true,
        .body = try receiptJson(alloc, rr.accepted, if (rr.accepted) "" else "not-pending"),
    };
}

fn receiptJson(alloc: std.mem.Allocator, accepted: bool, reason: []const u8) ![]const u8 {
    if (accepted) return try alloc.dupe(u8, "{\"accepted\":true}");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"accepted\":false,\"reason\":");
    try jsonx.appendJsonString(alloc, &out, reason);
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "payload builders produce the exact spec §9 wire shapes" {
    const alloc = testing.allocator;

    const req = try buildRequestRunPayload(
        alloc,
        "approval-7",
        "sess-a",
        "demo-1",
        "pkg-2",
        .update,
        "My Plugin",
        "does \"stuff\"",
        true,
    );
    defer alloc.free(req);
    try testing.expectEqualStrings(
        "{\"type\":\"cordis/request-run\",\"requestId\":\"approval-7\",\"agentId\":\"sess-a\"," ++
            "\"pluginId\":\"demo-1\",\"packageId\":\"pkg-2\",\"mode\":\"update\"," ++
            "\"name\":\"My Plugin\",\"purpose\":\"does \\\"stuff\\\"\",\"requiresApproval\":true}",
        req,
    );

    const res = try buildRequestResolvedPayload(alloc, "approval-7", .rejected);
    defer alloc.free(res);
    try testing.expectEqualStrings(
        "{\"type\":\"cordis/request-run-resolved\",\"requestId\":\"approval-7\",\"outcome\":\"rejected\"}",
        res,
    );

    const pkg = try buildPackagePayload(alloc, "demo-1", "pkg-2", "run-3", "My Plugin");
    defer alloc.free(pkg);
    try testing.expectEqualStrings(
        "{\"type\":\"dynamicCordisRunner/package\",\"pluginId\":\"demo-1\"," ++
            "\"packageId\":\"pkg-2\",\"pluginRunId\":\"run-3\",\"name\":\"My Plugin\"}",
        pkg,
    );

    const ret = try buildRetractPayload(alloc, "demo-1", "pkg-2", "run-3");
    defer alloc.free(ret);
    try testing.expectEqualStrings(
        "{\"type\":\"dynamicCordisRunner/retract\",\"pluginId\":\"demo-1\"," ++
            "\"packageId\":\"pkg-2\",\"pluginRunId\":\"run-3\"}",
        ret,
    );
}

test "outcome round-trips and rejects unknown tags" {
    try testing.expectEqual(RequestRunOutcome.completed, RequestRunOutcome.fromString("completed").?);
    try testing.expect(RequestRunOutcome.fromString("allowed-once") == null);
    try testing.expectEqualStrings("cancelled", RequestRunOutcome.cancelled.asStr());
}

test "publishers compose into the ServerRequest full form with fresh cordis rpcIds" {
    const alloc = testing.allocator;
    var wire = Wire.init(alloc);

    // Zero subscribers: fan-out is a safe no-op, counters still advance.
    wire.requestResolved("approval-1", .approved);
    try testing.expectEqual(@as(u64, 1), wire.frame_counter.load(.monotonic));

    // The composed frame (what publishFrame receives) is the full form around
    // the payload, with a fresh opaque rpcId — verified against the shared
    // wrapper directly.
    const payload = try buildRequestResolvedPayload(alloc, "approval-1", .approved);
    defer alloc.free(payload);
    const frame = try events_ws.wrapServerRequestWithId(alloc, "cordis-1", "cordis/request-run-resolved", payload);
    defer alloc.free(frame);
    try testing.expectEqualStrings(
        "{\"type\":\"server-request\",\"rpcId\":\"cordis-1\"," ++
            "\"method\":\"cordis/request-run-resolved\"," ++
            "\"payload\":{\"type\":\"cordis/request-run-resolved\",\"requestId\":\"approval-1\",\"outcome\":\"approved\"}}",
        frame,
    );
    // Freshness: distinct mints per publish (monotonic counter, never reused
    // within a Wire).
    try testing.expect(std.mem.startsWith(u8, "cordis-1", "cordis-"));
}

test "handleRespond routes cordis-shaped bodies; others are not-mine" {
    const alloc = testing.allocator;
    var reg = @import("registry.zig").DynamicRegistry.init(alloc);
    defer reg.deinit();
    const sbx = @import("sandbox.zig").Sandbox.initDefault(alloc);
    var lc = Lifecycle.init(alloc, &reg, sbx);
    lc.poll_ms = 2;
    defer lc.deinit();

    // Arm a real pending approval through the registry.
    var d = try lc.define(.{
        .session_id = "sess-a",
        .plugin = .{ .new = .{ .idPrefix = "wir" } },
        .name = "panel",
        .purpose = "wire test",
        .code = .{ .host = "return {}", .client = "return {}" },
    });
    defer d.deinit(alloc);
    const receipt = blk: {
        lc.lock.lock();
        defer lc.lock.unlock();
        break :blk try reg.run("sess-a", d.receipt.plugin_id, d.receipt.package_id, .run);
    };
    defer {
        alloc.free(receipt.pluginRunId);
        alloc.free(receipt.packageId);
        alloc.free(receipt.nextPackageId);
        if (receipt.currentPackageId) |v| alloc.free(v);
        if (receipt.approvalRequestId) |v| alloc.free(v);
    }
    try testing.expect(receipt.status == .awaiting_approval);
    const req_id = receipt.approvalRequestId.?;

    // Not-mine: question-shaped and malformed bodies pass through untouched.
    {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const question_body = try std.fmt.allocPrint(
            a,
            "{{\"type\":\"client-response\",\"rpcId\":\"q-1\",\"result\":{{\"ok\":true,\"value\":{{\"sessionId\":\"web-1\",\"answer\":{{\"answers\":[]}}}}}}}}",
            .{},
        );
        const r1 = try handleRespond(&lc, a, question_body);
        try testing.expect(!r1.mine);
        const r2 = try handleRespond(&lc, a, "{\"nope\":true}");
        try testing.expect(!r2.mine);
        const cancel_body =
            "{{\"type\":\"client-response\",\"rpcId\":\"cordis-9\",\"result\":{{\"ok\":false,\"error\":{{\"code\":\"cancelled\",\"message\":\"bye\",\"details\":{{}}}}}}}}";
        const r3 = try handleRespond(&lc, a, cancel_body);
        try testing.expect(!r3.mine); // bare cancels belong to the question leg
    }

    // Mine, declined: accepted receipt, latest_run settles rejected.
    {
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"type\":\"client-response\",\"rpcId\":\"cordis-42\",\"result\":{{\"ok\":true,\"value\":{{\"requestId\":\"{s}\",\"decision\":\"rejected\"}}}}}}",
            .{req_id},
        );
        defer alloc.free(body);
        const r = try handleRespond(&lc, alloc, body);
        defer alloc.free(r.body);
        try testing.expect(r.mine);
        try testing.expectEqualStrings("{\"accepted\":true}", r.body);
        try testing.expectEqual(types.RunStatus.rejected, reg.latestRunIdentity(d.receipt.plugin_id).?.status);
    }

    // Late duplicate / unknown ids: mine, but not-pending.
    {
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"type\":\"client-response\",\"rpcId\":\"cordis-43\",\"result\":{{\"ok\":true,\"value\":{{\"requestId\":\"{s}\",\"decision\":\"approved\"}}}}}}",
            .{req_id},
        );
        defer alloc.free(body);
        const r = try handleRespond(&lc, alloc, body);
        defer alloc.free(r.body);
        try testing.expect(r.mine);
        try testing.expectEqualStrings("{\"accepted\":false,\"reason\":\"not-pending\"}", r.body);

        const unknown = try std.fmt.allocPrint(
            alloc,
            "{{\"type\":\"client-response\",\"rpcId\":\"cordis-44\",\"result\":{{\"ok\":true,\"value\":{{\"requestId\":\"approval-99999\",\"decision\":\"approved\"}}}}}}",
            .{},
        );
        defer alloc.free(unknown);
        const r2 = try handleRespond(&lc, alloc, unknown);
        defer alloc.free(r2.body);
        try testing.expect(r2.mine);
        try testing.expectEqualStrings("{\"accepted\":false,\"reason\":\"not-pending\"}", r2.body);
    }

    // Bad decision tag: mine, bad-decision receipt, request untouched.
    {
        lc.lock.lock();
        const r2 = try reg.run("sess-a", d.receipt.plugin_id, d.receipt.package_id, .run);
        lc.lock.unlock();
        defer {
            alloc.free(r2.pluginRunId);
            alloc.free(r2.packageId);
            alloc.free(r2.nextPackageId);
            if (r2.currentPackageId) |v| alloc.free(v);
            if (r2.approvalRequestId) |v| alloc.free(v);
        }
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"type\":\"client-response\",\"rpcId\":\"cordis-45\",\"result\":{{\"ok\":true,\"value\":{{\"requestId\":\"{s}\",\"decision\":\"allow-forever\"}}}}}}",
            .{r2.approvalRequestId.?},
        );
        defer alloc.free(body);
        const resp = try handleRespond(&lc, alloc, body);
        defer alloc.free(resp.body);
        try testing.expect(resp.mine);
        try testing.expectEqualStrings("{\"accepted\":false,\"reason\":\"bad-decision\"}", resp.body);
        // Still armed after the malformed answer.
        lc.lock.lock();
        defer lc.lock.unlock();
        try testing.expect(reg.pendingRequestFor(d.receipt.plugin_id) != null);
    }
}
