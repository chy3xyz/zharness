//! ask_user tool (wave 6, G3-interactive): lets the agent pause its run and
//! ask the human a question through the web GUI, then continue with the
//! answer as the tool result.
//!
//! ── Protocol (contract: docs/dsh-reuse-spec.md §4 + upstream events.schema.ts) ──
//!
//!   1. executor builds ONE AskUserQuestionItem ({id:"q1", question,
//!      options?[{label}]}) and registers a Pending entry in the shared
//!      questions store (server/apiproxy/questions.zig), which mints the
//!      stable questionRpcId.
//!   2. it publishes on the mux hub — via the wired `publish` sink:
//!        {"type":"server-request","rpcId":"<questionRpcId>",
//!         "method":"question/requested",
//!         "payload":{"type":"question/requested","sessionId":"…",
//!                    "questions":[…]}}
//!      The frame rpcId IS the respond correlation id (upstream api-proxy
//!      reuses the server-request id for both directions).
//!   3. the browser renders the composer (options menu + free-text field)
//!      and answers with POST /api/respond {type:'client-response', rpcId,
//!      result:{ok,value:{sessionId,answer:{answers:[{id,selected,custom?}]}}}}.
//!   4. the REAL questions.handleRespond validates + settles the pending
//!      entry; this tool's poll loop (250 ms tick) observes it.
//!   5. executor emits question/resolved {…,"outcome":"answered"||
//!      "cancelled"} and returns "user chose: <label>" / "user answered:
//!      <custom>" as the ToolResult text.
//!
//! ── BLOCKING SEMANTICS (integrator: read before wiring) ───────────────────
//! The executor BLOCKS the calling thread until an answer, a cancellation,
//! or timeout_ms elapses (default 120 s). Under the agent loop's serialized-
//! mutex contract this HOLDS THE RUN SLOT for the whole wait — no other turn
//! can start on that session while a question is open. This is by design
//! (upstream behaves identically: the tool call promise parks inside the live
//! step), but it means:
//!   - session.cancel must call questions.Store.cancelAllForSession to break
//!     a waiting ask_user (the waiter then resolves cancelled);
//!   - serve-mode turn timeouts must account for interactive waits;
//!   - sub-agents must NOT be given this tool (an owned child has no human
//!     answerer upstream — DELEGATED_CALLER).
//!
//! ── Integrator contract (spawn_agent precedent) ───────────────────────────
//! Registry executors are plain functions, so this module keeps ONE
//! module-level context slot:
//!
//!     var g_ask_ctx: ?*AskCtx = null;
//!     pub fn setAskCtx(ctx: *AskCtx) void;    // once at startup
//!     pub fn clearAskCtx() void;              // once at shutdown
//!
//! AskCtx fields: .publish — fn(frame_json) receiving the COMPLETE
//! ServerRequest frame (pre-wrapped here with wrapServerRequestWithId so the
//! frame rpcId is our questionRpcId; integrator thunk fans it out verbatim,
//! e.g. a FrameHub.publishRaw passthrough); .session_id — the run's web
//! session id; .store — questions.sharedStore(); .timeout_ms/.poll_ms.
//!
//! Until setAskCtx runs, execute returns a FAILED ToolResult explaining the
//! missing wiring — never crashes, never blocks.

const std = @import("std");
const jsonx = @import("../server/apiproxy/jsonx.zig");
const questions = @import("../server/apiproxy/questions.zig");
const events_ws = @import("../server/apiproxy/events_ws.zig");
const tool_reg = @import("registry.zig");

/// Default human-answer budget (spec: bounded timeout, default 120 s).
pub const default_timeout_ms: u64 = 120_000;

/// Upstream ui-user-questions renders at most a handful of choices; the tool
/// schema caps options at 4 (mission spec) and rejects more loudly.
pub const max_options: usize = 4;

// ── module-level wiring slot (see header contract) ──────────────────────────

var g_ask_ctx: ?*AskCtx = null;

pub fn setAskCtx(ctx: *AskCtx) void {
    g_ask_ctx = ctx;
}

pub fn clearAskCtx() void {
    g_ask_ctx = null;
}

/// Current wiring (null until setAskCtx). Exposed for tests/introspection.
pub fn askCtx() ?*AskCtx {
    return g_ask_ctx;
}

/// Wiring bundle. `publish` receives the complete ServerRequest frame bytes;
/// the integrator thunk forwards them to every mux subscriber (the natural
/// implementation is `hubs.mux.publishFrame`/raw fan-out — see report).
pub const AskCtx = struct {
    publish: ?*const fn (frame_json: []const u8) void = null,
    session_id: []const u8 = "",
    store: ?*questions.Store = null,
    timeout_ms: u64 = default_timeout_ms,
    poll_ms: u64 = 250,
    /// When true the caller is a live subagent owned by another agent. The
    /// upstream contract (dsh-user-approval / tool-ask-user) requires a
    /// fail-fast DELEGATED_CALLER error instead of parking for a human
    /// answer that can never arrive.
    is_subagent: bool = false,
};

/// Stable DELEGATED_CALLER guidance — mirrors upstream dsh-tool-ask-user's
/// error so the model can correct without context loss.
pub const delegated_caller_msg = "human interaction is unavailable while the calling agent is owned by another live agent; include the unresolved question or decision in the child agent's final result";

/// Canonical upstream name — the model-visible schema source is
/// dsh-tool-ask-user (questions array). `ask_user` is retained as an alias
/// for backward compatibility; documentation advertises the canonical name.
pub const canonical_name = "ask_user_question";
pub const alias_name = "ask_user";

// ── registry-facing definitions ────────────────────────────────────────────

/// Legacy alias: `ask_user` with a flat question+options schema. Kept for
/// backward compatibility; new prompts should use `ask_user_question`.
pub const definition = tool_reg.ToolDefinition{
    .name = "ask_user",
    .description =
    \\Ask the human user a question and wait for their answer before
    \\continuing. Use when a decision genuinely needs the user's input
    \\(ambiguous requirements, destructive action confirmation, either/or
    \\design choices). Provide 2-4 short option labels when the answer is a
    \\choice; omit options when free-form input makes sense. The run pauses
    \\until the user answers or times out (2 minutes).
    ,
    .category = .general,
    .parameters_json =
    \\{"type":"object","properties":{"question":{"type":"string","description":"The question to show the user, self-contained and specific"},"options":{"type":"array","items":{"type":"string"},"maxItems":4,"description":"Optional 2-4 short choice labels; omit for free-text answers"}},"required":["question"]}
    ,
};

/// Canonical upstream definition: `ask_user_question` with the questions-array
/// schema (dsh-tool-ask-user). Both definitions dispatch through the same
/// executor so a model using either name gets identical behaviour.
pub const canonical_definition = tool_reg.ToolDefinition{
    .name = "ask_user_question",
    .description =
    \\Ask the user one or more concise questions when you need confirmation, a choice, or missing information before proceeding. Each question needs a stable id echoed in the answer; optionally include header, options with label/description, and multi_select.
    ,
    .category = .general,
    .parameters_json =
    \\{"type":"object","properties":{"questions":{"type":"array","description":"Questions to ask the user before continuing.","items":{"type":"object","properties":{"id":{"type":"string","description":"Stable id for this question; echoed in the answer."},"question":{"type":"string","description":"The specific question to ask the user."},"header":{"type":"string","description":"Optional short heading for the question"},"options":{"type":"array","description":"Optional choices to show the user.","items":{"type":"object","properties":{"label":{"type":"string","description":"Short user-facing option label."},"description":{"type":"string","description":"One sentence explaining the tradeoff."}},"required":["label"]}},"multi_select":{"type":"boolean","description":"Whether the user may select more than one option. Defaults to false."}},"required":["id","question"]}}},"required":["questions"]}
    ,
};

/// Whether `name` is the canonical upstream tool name.
pub fn isCanonicalName(name: []const u8) bool {
    return std.mem.eql(u8, name, canonical_name);
}

/// Whether `name` matches either advertised tool name.
pub fn isAskUserTool(name: []const u8) bool {
    return std.mem.eql(u8, name, canonical_name) or std.mem.eql(u8, name, alias_name);
}

/// Register both tool definitions at once. The canonical definition is
/// documented; the alias is kept for compatibility. Interactive adapters call
/// this; CLI-only runs register only what they need.
pub fn registerAll(reg: *tool_reg.ToolRegistry) !void {
    if (!reg.contains(definition.name)) {
        try reg.register(definition);
    }
    if (!reg.contains(canonical_definition.name)) {
        try reg.register(canonical_definition);
    }
}

// ── executor ────────────────────────────────────────────────────────────────

pub const ToolCall = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    err_msg: ?[]const u8 = null,
};

/// Free a result returned by `execute` (allocated with the same allocator).
pub fn freeResult(alloc: std.mem.Allocator, res: *const ToolResult) void {
    alloc.free(res.output);
    if (res.err_msg) |m| alloc.free(m);
}

fn fail(alloc: std.mem.Allocator, msg: []const u8) ToolResult {
    return .{
        .success = false,
        .output = alloc.dupe(u8, "") catch "",
        .err_msg = alloc.dupe(u8, msg) catch null,
    };
}

/// Parsed tool arguments.
const Args = struct {
    question: []const u8,
    options: [][]const u8,

    fn deinit(self: *Args, alloc: std.mem.Allocator) void {
        alloc.free(self.question);
        for (self.options) |o| alloc.free(o);
        alloc.free(self.options);
    }
};

/// Parse {"question": str, "options"?: [str,…]} (flat object, string array).
fn parseArgs(alloc: std.mem.Allocator, json_args: []const u8) !Args {
    var args = Args{ .question = "", .options = &.{} };
    errdefer args.deinit(alloc);

    const q_raw = jsonx.getRaw(json_args, "question") orelse return error.MissingQuestion;
    if (!jsonx.isString(q_raw)) return error.BadQuestion;
    args.question = try jsonx.decodeString(alloc, q_raw[1 .. q_raw.len - 1]);

    if (jsonx.getRaw(json_args, "options")) |opts_raw| {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(alloc);
        var elems = ElemScanner.init(opts_raw);
        while (elems.next()) |el| {
            if (!jsonx.isString(el)) return error.BadOption;
            try list.append(alloc, try jsonx.decodeString(alloc, el[1 .. el.len - 1]));
        }
        args.options = try list.toOwnedSlice(alloc);
    }
    return args;
}

/// Top-level element scanner over a JSON array span. Nesting-aware: object
/// elements come back as complete `{…}` spans (answers/selected/questions
/// arrays all carry objects), strings as quoted spans.
const ElemScanner = struct {
    body: []const u8,
    i: usize = 0,

    fn init(array_json: []const u8) ElemScanner {
        const t = jsonx.trimWs(array_json);
        if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
            return .{ .body = t[1 .. t.len - 1] };
        }
        return .{ .body = "" };
    }

    fn next(self: *ElemScanner) ?[]const u8 {
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
                // Non-string junk: skip to comma (rejected by the caller).
                while (i < b.len and b[i] != ',') : (i += 1) {}
            },
        }
        self.i = i;
        return jsonx.trimWs(b[start..i]);
    }
};

/// Build the single-item questions array:
/// [{"id":"q1","question":"…","options":[{"label":"…"},…]}]
/// (exact askUserQuestionItemShape; optional fields omitted).
fn buildQuestionsJson(alloc: std.mem.Allocator, args: *const Args) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "[{\"id\":\"q1\",\"question\":");
    try jsonx.appendJsonString(alloc, &out, args.question);
    if (args.options.len > 0) {
        try out.appendSlice(alloc, ",\"options\":[");
        for (args.options, 0..) |opt, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"label\":");
            try jsonx.appendJsonString(alloc, &out, opt);
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]");
    }
    try out.appendSlice(alloc, "}]");
    return try out.toOwnedSlice(alloc);
}

/// Dispatch an ask_user / ask_user_question call. Blocks until
/// answered/cancelled/timeout (see header: holds the run slot by design).
/// Allocations use `alloc`; the caller frees via freeResult.
pub fn execute(alloc: std.mem.Allocator, call: ToolCall) !ToolResult {
    if (!isAskUserTool(call.name)) {
        return fail(alloc, "ask_user tool called with unknown name");
    }
    const wiring = g_ask_ctx orelse return fail(
        alloc,
        "ask_user is not wired: the host must call ask_user.setAskCtx(&AskCtx{...}) at startup",
    );
    // Subagent exclusion — fail fast, never park.
    if (wiring.is_subagent) return fail(alloc, delegated_caller_msg);
    const store = wiring.store orelse return fail(alloc, "ask_user is not wired: missing questions store");
    const publish = wiring.publish orelse return fail(alloc, "ask_user is not wired: missing mux publisher");
    if (wiring.session_id.len == 0) return fail(alloc, "ask_user is not wired: missing session id");

    // Dual schema: upstream canonical `{"questions":[...]}` vs legacy flat
    // `{"question": "...", "options": [...]}`. Canonical wins when present.
    var questions_json: []const u8 = undefined;
    var owned_questions: ?[]u8 = null;
    defer if (owned_questions) |q| alloc.free(q);

    if (jsonx.getRaw(call.arguments, "questions")) |questions_raw| {
        const trimmed = jsonx.trimWs(questions_raw);
        if (trimmed.len < 2 or trimmed[0] != '[') return fail(alloc, "questions must be a non-empty array");
        // Validate at least one element by scanning.
        var scan = ElemScanner.init(trimmed);
        if (scan.next() == null) return fail(alloc, "questions must be a non-empty array");
        // Keep raw array verbatim — questions.zig validates ids/labels on respond.
        owned_questions = try alloc.dupe(u8, trimmed);
        questions_json = owned_questions.?;
    } else {
        var args = parseArgs(alloc, call.arguments) catch |e| switch (e) {
            error.MissingQuestion => return fail(alloc, "missing question"),
            error.BadQuestion => return fail(alloc, "question must be a string"),
            error.BadOption => return fail(alloc, "options must be an array of strings"),
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer args.deinit(alloc);
        if (args.question.len == 0) return fail(alloc, "question must be a non-empty string");
        if (args.options.len > max_options)
            return fail(alloc, "options supports at most 4 entries");
        owned_questions = try buildQuestionsJson(alloc, &args);
        questions_json = owned_questions.?;
    }

    // Register FIRST (mints the questionRpcId), then publish with that id —
    // an ultra-early respond between register and publish settles cleanly
    // because state lives in the store, not in this stack frame.
    const p = try store.ask(wiring.session_id, questions_json);
    // claimWaiter removes+frees the entry, so keep our own id for the
    // question/resolved frame emitted after the claim.
    const rpc_id = try alloc.dupe(u8, p.rpc_id);
    defer alloc.free(rpc_id);

    // Publish question/requested (full ServerRequest form, frame rpcId =
    // questionRpcId so the echoed client-response routes back to `p`).
    var frame: ?[]u8 = null;
    var resolved_frame: ?[]u8 = null;
    defer {
        if (frame) |f| alloc.free(f);
        if (resolved_frame) |f| alloc.free(f);
    }
    frame = blk: {
        const payload = questions.buildRequestedPayload(alloc, wiring.session_id, questions_json) catch break :blk null;
        defer alloc.free(payload);
        break :blk events_ws.wrapServerRequestWithId(alloc, p.rpc_id, "question/requested", payload) catch null;
    };
    if (frame) |f| publish(f);

    // Poll loop (events_ws spin+nap discipline): 250 ms tick, bounded total.
    const deadline = questions.monoMs() + @as(i64, @intCast(wiring.timeout_ms));
    var claim: questions.Store.Claim = .cancelled;
    while (true) {
        if (p.getState() != .waiting) {
            claim = store.claimWaiter(alloc, p);
            break;
        }
        if (questions.monoMs() >= deadline) {
            // Timeout wins unless a respond landed between the two checks —
            // claimWaiter re-checks under the lock.
            claim = store.claimWaiter(alloc, p);
            break;
        }
        questions.backoffSleepMs(wiring.poll_ms);
    }

    // Emit question/resolved (upstream has no timeout outcome; timeouts read
    // as cancelled, ASK_ABORTED family).
    resolved_frame = blk: {
        const payload = questions.buildResolvedPayload(
            alloc,
            wiring.session_id,
            rpc_id,
            claim == .answered,
        ) catch break :blk null;
        defer alloc.free(payload);
        break :blk events_ws.wrapServerRequestWithId(alloc, rpc_id, "question/resolved", payload) catch null;
    };
    if (resolved_frame) |f| publish(f);

    switch (claim) {
        .answered => |answer_json| {
            defer alloc.free(answer_json);
            return formatAnswer(alloc, answer_json);
        },
        .cancelled => {
            return fail(alloc, "user did not answer the question (cancelled or timed out)");
        },
    }
}

/// Render the settled answer value as the tool result text:
///   selected label(s) → "user chose: A" / "user chose: A, B"
///   custom text       → "user answered: …"
///   neither           → "user skipped the question"
pub fn formatAnswer(alloc: std.mem.Allocator, answer_json: []const u8) !ToolResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    const answer_raw = jsonx.getRaw(answer_json, "answer") orelse
        return .{ .success = true, .output = try alloc.dupe(u8, "user skipped the question"), .err_msg = null };
    const answers_raw = jsonx.getRaw(answer_raw, "answers") orelse
        return .{ .success = true, .output = try alloc.dupe(u8, "user skipped the question"), .err_msg = null };

    // Single-question batch by construction; still render whatever arrived.
    var labels: std.ArrayList([]const u8) = .empty;
    defer {
        for (labels.items) |s| alloc.free(s);
        labels.deinit(alloc);
    }
    var custom: ?[]const u8 = null;
    defer if (custom) |c| alloc.free(c);

    var elems = ElemScanner.init(answers_raw);
    while (elems.next()) |el| {
        if (jsonx.getRaw(el, "selected")) |sel_raw| {
            var sel = ElemScanner.init(sel_raw);
            while (sel.next()) |sraw| {
                if (!jsonx.isString(sraw)) continue;
                try labels.append(alloc, try jsonx.decodeString(alloc, sraw[1 .. sraw.len - 1]));
            }
        }
        if (jsonx.getRaw(el, "custom")) |craw| {
            if (jsonx.isString(craw)) {
                custom = try jsonx.decodeString(alloc, craw[1 .. craw.len - 1]);
            }
        }
    }

    if (labels.items.len > 0) {
        try out.appendSlice(alloc, "user chose: ");
        for (labels.items, 0..) |l, i| {
            if (i > 0) try out.appendSlice(alloc, ", ");
            try out.appendSlice(alloc, l);
        }
    } else if (custom) |c| {
        if (c.len == 0) {
            try out.appendSlice(alloc, "user skipped the question");
        } else {
            try out.appendSlice(alloc, "user answered: ");
            try out.appendSlice(alloc, c);
        }
    } else {
        try out.appendSlice(alloc, "user skipped the question");
    }

    return .{ .success = true, .output = try out.toOwnedSlice(alloc), .err_msg = null };
}
