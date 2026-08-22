const std = @import("std");

/// Canonical keyspace prefixes shared by store and store_api.
pub const Keyspace = enum(u8) {
    session = 's',
    cache = 'c',
    global = 'g',
    agent = 'a',
    checkpoint = 'k',
    reasonix = 'r',
    balance = 'b',
};

pub const KeyError = error{
    KeyTooLong,
};

pub fn makeKey(allocator: std.mem.Allocator, keyspace: Keyspace, parts: []const []const u8) KeyError![]const u8 {
    var key_bytes: [256]u8 = undefined;
    var i: usize = 0;
    key_bytes[i] = @intFromEnum(keyspace);
    i += 1;
    for (parts) |part| {
        if (i + part.len + 1 > key_bytes.len) return error.KeyTooLong;
        key_bytes[i] = ':';
        i += 1;
        @memcpy(key_bytes[i..][0..part.len], part);
        i += part.len;
    }
    return allocator.dupe(u8, key_bytes[0..i]) catch return error.KeyTooLong;
}

pub fn makeKeyBounded(keyspace: Keyspace, parts: []const []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    if (buf.len < 1) return buf[0..0];

    buf[i] = @intFromEnum(keyspace);
    i += 1;

    for (parts) |part| {
        if (i + part.len + 1 > buf.len) return buf[0..0];
        buf[i] = ':';
        i += 1;
        @memcpy(buf[i..][0..part.len], part);
        i += part.len;
    }

    return buf[0..i];
}

test "keyspace makeKey" {
    const key = try makeKey(std.testing.allocator, .session, &.{"123", "msg", "5"});
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("s:123:msg:5", key);
}

test "keyspace makeKeyBounded" {
    var buf: [64]u8 = undefined;
    const key = makeKeyBounded(.agent, &.{"task-1"}, &buf);
    try std.testing.expectEqualStrings("a:task-1", key);
}
