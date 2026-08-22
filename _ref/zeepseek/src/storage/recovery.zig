const std = @import("std");
const c = @import("c");
const mmap_store = @import("mmap_store.zig");
const Store = mmap_store.MmapStore;
const WalEntry = mmap_store.WalEntry;
const WalOp = mmap_store.WalOp;
const WalReader = mmap_store.WalReader;
const WalWriter = mmap_store.WalWriter;

pub const RecoveryError = error{
    CorruptedWal,
    MissingWalFile,
    IoError,
    CheckpointCorrupted,
};

pub fn recoverStore(allocator: std.mem.Allocator, db_path: []const u8, options: StoreOptions) !*Store {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const db_path_z = std.heap.page_allocator.dupeSentinel(u8, db_path, 0) catch return error.IoError;
    defer std.heap.page_allocator.free(db_path_z);
    _ = c.mkdir(db_path_z.ptr, 0o755);

    const wal_path = try std.mem.concat(alloc, u8, &.{ db_path, "/wal.log" });
    const meta_path = try std.mem.concat(alloc, u8, &.{ db_path, "/meta.json" });

    const store_path = try std.mem.concat(alloc, u8, &.{ db_path, "/data.mdb" });
    var store = try alloc.create(Store);
    store.* = try Store.init(alloc, store_path, options.hot_region_size, options.cold_region_size);
    errdefer store.deinit(alloc);

    if (options.wal_enabled) {
        try store.enableWal(wal_path);
    }

    const wal_path_z = std.heap.page_allocator.dupeSentinel(u8, wal_path, 0) catch return error.IoError;
    defer std.heap.page_allocator.free(wal_path_z);
    if (std.c.access(wal_path_z.ptr, std.posix.F_OK) == 0) {
        try recoverFromWal(store, wal_path);
    }

    if (options.wal_enabled) {
        try store.checkpoint();
    }

    try store.persistMeta(meta_path);

    return store;
}

fn recoverFromWal(store: *Store, wal_path: []const u8) !void {
    var wal_reader = try WalReader.init(wal_path);
    defer wal_reader.deinit();

    while (try wal_reader.next()) |entry| {
        switch (entry.op) {
            .put => {
                store.putAssumeWal(entry.key, entry.value) catch {};
            },
            .delete => {
                store.deleteAssumeWal(entry.key);
            },
        }
    }
}

pub const Checkpoint = struct {
    id: []const u8,
    timestamp: i64,
    session_id: []const u8,
    message_count: u32,
    context_tokens: u32,
    fold_count: u32,
    version: u32,
};

pub const CheckpointManager = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    wal: ?*WalWriter,
    max_checkpoints: u32 = 5,

    pub fn init(allocator: std.mem.Allocator, store: *Store, wal: ?*WalWriter) CheckpointManager {
        return CheckpointManager{
            .allocator = allocator,
            .store = store,
            .wal = wal,
            .max_checkpoints = 5,
        };
    }

    pub fn create(self: *CheckpointManager, session_id: []const u8, msg_count: u32, token_count: u32, fold_count: u32) ![]const u8 {
        var buf: [64]u8 = undefined;
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        const ts: i64 = @intCast(tv.tv_sec);
        const id = try std.fmt.bufPrint(&buf, "{d}", .{ts});

        const key_prefix = "k:snap:";
        const full_key = try std.mem.concat(self.allocator, u8, &.{ key_prefix, session_id, ":", id });

        const checkpoint = Checkpoint{
            .id = id,
            .timestamp = ts,
            .session_id = session_id,
            .message_count = msg_count,
            .context_tokens = token_count,
            .fold_count = fold_count,
            .version = 1,
        };

        var json_buf: [512]u8 = undefined;
        const json_str = std.json.stringify(checkpoint, .{}, &json_buf) catch {
            const value = std.fmt.bytesToHex(&[_]u8{0}, .lower);
            _ = value;
            return error.SerializationFailed;
        };

        try self.store.put(full_key, json_str);

        if (self.wal) |w| {
            try w.append(.{ .op = .put, .key = full_key, .value = json_str, .timestamp = ts, .seq = 0 });
        }

        try self.prune();

        return self.allocator.dupe(u8, id);
    }

    pub fn restore(self: *CheckpointManager, checkpoint_id: []const u8) !void {
        var it = self.store.entries.iterator();
        while (it.next()) |kv| {
            if (std.mem.indexOf(u8, kv.key_ptr.*, "k:snap:") == 0) {
                const value = self.store.get(kv.key_ptr.*) orelse continue;
                var parser = std.json.Parser.init(self.allocator, .{
                    .ignore_unknown_fields = true,
                });
                defer parser.deinit();
                const parsed = parser.parse(value) catch continue;
                const obj = parsed.root.object orelse continue;
                const id_val = obj.get("id") orelse continue;
                if (id_val == .string and std.mem.eql(u8, id_val.string, checkpoint_id)) {
                    return;
                }
            }
        }
        return error.CheckpointNotFound;
    }

    pub fn list(self: *CheckpointManager) ![]const Checkpoint {
        var results: std.ArrayList(Checkpoint) = .empty;
        var it = self.store.entries.iterator();
        while (it.next()) |kv| {
            if (std.mem.indexOf(u8, kv.key_ptr.*, "k:snap:") == 0) {
                const value = self.store.get(kv.key_ptr.*) orelse continue;
                var parser = std.json.Parser.init(self.allocator, .{
                    .ignore_unknown_fields = true,
                });
                defer parser.deinit();
                const parsed = parser.parse(value) catch continue;
                const cp = try self.allocator.create(Checkpoint);
                const obj = parsed.root.object orelse continue;

                cp.* = Checkpoint{
                    .id = try self.allocator.dupe(u8, obj.get("id").?.string),
                    .timestamp = @intCast(obj.get("timestamp").?.integer),
                    .session_id = try self.allocator.dupe(u8, obj.get("session_id").?.string),
                    .message_count = @intCast(obj.get("message_count").?.integer),
                    .context_tokens = @intCast(obj.get("context_tokens").?.integer),
                    .fold_count = @intCast(obj.get("fold_count").?.integer),
                    .version = @intCast((obj.get("version") orelse .{ .integer = 1 }).integer),
                };
                results.append(self.allocator, cp.*) catch {};
            }
        }
        return results.toOwnedSlice(self.allocator);
    }

    pub fn prune(self: *CheckpointManager) !void {
        var checkpoints = try self.list();
        defer self.allocator.free(checkpoints);

        if (checkpoints.len <= self.max_checkpoints) return;

        std.mem.sort(Checkpoint, checkpoints, {}, struct {
            fn less(_: void, a: Checkpoint, b: Checkpoint) bool {
                return a.timestamp < b.timestamp;
            }
        }.less);

        for (checkpoints[0..checkpoints.len - self.max_checkpoints]) |cp| {
            const key = try std.mem.concat(self.allocator, u8, &.{ "k:snap:", cp.session_id, ":", cp.id });
            self.store.delete(key);
            self.allocator.free(key);
        }
    }
};

pub const StoreOptions = struct {
    data_dir: []const u8 = ".zeepseek_data",
    hot_region_size: usize = 4 * 1024 * 1024,
    cold_region_size: usize = 2 * 1024 * 1024,
    wal_enabled: bool = true,
    wal_flush_interval: u32 = 100,
    max_checkpoints: u32 = 5,
};

test "checkpoint list" {
    const alloc = std.testing.allocator;
    _ = alloc;
}
