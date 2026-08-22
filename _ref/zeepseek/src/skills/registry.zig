const std = @import("std");
const c = @import("c");
const skill_mod = @import("skill.zig");
const Skill = skill_mod.Skill;
const Command = skill_mod.Command;
const Source = skill_mod.Source;
const SkillError = skill_mod.SkillError;
const installer_mod = @import("installer.zig");
const Installer = installer_mod.Installer;
const git_worker_mod = @import("../utils/git_worker.zig");
const manifest_mod = @import("manifest.zig");
const ManifestParser = manifest_mod.ManifestParser;

pub const SkillRegistry = struct {
    arena: std.heap.ArenaAllocator,
    skills: std.ArrayList(*Skill),

    pub fn init(allocator: std.mem.Allocator) !SkillRegistry {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .skills = std.ArrayList(*Skill).empty,
        };
    }

    pub fn deinit(self: *SkillRegistry) void {
        for (self.skills.items) |skill| {
            self.freeSkill(skill);
        }
        self.skills.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    fn freeSkill(self: *SkillRegistry, skill: *Skill) void {
        const a = self.arena.allocator();
        a.free(skill.name);
        a.free(skill.display_name);
        a.free(skill.description);
        a.free(skill.version);
        a.free(skill.author);
        for (skill.commands) |cmd| {
            a.free(cmd.name);
            a.free(cmd.description);
            a.free(cmd.usage);
            a.free(cmd.handler);
        }
        a.free(skill.commands);
        a.free(skill.tools);
        if (skill.config_schema) |cs| {
            a.free(cs);
        }
        for (skill.prompts) |prompt| {
            a.free(prompt.name);
            a.free(prompt.template);
        }
        a.free(skill.prompts);
    }

    pub fn installFromLocal(self: *SkillRegistry, path: []const u8) ![]const u8 {
        const a = self.arena.allocator();

        const manifest_path = try self.findManifest(path) orelse return SkillError.ManifestParseFailed;
        defer a.free(manifest_path);

        var parser = ManifestParser.init(a);
        const skill = try parser.parseFile(manifest_path);

        try self.registerSkill(&skill);
        return skill.name;
    }

    fn findManifest(self: *SkillRegistry, dir_path: []const u8) !?[]const u8 {
        const manifest_names = [_][]const u8{ "skill.yaml", "skill.yml", "skill.json" };
        for (manifest_names) |name| {
            const manifest_path = try std.fs.path.join(self.arena.allocator(), &.{ dir_path, name });
            const manifest_path_z = std.heap.page_allocator.dupeSentinel(u8, manifest_path, 0) catch {
                self.arena.allocator().free(manifest_path);
                continue;
            };
            defer std.heap.page_allocator.free(manifest_path_z);
            if (std.c.access(manifest_path_z.ptr, std.posix.F_OK) == 0) {
                return manifest_path;
            }
            self.arena.allocator().free(manifest_path);
        }
        return null;
    }

    pub fn installFromGithub(
        self: *SkillRegistry,
        git_worker: ?*git_worker_mod.Client,
        io: std.Io,
        owner: []const u8,
        repo: []const u8,
        skill_path: []const u8,
    ) ![]const u8 {
        const a = self.arena.allocator();
        var installer = try Installer.init(a);
        defer installer.deinit();

        const dest = try installer.getSkillPath(repo);
        defer a.free(dest);

        try installer.cloneFromGithub(git_worker, io, owner, repo, dest);

        _ = skill_path;
        return try self.installFromLocal(dest);
    }

    pub fn registerSkill(self: *SkillRegistry, skill: *const Skill) !void {
        const a = self.arena.allocator();

        const owned = try a.create(Skill);
        errdefer a.destroy(owned);

        owned.* = .{
            .name = try a.dupe(u8, skill.name),
            .display_name = try a.dupe(u8, skill.display_name),
            .description = try a.dupe(u8, skill.description),
            .version = try a.dupe(u8, skill.version),
            .author = try a.dupe(u8, skill.author),
            .source = skill.source,
            .commands = undefined,
            .tools = undefined,
            .config_schema = null,
            .prompts = undefined,
        };

        var cmds = try a.alloc(Command, skill.commands.len);
        errdefer a.free(cmds);
        for (skill.commands, 0..) |cmd, i| {
            cmds[i] = .{
                .name = try a.dupe(u8, cmd.name),
                .description = try a.dupe(u8, cmd.description),
                .usage = try a.dupe(u8, cmd.usage),
                .handler = try a.dupe(u8, cmd.handler),
            };
        }
        owned.commands = cmds;

        var tools_list = try a.alloc([]const u8, skill.tools.len);
        errdefer a.free(tools_list);
        for (skill.tools, 0..) |tool, i| {
            tools_list[i] = try a.dupe(u8, tool);
        }
        owned.tools = tools_list;

        if (skill.config_schema) |cs| {
            owned.config_schema = try a.dupe(u8, cs);
        }

        var prompts = try a.alloc(skill_mod.PromptTemplate, skill.prompts.len);
        errdefer a.free(prompts);
        for (skill.prompts, 0..) |prompt, i| {
            prompts[i] = .{
                .name = try a.dupe(u8, prompt.name),
                .template = try a.dupe(u8, prompt.template),
            };
        }
        owned.prompts = prompts;

        try self.skills.append(self.arena.allocator(), owned);
    }

    pub fn uninstall(self: *SkillRegistry, name: []const u8) !void {
        var idx: usize = 0;
        while (idx < self.skills.items.len) : (idx += 1) {
            if (std.mem.eql(u8, self.skills.items[idx].name, name)) {
                self.freeSkill(self.skills.items[idx]);
                _ = self.skills.orderedRemove(self.arena.allocator(), idx);
                return;
            }
        }
        return SkillError.SkillNotFound;
    }

    pub fn list(self: *SkillRegistry) []const *Skill {
        return self.skills.items;
    }

    pub fn findByCommand(self: *const SkillRegistry, cmd: []const u8) ?*Skill {
        for (self.skills.items) |skill| {
            for (skill.commands) |cmd2| {
                if (std.mem.eql(u8, cmd2.name, cmd)) return skill;
            }
        }
        return null;
    }

    pub fn findByName(self: *const SkillRegistry, name: []const u8) ?*Skill {
        for (self.skills.items) |skill| {
            if (std.mem.eql(u8, skill.name, name)) return skill;
        }
        return null;
    }

    pub fn reload(self: *SkillRegistry, name: []const u8) !void {
        const skill = self.skills.get(name) orelse return SkillError.SkillNotFound;

        const path = switch (skill.source) {
            .local => |s| s.path,
            .github => |s| std.fmt.comptimePrint("{s}/{s}/{s}", .{ s.owner, s.repo, s.path }),
        };

        _ = try self.uninstall(name);
        _ = try self.installFromLocal(path);
    }

    pub fn loadInstalledSkills(self: *SkillRegistry) !void {
        const a = self.arena.allocator();

        var installer = try Installer.init(a);
        defer installer.deinit();

        const skills_dir = installer.getSkillsDir() catch |err| {
            if (err == SkillError.SkillsDirNotFound) return;
            return err;
        };
        defer a.free(skills_dir);

        {
            var it = std.mem.splitScalar(u8, skills_dir, '/');
            var path_buf: [4096]u8 = undefined;
            var path_len: usize = 0;
            while (it.next()) |part| {
                if (part.len == 0) continue;
                if (path_len > 0 and path_buf[path_len - 1] != '/') {
                    path_buf[path_len] = '/';
                    path_len += 1;
                }
                @memcpy(path_buf[path_len..path_len + part.len], part);
                path_len += part.len;
                const sub_path = path_buf[0..path_len];
                const sub_path_z = std.heap.page_allocator.dupeSentinel(u8, sub_path, 0) catch return error.OutOfMemory;
                defer std.heap.page_allocator.free(sub_path_z);
                _ = c.mkdir(sub_path_z.ptr, 0o755);
            }
        }

        const skills_dir_z = std.heap.page_allocator.dupeSentinel(u8, skills_dir, 0) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(skills_dir_z);
        const dir = c.opendir(skills_dir_z.ptr);
        if (dir == null) {
            return;
        }
        defer _ = c.closedir(dir);

        while (true) {
            const entry = c.readdir(dir);
            if (entry == null) break;
            const name_slice = std.mem.sliceTo(entry.?.d_name[0..], 0);
            if (std.mem.eql(u8, name_slice, ".") or std.mem.eql(u8, name_slice, "..")) continue;

            var stat_buf: std.c.Stat = undefined;
            const entry_path = try std.fs.path.join(a, &.{ skills_dir, name_slice });
            const entry_path_z = std.heap.page_allocator.dupeSentinel(u8, entry_path, 0) catch {
                a.free(entry_path);
                continue;
            };
            defer std.heap.page_allocator.free(entry_path_z);
            if (std.c.stat(entry_path_z.ptr, &stat_buf) != 0) {
                a.free(entry_path);
                continue;
            }
            if (!std.posix.S.ISDIR(stat_buf.mode)) {
                a.free(entry_path);
                continue;
            }

            if (self.installFromLocal(entry_path)) {
                std.debug.print("[SKILL] Loaded: {s}\n", .{name_slice});
            } else |err| {
                std.debug.print("[SKILL] Failed to load {s}: {}\n", .{ name_slice, err });
            }
        }
    }

    pub fn getCommandCompletions(self: *SkillRegistry, prefix: []const u8) []const struct { name: []const u8, description: []const u8, skill_name: []const u8 } {
        var completions: std.ArrayList(struct { name: []const u8, description: []const u8, skill_name: []const u8 }) = .empty;
        for (self.skills.values()) |skill| {
            for (skill.commands) |cmd| {
                if (prefix.len == 0 or std.mem.startsWith(u8, cmd.name, prefix)) {
                    completions.append(self.arena.allocator(), .{
                        .name = try self.arena.allocator().dupe(u8, cmd.name),
                        .description = try self.arena.allocator().dupe(u8, cmd.description),
                        .skill_name = try self.arena.allocator().dupe(u8, skill.name),
                    }) catch break;
                }
            }
        }
        return completions.toOwnedSlice() catch &.{};
    }
};

test "skill registry init" {
    const alloc = std.testing.allocator;
    var registry = try SkillRegistry.init(alloc);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.list().len);
}

test "skill registry find by command empty" {
    const alloc = std.testing.allocator;
    var registry = try SkillRegistry.init(alloc);
    defer registry.deinit();

    try std.testing.expect(registry.findByCommand("qa") == null);
}

test "skill registry find by name empty" {
    const alloc = std.testing.allocator;
    var registry = try SkillRegistry.init(alloc);
    defer registry.deinit();

    try std.testing.expect(registry.findByName("nonexistent") == null);
}

test "skill registry register builtin skills" {
    const alloc = std.testing.allocator;
    var registry = try SkillRegistry.init(alloc);
    defer registry.deinit();

    var builtin_skills = @import("builtin.zig").BuiltinSkills{};
    const skills = try builtin_skills.loadAll(alloc);
    defer {
        for (skills) |*skill| {
            skill.deinit(alloc);
        }
        alloc.free(skills);
    }
    for (skills) |*skill| {
        try registry.registerSkill(skill);
    }

    try std.testing.expect(registry.findByName("design-review") != null);
    try std.testing.expect(registry.findByName("investigate") != null);
    try std.testing.expect(registry.findByName("health") != null);
}
