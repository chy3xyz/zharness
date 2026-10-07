const std = @import("std");
const clib = @import("clib.zig");
const cordis = @import("cordis");

const cli_flags = @import("cli_flags.zig");
const config = @import("config.zig");
const model = @import("model/model.zig");
const tool_reg = @import("tool/registry.zig");
const tool_builtin = @import("tool/builtin.zig");
const agent = @import("agent/agent.zig");
const session = @import("session/session.zig");

// Orphan modules wired by this pass (dev.md §XIII–XVII).
const checkpoint = @import("session/checkpoint.zig");
const skill_mod = @import("skill/skill.zig");
const skill_loader = @import("skill/loader.zig");
const mem_persistent = @import("memory/persistent.zig");
const mem_working = @import("memory/working.zig");
const plan_mod = @import("agent/plan.zig");
const goal_mod = @import("agent/goal.zig");
const todo_mod = @import("todo/todo.zig");

// Swarm wave-2 capabilities (dev.md §VI/§XVIII–XXVI/§XXVIII/§XXX).
const presets_mod = @import("presets.zig");
const obs_mod = @import("obs.zig");
const httpd = @import("server/httpd.zig");
const api = @import("server/api.zig");
const webfetch = @import("tool/webfetch.zig");
const spawn_agent = @import("tool/spawn_agent.zig");
const subagent_mod = @import("agent/subagent.zig");
const run_code = @import("tool/run_code.zig");
const instructions_mod = @import("agent/instructions.zig");
const compaction_mod = @import("agent/compaction.zig");
const sandbox_mod = @import("sandbox/sandbox.zig");
const preset_tools = @import("dynamic/preset_tools.zig");
const wf_mod = @import("workflow/workflow.zig");
const wf_exec = @import("workflow/executor.zig");
const wf_report = @import("workflow/run_report.zig");
const mcp_mod = @import("protocol/mcp.zig");
const mcp_bridge = @import("tool/mcp_bridge.zig");
const plugin_loader = @import("pluginabi/loader.zig");
const wasm_loader = @import("pluginabi/wasm_loader.zig");
const server_events = @import("server/events.zig");
const server_static = @import("server/static.zig");
const apiproxy = @import("server/apiproxy/router.zig");
const apix_sessions = @import("server/apiproxy/sessions.zig");
const remote_mux = @import("server/apiproxy/remote_mux.zig");
const apix_jsonx = @import("server/apiproxy/jsonx.zig");
const apix_inventory = @import("server/apiproxy/inventory.zig");
const events_ws = @import("server/apiproxy/events_ws.zig");
const questions = @import("server/apiproxy/questions.zig");
const ask_user = @import("tool/ask_user.zig");
const attachments = @import("server/apiproxy/attachments.zig");
const tool_attachments = @import("tool/attachments.zig");
const present_mod = @import("tool/present.zig");
const jobs_tool = @import("tool/jobs.zig");
const read_image_mod = @import("tool/read_image.zig");
const goals_rpc = @import("server/apiproxy/goals_rpc.zig");
const plan_frames = @import("server/apiproxy/plan_frames.zig");
const jobs_rpc = @import("server/apiproxy/jobs_rpc.zig");
const subagents_rpc = @import("server/apiproxy/subagents_rpc.zig");
const search_rpc = @import("server/apiproxy/search_rpc.zig");

const SYSTEM_PROMPT =
    \\You are zharness, a coding agent running inside a workspace. You help the user by
    \\reading, editing, and searching files, running shell commands, and using git. Prefer
    \\small, focused changes and verify them. Use the provided tools to inspect and modify
    \\the codebase rather than guessing. When you finish, give a concise final answer that
    \\summarizes what you did and any follow-up needed.
;

/// Escape a string as a JSON literal (owned). Bridge-helper for mux frames.
fn jsonEsc(alloc: std.mem.Allocator, s: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(alloc, "\"") catch return null;
    model.escape(alloc, s, &out) catch return null;
    out.appendSlice(alloc, "\"") catch return null;
    return out.toOwnedSlice(alloc) catch null;
}

// ── live SessionEvent envelopes (vendored-GUI mux fold) ─────────────────────
// The client validates every session/event frame against the strict
// sessionEventSchema ({type,seq,time,data} — sessions.schema.ts), so the
// bridge publishes full envelopes, never bare data payloads. Journal seqs
// allocate from remote_mux.nextJournalSeq() (from 0, consecutive) so the
// follow stream's cursor continuity holds.

var g_tool_call_seq = std.atomic.Value(u64).init(1);
/// Unique-per-message id counter: the client fold keys message identity by
/// id, so repeated ids collapse distinct turns into one node.
var g_msg_n = std.atomic.Value(u64).init(1);
/// Per-prompt turn number: the client groups the transcript into turn blocks
/// keyed by the events' turn field, so every prompt must open the NEXT turn
/// of ITS session (steps restart at 0 within each turn). Hardcoding turn:1
/// merged every prompt into the first group and misplaced its messages.
var g_turn_lens: [16]usize = @splat(0);
var g_turn_turns: [16]u64 = @splat(0);
var g_turn_sids: [16][128]u8 = @splat(std.mem.zeroes([128]u8));
var g_current_turn: u64 = 0;

/// Next turn number for `sid` (1-based). Runs hold g_run_mutex, so the table
/// needs no extra lock; session ids are short and slots are reused LRU-0.
fn nextTurnFor(sid: []const u8) u64 {
    var slot: usize = 0;
    var found = false;
    for (g_turn_lens, 0..) |len, i| {
        if (len != 0 and std.mem.eql(u8, g_turn_sids[i][0..len], sid)) {
            slot = i;
            found = true;
            break;
        }
    }
    if (!found) {
        for (g_turn_lens, 0..) |len, i| {
            if (len == 0) {
                slot = i;
                found = true;
                break;
            }
        }
    }
    const n = g_turn_turns[slot] + 1;
    const copy_len = @min(sid.len, g_turn_sids[slot].len);
    @memcpy(g_turn_sids[slot][0..copy_len], sid[0..copy_len]);
    g_turn_lens[slot] = copy_len;
    g_turn_turns[slot] = n;
    return n;
}
var g_current_call_id: [32]u8 = undefined;
var g_current_call_id_len: usize = 0;
var g_current_step: u64 = 0;

/// Publish ONE strict-envelope SessionEvent for the parked run session.
/// `surface_append` adds the fixture-parity `"surfaceOp":"append"` marker
/// carried by whole-message events (user/message, assistant/message,
/// tool/result). Returns the journal seq allocated for the event so the
/// assistant-stream `end` frame can cite the durable settlement.
fn muxPublishEvent(ev_type: []const u8, surface_append: bool, data_json: []const u8) u64 {
    if (std.c.getenv("ZH_DEBUG_FRAME") != null) {
        std.debug.print("[mux:{s}] {s}\n", .{ ev_type, data_json[0..@min(data_json.len, 200)] });
    }
    const A = gpaAlloc();
    const tj = jsonEsc(A, ev_type) orelse return 0;
    defer A.free(tj);
    const seq = remote_mux.nextJournalSeq();
    const ms = nowMsFallback();
    const line = if (surface_append)
        std.fmt.allocPrint(A, "{{\"type\":{s},\"seq\":{d},\"time\":{d},\"surfaceOp\":\"append\",\"data\":{s}}}", .{ tj, seq, ms, data_json }) catch return seq
    else
        std.fmt.allocPrint(A, "{{\"type\":{s},\"seq\":{d},\"time\":{d},\"data\":{s}}}", .{ tj, seq, ms, data_json }) catch return seq;
    defer A.free(line);
    followPublishLine(A, ev_type, seq, line);
    muxPublish(line);
    return seq;
}

fn nowMsFallback() i64 {
    const io = g_io orelse return 0;
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

/// Mirror one live frame onto the remote.mux session.follow streams (the
/// v0.1.6 GUI's journal transport). `line` is already the SessionWireEvent
/// wire shape; `seq` is the `remote_mux.nextJournalSeq()` value it carries.
/// Transformation for vocabulary drift the legacy publishers carry:
///   - step/start|end gain "turn":1 when the publisher omitted it
/// assistant/chunk never routes here — live deltas go through the
/// assistant-stream presentation channel (followAssistant* below).
fn followPublishLine(alloc: std.mem.Allocator, ev_type: []const u8, seq: u64, line: []const u8) void {
    const sid = g_mux_run_session orelse return;
    const known = [_][]const u8{
        "turn/start",   "turn/end",          "step/start", "step/end",
        "user/message", "assistant/message", "tool/call",  "tool/result",
    };
    var routed = false;
    for (known) |k| {
        if (std.mem.eql(u8, ev_type, k)) {
            routed = true;
            break;
        }
    }
    if (!routed) return;

    var out: []const u8 = line;
    if (std.mem.eql(u8, ev_type, "step/start") or std.mem.eql(u8, ev_type, "step/end")) {
        const marker = "\"data\":{";
        const didx = std.mem.indexOf(u8, out, marker) orelse return;
        const data = out[didx + "\"data\":".len ..];
        if (apix_jsonx.getRaw(data, "turn") != null) {
            remote_mux.publishLine(sid, seq, out);
            return;
        }
        out = std.fmt.allocPrint(alloc, "{s}\"turn\":{d},{s}", .{ out[0 .. didx + marker.len], g_current_turn, out[didx + marker.len ..] }) catch return;
    }
    remote_mux.publishLine(sid, seq, out);
    if (out.ptr != line.ptr) alloc.free(out);
}

// ── assistant-stream live presentation frames ───────────────────────────────
// The v0.1.6 GUI folds model token deltas from the session.follow
// `assistant-stream` notification channel, not the journal: a `start` frame
// opens the attempt, dense-indexed `chunk` frames stream deltas, and an `end`
// frame releases the durable assistant/message settlement. Revisions allocate
// from remote_mux's counter; the follow snapshot baseline carries the current
// value, so the client's revision+1 check holds across reconnects.

const asst_attempt_id = "attempt-live";
var g_asst_active = false;
var g_asst_start_step: u64 = 0;
var g_asst_chunk_index: u64 = 0;

fn followAssistantFrame(frame_json: []const u8) void {
    const sid = g_mux_run_session orelse return;
    remote_mux.publishAssistantLine(sid, frame_json);
}

/// Open the live attempt on the first chunk of a turn. `step` is captured so
/// the settlement check (attempt.step === assistant/message data.step) can
/// detect mid-turn tool rounds, which bump the step after streaming began.
fn followAssistantStart() void {
    if (g_asst_active) return;
    g_asst_active = true;
    g_asst_start_step = g_current_step;
    g_asst_chunk_index = 0;
    const frame = std.fmt.allocPrint(gpaAlloc(), "{{\"type\":\"start\",\"attemptId\":\"" ++ asst_attempt_id ++ "\",\"revision\":{d},\"startedAfterSeq\":{d},\"turn\":{d},\"step\":{d}}}", .{ remote_mux.nextAssistantRevision(), remote_mux.cursor(), g_current_turn, g_asst_start_step }) catch return;
    defer gpaAlloc().free(frame);
    followAssistantFrame(frame);
}

fn followAssistantChunk(kind: model.StreamKind, text_json: []const u8) void {
    if (g_mux_run_session == null) return;
    followAssistantStart();
    const idx = g_asst_chunk_index;
    g_asst_chunk_index += 1;
    const ctype: []const u8 = switch (kind) {
        .text => "text-delta",
        .reasoning => "reasoning-delta",
    };
    const frame = std.fmt.allocPrint(gpaAlloc(), "{{\"type\":\"chunk\",\"attemptId\":\"" ++ asst_attempt_id ++ "\",\"revision\":{d},\"index\":{d},\"time\":{d},\"chunk\":{{\"type\":\"{s}\",\"index\":0,\"text\":{s}}}}}", .{ remote_mux.nextAssistantRevision(), idx, nowMsFallback(), ctype, text_json }) catch return;
    defer gpaAlloc().free(frame);
    followAssistantFrame(frame);
}

/// Close the live attempt after the durable assistant/message committed at
/// `seq` (already published — the reducer stages the settlement on the
/// journal entry and releases it on this frame).
fn followAssistantEndCommitted(seq: u64) void {
    if (!g_asst_active) return;
    g_asst_active = false;
    const n = g_asst_chunk_index;
    g_asst_chunk_index = 0;
    const frame = std.fmt.allocPrint(gpaAlloc(), "{{\"type\":\"end\",\"attemptId\":\"" ++ asst_attempt_id ++ "\",\"revision\":{d},\"index\":{d},\"outcome\":{{\"kind\":\"committed\",\"eventType\":\"assistant/message\",\"seq\":{d}}}}}", .{ remote_mux.nextAssistantRevision(), n, seq }) catch return;
    defer gpaAlloc().free(frame);
    followAssistantFrame(frame);
}

/// Close the live attempt with no settlement (run error, or the step moved
/// mid-turn so the committed message cannot join this attempt).
fn followAssistantEndAbandoned() void {
    if (!g_asst_active) return;
    g_asst_active = false;
    const n = g_asst_chunk_index;
    g_asst_chunk_index = 0;
    const frame = std.fmt.allocPrint(gpaAlloc(), "{{\"type\":\"end\",\"attemptId\":\"" ++ asst_attempt_id ++ "\",\"revision\":{d},\"index\":{d},\"outcome\":{{\"kind\":\"abandoned\"}}}}", .{ remote_mux.nextAssistantRevision(), n }) catch return;
    defer gpaAlloc().free(frame);
    followAssistantFrame(frame);
}

/// Publish a SessionEvent whose data embeds exactly one JSON-escaped string.
fn muxPublishEventEsc(
    comptime ev_type: []const u8,
    comptime data_fmt: []const u8,
    surface_append: bool,
    escaped: []const u8,
) void {
    const A = gpaAlloc();
    const data = std.fmt.allocPrint(A, data_fmt, .{escaped}) catch return;
    defer A.free(data);
    _ = muxPublishEvent(ev_type, surface_append, data);
}

fn muxPublishEventStepEsc(
    comptime ev_type: []const u8,
    comptime data_fmt: []const u8,
    surface_append: bool,
    step: usize,
    escaped: []const u8,
) void {
    const A = gpaAlloc();
    const data = std.fmt.allocPrint(A, data_fmt, .{ step, escaped }) catch return;
    defer A.free(data);
    _ = muxPublishEvent(ev_type, surface_append, data);
}

fn onEvent(kind: agent.AgentLoop.EventKind, payload: []const u8) void {
    obsEmit(kind, payload);
    // Live SessionEventMap folding for vendored-GUI runs (spec §3): when a
    // session.prompt run is active, mirror the stream onto the mux hub as
    // strict-envelope events. Shapes mirror the upstream fixture log and
    // apiproxy/sessions.zig's history reconstruction exactly.
    if (g_mux_run_session != null) {
        switch (kind) {
            .turn_start => {
                // Publish step/start event so the client knows a new turn/step has begun,
                // which suppresses the "Interrupted" markers from previous steps.
                const A = gpaAlloc();
                const data = std.fmt.allocPrint(A, "{{\"step\":{d}}}", .{g_current_step}) catch return;
                defer A.free(data);
                _ = muxPublishEvent("step/start", false, data);
            },
            // NOTE: .thinking and .text streaming deltas are published by
            // onStreamDelta (the ChatClient's stream_sink), NOT here. The
            // onEvent .text fires after the full response is assembled and
            // would duplicate the streaming chunks.
            .tool_call => blk: {
                const A = gpaAlloc();
                const open = std.mem.indexOfScalar(u8, payload, '(');
                const close = if (open != null) std.mem.lastIndexOfScalar(u8, payload, ')') else null;
                const tool_name = if (open) |o| payload[0..o] else payload;
                const raw_args = if (open != null and close != null and close.? > open.?)
                    payload[open.? + 1 .. close.?]
                else
                    "{}";
                const name_j = jsonEsc(A, tool_name) orelse break :blk;
                defer A.free(name_j);
                // Arguments are passed as a raw JSON string (extracted from the
                // model payload). The client renders them as a readable code block.
                const args_j2 = raw_args;
                const n = g_tool_call_seq.fetchAdd(1, .monotonic);
                g_current_step += 1;
                g_current_call_id_len = (std.fmt.bufPrint(&g_current_call_id, "call-{d}", .{n}) catch return).len;
                const call_j = jsonEsc(A, g_current_call_id[0..g_current_call_id_len]) orelse break :blk;
                defer A.free(call_j);
                const data = std.fmt.allocPrint(
                    A,
                    "{{\"turn\":{d},\"step\":{d},\"callId\":{s},\"name\":{s},\"arguments\":{s}}}",
                    .{ g_current_turn, g_current_step, call_j, name_j, args_j2 },
                ) catch break :blk;
                defer A.free(data);
                if (std.c.getenv("ZH_DEBUG_FRAME") != null) std.debug.print("[frame:tool_call] {s}\n", .{data});
                _ = muxPublishEvent("tool/call", false, data);
            },
            .tool_result => if (jsonEsc(gpaAlloc(), payload)) |o| {
                defer gpaAlloc().free(o);
                const A = gpaAlloc();
                const call_j = jsonEsc(A, g_current_call_id[0..g_current_call_id_len]) orelse return;
                defer A.free(call_j);
                const data = std.fmt.allocPrint(
                    A,
                    "{{\"turn\":{d},\"step\":{d},\"message\":{{\"id\":{s},\"role\":\"user\",\"content\":[{{\"type\":\"tool-result\",\"toolCallId\":{s},\"content\":[{{\"type\":\"text\",\"text\":{s}}}]}}],\"source\":{{\"kind\":\"tool\",\"callId\":{s}}}}}}}",
                    .{ g_current_turn, g_current_step, call_j, call_j, o, call_j },
                ) catch return;
                defer A.free(data);
                if (std.c.getenv("ZH_DEBUG_FRAME") != null) std.debug.print("[frame:tool_result] {s}\n", .{data});
                // tool/result is a surface type: surfaceOp marks it as an
                // append so the transcript fold renders the tool card.
                _ = muxPublishEvent("tool/result", true, data);
            },
            .done => if (jsonEsc(gpaAlloc(), payload)) |t| {
                defer gpaAlloc().free(t);
                // Publish step/end before the final assistant/message so the
                // client knows this turn/step is complete.
                const end_data = std.fmt.allocPrint(gpaAlloc(), "{{\"step\":{d}}}", .{g_current_step}) catch return;
                defer gpaAlloc().free(end_data);
                _ = muxPublishEvent("step/end", false, end_data);
                // Assistant message uses the same step as the tool call/result
                // so the client can merge streaming chunks with the final message.
                const msg_data = std.fmt.allocPrint(
                    gpaAlloc(),
                    "{{\"turn\":{d},\"step\":{d},\"message\":{{\"id\":\"a-{d}\",\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"source\":{{\"kind\":\"model\"}}}},\"stream\":[]}}",
                    .{ g_current_turn, g_current_step, g_msg_n.fetchAdd(1, .monotonic), t },
                ) catch return;
                defer gpaAlloc().free(msg_data);
                const msg_seq = muxPublishEvent("assistant/message", true, msg_data);
                // Close the live streaming attempt: the reducer staged the
                // settlement above only when the attempt's step still matches,
                // so a mid-turn tool round (step bumped after streaming began)
                // abandons instead of citing a seq the reducer never staged.
                if (g_asst_active and g_asst_start_step == g_current_step) {
                    followAssistantEndCommitted(msg_seq);
                } else {
                    followAssistantEndAbandoned();
                }
            },
            else => {},
        }
    }
    switch (kind) {
        .thinking => std.debug.print("[thinking] {s}\n", .{payload}),
        .text => std.debug.print("{s}", .{payload}),
        .tool_call => std.debug.print("\n> calling {s}\n", .{payload}),
        .tool_result => std.debug.print("  -> {s}\n", .{payload}),
        .turn_start => {},
        .done => std.debug.print("\n=== Final answer ===\n{s}\n", .{payload}),
        .err => {
            std.debug.print("\n[error] {s}\n", .{payload});
            // Surface model failures on the vendored-GUI fold: the loop logs
            // and returns success, so without this capture the turn would end
            // 'completed' with no assistant content and no UI failure row.
            followAssistantEndAbandoned();
            if (g_mux_run_session != null) {
                if (g_mux_run_error) |old| gpaAlloc().free(old);
                g_mux_run_error = gpaAlloc().dupe(u8, payload) catch null;
            }
        },
    }
}

/// Live-delta sink for streamed chat completions: text prints as it arrives;
/// reasoning prints dimmed so it reads as scaffolding, not the answer.
fn onStreamDelta(kind: model.StreamKind, delta: []const u8) void {
    if (std.c.getenv("ZH_DEBUG_STREAM") != null) {
        std.debug.print("[stream] kind={s} len={d} mux_session={s}\n", .{ @tagName(kind), delta.len, if (g_mux_run_session != null) "SET" else "NULL" });
    }
    switch (kind) {
        .text => std.debug.print("{s}", .{delta}),
        .reasoning => std.debug.print("\x1b[2m{s}\x1b[0m", .{delta}),
    }
    // Stream deltas to the GUI in real time via the assistant-stream
    // presentation channel (start/chunk/end frames on session.follow). The
    // durable journal settlement is published by the .done handler.
    if (g_mux_run_session != null) {
        const A = gpaAlloc();
        const dj = jsonEsc(A, delta) orelse return;
        defer A.free(dj);
        followAssistantChunk(kind, dj);
    }
}

// ── observability (dev.md §XXX): JSONL event envelopes per run ──────────────

/// Module-level obs state for the current run. The loop's on_event callback
/// has no context slot, and the CLI is single-threaded per run, so a slot is
/// the same pattern spawn_agent uses. Null = observability disabled.
const ObsState = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    sink: *obs_mod.JsonlSink,
    trace: obs_mod.TraceCtx,
};

var g_obs: ?ObsState = null;

// ── dsh apiproxy run bridge (spec §3 phase-3 task 9) ────────────────────────
// When a session.prompt arrives over the vendored GUI, its run executes on a
// detached thread (serialized by the serve run mutex). While it runs, the
// session id is parked here so the shared on_event callback can fold loop
// events into SessionEventMap frames on the mux hub. Runs are serialized, so
// a single slot is race-free.

var g_mux_run_session: ?[]const u8 = null;

/// Failure captured from the live run's .err event (owned; runs serialize on
/// g_run_mutex, so a single slot is race-free). Non-null turns the turn/end
/// reason into kind:'error' and raises host/agent-error for the failure card.
var g_mux_run_error: ?[]const u8 = null;

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

/// Same spin-lock design as server/events.zig (std.Thread.Mutex lives under
/// std.Io in this toolchain, which a plain static can't carry).
const RunLock = struct {
    locked: std.atomic.Value(bool) = .init(false),
    fn lock(self: *RunLock) void {
        var spins: u32 = 0;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins >= 16) {
                const req: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                _ = nanosleep(&req, null);
            } else std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *RunLock) void {
        self.locked.store(false, .release);
    }
};

var g_run_mutex: RunLock = .{};
var g_apx_state: ?*ApxState = null;
var g_ask_storage: ask_user.AskCtx = .{};
/// Dynamic-Cordis wiring slot (preset_tools.setCordisCtx points here); the
/// lifecycle pointer is the process-global sharedDynamicLifecycle() singleton,
/// so a plain static outlives every per-run Built.
var g_cordis_deps: preset_tools.CordisDeps = undefined;

/// Publish an `approval/request` Remote-Event waterfall for the vendored
/// ui-approval consumer. The client answers through `$events.result` with the
/// same eventId; ApprovalStore.resolveEvent settles it.
fn publishApprovalRequest(approval_id: []const u8, tool_name: []const u8, reason: []const u8, session_id: []const u8) void {
    const alloc = gpaAlloc();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.appendSlice(alloc, "{\"type\":\"waterfall\",\"event\":\"approval/request\",\"eventId\":\"") catch return;
    out.appendSlice(alloc, approval_id) catch return;
    out.appendSlice(alloc, "\",\"agentId\":\"") catch return;
    out.appendSlice(alloc, session_id) catch return;
    out.appendSlice(alloc, "\",\"request\":{\"toolName\":\"") catch return;
    model.escape(alloc, tool_name, &out) catch return;
    out.appendSlice(alloc, "\",\"reason\":\"") catch return;
    model.escape(alloc, reason, &out) catch return;
    out.appendSlice(alloc, "\"}}") catch return;
    remote_mux.publishEvents(alloc, out.items);
}

fn publishAskFrame(frame_json: []const u8) void {
    if (events_ws.sharedHubs()) |hubs| hubs.mux.publishFrame(frame_json) else |_| {}
    forwardQuestionWaterfall(frame_json);
}

/// Mirror one question/requested frame onto the remote.mux $events streams as
/// the gateway-internal waterfall the v0.1.6 user-questions UI consumes:
/// {type:'waterfall', event:'user-questions/request', eventId, agentId,
///  request:{questions:[...]}}. The GUI answers through $events/result.
fn forwardQuestionWaterfall(frame_json: []const u8) void {
    const sid = apix_jsonx.getStringAlloc(gpaAlloc(), frame_json, "sessionId") catch null;
    defer if (sid) |s| gpaAlloc().free(s);
    const rpc = apix_jsonx.getStringAlloc(gpaAlloc(), frame_json, "questionRpcId") catch null;
    defer if (rpc) |r| gpaAlloc().free(r);
    const questions_raw = apix_jsonx.getRaw(frame_json, "questions") orelse return;
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(gpaAlloc());
    const sid_j = jsonEsc(gpaAlloc(), sid orelse "") orelse return;
    defer gpaAlloc().free(sid_j);
    const rpc_j = jsonEsc(gpaAlloc(), rpc orelse "") orelse return;
    defer gpaAlloc().free(rpc_j);
    value.appendSlice(gpaAlloc(), "{\"type\":\"waterfall\",\"event\":\"user-questions/request\",\"eventId\":") catch return;
    value.appendSlice(gpaAlloc(), rpc_j) catch return;
    value.appendSlice(gpaAlloc(), ",\"agentId\":") catch return;
    value.appendSlice(gpaAlloc(), sid_j) catch return;
    value.appendSlice(gpaAlloc(), ",\"request\":{\"questions\":") catch return;
    value.appendSlice(gpaAlloc(), questions_raw) catch return;
    value.appendSlice(gpaAlloc(), "}}") catch return;
    remote_mux.publishEvents(gpaAlloc(), value.items);
}

/// Publish one SessionEventMap payload onto the mux hub, wrapped in the
/// wire envelope {type:'session/event', sessionId, event} (spec §4).
fn muxPublish(payload_json: []const u8) void {
    const sid = g_mux_run_session orelse return;
    if (std.c.getenv("ZH_DEBUG_FRAME") != null) {
        std.debug.print("[mux] {s}\n", .{payload_json[0..@min(payload_json.len, 300)]});
    }
    if (events_ws.sharedHubs()) |hubs| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpaAlloc());
        buf.appendSlice(gpaAlloc(), "{\"type\":\"session/event\",\"sessionId\":") catch return;
        if (jsonEsc(gpaAlloc(), sid)) |s| {
            defer gpaAlloc().free(s);
            buf.appendSlice(gpaAlloc(), s) catch return;
        } else return;
        buf.appendSlice(gpaAlloc(), ",\"event\":") catch return;
        buf.appendSlice(gpaAlloc(), payload_json) catch return;
        buf.appendSlice(gpaAlloc(), "}") catch return;
        hubs.mux.publish("session/event", buf.items);
    } else |_| {}
}

fn hostPublishFmtSession(session_id: []const u8, running: bool) void {
    if (jsonEsc(gpaAlloc(), session_id)) |sid| {
        defer gpaAlloc().free(sid);
        const flag: []const u8 = if (running) "true" else "false";
        const line = std.fmt.allocPrint(gpaAlloc(), "{{\"sessionId\":{s},\"running\":{s}}}", .{ sid, flag }) catch return;
        defer gpaAlloc().free(line);
        hostPublish("host/session-status", line);
    }
    // v0.1.6 session-controller live event: the GUI's session list flips the
    // running pill from this forwarded cordis event ($events stream).
    {
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(gpaAlloc());
        const sid_j = jsonEsc(gpaAlloc(), session_id) orelse return;
        defer gpaAlloc().free(sid_j);
        value.appendSlice(gpaAlloc(), "{\"type\":\"emit\",\"event\":\"api-session/status\",\"args\":[") catch return;
        value.appendSlice(gpaAlloc(), sid_j) catch return;
        value.appendSlice(gpaAlloc(), if (running) ",true]" else ",false]") catch return;
        remote_mux.publishEvents(gpaAlloc(), value.items);
    }
}

/// Push a frame on the HOST hub (workspace/session list liveness).
fn hostPublish(method: []const u8, payload_json: []const u8) void {
    if (events_ws.sharedHubs()) |hubs| {
        hubs.host.publish(method, payload_json);
    } else |_| {}
}

fn muxPublishFmt(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(gpaAlloc(), fmt, args) catch return;
    defer gpaAlloc().free(s);
    muxPublish(s);
}

/// Process-wide GPA for bridge allocations that may outlive request arenas.
var g_gpa: ?std.mem.Allocator = null;
fn gpaAlloc() std.mem.Allocator {
    return g_gpa.?;
}

/// Long-lived Io for standalone commands (serve/workflow/plugin) that do not
/// go through a cordis Context. Null for run/chat (they use the ctx's io).
var g_io: ?std.Io = null;

/// Emit a log-only observability event with a pre-serialized JSON payload.
fn emitObsRaw(event_type: []const u8, payload_json: []const u8) void {
    const st = g_obs orelse return;
    st.sink.emitAt(st.io, &st.trace, .info, event_type, payload_json);
}

/// Monotonic approval-request id source for the audit pair.
var g_approval_seq = std.atomic.Value(u64).init(0);
/// How long the interactive approval round-trip waits for a client answer.
const approval_wait_ms: u64 = 120_000;

fn verdictOf(outcome: questions.ApprovalOutcome) agent.ApprovalVerdict {
    return switch (outcome) {
        .allowed_once => .allowed,
        .rejected => .rejected,
        .cancelled => .cancelled,
        .unavailable => .unavailable,
    };
}

fn obsBegin(alloc: std.mem.Allocator, io: std.Io, session_id: []const u8) void {
    const sink = alloc.create(obs_mod.JsonlSink) catch return;
    sink.* = obs_mod.JsonlSink.init(alloc, obs_mod.default_log_path) catch {
        alloc.destroy(sink);
        return;
    };
    g_obs = .{
        .alloc = alloc,
        .io = io,
        .sink = sink,
        .trace = obs_mod.TraceCtx.start(io, session_id, "agent-1"),
    };
}

fn obsEnd(alloc: std.mem.Allocator) void {
    if (g_obs) |st| {
        st.sink.deinit();
        alloc.destroy(st.sink);
        g_obs = null;
    }
}

/// Map the loop's event stream onto dev.md §XXX event types, emitting one
/// JSONL envelope per event when observability is active. Best-effort:
/// formatting/allocation failures drop the event instead of failing the turn.
fn obsEmit(kind: agent.AgentLoop.EventKind, payload: []const u8) void {
    const st = g_obs orelse return;
    const et: []const u8 = switch (kind) {
        .turn_start => "agent.turn_start",
        .thinking => "model.thinking",
        .text => "model.text",
        .tool_call => "tool.started",
        .tool_result => "tool.completed",
        .done => "agent.stopped",
        .err => "error",
    };
    var pj: std.ArrayList(u8) = .empty;
    defer pj.deinit(st.alloc);
    pj.appendSlice(st.alloc, "{\"detail\":\"") catch return;
    model.escape(st.alloc, payload, &pj) catch return;
    pj.appendSlice(st.alloc, "\"}") catch return;
    st.sink.emitAt(st.io, &st.trace, .info, et, pj.items);
}

// ── loop extensions: skills / memory / plan / goal (dev.md §XIII–XVII) ─────

// Workspace membership: `<root>/.zharness/sessions/workspaces.json` maps
// sessionId → workspace path for sessions created in a non-root workspace.
// Storage stays at the root; the map drives sidebar grouping and the run's
// tool-execution cwd.

/// Path of the membership map file. Caller owns the memory.
fn sessionWsMapPath(alloc: std.mem.Allocator, root_cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/.zharness/sessions/workspaces.json", .{root_cwd});
}

/// Read the map as a raw JSON object body (`"sid":"cwd",…`) or null.
fn readSessionWsMap(alloc: std.mem.Allocator, io: std.Io, root_cwd: []const u8) ?[]u8 {
    const path = sessionWsMapPath(alloc, root_cwd) catch return null;
    defer alloc.free(path);
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .unlimited) catch null;
}

/// Record `sid` as belonging to the workspace at `ws_cwd`. Best effort.
fn recordSessionWs(alloc: std.mem.Allocator, io: std.Io, root_cwd: []const u8, sid: []const u8, ws_cwd: []const u8) void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    if (readSessionWsMap(alloc, io, root_cwd)) |raw| {
        defer alloc.free(raw);
        // Keep every prior entry verbatim except the one being replaced.
        var it = apix_jsonx.MemberIter.init(raw);
        while (it.next()) |m| {
            const key = apix_jsonx.decodeString(alloc, m.key) catch continue;
            defer alloc.free(key);
            if (std.mem.eql(u8, key, sid)) continue;
            body.appendSlice(alloc, if (body.items.len > 0) "," else "") catch return;
            body.appendSlice(alloc, m.key) catch return;
            body.append(alloc, ':') catch return;
            body.appendSlice(alloc, m.value) catch return;
        }
    }
    var sid_j: std.ArrayList(u8) = .empty;
    defer sid_j.deinit(alloc);
    apix_jsonx.appendJsonString(alloc, &sid_j, sid) catch return;
    var cwd_j: std.ArrayList(u8) = .empty;
    defer cwd_j.deinit(alloc);
    apix_jsonx.appendJsonString(alloc, &cwd_j, ws_cwd) catch return;
    const doc = std.fmt.allocPrint(alloc, "{{{s}{s}:{s}}}", .{ body.items, sid_j.items, cwd_j.items }) catch return;
    defer alloc.free(doc);
    const path = sessionWsMapPath(alloc, root_cwd) catch return;
    defer alloc.free(path);
    const dir = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
    std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = doc }) catch {};
}

/// The workspace cwd recorded for `sid`, or null when it belongs to the root.
fn sessionWsFor(alloc: std.mem.Allocator, io: std.Io, root_cwd: []const u8, sid: []const u8) ?[]const u8 {
    const raw = readSessionWsMap(alloc, io, root_cwd) orelse return null;
    defer alloc.free(raw);
    var sid_buf: [84]u8 = undefined;
    if (sid.len + 2 > sid_buf.len) return null;
    sid_buf[0] = '"';
    @memcpy(sid_buf[1 .. sid.len + 1], sid);
    sid_buf[sid.len + 1] = '"';
    const key = sid_buf[0 .. sid.len + 2];
    const pos = std.mem.indexOf(u8, raw, key) orelse return null;
    var v = pos + key.len;
    while (v < raw.len and (raw[v] == ' ' or raw[v] == ':')) : (v += 1) {
        if (raw[v] == ':') {
            v += 1;
            break;
        }
    }
    while (v < raw.len and (raw[v] == ' ' or raw[v] == '\t')) : (v += 1) {}
    if (v >= raw.len or raw[v] != '"') return null;
    const end = std.mem.indexOfScalarPos(u8, raw, v + 1, '"') orelse return null;
    return apix_jsonx.decodeString(alloc, raw[v + 1 .. end]) catch null;
}

/// Re-register the workspaces adopted in earlier runs: config.toml
/// [workspaces] adopted = ["<abs path>", …] → remote.mux baseline rows
/// under deterministic ws-<hash> ids.
fn restoreAdoptedWorkspaces(alloc: std.mem.Allocator, home: []const u8) !void {
    if (home.len == 0) return;
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/.zharness/config.toml", .{home});
    defer alloc.free(cfg_path);
    const doc = std.Io.Dir.readFileAlloc(.cwd(), g_io orelse return, cfg_path, alloc, .unlimited) catch return;
    defer alloc.free(doc);
    const entries = (config.parseTomlFlat(alloc, doc) catch return) orelse return;
    for (entries) |e| {
        if (!std.mem.eql(u8, e.section, "workspaces") or !std.mem.eql(u8, e.key, "adopted")) continue;
        if (e.val != .str) continue;
        const id = try apiproxy.workspaceIdFor(alloc, e.val.str);
        defer alloc.free(id);
        remote_mux.addExtraWorkspace(id, e.val.str, std.fs.path.basename(e.val.str)) catch continue;
    }
}

fn homeDir() ?[]const u8 {
    const p = std.c.getenv("HOME") orelse return null;
    const h = std.mem.span(p);
    if (h.len == 0) return null;
    return h;
}

/// Split an --mcp command line on whitespace (no quote handling yet —
/// document this in --help). Returns an owned argv slice; empty input yields
/// an empty slice so callers can skip cheaply.
fn splitCommand(alloc: std.mem.Allocator, cmd: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    while (it.next()) |tok| try out.append(alloc, tok);
    return out.toOwnedSlice(alloc);
}

/// Preset gate for the CORE builtin toolset only (dev.md §XXVIII): names not
/// listed by the preset are removed from the registry. Harness capabilities
/// (plan/goal/memory/skill/web/mcp/plugin/spawn_agent) always stay available.
fn builtinAllowedByPreset(allowed: []const []const u8, name: []const u8) bool {
    for (allowed) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

/// True for names any preset toolkit mentions (the classic fs/shell/git
/// surface) — the only tools preset filtering may remove. Derived from
/// presets.table so the two cannot drift apart.
fn isPresetConstrainedName(name: []const u8) bool {
    for (presets_mod.table) |spec| {
        for (spec.tools) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
    }
    return false;
}

/// Translate parsed CLI flags into loop options (preset selection + MCP
/// servers). Exits with a usage message on invalid preset names.
fn optsFromFlags(alloc: std.mem.Allocator, flags: *const cli_flags.SubFlags) !LoopOpts {
    var lopts = LoopOpts{};
    if (flags.preset) |pname| {
        lopts.preset = presets_mod.fromString(pname) catch {
            std.debug.print("error: unknown preset '{s}' (standard | minimal | ptc | creative)\n", .{pname});
            std.process.exit(1);
        };
    }
    if (flags.mcp_count > 0) {
        const cmds = try alloc.alloc([]const u8, flags.mcp_count);
        for (0..flags.mcp_count) |i| cmds[i] = flags.mcp_cmds[i].?;
        lopts.mcp_cmds = cmds;
    }
    return lopts;
}

/// Hot-reload primitive: fresh Config from disk for ONE run, with the
/// serve-time CLI overrides re-applied (env > flags > file precedence kept).
fn loadRunConfig(alloc: std.mem.Allocator, base: *config.Config, ov: ServeOverrides) !config.Config {
    _ = base;
    var cfg = try config.load(alloc);
    errdefer cfg.deinit();
    try cfg.applyOverrides(ov.model, ov.provider, ov.no_stream);
    applySandboxOverride(&cfg, ov.sandbox);
    return cfg;
}

/// Apply the --sandbox flag directly onto the loaded config.
fn applySandboxOverride(cfg: *config.Config, flag: ?[]const u8) void {
    const v = flag orelse return;
    cfg.sandbox_mode = config.Config.SandboxMode.fromString(v);
}

/// Apply the permission flags onto the loaded config. --sandbox and --approval
/// set the individual knobs; --permission-preset bundles both atomically and
/// wins over them (upstream dsh-permission-presets).
fn applyPermissionFlagOverrides(cfg: *config.Config, flags: cli_flags.SubFlags) void {
    applySandboxOverride(cfg, flags.sandbox);
    if (flags.approval) |a| {
        cfg.approval_mode = config.Config.ApprovalMode.fromString(a) orelse {
            std.debug.print("error: unknown approval policy '{s}' (ask | never)\n", .{a});
            std.process.exit(1);
        };
    }
    if (flags.permission_preset) |p| {
        const m = sandbox_mod.configForPreset(p) orelse {
            std.debug.print(
                "error: unknown permission preset '{s}' (read-only | workspace-write | danger-full-access)\n",
                .{p},
            );
            std.process.exit(1);
        };
        cfg.sandbox_mode = switch (m.preset) {
            .read_only => .native,
            .workspace_write => .process,
            .danger_full_access => .none,
            .custom => return,
        };
        cfg.approval_mode = if (std.mem.eql(u8, m.approval, "never")) .never else .ask;
    }
}

/// The agent-loop extension state. Everything here is main-owned; the loop
/// only sees the two fn pointers exposed via `extensions()`.
pub const LoopExtensions = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Discovered SKILL.md packages (null when none were found).
    skills: ?*skill_mod.SkillRegistry = null,
    /// Durable key/value facts at ~/.zharness/memory (null without HOME).
    memory: ?*mem_persistent.PersistentStore = null,
    /// In-RAM task/plan scratchpad rendered into context.
    working: ?*mem_working.WorkingMemory = null,
    plan_board: *plan_mod.PlanBoard,
    goal_board: *goal_mod.GoalBoard,
    todo_board: *todo_mod.TodoBoard,
    /// Native dylib plugins (null when no plugin dirs had loadable entries).
    plugins: ?*plugin_loader.PluginRegistry = null,
    /// WASM plugin registry (null when no .wasm tools were discovered).
    wasm: ?*wasm_loader.WasmRegistry = null,
    /// Workspace cwd for cwd-aware extension tools (web_fetch etc.).
    cwd: []const u8,
    /// Current session id for GUI projection publishers; empty for CLI runs.
    session_id: []const u8 = "",
    /// Approval policy consulted by the permission gate (from config).
    approval_mode: config.Config.ApprovalMode = .ask,
    /// The owning loop (set after construction) for image attachments.
    loop: ?*agent.AgentLoop = null,

    pub fn extensions(self: *LoopExtensions) agent.Extensions {
        return .{
            .ctx = self,
            .renderContext = renderContext,
            .executeTool = execTool,
            .approve = approve,
        };
    }

    /// Permission gate: consult the shared ApprovalStore for this session.
    /// Fail-closed — with no interactive answerer \`ask\` resolves unavailable
    /// (a denial) and \`never\` rejects outright.
    fn approve(ctx: *anyopaque, tool_name: []const u8, reason: []const u8) agent.ApprovalVerdict {
        const self: *LoopExtensions = @ptrCast(@alignCast(ctx));
        const store = questions.sharedApprovalStore() catch return .unavailable;
        store.setPolicy(self.session_id, switch (self.approval_mode) {
            .ask => .ask,
            .never => .never,
        }) catch return .unavailable;
        // Interactive round-trip when a GUI answerer is attached: publish an
        // approval/request waterfall and wait for the client's $events.result.
        if (store.hasAnswerer()) {
            var idbuf: [32]u8 = undefined;
            const n = g_approval_seq.fetchAdd(1, .monotonic) + 1;
            const aid = std.fmt.bufPrint(&idbuf, "approval-{d}", .{n}) catch return .unavailable;
            store.openRequest(aid) catch return .unavailable;
            defer store.drop(aid);
            publishApprovalRequest(aid, tool_name, reason, self.session_id);
            const outcome = store.await(aid, approval_wait_ms, 250);
            auditApproval(tool_name, reason, outcome);
            return verdictOf(outcome);
        }

        const outcome = store.check(self.session_id);
        auditApproval(tool_name, reason, outcome);
        return verdictOf(outcome);
    }

    /// Log-only approval audit pair (approval/asked + approval/decided),
    /// mirroring upstream dsh-user-approval. Best-effort: no observability
    /// sink means no event.
    fn auditApproval(tool_name: []const u8, reason: []const u8, outcome: questions.ApprovalOutcome) void {
        const st = g_obs orelse return;
        const n = g_approval_seq.fetchAdd(1, .monotonic) + 1;
        var idbuf: [32]u8 = undefined;
        const aid = std.fmt.bufPrint(&idbuf, "approval-{d}", .{n}) catch return;
        const asked = std.fmt.allocPrint(
            st.alloc,
            "{{\"approvalId\":\"{s}\",\"toolName\":\"{s}\",\"reason\":\"{s}\"}}",
            .{ aid, tool_name, reason },
        ) catch return;
        defer st.alloc.free(asked);
        st.sink.emitAt(st.io, &st.trace, .info, "approval/asked", asked);
        const decided = std.fmt.allocPrint(
            st.alloc,
            "{{\"approvalId\":\"{s}\",\"outcome\":\"{s}\"}}",
            .{ aid, outcome.asStr() },
        ) catch return;
        defer st.alloc.free(decided);
        st.sink.emitAt(st.io, &st.trace, .info, "approval/decided", decided);
    }

    /// Dynamic system-prompt section: skill index + goal + plan checklist +
    /// working memory snapshot, joined with blank lines. "" when inactive.
    fn renderContext(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]const u8 {
        const self: *LoopExtensions = @ptrCast(@alignCast(ctx));
        var parts: std.ArrayList([]const u8) = .empty;
        defer {
            for (parts.items) |p| alloc.free(p);
            parts.deinit(alloc);
        }
        if (self.skills) |reg| {
            const s = try reg.renderPromptSection(alloc);
            if (s.len > 0) try parts.append(alloc, s) else alloc.free(s);
        }
        if (self.goal_board.current()) |g| {
            const s = try std.fmt.allocPrint(alloc, "## Current goal [{s}]\n{s}", .{ g.status.asStr(), g.text });
            try parts.append(alloc, s);
        }
        {
            const s = try self.plan_board.renderPrompt(alloc);
            if (s.len > 0) try parts.append(alloc, s) else alloc.free(s);
        }
        if (self.todo_board.count() > 0) {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            try out.appendSlice(alloc, "## Todos\n");
            for (self.todo_board.items.items) |it| {
                const mk = switch (it.status) {
                    .pending => "[ ]",
                    .in_progress => "[~]",
                    .completed => "[x]",
                };
                try out.appendSlice(alloc, mk);
                try out.appendSlice(alloc, " ");
                try out.appendSlice(alloc, it.content);
                try out.append(alloc, '\n');
            }
            const s = try out.toOwnedSlice(alloc);
            try parts.append(alloc, s);
        }
        if (self.working) |wm| {
            const s = try wm.snapshotPrompt(alloc);
            if (s.len > 0) try parts.append(alloc, s) else alloc.free(s);
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        for (parts.items, 0..) |p, i| {
            if (i > 0) try out.appendSlice(alloc, "\n\n");
            try out.appendSlice(alloc, p);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Serve a loop-native tool call; `null` = unknown name (the loop then
    /// falls back to the builtin executors).
    fn execTool(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, call: tool_builtin.ToolCall) anyerror!?tool_builtin.ToolResult {
        const self: *LoopExtensions = @ptrCast(@alignCast(ctx));
        if (jobs_tool.isJobTool(call.name)) return try jobs_tool.execute(alloc, io, self.cwd, call);
        if (std.mem.eql(u8, call.name, "read_image")) {
            const path = (model.extractStringField(alloc, call.arguments, "path") catch null) orelse
                return .{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, "read_image: missing 'path'") };
            defer alloc.free(path);
            const lp = self.loop orelse
                return .{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, "read_image: loop not wired") };
            return try lp.attachImage(io, path);
        }
        if (std.mem.eql(u8, call.name, "present")) {
            const r = try present_mod.execute(alloc, io, self.cwd, call);
            if (r.success) emitObsRaw("deliverable/presented", call.arguments);
            return r;
        }
        if (std.mem.eql(u8, call.name, "plan_add") or std.mem.eql(u8, call.name, "plan_update"))
            return try self.planBoardTool(alloc, call);
        if (std.mem.eql(u8, call.name, "plan_set")) return try self.planSet(alloc, call);
        if (std.mem.eql(u8, call.name, "goal_set")) return try self.goalSet(alloc, call);
        if (std.mem.eql(u8, call.name, todo_mod.todo_write_name)) return try self.todoWrite(alloc, call);
        if (std.mem.eql(u8, call.name, skill_mod.skill_use_name)) return try self.skillUse(alloc, call);
        if (std.mem.eql(u8, call.name, "memory_get")) return try self.memoryGet(alloc, call);
        if (std.mem.eql(u8, call.name, "memory_set")) return try self.memorySet(alloc, io, call);
        if (ask_user.isAskUserTool(call.name)) {
            const r = try ask_user.execute(alloc, .{ .name = call.name, .arguments = call.arguments });
            return .{ .success = r.success, .output = r.output, .err_msg = r.err_msg };
        }
        if (std.mem.eql(u8, call.name, "attachment_list") or std.mem.eql(u8, call.name, "attachment_read")) {
            const r = try tool_attachments.execute(alloc, io, self.cwd, .{ .name = call.name, .arguments = call.arguments });
            return .{ .success = r.success, .output = r.output, .err_msg = r.err_msg };
        }
        // ── swarm wave-2 tool surfaces ────────────────────────────────────
        if (std.mem.eql(u8, call.name, "run_code")) {
            const r = try run_code.execute(alloc, .{ .name = call.name, .arguments = call.arguments });
            return .{ .success = r.success, .output = r.output, .err_msg = r.err_msg };
        }
        if (std.mem.eql(u8, call.name, "spawn_agent")) {
            const r = try spawn_agent.execute(alloc, .{ .name = call.name, .arguments = call.arguments });
            // spawn_agent's ToolResult mirrors the builtin shape; re-tag it so
            // the loop's freeResult path owns the memory uniformly.
            return tool_builtin.ToolResult{ .success = r.success, .output = r.output, .err_msg = r.err_msg };
        }
        if (std.mem.eql(u8, call.name, "web_fetch") or std.mem.eql(u8, call.name, "web_search"))
            return try webfetch.execute(alloc, self.cwd, call);
        if (std.mem.startsWith(u8, call.name, "mcp_")) {
            const res = mcp_bridge.execute(alloc, call.name, call.arguments);
            return res;
        }
        if (std.mem.startsWith(u8, call.name, "cordis_")) {
            const r = try preset_tools.execute(alloc, .{ .name = call.name, .arguments = call.arguments });
            return .{ .success = r.success, .output = r.output, .err_msg = r.err_msg };
        }
        if (self.plugins) |p| {
            if (try p.execute(alloc, call.name, call.arguments)) |out| {
                return .{
                    .success = out.ok,
                    .output = out.output,
                    .err_msg = if (out.ok) null else try alloc.dupe(u8, "plugin tool failed"),
                };
            }
        }
        if (self.wasm) |w| {
            if (try w.execute(alloc, call.name, call.arguments)) |out| {
                return .{
                    .success = out.ok,
                    .output = out.output,
                    .err_msg = if (out.ok) null else try alloc.dupe(u8, "wasm tool failed"),
                };
            }
        }
        return null;
    }

    fn ok(alloc: std.mem.Allocator, msg: []const u8) !tool_builtin.ToolResult {
        return .{ .success = true, .output = try alloc.dupe(u8, msg), .err_msg = null };
    }

    fn fail(alloc: std.mem.Allocator, msg: []const u8) !tool_builtin.ToolResult {
        return .{ .success = false, .output = try alloc.dupe(u8, ""), .err_msg = try alloc.dupe(u8, msg) };
    }

    /// plan_add / plan_update delegate to plan.zig's own dispatcher.
    fn planBoardTool(self: *LoopExtensions, alloc: std.mem.Allocator, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        const msg = plan_mod.executeTool(self.plan_board, call.name, call.arguments, alloc) catch |e| switch (e) {
            error.MissingArgument => return fail(alloc, "missing argument"),
            error.BadArgument => return fail(alloc, "bad argument (unknown task id or invalid status)"),
            error.UnknownTool => return fail(alloc, "unknown plan tool"),
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (self.session_id.len > 0) plan_frames.publishPlanState(self.session_id, 1, self.plan_board);
        // msg is allocated with `alloc`; ToolResult.output has the same
        // ownership contract (freed via tool_builtin.freeResult).
        return .{ .success = true, .output = msg, .err_msg = null };
    }

    /// Replace the whole checklist from a line-based payload: one task per
    /// line, optional leading status marker `[x]` done, `[~]` in_progress,
    /// `[!]` blocked, `[ ]`/none pending.
    fn planSet(self: *LoopExtensions, alloc: std.mem.Allocator, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        var map = try tool_builtin.parseArgs(alloc, call.arguments);
        defer tool_builtin.freeArgs(alloc, &map);
        const tasks = map.get("tasks") orelse return fail(alloc, "missing tasks");

        const board_alloc = self.plan_board.alloc;
        self.plan_board.deinit();
        self.plan_board.* = plan_mod.PlanBoard.init(board_alloc);

        var added: usize = 0;
        var lines = std.mem.splitScalar(u8, tasks, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var status: plan_mod.TaskStatus = .pending;
            var text = line;
            if (std.mem.startsWith(u8, text, "[x]")) {
                status = .done;
                text = text[3..];
            } else if (std.mem.startsWith(u8, text, "[~]")) {
                status = .in_progress;
                text = text[3..];
            } else if (std.mem.startsWith(u8, text, "[!]")) {
                status = .blocked;
                text = text[3..];
            } else if (std.mem.startsWith(u8, text, "[ ]")) {
                text = text[3..];
            }
            text = std.mem.trim(u8, text, " \t");
            if (text.len == 0) continue;
            const id = try self.plan_board.addTask(text);
            _ = self.plan_board.updateStatus(id, status);
            added += 1;
        }
        const msg = try std.fmt.allocPrint(alloc, "plan replaced with {d} task(s)", .{added});
        if (self.session_id.len > 0) plan_frames.publishPlanState(self.session_id, 1, self.plan_board);
        return .{ .success = true, .output = msg, .err_msg = null };
    }

    fn goalSet(self: *LoopExtensions, alloc: std.mem.Allocator, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        var map = try tool_builtin.parseArgs(alloc, call.arguments);
        defer tool_builtin.freeArgs(alloc, &map);
        if (map.get("text")) |text| {
            if (text.len == 0) return fail(alloc, "goal text must not be empty");
            try self.goal_board.set(text);
            if (self.session_id.len > 0) goals_rpc.agentObjective(self.session_id, text);
            if (self.working) |wm| wm.set("goal", text) catch {};
            return ok(alloc, "goal set");
        }
        if (map.get("status")) |st| {
            const s = goalStatusFromStr(st) orelse
                return fail(alloc, "invalid status (active | achieved | abandoned)");
            if (!self.goal_board.updateStatus(s))
                return fail(alloc, "no active goal to transition");
            const msg = try std.fmt.allocPrint(alloc, "goal -> {s}", .{st});
            return .{ .success = true, .output = msg, .err_msg = null };
        }
        return fail(alloc, "goal_set requires 'text' or 'status'");
    }

    fn todoWrite(self: *LoopExtensions, alloc: std.mem.Allocator, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        const msg = todo_mod.executeTool(self.todo_board, call.name, call.arguments, alloc) catch |e| switch (e) {
            error.MissingArgument => return fail(alloc, "missing todos"),
            error.BadArgument => return fail(alloc, "bad argument (todos must be array of {content,status})"),
            error.InvalidTodo => return fail(alloc, "invalid todo (duplicate content, empty, or too many in_progress)"),
            error.UnknownTool => return fail(alloc, "unknown todo tool"),
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (self.session_id.len > 0) {
            // Publish todos projection (same wire key as plan_frames, but from TodoBoard).
            if (events_ws.sharedHubs()) |hubs| {
                const value = self.todo_board.toJson(hubs.mux.alloc) catch null;
                if (value) |v| {
                    defer hubs.mux.alloc.free(v);
                    const payload = plan_frames.projectionFramePayload(hubs.mux.alloc, self.session_id, 1, "todos", v) catch null;
                    if (payload) |p| {
                        defer hubs.mux.alloc.free(p);
                        hubs.mux.publish("session/projection", p);
                    }
                }
            } else |_| {}
        }
        return .{ .success = true, .output = msg, .err_msg = null };
    }

    fn skillUse(self: *LoopExtensions, alloc: std.mem.Allocator, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        const reg = self.skills orelse return fail(alloc, "no skills are available in this session");
        var map = try tool_builtin.parseArgs(alloc, call.arguments);
        defer tool_builtin.freeArgs(alloc, &map);
        const name = map.get("name") orelse return fail(alloc, "missing name");
        const body = (try reg.getBody(alloc, name)) orelse {
            const msg = try std.fmt.allocPrint(alloc, "unknown skill '{s}' (see Available skills)", .{name});
            defer alloc.free(msg);
            return fail(alloc, msg);
        };
        // body is allocated with `alloc` — same ownership as ToolResult.output.
        return .{ .success = true, .output = body, .err_msg = null };
    }

    fn memoryGet(self: *LoopExtensions, alloc: std.mem.Allocator, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        const store = self.memory orelse return fail(alloc, "persistent memory is not available");
        var map = try tool_builtin.parseArgs(alloc, call.arguments);
        defer tool_builtin.freeArgs(alloc, &map);
        const key = map.get("key") orelse return fail(alloc, "missing key");
        const value = (try store.get(alloc, key)) orelse {
            const msg = try std.fmt.allocPrint(alloc, "(no value stored for '{s}')", .{key});
            defer alloc.free(msg);
            return ok(alloc, msg);
        };
        return .{ .success = true, .output = value, .err_msg = null };
    }

    fn memorySet(self: *LoopExtensions, alloc: std.mem.Allocator, io: std.Io, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        const store = self.memory orelse return fail(alloc, "persistent memory is not available");
        var map = try tool_builtin.parseArgs(alloc, call.arguments);
        defer tool_builtin.freeArgs(alloc, &map);
        const key = map.get("key") orelse return fail(alloc, "missing key");
        const value = map.get("value") orelse return fail(alloc, "missing value");
        store.put(io, key, value) catch |e| switch (e) {
            error.InvalidKey => return fail(alloc, "invalid key (use [A-Za-z0-9_.-], max 128 chars)"),
            error.ValueTooLarge => return fail(alloc, "value too large"),
            else => return fail(alloc, @errorName(e)),
        };
        const msg = try std.fmt.allocPrint(alloc, "saved '{s}'", .{key});
        defer alloc.free(msg);
        return ok(alloc, msg);
    }
};

fn goalStatusFromStr(s: []const u8) ?goal_mod.Status {
    if (std.mem.eql(u8, s, "active")) return .active;
    if (std.mem.eql(u8, s, "achieved")) return .achieved;
    if (std.mem.eql(u8, s, "abandoned")) return .abandoned;
    return null;
}

/// Register the loop-native tools so the model sees their schemas. Executors
/// live in LoopExtensions.execTool; the names are intercepted by the agent
/// loop before builtin dispatch. skill_use is offered only when skills were
/// discovered; memory_* only when the persistent store is available.
pub fn registerExtensionTools(reg: *tool_reg.ToolRegistry, opts: struct { skills: bool, memory: bool }) !void {
    try reg.register(.{
        .name = plan_mod.TOOL_SCHEMAS[0].name,
        .description = "Add a task to your plan checklist. Use for multi-step work so progress stays visible across turns.",
        .category = .general,
        .parameters_json = plan_mod.TOOL_SCHEMAS[0].parameters_json,
    });
    try reg.register(.{
        .name = plan_mod.TOOL_SCHEMAS[1].name,
        .description = "Update a plan task's status (and optionally attach a progress note).",
        .category = .general,
        .parameters_json = plan_mod.TOOL_SCHEMAS[1].parameters_json,
    });
    try reg.register(.{
        .name = "plan_set",
        .description = "Replace the whole plan checklist. One task per line; optional leading status marker: [x] done, [~] in_progress, [!] blocked, [ ] pending.",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"tasks":{"type":"string","description":"Full plan, one task per line with optional [x]/[~]/[!]/[ ] markers"}},"required":["tasks"]}
        ,
    });
    try reg.register(.{
        .name = "goal_set",
        .description = "Set or update the current high-level goal. Provide 'text' to set/replace it, or 'status' (active|achieved|abandoned) to transition it.",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"text":{"type":"string","description":"The goal to pursue"},"status":{"type":"string","enum":["active","achieved","abandoned"],"description":"Transition the current goal instead of setting a new one"}},"required":[]}
        ,
    });
    try reg.register(.{
        .name = todo_mod.todo_write_name,
        .description = "Record and update a structured task list for the current work. Send the ENTIRE list every call — it REPLACES the previous list. Use it to plan multi-step work and show progress.",
        .category = .general,
        .parameters_json = todo_mod.TOOL_SCHEMAS[0].parameters_json,
    });
    if (opts.skills) {
        try reg.register(.{
            .name = skill_mod.skill_use_name,
            .description = "Load a skill's full instructions into context by name. See 'Available skills' in your prompt for the index.",
            .category = .general,
            .parameters_json = skill_mod.skill_use_parameters_json,
        });
    }
    if (opts.memory) {
        try reg.register(.{
            .name = "memory_get",
            .description = "Read a durable fact that survives restarts (stored under ~/.zharness/memory). Returns '(no value stored ...)' for unset keys.",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{"key":{"type":"string","description":"Memory key ([A-Za-z0-9_.-])"}},"required":["key"]}
            ,
        });
        try reg.register(.{
            .name = "memory_set",
            .description = "Persist a durable fact (max 64KB) that future sessions can read back via memory_get.",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{"key":{"type":"string","description":"Memory key ([A-Za-z0-9_.-])"},"value":{"type":"string","description":"Value to store"}},"required":["key","value"]}
            ,
        });
    }
    // Dynamic-Cordis surface (docs/dynamic-cordis-spec.md §9). Registered
    // unconditionally like ask_user: before the host calls setCordisCtx the
    // executor answers with teaching text instead of acting.
    for (preset_tools.definitions) |d| try reg.register(d);
}

// ── serve (dev.md §XXIII): HTTP API over the agent loop ─────────────────────

/// Shared state for the HTTP dependency callbacks.
/// Serve-time CLI overrides, re-applied on every per-run config reload so
/// boot-flag precedence (env > flags > file) is preserved across reloads.
pub const ServeOverrides = struct {
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    no_stream: bool = false,
    sandbox: ?[]const u8 = null,
};

const ServeState = struct {
    alloc: std.mem.Allocator,
    cfg: *config.Config,
    opts: LoopOpts,
    ov: ServeOverrides = .{},

    /// Fresh Config for ONE run: re-reads ~/.zharness/config.toml so settings
    /// edits apply to the next message without a server restart.
    fn reloadConfig(st: *ServeState, alloc: std.mem.Allocator) !config.Config {
        return loadRunConfig(alloc, st.cfg, st.ov);
    }
};

fn serveRunTask(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    prompt: []const u8,
    session_id: ?[]const u8,
) anyerror![]const u8 {
    const st: *ServeState = @ptrCast(@alignCast(@constCast(ctx.?)));
    // Hot config: re-read config.toml for THIS run (settings-page edits apply
    // to the next message). Runs are serialized by the caller's contract.
    var run_cfg = try st.reloadConfig(st.alloc);
    defer run_cfg.deinit();
    // Run on the server's long-lived allocator, then re-home the answer into
    // the request arena the API layer frees from.
    const answer = try agentRunOnce(st.alloc, &run_cfg, st.opts, prompt, session_id);
    defer st.alloc.free(answer);
    return try alloc.dupe(u8, answer);
}

fn serveListSessions(ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]api.ServerDeps.SessionSummary {
    const st: *ServeState = @ptrCast(@alignCast(@constCast(ctx.?)));
    const io = g_io.?;
    var out: std.ArrayList(api.ServerDeps.SessionSummary) = .empty;
    errdefer out.deinit(alloc);
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.zharness/sessions", .{st.cfg.cwd});
    defer alloc.free(dir_path);
    const cwd = std.Io.Dir.cwd();
    const dir = std.Io.Dir.openDir(cwd, io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return out.toOwnedSlice(alloc),
        else => return e,
    };
    defer std.Io.Dir.close(dir, io);
    // Directory iteration proved flaky for checkpoint listing; here a single
    // pass is best-effort anyway — failures yield an empty list.
    var it = std.Io.Dir.iterate(dir);
    while (it.next(io) catch null) |entry| {
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        if (std.mem.eql(u8, name, "index.json")) continue;
        const id = name[0 .. name.len - 5];
        // Message count comes from loading the transcript; skip unloadable.
        var detail = (try serveGetSession(ctx, alloc, id)) orelse continue;
        const summary = api.ServerDeps.SessionSummary{
            .id = try alloc.dupe(u8, id),
            .created_at = detail.created_at,
            .message_count = detail.messages.len,
        };
        detail.deinit(alloc);
        try out.append(alloc, summary);
    }
    return out.toOwnedSlice(alloc);
}

fn serveGetSession(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    id: []const u8,
) anyerror!?api.ServerDeps.SessionDetail {
    const st: *ServeState = @ptrCast(@alignCast(@constCast(ctx.?)));
    const io = g_io.?;
    const p = try std.fmt.allocPrint(
        alloc,
        "{s}/.zharness/sessions/{s}.json",
        .{ st.cfg.cwd, id },
    );
    defer alloc.free(p);
    const s = try alloc.create(session.Session);
    defer {
        s.deinit();
        alloc.destroy(s);
    }
    s.* = try session.Session.init(alloc, id);
    s.load(io, p) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    var msgs = try alloc.alloc(api.ServerDeps.MessageEntry, s.messages.items.len);
    for (s.messages.items, 0..) |m, i| {
        msgs[i] = .{
            .role = try alloc.dupe(u8, @tagName(m.role)),
            .content = try alloc.dupe(u8, m.content),
        };
    }
    // created_at: file mtime (best-effort — 0 when stat is unavailable).
    const created_at: i64 = blk: {
        const cwd = std.Io.Dir.cwd();
        const fstat = std.Io.Dir.statFile(cwd, io, p, .{}) catch break :blk 0;
        // Stat.mtime is an Io.Timestamp; its nanoseconds count real time.
        break :blk @intCast(@divTrunc(fstat.mtime.nanoseconds, std.time.ns_per_s));
    };
    return .{ .id = try alloc.dupe(u8, id), .created_at = created_at, .messages = msgs };
}

/// Top-level serve dispatcher: /api/* → dsh apiproxy (vendored GUI),
/// static URL space → Web UI files, everything else → legacy JSON API.
const ServeBundle = struct {
    apx_deps: *const apiproxy.ApiProxyDeps,
    api_handler: httpd.Handler,
    /// Static root for the Web UI (webui/dist — vendored dsh GUI).
    static_root: []const u8,
};

fn serveDispatch(ctx: ?*anyopaque, alloc: std.mem.Allocator, req: *const httpd.Request, res: *httpd.Responder) anyerror!void {
    const b: *ServeBundle = @ptrCast(@alignCast(@constCast(ctx.?)));
    if (std.mem.startsWith(u8, req.path, "/api/")) {
        return apiproxy.handleApiRequest(b.apx_deps, alloc, req, res);
    }
    // Host route for the ui-open-in-app plugin: zharness registers no external
    // applications, so the catalog is always empty (upstream shape).
    if (std.mem.eql(u8, req.path, "/open-in-app/apps")) {
        return res.send(.ok, .json, "{\"apps\":[]}");
    }
    if (server_static.claims(req.path)) {
        var sctx = server_static.Ctx{ .root = b.static_root };
        return server_static.handle(@ptrCast(&sctx), alloc, req, res);
    }
    return b.api_handler.call(b.api_handler.ctx, alloc, req, res);
}

/// obs.fanout chain: SSE hub (old /events) AND apiproxy WS hubs together.
fn fanoutBoth(line: []const u8) void {
    server_events.hubPublish(line);
    events_ws.publishObsEnvelope(line);
}

fn cmdServe(alloc: std.mem.Allocator, cfg: *config.Config, opts: LoopOpts, port_arg: ?[]const u8, ov: ServeOverrides) !void {
    var port: u16 = 3080;
    if (port_arg) |pa| {
        port = std.fmt.parseInt(u16, pa, 10) catch {
            std.debug.print("error: invalid port '{s}'\n", .{pa});
            std.process.exit(1);
        };
    }

    // A long-lived Io for the accept loop + per-request runs.
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    g_io = io;

    const st = try alloc.create(ServeState);
    defer alloc.destroy(st);
    st.* = .{ .alloc = alloc, .cfg = cfg, .opts = opts, .ov = ov };

    // api.handle casts its ctx straight to *ServerDeps — the state pointer
    // rides inside deps.ctx.
    const deps = try alloc.create(api.ServerDeps);
    defer alloc.destroy(deps);
    deps.* = .{
        .ctx = st,
        .runTask = serveRunTask,
        .listSessions = serveListSessions,
        .getSession = serveGetSession,
    };

    // Shared state for both API surfaces.
    g_gpa = alloc;
    const apx_state = try alloc.create(ApxState);
    defer alloc.destroy(apx_state);
    apx_state.* = .{ .alloc = alloc, .cfg = cfg, .opts = opts, .ov = ov };
    g_apx_state = apx_state;
    _ = search_rpc.installDefault(cfg.cwd) catch {};

    // Restore workspaces adopted in earlier runs (config.toml
    // [workspaces] adopted = ["…"]) into the remote.mux workspace baseline.
    restoreAdoptedWorkspaces(alloc, homeDir() orelse "") catch {};

    // dsh apiproxy surface (spec §4): unary RPC + WS event streams.
    const apx_deps = try alloc.create(apiproxy.ApiProxyDeps);
    defer alloc.destroy(apx_deps);
    apx_deps.* = .{
        .ctx = apx_state,
        .cwd = cfg.cwd,
        .home = homeDir() orelse "",
        .provider = cfg.provider,
        .model = cfg.model,
        .listSessions = apxListSessions,
        .sessionHistory = apxSessionHistory,
        .createSession = apxCreateSession,
        .promptSession = apxPromptSession,
        .cancelSession = apxCancelSession,
        .renameSession = apxRenameSession,
        .openPath = apxOpenPath,
        .pluginInventoryList = apxPluginInventoryList,
        .searchSessions = search_rpc.searchSessionsFn,
    };

    // Live event feed: agent-loop envelopes fan out to BOTH consumers —
    // the legacy SSE hub (/events) and the dsh WS hubs (events.mux/.host).
    // Install BEFORE the accept loop starts; obs.fanout is a plain var so
    // it must be set before any thread observes it.
    try server_events.install(alloc);
    _ = events_ws.sharedHubs() catch {}; // eagerly create shared frame hubs
    // Serve mode has a GUI answerer: enable the approval round-trip.
    if (questions.sharedApprovalStore() catch null) |s| s.setHasAnswerer(true);
    obs_mod.fanout = &fanoutBoth;
    // Mux baseline: each new subscriber gets session/subscribed for every
    // known session (lastSeq 0 — no durable seq store in v1).
    events_ws.on_mux_open = &apxMuxOpen;

    // Web root: vendored DeepSeek Harness GUI (webui/dist).
    const web_root: []const u8 = server_static.default_root;

    const bundle = try alloc.create(ServeBundle);
    defer alloc.destroy(bundle);
    bundle.* = .{
        .apx_deps = apx_deps,
        .api_handler = .{ .ctx = deps, .call = api.handle },
        .static_root = web_root,
    };

    var server = try httpd.Server.init(alloc, .{
        .ctx = bundle,
        .call = serveDispatch,
        // SSE + WebSocket subscribers need per-connection threads or one
        // open stream starves every other route on the accept thread.
    }, .{ .port = port, .threaded_connections = true });
    defer server.deinit();
    defer {
        obs_mod.fanout = null;
        server_events.deinstall();
    }

    std.debug.print(
        \\zharness serve listening on http://127.0.0.1:{d}
        \\  GUI (dsh):   http://127.0.0.1:{d}/          (webui dist; falls back to web/)
        \\  POST /run {{prompt, session?}}   POST /chat (same shape)
        \\  GET  /sessions  GET /sessions/<id>  GET /healthz  GET /events (live)
        \\Ctrl-C to stop.
        \\
    , .{ port, port });
    server.serveBlocking(); // never returns under normal operation
}

// ── dsh apiproxy deps: bridge vendored GUI onto zharness runtime ────────────

const ApxState = struct {
    alloc: std.mem.Allocator,
    cfg: *config.Config,
    opts: LoopOpts,
    ov: ServeOverrides = .{},
};

fn apxState(ctx: ?*anyopaque) *ApxState {
    return @ptrCast(@alignCast(ctx.?));
}

/// session.list → SessionSummary rows via the shared transcript adapter.
fn apxListSessions(ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]apiproxy.SessionSummary {
    const st = apxState(ctx);
    const io = g_io.?;
    var out: std.ArrayList(apiproxy.SessionSummary) = .empty;
    errdefer out.deinit(alloc);
    const dir = try apix_sessions.transcriptDir(alloc, st.cfg.cwd);
    defer alloc.free(dir);
    const ids = try apix_sessions.listSessionIds(io, alloc, dir);
    defer {
        for (ids) |i| alloc.free(i);
        alloc.free(ids);
    }
    for (ids) |id| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, id });
        defer alloc.free(path);
        const updated = apix_sessions.mtimeMs(io, path);
        var blank = true;
        var title: ?[]u8 = null;
        if (std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(8192))) |head| {
            defer alloc.free(head);
            blank = std.mem.indexOfScalar(u8, head, '{') == null;
            if (std.mem.indexOf(u8, head, "user") != null) {
                if (std.mem.indexOfPos(u8, head, 0, "\"content\":\"")) |ci| {
                    if (ci > 0) {
                        var ts = ci + 12;
                        if (ts < head.len and head[ts] == '"') ts += 1;
                        const te = std.mem.indexOfScalarPos(u8, head, ts, '"') orelse head.len;
                        if (te > ts) {
                            const raw = head[ts..te];
                            const clean = std.mem.trim(u8, raw, " \t\r\n");
                            const trunc = @min(clean.len, 40);
                            if (trunc > 0) title = try alloc.dupe(u8, clean[0..trunc]);
                        }
                        // Validate UTF-8: replace with session id if invalid
                        if (!std.unicode.utf8ValidateSlice(title.?)) {
                            alloc.free(title.?);
                            title = try alloc.dupe(u8, id);
                        }
                    }
                }
            }
        } else |e| switch (e) {
            error.StreamTooLong => blank = false,
            error.FileNotFound => {},
            else => return e,
        }
        const title_src: []const u8 = title orelse id;
        defer if (title) |t| alloc.free(t);
        // Workspace membership: sessions created in an adopted workspace
        // report its path (the client groups by cwd); the rest sit at root.
        const sess_cwd: []const u8 = sessionWsFor(alloc, io, st.cfg.cwd, id) orelse
            try alloc.dupe(u8, st.cfg.cwd);
        defer if (!std.mem.eql(u8, sess_cwd, st.cfg.cwd)) alloc.free(sess_cwd);
        const proj = try std.fmt.allocPrint(
            alloc,
            "{{\"asOfSeq\":-1,\"values\":{{\"title\":\"{s}\"}}}}",
            .{title_src},
        );
        defer alloc.free(proj);
        try out.append(alloc, .{
            .session_id = try alloc.dupe(u8, id),
            .updated_at_ms = updated,
            .running = false,
            .blank = blank,
            .cwd = try alloc.dupe(u8, sess_cwd),
            .projections_json = try alloc.dupe(u8, proj),
        });
    }
    return out.toOwnedSlice(alloc);
}
fn apxSessionHistory(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    before_seq: ?i64,
    max_messages: ?u32,
) anyerror!apiproxy.HistoryPage {
    _ = before_seq; // v1 stores one file per session; paging starts at tail
    const st = apxState(ctx);
    const io = g_io.?;
    const path = try apix_sessions.transcriptPath(alloc, st.cfg.cwd, session_id);
    defer alloc.free(path);
    const raw = std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return error.SessionNotFound,
        else => return e,
    };
    defer alloc.free(raw);
    const msgs = try apix_sessions.parseTranscript(alloc, raw);
    defer {
        for (msgs) |m| {
            alloc.free(m.role);
            alloc.free(m.content);
            if (m.tool_call_id) |t| alloc.free(t);
            if (m.tool_calls_json) |t| alloc.free(t);
        }
        alloc.free(msgs);
    }
    const updated = apix_sessions.mtimeMs(io, path);
    return try apix_sessions.buildHistoryPage(alloc, msgs, updated, max_messages, session_id);
}

/// session.create → empty transcript file on disk.
/// host.openPath seam: open a file/directory with the OS launcher (`open` on
/// macOS). The path is shell-quoted (single-quote escaping) before popen.
fn apxOpenPath(ctx: ?*anyopaque, alloc: std.mem.Allocator, path: []const u8) anyerror!void {
    _ = ctx;
    const launcher = switch (@import("builtin").os.tag) {
        .macos => "open",
        else => "xdg-open",
    };
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(alloc);
    try cmd.appendSlice(alloc, launcher);
    try cmd.appendSlice(alloc, " '");
    for (path) |ch| {
        if (ch == '\'') {
            try cmd.appendSlice(alloc, "'\\''");
        } else {
            try cmd.append(alloc, ch);
        }
    }
    try cmd.appendSlice(alloc, "'");
    try cmd.append(alloc, 0);
    const pipe = clib.popen(@ptrCast(cmd.items.ptr), "r") orelse return error.OpenFailed;
    _ = clib.pclose(pipe);
}

fn apxCreateSession(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    opts: apiproxy.CreateOptions,
) anyerror![]const u8 {
    const st = apxState(ctx);
    const io = g_io.?;
    var id_buf: [64]u8 = undefined;
    const final_id: []const u8 = if (opts.session_id) |sid|
        sid
    else blk: {
        const now_ms: i64 = std.Io.Timestamp.now(g_io.?, .real).toMilliseconds();
        const minted = api.formatMintedSessionId(&id_buf, @divTrunc(now_ms, 1000));
        break :blk try alloc.dupe(u8, minted);
    };
    errdefer if (opts.session_id == null) alloc.free(final_id);
    if (!api.validSessionId(final_id)) return error.InvalidSessionId;

    const dir = try std.fs.path.join(alloc, &.{ st.cfg.cwd, ".zharness", "sessions" });
    defer alloc.free(dir);
    std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, final_id });
    defer alloc.free(path);
    if (std.Io.Dir.statFile(.cwd(), io, path, .{})) |_| {
        return error.SessionExists;
    } else |_| {}

    const s = try alloc.create(session.Session);
    defer {
        s.deinit();
        alloc.destroy(s);
    }
    s.* = try session.Session.init(alloc, final_id);
    try s.save(io, path);
    // Workspace membership: a session created in an adopted workspace records
    // that directory — sidebar grouping and the run's tool-execution cwd both
    // read it. Root-workspace sessions stay unmapped (the default).
    if (opts.workspace_id) |wid| {
        if (remote_mux.workspacePathFor(alloc, wid)) |ws_path| {
            defer alloc.free(ws_path);
            if (!std.mem.eql(u8, ws_path, st.cfg.cwd)) {
                recordSessionWs(alloc, io, st.cfg.cwd, final_id, ws_path);
            }
        }
    }
    // Sidebar liveness: announce the new (blank) session on the host hub.
    if (jsonEsc(gpaAlloc(), final_id)) |sid| {
        defer gpaAlloc().free(sid);
        const cwd_json = jsonEsc(gpaAlloc(), st.cfg.cwd) orelse null;
        defer if (cwd_json) |cj| gpaAlloc().free(cj);
        const line = if (cwd_json) |cj|
            std.fmt.allocPrint(gpaAlloc(), "{{\"sessionId\":{s},\"blank\":true,\"cwd\":{s}}}", .{ sid, cj }) catch null
        else
            std.fmt.allocPrint(gpaAlloc(), "{{\"sessionId\":{s},\"blank\":true}}", .{sid}) catch null;
        if (line) |l| {
            defer gpaAlloc().free(l);
            hostPublish("host/session-added", l);
        }
        // Mux baseline for the newborn session: the client's open() settles
        // on this frame (upstream pushes it on session/created).
        const sub = std.fmt.allocPrint(gpaAlloc(), "{{\"type\":\"session/subscribed\",\"sessionId\":{s},\"lastSeq\":0}}", .{sid}) catch null;
        if (sub) |sl| {
            defer gpaAlloc().free(sl);
            if (events_ws.sharedHubs()) |hubs| {
                hubs.mux.publish("session/subscribed", sl);
            } else |_| {}
        }
    }
    // Workspace attachment contract (upstream fixture attachWorkspace): the
    // newborn joins the synthesized default workspace immediately and the
    // FULL updated view rides host/workspace-changed. The client never
    // re-pulls workspace.list after create and ignores membership in every
    // other frame, so without this push the session stays unaccounted
    // forever — ConversationRoot's composer gate resolves chipTitle through
    // workspace.sessionIds containment (the phase-ready state disables its
    // cwd fallback), leaving the composer inert on a freshly picked
    // workspace. Prepend order matches the fixture.
    {
        const scan = apix_sessions.listSessionIds(io, alloc, dir) catch null;
        if (scan) |ids| {
            defer {
                for (ids) |i| alloc.free(i);
                alloc.free(ids);
            }
            var ordered: std.ArrayList([]const u8) = .empty;
            defer ordered.deinit(alloc);
            ordered.append(alloc, final_id) catch {};
            for (ids) |id| {
                if (!std.mem.eql(u8, id, final_id)) ordered.append(alloc, id) catch {};
            }
            if (ordered.items.len > 0) {
                var view: std.ArrayList(u8) = .empty;
                defer view.deinit(alloc);
                const now_ms_v: i64 = clib.nowTimestamp() * std.time.ms_per_s;
                apiproxy.appendWorkspaceViewJson(
                    alloc,
                    &view,
                    apiproxy.default_workspace_id,
                    st.cfg.cwd,
                    apiproxy.basename(st.cfg.cwd),
                    ordered.items,
                    now_ms_v,
                    now_ms_v,
                ) catch {};
                if (view.items.len > 0) {
                    // The wrapper owns the quotes around the view value.
                    const wrapped = std.fmt.allocPrint(gpaAlloc(), "{{\"workspace\":{s}}}", .{view.items}) catch null;
                    if (wrapped) |w| {
                        defer gpaAlloc().free(w);
                        hostPublish("host/workspace-changed", w);
                    }
                }
            }
        }
    }
    return try alloc.dupe(u8, final_id);
}

/// session.prompt → unary accept; the run itself executes detached and folds
/// its events onto the mux hub (see onEvent bridge). Runs serialize behind
/// g_run_mutex because the DebugAllocator is not thread-safe.
fn apxPromptSession(ctx: ?*anyopaque, alloc: std.mem.Allocator, req: apiproxy.PromptRequest) anyerror!apiproxy.PromptAck {
    _ = alloc;
    const st = apxState(ctx);
    if (req.mode == .steer) return error.SteerUnavailable;

    // Persist and normalize text/image parts before handing ownership to the
    // detached run. The image pipeline is vision-aware and degrades to a path
    // note for text-only providers.
    const io = g_io orelse return error.IoUnavailable;
    const vision = if (st.cfg.resolvedProfile()) |p| p.vision else false;
    // This object crosses the request boundary into the detached run, so it
    // must live on the serve allocator rather than the connection arena.
    const pi = try st.alloc.create(attachments.PromptImages);
    errdefer st.alloc.destroy(pi);
    pi.* = attachments.processPromptContent(
        st.alloc,
        io,
        ".zharness/attachments",
        req.session_id,
        req.content_json,
        vision,
    ) catch |e| return e;
    errdefer pi.deinit(st.alloc);
    const prompt_copy = pi.prompt_text;
    // The session id must outlive the REQUEST: req slices die with the
    // connection arena while the detached run is still emitting frames.
    const sid_copy: []const u8 = st.alloc.dupe(u8, req.session_id) catch return error.OutOfMemory;
    const rpc_copy: ?[]const u8 = if (req.request_id) |rid|
        st.alloc.dupe(u8, rid) catch return error.OutOfMemory
    else
        null;
    // Workspace sessions execute in their workspace directory (tool cwd);
    // storage stays at the server root. sessionWsFor allocates from st.alloc,
    // which outlives the detached run.
    const ws_cwd_copy: ?[]const u8 = sessionWsFor(st.alloc, g_io orelse return error.IoUnavailable, st.cfg.cwd, req.session_id);

    const th = std.Thread.spawn(.{}, runDetachedForGui, .{ st.alloc, st.cfg, st.ov, st.opts, sid_copy, prompt_copy, pi, rpc_copy, ws_cwd_copy }) catch |e| {
        st.alloc.free(sid_copy);
        if (rpc_copy) |rid| st.alloc.free(rid);
        if (ws_cwd_copy) |wc| st.alloc.free(wc);
        return e;
    };
    th.detach();
    return .{};
}

/// Detached GUI run: owns its own config copy; publishes turn/start +
/// user/message before the loop and assistant/turn-end after (success or
/// failure). The session id parks BEFORE the first frame — muxPublish drops
/// everything while no run session is parked.
fn runDetachedForGui(alloc: std.mem.Allocator, base_cfg: *config.Config, ov: ServeOverrides, opts: LoopOpts, session_id: []const u8, prompt: []const u8, pi: *attachments.PromptImages, request_id: ?[]const u8, exec_cwd: ?[]const u8) void {
    defer if (request_id) |rid| alloc.free(rid);
    defer if (exec_cwd) |wc| alloc.free(wc);
    // ServeState outlives every detached run (serveBlocking never returns).
    g_run_mutex.lock();
    defer g_run_mutex.unlock();

    // Hot config: re-read config.toml for THIS run (settings edits hot-apply).
    var run_cfg = loadRunConfig(alloc, base_cfg, ov) catch {
        const end_data = std.fmt.allocPrint(gpaAlloc(), "{{\"turn\":{d},\"reason\":{{\"kind\":\"error\",\"error\":{{\"message\":\"config reload failed\"}}}}}}", .{@max(g_current_turn, 1)}) catch return;
        defer gpaAlloc().free(end_data);
        _ = muxPublishEvent("turn/end", false, end_data);
        pi.deinit(alloc);
        alloc.destroy(pi);
        return;
    };
    defer run_cfg.deinit();
    const job_reg = jobs_rpc.sharedRegistry() catch null;
    const job_id = if (job_reg) |jr| jr.register("agent", prompt) else null;
    defer if (job_id) |jid| if (job_reg) |jr| {
        _ = jr.settle(jid, if (g_mux_run_error == null) .completed else .failed, g_mux_run_error);
    };
    defer {
        pi.deinit(alloc);
        alloc.destroy(pi);
    }

    // Route this run's loop events to the mux fold (parked before any frame).
    const sid_dup = gpaAlloc().dupe(u8, session_id) catch return;
    g_mux_run_session = sid_dup;
    g_ask_storage.session_id = sid_dup;
    var run_opts = opts;
    run_opts.session_id = sid_dup;
    run_opts.images = pi.image_parts;
    run_opts.exec_cwd = exec_cwd;
    defer {
        g_mux_run_session = null;
        gpaAlloc().free(sid_dup);
    }

    // Canonical live-turn prefix (fixture order): turn/start then the user
    // bubble carrying the actual prompt text. Each prompt opens the NEXT turn
    // of its session (the client groups the transcript into turn blocks) and
    // steps restart at 0 within it; message ids stay unique per event.
    g_current_turn = nextTurnFor(session_id);
    g_current_step = 0;
    const turn_data = std.fmt.allocPrint(gpaAlloc(), "{{\"turn\":{d}}}", .{g_current_turn}) catch return;
    defer gpaAlloc().free(turn_data);
    _ = muxPublishEvent("turn/start", false, turn_data);
    if (jsonEsc(gpaAlloc(), prompt)) |t| {
        defer gpaAlloc().free(t);
        // source.rpcId echoes the browser submission identity — the client
        // retires its local echo bubble only on this match; without it the
        // bubble duplicates once the durable message lands.
        const source_json = if (request_id) |rid| blk: {
            const rid_j = jsonEsc(gpaAlloc(), rid) orelse break :blk null;
            defer gpaAlloc().free(rid_j);
            break :blk std.fmt.allocPrint(gpaAlloc(), "{{\"kind\":\"user\",\"rpcId\":{s}}}", .{rid_j}) catch null;
        } else null;
        defer if (source_json) |sj| gpaAlloc().free(sj);
        const data = std.fmt.allocPrint(
            gpaAlloc(),
            "{{\"id\":\"u-{d}\",\"role\":\"user\",\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"source\":{s}}}",
            .{ g_msg_n.fetchAdd(1, .monotonic), t, source_json orelse "{\"kind\":\"user\"}" },
        ) catch null;
        if (data) |d| {
            defer gpaAlloc().free(d);
            _ = muxPublishEvent("user/message", true, d);
            const step_data = std.fmt.allocPrint(gpaAlloc(), "{{\"turn\":{d},\"step\":0}}", .{g_current_turn}) catch return;
            defer gpaAlloc().free(step_data);
            _ = muxPublishEvent("step/start", false, step_data);
        }
    }

    hostPublishFmtSession(session_id, true);
    _ = agentRunOnce(alloc, &run_cfg, run_opts, prompt, session_id) catch {
        if (g_mux_run_error == null) g_mux_run_error = gpaAlloc().dupe(u8, "run failed") catch null;
        const step_data = std.fmt.allocPrint(gpaAlloc(), "{{\"turn\":{d},\"step\":0}}", .{g_current_turn}) catch return;
        defer gpaAlloc().free(step_data);
        _ = muxPublishEvent("step/end", false, step_data);
        const end_data = std.fmt.allocPrint(gpaAlloc(), "{{\"turn\":{d},\"reason\":{{\"kind\":\"error\",\"error\":{{\"message\":\"run failed\"}}}}}}", .{g_current_turn}) catch return;
        defer gpaAlloc().free(end_data);
        _ = muxPublishEvent("turn/end", false, end_data);
        if (jsonEsc(gpaAlloc(), session_id)) |sid| {
            defer gpaAlloc().free(sid);
            const line = std.fmt.allocPrint(gpaAlloc(), "{{\"sessionId\":{s},\"message\":\"run failed\"}}", .{sid}) catch null;
            if (line) |l| {
                defer gpaAlloc().free(l);
                hostPublish("host/agent-error", l);
            }
        }
        hostPublishFmtSession(session_id, false);
        return;
    };
    if (g_mux_run_error) |msg| {
        // The loop logs model failures and returns success; end the turn as a
        // terminal error so the client renders its turn-error card.
        defer {
            gpaAlloc().free(msg);
            g_mux_run_error = null;
        }
        const msg_json = jsonEsc(gpaAlloc(), msg) orelse "";
        defer if (msg_json.len > 0) gpaAlloc().free(msg_json);
        if (msg_json.len > 0) {
            const data = std.fmt.allocPrint(gpaAlloc(), "{{\"turn\":{d},\"reason\":{{\"kind\":\"error\",\"error\":{{\"message\":{s}}}}}}}", .{ g_current_turn, msg_json }) catch null;
            if (data) |d| {
                defer gpaAlloc().free(d);
                _ = muxPublishEvent("turn/end", false, d);
            }
            if (jsonEsc(gpaAlloc(), session_id)) |sid| {
                defer gpaAlloc().free(sid);
                const line = std.fmt.allocPrint(gpaAlloc(), "{{\"sessionId\":{s},\"message\":{s}}}", .{ sid, msg_json }) catch null;
                if (line) |l| {
                    defer gpaAlloc().free(l);
                    hostPublish("host/agent-error", l);
                }
            }
        }
    } else {
        const step_data = std.fmt.allocPrint(gpaAlloc(), "{{\"turn\":{d},\"step\":{d}}}", .{ g_current_turn, g_current_step }) catch return;
        defer gpaAlloc().free(step_data);
        _ = muxPublishEvent("step/end", false, step_data);
        const end_data = std.fmt.allocPrint(gpaAlloc(), "{{\"turn\":{d},\"reason\":{{\"kind\":\"completed\"}}}}", .{g_current_turn}) catch return;
        defer gpaAlloc().free(end_data);
        _ = muxPublishEvent("turn/end", false, end_data);
    }
    hostPublishFmtSession(session_id, false);
    if (job_reg != null) {
        if (events_ws.sharedHubs()) |hubs| {
            jobs_rpc.publishJobsOn(&hubs.mux, g_io orelse return, session_id, base_cfg.cwd);
        } else |_| {}
    }
}

/// session.cancel → best-effort no-op in v1: runs are not interruptible
/// mid-model-request; the client's turn closes naturally on completion.
fn apxCancelSession(ctx: ?*anyopaque, alloc: std.mem.Allocator, session_id: []const u8) anyerror!void {
    _ = ctx;
    _ = alloc;
    if (questions.sharedStore()) |store| {
        _ = store.cancelAllForSession(session_id);
    } else |_| {}
}

/// session.rename → rename the transcript file (title == new id semantics).
fn apxRenameSession(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    title: []const u8,
) anyerror!apiproxy.RenameResult {
    const st = apxState(ctx);
    if (!api.validSessionId(title)) return error.TitleInvalid;
    const dir = try std.fs.path.join(alloc, &.{ st.cfg.cwd, ".zharness", "sessions" });
    defer alloc.free(dir);
    const old_path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, session_id });
    defer alloc.free(old_path);
    const new_path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, title });
    defer alloc.free(new_path);
    const io = g_io.?;
    _ = session.Session.deleteFile(io, old_path); // clears "absent vs busy"
    if (std.Io.Dir.statFile(.cwd(), io, new_path, .{})) |_| {
        return error.SessionExists;
    } else |_| {}
    if (std.Io.Dir.statFile(.cwd(), io, old_path, .{})) |_| {} else |_| {
        return error.SessionNotFound;
    }
    // Pre-check target existence: this toolchain's RenameError has no
    // PathAlreadyExists member, so collisions are detected before the call.
    if (std.Io.Dir.statFile(.cwd(), io, new_path, .{})) |_| {
        return error.SessionExists;
    } else |_| {}
    std.Io.Dir.rename(.cwd(), old_path, .cwd(), new_path, io) catch |e| switch (e) {
        error.FileNotFound => return error.SessionNotFound,
        else => return e,
    };
    return .{ .title = try alloc.dupe(u8, title), .seq = 1 };
}

/// Mux open hook: write a session/subscribed baseline per known session.
fn apxMuxOpen(conn: *httpd.WsConn) void {
    const st = g_apx_state orelse return;
    const io = g_io orelse return;
    const alloc = st.alloc;
    const dir = apix_sessions.transcriptDir(alloc, st.cfg.cwd) catch return;
    defer alloc.free(dir);
    const ids = apix_sessions.listSessionIds(io, alloc, dir) catch return;
    defer {
        for (ids) |i| alloc.free(i);
        alloc.free(ids);
    }
    for (ids) |id| {
        var sid_esc_buf: [256]u8 = undefined;
        const sid_json = std.fmt.bufPrint(&sid_esc_buf, "\"{s}\"", .{id}) catch continue;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(alloc);
        payload.appendSlice(alloc, "{\"type\":\"session/subscribed\",\"sessionId\":") catch continue;
        payload.appendSlice(alloc, sid_json) catch continue;
        payload.appendSlice(alloc, ",\"lastSeq\":0}") catch continue;

        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(alloc);
        frame.appendSlice(alloc, "{\"type\":\"server-request\",\"rpcId\":\"baseline-") catch continue;
        frame.appendSlice(alloc, id) catch continue;
        frame.appendSlice(alloc, "\",\"method\":\"session/subscribed\",\"payload\":") catch continue;
        frame.appendSlice(alloc, payload.items) catch continue;
        frame.appendSlice(alloc, "}") catch continue;
        conn.writeText(frame.items) catch {};
    }
}

/// pluginInventory/list → fresh scan of BOTH plugin registries over the
/// serve cwd (apiproxy/inventory.zig). Per-request dlopen is accepted; the
/// scan never mutates the running tool surface.
fn apxPluginInventoryList(ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]u8 {
    const st = apxState(ctx);
    const io = g_io orelse return error.IoUnavailable;
    const home = homeDir() orelse "";
    return apix_inventory.listValue(alloc, io, st.cfg.cwd, home);
}

// ── workflow (dev.md §XIX): JSON-defined multi-step agent runs ──────────────

const WfRunState = struct {
    alloc: std.mem.Allocator,
    cfg: *config.Config,
};

/// Step runner: one agent task per workflow step. Dependency artifacts are
/// appended to the step prompt so later steps see earlier results.
fn wfStepRunner(
    alloc: std.mem.Allocator,
    io: std.Io,
    step_prompt: []const u8,
    ctx: *const wf_exec.StepContext,
) anyerror![]u8 {
    _ = io;
    const st: *WfRunState = @ptrCast(@alignCast(ctx.user.?));

    var prompt_buf: std.ArrayList(u8) = .empty;
    defer prompt_buf.deinit(alloc);
    try prompt_buf.appendSlice(alloc, step_prompt);

    // Inline dependency artifacts so the step has full local context.
    var first = true;
    for (ctx.artifacts.items.items) |*a| {
        if (first) {
            try prompt_buf.appendSlice(alloc, "\n\n--- Prior step results ---");
            first = false;
        }
        try prompt_buf.appendSlice(alloc, "\n[step ");
        try prompt_buf.appendSlice(alloc, a.id);
        try prompt_buf.appendSlice(alloc, "]\n");
        try prompt_buf.appendSlice(alloc, a.result);
    }

    const opts = LoopOpts{};
    if (ctx.max_turns) |mt| {
        // Per-step turn budget rides through a config copy.
        st.cfg.max_turns = mt;
    }
    const answer = try agentRunOnce(st.alloc, st.cfg, opts, prompt_buf.items, null);
    // Re-home into the executor's expected allocator (`alloc` here is the
    // caller-provided one; agentRunOnce used the state's allocator).
    defer st.alloc.free(answer);
    // An empty answer means the underlying turn produced nothing usable
    // (e.g. every model request failed). Surface that as a failed step so
    // the executor's failure policy engages instead of reporting success.
    if (std.mem.trim(u8, answer, " \t\r\n").len == 0) return error.EmptyStepOutput;
    return try alloc.dupe(u8, answer);
}

fn cmdWorkflow(alloc: std.mem.Allocator, cfg: *config.Config, path: []const u8) !void {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    g_io = io;

    const raw = std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(4 * 1024 * 1024)) catch |e| {
        std.debug.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        std.process.exit(1);
    };
    defer alloc.free(raw);

    var wf = wf_mod.Workflow.parseValidated(alloc, raw) catch |e| {
        if (e == error.CyclicDependency) {
            std.debug.print("error: workflow has a dependency cycle\n", .{});
        } else {
            std.debug.print("error: invalid workflow '{s}': {s}\n", .{ path, @errorName(e) });
        }
        std.process.exit(1);
    };
    defer wf.deinit(alloc);

    const st = try alloc.create(WfRunState);
    defer alloc.destroy(st);
    st.* = .{ .alloc = alloc, .cfg = cfg };

    var ex = wf_exec.Executor.init(alloc, wfStepRunner);
    ex.user = st;
    ex.stop_on_first_failure = true;

    std.debug.print("workflow '{s}': {d} step(s)\n", .{ wf.name, wf.steps.len });
    var outcome = try ex.run(io, &wf);
    defer outcome.deinit(alloc);

    // Atomic run report next to the session state.
    const report_path = try std.fmt.allocPrint(alloc, "{s}/.zharness/runs/{s}.json", .{ cfg.cwd, wf.name });
    defer alloc.free(report_path);
    if (std.fs.path.dirname(report_path)) |d| {
        // best-effort mkdir via Io layer happens inside generate; pre-create:
        std.Io.Dir.createDirPath(.cwd(), io, d) catch {};
    }
    wf_report.generate(alloc, io, report_path, &wf, &outcome) catch |e| {
        std.debug.print("[workflow] report not written: {s}\n", .{@errorName(e)});
    };

    switch (outcome.status) {
        .completed => std.debug.print("workflow completed — report: {s}\n", .{report_path}),
        .failed => {
            std.debug.print(
                "workflow FAILED at step '{s}' ({s}) — partial report: {s}\n",
                .{ outcome.failed_step orelse "?", outcome.err orelse "?", report_path },
            );
            std.process.exit(1);
        },
    }
}

// ── plugin CLI (dev.md §XXV): list / exec against native dylib tools ────────

fn cmdPluginList(alloc: std.mem.Allocator, dir_override: ?[]const u8) !void {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var reg = plugin_loader.PluginRegistry.init(alloc);
    defer reg.deinit();
    if (dir_override) |d| {
        const n = reg.loadDir(io, d);
        if (n == 0) std.debug.print("[plugin] no loadable plugins in {s}\n", .{d});
    } else {
        reg.loadDefaultDirs(io, ".");
    }

    if (reg.tools.items.len == 0 and reg.report.items.len == 0) {
        std.debug.print("no plugins found (~/.zharness/plugins, ./plugins)\n", .{});
        return;
    }
    for (reg.tools.items) |t| {
        std.debug.print("{s}\n  {s}\n", .{ t.host_name, t.description });
    }
    for (reg.report.items) |r| {
        std.debug.print("skipped {s}: {s}\n", .{ r.path, r.reason });
    }
}

fn cmdPluginExec(alloc: std.mem.Allocator, name: []const u8, args_json: []const u8, dir_override: ?[]const u8) !void {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var reg = plugin_loader.PluginRegistry.init(alloc);
    defer reg.deinit();
    if (dir_override) |d| {
        _ = reg.loadDir(io, d);
    } else {
        reg.loadDefaultDirs(io, ".");
    }

    const outcome = (try reg.execute(alloc, name, args_json)) orelse {
        std.debug.print("error: no plugin tool named '{s}'\n", .{name});
        std.process.exit(1);
    };
    defer alloc.free(outcome.output);
    std.debug.print("{s}\n", .{outcome.output});
    if (!outcome.ok) std.process.exit(1);
}

fn printUsage() void {
    std.debug.print(
        \\zh - a native coding-agent harness
        \\
        \\Usage:
        \\  zh run "prompt"          Run a single agent task
        \\  zh chat                  Start an interactive REPL
        \\  zh serve [--port N]      HTTP API (default port 3080)
        \\  zh workflow <file.json>  Run a step workflow through the agent
        \\  zh plugin list [--dir X] List native plugin tools
        \\  zh plugin exec <name> '<json>'  Invoke a plugin tool directly
        \\  zh --help                Show this help
        \\
        \\Flags (run/chat):
        \\  --model X        Override the model
        \\  --provider Y     deepseek | openai-compat | anthropic | ollama
        \\  --no-stream      Disable streaming
        \\  --session ID     Resume/save a named session (.zharness/sessions/)
        \\  --preset NAME    standard | minimal | ptc | creative
        \\  --sandbox MODE   native | process | none (shell policy + env allowlist)
        \\  --approval P     ask | never (never = fail-closed deny)
        \\  --permission-preset NAME
        \\                   read-only | workspace-write | danger-full-access
        \\                   (sets sandbox + approval atomically)
        \\  --mcp "CMD"      Attach an MCP stdio server (repeatable, max 4;
        \\                   split on spaces — no quote handling)
        \\
        \\Wired subsystems:
        \\  skills           <workspace>/skills + ~/.zharness/skills (SKILL.md)
        \\  memory           ~/.zharness/memory (memory_get / memory_set tools)
        \\  checkpoints      .zharness/checkpoints (saved per turn + tool batch)
        \\  observability    .zharness/logs/events.jsonl (trace/span envelopes)
        \\  plugins          ~/.zharness/plugins + <workspace>/plugins (dylib ABI v1)
        \\
    , .{});
}

/// Everything buildLoop creates, with the exact teardown order in deinitBuilt.
pub const Built = struct {
    ctx: *cordis.Context,
    tools: *tool_reg.ToolRegistry,
    loop: *agent.AgentLoop,
    ag: *agent.Agent,
    acfg: *agent.AgentConfig,
    checkpoints: *checkpoint.CheckpointStore,
    lext: *LoopExtensions,
    ext_iface: *agent.Extensions,
    skills: ?*skill_mod.SkillRegistry,
    memory: ?*mem_persistent.PersistentStore,
    working: *mem_working.WorkingMemory,
    plan_board: *plan_mod.PlanBoard,
    goal_board: *goal_mod.GoalBoard,
    todo_board: *todo_mod.TodoBoard,
    /// Heap copy of the chat client used by spawn_agent children (the loop
    /// holds its own by-value copy, so children need a stable one).
    spawn_client: ?*model.ChatClient = null,
    spawn_env: ?*spawn_agent.SpawnEnv = null,
    spawn_deps: ?*spawn_agent.SpawnDeps = null,
    /// Live MCP stdio clients (one per --mcp server), torn down last.
    mcp_clients: []*mcp_mod.McpClient = &.{},
    plugins: ?*plugin_loader.PluginRegistry = null,
    wasm: ?*wasm_loader.WasmRegistry = null,

    /// Tear everything down in strict reverse-creation order (the previous
    /// inline defer chain destroyed heap objects before deinitializing them).
    pub fn deinit(self: *Built, alloc: std.mem.Allocator) void {
        // Sub-agent wiring first: nothing may reach into these once the loop
        // is gone.
        if (self.spawn_deps) |d| {
            // d.deps.tools points at Built.tools — owned and freed there.
            alloc.destroy(d);
        }
        if (self.spawn_env) |e| alloc.destroy(e);
        if (self.spawn_client) |c| {
            c.* = undefined; // client has no deinit (plain value type)
            alloc.destroy(c);
        }
        spawn_agent.clearSpawnCtx();
        run_code.clearCtx();
        ask_user.clearAskCtx();
        preset_tools.clearCordisCtx();
        for (self.mcp_clients) |c| {
            c.deinit();
            alloc.destroy(c);
        }
        if (self.mcp_clients.len > 0) alloc.free(self.mcp_clients);
        mcp_bridge.clearInstances();
        if (self.wasm) |w| {
            w.deinit();
            alloc.destroy(w);
        }
        if (self.plugins) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        self.loop.deinit();
        alloc.destroy(self.loop);
        self.ag.deinit(alloc);
        // Preset mode heap-allocates the composed system prompt (base +
        // fragment); the default path points at the static literal and must
        // not be freed.
        if (self.acfg.system_prompt.ptr != SYSTEM_PROMPT.ptr) alloc.free(self.acfg.system_prompt);
        self.tools.deinit();
        alloc.destroy(self.tools);
        alloc.destroy(self.acfg);
        alloc.destroy(self.ext_iface);
        alloc.destroy(self.lext);
        self.working.deinit();
        alloc.destroy(self.working);
        self.goal_board.deinit();
        alloc.destroy(self.goal_board);
        self.plan_board.deinit();
        alloc.destroy(self.plan_board);
        self.todo_board.deinit();
        alloc.destroy(self.todo_board);
        if (self.memory) |m| {
            m.deinit();
            alloc.destroy(m);
        }
        if (self.skills) |s| {
            s.deinit();
            alloc.destroy(s);
        }
        self.checkpoints.deinit();
        alloc.destroy(self.checkpoints);
        self.ctx.deinit();
    }
};

/// Per-invocation loop options that do not belong in Config (they come from
/// CLI flags and are not persisted).
pub const LoopOpts = struct {
    /// MCP stdio servers: each entry is a raw command line, split on spaces.
    mcp_cmds: []const []const u8 = &.{},
    preset: ?presets_mod.Kind = null,
    /// Image parts owned by the caller for the first user message.
    images: []const model.ImagePart = &.{},
    session_id: []const u8 = "",
    /// Tool-execution root for this run (workspace sessions run in their
    /// workspace directory). Storage (transcripts/checkpoints/logs) stays at
    /// cfg.cwd regardless; only AgentLoop/spawn/run_code/persona see this.
    exec_cwd: ?[]const u8 = null,
};

fn buildLoop(alloc: std.mem.Allocator, cfg: *config.Config, opts: LoopOpts) !Built {
    var ctx = try cordis.Context.init(alloc);
    errdefer ctx.deinit();
    // Execution root: workspace sessions run in their workspace directory;
    // everything storage-shaped keeps using cfg.cwd.
    const run_cwd: []const u8 = opts.exec_cwd orelse cfg.cwd;

    const tools = try alloc.create(tool_reg.ToolRegistry);
    errdefer alloc.destroy(tools);
    tools.* = try tool_reg.ToolRegistry.init(alloc);
    errdefer tools.deinit();
    try tool_reg.registerBuiltins(tools);

    // ── skills: workspace `skills/` first, then ~/.zharness/skills ────────
    var skills_reg: ?*skill_mod.SkillRegistry = null;
    errdefer if (skills_reg) |s| {
        s.deinit();
        alloc.destroy(s);
    };
    {
        // From the moment of the create below, `skills_reg` is the single
        // owner of reg — every later failure unwinds through the errdefer.
        const reg = try alloc.create(skill_mod.SkillRegistry);
        skills_reg = reg;
        reg.* = skill_mod.SkillRegistry.init(alloc);
        const ws_root = try std.fmt.allocPrint(alloc, "{s}/skills", .{cfg.cwd});
        defer alloc.free(ws_root);
        if (homeDir()) |h| {
            const home_root = try std.fmt.allocPrint(alloc, "{s}/.zharness/skills", .{h});
            defer alloc.free(home_root);
            const roots = [_][]const u8{ ws_root, home_root };
            // Discovery is best-effort: unreadable roots yield nothing.
            _ = skill_loader.loadAll(alloc, ctx.io(), &roots, reg) catch {};
        } else {
            const roots = [_][]const u8{ws_root};
            _ = skill_loader.loadAll(alloc, ctx.io(), &roots, reg) catch {};
        }
        if (reg.count() == 0) {
            skills_reg = null;
            reg.deinit();
            alloc.destroy(reg);
        }
    }

    // ── persistent memory at ~/.zharness/memory ───────────────────────────
    var memory_store: ?*mem_persistent.PersistentStore = null;
    errdefer if (memory_store) |m| {
        m.deinit();
        alloc.destroy(m);
    };
    {
        if (homeDir()) |home| {
            const dir = try std.fmt.allocPrint(alloc, "{s}/.zharness/memory", .{home});
            defer alloc.free(dir);
            const st = try alloc.create(mem_persistent.PersistentStore);
            errdefer alloc.destroy(st);
            st.* = try mem_persistent.PersistentStore.init(alloc, dir);
            // Single owner from here: the outer errdefer / teardown path.
            memory_store = st;
            // Absent/corrupt backing files are tolerated by open; real IO
            // errors degrade to "no memory" instead of failing startup.
            st.open(ctx.io()) catch {
                memory_store = null;
                st.deinit();
                alloc.destroy(st);
            };
        }
    }

    // ── plan / goal / working-memory boards ────────────────────────────────
    const working = try alloc.create(mem_working.WorkingMemory);
    errdefer alloc.destroy(working);
    working.* = mem_working.WorkingMemory.init(alloc);
    errdefer working.deinit();

    const plan_board = try alloc.create(plan_mod.PlanBoard);
    errdefer alloc.destroy(plan_board);
    plan_board.* = plan_mod.PlanBoard.init(alloc);
    errdefer plan_board.deinit();

    const goal_board = try alloc.create(goal_mod.GoalBoard);
    errdefer alloc.destroy(goal_board);
    goal_board.* = goal_mod.GoalBoard.init(alloc);
    errdefer goal_board.deinit();

    const todo_board = try alloc.create(todo_mod.TodoBoard);
    errdefer alloc.destroy(todo_board);
    todo_board.* = todo_mod.TodoBoard.init(alloc);
    errdefer todo_board.deinit();

    // Native plugin registry slot — declared before lext (which borrows it);
    // discovery + registration happen further down, after tool schemas.
    var plugins_reg: ?*plugin_loader.PluginRegistry = null;
    // WASM registry slot — same early-declaration pattern.
    var wasm_reg: ?*wasm_loader.WasmRegistry = null;
    errdefer if (plugins_reg) |p| {
        p.deinit();
        alloc.destroy(p);
    };

    // Extension state + vtable instance (both must outlive the loop).
    const lext = try alloc.create(LoopExtensions);
    errdefer alloc.destroy(lext);
    lext.* = .{
        .alloc = alloc,
        .io = ctx.io(),
        .skills = skills_reg,
        .memory = memory_store,
        .working = working,
        .plan_board = plan_board,
        .goal_board = goal_board,
        .todo_board = todo_board,
        .plugins = plugins_reg,
        .wasm = wasm_reg,
        .cwd = cfg.cwd,
        .session_id = opts.session_id,
        .approval_mode = cfg.approval_mode,
    };
    const ext_iface = try alloc.create(agent.Extensions);
    errdefer alloc.destroy(ext_iface);
    ext_iface.* = lext.extensions();

    // Loop-native tool schemas (after builtin registration). The executors
    // are reached through AgentLoop.dispatchTool → ext.executeTool.
    try registerExtensionTools(tools, .{
        .skills = skills_reg != null,
        .memory = memory_store != null,
    });

    // ── web tools (dev.md §XI): web_fetch / web_search ────────────────────
    try webfetch.registerWebTools(tools);

    // spawn_agent (dev.md §XVIII) — schema registered now; the executor slot
    // is wired right after the chat client exists below.
    try tools.register(spawn_agent.definition);
    try tools.register(run_code.definition);
    try tools.register(ask_user.definition);
    // Upstream alias — canonical is ask_user_question (advertise both,
    // document canonical). Keep alias for backward compatibility.
    if (!tools.contains(ask_user.canonical_definition.name)) {
        try tools.register(ask_user.canonical_definition);
    }
    try tool_attachments.registerAttachments(tools);
    try present_mod.register(tools);
    try jobs_tool.register(tools);
    try read_image_mod.register(tools);
    g_ask_storage = .{ .publish = publishAskFrame, .store = questions.sharedStore() catch null };
    ask_user.setAskCtx(&g_ask_storage);

    // ── dynamic Cordis (docs/dynamic-cordis-spec.md §9): lifecycle wiring.
    // Tool schemas are registered by registerExtensionTools above; here we
    // only hand the executor the process-global lifecycle singleton (the same
    // one the apiproxy router serves — definitions made via cordis_define are
    // visible to connected pages and vice versa) and the owning session id.
    // Headless runs (CLI: empty session id) get an approval budget because no
    // page can ever resolve cordis/request-run — the wait would never end.
    if (apiproxy.sharedDynamicLifecycle()) |lc| {
        if (opts.session_id.len == 0) lc.approval_timeout_ms = 30_000;
        g_cordis_deps = .{ .lc = lc, .session_id = opts.session_id };
        preset_tools.setCordisCtx(&g_cordis_deps);
    } else |_| {}

    // ── native plugins (dev.md §XXV–XXVI): best-effort discovery ──────────
    {
        const p = try alloc.create(plugin_loader.PluginRegistry);
        p.* = plugin_loader.PluginRegistry.init(alloc);
        p.loadDefaultDirs(ctx.io(), cfg.cwd);
        if (p.tools.items.len > 0) {
            const defs = try p.definitions(alloc);
            defer alloc.free(defs);
            for (defs) |d| try tools.register(d);
            for (p.report.items) |r| {
                std.debug.print("[plugin] skipped {s}: {s}\n", .{ r.path, r.reason });
            }
            plugins_reg = p;
        } else {
            p.deinit();
            alloc.destroy(p);
        }
    }

    // ── WASM plugins (dev.md §XII L2): best-effort discovery ──────────────
    errdefer if (wasm_reg) |w| {
        w.deinit();
        alloc.destroy(w);
    };
    {
        const w = try alloc.create(wasm_loader.WasmRegistry);
        w.* = wasm_loader.WasmRegistry.init(alloc);
        w.loadDefaultDirs(ctx.io(), cfg.cwd);
        if (w.tools.items.len > 0) {
            const defs = try w.definitions(alloc);
            defer alloc.free(defs);
            for (defs) |d| try tools.register(d);
            for (w.report.items) |r| {
                std.debug.print("[wasm] skipped {s}: {s}\n", .{ r.path, r.reason });
            }
            wasm_reg = w;
        } else {
            w.deinit();
            alloc.destroy(w);
        }
    }

    // ── MCP stdio servers via --mcp "<command>" (dev.md §XX) ───────────────
    var mcp_clients: []*mcp_mod.McpClient = &.{};
    // MCP `initialize` instructions, joined into the system prompt below.
    var mcp_instr: std.ArrayList(u8) = .empty;
    defer mcp_instr.deinit(alloc);
    errdefer {
        for (mcp_clients) |c| {
            c.deinit();
            alloc.destroy(c);
        }
        if (mcp_clients.len > 0) alloc.free(mcp_clients);
        mcp_bridge.clearInstances();
    }
    if (opts.mcp_cmds.len > 0) {
        const clients = try alloc.alloc(*mcp_mod.McpClient, opts.mcp_cmds.len);
        mcp_clients = clients;
        var n: usize = 0;
        for (opts.mcp_cmds, 0..) |cmd, idx| {
            const argv = splitCommand(alloc, cmd) catch continue;
            defer alloc.free(argv);
            if (argv.len == 0) continue;
            const label = std.fmt.allocPrint(alloc, "mcp{d}", .{idx}) catch continue;
            defer alloc.free(label);
            const box = try alloc.create(mcp_mod.McpClient);
            box.* = mcp_mod.McpClient.spawnChild(alloc, ctx.io(), argv) catch |e| {
                std.debug.print("[mcp] {s} ({s}): spawn failed: {s}\n", .{ label, cmd, @errorName(e) });
                alloc.destroy(box);
                continue;
            };
            var init = box.initialize() catch |e| {
                std.debug.print("[mcp] {s} ({s}): initialize failed: {s}\n", .{ label, cmd, @errorName(e) });
                box.deinit();
                alloc.destroy(box);
                continue;
            };
            defer init.deinit(alloc);
            if (init.instructions.len > 0) {
                if (mcp_instr.items.len > 0) mcp_instr.appendSlice(alloc, "\n\n") catch {};
                mcp_instr.appendSlice(alloc, "MCP server ") catch {};
                mcp_instr.appendSlice(alloc, label) catch {};
                mcp_instr.appendSlice(alloc, " instructions:\n") catch {};
                mcp_instr.appendSlice(alloc, init.instructions) catch {};
            }
            const registered = mcp_bridge.registerServerTools(alloc, tools, label, box) catch |e| blk: {
                std.debug.print("[mcp] {s} ({s}): tool listing failed: {s}\n", .{ label, cmd, @errorName(e) });
                break :blk 0;
            };
            if (registered > 0) {
                std.debug.print("[mcp] {s} ({s}): registered {d} remote tool(s)\n", .{ label, cmd, registered });
                clients[n] = box;
                n += 1;
            } else {
                box.deinit();
                alloc.destroy(box);
            }
        }
        // Exact-length shrink so Built's later free() matches the allocation.
        if (n == clients.len) {
            // already exact
        } else if (alloc.resize(clients, n)) {
            mcp_clients = clients[0..n];
        } else if (n == 0) {
            alloc.free(clients);
            mcp_clients = &.{};
        } else {
            const shrunk = try alloc.alloc(*mcp_mod.McpClient, n);
            @memcpy(shrunk, clients[0..n]);
            alloc.free(clients);
            mcp_clients = shrunk;
        }
    }
    if (mcp_clients.len > 0) try mcp_bridge.registerResourceTools(tools);

    // ── preset filtering (dev.md §XXVIII): narrow the core builtin surface.
    // Only the classic coding-toolset names (the union of the preset
    // toolkits: fs/shell/git) are constrained; extension/web/mcp/plugin/
    // subagent/cordis capabilities stay available in every preset.
    if (opts.preset) |kind| {
        const spec = presets_mod.spec(kind);
        const names = try tools.list();
        defer alloc.free(names);
        for (names) |name| {
            if (isPresetConstrainedName(name) and !builtinAllowedByPreset(spec.tools, name)) _ = tools.remove(name);
        }
        std.debug.print("[preset] {s}: {d} builtin tool(s) allowed\n", .{ spec.name, spec.tools.len });
    }

    // ── checkpoints: <cwd>/.zharness/checkpoints (main-owned store) ───────
    const cp_dir = try std.fmt.allocPrint(alloc, "{s}/.zharness/checkpoints", .{cfg.cwd});
    defer alloc.free(cp_dir);
    const checkpoints = try alloc.create(checkpoint.CheckpointStore);
    errdefer alloc.destroy(checkpoints);
    checkpoints.* = try checkpoint.CheckpointStore.init(alloc, cp_dir);
    errdefer checkpoints.deinit();

    // Streamed deltas print live; wire the sink before the client value is
    // copied into the agent loop. Provider profiles (deepseek/openai-compat/
    // anthropic/ollama — dev.md §VI) select auth style + wire format here.
    var client = if (cfg.resolvedProfile()) |prof|
        model.ChatClient.initProvider(alloc, ctx.io(), prof, cfg.model, cfg.api_key)
    else
        model.ChatClient.init(alloc, ctx.io(), cfg.endpoint, cfg.model, cfg.api_key);
    if (std.c.getenv("ZH_DEBUG_CFG") != null) {
        std.debug.print("[cfg] endpoint={s} model={s} key_len={d} provider={s}\n", .{ cfg.endpoint, cfg.model, cfg.api_key.len, cfg.provider });
    }
    client.stream_sink = onStreamDelta;

    // spawn_agent wiring (dev.md §XVIII): a heap copy of the client (the loop
    // holds its own by-value copy), plus env + deps thunks. Sub-agents are
    // NOT allowed to spawn further agents — allowed_tools excludes it.
    const spawn_client = try alloc.create(model.ChatClient);
    errdefer alloc.destroy(spawn_client);
    spawn_client.* = if (cfg.resolvedProfile()) |prof|
        model.ChatClient.initProvider(alloc, ctx.io(), prof, cfg.model, cfg.api_key)
    else
        model.ChatClient.init(alloc, ctx.io(), cfg.endpoint, cfg.model, cfg.api_key);

    const spawn_env = try alloc.create(spawn_agent.SpawnEnv);
    errdefer alloc.destroy(spawn_env);
    spawn_env.* = .{
        .client = spawn_client,
        .io = ctx.io(),
        .cwd = run_cwd,
        .sandbox_mode = cfg.sandbox_mode,
    };

    const spawn_deps = try alloc.create(spawn_agent.SpawnDeps);
    errdefer alloc.destroy(spawn_deps);
    spawn_deps.* = .{
        .deps = .{
            .alloc = alloc,
            .ctx = spawn_env,
            .chat_fn = spawn_agent.chatThunk,
            .exec_fn = spawn_agent.execThunk,
            // Children share the parent's tool surface minus spawn_agent
            // itself (the execThunk guard enforces that at runtime).
            .tools = tools,
        },
    };
    spawn_agent.setSpawnCtx(spawn_deps);
    errdefer spawn_agent.clearSpawnCtx();

    // Code Mode (run_code) wiring
    const rc_deps = try alloc.create(run_code.Deps);
    errdefer alloc.destroy(rc_deps);
    rc_deps.* = .{ .io = ctx.io(), .cwd = run_cwd, .sandbox_mode = cfg.sandbox_mode };
    run_code.setCtx(rc_deps);
    errdefer run_code.clearCtx();

    // Heap-allocate the config so the pointer `Agent` holds stays valid after
    // buildLoop returns (a stack-local would dangle and corrupt system_prompt).
    // A preset (dev.md §XXVIII) appends its prompt fragment and supplies the
    // default turn budget when config did not set one.
    var system_prompt: []const u8 = SYSTEM_PROMPT;
    var max_turns = cfg.max_turns;
    if (opts.preset) |kind| {
        const spec = presets_mod.spec(kind);
        // Persona template: {{model}}/{{cwd}} substitution
        const persona = try presets_mod.resolvePersona(alloc, spec, cfg.model, run_cwd);
        if (spec.complete_prompt) {
            // complete_prompt: persona IS the entire system prompt
            system_prompt = persona;
        } else {
            system_prompt = try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ persona, spec.system_prompt_fragment });
        }
        if (cfg.max_turns == 0) max_turns = spec.default_max_turns;
    }
    errdefer if (system_prompt.ptr != SYSTEM_PROMPT.ptr) alloc.free(system_prompt);

    // Agent instructions: per-preset custom instructions file (max 64KB)
    if (opts.preset != null or true) {
        const preset_name = if (opts.preset) |k| presets_mod.spec(k).name else "standard";
        if (instructions_mod.loadFor(alloc, cfg.cwd, preset_name) catch null) |instr| {
            defer alloc.free(instr);
            const augmented = try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ system_prompt, instr });
            if (system_prompt.ptr != SYSTEM_PROMPT.ptr) alloc.free(system_prompt);
            system_prompt = augmented;
        }
    }

    // MCP server instructions (initialize result) join the system prompt so
    // the model sees each attached server's operating guidance.
    if (mcp_instr.items.len > 0) {
        const augmented = try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ system_prompt, mcp_instr.items });
        if (system_prompt.ptr != SYSTEM_PROMPT.ptr) alloc.free(system_prompt);
        system_prompt = augmented;
    }

    const acfg = try alloc.create(agent.AgentConfig);
    errdefer alloc.destroy(acfg);
    acfg.* = .{
        .system_prompt = system_prompt,
        .max_turns = max_turns,
        .reasoning_effort = cfg.reasoning_effort,
        .stream = cfg.stream,
        .sandbox_mode = cfg.sandbox_mode,
        .compact_threshold = cfg.compact_threshold,
        .compact_keep_recent = cfg.compact_keep_recent,
        .permission_preset = sandbox_mod.presetForSandboxModeName(cfg.sandbox_mode.asStr()),
        .approval_mode = cfg.approval_mode,
    };
    const ag = try agent.Agent.init(alloc, ctx.root, acfg);

    const loop = try alloc.create(agent.AgentLoop);
    errdefer alloc.destroy(loop);
    loop.* = try agent.AgentLoop.init(alloc, ctx, ag, client, tools, run_cwd, onEvent, checkpoints, ext_iface);
    loop.first_user_images = opts.images;
    lext.loop = loop;

    return .{
        .ctx = ctx,
        .tools = tools,
        .loop = loop,
        .ag = ag,
        .acfg = acfg,
        .checkpoints = checkpoints,
        .lext = lext,
        .ext_iface = ext_iface,
        .skills = skills_reg,
        .memory = memory_store,
        .working = working,
        .plan_board = plan_board,
        .goal_board = goal_board,
        .todo_board = todo_board,
        .spawn_client = spawn_client,
        .spawn_env = spawn_env,
        .spawn_deps = spawn_deps,
        .mcp_clients = mcp_clients,
        .plugins = plugins_reg,
        .wasm = wasm_reg,
    };
}

/// Run one agent task end-to-end and return the final answer (caller frees).
/// Shared by `run`, the workflow step runner, and the HTTP server. When
/// `session_id` is given the prior transcript is seeded first and the merged
/// transcript is persisted after the run (dev.md §XV).
fn agentRunOnce(
    alloc: std.mem.Allocator,
    cfg: *config.Config,
    opts: LoopOpts,
    prompt: []const u8,
    session_id: ?[]const u8,
) ![]const u8 {
    var built = try buildLoop(alloc, cfg, opts);
    defer built.deinit(alloc);
    if (built.spawn_env) |env| env.parent_session_id = session_id orelse "";
    if (built.spawn_deps) |deps| deps.parent_session_id = session_id orelse "";
    const io = built.ctx.io();

    // Task scratchpad: the current prompt is visible in context sections.
    if (built.lext.working) |wm| wm.set("task", prompt) catch {};

    // Observability for this run (dev.md §XXX): JSONL envelopes land in
    // .zharness/logs/events.jsonl; failures never break the turn.
    obsBegin(alloc, io, session_id orelse "adhoc");
    defer obsEnd(alloc);

    // Optional named session: load any prior transcript and seed the loop so
    // the run continues the conversation.
    var session_ptr: ?*session.Session = null;
    var session_path: ?[]u8 = null;
    if (session_id) |sid| {
        const dir = try std.fs.path.join(alloc, &.{ cfg.cwd, ".zharness", "sessions" });
        std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, sid });
        alloc.free(dir);
        session_path = p;
        const s = try alloc.create(session.Session);
        errdefer alloc.destroy(s);
        s.* = try session.Session.init(alloc, sid);
        errdefer s.deinit();
        s.load(io, p) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        for (s.messages.items) |m| try built.loop.seed(alloc, m);
        // Restore durable goal/todo projections (P1 backlog item 6)
        built.goal_board.restoreFromSession(s) catch {};
        built.todo_board.restoreFromSession(s) catch {};
        if (s.stored_goal) |sg| {
            const phase: goals_rpc.Phase = if (std.mem.eql(u8, sg.phase, "paused")) .paused else if (std.mem.eql(u8, sg.phase, "blocked")) .blocked else if (std.mem.eql(u8, sg.phase, "complete")) .complete else .active;
            const snap = goals_rpc.Snapshot{ .id = sg.id, .revision = sg.revision, .objective = sg.objective, .phase = phase, .blocked_code = sg.blocked_code, .blocked_message = sg.blocked_message, .max_goal_rounds = sg.max_goal_rounds };
            if (goals_rpc.shared()) |store| {
                store.hydrate(sid, snap, sg.rounds_started, sg.created_at, sg.updated_at) catch {};
            } else |_| {}
        }
        session_ptr = s;
    }
    defer if (session_ptr) |s| {
        s.deinit();
        alloc.destroy(s);
    };
    defer if (session_path) |p| alloc.free(p);

    const answer = try built.loop.run(prompt);

    // Token accounting: provider-reported usage summed across the turns.
    const usage = built.loop.usageTotals();
    if (!usage.isZero()) {
        std.debug.print(
            "[tokens] input={d} output={d} total={d} cache_read={d} cache_write={d}\n",
            .{ usage.input_tokens, usage.output_tokens, usage.total_tokens, usage.cache_read_tokens, usage.cache_write_tokens },
        );
    }

    if (session_ptr) |s| {
        try built.loop.syncToSession(s);
        built.goal_board.syncToSession(s) catch {};
        built.todo_board.syncToSession(s) catch {};
        try s.save(io, session_path.?);
    }
    return answer;
}

fn runTask(alloc: std.mem.Allocator, cfg: *config.Config, opts: LoopOpts, prompt: []const u8, session_id: ?[]const u8) !void {
    const answer = try agentRunOnce(alloc, cfg, opts, prompt, session_id);
    defer alloc.free(answer);
    // onEvent already printed the final answer; trailing newline for `run`.
    if (session_id) |sid| {
        std.debug.print("\nsession saved: {s}/.zharness/sessions/{s}.json\n", .{ cfg.cwd, sid });
    }
    std.debug.print("\n", .{});
}

fn chatLoop(alloc: std.mem.Allocator, cfg: *config.Config, opts: LoopOpts, session_id: ?[]const u8) !void {
    var built = try buildLoop(alloc, cfg, opts);
    defer built.deinit(alloc);

    const io = built.ctx.io();

    // Optional named session: load prior transcript, resume across turns and
    // process invocations, and persist after every exchange.
    var session_ptr: ?*session.Session = null;
    var session_path: ?[]u8 = null;
    if (session_id) |sid| {
        const dir = try std.fs.path.join(alloc, &.{ cfg.cwd, ".zharness", "sessions" });
        std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, sid });
        alloc.free(dir);
        session_path = p;
        const s = try alloc.create(session.Session);
        errdefer alloc.destroy(s);
        s.* = try session.Session.init(alloc, sid);
        errdefer s.deinit();
        s.load(io, p) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        for (s.messages.items) |m| try built.loop.seed(alloc, m);
        built.goal_board.restoreFromSession(s) catch {};
        built.todo_board.restoreFromSession(s) catch {};
        if (s.stored_goal) |sg| {
            const phase: goals_rpc.Phase = if (std.mem.eql(u8, sg.phase, "paused")) .paused else if (std.mem.eql(u8, sg.phase, "blocked")) .blocked else if (std.mem.eql(u8, sg.phase, "complete")) .complete else .active;
            const snap = goals_rpc.Snapshot{ .id = sg.id, .revision = sg.revision, .objective = sg.objective, .phase = phase, .blocked_code = sg.blocked_code, .blocked_message = sg.blocked_message, .max_goal_rounds = sg.max_goal_rounds };
            if (goals_rpc.shared()) |store| {
                store.hydrate(sid, snap, sg.rounds_started, sg.created_at, sg.updated_at) catch {};
            } else |_| {}
        }
        session_ptr = s;
    }
    defer if (session_ptr) |s| {
        s.deinit();
        alloc.destroy(s);
    };
    defer if (session_path) |p| alloc.free(p);

    std.debug.print("zharness chat", .{});
    if (session_ptr) |s| std.debug.print(" — session '{s}' ({d} messages)", .{ s.id, s.count() });
    std.debug.print(" — type 'exit' or 'quit' to leave.\n\n", .{});

    while (true) {
        std.debug.print("you> ", .{});
        const owned = clib.readLineStdin(alloc) catch |e| switch (e) {
            else => return e,
        } orelse break;
        if (std.mem.eql(u8, owned, "exit") or std.mem.eql(u8, owned, "quit")) {
            alloc.free(owned);
            break;
        }
        if (owned.len == 0) {
            alloc.free(owned);
            continue;
        }
        // Refresh the task scratchpad for this exchange.
        if (built.lext.working) |wm| wm.set("task", owned) catch {};
        const answer = built.loop.run(owned) catch |e| {
            std.debug.print("\n[error] {s}\n", .{@errorName(e)});
            alloc.free(owned);
            continue;
        };
        std.debug.print("\n", .{});
        alloc.free(answer);

        if (session_ptr) |s| {
            try built.loop.syncToSession(s);
            built.goal_board.syncToSession(s) catch {};
            built.todo_board.syncToSession(s) catch {};
            try s.save(io, session_path.?);
        }
        alloc.free(owned);
    }

    if (session_ptr) |s| {
        built.goal_board.syncToSession(s) catch {};
        built.todo_board.syncToSession(s) catch {};
        try s.save(io, session_path.?);
        std.debug.print("\nsession saved: {s}\n", .{session_path.?});
    }
    std.debug.print("\nbye.\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    // Collect argv into a slice of sentinel strings (Zig 0.17: args come via
    // the init.args iterator, not std.process.argsAlloc).
    var args_list: std.ArrayList([:0]const u8) = .empty;
    defer args_list.deinit(alloc);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |arg| {
        try args_list.append(alloc, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const sub = args[1];

    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, sub, "run")) {
        if (args.len < 3) {
            std.debug.print("error: 'run' requires a prompt argument.\n", .{});
            printUsage();
            std.process.exit(1);
        }
        // flags may appear before/after the prompt; one strict parser for all
        // subcommands (missing flag values are hard errors everywhere).
        const flags = cli_flags.parseSubFlags(args[2..], 1) catch |e| {
            std.debug.print("error: invalid flags ({s}).\n", .{@errorName(e)});
            printUsage();
            std.process.exit(1);
        };
        const prompt: ?[]const u8 = flags.prompt;

        if (prompt == null) {
            std.debug.print("error: 'run' requires a prompt argument.\n", .{});
            std.process.exit(1);
        }

        const lopts = try optsFromFlags(alloc, &flags);

        // load config in a sub-allocator to apply overrides + api-key check
        var cfg = try config.load(alloc);
        defer cfg.deinit();
        try cfg.applyOverrides(flags.model, flags.provider, flags.no_stream);
        applyPermissionFlagOverrides(&cfg, flags);

        if (cfg.api_key.len == 0) {
            std.debug.print(
                "error: no API key found. Set ZHARNESS_API_KEY or DEEPSEEK_API_KEY.\n",
                .{},
            );
            std.process.exit(1);
        }

        runTask(alloc, &cfg, lopts, prompt.?, flags.session_id) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, sub, "chat")) {
        // chat honors the same strict flag set; positionals are not accepted.
        const flags = cli_flags.parseSubFlags(args[2..], 0) catch |e| {
            std.debug.print("error: invalid flags ({s}).\n", .{@errorName(e)});
            printUsage();
            std.process.exit(1);
        };

        const lopts = try optsFromFlags(alloc, &flags);

        var cfg = try config.load(alloc);
        defer cfg.deinit();
        try cfg.applyOverrides(flags.model, flags.provider, flags.no_stream);
        applyPermissionFlagOverrides(&cfg, flags);

        if (cfg.api_key.len == 0) {
            std.debug.print(
                "error: no API key found. Set ZHARNESS_API_KEY or DEEPSEEK_API_KEY.\n",
                .{},
            );
            std.process.exit(1);
        }

        chatLoop(alloc, &cfg, lopts, flags.session_id) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, sub, "serve")) {
        // serve shares the run/chat flag set plus --port.
        const flags = cli_flags.parseSubFlags(args[2..], 0) catch |e| {
            std.debug.print("error: invalid flags ({s}).\n", .{@errorName(e)});
            printUsage();
            std.process.exit(1);
        };
        var cfg = try config.load(alloc);
        defer cfg.deinit();
        try cfg.applyOverrides(flags.model, flags.provider, flags.no_stream);
        applyPermissionFlagOverrides(&cfg, flags);
        const lopts = try optsFromFlags(alloc, &flags);
        const ov = ServeOverrides{
            .model = flags.model,
            .provider = flags.provider,
            .no_stream = flags.no_stream,
            .sandbox = flags.sandbox,
        };
        cmdServe(alloc, &cfg, lopts, flags.port, ov) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, sub, "workflow")) {
        if (args.len < 3) {
            std.debug.print("error: 'workflow' requires a JSON file argument.\n", .{});
            printUsage();
            std.process.exit(1);
        }
        var cfg = try config.load(alloc);
        defer cfg.deinit();
        cmdWorkflow(alloc, &cfg, args[2]) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, sub, "plugin")) {
        if (args.len < 3) {
            std.debug.print("error: 'plugin' requires a subcommand (list | exec).\n", .{});
            printUsage();
            std.process.exit(1);
        }
        if (std.mem.eql(u8, args[2], "list")) {
            var dir_override: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--dir")) {
                    i += 1;
                    if (i < args.len) dir_override = args[i];
                }
            }
            try cmdPluginList(alloc, dir_override);
            return;
        }
        if (std.mem.eql(u8, args[2], "exec")) {
            if (args.len < 5) {
                std.debug.print("error: 'plugin exec' requires <tool-name> '<args-json>'\n", .{});
                std.process.exit(1);
            }
            // Optional --dir (same semantics as list); default dirs otherwise.
            var dir_override: ?[]const u8 = null;
            var i: usize = 5;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--dir")) {
                    i += 1;
                    if (i < args.len) dir_override = args[i];
                }
            }
            try cmdPluginExec(alloc, args[3], args[4], dir_override);
            return;
        }
        std.debug.print("error: unknown plugin subcommand '{s}'\n", .{args[2]});
        std.process.exit(1);
    }

    std.debug.print("error: unknown subcommand '{s}'\n", .{sub});
    printUsage();
    std.process.exit(1);
}
