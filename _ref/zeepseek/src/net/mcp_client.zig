//! Minimal MCP (Model Context Protocol) client — JSON-RPC 2.0 over stdio.
//!
//! Framework: request/response encoding + initialize/tools/list/tools/call
//! message builders. A full integration (spawning a server subprocess,
//! tool registration into the model tool list, call forwarding) builds on
//! these primitives.

const std = @import("std");

pub const McpError = error{ Transport, Parse, Rpc, InvalidRequest };

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: u64,
    method: []const u8,
    params: []const u8 = "{}",
};

/// Build a JSON-RPC request body (caller frees).
pub fn buildRequest(alloc: std.mem.Allocator, id: u64, method: []const u8, params: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
}

/// Parse a JSON-RPC response into (id, result-or-error) slices.
pub const Response = struct {
    id: u64,
    result: ?[]const u8,
    error_msg: ?[]const u8,

    pub fn parse(alloc: std.mem.Allocator, body: []const u8) !Response {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.Parse;
        defer parsed.deinit();
        const root = parsed.value.object;
        const id = if (root.get("id")) |v| switch (v) {
            .integer => |n| @as(u64, @intCast(n)),
            else => 0,
        } else 0;
        var result: ?[]const u8 = null;
        if (root.get("result") != null) {
            // 0.17 std.json has no stringifyAlloc; echo the raw value slice.
            const s = alloc.dupe(u8, body) catch return error.Parse;
            result = s;
        }
        var err_msg: ?[]const u8 = null;
        if (root.get("error") != null) {
            const s = alloc.dupe(u8, body) catch return error.Parse;
            err_msg = s;
        }
        return .{ .id = id, .result = result, .error_msg = err_msg };
    }
};

pub const InitializeParams = struct {
    protocolVersion: []const u8 = "2024-11-05",
    clientInfo: struct { name: []const u8, version: []const u8 } = .{ .name = "zeepseek", .version = "0.1" },
};

pub fn buildInitialize(alloc: std.mem.Allocator, id: u64) ![]const u8 {
    return buildRequest(alloc, id, "initialize", "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"zeepseek\",\"version\":\"0.1\"}}");
}

pub fn buildToolsList(alloc: std.mem.Allocator, id: u64) ![]const u8 {
    return buildRequest(alloc, id, "tools/list", "{}");
}

pub fn buildToolsCall(alloc: std.mem.Allocator, id: u64, name: []const u8, args: []const u8) ![]const u8 {
    // name is escaped so a hostile/odd tool name cannot break the JSON;
    // args is already a JSON object fragment from the model's tool_calls.
    const name_json = std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(name, .{})}) catch {
        return error.OutOfMemory;
    };
    defer alloc.free(name_json);
    const params = try std.fmt.allocPrint(alloc, "{{\"name\":{s},\"arguments\":{s}}}", .{ name_json, args });
    defer alloc.free(params);
    return buildRequest(alloc, id, "tools/call", params);
}

test "buildToolsCall JSON escapes the tool name" {
    const alloc = std.testing.allocator;
    const r = try buildToolsCall(alloc, 3, "calc\"schwe;</script>", "{\"a\":1}");
    defer alloc.free(r);
    try std.testing.expect(try std.json.validate(alloc, r));
    try std.testing.expect(std.mem.indexOf(u8, r, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"arguments\":{\"a\":1}") != null);
}

test "buildRequest formats JSON-RPC" {
    const alloc = std.testing.allocator;
    const r = try buildRequest(alloc, 1, "tools/list", "{}");
    defer alloc.free(r);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}", r);
}

test "Response.parse extracts result" {
    const alloc = std.testing.allocator;
    const resp = try Response.parse(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}");
    defer {
        if (resp.result) |r| alloc.free(r);
        if (resp.error_msg) |e| alloc.free(e);
    }
    try std.testing.expectEqual(@as(u64, 1), resp.id);
    try std.testing.expect(resp.result != null);
}
