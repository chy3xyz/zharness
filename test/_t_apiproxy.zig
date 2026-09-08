//! P-zigapi (wave 5) apiproxy self-test root — cordis-aware like _t_w1.
//!
//! Standalone runner for everything this agent built:
//!   - server/httpd.zig WebSocket layer (unit tests live in the module)
//!   - server/apiproxy/{jsonx,router,events_ws,sessions}
//!
//! Run with:
//!   zig test -lc --dep cordis -Mroot=test/_t_apiproxy.zig -Mcordis=../zcordis/src/cordis.zig
//!
//! The integrator folds these modules into src/tests.zig and deletes the
//! file. `zig build && zig build test` stay untouched by design.

const std = @import("std");
const cordis = @import("cordis");

comptime {
    _ = @import("../src/server/httpd.zig"); // pulls its own WS unit tests
    _ = @import("../src/server/apiproxy/jsonx.zig");
    _ = @import("../src/server/apiproxy/events_ws.zig"); // mapping-table tests inside
}

const httpd = @import("../src/server/httpd.zig");
const jsonx = @import("../src/server/apiproxy/jsonx.zig");
const router = @import("../src/server/apiproxy/router.zig");
const events_ws = @import("../src/server/apiproxy/events_ws.zig");
const sessions_store = @import("../src/server/apiproxy/sessions.zig");

const testing = std.testing;

// ── Appendix A byte-exact envelope fixtures ────────────────────────────────

test "Appendix A: session.list success is byte-exact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const deps_ptr = try alloc.create(router.ApiProxyDeps);
    deps_ptr.* = fixtureDeps();

    const body =
        "{\"type\":\"client-request\",\"rpcId\":\"5f0c\",\"method\":\"session.list\",\"payload\":{}}";
    const env = (try router.parseEnvelope(alloc, body)) orelse return error.TestUnexpectedResult;
    const resp = try router.dispatch(deps_ptr, alloc, &env);

    try testing.expectEqual(httpd.Status.ok, resp.status);
    try testing.expectEqualStrings(
        "{\"type\":\"server-response\",\"rpcId\":\"5f0c\",\"result\":{\"ok\":true,\"value\":{\"items\":" ++
            "[{\"sessionId\":\"web-20260823-101500\",\"updatedAt\":1755946500000,\"running\":false," ++
            "\"blank\":true,\"cwd\":\"/Users/n0x/w4_proj/dev_machine/zharness\"," ++
            "\"projections\":{\"asOfSeq\":-1,\"values\":{}}}]}}}",
        resp.body,
    );
}

test "Appendix A: session.prompt acceptance is byte-exact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const deps_ptr = try alloc.create(router.ApiProxyDeps);
    deps_ptr.* = fixtureDeps();

    const body = "{\"type\":\"client-request\",\"rpcId\":\"c3d4\",\"method\":\"session.prompt\"," ++
        "\"payload\":{\"sessionId\":\"web-20260823-101500\",\"mode\":\"queue\"," ++
        "\"content\":[{\"type\":\"text\",\"text\":\"fix the failing test\"}]," ++
        "\"clientTimeZone\":\"Asia/Shanghai\"}}";
    const env = (try router.parseEnvelope(alloc, body)) orelse return error.TestUnexpectedResult;
    const resp = try router.dispatch(deps_ptr, alloc, &env);

    try testing.expectEqualStrings(
        "{\"type\":\"server-response\",\"rpcId\":\"c3d4\",\"result\":{\"ok\":true,\"value\":{\"accepted\":true}}}",
        resp.body,
    );
    // The backend saw the validated payload verbatim.
    try testing.expectEqualStrings("web-20260823-101500", g_last_prompt.session_id);
    try testing.expectEqual(router.PromptMode.queue, g_last_prompt.mode);
    try testing.expectEqualStrings(
        "[{\"type\":\"text\",\"text\":\"fix the failing test\"}]",
        g_last_prompt.content_json,
    );
}

test "Appendix A: mux frame wrapper is byte-exact" {
    const alloc = testing.allocator;
    const frame = try events_ws.wrapServerRequestWithId(
        alloc,
        "a1b2",
        "session/event",
        "{\"type\":\"session/event\",\"sessionId\":\"web-20260823-101500\"," ++
            "\"event\":{\"type\":\"assistant/chunk\",\"seq\":41,\"time\":1755946501123," ++
            "\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"Hello\"}}}}",
    );
    defer alloc.free(frame);
    try testing.expectEqualStrings(
        "{\"type\":\"server-request\",\"rpcId\":\"a1b2\",\"method\":\"session/event\"," ++
            "\"payload\":{\"type\":\"session/event\",\"sessionId\":\"web-20260823-101500\"," ++
            "\"event\":{\"type\":\"assistant/chunk\",\"seq\":41,\"time\":1755946501123," ++
            "\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"Hello\"}}}}}",
        frame,
    );
}

// ── method coverage: happy + error paths over fake deps ────────────────────

fn expectOkValue(
    parent_alloc: std.mem.Allocator,
    deps_ptr: *const router.ApiProxyDeps,
    method: []const u8,
    payload: []const u8,
    want_value: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const env = router.Envelope{ .rpc_id = "t", .method = method, .payload_raw = payload };
    const resp = try router.dispatch(deps_ptr, alloc, &env);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(alloc);
    try want.appendSlice(alloc, "{\"type\":\"server-response\",\"rpcId\":\"t\",\"result\":{\"ok\":true,\"value\":");
    try want.appendSlice(alloc, want_value);
    try want.appendSlice(alloc, "}}");
    try testing.expectEqualStrings(want.items, resp.body);
}

fn expectErrBody(
    parent_alloc: std.mem.Allocator,
    deps_ptr: *const router.ApiProxyDeps,
    method: []const u8,
    payload: []const u8,
    want_error: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const env = router.Envelope{ .rpc_id = "t", .method = method, .payload_raw = payload };
    const resp = try router.dispatch(deps_ptr, alloc, &env);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(alloc);
    try want.appendSlice(alloc, "{\"type\":\"server-response\",\"rpcId\":\"t\",\"result\":{\"ok\":false,\"error\":");
    try want.appendSlice(alloc, want_error);
    try want.appendSlice(alloc, "}}");
    try testing.expectEqualStrings(want.items, resp.body);
}

test "method coverage: registry methods answer per contract" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const deps_ptr = try alloc.create(router.ApiProxyDeps);
    deps_ptr.* = fixtureDeps();

    // host.describe built-in default from static facts + listSessions.
    try expectOkValue(alloc, deps_ptr, "host.describe", "{}", "{\"version\":\"zharness-test\",\"cwd\":\"/w\",\"attachedSessions\":1,\"home\":\"/home/u\",\"canOpenPath\":false}");

    // session.history happy path (fake returns one entry passthrough).
    try expectOkValue(alloc, deps_ptr, "session.history", "{\"sessionId\":\"s1\",\"maxMessages\":50}", "{\"events\":[{\"event\":{\"type\":\"user/message\",\"seq\":0,\"time\":1,\"data\":{}}}],\"hasMore\":false}");

    // session.create / rename / cancel.
    try expectOkValue(alloc, deps_ptr, "session.create", "{\"cwd\":\"/w\"}", "{\"sessionId\":\"fresh-1\"}");
    try expectOkValue(alloc, deps_ptr, "session.rename", "{\"sessionId\":\"s1\",\"title\":\"New name\"}", "{\"title\":\"New name\",\"seq\":7}");
    try expectOkValue(alloc, deps_ptr, "session.cancel", "{\"sessionId\":\"s1\"}", "{\"accepted\":true}");

    // workspace small acks (deterministic defaults).
    try expectOkValue(alloc, deps_ptr, "workspace.delete", "{\"workspaceId\":\"default\"}", "{\"deleted\":true}");
    try expectOkValue(alloc, deps_ptr, "workspace.insertBefore", "{\"workspaceId\":\"default\"}", "{\"workspaceIds\":[\"default\"]}");
    try expectOkValue(alloc, deps_ptr, "workspace.archiveSession", "{\"sessionId\":\"s1\"}", "{\"archivedSessionIds\":[]}");

    // settings.describe read stub.
    try expectOkValue(alloc, deps_ptr, "settings.describe", "{}", "{\"writable\":false,\"hasDocument\":false,\"namespaces\":[]}");
}

test "method coverage: workspace.list synthesizes the single root workspace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const deps_ptr = try alloc.create(router.ApiProxyDeps);
    deps_ptr.* = fixtureDeps();

    const env = router.Envelope{ .rpc_id = "t", .method = "workspace.list", .payload_raw = "{}" };
    const resp = try router.dispatch(deps_ptr, alloc, &env);

    // Stable prefix + ISO timestamps + stable suffix (wall-clock excluded).
    try testing.expect(std.mem.startsWith(u8, resp.body, "{\"type\":\"server-response\",\"rpcId\":\"t\",\"result\":{\"ok\":true,\"value\":{\"items\":["));
    try testing.expect(std.mem.indexOf(u8, resp.body, "{\"workspaceId\":\"default\",\"path\":\"/w\",\"title\":\"w\",\"sessionIds\":[\"web-20260823-101500\"]") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, ",\"createdAt\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "Z\",\"updatedAt\":\"") != null);
    try testing.expect(std.mem.endsWith(u8, resp.body, "],\"archivedSessionIds\":[]}}}"));
}

test "method coverage: workspace create/rename render the view wrapper" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const deps_ptr = try alloc.create(router.ApiProxyDeps);
    deps_ptr.* = fixtureDeps();

    // create on the root path → created:false + full WorkspaceView.
    const env_create = router.Envelope{ .rpc_id = "t", .method = "workspace.create", .payload_raw = "{\"path\":\"/w\"}" };
    const r1 = try router.dispatch(deps_ptr, alloc, &env_create);
    try testing.expect(std.mem.startsWith(u8, r1.body, "{\"type\":\"server-response\",\"rpcId\":\"t\",\"result\":{\"ok\":true,\"value\":{\"workspace\":{\"workspaceId\":\"default\",\"path\":\"/w\""));
    try testing.expect(std.mem.endsWith(u8, r1.body, ",\"created\":false}}}"));

    // rename → new title inside the view.
    const env_rename = router.Envelope{ .rpc_id = "t", .method = "workspace.rename", .payload_raw = "{\"workspaceId\":\"default\",\"title\":\"proj\"}" };
    const r2 = try router.dispatch(deps_ptr, alloc, &env_rename);
    try testing.expect(std.mem.indexOf(u8, r2.body, "{\"workspace\":{\"workspaceId\":\"default\",\"path\":\"/w\",\"title\":\"proj\"") != null);

    // insertSessionBefore → workspace view wrapper.
    const env_isb = router.Envelope{ .rpc_id = "t", .method = "workspace.insertSessionBefore", .payload_raw = "{\"workspaceId\":\"default\",\"sessionId\":\"s1\"}" };
    const r3 = try router.dispatch(deps_ptr, alloc, &env_isb);
    try testing.expect(std.mem.startsWith(u8, r3.body, "{\"type\":\"server-response\",\"rpcId\":\"t\",\"result\":{\"ok\":true,\"value\":{\"workspace\":{\"workspaceId\":\"default\""));
}

test "method coverage: error paths map onto the closed code union" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const deps_ptr = try alloc.create(router.ApiProxyDeps);
    deps_ptr.* = fixtureDeps();

    // Unknown session → session-not-found with details from the payload.
    try expectErrBody(alloc, deps_ptr, "session.history", "{\"sessionId\":\"nope\"}", "{\"code\":\"session-not-found\",\"message\":\"session not found\",\"details\":{\"sessionId\":\"nope\"}}");
    // Steer mode → steer-unavailable v1.
    try expectErrBody(alloc, deps_ptr, "session.prompt", "{\"sessionId\":\"s1\",\"mode\":\"steer\",\"content\":[{\"type\":\"text\",\"text\":\"x\"}]}", "{\"code\":\"steer-unavailable\",\"message\":\"steering is unavailable\",\"details\":{\"itemId\":\"s1\"}}");
    // Invalid mode → bad-request with the upstream message format.
    try expectErrBody(alloc, deps_ptr, "session.prompt", "{\"sessionId\":\"s1\",\"mode\":\"bogus\",\"content\":[{\"type\":\"text\",\"text\":\"x\"}]}", "{\"code\":\"bad-request\",\"message\":\"invalid payload for session.prompt\",\"details\":{\"issues\":[]}}");
    // Image part → documented text-only bad-request.
    try expectErrBody(alloc, deps_ptr, "session.prompt", "{\"sessionId\":\"s1\",\"mode\":\"queue\",\"content\":[{\"type\":\"image\",\"mediaType\":\"image/png\",\"data\":\"AA==\"}]}", "{\"code\":\"bad-request\",\"message\":\"invalid content parts for session.prompt (text-only)\",\"details\":{\"issues\":[]}}");
    // createSession with both workspaceId and cwd → refine violation.
    try expectErrBody(alloc, deps_ptr, "session.create", "{\"workspaceId\":\"w\",\"cwd\":\"/x\"}", "{\"code\":\"bad-request\",\"message\":\"session.create accepts workspaceId or cwd, not both\",\"details\":{\"issues\":[]}}");
    // workspace.create on a foreign path → workspace-invalid-path.
    try expectErrBody(alloc, deps_ptr, "workspace.create", "{\"path\":\"/elsewhere\"}", "{\"code\":\"workspace-invalid-path\",\"message\":\"only the server cwd can be adopted in v1\",\"details\":{\"path\":\"/elsewhere\"}}");
    // Unknown workspace → workspace-not-found.
    try expectErrBody(alloc, deps_ptr, "workspace.delete", "{\"workspaceId\":\"other\"}", "{\"code\":\"workspace-not-found\",\"message\":\"workspace not found\",\"details\":{\"workspaceId\":\"other\"}}");
    // Unknown METHOD → their error shape (documented deviation from bare 404).
    try expectErrBody(alloc, deps_ptr, "subagent.list", "{}", "{\"code\":\"bad-request\",\"message\":\"unknown method\",\"details\":{\"issues\":[]}}");
    // Backend crash-class error → internal.
    try expectErrBody(alloc, deps_ptr, "session.cancel", "{\"sessionId\":\"boom\"}", "{\"code\":\"internal\",\"message\":\"backend failure: BackendBoom\",\"details\":{}}");
}

// ── carrier glue: statuses match upstream ──────────────────────────────────

extern "c" fn socketpair(domain: c_int, ty: c_int, protocol: c_int, fds: *[2]c_int) c_int;

/// Unix-socketpair-backed Responder double: handleApiRequest writes the HTTP
/// response through send() on one end; the test reads the other. (Pipes do
/// not support send(2), which Responder uses.)
const PipeRes = struct {
    read_fd: c_int,
    write_fd: c_int,

    fn init() !PipeRes {
        var fds: [2]c_int = undefined;
        // AF_UNIX = 1, SOCK_STREAM = 1 on macOS/Linux.
        if (socketpair(1, 1, 0, &fds) != 0) return error.PipeFailed;
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    fn deinit(self: *PipeRes) void {
        _ = std.c.close(self.read_fd);
        _ = std.c.close(self.write_fd);
    }

    fn responder(self: *PipeRes) httpd.Responder {
        return .{ .fd = self.write_fd, .alloc = std.heap.page_allocator };
    }

    /// Read the full response (headers + Content-Length body). Caller frees.
    fn readResponse(self: *PipeRes, alloc: std.mem.Allocator) !struct { head: []u8, body: []u8 } {
        var raw: std.ArrayList(u8) = .empty;
        errdefer raw.deinit(alloc);
        var chunk: [512]u8 = undefined;
        while (std.mem.indexOf(u8, raw.items, "\r\n\r\n") == null) {
            const n = try clientRecv(self.read_fd, &chunk);
            try raw.appendSlice(alloc, chunk[0..n]);
        }
        const sep = std.mem.indexOf(u8, raw.items, "\r\n\r\n").?;
        const head = try alloc.dupe(u8, raw.items[0..sep]);
        errdefer alloc.free(head);
        var body_len: usize = 0;
        var lines = std.mem.splitSequence(u8, raw.items[0..sep], "\r\n");
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                body_len = try std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " "), 10);
            }
        }
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(alloc);
        try body.appendSlice(alloc, raw.items[sep + 4 ..]);
        while (body.items.len < body_len) {
            const n = try clientRecv(self.read_fd, &chunk);
            try body.appendSlice(alloc, chunk[0..n]);
        }
        return .{ .head = head, .body = try body.toOwnedSlice(alloc) };
    }
};

fn statusOf(head: []const u8) u16 {
    // "HTTP/1.1 200 OK"
    const sp1 = std.mem.indexOfScalar(u8, head, ' ').? + 1;
    const sp2 = std.mem.indexOfScalarPos(u8, head, sp1, ' ').?;
    return std.fmt.parseInt(u16, head[sp1..sp2], 10) catch 0;
}

fn runCarrier(
    alloc: std.mem.Allocator,
    deps_ptr: *const router.ApiProxyDeps,
    method: []const u8,
    path: []const u8,
    content_type: ?[]const u8,
    body: []const u8,
) !struct { status: u16, body: []u8 } {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var req_raw: std.ArrayList(u8) = .empty;
    try req_raw.print(aa, "{s} {s} HTTP/1.1\r\nHost: x\r\n", .{ method, path });
    if (content_type) |ct| try req_raw.print(aa, "Content-Type: {s}\r\n", .{ct});
    try req_raw.print(aa, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });

    var req = try httpd.parseRequest(aa, req_raw.items);

    var pres = try PipeRes.init();
    defer pres.deinit();
    var res = pres.responder();
    try router.handleApiRequest(deps_ptr, aa, &req, &res);

    const got = try pres.readResponse(alloc);
    defer alloc.free(got.head);
    return .{ .status = statusOf(got.head), .body = got.body };
}

test "carrier glue: statuses match upstream for non-envelope failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const deps_ptr = try alloc.create(router.ApiProxyDeps);
    deps_ptr.* = fixtureDeps();

    // Non-/api/ path → carrier-level 404 text.
    {
        const r = try runCarrier(alloc, deps_ptr, "GET", "/healthz", null, "");
        defer alloc.free(r.body);
        try testing.expectEqual(@as(u16, 404), r.status);
        try testing.expectEqualStrings("not found", r.body);
    }
    // Wrong content type → 415 (cross-site write fence).
    {
        const r = try runCarrier(alloc, deps_ptr, "POST", "/api/session.list", "text/plain", "{}");
        defer alloc.free(r.body);
        try testing.expectEqual(@as(u16, 415), r.status);
        try testing.expectEqualStrings("content type must be application/json", r.body);
    }
    // Non-JSON body → 400 plain text.
    {
        const r = try runCarrier(alloc, deps_ptr, "POST", "/api/session.list", "application/json", "not json");
        defer alloc.free(r.body);
        try testing.expectEqual(@as(u16, 400), r.status);
        try testing.expectEqualStrings("body is not JSON", r.body);
    }
    // Bad envelope shape → 200 with sentinel-rpcId bad-request.
    {
        const r = try runCarrier(alloc, deps_ptr, "POST", "/api/session.list", "application/json", "{\"nope\":1}");
        defer alloc.free(r.body);
        try testing.expectEqual(@as(u16, 200), r.status);
        try testing.expectEqualStrings(
            "{\"type\":\"server-response\",\"rpcId\":\"invalid-request\",\"result\":{\"ok\":false,\"error\":{\"code\":\"bad-request\",\"message\":\"invalid client-request message\",\"details\":{\"issues\":[]}}}}",
            r.body,
        );
    }
    // method/path mismatch → 200 bad-request.
    {
        const r = try runCarrier(alloc, deps_ptr, "POST", "/api/session.list", "application/json", "{\"type\":\"client-request\",\"rpcId\":\"r9\",\"method\":\"session.cancel\",\"payload\":{}}");
        defer alloc.free(r.body);
        try testing.expectEqual(@as(u16, 200), r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, "does not match path") != null);
    }
    // /api/respond → not-pending receipt stub.
    {
        const r = try runCarrier(alloc, deps_ptr, "POST", "/api/respond", "application/json", "{\"type\":\"client-response\",\"rpcId\":\"q1\",\"result\":{\"ok\":true,\"value\":{}}}");
        defer alloc.free(r.body);
        try testing.expectEqual(@as(u16, 200), r.status);
        try testing.expectEqualStrings("{\"accepted\":false,\"reason\":\"not-pending\"}", r.body);
    }
    // Full unary round-trip through the real handler surface.
    {
        const r = try runCarrier(alloc, deps_ptr, "POST", "/api/host.describe", "application/json", "{\"type\":\"client-request\",\"rpcId\":\"rt\",\"method\":\"host.describe\",\"payload\":{}}");
        defer alloc.free(r.body);
        try testing.expectEqual(@as(u16, 200), r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, "\"rpcId\":\"rt\",\"result\":{\"ok\":true,\"value\":{\"version\":\"zharness-test\"") != null);
    }
}

// ── sessions store adapter over real files ─────────────────────────────────

test "sessions adapter: transcript parse, summary, history page, listing" {
    const alloc = testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    const dir_path = ".zharness_apiproxy_test/sessions";
    const root = std.Io.Dir.cwd();
    defer std.Io.Dir.deleteTree(root, io, ".zharness_apiproxy_test") catch {};
    try std.Io.Dir.createDirPath(root, io, dir_path);

    // Two transcripts in the zharness Session.save format. The middle
    // assistant row carries tool_calls_json stored as an escaped JSON string
    // whose own `arguments` is also an escaped JSON string (double nesting).
    const t1 =
        "[{\"role\":\"user\",\"content\":\"fix the failing test\",\"tool_call_id\":null,\"tool_calls_json\":null}," ++
        "{\"role\":\"assistant\",\"content\":\"On it.\",\"tool_call_id\":null," ++
        "\"tool_calls_json\":\"{\\\"id\\\":\\\"c1\\\",\\\"name\\\":\\\"shell\\\",\\\"arguments\\\":\\\"{\\\\\\\"cmd\\\\\\\":\\\\\\\"zig test\\\\\\\"}\\\"}\"}," ++
        "{\"role\":\"tool\",\"content\":\"all green\",\"tool_call_id\":\"c1\",\"tool_calls_json\":null}]";
    try writeFileHelper(io, dir_path ++ "/web-a.json", t1);
    try writeFileHelper(io, dir_path ++ "/web-b.json", "[]");
    // Non-json noise must be ignored by listing.
    try writeFileHelper(io, dir_path ++ "/notes.txt", "hello");

    // Listing: sorted stems only.
    const ids = try sessions_store.listSessionIds(io, alloc, dir_path);
    defer {
        for (ids) |id| alloc.free(id);
        alloc.free(ids);
    }
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("web-a", ids[0]);
    try testing.expectEqualStrings("web-b", ids[1]);

    // transcriptPath formatting sanity.
    const p = try sessions_store.transcriptPath(alloc, "/repo", "web-a");
    defer alloc.free(p);
    try testing.expectEqualStrings("/repo/.zharness/sessions/web-a.json", p);

    // Transcript parse round-trip.
    const msgs = try sessions_store.loadTranscript(io, alloc, dir_path ++ "/web-a.json");
    defer {
        for (msgs) |m| {
            alloc.free(m.role);
            alloc.free(m.content);
            if (m.tool_call_id) |v| alloc.free(v);
            if (m.tool_calls_json) |v| alloc.free(v);
        }
        alloc.free(msgs);
    }
    try testing.expectEqual(@as(usize, 3), msgs.len);
    try testing.expectEqualStrings("fix the failing test", msgs[0].content);
    try testing.expect(msgs[1].tool_calls_json != null);
    try testing.expectEqualStrings(
        "{\"id\":\"c1\",\"name\":\"shell\",\"arguments\":\"{\\\"cmd\\\":\\\"zig test\\\"}\"}",
        msgs[1].tool_calls_json.?,
    );
    try testing.expectEqualStrings("c1", msgs[2].tool_call_id.?);

    // Missing file → empty session.
    const missing = try sessions_store.loadTranscript(io, alloc, dir_path ++ "/absent.json");
    defer alloc.free(missing);
    try testing.expectEqual(@as(usize, 0), missing.len);

    // Summary row shape (byte-exact).
    const sum = try sessions_store.buildSummaryJson(alloc, .{
        .session_id = "web-a",
        .updated_at_ms = 1755946500000,
        .message_count = msgs.len,
        .cwd = "/repo",
    });
    defer alloc.free(sum);
    try testing.expectEqualStrings(
        "{\"sessionId\":\"web-a\",\"updatedAt\":1755946500000,\"running\":false,\"blank\":false," ++
            "\"cwd\":\"/repo\",\"projections\":{\"asOfSeq\":-1,\"values\":{}}}",
        sum,
    );

    // History page: tool/call precedes assistant/message; tool/result wraps a
    // ToolResultMessage; arguments decode back to a JSON object.
    const page_all = try sessions_store.buildHistoryPage(alloc, msgs, 1755946500000, null, "sessions");
    defer freePage(alloc, page_all);
    try testing.expect(!page_all.has_more);
    try testing.expectEqual(@as(usize, 4), page_all.entries.len); // user, call, assistant, result
    try testing.expect(std.mem.startsWith(u8, page_all.entries[0].event_json, "{\"type\":\"user/message\",\"seq\":0,\"time\":1755946500000,\"data\":{\"id\":\"u0\""));
    try testing.expect(std.mem.indexOf(u8, page_all.entries[1].event_json, "\"type\":\"tool/call\"") != null);
    try testing.expect(std.mem.indexOf(u8, page_all.entries[1].event_json, "\"callId\":\"c1\",\"name\":\"shell\",\"arguments\":{\"cmd\":\"zig test\"}}") != null);
    try testing.expect(std.mem.startsWith(u8, page_all.entries[2].event_json, "{\"type\":\"assistant/message\",\"seq\":1"));
    try testing.expect(std.mem.indexOf(u8, page_all.entries[3].event_json, "\"source\":{\"kind\":\"tool\",\"callId\":\"c1\"}}}") != null);
    try testing.expect(std.mem.indexOf(u8, page_all.projections_json.?, "{\"asOfSeq\":2,\"values\":{\"title\":\"sessions\"}}") != null);

    // Tail page of 2 raw messages keeps FULL-transcript seqs + has_more.
    const page_tail = try sessions_store.buildHistoryPage(alloc, msgs, 1755946500000, 2, "sessions");
    defer freePage(alloc, page_tail);
    try testing.expect(page_tail.has_more);
    try testing.expect(std.mem.indexOf(u8, page_tail.entries[0].event_json, "\"seq\":1") != null);
}

fn freePage(alloc: std.mem.Allocator, page: router.HistoryPage) void {
    for (page.entries) |e| {
        alloc.free(e.event_json);
        if (e.view_json) |v| alloc.free(v);
    }
    alloc.free(page.entries);
    if (page.projections_json) |p| alloc.free(p);
}

fn writeFileHelper(io: std.Io, sub_path: []const u8, data: []const u8) !void {
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = sub_path, .data = data });
}

// ── WebSocket integration over real loopback ───────────────────────────────

extern "c" fn socket(domain: c_int, ty: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const std.c.sockaddr, len: std.c.socklen_t) c_int;
extern "c" fn recv(fd: c_int, buf: [*]u8, n: usize, flags: c_int) isize;
extern "c" fn send(fd: c_int, buf: [*]const u8, n: usize, flags: c_int) isize;
extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: std.c.socklen_t) c_int;

fn clientRecv(fd: c_int, buf: []u8) !usize {
    while (true) {
        const n = recv(fd, buf.ptr, buf.len, 0);
        if (n > 0) return @intCast(n);
        if (n == 0) return error.EndOfStream;
        const err = std.c.errno(n);
        if (err == .INTR) continue;
        return error.ReadFailed;
    }
}

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

fn testSleepMs(ms: u64) void {
    const req: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = nanosleep(&req, null);
}

fn clientSendAll(fd: c_int, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = send(fd, data.ptr + off, data.len - off, 0);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// Read the 101 handshake head from a client socket.
fn readHandshakeHead(fd: c_int, buf: []u8) ![]u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try clientRecv(fd, buf[total..]);
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |pos| return buf[0 .. pos + 4];
    }
    return error.ProtocolError;
}

/// Read ONE unmasked server frame; returns opcode and heap payload.
fn readServerFrame(fd: c_int, alloc: std.mem.Allocator) !struct { opcode: u8, payload: []u8 } {
    var hdr: [10]u8 = undefined;
    var got: usize = 0;
    while (got < 2) got += try clientRecv(fd, hdr[got..2]);
    const opcode = hdr[0] & 0x0F;
    if (hdr[1] & 0x80 != 0) return error.ProtocolError; // server never masks
    var len: u64 = hdr[1] & 0x7F;
    var hdr_len: usize = 2;
    if (len == 126) {
        while (got < 4) got += try clientRecv(fd, hdr[got..4]);
        len = std.mem.readInt(u16, hdr[2..4], .big);
        hdr_len = 4;
    } else if (len == 127) {
        while (got < 10) got += try clientRecv(fd, hdr[got..10]);
        len = std.mem.readInt(u64, hdr[2..10], .big);
    }

    const payload = try alloc.alloc(u8, @intCast(len));
    errdefer alloc.free(payload);
    var off: usize = 0;
    while (off < payload.len) {
        off += try clientRecv(fd, payload[off..]);
    }
    return .{ .opcode = opcode, .payload = payload };
}

fn connectTcp(port: u16) !c_int {
    const fd = socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    // Bounded reads so a misbehaving server fails tests instead of hanging.
    const tv: std.c.timeval = .{ .sec = 10, .usec = 0 };
    _ = setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &tv, @sizeOf(std.c.timeval));

    var addr = std.c.sockaddr.in{
        .family = std.c.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };
    if (connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) {
        _ = std.c.close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

const UpgradeBytes = struct { bytes: [512]u8, len: usize };

fn wsUpgradeBytes(port: u16, path: []const u8, key: []const u8) UpgradeBytes {
    var out: UpgradeBytes = .{ .bytes = undefined, .len = 0 };
    const s = std.fmt.bufPrint(&out.bytes, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nUpgrade: websocket\r\n" ++
        "Connection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{
        path,
        port,
        key,
    }) catch unreachable;
    out.len = s.len;
    return out;
}

fn startTestServer() !struct { srv: *httpd.Server, port: u16 } {
    const alloc = std.heap.page_allocator;
    const deps_ptr = try alloc.create(router.ApiProxyDeps);
    deps_ptr.* = fixtureDeps();
    const srv = try alloc.create(httpd.Server);
    srv.* = try httpd.Server.init(
        alloc,
        router.handler(deps_ptr),
        .{ .port = 0, .threaded_connections = true },
    );
    try srv.spawn();
    return .{ .srv = srv, .port = srv.boundPort() };
}

fn stopTestServer(st: anytype) void {
    st.srv.stop();
    st.srv.join();
    st.srv.deinit();
    std.heap.page_allocator.destroy(st.srv);
}

test "websocket: mux fan-out delivers ServerRequest frames to subscribers" {
    // The shared hubs may already exist (the earlier stream test created them
    // via its pump); reuse them. They are page_allocator-owned and released
    // at process exit — detached pump threads may hold subscribers at this
    // test's end, so destroying them here would race.
    const st = try startTestServer();
    defer stopTestServer(st);

    const fd = try connectTcp(st.port);
    defer _ = std.c.close(fd);
    const upg = wsUpgradeBytes(st.port, "/api/events.mux", "YWJjZGVmZ2hpamtsbW5vcA==");
    try clientSendAll(fd, upg.bytes[0..upg.len]);
    var head_buf: [1024]u8 = undefined;
    _ = try readHandshakeHead(fd, &head_buf);

    // Wait until the pump thread registered its subscription (poll, bounded).
    const hubs = try events_ws.sharedHubs();
    var subscribed = false;
    var attempt: usize = 0;
    while (attempt < 500) : (attempt += 1) {
        if (hubs.mux.subscriberCount() == 1) {
            subscribed = true;
            break;
        }
        testSleepMs(2);
    }
    try testing.expect(subscribed);

    // One publish → exactly one ServerRequest text frame on the socket.
    hubs.mux.publish("session/event",
        \\{"type":"session/event","sessionId":"s","event":{"type":"turn/start","seq":1,"time":1,"data":{"turn":1}}}
    );
    const fr = try readServerFrame(fd, testing.allocator);
    defer testing.allocator.free(fr.payload);
    try testing.expectEqual(@as(u8, 0x1), fr.opcode); // text
    try testing.expect(std.mem.startsWith(u8, fr.payload, "{\"type\":\"server-request\",\"rpcId\":\"push-"));
    // method mirrors payload.type; payload rides verbatim.
    try testing.expect(std.mem.indexOf(u8, fr.payload, "method\":\"session/event\",\"payload\":{\"type\":\"session/event\"") != null);
    try testing.expect(std.mem.indexOf(u8, fr.payload, "\"event\":{\"type\":\"turn/start\",\"seq\":1") != null);

    // Clean close handshake initiated by the client (code 1000).
    const close_frame = try httpd.encodeWsFrame(testing.allocator, .close, true, &[_]u8{ 0x03, 0xE8 }, .{ 9, 9, 9, 9 });
    defer testing.allocator.free(close_frame);
    try clientSendAll(fd, close_frame);
    var echoed = false;
    while (true) {
        const f2 = try readServerFrame(fd, testing.allocator);
        defer testing.allocator.free(f2.payload);
        if (f2.opcode == 0x8) {
            echoed = true;
            break;
        }
    }
    try testing.expect(echoed);
}

test "websocket: handshake accept key, protocol-violation close 1008, clean close" {
    if (events_ws.takeSharedHubs()) |old| old.destroy();
    const st = try startTestServer();
    defer stopTestServer(st);

    const fd = try connectTcp(st.port);
    defer _ = std.c.close(fd);

    const upg = wsUpgradeBytes(st.port, "/api/events.mux", "dGhlIHNhbXBsZSBub25jZQ==");
    try clientSendAll(fd, upg.bytes[0..upg.len]);

    var head_buf: [1024]u8 = undefined;
    const head = try readHandshakeHead(fd, &head_buf);
    try testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 101 Switching Protocols\r\n"));
    try testing.expect(std.mem.indexOf(u8, head, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != null);

    // A client TEXT frame violates the downstream-only contract → close 1008.
    const viol = try httpd.encodeWsFrame(testing.allocator, .text, true, "hi", .{ 1, 2, 3, 4 });
    defer testing.allocator.free(viol);
    try clientSendAll(fd, viol);

    var got_close = false;
    while (true) {
        const fr = try readServerFrame(fd, testing.allocator);
        defer testing.allocator.free(fr.payload);
        if (fr.opcode == 0x8) {
            got_close = true;
            if (fr.payload.len >= 2) {
                const code = std.mem.readInt(u16, fr.payload[0..2], .big);
                try testing.expectEqual(@as(u16, 1008), code);
            }
            break;
        }
    }
    try testing.expect(got_close);
}

// ── fixtures ───────────────────────────────────────────────────────────────

const RecordedPrompt = struct {
    session_id: []const u8 = "",
    mode: router.PromptMode = .queue,
    content_json: []const u8 = "",
};
var g_last_prompt: RecordedPrompt = .{};

fn fakeListSessions(ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]router.SessionSummary {
    _ = ctx;
    const out = try alloc.alloc(router.SessionSummary, 1);
    out[0] = .{
        .session_id = "web-20260823-101500",
        .updated_at_ms = 1755946500000,
        .running = false,
        .blank = true,
        .cwd = "/Users/n0x/w4_proj/dev_machine/zharness",
        .projections_json = "{\"asOfSeq\":-1,\"values\":{}}",
    };
    return out;
}

fn fakeSessionHistory(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    before_seq: ?i64,
    max_messages: ?u32,
) anyerror!router.HistoryPage {
    _ = ctx;
    _ = before_seq;
    _ = max_messages;
    if (std.mem.eql(u8, session_id, "s1")) {
        const entries = try alloc.alloc(router.HistoryEntry, 1);
        entries[0] = .{ .event_json = "{\"type\":\"user/message\",\"seq\":0,\"time\":1,\"data\":{}}" };
        return .{ .entries = entries, .has_more = false };
    }
    return error.SessionNotFound;
}

fn fakeCreateSession(ctx: ?*anyopaque, alloc: std.mem.Allocator, opts: router.CreateOptions) anyerror![]const u8 {
    _ = ctx;
    _ = opts;
    return alloc.dupe(u8, "fresh-1");
}

fn fakePromptSession(ctx: ?*anyopaque, alloc: std.mem.Allocator, req: router.PromptRequest) anyerror!router.PromptAck {
    _ = ctx;
    _ = alloc;
    g_last_prompt = .{
        .session_id = req.session_id,
        .mode = req.mode,
        .content_json = req.content_json,
    };
    if (req.mode == .steer) return error.SteerUnavailable;
    return .{};
}

fn fakeCancel(ctx: ?*anyopaque, alloc: std.mem.Allocator, session_id: []const u8) anyerror!void {
    _ = ctx;
    _ = alloc;
    if (std.mem.eql(u8, session_id, "ghost")) return error.SessionNotFound;
    if (std.mem.eql(u8, session_id, "boom")) return error.BackendBoom;
}

fn fakeRename(ctx: ?*anyopaque, alloc: std.mem.Allocator, session_id: []const u8, title: []const u8) anyerror!router.RenameResult {
    _ = ctx;
    _ = alloc;
    _ = session_id;
    if (title.len == 0 or std.mem.trim(u8, title, " ").len == 0) return error.TitleInvalid;
    return .{ .title = title, .seq = 7 };
}

fn fixtureDeps() router.ApiProxyDeps {
    return .{
        .version = "zharness-test",
        .cwd = "/w",
        .home = "/home/u",
        .listSessions = fakeListSessions,
        .sessionHistory = fakeSessionHistory,
        .createSession = fakeCreateSession,
        .promptSession = fakePromptSession,
        .cancelSession = fakeCancel,
        .renameSession = fakeRename,
    };
}

// ── sanity ─────────────────────────────────────────────────────────────────

test "sanity: jsonx getters used by dispatch decode browser payloads" {
    const alloc = testing.allocator;
    const doc = "{\"beforeSeq\":12,\"maxMessages\":50}";
    try testing.expectEqual(@as(?i64, 12), jsonx.getInt(doc, "beforeSeq"));
    const s = (try jsonx.getStringAlloc(alloc, "{\"k\":\"v\\n\"}", "k")).?;
    defer alloc.free(s);
    try testing.expectEqualStrings("v\n", s);
}
