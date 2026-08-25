//! pluginInventory/list — the vendored GUI's Plugins-settings inventory tab
//! over zharness's REAL plugin systems (native dylib registry + WASM
//! registry).
//!
//! Wire truth (upstream, vendored): `_ref/deepseek-harness/packages/host/
//! plugin-inventory/src/index.ts` — service `pluginInventory`, method `list`,
//! payload `{entries:[{entryId, moduleName, enabled, fiberPhase}]}`. The
//! browser validates the value against that exact zod schema (unknown fields
//! are stripped), so this module renders ONLY upstream fields and maps
//! zharness concepts onto them:
//!
//!   native dylib loaded  → entryId = file path, moduleName = manifest name,
//!                          enabled = true, fiberPhase = "active"
//!   wasm module loaded   → same, name re-read from the module's zh_manifest
//!   skipped/broken file  → entryId = file path, moduleName =
//!                          "<basename>: <skip reason>", enabled = true,
//!                          fiberPhase = "failed"  ← renders the failed dot
//!
//! The last mapping is deliberate: a file present in a watched plugins
//! directory but rejected by the loader IS an attempted-and-failed load in
//! upstream semantics ("enabled + fiberPhase failed" is exactly how cordis
//! renders a broken loader entry), so it shows up as an error card with the
//! reason as its title.
//!
//! Scanning policy: both registries are instantiated FRESH per request over
//! the default dirs (`~/.zharness/plugins` + `<cwd>/plugins` for native,
//! `~/.zharness/plugins-wasm` + `<cwd>/plugins-wasm` for wasm) on the request
//! arena. dlopen cost per click is fine; nothing here touches the running
//! session's tool surface (main.zig loads those registries per-run inside
//! buildLoop). No enable/disable: the upstream inventory tab is read-only.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const loader = @import("../../pluginabi/loader.zig");
const wasm_loader = @import("../../pluginabi/wasm_loader.zig");
const builtin_catalog = @import("../../pluginabi/builtin_catalog.zig");

/// One inventory row already projected into wire vocabulary.
const Entry = struct {
    entry_id: []const u8,
    module_name: []const u8,
    enabled: bool,
    /// Upstream phase literal: "active" or "failed" here.
    fiber_phase: []const u8,
};

/// Render the full pluginInventory/list VALUE (`{"entries":[…]}`) fresh from
/// disk. Everything lands in `alloc` (the httpd request arena — no manual
/// frees; the registry deinits are harmless arena no-ops kept for hygiene).
/// `home` is injected explicitly (not read from the environment) so callers
/// — and tests — can isolate the scanned set. Pass the real user home for
/// production; pass a temp dir to assert empty/controlled inventories.
pub fn listValue(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, home: []const u8) ![]u8 {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(alloc);

    // Both registries must outlive `entries`: rows borrow plugin paths and
    // manifest names from registry storage. Render happens below, BEFORE
    // deinit.
    // Built-in capability catalog first (upstream tool packages compiled
    // into zharness: fs, web, shell, goal, todo, ask-user, subagent, skill).
    for (builtin_catalog.entries) |b| {
        try entries.append(alloc, .{
            .entry_id = b.entry_id,
            .module_name = b.module_name,
            .enabled = b.enabled,
            .fiber_phase = b.fiber_phase,
        });
    }

    var reg = loader.PluginRegistry.init(alloc);
    defer reg.deinit();
    // Same discovery order as loadDefaultDirs, but with the home injected:
    // ~/.zharness/plugins first, then <workspace>/plugins.
    if (homeDirJoin(alloc, home, ".zharness", "plugins")) |user_dir| {
        defer alloc.free(user_dir);
        _ = reg.loadDir(io, user_dir);
    }
    _ = reg.loadDir(io, std.fmt.allocPrint(alloc, "{s}/plugins", .{cwd}) catch return error.OutOfMemory);
    try collectNative(alloc, &reg, &entries);
    try collectReports(alloc, &entries, reg.report.items);

    var wreg = wasm_loader.WasmRegistry.init(alloc);
    defer wreg.deinit();
    if (homeDirJoin(alloc, home, ".zharness", "plugins-wasm")) |user_dir| {
        defer alloc.free(user_dir);
        _ = wreg.loadDir(io, user_dir);
    }
    _ = wreg.loadDir(io, std.fmt.allocPrint(alloc, "{s}/plugins-wasm", .{cwd}) catch return error.OutOfMemory);
    try collectWasm(alloc, &wreg, &entries);
    try collectReports(alloc, &entries, wreg.report.items);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"entries\":[");
    for (entries.items, 0..) |e, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"entryId\":");
        try jsonx.appendJsonString(alloc, &out, e.entry_id);
        try out.appendSlice(alloc, ",\"moduleName\":");
        try jsonx.appendJsonString(alloc, &out, e.module_name);
        try out.appendSlice(alloc, ",\"enabled\":");
        try out.appendSlice(alloc, if (e.enabled) "true" else "false");
        if (e.fiber_phase.len > 0) {
            try out.appendSlice(alloc, ",\"fiberPhase\":");
            try jsonx.appendJsonString(alloc, &out, e.fiber_phase);
        } else {
            // Upstream union includes literal null (unobserved entries).
            try out.appendSlice(alloc, ",\"fiberPhase\":null");
        }
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

/// Loaded native plugins → active rows. The manifest is re-parsed from the
/// plugin's own storage to recover name/version-grade truth the registry
/// does not retain; a parse failure degrades to the basename.
fn collectNative(
    alloc: std.mem.Allocator,
    reg: *loader.PluginRegistry,
    entries: *std.ArrayList(Entry),
) !void {
    for (reg.plugins.items) |p| {
        const name = blk: {
            const src = p.manifest();
            const m = loader.parseManifest(alloc, src) catch break :blk null;
            break :blk m.name;
        };
        const display = name orelse try fallbackName(alloc, p.pathSlice());
        try entries.append(alloc, .{
            .entry_id = p.pathSlice(),
            .module_name = display,
            .enabled = true,
            .fiber_phase = "active",
        });
    }
}

/// Loaded wasm modules → active rows; names come straight from each guest's
/// zh_manifest export (non-destructive peek — the VM stays owned by the
/// registry).
fn collectWasm(
    alloc: std.mem.Allocator,
    reg: *wasm_loader.WasmRegistry,
    entries: *std.ArrayList(Entry),
) !void {
    for (reg.plugins.items, 0..) |p, idx| {
        const name: ?[]u8 = blk: {
            const src = reg.peekManifest(idx) orelse break :blk null;
            const m = loader.parseManifest(alloc, src) catch break :blk null;
            break :blk m.name;
        };
        const display = name orelse try fallbackName(alloc, p.path);
        try entries.append(alloc, .{
            .entry_id = p.path,
            .module_name = display,
            .enabled = true,
            .fiber_phase = "active",
        });
    }
}

/// Skip-report rows → failed rows (error cards). The card title carries the
/// reason (moduleShortName passes it through untouched); the details line
/// shows the full path via entryId.
fn collectReports(
    alloc: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    reports: anytype,
) !void {
    for (reports) |r| {
        const base = std.fs.path.basename(r.path);
        const title = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ base, r.reason });
        try entries.append(alloc, .{
            .entry_id = r.path,
            .module_name = title,
            .enabled = true,
            .fiber_phase = "failed",
        });
    }
}

fn homeDirJoin(alloc: std.mem.Allocator, home: []const u8, a: []const u8, b: []const u8) ?[]u8 {
    if (home.len == 0) return null;
    return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ home, a, b }) catch null;
}

/// Basename of a '/'-or-platform path when the manifest could not be read.
fn fallbackName(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return alloc.dupe(u8, std.fs.path.basename(path));
}

// ── tests (pure rendering + mapping; no dlopen/wasm needed) ────────────────

test "listValue renders empty entries array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // No real dirs under a temp workspace → zero rows, valid JSON shape.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // TmpDir lives under <cwd>/.zig-cache/tmp/<sub_path>; rebuild the real
    // path the same way loader.zig's own tests do.
    const dir_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // Builtins are always included; assert the response is valid JSON with
    // the expected builtin rows (external scan finds nothing in tmp dirs).
    const value = try listValue(alloc, std.testing.io, dir_path, dir_path);
    try std.testing.expect(std.mem.indexOf(u8, value, "\"entries\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "builtin:") != null);
}
