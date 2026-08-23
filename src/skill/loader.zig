//! SKILL.md discovery (dev.md §XIII): scan candidate roots one level deep
//! for `<root>/<name>/SKILL.md` packages plus a bare `<root>/SKILL.md`.
//!
//! Integration contract:
//!   - main.zig calls loadAll with [workspace_skills_dir, home_skills_dir];
//!     registry receives every parseable skill, first root wins on name
//!     clashes. Unparseable candidates are skipped (never fatal).
//!
//! Self-contained; standalone test via `zig test -lc src/skill/loader.zig`.

const std = @import("std");
const skill_mod = @import("skill.zig");

pub const SkillRegistry = skill_mod.SkillRegistry;

pub const Discovered = struct {
    /// Absolute-ish path to the SKILL.md document.
    path: []u8,
    /// Skill name implied by layout (<name>/SKILL.md or the root's basename).
    name: []u8,

    pub fn deinit(self: *Discovered, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.name);
    }
};

fn basenameOf(path_in: []const u8) []const u8 {
    var p = std.mem.trimEnd(u8, path_in, "/");
    if (p.len == 0) return "/";
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| p = p[slash + 1 ..];
    return p;
}

/// Discover candidates across roots. Caller frees via freeDiscovered.
pub fn discover(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir_paths: []const []const u8,
) ![]Discovered {
    var out: std.ArrayList(Discovered) = .empty;
    errdefer {
        for (out.items) |*d| d.deinit(alloc);
        out.deinit(alloc);
    }

    const cwd = std.Io.Dir.cwd();
    for (dir_paths) |root| {
        const dir = std.Io.Dir.openDir(cwd, io, root, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        defer std.Io.Dir.close(dir, io);

        // Collect entry metadata first; file reads happen through fresh
        // handles afterwards so this iterating handle stays read-only.
        const EntryInfo = struct { name: []u8, is_file: bool };
        var entries: std.ArrayList(EntryInfo) = .empty;
        defer {
            for (entries.items) |e| alloc.free(e.name);
            entries.deinit(alloc);
        }
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (std.mem.eql(u8, entry.name, "SKILL.md")) {
                try entries.append(alloc, .{ .name = try alloc.dupe(u8, entry.name), .is_file = true });
                continue;
            }
            // Probe subpackage marker directly (cheap, avoids kind ambiguity).
            var pb: [std.fs.max_path_bytes]u8 = undefined;
            const marker = std.fmt.bufPrint(&pb, "{s}/SKILL.md", .{entry.name}) catch continue;
            if (std.Io.Dir.access(dir, io, marker, .{})) |_| {
                try entries.append(alloc, .{ .name = try alloc.dupe(u8, entry.name), .is_file = false });
            } else |_| {}
        }

        for (entries.items) |e| {
            if (e.is_file) {
                try out.append(alloc, .{
                    .path = try std.fmt.allocPrint(alloc, "{s}/SKILL.md", .{root}),
                    .name = try alloc.dupe(u8, basenameOf(root)),
                });
                continue;
            }
            // Subpackage: dedup against already-collected names (first wins).
            var dup = false;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing.name, e.name)) dup = true;
            }
            if (dup) continue;
            try out.append(alloc, .{
                .path = try std.fmt.allocPrint(alloc, "{s}/{s}/SKILL.md", .{ root, e.name }),
                .name = try alloc.dupe(u8, e.name),
            });
        }
    }

    std.mem.sort(Discovered, out.items, {}, struct {
        fn lt(_: void, a: Discovered, b: Discovered) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

pub fn freeDiscovered(alloc: std.mem.Allocator, list: []Discovered) void {
    for (list) |*d| d.deinit(alloc);
    alloc.free(list);
}

/// Discover, read and register. Returns how many skills were registered.
/// Unreadable/unparseable candidates are skipped without failing the batch.
pub fn loadAll(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir_paths: []const []const u8,
    registry: *SkillRegistry,
) !usize {
    const found = try discover(alloc, io, dir_paths);
    defer freeDiscovered(alloc, found);

    const cwd = std.Io.Dir.cwd();
    var registered: usize = 0;
    for (found) |d| {
        const raw = std.Io.Dir.readFileAlloc(cwd, io, d.path, alloc, .limited(1024 * 1024)) catch continue;
        defer alloc.free(raw);
        const skill = skill_mod.parseSkillMd(alloc, raw, d.path) catch continue;
        const before = registry.count();
        try registry.add(skill);
        if (registry.count() > before) registered += 1;
    }
    return registered;
}

// ── tests ───────────────────────────────────────────────────────────────────

extern "c" fn time(tloc: ?*c_long) c_long;

var env_counter: u32 = 0;

const TestEnv = struct {
    t: std.Io.Threaded,
    root_a: []u8,
    root_b: []u8,

    fn setup(alloc: std.mem.Allocator) !TestEnv {
        env_counter += 1;
        var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
        errdefer t.deinit();
        const stamp: u64 = @intCast(time(null));
        const root_a = try std.fmt.allocPrint(alloc, "/tmp/zh_sk_{d}_{d}/a", .{ stamp, env_counter });
        errdefer alloc.free(root_a);
        const root_b = try std.fmt.allocPrint(alloc, "/tmp/zh_sk_{d}_{d}/b", .{ stamp, env_counter });
        errdefer alloc.free(root_b);

        const io_h = t.io();
        const good =
            "---\nname: {s}\ndescription: desc-{s}\n---\nbody of {s}\n";
        const pa = std.heap.page_allocator;
        try writeFileHelp(io_h, root_a, "coding/SKILL.md", try std.fmt.allocPrint(pa, good, .{ "coding", "coding", "coding" }));
        try writeFileHelp(io_h, root_a, "SKILL.md", try std.fmt.allocPrint(pa, good, .{ "a", "a-desc", "a" }));
        try writeFileHelp(io_h, root_b, "coding/SKILL.md", try std.fmt.allocPrint(pa, good, .{ "coding", "SHADOWED", "coding" }));
        try writeFileHelp(io_h, root_b, "debugging/SKILL.md", try std.fmt.allocPrint(pa, good, .{ "debugging", "dbg", "debugging" }));
        try writeFileHelp(io_h, root_b, "broken/SKILL.md", try std.fmt.allocPrint(pa, "not a skill", .{}));
        return .{ .t = t, .root_a = root_a, .root_b = root_b };
    }

    fn writeFileHelp(ioh: std.Io, root: []const u8, rel: []const u8, data: []const u8) !void {
        defer std.heap.page_allocator.free(data);
        const cwd = std.Io.Dir.cwd();
        const full = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ root, rel });
        defer std.heap.page_allocator.free(full);
        if (std.fs.path.dirname(full)) |parent| {
            try cwd.createDirPath(ioh, parent);
        }
        try std.Io.Dir.writeFile(cwd, ioh, .{ .sub_path = full, .data = data });
    }

    fn io(self: *TestEnv) std.Io {
        return self.t.io();
    }

    fn teardown(self: *TestEnv, alloc: std.mem.Allocator) void {
        defer self.t.deinit();
        const io_h = self.t.io();
        const tmp_root = blk: {
            const slash = std.mem.lastIndexOfScalar(u8, self.root_a, '/') orelse break :blk null;
            break :blk self.root_a[0..slash];
        };
        if (tmp_root) |tr| {
            const cwd = std.Io.Dir.cwd();
            const d = std.Io.Dir.openDir(cwd, io_h, tr, .{}) catch return;
            defer std.Io.Dir.close(d, io_h);
            // Remove both sibling roots by their basenames.
            const base_a = basenameOf(self.root_a);
            const base_b = basenameOf(self.root_b);
            std.Io.Dir.deleteTree(d, io_h, base_a) catch {};
            std.Io.Dir.deleteTree(d, io_h, base_b) catch {};
        }
        alloc.free(self.root_a);
        alloc.free(self.root_b);
    }
};

test "discover dedups sorts and loadAll registers parseable only" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);

    const roots = [_][]const u8{ env.root_b, env.root_a }; // b first: shadows coding
    const found = try discover(alloc, env.io(), &roots);
    defer freeDiscovered(alloc, found);

    // Sorted by name; coding resolved from FIRST root (b), toplevel 'a' from
    // root_a's bare SKILL.md, debugging from b. 'broken' is discovered too —
    // filtering happens at parse time.
    try std.testing.expectEqual(@as(usize, 4), found.len);
    // Lexicographic order.
    try std.testing.expectEqualStrings("a", found[0].name);
    try std.testing.expectEqualStrings("broken", found[1].name);
    try std.testing.expectEqualStrings("coding", found[2].name);
    try std.testing.expectEqualStrings("debugging", found[3].name);
    try std.testing.expect(std.mem.indexOf(u8, found[2].path, "/b/coding/") != null); // shadowed

    var reg = SkillRegistry.init(alloc);
    defer reg.deinit();
    const n = try loadAll(alloc, env.io(), &roots, &reg);
    try std.testing.expectEqual(@as(usize, 3), n); // broken skipped
    // First ROOT wins the name clash: b was passed first, so its coding
    // (desc-SHADOWED) is registered and root_a's variant is dropped.
    try std.testing.expectEqualStrings("desc-SHADOWED", reg.get("coding").?.description);
    try std.testing.expect(reg.get("broken") == null);
}
