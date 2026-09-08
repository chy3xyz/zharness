//! Native plugin loader — Discover → Load → Validate → Register → Unload
//! (dev.md §XXV–XXVI), built on capi.zig (contract) and ffi.zig (dlopen).
//!
//! Division of labor:
//!   - PURE, dlopen-free helpers live here as plain functions:
//!       parseManifest / validateManifest / abiVersionOk / hostToolName.
//!     They are unit-tested without touching the dynamic loader.
//!   - `PluginRegistry` owns loaded `ffi.LoadedPlugin`s and the host-visible
//!     tool table. Every failure — bad suffix, dlopen error, missing symbol,
//!     wrong ABI version, malformed manifest — is recorded in `report` and
//!     the offending plugin is skipped. The loader NEVER crashes the host
//!     and NEVER leaks: failed loads are unloaded immediately, successful
//!     ones are unloaded by `deinit`.
//!
//! Tool namespace: a plugin-local tool becomes host tool
//!   `p_<plugin>_<tool>` (sanitized to [a-z0-9_]) so plugin tools can never
//! collide with builtin names or with the MCP `mcp_*` namespace.

const std = @import("std");
const capi = @import("capi.zig");
const ffi = @import("ffi.zig");
const registry = @import("../tool/registry.zig");

// ─────────────────────────────────────────────────────────────────────────
// Pure manifest model + parsing (no dlopen, no I/O)
// ─────────────────────────────────────────────────────────────────────────

pub const Kind = enum {
    tool,

    pub fn fromString(s: []const u8) ?Kind {
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return null;
    }

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .tool => "tool",
        };
    }
};

/// One tool exported by a plugin. `schema` is the OpenAI-style parameters
/// object kept as raw JSON text (registry.ToolDefinition.parameters_json).
pub const ToolSpec = struct {
    name: []u8,
    description: []u8,
    schema: []u8,
};

/// Parsed manifest. All strings are owned; free with `deinit`.
pub const Manifest = struct {
    alloc: std.mem.Allocator,
    name: []u8,
    version: []u8,
    kind: Kind,
    tools: []ToolSpec,

    pub fn deinit(self: *Manifest) void {
        self.alloc.free(self.name);
        self.alloc.free(self.version);
        for (self.tools) |t| {
            self.alloc.free(t.name);
            self.alloc.free(t.description);
            self.alloc.free(t.schema);
        }
        self.alloc.free(self.tools);
    }
};

pub const ParseError = error{
    InvalidJson,
    MissingField,
    InvalidField,
    UnsupportedKind,
    OutOfMemory,
};

/// Validation runs on an already-parsed manifest; granular errors make test
/// failures readable and feed the skip-report reasons.
pub const ValidateError = error{
    InvalidName,
    InvalidVersion,
    UnsupportedKind,
    NoTools,
    InvalidToolEntry,
};

/// True when the plugin reports exactly the ABI this host speaks.
pub fn abiVersionOk(v: u32) bool {
    return v == capi.ABI_VERSION;
}

// ── tiny hand-rolled JSON scanner (model.zig style, string-aware) ────────

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn skipWs(src: []const u8, i: *usize) void {
    while (i.* < src.len and isWs(src[i.*])) : (i.* += 1) {}
}

/// Index of the delimiter matching `open` at `start`, skipping JSON strings
/// (escape-aware). Returns the position of the matching close char.
fn matchDelim(src: []const u8, start: usize, open: u8, close: u8) ?usize {
    if (start >= src.len or src[start] != open) return null;
    var depth: i32 = 0;
    var i = start;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '"') {
            i += 1;
            while (i < src.len and src[i] != '"') : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            continue;
        }
        if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Advance `i` past one JSON value of any type (used for unknown keys).
fn skipValue(src: []const u8, i: *usize) ParseError!void {
    if (i.* >= src.len) return error.InvalidJson;
    switch (src[i.*]) {
        '{' => {
            const end = matchDelim(src, i.*, '{', '}') orelse return error.InvalidJson;
            i.* = end + 1;
        },
        '[' => {
            const end = matchDelim(src, i.*, '[', ']') orelse return error.InvalidJson;
            i.* = end + 1;
        },
        '"' => {
            i.* += 1;
            while (i.* < src.len and src[i.*] != '"') : (i.* += 1) {
                if (src[i.*] == '\\') i.* += 1;
            }
            if (i.* >= src.len) return error.InvalidJson;
            i.* += 1; // closing quote
        },
        else => {
            // number / true / false / null — scan to a structural char
            while (i.* < src.len and !isWs(src[i.*]) and src[i.*] != ',' and src[i.*] != '}' and src[i.*] != ']') : (i.* += 1) {}
        },
    }
    if (i.* > src.len) return error.InvalidJson;
}

fn appendHex4(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cp: u21) ParseError!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.appendSlice(alloc, "\u{FFFD}");
        return;
    };
    try out.appendSlice(alloc, buf[0..n]);
}

/// Decode a JSON string starting at `src[i.*] == '"'`; advances past the
/// closing quote. Supports standard escapes incl. \uXXXX (with surrogate
/// pairs; lone surrogates become U+FFFD).
fn parseJsonString(alloc: std.mem.Allocator, src: []const u8, i: *usize) ParseError![]u8 {
    if (i.* >= src.len or src[i.*] != '"') return error.InvalidJson;
    i.* += 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    while (i.* < src.len) {
        const c = src[i.*];
        if (c == '"') {
            i.* += 1;
            return out.toOwnedSlice(alloc);
        }
        if (c != '\\') {
            try out.append(alloc, c);
            i.* += 1;
            continue;
        }
        i.* += 1;
        if (i.* >= src.len) break;
        const esc = src[i.*];
        i.* += 1;
        switch (esc) {
            '"' => try out.append(alloc, '"'),
            '\\' => try out.append(alloc, '\\'),
            '/' => try out.append(alloc, '/'),
            'b' => try out.append(alloc, 0x08),
            'f' => try out.append(alloc, 0x0C),
            'n' => try out.append(alloc, '\n'),
            'r' => try out.append(alloc, '\r'),
            't' => try out.append(alloc, '\t'),
            'u' => {
                if (i.* + 4 > src.len) return error.InvalidJson;
                const hi = std.fmt.parseInt(u16, src[i.* .. i.* + 4], 16) catch return error.InvalidJson;
                i.* += 4;
                var cp: u21 = hi;
                if (hi >= 0xD800 and hi <= 0xDBFF) {
                    // high surrogate — expect \uDC00..\uDFFF next
                    if (i.* + 6 <= src.len and src[i.*] == '\\' and src[i.* + 1] == 'u') {
                        const lo = std.fmt.parseInt(u16, src[i.* + 2 .. i.* + 6], 16) catch return error.InvalidJson;
                        if (lo >= 0xDC00 and lo <= 0xDFFF) {
                            cp = 0x10000 + (@as(u21, hi) - 0xD800) * 0x400 + (@as(u21, lo) - 0xDC00);
                            i.* += 6;
                        } else {
                            cp = 0xFFFD;
                        }
                    } else {
                        cp = 0xFFFD;
                    }
                } else if (hi >= 0xDC00 and hi <= 0xDFFF) {
                    cp = 0xFFFD; // lone low surrogate
                }
                try appendHex4(&out, alloc, cp);
            },
            else => return error.InvalidJson,
        }
    }
    return error.InvalidJson; // ran off the end before a closing quote
}

/// Read `"key": <string value>` inside the object spanning [obj_start..obj_end].
fn readStringField(
    alloc: std.mem.Allocator,
    src: []const u8,
    obj_start: usize,
    obj_end: usize,
    key: []const u8,
) ParseError!?[]u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;
    var pos = std.mem.indexOfPos(u8, src[0..obj_end], obj_start + 1, needle) orelse return null;
    pos += needle.len;
    var i = pos;
    skipWs(src, &i);
    if (i >= obj_end or src[i] != ':') return error.InvalidJson;
    i += 1;
    skipWs(src, &i);
    if (i >= obj_end) return error.MissingField;
    return try parseJsonString(alloc, src, &i);
}

/// Capture the RAW text of `"key": <object value>` (balanced braces). Used
/// for tool schemas written inline; returns a duped slice.
fn readObjectFieldRaw(
    alloc: std.mem.Allocator,
    src: []const u8,
    obj_start: usize,
    obj_end: usize,
    key: []const u8,
) ParseError!?[]u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;
    var pos = std.mem.indexOfPos(u8, src[0..obj_end], obj_start + 1, needle) orelse return null;
    pos += needle.len;
    var i = pos;
    skipWs(src, &i);
    if (i >= obj_end or src[i] != ':') return error.InvalidJson;
    i += 1;
    skipWs(src, &i);
    if (i >= obj_end or src[i] != '{') return null; // not an object here
    const end = matchDelim(src, i, '{', '}') orelse return error.InvalidJson;
    return try alloc.dupe(u8, src[i .. end + 1]);
}

/// Iterate top-level object members between `open`+1 and its matching close.
const MemberIter = struct {
    src: []const u8,
    start: usize,
    end: usize,
    i: usize,

    fn init(src: []const u8, obj_start: usize, obj_end: usize) MemberIter {
        return .{ .src = src, .start = obj_start + 1, .end = obj_end, .i = obj_start + 1 };
    }

    const Member = struct {
        key: []u8,
        /// Index of the first character of this member's VALUE (past ':').
        value_start: usize,
    };

    /// Next member with its value position, or null at '}' / end.
    fn nextMember(self: *MemberIter, alloc: std.mem.Allocator) ParseError!?Member {
        // Separator runs are consumed ITERATIVELY. The previous recursive
        // form spent one stack frame per ',' and crashed the process on a
        // hostile manifest containing a long comma run (found by src/fuzz;
        // regression case in fuzz/manifest.zig).
        while (true) {
            skipWs(self.src, &self.i);
            if (self.i >= self.end or self.src[self.i] == '}') return null;
            if (self.src[self.i] != ',') break;
            self.i += 1;
        }
        const key = try parseJsonString(alloc, self.src, &self.i);
        errdefer alloc.free(key);
        skipWs(self.src, &self.i);
        if (self.i >= self.end or self.src[self.i] != ':') return error.InvalidJson;
        self.i += 1;
        skipWs(self.src, &self.i);
        return .{ .key = key, .value_start = self.i };
    }

    /// Advance past one full value starting at `from`, then position for the
    /// next member (consumes an optional ',').
    fn consumeValue(self: *MemberIter, from: usize) ParseError!void {
        var j = from;
        try skipValue(self.src, &j);
        skipWs(self.src, &j);
        if (j >= self.end) {
            self.i = j;
            return;
        }
        if (self.src[j] == ',') j += 1 else if (self.src[j] != '}') return error.InvalidJson;
        self.i = j;
    }
};

/// Parse a plugin manifest document (hand-rolled, tolerant of unknown keys).
/// Does NOT enforce policy — run `validateManifest` afterwards.
pub fn parseManifest(alloc: std.mem.Allocator, src_in: []const u8) ParseError!Manifest {
    var m = Manifest{
        .alloc = alloc,
        .name = try alloc.dupe(u8, ""),
        .version = try alloc.dupe(u8, ""),
        .kind = .tool,
        .tools = try alloc.alloc(ToolSpec, 0),
    };
    errdefer {
        for (m.tools) |t| {
            alloc.free(t.name);
            alloc.free(t.description);
            alloc.free(t.schema);
        }
        alloc.free(m.tools);
        alloc.free(m.name);
        alloc.free(m.version);
    }

    var start: usize = 0;
    skipWs(src_in, &start);
    if (start >= src_in.len or src_in[start] != '{') return error.InvalidJson;
    const obj_end_full = matchDelim(src_in, start, '{', '}') orelse return error.InvalidJson;

    var it = MemberIter.init(src_in, start, obj_end_full);
    while (try it.nextMember(alloc)) |member| {
        defer alloc.free(member.key);
        var vi = member.value_start;
        if (std.mem.eql(u8, member.key, "name")) {
            const s = try parseJsonString(alloc, src_in, &vi);
            alloc.free(m.name);
            m.name = s;
        } else if (std.mem.eql(u8, member.key, "version")) {
            const s = try parseJsonString(alloc, src_in, &vi);
            alloc.free(m.version);
            m.version = s;
        } else if (std.mem.eql(u8, member.key, "kind")) {
            const ks = try parseJsonString(alloc, src_in, &vi);
            defer alloc.free(ks);
            m.kind = Kind.fromString(ks) orelse return error.UnsupportedKind;
        } else if (std.mem.eql(u8, member.key, "tools")) {
            if (matchDelim(src_in, vi, '[', ']') == null) return error.InvalidJson;
            const ts = try parseToolsArray(alloc, src_in, vi);
            alloc.free(m.tools);
            m.tools = ts;
        }
        // Advance past this member's value (any type) and its ','.
        try it.consumeValue(member.value_start);
    }
    return m;
}

/// Parse `"tools":[ {...}, ... ]` starting at the '[' . Each element needs
/// name/description/schema. `schema` may be written inline as an object
/// (canonical) or as a string containing the schema JSON — both are accepted.
fn parseToolsArray(
    alloc: std.mem.Allocator,
    src: []const u8,
    arr_start: usize,
) ParseError![]ToolSpec {
    const arr_end = matchDelim(src, arr_start, '[', ']') orelse return error.InvalidJson;
    var tools: std.ArrayList(ToolSpec) = .empty;
    errdefer {
        for (tools.items) |t| {
            alloc.free(t.name);
            alloc.free(t.description);
            alloc.free(t.schema);
        }
        tools.deinit(alloc);
    }
    var i = arr_start + 1;
    while (true) {
        skipWs(src, &i);
        if (i >= arr_end or src[i] == ']') break;
        if (src[i] != '{') return error.InvalidJson;
        const obj_end = matchDelim(src, i, '{', '}') orelse return error.InvalidJson;

        const tname = (try readStringField(alloc, src, i, obj_end, "name")) orelse
            return error.MissingField;
        errdefer alloc.free(tname);
        const tdesc = (try readStringField(alloc, src, i, obj_end, "description")) orelse
            return error.MissingField;
        errdefer alloc.free(tdesc);

        // Schema: inline object preferred; quoted string accepted too.
        var schema: []u8 = undefined;
        if (try readObjectFieldRaw(alloc, src, i, obj_end, "schema")) |raw| {
            schema = raw;
        } else if (try readStringField(alloc, src, i, obj_end, "schema")) |s| {
            schema = s;
        } else {
            return error.MissingField;
        }
        errdefer alloc.free(schema);

        try tools.append(alloc, .{ .name = tname, .description = tdesc, .schema = schema });

        i = obj_end + 1;
        skipWs(src, &i);
        if (i < arr_end and src[i] == ',') {
            i += 1;
            continue;
        }
        break;
    }
    return tools.toOwnedSlice(alloc);
}

// ── validation ───────────────────────────────────────────────────────────

fn validIdent(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// Plugin names may additionally carry dots ("tool.shell", dev.md §XXV)
/// and non-ASCII UTF-8 bytes; whitespace/control chars are rejected.
fn validPluginName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
            else => if (c < 0x80) return false, // ASCII must be whitelisted
        }
    }
    return true;
}

/// Policy check for a parsed manifest. `abiVersionOk` covers the other half
/// of admission; this one is pure and unit-testable without dlopen.
pub fn validateManifest(m: *const Manifest) ValidateError!void {
    if (!validPluginName(m.name)) return error.InvalidName;
    if (m.version.len == 0 or m.version.len > 32) return error.InvalidVersion;
    if (m.kind != .tool) return error.UnsupportedKind;
    if (m.tools.len == 0) return error.NoTools;
    for (m.tools) |t| {
        if (!validIdent(t.name)) return error.InvalidToolEntry;
        // schema must be a balanced JSON object
        const trimmed = std.mem.trim(u8, t.schema, " \t\r\n");
        if (matchDelim(trimmed, 0, '{', '}') != trimmed.len -| 1) return error.InvalidToolEntry;
    }
}

// ── naming ───────────────────────────────────────────────────────────────

/// Append `s` sanitized into the host tool namespace charset [a-z0-9_].
fn appendSanitized(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            'a'...'z', '0'...'9', '_' => try out.append(alloc, c),
            'A'...'Z' => try out.append(alloc, c + ('a' - 'A')),
            else => try out.append(alloc, '_'),
        }
    }
}

/// Host-visible tool name for plugin-local tool `<tool_name>` of plugin
/// `<plugin_name>`: `p_<plugin>_<tool>`, sanitized to [a-z0-9_] so plugin
/// tools can never collide with builtins or MCP (`mcp_*`) names. Caller frees.
pub fn hostToolName(alloc: std.mem.Allocator, plugin_name: []const u8, tool_name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, 'p');
    try out.append(alloc, '_');
    try appendSanitized(&out, alloc, plugin_name);
    try out.append(alloc, '_');
    try appendSanitized(&out, alloc, tool_name);
    return out.toOwnedSlice(alloc);
}

// ─────────────────────────────────────────────────────────────────────────
// Registry: discovery, loading, execution, unloading
// ─────────────────────────────────────────────────────────────────────────

/// One skipped-plugin record (path + human-readable reason).
pub const ReportEntry = struct {
    path: []u8,
    reason: []u8,
};

/// A registered plugin tool as seen by the host.
pub const LoadedTool = struct {
    /// Name the model calls: `p_<plugin>_<tool>`.
    host_name: []u8,
    /// Name passed to zh_tool_execute (plugin-local).
    tool_name: []u8,
    description: []u8,
    /// Raw parameters-schema JSON (registry-compatible view below).
    schema: []u8,
    plugin_idx: usize,
};

/// Result of executing a plugin tool. `output` is owned by the caller;
/// `ok == false` means the plugin signalled failure via NULL and `output`
/// carries a host-side error message.
pub const ExecOutcome = struct {
    ok: bool,
    output: []u8,
};

pub const PluginRegistry = struct {
    alloc: std.mem.Allocator,
    plugins: std.ArrayList(*ffi.LoadedPlugin),
    tools: std.ArrayList(LoadedTool),
    report: std.ArrayList(ReportEntry),

    pub fn init(alloc: std.mem.Allocator) PluginRegistry {
        return .{
            .alloc = alloc,
            .plugins = .empty,
            .tools = .empty,
            .report = .empty,
        };
    }

    /// Unload every plugin (dlclose) and free all owned memory.
    pub fn deinit(self: *PluginRegistry) void {
        for (self.plugins.items) |p| {
            p.deinit();
            self.alloc.destroy(p);
        }
        self.plugins.deinit(self.alloc);
        for (self.tools.items) |t| {
            self.alloc.free(t.host_name);
            self.alloc.free(t.tool_name);
            self.alloc.free(t.description);
            self.alloc.free(t.schema);
        }
        self.tools.deinit(self.alloc);
        for (self.report.items) |e| {
            self.alloc.free(e.path);
            self.alloc.free(e.reason);
        }
        self.report.deinit(self.alloc);
    }

    fn addReport(self: *PluginRegistry, path: []const u8, comptime fmt: []const u8, args: anytype) void {
        const path_copy = self.alloc.dupe(u8, path) catch return; // report best-effort
        const reason = std.fmt.allocPrint(self.alloc, fmt, args) catch {
            self.alloc.free(path_copy);
            return;
        };
        self.report.append(self.alloc, .{ .path = path_copy, .reason = reason }) catch {
            self.alloc.free(path_copy);
            self.alloc.free(reason);
        };
    }

    /// Load one candidate file. Never throws: failures land in `report`.
    pub fn loadPath(self: *PluginRegistry, path: []const u8) void {
        // Suffix gate first so random files in plugins/ get a clear reason.
        const is_dylib = std.mem.endsWith(u8, path, ".dylib");
        const is_so = std.mem.endsWith(u8, path, ".so");
        if (!is_dylib and !is_so) {
            self.addReport(path, "skipped: not a shared library (.so/.dylib)", .{});
            return;
        }
        const base = std.fs.path.basename(path);
        if (base.len == 0 or base[0] == '.') {
            self.addReport(path, "skipped: hidden file", .{});
            return;
        }

        var plugin = ffi.LoadedPlugin.load(self.alloc, path) catch |e| {
            switch (e) {
                error.OpenFailed => {
                    var buf: [256]u8 = undefined;
                    const detail = ffi.lastErrorText(&buf);
                    self.addReport(path, "dlopen failed: {s}", .{detail});
                },
                error.SymbolMissing => self.addReport(path, "missing required ABI symbol", .{}),
                error.OutOfMemory => self.addReport(path, "out of memory", .{}),
            }
            return;
        };

        // Version check BEFORE trusting anything else from the binary.
        const ver = plugin.vtable.abi_version();
        if (!abiVersionOk(ver)) {
            self.addReport(path, "ABI version {d} unsupported (host speaks {d})", .{ ver, capi.ABI_VERSION });
            plugin.deinit();
            return;
        }

        // Copy the manifest out of plugin storage so validation cannot race
        // an unload, then validate strictly.
        const manifest_src = self.alloc.dupe(u8, plugin.manifest()) catch {
            self.addReport(path, "out of memory", .{});
            plugin.deinit();
            return;
        };
        defer self.alloc.free(manifest_src);

        var m = parseManifest(self.alloc, manifest_src) catch |e| {
            self.addReport(path, "manifest rejected: {s}", .{@errorName(e)});
            plugin.deinit();
            return;
        };
        defer m.deinit();

        validateManifest(&m) catch |e| {
            self.addReport(path, "manifest invalid: {s}", .{@errorName(e)});
            plugin.deinit();
            return;
        };

        // Project each tool into the host namespace.
        const plugin_idx = self.plugins.items.len;
        var added: usize = 0;
        for (m.tools) |t| {
            const host_name = hostToolName(self.alloc, m.name, t.name) catch continue;
            if (self.findTool(host_name) != null) {
                self.addReport(path, "duplicate host tool '{s}' ignored", .{host_name});
                self.alloc.free(host_name);
                continue;
            }
            const tool_name = self.alloc.dupe(u8, t.name) catch {
                self.alloc.free(host_name);
                continue;
            };
            const description = self.alloc.dupe(u8, t.description) catch {
                self.alloc.free(host_name);
                self.alloc.free(tool_name);
                continue;
            };
            const schema = self.alloc.dupe(u8, t.schema) catch {
                self.alloc.free(host_name);
                self.alloc.free(tool_name);
                self.alloc.free(description);
                continue;
            };
            self.tools.append(self.alloc, .{
                .host_name = host_name,
                .tool_name = tool_name,
                .description = description,
                .schema = schema,
                .plugin_idx = plugin_idx,
            }) catch {
                self.freeToolRow(.{
                    .host_name = host_name,
                    .tool_name = tool_name,
                    .description = description,
                    .schema = schema,
                    .plugin_idx = plugin_idx,
                });
                continue; // OOM on this tool — skip it, keep the host alive
            };
            added += 1;
        }

        if (added == 0) {
            self.addReport(path, "no usable tools registered", .{});
            plugin.deinit();
            return;
        }

        const stored = self.alloc.create(ffi.LoadedPlugin) catch {
            // Roll back the tool rows we just added for this plugin.
            var k = self.tools.items.len;
            while (k > 0) {
                k -= 1;
                if (self.tools.items[k].plugin_idx == plugin_idx) {
                    const row = self.tools.swapRemove(k);
                    self.freeToolRow(row);
                }
            }
            self.addReport(path, "out of memory", .{});
            plugin.deinit();
            return;
        };
        stored.* = plugin;
        self.plugins.append(self.alloc, stored) catch {
            self.alloc.destroy(stored);
            self.addReport(path, "out of memory", .{});
            plugin.deinit();
            return;
        };
    }

    fn freeToolRow(self: *PluginRegistry, t: LoadedTool) void {
        self.alloc.free(t.host_name);
        self.alloc.free(t.tool_name);
        self.alloc.free(t.description);
        self.alloc.free(t.schema);
    }

    /// Scan `dir_path` for *.dylib / *.so (sorted for determinism) and load
    /// each. Missing directory is silently fine (nothing to discover).
    /// Returns the number of successfully loaded plugins.
    pub fn loadDir(self: *PluginRegistry, io: std.Io, dir_path: []const u8) usize {
        const before = self.plugins.items.len;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
        defer dir.close(io);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.alloc.free(n);
            names.deinit(self.alloc);
        }
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            const dup = self.alloc.dupe(u8, entry.name) catch continue;
            names.append(self.alloc, dup) catch {
                self.alloc.free(dup);
                continue;
            };
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (names.items) |n| {
            const full = std.fs.path.join(self.alloc, &.{ dir_path, n }) catch continue;
            defer self.alloc.free(full);
            self.loadPath(full);
        }
        return self.plugins.items.len - before;
    }

    /// Standard discovery order (dev.md §XXVII): ~/.zharness/plugins first,
    /// then the workspace's own plugins/ directory.
    pub fn loadDefaultDirs(self: *PluginRegistry, io: std.Io, workspace_root: []const u8) void {
        // std.posix.getenv was removed in this 0.17-dev build; use libc.
        if (std.c.getenv("HOME")) |home_ptr| {
            const home = std.mem.span(home_ptr);
            const user_dir = std.fs.path.join(self.alloc, &.{ home, ".zharness", "plugins" }) catch null;
            if (user_dir) |ud| {
                defer self.alloc.free(ud);
                _ = self.loadDir(io, ud);
            }
        }
        const ws_dir = std.fs.path.join(self.alloc, &.{ workspace_root, "plugins" }) catch return;
        defer self.alloc.free(ws_dir);
        _ = self.loadDir(io, ws_dir);
    }

    /// Index of the registered tool named `host_tool_name`, if any.
    pub fn findTool(self: *PluginRegistry, host_tool_name: []const u8) ?usize {
        for (self.tools.items, 0..) |t, idx| {
            if (std.mem.eql(u8, t.host_name, host_tool_name)) return idx;
        }
        return null;
    }

    /// registry.ToolDefinition view for tool `idx`. Strings point into
    /// registry-owned storage and stay valid until `deinit`.
    pub fn definitionFor(self: *PluginRegistry, idx: usize) registry.ToolDefinition {
        const t = self.tools.items[idx];
        return .{
            .name = t.host_name,
            .description = t.description,
            .parameters_json = t.schema,
            .category = .general,
        };
    }

    /// All definitions, ready to feed `tool_reg.ToolRegistry.register`
    /// (which duplicates strings itself).
    pub fn definitions(self: *PluginRegistry, alloc: std.mem.Allocator) ![]registry.ToolDefinition {
        var defs = try alloc.alloc(registry.ToolDefinition, self.tools.items.len);
        for (self.tools.items, 0..) |_, idx| defs[idx] = self.definitionFor(idx);
        return defs;
    }

    /// Execute a plugin tool previously discovered under `host_tool_name`.
    /// Marshals args into NUL-terminated buffers, calls the plugin, COPIES
    /// the returned C string into host memory, and only then releases the
    /// plugin-side buffer (zh_string_free) — copy-before-free keeps a
    /// misbehaving plugin from corrupting host state.
    /// Returns null when `host_tool_name` is not a plugin tool.
    pub fn execute(
        self: *PluginRegistry,
        alloc: std.mem.Allocator,
        host_tool_name: []const u8,
        args_json: []const u8,
    ) !?ExecOutcome {
        const idx = self.findTool(host_tool_name) orelse return null;
        const t = self.tools.items[idx];
        const plugin = self.plugins.items[t.plugin_idx];

        const effective_args: []const u8 =
            if (args_json.len == 0) "{}" else args_json;

        const tool_z = try alloc.dupeSentinel(u8, t.tool_name, 0);
        defer alloc.free(tool_z);
        const args_z = try alloc.dupeSentinel(u8, effective_args, 0);
        defer alloc.free(args_z);

        const ret = plugin.vtable.execute(tool_z.ptr, args_z.ptr) orelse {
            const msg = try std.fmt.allocPrint(
                alloc,
                "plugin tool '{s}' reported failure",
                .{t.host_name},
            );
            return ExecOutcome{ .ok = false, .output = msg };
        };

        // Copy first, free second — the contract-mandated order.
        const copied = alloc.dupe(u8, ret[0..std.mem.len(ret)]) catch |e| {
            plugin.vtable.string_free(ret);
            return e;
        };
        plugin.vtable.string_free(ret);
        return ExecOutcome{ .ok = true, .output = copied };
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Tests (pure — no dlopen; the dylib round trip lives in test/_t_plug.zig)
// ─────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "abiVersionOk accepts only the current version" {
    try testing.expect(abiVersionOk(capi.ABI_VERSION));
    try testing.expect(!abiVersionOk(0));
    try testing.expect(!abiVersionOk(2));
}

test "parseManifest extracts fields with nested schema objects" {
    const alloc = testing.allocator;
    const src =
        \\{
        \\  "name": "tool.shell",
        \\  "version": "0.1.0",
        \\  "kind": "tool",
        \\  "dependencies": ["cordis", "zharness"],
        \\  "tools": [
        \\    {
        \\      "name": "shell_run",
        \\      "description": "Run \"safe\" commands.",
        \\      "schema": {
        \\        "type": "object",
        \\        "properties": {"cmd": {"type": "string"}},
        \\        "required": ["cmd"]
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    var m = try parseManifest(alloc, src);
    defer m.deinit();
    try testing.expectEqualStrings("tool.shell", m.name);
    try testing.expectEqualStrings("0.1.0", m.version);
    try testing.expectEqual(Kind.tool, m.kind);
    try testing.expectEqual(@as(usize, 1), m.tools.len);
    try testing.expectEqualStrings("shell_run", m.tools[0].name);
    try testing.expectEqualStrings("Run \"safe\" commands.", m.tools[0].description);
    // Nested braces must survive intact.
    try testing.expect(std.mem.indexOf(u8, m.tools[0].schema, "\"properties\"") != null);
    try validateManifest(&m);
}

test "parseManifest decodes unicode escapes" {
    const alloc = testing.allocator;
    var m = try parseManifest(alloc, "{\"name\":\"caf\\u00e9\",\"version\":\"1\",\"kind\":\"tool\",\"tools\":[{\"name\":\"t\",\"description\":\"\\ud83d\\ude00 ok\",\"schema\":{}}]}");
    defer m.deinit();
    try testing.expectEqualStrings("café", m.name);
    try testing.expectEqualStrings("\u{1F600} ok", m.tools[0].description);
    try validateManifest(&m);
}

test "parseManifest accepts schema-as-string form" {
    const alloc = testing.allocator;
    const src = "{\"name\":\"p\",\"version\":\"1\",\"kind\":\"tool\",\"tools\":[{" ++
        "\"name\":\"t\",\"description\":\"d\",\"schema\":\"{\\\"type\\\":\\\"object\\\"}\"}]}";
    var m = try parseManifest(alloc, src);
    defer m.deinit();
    try testing.expectEqualStrings("{\"type\":\"object\"}", m.tools[0].schema);
    try validateManifest(&m);
}

test "parseManifest rejects garbage" {
    const alloc = testing.allocator;
    try testing.expectError(error.InvalidJson, parseManifest(alloc, "not json"));
    try testing.expectError(error.InvalidJson, parseManifest(alloc, "{\"name\":"));
    try testing.expectError(error.InvalidJson, parseManifest(alloc, "[1,2,3]"));
}

// Helper for building manifests from raw text in validator tests.
fn parseForTest(alloc: std.mem.Allocator, src: []const u8) !Manifest {
    return parseManifest(alloc, src);
}

fn toolSpec(a: std.mem.Allocator, n: []const u8, s: []const u8) !ToolSpec {
    return .{
        .name = try a.dupe(u8, n),
        .description = try a.dupe(u8, ""),
        .schema = try a.dupe(u8, s),
    };
}

test "parseManifest rejects wrong kind at parse time" {
    const alloc = testing.allocator;
    try testing.expectError(
        error.UnsupportedKind,
        parseForTest(alloc, "{\"name\":\"p\",\"version\":\"1\",\"kind\":\"daemon\",\"tools\":[]}"),
    );
}

test "validateManifest rejects bad plugin name" {
    const alloc = testing.allocator;
    var m = Manifest{
        .alloc = alloc,
        .name = try alloc.dupe(u8, "bad name"),
        .version = try alloc.dupe(u8, "1"),
        .kind = .tool,
        .tools = try alloc.alloc(ToolSpec, 1),
    };
    m.tools[0] = try toolSpec(alloc, "t", "{}");
    defer m.deinit();
    try testing.expectError(error.InvalidName, validateManifest(&m));
}

test "validateManifest rejects empty version" {
    const alloc = testing.allocator;
    var m = Manifest{
        .alloc = alloc,
        .name = try alloc.dupe(u8, "ok-name"),
        .version = try alloc.dupe(u8, ""),
        .kind = .tool,
        .tools = try alloc.alloc(ToolSpec, 1),
    };
    m.tools[0] = try toolSpec(alloc, "t", "{}");
    defer m.deinit();
    try testing.expectError(error.InvalidVersion, validateManifest(&m));
}

test "validateManifest rejects unbalanced schema" {
    const alloc = testing.allocator;
    var m = Manifest{
        .alloc = alloc,
        .name = try alloc.dupe(u8, "ok"),
        .version = try alloc.dupe(u8, "1"),
        .kind = .tool,
        .tools = try alloc.alloc(ToolSpec, 1),
    };
    m.tools[0] = try toolSpec(alloc, "t", "{\"type\":");
    defer m.deinit();
    try testing.expectError(error.InvalidToolEntry, validateManifest(&m));
}

test "validateManifest rejects invalid tool name" {
    const alloc = testing.allocator;
    var m = Manifest{
        .alloc = alloc,
        .name = try alloc.dupe(u8, "ok"),
        .version = try alloc.dupe(u8, "1"),
        .kind = .tool,
        .tools = try alloc.alloc(ToolSpec, 1),
    };
    m.tools[0] = try toolSpec(alloc, "bad.tool", "{}");
    defer m.deinit();
    try testing.expectError(error.InvalidToolEntry, validateManifest(&m));
}

test "validateManifest rejects zero tools" {
    const alloc = testing.allocator;
    var m = Manifest{
        .alloc = alloc,
        .name = try alloc.dupe(u8, "ok"),
        .version = try alloc.dupe(u8, "1"),
        .kind = .tool,
        .tools = try alloc.alloc(ToolSpec, 0),
    };
    defer m.deinit();
    try testing.expectError(error.NoTools, validateManifest(&m));
}

test "hostToolName sanitizes into p_plugin_tool namespace" {
    const alloc = testing.allocator;
    const cases = [_][3][]const u8{
        .{ "hello", "hello_echo", "p_hello_hello_echo" },
        .{ "My Plugin!", "do-Thing", "p_my_plugin__do_thing" },
        .{ "tool.shell", "run.cmd", "p_tool_shell_run_cmd" },
    };
    for (cases) |c| {
        const got = try hostToolName(alloc, c[0], c[1]);
        defer alloc.free(got);
        try testing.expectEqualStrings(c[2], got);
    }
}

test "registry reports unloadable file without crashing or leaking" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "fake.dylib", .data = "this is not a dylib" });
    try tmp.dir.writeFile(io, .{ .sub_path = "readme.txt", .data = "ignored suffix" });

    // TmpDir lives under <cwd>/.zig-cache/tmp/<sub_path>; dlopen needs a
    // real filesystem path, so rebuild it instead of realpath(3).
    const dir_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dir_path);

    var reg = PluginRegistry.init(alloc);
    defer reg.deinit();
    const loaded = reg.loadDir(io, dir_path);
    try testing.expectEqual(@as(usize, 0), loaded);
    try testing.expectEqual(@as(usize, 0), reg.plugins.items.len);
    // Both files produced a report (dlopen failure + suffix skip).
    try testing.expectEqual(@as(usize, 2), reg.report.items.len);
    // execute on an unknown tool is a clean null
    const none = try reg.execute(alloc, "nope", "{}");
    try testing.expect(none == null);
}
