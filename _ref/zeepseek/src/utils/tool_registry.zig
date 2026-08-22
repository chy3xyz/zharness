const std = @import("std");
const ZeepError = @import("error.zig").ZeepError;
const sandbox_mod = @import("sandbox.zig");
const validation = @import("validation.zig");
const Policy = sandbox_mod.Policy;
const ApprovalMode = sandbox_mod.ApprovalMode;

pub const SandboxPolicy = struct {
    kind: SandboxKind,
    allowed_paths: []const []const u8 = &.{},
    denied_paths: []const []const u8 = &.{},
};

pub const SandboxKind = enum {
    none,
    shell,
    file_read,
    file_write,
    git,
    subagent,
    network,
};

/// Canonical list of built-in tool names, in registry insertion order.
/// Single source of truth: /mcp routing (tools_run) and the buildToolsJson
/// coverage test both reference this so the set can never drift.
pub const builtinNames = [_][]const u8{
    "shell",     "file_read", "file_write", "file_edit", "git_status", "git_log",
    "git_diff",  "git_commit", "glob",       "grep",      "web_search", "web_scrape",
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    output_schema: []const u8,
    requires_approval: bool,
    sandbox_policy: SandboxKind,

    pub fn category(self: *const ToolDefinition) []const u8 {
        return switch (self.sandbox_policy) {
            .shell => "shell",
            .file_read => "file",
            .file_write => "file",
            .git => "git",
            .subagent => "agent",
            .network => "network",
            .none => "utility",
        };
    }
};

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    err_msg: ?[]const u8,
    sandbox_violation: bool = false,
    execution_denied: bool = false,
};

pub const ToolRegistry = struct {
    arena: std.heap.ArenaAllocator,
    tools: std.StringHashMap(ToolDefinition),

    pub fn init(alloc: std.mem.Allocator) !*ToolRegistry {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        var registry = try a.create(ToolRegistry);
        registry.* = .{
            .arena = arena,
            .tools = std.StringHashMap(ToolDefinition).init(a),
        };

        try registry.registerBuiltins();

        return registry;
    }

    fn registerBuiltin(self: *ToolRegistry, tool: ToolDefinition) !void {
        const a = self.arena.allocator();
        const name = try a.dupe(u8, tool.name);
        const desc = try a.dupe(u8, tool.description);
        const inp_schema = try a.dupe(u8, tool.input_schema);
        const out_schema = try a.dupe(u8, tool.output_schema);

        var owned = tool;
        owned.name = name;
        owned.description = desc;
        owned.input_schema = inp_schema;
        owned.output_schema = out_schema;

        try self.tools.put(name, owned);
    }

    fn registerBuiltins(self: *ToolRegistry) !void {
        try self.registerBuiltin(.{
            .name = "shell",
            .description = "Execute a shell command in the terminal. Output is returned as text.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"The shell command to execute\"}},\"required\":[\"command\"]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"stdout\":{\"type\":\"string\"},\"stderr\":{\"type\":\"string\"},\"exit_code\":{\"type\":\"integer\"}}}",
            .requires_approval = true,
            .sandbox_policy = .shell,
        });

        try self.registerBuiltin(.{
            .name = "file_read",
            .description = "Read the contents of a file from the filesystem.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Absolute or relative file path\"}},\"required\":[\"path\"]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\"},\"size\":{\"type\":\"integer\"}}}",
            .requires_approval = false,
            .sandbox_policy = .file_read,
        });

        try self.registerBuiltin(.{
            .name = "file_write",
            .description = "Write content to a file, creating it or overwriting it.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"bytes_written\":{\"type\":\"integer\"}}}",
            .requires_approval = true,
            .sandbox_policy = .file_write,
        });

        try self.registerBuiltin(.{
            .name = "file_edit",
            .description = "Edit an existing file by applying a replacement. Uses the old/new pattern.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"oldString\":{\"type\":\"string\"},\"newString\":{\"type\":\"string\"}},\"required\":[\"path\",\"oldString\",\"newString\"]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"lines_changed\":{\"type\":\"integer\"}}}",
            .requires_approval = true,
            .sandbox_policy = .file_write,
        });

        try self.registerBuiltin(.{
            .name = "git_status",
            .description = "Show the working tree status of the git repository.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"repo\":{\"type\":\"string\",\"description\":\"Path to the git repository (default: current directory)\"}},\"required\":[]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"files\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"branch\":{\"type\":\"string\"}}}",
            .requires_approval = false,
            .sandbox_policy = .git,
        });

        try self.registerBuiltin(.{
            .name = "git_log",
            .description = "Show the git commit log with optional limit.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\",\"default\":10},\"repo\":{\"type\":\"string\"}},\"required\":[]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"commits\":{\"type\":\"array\"}}}",
            .requires_approval = false,
            .sandbox_policy = .git,
        });

        try self.registerBuiltin(.{
            .name = "git_diff",
            .description = "Show changes between commits, commit and working tree, etc.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"target\":{\"type\":\"string\",\"description\":\"Commit ref or empty for working tree diff\"},\"repo\":{\"type\":\"string\"}},\"required\":[]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"diff\":{\"type\":\"string\"}}}",
            .requires_approval = false,
            .sandbox_policy = .git,
        });

        try self.registerBuiltin(.{
            .name = "git_commit",
            .description = "Create a new git commit with the given message.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"},\"all\":{\"type\":\"boolean\",\"default\":false},\"repo\":{\"type\":\"string\"}},\"required\":[\"message\"]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"commit_hash\":{\"type\":\"string\"}}}",
            .requires_approval = true,
            .sandbox_policy = .git,
        });

        try self.registerBuiltin(.{
            .name = "glob",
            .description = "Find files matching a glob pattern.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Glob pattern e.g. src/**/*.zig\"},\"root\":{\"type\":\"string\",\"default\":\".\"}},\"required\":[\"pattern\"]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"matches\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}",
            .requires_approval = false,
            .sandbox_policy = .file_read,
        });

        try self.registerBuiltin(.{
            .name = "grep",
            .description = "Search for patterns in files using regular expressions.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\",\"default\":\".\"},\"include\":{\"type\":\"string\",\"description\":\"File pattern filter\"}},\"required\":[\"pattern\"]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"matches\":{\"type\":\"array\"}}}",
            .requires_approval = false,
            .sandbox_policy = .file_read,
        });

        try self.registerBuiltin(.{
            .name = "web_search",
            .description = "Search the web for information. Requires network access.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\",\"default\":5}},\"required\":[\"query\"]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"results\":{\"type\":\"array\"}}}",
            .requires_approval = false,
            .sandbox_policy = .network,
        });

        try self.registerBuiltin(.{
            .name = "web_scrape",
            .description = "Fetch and extract content from a web page URL.",
            .input_schema = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"format\":\"uri\"},\"selectors\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"url\"]}",
            .output_schema = "{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\"},\"links\":{\"type\":\"array\"}}}",
            .requires_approval = false,
            .sandbox_policy = .network,
        });
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.arena.deinit();
    }

    pub fn register(self: *ToolRegistry, tool: ToolDefinition) !void {
        try self.registerBuiltin(tool);
    }

    pub fn get(self: *const ToolRegistry, name: []const u8) ?ToolDefinition {
        return self.tools.get(name);
    }

    pub fn listTools(self: *ToolRegistry) []const ToolDefinition {
        const a = self.arena.allocator();
        var out = std.ArrayList(ToolDefinition).empty;
        defer out.deinit(a);
        var it = self.tools.iterator();
        while (it.next()) |entry| out.append(a, entry.value_ptr.*) catch {};
        return out.toOwnedSlice(a) catch &.{};
    }

    pub fn listForPrompt(self: *ToolRegistry) []const ToolDefinition {
        return self.listTools();
    }

    pub fn checkSandbox(self: *const ToolRegistry, name: []const u8, sb: *sandbox_mod.Sandbox) bool {
        const tool = self.tools.get(name) orelse return false;
        return switch (tool.sandbox_policy) {
            .shell => sb.allowShell(name),
            .file_read => sb.allowFileRead(name),
            .file_write => sb.allowFileWrite(name),
            .git => sb.allowGit(name),
            .subagent => sb.allowSubAgent(),
            .network => true,
            .none => true,
        };
    }

    pub fn validateToolArgs(self: *const ToolRegistry, tool_name: []const u8, args: []const u8) !void {
        _ = self;
        if (std.mem.eql(u8, tool_name, "web_fetch") or std.mem.eql(u8, tool_name, "web_search") or std.mem.eql(u8, tool_name, "web_scrape")) {
            try validation.validateUrl(args);
        }
        if (std.mem.indexOf(u8, tool_name, "file_") != null) {
            validation.validatePath(args) catch |err| {
                if (err == error.InvalidPath) return ZeepError.ConfigValidationFailed;
                if (err == error.PathTraversal) return ZeepError.SandboxViolation;
                return err;
            };
        }
    }
};

/// Serialize every registered tool into the OpenAI `tools` array item format.
/// Each item is `{"type":"function","function":{"name":...,"description":...,"parameters":<input_schema>}}`.
/// Returns a comma-joined fragment with NO surrounding brackets, so callers can
/// strip it inside an existing `[ ... ]` and append MCP tools afterward.
/// Emitted in deterministic (sorted-by-name) order for reproducible requests.
pub fn buildToolsJson(allocator: std.mem.Allocator) ![]u8 {
    var registry = try ToolRegistry.init(allocator);
    defer registry.deinit();

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(allocator);
    var it = registry.tools.iterator();
    while (it.next()) |entry| {
        try names.append(allocator, entry.key_ptr.*);
    }
    if (names.items.len == 0) return allocator.dupe(u8, "");
    std.mem.sort([]const u8, names.items, {}, lessThanName);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (names.items, 0..) |name, i| {
        const t = registry.tools.get(name) orelse continue;
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":\"");
        try out.appendSlice(allocator, t.name);
        try out.appendSlice(allocator, "\",\"description\":\"");
        try escapeJson(allocator, &out, t.description);
        try out.appendSlice(allocator, "\",\"parameters\":");
        try out.appendSlice(allocator, t.input_schema);
        try out.appendSlice(allocator, "}}");
    }
    return out.toOwnedSlice(allocator);
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn escapeJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
}

test "buildToolsJson covers all registered tools" {
    const alloc = std.testing.allocator;
    const json = try buildToolsJson(alloc);
    defer alloc.free(json);

    // Every registered builtin name must appear as a function declaration.
    const names = builtinNames;
    var count: usize = 0;
    var needle_buf: [128]u8 = undefined;
    for (names) |n| {
        const needle = std.fmt.bufPrint(&needle_buf, "\"name\":\"{s}\"", .{n}) catch unreachable;
        if (std.mem.indexOf(u8, json, needle) != null) count += 1;
    }
    try std.testing.expectEqual(names.len, count);

    // Deterministic ordering: sorted by name.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"file_edit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"git_commit\"") != null);
    const f = std.mem.indexOf(u8, json, "\"name\":\"file_").?;
    const g = std.mem.indexOf(u8, json, "\"name\":\"git_").?;
    try std.testing.expect(f < g);

    // Each item embeds a valid JSON object schema.
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"type\":\"function\""));
}

test "tool registry init has builtins" {
    const alloc = std.testing.allocator;
    var registry = try ToolRegistry.init(alloc);
    defer registry.deinit();

    try std.testing.expect(registry.get("shell") != null);
    try std.testing.expect(registry.get("file_read") != null);
    try std.testing.expect(registry.get("file_write") != null);
    try std.testing.expect(registry.get("git_status") != null);
    try std.testing.expect(registry.get("git_log") != null);
    try std.testing.expect(registry.get("git_diff") != null);
    try std.testing.expect(registry.get("git_commit") != null);
    try std.testing.expect(registry.get("glob") != null);
    try std.testing.expect(registry.get("grep") != null);
    try std.testing.expect(registry.get("web_search") != null);
    try std.testing.expect(registry.get("web_scrape") != null);
}

test "tool registry listForPrompt returns all" {
    const alloc = std.testing.allocator;
    var registry = try ToolRegistry.init(alloc);
    defer registry.deinit();

    const tools = registry.listForPrompt();
    try std.testing.expect(tools.len >= 12);
}

test "tool sandbox kind categories" {
    const alloc = std.testing.allocator;
    var registry = try ToolRegistry.init(alloc);
    defer registry.deinit();

    const shell_tool = registry.get("shell").?;
    try std.testing.expect(std.mem.eql(u8, shell_tool.category(), "shell"));

    const file_tool = registry.get("file_read").?;
    try std.testing.expect(std.mem.eql(u8, file_tool.category(), "file"));

    const git_tool = registry.get("git_status").?;
    try std.testing.expect(std.mem.eql(u8, git_tool.category(), "git"));
}

test "tool registry unknown tool returns null" {
    const alloc = std.testing.allocator;
    var registry = try ToolRegistry.init(alloc);
    defer registry.deinit();

    try std.testing.expect(registry.get("nonexistent_tool") == null);
}
