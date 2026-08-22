//! Session — a simple in-memory message store with JSON file persistence
//! for the zharness MVP-1 coding agent.
//!
//! Holds the conversation transcript (the model IR `Message`s) plus a few
//! bookkeeping fields. Persistence is a minimal hand-rolled JSON file (no
//! SQLite dependency) so the module stays dependency-free.

const std = @import("std");
const clib = @import("../clib.zig");
const cordis = @import("cordis");
const model_mod = @import("../model/model.zig");

pub const Session = struct {
    id: []const u8,
    alloc: std.mem.Allocator,
    messages: std.ArrayList(model_mod.Message),
    created_at: i64,
    metadata: std.StringHashMap([]const u8),

    pub fn init(alloc: std.mem.Allocator, id: []const u8) !Session {
        const now = clib.nowTimestamp();
        return Session{
            .id = try alloc.dupe(u8, id),
            .alloc = alloc,
            .messages = try std.ArrayList(model_mod.Message).initCapacity(alloc, 0),
            .created_at = now,
            .metadata = std.StringHashMap([]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *Session) void {
        self.freeMessages();
        self.messages.deinit(self.alloc);
        // metadata keys/values are allocator-owned.
        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
        self.alloc.free(self.id);
    }

    fn freeMessages(self: *Session) void {
        for (self.messages.items) |m| {
            self.alloc.free(m.content);
            if (m.tool_call_id) |v| self.alloc.free(v);
            if (m.tool_calls_json) |v| self.alloc.free(v);
        }
    }

    pub fn addUser(self: *Session, text: []const u8) !void {
        try self.messages.append(self.alloc, model_mod.Message{
            .role = .user,
            .content = try self.alloc.dupe(u8, text),
        });
    }

    pub fn addAssistant(self: *Session, text: []const u8, tool_calls_json: ?[]const u8) !void {
        try self.messages.append(self.alloc, model_mod.Message{
            .role = .assistant,
            .content = try self.alloc.dupe(u8, text),
            .tool_calls_json = if (tool_calls_json) |v| try self.alloc.dupe(u8, v) else null,
        });
    }

    pub fn addToolResult(self: *Session, call_id: []const u8, text: []const u8) !void {
        try self.messages.append(self.alloc, model_mod.Message{
            .role = .tool,
            .content = try self.alloc.dupe(u8, text),
            .tool_call_id = try self.alloc.dupe(u8, call_id),
        });
    }

    pub fn clear(self: *Session) void {
        self.freeMessages();
        self.messages.clearRetainingCapacity();
    }

    pub fn count(self: *const Session) usize {
        return self.messages.items.len;
    }

    pub fn lastContent(self: *const Session) []const u8 {
        var i: usize = self.messages.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.messages.items[i].content;
            if (c.len > 0) return c;
        }
        return "";
    }

    // ---- Persistence ----------------------------------------------------

    pub fn save(self: *const Session, io: std.Io, path: []const u8) !void {
        // Build the JSON document into an allocator-backed buffer, then
        // write it in one shot via `std.Io.Dir` (Zig 0.17's file API;
        // `std.fs.cwd` was relocated here).
        var buf = try std.ArrayList(u8).initCapacity(self.alloc, 0);
        errdefer buf.deinit(self.alloc);

        try buf.appendSlice(self.alloc, "[");
        for (self.messages.items, 0..) |m, idx| {
            if (idx > 0) try buf.appendSlice(self.alloc, ",");
            try buf.appendSlice(self.alloc, "{\"role\":\"");
            try buf.appendSlice(self.alloc, m.role.asStr());
            try buf.appendSlice(self.alloc, "\",\"content\":\"");
            try escapeInto(self.alloc, m.content, &buf);
            try buf.appendSlice(self.alloc, "\",\"tool_call_id\":");
            if (m.tool_call_id) |v| {
                try buf.appendSlice(self.alloc, "\"");
                try escapeInto(self.alloc, v, &buf);
                try buf.appendSlice(self.alloc, "\"");
            } else {
                try buf.appendSlice(self.alloc, "null");
            }
            try buf.appendSlice(self.alloc, ",\"tool_calls_json\":");
            if (m.tool_calls_json) |v| {
                try buf.appendSlice(self.alloc, "\"");
                try escapeInto(self.alloc, v, &buf);
                try buf.appendSlice(self.alloc, "\"");
            } else {
                try buf.appendSlice(self.alloc, "null");
            }
            try buf.appendSlice(self.alloc, "}");
        }
        try buf.appendSlice(self.alloc, "]");

        const out = try buf.toOwnedSlice(self.alloc);
        defer self.alloc.free(out);

        try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = out });
    }

    pub fn load(self: *Session, io: std.Io, path: []const u8) !void {
        // Read via `std.Io.Dir` (Zig 0.17's file API).
        const raw = std.Io.Dir.readFileAlloc(.cwd(), io, path, self.alloc, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return, // empty session, OK
            else => return e,
        };
        defer self.alloc.free(raw);

        var it = JsonArrayIter.init(raw);
        while (it.next()) |obj| {
            const role = parseRole(obj.get("role") orelse "") orelse .user;
            const content = try self.alloc.dupe(u8, obj.getUnescaped("content") orelse "");
            const tcid_raw = obj.get("tool_call_id");
            const tcalls_raw = obj.get("tool_calls_json");
            const tool_call_id = if (tcid_raw) |v| try self.alloc.dupe(u8, try obj.unescape(v)) else null;
            const tool_calls_json = if (tcalls_raw) |v| try self.alloc.dupe(u8, try obj.unescape(v)) else null;
            try self.messages.append(self.alloc, model_mod.Message{
                .role = role,
                .content = content,
                .tool_call_id = tool_call_id,
                .tool_calls_json = tool_calls_json,
            });
        }
    }

    // ---- small JSON helpers (no library) -------------------------------

    /// Append a JSON-escaped copy of `input` to `buf`.
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

    fn parseRole(s: []const u8) ?model_mod.Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return null;
    }
};

/// Iterates top-level objects of a JSON array: `[ {...}, {...}, ... ]`.
/// Nested arrays/objects are skipped whole. Each yielded `Obj` exposes
/// `get(field)` -> raw quoted slice (excludes quotes) and `unescape(raw)`
/// to decode the simple escape sequences we emit.
const JsonArrayIter = struct {
    src: []const u8,
    i: usize,

    fn init(src: []const u8) JsonArrayIter {
        return .{ .src = src, .i = 0 };
    }

    fn next(self: *JsonArrayIter) ?Obj {
        // advance to the next '{'
        while (self.i < self.src.len) : (self.i += 1) {
            if (self.src[self.i] == '{') {
                const start = self.i;
                const end = findMatchingBrace(self.src, start) orelse return null;
                self.i = end; // resume after this object
                return Obj{ .text = self.src[start..end] };
            }
        }
        return null;
    }
};

const Obj = struct {
    text: []const u8,

    /// Returns the raw quoted value of `field` (without surrounding quotes),
    /// or null if the field is absent / not a string.
    fn get(self: Obj, field: []const u8) ?[]const u8 {
        var buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{field}) catch return null;
        const pos = std.mem.indexOf(u8, self.text, needle) orelse return null;
        var j = pos + needle.len;
        while (j < self.text.len and (self.text[j] == ' ' or self.text[j] == '\n')) : (j += 1) {}
        if (j >= self.text.len or self.text[j] != '"') return null;
        j += 1;
        const vs = j;
        while (j < self.text.len and self.text[j] != '"') : (j += 1) {
            if (self.text[j] == '\\' and j + 1 < self.text.len) j += 1;
        }
        return self.text[vs..j];
    }

    fn getUnescaped(self: Obj, field: []const u8) ?[]const u8 {
        const raw = self.get(field) orelse return null;
        return self.unescape(raw) catch null;
    }

    fn unescape(self: Obj, input: []const u8) ![]const u8 {
        _ = self;
        var out = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, 0);
        errdefer out.deinit(std.heap.page_allocator);
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            if (input[i] == '\\' and i + 1 < input.len) {
                i += 1;
                switch (input[i]) {
                    '"' => try out.append(std.heap.page_allocator, '"'),
                    '\\' => try out.append(std.heap.page_allocator, '\\'),
                    'n' => try out.append(std.heap.page_allocator, '\n'),
                    'r' => try out.append(std.heap.page_allocator, '\r'),
                    't' => try out.append(std.heap.page_allocator, '\t'),
                    else => try out.append(std.heap.page_allocator, input[i]),
                }
            } else {
                try out.append(std.heap.page_allocator, input[i]);
            }
        }
        return try out.toOwnedSlice(std.heap.page_allocator);
    }
};

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

test "session add and roundtrip" {
    const alloc = std.testing.allocator;
    var s1 = try Session.init(alloc, "test-session");
    defer s1.deinit();

    try s1.addUser("hello world");
    try s1.addAssistant("thinking...", "{\"id\":\"1\",\"name\":\"shell\"}");
    try s1.addToolResult("1", "done");

    try std.testing.expectEqual(@as(usize, 3), s1.count());

    const tmp = "zharness_session_test.json";

    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    try s1.save(io, tmp);

    var s2 = try Session.init(alloc, "other");
    defer s2.deinit();
    try s2.load(io, tmp);

    try std.testing.expectEqual(@as(usize, 3), s2.count());
    try std.testing.expectEqualStrings("hello world", s2.messages.items[0].content);
    try std.testing.expectEqual(model_mod.Role.tool, s2.messages.items[2].role);
    try std.testing.expectEqualStrings("1", s2.messages.items[2].tool_call_id.?);
    try std.testing.expectEqualStrings("{\"id\":\"1\",\"name\":\"shell\"}", s2.messages.items[1].tool_calls_json.?);
}
