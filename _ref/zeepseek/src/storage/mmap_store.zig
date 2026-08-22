const std = @import("std");

fn currentTimestamp() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) == 0) {
        return tv.sec;
    }
    return 0;
}

fn fileExists(path: []const u8) bool {
    var buf: [512:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(&buf, std.posix.F_OK) == 0;
}

pub const ColdEntry = struct {
    offset: u64,
    size: u32,
};

pub const MmapStore = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    io: std.Io,
    data_dir: []const u8,
    hot_region: []align(std.heap.page_size_min) u8,
    cold_region: []align(std.heap.page_size_min) u8,
    hot_file: std.Io.File,
    cold_file: ?std.Io.File = null,
    wal_file: ?std.Io.File = null,
    wal_seq: u64 = 0,
    cold_index: std.StringHashMap(ColdEntry),
    entries: std.StringHashMap(Entry),
    seq: u64 = 0,
    hot_size: usize,
    next_hot_offset: usize = 0,
    next_cold_offset: usize = 0,
    cold_size: usize,

    const Entry = struct {
        value: []const u8,
        hot: bool,
        offset: usize,
        size: usize,
    };

    pub fn init(allocator: std.mem.Allocator, path: []const u8, hot_size: usize, cold_size: usize) !MmapStore {
        var threaded = std.Io.Threaded.init(allocator, .{});
        const io = threaded.io();
        const dir = std.Io.Dir.cwd();
        const data_dir_path = std.fs.path.dirname(path) orelse ".";
        try std.Io.Dir.createDirPath(dir, io, data_dir_path);

        const hot_file = try std.Io.Dir.createFileAbsolute(io, path, .{
            .truncate = true,
            .read = true,
        });
        errdefer std.Io.File.close(hot_file, io);

        const hot_path = try std.mem.concat(allocator, u8, &.{ data_dir_path, "/cold.mdb" });
        defer allocator.free(hot_path);

        const cold_file = try std.Io.Dir.createFileAbsolute(io, hot_path, .{
            .truncate = true,
            .read = true,
        });
        errdefer std.Io.File.close(cold_file, io);

        try std.Io.File.setLength(hot_file, io, @intCast(hot_size));
        try std.Io.File.setLength(cold_file, io, @intCast(cold_size));

        const hot_region = try std.posix.mmap(null, hot_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, hot_file.handle, 0);
        const cold_region = std.posix.mmap(null, cold_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, cold_file.handle, 0) catch blk: {
            var empty: [0]u8 align(std.heap.page_size_min) = .{};
            break :blk @as([]align(std.heap.page_size_min) u8, &empty);
        };

        return MmapStore{
            .allocator = allocator,
            .threaded = threaded,
            .io = io,
            .data_dir = try allocator.dupe(u8, data_dir_path),
            .hot_region = hot_region,
            .cold_region = cold_region,
            .hot_file = hot_file,
            .cold_file = cold_file,
            .wal_file = null,
            .wal_seq = 0,
            .cold_index = std.StringHashMap(ColdEntry).init(allocator),
            .entries = std.StringHashMap(Entry).init(allocator),
            .hot_size = hot_size,
            .cold_size = cold_size,
        };
    }

    pub fn deinit(self: *MmapStore) void {
        if (self.wal_file) |*f| {
            std.Io.File.close(f.*, self.io);
        }
        self.cold_index.deinit();
        self.entries.deinit();
        std.posix.munmap(self.hot_region);
        if (self.cold_region.len > 0) {
            std.posix.munmap(self.cold_region);
        }
        std.Io.File.close(self.hot_file, self.io);
        if (self.cold_file) |*f| std.Io.File.close(f.*, self.io);
        self.threaded.deinit();
        self.allocator.free(self.data_dir);
    }

    pub fn enableWal(self: *MmapStore, wal_path: []const u8) !void {
        const wal_dir = std.fs.path.dirname(wal_path) orelse self.data_dir;
        std.Io.Dir.createDirPath(.cwd(), self.io, wal_dir) catch {};
        self.wal_file = try std.Io.Dir.createFileAbsolute(self.io, wal_path, .{
            .truncate = false,
            .read = true,
        });
        self.wal_seq = 0;
    }

    pub fn walInit(self: *MmapStore, db_path: []const u8) !void {
        const wal_path = try std.fmt.allocPrint(self.allocator, "{s}.wal", .{db_path});
        defer self.allocator.free(wal_path);
        self.wal_file = try std.Io.Dir.createFileAbsolute(self.io, wal_path, .{
            .truncate = false,
            .read = true,
        });
        self.wal_seq = 0;
    }

    /// Max WAL entry size (op + 2 len fields + key + value + seq + ts).
    /// Keeps entries well under walReplay's read buffer.
    const MAX_WAL_ENTRY: usize = 64 * 1024;

    pub fn walAppend(self: *MmapStore, op: enum(u8) { put = 1, delete = 2 }, key: []const u8, value: []const u8) !void {
        if (self.wal_file) |f| {
            const total: usize = 1 + 4 + key.len + 4 + value.len + 8 + 8;
            if (total > MAX_WAL_ENTRY) return error.WalEntryTooLarge;

            const buf = try self.allocator.alloc(u8, total);
            defer self.allocator.free(buf);
            var offset: usize = 0;

            buf[offset] = @as(u8, if (op == .put) 1 else 2);
            offset += 1;

            std.mem.writeInt(u32, buf[offset..][0..4], @as(u32, @intCast(key.len)), .little);
            offset += 4;
            @memcpy(buf[offset..offset + key.len], key);
            offset += key.len;

            std.mem.writeInt(u32, buf[offset..][0..4], @as(u32, @intCast(value.len)), .little);
            offset += 4;
            @memcpy(buf[offset..offset + value.len], value);
            offset += value.len;

            std.mem.writeInt(u64, buf[offset..][0..8], self.wal_seq, .little);
            offset += 8;
            self.wal_seq += 1;

            std.mem.writeInt(i64, buf[offset..][0..8], currentTimestamp(), .little);
            offset += 8;

            try std.Io.File.writePositionalAll(f, self.io, buf[0..offset], 0);
            try std.Io.File.sync(f, self.io);
        }
    }

    pub fn walReplay(self: *MmapStore) !void {
        if (self.wal_file) |f| {
            var buf: [MAX_WAL_ENTRY + 64]u8 = undefined;
            var pos: u64 = 0;

            while (true) {
                const n = std.posix.read(f.handle, &buf) catch break;
                if (n == 0) break;

                var offset: usize = 0;
                while (offset < n) {
                    const op = buf[offset];
                    offset += 1;

                    if (offset + 4 > n) break;
                    const kl = std.mem.readInt(u32, buf[offset..][0..4], .little);
                    offset += 4;
                    if (kl > MAX_WAL_ENTRY) break; // corrupt/untrusted length

                    if (offset + kl > n) break;
                    const k = try self.allocator.alloc(u8, kl);
                    @memcpy(k, buf[offset..offset + kl]);
                    offset += kl;

                    if (offset + 4 > n) {
                        self.allocator.free(k);
                        break;
                    }
                    const vl = std.mem.readInt(u32, buf[offset..][0..4], .little);
                    offset += 4;
                    if (vl > MAX_WAL_ENTRY) break; // corrupt/untrusted length

                    if (offset + vl > n) {
                        self.allocator.free(k);
                        break;
                    }
                    const v = try self.allocator.alloc(u8, vl);
                    @memcpy(v, buf[offset..offset + vl]);
                    offset += vl;

                    if (offset + 8 > n) {
                        self.allocator.free(k);
                        self.allocator.free(v);
                        break;
                    }
                    offset += 8;

                    if (offset + 8 > n) {
                        self.allocator.free(k);
                        self.allocator.free(v);
                        break;
                    }
                    offset += 8;

                    if (op == 1) {
                        try self.putAssumeWal(k, v);
                    } else {
                        self.deleteAssumeWal(k);
                    }
                }
                pos += @as(u64, @intCast(n));
            }
        }
    }

    pub fn walCheckpoint(self: *MmapStore) !void {
        if (self.wal_file) |f| {
            try std.Io.File.setLength(f, self.io, 0);
            try std.Io.File.sync(f, self.io);
            self.wal_seq = 0;
        }
    }

    pub fn recoverWal(self: *MmapStore, wal_path: []const u8) !void {
        if (!fileExists(wal_path)) return;
        self.wal_file = try std.Io.Dir.openFileAbsolute(self.io, wal_path, .{
            .mode = .read_write,
        });
        try self.walReplay();
    }

    pub fn putAssumeWal(self: *MmapStore, key: []const u8, value: []const u8) !void {
        try self.putInternal(key, value);
    }

    pub fn deleteAssumeWal(self: *MmapStore, key: []const u8) void {
        self.deleteInternal(key);
    }

    pub fn putInternal(self: *MmapStore, key: []const u8, value: []const u8) !void {
        const is_hot = self.entries.count() < 4096;
        const region = if (is_hot) self.hot_region else self.cold_region;
        const region_size = if (is_hot) self.hot_size else self.cold_size;

        if (self.entries.get(key)) |old| {
            if (old.hot == is_hot) {
                const new_entry = Entry{
                    .value = value,
                    .hot = is_hot,
                    .offset = old.offset,
                    .size = value.len,
                };
                if (new_entry.offset + value.len <= region_size) {
                    @memcpy(region[new_entry.offset..new_entry.offset + value.len], value);
                    try self.entries.put(key, new_entry);
                    self.seq += 1;
                    return;
                }
            }
        }

        const offset = self.findFreeSlot(region_size, value.len) orelse {
            return error.OutOfMemory;
        };

        if (offset + value.len <= region_size) {
            @memcpy(region[offset..offset + value.len], value);
        }

        const entry = Entry{
            .value = value,
            .hot = is_hot,
            .offset = offset,
            .size = value.len,
        };

        try self.entries.put(key, entry);
        self.seq += 1;
    }

    pub fn deleteInternal(self: *MmapStore, key: []const u8) void {
        _ = self.entries.remove(key);
    }

    pub fn put(self: *MmapStore, key: []const u8, value: []const u8) !void {
        try self.putInternal(key, value);
        try self.walAppend(.put, key, value);
    }

    pub fn delete(self: *MmapStore, key: []const u8) !void {
        self.deleteInternal(key);
        try self.walAppend(.delete, key, &.{});
    }

    pub fn get(self: *MmapStore, key: []const u8) ?[]const u8 {
        if (self.entries.get(key)) |entry| {
            return entry.value;
        }
        return self.getFromCold(key);
    }

    pub fn list(self: *MmapStore, prefix: []const u8) []const []const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        self.listWithPrefix(prefix, &result);
        return result.toOwnedSlice(self.allocator) catch &[0][]const u8{};
    }

    pub fn listWithPrefix(self: *MmapStore, prefix: []const u8, results: *std.ArrayList([]const u8)) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                results.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
    }

    pub fn coldTierInit(self: *MmapStore, db_path: []const u8) !void {
        const cold_path = try std.fmt.allocPrint(self.allocator, "{s}.cold", .{db_path});
        defer self.allocator.free(cold_path);
        self.cold_file = try std.Io.Dir.createFileAbsolute(self.io, cold_path, .{
            .truncate = false,
            .read = true,
        });
        self.cold_index = std.StringHashMap(ColdEntry).init(self.allocator);
    }

    pub fn flushColdTier(self: *MmapStore) !void {
        if (self.cold_file == null) return;

        if (self.entries.count() < 4096) return;

        const file = self.cold_file.?;
        const end_pos = try std.Io.File.length(file, self.io);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.hot) {
                const ce = ColdEntry{
                    .offset = end_pos,
                    .size = @intCast(entry.value_ptr.size),
                };
                try std.Io.File.writePositionalAll(file, self.io, entry.value_ptr.value, end_pos);
                try self.cold_index.put(entry.key_ptr.*, ce);
            }
        }

        try std.Io.File.sync(file, self.io);
    }

    pub fn getFromCold(self: *MmapStore, key: []const u8) ?[]const u8 {
        if (self.cold_index.get(key)) |entry| {
            if (self.cold_file) |f| {
                const data = self.allocator.alloc(u8, entry.size) catch return null;
                const n = std.posix.read(f.handle, data[0..entry.size]) catch return null;
                if (n != entry.size) {
                    self.allocator.free(data);
                    return null;
                }
                return data;
            }
        }
        return null;
    }

    pub fn checkpoint(self: *MmapStore) !void {
        try self.walCheckpoint();
    }

    pub fn close(self: *MmapStore) void {
        std.Io.File.sync(self.hot_file, self.io) catch {};
        if (self.cold_file) |f| std.Io.File.sync(f, self.io) catch {};
        if (self.wal_file) |f| std.Io.File.sync(f, self.io) catch {};
    }

    pub fn defragmentIfNeeded(self: *MmapStore, threshold: f32) void {
        _ = self;
        _ = threshold;
    }

    /// Sequential cursor allocation per tier. Slots are never reclaimed
    /// (no bitmap) — acceptable for a WAL-backed store where entries are
    /// rewritten in place by key; a full region returns OutOfMemory.
    fn findFreeSlot(self: *MmapStore, region_size: usize, size: usize) ?usize {
        const is_hot = self.entries.count() < 4096;
        const next = if (is_hot) self.next_hot_offset else self.next_cold_offset;
        if (next + size > region_size) return null;
        if (is_hot)
            self.next_hot_offset = next + size
        else
            self.next_cold_offset = next + size;
        return next;
    }

    pub fn persistMeta(self: *MmapStore, meta_path: []const u8) !void {
        _ = self;
        _ = meta_path;
    }
};
