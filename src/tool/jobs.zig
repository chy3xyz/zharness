//! `job_list` / `job_output` / `job_kill` — model-facing view of the jobs
//! surface (alignment with upstream dsh tool-jobs).
//!
//! Sources mirror the GUI frame builder in server/apiproxy/jobs_rpc.zig:
//! the live JobRegistry singleton plus durable workflow runs under
//! `.zharness/runs/<name>.json` (id `wf-<name>`).

const std = @import("std");
const model = @import("../model/model.zig");
const tool_reg = @import("registry.zig");
const builtin = @import("builtin.zig");
const jobs = @import("../server/apiproxy/jobs_rpc.zig");

pub const ToolCall = builtin.ToolCall;
pub const ToolResult = builtin.ToolResult;
pub const freeResult = builtin.freeResult;

pub const definitions = [_]tool_reg.ToolDefinition{
    .{
        .name = "job_list",
        .description = "List background jobs: live registered work plus settled workflow runs (.zharness/runs). Returns JSON.",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .{
        .name = "job_output",
        .description = "Read a job's captured output. For workflow jobs (id wf-<name>) returns the run report JSON; otherwise the live job's status/detail.",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Job id from job_list"}},"required":["id"]}
        ,
    },
    .{
        .name = "job_kill",
        .description = "Mark a live background job as killed (best-effort; workflows already settled cannot be killed).",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Live job id from job_list"}},"required":["id"]}
        ,
    },
};

pub fn register(reg: *tool_reg.ToolRegistry) !void {
    for (definitions) |d| try reg.register(d);
}

pub fn isJobTool(name: []const u8) bool {
    for (definitions) |d| {
        if (std.mem.eql(u8, name, d.name)) return true;
    }
    return false;
}

fn fail(alloc: std.mem.Allocator, msg: []const u8) !ToolResult {
    return .{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, msg) };
}

pub fn execute(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    if (std.mem.eql(u8, call.name, "job_list")) {
        const json = try jobs.jobsListValue(alloc, io, cwd);
        return .{ .success = true, .output = json };
    }
    if (std.mem.eql(u8, call.name, "job_output")) return jobOutput(alloc, io, cwd, call.arguments);
    if (std.mem.eql(u8, call.name, "job_kill")) return jobKill(alloc, call.arguments);
    return fail(alloc, "unknown job tool");
}

fn jobOutput(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const u8) !ToolResult {
    const id = (try model.extractStringField(alloc, args, "id")) orelse
        return fail(alloc, "job_output: missing 'id'");
    defer alloc.free(id);

    if (std.mem.startsWith(u8, id, "wf-")) {
        const name = id[3..];
        const path = try std.fmt.allocPrint(alloc, "{s}/.zharness/runs/{s}.json", .{ cwd, name });
        defer alloc.free(path);
        const raw = std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(4 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return fail(alloc, "job_output: no run report for that workflow id"),
            else => return e,
        };
        return .{ .success = true, .output = raw };
    }

    if (jobs.sharedRegistry() catch null) |reg| {
        const views = try reg.listSnapshot(alloc);
        defer {
            for (views) |v| {
                alloc.free(v.id);
                alloc.free(v.kind);
                alloc.free(v.label);
                if (v.detail) |d| alloc.free(d);
            }
            alloc.free(views);
        }
        for (views) |v| {
            if (!std.mem.eql(u8, v.id, id)) continue;
            const out = if (v.detail) |d|
                try std.fmt.allocPrint(alloc, "status={s} detail={s}", .{ v.status.asStr(), d })
            else
                try std.fmt.allocPrint(alloc, "status={s} (no captured output)", .{v.status.asStr()});
            return .{ .success = true, .output = out };
        }
    }
    return fail(alloc, "job_output: unknown job id");
}

fn jobKill(alloc: std.mem.Allocator, args: []const u8) !ToolResult {
    const id = (try model.extractStringField(alloc, args, "id")) orelse
        return fail(alloc, "job_kill: missing 'id'");
    defer alloc.free(id);
    const reg = jobs.sharedRegistry() catch return fail(alloc, "job_kill: no live job registry");
    if (reg.settle(id, .killed, "killed by job_kill")) {
        return .{ .success = true, .output = try std.fmt.allocPrint(alloc, "job {s} marked killed", .{id}) };
    }
    return fail(alloc, "job_kill: unknown or already settled job id");
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "job tools list and report errors without a registry entry" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try register(&reg);
    try testing.expect(reg.contains("job_list"));
    try testing.expect(reg.contains("job_output"));
    try testing.expect(reg.contains("job_kill"));

    // job_output for an unknown live id fails closed (no crash on a missing run).
    var r = try execute(alloc, io, "/tmp", .{ .name = "job_output", .arguments = "{\"id\":\"no-such-job\"}" });
    defer freeResult(alloc, &r);
    try testing.expect(!r.success);
}
