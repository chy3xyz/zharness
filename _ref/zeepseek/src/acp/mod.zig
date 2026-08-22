const std = @import("std");
const error_mod = @import("../utils/error.zig");

pub const ACPError = error{
    ProcessSpawnFailed,
    ProcessNotRunning,
    ConnectionFailed,
    SendFailed,
    RecvFailed,
    JsonParseError,
    MethodNotFound,
    Timeout,
    PeerDisconnected,
};

pub const MessageType = enum {
    request,
    response,
    notification,
    error_resp,
};

pub const CallPayload = struct {
    method: []const u8,
    params: ?[]const u8 = null,
};

pub const ResultPayload = struct {
    result: []const u8,
};

pub const NotifyPayload = struct {
    event: []const u8,
    data: ?[]const u8 = null,
};

pub const ErrorPayload = struct {
    code: i64,
    message: []const u8,
    data: ?[]const u8 = null,
};

pub const ACPMessage = struct {
    version: []const u8 = "1.0",
    id: []const u8,
    msg_type: MessageType,
    from: []const u8,
    to: []const u8,
    method: ?[]const u8 = null,
    params: ?[]const u8 = null,
    result: ?[]const u8 = null,
    event: ?[]const u8 = null,
    data: ?[]const u8 = null,
    error_code: ?i64 = null,
    error_message: ?[]const u8 = null,

    pub fn toJson(self: *const ACPMessage, alloc: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(alloc);

        try list.appendSlice(alloc, "{\"version\":\"1.0\",\"id\":\"");
        try list.appendSlice(alloc, self.id);
        try list.appendSlice(alloc, "\",\"type\":\"");
        try list.appendSlice(alloc, @tagName(self.msg_type));
        try list.appendSlice(alloc, "\",\"from\":\"");
        try list.appendSlice(alloc, self.from);
        try list.appendSlice(alloc, "\",\"to\":\"");
        try list.appendSlice(alloc, self.to);
        try list.appendSlice(alloc, "\"");

        if (self.method) |m| {
            try list.appendSlice(alloc, ",\"method\":\"");
            try list.appendSlice(alloc, m);
            try list.appendSlice(alloc, "\"");
        }
        if (self.params) |p| {
            try list.appendSlice(alloc, ",\"params\":\"");
            try list.appendSlice(alloc, p);
            try list.appendSlice(alloc, "\"");
        }
        if (self.result) |r| {
            try list.appendSlice(alloc, ",\"result\":\"");
            try list.appendSlice(alloc, r);
            try list.appendSlice(alloc, "\"");
        }
        if (self.event) |e| {
            try list.appendSlice(alloc, ",\"event\":\"");
            try list.appendSlice(alloc, e);
            try list.appendSlice(alloc, "\"");
        }
        if (self.data) |d| {
            try list.appendSlice(alloc, ",\"data\":\"");
            try list.appendSlice(alloc, d);
            try list.appendSlice(alloc, "\"");
        }
        if (self.error_code) |c| {
            try list.appendSlice(alloc, ",\"error\":{\"code\":");
            var buf: [32]u8 = undefined;
            const code_str = std.fmt.bufPrint(&buf, "{d}", .{c}) catch "0";
            try list.appendSlice(alloc, code_str);
            if (self.error_message) |msg| {
                try list.appendSlice(alloc, ",\"message\":\"");
                try list.appendSlice(alloc, msg);
                try list.appendSlice(alloc, "\"");
            }
            try list.appendSlice(alloc, "}");
        }

        try list.appendSlice(alloc, "}");
        return try list.toOwnedSlice(alloc);
    }

    pub fn fromJson(json_str: []const u8, alloc: std.mem.Allocator) !ACPMessage {
        _ = alloc;
        var msg = ACPMessage{
            .id = "",
            .msg_type = .request,
            .from = "",
            .to = "",
        };
        if (std.mem.indexOf(u8, json_str, "\"request\"") != null) msg.msg_type = .request;
        if (std.mem.indexOf(u8, json_str, "\"response\"") != null) msg.msg_type = .response;
        if (std.mem.indexOf(u8, json_str, "\"notification\"") != null) msg.msg_type = .notification;
        if (std.mem.indexOf(u8, json_str, "\"error\"") != null) msg.msg_type = .error_resp;
        return msg;
    }
};

pub const ACPClient = struct {
    allocator: std.mem.Allocator,
    child: ?std.process.Child = null,
    stdin_fd: ?std.posix.fd_t = null,
    stdout_fd: ?std.posix.fd_t = null,
    peer_name: []const u8,
    self_name: []const u8,
    request_id: i64 = 0,
    running: bool = false,
    io: std.Io,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, self_name: []const u8, peer_name: []const u8) !ACPClient {
        return ACPClient{
            .allocator = alloc,
            .io = io,
            .peer_name = try alloc.dupe(u8, peer_name),
            .self_name = try alloc.dupe(u8, self_name),
            .running = false,
        };
    }

    pub fn deinit(self: *ACPClient) void {
        self.stop();
        self.allocator.free(self.peer_name);
        self.allocator.free(self.self_name);
    }

    pub fn connect(self: *ACPClient, args: []const []const u8) !void {
        if (self.running) return;

        self.child = std.process.spawn(self.io, .{
            .argv = args,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return error.ProcessSpawnFailed;

        self.stdin_fd = self.child.?.stdin.?.handle;
        self.stdout_fd = self.child.?.stdout.?.handle;
        self.running = true;
    }

    pub fn start(self: *ACPClient) !void {
        self.running = true;
    }

    pub fn stop(self: *ACPClient) void {
        if (!self.running) return;
        if (self.child) |child| {
            _ = std.c.close(child.stdin.?.handle);
            _ = std.c.close(child.stdout.?.handle);
            _ = std.c.close(child.stderr.?.handle);
            self.child = null;
        }
        self.stdin_fd = null;
        self.stdout_fd = null;
        self.running = false;
    }

    fn nextId(self: *ACPClient) []const u8 {
        self.request_id += 1;
        return std.fmt.allocPrint(self.allocator, "{d}", .{self.request_id}) catch "0";
    }

    fn sendMessage(self: *ACPClient, msg: *const ACPMessage) !void {
        if (self.stdin_fd == null) return error.ProcessNotRunning;
        const json = try msg.toJson(self.allocator);
        defer self.allocator.free(json);
        _ = std.c.write(self.stdin_fd.?, json.ptr, json.len);
        _ = std.c.write(self.stdin_fd.?, "\n".ptr, 1);
    }

    fn recvMessage(self: *ACPClient) !ACPMessage {
        if (self.stdout_fd == null) return error.ProcessNotRunning;
        var buf: [8192]u8 = undefined;
        const n_read = std.c.read(self.stdout_fd.?, &buf, buf.len);
        if (n_read <= 0) return error.PeerDisconnected;
        const n: usize = @intCast(n_read);
        return ACPMessage.fromJson(buf[0..n], self.allocator);
    }

    pub fn call(self: *ACPClient, method: []const u8, params: ?[]const u8) ![]const u8 {
        const id = self.nextId();
        var msg = ACPMessage{
            .id = try self.allocator.dupe(u8, id),
            .msg_type = .request,
            .from = self.self_name,
            .to = self.peer_name,
            .method = try self.allocator.dupe(u8, method),
            .params = if (params) |p| try self.allocator.dupe(u8, p) else null,
        };
        errdefer {
            self.allocator.free(msg.id);
            if (msg.method) |m| self.allocator.free(m);
            if (msg.params) |p| self.allocator.free(p);
        }

        try self.sendMessage(&msg);
        if (msg.method) |m| self.allocator.free(m);
        if (msg.params) |p| self.allocator.free(p);

        const resp = try self.recvMessage();
        if (resp.msg_type == .error_resp) {
            return error.PeerDisconnected;
        }
        if (resp.result) |r| {
            return try self.allocator.dupe(u8, r);
        }
        return error.PeerDisconnected;
    }

    pub fn notify(self: *ACPClient, event: []const u8, data: ?[]const u8) void {
        const id = self.nextId();
        var msg = ACPMessage{
            .id = try self.allocator.dupe(u8, id),
            .msg_type = .notification,
            .from = self.self_name,
            .to = self.peer_name,
            .event = try self.allocator.dupe(u8, event),
            .data = if (data) |d| self.allocator.dupe(u8, d) catch null else null,
        };
        self.sendMessage(&msg) catch return;
        self.allocator.free(msg.id);
        if (msg.event) |e| self.allocator.free(e);
        if (msg.data) |d| self.allocator.free(d);
    }

    pub fn sendResult(self: *ACPClient, orig_id: []const u8, result: []const u8) !void {
        var msg = ACPMessage{
            .id = try self.allocator.dupe(u8, orig_id),
            .msg_type = .response,
            .from = self.self_name,
            .to = self.peer_name,
            .result = try self.allocator.dupe(u8, result),
        };
        try self.sendMessage(&msg);
        self.allocator.free(msg.id);
        self.allocator.free(msg.result);
    }
};

test "acp message to json" {
    const alloc = std.testing.allocator;
    var msg = ACPMessage{
        .id = "123",
        .msg_type = .request,
        .from = "zeepseek",
        .to = "zed",
        .method = try alloc.dupe(u8, "get_diagnostics"),
    };
    defer {
        alloc.free(msg.method.?);
    }
    const json = try msg.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "request") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "get_diagnostics") != null);
}

test "acp client init" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    var client = try ACPClient.init(alloc, io, "zeepseek", "zed");
    defer client.deinit();
    try std.testing.expectEqualStrings("zeepseek", client.self_name);
    try std.testing.expectEqualStrings("zed", client.peer_name);
}
