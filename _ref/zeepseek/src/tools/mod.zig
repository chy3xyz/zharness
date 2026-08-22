const std = @import("std");
const sandbox_mod = @import("../utils/sandbox.zig");

pub const shell = @import("shell.zig");
pub const file = @import("file.zig");
pub const git = @import("git.zig");
pub const web = @import("web.zig");

pub const Sandbox = sandbox_mod.Sandbox;
pub const ApprovalMode = sandbox_mod.ApprovalMode;
pub const CommandValidator = sandbox_mod.CommandValidator;
pub const Policy = sandbox_mod.Policy;

pub const ToolCall = struct {
    index: usize,
    id: []const u8 = "",
    name: []const u8,
    arguments: []const u8,
};

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    err_msg: ?[]const u8 = null,
    sandbox_violation: bool = false,
    execution_denied: bool = false,

    pub fn formatResult(self: *const ToolResult, alloc: std.mem.Allocator) ![]const u8 {
        if (self.success) {
            return alloc.dupe(u8, self.output);
        }
        if (self.sandbox_violation) {
            return std.fmt.allocPrint(alloc, "[sandbox violation] {s}", .{self.err_msg orelse "blocked"});
        }
        if (self.execution_denied) {
            return std.fmt.allocPrint(alloc, "[denied] {s}", .{self.err_msg orelse "user denied"});
        }
        return std.fmt.allocPrint(alloc, "[error] {s}", .{self.err_msg orelse "unknown error"});
    }
};

pub const ExecutionEvent = union(enum) {
    tool_call: ToolCall,
    tool_result: struct {
        call: ToolCall,
        result: ToolResult,
    },
    approval_request: struct {
        call: ToolCall,
        description: []const u8,
    },
};

/// Parse JSON arguments into a string hashmap for easy access.
/// Caller must free the returned HashMap.
pub fn parseArgs(alloc: std.mem.Allocator, json_args: []const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(alloc);
    errdefer {
        var it = map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    // Simple JSON string-value extractor for flat objects
    var i: usize = 0;
    while (i < json_args.len) : (i += 1) {
        if (json_args[i] != '"') continue;
        i += 1;
        const key_start = i;
        while (i < json_args.len and json_args[i] != '"') : (i += 1) {
            if (json_args[i] == '\\' and i + 1 < json_args.len) i += 1;
        }
        const key = json_args[key_start..i];
        if (i >= json_args.len) break;
        i += 1;

        // Skip to colon
        while (i < json_args.len and json_args[i] != ':') : (i += 1) {}
        if (i >= json_args.len) break;
        i += 1;
        while (i < json_args.len and (json_args[i] == ' ' or json_args[i] == '\t')) : (i += 1) {}

        if (i >= json_args.len) break;

        var value: []const u8 = "";
        if (json_args[i] == '"') {
            i += 1;
            const val_start = i;
            while (i < json_args.len and json_args[i] != '"') : (i += 1) {
                if (json_args[i] == '\\' and i + 1 < json_args.len) i += 1;
            }
            value = try alloc.dupe(u8, json_args[val_start..i]);
            if (i < json_args.len) i += 1;
        } else if (json_args[i] == 't' or json_args[i] == 'f') {
            // boolean
            const bool_start = i;
            while (i < json_args.len and std.ascii.isAlphabetic(json_args[i])) : (i += 1) {}
            value = try alloc.dupe(u8, json_args[bool_start..i]);
        } else if (json_args[i] == '-' or std.ascii.isDigit(json_args[i])) {
            // number
            const num_start = i;
            while (i < json_args.len and (std.ascii.isDigit(json_args[i]) or json_args[i] == '.' or json_args[i] == '-')) : (i += 1) {}
            value = try alloc.dupe(u8, json_args[num_start..i]);
        }

        try map.put(key, value);
    }

    return map;
}

pub fn freeArgs(alloc: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.value_ptr.*);
    }
    map.deinit();
}

/// Check if a tool call requires approval based on sandbox policy.
pub fn requiresApproval(sandbox: ?*Sandbox, call: ToolCall) bool {
    const sb = sandbox orelse {
        // No platform sandbox (e.g. macOS Seatbelt failed to init): fail
        // closed — anything mutating or executing requires explicit user
        // approval instead of silently allowing it.
        return std.mem.eql(u8, call.name, "shell") or
            std.mem.eql(u8, call.name, "file_write") or
            std.mem.eql(u8, call.name, "file_edit") or
            std.mem.eql(u8, call.name, "git_commit");
    };
    if (std.mem.eql(u8, call.name, "shell")) {
        return sb.shell_mode == .prompt;
    }
    if (std.mem.eql(u8, call.name, "file_write") or std.mem.eql(u8, call.name, "file_edit")) {
        return sb.file_write_mode == .prompt;
    }
    if (std.mem.eql(u8, call.name, "git_commit")) {
        return sb.git_mode == .prompt;
    }
    return false;
}

/// Build a human-readable description of a tool call for approval UI.
pub fn describeToolCall(alloc: std.mem.Allocator, call: ToolCall) ![]const u8 {
    var map = parseArgs(alloc, call.arguments) catch {
        return std.fmt.allocPrint(alloc, "{s}({s})", .{ call.name, call.arguments });
    };
    defer freeArgs(alloc, &map);

    if (std.mem.eql(u8, call.name, "shell")) {
        const cmd = map.get("command") orelse "(unknown)";
        return std.fmt.allocPrint(alloc, "Run shell command: {s}", .{cmd});
    }
    if (std.mem.eql(u8, call.name, "file_read")) {
        const path = map.get("path") orelse "(unknown)";
        return std.fmt.allocPrint(alloc, "Read file: {s}", .{path});
    }
    if (std.mem.eql(u8, call.name, "file_write")) {
        const path = map.get("path") orelse "(unknown)";
        return std.fmt.allocPrint(alloc, "Write file: {s}", .{path});
    }
    if (std.mem.eql(u8, call.name, "file_edit")) {
        const path = map.get("path") orelse "(unknown)";
        return std.fmt.allocPrint(alloc, "Edit file: {s}", .{path});
    }
    if (std.mem.eql(u8, call.name, "git_status")) {
        return alloc.dupe(u8, "Check git status");
    }
    if (std.mem.eql(u8, call.name, "git_commit")) {
        const msg = map.get("message") orelse "(unknown)";
        return std.fmt.allocPrint(alloc, "Git commit: {s}", .{msg});
    }
    if (std.mem.eql(u8, call.name, "web_search")) {
        const query = map.get("query") orelse "(unknown)";
        return std.fmt.allocPrint(alloc, "Web search: {s}", .{query});
    }
    if (std.mem.eql(u8, call.name, "web_scrape")) {
        const url = map.get("url") orelse "(unknown)";
        return std.fmt.allocPrint(alloc, "Fetch URL: {s}", .{url});
    }

    return std.fmt.allocPrint(alloc, "{s}({s})", .{ call.name, call.arguments });
}

/// Execute a tool call. Returns the result.
/// Does NOT handle approval — caller should check requiresApproval first.
pub fn executeTool(
    alloc: std.mem.Allocator,
    sandbox: ?*Sandbox,
    cwd: []const u8,
    call: ToolCall,
) !ToolResult {
    if (std.mem.eql(u8, call.name, "shell")) {
        return shell.execute(alloc, sandbox, cwd, call);
    }
    if (std.mem.eql(u8, call.name, "file_read")) {
        return file.executeRead(alloc, sandbox, cwd, call);
    }
    if (std.mem.eql(u8, call.name, "file_write")) {
        return file.executeWrite(alloc, sandbox, cwd, call);
    }
    if (std.mem.eql(u8, call.name, "file_edit")) {
        return file.executeEdit(alloc, sandbox, cwd, call);
    }
    if (std.mem.eql(u8, call.name, "glob")) {
        return file.executeGlob(alloc, sandbox, cwd, call);
    }
    if (std.mem.eql(u8, call.name, "grep")) {
        return file.executeGrep(alloc, sandbox, cwd, call);
    }
    if (std.mem.eql(u8, call.name, "git_status")) {
        return git.executeStatus(alloc, sandbox, cwd, call);
    }
    if (std.mem.eql(u8, call.name, "git_log")) {
        return git.executeLog(alloc, sandbox, cwd, call);
    }
    if (std.mem.eql(u8, call.name, "git_diff")) {
        return git.executeDiff(alloc, sandbox, cwd, call);
    }
    if (std.mem.eql(u8, call.name, "git_commit")) {
        return git.executeCommit(alloc, sandbox, cwd, call);
    }
    if (std.mem.eql(u8, call.name, "web_search")) {
        return web.executeSearch(alloc, sandbox, call);
    }
    if (std.mem.eql(u8, call.name, "web_scrape")) {
        return web.executeScrape(alloc, sandbox, call);
    }

    return ToolResult{
        .success = false,
        .output = "",
        .err_msg = "Unknown tool",
    };
}

test "parseArgs simple object" {
    const alloc = std.testing.allocator;
    var map = try parseArgs(alloc, "{\"command\":\"ls -la\",\"path\":\"/tmp\"}");
    defer freeArgs(alloc, &map);

    try std.testing.expectEqual(@as(usize, 2), map.count());
    try std.testing.expectEqualSlices(u8, "ls -la", map.get("command").?);
    try std.testing.expectEqualSlices(u8, "/tmp", map.get("path").?);
}

test "parseArgs nested string" {
    const alloc = std.testing.allocator;
    var map = try parseArgs(alloc, "{\"message\":\"hello world\"}");
    defer freeArgs(alloc, &map);

    try std.testing.expectEqualSlices(u8, "hello world", map.get("message").?);
}

test "describeToolCall shell" {
    const alloc = std.testing.allocator;
    const desc = try describeToolCall(alloc, .{
        .index = 0,
        .name = "shell",
        .arguments = "{\"command\":\"ls -la\"}",
    });
    defer alloc.free(desc);
    try std.testing.expectEqualSlices(u8, "Run shell command: ls -la", desc);
}
