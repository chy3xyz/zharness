//! Plan projection frames — renders the zharness PlanBoard (agent/plan.zig)
//! onto the DSH client's plan/todo surface (contract truth:
//! `_ref/deepseek-harness/packages/{todo/tool-todo,plan/plan-mode}/src/types.ts`
//! + `host/apiproxy/src/api/events.schema.ts`).
//!
//! ── HOW PLAN STATE REACHES THE CLIENT (recon verdict) ─────────────────────
//!
//! ui-plan's chip reads the generic projection pair (`useProjection`); the
//! task checklist itself is the `todos` SESSION PROJECTION
//! (tool-todo/types.ts): `TodoItem[] | null`, where one TodoItem is
//! `{content: string, status: 'pending'|'in_progress'|'completed'}`. The
//! separate `plan` projection key is upstream PLAN MODE
//! (`{active:boolean,pending:boolean}`) — a collaboration state zharness
//! does not implement; this module never emits it (capability absence is the
//! key's absence per upstream semantics).
//!
//! Projections travel as mux frames:
//!
//!   {"type":"session/projection","sessionId":"…","key":"todos",
//!    "value":[{"content":"…","status":"in_progress"},…],"seq":N}
//!
//! seq is the session's monotonic projection sequence (≥ 0). On session open
//! the integrator pushes ONE such frame with the current board as the INITIAL
//! state (the same shape `session.history`'s trailing `projections` block
//! carries), then re-publishes after every mutating tool call.
//!
//! ── EMISSION CONTRACT for the integrator (main.zig LoopExtensions) ────────
//!
//! After each SUCCESSFUL plan mutation call `publishPlanState`:
//!   - main.zig:496 end of LoopExtensions.planBoardTool — covers both
//!     plan_add and plan_update (the executeTool dispatch at :487).
//!   - main.zig:536 end of LoopExtensions.planSet — after the board replace.
//! The loop extension does not know its sessionId today; the integrator adds
//! one field to LoopExtensions (session id string) or threads it from the
//! serve-mode session wrapper that owns the board (built around main.zig:1697).
//! Failures are swallowed inside publishPlanState (observability-bridge
//! contract: a dead socket never fails an agent turn).
//!
//! ── MAPPING / GAPS ─────────────────────────────────────────────────────────
//!
//!   PlanBoard.Task.status → TodoItem.status
//!     pending     → "pending"
//!     in_progress → "in_progress"
//!     done        → "completed"
//!     blocked     → "pending"  (GAP: upstream has no blocked state; the
//!                               note text keeps the human-visible signal)
//!   Task.note is appended to content as " — <note>" (upstream items carry no
//!   separate note field). Empty boards render `[]` (upstream null means
//!   "no list yet"; an empty list is a real list).

const std = @import("std");
const jsonx = @import("jsonx.zig");
const events_ws = @import("events_ws.zig");
const plan_mod = @import("../../agent/plan.zig");

/// The SessionProjectionMap key this module publishes under.
pub const projection_key = "todos";

/// Upstream wire status for one board task (closed union).
fn statusStr(s: plan_mod.TaskStatus) []const u8 {
    return switch (s) {
        .pending => "pending",
        .in_progress => "in_progress",
        .done => "completed",
        // GAP: upstream union has no blocked; degrades to pending.
        .blocked => "pending",
    };
}

/// One TodoItem in declaration order ({content,status}); the note rides
/// inside content because the wire type has no note slot.
pub fn appendTodoItem(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    task: *const plan_mod.Task,
) !void {
    try out.appendSlice(alloc, "{\"content\":\"");
    try jsonx.appendJsonStringBody(alloc, out, task.text);
    if (task.note) |n| {
        if (n.len > 0) {
            try out.appendSlice(alloc, " — ");
            try jsonx.appendJsonStringBody(alloc, out, n);
        }
    }
    try out.append(alloc, '"');
    try out.appendSlice(alloc, ",\"status\":");
    try jsonx.appendJsonString(alloc, out, statusStr(task.status));
    try out.append(alloc, '}');
}

/// Append the todos projection VALUE (`TodoItem[]`) for `board`.
pub fn appendTodosValue(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    board: *const plan_mod.PlanBoard,
) !void {
    try out.append(alloc, '[');
    for (board.tasks.items, 0..) |*t, i| {
        if (i > 0) try out.append(alloc, ',');
        try appendTodoItem(alloc, out, t);
    }
    try out.append(alloc, ']');
}

/// Owned todos projection VALUE JSON. Caller frees.
pub fn todosValue(alloc: std.mem.Allocator, board: *const plan_mod.PlanBoard) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendTodosValue(alloc, &out, board);
    return out.toOwnedSlice(alloc);
}

/// Full `session/projection` frame PAYLOAD around a pre-rendered value.
/// Caller frees. `value_json` must be a complete JSON value.
pub fn projectionFramePayload(
    alloc: std.mem.Allocator,
    session_id: []const u8,
    seq: u64,
    key: []const u8,
    value_json: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"session/projection\",\"sessionId\":");
    try jsonx.appendJsonString(alloc, &out, session_id);
    try out.appendSlice(alloc, ",\"key\":");
    try jsonx.appendJsonString(alloc, &out, key);
    try out.appendSlice(alloc, ",\"value\":");
    try out.appendSlice(alloc, value_json);
    try out.appendSlice(alloc, ",\"seq\":");
    try jsonx.appendInt(alloc, &out, @intCast(seq));
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

/// Publish the current board as a `todos` projection frame on the shared mux
/// hub. No-op when serve mode has not installed the hubs (CLI runs). All
/// failures are swallowed per the emission contract above; internal scratch
/// lives on the hub allocator (process-lifetime, never a request arena).
pub fn publishPlanState(session_id: []const u8, seq: u64, board: *const plan_mod.PlanBoard) void {
    const hubs = events_ws.sharedHubs() catch return;
    publishPlanStateOn(&hubs.mux, session_id, seq, board);
}

/// Same publish against an explicit hub (test/integrator seam; also lets a
/// caller fan out to a non-singleton hub).
pub fn publishPlanStateOn(
    hub: *events_ws.FrameHub,
    session_id: []const u8,
    seq: u64,
    board: *const plan_mod.PlanBoard,
) void {
    const alloc = hub.alloc;
    const value = todosValue(alloc, board) catch return;
    defer alloc.free(value);
    const payload = projectionFramePayload(alloc, session_id, seq, projection_key, value) catch return;
    defer alloc.free(payload);
    hub.publish("session/projection", payload);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "todos value maps statuses and folds notes into content" {
    const alloc = testing.allocator;
    var b = plan_mod.PlanBoard.init(alloc);
    defer b.deinit();

    const id1 = try b.addTask("ship it");
    _ = try b.setNote(id1, "reviewed");
    _ = b.updateStatus(id1, .done);
    const id2 = try b.addTask("write docs \"now\"");
    _ = b.updateStatus(id2, .in_progress);
    const id3 = try b.addTask("blocked thing");
    _ = b.updateStatus(id3, .blocked);

    const v = try todosValue(alloc, &b);
    defer alloc.free(v);
    try testing.expectEqualStrings(
        "[{\"content\":\"ship it — reviewed\",\"status\":\"completed\"}," ++
            "{\"content\":\"write docs \\\"now\\\"\",\"status\":\"in_progress\"}," ++
            "{\"content\":\"blocked thing\",\"status\":\"pending\"}]",
        v,
    );
}

test "empty board renders an empty array" {
    const alloc = testing.allocator;
    var b = plan_mod.PlanBoard.init(alloc);
    defer b.deinit();
    const v = try todosValue(alloc, &b);
    defer alloc.free(v);
    try testing.expectEqualStrings("[]", v);
}

test "projection frame payload matches the mux schema bytes" {
    const payload = try projectionFramePayload(
        testing.allocator,
        "web-1",
        7,
        projection_key,
        "[{\"content\":\"a\",\"status\":\"pending\"}]",
    );
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings(
        "{\"type\":\"session/projection\",\"sessionId\":\"web-1\",\"key\":\"todos\"," ++
            "\"value\":[{\"content\":\"a\",\"status\":\"pending\"}],\"seq\":7}",
        payload,
    );
}
