//! Permission-preset RPC domain — wire truth:
//! `_ref/deepseek-harness/packages/interaction/permission-presets/src/index.ts`
//! (preset table, settings namespace) and
//! `packages/client/ui-permission-presets/src/client/settings-store.ts`
//! (PERMISSION_SETTINGS_NS = "permission", field `defaultPreset`).
//!
//! ── CONTRACT ──────────────────────────────────────────────────────────────
//! The GUI row renders from the shared settings mirror: settings.describe
//! must carry a `permission` namespace whose schema advertises the preset
//! enum as a union-of-consts (with meta.description labels), and writes go
//! through settings.mutate {ns:"permission", ops:[{op:"set",
//! path:["defaultPreset"], value:<preset>}], expectedRevision}.
//!
//! Preset table (upstream defaults + zharness sandbox mapping):
//!
//!   id                  upstream sandbox       zharness sandbox_mode
//!   read-only           read-only              native
//!   workspace-write     workspace-write        process   ← default
//!   danger-full-access  danger-full-access     none
//!
//! The canonical knob is config.toml [general] sandbox_mode — the value
//! main.zig actually reads at boot. A defaultPreset write maps to it via the
//! table; reads reverse-map. Unknown sandbox spellings render as "custom"
//! (CUSTOM_PRESET posture) rather than erroring.
//!
//! The router intercepts settings.{update,mutate,replace} carrying
//! ns:"permission" BEFORE the generic store path (settings.zig is a read-only
//! import for this module) and answers with this module's namespace view.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const router = @import("router.zig");
const config = @import("../../config.zig");

pub const custom_preset = "custom";
pub const default_preset = "workspace-write";

/// One preset row: upstream key ↔ zharness SandboxMode.
pub const Row = struct {
    id: []const u8,
    /// config.toml [general] sandbox_mode spelling (config.SandboxMode).
    sandbox_mode: []const u8,
    description: []const u8,
};

pub const table = [_]Row{
    .{
        .id = "read-only",
        .sandbox_mode = "native",
        .description = "OS-native confinement for inspection-only sessions; no writes.",
    },
    .{
        .id = "workspace-write",
        .sandbox_mode = "process",
        .description = "Write inside the workspace and permitted temporary directories; wider retries require approval.",
    },
    .{
        .id = "danger-full-access",
        .sandbox_mode = "none",
        .description = "Full file access without approval prompts.",
    },
};

/// Preset id for a sandbox_mode spelling; null ⇒ "custom" territory.
pub fn presetForSandbox(sandbox_mode: []const u8) ?[]const u8 {
    for (&table) |*r| {
        if (std.mem.eql(u8, r.sandbox_mode, sandbox_mode)) return r.id;
    }
    return null;
}

/// Sandbox mode for a preset id; unknown ids are rejected by callers.
pub fn sandboxForPreset(preset_id: []const u8) ?[]const u8 {
    for (&table) |*r| {
        if (std.mem.eql(u8, r.id, preset_id)) return r.sandbox_mode;
    }
    return null;
}

// ── persistence ([general] sandbox_mode) ───────────────────────────────────

var g_revision: u64 = 0;

/// Shared fenced-commit revision counter (router.commitCustomKv consumer).
pub fn revisionPtr() *u64 {
    return &g_revision;
}

/// Persist one preset as the new-session default by writing its mapped
/// sandbox mode into [general] sandbox_mode.
pub fn writeDefault(store: anytype, alloc: std.mem.Allocator, preset_id: []const u8, expected_revision: ?i64) !void {
    const mode = sandboxForPreset(preset_id) orelse return error.UnknownPreset;
    try router.commitCustomKv(
        store,
        alloc,
        .{ .section = "general", .key = "sandbox_mode", .value = .{ .str = mode } },
        &g_revision,
        expected_revision,
    );
}

/// Reverse-map the document's [general] sandbox_mode onto the advertised
/// current preset (unknown spellings → "custom").
pub fn currentPresetOf(entries: ?[]const config.TomlEntry) []const u8 {
    const list = entries orelse return default_preset;
    for (list) |e| {
        if (std.mem.eql(u8, e.section, "general") and
            std.mem.eql(u8, e.key, "sandbox_mode") and e.val == .str)
        {
            return presetForSandbox(e.val.str) orelse custom_preset;
        }
    }
    return default_preset;
}

// ── describe view ──────────────────────────────────────────────────────────

/// Schemastery envelope for {defaultPreset: union("read-only"|"workspace-
/// write"|"danger-full-access")} — union of consts WITH meta.description
/// labels exactly as ui-permission-presets' permissionDefaultOf() expects
/// (node.type === "union" → list of consts carrying meta.description).
/// The top-level uid names the ROOT ref (Schemastery's fromJSON returns
/// refs[uid]); a uid absent from refs rehydrates to undefined.
const schema_permission =
    \\{"uid":5,"refs":{"1":{"type":"const","meta":{"required":true,"description":"OS-native confinement for inspection-only sessions; no writes."},"value":"read-only"},"2":{"type":"const","meta":{"required":true,"description":"Write inside the workspace and permitted temporary directories; wider retries require approval."},"value":"workspace-write"},"3":{"type":"const","meta":{"required":true,"description":"Full file access without approval prompts."},"value":"danger-full-access"},"4":{"type":"union","meta":{"default":"workspace-write"},"list":[1,2,3]},"5":{"type":"object","meta":{"default":{}},"dict":{"defaultPreset":4}}}}
;

pub fn appendNamespaceViewJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), revision: u64, current: []const u8) !void {
    try out.appendSlice(alloc, "{\"ns\":\"permission\",\"schema\":" ++ schema_permission ++
        ",\"value\":{\"defaultPreset\":");
    try jsonx.appendJsonString(alloc, out, current);
    try out.appendSlice(alloc, "},\"user\":{\"defaultPreset\":");
    try jsonx.appendJsonString(alloc, out, current);
    try out.appendSlice(alloc, "},\"applies\":\"live\",\"secrets\":[],\"revision\":");
    try jsonx.appendInt(alloc, out, @intCast(revision));
    try out.append(alloc, '}');
}

// ── write-path helpers (called from the router intercepts) ─────────────────

/// Validate one defaultPreset candidate against the table.
/// PermissionPresetsCatalog JSON ({options:[{value,name,description?},…]})
/// over the preset table, in declaration order (upstream optionOf shape).
pub fn catalogJson(alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"options\":[");
    for (&table, 0..) |*r, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"value\":");
        try jsonx.appendJsonString(alloc, &out, r.id);
        try out.appendSlice(alloc, ",\"name\":");
        try jsonx.appendJsonString(alloc, &out, r.id);
        try out.appendSlice(alloc, ",\"description\":");
        try jsonx.appendJsonString(alloc, &out, r.description);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

pub fn validPreset(id: []const u8) bool {
    return sandboxForPreset(id) != null;
}

test "preset table round-trips through sandbox modes" {
    for (&table) |*r| {
        try std.testing.expectEqualStrings(r.id, presetForSandbox(r.sandbox_mode).?);
        try std.testing.expectEqualStrings(r.sandbox_mode, sandboxForPreset(r.id).?);
        try std.testing.expect(validPreset(r.id));
    }
    try std.testing.expectEqualStrings("workspace-write", currentPresetOf(null));
    try std.testing.expect(!validPreset(custom_preset));
    try std.testing.expect(sandboxForPreset("bogus") == null);
}
