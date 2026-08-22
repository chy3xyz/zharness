//! Session file format: one record per message, length-prefixed so content
//! may contain any bytes (newlines, colons, etc.):
//!
//!   "ROLE <len>\n<content>\n"
//!
//! ROLE is one of USER / ASSISTANT / SYSTEM / TOOL.

const std = @import("std");

pub const Role = enum {
    user,
    assistant,
    system,
    tool,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .user => "USER",
            .assistant => "ASSISTANT",
            .system => "SYSTEM",
            .tool => "TOOL",
        };
    }

    pub fn fromString(s: []const u8) Role {
        if (std.mem.eql(u8, s, "USER")) return .user;
        if (std.mem.eql(u8, s, "ASSISTANT")) return .assistant;
        if (std.mem.eql(u8, s, "SYSTEM")) return .system;
        return .tool;
    }
};

pub const SerializedMessage = struct {
    role: Role,
    content: []const u8,
};

pub const ParsedMessage = struct {
    role: Role,
    /// Caller-owned copy (allocated by parse)
    content: []const u8,
};

/// Serialize messages to the session format. Returns caller-owned bytes.
pub fn serialize(alloc: std.mem.Allocator, messages: []const SerializedMessage) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var hdr: [64]u8 = undefined;
    for (messages) |m| {
        const header = try std.fmt.bufPrint(&hdr, "{s} {d}\n", .{ m.role.toString(), m.content.len });
        try out.appendSlice(alloc, header);
        try out.appendSlice(alloc, m.content);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// Parse session data. Content slices are duplicated with `alloc` and owned
/// by the caller. Invalid records stop parsing (returns what was parsed so far).
pub fn parse(alloc: std.mem.Allocator, data: []const u8) ![]ParsedMessage {
    var out = std.ArrayList(ParsedMessage).empty;
    errdefer {
        for (out.items) |m| alloc.free(m.content);
        out.deinit(alloc);
    }

    var i: usize = 0;
    while (i < data.len) {
        const nl = std.mem.indexOfScalarPos(u8, data, i, '\n') orelse break;
        const hdr = data[i..nl];
        const space = std.mem.indexOfScalar(u8, hdr, ' ') orelse break;
        const role = Role.fromString(hdr[0..space]);
        const content_len = std.fmt.parseInt(usize, hdr[space + 1 ..], 10) catch break;
        const content_start = nl + 1;
        if (content_start + content_len > data.len) break;
        const content = data[content_start .. content_start + content_len];
        try out.append(alloc, .{
            .role = role,
            .content = try alloc.dupe(u8, content),
        });
        i = content_start + content_len + 1; // skip content + trailing '\n'
    }
    return out.toOwnedSlice(alloc);
}

test "serialize and parse roundtrip" {
    const alloc = std.testing.allocator;
    const msgs = [_]SerializedMessage{
        .{ .role = .user, .content = "hello world" },
        .{ .role = .assistant, .content = "hi there" },
    };
    const blob = try serialize(alloc, &msgs);
    defer alloc.free(blob);

    try std.testing.expectEqualSlices(u8, "USER 11\nhello world\nASSISTANT 8\nhi there\n", blob);

    const parsed = try parse(alloc, blob);
    defer {
        for (parsed) |m| alloc.free(m.content);
        alloc.free(parsed);
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqual(Role.user, parsed[0].role);
    try std.testing.expectEqualSlices(u8, "hello world", parsed[0].content);
    try std.testing.expectEqual(Role.assistant, parsed[1].role);
    try std.testing.expectEqualSlices(u8, "hi there", parsed[1].content);
}

test "content with newlines and colons survives" {
    const alloc = std.testing.allocator;
    const tricky = "line1\nline2: with colon";
    const msgs = [_]SerializedMessage{.{ .role = .tool, .content = tricky }};
    const blob = try serialize(alloc, &msgs);
    defer alloc.free(blob);

    const parsed = try parse(alloc, blob);
    defer {
        for (parsed) |m| alloc.free(m.content);
        alloc.free(parsed);
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqual(Role.tool, parsed[0].role);
    try std.testing.expectEqualSlices(u8, tricky, parsed[0].content);
}

test "parse stops at invalid record" {
    const alloc = std.testing.allocator;
    const data = "USER 2\nhi\nGARBAGE\n";
    const parsed = try parse(alloc, data);
    defer {
        for (parsed) |m| alloc.free(m.content);
        alloc.free(parsed);
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualSlices(u8, "hi", parsed[0].content);
}

test "empty data yields no messages" {
    const alloc = std.testing.allocator;
    const parsed = try parse(alloc, "");
    defer alloc.free(parsed);
    try std.testing.expectEqual(@as(usize, 0), parsed.len);
}
