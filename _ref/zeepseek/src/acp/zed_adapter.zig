const std = @import("std");
const acp_mod = @import("mod.zig");
const ACPClient = acp_mod.ACPClient;

const ZedError = error{NotConnected};

pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    column: u32,
    severity: DiagnosticSeverity,
    message: []const u8,
};

pub const DiagnosticSeverity = enum {
    diag_error,
    warning,
    information,
    hint,
};

pub const ZedAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: ACPClient,
    connected: bool = false,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) !ZedAdapter {
        const client = try ACPClient.init(alloc, io, "zeepseek", "zed-agent");
        return ZedAdapter{
            .allocator = alloc,
            .io = io,
            .client = client,
            .connected = false,
        };
    }

    pub fn deinit(self: *ZedAdapter) void {
        self.client.deinit();
    }

    pub fn connect(self: *ZedAdapter) !void {
        const args = &.{ "zed", "--plugin", "agent" };
        self.client.peer_name = try self.allocator.dupe(u8, "zed-agent");
        try self.client.connect(args);
        try self.client.start();
        self.connected = true;
    }

    pub fn disconnect(self: *ZedAdapter) void {
        self.client.stop();
        self.connected = false;
    }

    pub fn sendToAgent(self: *ZedAdapter, content: []const u8) !void {
        if (!self.connected) return ZedError.NotConnected;
        _ = try self.client.call("agent.message", content);
    }

    pub fn getAgentResponse(self: *ZedAdapter) ![]const u8 {
        if (!self.connected) return ZedError.NotConnected;
        return try self.client.call("agent.response", null);
    }

    pub fn getDiagnostics(self: *ZedAdapter) ![]Diagnostic {
        if (!self.connected) return ZedError.NotConnected;
        const result = try self.client.call("diagnostics.list", null);
        defer self.allocator.free(result);

        const parsed = std.json.parseFromSlice([]Diagnostic, self.allocator, result, .{
            .ignore_unknown_fields = true,
        }) catch return &.{};
        return parsed.value;
    }

    pub fn readFile(self: *ZedAdapter, path: []const u8) ![]const u8 {
        if (!self.connected) return ZedError.NotConnected;
        return try self.client.call("fs.read", path);
    }

    pub fn writeFile(self: *ZedAdapter, path: []const u8, content: []const u8) !void {
        if (!self.connected) return ZedError.NotConnected;
        const params = try std.fmt.allocPrint(self.allocator, "\"{s}\",\"{s}\"", .{ path, content });
        defer self.allocator.free(params);
        _ = try self.client.call("fs.write", params);
    }

    pub fn openBuffer(self: *ZedAdapter, path: []const u8) !void {
        if (!self.connected) return ZedError.NotConnected;
        _ = try self.client.call("buffer.open", path);
    }

    pub fn closeBuffer(self: *ZedAdapter, path: []const u8) !void {
        if (!self.connected) return ZedError.NotConnected;
        _ = try self.client.call("buffer.close", path);
    }

    pub fn listBuffers(self: *ZedAdapter) ![][]const u8 {
        if (!self.connected) return ZedError.NotConnected;
        const result = try self.client.call("buffer.list", null);
        defer self.allocator.free(result);

        const parsed = std.json.parseFromSlice([]const []const u8, self.allocator, result, .{
            .ignore_unknown_fields = true,
        }) catch return &.{};
        return parsed.value;
    }
};

test "zed adapter init" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    var adapter = try ZedAdapter.init(alloc, io);
    defer adapter.deinit();
    try std.testing.expectEqual(false, adapter.connected);
}
