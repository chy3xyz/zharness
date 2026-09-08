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
//! Persona templates (upstream parity): every builtin carries a
//! `persona_template` supporting `{{model}}` / `{{cwd}}` placeholders,
//! resolved via `resolvePersona`. `complete_prompt` marks upstream minimal
//! isolation: the persona IS the whole system prompt (no base prompt, no
//! dynamic sections).
//!
//! User-defined presets live as JSON files under
//! `~/.zharness/agent-presets/<name>.json` managed by `CustomStore`
//! (src/preset/custom.zig, re-exported here). `resolve` is the full
//! name→Spec resolver: builtins first, then custom presets. Format choice:
//! JSON (hand-rolled like session/checkpoint.zig) rather than flat TOML —
//! the store writes whole documents per preset and needs nested arrays of
//! strings/objects, which the config.toml flat writer does not express.
//!
//! Pure data at rest: the builtin tool tables are static string slices;
//! `filterTools` derives a filtered VIEW of caller-owned definitions
//! without copying definition memory — the returned slice holds borrowed
//! pointers into `all_defs`, so freeing the slice must NOT free the
//! pointed-to definitions. Specs returned by `resolve`/`CustomStore.list`
//! may own heap memory (origin == .custom); release them via `freeSpec`.
//!
//! Tests live in this file; run everything via `zig test -lc test/_t_obs.zig`.

const std = @import("std");

pub const Error = error{UnknownPreset};

/// The four canonical modes (dev.md §XXVIII). Order matches `table`.
pub const Kind = enum {
    standard,
    minimal,
    ptc,
    creative,
};

/// Where a Spec's memory lives. `.builtin` rows point into static data and
/// must never be freed; `.custom` specs own every string/slice (release via
/// `freeSpec`).
pub const Origin = enum { builtin, custom };

/// Per-preset tool customization: disable a tool the allowlist would
/// otherwise grant, or attach opaque JSON config the integrator forwards to
/// the tool at registration/execution time.
pub const ToolOverride = struct {
    tool_name: []const u8,
    disabled: bool = false,
    /// Raw JSON object (or any JSON value) handed to the tool unchanged.
    config_json: ?[]const u8 = null,
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
    /// One-line display description (GUI preset pickers); empty for legacy.
    description: []const u8 = "",
    /// Persona with `{{model}}` / `{{cwd}}` placeholders (see resolvePersona).
    /// null → fall back to `system_prompt_fragment`.
    persona_template: ?[]const u8 = null,
    /// Upstream minimal isolation: when true the resolved persona IS the
    /// entire system prompt — callers must skip the base prompt, tool-rule
    /// sections, dynamic sections, and working-memory rendering entirely.
    complete_prompt: bool = false,
    /// Per-tool overrides applied after the allowlist filter.
    tool_config: []const ToolOverride = &.{},
    /// Sort key for GUI listing (custom presets persist their order).
    order: i32 = 0,
    origin: Origin = .builtin,
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

/// Shared upstream-grade persona opener ({{model}}/{{cwd}} substituted at
/// resolve time by `resolvePersona`).
const standard_persona =
    \\You are a coding agent powered by the {{model}} model. Your working directory is {{cwd}}.
;

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
        .description = "Full coding agent: files, search, shell, and git.",
        .persona_template = standard_persona ++
            \\
            \\Plan before multi-step work, verify your changes after editing,
            \\and report outcomes concisely.
        ,
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
        .description = "Minimal isolation: the persona is the entire prompt.",
        .persona_template =
        \\You are a helpful software engineer assistant.
        ,
        // Upstream minimal-mode key isolation mechanism: nothing else may
        // contribute to the system prompt (no tool rules, no dynamic
        // sections, no working memory).
        .complete_prompt = true,
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
        .description = "Programmatic tool calling via Code Mode programs.",
        .persona_template = standard_persona ++
            \\
            \\You operate in Code Mode: compose programs against the zharness
            \\Tool SDK so a single step executes many operations. Read-only
            \\inspection tools help you author correct programs; prefer one
            \\verified program over many individual tool calls.
        ,
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
        .description = "Cordis plugin development with the full surface.",
        .persona_template = standard_persona ++
            \\
            \\You develop Cordis plugins: inspect manifests, exercise tool
            \\surfaces, prototype quickly against the live runtime, and favor
            \\expressive solutions over conservative ones. Debugging and
            \\iteration are first-class activities in this mode.
        ,
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

// ── persona templates ───────────────────────────────────────────────────────

/// Substitute `{{model}}` and `{{cwd}}` in the spec's persona template.
///
/// Returns a caller-owned string (free with `alloc.free`). When
/// `persona_template` is null the fallback is a duplicate of
/// `system_prompt_fragment` — placeholders there are substituted too, so
/// user-authored prompts may use them. Unknown `{{...}}` tokens pass through
/// untouched; both placeholders may appear any number of times.
pub fn resolvePersona(
    alloc: std.mem.Allocator,
    s: *const Spec,
    model: []const u8,
    cwd: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const template = s.persona_template orelse s.system_prompt_fragment;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "{{model}}")) {
            try out.appendSlice(alloc, model);
            i += "{{model}}".len;
        } else if (std.mem.startsWith(u8, template[i..], "{{cwd}}")) {
            try out.appendSlice(alloc, cwd);
            i += "{{cwd}}".len;
        } else {
            try out.append(alloc, template[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

// ── per-tool overrides ──────────────────────────────────────────────────────

/// Override row for `name`, or null when the preset carries none.
pub fn toolOverrideFor(s: *const Spec, name: []const u8) ?*const ToolOverride {
    for (s.tool_config) |*o| {
        if (std.mem.eql(u8, o.tool_name, name)) return o;
    }
    return null;
}

// ── memory ownership ────────────────────────────────────────────────────────

/// Free every field a `.custom` spec owns. No-op for `.builtin` specs
/// (their strings point into static data). Safe to call on specs produced
/// by `CustomStore.list` / `resolve`.
pub fn freeSpec(alloc: std.mem.Allocator, s: *const Spec) void {
    if (s.origin != .custom) return;
    alloc.free(s.name);
    if (s.description.len > 0) alloc.free(s.description);
    alloc.free(s.system_prompt_fragment);
    if (s.persona_template) |p| alloc.free(p);
    for (s.tools) |t| alloc.free(t);
    if (s.tools.len > 0) alloc.free(s.tools);
    for (s.tool_config) |o| {
        alloc.free(o.tool_name);
        if (o.config_json) |c| alloc.free(c);
    }
    if (s.tool_config.len > 0) alloc.free(s.tool_config);
}

// ── tool filtering ──────────────────────────────────────────────────────────

/// Allowlist membership AFTER per-tool overrides: the name must be granted
/// by `tools` AND not be disabled through `tool_config`.
pub fn allowsTool(s: *const Spec, name: []const u8) bool {
    var granted = false;
    for (s.tools) |t| {
        if (std.mem.eql(u8, t, name)) {
            granted = true;
            break;
        }
    }
    if (!granted) return false;
    if (toolOverrideFor(s, name)) |o| return !o.disabled;
    return true;
}

/// Resolve the DEFINITION element type whether callers pass a slice
/// (`[]Def`) or a pointer-to-array (`&defs_array`, common in tests).
fn DefinitionOf(comptime defs_any: type) type {
    const info = @typeInfo(defs_any);
    if (info != .pointer) @compileError("filterTools expects a slice or pointer-to-array of definitions");
    const child_info = @typeInfo(info.pointer.child);
    return if (child_info == .array) child_info.array.child else info.pointer.child;
}

/// Filtered VIEW of `all_defs` keeping only tools allowed by the spec
/// (allowlist minus `tool_config` disabled entries). See `filterTools` for
/// ownership rules.
///
/// Works with any slice of definitions carrying a `.name` string field
/// (structurally compatible with `tool.registry.ToolDefinition`). Result
/// preserves `all_defs` order; preset tool names absent from `all_defs`
/// are silently skipped. Elements are borrowed pointers into `all_defs` —
/// free the returned slice with `alloc.free`, never free (or deinit)
/// through the elements themselves.
pub fn filterToolsSpec(
    s: *const Spec,
    all_defs: anytype,
    alloc: std.mem.Allocator,
) std.mem.Allocator.Error![]*const DefinitionOf(@TypeOf(all_defs)) {
    const Def = DefinitionOf(@TypeOf(all_defs));
    // Accept slices AND pointers-to-arrays by coercing to a slice view.
    const defs_view: []const Def = all_defs;
    var picked: std.ArrayList(*const Def) = .empty;
    errdefer picked.deinit(alloc);
    for (defs_view) |*def| {
        if (allowsTool(s, def.name)) try picked.append(alloc, def);
    }
    return picked.toOwnedSlice(alloc);
}

/// Kind-based convenience wrapper over `filterToolsSpec`.
pub fn filterTools(
    preset: Kind,
    all_defs: anytype,
    alloc: std.mem.Allocator,
) std.mem.Allocator.Error![]*const DefinitionOf(@TypeOf(all_defs)) {
    return filterToolsSpec(spec(preset), all_defs, alloc);
}

// ── user-defined presets (src/preset/custom.zig) ────────────────────────────

pub const custom = @import("preset/custom.zig");
pub const CustomStore = custom.CustomStore;

/// Full name→Spec resolver used by CLI/GUI surfaces: builtins win, then
/// `<custom_dir>/<name>.json`. The returned Spec is caller-owned in BOTH
/// cases — release via `freeSpec` (a builtin free is a no-op).
pub fn resolve(
    alloc: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    custom_dir: ?[]const u8,
) custom.ResolveError!Spec {
    if (lookup(name)) |s| return s.*;
    const dir = custom_dir orelse try custom.defaultDirPath(alloc);
    defer if (custom_dir == null) alloc.free(dir);
    return custom.loadFile(alloc, io, dir, name);
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

// ── persona templates (item 1) ──────────────────────────────────────────────

test "resolvePersona substitutes {{model}} and {{cwd}}" {
    const alloc = std.testing.allocator;

    // standard: both placeholders present.
    {
        const s = spec(.standard);
        const got = try resolvePersona(alloc, s, "deepseek-v4", "/work/repo");
        defer alloc.free(got);
        try std.testing.expectEqualStrings(
            "You are a coding agent powered by the deepseek-v4 model. Your working directory is /work/repo." ++
                "\nPlan before multi-step work, verify your changes after editing," ++
                "\nand report outcomes concisely.",
            got,
        );
    }

    // Repeated placeholders all substitute; unknown {{...}} passes through.
    {
        const custom_spec = Spec{
            .kind = .standard,
            .name = "t",
            .tools = &.{},
            .system_prompt_fragment = "",
            .default_max_turns = 1,
            .persona_template = "{{model}}/{{model}} {{cwd}} {{unknown}} {{cwd}}",
        };
        const got = try resolvePersona(alloc, &custom_spec, "m", "~/c");
        defer alloc.free(got);
        try std.testing.expectEqualStrings("m/m ~/c {{unknown}} ~/c", got);
    }

    // null template falls back to system_prompt_fragment (still resolved).
    {
        const custom_spec = Spec{
            .kind = .minimal,
            .name = "t",
            .tools = &.{},
            .system_prompt_fragment = "cwd is {{cwd}}",
            .default_max_turns = 1,
        };
        const got = try resolvePersona(alloc, &custom_spec, "ignored-model", "/");
        defer alloc.free(got);
        try std.testing.expectEqualStrings("cwd is /", got);
    }

    // Every builtin ships a persona template; the shared opener carries
    // both placeholders, while upstream minimal's terse persona is exempt
    // (it must stay exactly "You are a helpful software engineer
    // assistant." and isolates via complete_prompt instead).
    var it = iterator();
    while (it.next()) |s| {
        try std.testing.expect(s.persona_template != null);
        if (s.complete_prompt) {
            try std.testing.expectEqualStrings(
                "You are a helpful software engineer assistant.",
                s.persona_template.?,
            );
        } else {
            try std.testing.expect(std.mem.indexOf(u8, s.persona_template.?, "{{model}}") != null);
            try std.testing.expect(std.mem.indexOf(u8, s.persona_template.?, "{{cwd}}") != null);
        }
    }
}

// ── complete_prompt isolation flag (item 2) ─────────────────────────────────

test "complete_prompt is minimal-only isolation" {
    try std.testing.expect(spec(.minimal).complete_prompt);
    try std.testing.expect(!spec(.standard).complete_prompt);
    try std.testing.expect(!spec(.ptc).complete_prompt);
    try std.testing.expect(!spec(.creative).complete_prompt);

    // Default is false so user data and old callers stay on full prompts.
    const default_spec = Spec{
        .kind = .standard,
        .name = "t",
        .tools = &.{},
        .system_prompt_fragment = "",
        .default_max_turns = 1,
    };
    try std.testing.expect(!default_spec.complete_prompt);
}

// ── per-preset tool overrides (item 4) ──────────────────────────────────────

test "tool_config disabled entries are removed by filterToolsSpec" {
    const Def = struct { name: []const u8 };

    const with_overrides = Spec{
        .kind = .minimal,
        .name = "guarded",
        .tools = &.{ "file_read", "file_edit", "shell" },
        .system_prompt_fragment = "",
        .default_max_turns = 8,
        .tool_config = &.{
            .{ .tool_name = "shell", .disabled = true },
            .{ .tool_name = "file_edit", .config_json = "{\"mode\":\"safe\"}" }, // config only: kept
        },
    };
    const defs = [_]Def{ .{ .name = "shell" }, .{ .name = "file_read" }, .{ .name = "file_edit" } };

    const got = try filterToolsSpec(&with_overrides, &defs, std.testing.allocator);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len); // shell dropped
    try std.testing.expectEqualStrings("file_read", got[0].name);
    try std.testing.expectEqualStrings("file_edit", got[1].name); // config-only override keeps tool

    // Override lookup helpers agree.
    try std.testing.expect(toolOverrideFor(&with_overrides, "shell") != null);
    try std.testing.expect(toolOverrideFor(&with_overrides, "glob") == null);
    try std.testing.expectEqualStrings("{\"mode\":\"safe\"}", toolOverrideFor(&with_overrides, "file_edit").?.config_json.?);
    try std.testing.expect(!allowsTool(&with_overrides, "shell"));
    try std.testing.expect(allowsTool(&with_overrides, "file_edit"));

    // Builtin presets carry no overrides — filter behavior unchanged.
    const defs2 = [_]Def{ .{ .name = "shell" }, .{ .name = "grep" } };
    const got2 = try filterTools(.ptc, &defs2, std.testing.allocator);
    defer std.testing.allocator.free(got2);
    try std.testing.expectEqual(@as(usize, 1), got2.len);
    try std.testing.expectEqualStrings("grep", got2[0].name);
}

// ── custom preset CRUD (item 3) ─────────────────────────────────────────────

test "custom preset save/list/delete round-trip and resolve precedence" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // TmpDir lives under <cwd>/.zig-cache/tmp/<sub_path>; rebuild the real
    // relative path (same trick as pluginabi/loader.zig tests).
    const dir_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dir_path);

    var store = CustomStore.init(alloc, dir_path);

    // Empty dir → empty list, resolve misses customs but hits builtins.
    {
        const none = try store.list(io, alloc);
        store.freeList(alloc, none);
        try std.testing.expectError(error.UnknownPreset, fromString("team-tooling"));
    }
    {
        const builtin_resolved = try resolve(alloc, io, "ptc", dir_path);
        freeSpec(alloc, &builtin_resolved); // builtin free is a no-op
        try std.testing.expectEqual(Origin.builtin, builtin_resolved.origin);
        try std.testing.expectEqualStrings("ptc", builtin_resolved.name);
    }

    // Save two customs (unsorted order values to exercise sorting).
    const saved_a = Spec{
        .kind = .standard,
        .name = "team-a",
        .tools = &.{ "file_read", "shell", "grep" },
        .system_prompt_fragment = "Team A agent for {{cwd}}.",
        .default_max_turns = 16,
        .order = 5,
        .origin = .custom,
    };
    const saved_b = Spec{
        .kind = .minimal,
        .name = "team-b",
        .tools = &.{"shell"},
        .system_prompt_fragment = "Locked-down helper.",
        .description = "locked down",
        .default_max_turns = 4,
        .order = 1,
        .complete_prompt = true,
        .tool_config = &.{.{ .tool_name = "shell", .disabled = true }},
        .origin = .custom,
    };
    try store.save(io, &saved_b);
    try store.save(io, &saved_a);

    // List sorts by order then name; fields round-trip.
    {
        const listed = try store.list(io, alloc);
        defer store.freeList(alloc, listed);
        try std.testing.expectEqual(@as(usize, 2), listed.len);
        try std.testing.expectEqualStrings("team-b", listed[0].name);
        try std.testing.expectEqualStrings("team-a", listed[1].name);
        try std.testing.expect(listed[0].complete_prompt);
        try std.testing.expectEqual(@as(usize, 4), listed[0].default_max_turns);
        try std.testing.expectEqual(@as(i32, 5), listed[1].order);
        try std.testing.expectEqualStrings("Team A agent for {{cwd}}.", listed[1].system_prompt_fragment);
        try std.testing.expectEqual(@as(usize, 3), listed[1].tools.len);
        try std.testing.expectEqual(Origin.custom, listed[0].origin);
        // Disabled override survives persistence and filters tools.
        try std.testing.expect(!allowsTool(&listed[0], "shell"));
    }

    // Full resolver finds customs after builtins and personas still resolve.
    {
        const team = try resolve(alloc, io, "team-a", dir_path);
        defer freeSpec(alloc, &team);
        const persona = try resolvePersona(alloc, &team, "m9", "/w");
        defer alloc.free(persona);
        try std.testing.expectEqualStrings("Team A agent for /w.", persona);
    }

    // Overwrite (save is create-or-replace).
    {
        var updated = saved_a;
        updated.default_max_turns = 99;
        try store.save(io, &updated);
        const reread = try custom.loadFile(alloc, io, dir_path, "team-a");
        defer freeSpec(alloc, &reread);
        try std.testing.expectEqual(@as(usize, 99), reread.default_max_turns);
    }

    // Delete removes the file; second delete reports missing.
    try store.delete(io, "team-a");
    try std.testing.expectError(error.PresetNotFound, store.delete(io, "team-a"));
    try std.testing.expectError(error.UnknownPreset, resolve(alloc, io, "team-a", dir_path));

    // Path-safety: hostile names never touch the filesystem.
    try std.testing.expect(!custom.validName("../escape"));
    try std.testing.expect(!custom.validName("a/b"));
    try std.testing.expect(!custom.validName(""));
    try std.testing.expectError(error.InvalidName, store.save(io, &.{
        .kind = .standard,
        .name = "../evil",
        .tools = &.{},
        .system_prompt_fragment = "x",
        .default_max_turns = 1,
    }));
}
