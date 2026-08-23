//! DSH apiproxy unary router — the four-quadrant RPC envelope over
//! `POST /api/<method>` (docs/dsh-reuse-spec.md §4; contract truth:
//! `_ref/deepseek-harness/packages/host/apiproxy/src/api/*.schema.ts`).
//!
//! Wire contract (§4, byte-exact fixtures in src/_t_apiproxy.zig):
//!
//!   request  {"type":"client-request","rpcId":"<uuid>","method":"<m>","payload":{…}}
//!   response ALWAYS HTTP 200; business errors live in result.error
//!            {"type":"server-response","rpcId":"<echoed>",
//!             "result":{"ok":true,"value":…} | {"ok":false,"error":{…}}}
//!
//! Error bodies follow the closed RpcError union: {code,message,details}
//! with per-code details objects. Codes zharness uses: bad-request,
//! internal, session-not-found, workspace-not-found, workspace-invalid-path,
//! steer-unavailable, title-invalid, directory-picker-unavailable.
//!
//! DEVIATION from upstream (documented): upstream's fetch carrier answers a
//! bare HTTP 404 "not found" for unknown methods and 400 plain-text for
//! non-JSON bodies at the carrier layer. This router keeps the carrier-level
//! 404/415/400 statuses for path/content-type/non-JSON-body cases (client-
//! invisible: the vendored GUI never calls unknown paths) but answers an
//! UNKNOWN METHOD NAME with 200 + result.error bad-request per the wave-5
//! instruction "unknown method → their error shape".
//!
//! Dependency seam — main.zig wires zharness implementations later WITHOUT
//! this file knowing agent/session internals (`ServerDeps` pattern):
//!
//!   var deps = apiproxy.ApiProxyDeps{
//!       .cwd = cfg.cwd, .home = home, .version = "0.1.0",
//!       .listSessions = my.listSessions,
//!       .sessionHistory = my.sessionHistory,
//!       …
//!   };
//!   server = httpd.Server.init(alloc, apiproxy.handler(&deps), .{
//!       .port = 3080, .threaded_connections = true }); // WS/SSE need threads!
//!
//! Handlers receive the per-connection ARENA allocator (httpd contract):
//! everything they return is freed wholesale when the connection ends, so no
//! DTO in this file has a deinit.
//!
//! Threading: route execution is single-threaded per request and serialized
//! only by whatever the deps implementations do; WebSocket downlink pumps run
//! on their own connection threads (see events_ws.zig). Run httpd with
//! `threaded_connections = true` whenever this router is mounted.

const std = @import("std");
const httpd = @import("../httpd.zig");
const jsonx = @import("jsonx.zig");
const events_ws = @import("events_ws.zig");
const clib = @import("../../clib.zig");

pub const json = jsonx; // re-export for sibling modules/tests

// ── RPC error codes ─────────────────────────────────────────────────────────

/// The subset of upstream's closed code union zharness can produce.
pub const RpcCode = enum {
    bad_request,
    internal,
    session_not_found,
    steer_unavailable,
    title_invalid,
    workspace_not_found,
    workspace_invalid_path,
    directory_picker_unavailable,

    pub fn asStr(self: RpcCode) []const u8 {
        return switch (self) {
            .bad_request => "bad-request",
            .internal => "internal",
            .session_not_found => "session-not-found",
            .steer_unavailable => "steer-unavailable",
            .title_invalid => "title-invalid",
            .workspace_not_found => "workspace-not-found",
            .workspace_invalid_path => "workspace-invalid-path",
            .directory_picker_unavailable => "directory-picker-unavailable",
        };
    }
};

/// Sentinel rpcId for error responses whose request rpcId was unreadable
/// (upstream `INVALID_REQUEST_RPC_ID`, fetch/handler.ts).
pub const invalid_request_rpc_id = "invalid-request";

// ── DTOs crossing the deps seam ─────────────────────────────────────────────

/// Row of `session.list`. All slices are arena-owned by the caller's alloc.
pub const SessionSummary = struct {
    session_id: []const u8,
    updated_at_ms: i64,
    running: bool = false,
    blank: bool = true,
    parent_session_id: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    agent_preset: ?[]const u8 = null,
    /// Pre-rendered {"asOfSeq":…,"values":{…}} or null to omit the block.
    projections_json: ?[]const u8 = null,
};

/// One `session.history` entry: strict-envelope SessionEvent JSON plus an
/// optional host-computed tool view, both passed through VERBATIM (the wire
/// passthrough discipline of sessions.schema.ts — the client fold owns the
/// event interior).
pub const HistoryEntry = struct {
    event_json: []const u8,
    view_json: ?[]const u8 = null,
};

pub const HistoryPage = struct {
    entries: []HistoryEntry,
    has_more: bool = false,
    /// Tail-page-only projections block JSON, or null to omit.
    projections_json: ?[]const u8 = null,
};

pub const PromptMode = enum {
    queue,
    steer,

    pub fn parse(s: []const u8) ?PromptMode {
        if (std.mem.eql(u8, s, "queue")) return .queue;
        if (std.mem.eql(u8, s, "steer")) return .steer;
        return null;
    }

    pub fn asStr(self: PromptMode) []const u8 {
        return switch (self) {
            .queue => "queue",
            .steer => "steer",
        };
    }
};

/// Validated session.prompt payload handed to the backend.
pub const PromptRequest = struct {
    session_id: []const u8,
    mode: PromptMode,
    /// Pre-rendered content array JSON (validated text-only parts), passed
    /// through verbatim so the backend sees exactly what the browser sent.
    content_json: []const u8,
    client_time_zone: ?[]const u8 = null,
};

pub const PromptAck = struct {
    /// Non-null renders the optional command slot
    /// ("command":{"kind":"success","text":…}).
    command_text: ?[]const u8 = null,
};

pub const CreateOptions = struct {
    workspace_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    agent_preset: ?[]const u8 = null,
};

pub const RenameResult = struct {
    title: []const u8,
    seq: i64,
};

pub const SearchItem = struct {
    session_id: []const u8,
    snippet: []const u8,
};

pub const SearchPage = struct {
    items: []SearchItem,
    has_more: bool = false,
};

// ── dependency surface ──────────────────────────────────────────────────────

pub const ListSessionsFn = *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]SessionSummary;
pub const SessionHistoryFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    before_seq: ?i64,
    max_messages: ?u32,
) anyerror!HistoryPage;
pub const CreateSessionFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    opts: CreateOptions,
) anyerror![]const u8; // final sessionId, allocated with alloc
pub const PromptSessionFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    req: PromptRequest,
) anyerror!PromptAck;
pub const CancelSessionFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    session_id: []const u8,
) anyerror!void;
pub const RenameSessionFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    title: []const u8,
) anyerror!RenameResult;
pub const SearchSessionsFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    query: []const u8,
) anyerror!SearchPage;
pub const OpenPathFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    path: []const u8,
) anyerror!void;

/// Function-pointer registry the integrator fills in. Required members are
/// the conversation/session lifecycle only main.zig can know; every other
/// method answers via the built-in default implementations below until an
/// override is provided.
pub const ApiProxyDeps = struct {
    ctx: ?*anyopaque = null,

    // Static host facts consumed by the built-in host.describe and the
    // single-synthesized-workspace defaults (spec §7: v1 has one workspace
    // rooted at the server cwd).
    version: []const u8 = "zharness-dev",
    cwd: []const u8 = "",
    home: []const u8 = "",
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,

    // ── required ──
    listSessions: ListSessionsFn,
    sessionHistory: SessionHistoryFn,
    createSession: CreateSessionFn,
    promptSession: PromptSessionFn,
    cancelSession: CancelSessionFn,
    renameSession: RenameSessionFn,

    // ── optional overrides (null ⇒ built-in default) ──
    searchSessions: ?SearchSessionsFn = null,
    openPath: ?OpenPathFn = null,
};

// ── response rendering ──────────────────────────────────────────────────────

pub const UnaryResponse = struct {
    status: httpd.Status = .ok,
    body: []u8,
};

/// Full ServerResponse form around a pre-rendered result object.
fn renderFull(alloc: std.mem.Allocator, rpc_id: []const u8, result_inner: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"server-response\",\"rpcId\":");
    try jsonx.appendJsonString(alloc, &out, rpc_id);
    try out.appendSlice(alloc, ",\"result\":");
    try out.appendSlice(alloc, result_inner);
    try out.appendSlice(alloc, "}");
    return out.toOwnedSlice(alloc);
}

/// ok:true + value (value must be a complete JSON value string).
pub fn okValue(alloc: std.mem.Allocator, rpc_id: []const u8, value_json: []const u8) !UnaryResponse {
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(alloc);
    try inner.appendSlice(alloc, "{\"ok\":true,\"value\":");
    try inner.appendSlice(alloc, value_json);
    try inner.appendSlice(alloc, "}");
    return .{ .body = try renderFull(alloc, rpc_id, inner.items) };
}

/// ok:false + error with the given code/message/details (details must be a
/// complete JSON object matching the code's details schema).
pub fn errValue(
    alloc: std.mem.Allocator,
    rpc_id: []const u8,
    code: RpcCode,
    message: []const u8,
    details_json: []const u8,
) !UnaryResponse {
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(alloc);
    try inner.appendSlice(alloc, "{\"ok\":false,\"error\":{\"code\":\"");
    try inner.appendSlice(alloc, code.asStr());
    try inner.appendSlice(alloc, "\",\"message\":");
    try jsonx.appendJsonString(alloc, &inner, message);
    try inner.appendSlice(alloc, ",\"details\":");
    try inner.appendSlice(alloc, details_json);
    try inner.appendSlice(alloc, "}}");
    return .{ .body = try renderFull(alloc, rpc_id, inner.items) };
}

/// bad-request error with empty issues array (payload validation failures).
fn badRequest(alloc: std.mem.Allocator, rpc_id: []const u8, message: []const u8) !UnaryResponse {
    return errValue(alloc, rpc_id, .bad_request, message, "{\"issues\":[]}");
}

fn internalError(alloc: std.mem.Allocator, rpc_id: []const u8, message: []const u8) !UnaryResponse {
    return errValue(alloc, rpc_id, .internal, message, "{}");
}

/// Map a deps implementation error onto the RPC error vocabulary. The
/// sessionId/workspaceId hints for the code-specific details objects are
/// pulled from the request payload when present (empty strings otherwise).
fn mapDepsError(
    alloc: std.mem.Allocator,
    rpc_id: []const u8,
    err: anyerror,
    payload: []const u8,
) !UnaryResponse {
    const session_hint: []const u8 = (jsonx.getStringAlloc(alloc, payload, "sessionId") catch null) orelse "";
    const ws_hint: []const u8 = (jsonx.getStringAlloc(alloc, payload, "workspaceId") catch null) orelse "";

    switch (err) {
        error.SessionNotFound => {
            var d: std.ArrayList(u8) = .empty;
            defer d.deinit(alloc);
            try d.appendSlice(alloc, "{\"sessionId\":");
            try jsonx.appendJsonString(alloc, &d, session_hint);
            try d.appendSlice(alloc, "}");
            return errValue(alloc, rpc_id, .session_not_found, "session not found", d.items);
        },
        error.WorkspaceNotFound => {
            var d: std.ArrayList(u8) = .empty;
            defer d.deinit(alloc);
            try d.appendSlice(alloc, "{\"workspaceId\":");
            try jsonx.appendJsonString(alloc, &d, ws_hint);
            try d.appendSlice(alloc, "}");
            return errValue(alloc, rpc_id, .workspace_not_found, "workspace not found", d.items);
        },
        error.WorkspaceInvalidPath => {
            const path_hint = jsonx.getStringAlloc(alloc, payload, "path") catch null;
            var d: std.ArrayList(u8) = .empty;
            defer d.deinit(alloc);
            try d.appendSlice(alloc, "{\"path\":");
            if (path_hint) |ph| {
                try jsonx.appendJsonString(alloc, &d, ph);
            } else {
                try d.appendSlice(alloc, "null");
            }
            try d.appendSlice(alloc, "}");
            return errValue(alloc, rpc_id, .workspace_invalid_path, "invalid workspace path", d.items);
        },
        error.SteerUnavailable => {
            // itemId placeholder v1: the session the steer targeted (the
            // queued-item id does not exist in zharness's single-slot model).
            var d: std.ArrayList(u8) = .empty;
            defer d.deinit(alloc);
            try d.appendSlice(alloc, "{\"itemId\":");
            try jsonx.appendJsonString(alloc, &d, session_hint);
            try d.appendSlice(alloc, "}");
            return errValue(alloc, rpc_id, .steer_unavailable, "steering is unavailable", d.items);
        },
        error.TitleInvalid => {
            var d: std.ArrayList(u8) = .empty;
            defer d.deinit(alloc);
            try d.appendSlice(alloc, "{\"sessionId\":");
            try jsonx.appendJsonString(alloc, &d, session_hint);
            try d.appendSlice(alloc, "}");
            return errValue(alloc, rpc_id, .title_invalid, "invalid title", d.items);
        },
        else => {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "backend failure: {s}", .{@errorName(err)}) catch "backend failure";
            return internalError(alloc, rpc_id, msg);
        },
    }
}

// ── envelope parsing ────────────────────────────────────────────────────────

pub const EnvelopeError = error{
    /// Body is not JSON at all → carrier-level 400 (upstream parity).
    NotJson,
    OutOfMemory,
};

/// Parsed ClientRequest full form. `method` is the decoded method string;
/// `payload_raw` is the verbatim JSON value slice ("{}" when the key is
/// absent — z.unknown() treats absent and undefined identically on the wire).
pub const Envelope = struct {
    rpc_id: []const u8,
    method: []const u8,
    payload_raw: []const u8,
};

/// Parse and validate the message-layer full form (rpc.schema.ts
/// clientRequestSchema): type literal + string rpcId + string method +
/// unknown payload. Bad SHAPE (valid JSON, wrong envelope) returns null so
/// callers emit 200 + bad-request with a salvaged rpcId.
pub fn parseEnvelope(alloc: std.mem.Allocator, body: []const u8) EnvelopeError!?Envelope {
    if (jsonx.objectBody(body) == null) return error.NotJson;

    const type_raw = jsonx.getRaw(body, "type") orelse return null;
    if (!std.mem.eql(u8, type_raw, "\"client-request\"")) return null;

    var env = Envelope{ .rpc_id = invalid_request_rpc_id, .method = "", .payload_raw = "{}" };

    if (jsonx.getStringAlloc(alloc, body, "rpcId") catch null) |id| {
        env.rpc_id = id; // readable id wins; unreadable keeps the sentinel
    }
    env.method = (jsonx.getStringAlloc(alloc, body, "method") catch null) orelse return null;
    if (jsonx.getRaw(body, "payload")) |p| env.payload_raw = p;
    return env;
}

// ── payload field validation helpers ────────────────────────────────────────

const PayloadError = error{ PayloadInvalid, OutOfMemory };

/// Required non-empty JSON string field, decoded into `alloc`.
fn reqString(alloc: std.mem.Allocator, payload: []const u8, key: []const u8) PayloadError![]const u8 {
    const raw = jsonx.getRaw(payload, key) orelse return error.PayloadInvalid;
    if (!jsonx.isString(raw)) return error.PayloadInvalid;
    return jsonx.decodeString(alloc, raw[1 .. raw.len - 1]) catch return error.OutOfMemory;
}

/// Optional JSON string field.
fn optString(alloc: std.mem.Allocator, payload: []const u8, key: []const u8) PayloadError!?[]const u8 {
    const raw = jsonx.getRaw(payload, key) orelse return null;
    if (!jsonx.isString(raw)) return error.PayloadInvalid;
    return jsonx.decodeString(alloc, raw[1 .. raw.len - 1]) catch return error.OutOfMemory;
}

/// Optional integer field (zod z.number().int() analog).
fn optInt(payload: []const u8, key: []const u8) PayloadError!?i64 {
    const raw = jsonx.getRaw(payload, key) orelse return null;
    if (jsonx.isString(raw)) return error.PayloadInvalid;
    return jsonx.getInt(payload, key) orelse error.PayloadInvalid;
}

// ── shared renderers ────────────────────────────────────────────────────────

/// SessionSummary row in sessions.schema.ts declaration order (null fields
/// omitted — indistinguishable from absent after JSON transport).
pub fn appendSessionSummaryJson(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    s: *const SessionSummary,
) !void {
    try out.appendSlice(alloc, "{\"sessionId\":");
    try jsonx.appendJsonString(alloc, out, s.session_id);
    try out.appendSlice(alloc, ",\"updatedAt\":");
    try jsonx.appendInt(alloc, out, s.updated_at_ms);
    try out.appendSlice(alloc, ",\"running\":");
    try out.appendSlice(alloc, if (s.running) "true" else "false");
    try out.appendSlice(alloc, ",\"blank\":");
    try out.appendSlice(alloc, if (s.blank) "true" else "false");
    if (s.parent_session_id) |v| {
        try out.appendSlice(alloc, ",\"parentSessionId\":");
        try jsonx.appendJsonString(alloc, out, v);
    }
    if (s.origin) |v| {
        try out.appendSlice(alloc, ",\"origin\":");
        try jsonx.appendJsonString(alloc, out, v);
    }
    if (s.cwd) |v| {
        try out.appendSlice(alloc, ",\"cwd\":");
        try jsonx.appendJsonString(alloc, out, v);
    }
    if (s.agent_preset) |v| {
        try out.appendSlice(alloc, ",\"agentPreset\":");
        try jsonx.appendJsonString(alloc, out, v);
    }
    if (s.projections_json) |p| {
        try out.appendSlice(alloc, ",\"projections\":");
        try out.appendSlice(alloc, p);
    }
    try out.appendSlice(alloc, "}");
}

/// WorkspaceView row in workspace.schema.ts order; timestamps rendered as
/// ISO-8601 Z strings from epoch-ms values.
pub fn appendWorkspaceViewJson(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    workspace_id: []const u8,
    path: []const u8,
    title: []const u8,
    session_ids: []const []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
) !void {
    try out.appendSlice(alloc, "{\"workspaceId\":");
    try jsonx.appendJsonString(alloc, out, workspace_id);
    try out.appendSlice(alloc, ",\"path\":");
    try jsonx.appendJsonString(alloc, out, path);
    try out.appendSlice(alloc, ",\"title\":");
    try jsonx.appendJsonString(alloc, out, title);
    try out.appendSlice(alloc, ",\"sessionIds\":[");
    for (session_ids, 0..) |id, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        try jsonx.appendJsonString(alloc, out, id);
    }
    var iso: std.ArrayList(u8) = .empty;
    defer iso.deinit(alloc);
    try out.appendSlice(alloc, "],\"createdAt\":");
    try jsonx.appendIso8601(alloc, &iso, created_at_ms);
    try jsonx.appendJsonString(alloc, out, iso.items);
    iso.clearRetainingCapacity();
    try out.appendSlice(alloc, ",\"updatedAt\":");
    try jsonx.appendIso8601(alloc, &iso, updated_at_ms);
    try jsonx.appendJsonString(alloc, out, iso.items);
    try out.appendSlice(alloc, "}");
}

/// Basename of a '/'-separated path (synthesized workspace title).
pub fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    var p = path;
    while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
    return p;
}

/// Wall-clock ms for default views (clib seconds timestamp × 1000).
fn nowMs() i64 {
    return clib.nowTimestamp() * std.time.ms_per_s;
}

// ── built-in defaults (single synthesized workspace; spec §7) ──────────────

/// The single synthesized workspace id.
pub const default_workspace_id = "default";

fn wsListDefault(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8) !UnaryResponse {
    const sessions = try deps.listSessions(deps.ctx, alloc);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    for (sessions) |s| try ids.append(alloc, s.session_id);

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    const now = nowMs();
    try value.appendSlice(alloc, "{\"items\":[");
    try appendWorkspaceViewJson(alloc, &value, default_workspace_id, deps.cwd, basename(deps.cwd), ids.items, now, now);
    try value.appendSlice(alloc, "],\"archivedSessionIds\":[]}");
    return okValue(alloc, rpc_id, value.items);
}

fn wsCreateDefault(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const path = (try optString(alloc, payload, "path")) orelse return error.PayloadInvalid;
    if (!std.mem.eql(u8, path, deps.cwd)) {
        // v1 has exactly one adoptable directory: the server cwd.
        var d: std.ArrayList(u8) = .empty;
        defer d.deinit(alloc);
        try d.appendSlice(alloc, "{\"path\":");
        try jsonx.appendJsonString(alloc, &d, path);
        try d.appendSlice(alloc, "}");
        return errValue(alloc, rpc_id, .workspace_invalid_path, "only the server cwd can be adopted in v1", d.items);
    }
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    const now = nowMs();
    try value.appendSlice(alloc, "{\"workspace\":");
    try appendWorkspaceViewJson(alloc, &value, default_workspace_id, deps.cwd, basename(deps.cwd), &.{}, now, now);
    try value.appendSlice(alloc, ",\"created\":false}");
    return okValue(alloc, rpc_id, value.items);
}

fn wsViewDefault(deps: *const ApiProxyDeps, alloc: std.mem.Allocator) ![]u8 {
    const sessions = try deps.listSessions(deps.ctx, alloc);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    for (sessions) |s| try ids.append(alloc, s.session_id);
    var view: std.ArrayList(u8) = .empty;
    errdefer view.deinit(alloc);
    const now = nowMs();
    try appendWorkspaceViewJson(alloc, &view, default_workspace_id, deps.cwd, basename(deps.cwd), ids.items, now, now);
    return view.toOwnedSlice(alloc);
}

fn wsRenameDefault(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const wid = (try optString(alloc, payload, "workspaceId")) orelse return error.PayloadInvalid;
    const title = (try optString(alloc, payload, "title")) orelse return error.PayloadInvalid;
    if (std.mem.trim(u8, title, " \t").len == 0) return error.PayloadInvalid; // refine: non-blank
    if (!std.mem.eql(u8, wid, default_workspace_id)) return error.WorkspaceNotFound;
    const view = try wsViewForSessions(deps, alloc, title);
    defer alloc.free(view);
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"workspace\":");
    try value.appendSlice(alloc, view);
    try value.appendSlice(alloc, "}");
    return okValue(alloc, rpc_id, value.items);
}

fn wsViewForSessions(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, title_override: ?[]const u8) ![]u8 {
    const sessions = try deps.listSessions(deps.ctx, alloc);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    for (sessions) |s| try ids.append(alloc, s.session_id);
    var view: std.ArrayList(u8) = .empty;
    errdefer view.deinit(alloc);
    const now = nowMs();
    try appendWorkspaceViewJson(
        alloc,
        &view,
        default_workspace_id,
        deps.cwd,
        title_override orelse basename(deps.cwd),
        ids.items,
        now,
        now,
    );
    return view.toOwnedSlice(alloc);
}

fn wsDeleteDefault(alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const wid = (try optString(alloc, payload, "workspaceId")) orelse return error.PayloadInvalid;
    if (!std.mem.eql(u8, wid, default_workspace_id)) return error.WorkspaceNotFound;
    // The synthesized root cannot truly be deleted; ack per the wire shape.
    // Documented v1 limitation (nothing durable is removed).
    return okValue(alloc, rpc_id, "{\"deleted\":true}");
}

fn wsInsertBeforeDefault(alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const wid = (try optString(alloc, payload, "workspaceId")) orelse return error.PayloadInvalid;
    if (!std.mem.eql(u8, wid, default_workspace_id)) return error.WorkspaceNotFound;
    return okValue(alloc, rpc_id, "{\"workspaceIds\":[\"" ++ default_workspace_id ++ "\"]}");
}

fn wsInsertSessionBeforeDefault(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const wid = (try optString(alloc, payload, "workspaceId")) orelse return error.PayloadInvalid;
    _ = try optString(alloc, payload, "sessionId"); // required by schema
    _ = try optString(alloc, payload, "beforeSessionId"); // optional anchor
    if (!std.mem.eql(u8, wid, default_workspace_id)) return error.WorkspaceNotFound;
    // Session ordering is not tracked in the v1 synthesized view.
    const view = try wsViewForSessions(deps, alloc, null);
    defer alloc.free(view);
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"workspace\":");
    try value.appendSlice(alloc, view);
    try value.appendSlice(alloc, "}");
    return okValue(alloc, rpc_id, value.items);
}

fn wsArchiveSessionDefault(alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    _ = try optString(alloc, payload, "sessionId"); // required by schema
    // Archive set is not persisted in v1 (documented limitation).
    return okValue(alloc, rpc_id, "{\"archivedSessionIds\":[]}");
}

// ── per-method handlers (all answer HTTP 200; errors ride result.error) ────

fn hSessionList(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    _ = try optString(alloc, payload, "cursor"); // reserved seat, unimplemented v1
    const sessions = try deps.listSessions(deps.ctx, alloc);
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"items\":[");
    for (sessions, 0..) |*s, i| {
        if (i > 0) try value.appendSlice(alloc, ",");
        try appendSessionSummaryJson(alloc, &value, s);
    }
    try value.appendSlice(alloc, "]}");
    return okValue(alloc, rpc_id, value.items);
}

fn hSessionSearch(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const query = try reqString(alloc, payload, "query");
    const page = try deps.searchSessions.?(deps.ctx, alloc, query);
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"items\":[");
    for (page.items, 0..) |it, i| {
        if (i > 0) try value.appendSlice(alloc, ",");
        try value.appendSlice(alloc, "{\"sessionId\":");
        try jsonx.appendJsonString(alloc, &value, it.session_id);
        try value.appendSlice(alloc, ",\"snippet\":");
        try jsonx.appendJsonString(alloc, &value, it.snippet);
        try value.appendSlice(alloc, "}");
    }
    try value.appendSlice(alloc, "],\"hasMore\":");
    try value.appendSlice(alloc, if (page.has_more) "true" else "false");
    try value.appendSlice(alloc, "}");
    return okValue(alloc, rpc_id, value.items);
}

fn hSessionCreate(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const opts = CreateOptions{
        .workspace_id = try optString(alloc, payload, "workspaceId"),
        .cwd = try optString(alloc, payload, "cwd"),
        .session_id = try optString(alloc, payload, "sessionId"),
        .agent_preset = try optString(alloc, payload, "agentPreset"),
    };
    // zod refine: workspaceId and cwd are mutually exclusive.
    if (opts.workspace_id != null and opts.cwd != null) {
        return badRequest(alloc, rpc_id, "session.create accepts workspaceId or cwd, not both");
    }
    const final_id = try deps.createSession(deps.ctx, alloc, opts);
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"sessionId\":");
    try jsonx.appendJsonString(alloc, &value, final_id);
    if (opts.agent_preset) |preset| {
        try value.appendSlice(alloc, ",\"agentPreset\":");
        try jsonx.appendJsonString(alloc, &value, preset);
    }
    try value.appendSlice(alloc, "}");
    return okValue(alloc, rpc_id, value.items);
}

/// Validates prompt content parts against promptContentPartSchema under the
/// zharness text-only policy (spec §7 drops attachments): every part must be
/// {type:'text',text:string}; image parts are rejected with a documented
/// bad-request rather than silently dropped.
fn promptContentValid(payload: []const u8) bool {
    const raw_arr = jsonx.getRaw(payload, "content") orelse return false;
    if (raw_arr.len < 2 or raw_arr[0] != '[' or raw_arr[raw_arr.len - 1] != ']') return false;
    const inner = raw_arr[1 .. raw_arr.len - 1];
    var seen: usize = 0;
    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ',' or inner[i] == ' ' or inner[i] == '\n' or inner[i] == '\t' or inner[i] == '\r')) : (i += 1) {}
        if (i >= inner.len) break;
        if (inner[i] != '{') return false;
        const end = jsonx.matchBraceFrom(inner, i) orelse return false;
        const part = inner[i..end];
        i = end;
        seen += 1;
        const t = jsonx.getRaw(part, "type") orelse return false;
        if (!std.mem.eql(u8, t, "\"text\"")) return false;
        const txt = jsonx.getRaw(part, "text") orelse return false;
        if (!jsonx.isString(txt)) return false;
    }
    return seen >= 1;
}

fn hSessionHistory(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const session_id = try reqString(alloc, payload, "sessionId");
    const before_seq_i = try optInt(payload, "beforeSeq");
    if (before_seq_i) |v| {
        if (v < 0) return error.PayloadInvalid;
    }
    const max_i = try optInt(payload, "maxMessages");
    if (max_i) |v| {
        if (v <= 0) return error.PayloadInvalid;
    }

    const page = try deps.sessionHistory(deps.ctx, alloc, session_id, before_seq_i, if (max_i) |v| @intCast(v) else null);
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"events\":[");
    for (page.entries, 0..) |e, i| {
        if (i > 0) try value.appendSlice(alloc, ",");
        try value.appendSlice(alloc, "{\"event\":");
        try value.appendSlice(alloc, e.event_json);
        if (e.view_json) |v| {
            try value.appendSlice(alloc, ",\"view\":");
            try value.appendSlice(alloc, v);
        }
        try value.appendSlice(alloc, "}");
    }
    try value.appendSlice(alloc, "],\"hasMore\":");
    try value.appendSlice(alloc, if (page.has_more) "true" else "false");
    if (page.projections_json) |proj| {
        try value.appendSlice(alloc, ",\"projections\":");
        try value.appendSlice(alloc, proj);
    }
    try value.appendSlice(alloc, "}");
    return okValue(alloc, rpc_id, value.items);
}

fn hSessionPrompt(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const session_id = try reqString(alloc, payload, "sessionId");
    const mode_raw = (try optString(alloc, payload, "mode")) orelse return error.PayloadInvalid;
    const mode = PromptMode.parse(mode_raw) orelse return error.PayloadInvalid;
    if (!promptContentValid(payload)) {
        return badRequest(alloc, rpc_id, "invalid content parts for session.prompt (text-only)");
    }
    const tz = try optString(alloc, payload, "clientTimeZone");

    const ack = try deps.promptSession(deps.ctx, alloc, .{
        .session_id = session_id,
        .mode = mode,
        .content_json = jsonx.getRaw(payload, "content").?,
        .client_time_zone = tz,
    });
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"accepted\":true");
    if (ack.command_text) |txt| {
        try value.appendSlice(alloc, ",\"command\":{\"kind\":\"success\",\"text\":");
        try jsonx.appendJsonString(alloc, &value, txt);
        try value.appendSlice(alloc, "}");
    }
    try value.appendSlice(alloc, "}");
    return okValue(alloc, rpc_id, value.items);
}

fn hSessionCancel(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const session_id = try reqString(alloc, payload, "sessionId");
    try deps.cancelSession(deps.ctx, alloc, session_id);
    return okValue(alloc, rpc_id, "{\"accepted\":true}");
}

fn hSessionRename(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const session_id = try reqString(alloc, payload, "sessionId");
    const title = (try optString(alloc, payload, "title")) orelse return error.PayloadInvalid;
    const res = try deps.renameSession(deps.ctx, alloc, session_id, title);
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"title\":");
    try jsonx.appendJsonString(alloc, &value, res.title);
    try value.appendSlice(alloc, ",\"seq\":");
    try jsonx.appendInt(alloc, &value, res.seq);
    try value.appendSlice(alloc, "}");
    return okValue(alloc, rpc_id, value.items);
}

fn hHostDescribe(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    _ = payload; // empty object literal per hostDescribeRequestSchema
    const sessions = try deps.listSessions(deps.ctx, alloc);
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"version\":");
    try jsonx.appendJsonString(alloc, &value, deps.version);
    try value.appendSlice(alloc, ",\"cwd\":");
    try jsonx.appendJsonString(alloc, &value, deps.cwd);
    if (deps.provider) |prov| {
        try value.appendSlice(alloc, ",\"provider\":");
        try jsonx.appendJsonString(alloc, &value, prov);
    }
    if (deps.model) |mod| {
        try value.appendSlice(alloc, ",\"model\":");
        try jsonx.appendJsonString(alloc, &value, mod);
    }
    try value.appendSlice(alloc, ",\"attachedSessions\":");
    try jsonx.appendInt(alloc, &value, @intCast(sessions.len));
    try value.appendSlice(alloc, ",\"home\":");
    try jsonx.appendJsonString(alloc, &value, deps.home);
    try value.appendSlice(alloc, ",\"canOpenPath\":");
    try value.appendSlice(alloc, if (deps.openPath != null) "true" else "false");
    try value.appendSlice(alloc, "}");
    return okValue(alloc, rpc_id, value.items);
}

fn hHostOpenPath(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    const path = try reqString(alloc, payload, "path");
    const open = deps.openPath orelse {
        return errValue(
            alloc,
            rpc_id,
            .directory_picker_unavailable,
            "openPath is not wired on this host",
            "{\"capability\":\"openPath\"}",
        );
    };
    try open(deps.ctx, alloc, path);
    return okValue(alloc, rpc_id, "{\"opened\":true}");
}

fn hSettingsDescribe(alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    _ = payload;
    // Read stub per spec §4: an empty document view — the settings mirror
    // degrades gracefully and the enter-behavior preference stays inert.
    return okValue(alloc, rpc_id, "{\"writable\":false,\"hasDocument\":false,\"namespaces\":[]}");
}

// ── dispatch ────────────────────────────────────────────────────────────────

pub const DispatchError = error{OutOfMemory};

/// Central error→response seam: handlers return plain errors (payload
/// validation, deps failures); this wrapper renders each onto the closed
/// code union so ONLY OutOfMemory escapes the router. Hints for the
/// code-specific details objects are pulled from the request payload.
fn run(
    alloc: std.mem.Allocator,
    env: *const Envelope,
    result: anyerror!UnaryResponse,
) anyerror!UnaryResponse {
    return result catch |e| switch (e) {
        error.PayloadInvalid => blk: {
            const msg = std.fmt.allocPrint(
                alloc,
                "invalid payload for {s}",
                .{env.method},
            ) catch return error.OutOfMemory;
            break :blk try badRequest(alloc, env.rpc_id, msg);
        },
        error.OutOfMemory => error.OutOfMemory,
        else => try mapDepsError(alloc, env.rpc_id, e, env.payload_raw),
    };
}

/// Route one parsed unary envelope by method name. ALWAYS answers HTTP 200
/// carrying result.ok=true or result.ok=false+error (spec §4); unknown
/// methods answer the bad-request error shape (documented deviation from
/// upstream's bare carrier-level 404). Error contract: only OutOfMemory
/// escapes as an error — every business failure is rendered in-band.
pub fn dispatch(
    deps: *const ApiProxyDeps,
    alloc: std.mem.Allocator,
    env: *const Envelope,
) anyerror!UnaryResponse {
    const m = env.method;
    const p = env.payload_raw;

    // sessions domain
    if (std.mem.eql(u8, m, "session.list")) return run(alloc, env, hSessionList(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "session.search")) {
        if (deps.searchSessions == null) {
            return internalError(alloc, env.rpc_id, "session.search is not implemented on this host");
        }
        return run(alloc, env, hSessionSearch(deps, alloc, env.rpc_id, p));
    }
    if (std.mem.eql(u8, m, "session.create")) return run(alloc, env, hSessionCreate(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "session.history")) return run(alloc, env, hSessionHistory(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "session.prompt")) return run(alloc, env, hSessionPrompt(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "session.cancel")) return run(alloc, env, hSessionCancel(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "session.rename")) return run(alloc, env, hSessionRename(deps, alloc, env.rpc_id, p));

    // host domain
    if (std.mem.eql(u8, m, "host.describe")) return run(alloc, env, hHostDescribe(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "host.openPath")) return run(alloc, env, hHostOpenPath(deps, alloc, env.rpc_id, p));

    // workspace domain (built-in single-workspace defaults)
    if (std.mem.eql(u8, m, "workspace.list")) return run(alloc, env, wsListDefault(deps, alloc, env.rpc_id));
    if (std.mem.eql(u8, m, "workspace.create")) return run(alloc, env, wsCreateDefault(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "workspace.rename")) return run(alloc, env, wsRenameDefault(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "workspace.delete")) return run(alloc, env, wsDeleteDefault(alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "workspace.insertBefore")) return run(alloc, env, wsInsertBeforeDefault(alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "workspace.insertSessionBefore")) return run(alloc, env, wsInsertSessionBeforeDefault(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "workspace.archiveSession")) return run(alloc, env, wsArchiveSessionDefault(alloc, env.rpc_id, p));

    // settings domain (read stub only)
    if (std.mem.eql(u8, m, "settings.describe")) return run(alloc, env, hSettingsDescribe(alloc, env.rpc_id, p));

    return badRequest(alloc, env.rpc_id, "unknown method");
}

// ── carrier glue (httpd.Handler adapter) ───────────────────────────────────

pub const HandleError = error{MissingDeps};

fn apiHandle(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    req: *const httpd.Request,
    res: *httpd.Responder,
) anyerror!void {
    const deps: *const ApiProxyDeps = @ptrCast(@alignCast(ctx orelse return error.MissingDeps));
    return handleApiRequest(deps, alloc, req, res);
}

/// Build the httpd.Handler that mounts this apiproxy (ServerDeps pattern).
/// Remember `threaded_connections = true`: WebSocket downlinks occupy their
/// connection threads for the life of each stream.
pub fn handler(deps: *const ApiProxyDeps) httpd.Handler {
    return .{ .ctx = @constCast(deps), .call = apiHandle };
}

/// Full /api surface: unary POST envelope routing, the /api/respond receipt
/// stub, and the two downstream WebSocket streams. Paths outside /api/ get
/// upstream's carrier-level 404 text response.
pub fn handleApiRequest(
    deps: *const ApiProxyDeps,
    alloc: std.mem.Allocator,
    req: *const httpd.Request,
    res: *httpd.Responder,
) anyerror!void {
    if (!std.mem.startsWith(u8, req.path, "/api/")) {
        return res.send(.not_found, .text, "not found");
    }

    // Downstream streams (GET upgrades).
    if (std.mem.eql(u8, req.path, "/api/events.mux") or std.mem.eql(u8, req.path, "/api/events.host")) {
        const upg = httpd.WsUpgrade.fromRequest(req) catch {
            return res.send(.bad_request, .text, "websocket upgrade required");
        };
        var conn = res.startWebSocket(&upg) catch |e| switch (e) {
            error.HandshakeWriteFailed => return error.WriteFailed,
            error.SocketSetupFailed => return error.SocketSetupFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        _ = &conn;
        if (std.mem.eql(u8, req.path, "/api/events.mux")) {
            return events_ws.serveMuxStream(alloc, &conn);
        }
        return events_ws.serveHostStream(alloc, &conn);
    }

    if (!std.mem.eql(u8, req.method, "POST")) {
        // Upstream parity: anything but the SSE GETs and unary POSTs is 404.
        return res.send(.not_found, .text, "not found");
    }

    const seg = req.path["/api/".len..];

    // Answerable-push receipt stub: zharness emits no approvals/questions, so
    // nothing is ever pending (spec §4).
    if (std.mem.eql(u8, seg, "respond")) {
        const is_client_response = blk: {
            const t = jsonx.getRaw(req.body, "type") orelse break :blk false;
            break :blk std.mem.eql(u8, t, "\"client-response\"");
        };
        const has_result = jsonx.getRaw(req.body, "result") != null;
        if (is_client_response and has_result) {
            return res.send(.ok, .json, "{\"accepted\":false,\"reason\":\"not-pending\"}");
        }
        return res.send(.ok, .json, "{\"accepted\":false,\"reason\":\"bad-response\"}");
    }

    // Cross-site write fence (upstream fetch/handler.ts): only application/
    // json passes without a CORS preflight this server never answers.
    if (req.header("content-type")) |ct| {
        var media = ct;
        if (std.mem.indexOfScalar(u8, media, ';')) |semi| media = media[0..semi];
        media = std.mem.trim(u8, media, " \t");
        if (!std.ascii.eqlIgnoreCase(media, "application/json")) {
            return res.send(.unsupported_media_type, .text, "content type must be application/json");
        }
    } else {
        return res.send(.unsupported_media_type, .text, "content type must be application/json");
    }

    const env = parseEnvelope(alloc, req.body) catch |e| switch (e) {
        error.NotJson => return res.send(.bad_request, .text, "body is not JSON"),
        error.OutOfMemory => return error.OutOfMemory,
    } orelse {
        // Valid JSON, wrong envelope: salvage a string rpcId or use the
        // documented sentinel, and report inside the ServerResponse form.
        const salvaged = (jsonx.getStringAlloc(alloc, req.body, "rpcId") catch null) orelse invalid_request_rpc_id;
        const resp = try badRequest(alloc, salvaged, "invalid client-request message");
        return res.send(resp.status, .json, resp.body);
    };

    if (!std.mem.eql(u8, env.method, seg)) {
        var msg_buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "method \"{s}\" does not match path \"{s}\"", .{ env.method, seg }) catch "method does not match path";
        const resp = try badRequest(alloc, env.rpc_id, msg);
        return res.send(resp.status, .json, resp.body);
    }

    const resp = try dispatch(deps, alloc, &env);
    return res.send(resp.status, .json, resp.body);
}
