const std = @import("std");
const c = @import("c");
const mmap_store = @import("mmap_store.zig");
const keyspace = @import("keyspace.zig");

pub const Keyspace = keyspace.Keyspace;
pub const makeKey = keyspace.makeKey;
pub const makeKeyBounded = keyspace.makeKeyBounded;

pub const Store = mmap_store.MmapStore;

pub const StoreOptions = struct {
    data_dir: []const u8 = ".zeepseek_data",
    hot_region_size: usize = 4 * 1024 * 1024,
    cold_region_size: usize = 2 * 1024 * 1024,
    wal_enabled: bool = true,
    wal_flush_interval: u32 = 100,
    max_checkpoints: u32 = 5,
};

pub const StoreError = error{
    DatabaseCorrupted,
    OutOfMemory,
    IoError,
    KeyNotFound,
    InvalidKey,
    MmapFailed,
    WalError,
};

pub fn openStore(allocator: std.mem.Allocator, options: StoreOptions) StoreError!*Store {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const data_dir = try alloc.dupe(u8, options.data_dir);
    const data_dir_z = std.heap.page_allocator.dupeSentinel(u8, data_dir, 0) catch return error.IoError;
    defer std.heap.page_allocator.free(data_dir_z);
    _ = c.mkdir(data_dir_z.ptr, 0o755);

    const store_path = try std.mem.concat(alloc, u8, &.{ data_dir, "/data.mdb" });
    const wal_path = try std.mem.concat(alloc, u8, &.{ data_dir, "/wal.log" });
    const meta_path = try std.mem.concat(alloc, u8, &.{ data_dir, "/meta.json" });

    var store = try alloc.create(Store);
    store.* = try Store.init(alloc, store_path, options.hot_region_size, options.cold_region_size);
    errdefer store.deinit(alloc);

    if (options.wal_enabled) {
        try store.enableWal(wal_path);
    }

    const wal_path_z = std.heap.page_allocator.dupeSentinel(u8, wal_path, 0) catch return error.IoError;
    defer std.heap.page_allocator.free(wal_path_z);
    if (std.c.access(wal_path_z.ptr, std.posix.F_OK) == 0) {
        try store.recoverWal(wal_path);
        try store.checkpoint();
    }

    try store.persistMeta(meta_path);

    return store;
}

test "keyspace formatting" {
    var buf: [64]u8 = undefined;
    const key = makeKeyBounded(.session, &.{"id123", "msg", "5"}, &buf);
    try std.testing.expectEqualStrings("s:id123:msg:5", key);
}

test "keyspace cache" {
    var buf: [64]u8 = undefined;
    const key = makeKeyBounded(.cache, &.{"abc123"}, &buf);
    try std.testing.expectEqualStrings("c:abc123", key);
}

test "keyspace global" {
    var buf: [32]u8 = undefined;
    const key = makeKeyBounded(.global, &.{"config"}, &buf);
    try std.testing.expectEqualStrings("g:config", key);
}
