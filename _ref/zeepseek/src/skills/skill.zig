const std = @import("std");

pub const SkillError = error{
    InvalidManifest,
    ManifestParseFailed,
    ValidationFailed,
    InstallFailed,
    UninstallFailed,
    ReloadFailed,
    SkillNotFound,
    CommandNotFound,
    HandlerNotFound,
    SkillsDirNotFound,
    NetworkError,
    ParseError,
};

pub const Source = union(enum) {
    github: GithubSource,
    local: LocalSource,

    pub const GithubSource = struct {
        owner: []const u8,
        repo: []const u8,
        path: []const u8,
    };

    pub const LocalSource = struct {
        path: []const u8,
    };
};

pub const HandlerType = enum {
    mcp,
    script,
    prompt,

    pub fn parse(raw: []const u8) ?HandlerType {
        if (std.mem.startsWith(u8, raw, "mcp:")) return .mcp;
        if (std.mem.startsWith(u8, raw, "script:")) return .script;
        if (std.mem.startsWith(u8, raw, "prompt:")) return .prompt;
        return null;
    }

    pub fn parseMcp(raw: []const u8) ?struct { server: []const u8, tool: []const u8 } {
        if (!std.mem.startsWith(u8, raw, "mcp:")) return null;
        const rest = raw[4..];
        const colon_idx = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
        return .{
            .server = rest[0..colon_idx],
            .tool = rest[colon_idx + 1..],
        };
    }

    pub fn parseScript(raw: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, raw, "script:")) return null;
        return raw[7..];
    }

    pub fn parsePrompt(raw: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, raw, "prompt:")) return null;
        return raw[7..];
    }
};

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    usage: []const u8,
    handler: []const u8,
};

pub const PromptTemplate = struct {
    name: []const u8,
    template: []const u8,
};

pub const Skill = struct {
    name: []const u8,
    display_name: []const u8,
    description: []const u8,
    version: []const u8,
    author: []const u8,
    source: Source,
    commands: []Command,
    tools: []const []const u8,
    config_schema: ?[]const u8,
    prompts: []PromptTemplate,

    pub fn getCommand(self: *const Skill, name: []const u8) ?*const Command {
        for (self.commands) |*cmd| {
            if (std.mem.eql(u8, cmd.name, name)) return cmd;
        }
        return null;
    }

    pub fn getPrompt(self: *const Skill, name: []const u8) ?*const PromptTemplate {
        for (self.prompts) |*prompt| {
            if (std.mem.eql(u8, prompt.name, name)) return prompt;
        }
        return null;
    }

    pub fn formatCommand(_: *const Skill, cmd: *const Command) []const u8 {
        return std.fmt.comptimePrint("/{s}", .{cmd.name});
    }

    /// Free all strings/slices owned by this skill. `source` paths are not
    /// freed here (they may reference owned or borrowed storage depending on
    /// how the skill was constructed).
    pub fn deinit(self: *Skill, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.display_name);
        alloc.free(self.description);
        alloc.free(self.version);
        alloc.free(self.author);
        for (self.commands) |*cmd| {
            alloc.free(cmd.name);
            alloc.free(cmd.description);
            alloc.free(cmd.usage);
            alloc.free(cmd.handler);
        }
        alloc.free(self.commands);
        for (self.tools) |t| alloc.free(t);
        alloc.free(self.tools);
        if (self.config_schema) |cs| {
            alloc.free(cs);
        }
        for (self.prompts) |*prompt| {
            alloc.free(prompt.name);
            alloc.free(prompt.template);
        }
        alloc.free(self.prompts);
    }
};

pub const ManifestRaw = struct {
    name: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
    author: ?[]const u8 = null,
    source: ?ManifestSourceRaw = null,
    commands: ?[]ManifestCommandRaw = null,
    tools: ?[]const []const u8 = null,
    config_schema: ?[]const u8 = null,
    prompts: ?[]ManifestPromptRaw = null,
};

pub const ManifestSourceRaw = struct {
    github: ?ManifestGithubRaw = null,
    local: ?ManifestLocalRaw = null,
};

pub const ManifestGithubRaw = struct {
    owner: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const ManifestLocalRaw = struct {
    path: ?[]const u8 = null,
};

pub const ManifestCommandRaw = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    usage: ?[]const u8 = null,
    handler: ?[]const u8 = null,
};

pub const ManifestPromptRaw = struct {
    name: ?[]const u8 = null,
    template: ?[]const u8 = null,
};
