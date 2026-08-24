//! Skills RPC domain — wire truth:
//! `_ref/deepseek-harness/packages/host/apiproxy/src/api/skills{,.schema}.ts`
//! (method key `skill.list`, rpc-map.ts).
//!
//! ── CONTRACT ──────────────────────────────────────────────────────────────
//! skill.list request  {sessionId}                    (sessionIdSchema)
//! skill.list response {skills:[{name,description,
//!                              whenToUse?,modelInvocable}]}
//!
//! The sessionId only selects which session header resolves the project root
//! upstream; zharness is single-cwd, so it is validated and otherwise unused
//! (documented deviation). Invocation itself is a plain session.prompt with a
//! leading `/name` token upstream — zharness has no slash pipeline yet, so
//! this method is catalog-only.
//!
//! Implementation: a FRESH SkillRegistry disk scan per call over the two
//! integration roots (skill/loader.zig contract):
//!   <cwd>/skills          — workspace skills (first root wins name clashes)
//!   <home>/.zharness/skills
//! Rows map loader/skill.zig facts onto SkillEntry: `name` + `description`
//! from front-matter; `whenToUse` is omitted (zharness front-matter has no
//! such field); `modelInvocable` is always true (`disable-model-invocation`
//! does not exist in the zharness format — every skill reaches the model).
//! Output is sorted by name for deterministic byte shapes.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const router = @import("router.zig");
const skill_mod = @import("../../skill/skill.zig");
const skill_loader = @import("../../skill/loader.zig");

// ── value builder ───────────────────────────────────────────────────────────

/// Render the skill.list response VALUE ({skills:[…]}) from one registry.
/// Registry order is load order; rows are emitted sorted by name.
pub fn valueFromRegistry(alloc: std.mem.Allocator, reg: *const skill_mod.SkillRegistry) ![]u8 {
    const Entry = struct { s: *const skill_mod.Skill };
    var rows: std.ArrayList(Entry) = .empty;
    defer rows.deinit(alloc);
    for (reg.skills.items) |*s| try rows.append(alloc, .{ .s = s });

    std.mem.sort(Entry, rows.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.s.name, b.s.name) == .lt;
        }
    }.lt);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"skills\":[");
    for (rows.items, 0..) |row, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        try out.appendSlice(alloc, "{\"name\":");
        try jsonx.appendJsonString(alloc, &out, row.s.name);
        try out.appendSlice(alloc, ",\"description\":");
        try jsonx.appendJsonString(alloc, &out, row.s.description);
        // whenToUse omitted (absent in the zharness format);
        // modelInvocable always true (see module header).
        try out.appendSlice(alloc, ",\"modelInvocable\":true}");
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

/// Fresh disk scan → skill.list value. Either root may be empty/null.
pub fn listValueFromDisk(
    alloc: std.mem.Allocator,
    workspace_skills_dir: []const u8,
    home_skills_dir: []const u8,
) ![]u8 {
    // A Threaded io is required by the loader's directory walking; built per
    // call because this handler runs rarely (composer @-trigger / open).
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var reg = skill_mod.SkillRegistry.init(alloc);
    defer reg.deinit();

    var roots_buf: [2][]const u8 = undefined;
    var n_roots: usize = 0;
    if (workspace_skills_dir.len > 0) {
        roots_buf[n_roots] = workspace_skills_dir;
        n_roots += 1;
    }
    if (home_skills_dir.len > 0) {
        roots_buf[n_roots] = home_skills_dir;
        n_roots += 1;
    }
    _ = skill_loader.loadAll(alloc, io, roots_buf[0..n_roots], &reg) catch {};
    // Individual unreadable candidates are skipped inside loadAll; a total
    // failure degrades to whatever registered (possibly nothing) rather than
    // failing the RPC — an empty catalog renders an empty picker.

    return valueFromRegistry(alloc, &reg);
}

// ── handler (wired from router.dispatch) ────────────────────────────────────

pub fn handle(deps: *const router.ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !router.UnaryResponse {
    // sessionId required by schema; unused beyond validation (single-cwd host).
    const raw = jsonx.getRaw(payload, "sessionId") orelse return error.PayloadInvalid;
    if (!jsonx.isString(raw)) return error.PayloadInvalid;
    _ = jsonx.decodeString(alloc, raw[1 .. raw.len - 1]) catch return error.OutOfMemory;

    var ws_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var home_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_dir = std.fmt.bufPrint(&ws_dir_buf, "{s}/skills", .{deps.cwd}) catch "";
    const home_dir = std.fmt.bufPrint(&home_dir_buf, "{s}/.zharness/skills", .{deps.home}) catch "";

    const value = try listValueFromDisk(alloc, ws_dir, home_dir);
    return router.okValue(alloc, rpc_id, value);
}
