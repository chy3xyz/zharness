//! Skill system (dev.md §XIII): discoverable SKILL.md packages whose
//! instructions are injected into agent context on demand.
//!
//! Format (front-matter convention):
//!   ---
//!   name: coding
//!   description: Code review & refactoring guidance
//!   category: engineering        # optional
//!   ---
//!   <markdown body>
//!
//! Integration contract:
//!   - loader.zig discovers candidates under workspace `skills/` and
//!     ~/.zharness/skills; this module parses them and owns the registry.
//!   - renderPromptSection output joins the system prompt area.
//!   - The optional `skill_use` tool (schema below) lets the model pull a
//!     chosen skill's full body into context.
//!
//! Self-contained; standalone test via `zig test -lc src/skill/loader.zig`.

const std = @import("std");

pub const ParseError = error{
    MissingFrontMatter,
    MissingName,
    MissingDescription,
    BadFrontMatter,
} || std.mem.Allocator.Error;

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    category: ?[]const u8 = null,
    body: []const u8,
    source_path: []const u8,

    pub fn deinit(self: *Skill, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        if (self.category) |c| alloc.free(c);
        alloc.free(self.body);
        alloc.free(self.source_path);
    }
};

fn trimCr(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

/// Parse front-matter + body from a SKILL.md document. All strings are
/// freshly allocated.
pub fn parseSkillMd(alloc: std.mem.Allocator, text: []const u8, source_path: []const u8) ParseError!Skill {
    var rest = text;
    if (!std.mem.startsWith(u8, rest, "---")) return error.MissingFrontMatter;
    rest = rest["---".len..];
    // Skip the remainder of the opening line.
    const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.BadFrontMatter;
    rest = rest[nl + 1 ..];

    const close = std.mem.indexOf(u8, rest, "\n---") orelse return error.BadFrontMatter;
    const fm_block = rest[0..close];
    var body = rest[close + "\n---".len ..];
    if (std.mem.startsWith(u8, body, "\r\n")) body = body[2..] else if (std.mem.startsWith(u8, body, "\n")) body = body[1..];

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var category: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, fm_block, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, trimCr(raw_line), " \t");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "name")) name = value;
        if (std.mem.eql(u8, key, "description")) description = value;
        if (std.mem.eql(u8, key, "category")) category = value;
    }

    const n = name orelse return error.MissingName;
    const d = description orelse return error.MissingDescription;

    return .{
        .name = try alloc.dupe(u8, n),
        .description = try alloc.dupe(u8, d),
        .category = if (category) |c| try alloc.dupe(u8, c) else null,
        .body = try alloc.dupe(u8, body),
        .source_path = try alloc.dupe(u8, source_path),
    };
}

// ── registry ────────────────────────────────────────────────────────────────

pub const skill_use_name = "skill_use";
pub const skill_use_parameters_json =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Skill name to activate"}},"required":["name"]}
;

pub const SkillRegistry = struct {
    alloc: std.mem.Allocator,
    skills: std.ArrayList(Skill) = .empty,

    pub fn init(alloc: std.mem.Allocator) SkillRegistry {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *SkillRegistry) void {
        for (self.skills.items) |*s| s.deinit(self.alloc);
        self.skills.deinit(self.alloc);
    }

    /// Take ownership of `skill`; duplicate names are first-wins and the
    /// incoming copy is freed.
    pub fn add(self: *SkillRegistry, skill: Skill) !void {
        for (self.skills.items) |existing| {
            if (std.mem.eql(u8, existing.name, skill.name)) {
                var dup = skill;
                dup.deinit(self.alloc);
                return;
            }
        }
        try self.skills.append(self.alloc, skill);
    }

    pub fn count(self: *const SkillRegistry) usize {
        return self.skills.items.len;
    }

    pub fn get(self: *const SkillRegistry, name: []const u8) ?*const Skill {
        for (self.skills.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// Full markdown body of a skill (caller frees).
    pub fn getBody(self: *const SkillRegistry, alloc: std.mem.Allocator, name: []const u8) !?[]const u8 {
        const s = self.get(name) orelse return null;
        return try alloc.dupe(u8, s.body);
    }

    /// Context-injection listing; "" when no skills are registered so
    /// callers can omit the section.
    pub fn renderPromptSection(self: *const SkillRegistry, alloc: std.mem.Allocator) ![]const u8 {
        if (self.skills.items.len == 0) return try alloc.dupe(u8, "");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "## Available skills\n");
        for (self.skills.items) |s| {
            try out.appendSlice(alloc, "- ");
            try out.appendSlice(alloc, s.name);
            try out.appendSlice(alloc, ": ");
            try out.appendSlice(alloc, s.description);
            try out.append(alloc, '\n');
        }
        try out.appendSlice(alloc, "Activate one with the ");
        try out.appendSlice(alloc, skill_use_name);
        try out.appendSlice(alloc, " tool to load its full instructions.\n");
        return out.toOwnedSlice(alloc);
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const sample =
    \\---
    \\name: debugging
    \\description: Root-cause hunting playbook
    \\category: engineering
    \\---
    \\## Steps
    \\1. Reproduce
    \\2. Isolate
    \\
;

test "parse valid front matter" {
    const alloc = std.testing.allocator;
    var s = try parseSkillMd(alloc, sample, "/skills/debugging/SKILL.md");
    defer s.deinit(alloc);
    try std.testing.expectEqualStrings("debugging", s.name);
    try std.testing.expectEqualStrings("Root-cause hunting playbook", s.description);
    try std.testing.expectEqualStrings("engineering", s.category.?);
    try std.testing.expect(std.mem.indexOf(u8, s.body, "1. Reproduce") != null);
}

test "parse rejects missing required fields" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MissingFrontMatter, parseSkillMd(alloc, "no front matter", "p"));
    try std.testing.expectError(error.MissingName, parseSkillMd(alloc, "---\ndescription: d\n---\nb", "p"));
    try std.testing.expectError(error.MissingDescription, parseSkillMd(alloc, "---\nname: n\n---\nb", "p"));
}

test "registry dedup prompt section and body fetch" {
    const alloc = std.testing.allocator;
    var r = SkillRegistry.init(alloc);
    defer r.deinit();

    const empty = try r.renderPromptSection(alloc);
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);

    try r.add(try parseSkillMd(alloc, sample, "/a/SKILL.md"));
    // Same-name second registration is dropped (first wins).
    try r.add(try parseSkillMd(alloc, sample, "/b/SKILL.md"));
    try std.testing.expectEqual(@as(usize, 1), r.count());

    const section = try r.renderPromptSection(alloc);
    defer alloc.free(section);
    try std.testing.expect(std.mem.indexOf(u8, section, "- debugging: Root-cause hunting playbook") != null);

    const body = (try r.getBody(alloc, "debugging")).?;
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "2. Isolate") != null);
    try std.testing.expect((try r.getBody(alloc, "nope")) == null);
}
