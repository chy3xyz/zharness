const std = @import("std");
const c = @import("c");
const mmap_store = @import("mmap_store.zig");
const recovery = @import("recovery.zig");
const migrations = @import("migrations.zig");
const keyspace = @import("keyspace.zig");

pub const Keyspace = keyspace.Keyspace;
pub const makeKey = keyspace.makeKey;

pub const StoreOptions = struct {
    data_dir: []const u8 = ".zeepseek_data",
    hot_region_size: usize = 4 * 1024 * 1024,
    cold_region_size: usize = 2 * 1024 * 1024,
    wal_enabled: bool = true,
    wal_flush_interval: u32 = 100,
    max_checkpoints: u32 = 5,
};

fn fileExists(path: []const u8) bool {
    var buf: [512:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(&buf, std.posix.F_OK) == 0;
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    inner: *mmap_store.MmapStore,
    arena: std.heap.ArenaAllocator,
    options: StoreOptions,

    pub fn init(allocator: std.mem.Allocator, options: StoreOptions) !Store {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const store_path = try std.mem.concat(alloc, u8, &.{ options.data_dir, "/data.mdb" });
        const wal_path = try std.mem.concat(alloc, u8, &.{ options.data_dir, "/wal.log" });
        const meta_path = try std.mem.concat(alloc, u8, &.{ options.data_dir, "/meta.json" });

        var inner = try alloc.create(mmap_store.MmapStore);
        inner.* = try mmap_store.MmapStore.init(allocator, store_path, options.hot_region_size, options.cold_region_size);
        errdefer inner.deinit();

        if (options.wal_enabled) {
            try inner.enableWal(wal_path);
        }

        if (fileExists(wal_path)) {
            try inner.recoverWal(wal_path);
        }

        if (options.wal_enabled) {
            try inner.checkpoint();
        }

        try inner.persistMeta(meta_path);

        _ = try migrations.migrate(alloc, inner);

        return Store{
            .allocator = alloc,
            .inner = inner,
            .arena = arena,
            .options = options,
        };
    }

    pub fn deinit(self: *Store) void {
        self.inner.checkpoint() catch {};
        self.inner.deinit();
        self.arena.deinit();
    }

    pub fn get(self: *Store, key: []const u8) ?[]const u8 {
        return self.inner.get(key);
    }

    pub fn put(self: *Store, key: []const u8, value: []const u8) !void {
        try self.inner.put(key, value);
    }

    pub fn delete(self: *Store, key: []const u8) !void {
        try self.inner.delete(key);
    }

    pub fn list(self: *Store, prefix: []const u8) []const []const u8 {
        return self.inner.list(prefix);
    }

    pub fn listBounded(self: *Store, prefix: []const u8, results: *std.ArrayList([]const u8)) void {
        self.inner.listWithPrefix(prefix, results);
    }

    pub fn close(self: *Store) void {
        self.inner.close();
    }

    pub fn checkpoint(self: *Store) !void {
        try self.inner.checkpoint();
    }

    pub fn cleanupExpired(self: *Store) void {
        _ = self;
    }
};

test "store basic" {
    const alloc = std.testing.allocator;
    const tmp_dir = "/tmp/zeepseek_test_store";
    const tmp_dir_z = std.heap.page_allocator.dupeSentinel(u8, tmp_dir, 0) catch return;
    defer std.heap.page_allocator.free(tmp_dir_z);
    _ = c.mkdir(tmp_dir_z.ptr, 0o755);

    var store = try Store.init(alloc, .{
        .data_dir = tmp_dir,
        .wal_enabled = false,
    });
    defer {
        store.deinit();
        var rm_cmd: [1024:0]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&rm_cmd, "rm -rf {s}", .{tmp_dir_z}, 0)) |cmd| {
            _ = c.system(cmd.ptr);
        } else |_| {}
    }

    try store.put("test:key1", "hello");
    const val = store.get("test:key1");
    try std.testing.expect(val != null);
    try std.testing.expectEqualSlices(u8, "hello", val.?);

    try store.put("test:key2", "world");
    const val2 = store.get("test:key2");
    try std.testing.expectEqualSlices(u8, "world", val2.?);

    try store.delete("test:key1");
    try std.testing.expect(store.get("test:key1") == null);
}

test "store keyspace" {
    const key = try makeKey(std.testing.allocator, .session, &.{"123", "msg", "5"});
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("s:123:msg:5", key);
}

test "store checkpoint" {
    const alloc = std.testing.allocator;
    const tmp_dir = "/tmp/zeepseek_test_checkpoint";
    const tmp_dir_z = std.heap.page_allocator.dupeSentinel(u8, tmp_dir, 0) catch return;
    defer std.heap.page_allocator.free(tmp_dir_z);
    _ = c.mkdir(tmp_dir_z.ptr, 0o755);

    var store = try Store.init(alloc, .{
        .data_dir = tmp_dir,
        .wal_enabled = true,
    });
    defer {
        store.deinit();
        var rm_cmd: [1024:0]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&rm_cmd, "rm -rf {s}", .{tmp_dir_z}, 0)) |cmd| {
            _ = c.system(cmd.ptr);
        } else |_| {}
    }

    try store.checkpoint();
    try std.testing.expect(true);
}
