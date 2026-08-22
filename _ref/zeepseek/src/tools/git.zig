const std = @import("std");
const tools_mod = @import("mod.zig");
const ToolCall = tools_mod.ToolCall;
const ToolResult = tools_mod.ToolResult;
const sandbox_mod = @import("../utils/sandbox.zig");
const Sandbox = sandbox_mod.Sandbox;
const process_mod = @import("process.zig");

fn resolveRepoPath(alloc: std.mem.Allocator, cwd: []const u8, repo: ?[]const u8) ![]const u8 {
    if (repo) |r| {
        if (std.mem.startsWith(u8, r, "/")) return alloc.dupe(u8, r);
        return std.fs.path.join(alloc, &.{ cwd, r });
    }
    return alloc.dupe(u8, cwd);
}

fn runGitCommand(alloc: std.mem.Allocator, repo: []const u8, args: []const []const u8) !ToolResult {
    const result = process_mod.runGit(alloc, repo, args) catch {
        return ToolResult{
            .success = false,
            .output = "",
            .err_msg = "Failed to spawn git process",
        };
    };

    return ToolResult{
        .success = result.success,
        .output = result.output,
        .err_msg = if (result.success) null else "Git command failed",
    };
}

pub fn executeStatus(alloc: std.mem.Allocator, sandbox: ?*Sandbox, cwd: []const u8, call: ToolCall) !ToolResult {
    _ = sandbox;
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const repo = map.get("repo");
    const resolved = resolveRepoPath(alloc, cwd, repo) catch cwd;
    defer if (resolved.ptr != cwd.ptr) alloc.free(resolved);

    return runGitCommand(alloc, resolved, &.{ "status", "-sb" });
}

pub fn executeLog(alloc: std.mem.Allocator, sandbox: ?*Sandbox, cwd: []const u8, call: ToolCall) !ToolResult {
    _ = sandbox;
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const repo = map.get("repo");
    const resolved = resolveRepoPath(alloc, cwd, repo) catch cwd;
    defer if (resolved.ptr != cwd.ptr) alloc.free(resolved);

    const limit_str = map.get("limit") orelse "10";
    const limit_arg = try std.fmt.allocPrint(alloc, "-{s}", .{limit_str});
    defer alloc.free(limit_arg);

    return runGitCommand(alloc, resolved, &.{ "log", "--oneline", limit_arg });
}

pub fn executeDiff(alloc: std.mem.Allocator, sandbox: ?*Sandbox, cwd: []const u8, call: ToolCall) !ToolResult {
    _ = sandbox;
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const repo = map.get("repo");
    const resolved = resolveRepoPath(alloc, cwd, repo) catch cwd;
    defer if (resolved.ptr != cwd.ptr) alloc.free(resolved);

    if (map.get("target")) |target| {
        return runGitCommand(alloc, resolved, &.{ "diff", target });
    }
    return runGitCommand(alloc, resolved, &.{ "diff" });
}

pub fn executeCommit(alloc: std.mem.Allocator, sandbox: ?*Sandbox, cwd: []const u8, call: ToolCall) !ToolResult {
    _ = sandbox;
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const message = map.get("message") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing message argument" };
    };

    const repo = map.get("repo");
    const resolved = resolveRepoPath(alloc, cwd, repo) catch cwd;
    defer if (resolved.ptr != cwd.ptr) alloc.free(resolved);

    const all = map.get("all");
    if (all != null and (std.mem.eql(u8, all.?, "true") or std.mem.eql(u8, all.?, "1"))) {
        _ = try runGitCommand(alloc, resolved, &.{ "add", "-A" });
        return runGitCommand(alloc, resolved, &.{ "commit", "-m", message });
    }

    return runGitCommand(alloc, resolved, &.{ "commit", "-m", message });
}

test "git status reports untracked files in a temp repository" {
    const alloc = std.testing.allocator;

    // Unique temp dir from a wall-clock timestamp (avoids std.crypto.random,
    // which was removed in Zig 0.17). Matches the repo's timestamp idiom.
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const now = @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
    const dir_name = try std.fmt.allocPrint(alloc, "/tmp/zz-git-{d}", .{now});
    defer alloc.free(dir_name);
    defer {
        _ = process_mod.runArgv(alloc, "/tmp", &.{ "rm", "-rf", dir_name }) catch {};
    }

    const dir_z = try alloc.dupeSentinel(u8, dir_name, 0);
    defer alloc.free(dir_z);
    if (std.c.mkdir(dir_z.ptr, 0o755) != 0) return error.SkipZigTest;

    const init_res = process_mod.runArgv(alloc, dir_name, &.{ "git", "init", "-q" }) catch return error.SkipZigTest;
    defer alloc.free(init_res.output);
    if (!init_res.success) return error.SkipZigTest;

    const file_path = try std.fmt.allocPrint(alloc, "{s}/tracked.txt", .{dir_name});
    defer alloc.free(file_path);
    const file_z = try alloc.dupeSentinel(u8, file_path, 0);
    defer alloc.free(file_z);
    const fd = std.c.open(file_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.SkipZigTest;
    _ = std.c.write(fd, "hello", 5);
    _ = std.c.close(fd);

    const st = try executeStatus(alloc, null, dir_name, .{ .index = 0, .name = "git_status", .arguments = "{}" });
    defer alloc.free(st.output);
    try std.testing.expect(st.success);
    try std.testing.expect(std.mem.indexOf(u8, st.output, "tracked.txt") != null);
}
