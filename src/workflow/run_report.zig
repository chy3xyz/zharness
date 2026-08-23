//! Run reports (dev.md §XIX follow-up): persist the outcome of a workflow
//! execution as a single JSON document.
//!
//! Shape:
//!
//!   {
//!     "created_at": 1700000000,
//!     "workflow": "ship-it",
//!     "status": "completed" | "failed",
//!     "steps": [ { "id":"a", "status":"completed" },
//!                { "id":"b", "status":"skipped" },
//!                { "id":"c", "status":"failed", "error":"StepExploded" } ],
//!     "artifacts": [ { "id":"a", "result":"..." }, ... ],
//!     "failed_step": "c" | null,
//!     "error": "..." | null
//!   }
//!
//! Per-step status is DERIVED (no extra bookkeeping in the executor):
//! completed ⇔ an artifact exists for the step; failed ⇔ it is the outcome's
//! failed_step; everything else was skipped or never reached ("skipped").
//!
//! Publishing is atomic exactly like session checkpoints: write
//! `<path>.tmp` inside the destination directory, rename over the target;
//! a failed publish leaves no tmp residue and never truncates a previous
//! report. `render` is pure and testable offline; only `publish` touches the
//! filesystem.

const std = @import("std");
const wf_mod = @import("workflow.zig");
const exec = @import("executor.zig");

/// Render the full report. Caller frees the returned buffer.
pub fn render(
    alloc: std.mem.Allocator,
    wf: *const wf_mod.Workflow,
    outcome: *const exec.WorkflowOutcome,
    created_at: i64,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "{\"created_at\":");
    try appendInt(alloc, &out, created_at);
    try out.appendSlice(alloc, ",\"workflow\":\"");
    try escapeInto(alloc, wf.name, &out);
    try out.appendSlice(alloc, "\",\"status\":\"");
    try out.appendSlice(alloc, switch (outcome.status) {
        .completed => "completed",
        .failed => "failed",
    });
    try out.appendSlice(alloc, "\",\"steps\":[");

    for (wf.steps, 0..) |*step, si| {
        if (si > 0) try out.appendSlice(alloc, ",");
        const status: []const u8 = blk: {
            if (outcome.artifactOf(step.id) != null) break :blk "completed";
            if (outcome.failed_step) |fs| {
                if (std.mem.eql(u8, fs, step.id)) break :blk "failed";
            }
            break :blk "skipped";
        };
        try out.appendSlice(alloc, "{\"id\":\"");
        try escapeInto(alloc, step.id, &out);
        try out.appendSlice(alloc, "\",\"status\":\"");
        try out.appendSlice(alloc, status);
        try out.appendSlice(alloc, "\"");
        // Surface the runner error name next to the failing step.
        if (std.mem.eql(u8, status, "failed")) {
            if (outcome.err) |e| {
                try out.appendSlice(alloc, ",\"error\":\"");
                try escapeInto(alloc, e, &out);
                try out.appendSlice(alloc, "\"");
            }
        }
        try out.appendSlice(alloc, "}");
    }

    try out.appendSlice(alloc, "],\"artifacts\":[");
    for (outcome.artifacts, 0..) |*a, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        try out.appendSlice(alloc, "{\"id\":\"");
        try escapeInto(alloc, a.id, &out);
        try out.appendSlice(alloc, "\",\"result\":\"");
        try escapeInto(alloc, a.result, &out);
        try out.appendSlice(alloc, "\"}");
    }
    try out.appendSlice(alloc, "]");

    try out.appendSlice(alloc, ",\"failed_step\":");
    try appendOptString(alloc, &out, outcome.failed_step);
    try out.appendSlice(alloc, ",\"error\":");
    try appendOptString(alloc, &out, outcome.err);
    try out.appendSlice(alloc, "}");

    return out.toOwnedSlice(alloc);
}

/// Atomically publish `json` at `path` (tmp file + rename). The parent
/// directory is created when missing. On rename failure the tmp file is
/// removed and error.WriteFailed is returned; any previously published
/// report stays intact.
pub fn publish(io: std.Io, path: []const u8, json: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    // Split into parent dir + basename so tmp lives on the same filesystem.
    var parent: []const u8 = ".";
    var base = path;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        parent = path[0..slash];
        base = path[slash + 1 ..];
    }
    if (base.len == 0) return error.WriteFailed;

    try cwd.createDirPath(io, parent);

    const dir = try std.Io.Dir.openDir(cwd, io, parent, .{});
    defer std.Io.Dir.close(dir, io);

    const tmp_name = ".zh_run_report.tmp";
    try std.Io.Dir.writeFile(dir, io, .{ .sub_path = tmp_name, .data = json });
    std.Io.Dir.rename(dir, tmp_name, dir, base, io) catch {
        std.Io.Dir.deleteFile(dir, io, tmp_name) catch {};
        return error.WriteFailed;
    };
}

/// render + publish convenience for integrators.
pub fn generate(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    wf: *const wf_mod.Workflow,
    outcome: *const exec.WorkflowOutcome,
) !void {
    const json = try render(alloc, wf, outcome, nowSecs());
    defer alloc.free(json);
    try publish(io, path, json);
}

// ── shared small helpers (same style as session/checkpoint.zig) ─────────────

extern "c" fn time(tloc: ?*c_long) c_long;

/// Seconds since epoch (libc time(2)); std.time lost its clock fns in 0.17.
fn nowSecs() i64 {
    return @intCast(time(null));
}

fn appendInt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: anytype) !void {
    var b: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{d}", .{v}) catch return;
    try out.appendSlice(alloc, s);
}

fn escapeInto(alloc: std.mem.Allocator, input: []const u8, buf: *std.ArrayList(u8)) !void {
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

fn appendOptString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: ?[]const u8) !void {
    if (v) |s| {
        try out.appendSlice(alloc, "\"");
        try escapeInto(alloc, s, out);
        try out.appendSlice(alloc, "\"");
    } else {
        try out.appendSlice(alloc, "null");
    }
}

/// Remove a /tmp report directory by basename (test helper; returns quietly
/// on any filesystem problem).
fn deleteReportDir(io: std.Io, dir_path: []const u8) void {
    const slash = std.mem.lastIndexOfScalar(u8, dir_path, '/') orelse return;
    const cwd = std.Io.Dir.cwd();
    const pd = std.Io.Dir.openDir(cwd, io, dir_path[0..slash], .{}) catch return;
    defer std.Io.Dir.close(pd, io);
    std.Io.Dir.deleteTree(pd, io, dir_path[slash + 1 ..]) catch {};
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn fakeRunner(
    alloc: std.mem.Allocator,
    io: std.Io,
    step_prompt: []const u8,
    ctx: *const exec.StepContext,
) anyerror![]u8 {
    _ = io;
    _ = ctx;
    return alloc.dupe(u8, step_prompt);
}

test "render derives per-step statuses and escapes artifact text" {
    const alloc = testing.allocator;
    const json_src = "{\"name\":\"rep\",\"steps\":[" ++
        "{\"id\":\"ok\",\"prompt\":\"p\"}," ++
        "{\"id\":\"late\",\"prompt\":\"q\",\"depends_on\":[\"boom\"]}," ++
        "{\"id\":\"boom\",\"prompt\":\"r\"}]}";
    var wf = try wf_mod.Workflow.parseValidated(alloc, json_src);
    defer wf.deinit(alloc);

    // Simulate an executor result without running one: ok completed, boom
    // failed with StepExploded, late skipped.
    var artifacts = [_]exec.Artifact{
        .{
            .id = try alloc.dupe(u8, "ok"),
            .result = try alloc.dupe(u8, "said \"hi\"\nbye"),
        },
    };
    const failed_step = try alloc.dupe(u8, "boom");
    const err_msg = try alloc.dupe(u8, "StepExploded");
    var outcome = exec.WorkflowOutcome{
        .status = .failed,
        .artifacts = &artifacts,
        .failed_step = failed_step,
        .err = err_msg,
    };
    defer {
        for (&artifacts) |*a| {
            alloc.free(a.id);
            alloc.free(a.result);
        }
        alloc.free(failed_step);
        alloc.free(err_msg);
    }

    const rep = try render(alloc, &wf, &outcome, 1700000000);
    defer alloc.free(rep);

    // Spot-check the derived structure rather than exact serialization.
    try testing.expect(std.mem.indexOf(u8, rep, "\"workflow\":\"rep\"") != null);
    try testing.expect(std.mem.indexOf(u8, rep, "\"status\":\"failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, rep, "{\"id\":\"ok\",\"status\":\"completed\"}") != null);
    try testing.expect(std.mem.indexOf(u8, rep, "{\"id\":\"late\",\"status\":\"skipped\"}") != null);
    try testing.expect(std.mem.indexOf(u8, rep, "{\"id\":\"boom\",\"status\":\"failed\",\"error\":\"StepExploded\"}") != null);
    try testing.expect(std.mem.indexOf(u8, rep, "\"result\":\"said \\\"hi\\\"\\nbye\"") != null);
    try testing.expect(std.mem.indexOf(u8, rep, "\"failed_step\":\"boom\"") != null);
}

test "publish is atomic and readable back" {
    const alloc = testing.allocator;

    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();

    const stamp: u64 = @intCast(time(null));
    const dir_path = try std.fmt.allocPrint(std.heap.page_allocator, "/tmp/zh_wf_report_{d}", .{stamp});
    defer std.heap.page_allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/report.json", .{dir_path});
    defer std.heap.page_allocator.free(file_path);

    // Cleanup regardless of test outcome: remove the /tmp/zh_wf_report_* dir.
    errdefer deleteReportDir(t.io(), dir_path);

    var wf = try wf_mod.Workflow.parseValidated(alloc, "{\"name\":\"one\",\"steps\":[{\"id\":\"only\",\"prompt\":\"do\"}]}");
    defer wf.deinit(alloc);

    var ex = exec.Executor.init(alloc, &fakeRunner);
    var outcome = try ex.run(t.io(), &wf);
    defer outcome.deinit(alloc);
    try testing.expect(outcome.status == .completed);

    try generate(alloc, t.io(), file_path, &wf, &outcome);

    const raw = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), t.io(), file_path, alloc, .limited(1 << 20));
    defer alloc.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"workflow\":\"one\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "{\"id\":\"only\",\"status\":\"completed\"}") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"result\":\"do\"") != null);

    // No tmp residue after a successful publish.
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}/.zh_run_report.tmp", .{dir_path});
    defer alloc.free(tmp_path);
    const missing = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), t.io(), tmp_path, alloc, .limited(16)) catch |e| e == error.FileNotFound;
    try testing.expect(missing == true);
}
