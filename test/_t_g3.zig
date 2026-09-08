//! G3-interactive wave-6 test root: ask_user tool + apiproxy/questions.
//! Run from src/:  zig test -lc test/_t_g3.zig
//! (top-level root so the modules' relative imports stay inside the module
//! path; integrator folds these into tests.zig).

const std = @import("std");
const testing = std.testing;

const ask_user = @import("../src/tool/ask_user.zig");
const questions = @import("../src/server/apiproxy/questions.zig");
const events_ws = @import("../src/server/apiproxy/events_ws.zig");
const tool_reg = @import("../src/tool/registry.zig");
const jsonx = @import("../src/server/apiproxy/jsonx.zig");

// ── shared test harness ─────────────────────────────────────────────────────

/// Captures published frames (thread-safe: publish may race the responder).
const FrameCapture = struct {
    lock: questions.SpinLock = .{},
    frames: std.ArrayList([]u8) = .empty,
    alloc: std.mem.Allocator,

    fn publish(self: *FrameCapture, frame_json: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        const copy = self.alloc.dupe(u8, frame_json) catch return;
        self.frames.append(self.alloc, copy) catch {
            self.alloc.free(copy);
        };
    }

    fn deinit(self: *FrameCapture) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.frames.items) |f| self.alloc.free(f);
        self.frames.deinit(self.alloc);
    }
};

var g_capture: ?*FrameCapture = null;

fn capturePublish(frame_json: []const u8) void {
    g_capture.?.publish(frame_json);
}

/// Responder thread body: wait until a question/requested frame appears,
/// extract its frame rpcId, then POST-style respond with the scripted answer
/// (or cancellation).
const Responder = struct {
    store: *questions.Store,
    alloc: std.mem.Allocator,
    capture: *FrameCapture,
    /// Label to answer with; null = cancel via result.ok:false code:'cancelled'.
    selected_label: ?[]const u8 = null,
    responded: bool = false,

    fn run(self: *Responder) void {
        // Wait for the requested frame (bounded: ~10 s).
        var waited: usize = 0;
        var rpc_raw: ?[]const u8 = null;
        defer if (rpc_raw) |r| self.alloc.free(r);
        while (waited < 10000) : (waited += 1) {
            {
                self.capture.lock.lock();
                defer self.capture.lock.unlock();
                for (self.capture.frames.items) |f| {
                    const t = jsonx.getRaw(f, "method") orelse continue;
                    if (!std.mem.eql(u8, jsonx.trimWs(t), "\"question/requested\"")) continue;
                    if (rpc_raw != null) continue;
                    const raw = jsonx.getRaw(f, "rpcId") orelse continue;
                    rpc_raw = self.alloc.dupe(u8, raw) catch null;
                }
            }
            if (rpc_raw != null) break;
            questions.backoffSleepMs(1);
        }
        if (rpc_raw == null) return; // timeout → main thread's own timeout fires

        var body: []u8 = undefined;
        if (self.selected_label) |label| {
            body = std.fmt.allocPrint(
                self.alloc,
                "{{\"type\":\"client-response\",\"rpcId\":{s},\"result\":{{\"ok\":true,\"value\":{{\"sessionId\":\"web-1\",\"answer\":{{\"answers\":[{{\"id\":\"q1\",\"selected\":[\"{s}\"]}}]}}}}}}}}",
                .{ rpc_raw.?, label },
            ) catch return;
        } else {
            body = std.fmt.allocPrint(
                self.alloc,
                "{{\"type\":\"client-response\",\"rpcId\":{s},\"result\":{{\"ok\":false,\"error\":{{\"code\":\"cancelled\",\"message\":\"user cancelled\",\"details\":{{}}}}}}}}",
                .{rpc_raw.?},
            ) catch return;
        }
        defer self.alloc.free(body);
        _ = self.store.respond(body);
        self.responded = true;
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

test "ask_user definition matches fixture and registers into the registry" {
    const alloc = testing.allocator;

    try testing.expectEqualStrings("ask_user", ask_user.definition.name);
    try testing.expect(ask_user.definition.description.len > 0);
    // Upstream item shape needs question + optional options; schema must say so.
    try testing.expect(std.mem.indexOf(u8, ask_user.definition.parameters_json, "\"required\":[\"question\"]") != null);
    try testing.expect(std.mem.indexOf(u8, ask_user.definition.parameters_json, "\"maxItems\":4") != null);

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try reg.register(ask_user.definition);
    const got = reg.get("ask_user") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("ask_user", got.name);

    const tools_json = try reg.buildToolsJson(alloc);
    defer alloc.free(tools_json);
    try testing.expect(std.mem.startsWith(u8, tools_json, "{\"type\":\"function\",\"function\":{\"name\":\"ask_user\""));
}

test "unwired executor fails gracefully without blocking" {
    const alloc = testing.allocator;
    ask_user.clearAskCtx(); // guarantee the unwired state regardless of order
    var res = try ask_user.execute(alloc, .{ .name = "ask_user", .arguments = "{\"question\":\"x\"}" });
    defer ask_user.freeResult(alloc, &res);
    try testing.expect(!res.success);
    try testing.expect(std.mem.indexOf(u8, res.err_msg.?, "setAskCtx") != null);
}

test "arg validation: missing/empty question and >4 options rejected" {
    const alloc = testing.allocator;
    ask_user.clearAskCtx();

    const cases = [_][]const u8{
        "{\"options\":[\"a\"]}", // missing question
        "{\"question\":\"\"}", // empty question
        "{\"question\":\"pick\",\"options\":[\"1\",\"2\",\"3\",\"4\",\"5\"]}", // >4 options
    };
    for (cases) |args| {
        var res = try ask_user.execute(alloc, .{ .name = "ask_user", .arguments = args });
        defer ask_user.freeResult(alloc, &res);
        try testing.expect(!res.success);
    }
}

test "happy path: request frame shape, respond from another thread, resolved frame" {
    const alloc = testing.allocator;

    var store: questions.Store = undefined;
    store.initInPlace(alloc);
    defer store.pendings.deinit(alloc);

    var capture = FrameCapture{ .alloc = alloc };
    defer capture.deinit();
    g_capture = &capture;

    var wiring = ask_user.AskCtx{
        .publish = capturePublish,
        .session_id = "web-1",
        .store = &store,
        .timeout_ms = 15_000,
        .poll_ms = 5,
    };
    ask_user.setAskCtx(&wiring);
    defer ask_user.clearAskCtx();

    var responder = Responder{
        .store = &store,
        .alloc = alloc,
        .capture = &capture,
        .selected_label = "Option B",
    };
    const th = try std.Thread.spawn(.{}, Responder.run, .{&responder});
    var res = try ask_user.execute(alloc, .{
        .name = "ask_user",
        .arguments = "{\"question\":\"Which path?\",\"options\":[\"Option A\",\"Option B\"]}",
    });
    th.join();

    defer ask_user.freeResult(alloc, &res);
    try testing.expect(responder.responded);
    try testing.expect(res.success);

    // Result text per contract.
    try testing.expectEqualStrings("user chose: Option B", res.output);

    // Envelope assertions vs the upstream shapes.
    try testing.expect(capture.frames.items.len >= 2); // requested + resolved
    const req_frame = capture.frames.items[0];
    try testing.expect(std.mem.startsWith(u8, req_frame, "{\"type\":\"server-request\",\"rpcId\":\""));
    try testing.expect(std.mem.indexOf(u8, req_frame, ",\"method\":\"question/requested\",\"payload\":{\"type\":\"question/requested\",\"sessionId\":\"web-1\",\"questions\":[{\"id\":\"q1\",\"question\":\"Which path?\",\"options\":[{\"label\":\"Option A\"},{\"label\":\"Option B\"}]}]}") != null);

    const res_frame = capture.frames.items[capture.frames.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, res_frame, "\"method\":\"question/resolved\"") != null);
    try testing.expect(std.mem.indexOf(u8, res_frame, "\"outcome\":\"answered\"") != null);
    try testing.expect(std.mem.indexOf(u8, res_frame, "\"questionRpcId\":\"") != null);

    try testing.expectEqual(@as(usize, 0), store.count()); // entry cleaned up
}

test "free-text custom answer renders as 'user answered'" {
    const alloc = testing.allocator;

    var store: questions.Store = undefined;
    store.initInPlace(alloc);
    defer store.pendings.deinit(alloc);

    // Register a free-text (optionless) question, settle it with a custom
    // answer the way questions.handleRespond would, then render it through
    // the tool's formatter.
    const qj = "[{\"id\":\"q1\",\"question\":\"When?\"}]";
    const p = try store.ask("web-1", qj);
    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"type\":\"client-response\",\"rpcId\":\"{s}\",\"result\":{{\"ok\":true,\"value\":{{\"sessionId\":\"web-1\",\"answer\":{{\"answers\":[{{\"id\":\"q1\",\"selected\":[],\"custom\":\"ship it Tuesday\"}}]}}}}}}}}",
        .{p.rpc_id},
    );
    defer alloc.free(body);
    try testing.expect(store.respond(body).accepted);
    const claim = store.claimWaiter(alloc, p);
    try testing.expect(claim == .answered);
    defer alloc.free(claim.answered);

    var res = try ask_user.formatAnswer(alloc, claim.answered);
    defer ask_user.freeResult(alloc, &res);
    try testing.expect(res.success);
    try testing.expectEqualStrings("user answered: ship it Tuesday", res.output);

    // Empty selection and no custom text → skipped.
    const skip_json =
        "{\"sessionId\":\"web-1\",\"answer\":{\"answers\":[{\"id\":\"q1\",\"selected\":[]}]}}";
    var res2 = try ask_user.formatAnswer(alloc, skip_json);
    defer ask_user.freeResult(alloc, &res2);
    try testing.expectEqualStrings("user skipped the question", res2.output);

    // Multi-select joins labels.
    const multi_json =
        "{\"sessionId\":\"web-1\",\"answer\":{\"answers\":[{\"id\":\"q1\",\"selected\":[\"A\",\"B\"]}]}}";
    var res3 = try ask_user.formatAnswer(alloc, multi_json);
    defer ask_user.freeResult(alloc, &res3);
    try testing.expectEqualStrings("user chose: A, B", res3.output);
}

test "timeout path: failed result + cancelled resolution" {
    const alloc = testing.allocator;

    var store: questions.Store = undefined;
    store.initInPlace(alloc);
    defer store.pendings.deinit(alloc);

    var capture = FrameCapture{ .alloc = alloc };
    defer capture.deinit();
    g_capture = &capture;

    var wiring = ask_user.AskCtx{
        .publish = capturePublish,
        .session_id = "web-1",
        .store = &store,
        .timeout_ms = 120,
        .poll_ms = 25,
    };
    ask_user.setAskCtx(&wiring);
    defer ask_user.clearAskCtx();

    var res = try ask_user.execute(alloc, .{
        .name = "ask_user",
        .arguments = "{\"question\":\"Anyone there?\"}",
    });
    defer ask_user.freeResult(alloc, &res);

    try testing.expect(!res.success);
    try testing.expect(std.mem.indexOf(u8, res.err_msg.?, "timed out") != null or
        std.mem.indexOf(u8, res.err_msg.?, "cancelled") != null);

    // Resolved frame emitted with cancelled outcome (upstream timeout posture).
    try testing.expect(capture.frames.items.len >= 2);
    const res_frame = capture.frames.items[capture.frames.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, res_frame, "\"outcome\":\"cancelled\"") != null);
    try testing.expectEqual(@as(usize, 0), store.count());
}

test "cancel-all sweep breaks a waiting execute (session.cancel hook)" {
    const alloc = testing.allocator;

    var store: questions.Store = undefined;
    store.initInPlace(alloc);
    defer store.pendings.deinit(alloc);

    var capture = FrameCapture{ .alloc = alloc };
    defer capture.deinit();
    g_capture = &capture;

    var wiring = ask_user.AskCtx{
        .publish = capturePublish,
        .session_id = "web-7",
        .store = &store,
        .timeout_ms = 30_000,
        .poll_ms = 5,
    };
    ask_user.setAskCtx(&wiring);
    defer ask_user.clearAskCtx();

    const Canceller = struct {
        fn run(s: *questions.Store) void {
            // Wait until the question is registered, then sweep it.
            var waited: usize = 0;
            while (s.count() == 0 and waited < 5000) : (waited += 1)
                questions.backoffSleepMs(1);
            _ = s.cancelAllForSession("web-7");
        }
    };
    const th = try std.Thread.spawn(.{}, Canceller.run, .{&store});

    var res = try ask_user.execute(alloc, .{
        .name = "ask_user",
        .arguments = "{\"question\":\"long wait\"}",
    });
    th.join();
    defer ask_user.freeResult(alloc, &res);

    try testing.expect(!res.success); // cancelled reads as failure to the model
    try testing.expectEqual(@as(usize, 0), store.count());
}

test "handleRespond emits exact upstream receipt bytes" {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var store: questions.Store = undefined;
    store.initInPlace(a);

    const p = try store.ask("web-1",
        \\[{"id":"q1","question":"Q","options":[{"label":"Yes"}]}]
    );
    const rpc = p.rpc_id;

    // Not pending first.
    const miss = try questions.handleRespond(&store, a, "{\"type\":\"client-response\",\"rpcId\":\"zzz\",\"result\":{\"ok\":true,\"value\":{}}}");
    try testing.expectEqualStrings("{\"accepted\":false,\"reason\":\"not-pending\"}", miss);

    const good = try std.fmt.allocPrint(
        a,
        "{{\"type\":\"client-response\",\"rpcId\":\"{s}\",\"result\":{{\"ok\":true,\"value\":{{\"sessionId\":\"web-1\",\"answer\":{{\"answers\":[{{\"id\":\"q1\",\"selected\":[\"Yes\"]}}]}}}}}}}}",
        .{rpc},
    );
    const ok = try questions.handleRespond(&store, a, good);
    try testing.expectEqualStrings("{\"accepted\":true}", ok);

    // Settled entries are observably gone from the routing table (upstream
    // deletes on claim), so even a malformed late retry reads not-pending.
    const bad = try std.fmt.allocPrint(
        a,
        "{{\"type\":\"client-response\",\"rpcId\":\"{s}\",\"result\":{{\"ok\":false,\"error\":{{\"code\":\"internal\",\"message\":\"x\",\"details\":{{}}}}}}}}",
        .{rpc},
    );
    const nope = try questions.handleRespond(&store, a, bad);
    try testing.expectEqualStrings("{\"accepted\":false,\"reason\":\"not-pending\"}", nope);

    // A still-waiting entry with a non-cancelled error code → bad-response.
    _ = try store.ask("web-1",
        \\[{"id":"q1","question":"Q","options":[{"label":"Yes"}]}]
    );
    const bad2 = try std.fmt.allocPrint(
        a,
        "{{\"type\":\"client-response\",\"rpcId\":\"q-2\",\"result\":{{\"ok\":false,\"error\":{{\"code\":\"internal\",\"message\":\"x\",\"details\":{{}}}}}}}}",
        .{},
    );
    const nope2 = try questions.handleRespond(&store, a, bad2);
    try testing.expectEqualStrings("{\"accepted\":false,\"reason\":\"bad-response\"}", nope2);
}

test "frame payload builders match upstream zod field sets exactly" {
    const alloc = testing.allocator;

    const req = try questions.buildRequestedPayload(
        alloc,
        "web-20260823",
        "[{\"id\":\"q1\",\"question\":\"Go?\",\"header\":\"Plan\",\"detail\":\"the plan md\",\"multiSelect\":false,\"intent\":{\"kind\":\"plan-review\",\"approve\":\"Ship it\"}}]",
    );
    defer alloc.free(req);
    try testing.expectEqualStrings(
        "{\"type\":\"question/requested\",\"sessionId\":\"web-20260823\",\"questions\":" ++
            "[{\"id\":\"q1\",\"question\":\"Go?\",\"header\":\"Plan\",\"detail\":\"the plan md\",\"multiSelect\":false," ++
            "\"intent\":{\"kind\":\"plan-review\",\"approve\":\"Ship it\"}}]}",
        req,
    );

    const res1 = try questions.buildResolvedPayload(alloc, "web-20260823", "q-9", true);
    defer alloc.free(res1);
    try testing.expectEqualStrings("{\"type\":\"question/resolved\",\"sessionId\":\"web-20260823\",\"questionRpcId\":\"q-9\",\"outcome\":\"answered\"}", res1);

    const res2 = try questions.buildResolvedPayload(alloc, "web-x", "q-10", false);
    defer alloc.free(res2);
    try testing.expectEqualStrings("{\"type\":\"question/resolved\",\"sessionId\":\"web-x\",\"questionRpcId\":\"q-10\",\"outcome\":\"cancelled\"}", res2);

    // Full ServerRequest form around a requested payload (what the wire sees).
    const frame = try events_ws.wrapServerRequestWithId(alloc, "q-11", "question/requested", req);
    defer alloc.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "\"type\":\"server-request\",\"rpcId\":\"q-11\",\"method\":\"question/requested\",\"payload\":{\"type\":\"question/requested\"") != null);
}
