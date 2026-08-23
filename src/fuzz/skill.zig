//! Fuzz suite: skill/skill.zig front-matter parsing + registry (SWARM
//! wave-4, agent J-fuzz). skill/loader.zig delegates ALL front-matter
//! parsing to skill.parseSkillMd, so this covers the loader's parse surface
//! too (its discovery walk is plain directory I/O already covered by the
//! loader's own tests).
//!
//! Property: for ANY document bytes, parseSkillMd yields an owned Skill
//! (deinit frees all five fields) or a clean ParseError. Registry add/get/
//! render/getBody stay total over arbitrary parsed skills.
//!
//! Corpus: src/fuzz/corpus/skill_seeds.txt, embedded at compile time.

const std = @import("std");
const mutator = @import("mutator.zig");
const skill_mod = @import("../skill/skill.zig");

const corpus_raw = @embedFile("corpus/skill_seeds.txt");

const seed_skill = 0x5111;

test "fuzz: parseSkillMd over mutated seeds" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_skill);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| {
        try exerciseDoc(alloc, seed);
        var round: usize = 0;
        while (round < 12) : (round += 1) {
            try mutator.mutate(alloc, &out, &rnd, seed);
            try exerciseDoc(alloc, out.items);
        }
    }
}

fn exerciseDoc(alloc: std.mem.Allocator, doc: []const u8) !void {
    if (skill_mod.parseSkillMd(alloc, doc, "/fuzz/SKILL.md")) |sk| {
        const s = sk;
        // Parsed fields are owned copies within the document's size.
        try std.testing.expect(s.name.len <= doc.len);
        try std.testing.expect(s.description.len <= doc.len);
        try std.testing.expect(s.body.len <= doc.len);
        try exerciseRegistry(alloc, s);
    } else |_| {}
}

// Registry gauntlet: dedup, lookup, body fetch, prompt render — all with
/// full cleanup, so any registry-side leak surfaces here.
fn exerciseRegistry(alloc: std.mem.Allocator, first: skill_mod.Skill) !void {
    var reg = skill_mod.SkillRegistry.init(alloc);
    defer reg.deinit();

    try reg.add(first);

    // Same-name duplicate is dropped AND freed by the registry contract.
    const dup_doc = "---\nname: x\ndescription: d\n---\nbody";
    const dup = try skill_mod.parseSkillMd(alloc, dup_doc, "/dup/SKILL.md");
    try reg.add(dup);

    // A differently-named second entry exercises multi-item paths.
    const other_doc = try std.fmt.allocPrint(
        alloc,
        "---\nname: other-{s}\ndescription: o\n---\nob",
        .{first.name},
    );
    defer alloc.free(other_doc);
    if (skill_mod.parseSkillMd(alloc, other_doc, "/other/SKILL.md")) |o| {
        try reg.add(o);
    } else |_| {}

    _ = reg.count();
    try std.testing.expect(reg.get(first.name) != null); // get is total
    try std.testing.expect(reg.get("\xff\xfe weird name") == null);

    if (try reg.getBody(alloc, first.name)) |b| alloc.free(b);
    const section = try reg.renderPromptSection(alloc);
    alloc.free(section);
}

test "regression: front-matter edges stay clean" {
    const alloc = std.testing.allocator;

    // CRLF front matter.
    {
        var s = try skill_mod.parseSkillMd(
            alloc,
            "---\r\nname: win\r\ndescription: crlf ok\r\n---\r\nbody line\r\n",
            "p",
        );
        defer s.deinit(alloc);
        try std.testing.expectEqualStrings("win", s.name);
        try std.testing.expectEqualStrings("crlf ok", s.description);
        try std.testing.expectEqualStrings("body line\r\n", s.body);
    }

    // Empty values and colon-bearing values.
    {
        var s = try skill_mod.parseSkillMd(
            alloc,
            "---\nname:\ndescription: key: value: more\n---\nb\n",
            "p",
        );
        defer s.deinit(alloc);
        try std.testing.expectEqualStrings("", s.name); // present but empty
        try std.testing.expectEqualStrings("key: value: more", s.description);
    }

    // Missing close delimiter / no newline after opener / wrong opener.
    try std.testing.expectError(
        error.BadFrontMatter,
        skill_mod.parseSkillMd(alloc, "---\nname: x\ndescription: y", "p"),
    );
    try std.testing.expectError(
        error.BadFrontMatter,
        skill_mod.parseSkillMd(alloc, "---", "p"),
    );
    try std.testing.expectError(
        error.MissingFrontMatter,
        skill_mod.parseSkillMd(alloc, "--\nname: x\ndescription: y\n---\nb", "p"),
    );
    try std.testing.expectError(
        error.MissingFrontMatter,
        skill_mod.parseSkillMd(alloc, "\n---\nname: late\ndescription: d\n---\nb", "p"), // must start at byte 0
    );
}
