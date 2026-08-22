const std = @import("std");
const c = @import("c");
const skill_mod = @import("skill.zig");
const Skill = skill_mod.Skill;
const Source = skill_mod.Source;
const Command = skill_mod.Command;
const PromptTemplate = skill_mod.PromptTemplate;
const ManifestRaw = skill_mod.ManifestRaw;
const ManifestSourceRaw = skill_mod.ManifestSourceRaw;
const ManifestGithubRaw = skill_mod.ManifestGithubRaw;
const ManifestLocalRaw = skill_mod.ManifestLocalRaw;
const ManifestCommandRaw = skill_mod.ManifestCommandRaw;
const ManifestPromptRaw = skill_mod.ManifestPromptRaw;
const SkillError = skill_mod.SkillError;

pub const ManifestParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ManifestParser {
        return .{ .allocator = allocator };
    }

    pub fn parseFile(self: *ManifestParser, path: []const u8) !Skill {
        const path_z = std.heap.page_allocator.dupeSentinel(u8, path, 0) catch return SkillError.ManifestParseFailed;
        defer std.heap.page_allocator.free(path_z);

        const fp = c.fopen(path_z.ptr, "rb");
        if (fp == null) {
            std.debug.print("[SKILL] Manifest not found: {s}\n", .{path});
            return SkillError.ManifestParseFailed;
        }
        defer _ = c.fclose(fp);

        _ = c.fseek(fp, 0, c.SEEK_END);
        const file_size = c.ftell(fp);
        _ = c.fseek(fp, 0, c.SEEK_SET);
        if (file_size < 0) return error.ReadError;

        const size_usize = @as(usize, @intCast(file_size));
        const content = try self.allocator.alloc(u8, size_usize);
        defer self.allocator.free(content);
        const read_size = c.fread(content.ptr, 1, size_usize, fp);
        if (read_size != size_usize) return error.ReadError;

        return self.parse(content, path);
    }

    pub fn parse(self: *ManifestParser, content: []const u8, source_path: []const u8) !Skill {
        if (std.mem.endsWith(u8, source_path, ".yaml") or std.mem.endsWith(u8, source_path, ".yml")) {
            return self.parseYaml(content);
        } else if (std.mem.endsWith(u8, source_path, ".json")) {
            return self.parseJson(content);
        }
        return self.parseYaml(content);
    }

    fn parseYaml(self: *ManifestParser, content: []const u8) !Skill {
        var raw = ManifestRaw{};
        var lines = std.mem.splitScalar(u8, content, '\n');

        var in_list = false;
        var list_item_buf: std.ArrayList([]const u8) = undefined;
        var command_buf: std.ArrayList(ManifestCommandRaw) = undefined;
        var prompt_buf: std.ArrayList(ManifestPromptRaw) = undefined;
        var current_command: ?ManifestCommandRaw = null;
        var current_prompt: ?ManifestPromptRaw = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;

            if (trimmed[0] == '#') continue;

            if (std.mem.startsWith(u8, trimmed, "name:")) {
                raw.name = try self.extractYamlValue(trimmed, "name:");
            } else if (std.mem.startsWith(u8, trimmed, "display_name:")) {
                raw.display_name = try self.extractYamlValue(trimmed, "display_name:");
            } else if (std.mem.startsWith(u8, trimmed, "description:")) {
                raw.description = try self.extractYamlValue(trimmed, "description:");
            } else if (std.mem.startsWith(u8, trimmed, "version:")) {
                raw.version = try self.extractYamlValue(trimmed, "version:");
            } else if (std.mem.startsWith(u8, trimmed, "author:")) {
                raw.author = try self.extractYamlValue(trimmed, "author:");
            } else if (std.mem.startsWith(u8, trimmed, "tools:")) {
                in_list = true;
                list_item_buf = .empty;
                const val = try self.extractYamlValue(trimmed, "tools:");
                if (val) |v| {
                    try list_item_buf.append(self.allocator, v);
                }
            } else if (std.mem.startsWith(u8, trimmed, "config_schema:")) {
                raw.config_schema = try self.extractYamlValue(trimmed, "config_schema:");
            } else if (std.mem.startsWith(u8, trimmed, "commands:")) {
                in_list = true;
                command_buf = .empty;
                _ = lines.next();
                while (lines.peek()) |next| {
                    if (std.mem.startsWith(u8, std.mem.trim(u8, next, " \t"), "- name:")) {
                        if (current_command) |cmd| {
                            try command_buf.append(self.allocator, cmd);
                        }
                        current_command = .{};
                        const name_val = try self.extractYamlValue(std.mem.trim(u8, next[1..], " \t"), "name:");
                        if (current_command) |*cmd| {
                            cmd.name = name_val;
                        }
                    } else if (std.mem.startsWith(u8, std.mem.trim(u8, next, " \t"), "description:")) {
                        if (current_command) |*cmd| {
                            cmd.description = try self.extractYamlValue(std.mem.trim(u8, next, " \t"), "description:");
                        }
                    } else if (std.mem.startsWith(u8, std.mem.trim(u8, next, " \t"), "usage:")) {
                        if (current_command) |*cmd| {
                            cmd.usage = try self.extractYamlValue(std.mem.trim(u8, next, " \t"), "usage:");
                        }
                    } else if (std.mem.startsWith(u8, std.mem.trim(u8, next, " \t"), "handler:")) {
                        if (current_command) |*cmd| {
                            cmd.handler = try self.extractYamlValue(std.mem.trim(u8, next, " \t"), "handler:");
                        }
                    } else if (!std.mem.startsWith(u8, std.mem.trim(u8, next, " \t"), "  ") and std.mem.trim(u8, next, " \t").len > 0 and !std.mem.startsWith(u8, std.mem.trim(u8, next, " \t"), "-")) {
                        if (current_command) |cmd| {
                            try command_buf.append(self.allocator, cmd);
                        }
                        current_command = null;
                        break;
                    } else {
                        _ = lines.next();
                    }
                }
                if (current_command) |cmd| {
                    try command_buf.append(self.allocator, cmd);
                }
                current_command = null;
                raw.commands = try command_buf.toOwnedSlice(self.allocator);
                in_list = false;
            } else if (std.mem.startsWith(u8, trimmed, "prompts:")) {
                in_list = true;
                prompt_buf = .empty;
                _ = lines.next();
                while (lines.peek()) |next| {
                    if (std.mem.startsWith(u8, std.mem.trim(u8, next, " \t"), "- name:")) {
                        if (current_prompt) |pr| {
                            try prompt_buf.append(self.allocator, pr);
                        }
                        current_prompt = .{};
                        const name_val = try self.extractYamlValue(std.mem.trim(u8, next[1..], " \t"), "name:");
                        if (current_prompt) |*prompt| {
                            prompt.name = name_val;
                        }
                    } else if (std.mem.startsWith(u8, std.mem.trim(u8, next, " \t"), "template:")) {
                        if (current_prompt) |*prompt| {
                            prompt.template = try self.extractYamlValue(std.mem.trim(u8, next, " \t"), "template:");
                        }
                    } else if (!std.mem.startsWith(u8, std.mem.trim(u8, next, " \t"), "  ") and std.mem.trim(u8, next, " \t").len > 0 and !std.mem.startsWith(u8, std.mem.trim(u8, next, " \t"), "-")) {
                        if (current_prompt) |pr| {
                            try prompt_buf.append(self.allocator, pr);
                        }
                        current_prompt = null;
                        break;
                    } else {
                        _ = lines.next();
                    }
                }
                if (current_prompt) |pr| {
                    try prompt_buf.append(self.allocator, pr);
                }
                current_prompt = null;
                raw.prompts = try prompt_buf.toOwnedSlice(self.allocator);
                in_list = false;
            }
        }

        return try self.buildSkill(raw);
    }

    fn extractYamlValue(self: *ManifestParser, line: []const u8, key: []const u8) !?[]const u8 {
        _ = self;
        _ = key;
        const idx = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        const value = std.mem.trim(u8, line[idx + 1 ..], " \t\"");
        if (value.len == 0) return null;
        return value;
    }

    fn parseJson(self: *ManifestParser, content: []const u8) !Skill {
        var raw = ManifestRaw{};
        errdefer freeJsonRaw(self.allocator, &raw);
        _ = try self.parseJsonValue(content, 0, &raw);
        const skill = try self.buildSkill(raw);
        freeJsonRaw(self.allocator, &raw);
        return skill;
    }

    /// Free the string fields parsed from JSON. Every value produced by
    /// parseJsonValue is a fresh allocation owned by `raw`; the Skill built
    /// from it duplicates the ones it keeps, so the raw copies are released.
    fn freeJsonRaw(alloc: std.mem.Allocator, raw: *ManifestRaw) void {
        if (raw.name) |s| alloc.free(s);
        if (raw.display_name) |s| alloc.free(s);
        if (raw.description) |s| alloc.free(s);
        if (raw.version) |s| alloc.free(s);
        if (raw.author) |s| alloc.free(s);
        if (raw.config_schema) |s| alloc.free(s);
    }

    fn parseJsonValue(self: *ManifestParser, content: []const u8, start: usize, raw: *ManifestRaw) !usize {
        var i = start;
        while (i < content.len) {
            while (i < content.len and std.mem.indexOfScalar(u8, content[i..], ':') == null and content[i] != '}' and content[i] != ']') : (i += 1) {}

            if (i >= content.len) break;

            if (content[i] == '}') return i + 1;
            if (content[i] == ']') return i + 1;

            while (i < content.len and content[i] != '"') : (i += 1) {}
            i += 1;

            const key_end = i;
            while (i < content.len and content[i] != '"') : (i += 1) {}
            const key = content[key_end..i];
            i += 1;

            while (i < content.len and content[i] != ':') : (i += 1) {}
            i += 1;
            while (i < content.len and content[i] == ' ') : (i += 1) {}

            if (std.mem.eql(u8, key, "name")) {
                const val = try self.parseJsonString(content, &i);
                raw.name = val;
            } else if (std.mem.eql(u8, key, "display_name")) {
                const val = try self.parseJsonString(content, &i);
                raw.display_name = val;
            } else if (std.mem.eql(u8, key, "description")) {
                const val = try self.parseJsonString(content, &i);
                raw.description = val;
            } else if (std.mem.eql(u8, key, "version")) {
                const val = try self.parseJsonString(content, &i);
                raw.version = val;
            } else if (std.mem.eql(u8, key, "author")) {
                const val = try self.parseJsonString(content, &i);
                raw.author = val;
            } else if (std.mem.eql(u8, key, "config_schema")) {
                const val = try self.parseJsonString(content, &i);
                raw.config_schema = val;
            } else if (std.mem.eql(u8, key, "tools")) {
                i += 1;
                var tools_list: std.ArrayList([]const u8) = .empty;
                while (i < content.len and content[i] != ']') {
                    while (i < content.len and content[i] != '"') : (i += 1) {}
                    i += 1;
                    const tool_end = i;
                    while (i < content.len and content[i] != '"') : (i += 1) {}
                    try tools_list.append(self.allocator, self.allocator.dupe(u8, content[tool_end..i]) catch break);
                    i += 1;
                    while (i < content.len and (content[i] == ' ' or content[i] == ',' or content[i] == '\n')) : (i += 1) {}
                }
                i += 1;
                raw.tools = try tools_list.toOwnedSlice(self.allocator);
            } else {
                while (i < content.len and content[i] != ',' and content[i] != '}') : (i += 1) {}
            }

            while (i < content.len and (content[i] == ' ' or content[i] == '\n' or content[i] == ',')) : (i += 1) {}
        }
        return i;
    }

    fn parseJsonString(self: *ManifestParser, content: []const u8, i: *usize) ![]const u8 {
        while (i.* < content.len and content[i.*] == ' ') : (i.* += 1) {}

        if (content[i.*] != '"') {
            return error.InvalidManifest;
        }
        i.* += 1;

        const start = i.*;
        while (i.* < content.len and content[i.*] != '"') : (i.* += 1) {}

        const val = try self.allocator.dupe(u8, content[start..i.*]);
        i.* += 1;
        return val;
    }

    fn buildSkill(self: *ManifestParser, raw: ManifestRaw) !Skill {
        const name = raw.name orelse return SkillError.InvalidManifest;
        const display_name = raw.display_name orelse name;
        const description = raw.description orelse "";
        const version = raw.version orelse "1.0.0";
        const author = raw.author orelse "unknown";

        var source: Source = .{ .local = .{ .path = "" } };

        if (raw.source) |s| {
            if (s.github) |g| {
                source = .{
                    .github = .{
                        .owner = g.owner orelse "unknown",
                        .repo = g.repo orelse "unknown",
                        .path = g.path orelse "",
                    },
                };
            } else if (s.local) |l| {
                source = .{ .local = .{ .path = l.path orelse "" } };
            }
        }

        var commands: []Command = &.{};
        if (raw.commands) |cmds| {
            var cmd_list: std.ArrayList(Command) = .empty;
            for (cmds) |cmd_raw| {
                try cmd_list.append(self.allocator, .{
                    .name = cmd_raw.name orelse "unknown",
                    .description = cmd_raw.description orelse "",
                    .usage = cmd_raw.usage orelse "",
                    .handler = cmd_raw.handler orelse "",
                });
            }
            commands = try cmd_list.toOwnedSlice(self.allocator);
        }

        var tools: []const []const u8 = &.{};
        if (raw.tools) |t| {
            tools = t;
        }

        var prompts: []PromptTemplate = &.{};
        if (raw.prompts) |p| {
            var prompt_list: std.ArrayList(PromptTemplate) = .empty;
            for (p) |pr| {
                try prompt_list.append(self.allocator, .{
                    .name = pr.name orelse "unknown",
                    .template = pr.template orelse "",
                });
            }
            prompts = try prompt_list.toOwnedSlice(self.allocator);
        }

        return Skill{
            .name = try self.allocator.dupe(u8, name),
            .display_name = try self.allocator.dupe(u8, display_name),
            .description = try self.allocator.dupe(u8, description),
            .version = try self.allocator.dupe(u8, version),
            .author = try self.allocator.dupe(u8, author),
            .source = source,
            .commands = commands,
            .tools = tools,
            .config_schema = if (raw.config_schema) |cs| try self.allocator.dupe(u8, cs) else null,
            .prompts = prompts,
        };
    }
};

test "manifest parser yaml basic" {
    const alloc = std.testing.allocator;
    var parser = ManifestParser.init(alloc);

    const yaml =
        \\name: test-skill
        \\display_name: Test Skill
        \\description: A test skill
        \\version: 1.0.0
        \\author: tester
    ;

    var skill = try parser.parse(yaml, "test.yaml");
    defer skill.deinit(alloc);

    try std.testing.expectEqualSlices(u8, "test-skill", skill.name);
    try std.testing.expectEqualSlices(u8, "Test Skill", skill.display_name);
    try std.testing.expectEqualSlices(u8, "A test skill", skill.description);
    try std.testing.expectEqualSlices(u8, "1.0.0", skill.version);
}

test "manifest parser json basic" {
    const alloc = std.testing.allocator;
    var parser = ManifestParser.init(alloc);

    const json = "{\"name\":\"json-skill\",\"display_name\":\"JSON Skill\",\"version\":\"2.0.0\"}";

    var skill = try parser.parse(json, "skill.json");
    defer skill.deinit(alloc);

    try std.testing.expectEqualSlices(u8, "json-skill", skill.name);
    try std.testing.expectEqualSlices(u8, "JSON Skill", skill.display_name);
    try std.testing.expectEqualSlices(u8, "2.0.0", skill.version);
}
