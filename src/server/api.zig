//! JSON API routes on top of the minimal HTTP server (dev.md §XXIII).
//!
//! Contract:
//! - api.zig owns routing + JSON shaping ONLY. It never touches sockets or
//!   the agent runtime: every capability arrives through `ServerDeps`, a plain
//!   struct of function pointers (+ an opaque ctx), so this module stays
//!   decoupled from main.zig/cordis and is testable with fake deps.
//! - The integrator wires it as the httpd handler:
//!       const deps = try alloc.create(api.ServerDeps);
//!       deps.* = .{ .ctx = ..., .runTask = ..., ... };
//!       var srv = try httpd.Server.init(alloc, .{ .ctx = deps, .call = api.handle }, .{ .port = p });
//! - `route` is pure (no socket I/O) and returns a `RouteResult` so dispatch
//!   can be unit-tested offline; `handle` adapts it to the live connection,
//!   including the `/events` SSE stub (heartbeat comments until disconnect).
//!
//! Route table:
//!   POST /run            {prompt, session?} -> deps.runTask
//!   POST /chat           {prompt, session?} -> deps.runTask (conversational alias)
//!   GET  /sessions                          -> deps.listSessions
//!   GET  /sessions/:id                         -> deps.getSession
//!   GET  /healthz                                -> {"ok":true}
//!   GET  /events                                 -> SSE stub (heartbeats)

const std = @import("std");
const httpd = @import("httpd.zig");

// ── dependency surface ──────────────────────────────────────────────────────

pub const ServerDeps = struct {
    // ── types ───────────────────────────────────────────────────────────

    pub const SessionSummary = struct {
        id: []const u8,
        created_at: i64,
        message_count: usize,
    };

    pub const MessageEntry = struct {
        role: []const u8,
        content: []const u8,
    };

    pub const SessionDetail = struct {
        id: []const u8,
        created_at: i64,
        messages: []MessageEntry,

        pub fn deinit(self: *SessionDetail, alloc: std.mem.Allocator) void {
            alloc.free(self.id);
            for (self.messages) |m| {
                alloc.free(m.role);
                alloc.free(m.content);
            }
            if (self.messages.len > 0) alloc.free(self.messages);
        }
    };

    // ── context ─────────────────────────────────────────────────────────

    /// Opaque context passed back to every function pointer (e.g. a *Config
    /// or agent factory owned by main.zig).
    ctx: ?*anyopaque = null,

    /// Execute one agent task. Returns the final answer text, allocated with
    /// `alloc` (caller frees). `session_id` optionally names a persisted
    /// session to resume/persist (dev.md §XV semantics).
    runTask: *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, prompt: []const u8, session_id: ?[]const u8) anyerror![]const u8,

    /// List known sessions. The returned slice AND each `id` are allocated
    /// with `alloc`; use `freeSessionSummaries` to release.
    listSessions: *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]SessionSummary,

    /// Fetch one session transcript; null when the id is unknown. Allocated
    /// with `alloc` — release via `SessionDetail.deinit`.
    getSession: *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, id: []const u8) anyerror!?SessionDetail,

    // ── helpers ─────────────────────────────────────────────────────────

    /// Release a `listSessions` result (no-op for empty slices).
    pub fn freeSessionSummaries(alloc: std.mem.Allocator, sessions: []SessionSummary) void {
        for (sessions) |s| alloc.free(s.id);
        if (sessions.len > 0) alloc.free(sessions);
    }
};

/// Heartbeat cadence for the /events stub.
pub const sse_heartbeat_ms: u64 = 15_000;
/// Upper bound on how long one /events connection may stay open (the stub has
/// no real event feed yet; without a cap a held stream would pin a thread in
/// threaded mode forever).
pub const sse_max_lifetime_ms: u64 = 5 * 60 * 1000;

// ── route result (pure, testable) ───────────────────────────────────────────

pub const RouteResult = struct {
    status: httpd.Status = .ok,
    content_type: httpd.ContentType = .json,
    /// Response body, allocated with the route call's allocator. For SSE
    /// routes (`sse == true`) the body is unused.
    body: []u8 = &.{},
    /// True when the request must be answered by streaming SSE instead of a
    /// buffered response.
    sse: bool = false,

    pub fn deinit(self: *RouteResult, alloc: std.mem.Allocator) void {
        if (self.body.len > 0) alloc.free(self.body);
        self.body = &.{};
    }
};

pub const RouteError = error{
    MissingDeps,
    OutOfMemory,
};

/// Dispatch a parsed request against the deps. Pure: no I/O, no clock reads.
/// The returned body is owned by `alloc` (free via RouteResult.deinit unless
/// an arena owns it).
pub fn route(deps: *const ServerDeps, alloc: std.mem.Allocator, req: *const httpd.Request) anyerror!RouteResult {
    const path = req.path;

    if (std.mem.eql(u8, path, "/healthz")) {
        if (!req.isGetLike()) return methodNotAllowed(alloc);
        return jsonBody(alloc, .ok, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, path, "/run") or std.mem.eql(u8, path, "/chat")) {
        if (req.isGetLike()) return methodNotAllowed(alloc);
        return routeRun(deps, alloc, req);
    }

    if (std.mem.eql(u8, path, "/sessions")) {
        if (!req.isGetLike()) return methodNotAllowed(alloc);
        return routeListSessions(deps, alloc);
    }

    // /sessions/:id
    if (std.mem.startsWith(u8, path, "/sessions/")) {
        const raw_id = path["/sessions/".len..];
        if (!req.isGetLike()) return methodNotAllowed(alloc);
        if (raw_id.len == 0) return jsonBody(alloc, .not_found, "{\"ok\":false,\"error\":\"session not found\"}");
        const id = try httpd.percentDecode(alloc, raw_id);
        defer alloc.free(id);
        return routeGetSession(deps, alloc, id);
    }

    if (std.mem.eql(u8, path, "/events")) {
        if (!req.isGetLike()) return methodNotAllowed(alloc);
        return RouteResult{ .sse = true };
    }

    return jsonBody(alloc, .not_found, "{\"ok\":false,\"error\":\"not found\"}");
}

// ── individual routes ───────────────────────────────────────────────────────

fn routeRun(deps: *const ServerDeps, alloc: std.mem.Allocator, req: *const httpd.Request) anyerror!RouteResult {
    const prompt = (try jsonStringField(alloc, req.body, "prompt")) orelse {
        return jsonBody(alloc, .bad_request, "{\"ok\":false,\"error\":\"missing prompt\"}");
    };
    defer alloc.free(prompt);
    const session_id = try jsonStringField(alloc, req.body, "session");
    defer if (session_id) |s| alloc.free(s);

    const answer = deps.runTask(deps.ctx, alloc, prompt, session_id) catch |e| {
        var buf: [160]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}) catch
            "{\"ok\":false,\"error\":\"run failed\"}";
        return jsonBody(alloc, .internal_server_error, body);
    };
    defer alloc.free(answer);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"ok\":true,\"answer\":\"");
    try jsonEscape(alloc, answer, &out);
    try out.appendSlice(alloc, "\",\"session\":");
    if (session_id) |sid| {
        try out.append(alloc, '"');
        try jsonEscape(alloc, sid, &out);
        try out.append(alloc, '"');
    } else {
        try out.appendSlice(alloc, "null");
    }
    try out.append(alloc, '}');
    return RouteResult{ .status = .ok, .content_type = .json, .body = try out.toOwnedSlice(alloc) };
}

fn routeListSessions(deps: *const ServerDeps, alloc: std.mem.Allocator) anyerror!RouteResult {
    const sessions = deps.listSessions(deps.ctx, alloc) catch |e| {
        var buf: [160]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}) catch
            "{\"ok\":false,\"error\":\"list failed\"}";
        return jsonBody(alloc, .internal_server_error, body);
    };
    defer ServerDeps.freeSessionSummaries(alloc, sessions);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"ok\":true,\"sessions\":[");
    for (sessions, 0..) |s, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"id\":\"");
        try jsonEscape(alloc, s.id, &out);
        try out.print(alloc, "\",\"created_at\":{d},\"message_count\":{d}}}", .{ s.created_at, s.message_count });
    }
    try out.appendSlice(alloc, "]}");
    return RouteResult{ .status = .ok, .content_type = .json, .body = try out.toOwnedSlice(alloc) };
}

fn routeGetSession(deps: *const ServerDeps, alloc: std.mem.Allocator, id: []const u8) anyerror!RouteResult {
    const maybe = deps.getSession(deps.ctx, alloc, id) catch |e| {
        var buf: [160]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}) catch
            "{\"ok\":false,\"error\":\"lookup failed\"}";
        return jsonBody(alloc, .internal_server_error, body);
    };
    var detail = maybe orelse
        return jsonBody(alloc, .not_found, "{\"ok\":false,\"error\":\"session not found\"}");
    defer detail.deinit(alloc);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"ok\":true,\"session\":{\"id\":\"");
    try jsonEscape(alloc, detail.id, &out);
    try out.print(alloc, "\",\"created_at\":{d},\"messages\":[", .{detail.created_at});
    for (detail.messages, 0..) |m, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"role\":\"");
        try jsonEscape(alloc, m.role, &out);
        try out.appendSlice(alloc, "\",\"content\":\"");
        try jsonEscape(alloc, m.content, &out);
        try out.appendSlice(alloc, "\"}");
    }
    try out.appendSlice(alloc, "]}}");
    return RouteResult{ .status = .ok, .content_type = .json, .body = try out.toOwnedSlice(alloc) };
}

fn methodNotAllowed(alloc: std.mem.Allocator) RouteError!RouteResult {
    return jsonBody(alloc, .method_not_allowed, "{\"ok\":false,\"error\":\"method not allowed\"}");
}

fn jsonBody(alloc: std.mem.Allocator, status: httpd.Status, literal: []const u8) RouteError!RouteResult {
    return RouteResult{
        .status = status,
        .content_type = .json,
        .body = try alloc.dupe(u8, literal),
    };
}

// ── live adapter (httpd.HandlerFn shape) ────────────────────────────────────

/// Entry point for the http server: cast ctx back to *ServerDeps, route, and
/// either send the buffered result or run the SSE heartbeat loop.
pub fn handle(ctx: ?*anyopaque, alloc: std.mem.Allocator, req: *const httpd.Request, res: *httpd.Responder) anyerror!void {
    const deps: *const ServerDeps = @ptrCast(@alignCast(ctx orelse return error.MissingDeps));
    var result = try route(deps, alloc, req);
    defer result.deinit(alloc);

    if (result.sse) {
        try serveEventsStub(res);
    } else {
        try res.send(result.status, result.content_type, result.body);
    }
}

/// SSE stub: emit heartbeats every `sse_heartbeat_ms` until the client goes
/// away or the max lifetime elapses. The real event feed arrives at
/// integration time (obs.zig envelopes); this endpoint only pins the wire
/// contract.
fn serveEventsStub(res: *httpd.Responder) !void {
    var stream = try res.startEventStream();
    try stream.comment("zharness events (stub); heartbeats every 15s");
    var elapsed: u64 = 0;
    while (!stream.peerGone() and elapsed < sse_max_lifetime_ms) {
        stream.sleepTicks(sse_heartbeat_ms, 250);
        elapsed += sse_heartbeat_ms;
        if (stream.peerGone()) break;
        stream.comment("heartbeat") catch break;
    }
}

// ── hand-rolled JSON helpers (repo style: no library) ───────────────────────

/// Append a JSON-escaped copy of `input` to `buf` (\", \\, \n, \r, \t).
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

/// Extract a string field from a flat JSON object into a freshly allocated,
/// escape-decoded slice. Null when absent or not a string. Mirrors the
/// extractor pattern used in model.zig/session.zig.
pub fn jsonStringField(alloc: std.mem.Allocator, obj: []const u8, key: []const u8) !?[]u8 {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
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
        if (obj[i] == '"') return try unescapeJson(alloc, obj[vs..i]);
    }
    return null;
}

/// Decode the simple escapes zharness emits (\" \\ \n \r \t \uXXXX-basic).
fn unescapeJson(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
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
                    // \uXXXX — decode BMP code points; surrogate pairs are
                    // beyond this harness's needs and pass through raw.
                    if (i + 4 < input.len) {
                        const cp = std.fmt.parseInt(u21, input[i + 1 .. i + 5], 16) catch {
                            try out.append(alloc, 'u');
                            continue;
                        };
                        var utf8_buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &utf8_buf) catch 0;
                        try out.appendSlice(alloc, utf8_buf[0..n]);
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

// ── tests ───────────────────────────────────────────────────────────────────

// Fake deps: static in-memory session store + canned task runner.
const FakeState = struct {
    answer: []const u8 = "did the thing",
    last_prompt: [256]u8 = undefined,
    last_prompt_len: usize = 0,
    last_session: [128]u8 = undefined,
    last_session_len: usize = 0,
};

var fake_state = FakeState{};

fn fakeRunTask(ctx: ?*anyopaque, alloc: std.mem.Allocator, prompt: []const u8, session_id: ?[]const u8) anyerror![]const u8 {
    const st: *FakeState = @ptrCast(@alignCast(ctx.?));
    st.last_prompt_len = @min(prompt.len, st.last_prompt.len);
    @memcpy(st.last_prompt[0..st.last_prompt_len], prompt[0..st.last_prompt_len]);
    if (session_id) |sid| {
        st.last_session_len = @min(sid.len, st.last_session.len);
        @memcpy(st.last_session[0..st.last_session_len], sid[0..st.last_session_len]);
    } else {
        st.last_session_len = 0;
    }
    return alloc.dupe(u8, st.answer);
}

fn fakeListSessions(ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]ServerDeps.SessionSummary {
    _ = ctx;
    var out: std.ArrayList(ServerDeps.SessionSummary) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, .{ .id = try alloc.dupe(u8, "alpha"), .created_at = 100, .message_count = 2 });
    try out.append(alloc, .{ .id = try alloc.dupe(u8, "beta"), .created_at = 200, .message_count = 4 });
    return out.toOwnedSlice(alloc);
}

fn fakeGetSession(ctx: ?*anyopaque, alloc: std.mem.Allocator, id: []const u8) anyerror!?ServerDeps.SessionDetail {
    _ = ctx;
    if (!std.mem.eql(u8, id, "alpha")) return null;
    var msgs: std.ArrayList(ServerDeps.MessageEntry) = .empty;
    errdefer msgs.deinit(alloc);
    try msgs.append(alloc, .{ .role = try alloc.dupe(u8, "user"), .content = try alloc.dupe(u8, "hi \"there\"\nline2") });
    try msgs.append(alloc, .{ .role = try alloc.dupe(u8, "assistant"), .content = try alloc.dupe(u8, "hello") });
    return ServerDeps.SessionDetail{
        .id = try alloc.dupe(u8, id),
        .created_at = 100,
        .messages = try msgs.toOwnedSlice(alloc),
    };
}

fn fakeDeps() ServerDeps {
    return .{
        .ctx = &fake_state,
        .runTask = fakeRunTask,
        .listSessions = fakeListSessions,
        .getSession = fakeGetSession,
    };
}

fn makeRequest(alloc: std.mem.Allocator, method: []const u8, target: []const u8, body: []const u8) !httpd.Request {
    var cl_buf: [16]u8 = undefined;
    const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{body.len});
    const raw = try std.fmt.allocPrint(alloc, "{s} {s} HTTP/1.1\r\nHost: t\r\nContent-Length: {s}\r\n\r\n{s}", .{ method, target, cl, body });
    defer alloc.free(raw);
    return httpd.parseRequest(alloc, raw);
}

test "route healthz" {
    const alloc = std.testing.allocator;
    const deps = fakeDeps();
    var req = try makeRequest(alloc, "GET", "/healthz", "");
    defer req.deinit(alloc);
    var r = try route(&deps, alloc, &req);
    defer r.deinit(alloc);
    try std.testing.expectEqual(httpd.Status.ok, r.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", r.body);
}

test "route run posts through deps.runTask with escaped answer" {
    const alloc = std.testing.allocator;
    fake_state.answer = "said \"hi\"\nbye";
    defer fake_state.answer = "did the thing";
    const deps = fakeDeps();

    var req = try makeRequest(alloc, "POST", "/run", "{\"prompt\":\"fix the bug\",\"session\":\"wk1\"}");
    defer req.deinit(alloc);
    var r = try route(&deps, alloc, &req);
    defer r.deinit(alloc);

    try std.testing.expectEqual(httpd.Status.ok, r.status);
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"answer\":\"said \\\"hi\\\"\\nbye\",\"session\":\"wk1\"}",
        r.body,
    );
    try std.testing.expectEqualStrings("fix the bug", fake_state.last_prompt[0..fake_state.last_prompt_len]);
    try std.testing.expectEqualStrings("wk1", fake_state.last_session[0..fake_state.last_session_len]);
}

test "route chat aliases run; missing prompt is a 400" {
    const alloc = std.testing.allocator;
    const deps = fakeDeps();

    var chat_req = try makeRequest(alloc, "POST", "/chat", "{\"prompt\":\"ping\"}");
    defer chat_req.deinit(alloc);
    var r1 = try route(&deps, alloc, &chat_req);
    defer r1.deinit(alloc);
    try std.testing.expect(r1.status == .ok);
    try std.testing.expect(std.mem.indexOf(u8, r1.body, "\"session\":null") != null);

    var bad_req = try makeRequest(alloc, "POST", "/run", "{\"other\":1}");
    defer bad_req.deinit(alloc);
    var r2 = try route(&deps, alloc, &bad_req);
    defer r2.deinit(alloc);
    try std.testing.expectEqual(httpd.Status.bad_request, r2.status);
    try std.testing.expect(std.mem.indexOf(u8, r2.body, "missing prompt") != null);
}

test "route lists and fetches sessions; unknown id is 404" {
    const alloc = std.testing.allocator;
    const deps = fakeDeps();

    var list_req = try makeRequest(alloc, "GET", "/sessions", "");
    defer list_req.deinit(alloc);
    var r1 = try route(&deps, alloc, &list_req);
    defer r1.deinit(alloc);
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"sessions\":[{\"id\":\"alpha\",\"created_at\":100,\"message_count\":2},{\"id\":\"beta\",\"created_at\":200,\"message_count\":4}]}",
        r1.body,
    );

    var get_req = try makeRequest(alloc, "GET", "/sessions/alpha", "");
    defer get_req.deinit(alloc);
    var r2 = try route(&deps, alloc, &get_req);
    defer r2.deinit(alloc);
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"session\":{\"id\":\"alpha\",\"created_at\":100,\"messages\":[{\"role\":\"user\",\"content\":\"hi \\\"there\\\"\\nline2\"},{\"role\":\"assistant\",\"content\":\"hello\"}]}}",
        r2.body,
    );

    var miss_req = try makeRequest(alloc, "GET", "/sessions/nope", "");
    defer miss_req.deinit(alloc);
    var r3 = try route(&deps, alloc, &miss_req);
    defer r3.deinit(alloc);
    try std.testing.expectEqual(httpd.Status.not_found, r3.status);

    // Percent-encoded ids resolve too.
    var enc_req = try makeRequest(alloc, "GET", "/sessions/al%70ha", "");
    defer enc_req.deinit(alloc);
    var r4 = try route(&deps, alloc, &enc_req);
    defer r4.deinit(alloc);
    try std.testing.expect(r4.status == .ok);
}

test "route unknown path 404 and wrong methods 405" {
    const alloc = std.testing.allocator;
    const deps = fakeDeps();

    var nf = try makeRequest(alloc, "GET", "/nope", "");
    defer nf.deinit(alloc);
    var r1 = try route(&deps, alloc, &nf);
    defer r1.deinit(alloc);
    try std.testing.expectEqual(httpd.Status.not_found, r1.status);

    var wrong_run = try makeRequest(alloc, "GET", "/run", "");
    defer wrong_run.deinit(alloc);
    var r2 = try route(&deps, alloc, &wrong_run);
    defer r2.deinit(alloc);
    try std.testing.expectEqual(httpd.Status.method_not_allowed, r2.status);

    var wrong_sessions = try makeRequest(alloc, "POST", "/sessions", "{}");
    defer wrong_sessions.deinit(alloc);
    var r3 = try route(&deps, alloc, &wrong_sessions);
    defer r3.deinit(alloc);
    try std.testing.expectEqual(httpd.Status.method_not_allowed, r3.status);

    var wrong_events = try makeRequest(alloc, "DELETE", "/events", "");
    defer wrong_events.deinit(alloc);
    var r4 = try route(&deps, alloc, &wrong_events);
    defer r4.deinit(alloc);
    try std.testing.expectEqual(httpd.Status.method_not_allowed, r4.status);
}

test "route marks /events as SSE stub" {
    const alloc = std.testing.allocator;
    const deps = fakeDeps();
    var req = try makeRequest(alloc, "GET", "/events", "");
    defer req.deinit(alloc);
    var r = try route(&deps, alloc, &req);
    defer r.deinit(alloc);
    try std.testing.expect(r.sse);
}

test "jsonStringField decodes escapes incl unicode" {
    const alloc = std.testing.allocator;
    const v = (try jsonStringField(alloc, "{\"prompt\":\"a\\nb\\\"c\\u00e9\"}", "prompt")).?;
    defer alloc.free(v);
    try std.testing.expectEqualStrings("a\nb\"c\u{00e9}", v);
    try std.testing.expect((try jsonStringField(alloc, "{\"a\":1}", "a")) == null);
    try std.testing.expect((try jsonStringField(alloc, "{}", "absent")) == null);
}

test "handle returns MissingDeps when ctx is null" {
    const alloc = std.testing.allocator;
    // Directly exercise the guard clause without a socket.
    try std.testing.expectError(error.MissingDeps, handle(null, alloc, undefined, undefined));
}
