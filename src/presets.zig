//! Agent presets (dev.md §XXVIII) — pure configuration data.
//!
//! A preset bundles three decisions the CLI and agent loop need up front:
//! which builtin tools the model may call (names matching
//! `src/tool/registry.zig`), a system-prompt fragment describing the mode,
//! and a default turn budget. Presets are the user-facing dials behind the
//! `--preset <name>` flag: `standard` (full coding agent), `minimal`
//! (shell + editor), `ptc` (programmatic tool calling / Tool SDK), and
//! `creative` (full surface plus inspection/debugging framing).
//!
//! Pure data by design: no imports beyond std, no allocation at rest. The
//! tool tables are static string slices; `filterTools` derives a filtered
//! VIEW of caller-owned definitions without copying definition memory —
//! the returned slice holds borrowed pointers into `all_defs`, so freeing
//! the slice must NOT free the pointed-to definitions.
//!
//! Tests live in this file; run everything via `zig test -lc src/_t_obs.zig`.

const std = @import("std");

pub const Error = error{UnknownPreset};

/// The four canonical modes (dev.md §XXVIII). Order matches `table`.
pub const Kind = enum {
    standard,
    minimal,
    ptc,
    creative,
};

pub const Spec = struct {
    kind: Kind,
    /// Canonical name accepted by --preset / fromString (exact match).
    name: []const u8,
    /// Allowed builtin tool names; strings must match registry names.
    tools: []const []const u8,
    /// Fragment appended to the system prompt when active.
    system_prompt_fragment: []const u8,
    /// Turn budget applied when config does not override it.
    default_max_turns: usize,
};

/// The full builtin toolbox (src/tool/registry.zig::registerBuiltins).
const full_toolkit = [_][]const u8{
    "file_read",
    "file_write",
    "file_edit",
    "glob",
    "grep",
    "shell",
    "git_status",
    "git_diff",
    "git_log",
    "git_commit",
};

/// Read-only inspection set for PTC program authoring.
const read_only_toolkit = [_][]const u8{ "file_read", "glob", "grep" };

/// Shell + editing subset for minimal mode ("bash + editor").
const minimal_toolkit = [_][]const u8{ "file_read", "file_write", "file_edit", "shell" };

pub const table = [_]Spec{
    .{
        .kind = .standard,
        .name = "standard",
        .tools = &full_toolkit,
        .system_prompt_fragment =
        \\You operate in standard mode with the complete built-in toolbox:
        \\files, search, shell, and git. Plan before multi-step work, verify
        \\your changes after editing, and report outcomes concisely.
        ,
        .default_max_turns = 64,
    },
    .{
        .kind = .minimal,
        .name = "minimal",
        .tools = &minimal_toolkit,
        .system_prompt_fragment =
        \\You operate in minimal mode: only a shell and basic file editing are
        \\available. Prefer direct commands over exploration and keep output
        \\terse.
        ,
        .default_max_turns = 32,
    },
    .{
        .kind = .ptc,
        .name = "ptc",
        .tools = &read_only_toolkit,
        .system_prompt_fragment =
        \\You operate in programmatic-tool-calling (PTC) mode: compose programs
        \\against the zharness Tool SDK to execute many operations per step
        \\instead of issuing one tool call at a time. Read-only inspection
        \\tools help you author correct programs.
        ,
        .default_max_turns = 48,
    },
    .{
        .kind = .creative,
        .name = "creative",
        .tools = &full_toolkit,
        .system_prompt_fragment =
        \\You operate in creative mode: the full agent surface plus plugin
        \\inspection and runtime debugging. Explore boldly, prototype quickly,
        \\and favor expressive solutions over conservative ones.
        ,
        .default_max_turns = 96,
    },
};

pub const count = table.len;

// ── lookup API ──────────────────────────────────────────────────────────────

/// Resolve a preset name; unknown names yield error.UnknownPreset.
pub fn fromString(name: []const u8) Error!Kind {
    for (&table) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s.kind;
    }
    return error.UnknownPreset;
}

/// Spec for a kind (linear scan — no ordering coupling between enum and
/// table layout).
pub fn spec(kind: Kind) *const Spec {
    for (&table) |*s| {
        if (s.kind == kind) return s;
    }
    unreachable; // every Kind has exactly one row in `table`
}

/// Lookup by name; null when unknown (for callers that want a soft probe).
pub fn lookup(name: []const u8) ?*const Spec {
    for (&table) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// Stateless iterator over all preset specs, table order.
pub const Iterator = struct {
    idx: usize = 0,

    pub fn next(self: *Iterator) ?*const Spec {
        if (self.idx >= table.len) return null;
        defer self.idx += 1;
        return &table[self.idx];
    }
};

pub fn iterator() Iterator {
    return .{};
}

// ── tool filtering ──────────────────────────────────────────────────────────

fn allowsTool(s: *const Spec, name: []const u8) bool {
    for (s.tools) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

/// Resolve the DEFINITION element type whether callers pass a slice
/// (`[]Def`) or a pointer-to-array (`&defs_array`, common in tests).
fn DefinitionOf(comptime defs_any: type) type {
    const info = @typeInfo(defs_any);
    if (info != .pointer) @compileError("filterTools expects a slice or pointer-to-array of definitions");
    const child_info = @typeInfo(info.pointer.child);
    return if (child_info == .array) child_info.array.child else info.pointer.child;
}

/// Filtered VIEW of `all_defs` keeping only tools allowed by `preset`.
///
/// Works with any slice of definitions carrying a `.name` string field
/// (structurally compatible with `tool.registry.ToolDefinition`), so this
/// module stays import-free. Result preserves `all_defs` order; preset tool
/// names absent from `all_defs` are silently skipped. Elements are borrowed
/// pointers into `all_defs` — free the returned slice with `alloc.free`,
/// never free (or deinit) through the elements themselves.
pub fn filterTools(
    preset: Kind,
    all_defs: anytype,
    alloc: std.mem.Allocator,
) std.mem.Allocator.Error![]*const DefinitionOf(@TypeOf(all_defs)) {
    const Def = DefinitionOf(@TypeOf(all_defs));
    const s = spec(preset);
    // Accept slices AND pointers-to-arrays by coercing to a slice view.
    const defs_view: []const Def = all_defs;
    var picked: std.ArrayList(*const Def) = .empty;
    errdefer picked.deinit(alloc);
    for (defs_view) |*def| {
        if (allowsTool(s, def.name)) try picked.append(alloc, def);
    }
    return picked.toOwnedSlice(alloc);
}

// ── tests ───────────────────────────────────────────────────────────────────

test "preset resolution and unknown-name error" {
    try std.testing.expectEqual(Kind.standard, try fromString("standard"));
    try std.testing.expectEqual(Kind.minimal, try fromString("minimal"));
    try std.testing.expectEqual(Kind.ptc, try fromString("ptc"));
    try std.testing.expectEqual(Kind.creative, try fromString("creative"));
    try std.testing.expectError(error.UnknownPreset, fromString("bogus"));
    try std.testing.expectError(error.UnknownPreset, fromString(""));
    try std.testing.expectError(error.UnknownPreset, fromString("Standard")); // exact match only

    // spec() agrees with lookup() and names are canonical.
    var it = iterator();
    while (it.next()) |s| {
        try std.testing.expectEqualStrings(s.name, spec(s.kind).name);
        try std.testing.expectEqual(s.kind, lookup(s.name).?.kind);
    }
    try std.testing.expect(lookup("nope") == null);
}

test "iterator lists every preset exactly once" {
    var seen: [count]bool = @splat(false);
    var listed: usize = 0;
    var it = iterator();
    while (it.next()) |s| {
        listed += 1;
        try std.testing.expect(!seen[@backingInt(s.kind)]);
        seen[@backingInt(s.kind)] = true;
    }
    try std.testing.expectEqual(count, listed);
    // Exhausted iterator stays exhausted.
    try std.testing.expect(it.next() == null);
}

test "filterTools returns allowed subset preserving order" {
    // Fixture mirrors the REAL registry def names (registerBuiltins) plus an
    // extra non-builtin tool that no preset grants.
    const Def = struct {
        name: []const u8,
        description: []const u8 = "",
        category: enum { general } = .general,
    };
    const defs = [_]Def{
        .{ .name = "web_fetch", .description = "extra tool no preset allows" },
        .{ .name = "file_read" },
        .{ .name = "grep" },
        .{ .name = "shell" },
        .{ .name = "git_commit" },
        .{ .name = "glob" },
        .{ .name = "mcp_remote_thing" },
    };
    const alloc = std.testing.allocator;

    // standard: every real builtin in the fixture passes, extras don't.
    {
        const got = try filterTools(.standard, &defs, alloc);
        defer alloc.free(got);
        try std.testing.expectEqual(@as(usize, 5), got.len);
        try std.testing.expectEqualStrings("file_read", got[0].name);
        try std.testing.expectEqualStrings("grep", got[1].name);
        try std.testing.expectEqualStrings("shell", got[2].name);
        try std.testing.expectEqualStrings("git_commit", got[3].name);
        try std.testing.expectEqualStrings("glob", got[4].name);
        // Borrowed pointers into the input array, not copies.
        try std.testing.expectEqual(&defs[1], got[0]);
        try std.testing.expectEqual(&defs[5], got[4]);
    }

    // ptc: file_read + glob + grep only.
    {
        const got = try filterTools(.ptc, &defs, alloc);
        defer alloc.free(got);
        try std.testing.expectEqual(@as(usize, 3), got.len);
        try std.testing.expectEqualStrings("file_read", got[0].name);
        try std.testing.expectEqualStrings("grep", got[1].name);
        try std.testing.expectEqualStrings("glob", got[2].name);
    }

    // minimal: shell + editor trio; glob/grep/git excluded here.
    {
        const got = try filterTools(.minimal, &defs, alloc);
        defer alloc.free(got);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqualStrings("file_read", got[0].name);
        try std.testing.expectEqualStrings("shell", got[1].name);
    }

    // Empty input yields an empty (non-null) view.
    {
        const got = try filterTools(.creative, &[_]Def{}, alloc);
        defer alloc.free(got);
        try std.testing.expectEqual(@as(usize, 0), got.len);
    }
}

test "preset tool names all exist in the builtin registry fixture" {
    // Hardcoded real registry names (src/tool/registry.zig). Catches typos
    // in preset tables without importing the registry itself.
    const registry_names = [_][]const u8{
        "file_read", "file_write", "file_edit", "glob",    "grep",
        "shell",     "git_status", "git_diff",  "git_log", "git_commit",
    };

    var it = iterator();
    while (it.next()) |s| {
        try std.testing.expect(s.tools.len > 0); // every preset grants something
        for (s.tools) |t| {
            var found = false;
            for (registry_names) |r| {
                if (std.mem.eql(u8, r, t)) found = true;
            }
            if (!found) {
                std.debug.print("preset '{s}' grants unknown tool '{s}'\n", .{ s.name, t });
                return error.TestUnexpectedResult;
            }
        }
    }

    // standard/creative expose the ENTIRE toolkit.
    for ([_]Kind{ .standard, .creative }) |k| {
        try std.testing.expectEqual(registry_names.len, spec(k).tools.len);
    }
}
