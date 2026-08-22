const std = @import("std");
const tools_mod = @import("mod.zig");
const ToolCall = tools_mod.ToolCall;
const ToolResult = tools_mod.ToolResult;
const sandbox_mod = @import("../utils/sandbox.zig");
const Sandbox = sandbox_mod.Sandbox;
const process_mod = @import("process.zig");

pub fn execute(
    alloc: std.mem.Allocator,
    sandbox: ?*Sandbox,
    cwd: []const u8,
    call: ToolCall,
) !ToolResult {
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{
            .success = false,
            .output = "",
            .err_msg = "Failed to parse arguments",
        };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const cmd = map.get("command") orelse {
        return ToolResult{
            .success = false,
            .output = "",
            .err_msg = "Missing 'command' argument",
        };
    };

    const result = process_mod.runShell(alloc, sandbox, cwd, cmd) catch {
        return ToolResult{
            .success = false,
            .output = "",
            .err_msg = "Failed to spawn shell process",
        };
    };

    if (!result.success and std.mem.startsWith(u8, result.output, "[sandbox violation]")) {
        return ToolResult{
            .success = false,
            .output = result.output,
            .err_msg = "Command blocked by sandbox",
            .sandbox_violation = true,
        };
    }

    return ToolResult{
        .success = result.success,
        .output = result.output,
        .err_msg = if (result.success) null else "Command exited with non-zero status",
    };
}

test "shell execute echo" {
    const alloc = std.testing.allocator;
    const result = try execute(alloc, null, ".", .{
        .index = 0,
        .name = "shell",
        .arguments = "{\"command\":\"echo hello\"}",
    });
    defer alloc.free(result.output);
    if (result.err_msg) |em| {
        alloc.free(em);
    }

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

test "shell execute pwd" {
    const alloc = std.testing.allocator;
    const result = try execute(alloc, null, "/tmp", .{
        .index = 0,
        .name = "shell",
        .arguments = "{\"command\":\"pwd\"}",
    });
    defer alloc.free(result.output);
    if (result.err_msg) |em| {
        alloc.free(em);
    }

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/tmp") != null);
}
