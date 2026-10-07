//! zharness configuration.
//!
//! Loads model/provider/api-key/workspace settings from environment and an
//! optional `~/.zharness/config.toml`. Kept minimal — the runtime resolves a
//! provider by id and an endpoint, then the model layer talks to it.
//!
//! Environment keys (dev.md §VI provider matrix):
//!   ZHARNESS_API_KEY   global harness credential — wins for EVERY provider
//!   DEEPSEEK_API_KEY   DeepSeek fallback when the global key is unset
//!   ANTHROPIC_API_KEY  Anthropic credential (swapped in by applyOverrides
//!                      when the anthropic/claude provider is selected,
//!                      unless the global key is present)
//!   OLLAMA_HOST        Ollama server host[:port][/path] or full URL;
//!                      becomes http://<host>/v1/chat/completions
//!   ZHARNESS_ENDPOINT  explicit endpoint override (testability/gateways)
//!   ZHARNESS_CWD       workspace override
//!
//! Endpoint precedence (highest last): --provider default <
//! ZHARNESS_ENDPOINT at load < explicit endpoint argument to applyOverrides.

const std = @import("std");
const providers = @import("model/provider.zig");
const ollama = @import("model/ollama.zig");

pub const ProviderProfile = providers.ProviderProfile;

/// Historical default model — used to detect "the user never picked a model"
/// so a provider switch can install that provider's own default.
pub const default_model = "deepseek-v4-flash";

pub const Config = struct {
    alloc: std.mem.Allocator,
    provider: []const u8 = "deepseek",
    model: []const u8 = default_model,
    api_key: []const u8 = "",
    endpoint: []const u8 = "https://api.deepseek.com/chat/completions",
    reasoning_effort: []const u8 = "medium",
    stream: bool = true,
    cwd: []const u8 = ".",
    max_turns: usize = 64,
    /// Context-compaction character budget for the whole transcript. When the
    /// summed `content` lengths reach this, older messages collapse into one
    /// summary (see agent/compaction.zig). 0 disables compaction.
    compact_threshold: usize = 480_000,
    /// Verbatim messages compaction keeps at the transcript tail (>= 1 keeps
    /// the in-flight user turn intact).
    compact_keep_recent: usize = 16,
    sandbox_mode: SandboxMode = .process,
    /// Approval policy for permission-gated tool calls (upstream
    /// approval/policy): `ask` prompts, `never` auto-rejects (fail-closed).
    approval_mode: ApprovalMode = .ask,

    /// Anthropic credential from ANTHROPIC_API_KEY ("" when absent).
    anthropic_key: []const u8 = "",
    /// Raw OLLAMA_HOST value ("" when absent); consumed on provider switch.
    ollama_host: []const u8 = "",
    /// True when the active api_key came from ZHARNESS_API_KEY (global).
    api_key_is_global: bool = false,

    pub const SandboxMode = enum {
        native,
        process,
        none,

        pub fn fromString(s: []const u8) SandboxMode {
            if (std.mem.eql(u8, s, "native")) return .native;
            if (std.mem.eql(u8, s, "none")) return .none;
            return .process;
        }
        pub fn asStr(self: SandboxMode) []const u8 {
            return switch (self) {
                .native => "native",
                .process => "process",
                .none => "none",
            };
        }
    };

    /// Approval policy for permission-gated tool calls (upstream
    /// approval/policy): `ask` prompts, `never` auto-rejects (fail-closed).
    pub const ApprovalMode = enum {
        ask,
        never,

        pub fn fromString(s: []const u8) ?ApprovalMode {
            if (std.mem.eql(u8, s, "ask")) return .ask;
            if (std.mem.eql(u8, s, "never")) return .never;
            return null;
        }
        pub fn asStr(self: ApprovalMode) []const u8 {
            return switch (self) {
                .ask => "ask",
                .never => "never",
            };
        }
    };

    pub fn deinit(self: *Config) void {
        self.alloc.free(self.provider);
        self.alloc.free(self.model);
        self.alloc.free(self.api_key);
        self.alloc.free(self.endpoint);
        self.alloc.free(self.reasoning_effort);
        self.alloc.free(self.cwd);
        self.alloc.free(self.anthropic_key);
        self.alloc.free(self.ollama_host);
    }

    /// Apply CLI overrides (e.g. --model, --provider, --no-stream). Existing
    /// three-argument callers compile unchanged; see `applyOverridesFull`
    /// for the per-provider --endpoint support.
    pub fn applyOverrides(
        self: *Config,
        model: ?[]const u8,
        provider: ?[]const u8,
        no_stream: bool,
    ) !void {
        return self.applyOverridesFull(.{ .model = model, .provider = provider, .no_stream = no_stream });
    }

    pub const Overrides = struct {
        model: ?[]const u8 = null,
        provider: ?[]const u8 = null,
        no_stream: bool = false,
        /// Per-provider endpoint override (a future --endpoint flag).
        endpoint: ?[]const u8 = null,
    };

    /// Full override application.
    ///
    /// Precedence inside this function: an explicit endpoint beats the
    /// provider default; the provider default beats anything loaded from
    /// ZHARNESS_ENDPOINT (historical behaviour, documented at load()).
    pub fn applyOverridesFull(self: *Config, o: Overrides) !void {
        const a = self.alloc;
        if (o.model) |mo| {
            a.free(self.model);
            self.model = try a.dupe(u8, mo);
        }
        if (o.provider) |p| {
            a.free(self.provider);
            self.provider = try a.dupe(u8, p);

            // Default endpoint for the named provider. Known profiles may
            // refine it (Ollama host override); unknown spellings keep the
            // legacy permissive table (e.g. "openrouter") untouched.
            var ep: []const u8 = providerEndpoint(p);
            var owned_ep: ?[]u8 = null;
            defer if (owned_ep) |own| a.free(own);

            if (providers.Provider.fromString(p)) |prov| {
                const prof = providers.profile(prov);
                ep = prof.endpoint;
                switch (prov) {
                    .ollama => {
                        if (self.ollama_host.len > 0) {
                            owned_ep = try ollama.endpointFromHost(a, self.ollama_host);
                            ep = owned_ep.?;
                        }
                        // Ollama needs no credentials, but callers gate on a
                        // non-empty key before building a client; use an
                        // inert placeholder (no header is emitted anyway).
                        if (self.api_key.len == 0) {
                            a.free(self.api_key);
                            self.api_key = try a.dupe(u8, "ollama-local");
                        }
                    },
                    .anthropic => {
                        // Per-provider key wins unless the GLOBAL harness key
                        // was set explicitly (ZHARNESS_API_KEY precedence).
                        if (self.anthropic_key.len > 0 and
                            !(self.api_key_is_global and self.api_key.len > 0))
                        {
                            a.free(self.api_key);
                            self.api_key = try a.dupe(u8, self.anthropic_key);
                        }
                    },
                    else => {},
                }
                // First switch away from a stock model installs the
                // provider's own default (a user-pinned --model always wins
                // because it lands in the branch above).
                if (o.model == null and std.mem.eql(u8, self.model, default_model)) {
                    a.free(self.model);
                    self.model = try a.dupe(u8, prof.default_model);
                }
            }

            a.free(self.endpoint);
            self.endpoint = try a.dupe(u8, ep);
        }
        if (o.endpoint) |e| {
            a.free(self.endpoint);
            self.endpoint = try a.dupe(u8, e);
        }
        if (o.no_stream) self.stream = false;
    }

    /// Resolved profile for the CURRENT provider string with this config's
    /// endpoint layered on top. Null for legacy permissive spellings the
    /// matrix does not know (e.g. "openrouter") — those stay plain
    /// OpenAI-style clients. This plus ChatClient.initProvider is the whole
    /// provider-selection story:
    ///
    ///   var client = if (cfg.resolvedProfile()) |prof|
    ///       model.ChatClient.initProvider(alloc, io, prof, cfg.model, cfg.api_key)
    ///   else
    ///       model.ChatClient.init(alloc, io, cfg.endpoint, cfg.model, cfg.api_key);
    pub fn resolvedProfile(self: *const Config) ?ProviderProfile {
        const p = providers.Provider.fromString(self.provider) orelse return null;
        var prof = providers.profile(p);
        prof.endpoint = self.endpoint; // explicit/env override already applied
        return prof;
    }
};

/// Injectable environment snapshot so config behaviour is testable offline.
/// load() fills it from libc getenv; tests pass literals.
pub const EnvSnapshot = struct {
    zharness_api_key: ?[]const u8 = null,
    deepseek_api_key: ?[]const u8 = null,
    anthropic_api_key: ?[]const u8 = null,
    ollama_host: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    /// Contents of ~/.zharness/config.toml (the file layer, applied after
    /// defaults and BEFORE the env overrides above — env beats file).
    config_toml: ?[]const u8 = null,
};

fn optSpan(p: ?[*:0]const u8) ?[]const u8 {
    const ptr = p orelse return null;
    const s = std.mem.span(ptr);
    return if (s.len > 0) s else null;
}

/// Resolve credentials and defaults. API key precedence:
///   1. ZHARNESS_API_KEY / DEEPSEEK_API_KEY env (global first)
///   2. ~/.zharness/config.toml [model] api_key (not read yet)
/// Per-provider keys land in dedicated fields and are swapped in by
/// applyOverrides when their provider is selected.
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fread(buf: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fseek(f: *anyopaque, off: c_long, whence: c_int) c_int;
extern "c" fn ftell(f: *anyopaque) c_long;
extern "c" fn fclose(f: *anyopaque) c_int;

/// Read a whole file via libc (no std.Io needed at config-load time).
/// Returns null on any failure — the file layer is strictly best-effort.
fn readFileLibc(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const path_z = alloc.allocSentinel(u8, path.len, 0) catch return null;
    @memcpy(path_z, path);
    defer alloc.free(path_z);
    const f = fopen(path_z.ptr, "rb") orelse return null;
    defer _ = fclose(f);
    if (fseek(f, 0, 2) != 0) return null; // SEEK_END
    const size = ftell(f);
    if (size < 0 or size > 4 * 1024 * 1024) return null;
    if (fseek(f, 0, 0) != 0) return null; // SEEK_SET
    const buf = alloc.alloc(u8, @intCast(size)) catch return null;
    errdefer alloc.free(buf);
    const got = fread(buf.ptr, 1, @intCast(size), f);
    if (got != @as(usize, @intCast(size))) return null;
    return buf;
}

pub fn load(alloc: std.mem.Allocator) !Config {
    // File layer: ~/.zharness/config.toml (best-effort — absent/corrupt
    // documents yield the defaults instead of failing the boot). Read via
    // libc directly: load() runs before any std.Io exists in CLI paths.
    var toml_text: ?[]const u8 = null;
    const home = optSpan(std.c.getenv("HOME"));
    if (home) |h| {
        const path = std.fmt.allocPrint(alloc, "{s}/.zharness/config.toml", .{h}) catch null;
        if (path) |pth| {
            defer alloc.free(pth);
            toml_text = readFileLibc(alloc, pth);
        }
    }
    defer if (toml_text) |t| alloc.free(t);

    return loadFromSnapshot(alloc, .{
        .zharness_api_key = optSpan(std.c.getenv("ZHARNESS_API_KEY")),
        .deepseek_api_key = optSpan(std.c.getenv("DEEPSEEK_API_KEY")),
        .anthropic_api_key = optSpan(std.c.getenv("ANTHROPIC_API_KEY")),
        .ollama_host = optSpan(std.c.getenv("OLLAMA_HOST")),
        .endpoint = optSpan(std.c.getenv("ZHARNESS_ENDPOINT")),
        .cwd = optSpan(std.c.getenv("ZHARNESS_CWD")),
        .config_toml = toml_text,
    });
}

/// Pure core of load(): same result, environment supplied by the caller.
pub fn loadFromSnapshot(alloc: std.mem.Allocator, env: EnvSnapshot) !Config {
    var cfg = Config{ .alloc = alloc };

    // Provider defaults.
    cfg.provider = try alloc.dupe(u8, "deepseek");
    cfg.model = try alloc.dupe(u8, default_model);
    cfg.endpoint = try alloc.dupe(u8, "https://api.deepseek.com/chat/completions");
    cfg.reasoning_effort = try alloc.dupe(u8, "medium");
    cfg.cwd = try alloc.dupe(u8, ".");

    // API key from the snapshot (dupe immediately; snapshots may be stack
    // literals in tests).
    if (env.zharness_api_key) |k| {
        cfg.api_key = try alloc.dupe(u8, k);
        cfg.api_key_is_global = true;
    } else if (env.deepseek_api_key) |k| {
        cfg.api_key = try alloc.dupe(u8, k);
    } else {
        cfg.api_key = try alloc.dupe(u8, "");
    }
    cfg.anthropic_key = try alloc.dupe(u8, env.anthropic_api_key orelse "");
    cfg.ollama_host = try alloc.dupe(u8, env.ollama_host orelse "");

    // Workspace cwd: honor ZHARNESS_CWD, else process cwd.
    if (env.cwd) |cwd| {
        alloc.free(cfg.cwd);
        cfg.cwd = try alloc.dupe(u8, cwd);
    }

    // Endpoint override (testability + self-hosted gateways): applied after
    // provider defaults so an explicit ZHARNESS_ENDPOINT always wins there.
    // An explicit --provider later still resets it (documented precedence).
    if (env.endpoint) |ep| {
        alloc.free(cfg.endpoint);
        cfg.endpoint = try alloc.dupe(u8, ep);
    }

    // ── File layer: ~/.zharness/config.toml (env beats file per key) ──────
    if (env.config_toml) |doc| {
        if (parseTomlFlat(alloc, doc) catch null) |es| {
            defer alloc.free(es);
            const env_key = env.zharness_api_key != null or env.deepseek_api_key != null;
            const env_endpoint = env.endpoint != null;
            for (es) |e| {
                defer if (e.val == .str) alloc.free(e.val.str);
                const in_model = std.mem.eql(u8, e.section, "model");
                const in_agent = std.mem.eql(u8, e.section, "agent");
                const in_general = std.mem.eql(u8, e.section, "general");
                // NOTE: e.val.str is freed at the top of the next iteration
                // (defer above), so every string consumer dupes BEFORE any
                // early continue.
                if (in_model and std.mem.eql(u8, e.key, "provider")) {
                    const v = try alloc.dupe(u8, e.val.str);
                    alloc.free(cfg.provider);
                    cfg.provider = v;
                } else if (in_model and std.mem.eql(u8, e.key, "model")) {
                    const v = try alloc.dupe(u8, e.val.str);
                    alloc.free(cfg.model);
                    cfg.model = v;
                } else if (in_model and std.mem.eql(u8, e.key, "api_key")) {
                    if (!env_key) {
                        const v = try alloc.dupe(u8, e.val.str);
                        alloc.free(cfg.api_key);
                        cfg.api_key = v;
                        cfg.api_key_is_global = false;
                    }
                } else if (in_model and std.mem.eql(u8, e.key, "endpoint")) {
                    if (!env_endpoint) {
                        const v = try alloc.dupe(u8, e.val.str);
                        alloc.free(cfg.endpoint);
                        cfg.endpoint = v;
                    }
                } else if (in_agent and std.mem.eql(u8, e.key, "max_turns")) {
                    if (e.val.int > 0) cfg.max_turns = @intCast(e.val.int);
                } else if (in_agent and std.mem.eql(u8, e.key, "compact_threshold")) {
                    if (e.val.int >= 0) cfg.compact_threshold = @intCast(e.val.int);
                } else if (in_agent and std.mem.eql(u8, e.key, "compact_keep_recent")) {
                    if (e.val.int > 0) cfg.compact_keep_recent = @intCast(e.val.int);
                } else if (in_agent and std.mem.eql(u8, e.key, "reasoning_effort")) {
                    const v = try alloc.dupe(u8, e.val.str);
                    alloc.free(cfg.reasoning_effort);
                    cfg.reasoning_effort = v;
                } else if (in_agent and std.mem.eql(u8, e.key, "stream")) {
                    cfg.stream = e.val.boolean;
                } else if (in_general and std.mem.eql(u8, e.key, "sandbox_mode")) {
                    if (e.val == .str) cfg.sandbox_mode = Config.SandboxMode.fromString(e.val.str);
                } else if (in_general and std.mem.eql(u8, e.key, "approval_policy")) {
                    if (e.val == .str) {
                        if (Config.ApprovalMode.fromString(e.val.str)) |m| cfg.approval_mode = m;
                    }
                }
                // [preferences] * and unknown keys: owned by the settings
                // store / deliberately ignored by the runtime.
            }
        }
    }

    return cfg;
}

fn providerEndpoint(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "openai")) return "https://api.openai.com/v1/chat/completions";
    if (std.mem.eql(u8, provider, "ollama")) return "http://localhost:11434/v1/chat/completions";
    if (std.mem.eql(u8, provider, "openrouter")) return "https://openrouter.ai/api/v1/chat/completions";
    return "https://api.deepseek.com/chat/completions";
}

// ── minimal flat TOML (the ~/.zharness/config.toml document) ────────────────
//
// The document is a flat section/key table: `[section]` headers plus
// `key = value` lines. Values: basic strings ("…"), literal strings ('…'),
// integers, booleans, and verbatim raw values starting with '[' or '{'
// (JSON-compatible inline arrays/tables — written back byte-exact so no
// array parser is needed). Comments and unknown sections/keys survive a
// read-modify-write round trip; inline comments AFTER an updated value do
// not (documented limitation).

/// One TOML value in the supported subset.
pub const TomlValue = union(enum) {
    /// Decoded contents of a quoted string.
    str: []const u8,
    int: i64,
    boolean: bool,
    /// Verbatim slice of an inline array/table ('['- or '{'-prefixed).
    raw: []const u8,

    pub fn render(self: TomlValue, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        switch (self) {
            .str => |s| try appendQuotedToml(alloc, out, s),
            .int => |i| try out.print(alloc, "{d}", .{i}),
            .boolean => |b| try out.appendSlice(alloc, if (b) "true" else "false"),
            .raw => |r| try out.appendSlice(alloc, r),
        }
    }
};

/// One parsed `key = value` row with its owning section.
pub const TomlEntry = struct {
    section: []const u8,
    key: []const u8,
    val: TomlValue,
};

pub const TomlError = error{OutOfMemory};

/// Parse the supported TOML subset into ordered entries. Malformed lines are
/// skipped silently (a hand-edited document must not brick the GUI): the
/// reader accepts strictly more than the writer emits.
pub fn parseTomlFlat(alloc: std.mem.Allocator, text: []const u8) TomlError!?[]TomlEntry {
    var entries: std.ArrayList(TomlEntry) = .empty;
    errdefer entries.deinit(alloc);
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trimWs(raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            section = line[1..end];
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trimWs(line[0..eq]);
        if (key.len == 0) continue;
        var rest = trimWs(line[eq + 1 ..]);
        // Strip a trailing unquoted comment.
        rest = stripComment(rest);
        const val = parseTomlValue(alloc, rest) catch continue;
        try entries.append(alloc, .{ .section = section, .key = key, .val = val });
    }
    if (entries.items.len == 0) return null;
    return try entries.toOwnedSlice(alloc);
}

/// Free an entry list returned by parseTomlFlat.
pub fn freeTomlEntries(alloc: std.mem.Allocator, entries: ?[]TomlEntry) void {
    const list = entries orelse return;
    for (list) |e| {
        switch (e.val) {
            .str => |s| alloc.free(s),
            else => {},
        }
    }
    alloc.free(list);
}

fn parseTomlValue(alloc: std.mem.Allocator, v: []const u8) !TomlValue {
    if (v.len == 0) return error.BadValue;
    if (v[0] == '"') {
        const s = try decodeBasicString(alloc, v);
        return .{ .str = s };
    }
    if (v[0] == '\'') {
        const end = std.mem.indexOfScalarPos(u8, v, 1, '\'') orelse return error.BadValue;
        return .{ .str = try alloc.dupe(u8, v[1..end]) };
    }
    if (v[0] == '[' or v[0] == '{') return .{ .raw = try alloc.dupe(u8, v) };
    if (std.mem.eql(u8, v, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, v, "false")) return .{ .boolean = false };
    return .{ .int = std.fmt.parseInt(i64, v, 10) catch return error.BadValue };
}

/// Decode a double-quoted TOML string with escapes into `alloc`.
fn decodeBasicString(alloc: std.mem.Allocator, v: []const u8) ![]u8 {
    // v starts with '"'; find the closing unescaped quote.
    var i: usize = 1;
    while (i < v.len) : (i += 1) {
        if (v[i] == '\\') {
            i += 1;
            continue;
        }
        if (v[i] == '"') break;
    }
    if (i >= v.len) return error.BadValue;
    const inner = v[1..i];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var j: usize = 0;
    while (j < inner.len) : (j += 1) {
        if (inner[j] != '\\' or j + 1 >= inner.len) {
            try out.append(alloc, inner[j]);
            continue;
        }
        j += 1;
        const c = inner[j];
        const mapped: ?u8 = switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            else => null,
        };
        if (mapped) |m| try out.append(alloc, m) else {
            try out.append(alloc, '\\');
            try out.append(alloc, c);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Render a string as a double-quoted TOML value with escapes.
fn appendQuotedToml(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            else => try out.append(alloc, c),
        }
    }
    try out.append(alloc, '"');
}

/// One read-modify-write edit: set `key` in `section`, or remove it when
/// `value` is null.
pub const ConfigKv = struct {
    section: []const u8,
    key: []const u8,
    /// Null removes the key's line from its section.
    value: ?TomlValue,
};

/// Apply ordered edits to a TOML document, preserving everything this module
/// does not touch (comments, unknown keys, unknown sections, ordering).
/// Known keys update in place; new known keys join their section block
/// (appended after the section's last line); missing sections are appended at
/// EOF with one header per section. Returns the new document text.
pub fn applyConfigKvs(
    alloc: std.mem.Allocator,
    original: []const u8,
    kvs: []const ConfigKv,
) TomlError![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, original, '\n');
    while (it.next()) |l| try lines.append(alloc, l);
    // A document ending in '\n' yields a phantom trailing "" from the split;
    // dropping it keeps byte-exact round trips.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    //   - replace/remove: index of the key's line;
    //   - insert: index the new line goes BEFORE (section end or EOF).
    const Kind = enum { replace, remove, insert };
    const Resolved = struct { kind: Kind, line_idx: usize, kv_idx: usize };
    var resolved: std.ArrayList(Resolved) = .empty;
    defer resolved.deinit(alloc);

    outer: for (kvs, 0..) |kv, kv_idx| {
        // Insert point when the section exists but lacks the key: after its
        // last line. Starts at the section header's next line so an empty
        // existing section still inserts correctly.
        var insert_at: ?usize = null;
        var current_section: []const u8 = "";
        for (lines.items, 0..) |raw_line, li| {
            const line = trimWs(raw_line);
            if (line.len > 0 and line[0] == '[') {
                if (std.mem.eql(u8, current_section, kv.section)) {
                    // Ran off the end of the target section.
                    break;
                }
                const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
                current_section = line[1..end];
                if (std.mem.eql(u8, current_section, kv.section)) insert_at = li + 1;
                continue;
            }
            if (!std.mem.eql(u8, current_section, kv.section)) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                if (line.len > 0) insert_at = li + 1; // unknown row type still extends the block
                continue;
            };
            const key = trimWs(line[0..eq]);
            if (kv.key.len == key.len and std.mem.eql(u8, kv.key, key)) {
                try resolved.append(alloc, .{
                    .kind = if (kv.value == null) .remove else .replace,
                    .line_idx = li,
                    .kv_idx = kv_idx,
                });
                continue :outer;
            }
            insert_at = li + 1;
        }
        if (kv.value == null) continue; // removing an absent key is a no-op
        try resolved.append(alloc, .{ .kind = .insert, .line_idx = insert_at orelse lines.items.len, .kv_idx = kv_idx });
    }

    // Emit in one pass over the original lines: replacements/removals in
    // place, pending inserts flushed when the walk reaches their line.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // Inserts sorted ASCENDING by line index; EOF tail handled after the walk.
    std.mem.sort(Resolved, resolved.items, {}, struct {
        fn less(_: void, x: Resolved, y: Resolved) bool {
            if (x.line_idx != y.line_idx) return x.line_idx < y.line_idx;
            // Equal index: an insert lands before the line's replace/remove.
            return x.kind == .insert and y.kind != .insert;
        }
    }.less);
    var inserts_only: std.ArrayList(Resolved) = .empty;
    defer inserts_only.deinit(alloc);
    for (resolved.items) |r| {
        if (r.kind == .insert) try inserts_only.append(alloc, r);
    }

    var headers_written: std.ArrayList([]const u8) = .empty;
    defer headers_written.deinit(alloc);

    var pos: usize = 0; // cursor into inserts_only
    var li: usize = 0;
    while (li < lines.items.len) : (li += 1) {
        while (pos < inserts_only.items.len and inserts_only.items[pos].line_idx == li) : (pos += 1) {
            try emitInsert(alloc, &out, &headers_written, kvs[inserts_only.items[pos].kv_idx], lines.items);
        }
        var replaced = false;
        for (resolved.items) |r| {
            if (r.kind != .insert and r.line_idx == li) {
                if (r.kind == .replace) try renderKvLine(alloc, &out, kvs[r.kv_idx]);
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            try out.appendSlice(alloc, lines.items[li]);
            try out.append(alloc, '\n');
        }
    }
    while (pos < inserts_only.items.len) : (pos += 1) {
        try emitInsert(alloc, &out, &headers_written, kvs[inserts_only.items[pos].kv_idx], lines.items);
    }
    return out.toOwnedSlice(alloc);
}

/// Render one insert action: a fresh section header first when the original
/// document never declared it (once per section), then the key/value line.
fn emitInsert(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    headers_written: *std.ArrayList([]const u8),
    kv: ConfigKv,
    original_lines: [][]const u8,
) !void {
    if (!sectionExists(original_lines, kv.section)) {
        var seen = false;
        for (headers_written.items) |h| {
            if (std.mem.eql(u8, h, kv.section)) seen = true;
        }
        if (!seen) {
            try out.append(alloc, '\n');
            try out.append(alloc, '[');
            try out.appendSlice(alloc, kv.section);
            try out.appendSlice(alloc, "]\n");
            try headers_written.append(alloc, kv.section);
        }
    }
    try renderKvLine(alloc, out, kv);
}

fn sectionExists(lines: [][]const u8, section: []const u8) bool {
    for (lines) |raw_line| {
        const line = trimWs(raw_line);
        if (line.len == 0 or line[0] != '[') continue;
        const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        if (std.mem.eql(u8, line[1..end], section)) return true;
    }
    return false;
}

fn renderKvLine(alloc: std.mem.Allocator, out: *std.ArrayList(u8), kv: ConfigKv) !void {
    try out.appendSlice(alloc, kv.key);
    try out.appendSlice(alloc, " = ");
    try kv.value.?.render(alloc, out);
    try out.append(alloc, '\n');
}

fn trimWs(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// Strip a trailing ` #comment` from a value slice (quoted-string aware).
fn stripComment(v: []const u8) []const u8 {
    var in_str: u8 = 0;
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        const c = v[i];
        if (in_str != 0) {
            if (c == '\\' and in_str == '"') i += 1 else if (c == in_str) in_str = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
        } else if (c == '#') {
            return trimWs(v[0..i]);
        }
    }
    return trimWs(v);
}

// ── TOML round-trip tests ───────────────────────────────────────────────────

test "toml parse flat subset" {
    const alloc = std.testing.allocator;
    const doc =
        \\# top comment
        \\[model]
        \\provider = "deepseek"
        \\model = "deepseek-v4-flash" # trailing comment
        \\api_key = "sk-\"q\\"
        \\
        \\[agent]
        \\max_turns = 64
        \\stream = true
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const entries = (try parseTomlFlat(arena.allocator(), doc)).?;
    try std.testing.expectEqual(@as(usize, 5), entries.len);
    try std.testing.expectEqualStrings("model", entries[0].section);
    try std.testing.expectEqualStrings("deepseek", entries[0].val.str);
    try std.testing.expectEqualStrings("sk-\"q\\", entries[2].val.str);
    try std.testing.expectEqual(@as(i64, 64), entries[3].val.int);
    try std.testing.expectEqual(true, entries[4].val.boolean);
}

test "toml apply kvs preserves unknown content" {
    const alloc = std.testing.allocator;
    const doc =
        \\# header comment
        \\[model]
        \\provider = "deepseek"
        \\custom_thing = "keep me"
        \\
        \\[agent]
        \\stream = true
        \\
        \\[unknown_section]
        \\x = 1
        \\
    ;
    const updated = try applyConfigKvs(alloc, doc, &.{
        .{ .section = "model", .key = "provider", .value = .{ .str = "anthropic" } },
        .{ .section = "agent", .key = "max_turns", .value = .{ .int = 32 } },
        .{ .section = "preferences", .key = "theme", .value = .{ .str = "dark" } },
        .{ .section = "agent", .key = "stream", .value = null },
    });
    defer alloc.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "# header comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "provider = \"anthropic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "custom_thing = \"keep me\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[unknown_section]") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "max_turns = 32") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[preferences]\ntheme = \"dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "stream") == null); // removed

    // Round trip: parsing the rewritten document yields the same facts.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const entries = (try parseTomlFlat(arena.allocator(), updated)).?;
    var seen_provider: ?[]const u8 = null;
    for (entries) |e| {
        if (std.mem.eql(u8, e.key, "provider")) seen_provider = e.val.str;
        if (std.mem.eql(u8, e.key, "max_turns")) try std.testing.expectEqual(@as(i64, 32), e.val.int);
    }
    try std.testing.expectEqualStrings("anthropic", seen_provider.?);
}

test "toml apply kvs into empty document creates sections" {
    const alloc = std.testing.allocator;
    const updated = try applyConfigKvs(alloc, "", &.{
        .{ .section = "model", .key = "model", .value = .{ .str = "m1" } },
        .{ .section = "preferences", .key = "locale", .value = .{ .str = "en" } },
    });
    defer alloc.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[model]\nmodel = \"m1\"\n\n[preferences]\nlocale = \"en\"") != null);
}

test "toml raw json value round trips verbatim" {
    const alloc = std.testing.allocator;
    const doc = "[model]\nmodels = [{\"id\":\"m1\",\"contextWindow\":128}]\n";
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = (try parseTomlFlat(a, doc)).?;
    try std.testing.expectEqualStrings("[{\"id\":\"m1\",\"contextWindow\":128}]", entries[0].val.raw);
    const updated = try applyConfigKvs(a, doc, &.{});
    try std.testing.expectEqualStrings(doc, updated);
}
