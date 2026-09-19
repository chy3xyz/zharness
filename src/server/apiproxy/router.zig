//! DSH apiproxy unary router — the four-quadrant RPC envelope over
//! `POST /api/<method>` (docs/dsh-reuse-spec.md §4; contract truth:
//! `_ref/deepseek-harness/packages/host/apiproxy/src/api/*.schema.ts`).
//!
//! Wire contract (§4, byte-exact fixtures in test/_t_apiproxy.zig):
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
const remote_mux = @import("remote_mux.zig");
const questions = @import("questions.zig");
const subagents_rpc = @import("subagents_rpc.zig");
const jobs_rpc = @import("jobs_rpc.zig");
const trajectory = @import("trajectory.zig");
const wf_replay = @import("wf_replay.zig");
const export_rpc = @import("export_rpc.zig");
const config = @import("../../config.zig");
const events_ws = @import("events_ws.zig");
const clib = @import("../../clib.zig");

// Dynamic Cordis runtime (src/dynamic/*): browser-half host endpoints +
// the cordis leg of POST /api/respond (see dyn_wire below).
const dyn_lifecycle = @import("../../dynamic/lifecycle.zig");
const dyn_registry = @import("../../dynamic/registry.zig");
const dyn_sandbox = @import("../../dynamic/sandbox.zig");
const dyn_wire = @import("../../dynamic/wire.zig");

// ── Tier-1 RPC domains (wave 6, G1-tier1) ──────────────────────────────────
const goals_rpc = @import("goals_rpc.zig");
const skills_rpc = @import("skills_rpc.zig");
const models_rpc = @import("models_rpc.zig");
const presets_rpc = @import("presets_rpc.zig");
const perms_rpc = @import("perms_rpc.zig");

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
    /// settings write rejected (validation / read-only credential) —
    /// upstream `settings-rejected` (settings.ts SettingsApi docs).
    settings_rejected,
    /// stale expectedRevision on a settings write — upstream
    /// `settings-conflict` (the Models editor keys its conflict copy on it).
    settings_conflict,
    /// unknown provider route on session.selectModel — upstream
    /// `model-unavailable` ({provider,model} details).
    model_unavailable,
    /// agentPreset.select named an unlisted preset — upstream
    /// `agent-preset-not-found`.
    agent_preset_not_found,
    /// agentPreset.select on a session whose first turn already ran —
    /// upstream `agent-preset-locked`.
    agent_preset_locked,

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
            .settings_rejected => "settings-rejected",
            .settings_conflict => "settings-conflict",
            .model_unavailable => "model-unavailable",
            .agent_preset_not_found => "agent-preset-not-found",
            .agent_preset_locked => "agent-preset-locked",
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
    /// Browser submission identity; the durable user/message must echo it as
    /// `source.rpcId` or the client never retires its local echo bubble.
    request_id: ?[]const u8 = null,
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

/// Settings-domain dep signatures. `describe` returns the full
/// settings.describe VALUE JSON; write handlers return the namespace-view
/// VALUE JSON (both wrapped into ok:true by the router). Errors map through
/// mapSettingsError (settings-conflict / settings-rejected / internal).
pub const SettingsDescribeFn = *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]u8;
pub const SettingsWriteFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    payload: []const u8,
) anyerror![]u8;
/// llm.providers value builder for the Models section join.
pub const LlmProvidersFn = *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]u8;
/// credentials.describe ({refs:[…]}) → {credentials:{…}} value JSON.
pub const CredentialsDescribeFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    payload: []const u8,
) anyerror![]u8;
/// credentials.set/unset → {} value JSON.
pub const CredentialsWriteFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    payload: []const u8,
) anyerror!void;
/// pluginInventory/list VALUE builder (vendored GUI Plugins-settings
/// inventory tab) — fresh scan of both plugin registries; see inventory.zig.
pub const PluginInventoryFn = *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]u8;

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

    // Settings domain (null ⇒ legacy stub / not-implemented, or the
    // module-level `default_settings_store` when installed — see
    // installDefaultSettings; the integrator decides which seam to keep).
    settingsDescribe: ?SettingsDescribeFn = null,
    settingsUpdate: ?SettingsWriteFn = null,
    settingsMutate: ?SettingsWriteFn = null,
    settingsReplace: ?SettingsWriteFn = null,
    llmProviders: ?LlmProvidersFn = null,
    credentialsDescribe: ?CredentialsDescribeFn = null,
    credentialsSet: ?CredentialsWriteFn = null,
    credentialsUnset: ?CredentialsWriteFn = null,
    pluginInventoryList: ?PluginInventoryFn = null,
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
/// Repair a JSON response body: walk the string tracking JSON structure
/// (inside/outside string, escape state). Fix:
///   1. Raw control chars (< 0x20) inside strings → space
///   2. Invalid UTF-8 (orphan continuation, bad start) → '?'
///   3. Unescaped quotes inside strings that would prematurely close → \"
/// The repair is conservative: it only fixes, never restructures.
fn sanitizeResponseBody(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    // First check if the body is already valid by trying a structural scan.
    var needs_fix = false;
    var i: usize = 0;
    var in_str = false;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (in_str) {
            if (c == '\\') { i += 1; continue; }
            if (c == '"') in_str = false;
            if (c < 0x20) { needs_fix = true; break; }
        } else {
            switch (c) {
                '"' => in_str = true,
                else => {},
            }
        }
    }
    // Structural check: braces and brackets must balance (outside strings).
    if (!needs_fix) {
        var depth_brace: i32 = 0;
        var depth_bracket: i32 = 0;
        var in_s = false;
        var si: usize = 0;
        while (si < body.len) : (si += 1) {
            const bc = body[si];
            if (in_s) {
                if (bc == '\\') { si += 1; continue; }
                if (bc == '"') in_s = false;
            } else {
                if (bc == '"') { in_s = true; continue; }
                if (bc == '{') depth_brace += 1;
                if (bc == '}') depth_brace -= 1;
                if (bc == '[') depth_bracket += 1;
                if (bc == ']') depth_bracket -= 1;
                if (depth_brace < 0 or depth_bracket < 0) { needs_fix = true; break; }
            }
        }
        if (in_s or depth_brace != 0 or depth_bracket != 0) needs_fix = true;
    }
    if (!needs_fix and !in_str) return body; // clean close

    // Repair pass: track state and fix issues.
    const out = try alloc.dupe(u8, body);
    var oi: usize = 0; // write index (can lag behind i for removals)
    i = 0;
    in_str = false;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (in_str) {
            if (c == '\\' and i + 1 < body.len) {
                // Escaped char: copy both bytes
                out[oi] = body[i]; oi += 1;
                i += 1;
                out[oi] = body[i]; oi += 1;
                continue;
            }
            if (c == '"') {
                in_str = false;
                out[oi] = c; oi += 1;
                continue;
            }
            if (c < 0x20) {
                // Raw control char inside string → space
                out[oi] = ' '; oi += 1;
                continue;
            }
            // Check for invalid UTF-8
            if (c >= 0x80 and c <= 0xBF) { out[oi] = '?'; oi += 1; continue; }
            if (c >= 0xF8) { out[oi] = '?'; oi += 1; continue; }
            if (c >= 0xC0) {
                const len: usize = if (c >= 0xF0) 4 else if (c >= 0xE0) 3 else 2;
                if (i + len <= body.len) {
                    var ok = true;
                    var k: usize = 1;
                    while (k < len) : (k += 1) {
                        if (body[i+k] & 0xC0 != 0x80) ok = false;
                    }
                    if (ok) {
                        @memcpy(out[oi..oi+len], body[i..i+len]);
                        oi += len; i += len - 1; // -1 because loop increments
                        continue;
                    }
                }
                out[oi] = '?'; oi += 1;
                continue;
            }
            // Normal char inside string
            out[oi] = c; oi += 1;
        } else {
            // Outside string
            if (c == '"') {
                in_str = true;
                out[oi] = c; oi += 1;
                continue;
            }
            // Check for invalid UTF-8 outside strings (shouldn't happen in JSON)
            if (c >= 0x80 and c <= 0xBF) { out[oi] = '?'; oi += 1; continue; }
            if (c >= 0xF8) { out[oi] = '?'; oi += 1; continue; }
            out[oi] = c; oi += 1;
        }
    }
    return out[0..oi];
}

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

pub fn internalError(alloc: std.mem.Allocator, rpc_id: []const u8, message: []const u8) !UnaryResponse {
    return errValue(alloc, rpc_id, .internal, message, "{}");
}

/// Lazy settings-store accessor shared with the Tier-1 RPC domain modules
/// (goals/skills/models/presets/perms). Installs the process store on first
/// use from ApiProxyDeps.home; null without a home.
pub fn settingsStoreOf(home: []const u8) ?*apx_settings.Store {
    if (default_settings_store) |s| return s;
    if (home.len == 0) return null;
    return installDefaultSettings(std.heap.c_allocator, home) catch null;
}

/// Test hook: detach the singleton so a later installDefaultSettings /
/// settingsStoreOf call binds a fresh home (the previous store leaks by
/// design — process lifetime).
pub fn resetSettingsStoreForTests() void {
    default_settings_store = null;
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

extern "c" fn clock_gettime(clk_id: c_int, tp: *std.c.timespec) c_int;
fn nowMsValue() i64 {
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(0, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// session.create + announce: after a successful create, forward the
/// `api-session/added` cordis event onto the $events streams — the GUI's
/// session store learns new sessions exclusively through that event.
fn sessionCreateAndAnnounce(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    if (std.c.getenv("ZH_DEBUG_RPC") != null)
        std.debug.print("[announce] wrapper entered\n", .{});
    const resp = try hSessionCreate(deps, alloc, rpc_id, payload);
    if (std.c.getenv("ZH_DEBUG_RPC") != null)
        std.debug.print("[announce] resp body: {s}\n", .{resp.body[0..@min(resp.body.len, 220)]});
    // Salvage the created id from the ok-value ({"sessionId":…}); the body is
    // the full server-response envelope, so descend through "result".
    const result = jsonx.getRaw(resp.body, "result") orelse return resp;
    const value_raw = jsonx.getRaw(result, "value") orelse return resp;
    const sid = (jsonx.getStringAlloc(alloc, value_raw, "sessionId") catch null) orelse return resp;
    defer alloc.free(sid);

    var sid_j: std.ArrayList(u8) = .empty;
    defer sid_j.deinit(alloc);
    jsonx.appendJsonString(alloc, &sid_j, sid) catch return resp;

    const emit = std.fmt.allocPrint(alloc, "{{\"type\":\"emit\",\"event\":\"api-session/added\",\"args\":[{{\"sessionId\":{s},\"updatedAt\":{d},\"running\":false,\"blank\":true}}]}}", .{ sid_j.items, nowMsValue() }) catch return resp;
    defer alloc.free(emit);
    remote_mux.publishEvents(alloc, emit);

    // Model-selection projection for the new session: the composer's model
    // seat waits for this row; absent it renders "loading models" forever and
    // the input stays gated. Default = the host's configured route.
    var sid_j2: std.ArrayList(u8) = .empty;
    defer sid_j2.deinit(alloc);
    jsonx.appendJsonString(alloc, &sid_j2, sid) catch return resp;
    const proj_frame = std.fmt.allocPrint(alloc, "{{\"type\":\"projection\",\"sessionId\":{s},\"key\":\"modelSelection\",\"value\":{{\"lastUsed\":{{\"provider\":\"deepseek\",\"model\":\"deepseek-v4-flash\"}},\"pending\":null}},\"seq\":1}}", .{ sid_j2.items }) catch return resp;
    defer alloc.free(proj_frame);
    remote_mux.publishControlRaw(proj_frame);

    // Workspace membership: the created session joins the single workspace;
    // workspace.follow streams receive the refreshed upsert so the picker
    // chip resolves and the composer binds.
    remote_mux.publishWorkspaceUpsertFromDir(alloc);
    return resp;
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

/// session.page (v0.1.6 paged history): remaps the upstream request
/// {address:{sessionId}, throughSeq, beforeSeq?, maxMessages?} onto the
/// session.history handler (flat sessionId + beforeSeq + maxMessages).
fn hSessionPage(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    var address = jsonx.getRaw(payload, "address") orelse return error.PayloadInvalid;
    if (jsonx.getRaw(address, "sessionId")) |_| {} else {
        if (jsonx.getRaw(payload, "request")) |req| {
            if (jsonx.getRaw(req, "address")) |a2| address = a2;
        }
    }
    const sid_raw = jsonx.getRaw(address, "sessionId") orelse return error.PayloadInvalid;
    if (!jsonx.isString(sid_raw)) return error.PayloadInvalid;
    const session_id = try jsonx.decodeString(alloc, sid_raw[1 .. sid_raw.len - 1]);
    defer alloc.free(session_id);

    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(alloc);
    try flat.appendSlice(alloc, "{\"sessionId\":");
    try flat.appendSlice(alloc, sid_raw);
    if (jsonx.getInt(payload, "throughSeq")) |through| {
        try flat.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"throughSeq\":{d}", .{through}));
    }
    if (jsonx.getInt(payload, "beforeSeq")) |before| {
        try flat.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"beforeSeq\":{d}", .{before}));
    }
    if (jsonx.getInt(payload, "maxMessages")) |max| {
        try flat.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"maxMessages\":{d}", .{max}));
    }
    try flat.append(alloc, '}');
    return hSessionHistory(deps, alloc, rpc_id, flat.items);
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
    try value.appendSlice(alloc, "{\"records\":[");
    for (page.entries, 0..) |e, i| {
        if (i > 0) try value.appendSlice(alloc, ",");
        try value.appendSlice(alloc, "{\"type\":\"event\",\"event\":");
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
    // Image parts allowed (attachments.zig validates text+image parts; the
    // apiproxy/attachments pipeline persists them before the run starts).
    const attachments = @import("attachments.zig");
    if (!attachments.contentPartsValid(jsonx.getRaw(payload, "content") orelse "[]")) {
        return badRequest(alloc, rpc_id, "invalid content parts for session.prompt");
    }
    const tz = try optString(alloc, payload, "clientTimeZone");

    const ack = try deps.promptSession(deps.ctx, alloc, .{
        .session_id = session_id,
        .mode = mode,
        .content_json = jsonx.getRaw(payload, "content").?,
        .client_time_zone = tz,
        .request_id = try optString(alloc, payload, "requestId"),
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

fn hSettingsDescribe(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    _ = payload; // {} per settingsDescribeRequestSchema
    var base: []u8 = undefined;
    if (deps.settingsDescribe) |f| {
        base = try f(deps.ctx, alloc);
    } else if (settingsStoreOf(deps.home)) |s| {
        base = try apx_settings.describeValue(s, alloc, apx_settings.collectEnv());
    } else {
        // Legacy read stub per spec §4 (no settings store installed): an empty
        // document view EXCEPT the ui-onboarding row, which stays
        // PRE-ACKNOWLEDGED at the vendored GUI's current notice version
        // (ui-settings-models/onboarding-copy.ts). Its WelcomeNotice modal gates
        // the whole composer behind an acknowledgement write; without a write
        // path an unacknowledged document would render an overlay no user can
        // ever dismiss. The scope binds a verbatim-object decoder
        // (decodeWelcomeSection), so this bare row validates without a schema.
        base = @constCast("{\"writable\":false,\"hasDocument\":true,\"namespaces\":[" ++
            "{\"ns\":\"ui-onboarding\",\"schema\":null," ++
            "\"value\":{\"welcomeNoticeVersion\":\"" ++ onboarding_notice_version ++ "\"}," ++
            "\"applies\":\"live\",\"secrets\":[],\"revision\":1}" ++
            "]}");
    }
    // Tier-1 GUI rows ride along: permission presets + agent-preset default.
    const augmented = try augmentDescribeValue(deps, alloc, base);
    return okValue(alloc, rpc_id, augmented);
}

// ── settings domain (real config.toml backend) ──────────────────────────────
//
// Built-in backend over ~/.zharness/config.toml via apiproxy/settings.zig.
// Precedence: an explicit ApiProxyDeps fn pointer wins; otherwise the module
// store below serves REAL config.toml-backed answers once installed via
// installDefaultSettings(); with neither, describe falls back to the legacy
// ui-onboarding stub above and every other settings method reports
// not-implemented.
//
// INTERIM NOTE FOR THE INTEGRATOR: installDefaultSettings() exists so the GUI
// works without touching main.zig while another agent owns that file. The
// final wiring should either keep the one-line call in serve startup OR move
// to explicit deps pointers — both are shown in docs/settings.md.

const apx_settings = @import("settings.zig");

/// The vendored GUI's current WelcomeNotice version (onboarding-copy.ts).
/// Single source: apiproxy/settings.zig owns the constant.
const onboarding_notice_version = apx_settings.onboarding_notice_version;

/// Module-level store used when no explicit deps pointer overrides a method.
var default_settings_store: ?*apx_settings.Store = null;

/// Create the process-wide settings store backed by `<home>/.zharness/
/// config.toml`. Idempotent; returns the existing store on re-entry.
/// Process-lifetime singleton on the C allocator (it outlives any request
/// arena and must not leak into one).
pub fn installDefaultSettings(gpa: std.mem.Allocator, home: []const u8) !*apx_settings.Store {
    _ = gpa;
    if (default_settings_store) |s| return s;
    const s = try std.heap.c_allocator.create(apx_settings.Store);
    errdefer std.heap.c_allocator.destroy(s);
    try s.initInPlace(std.heap.c_allocator, home);
    default_settings_store = s;
    return s;
}

/// Map settings-backend errors onto the RPC error vocabulary.
fn mapSettingsError(alloc: std.mem.Allocator, rpc_id: []const u8, err: anyerror) !UnaryResponse {
    switch (err) {
        error.UnknownNamespace => return errValue(
            alloc,
            rpc_id,
            .settings_rejected,
            "unknown settings namespace",
            "{}",
        ),
        error.UnknownField => return errValue(
            alloc,
            rpc_id,
            .settings_rejected,
            "unknown settings field",
            "{\"issues\":[]}",
        ),
        error.BadValueType => return errValue(
            alloc,
            rpc_id,
            .settings_rejected,
            "value type does not match the namespace schema",
            "{\"issues\":[]}",
        ),
        error.RevisionConflict => return errValue(
            alloc,
            rpc_id,
            .settings_conflict,
            "settings were changed elsewhere; reload and retry",
            "{}",
        ),
        error.WriteFailed => return internalError(alloc, rpc_id, "failed to persist config.toml"),
        error.CredentialReadOnly => return errValue(
            alloc,
            rpc_id,
            .settings_rejected,
            "credential is provided by the environment and cannot be edited here",
            "{}",
        ),
        error.CredentialRefUnknown => return errValue(
            alloc,
            rpc_id,
            .settings_rejected,
            "credential reference is not managed by zharness",
            "{}",
        ),
        else => {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "settings failure: {s}", .{@errorName(err)}) catch "settings failure";
            return internalError(alloc, rpc_id, msg);
        },
    }
}

/// Translate a validateOp/kvFor domain rejection into handler errors that run()'s
/// mapper renders in-band (only PayloadInvalid/OutOfMemory pass through raw).
fn mapOpError(e: anyerror) anyerror {
    return switch (e) {
        error.UnknownNamespace, error.UnknownField, error.BadValueType => error.SettingsRejected,
        error.RevisionConflict => error.SettingsConflict,
        error.PathTooDeep => error.PayloadInvalid,
        error.OutOfMemory => error.OutOfMemory,
        else => e,
    };
}

/// Parse `expectedRevision` from a settings write payload (optional int).
fn expectedRevisionOf(payload: []const u8) ?i64 {
    return jsonx.getInt(payload, "expectedRevision");
}

/// One validated write op ready for commitKvs.
const PendingOp = struct {
    ns_id: usize,
    kv: config.ConfigKv,
};

fn parseTomlValueRaw(alloc: std.mem.Allocator, raw: []const u8) !config.TomlValue {
    return apx_settings.tomlFromJsonRaw(alloc, raw) catch |e| switch (e) {
        error.BadValueType => error.PayloadInvalid,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Convert one raw JSON value slice into a TomlValue — see parseTomlValueRaw.
fn opsFromPatch(alloc: std.mem.Allocator, payload: []const u8, ns: []const u8, out: *std.ArrayList(PendingOp)) !void {
    const patch_raw = jsonx.getRaw(payload, "patch") orelse return error.PayloadInvalid;
    if (!isJsonObjectRaw(patch_raw)) return error.PayloadInvalid;
    const body = jsonx.objectBody(patch_raw).?;
    var it = jsonx.MemberIter.init(body);
    while (it.next()) |m| {
        const key = try jsonx.decodeString(alloc, m.key);
        const val = try parseTomlValueRaw(alloc, m.value);
        const ns_id = apx_settings.validateOp(ns, key, val) catch |e| return mapOpError(e);
        const kv = apx_settings.kvFor(ns_id, key, val) catch |e| return mapOpError(e);
        try out.append(alloc, .{ .ns_id = ns_id, .kv = kv });
    }
}

fn asciiWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Raw JSON type probes (jsonx keeps only isString).
fn isJsonObjectRaw(raw: []const u8) bool {
    const t = jsonx.trimWs(raw);
    return t.len >= 2 and t[0] == '{' and t[t.len - 1] == '}';
}

fn isJsonArrayRaw(raw: []const u8) bool {
    const t = jsonx.trimWs(raw);
    return t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']';
}

/// First path segment of `["a","b",…]` (decoded), or null when empty/malformed.
fn firstPathSegment(alloc: std.mem.Allocator, arr_raw: []const u8) ?[]const u8 {
    const inner = arr_raw[1 .. arr_raw.len - 1];
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |seg_raw| {
        const seg = jsonx.trimWs(seg_raw);
        if (seg.len == 0) continue;
        if (!jsonx.isString(seg)) return null;
        return jsonx.decodeString(alloc, seg[1 .. seg.len - 1]) catch null;
    }
    return null;
}

/// Whether the path array carries more than one segment (v1 fields are
/// top-level scalars; deeper paths are rejected as bad-request).
fn pathHasSecondSegment(arr_raw: []const u8) bool {
    const inner = arr_raw[1 .. arr_raw.len - 1];
    var seen_first = false;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |seg_raw| {
        const seg = jsonx.trimWs(seg_raw);
        if (seg.len == 0) continue;
        if (seen_first) return true;
        seen_first = true;
    }
    return false;
}

/// Build the pending edit list for settings.mutate ({ns, ops:[…]}).
fn opsFromMutate(alloc: std.mem.Allocator, payload: []const u8, ns: []const u8, out: *std.ArrayList(PendingOp)) !void {
    const ops_raw = jsonx.getRaw(payload, "ops") orelse return error.PayloadInvalid;
    if (!isJsonArrayRaw(ops_raw)) return error.PayloadInvalid;
    const body = ops_raw[1 .. ops_raw.len - 1];
    var i: usize = 0;
    while (i < body.len) {
        while (i < body.len and (body[i] == ',' or asciiWs(body[i]))) : (i += 1) {}
        if (i >= body.len) break;
        if (body[i] != '{') return error.PayloadInvalid;
        const end = jsonx.matchBraceFrom(body, i) orelse return error.PayloadInvalid;
        const op = body[i..end];
        i = end;

        const kind_raw = jsonx.getRaw(op, "op") orelse return error.PayloadInvalid;
        const is_set = std.mem.eql(u8, kind_raw, "\"set\"");
        const is_unset = std.mem.eql(u8, kind_raw, "\"unset\"");
        if (!is_set and !is_unset) return error.PayloadInvalid;

        const path_raw = jsonx.getRaw(op, "path") orelse return error.PayloadInvalid;
        if (!isJsonArrayRaw(path_raw)) return error.PayloadInvalid;
        const first = firstPathSegment(alloc, path_raw) orelse return error.PayloadInvalid;
        if (pathHasSecondSegment(path_raw)) return error.PathTooDeep;

        const val: ?config.TomlValue = if (is_set)
            try parseTomlValueRaw(alloc, jsonx.getRaw(op, "value") orelse return error.PayloadInvalid)
        else
            null;
        const ns_id = apx_settings.validateOp(ns, first, val) catch |e| return mapOpError(e);
        const kv = apx_settings.kvFor(ns_id, first, val) catch |e| return mapOpError(e);
        try out.append(alloc, .{ .ns_id = ns_id, .kv = kv });
    }
}

fn namespaceIdOf(ns: []const u8) ?usize {
    if (std.mem.eql(u8, ns, "agent")) return apx_settings.Store.ns_agent;
    if (std.mem.eql(u8, ns, "llm-deepseek")) return apx_settings.Store.ns_llm_deepseek;
    if (std.mem.eql(u8, ns, "ui-theme")) return apx_settings.Store.ns_theme;
    if (std.mem.eql(u8, ns, "locale")) return apx_settings.Store.ns_locale;
    if (std.mem.eql(u8, ns, "ui-onboarding")) return apx_settings.Store.ns_onboarding;
    return null;
}

/// Shared write pipeline behind update/mutate: parse ops, commit through the
/// store, answer with the new namespace view (settingsNamespaceViewSchema).
fn settingsWrite(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8, mode: enum { update, mutate }) !UnaryResponse {
    var pending: std.ArrayList(PendingOp) = .empty;
    defer pending.deinit(alloc);
    const ns = try reqString(alloc, payload, "ns");
    switch (mode) {
        .update => try opsFromPatch(alloc, payload, ns, &pending),
        .mutate => try opsFromMutate(alloc, payload, ns, &pending),
    }

    const answer_ns = namespaceIdOf(ns) orelse return mapOpError(error.UnknownNamespace);

    const s = settingsStoreOf(deps.home) orelse return internalError(alloc, rpc_id, "settings are not implemented on this host");
    var kvs: std.ArrayList(config.ConfigKv) = .empty;
    defer kvs.deinit(alloc);
    var ns_ids: std.ArrayList(usize) = .empty;
    defer ns_ids.deinit(alloc);
    for (pending.items) |p| {
        try kvs.append(alloc, p.kv);
        try ns_ids.append(alloc, p.ns_id);
    }
    if (kvs.items.len == 0) {
        // No-op writes still fence and answer with a fresh view.
        try ns_ids.append(alloc, answer_ns);
    }
    const view = apx_settings.commitKvs(
        s,
        alloc,
        kvs.items,
        ns_ids.items,
        answer_ns,
        expectedRevisionOf(payload),
        apx_settings.collectEnv(),
    ) catch |e| return mapOpError(e);
    return okValue(alloc, rpc_id, view);
}

fn hSettingsUpdate(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    // Tier-1 GUI pseudo-namespaces ride before the generic store path.
    if (reqString(alloc, payload, "ns") catch null) |ns| {
        if (customSpecOf(ns)) |spec| {
            return customNamespaceWrite(deps, alloc, rpc_id, payload, .update, spec);
        }
    }
    if (deps.settingsUpdate) |f| {
        return okValue(alloc, rpc_id, try f(deps.ctx, alloc, payload));
    }
    return settingsWrite(deps, alloc, rpc_id, payload, .update);
}

fn hSettingsMutate(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    if (reqString(alloc, payload, "ns") catch null) |ns| {
        if (customSpecOf(ns)) |spec| {
            return customNamespaceWrite(deps, alloc, rpc_id, payload, .mutate, spec);
        }
    }
    if (deps.settingsMutate) |f| {
        return okValue(alloc, rpc_id, try f(deps.ctx, alloc, payload));
    }
    return settingsWrite(deps, alloc, rpc_id, payload, .mutate);
}

/// settings.replace: reset semantics — clear every known field of the
/// namespace first, then apply what `section` carries (clears-first mutate).
fn hSettingsReplace(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    if (reqString(alloc, payload, "ns") catch null) |ns| {
        if (customSpecOf(ns)) |spec| {
            return customNamespaceWrite(deps, alloc, rpc_id, payload, .replace, spec);
        }
    }
    if (deps.settingsReplace) |f| {
        return okValue(alloc, rpc_id, try f(deps.ctx, alloc, payload));
    }
    const ns = try reqString(alloc, payload, "ns");
    if (namespaceIdOf(ns) == null) return mapOpError(error.UnknownNamespace);
    const known: []const []const u8 = blk: {
        if (std.mem.eql(u8, ns, "llm-deepseek")) break :blk &.{ "baseURL", "models" };
        if (std.mem.eql(u8, ns, "ui-theme") or std.mem.eql(u8, ns, "locale")) break :blk &.{"preference"};
        break :blk &.{ "provider", "model", "maxTurns", "reasoningEffort", "stream", "sandboxMode" };
    };
    var merged: std.ArrayList(u8) = .empty;
    defer merged.deinit(alloc);
    try merged.appendSlice(alloc, "{\"ns\":");
    try jsonx.appendJsonString(alloc, &merged, ns);
    try merged.appendSlice(alloc, ",\"ops\":[");
    for (known, 0..) |f, i| {
        if (i > 0) try merged.append(alloc, ',');
        try merged.appendSlice(alloc, "{\"op\":\"unset\",\"path\":[\"");
        try merged.appendSlice(alloc, f);
        try merged.appendSlice(alloc, "\"]}");
    }
    const section_raw = jsonx.getRaw(payload, "section") orelse return error.PayloadInvalid;
    if (!isJsonObjectRaw(section_raw)) return error.PayloadInvalid;
    const body = jsonx.objectBody(section_raw).?;
    var it = jsonx.MemberIter.init(body);
    while (it.next()) |m| {
        const key = try jsonx.decodeString(alloc, m.key);
        try merged.appendSlice(alloc, ",{\"op\":\"set\",\"path\":[\"");
        try merged.appendSlice(alloc, key);
        try merged.appendSlice(alloc, "\"],\"value\":");
        try merged.appendSlice(alloc, m.value);
        try merged.append(alloc, '}');
    }
    try merged.appendSlice(alloc, "]}");
    if (expectedRevisionOf(payload)) |rev| {
        try merged.appendSlice(alloc, ",\"expectedRevision\":");
        try jsonx.appendInt(alloc, &merged, rev);
    }
    return settingsWrite(deps, alloc, rpc_id, merged.items, .mutate);
}

// ── credentials domain (config.toml-backed credential slots) ────────────────
//
// The Models editor derives DEEPSEEK_API_KEY from the provider route and
// stores typed keys through credentials.set. zharness has no env vault: the
// two harness-managed refs map onto [model] api_key; anything else is absent
// and read-only. Environment-provided keys stay read-only here (env beats the
// document at boot, so editing them here would be a lie).

fn credentialState(alloc: std.mem.Allocator, ref: []const u8, home: []const u8) !struct { configured: bool, writable: bool, source: ?[]const u8 } {
    _ = alloc;
    const managed = std.mem.eql(u8, ref, "DEEPSEEK_API_KEY") or std.mem.eql(u8, ref, "ZHARNESS_API_KEY");
    if (!managed) return .{ .configured = false, .writable = false, .source = null };
    const env = apx_settings.collectEnv();
    if (env.zharness_api_key != null or env.deepseek_api_key != null) {
        return .{ .configured = true, .writable = false, .source = "environment" };
    }
    if (settingsStoreOf(home)) |s| {
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (try s.readDoc(a)) |doc| {
            if (try config.parseTomlFlat(a, doc)) |entries| {
                if (findApiKeyEntry(entries)) |k| {
                    if (k.len > 0) return .{ .configured = true, .writable = true, .source = "~/.zharness/config.toml" };
                }
            }
        }
    }
    return .{ .configured = false, .writable = true, .source = null };
}

fn findApiKeyEntry(entries: []const config.TomlEntry) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.section, "model") and std.mem.eql(u8, e.key, "api_key")) {
            return switch (e.val) {
                .str => |s| s,
                else => null,
            };
        }
    }
    return null;
}

fn hCredentialsDescribe(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    if (deps.credentialsDescribe) |f| {
        return okValue(alloc, rpc_id, try f(deps.ctx, alloc, payload));
    }
    if (settingsStoreOf(deps.home) == null) {
        return internalError(alloc, rpc_id, "credentials are not implemented on this host");
    }
    const refs_raw = jsonx.getRaw(payload, "refs") orelse return error.PayloadInvalid;
    if (!isJsonArrayRaw(refs_raw)) return error.PayloadInvalid;
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"credentials\":{");
    const inner = refs_raw[1 .. refs_raw.len - 1];
    var it = std.mem.splitScalar(u8, inner, ',');
    var first = true;
    while (it.next()) |seg_raw| {
        const seg = jsonx.trimWs(seg_raw);
        if (seg.len == 0) continue;
        if (!jsonx.isString(seg)) return error.PayloadInvalid;
        const ref = try jsonx.decodeString(alloc, seg[1 .. seg.len - 1]);
        // POSIX-portable env-name guard (credentialRefNameSchema).
        for (ref, 0..) |c, ci| {
            const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_' or (ci > 0 and c >= '0' and c <= '9');
            if (!ok) return badRequest(alloc, rpc_id, "invalid credential reference");
        }
        const st = try credentialState(alloc, ref, deps.home);
        if (!first) try value.append(alloc, ',');
        first = false;
        try value.append(alloc, '"');
        try value.appendSlice(alloc, ref);
        try value.appendSlice(alloc, "\":{\"configured\":");
        try value.appendSlice(alloc, if (st.configured) "true" else "false");
        if (st.source) |src| {
            try value.appendSlice(alloc, ",\"source\":");
            try jsonx.appendJsonString(alloc, &value, src);
        }
        try value.appendSlice(alloc, ",\"writable\":");
        try value.appendSlice(alloc, if (st.writable) "true" else "false");
        try value.append(alloc, '}');
    }
    try value.appendSlice(alloc, "}}");
    return okValue(alloc, rpc_id, value.items);
}

/// Write/clear [model] api_key under the llm-deepseek revision fence so the
/// Models page stays coherent with settings writes. Answers {} per schema.
fn credentialsSetUnset(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8, set: bool) !UnaryResponse {
    const ref = try reqString(alloc, payload, "ref");
    const managed = std.mem.eql(u8, ref, "DEEPSEEK_API_KEY") or std.mem.eql(u8, ref, "ZHARNESS_API_KEY");
    if (!managed) {
        return errValue(alloc, rpc_id, .settings_rejected, "credential reference is not managed by zharness", "{}");
    }
    const st = try credentialState(alloc, ref, deps.home);
    if (st.configured and !st.writable) {
        return errValue(alloc, rpc_id, .settings_rejected, "credential is provided by the environment and cannot be edited here", "{}");
    }
    const s = settingsStoreOf(deps.home) orelse return internalError(alloc, rpc_id, "credentials are not implemented on this host");
    var kv_val: ?config.TomlValue = null;
    if (set) {
        const v = try reqString(alloc, payload, "value");
        if (v.len == 0) return error.PayloadInvalid;
        kv_val = .{ .str = v };
    } else if (!st.configured) {
        return okValue(alloc, rpc_id, "{}"); // idempotent unset
    }
    var kvs = [_]config.ConfigKv{.{ .section = "model", .key = "api_key", .value = kv_val }};
    var ns_ids = [_]usize{apx_settings.Store.ns_llm_deepseek};
    _ = apx_settings.commitKvs(s, alloc, &kvs, &ns_ids, apx_settings.Store.ns_llm_deepseek, expectedRevisionOf(payload), apx_settings.collectEnv()) catch |e| return mapOpError(e);
    return okValue(alloc, rpc_id, "{}");
}

fn hCredentialsSet(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    if (deps.credentialsSet) |f| {
        try f(deps.ctx, alloc, payload);
        return okValue(alloc, rpc_id, "{}");
    }
    return credentialsSetUnset(deps, alloc, rpc_id, payload, true);
}

fn hCredentialsUnset(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    if (deps.credentialsUnset) |f| {
        try f(deps.ctx, alloc, payload);
        return okValue(alloc, rpc_id, "{}");
    }
    return credentialsSetUnset(deps, alloc, rpc_id, payload, false);
}

// ── llm domain (provider directory for the Models join) ─────────────────────

fn hLlmProviders(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    if (deps.llmProviders) |f| {
        return okValue(alloc, rpc_id, try f(deps.ctx, alloc));
    }
    // Static provider matrix over model/provider.zig profiles (models_rpc).
    return models_rpc.handleLlmProviders(deps, alloc, rpc_id, payload);
}

/// settings.openDocument: materialize the local document when absent, then
/// hand the path to the platform opener through the same seam as
/// host.openPath (macOS forces a text editor per upstream).
fn hSettingsOpenDocument(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    _ = payload; // {} per settingsOpenDocumentRequestSchema
    const s = settingsStoreOf(deps.home) orelse {
        return errValue(alloc, rpc_id, .directory_picker_unavailable, "no settings document on this host", "{\"capability\":\"openDocument\"}");
    };
    if (s.home.len == 0) {
        return errValue(alloc, rpc_id, .directory_picker_unavailable, "home is unknown; cannot open the settings document", "{}");
    }
    const path = try s.configPath(alloc);
    if (try s.readDoc(alloc) == null) {
        const template =
            \\# zharness configuration (~/.zharness/config.toml)
            \\# Edited by the web UI's Settings page; keys not listed here fall back
            \\# to defaults (see docs/settings.md).
            \\
        ;
        try s.writeDoc(template);
    }
    const open = deps.openPath orelse {
        return errValue(alloc, rpc_id, .directory_picker_unavailable, "openPath is not wired on this host", "{\"capability\":\"openDocument\"}");
    };
    try open(deps.ctx, alloc, path);
    return okValue(alloc, rpc_id, "{\"opened\":true}");
}

// ── plugin inventory domain (vendored GUI Plugins-settings inventory tab) ───

const apx_inventory = @import("inventory.zig");

/// pluginInventory/list → fresh scan of BOTH plugin registries (native dylib
/// + wasm) rendered into the upstream PluginInventorySnapshot shape. Payload
/// is {} per the upstream descriptor (no parameters).
fn hPluginInventoryList(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    _ = payload;
    const f = deps.pluginInventoryList orelse
        return internalError(alloc, rpc_id, "pluginInventory is not implemented on this host");
    return okValue(alloc, rpc_id, try f(deps.ctx, alloc));
}

// ── Tier-1 RPC domains (wave 6) ─────────────────────────────────────────────
//
// goals.* / skill.list / session.models / session.selectModel / llm.providers
// / agentPreset.{list,select} plus the two GUI pseudo-settings namespaces
// ("agent-presets".default and "permission".defaultPreset). The domain
// modules own their logic; this file owns envelope rendering, dispatch, and
// the settings-store plumbing they share.

/// Fenced single-key commit for the pseudo-settings namespaces. Runs under
/// the Store's own lock (read → applyConfigKvs → atomic write), bumps a
/// caller-owned revision counter (restart resets it — same documented
/// posture as Store.revisions), and answers nothing (callers re-render).
pub fn commitCustomKv(
    store: *apx_settings.Store,
    alloc: std.mem.Allocator,
    kv: config.ConfigKv,
    revision_counter: *u64,
    expected_revision: ?i64,
) !void {
    if (expected_revision) |want| {
        if (@as(i64, @intCast(revision_counter.*)) != want) return error.RevisionConflict;
    }
    const doc = try store.readDoc(alloc);
    const original: []const u8 = doc orelse "";
    const updated = config.applyConfigKvs(alloc, original, &[_]config.ConfigKv{kv}) catch return error.OutOfMemory;
    store.writeDoc(updated) catch return error.WriteFailed;
    revision_counter.* += 1;
}

fn docEntriesForHome(home: []const u8, alloc: std.mem.Allocator) ?[]config.TomlEntry {
    const store = settingsStoreOf(home) orelse return null;
    const doc = store.readDoc(alloc) catch return null;
    if (doc == null) return null;
    return config.parseTomlFlat(alloc, doc.?) catch null;
}

/// One pseudo-settings namespace descriptor: a single string field with a
/// validated value domain, persisted under one [general] key. An optional
/// second BOOLEAN field (agent-presets' modeSelectionEnabled) persists under
/// kv_key2.
const CustomNsSpec = struct {
    ns_name: []const u8,
    field: []const u8,
    /// Validate one candidate value (.str guaranteed by the parser).
    validate: *const fn ([]const u8) bool,
    /// Map the wire value onto the canonical TOML spelling (permission
    /// presets map onto sandbox_mode; agent-presets is identity).
    map_value: *const fn ([]const u8) []const u8,
    /// TOML landing spot.
    kv_key: []const u8,
    revision_counter: *const fn () *u64,
    /// Effective current value from document entries ⊕ default.
    currentOf: *const fn (?[]const config.TomlEntry) []const u8,
    /// Render the namespace view ({ns…} object); the trailing param is the
    /// second field's effective value when the spec declares one.
    view: *const fn (std.mem.Allocator, *std.ArrayList(u8), u64, []const u8, ?bool) anyerror!void,
    /// Optional second field (boolean only) and its TOML landing spot.
    field2: ?[]const u8 = null,
    kv_key2: ?[]const u8 = null,
    /// Effective current value of field2 from document entries ⊕ default.
    currentOf2: ?*const fn (?[]const config.TomlEntry) bool = null,
};

const custom_specs = [_]CustomNsSpec{
    .{
        .ns_name = "agent-presets",
        .field = "default",
        .validate = presetsValidate,
        .map_value = presetsIdentity,
        .kv_key = "agent_preset",
        .revision_counter = presetsRevision,
        .currentOf = presetsCurrent,
        .view = presetsView,
        .field2 = "modeSelectionEnabled",
        .kv_key2 = "mode_selection_enabled",
        .currentOf2 = presetsModeSelectionOf,
    },
    .{
        .ns_name = "permission",
        .field = "defaultPreset",
        .validate = permsValidate,
        .map_value = permsMapValue,
        .kv_key = "sandbox_mode",
        .revision_counter = permsRevision,
        .currentOf = permsCurrent,
        .view = permsView,
    },
};

fn presetsValidate(v: []const u8) bool {
    return presets_rpc.validDefaultId(v);
}
fn presetsRevision() *u64 {
    return presets_rpc.revisionPtr();
}
fn presetsCurrent(entries: ?[]const config.TomlEntry) []const u8 {
    return presets_rpc.defaultPresetOf(entries);
}
/// [general] mode_selection_enabled ⊕ false — the new-session preset picker.
fn presetsModeSelectionOf(entries: ?[]const config.TomlEntry) bool {
    const list = entries orelse return false;
    for (list) |e| {
        if (std.mem.eql(u8, e.section, "general") and
            std.mem.eql(u8, e.key, "mode_selection_enabled") and e.val == .boolean)
        {
            return e.val.boolean;
        }
    }
    return false;
}
fn presetsView(alloc: std.mem.Allocator, out: *std.ArrayList(u8), rev: u64, cur: []const u8, mode_enabled: ?bool) anyerror!void {
    try presets_rpc.appendNamespaceViewJson(alloc, out, rev, cur, mode_enabled orelse false);
}
fn permsValidate(v: []const u8) bool {
    return perms_rpc.validPreset(v);
}
fn permsMapValue(v: []const u8) []const u8 {
    return perms_rpc.sandboxForPreset(v) orelse v;
}
fn presetsIdentity(v: []const u8) []const u8 {
    return v;
}
fn permsRevision() *u64 {
    return perms_rpc.revisionPtr();
}
fn permsCurrent(entries: ?[]const config.TomlEntry) []const u8 {
    return perms_rpc.currentPresetOf(entries);
}
fn permsView(alloc: std.mem.Allocator, out: *std.ArrayList(u8), rev: u64, cur: []const u8, mode_enabled: ?bool) anyerror!void {
    _ = mode_enabled;
    try perms_rpc.appendNamespaceViewJson(alloc, out, rev, cur);
}

fn customSpecOf(ns: []const u8) ?*const CustomNsSpec {
    for (&custom_specs) |*spec| {
        if (std.mem.eql(u8, spec.ns_name, ns)) return spec;
    }
    return null;
}

/// Intercepted settings.update/mutate/replace for the pseudo namespaces.
/// Single-field semantics: the last set/unset wins; unknown fields answer
/// settings-rejected; stale expectedRevision answers settings-conflict with
/// {ns,expected,actual} details (upstream shape).
fn customNamespaceWrite(
    deps: *const ApiProxyDeps,
    alloc: std.mem.Allocator,
    rpc_id: []const u8,
    payload: []const u8,
    mode: enum { update, mutate, replace },
    spec: *const CustomNsSpec,
) !UnaryResponse {
    const store = settingsStoreOf(deps.home) orelse
        return internalError(alloc, rpc_id, "settings are not implemented on this host");

    var final_val: ?config.TomlValue = null;
    var final_val2: ?config.TomlValue = null;
    var touched = false;

    switch (mode) {
        // patch / section carry {"<field>": value}.
        .update, .replace => {
            const obj_raw = jsonx.getRaw(payload, if (mode == .update) "patch" else "section") orelse
                return error.PayloadInvalid;
            if (!isJsonObjectRaw(obj_raw)) return error.PayloadInvalid;
            const body = jsonx.objectBody(obj_raw).?;
            var it = jsonx.MemberIter.init(body);
            while (it.next()) |m| {
                const key = jsonx.decodeString(alloc, m.key) catch return error.OutOfMemory;
                if (std.mem.eql(u8, key, spec.field)) {
                    final_val = parseTomlValueRaw(alloc, m.value) catch |e| return e;
                    touched = true;
                } else if (spec.field2 != null and std.mem.eql(u8, key, spec.field2.?)) {
                    final_val2 = parseTomlValueRaw(alloc, m.value) catch |e| return e;
                    touched = true;
                } else return mapOpError(error.UnknownField);
            }
        },
        // ops carry [{op:"set"|"unset", path:["<field>"], value?}].
        .mutate => {
            const ops_raw = jsonx.getRaw(payload, "ops") orelse return error.PayloadInvalid;
            if (!isJsonArrayRaw(ops_raw)) return error.PayloadInvalid;
            const body = ops_raw[1 .. ops_raw.len - 1];
            var i: usize = 0;
            while (i < body.len) {
                while (i < body.len and (body[i] == ',' or asciiWs(body[i]))) : (i += 1) {}
                if (i >= body.len) break;
                if (body[i] != '{') return error.PayloadInvalid;
                const end = jsonx.matchBraceFrom(body, i) orelse return error.PayloadInvalid;
                const op = body[i..end];
                i = end;

                const kind_raw = jsonx.getRaw(op, "op") orelse return error.PayloadInvalid;
                const is_set = std.mem.eql(u8, kind_raw, "\"set\"");
                const is_unset = std.mem.eql(u8, kind_raw, "\"unset\"");
                if (!is_set and !is_unset) return error.PayloadInvalid;

                const path_raw = jsonx.getRaw(op, "path") orelse return error.PayloadInvalid;
                if (!isJsonArrayRaw(path_raw)) return error.PayloadInvalid;
                const first = firstPathSegment(alloc, path_raw) orelse return error.PayloadInvalid;
                if (std.mem.eql(u8, first, spec.field)) {
                    final_val = if (is_set)
                        parseTomlValueRaw(alloc, jsonx.getRaw(op, "value") orelse return error.PayloadInvalid) catch |e| return e
                    else
                        null;
                    touched = true;
                } else if (spec.field2 != null and std.mem.eql(u8, first, spec.field2.?)) {
                    final_val2 = if (is_set)
                        parseTomlValueRaw(alloc, jsonx.getRaw(op, "value") orelse return error.PayloadInvalid) catch |e| return e
                    else
                        null;
                    touched = true;
                } else return mapOpError(error.UnknownField);
            }
        },
    }

    if (touched) {
        if (final_val) |v| {
            if (v != .str) return errValue(
                alloc,
                rpc_id,
                .settings_rejected,
                "value type does not match the namespace schema",
                "{\"issues\":[]}",
            );
            if (!spec.validate(v.str)) {
                return errValue(
                    alloc,
                    rpc_id,
                    .settings_rejected,
                    "unknown preset id",
                    "{\"issues\":[]}",
                );
            }
            // Canonicalize onto the TOML knob spelling (preset → sandbox mode
            // for the permission namespace; identity for agent-presets).
            final_val = .{ .str = spec.map_value(v.str) };
        }
        if (final_val2) |v| {
            if (v != .boolean) return errValue(
                alloc,
                rpc_id,
                .settings_rejected,
                "value type does not match the namespace schema",
                "{\"issues\":[]}",
            );
        }
        if (final_val != null) commitCustomKv(store, alloc, .{
            .section = "general",
            .key = spec.kv_key,
            .value = final_val,
        }, spec.revision_counter(), expectedRevisionOf(payload)) catch |e| switch (e) {
            error.RevisionConflict => return revisionConflictResponse(alloc, rpc_id, spec, payload),
            error.OutOfMemory => return error.OutOfMemory,
            else => return internalError(alloc, rpc_id, "failed to persist config.toml"),
        };
        if (final_val2 != null) commitCustomKv(store, alloc, .{
            .section = "general",
            .key = spec.kv_key2.?,
            .value = final_val2,
        }, spec.revision_counter(), expectedRevisionOf(payload)) catch |e| switch (e) {
            error.RevisionConflict => return revisionConflictResponse(alloc, rpc_id, spec, payload),
            error.OutOfMemory => return error.OutOfMemory,
            else => return internalError(alloc, rpc_id, "failed to persist config.toml"),
        };
    }

    // Fresh view of the namespace after the write (or no-op read-through).
    var view: std.ArrayList(u8) = .empty;
    errdefer view.deinit(alloc);
    const entries = docEntriesForHome(deps.home, alloc);
    try spec.view(alloc, &view, spec.revision_counter().*, spec.currentOf(entries), if (spec.currentOf2) |f| f(entries) else null);
    return okValue(alloc, rpc_id, view.items);
}

fn revisionConflictResponse(alloc: std.mem.Allocator, rpc_id: []const u8, spec: *const CustomNsSpec, payload: []const u8) !UnaryResponse {
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(alloc);
    const want = expectedRevisionOf(payload) orelse -1;
    try d.appendSlice(alloc, "{\"ns\":");
    try jsonx.appendJsonString(alloc, &d, spec.ns_name);
    try d.appendSlice(alloc, ",\"expected\":");
    try jsonx.appendInt(alloc, &d, want);
    try d.appendSlice(alloc, ",\"actual\":");
    try jsonx.appendInt(alloc, &d, @intCast(spec.revision_counter().*));
    try d.append(alloc, '}');
    return errValue(alloc, rpc_id, .settings_conflict, "settings were changed elsewhere; reload and retry", d.items);
}

/// Splice the two pseudo-namespace views into a settings.describe VALUE so
/// the vendored permission-presets row and agent-preset default row render.
/// Works on every describe shape (real store output AND the legacy ui-
/// onboarding stub): both end with `]}`.
fn augmentDescribeValue(
    deps: *const ApiProxyDeps,
    alloc: std.mem.Allocator,
    base_value: []const u8,
) ![]u8 {
    if (base_value.len < 2 or base_value[base_value.len - 2] != ']' or base_value[base_value.len - 1] != '}') {
        return alloc.dupe(u8, base_value);
    }
    const entries = docEntriesForHome(deps.home, alloc);

    var perm_view: std.ArrayList(u8) = .empty;
    defer perm_view.deinit(alloc);
    try perms_rpc.appendNamespaceViewJson(alloc, &perm_view, perms_rpc.revisionPtr().*, perms_rpc.currentPresetOf(entries));

    var preset_view: std.ArrayList(u8) = .empty;
    defer preset_view.deinit(alloc);
    try presets_rpc.appendNamespaceViewJson(alloc, &preset_view, presets_rpc.revisionPtr().*, presets_rpc.defaultPresetOf(entries), presets_rpc.modeSelectionOf(entries));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, base_value[0 .. base_value.len - 2]);
    try out.append(alloc, ',');
    try out.appendSlice(alloc, perm_view.items);
    try out.append(alloc, ',');
    try out.appendSlice(alloc, preset_view.items);
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

// ── dynamic cordis domain (P3 runtime) ──────────────────────────────────────
//
// Process-global Lifecycle singleton (installDefaultSettings pattern): one
// registry + sandbox + lifecycle per process on the C allocator — it
// outlives any request arena and is released with the process, matching the
// events_ws.sharedHubs posture documented in src/dynamic/wire.zig.

var default_dynamic_lifecycle: ?*dyn_lifecycle.Lifecycle = null;

/// The shared dynamic runtime, created lazily on first use. Idempotent.
pub fn sharedDynamicLifecycle() !*dyn_lifecycle.Lifecycle {
    if (default_dynamic_lifecycle) |lc| return lc;
    const reg = try std.heap.c_allocator.create(dyn_registry.DynamicRegistry);
    errdefer std.heap.c_allocator.destroy(reg);
    reg.* = dyn_registry.DynamicRegistry.init(std.heap.c_allocator);
    const lc = try std.heap.c_allocator.create(dyn_lifecycle.Lifecycle);
    errdefer std.heap.c_allocator.destroy(lc);
    lc.* = dyn_lifecycle.Lifecycle.init(
        std.heap.c_allocator,
        reg,
        dyn_sandbox.Sandbox.initDefault(std.heap.c_allocator),
    );
    default_dynamic_lifecycle = lc;
    return lc;
}

/// dynamic.getClientCode (spec §4): the ONLY path client source reaches the
/// browser. Answers {"code":"<clientCode>"} for the given packageId; a
/// host-only or unknown package carries null code so the page logs and skips.
/// Page-global read under the lifecycle lock (spec §6: no session).
/// dynamicCordisRunner.inventory: one row per stable Plugin in the shared
/// lifecycle registry (upstream DynamicCordisInventoryRow shape), grouped by
/// plugin with its package revisions and current run.
fn hDynamicInventory(alloc: std.mem.Allocator, rpc_id: []const u8) !UnaryResponse {
    const lc = try sharedDynamicLifecycle();
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.append(alloc, '[');
    {
        lc.lock.lock();
        defer lc.lock.unlock();
        var first_plugin = true;
        var it = lc.reg.plugins.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            if (!first_plugin) try value.append(alloc, ',');
            first_plugin = false;
            try value.appendSlice(alloc, "{\"pluginId\":");
            try jsonx.appendJsonString(alloc, &value, p.plugin_id);
            try value.appendSlice(alloc, ",\"agentId\":");
            try jsonx.appendJsonString(alloc, &value, p.session_id);
            try value.appendSlice(alloc, ",\"packages\":[");
            var first_pkg = true;
            for (p.package_order.items) |pkg_id| {
                const pkg = p.packages.get(pkg_id) orelse continue;
                if (!first_pkg) try value.append(alloc, ',');
                first_pkg = false;
                try value.appendSlice(alloc, "{\"packageId\":");
                try jsonx.appendJsonString(alloc, &value, pkg.package_id);
                try value.appendSlice(alloc, ",\"name\":");
                try jsonx.appendJsonString(alloc, &value, pkg.name);
                try value.appendSlice(alloc, ",\"purpose\":");
                try jsonx.appendJsonString(alloc, &value, pkg.purpose);
                try value.appendSlice(alloc, if (pkg.hostCode != null) ",\"hasHostHalf\":true" else ",\"hasHostHalf\":false");
                try value.appendSlice(alloc, if (pkg.clientCode != null) ",\"hasClientHalf\":true" else ",\"hasClientHalf\":false");
                try value.append(alloc, '}');
            }
            try value.append(alloc, ']');
            if (p.current_package_id) |cur| {
                try value.appendSlice(alloc, ",\"currentPackageId\":");
                try jsonx.appendJsonString(alloc, &value, cur);
            }
            if (p.next_package_id) |next| {
                try value.appendSlice(alloc, ",\"nextPackageId\":");
                try jsonx.appendJsonString(alloc, &value, next);
            }
            if (p.run) |r| {
                try value.appendSlice(alloc, ",\"activeRun\":{\"pluginRunId\":");
                try jsonx.appendJsonString(alloc, &value, r.pluginRunId);
                try value.appendSlice(alloc, ",\"packageId\":");
                try jsonx.appendJsonString(alloc, &value, r.packageId);
                try value.append(alloc, '}');
            }
            try value.append(alloc, '}');
        }
    }
    try value.append(alloc, ']');
    return okValue(alloc, rpc_id, value.items);
}

fn hDynamicGetClientCode(alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {    const lc = try sharedDynamicLifecycle();
    const plugin_id = try reqString(alloc, payload, "pluginId");
    const package_id = try reqString(alloc, payload, "packageId");
    const run_id = try optString(alloc, payload, "pluginRunId");

    var code: ?[]const u8 = null;
    {
        lc.lock.lock();
        defer lc.lock.unlock();
        const p = lc.reg.getPlugin(plugin_id) orelse
            return badRequest(alloc, rpc_id, "unknown plugin");
        // Stale-revision guard: a half pinned to another run id reads as absent.
        if (p.run) |r| {
            if (run_id) |want| {
                if (!std.mem.eql(u8, want, r.pluginRunId))
                    return badRequest(alloc, rpc_id, "stale pluginRunId");
            }
        }
        const pkg = p.packages.get(package_id) orelse
            return badRequest(alloc, rpc_id, "unknown package");
        code = pkg.clientCode;
    }

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"code\":");
    if (code) |c| {
        try jsonx.appendJsonString(alloc, &value, c);
    } else {
        try value.appendSlice(alloc, "null");
    }
    try value.append(alloc, '}');
    return okValue(alloc, rpc_id, value.items);
}

/// dynamic.invoke (spec §7): unary harness.handle RPC through the ACTIVE
/// run's host half. Value is {ok,value} | {code,message}; transport-level
/// failures (node missing/crashed) ride the same {code,message} shape with
/// the transport tag as code.
fn hDynamicInvoke(deps: *const ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !UnaryResponse {
    _ = deps;
    const lc = try sharedDynamicLifecycle();
    const plugin_id = try reqString(alloc, payload, "pluginId");
    const run_id = try optString(alloc, payload, "pluginRunId");
    const method = try reqString(alloc, payload, "method");
    const args_raw = jsonx.getRaw(payload, "args") orelse "{}";

    var inv = lc.invoke(plugin_id, run_id, method, args_raw) catch |e| {
        // PluginNotFound/NotRunning/StaleRevision/etc.: in-band handler-level
        // failure shape rather than a carrier error (spec §7).
        if (e == error.OutOfMemory) return error.OutOfMemory;
        var fallback: std.ArrayList(u8) = .empty;
        errdefer fallback.deinit(alloc);
        try fallback.appendSlice(alloc, "{\"ok\":false,\"code\":\"no-active-run\",\"message\":");
        try jsonx.appendJsonString(alloc, &fallback, @errorName(e));
        try fallback.append(alloc, '}');
        return okValue(alloc, rpc_id, fallback.items);
    };
    defer inv.deinit(alloc);

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    if (inv.ok) {
        try value.appendSlice(alloc, "{\"ok\":true,\"value\":");
        try value.appendSlice(alloc, if (inv.value_json.len > 0) inv.value_json else "null");
        try value.appendSlice(alloc, "}");
    } else {
        try value.appendSlice(alloc, "{\"ok\":false,\"code\":");
        try jsonx.appendJsonString(
            alloc,
            &value,
            inv.code orelse inv.transport_err orelse "handler-error",
        );
        try value.appendSlice(alloc, ",\"message\":");
        try jsonx.appendJsonString(alloc, &value, inv.message orelse "");
        try value.append(alloc, '}');
    }
    return okValue(alloc, rpc_id, value.items);
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
    const m_raw = env.method;
    if (std.c.getenv("ZH_DEBUG_RPC") != null)
        std.debug.print("[rpc] {s}\n", .{m_raw});
    // Payload unwrap: the v0.1.6 typert gateway transports every unary
    // request as {args: <request>} while handlers read the request's own
    // top-level fields. Unwrap once here; bare (legacy) payloads without an
    // "args" object member pass through unchanged.
    var p = env.payload_raw;
    if (jsonx.getRaw(p, "args")) |args| {
        if (jsonx.objectBody(args) != null) p = args;
    }
    // Session-controller faces nest their request one layer deeper
    // ({args:{request:{...}}} on the wire — {request:{...}} after the args
    // unwrap above); descend when present so handlers see the request's own
    // top-level fields.
    if (jsonx.getRaw(p, "request")) |request| {
        if (jsonx.objectBody(request) != null) p = request;
    }
    // Wire-form normalization: the v0.1.6 typert gateway composes endpoints as
    // `namespace/method` while the v0.1.1 surface used `namespace.method`.
    // Match on the dot form so both eras hit the same handlers.
    const m = if (std.mem.indexOfScalar(u8, m_raw, '/') != null) blk: {
        const norm = try alloc.dupe(u8, m_raw);
        for (norm) |*ch| {
            if (ch.* == '/') ch.* = '.';
        }
        break :blk norm;
    } else m_raw;

    // sessions domain
    if (std.mem.eql(u8, m, "session.list")) {
        const resp = try hSessionList(deps, alloc, env.rpc_id, p);
        const clean = try sanitizeResponseBody(alloc, resp.body);
        if (clean.ptr == resp.body.ptr) return resp;
        const mutable = try alloc.dupe(u8, clean);
        return .{ .body = mutable };
    }
    if (std.mem.eql(u8, m, "session.search")) {
        if (deps.searchSessions == null) {
            return internalError(alloc, env.rpc_id, "session.search is not implemented on this host");
        }
        return run(alloc, env, hSessionSearch(deps, alloc, env.rpc_id, p));
    }
    if (std.mem.eql(u8, m, "session.create")) return run(alloc, env, sessionCreateAndAnnounce(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "session.history")) {
        const resp = try hSessionHistory(deps, alloc, env.rpc_id, p);
        const clean = try sanitizeResponseBody(alloc, resp.body);
        if (clean.ptr == resp.body.ptr) return resp;
        // Repair was needed — the session data contains malformed JSON from
        // before the tool_mod_echo fix. Return an empty but valid history
        // rather than risk returning broken JSON to the client.
        const empty_value = "{\"records\":[],\"hasMore\":false,\"projections\":{\"asOfSeq\":-1,\"values\":{}}}";
        _ = empty_value;
        var rpc_buf: std.ArrayList(u8) = .empty;
        defer rpc_buf.deinit(alloc);
        try jsonx.appendJsonString(alloc, &rpc_buf, env.rpc_id);
        const empty_body = try std.fmt.allocPrint(alloc, "{{\"type\":\"server-response\",\"rpcId\":{s},\"result\":{{\"ok\":true,\"value\":{{\"records\":[],\"hasMore\":false,\"projections\":{{\"asOfSeq\":-1,\"values\":{{}}}}}}}}}}", .{rpc_buf.items});
        return .{ .body = try alloc.dupe(u8, empty_body) };
    }
    if (std.mem.eql(u8, m, "session.prompt")) return run(alloc, env, hSessionPrompt(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "session.cancel")) return run(alloc, env, hSessionCancel(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "session.rename")) return run(alloc, env, hSessionRename(deps, alloc, env.rpc_id, p));

    // subagent domain (wave-6: ui-subagent over the process-global registry)
    if (std.mem.eql(u8, m, "subagent.list")) {
        const value = try subagents_rpc.handleList(alloc, p);
        return okValue(alloc, env.rpc_id, value);
    }
    if (std.mem.eql(u8, m, "subagent.history")) {
        const value = try subagents_rpc.handleHistory(alloc, p);
        return okValue(alloc, env.rpc_id, value);
    }

    // zharness extensions (wave-6: jobs / trajectory / workflow-run replay —
    // upstream folds these client-side from frames; these unary views are
    // zharness-only conveniences, clearly namespaced)
    if (std.mem.eql(u8, m, "zharness.jobs.list")) {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        return jobs_rpc.handleJobsList(alloc, env.rpc_id, threaded.io(), deps.cwd);
    }
    if (std.mem.eql(u8, m, "zharness.trajectory.get")) {
        const sid = (jsonx.getStringAlloc(alloc, p, "sessionId") catch null) orelse return badRequest(alloc, env.rpc_id, "missing sessionId");
        defer alloc.free(sid);
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const value = try trajectory.valueForSession(deps.cwd, threaded.io(), alloc, sid);
        return okValue(alloc, env.rpc_id, value);
    }
    if (std.mem.eql(u8, m, "zharness.workflowRun.list")) return wf_replay.handleRunList(alloc, env.rpc_id, deps.cwd);
    if (std.mem.eql(u8, m, "zharness.workflowRun.get")) return wf_replay.handleRunGet(alloc, env.rpc_id, deps.cwd, p);

    // model selection domain (Tier-1: vendored ui-model-selection)
    if (std.mem.eql(u8, m, "session.models")) return run(alloc, env, models_rpc.handleSessionModels(deps, alloc, env.rpc_id, p));
    // v0.1.6 rename: model catalog over the same provider matrix.
    if (std.mem.eql(u8, m, "session.modelCatalog")) return run(alloc, env, models_rpc.handleModelCatalog(deps, alloc, env.rpc_id));
    // v0.1.6 paged cold history (address + throughSeq cursor).
    if (std.mem.eql(u8, m, "session.page")) return run(alloc, env, hSessionPage(deps, alloc, env.rpc_id, p));
    // llm provider directory (settings model selector + selector defaults).
    if (std.mem.eql(u8, m, "llm.listProviders"))
        return run(alloc, env, okValue(alloc, env.rpc_id, "[{\"id\":\"deepseek\",\"name\":\"DeepSeek\"}]"));
    if (std.mem.eql(u8, m, "llm.listConfigurableProviders"))
        return run(alloc, env, okValue(alloc, env.rpc_id, "[{\"provider\":\"deepseek\",\"displayName\":\"DeepSeek\",\"settingsNs\":\"llm-deepseek\",\"settingsPath\":[]}]"));
    if (std.mem.eql(u8, m, "session.selectModel")) return run(alloc, env, models_rpc.handleSessionSelectModel(deps, alloc, env.rpc_id, p));

    // skills domain (Tier-1: vendored ui-skill; fresh disk scan per call)
    if (std.mem.eql(u8, m, "skill.list")) return run(alloc, env, skills_rpc.handle(deps, alloc, env.rpc_id, p));

    // goals domain (Tier-1: vendored ui-goal; process-global store + mux
    // goal/change + session/projection frames — see goals_rpc.zig)
    if (std.mem.startsWith(u8, m, "goal.")) {
        return run(alloc, env, goals_rpc.handle(m, alloc, env.rpc_id, p));
    }

    // agent presets domain (Tier-1: vendored ui-agent-preset over
    // src/presets.zig)
    if (std.mem.eql(u8, m, "agentPreset.list")) return run(alloc, env, presets_rpc.handleList(deps, alloc, env.rpc_id));
    if (std.mem.eql(u8, m, "agentPreset.select")) return run(alloc, env, presets_rpc.handleSelect(deps, alloc, env.rpc_id, p));
    // v0.1.6 client namespaces (plural) — same handlers, alias dispatch.
    // Permission-preset catalog (vendored ui-permission-presets): zharness
    // exposes its sandbox levels as the selectable presets; `custom` derives
    // client-side when live settings diverge.
    if (std.mem.eql(u8, m, "permissionPresets.catalog"))
        return run(alloc, env, okValue(alloc, env.rpc_id, try perms_rpc.catalogJson(alloc)));
    if (std.mem.eql(u8, m, "agentPresets.list")) return run(alloc, env, presets_rpc.handleList(deps, alloc, env.rpc_id));
    if (std.mem.eql(u8, m, "agentPresets.select")) return run(alloc, env, presets_rpc.handleSelect(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "subagents.list")) {
        const value = try subagents_rpc.handleList(alloc, p);
        return okValue(alloc, env.rpc_id, value);
    }
    if (std.mem.eql(u8, m, "subagents.history")) {
        const value = try subagents_rpc.handleHistory(alloc, p);
        return okValue(alloc, env.rpc_id, value);
    }
    if (std.mem.eql(u8, m, "skills.list")) return run(alloc, env, skills_rpc.handle(deps, alloc, env.rpc_id, p));
    // Composer slash-command catalog: zharness's chat command registry is
    // interactive-only, so the web catalog is empty for now.
    if (std.mem.eql(u8, m, "commands.list")) return run(alloc, env, okValue(alloc, env.rpc_id, "[]"));
    // Settings-panel preset-directory affordance: zharness keeps presets in
    // config.toml (no directory to open), so the affordance is unavailable.
    if (std.mem.eql(u8, m, "settings.canOpenAgentPresetDirectory")) return run(alloc, env, okValue(alloc, env.rpc_id, "false"));

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

    // settings domain (config.toml-backed when a store is installed; else
    // describe answers the legacy ui-onboarding stub and writes degrade)
    if (std.mem.eql(u8, m, "settings.describe")) return run(alloc, env, hSettingsDescribe(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "settings.update")) return run(alloc, env, hSettingsUpdate(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "settings.mutate")) return run(alloc, env, hSettingsMutate(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "settings.replace")) return run(alloc, env, hSettingsReplace(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "settings.openDocument")) return run(alloc, env, hSettingsOpenDocument(deps, alloc, env.rpc_id, p));

    // credentials domain (Models-page key slots over [model] api_key)
    if (std.mem.eql(u8, m, "credentials.describe")) return run(alloc, env, hCredentialsDescribe(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "credentials.set")) return run(alloc, env, hCredentialsSet(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "credentials.unset")) return run(alloc, env, hCredentialsUnset(deps, alloc, env.rpc_id, p));

    // llm domain (provider directory for the Models join; discovery is a
    // pi-ai/custom-route feature zharness does not offer)
    if (std.mem.eql(u8, m, "llm.providers")) return run(alloc, env, hLlmProviders(deps, alloc, env.rpc_id, p));

    // plugin inventory (Plugins-settings inventory tab; upstream wire method
    // keeps its slash form — the typert gateway composes namespace/method)
    // v0.1.6 gateway sends slash-form; accept the normalized dot form too.
    if (std.mem.eql(u8, m, "pluginInventory.list")) return run(alloc, env, hPluginInventoryList(deps, alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "pluginInventory/list")) return run(alloc, env, hPluginInventoryList(deps, alloc, env.rpc_id, p));

    // dynamic cordis domain (P3 runtime: browser-half host endpoints)
    if (std.mem.eql(u8, m, "dynamic.getClientCode")) return run(alloc, env, hDynamicGetClientCode(alloc, env.rpc_id, p));
    if (std.mem.eql(u8, m, "dynamic.invoke")) return run(alloc, env, hDynamicInvoke(deps, alloc, env.rpc_id, p));
    // v0.1.6 dynamicCordisRunner surface (upstream cordis-host-runner): the
    // inventory is backed by the shared lifecycle registry; the client inspect
    // manifest sync is accepted and mirrored as a no-op.
    if (std.mem.eql(u8, m, "dynamicCordisRunner.inventory")) return run(alloc, env, hDynamicInventory(alloc, env.rpc_id));
    if (std.mem.eql(u8, m, "dynamicCordisRunner.syncInspectManifest")) return run(alloc, env, okValue(alloc, env.rpc_id, "null"));
    // Gateway-internal event-result endpoint: user-questions waterfall
    // answers settle their pending question here (first answer wins).
    if (std.mem.eql(u8, m, "$events.result")) {
        const store = questions.sharedStore() catch null;
        const store_ptr = store orelse return run(alloc, env, okValue(alloc, env.rpc_id, "null"));
        const event_id = (jsonx.getStringAlloc(alloc, p, "eventId") catch null) orelse
            return badRequest(alloc, env.rpc_id, "$events.result requires eventId");
        const outcome = jsonx.getRaw(p, "outcome") orelse
            return badRequest(alloc, env.rpc_id, "$events.result requires outcome");
        const kind = (jsonx.getStringAlloc(alloc, outcome, "kind") catch null) orelse
            return badRequest(alloc, env.rpc_id, "$events.result requires outcome.kind");
        const value = jsonx.getRaw(outcome, "value") orelse "null";
        const receipt = store_ptr.respondEvent(event_id, kind, value);
        if (receipt.accepted) return run(alloc, env, okValue(alloc, env.rpc_id, "null"));
        return badRequest(alloc, env.rpc_id, receipt.reason);
    }

    if (std.c.getenv("ZH_DEBUG_RPC") != null)
        std.debug.print("[rpc] unknown method: {s}\n", .{m});
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
        // Host route for the ui-open-in-app plugin: zharness registers no
        // external applications, so the catalog is always empty.
        if (std.mem.eql(u8, req.path, "/open-in-app/apps")) {
            return res.send(.ok, .json, "{\"apps\":[]}");
        }
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

    // Gateway multiplexed Remote-stream socket (upstream stream-protocol.ts).
    // v1 accepts the socket and degrades every stream open to `unavailable`.
    if (std.mem.eql(u8, req.path, "/api/remote.mux")) {
        const upg = httpd.WsUpgrade.fromRequest(req) catch {
            return res.send(.bad_request, .text, "websocket upgrade required");
        };
        var conn = res.startWebSocket(&upg) catch |e| switch (e) {
            error.HandshakeWriteFailed => return error.WriteFailed,
            error.SocketSetupFailed => return error.SocketSetupFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return events_ws.serveRemoteMux(alloc, &conn);
    }

    // Envelope-less upstream download channel (session-export): the GUI
    // requests a ZIP by query string rather than through unary RPC.
    if (std.mem.eql(u8, req.path, "/api/session.export") and
        (std.mem.eql(u8, req.method, "GET") or std.mem.eql(u8, req.method, "HEAD")))
    {
        var sid: ?[]u8 = null;
        var include_descendants = false;
        var qit = std.mem.splitScalar(u8, req.query, '&');
        while (qit.next()) |part| {
            const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            const key = part[0..eq];
            const val = part[eq + 1 ..];
            if (std.mem.eql(u8, key, "sessionId")) {
                sid = httpd.percentDecode(alloc, val) catch return res.send(.bad_request, .text, "invalid sessionId");
            } else if (std.mem.eql(u8, key, "includeDescendants")) {
                if (std.mem.eql(u8, val, "true")) include_descendants = true else if (!std.mem.eql(u8, val, "false")) return res.send(.bad_request, .text, "invalid includeDescendants");
            }
        }
        const session_id = sid orelse return res.send(.bad_request, .text, "sessionId is required");
        defer alloc.free(session_id);
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const dl = export_rpc.sessionLogDownload(threaded.io(), alloc, deps.cwd, session_id, include_descendants) catch |e| switch (e) {
            error.SessionNotFound => return res.send(.not_found, .text, "no such session"),
            else => return e,
        };
        defer {
            alloc.free(dl.filename);
            alloc.free(dl.body);
        }
        if (std.mem.eql(u8, req.method, "HEAD")) return res.sendRawType(.ok, dl.content_type, "");
        return res.sendRawType(.ok, dl.content_type, dl.body);
    }

    if (!std.mem.eql(u8, req.method, "POST")) {
        // Upstream parity: anything but the SSE GETs and unary POSTs is 404.
        return res.send(.not_found, .text, "not found");
    }

    const seg = req.path["/api/".len..];

    // Answerable-push receipt: real question flow (ask_user tool publishes
    // question/requested; the GUI answers via /api/respond; the frame rpcId
    // is the correlation id). The dynamic cordis leg runs FIRST: wire's
    // handleRespond self-detects cordis-shaped bodies (result.value carrying
    // {requestId, decision}) and reports mine:false for everything else, so
    // question answers pass through untouched to the questions.zig leg below
    // (multiplex contract documented in src/dynamic/wire.zig).
    if (std.mem.eql(u8, seg, "respond")) {
        if (sharedDynamicLifecycle()) |lc| {
            const leg = try dyn_wire.handleRespond(lc, alloc, req.body);
            if (leg.mine) return res.send(.ok, .json, leg.body);
        } else |_| {} // no dynamic runtime on this host → questions leg only

        const store = try questions.sharedStore();
        const receipt = try questions.handleRespond(store, alloc, req.body);
        return res.send(.ok, .json, receipt);
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

    if (std.c.getenv("ZH_DEBUG_RPC") != null)
        std.debug.print("[env] {s} body[{d}]: {s}\n", .{ req.path, req.body.len, req.body[0..@min(req.body.len, 260)] });
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
