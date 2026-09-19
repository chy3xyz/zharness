//! Model-selection RPC domain — wire truth:
//! `_ref/deepseek-harness/packages/host/apiproxy/src/api/sessions.schema.ts`
//! (modelSelectionSchema / modelCatalog* schemas) and `llm{,.schema}.ts`.
//!
//! ── CONTRACT ──────────────────────────────────────────────────────────────
//! session.models      {sessionId} → {current:{provider,model,
//!                        reasoningEffort?}, routable:bool,
//!                        groups:[{id,name,models:[{id,name,description?,
//!                        reasoning?}]}], failures:[]}
//! session.selectModel {sessionId,provider,model,reasoningEffort?}
//!                                → {selected:{provider,model,
//!                                  reasoningEffort?}}
//! llm.providers       {}         → {providers:[ConfigurableProviderView]}
//!
//! Catalog policy (advisory; zharness never phones a provider for discovery):
//!   deepseek      — [model] models rows from config.toml first, then the
//!                   static seeds (deepseek-chat / deepseek-reasoner /
//!                   deepseek-v4-flash), dedup by id;
//!   anthropic     — claude family static seeds;
//!   ollama        — local seed(s) from the provider profile;
//!   openai-compat — profile default seed.
//! All four groups are ALWAYS listed (a host-scoped catalog); `failures` is
//! always empty because listing is pure data.
//!
//! Persistence: session.selectModel writes through apiproxy/settings.zig's
//! Store via commitKvs under the agent namespace ([model] provider/model +
//! [agent] reasoning_effort) so the choice survives restart and hot-reloads
//! per run exactly like every other config.toml edit. The sessionId is
//! validated but unused — zharness runs one host-wide selection (documented
//! deviation; upstream selections are per-session).
//!
//! llm.providers rows follow ConfigurableProviderView: only the DeepSeek route
//! has its own settings section (`settingsNs:"llm-deepseek"`, whole-section
//! settingsPath); the other three switch via the agent namespace's `provider`
//! field (settingsPath ["provider"]). `active` mirrors deps.provider.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const router = @import("router.zig");
const config = @import("../../config.zig");
const providers = @import("../../model/provider.zig");
const apx_settings = @import("settings.zig");

// ── catalog seeds ───────────────────────────────────────────────────────────

const Seed = struct { id: []const u8, name: []const u8 };

const anthropic_seeds = [_]Seed{
    .{ .id = "claude-sonnet-4-20250514", .name = "Claude Sonnet 4" },
    .{ .id = "claude-opus-4-20250514", .name = "Claude Opus 4" },
    .{ .id = "claude-haiku-4-20250514", .name = "Claude Haiku 4" },
};
const ollama_seeds = [_]Seed{
    .{ .id = "qwen2.5-coder", .name = "Qwen2.5 Coder (local)" },
};
const openai_compat_seeds = [_]Seed{
    .{ .id = "gpt-4o-mini", .name = "GPT-4o mini" },
};

fn appendSeed(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: Seed, first: *bool) !void {
    if (!first.*) try out.append(alloc, ',');
    first.* = false;
    try out.appendSlice(alloc, "{\"id\":");
    try jsonx.appendJsonString(alloc, out, s.id);
    try out.appendSlice(alloc, ",\"name\":");
    try jsonx.appendJsonString(alloc, out, s.name);
    try out.append(alloc, '}');
}

/// One provider group row of modelProviderGroupSchema.
fn appendGroup(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    id: []const u8,
    name: []const u8,
    entries: ?[]const config.TomlEntry,
    extra_seeds: []const Seed,
) !void {
    try out.appendSlice(alloc, "{\"id\":");
    try jsonx.appendJsonString(alloc, out, id);
    try out.appendSlice(alloc, ",\"name\":");
    try jsonx.appendJsonString(alloc, out, name);
    try out.appendSlice(alloc, ",\"models\":[");

    var first = true;

    if (std.mem.eql(u8, id, "deepseek")) {
        // Configured rows win the head positions: [model] models =
        // [{id,name?,contextWindow?,maxTokens?},…].
        if (findModelsArray(entries)) |rows_raw| {
            // Walk complete {...} objects; naive comma-splitting would cut
            // rows that carry commas inside their own members.
            const inner_raw = trimArr(rows_raw);
            var pos: usize = 0;
            while (pos < inner_raw.len) {
                while (pos < inner_raw.len and (inner_raw[pos] == ',' or asciiWsByte(inner_raw[pos]))) : (pos += 1) {}
                if (pos >= inner_raw.len or inner_raw[pos] != '{') break;
                const end = jsonx.matchBraceFrom(inner_raw, pos) orelse break;
                const row = inner_raw[pos..end];
                pos = end;
                const id_raw = jsonx.getRaw(row, "id") orelse continue;
                if (!jsonx.isString(id_raw)) continue;
                const mid = jsonx.decodeString(alloc, id_raw[1 .. id_raw.len - 1]) catch continue;
                const mname = blk: {
                    const nr = jsonx.getRaw(row, "name") orelse break :blk mid;
                    if (!jsonx.isString(nr)) break :blk mid;
                    break :blk jsonx.decodeString(alloc, nr[1 .. nr.len - 1]) catch mid;
                };
                if (!first) try out.append(alloc, ',');
                first = false;
                try out.appendSlice(alloc, "{\"id\":");
                try jsonx.appendJsonString(alloc, out, mid);
                try out.appendSlice(alloc, ",\"name\":");
                try jsonx.appendJsonString(alloc, out, mname);
                try out.append(alloc, '}');
            }
        }
        // Static seeds dedup against configured ids.
        const statics = [_]Seed{
            .{ .id = "deepseek-chat", .name = "DeepSeek Chat" },
            .{ .id = "deepseek-reasoner", .name = "DeepSeek Reasoner" },
            .{ .id = config.default_model, .name = "DeepSeek (zharness default)" },
        };
        for (statics) |s| {
            if (groupContainsModel(alloc, out.items, s.id)) continue;
            try appendSeed(alloc, out, s, &first);
        }
    } else {
        for (extra_seeds) |s| {
            try appendSeed(alloc, out, s, &first);
        }
    }

    try out.appendSlice(alloc, "]}");
}

fn trimArr(raw: []const u8) []const u8 {
    if (raw.len >= 2 and raw[0] == '[') return raw[1 .. raw.len - 1];
    return raw;
}

fn asciiWsByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn findModelsArray(entries: ?[]const config.TomlEntry) ?[]const u8 {
    const list = entries orelse return null;
    for (list) |e| {
        if (std.mem.eql(u8, e.section, "model") and std.mem.eql(u8, e.key, "models")) {
            return switch (e.val) {
                .raw => |r| r,
                else => null,
            };
        }
    }
    return null;
}

/// Whether the rendered group JSON already carries `"id":"<mid>"`. Cheap
/// substring probe over the bytes appended so far — good enough for dedup of
/// advisory rows within one render pass.
fn groupContainsModel(alloc: std.mem.Allocator, rendered_so_far: []const u8, model_id: []const u8) bool {
    var probe: std.ArrayList(u8) = .empty;
    defer probe.deinit(alloc);
    jsonx.appendJsonString(alloc, &probe, model_id) catch return false;
    const needle = std.fmt.allocPrint(alloc, "\"id\":{s}", .{probe.items}) catch return false;
    defer alloc.free(needle);
    return std.mem.indexOf(u8, rendered_so_far, needle) != null;
}

/// All groups in declaration order (deepseek, openai-compat, anthropic,
/// ollama — matching provider.zig's enum order).
pub fn appendGroupsJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), entries: ?[]const config.TomlEntry) !void {
    try appendGroup(alloc, out, "deepseek", "DeepSeek", entries, &.{});
    try out.append(alloc, ',');
    try appendGroup(alloc, out, "openai-compat", "OpenAI-Compatible", entries, &openai_compat_seeds);
    try out.append(alloc, ',');
    try appendGroup(alloc, out, "anthropic", "Anthropic", entries, &anthropic_seeds);
    try out.append(alloc, ',');
    try appendGroup(alloc, out, "ollama", "Ollama (local)", entries, &ollama_seeds);
}

// ── current selection ───────────────────────────────────────────────────────

pub const Selection = struct {
    provider: []const u8,
    model: []const u8,
    reasoning_effort: ?[]const u8,
};

/// Effective selection resolved from the document ⊕ defaults (agent ns
/// semantics: env does not shadow provider/model at the settings layer).
pub fn currentSelection(entries: ?[]const config.TomlEntry) Selection {
    var sel = Selection{
        .provider = "deepseek",
        .model = config.default_model,
        .reasoning_effort = "medium",
    };
    if (entries) |list| {
        for (list) |e| {
            if (e.val != .str) continue;
            if (std.mem.eql(u8, e.section, "model")) {
                if (std.mem.eql(u8, e.key, "provider")) sel.provider = e.val.str;
                if (std.mem.eql(u8, e.key, "model")) sel.model = e.val.str;
            }
            if (std.mem.eql(u8, e.section, "agent") and std.mem.eql(u8, e.key, "reasoning_effort")) {
                sel.reasoning_effort = e.val.str;
            }
        }
    }
    return sel;
}

/// Render modelSelectionSchema bytes (provider/model/reasoningEffort?).
pub fn appendSelectionJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), sel: Selection) !void {
    try out.appendSlice(alloc, "{\"provider\":");
    try jsonx.appendJsonString(alloc, out, sel.provider);
    try out.appendSlice(alloc, ",\"model\":");
    try jsonx.appendJsonString(alloc, out, sel.model);
    if (sel.reasoning_effort) |re| {
        try out.appendSlice(alloc, ",\"reasoningEffort\":");
        try jsonx.appendJsonString(alloc, out, re);
    }
    try out.append(alloc, '}');
}

// ── persistence ─────────────────────────────────────────────────────────────

pub const SelectError = error{
    UnknownProvider,
    BadValueType,
    WriteFailed,
    OutOfMemory,
};

/// Persist one full selection through the settings Store (agent ns fields:
/// provider/model ride [model], reasoningEffort rides [agent]). Fenced by
/// commitKvs' revision machinery; expectedRevision is not part of the
/// selectModel schema, so no fence is requested.
pub fn selectInto(
    store: *apx_settings.Store,
    alloc: std.mem.Allocator,
    provider: []const u8,
    model: []const u8,
    reasoning_effort: ?[]const u8,
) SelectError!void {
    if (providers.Provider.fromString(provider) == null) return error.UnknownProvider;
    if (model.len == 0) return error.BadValueType;
    if (reasoning_effort) |re| if (!validReasoningEffort(re)) return error.BadValueType;

    var kvs: std.ArrayList(config.ConfigKv) = .empty;
    defer kvs.deinit(alloc);
    kvs.append(alloc, .{ .section = "model", .key = "provider", .value = .{ .str = provider } }) catch return error.OutOfMemory;
    kvs.append(alloc, .{ .section = "model", .key = "model", .value = .{ .str = model } }) catch return error.OutOfMemory;
    if (reasoning_effort) |re| {
        kvs.append(alloc, .{ .section = "agent", .key = "reasoning_effort", .value = .{ .str = re } }) catch return error.OutOfMemory;
    }

    const ns_ids = [_]usize{apx_settings.Store.ns_agent};
    _ = apx_settings.commitKvs(store, alloc, kvs.items, &ns_ids, apx_settings.Store.ns_agent, null, apx_settings.collectEnv()) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.WriteFailed,
    };
}

// ── handlers (wired from router.dispatch) ──────────────────────────────────

fn docEntries(deps: *const router.ApiProxyDeps, alloc: std.mem.Allocator) !?[]config.TomlEntry {
    const store = router.settingsStoreOf(deps.home) orelse return null;
    const doc = try store.readDoc(alloc);
    if (doc == null) return null;
    return try config.parseTomlFlat(alloc, doc.?);
}

pub fn handleSessionModels(deps: *const router.ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !router.UnaryResponse {
    // sessionId required (single-selection host: validated, otherwise unused).
    const raw = jsonx.getRaw(payload, "sessionId") orelse return error.PayloadInvalid;
    if (!jsonx.isString(raw)) return error.PayloadInvalid;

    const entries = try docEntries(deps, alloc);
    const current = currentSelection(entries);

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"current\":");
    try appendSelectionJson(alloc, &value, current);
    // routable: the active route is requestable whenever it resolves to a
    // known provider profile (credentials gate the request itself).
    try value.appendSlice(alloc, ",\"routable\":");
    try value.appendSlice(alloc, if (providers.Provider.fromString(current.provider) != null) "true" else "false");
    try value.appendSlice(alloc, ",\"groups\":[");
    try appendGroupsJson(alloc, &value, entries);
    try value.appendSlice(alloc, "],\"failures\":[]}");
    return router.okValue(alloc, rpc_id, value.items);
}

/// session.modelCatalog (v0.1.6 shape): default selection, routable provider
/// ids, provider groups, and per-provider catalog failures.
pub fn handleModelCatalog(deps: *const router.ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8) !router.UnaryResponse {
    const entries = try docEntries(deps, alloc);
    const current = currentSelection(entries);

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"default\":{\"provider\":");
    try appendSelectionJsonStr(alloc, &value, current.provider);
    try value.appendSlice(alloc, ",\"model\":");
    try appendSelectionJsonStr(alloc, &value, current.model);
    try value.appendSlice(alloc, "},\"routableProviders\":[");
    try value.appendSlice(alloc, if (providers.Provider.fromString(current.provider) != null) "\"deepseek\"" else "");
    try value.appendSlice(alloc, "],\"groups\":[");
    try appendGroupsJson(alloc, &value, entries);
    try value.appendSlice(alloc, "],\"failures\":[]}");
    return router.okValue(alloc, rpc_id, value.items);
}

/// String-literal append with JSON escaping (models/provider ids here are
/// plain ASCII; escape anyway so nothing can break the envelope).
fn appendSelectionJsonStr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(alloc);
    try jsonx.appendJsonString(alloc, &tmp, s);
    try out.appendSlice(alloc, tmp.items);
}

/// DeepSeek API's documented reasoning_effort variants. Values outside this
/// set make the provider reject the whole request body.
pub fn validReasoningEffort(v: []const u8) bool {
    const variants = [_][]const u8{ "none", "minimal", "low", "medium", "high", "xhigh", "max" };
    for (variants) |want| if (std.mem.eql(u8, v, want)) return true;
    return false;
}

pub fn handleSessionSelectModel(deps: *const router.ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !router.UnaryResponse {
    const sid_raw = jsonx.getRaw(payload, "sessionId") orelse return error.PayloadInvalid;
    if (!jsonx.isString(sid_raw)) return error.PayloadInvalid;

    const provider_raw = jsonx.getRaw(payload, "provider") orelse return error.PayloadInvalid;
    const model_raw = jsonx.getRaw(payload, "model") orelse return error.PayloadInvalid;
    if (!jsonx.isString(provider_raw) or !jsonx.isString(model_raw)) return error.PayloadInvalid;
    const provider = jsonx.decodeString(alloc, provider_raw[1 .. provider_raw.len - 1]) catch return error.OutOfMemory;
    const model = jsonx.decodeString(alloc, model_raw[1 .. model_raw.len - 1]) catch return error.OutOfMemory;
    const effort: ?[]const u8 = blk: {
        const er = jsonx.getRaw(payload, "reasoningEffort") orelse break :blk null;
        if (!jsonx.isString(er)) return error.PayloadInvalid;
        const decoded = jsonx.decodeString(alloc, er[1 .. er.len - 1]) catch return error.OutOfMemory;
        // The GUI sends enum keys, not wire values ("reasoningEffort" once
        // landed in config.toml and the API rejected every request). Only the
        // documented variants may persist; anything else is dropped.
        break :blk if (validReasoningEffort(decoded)) decoded else null;
    };

    const store = router.settingsStoreOf(deps.home) orelse
        return router.internalError(alloc, rpc_id, "settings are not implemented on this host");

    selectInto(store, alloc, provider, model, effort) catch |e| switch (e) {
        error.UnknownProvider => {
            var d: std.ArrayList(u8) = .empty;
            defer d.deinit(alloc);
            try d.appendSlice(alloc, "{\"provider\":");
            try jsonx.appendJsonString(alloc, &d, provider);
            try d.appendSlice(alloc, ",\"model\":");
            try jsonx.appendJsonString(alloc, &d, model);
            try d.appendSlice(alloc, "}");
            return router.errValue(alloc, rpc_id, .model_unavailable, "unknown provider route", d.items);
        },
        else => return error.PayloadInvalid,
    };

    const sel = Selection{ .provider = provider, .model = model, .reasoning_effort = effort };
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"selected\":");
    try appendSelectionJson(alloc, &value, sel);
    try value.appendSlice(alloc, "}");
    return router.okValue(alloc, rpc_id, value.items);
}

/// llm.providers over the static provider matrix (deps.llmProviders override
/// still wins — see router.dispatch).
pub fn handleLlmProviders(deps: *const router.ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !router.UnaryResponse {
    _ = payload; // {} per llmProvidersRequestSchema

    const Row = struct { key: []const u8, display: []const u8, settings_ns: []const u8, path_elem: []const u8 };
    const rows = [_]Row{
        .{ .key = "deepseek", .display = "DeepSeek", .settings_ns = "llm-deepseek", .path_elem = "" },
        .{ .key = "openai-compat", .display = "OpenAI-Compatible", .settings_ns = "agent", .path_elem = "provider" },
        .{ .key = "anthropic", .display = "Anthropic", .settings_ns = "agent", .path_elem = "provider" },
        .{ .key = "ollama", .display = "Ollama (local)", .settings_ns = "agent", .path_elem = "provider" },
    };

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(alloc);
    try value.appendSlice(alloc, "{\"providers\":[");
    for (rows, 0..) |row, i| {
        if (i > 0) try value.append(alloc, ',');
        try value.appendSlice(alloc, "{\"provider\":");
        try jsonx.appendJsonString(alloc, &value, row.key);
        try value.appendSlice(alloc, ",\"displayName\":");
        try jsonx.appendJsonString(alloc, &value, row.display);
        try value.appendSlice(alloc, ",\"settingsNs\":");
        try jsonx.appendJsonString(alloc, &value, row.settings_ns);
        try value.appendSlice(alloc, ",\"settingsPath\":[");
        if (row.path_elem.len > 0) try jsonx.appendJsonString(alloc, &value, row.path_elem);
        try value.appendSlice(alloc, "],\"active\":");
        const active = deps.provider != null and std.mem.eql(u8, deps.provider.?, row.key);
        try value.appendSlice(alloc, if (active) "true" else "false");
        try value.appendSlice(alloc, ",\"declared\":true}");
    }
    try value.appendSlice(alloc, "]}");
    return router.okValue(alloc, rpc_id, value.items);
}
