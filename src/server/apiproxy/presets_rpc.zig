//! Agent-preset RPC domain — wire truth:
//! `_ref/deepseek-harness/packages/host/apiproxy/src/api/agent-presets{,.schema}.ts`.
//!
//! ── CONTRACT ──────────────────────────────────────────────────────────────
//! agentPreset.list   {} → {presets:[{id,trust:"system"|"user",isDefault,
//!                        name?,description?,broken?}],
//!                        authorable:bool, hasDocument:bool}
//! agentPreset.select {sessionId,agentPreset} → {agentPreset}
//!
//! Roster: the four zharness presets (src/presets.zig — standard / minimal /
//! ptc / creative), all trust "system" (they ship with the deployment),
//! never broken. `description` is the preset's first prompt-fragment line.
//! `authorable:false` and `hasDocument:false` are deployment facts: zharness
//! configures no user-writable preset root and no native opener for one.
//!
//! Default persistence rides the settings pseudo-namespace "agent-presets"
//! (ui-agent-preset/src/client/settings-store.ts AGENT_PRESET_SETTINGS_NS,
//! field `default`): the router intercepts settings.update/mutate with that
//! ns and lands the value in config.toml [general] agent_preset through
//! router.commitCustomKv. list resolves isDefault from that document value
//! (fallback: "standard").
//!
//! select is SESSION-scoped upstream ("recompose one session's agent"); it is
//! only allowed while the session is blank (agent-preset-locked otherwise).
//! zharness records the choice in a process-global table (SpinLock singleton)
//! so the integrator's session-create path can read it via
//! `takeSelection(session_id)`; the GUI refreshes its label from the next
//! session.list summary (`agentPreset` field) or from the response value.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const router = @import("router.zig");
const presets = @import("../../presets.zig");
const config = @import("../../config.zig");

pub const default_preset_name = "standard";

/// First sentence of the preset's system-prompt fragment (display text).
fn firstSentence(fragment: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, fragment, " \n\t\r");
    if (std.mem.indexOfScalar(u8, trimmed, '.')) |dot| {
        if (dot + 1 <= trimmed.len) return trimmed[0 .. dot + 1];
    }
    return trimmed;
}

// ── default-preset persistence ([general] agent_preset) ────────────────────

/// Resolve the document default preset (falls back to "standard").
pub fn defaultPresetOf(entries: ?[]const config.TomlEntry) []const u8 {
    const list = entries orelse return default_preset_name;
    for (list) |e| {
        if (std.mem.eql(u8, e.section, "general") and
            std.mem.eql(u8, e.key, "agent_preset") and e.val == .str)
        {
            return e.val.str;
        }
    }
    return default_preset_name;
}

/// Resolve the document mode-selection flag (falls back to false).
pub fn modeSelectionOf(entries: ?[]const config.TomlEntry) bool {
    const list = entries orelse return false;
    for (list) |e| {
        if (std.mem.eql(u8, e.section, "general") and
            std.mem.eql(u8, e.key, "mode_selection_enabled") and e.val == .boolean)
        {
            return e.val.boolean;
        }
    }
    return false;
}

/// Persist the default preset through the settings Store under the shared
/// fenced commit. Revision counter is module-global (restart resets, same
/// documented posture as Store.revisions).
var g_revision: u64 = 0;

/// Shared fenced-commit revision counter (router.commitCustomKv consumer).
pub fn revisionPtr() *u64 {
    return &g_revision;
}

/// Whether an id names a listed preset (validation hook for the intercepted
/// agent-presets settings writes).
pub fn validDefaultId(id: []const u8) bool {
    return presets.lookup(id) != null;
}

pub fn writeDefault(store: anytype, alloc: std.mem.Allocator, preset_id: []const u8, expected_revision: ?i64) !void {
    if (presets.lookup(preset_id) == null) return error.UnknownPreset;
    try router.commitCustomKv(
        store,
        alloc,
        .{ .section = "general", .key = "agent_preset", .value = .{ .str = preset_id } },
        &g_revision,
        expected_revision,
    );
}

// ── per-session selection registry (process-global) ────────────────────────

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins >= 16) {
                const req: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                _ = nanosleep(&req, null);
            } else std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

const SelectionRow = struct {
    session_id: []u8,
    preset: []u8,
};

var g_lock: SpinLock = .{};
var g_selections: std.ArrayList(SelectionRow) = .empty;

/// Record a session's selected preset (process-lifetime; entries accumulate
/// by design so late-created sessions can still resolve their composition).
pub fn recordSelection(session_id: []const u8, preset: []const u8) !void {
    const alloc = std.heap.page_allocator;
    g_lock.lock();
    defer g_lock.unlock();
    for (g_selections.items) |*row| {
        if (std.mem.eql(u8, row.session_id, session_id)) {
            const copy = try alloc.dupe(u8, preset);
            alloc.free(row.preset);
            row.preset = copy;
            return;
        }
    }
    try g_selections.append(alloc, .{
        .session_id = try alloc.dupe(u8, session_id),
        .preset = try alloc.dupe(u8, preset),
    });
}

/// Read back a session's recorded selection; null when none.
pub fn selectionFor(session_id: []const u8) ?[]const u8 {
    g_lock.lock();
    defer g_lock.unlock();
    for (g_selections.items) |row| {
        if (std.mem.eql(u8, row.session_id, session_id)) return row.preset;
    }
    return null;
}

/// Test hook: drop every recorded selection.
pub fn clearSelections() void {
    g_lock.lock();
    defer g_lock.unlock();
    for (g_selections.items) |row| {
        std.heap.page_allocator.free(row.session_id);
        std.heap.page_allocator.free(row.preset);
    }
    g_selections.clearRetainingCapacity();
}

// ── value builders ─────────────────────────────────────────────────────────

pub fn appendPresetEntryJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: *const presets.Spec, default_name: []const u8, first: *bool) !void {
    if (!first.*) try out.append(alloc, ',');
    first.* = false;
    try out.appendSlice(alloc, "{\"id\":");
    try jsonx.appendJsonString(alloc, out, s.name);
    try out.appendSlice(alloc, ",\"trust\":\"system\",\"isDefault\":");
    try out.appendSlice(alloc, if (std.mem.eql(u8, s.name, default_name)) "true" else "false");
    try out.appendSlice(alloc, ",\"name\":");
    try jsonx.appendJsonString(alloc, out, s.name);
    try out.appendSlice(alloc, ",\"description\":");
    try jsonx.appendJsonString(alloc, out, firstSentence(s.system_prompt_fragment));
    try out.append(alloc, '}');
}

pub fn listValue(alloc: std.mem.Allocator, default_name: []const u8, mode_selection_enabled: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"presets\":[");
    var first = true;
    var it = presets.iterator();
    while (it.next()) |s| {
        try appendPresetEntryJson(alloc, &out, s, default_name, &first);
    }
    // Deployment facts: no user-writable root, no native opener.
    try out.appendSlice(alloc, "],\"authorable\":false,\"hasDocument\":false,\"modeSelectionEnabled\":");
    try out.appendSlice(alloc, if (mode_selection_enabled) "true" else "false");
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

/// settings namespace view for the intercepted "agent-presets" ns
/// (settingsNamespaceViewSchema shape).
pub fn appendNamespaceViewJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), revision: u64, current_default: []const u8, mode_selection_enabled: bool) !void {
    try out.appendSlice(alloc, "{\"ns\":\"agent-presets\",\"schema\":" ++ schema_agent_presets ++
        ",\"value\":{\"default\":");
    try jsonx.appendJsonString(alloc, out, current_default);
    try out.appendSlice(alloc, ",\"modeSelectionEnabled\":");
    try out.appendSlice(alloc, if (mode_selection_enabled) "true" else "false");
    try out.appendSlice(alloc, "},\"user\":{\"default\":");
    try jsonx.appendJsonString(alloc, out, current_default);
    try out.appendSlice(alloc, ",\"modeSelectionEnabled\":");
    try out.appendSlice(alloc, if (mode_selection_enabled) "true" else "false");
    try out.appendSlice(alloc, "},\"applies\":\"live\",\"secrets\":[],\"revision\":");
    try jsonx.appendInt(alloc, out, @intCast(revision));
    try out.append(alloc, '}');
}

/// Schemastery envelope ({uid,refs}) for {default:string,
/// modeSelectionEnabled:boolean} — same hand-serialized style as
/// apiproxy/settings.zig's envelopes. uid names the ROOT ref (the object);
/// Schemastery's fromJSON returns refs[uid], so a uid missing from refs
/// rehydrates to undefined.
const schema_agent_presets =
    \\{"uid":3,"refs":{"1":{"type":"string","meta":{}},"2":{"type":"boolean","meta":{"default":false}},"3":{"type":"object","meta":{"default":{"default":"standard","modeSelectionEnabled":false}},"dict":{"default":1,"modeSelectionEnabled":2}}}}
;

// ── handlers (wired from router.dispatch) ──────────────────────────────────

fn docEntries(deps: *const router.ApiProxyDeps, alloc: std.mem.Allocator) ?[]config.TomlEntry {
    const store = router.settingsStoreOf(deps.home) orelse return null;
    const doc = store.readDoc(alloc) catch return null;
    if (doc == null) return null;
    return config.parseTomlFlat(alloc, doc.?) catch null;
}

pub fn handleList(deps: *const router.ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8) !router.UnaryResponse {
    const entries = docEntries(deps, alloc);
    const def = defaultPresetOf(entries);
    const value = try listValue(alloc, def, modeSelectionOf(entries));
    return router.okValue(alloc, rpc_id, value);
}

pub fn handleSelect(deps: *const router.ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !router.UnaryResponse {
    const sid_raw = jsonx.getRaw(payload, "sessionId") orelse return error.PayloadInvalid;
    const preset_raw = jsonx.getRaw(payload, "agentPreset") orelse return error.PayloadInvalid;
    if (!jsonx.isString(sid_raw) or !jsonx.isString(preset_raw)) return error.PayloadInvalid;
    const session_id = try jsonx.decodeString(alloc, sid_raw[1 .. sid_raw.len - 1]);
    const preset_id = try jsonx.decodeString(alloc, preset_raw[1 .. preset_raw.len - 1]);

    // Unknown preset → agent-preset-not-found {agentPreset, available}.
    if (presets.lookup(preset_id) == null) {
        var d: std.ArrayList(u8) = .empty;
        defer d.deinit(alloc);
        var avail: std.ArrayList(u8) = .empty;
        defer avail.deinit(alloc);
        try avail.append(alloc, '[');
        var it = presets.iterator();
        var f = true;
        while (it.next()) |s| {
            if (!f) try avail.append(alloc, ',');
            f = false;
            try jsonx.appendJsonString(alloc, &avail, s.name);
        }
        try avail.append(alloc, ']');
        try d.appendSlice(alloc, "{\"agentPreset\":");
        try jsonx.appendJsonString(alloc, &d, preset_id);
        try d.appendSlice(alloc, ",\"available\":");
        try d.appendSlice(alloc, avail.items);
        try d.append(alloc, '}');
        return router.errValue(alloc, rpc_id, .agent_preset_not_found, "unknown agent preset", d.items);
    }

    // Blank-gate: allowed only while the session has run no turn.
    const sessions = try deps.listSessions(deps.ctx, alloc);
    for (sessions) |s| {
        if (!std.mem.eql(u8, s.session_id, session_id)) continue;
        if (!s.blank) {
            var d: std.ArrayList(u8) = .empty;
            defer d.deinit(alloc);
            try d.appendSlice(alloc, "{\"sessionId\":");
            try jsonx.appendJsonString(alloc, &d, session_id);
            try d.appendSlice(alloc, ",\"agentPreset\":");
            try jsonx.appendJsonString(alloc, &d, preset_id);
            try d.append(alloc, '}');
            return router.errValue(alloc, rpc_id, .agent_preset_locked, "session already started; preset is locked", d.items);
        }
        break;
    }
    // Unknown sessions pass through unvalidated here (the create path owns
    // existence); upstream resolves an ordinary session first.

    try recordSelection(session_id, preset_id);

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"agentPreset\":");
    try jsonx.appendJsonString(alloc, &value, preset_id);
    try value.append(alloc, '}');
    return router.okValue(alloc, rpc_id, value.items);
}
