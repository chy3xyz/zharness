//! Settings RPC backend — the web face of `~/.zharness/config.toml`
//! (docs/settings.md is the user-level contract; wire truth:
//! `_ref/deepseek-harness/packages/host/apiproxy/src/api/settings*.ts`).
//!
//! The GUI's settings shell renders NAMESPACES from `settings.describe`; each
//! namespace carries a schemastery envelope (`{uid, refs}` — the exact
//! serialization of `Schema.toJSON()`, rehydrated client-side with
//! `new Schema(json)`), the effective value, the raw user layer, and a
//! monotonic revision. Writes (`settings.update/mutate/replace`) are
//! validated against the per-field table below, persisted atomically
//! (tmp + rename, checkpoint-writer style), and answered with the namespace's
//! new redacted view so the browser mirror can fold it in.
//!
//! Namespace ↔ config.toml mapping (v1):
//!
//!   agent        {provider,model,maxTurns,reasoningEffort,stream,sandboxMode}
//!                ⇄ defaults ⊕ [model] provider/model ⊕ [agent] *   (per-run hot reload)
//!   llm-deepseek {baseURL,apiKeyEnv?,models?}
//!                ⇄ [model] endpoint/api_key/models                  (per-run hot reload)
//!   ui-theme     {preference} ⇄ [preferences] theme                 (live*)
//!   locale       {preference?} ⇄ [preferences] locale               (live*)
//!
//! (*) the Host only persists; the owning client plugin applies live.
//!
//! Precedence: env (ZHARNESS_API_KEY / DEEPSEEK_API_KEY / ZHARNESS_ENDPOINT)
//! still beats the FILE at boot for api_key/endpoint — writes land in the
//! document and an env override keeps winning on the next start. The value
//! payload therefore reports the DOCUMENT truth while `apiKeyEnv` presence
//! reflects the effective credential state.
//!
//! Concurrency: one Store per server, all RPCs under one mutex. Handlers are
//! arena-allocated by the router (no deinit on returned JSON).

const std = @import("std");
const config = @import("../../config.zig");
const jsonx = @import("jsonx.zig");

/// Minimal test-and-set spin lock with sleep backoff — the codebase's
/// server/events.zig design (std.Thread.Mutex lives under std.Io in this
/// toolchain). Critical sections here are tiny (parse + one file write).
const StoreLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *StoreLock) void {
        var spins: u32 = 0;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins >= 16) {
                const req: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                _ = nanosleep(&req, null);
            } else std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *StoreLock) void {
        self.locked.store(false, .release);
    }
};

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

pub const Store = struct {
    gpa: std.mem.Allocator,
    /// Process home ("~"), used as `<home>/.zharness/config.toml`. Empty ⇒
    /// describe degrades to an empty document view.
    home: []const u8,
    mutex: StoreLock = .{},
    io: std.Io,

    /// Per-namespace revision counters (indexed by `Store.ns_*`). Monotonic
    /// for the process lifetime; restart resets them (documented).
    revisions: [5]u64 = .{ 0, 0, 0, 0, 0 },

    /// Heap-allocated threaded Io backing `io`; owned by the store.
    threaded: ?*std.Io.Threaded = null,

    /// Initialize IN PLACE (a Threaded must not be copied after init). The
    /// store lives for the process lifetime; there is no deinit by design.
    pub fn initInPlace(self: *Store, gpa: std.mem.Allocator, home: []const u8) !void {
        const threaded = try gpa.create(std.Io.Threaded);
        threaded.* = std.Io.Threaded.init(gpa, .{});
        self.* = .{ .gpa = gpa, .home = home, .io = threaded.io(), .threaded = threaded };
    }

    pub const ns_agent: usize = 0;
    pub const ns_llm_deepseek: usize = 1;
    pub const ns_theme: usize = 2;
    pub const ns_locale: usize = 3;
    /// WelcomeNotice acknowledgement row (schema-less; verbatim-object
    /// decoder client-side). Persisted under [preferences]
    /// welcome_notice_version; defaults to the CURRENT notice version so a
    /// provisioned harness boots pre-acknowledged.
    pub const ns_onboarding: usize = 4;

    /// Full path of the settings document ("<home>/.zharness/config.toml").
    pub fn configPath(self: *Store, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/.zharness/config.toml", .{self.home});
    }

    /// Read the raw document; null when absent. Empty home ⇒ null.
    pub fn readDoc(self: *Store, alloc: std.mem.Allocator) !?[]u8 {
        if (self.home.len == 0) return null;
        const path = try self.configPath(alloc);
        defer alloc.free(path);
        return std.Io.Dir.readFileAlloc(.cwd(), self.io, path, alloc, .unlimited) catch |e| switch (e) {
            error.FileNotFound => null,
            else => e,
        };
    }

    /// Atomically write the document: ensure ~/.zharness exists, write
    /// "<path>.tmp", rename over the target (checkpoint.zig style).
    pub fn writeDoc(self: *Store, data: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        const path = try self.configPath(alloc);
        const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            const dir = path[0..slash];
            std.Io.Dir.createDirPath(.cwd(), self.io, dir) catch {};
        }
        try std.Io.Dir.writeFile(.cwd(), self.io, .{ .sub_path = tmp_path, .data = data });
        std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, self.io) catch {
            std.Io.Dir.deleteFile(.cwd(), self.io, tmp_path) catch {};
            return error.WriteFailed;
        };
    }
};

/// Environment facts that beat the document at boot (config.load semantics).
/// Tests pass literals; runtime fills via collectEnv().
pub const EnvFacts = struct {
    zharness_api_key: ?[]const u8 = null,
    deepseek_api_key: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,

    /// Whether any credential source is configured for the DeepSeek route.
    pub fn keyConfigured(self: EnvFacts) bool {
        return self.zharness_api_key != null or self.deepseek_api_key != null;
    }
};

/// Collect env facts like config.load does (libc getenv).
pub fn collectEnv() EnvFacts {
    return .{
        .zharness_api_key = optEnv("ZHARNESS_API_KEY"),
        .deepseek_api_key = optEnv("DEEPSEEK_API_KEY"),
        .endpoint = optEnv("ZHARNESS_ENDPOINT"),
    };
}

fn optEnv(name: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name.ptr) orelse return null;
    const s = std.mem.span(v);
    return if (s.len > 0) s else null;
}

// ── schema envelopes ────────────────────────────────────────────────────────
//
// Hand-serialized `Schema.toJSON()` output ({uid, refs} with numeric child
// references). Verified against vendor/schemastery: `new Schema(env)`
// rehydrates and validates these exact byte shapes.

const schema_agent =
    \\{"uid":7,"refs":{"1":{"type":"string","meta":{}},"2":{"type":"string","meta":{}},"3":{"type":"number","meta":{}},"4":{"type":"string","meta":{}},"5":{"type":"boolean","meta":{}},"6":{"type":"string","meta":{}},"7":{"type":"object","meta":{"default":{}},"dict":{"provider":1,"model":2,"maxTurns":3,"reasoningEffort":4,"stream":5,"sandboxMode":6}}}}
;
const schema_llm_deepseek =
    \\{"uid":9,"refs":{"1":{"type":"string","meta":{}},"2":{"type":"string","meta":{}},"3":{"type":"number","meta":{}},"4":{"type":"number","meta":{}},"5":{"type":"object","meta":{},"dict":{"id":1,"name":2,"contextWindow":3,"maxTokens":4}},"6":{"type":"array","meta":{},"inner":5},"7":{"type":"string","meta":{}},"8":{"type":"string","meta":{}},"9":{"type":"object","meta":{"default":{}},"dict":{"baseURL":7,"apiKeyEnv":8,"models":6}}}}
;
const schema_ui_theme =
    \\{"uid":5,"refs":{"1":{"type":"const","meta":{"required":true},"value":"light"},"2":{"type":"const","meta":{"required":true},"value":"dark"},"3":{"type":"const","meta":{"required":true},"value":"system"},"4":{"type":"union","meta":{"default":"system"},"list":[1,2,3]},"5":{"type":"object","meta":{"default":{}},"dict":{"preference":4}}}}
;
const schema_locale =
    \\{"uid":4,"refs":{"1":{"type":"const","meta":{"required":true},"value":"zh"},"2":{"type":"const","meta":{"required":true},"value":"en"},"3":{"type":"union","meta":{"required":false},"list":[1,2]},"4":{"type":"object","meta":{"default":{}},"dict":{"preference":3}}}}
;

/// The vendored GUI's current WelcomeNotice version (onboarding-copy.ts).
/// Kept in sync when webui/ is re-vendored.
pub const onboarding_notice_version = "2026-08-13.1";

// ── effective-config projection ─────────────────────────────────────────────

/// One scalar field slot shared by the value/user-layer builders and write
/// validation. `toml_section`/`toml_key` name where the field persists.
const FieldDef = struct {
    name: []const u8, // namespace JSON field
    kind: Kind,
    section: []const u8,
    key: []const u8,
    default: TomlDefault = .none,

    const Kind = enum { string, integer, boolean, models_array };

    const TomlDefault = union(enum) {
        none,
        str: []const u8,
        int: i64,
        boolean: bool,
    };
};

/// The `agent` namespace fields (mission-required knobs).
const agent_fields = [_]FieldDef{
    .{ .name = "provider", .kind = .string, .section = "model", .key = "provider", .default = .{ .str = "deepseek" } },
    .{ .name = "model", .kind = .string, .section = "model", .key = "model", .default = .{ .str = config.default_model } },
    .{ .name = "maxTurns", .kind = .integer, .section = "agent", .key = "max_turns", .default = .{ .int = 64 } },
    .{ .name = "reasoningEffort", .kind = .string, .section = "agent", .key = "reasoning_effort", .default = .{ .str = "medium" } },
    .{ .name = "stream", .kind = .boolean, .section = "agent", .key = "stream", .default = .{ .boolean = true } },
    .{ .name = "sandboxMode", .kind = .string, .section = "general", .key = "sandbox_mode", .default = .{ .str = "process" } },
};

/// Look up one parsed entry by section+key.
fn findEntry(entries: ?[]const config.TomlEntry, section: []const u8, key: []const u8) ?config.TomlValue {
    const list = entries orelse return null;
    for (list) |e| {
        if (std.mem.eql(u8, e.section, section) and std.mem.eql(u8, e.key, key)) return e.val;
    }
    return null;
}

fn findString(entries: ?[]const config.TomlEntry, section: []const u8, key: []const u8) ?[]const u8 {
    const v = findEntry(entries, section, key) orelse return null;
    return switch (v) {
        .str => |s| s,
        else => null,
    };
}

/// Append `"name":<json>` for one agent field resolved from entries ⊕ default.
fn appendAgentField(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    f: FieldDef,
    entries: ?[]const config.TomlEntry,
    first: *bool,
) !void {
    var got: ?config.TomlValue = findEntry(entries, f.section, f.key);
    if (got == null and f.default == .none) return; // absent stays absent
    const val = got orelse switch (f.default) {
        .str => |s| config.TomlValue{ .str = s },
        .int => |i| config.TomlValue{ .int = i },
        .boolean => |b| config.TomlValue{ .boolean = b },
        .none => return,
    };
    _ = &got;
    if (!first.*) try out.append(alloc, ',');
    first.* = false;
    try out.append(alloc, '"');
    try out.appendSlice(alloc, f.name);
    try out.appendSlice(alloc, "\":");
    try appendTomlJson(alloc, out, val);
}

/// Render one TOML scalar as its JSON twin (strings quoted/escaped).
fn appendTomlJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: config.TomlValue) !void {
    switch (v) {
        .str => |s| try jsonx.appendJsonString(alloc, out, s),
        .int => |i| try jsonx.appendInt(alloc, out, i),
        .boolean => |b| try out.appendSlice(alloc, if (b) "true" else "false"),
        // Raw values were required to be JSON-compatible at parse time.
        .raw => |r| {
            if (jsonx.objectBody(r) != null or (r.len >= 2 and r[0] == '[')) {
                try out.appendSlice(alloc, r);
            } else {
                try out.appendSlice(alloc, "null");
            }
        },
    }
}

// ── namespace views ─────────────────────────────────────────────────────────

/// Build ONE namespace view object per settingsNamespaceViewSchema:
/// {ns, schema, value, user?, applies, secrets, revision}.
pub fn appendNamespaceView(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    store: *Store,
    ns_id: usize,
    entries: ?[]const config.TomlEntry,
    env: EnvFacts,
) !void {
    const ns_name: []const u8 = switch (ns_id) {
        Store.ns_agent => "agent",
        Store.ns_llm_deepseek => "llm-deepseek",
        Store.ns_theme => "ui-theme",
        Store.ns_locale => "locale",
        Store.ns_onboarding => "ui-onboarding",
        else => unreachable,
    };
    const schema_json: ?[]const u8 = switch (ns_id) {
        Store.ns_agent => schema_agent,
        Store.ns_llm_deepseek => schema_llm_deepseek,
        Store.ns_theme => schema_ui_theme,
        Store.ns_locale => schema_locale,
        // The welcome scope binds a verbatim-object decoder; no envelope.
        Store.ns_onboarding => null,
        else => unreachable,
    };
    // Hot semantics: the server re-reads config.toml before every run, so
    // agent/llm edits apply to the NEXT message without a restart. Theme/
    // locale/onboarding are applied live by the owning client plugin.
    const applies: []const u8 = "live";

    try out.appendSlice(alloc, "{\"ns\":");
    try jsonx.appendJsonString(alloc, out, ns_name);
    try out.appendSlice(alloc, ",\"schema\":");
    if (schema_json) |sj| try out.appendSlice(alloc, sj) else try out.appendSlice(alloc, "null");
    try out.appendSlice(alloc, ",\"value\":");

    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(alloc);
    var user: std.ArrayList(u8) = .empty;
    defer user.deinit(alloc);

    switch (ns_id) {
        Store.ns_agent => {
            try value.appendSlice(alloc, "{");
            var first = true;
            for (agent_fields) |f| try appendAgentField(alloc, &value, f, entries, &first);
            try value.appendSlice(alloc, "}");

            try user.appendSlice(alloc, "{");
            var ufirst = true;
            for (agent_fields) |f| {
                if (findEntry(entries, f.section, f.key) == null) continue;
                try appendAgentField(alloc, &user, f, entries, &ufirst);
            }
            try user.appendSlice(alloc, "}");
        },
        Store.ns_llm_deepseek => {
            // Effective endpoint: env beats file beats provider default.
            const ep_env = env.endpoint;
            const ep_file = findString(entries, "model", "endpoint");
            const base_url = ep_env orelse ep_file orelse "https://api.deepseek.com/chat/completions";
            const model = findString(entries, "model", "model") orelse config.default_model;
            const key_set = env.keyConfigured() or blk: {
                const k = findString(entries, "model", "api_key") orelse break :blk false;
                break :blk k.len > 0;
            };
            const file_key = findString(entries, "model", "api_key");
            const file_key_set = file_key != null and file_key.?.len > 0;

            try value.appendSlice(alloc, "{\"baseURL\":");
            try jsonx.appendJsonString(alloc, &value, base_url);
            if (key_set) {
                try value.appendSlice(alloc, ",\"apiKeyEnv\":\"DEEPSEEK_API_KEY\"");
            }
            try value.appendSlice(alloc, ",\"models\":[{\"id\":");
            try jsonx.appendJsonString(alloc, &value, model);
            try value.appendSlice(alloc, "}]}");

            // User layer: only what the FILE carries.
            try user.appendSlice(alloc, "{");
            var ufirst = true;
            if (ep_file != null) {
                try user.appendSlice(alloc, "\"baseURL\":");
                try jsonx.appendJsonString(alloc, &user, ep_file.?);
                ufirst = false;
            }
            if (file_key_set) {
                if (!ufirst) try user.append(alloc, ',');
                ufirst = false;
                try user.appendSlice(alloc, "\"apiKeyEnv\":\"DEEPSEEK_API_KEY\"");
            }
            if (findEntry(entries, "model", "models")) |mr| {
                switch (mr) {
                    .raw => {
                        if (!ufirst) try user.append(alloc, ',');
                        try user.appendSlice(alloc, "\"models\":");
                        try appendTomlJson(alloc, &user, mr);
                    },
                    else => {},
                }
            }
            try user.appendSlice(alloc, "}");
        },
        Store.ns_theme => {
            const pref = findString(entries, "preferences", "theme") orelse "system";
            try value.appendSlice(alloc, "{\"preference\":");
            try jsonx.appendJsonString(alloc, &value, pref);
            try value.appendSlice(alloc, "}");
            try user.appendSlice(alloc, "{");
            if (findEntry(entries, "preferences", "theme") != null) {
                try user.appendSlice(alloc, "\"preference\":");
                try jsonx.appendJsonString(alloc, &user, pref);
            }
            try user.appendSlice(alloc, "}");
        },
        Store.ns_locale => {
            const pref_opt = findString(entries, "preferences", "locale");
            try value.appendSlice(alloc, "{");
            if (pref_opt) |p| {
                try value.appendSlice(alloc, "\"preference\":");
                try jsonx.appendJsonString(alloc, &value, p);
            }
            try value.appendSlice(alloc, "}");
            try user.appendSlice(alloc, "{");
            if (pref_opt) |p| {
                try user.appendSlice(alloc, "\"preference\":");
                try jsonx.appendJsonString(alloc, &user, p);
            }
            try user.appendSlice(alloc, "}");
        },
        Store.ns_onboarding => {
            // Pre-acknowledged when the document carries no explicit version
            // (provisioned posture); a stored OLDER version means the user
            // has not seen the current notice yet.
            const acked = findString(entries, "preferences", "welcome_notice_version") orelse onboarding_notice_version;
            try value.appendSlice(alloc, "{\"welcomeNoticeVersion\":");
            try jsonx.appendJsonString(alloc, &value, acked);
            try value.appendSlice(alloc, "}");
            const raw_ack = findEntry(entries, "preferences", "welcome_notice_version");
            try user.appendSlice(alloc, "{");
            if (raw_ack != null) {
                try user.appendSlice(alloc, "\"welcomeNoticeVersion\":");
                try jsonx.appendJsonString(alloc, &user, acked);
            }
            try user.appendSlice(alloc, "}");
        },
        else => unreachable,
    }
    try out.appendSlice(alloc, value.items);
    // base layer omitted (no composition layer in v1); user layer always sent
    // (an empty object means "no overrides", which the mirror treats as such
    // via hasPath checks).
    try out.appendSlice(alloc, ",\"user\":");
    try out.appendSlice(alloc, user.items);
    try out.appendSlice(alloc, ",\"applies\":");
    try jsonx.appendJsonString(alloc, out, applies);
    try out.appendSlice(alloc, ",\"secrets\":[]");
    try out.appendSlice(alloc, ",\"revision\":");
    try jsonx.appendInt(alloc, out, @intCast(store.revisions[ns_id]));
    try out.append(alloc, '}');
}

/// Full settings.describe value: {"writable":true,"hasDocument":…,"namespaces":[…]}.
/// (anyerror: file IO underneath carries the wide std.Io sets; the router
/// maps everything onto the RPC vocabulary.)
pub fn describeValue(store: *Store, alloc: std.mem.Allocator, env: EnvFacts) anyerror![]u8 {
    store.mutex.lock();
    defer store.mutex.unlock();

    const doc = try store.readDoc(alloc);
    const entries: ?[]config.TomlEntry = if (doc) |d| try config.parseTomlFlat(alloc, d) else null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"writable\":true,\"hasDocument\":");
    try out.appendSlice(alloc, if (store.home.len > 0) "true" else "false");
    try out.appendSlice(alloc, ",\"namespaces\":[");
    const order = [_]usize{ Store.ns_agent, Store.ns_llm_deepseek, Store.ns_theme, Store.ns_locale, Store.ns_onboarding };
    for (order, 0..) |ns_id, i| {
        if (i > 0) try out.append(alloc, ',');
        try appendNamespaceView(alloc, &out, store, ns_id, entries, env);
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

pub const WriteError = error{
    UnknownNamespace,
    UnknownField,
    BadValueType,
    RevisionConflict,
    OutOfMemory,
    WriteFailed,
};

/// Validate one op against the field tables. Returns the target namespace id.
pub fn validateOp(
    ns: []const u8,
    field: []const u8,
    val: ?config.TomlValue,
) WriteError!usize {
    const ns_id: usize = if (std.mem.eql(u8, ns, "agent"))
        Store.ns_agent
    else if (std.mem.eql(u8, ns, "llm-deepseek"))
        Store.ns_llm_deepseek
    else if (std.mem.eql(u8, ns, "ui-theme"))
        Store.ns_theme
    else if (std.mem.eql(u8, ns, "locale"))
        Store.ns_locale
    else if (std.mem.eql(u8, ns, "ui-onboarding"))
        Store.ns_onboarding
    else
        return error.UnknownNamespace;

    switch (ns_id) {
        Store.ns_agent => {
            for (agent_fields) |f| {
                if (std.mem.eql(u8, f.name, field)) {
                    checkKind(f.kind, val) catch return error.BadValueType;
                    return ns_id;
                }
            }
            return error.UnknownField;
        },
        Store.ns_llm_deepseek => {
            if (std.mem.eql(u8, field, "baseURL")) {
                checkKind(.string, val) catch return error.BadValueType;
                return ns_id;
            }
            if (std.mem.eql(u8, field, "models")) {
                checkKind(.models_array, val) catch return error.BadValueType;
                return ns_id;
            }
            return error.UnknownField; // apiKeyEnv rides credentials.*, not mutate
        },
        Store.ns_theme, Store.ns_locale => {
            if (std.mem.eql(u8, field, "preference")) {
                checkKind(.string, val) catch return error.BadValueType;
                return ns_id;
            }
            return error.UnknownField;
        },
        Store.ns_onboarding => {
            if (std.mem.eql(u8, field, "welcomeNoticeVersion")) {
                checkKind(.string, val) catch return error.BadValueType;
                return ns_id;
            }
            return error.UnknownField;
        },
        else => return error.UnknownNamespace,
    }
}

fn checkKind(kind: FieldDef.Kind, val: ?config.TomlValue) !void {
    const v = val orelse return; // unset ops have no value
    switch (kind) {
        .string => if (v != .str) return error.BadValueType,
        .integer => if (v != .int) return error.BadValueType,
        .boolean => if (v != .boolean) return error.BadValueType,
        .models_array => if (v != .raw) return error.BadValueType,
    }
}

/// Translate one validated (ns, field, value?) into its TOML edit.
pub fn kvFor(ns_id: usize, field: []const u8, val: ?config.TomlValue) !config.ConfigKv {
    switch (ns_id) {
        Store.ns_agent => {
            for (agent_fields) |f| {
                if (std.mem.eql(u8, f.name, field)) {
                    return .{ .section = f.section, .key = f.key, .value = val };
                }
            }
        },
        Store.ns_llm_deepseek => {
            if (std.mem.eql(u8, field, "baseURL")) {
                return .{ .section = "model", .key = "endpoint", .value = val };
            }
            if (std.mem.eql(u8, field, "models")) {
                return .{ .section = "model", .key = "models", .value = val };
            }
        },
        Store.ns_theme => {
            if (std.mem.eql(u8, field, "preference")) {
                return .{ .section = "preferences", .key = "theme", .value = val };
            }
        },
        Store.ns_locale => {
            if (std.mem.eql(u8, field, "preference")) {
                return .{ .section = "preferences", .key = "locale", .value = val };
            }
        },
        Store.ns_onboarding => {
            if (std.mem.eql(u8, field, "welcomeNoticeVersion")) {
                return .{ .section = "preferences", .key = "welcome_notice_version", .value = val };
            }
        },
        else => {},
    }
    return error.UnknownField;
}

// ── write pipeline ──────────────────────────────────────────────────────────

/// Apply validated edits: read → parse → render → atomic write → bump
/// revisions → answer with the new view of `answer_ns`.
pub fn commitKvs(
    store: *Store,
    alloc: std.mem.Allocator,
    kvs: []const config.ConfigKv,
    ns_ids: []const usize,
    answer_ns: usize,
    expected_revision: ?i64,
    env: EnvFacts,
) anyerror![]u8 {
    store.mutex.lock();
    defer store.mutex.unlock();

    // Revision fence: checked against EVERY touched namespace (a write may
    // span namespaces only via separate calls today; single-ns in practice).
    for (ns_ids) |nid| {
        if (expected_revision) |want| {
            if (@as(i64, @intCast(store.revisions[nid])) != want) return error.RevisionConflict;
        }
    }

    const doc = try store.readDoc(alloc);
    const original: []const u8 = doc orelse "";
    const updated = config.applyConfigKvs(alloc, original, kvs) catch return error.OutOfMemory;
    store.writeDoc(updated) catch return error.WriteFailed;

    for (ns_ids) |nid| store.revisions[nid] += 1;

    const entries: ?[]config.TomlEntry = try config.parseTomlFlat(alloc, updated);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    appendNamespaceView(alloc, &out, store, answer_ns, entries, env) catch return error.OutOfMemory;
    return out.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

/// Parse a wire patch object `{field:value,…}` into validated edits. Values
/// arrive as raw JSON; convert to TomlValue equivalents (strings, ints,
/// booleans, verbatim arrays for models).
pub const Op = struct {
    field: []const u8,
    val: ?config.TomlValue,
};

/// Convert one raw JSON value slice into a TomlValue (arena-owned).
pub fn tomlFromJsonRaw(alloc: std.mem.Allocator, raw: []const u8) !config.TomlValue {
    if (jsonx.isString(raw)) {
        return .{ .str = jsonx.decodeString(alloc, raw[1 .. raw.len - 1]) catch return error.OutOfMemory };
    }
    if (raw.len > 0 and (raw[0] == '[' or raw[0] == '{')) {
        return .{ .raw = try alloc.dupe(u8, raw) };
    }
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "false")) {
        return .{ .boolean = raw[0] == 't' };
    }
    const i = std.fmt.parseInt(i64, raw, 10) catch return error.BadValueType;
    return .{ .int = i };
}

// ── tests (pure doc build/parse round-trips + validation) ───────────────────

const testing = std.testing;

// NOTE on schema-envelope testing: rehydration/validation of the four
// envelopes is exercised out-of-band against vendor/schemastery (node smoke);
// there is no JS bridge inside `zig build test`.

test "settings validateOp accepts known fields and rejects unknown" {
    try testing.expectEqual(@as(usize, Store.ns_agent), try validateOp("agent", "maxTurns", .{ .int = 8 }));
    try testing.expectEqual(@as(usize, Store.ns_agent), try validateOp("agent", "stream", null)); // unset
    try testing.expectError(error.UnknownField, validateOp("agent", "bogus", .{ .int = 1 }));
    try testing.expectError(error.BadValueType, validateOp("agent", "maxTurns", .{ .str = "x" }));
    try testing.expectError(error.UnknownNamespace, validateOp("nope", "x", null));
    try testing.expectEqual(@as(usize, Store.ns_llm_deepseek), try validateOp("llm-deepseek", "models", .{ .raw = "[{\"id\":\"m\"}]" }));
    try testing.expectError(error.UnknownField, validateOp("llm-deepseek", "apiKeyEnv", .{ .str = "X" }));
    try testing.expectEqual(@as(usize, Store.ns_theme), try validateOp("ui-theme", "preference", .{ .str = "dark" }));
}

test "settings describe builds full document with four namespaces" {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var store = Store{ .gpa = a, .home = "", .io = undefined };
    const doc =
        \\[model]
        \\endpoint = "https://gw.example.com/v1"
        \\api_key = "file-key"
        \\
        \\[agent]
        \\max_turns = 32
        \\
        \\[preferences]
        \\theme = "dark"
        \\
    ;
    const entries = try config.parseTomlFlat(a, doc);
    var out: std.ArrayList(u8) = .empty;
    try appendNamespaceView(a, &out, &store, Store.ns_agent, entries, .{});
    try testing.expect(std.mem.indexOf(u8, out.items, "\"ns\":\"agent\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"maxTurns\":32") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"provider\":\"deepseek\"") != null); // default fills
    try testing.expect(std.mem.indexOf(u8, out.items, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"revision\":0") != null);

    var out2: std.ArrayList(u8) = .empty;
    try appendNamespaceView(a, &out2, &store, Store.ns_llm_deepseek, entries, .{ .deepseek_api_key = "env-key" });
    try testing.expect(std.mem.indexOf(u8, out2.items, "\"baseURL\":\"https://gw.example.com/v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out2.items, "\"apiKeyEnv\":\"DEEPSEEK_API_KEY\"") != null);
    try testing.expect(std.mem.indexOf(u8, out2.items, "\"models\":[{\"id\":\"deepseek-v4-flash\"}]") != null);

    var out3: std.ArrayList(u8) = .empty;
    try appendNamespaceView(a, &out3, &store, Store.ns_theme, entries, .{});
    try testing.expect(std.mem.indexOf(u8, out3.items, "\"preference\":\"dark\"") != null);
    try testing.expect(std.mem.indexOf(u8, out3.items, "\"applies\":\"live\"") != null);

    var out4: std.ArrayList(u8) = .empty;
    try appendNamespaceView(a, &out4, &store, Store.ns_locale, entries, .{});
    try testing.expect(std.mem.indexOf(u8, out4.items, "\"value\":{}") != null); // no locale set → empty section
}

test "settings kvFor maps fields onto toml sections" {
    const kv = try kvFor(Store.ns_agent, "maxTurns", .{ .int = 16 });
    try testing.expectEqualStrings("agent", kv.section);
    try testing.expectEqualStrings("max_turns", kv.key);
    const kv2 = try kvFor(Store.ns_llm_deepseek, "baseURL", .{ .str = "https://x" });
    try testing.expectEqualStrings("endpoint", kv2.key);
    const kv3 = try kvFor(Store.ns_theme, "preference", .{ .str = "light" });
    try testing.expectEqualStrings("preferences", kv3.section);
    try testing.expectEqualStrings("theme", kv3.key);
}
