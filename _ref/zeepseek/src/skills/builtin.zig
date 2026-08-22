const std = @import("std");
const skill_mod = @import("skill.zig");
const Skill = skill_mod.Skill;
const Command = skill_mod.Command;
const PromptTemplate = skill_mod.PromptTemplate;
const Source = skill_mod.Source;

fn dupTools(alloc: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    var tools = try alloc.alloc([]const u8, names.len);
    errdefer alloc.free(tools);
    for (names, 0..) |name, i| {
        tools[i] = try alloc.dupe(u8, name);
    }
    return tools;
}

pub const BuiltinSkills = struct {
    pub fn getDesignReview(self: *const BuiltinSkills, alloc: std.mem.Allocator) !Skill {
        _ = self;
        var commands = try alloc.alloc(Command, 3);
        commands[0] = Command{
            .name = try alloc.dupe(u8, "design-review"),
            .description = try alloc.dupe(u8, "Designer's eye QA for visual inconsistency and spacing"),
            .usage = try alloc.dupe(u8, "/design-review [url]"),
            .handler = try alloc.dupe(u8, "prompt:design_review"),
        };
        commands[1] = Command{
            .name = try alloc.dupe(u8, "design-shotgun"),
            .description = try alloc.dupe(u8, "Generate multiple AI design variants"),
            .usage = try alloc.dupe(u8, "/design-shotgun [description]"),
            .handler = try alloc.dupe(u8, "prompt:design_shotgun"),
        };
        commands[2] = Command{
            .name = try alloc.dupe(u8, "plan-design-review"),
            .description = try alloc.dupe(u8, "Designer's eye plan review before implementation"),
            .usage = try alloc.dupe(u8, "/plan-design-review"),
            .handler = try alloc.dupe(u8, "prompt:plan_design_review"),
        };

        var prompts = try alloc.alloc(PromptTemplate, 3);
        prompts[0] = PromptTemplate{
            .name = try alloc.dupe(u8, "design_review"),
            .template = try alloc.dupe(u8, "You are a design critic. Review the UI/UX for visual inconsistency, spacing issues, hierarchy problems, and slow interactions."),
        };
        prompts[1] = PromptTemplate{
            .name = try alloc.dupe(u8, "design_shotgun"),
            .template = try alloc.dupe(u8, "Generate 3-5 distinct design variants for the described feature."),
        };
        prompts[2] = PromptTemplate{
            .name = try alloc.dupe(u8, "plan_design_review"),
            .template = try alloc.dupe(u8, "Rate each design dimension 0-10, explain what would make it a 10."),
        };

        return Skill{
            .name = try alloc.dupe(u8, "design-review"),
            .display_name = try alloc.dupe(u8, "Design Review"),
            .description = try alloc.dupe(u8, "Designer's eye QA - finds visual inconsistency, spacing issues, hierarchy problems"),
            .version = try alloc.dupe(u8, "1.0.0"),
            .author = try alloc.dupe(u8, "zeepseek"),
            .source = .{ .local = .{ .path = "builtin/design-review" } },
            .commands = commands,
            .tools = try dupTools(alloc, &.{"gstack-design"}),
            .config_schema = null,
            .prompts = prompts,
        };
    }

    pub fn getInvestigate(self: *const BuiltinSkills, alloc: std.mem.Allocator) !Skill {
        _ = self;
        var commands = try alloc.alloc(Command, 2);
        commands[0] = Command{
            .name = try alloc.dupe(u8, "investigate"),
            .description = try alloc.dupe(u8, "Systematic debugging with root cause investigation"),
            .usage = try alloc.dupe(u8, "/investigate [issue description]"),
            .handler = try alloc.dupe(u8, "prompt:investigate"),
        };
        commands[1] = Command{
            .name = try alloc.dupe(u8, "debug"),
            .description = try alloc.dupe(u8, "Debug and fix an error or bug"),
            .usage = try alloc.dupe(u8, "/debug [error description]"),
            .handler = try alloc.dupe(u8, "prompt:debug_flow"),
        };

        var prompts = try alloc.alloc(PromptTemplate, 2);
        prompts[0] = PromptTemplate{
            .name = try alloc.dupe(u8, "investigate"),
            .template = try alloc.dupe(u8, "You are a debugging expert. Follow: 1. INVESTIGATE 2. ANALYZE 3. HYPOTHESIZE 4. IMPLEMENT. Iron Law: No fixes without root cause."),
        };
        prompts[1] = PromptTemplate{
            .name = try alloc.dupe(u8, "debug_flow"),
            .template = try alloc.dupe(u8, "Debug workflow: gather error messages, trace execution, find root cause."),
        };

        return Skill{
            .name = try alloc.dupe(u8, "investigate"),
            .display_name = try alloc.dupe(u8, "Investigate"),
            .description = try alloc.dupe(u8, "Systematic debugging with root cause investigation"),
            .version = try alloc.dupe(u8, "1.0.0"),
            .author = try alloc.dupe(u8, "zeepseek"),
            .source = .{ .local = .{ .path = "builtin/investigate" } },
            .commands = commands,
            .tools = try dupTools(alloc, &.{
                "shell",
                "file_read",
                "grep",
            }),
            .config_schema = null,
            .prompts = prompts,
        };
    }

    pub fn getHealth(self: *const BuiltinSkills, alloc: std.mem.Allocator) !Skill {
        _ = self;
        var commands = try alloc.alloc(Command, 3);
        commands[0] = Command{
            .name = try alloc.dupe(u8, "health"),
            .description = try alloc.dupe(u8, "Run code quality checks and compute health score"),
            .usage = try alloc.dupe(u8, "/health"),
            .handler = try alloc.dupe(u8, "prompt:health_check"),
        };
        commands[1] = Command{
            .name = try alloc.dupe(u8, "lint"),
            .description = try alloc.dupe(u8, "Run linter on the codebase"),
            .usage = try alloc.dupe(u8, "/lint [path]"),
            .handler = try alloc.dupe(u8, "prompt:lint_check"),
        };
        commands[2] = Command{
            .name = try alloc.dupe(u8, "test-all"),
            .description = try alloc.dupe(u8, "Run all tests"),
            .usage = try alloc.dupe(u8, "/test-all"),
            .handler = try alloc.dupe(u8, "prompt:test_run"),
        };

        var prompts = try alloc.alloc(PromptTemplate, 3);
        prompts[0] = PromptTemplate{
            .name = try alloc.dupe(u8, "health_check"),
            .template = try alloc.dupe(u8, "Run type checker, linter, test runner. Compute weighted composite 0-10 score."),
        };
        prompts[1] = PromptTemplate{
            .name = try alloc.dupe(u8, "lint_check"),
            .template = try alloc.dupe(u8, "Run the linter and report warnings/errors."),
        };
        prompts[2] = PromptTemplate{
            .name = try alloc.dupe(u8, "test_run"),
            .template = try alloc.dupe(u8, "Execute all tests and report pass/fail."),
        };

        return Skill{
            .name = try alloc.dupe(u8, "health"),
            .display_name = try alloc.dupe(u8, "Health Check"),
            .description = try alloc.dupe(u8, "Code quality dashboard with weighted composite 0-10 score"),
            .version = try alloc.dupe(u8, "1.0.0"),
            .author = try alloc.dupe(u8, "zeepseek"),
            .source = .{ .local = .{ .path = "builtin/health" } },
            .commands = commands,
            .tools = try dupTools(alloc, &.{
                "shell",
                "git_status",
                "git_diff",
            }),
            .config_schema = null,
            .prompts = prompts,
        };
    }

    pub fn loadAll(self: *const BuiltinSkills, alloc: std.mem.Allocator) ![]Skill {
        var skills = try alloc.alloc(skill_mod.Skill, 3);
        skills[0] = try self.getDesignReview(alloc);
        skills[1] = try self.getInvestigate(alloc);
        skills[2] = try self.getHealth(alloc);
        return skills;
    }
};
