//! Standalone catalog/inventory test root.
//!
//! Run with `zig test -lc --dep cordis -Mroot=test/_t_catalog.zig
//! -Mcordis=../zcordis/src/cordis.zig` from the repository root.

const std = @import("std");

const catalog = @import("../src/pluginabi/builtin_catalog.zig");
const inventory = @import("../src/server/apiproxy/inventory.zig");

test "catalog inventory emits one active row per builtin package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const value = try inventory.listValueWithBuiltins(alloc, std.testing.io, dir_path, dir_path, true);
    const repeated = try inventory.listValueWithBuiltins(alloc, std.testing.io, dir_path, dir_path, true);

    try std.testing.expectEqual(catalog.entries.len, std.mem.count(u8, value, "\"fiberPhase\":\"active\""));
    try std.testing.expect(std.mem.indexOf(u8, value, "\"enabled\":true") != null);
    try std.testing.expectEqualStrings(value, repeated);
    try std.testing.expect(std.mem.indexOf(u8, value, "\"toolNames\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, value, "\"status\"") == null);
    for (catalog.entries) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, value, entry.entry_id) != null);
        try std.testing.expect(std.mem.indexOf(u8, value, entry.module_name) != null);
    }
}
