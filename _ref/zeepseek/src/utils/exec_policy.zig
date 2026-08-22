const std = @import("std");
const array_list = std.array_list;
const ZeepError = @import("error.zig").ZeepError;
const dangerous_patterns = @import("dangerous_patterns.zig");

pub const ApprovalMode = enum {
    prompt,
    auto_allow,
    auto_deny,

    pub fn fromString(s: []const u8) ?ApprovalMode {
        if (std.mem.eql(u8, s, "auto_allow")) return .auto_allow;
        if (std.mem.eql(u8, s, "auto_deny")) return .auto_deny;
        if (std.mem.eql(u8, s, "prompt")) return .prompt;
        return null;
    }

    pub fn toString(self: ApprovalMode) []const u8 {
        return switch (self) {
            .auto_allow => "auto_allow",
            .auto_deny => "auto_deny",
            .prompt => "prompt",
        };
    }
};

pub const ToolPermission = struct {
    name: []const u8,
    mode: ApprovalMode = .prompt,
    last_approved_ts: i64 = 0,
    deny_count: u32 = 0,
};

pub const ExecPolicy = struct {
    arena: std.heap.ArenaAllocator,
    permissions: std.StringHashMap(ToolPermission),
    config_entries: std.StringHashMap(ApprovalMode),

    pub fn init(alloc: std.mem.Allocator) !*ExecPolicy {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        var policy = try a.create(ExecPolicy);
        policy.* = .{
            .arena = arena,
            .permissions = undefined,
            .config_entries = undefined,
        };
        const stable = policy.arena.allocator();
        policy.permissions = std.StringHashMap(ToolPermission).init(stable);
        policy.config_entries = std.StringHashMap(ApprovalMode).init(stable);

        try policy.initDefaults();

        return policy;
    }

    fn initDefaults(self: *ExecPolicy) !void {
        const a = self.arena.allocator();
        const default_tools = [_][]const u8{
            "shell",
            "file_read",
            "file_write",
            "file_edit",
            "git_status",
            "git_log",
            "git_diff",
            "git_commit",
            "glob",
            "grep",
            "web_search",
            "web_scrape",
        };

        for (default_tools) |name| {
            const owned = try a.dupe(u8, name);
            try self.permissions.put(owned, .{
                .name = owned,
                .mode = .prompt,
                .last_approved_ts = 0,
                .deny_count = 0,
            });
            try self.config_entries.put(owned, .prompt);
        }
    }

    pub fn deinit(self: *ExecPolicy) void {
        self.arena.deinit();
    }

    pub fn canExecute(self: *ExecPolicy, tool_name: []const u8) ApprovalMode {
        if (self.permissions.get(tool_name)) |perm| {
            return perm.mode;
        }
        return .prompt;
    }

    pub fn approve(self: *ExecPolicy, tool_name: []const u8) void {
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        const now: i64 = @intCast(tv.sec);
        if (self.permissions.getPtr(tool_name)) |perm| {
            perm.mode = .auto_allow;
            perm.last_approved_ts = now;
        } else {
            const a = self.arena.allocator();
            const owned = a.dupe(u8, tool_name) catch return;
            self.permissions.put(owned, .{
                .name = owned,
                .mode = .auto_allow,
                .last_approved_ts = now,
                .deny_count = 0,
            }) catch return;
        }
        self.config_entries.put(tool_name, .auto_allow) catch return;
    }

    pub fn deny(self: *ExecPolicy, tool_name: []const u8) void {
        if (self.permissions.getPtr(tool_name)) |perm| {
            perm.mode = .auto_deny;
            perm.deny_count += 1;
        } else {
            const a = self.arena.allocator();
            const owned = a.dupe(u8, tool_name) catch return;
            self.permissions.put(owned, .{
                .name = owned,
                .mode = .auto_deny,
                .last_approved_ts = 0,
                .deny_count = 1,
            }) catch return;
        }
        self.config_entries.put(tool_name, .auto_deny) catch return;
    }

    pub fn setMode(self: *ExecPolicy, tool_name: []const u8, mode: ApprovalMode) void {
        if (self.permissions.getPtr(tool_name)) |perm| {
            perm.mode = mode;
        } else {
            const a = self.arena.allocator();
            const owned = a.dupe(u8, tool_name) catch return;
            self.permissions.put(owned, .{
                .name = owned,
                .mode = mode,
                .last_approved_ts = 0,
                .deny_count = 0,
            }) catch return;
        }
        self.config_entries.put(tool_name, mode) catch return;
    }

    pub fn loadFromConfig(self: *ExecPolicy, entries: []const ToolConfigEntry) void {
        for (entries) |entry| {
            self.setMode(entry.name, entry.mode);
        }
    }

    pub fn persistToConfig(self: *ExecPolicy, alloc: std.mem.Allocator) ![]const u8 {
        var content = std.ArrayList(u8).empty;
        defer content.deinit(alloc);
        try content.appendSlice(alloc, "# Tool execution policies\n");
        var iter = self.config_entries.iterator();
        while (iter.next()) |entry| {
            const line = try std.fmt.allocPrint(alloc, "tool.{s}.mode={s}\n", .{ entry.key_ptr.*, entry.value_ptr.toString() });
            defer alloc.free(line);
            try content.appendSlice(alloc, line);
        }

        return content.toOwnedSlice(alloc);
    }

    pub fn listPermissions(self: *const ExecPolicy) []const ToolPermission {
        const a = self.arena.allocator();
        var list = std.ArrayList(ToolPermission).empty;
        defer list.deinit(a);
        var it = self.permissions.iterator();
        while (it.next()) |entry| {
            list.append(a, entry.value_ptr.*) catch break;
        }
        return list.toOwnedSlice(a) catch return &.{};
    }

    pub fn checkDangerous(self: *ExecPolicy, command: []const u8) ?dangerous_patterns.DangerousPattern {
        _ = self;
        return dangerous_patterns.checkDangerousCommand(command);
    }
};

pub const ToolConfigEntry = struct {
    name: []const u8,
    mode: ApprovalMode,
};

test "exec policy default is prompt" {
    const alloc = std.testing.allocator;
    var policy = try ExecPolicy.init(alloc);
    defer policy.deinit();

    try std.testing.expect(policy.canExecute("shell") == .prompt);
    try std.testing.expect(policy.canExecute("file_read") == .prompt);
    try std.testing.expect(policy.canExecute("unknown_tool") == .prompt);
}

test "exec policy approve" {
    const alloc = std.testing.allocator;
    var policy = try ExecPolicy.init(alloc);
    defer policy.deinit();

    policy.approve("shell");
    try std.testing.expect(policy.canExecute("shell") == .auto_allow);
}

test "exec policy deny" {
    const alloc = std.testing.allocator;
    var policy = try ExecPolicy.init(alloc);
    defer policy.deinit();

    policy.deny("shell");
    try std.testing.expect(policy.canExecute("shell") == .auto_deny);

    const perm = policy.permissions.get("shell");
    try std.testing.expect(perm.?.deny_count == 1);
}

test "exec policy setMode" {
    const alloc = std.testing.allocator;
    var policy = try ExecPolicy.init(alloc);
    defer policy.deinit();

    policy.setMode("shell", .auto_allow);
    try std.testing.expect(policy.canExecute("shell") == .auto_allow);

    policy.setMode("shell", .prompt);
    try std.testing.expect(policy.canExecute("shell") == .prompt);
}

test "exec policy persistToConfig" {
    const alloc = std.testing.allocator;
    var policy = try ExecPolicy.init(alloc);
    defer policy.deinit();

    policy.setMode("shell", .auto_allow);
    const config = try policy.persistToConfig(alloc);
    defer alloc.free(config);

    try std.testing.expect(std.mem.indexOf(u8, config, "tool.shell.mode=auto_allow") != null);
}

test "approval mode fromString" {
    try std.testing.expect(ApprovalMode.fromString("auto_allow") == .auto_allow);
    try std.testing.expect(ApprovalMode.fromString("auto_deny") == .auto_deny);
    try std.testing.expect(ApprovalMode.fromString("prompt") == .prompt);
    try std.testing.expect(ApprovalMode.fromString("invalid") == null);
}

test "approval mode toString" {
    try std.testing.expect(std.mem.eql(u8, ApprovalMode.toString(.auto_allow), "auto_allow"));
    try std.testing.expect(std.mem.eql(u8, ApprovalMode.toString(.auto_deny), "auto_deny"));
    try std.testing.expect(std.mem.eql(u8, ApprovalMode.toString(.prompt), "prompt"));
}
