const std = @import("std");
const tools_mod = @import("mod.zig");
const ToolCall = tools_mod.ToolCall;
const ToolResult = tools_mod.ToolResult;
const sandbox_mod = @import("../utils/sandbox.zig");
const Sandbox = sandbox_mod.Sandbox;

const process_mod = @import("process.zig");

const c = @import("c");

/// Resolve a path against cwd (or $HOME for ~/). Uses std.fs.path.resolve,
/// which normalizes "." and ".." so sandbox prefix checks cannot be bypassed
/// with traversal components (e.g. cwd/../etc/...).
fn resolvePath(alloc: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home_ptr = std.c.getenv("HOME") orelse {
            return alloc.dupe(u8, path);
        };
        const home = std.mem.sliceTo(home_ptr, 0);
        return std.fs.path.resolve(alloc, &.{ home, path[2..] });
    }
    return std.fs.path.resolve(alloc, &.{ cwd, path });
}

/// Workspace model: structured file tools may only touch paths inside cwd.
/// System files / project-external reads require the shell tool (with
/// approval). resolved must already be absolute + normalized (resolvePath).
fn isInsideWorkspace(resolved: []const u8, cwd: []const u8) bool {
    if (std.mem.eql(u8, resolved, cwd)) return true;
    if (resolved.len > cwd.len and std.mem.startsWith(u8, resolved, cwd) and resolved[cwd.len] == '/') return true;
    return false;
}

fn readFileC(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const path_z = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(path_z);

    const fp = c.fopen(path_z.ptr, "rb");
    if (fp == null) return error.FileNotFound;
    defer _ = c.fclose(fp);

    _ = c.fseek(fp, 0, c.SEEK_END);
    const size = c.ftell(fp);
    _ = c.fseek(fp, 0, c.SEEK_SET);
    if (size < 0) return error.ReadError;

    const usize_size = @as(usize, @intCast(size));
    const buf = try alloc.alloc(u8, usize_size);
    const read_size = c.fread(buf.ptr, 1, usize_size, fp);
    if (read_size != usize_size) {
        alloc.free(buf);
        return error.ReadError;
    }
    return buf;
}

fn writeFileC(path: []const u8, content: []const u8) !void {
    const path_z = try std.heap.page_allocator.dupeSentinel(u8, path, 0);
    defer std.heap.page_allocator.free(path_z);

    const fp = c.fopen(path_z.ptr, "wb");
    if (fp == null) return error.FileNotFound;
    defer _ = c.fclose(fp);

    const written = c.fwrite(content.ptr, 1, content.len, fp);
    if (written != content.len) return error.WriteError;
}

fn ensureDir(path: []const u8) void {
    var buf: [512:0]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            _ = c.mkdir(&buf, 0o755);
        }
    }
}

pub fn executeRead(alloc: std.mem.Allocator, sandbox: ?*Sandbox, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const path = map.get("path") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing path argument" };
    };

    const resolved = resolvePath(alloc, cwd, path) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Invalid path" };
    };
    defer alloc.free(resolved);

    if (!isInsideWorkspace(resolved, cwd)) {
        return ToolResult{ .success = false, .output = "", .err_msg = "Path is outside the workspace (use shell for system files)", .sandbox_violation = true };
    }
    if (sandbox) |sb| {
        if (!sb.allowFileRead(resolved)) {
            return ToolResult{ .success = false, .output = "", .err_msg = "File read blocked by sandbox", .sandbox_violation = true };
        }
    }

    const content = readFileC(alloc, resolved) catch |err| {
        return ToolResult{
            .success = false,
            .output = "",
            .err_msg = try std.fmt.allocPrint(alloc, "Failed to read file: {}", .{err}),
        };
    };

    const max_len = 64 * 1024;
    if (content.len > max_len) {
        const truncated = try alloc.alloc(u8, max_len + 64);
        @memcpy(truncated[0..max_len], content[0..max_len]);
        const suffix = try std.fmt.bufPrint(truncated[max_len..], "\n\n... ({d} bytes truncated)", .{content.len - max_len});
        alloc.free(content);
        return ToolResult{ .success = true, .output = truncated[0 .. max_len + suffix.len] };
    }

    return ToolResult{ .success = true, .output = content };
}

pub fn executeWrite(alloc: std.mem.Allocator, sandbox: ?*Sandbox, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const path = map.get("path") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing path argument" };
    };
    const content = map.get("content") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing content argument" };
    };

    const resolved = resolvePath(alloc, cwd, path) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Invalid path" };
    };
    defer alloc.free(resolved);

    if (!isInsideWorkspace(resolved, cwd)) {
        return ToolResult{ .success = false, .output = "", .err_msg = "Path is outside the workspace (use shell for system files)", .sandbox_violation = true };
    }
    if (!isInsideWorkspace(resolved, cwd)) {
        return ToolResult{ .success = false, .output = "", .err_msg = "Path is outside the workspace (use shell for system files)", .sandbox_violation = true };
    }
    if (sandbox) |sb| {
        if (!sb.allowFileWrite(resolved)) {
            return ToolResult{ .success = false, .output = "", .err_msg = "File write blocked by sandbox", .sandbox_violation = true };
        }
    }

    if (std.fs.path.dirname(resolved)) |dir| {
        ensureDir(dir);
    }

    writeFileC(resolved, content) catch |err| {
        return ToolResult{
            .success = false,
            .output = "",
            .err_msg = try std.fmt.allocPrint(alloc, "Failed to write file: {}", .{err}),
        };
    };

    return ToolResult{
        .success = true,
        .output = try std.fmt.allocPrint(alloc, "Wrote {d} bytes to {s}", .{ content.len, resolved }),
    };
}

pub fn executeEdit(alloc: std.mem.Allocator, sandbox: ?*Sandbox, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const path = map.get("path") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing path argument" };
    };
    const old_str = map.get("oldString") orelse map.get("old_string") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing oldString argument" };
    };
    const new_str = map.get("newString") orelse map.get("new_string") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing newString argument" };
    };

    const resolved = resolvePath(alloc, cwd, path) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Invalid path" };
    };
    defer alloc.free(resolved);

    if (sandbox) |sb| {
        if (!sb.allowFileWrite(resolved)) {
            return ToolResult{ .success = false, .output = "", .err_msg = "File edit blocked by sandbox", .sandbox_violation = true };
        }
    }

    const content = readFileC(alloc, resolved) catch |err| {
        return ToolResult{
            .success = false,
            .output = "",
            .err_msg = try std.fmt.allocPrint(alloc, "Failed to read file: {}", .{err}),
        };
    };
    defer alloc.free(content);

    const idx = std.mem.indexOf(u8, content, old_str) orelse {
        return ToolResult{
            .success = false,
            .output = content,
            .err_msg = "Pattern not found in file",
        };
    };

    const new_content = try alloc.alloc(u8, content.len - old_str.len + new_str.len);
    @memcpy(new_content[0..idx], content[0..idx]);
    @memcpy(new_content[idx..][0..new_str.len], new_str);
    @memcpy(new_content[idx + new_str.len ..], content[idx + old_str.len ..]);
    defer alloc.free(new_content);

    writeFileC(resolved, new_content) catch |err| {
        return ToolResult{
            .success = false,
            .output = "",
            .err_msg = try std.fmt.allocPrint(alloc, "Failed to write file: {}", .{err}),
        };
    };

    return ToolResult{
        .success = true,
        .output = try std.fmt.allocPrint(alloc, "Edited {s}: replaced {d} chars at offset {d}", .{ resolved, old_str.len, idx }),
    };
}

pub fn executeGlob(alloc: std.mem.Allocator, sandbox: ?*Sandbox, cwd: []const u8, call: ToolCall) !ToolResult {
    _ = sandbox;
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const pattern = map.get("pattern") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing pattern argument" };
    };
    const root = map.get("root") orelse cwd;

    const resolved_root = resolvePath(alloc, cwd, root) catch cwd;
    defer if (resolved_root.ptr != cwd.ptr) alloc.free(resolved_root);
    if (!isInsideWorkspace(resolved_root, cwd)) {
        return ToolResult{ .success = false, .output = "", .err_msg = "Glob root is outside the workspace", .sandbox_violation = true };
    }

    const result = process_mod.runArgv(alloc, resolved_root, &.{
        "find", ".", "-type", "f", "-name", pattern,
    }) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to run find" };
    };

    if (result.output.len == 0) {
        alloc.free(result.output);
        return ToolResult{ .success = true, .output = try alloc.dupe(u8, "(no matches)\n") };
    }

    return ToolResult{ .success = result.success, .output = result.output };
}

pub fn executeGrep(alloc: std.mem.Allocator, sandbox: ?*Sandbox, cwd: []const u8, call: ToolCall) !ToolResult {
    _ = sandbox;
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const pattern = map.get("pattern") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing pattern argument" };
    };
    const path = map.get("path") orelse cwd;

    const resolved = resolvePath(alloc, cwd, path) catch cwd;
    defer if (resolved.ptr != cwd.ptr) alloc.free(resolved);
    if (!isInsideWorkspace(resolved, cwd)) {
        return ToolResult{ .success = false, .output = "", .err_msg = "Search path is outside the workspace", .sandbox_violation = true };
    }

    const result = process_mod.runArgv(alloc, cwd, &.{
        "grep", "-rn", "--", pattern, resolved,
    }) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to run grep" };
    };

    if (result.output.len == 0) {
        alloc.free(result.output);
        return ToolResult{ .success = true, .output = try alloc.dupe(u8, "(no matches)\n") };
    }

    return ToolResult{ .success = result.success, .output = result.output };
}

test "file_read basic" {
    const alloc = std.testing.allocator;
    const tmp_path = "/tmp/zeepseek_test_read.txt";
    try writeFileC(tmp_path, "hello world");

    const result = try executeRead(alloc, null, "/tmp", .{
        .index = 0,
        .name = "file_read",
        .arguments = "{\"path\":\"zeepseek_test_read.txt\"}",
    });
    defer alloc.free(result.output);
    if (result.err_msg) |em| {
        alloc.free(em);
    }

    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, "hello world", result.output);
}

test "file_write basic" {
    const alloc = std.testing.allocator;
    const tmp_path = "/tmp/zeepseek_test_write.txt";

    const result = try executeWrite(alloc, null, "/tmp", .{
        .index = 0,
        .name = "file_write",
        .arguments = "{\"path\":\"zeepseek_test_write.txt\",\"content\":\"test content\"}",
    });
    defer alloc.free(result.output);
    if (result.err_msg) |em| {
        alloc.free(em);
    }

    try std.testing.expect(result.success);

    const content = try readFileC(alloc, tmp_path);
    defer alloc.free(content);
    try std.testing.expectEqualSlices(u8, "test content", content);
}

test "resolvePath normalizes traversal so sandbox prefix checks work (M3)" {
    const alloc = std.testing.allocator;
    const resolved = try resolvePath(alloc, "/home/user/proj", "../../../etc/passwd");
    defer alloc.free(resolved);
    try std.testing.expectEqualSlices(u8, "/etc/passwd", resolved);

    // After normalization the prefix check actually rejects system files.
    const sb = try Sandbox.init(.none, &.{});
    defer sb.deinit();
    try std.testing.expect(!sb.allowFileWrite(resolved));
}

test "resolvePath keeps normal relative paths" {
    const alloc = std.testing.allocator;
    const resolved = try resolvePath(alloc, "/home/user/proj", "src/main.zig");
    defer alloc.free(resolved);
    try std.testing.expectEqualSlices(u8, "/home/user/proj/src/main.zig", resolved);
}

test "workspace restriction blocks outside paths" {
    const alloc = std.testing.allocator;
    const outside = try resolvePath(alloc, "/home/u/proj", "../etc/passwd");
    defer alloc.free(outside);
    try std.testing.expect(!isInsideWorkspace(outside, "/home/u/proj"));

    const inside = try resolvePath(alloc, "/home/u/proj", "src/main.zig");
    defer alloc.free(inside);
    try std.testing.expect(isInsideWorkspace(inside, "/home/u/proj"));

    const cwd_itself = try resolvePath(alloc, "/home/u/proj", ".");
    defer alloc.free(cwd_itself);
    try std.testing.expect(isInsideWorkspace(cwd_itself, "/home/u/proj"));
}
