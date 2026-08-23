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
//!   can be unit-tested offline; `handle` adapts it to the live connection.
//! - GET /events streams SSE: when the broadcast hub (server/events.zig) is
//!   installed it replays recent envelopes then tails live ones as bare
//!   `data:` frames; without a hub it falls back to the original heartbeat
//!   stub. Both paths honor client disconnects via Responder mechanics.
//!
//! Route table:
//!   POST /run            {prompt, session?} -> deps.runTask (buffered)
//!   POST /chat           {prompt, session?} -> deps.runTask (conversational alias)
//!   POST /run/stream     {prompt, session?, preset?, sandbox?}
//!                                            -> deps.runStream (SSE frames;
//!                                               see server/sse_run.zig)
//!   GET  /sessions                          -> deps.listSessions
//!   POST /sessions       {id?}              -> deps.createSession (501 when unwired)
//!   GET  /sessions/:id                      -> deps.getSession
//!   PATCH /sessions/:id  {rename:"new-id"}  -> deps.renameSession (501 when unwired)
//!   DELETE /sessions/:id                    -> deps.deleteSession (501 when unwired)
//!   GET  /healthz                           -> {"ok":true}
//!   GET  /events                            -> SSE (live hub feed or heartbeat fallback)
//!
//! ── RUN SERIALIZATION (applies to /run AND /run/stream) ───────────────────
//! Agent runs mutate shared process state (the DebugAllocator is not
//! thread-safe), so BOTH run paths must hold one process-wide run mutex
//! inside their ServerDeps implementations. HTTP connections stay concurrent
//! (threaded_connections = true); concurrent runs merely QUEUE behind each
//! other — at most one agent run is active at a time. Streaming clients keep
//! receiving heartbeats from the pump while queued. See server/sse_run.zig.
//!
//! Session ids are validated against [A-Za-z0-9_-] (max 128 chars) on every
//! /sessions/:id route BEFORE any dep runs — ids end up in file paths in the
//! main.zig implementations, so this is the path-traversal guard.

const std = @import("std");
const httpd = @import("httpd.zig");
const events = @import("events.zig");
const sse_run = @import("sse_run.zig");

/// Semantic errors the session-management deps may return; mapped to HTTP
/// statuses by `sessionOpFailure`.
pub const SessionOpError = error{
    /// DELETE/PATCH source id unknown -> 404.
    SessionNotFound,
    /// Rename/create target id already taken -> 409 Conflict.
    SessionExists,
    /// Id outside [A-Za-z0-9_-] -> 400 (route pre-validates too).
    InvalidSessionId,
};

/// Largest accepted session id length.
pub const max_session_id_len: usize = 128;

/// True when `id` is a well-formed session id: non-empty, ≤128 bytes, only
/// [A-Za-z0-9_-]. Enforced before any session dep invocation.
pub fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_session_id_len) return false;
    for (id) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

const CivilDate = struct { year: i64, month: u32, day: u32 };

/// Days-since-epoch -> civil date (Howard Hinnant's algorithm).
fn civilFromDays(days_since_epoch: i64) CivilDate {
    const z = days_since_epoch + 719_468;
    const era = @divFloor(z, 146_097);
    const doe: u64 = @intCast(z - era * 146_097); // [0, 146096]
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365; // [0, 399]
    const y = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    const mp = (5 * doy + 2) / 153; // [0, 11]
    const d: u32 = @intCast(doy - (153 * mp + 2) / 5 + 1); // [1, 31]
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9); // [1, 12]
    return .{ .year = if (m <= 2) y + 1 else y, .month = m, .day = d };
}

/// Mint a session id of the shape "web-YYYYMMDD-HHMMSS" (UTC) from a Unix
/// timestamp in seconds. Written into `buf` (≥32 bytes recommended). Used by
/// the POST /sessions implementation when the client sent no id.
pub fn formatMintedSessionId(buf: []u8, now_secs: i64) []const u8 {
    const days = @divFloor(now_secs, 86_400);
    var secs_of_day = now_secs - days * 86_400;
    const civ = civilFromDays(days);
    const hour = @divFloor(secs_of_day, 3600);
    secs_of_day -= hour * 3600;
    const minute = @divFloor(secs_of_day, 60);
    const sec = secs_of_day - minute * 60;
    return std.fmt.bufPrint(buf, "web-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        @as(u64, @intCast(civ.year)), civ.month, civ.day,
        @as(u32, @intCast(hour)),      @as(u32, @intCast(minute)), @as(u32, @intCast(sec)),
    }) catch "web-session"; // unreachable with a sane buf; degrade gracefully
}

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

    // ── wave-5 additions (all optional; null ⇒ the route answers 501) ────

    /// Streaming twin of `runTask` backing POST /run/stream. MUST hold the
    /// same process-wide run mutex as `runTask` (see the module doc's RUN
    /// SERIALIZATION note). Full RunEvent contract: server/sse_run.zig.
    /// Null ⇒ POST /run/stream answers 501 {"ok":false,...}.
    runStream: ?sse_run.RunStreamFn = null,

    /// DELETE /sessions/:id backend: unlink
    /// `<cwd>/.zharness/sessions/<id>.json` (stat first so a missing file
    /// maps to error.SessionNotFound) and best-effort removeTree
    /// `<cwd>/.zharness/checkpoints/<id>/` when present.
    deleteSession: ?*const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, id: []const u8) anyerror!void = null,

    /// PATCH /sessions/:id rename backend. Errors map:
    /// SessionNotFound → 404, SessionExists → 409, InvalidSessionId → 400.
    renameSession: ?*const fn (
        ctx: ?*anyopaque,
        alloc: std.mem.Allocator,
        old_id: []const u8,
        new_id: []const u8,
    ) anyerror!void = null,

    /// POST /sessions backend. `id == null` ⇒ mint one via
    /// api.formatMintedSessionId. Returns the FINAL id allocated with
    /// `alloc` (route frees it). error.SessionExists → 409.
    createSession: ?*const fn (
        ctx: ?*anyopaque,
        alloc: std.mem.Allocator,
        id: ?[]const u8,
    ) anyerror![]const u8 = null,

    // ── helpers ─────────────────────────────────────────────────────────

    /// Release a `listSessions` result (no-op for empty slices).
    pub fn freeSessionSummaries(alloc: std.mem.Allocator, sessions: []SessionSummary) void {
        for (sessions) |s| alloc.free(s.id);
        if (sessions.len > 0) alloc.free(sessions);
    }
};

/// Heartbeat cadence for the /events fallback (no hub installed).
pub const sse_heartbeat_ms: u64 = 15_000;
/// Upper bound on how long one FALLBACK /events connection may stay open
/// (without a real event feed a held stream would pin a thread in threaded
/// mode forever, so the stub self-terminates).
pub const sse_max_lifetime_ms: u64 = 5 * 60 * 1000;
/// Live-feed idle poll cadence: how often the hub stream checks its queue.
pub const sse_poll_ms: u64 = 50;
/// Live-feed keep-alive comment cadence. Doubles as the disconnect probe:
/// the write fails on a vanished peer even when no events flow, bounding
/// how long a dead /events connection lingers.
pub const sse_keepalive_ms: u64 = 15_000;

// ── route result (pure, testable) ───────────────────────────────────────────

pub const RouteResult = struct {
    status: httpd.Status = .ok,
    content_type: httpd.ContentType = .json,
    /// Response body, allocated with the route call's allocator. For SSE
    /// routes (`sse == true` or `run_stream == true`) the body is unused.
    body: []u8 = &.{},
    /// True when the request must be answered by streaming SSE instead of a
    /// buffered response (GET /events).
    sse: bool = false,
    /// True when the request must be answered by the /run/stream pump
    /// (POST /run/stream). Dispatched in `handle`, which parses the body and
    /// calls sse_run.serve.
    run_stream: bool = false,

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

    if (std.mem.eql(u8, path, "/run/stream")) {
        // Pure route decision only: body parsing + pump live in handle()
        // (sse_run.serve needs the Responder).
        if (!std.mem.eql(u8, req.method, "POST")) return methodNotAllowed(alloc);
        if (deps.runStream == null) {
            return jsonBody(alloc, .not_implemented, "{\"ok\":false,\"error\":\"streaming runs not available\"}");
        }
        return RouteResult{ .run_stream = true };
    }

    if (std.mem.eql(u8, path, "/sessions")) {
        if (req.isGetLike()) return routeListSessions(deps, alloc);
        if (std.mem.eql(u8, req.method, "POST")) return routeCreateSession(deps, alloc, req.body);
        return methodNotAllowed(alloc);
    }

    // /sessions/:id — GET fetches, DELETE removes, PATCH renames.
    if (std.mem.startsWith(u8, path, "/sessions/")) {
        const raw_id = path["/sessions/".len..];
        const id = try httpd.percentDecode(alloc, raw_id);
        defer alloc.free(id);

        if (req.isGetLike()) {
            if (id.len == 0) return jsonBody(alloc, .not_found, "{\"ok\":false,\"error\":\"session not found\"}");
            if (!validSessionId(id)) return jsonBody(alloc, .bad_request, "{\"ok\":false,\"error\":\"invalid session id\"}");
            return routeGetSession(deps, alloc, id);
        }
        if (std.mem.eql(u8, req.method, "DELETE")) {
            if (!validSessionId(id)) return jsonBody(alloc, .bad_request, "{\"ok\":false,\"error\":\"invalid session id\"}");
            return routeDeleteSession(deps, alloc, id);
        }
        if (std.mem.eql(u8, req.method, "PATCH")) {
            if (!validSessionId(id)) return jsonBody(alloc, .bad_request, "{\"ok\":false,\"error\":\"invalid session id\"}");
            return routeRenameSession(deps, alloc, id, req.body);
        }
        return methodNotAllowed(alloc);
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

/// Map a session-dep error onto a JSON failure response.
/// SessionNotFound → 404, SessionExists → 409, InvalidSessionId → 400,
/// anything else → 500 with the error name.
fn sessionOpFailure(alloc: std.mem.Allocator, e: anyerror) RouteError!RouteResult {
    switch (e) {
        error.SessionNotFound => return jsonBody(alloc, .not_found, "{\"ok\":false,\"error\":\"session not found\"}"),
        error.SessionExists => return jsonBody(alloc, .conflict, "{\"ok\":false,\"error\":\"session id already exists\"}"),
        error.InvalidSessionId => return jsonBody(alloc, .bad_request, "{\"ok\":false,\"error\":\"invalid session id\"}"),
        else => {
            var buf: [160]u8 = undefined;
            const body = std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}) catch
                "{\"ok\":false,\"error\":\"session op failed\"}";
            return jsonBody(alloc, .internal_server_error, body);
        },
    }
}

fn routeDeleteSession(deps: *const ServerDeps, alloc: std.mem.Allocator, id: []const u8) RouteError!RouteResult {
    const del = deps.deleteSession orelse
        return jsonBody(alloc, .not_implemented, "{\"ok\":false,\"error\":\"session deletion not available\"}");
    del(deps.ctx, alloc, id) catch |e| return sessionOpFailure(alloc, e);
    return jsonBody(alloc, .ok, "{\"ok\":true}");
}

fn routeRenameSession(deps: *const ServerDeps, alloc: std.mem.Allocator, old_id: []const u8, body: []const u8) RouteError!RouteResult {
    const rename = deps.renameSession orelse
        return jsonBody(alloc, .not_implemented, "{\"ok\":false,\"error\":\"session renaming not available\"}");
    const new_id = (try jsonStringField(alloc, body, "rename")) orelse
        return jsonBody(alloc, .bad_request, "{\"ok\":false,\"error\":\"missing rename\"}");
    defer alloc.free(new_id);
    if (!validSessionId(new_id)) return jsonBody(alloc, .bad_request, "{\"ok\":false,\"error\":\"invalid session id\"}");

    // Reject collisions at the ROUTE layer too (cheap stat-free guard for
    // fakes); the dep remains the authority and re-checks atomically.
    if (std.mem.eql(u8, old_id, new_id)) {
        return jsonBody(alloc, .conflict, "{\"ok\":false,\"error\":\"session id already exists\"}");
    }

    rename(deps.ctx, alloc, old_id, new_id) catch |e| return sessionOpFailure(alloc, e);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"ok\":true,\"id\":\"");
    try jsonEscape(alloc, new_id, &out);
    try out.appendSlice(alloc, "\"}");
    return RouteResult{ .status = .ok, .content_type = .json, .body = try out.toOwnedSlice(alloc) };
}

fn routeCreateSession(deps: *const ServerDeps, alloc: std.mem.Allocator, body: []const u8) RouteError!RouteResult {
    const create = deps.createSession orelse
        return jsonBody(alloc, .not_implemented, "{\"ok\":false,\"error\":\"session creation not available\"}");
    const requested = try jsonStringField(alloc, body, "id");
    defer if (requested) |r| alloc.free(r);
    if (requested) |r| {
        if (!validSessionId(r)) return jsonBody(alloc, .bad_request, "{\"ok\":false,\"error\":\"invalid session id\"}");
    }

    // Null ⇒ the dep mints an id (api.formatMintedSessionId shape). The dep
    // returns the FINAL id either way; this route only echoes it.
    const final_id = create(deps.ctx, alloc, requested) catch |e| return sessionOpFailure(alloc, e);
    defer alloc.free(final_id);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"ok\":true,\"id\":\"");
    try jsonEscape(alloc, final_id, &out);
    try out.appendSlice(alloc, "\"}");
    return RouteResult{ .status = .ok, .content_type = .json, .body = try out.toOwnedSlice(alloc) };
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
/// dispatch to the buffered sender or one of the SSE pumps.
pub fn handle(ctx: ?*anyopaque, alloc: std.mem.Allocator, req: *const httpd.Request, res: *httpd.Responder) anyerror!void {
    const deps: *const ServerDeps = @ptrCast(@alignCast(ctx orelse return error.MissingDeps));
    var result = try route(deps, alloc, req);
    defer result.deinit(alloc);

    if (result.run_stream) {
        // Route already guaranteed deps.runStream != null (501 otherwise).
        const run_fn = deps.runStream.?;
        var run_req = sse_run.parseRunRequest(alloc, req.body) catch |e| switch (e) {
            error.MissingPrompt => {
                try res.send(.bad_request, .json, "{\"ok\":false,\"error\":\"missing prompt\"}");
                return;
            },
            else => return e,
        };
        defer sse_run.freeRunRequest(alloc, &run_req);
        return sse_run.serve(run_fn, deps.ctx, run_req, res, .{});
    }
    if (result.sse) {
        try serveEvents(res);
    } else {
        try res.send(result.status, result.content_type, result.body);
    }
}

/// /events entry point: live hub feed when the broadcast hub is installed,
/// heartbeat stub otherwise. (Route dispatch stays pure; the mode decision
/// happens here at handle time.)
pub fn serveEvents(res: *httpd.Responder) !void {
    if (events.hub()) |h| return serveHubStream(h, res);
    return serveHeartbeatStream(res, sse_heartbeat_ms, sse_max_lifetime_ms);
}

/// Live SSE feed: replay the subscriber's history snapshot as bare
/// `data: <json>` frames, then tail the queue. Disconnects surface through
/// the Responder (`peerGone`) once a write fails — keep-alive comments make
/// sure an idle-but-dead connection is detected within ~`sse_keepalive_ms`.
///
/// Requires httpd Options.threaded_connections = true in production: the
/// loop runs until the client goes away and must not starve other routes.
fn serveHubStream(h: *events.Hub, res: *httpd.Responder) !void {
    var stream = try res.startEventStream();
    try stream.comment("zharness event stream; recent envelopes then live");

    const sub = h.subscribe() catch return; // stream already open: just end it
    defer h.unsubscribe(sub);

    var quiet_ms: u64 = 0;
    while (!stream.peerGone()) {
        if (sub.take()) |line| {
            // Borrowed line: valid only until the next take — write it out
            // now. A failed write means the client is gone.
            events.writeDataFrame(&stream, line) catch break;
            quiet_ms = 0;
            continue; // drain any backlog without sleeping
        }
        quiet_ms += sse_poll_ms;
        if (quiet_ms >= sse_keepalive_ms) {
            stream.comment("keep-alive") catch break;
            quiet_ms = 0;
        }
        stream.sleepTicks(sse_poll_ms, 10);
    }
}

/// Heartbeat fallback (no hub): emit SSE comments every `beat_ms` until the
/// client goes away or `max_ms` elapses. Parametrized so offline tests can
/// shrink the cadence; production passes the module constants above.
pub fn serveHeartbeatStream(res: *httpd.Responder, beat_ms: u64, max_ms: u64) !void {
    var stream = try res.startEventStream();
    try stream.comment("zharness events (no feed installed); heartbeats");
    var elapsed: u64 = 0;
    while (!stream.peerGone() and elapsed < max_ms) {
        stream.sleepTicks(beat_ms, 250);
        elapsed += beat_ms;
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

/// Never actually invoked in route tests (route only checks non-null);
/// panics loudly if a dispatch path ever forgets to guard.
fn stubRunStream(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    req: sse_run.RunRequest,
    on_event: sse_run.OnEventFn,
    userdata: ?*anyopaque,
) anyerror!void {
    _ = ctx;
    _ = alloc;
    _ = req;
    _ = on_event;
    _ = userdata;
    @panic("stubRunStream must not be called from route()");
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

    // POST /sessions is now the CREATE route: with no createSession dep it
    // answers 501 (previously a blanket 405).
    var wrong_sessions = try makeRequest(alloc, "POST", "/sessions", "{}");
    defer wrong_sessions.deinit(alloc);
    var r3 = try route(&deps, alloc, &wrong_sessions);
    defer r3.deinit(alloc);
    try std.testing.expectEqual(httpd.Status.not_implemented, r3.status);

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

test "route POST /run/stream marks stream when wired, 501 and 405 otherwise" {
    const alloc = std.testing.allocator;

    // fakeDeps() leaves runStream null: buffered 501, no SSE marker.
    const plain = fakeDeps();
    var post = try makeRequest(alloc, "POST", "/run/stream", "{\"prompt\":\"p\"}");
    defer post.deinit(alloc);
    var r1 = try route(&plain, alloc, &post);
    defer r1.deinit(alloc);
    try std.testing.expectEqual(httpd.Status.not_implemented, r1.status);
    try std.testing.expect(std.mem.indexOf(u8, r1.body, "streaming runs not available") != null);

    // With runStream wired: pure SSE marker; body parsing happens in handle.
    var wired = fakeDeps();
    wired.runStream = stubRunStream;
    var r2 = try route(&wired, alloc, &post);
    defer r2.deinit(alloc);
    try std.testing.expect(r2.run_stream);
    try std.testing.expect(!r2.sse);

    // GET and PUT are refused (POST-only resource).
    var get = try makeRequest(alloc, "GET", "/run/stream", "");
    defer get.deinit(alloc);
    var r3 = try route(&wired, alloc, &get);
    defer r3.deinit(alloc);
    try std.testing.expectEqual(httpd.Status.method_not_allowed, r3.status);

    var put = try makeRequest(alloc, "PUT", "/run/stream", "{}");
    defer put.deinit(alloc);
    var r4 = try route(&wired, alloc, &put);
    defer r4.deinit(alloc);
    try std.testing.expectEqual(httpd.Status.method_not_allowed, r4.status);
}

test "validSessionId gates charset, length and emptiness" {
    try std.testing.expect(validSessionId("web-20260823-101112"));
    try std.testing.expect(validSessionId("a_b-c"));
    try std.testing.expect(validSessionId("0"));
    try std.testing.expect(!validSessionId(""));
    try testing_expectInvalid("../etc/passwd");
    try testing_expectInvalid("a/b");
    try testing_expectInvalid("a b");
    try testing_expectInvalid("dot.dot");
    try testing_expectInvalid("quote\"id");
    // Over-length rejected; exact length accepted.
    const over = comptime comptimeFill(max_session_id_len + 1, 'x');
    const exact = comptime comptimeFill(max_session_id_len, 'x');
    try std.testing.expect(!validSessionId(&over));
    try std.testing.expect(validSessionId(&exact));
}

/// Comptime byte-fill (stand-in for the removed `str ** n` repetition).
fn comptimeFill(comptime n: usize, comptime byte: u8) [n]u8 {
    var a: [n]u8 = undefined;
    for (&a) |*c| c.* = byte;
    return a;
}

fn testing_expectInvalid(id: []const u8) !void {
    try std.testing.expect(!validSessionId(id));
}

test "formatMintedSessionId renders web-YYYYMMDD-HHMMSS from unix seconds" {
    var buf: [64]u8 = undefined;
    // 2026-08-23 10:11:12 UTC == 1787479872 epoch seconds
    // (2026-08-23T00:00:00Z == 1787443200 + 36672s).
    const id = formatMintedSessionId(&buf, 1_787_479_872);
    try std.testing.expectEqualStrings("web-20260823-101112", id);

    const id2 = formatMintedSessionId(&buf, 0); // 1970-01-01 00:00:00
    try std.testing.expectEqualStrings("web-19700101-000000", id2);

    const id3 = formatMintedSessionId(&buf, 951_782_400); // 2000-02-29 00:00:00
    try testing_expectEqualStrings(id3, "web-20000229-000000");
}

fn testing_expectEqualStrings(got: []const u8, want: []const u8) !void {
    try std.testing.expectEqualStrings(want, got);
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
