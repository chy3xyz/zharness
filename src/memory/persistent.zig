//! Persistent memory (dev.md §XIV): durable key/value facts that survive
//! process restarts, backed by a single JSON document at
//! `<dir>/memory.json` (main.zig wires ~/.zharness/memory).
//!
//! Every mutation rewrites the whole document atomically (tmp + rename).
//! The in-RAM map is authoritative between saves; `open` is tolerant of an
//! absent or corrupt file (starts empty rather than failing).
//!
//! Self-contained; standalone test via
//! `zig test -lc src/memory/persistent.zig` (needs libc for the Threaded io
//! used by tests).

const std = @import("std");

pub const max_key_len = 128;
pub const max_value_len = 64 * 1024;
const FILE_NAME = "memory.json";

pub const PersistentStore = struct {
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    map: std.StringHashMap([]const u8),

    pub fn init(alloc: std.mem.Allocator, dir_path: []const u8) !PersistentStore {
        return .{
            .alloc = alloc,
            .dir_path = try alloc.dupe(u8, dir_path),
            .map = std.StringHashMap([]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *PersistentStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.map.deinit();
        self.alloc.free(self.dir_path);
    }

    /// Load the backing document. Absent/corrupt file ⇒ empty store.
    pub fn open(self: *PersistentStore, io: std.Io) !void {
        const cwd = std.Io.Dir.cwd();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const fpath = try std.fmt.bufPrint(&pbuf, "{s}/" ++ FILE_NAME, .{self.dir_path});
        const raw = std.Io.Dir.readFileAlloc(cwd, io, fpath, self.alloc, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer self.alloc.free(raw);
        // Flat string-object scan — adapted from src/tool/builtin.zig parseArgs.
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] != '"') continue;
            i += 1;
            const ks = i;
            while (i < raw.len and raw[i] != '"') : (i += 1) {
                if (raw[i] == '\\' and i + 1 < raw.len) i += 1;
            }
            if (i >= raw.len) break;
            const key = decode(self.alloc, raw[ks..i]) catch continue;
            i += 1;
            while (i < raw.len and raw[i] != ':') : (i += 1) {}
            if (i >= raw.len) {
                self.alloc.free(key);
                break;
            }
            i += 1;
            while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
            if (i >= raw.len or raw[i] != '"') {
                self.alloc.free(key);
                continue;
            }
            i += 1;
            const vs = i;
            while (i < raw.len and raw[i] != '"') : (i += 1) {
                if (raw[i] == '\\' and i + 1 < raw.len) i += 1;
            }
            if (i > raw.len) {
                self.alloc.free(key);
                break;
            }
            const value = decode(self.alloc, raw[vs..i]) catch {
                self.alloc.free(key);
                continue;
            };
            try self.map.put(key, value);
        }
    }

    /// Upsert and persist atomically.
    pub fn put(self: *PersistentStore, io: std.Io, key: []const u8, value: []const u8) !void {
        try validateKey(key);
        if (value.len > max_value_len) return error.ValueTooLarge;

        const gop = try self.map.getOrPut(key);
        if (gop.found_existing) {
            const copy = try self.alloc.dupe(u8, value);
            self.alloc.free(gop.value_ptr.*);
            gop.value_ptr.* = copy;
        } else {
            const kcopy = try self.alloc.dupe(u8, key);
            errdefer self.alloc.free(kcopy);
            const vcopy = try self.alloc.dupe(u8, value);
            gop.key_ptr.* = kcopy;
            gop.value_ptr.* = vcopy;
        }
        try self.persist(io);
    }

    /// Caller owns the returned copy.
    pub fn get(self: *PersistentStore, alloc: std.mem.Allocator, key: []const u8) !?[]const u8 {
        const v = self.map.get(key) orelse return null;
        return try alloc.dupe(u8, v);
    }

    /// Remove a key and persist. False when the key was absent.
    pub fn delete(self: *PersistentStore, io: std.Io, key: []const u8) !bool {
        const entry = self.map.fetchRemove(key) orelse return false;
        defer {
            self.alloc.free(entry.key);
            self.alloc.free(entry.value);
        }
        try self.persist(io);
        return true;
    }

    /// Dup'd key list (free each item + the slice).
    pub fn listKeys(self: *PersistentStore, alloc: std.mem.Allocator) ![][]const u8 {
        var out = try alloc.alloc([]const u8, self.map.count());
        errdefer alloc.free(out);
        var i: usize = 0;
        var it = self.map.keyIterator();
        while (it.next()) |k| : (i += 1) {
            out[i] = try alloc.dupe(u8, k.*);
        }
        return out;
    }

    // ---- internals -------------------------------------------------------

    fn validateKey(key: []const u8) !void {
        if (key.len == 0 or key.len > max_key_len) return error.InvalidKey;
        for (key) |ch| {
            const ok = std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '-';
            if (!ok) return error.InvalidKey;
        }
    }

    /// Atomic full-document rewrite: "<path>.tmp" then rename over target.
    fn persist(self: *PersistentStore, io: std.Io) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "{");
        var first = true;
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (!first) try out.appendSlice(self.alloc, ",");
            first = false;
            try out.appendSlice(self.alloc, "\"");
            try escapeInto(self.alloc, e.key_ptr.*, &out);
            try out.appendSlice(self.alloc, "\":\"");
            try escapeInto(self.alloc, e.value_ptr.*, &out);
            try out.appendSlice(self.alloc, "\"");
        }
        try out.appendSlice(self.alloc, "}");

        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, self.dir_path);
        const dir = try std.Io.Dir.openDir(cwd, io, self.dir_path, .{});
        defer std.Io.Dir.close(dir, io);

        try std.Io.Dir.writeFile(dir, io, .{ .sub_path = FILE_NAME ++ ".tmp", .data = out.items });
        std.Io.Dir.rename(dir, FILE_NAME ++ ".tmp", dir, FILE_NAME, io) catch {
            std.Io.Dir.deleteFile(dir, io, FILE_NAME ++ ".tmp") catch {};
            return error.WriteFailed;
        };
    }
};

/// Decode simple JSON escapes — adapted from src/session/session.zig.
fn decode(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
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

// ── tests ───────────────────────────────────────────────────────────────────

extern "c" fn time(tloc: ?*c_long) c_long;

var env_counter: u32 = 0;

fn freshDir(alloc: std.mem.Allocator) ![]u8 {
    env_counter += 1;
    return std.fmt.allocPrint(alloc, "/tmp/zh_mem_{d}_{d}", .{ time(null), env_counter });
}

test "put persists across instances" {
    const alloc = std.testing.allocator;
    const dir = try freshDir(alloc);
    defer alloc.free(dir);

    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();

    {
        var s = try PersistentStore.init(alloc, dir);
        defer s.deinit();
        try s.put(io, "user.color", "cobalt blue \"dark\"");
    }
    {
        var s2 = try PersistentStore.init(alloc, dir);
        defer s2.deinit();
        try s2.open(io);
        const v = (try s2.get(alloc, "user.color")).?;
        defer alloc.free(v);
        try std.testing.expectEqualStrings("cobalt blue \"dark\"", v);
        try std.testing.expect((try s2.get(alloc, "missing")) == null);
    }
}

test "delete removes and persists" {
    const alloc = std.testing.allocator;
    const dir = try freshDir(alloc);
    defer alloc.free(dir);
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();

    var s = try PersistentStore.init(alloc, dir);
    defer s.deinit();
    try s.put(io, "gone", "soon");
    try std.testing.expect(try s.delete(io, "gone"));
    try std.testing.expect(!try s.delete(io, "gone"));
    try std.testing.expect((try s.get(alloc, "gone")) == null);
}

test "corrupt backing file tolerated" {
    const alloc = std.testing.allocator;
    const dir = try freshDir(alloc);
    defer alloc.free(dir);
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();

    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, dir);
    const junk = try std.fmt.allocPrint(alloc, "{s}/" ++ FILE_NAME, .{dir});
    defer alloc.free(junk);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = junk, .data = "{{{not json" });

    var s = try PersistentStore.init(alloc, dir);
    defer s.deinit();
    try s.open(io); // must not fail
    try s.put(io, "fresh", "1"); // and remain usable
    const v = (try s.get(alloc, "fresh")).?;
    defer alloc.free(v);
    try std.testing.expectEqualStrings("1", v);
}

test "invalid keys rejected; no tmp residue after put" {
    const alloc = std.testing.allocator;
    const dir = try freshDir(alloc);
    defer alloc.free(dir);
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();

    var s = try PersistentStore.init(alloc, dir);
    defer s.deinit();
    try std.testing.expectError(error.InvalidKey, s.put(io, "", "v"));
    try std.testing.expectError(error.InvalidKey, s.put(io, "bad key!", "v"));

    _ = try s.put(io, "ok", "v");
    const cwd = std.Io.Dir.cwd();
    const d = try std.Io.Dir.openDir(cwd, io, dir, .{});
    defer std.Io.Dir.close(d, io);
    // Only memory.json expected; assert the tmp variant is absent.
    if (std.Io.Dir.openFile(d, io, FILE_NAME ++ ".tmp", .{})) |f| {
        f.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}
}
