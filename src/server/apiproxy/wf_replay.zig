//! Workflow-run replay — durable zharness workflow runs
//! (`.zharness/runs/<name>.json`, run_report.zig shape) rendered onto the
//! upstream workflow-run view vocabulary (contract truth:
//! `_ref/deepseek-harness/packages/workflow/tool-workflow/src/types.ts` +
//! `client/ui-workflow-run/src/client/{workflow-definition.ts,
//! WorkflowRunPanel.tsx}`).
//!
//! ── RECON VERDICT ───────────────────────────────────────────────────────────
//!
//! Upstream replays runs as nested Chat disclosures: the session log carries
//! `tool-workflow/run-start|agent-start|agent-end|run-end` events; the client
//! folds them (workflowRunDefinition) into one keyed node whose data is
//! `WorkflowRunChatData {name, status, phases:[{key, phase, members:[
//! {seq,label,childId,status}]}]}`. Statuses:
//!   run/member: running|completed|failed|cancelled|interrupted
//!   stopReason: completed→completed, cancelled→cancelled, error→failed.
//! There is no unary workflow-run RPC upstream either — the view is a fold.
//!
//! This module therefore ships BOTH replay paths:
//!  1. EVENT REPLAY: synthesize the tool-workflow/* session/event stream for
//!     a stored report and publish it on the mux hub — the vendored GUI folds
//!     exactly these events into the nested disclosures. Envelopes follow the
//!     sessions.schema passthrough (strict type/seq/time + wide data).
//!  2. EXTENSION RPCs (`zharness.workflowRun.list` / `.get`): direct views of
//!     the durable reports, including per-step statuses and artifacts that
//!     the event stream cannot carry (skipped steps, artifact text).
//!
//! ── MAPPING / GAPS ──────────────────────────────────────────────────────────
//!
//!   report field            → view
//!   workflow                → name / runId
//!   status completed        → 'completed' (stopReason 'completed')
//!   status failed           → 'failed'    (stopReason 'error')
//!   steps with artifact     → agent-start+agent-end outcome 'completed'
//!   failed_step             → agent-end outcome 'failed'
//!   skipped/unreached steps → NOT recorded as members (upstream records
//!                             "all members that actually started"; they
//!                             remain visible via zharness.workflowRun.get)
//!   phase                   → none in zharness reports → single phase group
//!                             with phase:null, key "missing" (the exact
//!                             collision-free identity workflowPhaseKey
//!                             defines for an absent field)
//!   childId                 → SYNTHETIC "<run>.<step>" ids. GAP: zharness
//!                             runs execute no child sessions, so members are
//!                             never navigable (upstream's navigableMembers
//!                             requires origin:'subagent' + running parent —
//!                             synthetic ids can never match).
//!   artifacts               → exposed only through zharness.workflowRun.get.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const router = @import("router.zig");
const events_ws = @import("events_ws.zig");

// ── report model (tolerant parse of run_report.zig documents) ───────────────

pub const StepStatus = enum {
    completed,
    failed,
    skipped,

    pub fn parse(s: []const u8) ?StepStatus {
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "skipped")) return .skipped;
        return null;
    }

    pub fn asStr(self: StepStatus) []const u8 {
        return @tagName(self);
    }
};

pub const StepRec = struct {
    id: []const u8,
    status: StepStatus,
    /// Runner error name next to a failing step ("StepExploded").
    err: ?[]const u8 = null,
};

pub const ArtifactRec = struct {
    id: []const u8,
    result: []const u8,
};

pub const RunReport = struct {
    name: []const u8,
    /// "completed" | "failed" (raw string preserved for unknown values).
    status: []const u8,
    created_at_secs: i64,
    steps: []StepRec,
    artifacts: []ArtifactRec,
    failed_step: ?[]const u8,
    err: ?[]const u8,

    /// Free everything this parse produced.
    pub fn deinit(self: *RunReport, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.status);
        for (self.steps) |s| {
            alloc.free(s.id);
            if (s.err) |e| alloc.free(e);
        }
        alloc.free(self.steps);
        for (self.artifacts) |a| {
            alloc.free(a.id);
            alloc.free(a.result);
        }
        alloc.free(self.artifacts);
        if (self.failed_step) |f| alloc.free(f);
        if (self.err) |e| alloc.free(e);
    }
};

pub const ParseError = error{ MalformedReport, OutOfMemory };

/// Parse one serialized run report. Missing optional fields degrade to
/// defaults; a document without a workflow name is malformed.
pub fn parseReport(alloc: std.mem.Allocator, raw: []const u8) ParseError!RunReport {
    var rep = RunReport{
        .name = "",
        .status = "unknown",
        .created_at_secs = 0,
        .steps = try alloc.alloc(StepRec, 0),
        .artifacts = try alloc.alloc(ArtifactRec, 0),
        .failed_step = null,
        .err = null,
    };
    errdefer {
        alloc.free(rep.steps);
        alloc.free(rep.artifacts);
    }

    rep.name = ((try optString(alloc, raw, "workflow")) orelse return error.MalformedReport);
    errdefer alloc.free(rep.name);
    if (rep.name.len == 0) return error.MalformedReport;
    rep.status = (try optString(alloc, raw, "status")) orelse "unknown";
    errdefer alloc.free(rep.status);
    rep.created_at_secs = jsonx.getInt(raw, "created_at") orelse 0;
    rep.failed_step = try optString(alloc, raw, "failed_step");
    errdefer if (rep.failed_step) |f| alloc.free(f);
    rep.err = try optString(alloc, raw, "error");
    errdefer if (rep.err) |e| alloc.free(e);

    // steps array.
    if (jsonx.getRaw(raw, "steps")) |arr| {
        var steps: std.ArrayList(StepRec) = .empty;
        errdefer steps.deinit(alloc);
        var i: usize = 0;
        while (scanArrayElement(arr, &i)) |obj| {
            const id = (try optString(alloc, obj, "id")) orelse continue;
            const st_raw = (try optString(alloc, obj, "status")) orelse {
                alloc.free(id);
                continue;
            };
            const parsed = StepStatus.parse(st_raw);
            alloc.free(st_raw); // unknown statuses degrade to skipped
            const serr = try optString(alloc, obj, "error");
            try steps.append(alloc, .{ .id = id, .status = parsed orelse .skipped, .err = serr });
        }
        alloc.free(rep.steps);
        rep.steps = try steps.toOwnedSlice(alloc);
    }

    // artifacts array.
    if (jsonx.getRaw(raw, "artifacts")) |arr| {
        var arts: std.ArrayList(ArtifactRec) = .empty;
        errdefer arts.deinit(alloc);
        var i: usize = 0;
        while (scanArrayElement(arr, &i)) |obj| {
            const id = (try optString(alloc, obj, "id")) orelse continue;
            const result = (try optString(alloc, obj, "result")) orelse {
                alloc.free(id);
                continue;
            };
            try arts.append(alloc, .{ .id = id, .result = result });
        }
        alloc.free(rep.artifacts);
        rep.artifacts = try arts.toOwnedSlice(alloc);
    }

    return rep;
}

fn optString(alloc: std.mem.Allocator, json: []const u8, key: []const u8) !?[]const u8 {
    return jsonx.getStringAlloc(alloc, json, key) catch return error.OutOfMemory;
}

/// Iterate top-level object elements of a raw JSON array slice.
fn scanArrayElement(arr: []const u8, i: *usize) ?[]const u8 {
    while (i.* < arr.len) : (i.* += 1) {
        if (arr[i.*] == '{') {
            const end = jsonx.matchBraceFrom(arr, i.*) orelse return null;
            const obj = arr[i.*..end];
            i.* = end;
            return obj;
        }
    }
    return null;
}

// ── disk IO ─────────────────────────────────────────────────────────────────

/// `<cwd>/.zharness/runs` listing (file stems, sorted). Missing dir → empty.
pub fn listRunNames(io: std.Io, alloc: std.mem.Allocator, cwd: []const u8) ![][]const u8 {
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.zharness/runs", .{cwd});
    defer alloc.free(dir_path);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);

    const root = std.Io.Dir.cwd();
    const dir = std.Io.Dir.openDir(root, io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return try out.toOwnedSlice(alloc),
        else => return e,
    };
    defer std.Io.Dir.close(dir, io);

    var it = std.Io.Dir.iterate(dir);
    while (it.next(io) catch null) |entry| {
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        if (std.mem.startsWith(u8, name, ".")) continue;
        try out.append(alloc, try alloc.dupe(u8, name[0 .. name.len - ".json".len]));
    }
    std.mem.sort([]const u8, out.items, {}, lessStr);
    return out.toOwnedSlice(alloc);
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Load one run report by name. Missing → error.ReportNotFound.
pub fn loadReport(io: std.Io, alloc: std.mem.Allocator, cwd: []const u8, run_name: []const u8) !RunReport {
    const path = try std.fmt.allocPrint(alloc, "{s}/.zharness/runs/{s}.json", .{ cwd, run_name });
    defer alloc.free(path);
    const raw = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, .limited(4 << 20)) catch |e| switch (e) {
        error.FileNotFound => return error.ReportNotFound,
        else => return e,
    };
    defer alloc.free(raw);
    return parseReport(alloc, raw) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.MalformedReport => error.MalformedReport,
    };
}

// ── view shapes ─────────────────────────────────────────────────────────────

/// Upstream WorkflowRunStatus subset a settled report can express.
fn runStatusStr(report_status: []const u8) []const u8 {
    if (std.mem.eql(u8, report_status, "failed")) return "failed";
    if (std.mem.eql(u8, report_status, "completed")) return "completed";
    return "interrupted"; // unknown report state renders as interrupted
}

/// Upstream WorkflowAgentOutcome for one step.
fn memberOutcome(s: StepStatus) []const u8 {
    return switch (s) {
        .completed => "completed",
        .failed => "failed",
        .skipped => "cancelled", // never started; not surfaced as a member
    };
}

/// Synthetic childId for one member ("<run>.<step>"). Caller frees.
fn childIdOf(alloc: std.mem.Allocator, run_name: []const u8, step_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ run_name, step_id });
}

/// Build the `zharness.workflowRun.get` VALUE:
///
///   {"run":{"name":"smoke","status":"completed","phases":[
///      {"key":"missing","phase":null,"members":[
///        {"seq":0,"label":"a","childId":"smoke.a","status":"completed"},…]}]},
///    "steps":[{"id":"a","status":"completed"},…],
///    "artifacts":[{"id":"a","result":"…"}],
///    "failedStep":null,"error":null}
///
/// `run_name` is the on-disk run id used to mint childIds.
pub fn runDetailValue(
    alloc: std.mem.Allocator,
    run_name: []const u8,
    rep: *const RunReport,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "{\"run\":{\"name\":");
    try jsonx.appendJsonString(alloc, &out, rep.name);
    try out.appendSlice(alloc, ",\"status\":");
    try jsonx.appendJsonString(alloc, &out, runStatusStr(rep.status));
    try out.appendSlice(alloc, ",\"phases\":[{\"key\":\"missing\",\"phase\":null,\"members\":[");

    var member_seq: usize = 0;
    for (rep.steps) |*s| {
        if (s.status == .skipped) continue; // only members that actually ran
        if (member_seq > 0) try out.append(alloc, ',');
        const cid = try childIdOf(alloc, run_name, s.id);
        defer alloc.free(cid);
        try out.appendSlice(alloc, "{\"seq\":");
        try jsonx.appendInt(alloc, &out, @intCast(member_seq));
        try out.appendSlice(alloc, ",\"label\":");
        try jsonx.appendJsonString(alloc, &out, s.id);
        try out.appendSlice(alloc, ",\"childId\":");
        try jsonx.appendJsonString(alloc, &out, cid);
        try out.appendSlice(alloc, ",\"status\":");
        try jsonx.appendJsonString(alloc, &out, memberOutcome(s.status));
        try out.append(alloc, '}');
        member_seq += 1;
    }
    try out.appendSlice(alloc, "]}]}");

    // Full per-step truth including skipped steps (extension-only fields).
    try out.appendSlice(alloc, ",\"steps\":[");
    for (rep.steps, 0..) |*s, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"id\":");
        try jsonx.appendJsonString(alloc, &out, s.id);
        try out.appendSlice(alloc, ",\"status\":");
        try jsonx.appendJsonString(alloc, &out, s.status.asStr());
        if (s.err) |e| {
            try out.appendSlice(alloc, ",\"error\":");
            try jsonx.appendJsonString(alloc, &out, e);
        }
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "],\"artifacts\":[");
    for (rep.artifacts, 0..) |*a, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"id\":");
        try jsonx.appendJsonString(alloc, &out, a.id);
        try out.appendSlice(alloc, ",\"result\":");
        try jsonx.appendJsonString(alloc, &out, a.result);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "],\"failedStep\":");
    try appendOptStr(alloc, &out, rep.failed_step);
    try out.appendSlice(alloc, ",\"error\":");
    try appendOptStr(alloc, &out, rep.err);
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

fn appendOptStr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: ?[]const u8) !void {
    if (v) |s| {
        try jsonx.appendJsonString(alloc, out, s);
    } else {
        try out.appendSlice(alloc, "null");
    }
}

/// Build the `zharness.workflowRun.list` VALUE:
///   {"items":[{"run":"<stem>","name":"<workflow>","status":"completed",
///             "createdAt":1787470611000}]}
pub fn runListValue(io: std.Io, alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const names = try listRunNames(io, alloc, cwd);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"items\":[");
    for (names, 0..) |n, i| {
        const path = try std.fmt.allocPrint(alloc, "{s}/.zharness/runs/{s}.json", .{ cwd, n });
        defer alloc.free(path);
        const raw = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, .limited(4 << 20)) catch continue;
        defer alloc.free(raw);

        const name = (optString(alloc, raw, "workflow") catch null) orelse n;
        defer alloc.free(name);
        const status = (optString(alloc, raw, "status") catch null) orelse "unknown";
        defer alloc.free(status);
        const created = (jsonx.getInt(raw, "created_at") orelse 0) * std.time.ms_per_s;

        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"run\":");
        try jsonx.appendJsonString(alloc, &out, n);
        try out.appendSlice(alloc, ",\"name\":");
        try jsonx.appendJsonString(alloc, &out, name);
        try out.appendSlice(alloc, ",\"status\":");
        try jsonx.appendJsonString(alloc, &out, runStatusStr(status));
        try out.appendSlice(alloc, ",\"createdAt\":");
        try jsonx.appendInt(alloc, &out, created);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

// ── event replay (tool-workflow/* synthesis) ────────────────────────────────

/// One pre-rendered mux-frame PAYLOAD ready for
/// `hubs.mux.publish("session/event", payload)`.
pub const ReplayFrame = struct {
    payload_json: []u8,
};

/// Synthesize the full tool-workflow event stream for one stored report:
/// run-start, then agent-start+agent-end per attempted step (report order),
/// then run-end. Envelope seq counts events from 0; member seq inside data
/// counts members from 0 (matching agent-end's pairing rule). time =
/// created_at×1000 for every frame (reports carry no per-step clocks —
/// documented gap vs upstream's live timestamps). Caller frees payload_json.
pub fn buildReplayFrames(
    alloc: std.mem.Allocator,
    session_id: []const u8,
    run_name: []const u8,
    rep: *const RunReport,
) ![]ReplayFrame {
    var frames: std.ArrayList(ReplayFrame) = .empty;
    errdefer {
        for (frames.items) |*f| alloc.free(f.payload_json);
        frames.deinit(alloc);
    }

    const time_ms = rep.created_at_secs * std.time.ms_per_s;
    var ev_seq: i64 = 0;
    var member_seq: i64 = 0;

    // run-start {"runId","name"}
    {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(alloc);
        try data.appendSlice(alloc, "{\"runId\":");
        try jsonx.appendJsonString(alloc, &data, run_name);
        try data.appendSlice(alloc, ",\"name\":");
        try jsonx.appendJsonString(alloc, &data, rep.name);
        try data.append(alloc, '}');
        try appendEventFrame(alloc, &frames, session_id, ev_seq, time_ms, "tool-workflow/run-start", data.items);
        ev_seq += 1;
    }

    // agent-start + agent-end per attempted step.
    for (rep.steps) |*s| {
        if (s.status == .skipped) continue;
        const outcome = memberOutcome(s.status);

        const cid = try childIdOf(alloc, run_name, s.id);
        defer alloc.free(cid);

        var start_data: std.ArrayList(u8) = .empty;
        defer start_data.deinit(alloc);
        try start_data.appendSlice(alloc, "{\"runId\":");
        try jsonx.appendJsonString(alloc, &start_data, run_name);
        try start_data.appendSlice(alloc, ",\"seq\":");
        try jsonx.appendInt(alloc, &start_data, member_seq);
        try start_data.appendSlice(alloc, ",\"label\":");
        try jsonx.appendJsonString(alloc, &start_data, s.id);
        try start_data.appendSlice(alloc, ",\"childId\":");
        try jsonx.appendJsonString(alloc, &start_data, cid);
        try start_data.append(alloc, '}');

        var end_data: std.ArrayList(u8) = .empty;
        defer end_data.deinit(alloc);
        try end_data.appendSlice(alloc, "{\"runId\":");
        try jsonx.appendJsonString(alloc, &end_data, run_name);
        try end_data.appendSlice(alloc, ",\"seq\":");
        try jsonx.appendInt(alloc, &end_data, member_seq);
        try end_data.appendSlice(alloc, ",\"outcome\":");
        try jsonx.appendJsonString(alloc, &end_data, outcome);
        try end_data.append(alloc, '}');

        try appendEventFrame(alloc, &frames, session_id, ev_seq, time_ms, "tool-workflow/agent-start", start_data.items);
        ev_seq += 1;
        try appendEventFrame(alloc, &frames, session_id, ev_seq, time_ms, "tool-workflow/agent-end", end_data.items);
        ev_seq += 1;
        member_seq += 1;
    }

    // run-end {"stopReason"}
    {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(alloc);
        const stop = if (std.mem.eql(u8, rep.status, "failed")) "error" else "completed";
        try data.appendSlice(alloc, "{\"runId\":");
        try jsonx.appendJsonString(alloc, &data, run_name);
        try data.appendSlice(alloc, ",\"stopReason\":");
        try jsonx.appendJsonString(alloc, &data, stop);
        try data.append(alloc, '}');
        try appendEventFrame(alloc, &frames, session_id, ev_seq, time_ms, "tool-workflow/run-end", data.items);
    }

    return frames.toOwnedSlice(alloc);
}

/// Strict SessionEvent envelope + session/event mux wrapper around wide data.
fn appendEventFrame(
    alloc: std.mem.Allocator,
    frames: *std.ArrayList(ReplayFrame),
    session_id: []const u8,
    seq: i64,
    time_ms: i64,
    ev_type: []const u8,
    data_json: []const u8,
) !void {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"session/event\",\"sessionId\":");
    try jsonx.appendJsonString(alloc, &out, session_id);
    try out.appendSlice(alloc, ",\"event\":{\"type\":");
    try jsonx.appendJsonString(alloc, &out, ev_type);
    try out.appendSlice(alloc, ",\"seq\":");
    try jsonx.appendInt(alloc, &out, seq);
    try out.appendSlice(alloc, ",\"time\":");
    try jsonx.appendInt(alloc, &out, time_ms);
    try out.appendSlice(alloc, ",\"data\":");
    try out.appendSlice(alloc, data_json);
    try out.appendSlice(alloc, "}}");
    try frames.append(alloc, .{ .payload_json = try out.toOwnedSlice(alloc) });
}

/// Publish a whole run replay onto the shared mux hub. Returns the number of
/// frames pushed (0 when no hubs are installed); write failures drop
/// individual subscribers inside FrameHub.publish.
pub fn publishReplay(session_id: []const u8, run_name: []const u8, rep: *const RunReport) usize {
    const hubs = events_ws.sharedHubs() catch return 0;
    return publishReplayOn(&hubs.mux, session_id, run_name, rep);
}

/// Test/integrator seam against an explicit hub.
pub fn publishReplayOn(
    hub: *events_ws.FrameHub,
    session_id: []const u8,
    run_name: []const u8,
    rep: *const RunReport,
) usize {
    const alloc = hub.alloc;
    const frames = buildReplayFrames(alloc, session_id, run_name, rep) catch return 0;
    defer {
        for (frames) |*f| alloc.free(f.payload_json);
        alloc.free(frames);
    }
    for (frames) |*f| hub.publish("session/event", f.payload_json);
    return frames.len;
}

// ── extension RPC handlers ──────────────────────────────────────────────────

/// G1 wiring (router.dispatch):
///   if (std.mem.eql(u8, m, "zharness.workflowRun.list"))
///       return wf_replay.handleRunList(alloc, env.rpc_id, deps.cwd);
/// (The handler owns its own threaded Io; deps.ctx is unused.)
pub fn handleRunList(
    alloc: std.mem.Allocator,
    rpc_id: []const u8,
    cwd: []const u8,
) anyerror!router.UnaryResponse {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const value = try runListValue(threaded.io(), alloc, cwd);
    return router.okValue(alloc, rpc_id, value);
}

/// Payload of `zharness.workflowRun.get`: {"run":"<name>"} (required).
/// G1 wiring mirrors handleRunList's dispatch line.
pub fn handleRunGet(
    alloc: std.mem.Allocator,
    rpc_id: []const u8,
    cwd: []const u8,
    payload: []const u8,
) anyerror!router.UnaryResponse {
    const run_name = (router.json.getStringAlloc(alloc, payload, "run") catch null) orelse
        return error.PayloadInvalid;
    defer alloc.free(run_name);
    if (run_name.len == 0) return error.PayloadInvalid;
    // Path safety: the name must not escape <cwd>/.zharness/runs/.
    for (run_name) |c| {
        if (c == '/' or c == '\\') return error.PayloadInvalid;
    }
    if (std.mem.indexOf(u8, run_name, "..") != null) return error.PayloadInvalid;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    var rep = try loadReport(threaded.io(), alloc, cwd, run_name);
    defer rep.deinit(alloc);
    const value = try runDetailValue(alloc, run_name, &rep);
    return router.okValue(alloc, rpc_id, value);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseReport tolerates the real smoke.json shape" {
    const alloc = testing.allocator;
    // Byte-identical to .zharness/runs/smoke.json (single line on disk).
    const raw =
        "{\"created_at\":1787470611,\"workflow\":\"smoke\",\"status\":\"completed\"," ++
        "\"steps\":[{\"id\":\"a\",\"status\":\"completed\"},{\"id\":\"b\",\"status\":\"completed\"}]," ++
        "\"artifacts\":[{\"id\":\"a\",\"result\":\"model request failed: stream ended without any data from the provider\"}," ++
        "{\"id\":\"b\",\"result\":\"model request failed: stream ended without any data from the provider\"}]," ++
        "\"failed_step\":null,\"error\":null}";
    var rep = try parseReport(alloc, raw);
    defer rep.deinit(alloc);
    try testing.expectEqualStrings("smoke", rep.name);
    try testing.expectEqual(@as(i64, 1787470611), rep.created_at_secs);
    try testing.expectEqual(@as(usize, 2), rep.steps.len);
    try testing.expectEqual(StepStatus.completed, rep.steps[0].status);
    try testing.expectEqual(@as(usize, 2), rep.artifacts.len);
    try testing.expect(rep.failed_step == null);

    // Malformed: no workflow name.
    try testing.expectError(error.MalformedReport, parseReport(alloc, "{}"));
}

test "runDetailValue nests members under the missing phase and lists all steps" {
    const alloc = testing.allocator;
    const raw =
        "{\"created_at\":1700000000,\"workflow\":\"ship-it\",\"status\":\"failed\"," ++
        "\"steps\":[{\"id\":\"ok\",\"status\":\"completed\"}," ++
        "{\"id\":\"boom\",\"status\":\"failed\",\"error\":\"StepExploded\"}," ++
        "{\"id\":\"late\",\"status\":\"skipped\"}]," ++
        "\"artifacts\":[{\"id\":\"ok\",\"result\":\"fine\"}]," ++
        "\"failed_step\":\"boom\",\"error\":\"StepExploded\"}";
    var rep = try parseReport(alloc, raw);
    defer rep.deinit(alloc);

    const v = try runDetailValue(alloc, "ship-it", &rep);
    defer alloc.free(v);
    try testing.expect(std.mem.indexOf(u8, v, "\"name\":\"ship-it\",\"status\":\"failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, v, "\"phases\":[{\"key\":\"missing\",\"phase\":null,\"members\":") != null);
    try testing.expect(std.mem.indexOf(u8, v, "{\"seq\":0,\"label\":\"ok\",\"childId\":\"ship-it.ok\",\"status\":\"completed\"}") != null);
    try testing.expect(std.mem.indexOf(u8, v, "{\"seq\":1,\"label\":\"boom\",\"childId\":\"ship-it.boom\",\"status\":\"failed\"}") != null);
    // Skipped step visible only in the extension step list, never as a member.
    try testing.expect(std.mem.indexOf(u8, v, "{\"id\":\"late\",\"status\":\"skipped\"}") != null);
    try testing.expect(std.mem.indexOf(u8, v, "\"failedStep\":\"boom\"") != null);
}

test "buildReplayFrames emits the four-event fold the client definition matches" {
    const alloc = testing.allocator;
    const raw =
        "{\"created_at\":1700000000,\"workflow\":\"one\",\"status\":\"completed\"," ++
        "\"steps\":[{\"id\":\"only\",\"status\":\"completed\"}],\"artifacts\":[],\"failed_step\":null,\"error\":null}";
    var rep = try parseReport(alloc, raw);
    defer rep.deinit(alloc);

    const frames = try buildReplayFrames(alloc, "web-9", "one", &rep);
    defer {
        for (frames) |*f| alloc.free(f.payload_json);
        alloc.free(frames);
    }
    try testing.expectEqual(@as(usize, 4), frames.len); // start + start/end + end

    try testing.expectEqualStrings(
        "{\"type\":\"session/event\",\"sessionId\":\"web-9\",\"event\":" ++
            "{\"type\":\"tool-workflow/run-start\",\"seq\":0,\"time\":1700000000000," ++
            "\"data\":{\"runId\":\"one\",\"name\":\"one\"}}}",
        frames[0].payload_json,
    );
    try testing.expect(std.mem.indexOf(u8, frames[1].payload_json, "\"type\":\"tool-workflow/agent-start\",\"seq\":1,\"time\":1700000000000," ++
        "\"data\":{\"runId\":\"one\",\"seq\":0,\"label\":\"only\",\"childId\":\"one.only\"}") != null);
    try testing.expect(std.mem.indexOf(u8, frames[2].payload_json, "\"type\":\"tool-workflow/agent-end\",\"seq\":2,\"time\":1700000000000," ++
        "\"data\":{\"runId\":\"one\",\"seq\":0,\"outcome\":\"completed\"}") != null);
    try testing.expect(std.mem.indexOf(u8, frames[3].payload_json, "\"type\":\"tool-workflow/run-end\",\"seq\":3,\"time\":1700000000000," ++
        "\"data\":{\"runId\":\"one\",\"stopReason\":\"completed\"}") != null);
}

test "handleRunGet validates the run name before touching disk" {
    const alloc = testing.allocator;
    try testing.expectError(
        error.PayloadInvalid,
        handleRunGet(alloc, "rpc-1", "/tmp/x", "{\"run\":\"../escape\"}"),
    );
    try testing.expectError(
        error.PayloadInvalid,
        handleRunGet(alloc, "rpc-1", "/tmp/x", "{\"run\":\"a/b\"}"),
    );
    try testing.expectError(
        error.PayloadInvalid,
        handleRunGet(alloc, "rpc-1", "/tmp/x", "{}"),
    );
}
