//! Session checkpointing (dev.md §XVI).
//!
//! Snapshots of an agent transcript are plain JSON files `NNNNNN.json` inside
//! one directory (main.zig wires `<session_dir>/checkpoints`). Every save is
//! atomic (tmp file + rename), ids are derived statelessly from the directory
//! contents (max existing id + 1) so separate store instances agree, and the
//! store prunes itself down to `max_checkpoints` newest files.
//!
//! Integration contract:
//!   - AgentLoop calls CheckpointStore.save(io, label, messages) at turn
//!     boundaries and after tool batches.
//!   - CLI later exposes `--checkpoint N` resume / fork-on-resume semantics;
//!     `load` returns a deep copy owned by the caller's allocator.
//!
//! Deliberately self-contained: SnapshotMessage duplicates the session
//! message shape (trivial mapping at the wiring site) so this module stays
//! testable in isolation (`zig test -lc src/session/checkpoint.zig`).
//! JSON helpers are adapted from src/session/session.zig.
//!
//! Errors: save fails on filesystem errors (WriteFailed after a failed
//! publish leaves no tmp residue); load raises CheckpointNotFound /
//! MalformedCheckpoint; list skips corrupt entries instead of failing.

const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn asStr(self: Role) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return null;
    }
};

pub const SnapshotMessage = struct {
    role: Role,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_calls_json: ?[]const u8 = null,
};

pub const CheckpointMeta = struct {
    id: u32,
    label: []const u8,
    created_at: i64,
    message_count: usize,

    pub fn deinit(self: *const CheckpointMeta, alloc: std.mem.Allocator) void {
        alloc.free(self.label);
    }
};

pub const Checkpoint = struct {
    id: u32,
    label: []const u8,
    created_at: i64,
    messages: []SnapshotMessage,

    /// Deep-free all memory owned by this loaded checkpoint.
    pub fn deinit(self: *Checkpoint, alloc: std.mem.Allocator) void {
        alloc.free(self.label);
        for (self.messages) |m| {
            alloc.free(m.content);
            if (m.tool_call_id) |t| alloc.free(t);
            if (m.tool_calls_json) |t| alloc.free(t);
        }
        alloc.free(self.messages);
    }
};

pub const CheckpointStore = struct {
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    /// Newest N kept; older checkpoints are deleted after each save.
    max_checkpoints: usize = 50,

    pub fn init(alloc: std.mem.Allocator, dir_path: []const u8) !CheckpointStore {
        return .{
            .alloc = alloc,
            .dir_path = try alloc.dupe(u8, dir_path),
        };
    }

    pub fn deinit(self: *CheckpointStore) void {
        self.alloc.free(self.dir_path);
    }

    /// Monotonic id bookkeeping lives in an `_index.json` sidecar ({"last":N}).
    /// save writes a NEW higher id and refreshes the index; pruning removes
    /// only OLD files, so the indexed last id stays valid forever. Enumeration
    /// walks downward from it, tolerating arbitrary gaps left by pruning.
    /// If the index is lost, we fall back to a bounded upward probe and heal
    /// the index on the spot.
    /// Persist a snapshot atomically; returns its assigned id (always strictly
    /// greater than every earlier id, even across prunes).
    pub fn save(
        self: *CheckpointStore,
        io: std.Io,
        label: []const u8,
        created_at: i64,
        messages: []const SnapshotMessage,
    ) !u32 {
        const cwd = std.Io.Dir.cwd();
        try std.Io.Dir.createDirPath(cwd, io, self.dir_path);

        const id = try self.nextId(io);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "{\"id\":");
        try appendInt(self.alloc, &out, id);
        try out.appendSlice(self.alloc, ",\"label\":\"");
        try escapeInto(self.alloc, label, &out);
        try out.appendSlice(self.alloc, "\",\"created_at\":");
        try appendInt(self.alloc, &out, created_at);
        try out.appendSlice(self.alloc, ",\"messages\":[");
        for (messages, 0..) |m, i| {
            if (i > 0) try out.appendSlice(self.alloc, ",");
            try out.appendSlice(self.alloc, "{\"role\":\"");
            try out.appendSlice(self.alloc, m.role.asStr());
            try out.appendSlice(self.alloc, "\",\"content\":\"");
            try escapeInto(self.alloc, m.content, &out);
            try out.appendSlice(self.alloc, "\",\"tool_call_id\":");
            try appendOptString(self.alloc, &out, m.tool_call_id);
            try out.appendSlice(self.alloc, ",\"tool_calls_json\":");
            try appendOptString(self.alloc, &out, m.tool_calls_json);
            try out.appendSlice(self.alloc, "}");
        }
        try out.appendSlice(self.alloc, "]}");

        var nb: [32]u8 = undefined;
        const final_name = idFileName(&nb, id);
        const tmp_name = ".checkpoint.tmp";

        const dir = try std.Io.Dir.openDir(cwd, io, self.dir_path, .{});
        defer std.Io.Dir.close(dir, io);

        try std.Io.Dir.writeFile(dir, io, .{ .sub_path = tmp_name, .data = out.items });
        std.Io.Dir.rename(dir, tmp_name, dir, final_name, io) catch {
            std.Io.Dir.deleteFile(dir, io, tmp_name) catch {};
            return error.WriteFailed;
        };

        try self.writeIndex(io, id);
        try self.prune(io);
        return id;
    }

    /// Load a checkpoint; every string is freshly allocated from `alloc`
    /// (free via Checkpoint.deinit).
    pub fn load(self: *CheckpointStore, io: std.Io, alloc: std.mem.Allocator, id: u32) !Checkpoint {
        var nb: [32]u8 = undefined;
        const fname = idFileName(&nb, id);
        const cwd = std.Io.Dir.cwd();
        const dir = std.Io.Dir.openDir(cwd, io, self.dir_path, .{}) catch |e| switch (e) {
            error.FileNotFound => return error.CheckpointNotFound,
            else => return e,
        };
        defer std.Io.Dir.close(dir, io);
        const raw = std.Io.Dir.readFileAlloc(dir, io, fname, alloc, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return error.CheckpointNotFound,
            else => return e,
        };
        defer alloc.free(raw);

        var cp = Checkpoint{
            .id = id,
            .label = try alloc.dupe(u8, ""),
            .created_at = 0,
            .messages = try alloc.alloc(SnapshotMessage, 0),
        };
        errdefer cp.deinit(alloc);

        const stored_id = parseUintAfter(raw, "\"id\":") orelse return error.MalformedCheckpoint;
        if (stored_id > std.math.maxInt(u32)) return error.MalformedCheckpoint;
        cp.id = @intCast(stored_id);
        const label = (try extractOwnedString(alloc, raw, "label")) orelse return error.MalformedCheckpoint;
        alloc.free(cp.label);
        cp.label = label;
        cp.created_at = @intCast(parseUintAfter(raw, "\"created_at\":") orelse return error.MalformedCheckpoint);

        const arr = sliceArrayField(raw, "messages") orelse return error.MalformedCheckpoint;
        var msgs: std.ArrayList(SnapshotMessage) = .empty;
        errdefer msgs.deinit(alloc);
        var i: usize = 1; // skip '['
        while (i < arr.len - 1) {
            if (arr[i] != '{') {
                i += 1;
                continue;
            }
            const obj_end = findMatchingBrace(arr, i) orelse return error.MalformedCheckpoint;
            const obj = arr[i..obj_end];
            const role_s = extractRawQuoted(obj, "role") orelse return error.MalformedCheckpoint;
            const content = (try extractOwnedString(alloc, obj, "content")) orelse try alloc.dupe(u8, "");
            errdefer alloc.free(content);
            const tcid = try extractOwnedString(alloc, obj, "tool_call_id");
            const tcj = try extractOwnedString(alloc, obj, "tool_calls_json");
            try msgs.append(alloc, .{
                .role = Role.fromStr(role_s) orelse return error.MalformedCheckpoint,
                .content = content,
                .tool_call_id = tcid,
                .tool_calls_json = tcj,
            });
            i = obj_end;
        }
        cp.messages = try msgs.toOwnedSlice(alloc);
        return cp;
    }

    /// Metadata of the newest checkpoint, or null when none exist.
    pub fn latest(self: *CheckpointStore, io: std.Io) !?CheckpointMeta {
        const metas = try self.list(io, self.alloc);
        defer {
            for (metas) |m| m.deinit(self.alloc);
            self.alloc.free(metas);
        }
        if (metas.len == 0) return null;
        const m = metas[metas.len - 1];
        return CheckpointMeta{
            .id = m.id,
            .label = try self.alloc.dupe(u8, m.label),
            .created_at = m.created_at,
            .message_count = m.message_count,
        };
    }

    /// Metadata for all stored checkpoints in ascending-id order, allocated
    /// from `alloc` (free each label via Meta.deinit + free the slice).
    /// Walks downward from the indexed newest id; corrupt entries are skipped
    /// rather than failing the listing.
    pub fn list(self: *CheckpointStore, io: std.Io, alloc: std.mem.Allocator) ![]CheckpointMeta {
        var metas: std.ArrayList(CheckpointMeta) = .empty;
        errdefer {
            for (metas.items) |m| m.deinit(alloc);
            metas.deinit(alloc);
        }
        const cwd = std.Io.Dir.cwd();
        const dir = std.Io.Dir.openDir(cwd, io, self.dir_path, .{}) catch |e| switch (e) {
            error.FileNotFound => return try alloc.alloc(CheckpointMeta, 0),
            else => return e,
        };
        defer std.Io.Dir.close(dir, io);

        var nb: [32]u8 = undefined;
        // Walk DOWNWARD from the indexed newest id: pruning leaves arbitrary
        // gaps below, and directory iteration proved unreliable here. A few
        // consecutive misses below the oldest survivor end the walk.
        var id = (try self.readLastIndexed(io)) orelse try self.probeUpLast(io);
        if (id == 0) return try alloc.alloc(CheckpointMeta, 0);

        var misses: u32 = 0;
        while (id > 0 and misses < 3) : (id -= 1) {
            const raw = std.Io.Dir.readFileAlloc(dir, io, idFileName(&nb, id), alloc, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
                error.FileNotFound => {
                    misses += 1;
                    continue;
                },
                else => return e,
            };
            defer alloc.free(raw);
            misses = 0;
            // Malformed/corrupt files are skipped, not fatal.
            const label = (try extractOwnedString(alloc, raw, "label")) orelse continue;
            const created = parseUintAfter(raw, "\"created_at\":") orelse {
                alloc.free(label);
                continue;
            };
            try metas.append(alloc, .{
                .id = id,
                .label = label,
                .created_at = @intCast(created),
                .message_count = countMessages(raw),
            });
        }
        std.mem.reverse(CheckpointMeta, metas.items);
        return metas.toOwnedSlice(alloc);
    }

    /// Highest stored id per the `_index.json` sidecar; null when the index
    /// is absent or unreadable (caller falls back to probing).
    fn readLastIndexed(self: *CheckpointStore, io: std.Io) !?u32 {
        const cwd = std.Io.Dir.cwd();
        const dir = std.Io.Dir.openDir(cwd, io, self.dir_path, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer std.Io.Dir.close(dir, io);
        const raw = std.Io.Dir.readFileAlloc(dir, io, INDEX_FILE, self.alloc, .limited(4096)) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer self.alloc.free(raw);
        const v = parseUintAfter(raw, "\"last\":") orelse return null;
        if (v > std.math.maxInt(u32)) return null;
        return @intCast(v);
    }

    /// Refresh the sidecar index (hint file only; plain overwrite is fine).
    fn writeIndex(self: *CheckpointStore, io: std.Io, last: u32) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "{\"last\":");
        try appendInt(self.alloc, &out, last);
        try out.appendSlice(self.alloc, "}");
        const cwd = std.Io.Dir.cwd();
        const dir = try std.Io.Dir.openDir(cwd, io, self.dir_path, .{});
        defer std.Io.Dir.close(dir, io);
        try std.Io.Dir.writeFile(dir, io, .{ .sub_path = INDEX_FILE, .data = out.items });
    }

    /// Bounded upward filename probe for the highest existing id. Used only
    /// to heal a lost index; O(gap below lowest surviving id) worst case.
    fn probeUpLast(self: *const CheckpointStore, io: std.Io) !u32 {
        const cwd = std.Io.Dir.cwd();
        const dir = std.Io.Dir.openDir(cwd, io, self.dir_path, .{}) catch |e| switch (e) {
            error.FileNotFound => return 0,
            else => return e,
        };
        defer std.Io.Dir.close(dir, io);
        var nb: [32]u8 = undefined;
        var last: u32 = 0;
        var id: u32 = 0;
        while (id < max_scan_files) : (id += 1) {
            const f = std.Io.Dir.openFile(dir, io, idFileName(&nb, id + 1), .{}) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return e,
            };
            f.close(io);
            last = id + 1;
        }
        return last;
    }

    fn nextId(self: *CheckpointStore, io: std.Io) !u32 {
        if (try self.readLastIndexed(io)) |n| return n + 1;
        const probed = try self.probeUpLast(io);
        if (probed > 0) try self.writeIndex(io, probed);
        return probed + 1;
    }

    // ---- internals -------------------------------------------------------

    fn prune(self: *CheckpointStore, io: std.Io) !void {
        const metas = try self.list(io, self.alloc);
        defer {
            for (metas) |m| m.deinit(self.alloc);
            self.alloc.free(metas);
        }
        if (metas.len <= self.max_checkpoints) return;
        const cwd = std.Io.Dir.cwd();
        const dir = std.Io.Dir.openDir(cwd, io, self.dir_path, .{}) catch return;
        defer std.Io.Dir.close(dir, io);
        var over = metas.len - self.max_checkpoints;
        for (metas) |m| {
            if (over == 0) break;
            var nb: [32]u8 = undefined;
            std.Io.Dir.deleteFile(dir, io, idFileName(&nb, m.id)) catch {};
            over -= 1;
        }
    }
};

// ── shared small helpers (self-contained by design) ────────────────────────

/// Hard cap on filename probing during enumeration; far above any realistic
/// checkpoint count.
const max_scan_files: u32 = 4096;

/// Sidecar hint recording the newest checkpoint id (see CheckpointStore).
const INDEX_FILE = "_index.json";

fn idFileName(buf: *[32]u8, id: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>6}.json", .{id}) catch unreachable;
}

fn appendInt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: anytype) !void {
    var b: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{d}", .{v}) catch return;
    try out.appendSlice(alloc, s);
}

/// Adapted from src/session/session.zig escapeInto.
fn escapeInto(alloc: std.mem.Allocator, input: []const u8, buf: *std.ArrayList(u8)) !void {
    for (input) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
}

fn appendOptString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: ?[]const u8) !void {
    if (v) |s| {
        try out.appendSlice(alloc, "\"");
        try escapeInto(alloc, s, out);
        try out.appendSlice(alloc, "\"");
    } else {
        try out.appendSlice(alloc, "null");
    }
}

/// Raw (still-escaped) value slice for `"key":"..."`.
fn extractRawQuoted(hay: []const u8, key: []const u8) ?[]const u8 {
    var nb: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, hay, needle) orelse return null;
    var i = pos + needle.len;
    while (i < hay.len and (hay[i] == ' ' or hay[i] == '\t')) : (i += 1) {}
    if (i >= hay.len or hay[i] != '"') return null;
    i += 1;
    const vs = i;
    while (i < hay.len and hay[i] != '"') : (i += 1) {
        if (hay[i] == '\\' and i + 1 < hay.len) i += 1;
    }
    return hay[vs..i];
}

/// Decoded copy of `"key":"..."`; caller frees. Null when the key is absent
/// or its value is JSON null (downstream treats both identically).
fn extractOwnedString(alloc: std.mem.Allocator, hay: []const u8, key: []const u8) !?[]const u8 {
    const raw = extractRawQuoted(hay, key) orelse return null;
    return try unescapeInto(alloc, raw);
}

fn unescapeInto(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            switch (input[i]) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                't' => try out.append(alloc, '\t'),
                else => try out.append(alloc, input[i]),
            }
        } else {
            try out.append(alloc, input[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn parseUintAfter(hay: []const u8, needle: []const u8) ?u64 {
    const p = std.mem.indexOf(u8, hay, needle) orelse return null;
    var i = p + needle.len;
    while (i < hay.len and (hay[i] == ' ' or hay[i] == '\t')) : (i += 1) {}
    var v: u64 = 0;
    var any = false;
    while (i < hay.len and std.ascii.isDigit(hay[i])) : (i += 1) {
        v = v * 10 + (hay[i] - '0');
        any = true;
        if (v > 1 << 45) return null;
    }
    return if (any) v else null;
}

/// Slice covering `[...]` inclusive for the given top-level array field.
fn sliceArrayField(hay: []const u8, key: []const u8) ?[]const u8 {
    var nb: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"{s}\":[", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, hay, needle) orelse return null;
    const start = pos + needle.len - 1; // points at '['
    const end = findMatchingBracket(hay, start) orelse return null; // exclusive
    return hay[start..end];
}

fn countMessages(raw: []const u8) usize {
    const arr = sliceArrayField(raw, "messages") orelse return 0;
    var n: usize = 0;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    for (arr) |c| {
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) n += 1;
            },
            else => {},
        }
    }
    return n;
}

fn findMatchingBrace(json: []const u8, start: usize) ?usize {
    if (start >= json.len or json[start] != '{') return null;
    var count: i32 = 1;
    var i = start + 1;
    while (i < json.len and count > 0) : (i += 1) {
        switch (json[i]) {
            '{' => count += 1,
            '}' => count -= 1,
            '"' => {
                i += 1;
                while (i < json.len and json[i] != '"') : (i += 1) {
                    if (json[i] == '\\') i += 1;
                }
            },
            else => {},
        }
    }
    if (count == 0) return i;
    return null;
}

fn findMatchingBracket(json: []const u8, start: usize) ?usize {
    if (start >= json.len or json[start] != '[') return null;
    var count: i32 = 1;
    var i = start + 1;
    while (i < json.len and count > 0) : (i += 1) {
        switch (json[i]) {
            '[' => count += 1,
            ']' => count -= 1,
            '{' => {
                // Skip nested object wholesale; back off one so the loop's
                // increment re-examines the char right after it.
                if (findMatchingBrace(json, i)) |be| {
                    i = be - 1;
                    continue;
                }
                return null;
            },
            '"' => {
                i += 1;
                while (i < json.len and json[i] != '"') : (i += 1) {
                    if (json[i] == '\\') i += 1;
                }
            },
            else => {},
        }
    }
    if (count == 0) return i;
    return null;
}

// ── tests ───────────────────────────────────────────────────────────────────

extern "c" fn time(tloc: ?*c_long) c_long;

/// Seconds since epoch (libc time(2)); std.time lost its clock fns in 0.17.
fn nowSecs() i64 {
    return @intCast(time(null));
}

var env_counter: u32 = 0;

const TestEnv = struct {
    t: std.Io.Threaded,
    dir: []u8,

    fn setup(alloc: std.mem.Allocator) !TestEnv {
        env_counter += 1;
        // Threaded must own a threadsafe, test-independent allocator for its
        // internal worker machinery; std.testing.allocator breaks dir
        // iteration here.
        const t = std.Io.Threaded.init(std.heap.page_allocator, .{});
        return .{
            .t = t,
            .dir = try std.fmt.allocPrint(alloc, "/tmp/zh_cp_{d}_{d}", .{ nowSecs(), env_counter }),
        };
    }
    fn io(self: *TestEnv) std.Io {
        return self.t.io();
    }
    fn teardown(self: *TestEnv, alloc: std.mem.Allocator) void {
        defer self.t.deinit();
        defer alloc.free(self.dir);
        // dir looks like "/tmp/zh_cp_<secs>_<n>": open /tmp and remove the
        // subtree by basename (deleteTree is namespace-level on Dir).
        const slash = std.mem.lastIndexOfScalar(u8, self.dir, '/') orelse return;
        const cwd = std.Io.Dir.cwd();
        const parent = std.Io.Dir.openDir(cwd, self.io(), self.dir[0..slash], .{}) catch return;
        defer std.Io.Dir.close(parent, self.io());
        std.Io.Dir.deleteTree(parent, self.io(), self.dir[slash + 1 ..]) catch {};
    }
};

test "save/load roundtrip preserves fields and optionals" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);

    var store = try CheckpointStore.init(alloc, env.dir);
    defer store.deinit();

    const msgs = [_]SnapshotMessage{
        .{ .role = .user, .content = "line1\nline2 \"quoted\"" },
        .{ .role = .assistant, .content = "calling", .tool_calls_json = "[{\"id\":\"c1\"}]" },
        .{ .role = .tool, .content = "result", .tool_call_id = "c1" },
    };
    const id = try store.save(env.io(), "turn 1 pre-tool", 1700000000, &msgs);
    try std.testing.expectEqual(@as(u32, 1), id);

    var cp = try store.load(env.io(), alloc, id);
    defer cp.deinit(alloc);
    try std.testing.expectEqualStrings("turn 1 pre-tool", cp.label);
    try std.testing.expectEqual(@as(i64, 1700000000), cp.created_at);
    try std.testing.expectEqual(msgs.len, cp.messages.len);
    try std.testing.expectEqualStrings(msgs[0].content, cp.messages[0].content);
    try std.testing.expect(cp.messages[0].tool_call_id == null);
    try std.testing.expectEqualStrings("c1", cp.messages[2].tool_call_id.?);
    try std.testing.expectEqualStrings("[{\"id\":\"c1\"}]", cp.messages[1].tool_calls_json.?);
    try std.testing.expect(cp.messages[2].tool_calls_json == null);
}

test "stateless ids continue across store instances" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);

    var a = try CheckpointStore.init(alloc, env.dir);
    defer a.deinit();
    _ = try a.save(env.io(), "one", 1, &.{.{ .role = .user, .content = "x" }});

    var b = try CheckpointStore.init(alloc, env.dir);
    defer b.deinit();
    const id2 = try b.save(env.io(), "two", 2, &.{.{ .role = .user, .content = "y" }});
    try std.testing.expectEqual(@as(u32, 2), id2);
}

test "latest and list ordering with meta fields" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);

    var store = try CheckpointStore.init(alloc, env.dir);
    defer store.deinit();

    const none = try store.latest(env.io());
    try std.testing.expect(none == null);

    _ = try store.save(env.io(), "first", 10, &.{.{ .role = .user, .content = "a" }});
    _ = try store.save(env.io(), "second", 20, &.{ .{ .role = .user, .content = "b" }, .{ .role = .assistant, .content = "c" } });

    const lat = (try store.latest(env.io())).?;
    defer lat.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 2), lat.id);
    try std.testing.expectEqualStrings("second", lat.label);
    try std.testing.expectEqual(@as(usize, 2), lat.message_count);

    const metas = try store.list(env.io(), alloc);
    defer {
        for (metas) |m| m.deinit(alloc);
        alloc.free(metas);
    }
    try std.testing.expectEqual(@as(usize, 2), metas.len);
    try std.testing.expect(metas[0].id < metas[1].id);
    try std.testing.expectEqualStrings("first", metas[0].label);
}

test "prune keeps max_checkpoints newest" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);

    var store = try CheckpointStore.init(alloc, env.dir);
    defer store.deinit();
    store.max_checkpoints = 3;

    for (0..5) |_| _ = try store.save(env.io(), "cp", 0, &.{.{ .role = .user, .content = "m" }});
    const metas = try store.list(env.io(), alloc);
    defer {
        for (metas) |m| m.deinit(alloc);
        alloc.free(metas);
    }
    try std.testing.expectEqual(store.max_checkpoints, metas.len);
    try std.testing.expectEqual(@as(u32, 5), metas[metas.len - 1].id); // newest survived
    // Oldest (id 1) must be gone.
    try std.testing.expectError(error.CheckpointNotFound, store.load(env.io(), alloc, 1));
}

test "corrupt checkpoint skipped by list" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.setup(alloc);
    defer env.teardown(alloc);

    var store = try CheckpointStore.init(alloc, env.dir);
    defer store.deinit();
    _ = try store.save(env.io(), "good", 1, &.{.{ .role = .user, .content = "x" }});

    const cwd = std.Io.Dir.cwd();
    const junk_path = try std.fmt.allocPrint(alloc, "{s}/999999.json", .{env.dir});
    defer alloc.free(junk_path);
    try cwd.writeFile(env.io(), .{ .sub_path = junk_path, .data = "{{{ not json" });

    const metas = try store.list(env.io(), alloc);
    defer {
        for (metas) |m| m.deinit(alloc);
        alloc.free(metas);
    }
    try std.testing.expectEqual(@as(usize, 1), metas.len);
}
