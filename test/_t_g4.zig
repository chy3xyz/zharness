//! G4-views test root — plan frames / jobs / trajectory / workflow-run replay.
//! Run: `zig test -lc test/_t_g4.zig` (top-level src/ so relative imports stay
//! inside the module path). Each owned module also carries inline tests; this
//! root folds them plus the cross-module fixtures below.

const std = @import("std");
const testing = std.testing;

const plan_frames = @import("../src/server/apiproxy/plan_frames.zig");
const jobs_rpc = @import("../src/server/apiproxy/jobs_rpc.zig");
const trajectory = @import("../src/server/apiproxy/trajectory.zig");
const wf_replay = @import("../src/server/apiproxy/wf_replay.zig");
const events_ws = @import("../src/server/apiproxy/events_ws.zig");
const jsonx = @import("../src/server/apiproxy/jsonx.zig");
const sessions = @import("../src/server/apiproxy/sessions.zig");
const router = @import("../src/server/apiproxy/router.zig");
const plan_mod = @import("../src/agent/plan.zig");

extern "c" fn time(tloc: ?*c_long) c_long;

// Re-export module-internal suites so `zig test test/_t_g4.zig` runs them all.
comptime {
    _ = jsonx;
    _ = router;
}

test "plan: board → todos projection value + initial-state frame" {
    const alloc = testing.allocator;
    var board = plan_mod.PlanBoard.init(alloc);
    defer board.deinit();

    const t1 = try board.addTask("recon upstream shape");
    _ = try board.setNote(t1, "projection key found");
    _ = board.updateStatus(t1, .done);
    const t2 = try board.addTask("wire emission hooks");
    _ = board.updateStatus(t2, .in_progress);

    const value = try plan_frames.todosValue(alloc, &board);
    defer alloc.free(value);
    try testing.expectEqualStrings(
        "[{\"content\":\"recon upstream shape — projection key found\",\"status\":\"completed\"}," ++
            "{\"content\":\"wire emission hooks\",\"status\":\"in_progress\"}]",
        value,
    );

    // INITIAL state frame on session open (integrator pushes once).
    const frame = try plan_frames.projectionFramePayload(
        alloc,
        "web-7",
        0,
        plan_frames.projection_key,
        value,
    );
    defer alloc.free(frame);
    try testing.expectEqualStrings(
        "{\"type\":\"session/projection\",\"sessionId\":\"web-7\",\"key\":\"todos\"," ++
            "\"value\":[{\"content\":\"recon upstream shape — projection key found\",\"status\":\"completed\"}," ++
            "{\"content\":\"wire emission hooks\",\"status\":\"in_progress\"}],\"seq\":0}",
        frame,
    );
}

test "plan: publishPlanStateOn fans a projection frame to mux subscribers" {
    const alloc = testing.allocator;
    var board = plan_mod.PlanBoard.init(alloc);
    defer board.deinit();
    _ = try board.addTask("only");

    var hub = events_ws.FrameHub{ .alloc = alloc };
    defer hub.subs.deinit(alloc);

    // Zero subscribers: safe publish, nothing dropped.
    plan_frames.publishPlanStateOn(&hub, "web-1", 3, &board);
    try testing.expectEqual(@as(usize, 0), hub.dropped);
}

test "jobs: registry lifecycle + combined list over a real run-report fixture" {
    const alloc = testing.allocator;

    // Live registry rows.
    var reg = jobs_rpc.JobRegistry{ .gpa = alloc };
    const live_id = reg.registerAt("gui-run", "detached chat", 1000).?;
    try testing.expect(reg.settle(live_id, .completed, "exit 0"));
    const snapshot = try reg.listSnapshot(alloc);
    defer {
        for (snapshot) |j| {
            alloc.free(j.id);
            alloc.free(j.kind);
            alloc.free(j.label);
            if (j.detail) |d| alloc.free(d);
        }
        alloc.free(snapshot);
    }
    try testing.expectEqual(@as(usize, 1), snapshot.len);
    try testing.expectEqualStrings("completed", snapshot[0].status.asStr());

    // Durable run fixture: copy the repo's real smoke.json into a temp
    // <dir>/.zharness/runs layout and list against it.
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();

    const stamp: u64 = @intCast(time(null));
    const tmp_root = try std.fmt.allocPrint(std.heap.page_allocator, "/tmp/zh_g4_jobs_{d}", .{stamp});
    defer std.heap.page_allocator.free(tmp_root);
    const runs_dir = try std.fmt.allocPrint(alloc, "{s}/.zharness/runs", .{tmp_root});
    defer alloc.free(runs_dir);

    errdefer deleteTree(io, tmp_root);
    try makeRunsFixture(io, runs_dir);

    const value = try jobs_rpc.jobsListValueFrom(alloc, io, tmp_root, &reg);
    defer alloc.free(value);
    // Live row first, durable run second.
    try testing.expect(std.mem.startsWith(u8, value, "{\"jobs\":[{\"id\":\"gui-run-1\",\"kind\":\"gui-run\",\"label\":\"detached chat\"," ++
        "\"status\":\"completed\",\"detail\":\"exit 0\",\"startedAt\":1000,\"finishedAt\":"));
    try testing.expect(std.mem.indexOf(u8, value, "{\"id\":\"wf-smoke\",\"kind\":\"workflow\",\"label\":\"smoke\",\"status\":\"completed\"," ++
        "\"startedAt\":1787470611000}") != null);
    // finishedAt omitted for disk rows (no completion timestamp stored).
    try testing.expect(std.mem.indexOf(u8, value, "\"finishedAt\":1787470611000") == null);

    reg.deinit();

    deleteTree(io, tmp_root);
}

/// Copy .zharness/runs/smoke.json into `<runs_dir>` under `<tmp_root>`.
fn makeRunsFixture(io: std.Io, runs_dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, runs_dir);
    const raw = try std.Io.Dir.readFileAlloc(cwd, io, ".zharness/runs/smoke.json", std.heap.page_allocator, .limited(1 << 20));
    defer std.heap.page_allocator.free(raw);
    const dir = try std.Io.Dir.openDir(cwd, io, runs_dir, .{});
    defer std.Io.Dir.close(dir, io);
    try std.Io.Dir.writeFile(dir, io, .{ .sub_path = "smoke.json", .data = raw });
}

fn deleteTree(io: std.Io, path: []const u8) void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    const cwd = std.Io.Dir.cwd();
    const pd = std.Io.Dir.openDir(cwd, io, path[0..slash], .{}) catch return;
    defer std.Io.Dir.close(pd, io);
    std.Io.Dir.deleteTree(pd, io, path[slash + 1 ..]) catch {};
}

test "trajectory: synthetic transcript aggregates turns/steps/totals" {
    const alloc = testing.allocator;
    const transcript =
        \\[{"role":"user","content":"fix the bug"},
        \\{"role":"assistant","content":"","tool_calls_json":"{\"id\":\"9\",\"name\":\"shell\"}"},
        \\{"role":"tool","tool_call_id":"9","content":"patched"},
        \\{"role":"assistant","content":"done"}]
    ;
    const msgs = try sessions.parseTranscript(alloc, transcript);
    defer {
        for (msgs) |m| {
            alloc.free(m.role);
            alloc.free(m.content);
            if (m.tool_call_id) |v| alloc.free(v);
            if (m.tool_calls_json) |v| alloc.free(v);
        }
        alloc.free(msgs);
    }

    const value = try trajectory.trajectoryValue(alloc, msgs);
    defer alloc.free(value);
    try testing.expect(std.mem.indexOf(u8, value, "\"turns\":[{\"turn\":1,\"steps\":[") != null);
    try testing.expect(std.mem.indexOf(u8, value, "\"kind\":\"tool_call\",\"preview\":\"\",\"toolName\":\"shell\"") != null);
    try testing.expect(std.mem.indexOf(u8, value, "\"totals\":{\"turns\":1,\"steps\":4,\"toolCalls\":1}") != null);
}

test "trajectory: empty/missing transcript renders an honest empty view" {
    const alloc = testing.allocator;
    const value = try trajectory.trajectoryValue(alloc, &.{});
    defer alloc.free(value);
    try testing.expectEqualStrings("{\"turns\":[],\"totals\":{\"turns\":0,\"steps\":0,\"toolCalls\":0}}", value);
}

test "wf_replay: list + detail over the copied real run fixture; replay frames publish" {
    const alloc = testing.allocator;
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();

    const stamp: u64 = @intCast(time(null));
    const tmp_root = try std.fmt.allocPrint(std.heap.page_allocator, "/tmp/zh_g4_runs_{d}", .{stamp});
    defer std.heap.page_allocator.free(tmp_root);
    const runs_dir = try std.fmt.allocPrint(alloc, "{s}/.zharness/runs", .{tmp_root});
    defer alloc.free(runs_dir);
    errdefer deleteTree(io, tmp_root);
    try makeRunsFixture(io, runs_dir);

    // LIST
    const list = try wf_replay.runListValue(io, alloc, tmp_root);
    defer alloc.free(list);
    try testing.expectEqualStrings(
        "{\"items\":[{\"run\":\"smoke\",\"name\":\"smoke\",\"status\":\"completed\",\"createdAt\":1787470611000}]}",
        list,
    );

    // GET detail
    var rep = try wf_replay.loadReport(io, alloc, tmp_root, "smoke");
    defer rep.deinit(alloc);
    const detail = try wf_replay.runDetailValue(alloc, "smoke", &rep);
    defer alloc.free(detail);
    try testing.expect(std.mem.indexOf(u8, detail, "{\"seq\":0,\"label\":\"a\",\"childId\":\"smoke.a\",\"status\":\"completed\"}") != null);
    try testing.expect(std.mem.indexOf(u8, detail, "\"artifacts\":[{\"id\":\"a\",\"result\":\"model request failed: stream ended without any data from the provider\"}") != null);

    // REPLAY onto an explicit hub with one dead-fd subscriber stand-in.
    var hub = events_ws.FrameHub{ .alloc = alloc };
    defer hub.subs.deinit(alloc);
    const pushed = wf_replay.publishReplayOn(&hub, "web-2", "smoke", &rep);
    try testing.expectEqual(@as(usize, 6), pushed); // start + 2×(start,end) + end

    deleteTree(io, tmp_root);
}

test "wf_replay: missing report errors cleanly for the handler path" {
    const alloc = testing.allocator;
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    try testing.expectError(
        error.ReportNotFound,
        wf_replay.loadReport(t.io(), alloc, "/tmp/zh_g4_missing_cwd_xyz", "nope"),
    );
}
