const std = @import("std");
const mmap_store = @import("mmap_store.zig");
const Store = mmap_store.MmapStore;

pub const CURRENT_VERSION: u32 = 1;

pub const Migration = struct {
    version: u32,
    name: []const u8,
    up: *const fn (store: *Store) anyerror!void,
    down: *const fn (store: *Store) anyerror!void,
};

fn migrationV1Up(store: *Store) !void {
    try store.put("g:meta:version", "1");
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    const ts: i64 = @intCast(tv.sec);
    _ = try store.put("g:meta:created_at", try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{ts}));
}

fn migrationV1Down(store: *Store) !void {
    try store.delete("g:meta:created_at");
}

pub const migrations = [_]Migration{
    .{
        .version = 1,
        .name = "initial_schema",
        .up = migrationV1Up,
        .down = migrationV1Down,
    },
};

pub fn runMigrations(store: *Store, from_version: u32) !void {
    for (migrations) |m| {
        if (m.version > from_version) {
            try m.up(store);
        }
    }
}

pub fn getCurrentVersion(store: *Store) u32 {
    if (store.get("g:meta:version")) |v| {
        return std.fmt.parseInt(u32, v, 10) catch 0;
    }
    return 0;
}

pub fn migrate(allocator: std.mem.Allocator, store: *Store) !void {
    _ = allocator;
    const current = getCurrentVersion(store);
    if (current >= CURRENT_VERSION) return;

    for (migrations) |m| {
        if (m.version > current) {
            try m.up(store);
        }
    }
}

test "migration version" {
    try std.testing.expect(migrations.len >= 1);
    try std.testing.expect(migrations[0].version == 1);
}
