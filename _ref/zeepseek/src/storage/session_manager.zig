const std = @import("std");

pub fn currentTimestamp() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) == 0) {
        return tv.sec;
    }
    return 0;
}

const store_mod = @import("store.zig");
const Store = store_mod.Store;
const makeKey = store_mod.makeKey;
const Keyspace = store_mod.Keyspace;

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    timestamp: i64,
};

pub const SessionMetadata = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    title: []const u8,
    model: []const u8,
    message_count: u32,
    total_tokens: u32,
    cache_hit_rate: f64,
    tags: []const []const u8,
    created_at: i64,
    last_updated: i64,
};

pub const Session = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    messages: std.ArrayListUnmanaged(Message),
    created_at: i64,
    last_updated: i64,
    metadata: SessionMetadata,

    pub fn init(alloc: std.mem.Allocator, id: []const u8, parent_id: ?[]const u8, model: []const u8, title: []const u8) !Session {
        return .{
            .id = id,
            .parent_id = parent_id,
            .messages = .empty,
            .created_at = currentTimestamp(),
            .last_updated = currentTimestamp(),
            .metadata = .{
                .id = id,
                .parent_id = parent_id,
                .title = try alloc.dupe(u8, title),
                .model = model,
                .message_count = 0,
                .total_tokens = 0,
                .cache_hit_rate = 0.0,
                .tags = &.{},
                .created_at = currentTimestamp(),
                .last_updated = currentTimestamp(),
            },
        };
    }

    pub fn deinit(self: *Session, alloc: std.mem.Allocator) void {
        alloc.free(self.metadata.title);
        for (self.messages.items) |msg| {
            alloc.free(msg.role);
            alloc.free(msg.content);
        }
        self.messages.deinit(alloc);
    }

    pub fn addMessage(self: *Session, alloc: std.mem.Allocator, role: []const u8, content: []const u8) !void {
        const owned_role = try alloc.dupe(u8, role);
        errdefer alloc.free(owned_role);
        const owned_content = try alloc.dupe(u8, content);
        errdefer alloc.free(owned_content);
        try self.messages.append(alloc, .{
            .role = owned_role,
            .content = owned_content,
            .timestamp = currentTimestamp(),
        });
        self.metadata.message_count = @intCast(self.messages.items.len);
        self.last_updated = currentTimestamp();
        self.metadata.last_updated = self.last_updated;
    }

    pub fn getMessages(self: *const Session) []const Message {
        return self.messages.items;
    }

    pub fn fork(self: *Session, alloc: std.mem.Allocator, new_id: []const u8, label: ?[]const u8) !Session {
        var forked = Session{
            .id = new_id,
            .parent_id = self.id,
            .messages = .empty,
            .created_at = currentTimestamp(),
            .last_updated = currentTimestamp(),
            .metadata = .{
                .id = new_id,
                .parent_id = self.id,
                .title = try alloc.dupe(u8, label orelse "Fork"),
                .model = self.metadata.model,
                .message_count = self.metadata.message_count,
                .total_tokens = self.metadata.total_tokens,
                .cache_hit_rate = self.metadata.cache_hit_rate,
                .tags = &.{},
                .created_at = currentTimestamp(),
                .last_updated = currentTimestamp(),
            },
        };

        for (self.messages.items) |msg| {
            const owned_role = try alloc.dupe(u8, msg.role);
            errdefer alloc.free(owned_role);
            const owned_content = try alloc.dupe(u8, msg.content);
            errdefer alloc.free(owned_content);
            try forked.messages.append(alloc, .{
                .role = owned_role,
                .content = owned_content,
                .timestamp = msg.timestamp,
            });
        }

        return forked;
    }
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    current: ?*Session,
    history: std.ArrayListUnmanaged([]const u8),
    session_cache: std.StringArrayHashMapUnmanaged(*Session),

    pub fn init(allocator: std.mem.Allocator, store: *Store) SessionManager {
        return .{
            .allocator = allocator,
            .store = store,
            .current = null,
            .history = .empty,
            .session_cache = .empty,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var it = self.session_cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.session_cache.deinit(self.allocator);

        for (self.history.items) |id| {
            self.allocator.free(id);
        }
        self.history.deinit(self.allocator);
    }

    pub fn createSession(self: *SessionManager, model: []const u8, title: ?[]const u8) !*Session {
        const id = try generateSessionId(self.allocator);
        const session = try self.allocator.create(Session);
        session.* = try Session.init(self.allocator, id, null, model, title orelse "New Session");

        try self.saveSession(session);

        try self.session_cache.put(self.allocator, id, session);
        try self.history.append(self.allocator, id);

        self.current = session;
        return session;
    }

    pub fn forkSession(self: *SessionManager, label: ?[]const u8) !*Session {
        const current = self.current orelse return error.NoCurrentSession;

        const fork_id = try generateSessionId(self.allocator);
        const forked = try current.fork(self.allocator, fork_id, label);

        const session = try self.allocator.create(Session);
        session.* = forked;

        try self.saveSession(session);

        try self.session_cache.put(self.allocator, fork_id, session);
        try self.history.append(self.allocator, fork_id);

        self.current = session;
        return session;
    }

    pub fn switchSession(self: *SessionManager, id: []const u8) !*Session {
        if (self.session_cache.get(id)) |session| {
            self.current = session;
            return session;
        }

        const session = try self.loadSession(id);
        try self.session_cache.put(self.allocator, id, session);
        self.current = session;
        return session;
    }

    pub fn listSessions(self: *SessionManager) ![]SessionMetadata {
        const prefix = try makeKey(self.allocator, .session, &.{});
        defer self.allocator.free(prefix);
        const keys = self.store.list(prefix);

        var sessions: std.ArrayList(SessionMetadata) = .empty;
        errdefer sessions.deinit(self.allocator);

        for (keys) |key| {
            if (self.store.get(key)) |data| {
                if (parseMetadata(data)) |meta| {
                    try sessions.append(self.allocator, meta);
                }
            }
        }

        return sessions.toOwnedSlice(self.allocator);
    }

    pub fn saveSession(self: *SessionManager, session: *const Session) !void {
        const key = try makeKey(self.allocator, .session, &.{session.id});
        defer self.allocator.free(key);
        const data = try serializeSession(self.allocator, session);
        defer self.allocator.free(data);

        try self.store.put(key, data);
    }

    pub fn loadSession(self: *SessionManager, id: []const u8) !*Session {
        const key = try makeKey(self.allocator, .session, &.{id});
        defer self.allocator.free(key);
        const data = self.store.get(key) orelse return error.SessionNotFound;

        const session = try self.allocator.create(Session);
        session.* = try deserializeSession(self.allocator, data);

        return session;
    }

    pub fn deleteSession(self: *SessionManager, id: []const u8) !void {
        const key = try makeKey(self.allocator, .session, &.{id});
        defer self.allocator.free(key);

        if (self.session_cache.get(id)) |session| {
            session.deinit(self.allocator);
            self.allocator.destroy(session);
            _ = self.session_cache.remove(id);
        }

        self.store.delete(key);

        for (self.history.items, 0..) |h_id, i| {
            if (std.mem.eql(u8, h_id, id)) {
                self.allocator.free(h_id);
                _ = self.history.swapRemove(i);
                break;
            }
        }
    }

    pub fn searchSessions(self: *SessionManager, query: []const u8) ![]SessionMetadata {
        const all_sessions = try self.listSessions();

        var results: std.ArrayList(SessionMetadata) = .empty;
        errdefer results.deinit(self.allocator);

        for (all_sessions) |meta| {
            if (std.mem.indexOf(u8, meta.title, query) != null or
                std.mem.indexOf(u8, meta.model, query) != null)
            {
                try results.append(self.allocator, meta);
            }
        }

        self.allocator.free(all_sessions);
        return results.toOwnedSlice(self.allocator);
    }

    pub fn getCurrent(self: *SessionManager) ?*Session {
        return self.current;
    }

    pub fn getSessionHistory(self: *SessionManager) []const []const u8 {
        return self.history.items;
    }

    pub fn forkAtMessage(self: *SessionManager, message_index: usize, label: ?[]const u8) !*Session {
        const current = self.current orelse return error.NoCurrentSession;

        const fork_id = try generateSessionId(self.allocator);
        var forked = try current.fork(self.allocator, fork_id, label);

        while (forked.messages.items.len > message_index) {
            const msg = forked.messages.pop();
            self.allocator.free(msg.role);
            self.allocator.free(msg.content);
            forked.metadata.message_count -= 1;
        }

        const session = try self.allocator.create(Session);
        session.* = forked;

        try self.saveSession(session);
        try self.session_cache.put(self.allocator, fork_id, session);
        try self.history.append(self.allocator, fork_id);

        self.current = session;
        return session;
    }
};

var session_counter: u32 = 0;

fn generateSessionId(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [32]u8 = undefined;
    const timestamp = currentTimestamp();
    const counter = @addWithOverflow(session_counter, 1);
    session_counter = counter[0];
    const n = std.fmt.bufPrint(&buf, "sess_{d}_{x}", .{ timestamp, counter[0] }) catch {
        return try allocator.dupe(u8, "sess_default");
    };
    return try allocator.dupe(u8, n);
}

fn serializeSession(allocator: std.mem.Allocator, session: *const Session) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{d}\n{d}\n{s}\n{s}\n{d}\n{d}\n{d}\n", .{
        session.id,
        session.parent_id orelse "",
        session.created_at,
        session.last_updated,
        session.metadata.title,
        session.metadata.model,
        session.metadata.message_count,
        session.metadata.total_tokens,
        session.metadata.cache_hit_rate,
    });
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (session.messages.items) |msg| {
        const line = try std.fmt.allocPrint(allocator, "{s}|{s}|{d}\n", .{
            msg.role,
            msg.content,
            msg.timestamp,
        });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }

    return try buf.toOwnedSlice(allocator);
}

fn deserializeSession(allocator: std.mem.Allocator, data: []const u8) !Session {
    var lines = std.mem.splitScalar(u8, data, '\n');

    const id = lines.next() orelse return error.InvalidSessionData;
    const parent_id_str = lines.next() orelse return error.InvalidSessionData;
    const parent_id: ?[]const u8 = if (parent_id_str.len > 0) parent_id_str else null;
    const created_at = try std.fmt.parseInt(i64, lines.next() orelse return error.InvalidSessionData, 10);
    const last_updated = try std.fmt.parseInt(i64, lines.next() orelse return error.InvalidSessionData, 10);
    const title = lines.next() orelse return error.InvalidSessionData;
    const model = lines.next() orelse return error.InvalidSessionData;
    const message_count = try std.fmt.parseInt(u32, lines.next() orelse return error.InvalidSessionData, 10);
    const total_tokens = try std.fmt.parseInt(u32, lines.next() orelse return error.InvalidSessionData, 10);
    _ = lines.next();
    _ = total_tokens;
    _ = message_count;

    var session = try Session.init(allocator, id, parent_id, model, title);
    session.created_at = created_at;
    session.last_updated = last_updated;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '|');
        const role = parts.next() orelse continue;
        const content = parts.next() orelse continue;
        const timestamp_str = parts.next() orelse continue;
        const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch continue;

        const owned_role = allocator.dupe(u8, role) catch continue;
        errdefer allocator.free(owned_role);
        const owned_content = allocator.dupe(u8, content) catch continue;
        errdefer allocator.free(owned_content);
        try session.messages.append(allocator, .{
            .role = owned_role,
            .content = owned_content,
            .timestamp = timestamp,
        });
    }

    session.metadata.message_count = @intCast(session.messages.items.len);
    return session;
}

fn parseMetadata(data: []const u8) ?SessionMetadata {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const id = lines.next() orelse return null;
    const parent_id_str = lines.next() orelse return null;
    const parent_id: ?[]const u8 = if (parent_id_str.len > 0) parent_id_str else null;
    const created_at = std.fmt.parseInt(i64, lines.next() orelse return null, 10) catch return null;
    const last_updated = std.fmt.parseInt(i64, lines.next() orelse return null, 10) catch return null;
    const title = lines.next() orelse return null;
    const model = lines.next() orelse return null;
    const message_count = std.fmt.parseInt(u32, lines.next() orelse return null, 10) catch return null;
    const total_tokens = std.fmt.parseInt(u32, lines.next() orelse return null, 10) catch return null;
    const cache_hit_rate = std.fmt.parseFloat(f64, lines.next() orelse return null) catch return null;
    _ = lines.next();

    return .{
        .id = id,
        .parent_id = parent_id,
        .title = title,
        .model = model,
        .message_count = message_count,
        .total_tokens = total_tokens,
        .cache_hit_rate = cache_hit_rate,
        .tags = &.{},
        .created_at = created_at,
        .last_updated = last_updated,
    };
}

test "session init" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, "test_id", null, "deepseek-chat", "Test Session");
    defer session.deinit(alloc);

    try std.testing.expectEqualStrings("test_id", session.id);
    try std.testing.expectEqualStrings("Test Session", session.metadata.title);
    try std.testing.expectEqualStrings("deepseek-chat", session.metadata.model);
}

test "session add message" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, "test_id", null, "deepseek-chat", "Test");
    defer session.deinit(alloc);

    try session.addMessage(alloc, "user", "Hello");
    try session.addMessage(alloc, "assistant", "Hi there!");

    try std.testing.expectEqual(@as(usize, 2), session.messages.items.len);
    try std.testing.expectEqualStrings("user", session.messages.items[0].role);
    try std.testing.expectEqualStrings("Hello", session.messages.items[0].content);
}

test "session fork" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, "original", null, "deepseek-chat", "Original");
    defer session.deinit(alloc);

    try session.addMessage(alloc, "user", "Hello");
    try session.addMessage(alloc, "assistant", "Hi!");

    var forked = try session.fork(alloc, "forked", "My Fork");
    defer forked.deinit(alloc);

    try std.testing.expectEqualStrings("forked", forked.id);
    try std.testing.expectEqualStrings("original", forked.parent_id.?);
    try std.testing.expectEqualStrings("My Fork", forked.metadata.title);
    try std.testing.expectEqual(@as(usize, 2), forked.messages.items.len);
}
