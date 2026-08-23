//! Tool system — single source of truth for the agent's callable capabilities.
//!
//! Every tool the model can invoke is declared here as a `ToolDefinition`
//! carrying its OpenAI-format schema. The model client serializes these into
//! the request `tools` field, so the wire schema can never drift from what the
//! executor actually implements (dev.md §VI–VII).

const std = @import("std");

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    /// JSON object describing the `parameters` of the tool (OpenAI function
    /// schema). Owned by the registry.
    parameters_json: []const u8,
    category: Category = .general,

    pub const Category = enum {
        general,
        filesystem,
        shell,
        vcs,
        search,
    };
};

pub const ToolRegistry = struct {
    alloc: std.mem.Allocator,
    tools: std.StringHashMap(ToolDefinition),

    pub fn init(alloc: std.mem.Allocator) !ToolRegistry {
        return .{
            .alloc = alloc,
            .tools = std.StringHashMap(ToolDefinition).init(alloc),
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.name);
            self.alloc.free(entry.value_ptr.description);
            self.alloc.free(entry.value_ptr.parameters_json);
        }
        self.tools.deinit();
    }

    pub fn register(self: *ToolRegistry, def: ToolDefinition) !void {
        const key = try self.alloc.dupe(u8, def.name);
        const value = ToolDefinition{
            .name = try self.alloc.dupe(u8, def.name),
            .description = try self.alloc.dupe(u8, def.description),
            .parameters_json = try self.alloc.dupe(u8, def.parameters_json),
            .category = def.category,
        };
        try self.tools.put(key, value);
    }

    pub fn get(self: *const ToolRegistry, name: []const u8) ?ToolDefinition {
        return self.tools.get(name);
    }

    pub fn contains(self: *const ToolRegistry, name: []const u8) bool {
        return self.tools.contains(name);
    }

    pub fn list(self: *const ToolRegistry) ![][]const u8 {
        var names = try std.ArrayList([]const u8).initCapacity(self.alloc, 0);
        var it = self.tools.keyIterator();
        while (it.next()) |k| {
            try names.append(self.alloc, k.*);
        }
        return names.toOwnedSlice(self.alloc);
    }

    /// Serialize all tool definitions as an OpenAI `tools` array body fragment
    /// (no surrounding brackets), comma-joined. Caller frees.
    pub fn buildToolsJson(self: *const ToolRegistry, alloc: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var it = self.tools.iterator();
        var first = true;
        while (it.next()) |entry| {
            const def = entry.value_ptr.*;
            if (!first) try out.append(alloc, ',');
            first = false;
            try out.appendSlice(alloc, "{\"type\":\"function\",\"function\":{\"name\":\"");
            try out.appendSlice(alloc, def.name);
            try out.appendSlice(alloc, "\",\"description\":\"");
            try escapeJson(alloc, def.description, &out);
            try out.appendSlice(alloc, "\",\"parameters\":");
            try out.appendSlice(alloc, def.parameters_json);
            try out.appendSlice(alloc, "}}");
        }
        return out.toOwnedSlice(alloc);
    }
};

fn escapeJson(alloc: std.mem.Allocator, input: []const u8, out: *std.ArrayList(u8)) !void {
    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
}

/// Register the builtin coding-agent tools (dev.md §X–XI): filesystem, shell,
/// git, grep, glob. The `execute` side lives in `tool/builtin.zig`.
pub fn registerBuiltins(reg: *ToolRegistry) !void {
    try reg.register(.{
        .name = "file_read",
        .description = "Read a UTF-8 text file inside the workspace. Returns the file content. Use for source, configs, logs.",
        .category = .filesystem,
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Relative or absolute path to the file"}},"required":["path"]}
        ,
    });
    try reg.register(.{
        .name = "file_write",
        .description = "Write content to a file inside the workspace, creating parent directories. Overwrites existing files.",
        .category = .filesystem,
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"content":{"type":"string","description":"Full file content to write"}},"required":["path","content"]}
        ,
    });
    try reg.register(.{
        .name = "file_edit",
        .description = "Apply a precise textual edit to a file via an exact old->new string replacement. Fails if old_string is not unique or not found.",
        .category = .filesystem,
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"old_string":{"type":"string","description":"Exact text to replace"},"new_string":{"type":"string","description":"Replacement text"}},"required":["path","old_string","new_string"]}
        ,
    });
    try reg.register(.{
        .name = "glob",
        .description = "Find files by glob pattern (e.g. '**/*.zig'). Searches the workspace.",
        .category = .search,
        .parameters_json =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern"},"path":{"type":"string","description":"Optional base directory"}},"required":["pattern"]}
        ,
    });
    try reg.register(.{
        .name = "grep",
        .description = "Search file contents for a text pattern (case-sensitive substring match by default). Returns matching lines with file paths.",
        .category = .search,
        .parameters_json =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Text pattern to search for"},"path":{"type":"string","description":"Directory or file to search"},"ignore_case":{"type":"boolean","description":"Case-insensitive match"}},"required":["pattern"]}
        ,
    });
    try reg.register(.{
        .name = "shell",
        .description = "Run a shell command via /bin/sh -c in the workspace directory. stdout and stderr are merged into the result. Prefer precise commands over shell pipelines where possible.",
        .category = .shell,
        .parameters_json =
        \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute"}},"required":["command"]}
        ,
    });
    try reg.register(.{
        .name = "git_status",
        .description = "Show the git working tree status (porcelain format).",
        .category = .vcs,
        .parameters_json =
        \\{"type":"object","properties":{},"required":[]}
        ,
    });
    try reg.register(.{
        .name = "git_diff",
        .description = "Show a git diff. Optional staged flag to show staged changes.",
        .category = .vcs,
        .parameters_json =
        \\{"type":"object","properties":{"staged":{"type":"boolean","description":"Show staged changes instead of working tree"}},"required":[]}
        ,
    });
    try reg.register(.{
        .name = "git_log",
        .description = "Show recent git commit history.",
        .category = .vcs,
        .parameters_json =
        \\{"type":"object","properties":{"limit":{"type":"integer","description":"Number of commits to show"}},"required":[]}
        ,
    });
    try reg.register(.{
        .name = "git_commit",
        .description = "Stage all changes and create a git commit with the given message.",
        .category = .vcs,
        .parameters_json =
        \\{"type":"object","properties":{"message":{"type":"string","description":"Commit message"}},"required":["message"]}
        ,
    });
}
