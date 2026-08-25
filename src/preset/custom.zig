//! User-defined agent presets — CRUD over `~/.zharness/agent-presets/*.json`.
//!
//! One file per preset, named `<name>.json`, schema (hand-rolled JSON like
//! session/checkpoint.zig; JSON chosen over flat TOML because presets need
//! nested arrays of strings/objects that the config.toml flat writer does
//! not express):
//!
//!     {
//!       "name": "my-preset",
//!       "description": "one-line display text",
//!       "tools": ["file_read", "shell"],
//!       "system_prompt": "You are ... {{model}} ... {{cwd}}",
//!       "default_max_turns": 32,
//!       "order": 10,
//!       "complete_prompt": false,
//!       "tool_config": [{"tool_name":"shell","disabled":false,
//!                        "config_json":"{\"timeout_ms\":5000}"}]
//!     }
//!
//! The first five fields are the required base; `complete_prompt` and
//! `tool_config` are additive extensions defaulting to false / empty.
//!
//! Writes are atomic (tmp file + rename inside the preset dir). Names are
//! validated (`[A-Za-z0-9._-]+`, no path separators) before they ever touch
//! the filesystem. Loaded specs own their memory (origin == .custom);
//! release via `presets.freeSpec`. `resolve` composes builtins-first lookup
//! with this store so `--preset <name>` accepts both kinds.
//!
//! Errors: MalformedPreset on structurally invalid documents, UnknownPreset
//! when a name has no file, PresetNotFound on delete of a missing name.

const std = @import("std");
const presets = @import("../presets.zig");

pub const ResolveError = error{
    UnknownPreset,
    MalformedPreset,
    InvalidName,
} || std.mem.Allocator.Error || anyerror;

/// `<HOME>/.zharness/agent-presets` (caller frees). Null without HOME env.
pub fn defaultDirPath(alloc: std.mem.Allocator) ![]u8 {
    const home = std.c.getenv("HOME") orelse return error.HomeUnavailable;
    return std.fmt.allocPrint(alloc, "{s}/.zharness/agent-presets", .{home});
}

/// Restrict file-derived names to a safe charset (no separators, no `..`).
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

fn fileName(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}.json", .{name}) catch unreachable;
}

// ── serialization ───────────────────────────────────────────────────────────

/// Escape into an ArrayList as a JSON string body (no surrounding quotes).
fn escapeInto(alloc: std.mem.Allocator, input: []const u8, out: *std.ArrayList(u8)) !void {
    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
}

/// Serialize one spec to the on-disk document shape.
pub fn renderJson(alloc: std.mem.Allocator, s: *const presets.Spec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"name\":\"");
    try escapeInto(alloc, s.name, &out);
    try out.appendSlice(alloc, "\",\"description\":\"");
    try escapeInto(alloc, s.description, &out);
    try out.appendSlice(alloc, "\",\"tools\":[");
    for (s.tools, 0..) |t, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.append(alloc, '"');
        try escapeInto(alloc, t, &out);
        try out.append(alloc, '"');
    }
    try out.appendSlice(alloc, "],\"system_prompt\":\"");
    try escapeInto(alloc, s.system_prompt_fragment, &out);
    try out.appendSlice(alloc, "\",\"default_max_turns\":");
    var nb: [24]u8 = undefined;
    try out.appendSlice(alloc, std.fmt.bufPrint(&nb, "{d}", .{s.default_max_turns}) catch unreachable);
    try out.appendSlice(alloc, ",\"order\":");
    try out.appendSlice(alloc, std.fmt.bufPrint(&nb, "{d}", .{s.order}) catch unreachable);
    try out.appendSlice(alloc, ",\"complete_prompt\":");
    try out.appendSlice(alloc, if (s.complete_prompt) "true" else "false");
    try out.appendSlice(alloc, ",\"tool_config\":[");
    for (s.tool_config, 0..) |o, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"tool_name\":\"");
        try escapeInto(alloc, o.tool_name, &out);
        try out.appendSlice(alloc, "\",\"disabled\":");
        try out.appendSlice(alloc, if (o.disabled) "true" else "false");
        try out.appendSlice(alloc, ",\"config_json\":");
        if (o.config_json) |cj| {
            // config_json is already valid JSON text — embed verbatim.
            try out.appendSlice(alloc, cj);
        } else {
            try out.appendSlice(alloc, "null");
        }
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]}\n");
    return out.toOwnedSlice(alloc);
}

// ── parsing (tolerant hand-rolled subset) ───────────────────────────────────

fn findMatchingBrace(hay: []const u8, open: usize) ?usize {
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    var i = open;
    while (i < hay.len) : (i += 1) {
        const c = hay[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

fn skipWs(hay: []const u8, i: usize) usize {
    var j = i;
    while (j < hay.len and (hay[j] == ' ' or hay[j] == '\t' or hay[j] == '\n' or hay[j] == '\r')) : (j += 1) {}
    return j;
}

/// Decoded copy of `"key":"value"` anywhere in `hay`; caller frees. Null
/// when absent or not a string.
fn extractOwnedString(alloc: std.mem.Allocator, hay: []const u8, key: []const u8) !?[]u8 {
    var nb: [160]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, hay, needle) orelse return null;
    var i = skipWs(hay, pos + needle.len);
    if (i >= hay.len or hay[i] != '"') return null;
    i += 1;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    while (i < hay.len and hay[i] != '"') : (i += 1) {
        if (hay[i] == '\\' and i + 1 < hay.len) i += 1;
        try raw.append(alloc, hay[i]);
    }
    if (i >= hay.len) return null; // unterminated string
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var j: usize = 0;
    while (j < raw.items.len) : (j += 1) {
        if (raw.items[j] == '\\' and j + 1 < raw.items.len) {
            j += 1;
            try out.append(alloc, switch (raw.items[j]) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'b' => 8,
                'f' => 12,
                else => raw.items[j],
            });
        } else {
            try out.append(alloc, raw.items[j]);
        }
    }
    return try out.toOwnedSlice(alloc);
}

fn parseBool(hay: []const u8, key: []const u8) bool {
    var nb: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"{s}\":true", .{key}) catch return false;
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn parseIntField(hay: []const u8, key: []const u8, default_value: i64) i64 {
    var nb: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"{s}\":", .{key}) catch return default_value;
    const p = std.mem.indexOf(u8, hay, needle) orelse return default_value;
    var i = skipWs(hay, p + needle.len);
    var neg = false;
    if (i < hay.len and hay[i] == '-') {
        neg = true;
        i += 1;
    }
    var v: i64 = 0;
    var any = false;
    while (i < hay.len and std.ascii.isDigit(hay[i])) : (i += 1) {
        v = v * 10 + @as(i64, hay[i] - '0');
        any = true;
        if (v > 1 << 40) return default_value;
    }
    return if (any) (if (neg) -v else v) else default_value;
}

/// Slice covering `[...]` inclusive for `"key":[`.
fn sliceArrayField(hay: []const u8, key: []const u8) ?[]const u8 {
    var nb: [160]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"{s}\":[", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, hay, needle) orelse return null;
    const start = pos + needle.len - 1;
    // Find matching ']' with string awareness.
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    var i = start;
    while (i < hay.len) : (i += 1) {
        const c = hay[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return hay[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// Top-level elements of a flat `[...]` array of strings/objects. The
/// outermost brackets belong to `arr` itself, so scanning stops one byte
/// short of the closing delimiter.
fn splitTopLevel(arr: []const u8, alloc: std.mem.Allocator, cb: anytype) !void {
    if (arr.len < 2) return error.MalformedPreset;
    var i: usize = 1; // skip '['
    while (i < arr.len - 1) {
        switch (arr[i]) {
            ' ', '\t', '\n', '\r', ',' => i += 1,
            '{', '[' => {
                const close = if (arr[i] == '{') findMatchingBrace(arr, i) else matchingBracket(arr, i);
                const end = close orelse return error.MalformedPreset;
                try cb.object(alloc, arr[i..end]);
                i = end;
            },
            '"' => {
                i += 1;
                const vs = i;
                while (i < arr.len and arr[i] != '"') : (i += 1) {
                    if (arr[i] == '\\' and i + 1 < arr.len) i += 1;
                }
                if (i >= arr.len) return error.MalformedPreset;
                try cb.quoted(alloc, arr[vs..i]);
                i += 1;
            },
            else => return error.MalformedPreset,
        }
    }
}

fn matchingBracket(hay: []const u8, open: usize) ?usize {
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    var i = open;
    while (i < hay.len) : (i += 1) {
        const c = hay[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

/// Parse one preset document. All returned strings are heap-owned by
/// `alloc`; missing optional fields become static-empty values so
/// `presets.freeSpec` stays symmetric.
pub fn parseDocument(alloc: std.mem.Allocator, raw: []const u8) !presets.Spec {
    const trimmed = std.mem.trim(u8, raw, " \n\r\t");
    if (trimmed.len < 2 or trimmed[0] != '{') return error.MalformedPreset;
    const obj_end = findMatchingBrace(trimmed, 0) orelse return error.MalformedPreset;
    const doc = trimmed[0..obj_end];

    var spec = presets.Spec{
        .kind = .standard, // customs carry no Kind; field kept for layout parity
        .name = try alloc.dupe(u8, ""),
        .tools = &.{},
        .system_prompt_fragment = try alloc.dupe(u8, ""),
        .default_max_turns = 32,
        .origin = .custom,
    };
    errdefer presets.freeSpec(alloc, &spec);

    spec.name = (try extractOwnedString(alloc, doc, "name")) orelse return error.MalformedPreset;
    if (!validName(spec.name)) return error.InvalidName;
    spec.system_prompt_fragment = (try extractOwnedString(alloc, doc, "system_prompt")) orelse
        return error.MalformedPreset;
    if (try extractOwnedString(alloc, doc, "description")) |d| spec.description = d;

    spec.default_max_turns = @intCast(@max(1, parseIntField(doc, "default_max_turns", 32)));
    spec.order = @intCast(std.math.clamp(parseIntField(doc, "order", 0), -1 << 20, (1 << 20) - 1));
    spec.complete_prompt = parseBool(doc, "complete_prompt");

    // tools: ["a", "b"]
    const Ctx = struct {
        list: *std.ArrayList([]const u8),
        alloc: std.mem.Allocator,

        fn quoted(self: @This(), a: std.mem.Allocator, raw_s: []const u8) !void {
            const decoded = try unescape(a, raw_s);
            errdefer a.free(decoded);
            try self.list.append(a, decoded);
        }
        fn object(self: @This(), a: std.mem.Allocator, raw_obj: []const u8) !void {
            _ = self;
            _ = a;
            _ = raw_obj;
            return error.MalformedPreset; // tools must be plain strings
        }
    };
    var tools_list: std.ArrayList([]const u8) = .empty;
    if (sliceArrayField(doc, "tools")) |arr| {
        errdefer {
            for (tools_list.items) |t| alloc.free(t);
            tools_list.deinit(alloc);
        }
        try splitTopLevel(arr, alloc, Ctx{ .list = &tools_list, .alloc = alloc });
        if (tools_list.items.len > 0) spec.tools = try tools_list.toOwnedSlice(alloc);
    }

    // tool_config: [{tool_name, disabled, config_json}]
    const OCtx = struct {
        list: *std.ArrayList(presets.ToolOverride),
        alloc: std.mem.Allocator,

        fn quoted(self: @This(), a: std.mem.Allocator, raw_s: []const u8) !void {
            _ = self;
            _ = a;
            _ = raw_s;
            return error.MalformedPreset; // bare strings invalid here
        }
        fn object(self: @This(), a: std.mem.Allocator, raw_obj: []const u8) !void {
            var o = presets.ToolOverride{
                .tool_name = (try extractOwnedString(a, raw_obj, "tool_name")) orelse
                    return error.MalformedPreset,
            };
            errdefer a.free(o.tool_name);
            o.disabled = parseBool(raw_obj, "disabled");
            if (try extractRawJsonValue(a, raw_obj, "config_json")) |cj| o.config_json = cj;
            try self.list.append(a, o);
        }
    };
    var overrides: std.ArrayList(presets.ToolOverride) = .empty;
    if (sliceArrayField(doc, "tool_config")) |arr| {
        errdefer freeOverrides(alloc, overrides.items);
        try splitTopLevel(arr, alloc, OCtx{ .list = &overrides, .alloc = alloc });
        if (overrides.items.len > 0) spec.tool_config = try overrides.toOwnedSlice(alloc);
    } else {
        overrides.deinit(alloc);
    }
    return spec;
}

fn freeOverrides(alloc: std.mem.Allocator, items: []const presets.ToolOverride) void {
    for (items) |o| {
        alloc.free(o.tool_name);
        if (o.config_json) |c| alloc.free(c);
    }
}

fn unescape(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            try out.append(alloc, switch (raw[i]) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'b' => 8,
                'f' => 12,
                else => raw[i],
            });
        } else {
            try out.append(alloc, raw[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Extract `"key":<json value>` as decoded JSON text (objects/arrays keep
/// their exact source span; scalars are decoded). Caller frees.
fn extractRawJsonValue(alloc: std.mem.Allocator, hay: []const u8, key: []const u8) !?[]u8 {
    var nb: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, hay, needle) orelse return null;
    const start = skipWs(hay, pos + needle.len);
    if (start >= hay.len) return null;
    switch (hay[start]) {
        '{' => {
            const end = findMatchingBrace(hay, start) orelse return error.MalformedPreset;
            return try alloc.dupe(u8, hay[start..end]);
        },
        '[' => {
            const end = matchingBracket(hay, start) orelse return error.MalformedPreset;
            return try alloc.dupe(u8, hay[start..end]);
        },
        '"' => {
            const raw = (try extractOwnedString(alloc, hay, key)) orelse return null;
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            try out.append(alloc, '"');
            try escapeInto(alloc, raw, &out);
            try out.append(alloc, '"');
            alloc.free(raw);
            return try out.toOwnedSlice(alloc);
        },
        'n', 't', 'f' => return null, // null/false/true → treat as absent
        else => return null,
    }
}

// ── store ───────────────────────────────────────────────────────────────────

pub const CustomStore = struct {
    alloc: std.mem.Allocator,
    /// Absolute (or cwd-relative) directory holding `<name>.json` files.
    dir_path: []const u8,

    pub fn init(alloc: std.mem.Allocator, dir_path: []const u8) CustomStore {
        return .{ .alloc = alloc, .dir_path = dir_path };
    }

    /// Default root: `<HOME>/.zharness/agent-presets`.
    pub fn initDefault(alloc: std.mem.Allocator) !CustomStore {
        return .{ .alloc = alloc, .dir_path = try defaultDirPath(alloc) };
    }

    /// Load every well-formed preset file, sorted by `order` then name.
    /// Corrupt files are skipped (never fail the whole listing). Free via
    /// `freeList`.
    pub fn list(self: *CustomStore, io: std.Io, alloc: std.mem.Allocator) ![]presets.Spec {
        const cwd = std.Io.Dir.cwd();
        const dir = std.Io.Dir.openDir(cwd, io, self.dir_path, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return try alloc.alloc(presets.Spec, 0),
            else => return e,
        };
        defer std.Io.Dir.close(dir, io);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| alloc.free(n);
            names.deinit(alloc);
        }
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .unknown) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const stem = entry.name[0 .. entry.name.len - ".json".len];
            if (!validName(stem)) continue;
            try names.append(alloc, try alloc.dupe(u8, stem));
        }

        var out: std.ArrayList(presets.Spec) = .empty;
        errdefer {
            for (out.items) |*s| presets.freeSpec(alloc, s);
            out.deinit(alloc);
        }
        for (names.items) |name| {
            const s = loadFile(alloc, io, self.dir_path, name) catch continue;
            try out.append(alloc, s);
        }
        std.mem.sort(presets.Spec, out.items, {}, lessByOrder);
        return out.toOwnedSlice(alloc);
    }

    fn lessByOrder(_: void, a: presets.Spec, b: presets.Spec) bool {
        if (a.order != b.order) return a.order < b.order;
        return std.mem.lessThan(u8, a.name, b.name);
    }

    /// Release a slice produced by `list` (specs + storage).
    pub fn freeList(_: *CustomStore, alloc: std.mem.Allocator, specs: []presets.Spec) void {
        for (specs) |*s| presets.freeSpec(alloc, s);
        alloc.free(specs);
    }

    /// Atomically write (create or overwrite) a preset file. Any Spec can
    /// be saved — builtin rows serialize their static data like customs,
    /// producing an editable user copy under a different name if desired.
    pub fn save(self: *CustomStore, io: std.Io, s: *const presets.Spec) !void {
        if (!validName(s.name)) return error.InvalidName;
        const json = try renderJson(self.alloc, s);
        defer self.alloc.free(json);

        const cwd = std.Io.Dir.cwd();
        try std.Io.Dir.createDirPath(cwd, io, self.dir_path);
        const dir = try std.Io.Dir.openDir(cwd, io, self.dir_path, .{});
        defer std.Io.Dir.close(dir, io);

        var fb: [160]u8 = undefined;
        const final_name = fileName(&fb, s.name);
        const tmp_name = ".preset.tmp";

        try std.Io.Dir.writeFile(dir, io, .{ .sub_path = tmp_name, .data = json });
        std.Io.Dir.rename(dir, tmp_name, dir, final_name, io) catch {
            std.Io.Dir.deleteFile(dir, io, tmp_name) catch {};
            return error.WriteFailed;
        };
    }

    /// Delete `<name>.json`; error.PresetNotFound when absent.
    pub fn delete(self: *CustomStore, io: std.Io, name: []const u8) !void {
        if (!validName(name)) return error.InvalidName;
        const cwd = std.Io.Dir.cwd();
        const dir = std.Io.Dir.openDir(cwd, io, self.dir_path, .{}) catch |e| switch (e) {
            error.FileNotFound => return error.PresetNotFound,
            else => return e,
        };
        defer std.Io.Dir.close(dir, io);
        var fb: [160]u8 = undefined;
        std.Io.Dir.deleteFile(dir, io, fileName(&fb, name)) catch |e| switch (e) {
            error.FileNotFound => return error.PresetNotFound,
            else => return e,
        };
    }
};

/// Load one `<dir>/<name>.json`; every field is freshly allocated.
pub fn loadFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    name: []const u8,
) !presets.Spec {
    if (!validName(name)) return error.InvalidName;
    var fb: [160]u8 = undefined;
    const rel = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, fileName(&fb, name) }) catch |e| return e;
    defer alloc.free(rel);
    const raw = std.Io.Dir.readFileAlloc(.cwd(), io, rel, alloc, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return error.UnknownPreset,
        else => return e,
    };
    defer alloc.free(raw);
    var spec = try parseDocument(alloc, raw);
    // Trust the FILENAME as identity when the body's name disagrees (the
    // stem is what users typed); rewrite in place without leaking.
    if (!std.mem.eql(u8, spec.name, name)) {
        alloc.free(spec.name);
        spec.name = try alloc.dupe(u8, name);
    }
    return spec;
}
