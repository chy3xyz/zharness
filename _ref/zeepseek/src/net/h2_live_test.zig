const std = @import("std");
const h2c = @import("h2_client.zig");
const stream_client = @import("stream_client.zig");

test "h2 example live" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();

    const key_ptr = std.c.getenv("DEEPSEEK_API_KEY") orelse return error.SkipZigTest;
    const key = std.mem.sliceTo(key_ptr, 0);
    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
    defer alloc.free(auth);
    const headers = [_]struct { []const u8, []const u8 }{
        .{ "authorization", auth },
        .{ "content-type", "application/json" },
        .{ "accept", "text/event-stream" },
    };
    const body = "{\"model\":\"deepseek-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true}";

    var client = h2c.H2Client.init(alloc, threaded.io());
    client.read_timeout_ms = 8000;
    var resp = client.request("localhost", 8443, "/", &headers, body, null) catch |e| {
        std.debug.print("H2 ERROR: {s}\n", .{@errorName(e)});
        return;
    };
    defer resp.deinit();
    std.debug.print("H2 STATUS: {d} BODY: {d} bytes\n", .{ resp.status, resp.body.items.len });
    if (resp.body.items.len > 0) {
        std.debug.print("H2 BODY: {s}\n", .{resp.body.items[0..@min(resp.body.items.len, 200)]});
    }
}

test "h2 deepseek live" {
    const alloc = std.testing.allocator;
    const key_env = std.c.getenv("DEEPSEEK_API_KEY") orelse return;
    const key = try alloc.dupe(u8, std.mem.span(key_env));
    defer alloc.free(key);
    var io = std.Io.Threaded.init(alloc, .{});
    var client = h2c.H2Client.init(alloc, io.io());
    const body = "{\"model\":\"deepseek-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true}";
    var headers: [2]struct { []const u8, []const u8 } = .{
        .{ "authorization", std.fmt.allocPrint(alloc, "Bearer {s}", .{key}) catch return },
        .{ "content-type", "application/json" },
    };
    defer alloc.free(headers[0][1]);
    var resp = client.request("api.deepseek.com", 443, "/chat/completions", &headers, body, null) catch |e| {
        std.debug.print("DEEPSEEK ERR: {s}\n", .{@errorName(e)});
        return;
    };
    defer resp.deinit();
    std.debug.print("DEEPSEEK STATUS: {d} BODY: {d} bytes\n", .{ resp.status, resp.body.items.len });
    const idx = std.mem.indexOf(u8, resp.body.items, "Hello") orelse std.mem.indexOf(u8, resp.body.items, "hello");
    std.debug.print("DEEPSEEK has hello: {any}\n", .{idx != null});
}

test "h2 deepseek streaming" {
    const alloc = std.testing.allocator;
    const key_env = std.c.getenv("DEEPSEEK_API_KEY") orelse return;
    const key = try alloc.dupe(u8, std.mem.span(key_env));
    defer alloc.free(key);
    var io = std.Io.Threaded.init(alloc, .{});
    var client = h2c.H2Client.init(alloc, io.io());

    const Ctx = struct {
        alloc: std.mem.Allocator,
        chunks: std.ArrayList([]const u8),
        fn onData(ctx: *anyopaque, data: []const u8) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.chunks.append(c.alloc, data) catch {};
        }
    };
    var ctx = Ctx{ .alloc = alloc, .chunks = .empty };
    defer ctx.chunks.deinit(alloc);

    const body = "{\"model\":\"deepseek-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true}";
    var headers: [2]struct { []const u8, []const u8 } = .{
        .{ "authorization", std.fmt.allocPrint(alloc, "Bearer {s}", .{key}) catch return },
        .{ "content-type", "application/json" },
    };
    defer alloc.free(headers[0][1]);
    var sink = h2c.StreamSink{ .ctx = &ctx, .on_data = Ctx.onData };
    var resp = client.request("api.deepseek.com", 443, "/chat/completions", &headers, body, &sink) catch |e| {
        std.debug.print("STREAM ERR: {s}\n", .{@errorName(e)});
        return;
    };
    defer resp.deinit();
    std.debug.print("STREAM chunks={d} total={d} status={d}\n", .{ ctx.chunks.items.len, resp.body.items.len, resp.status });
    var total: usize = 0;
    for (ctx.chunks.items) |c| total += c.len;
    std.debug.print("STREAM via-callback={d} has hello: {any}\n", .{ total, std.mem.indexOf(u8, resp.body.items, "Hello") != null });
}

test "streamMessageH2 live" {
    const alloc = std.testing.allocator;
    const key_env = std.c.getenv("DEEPSEEK_API_KEY") orelse return;
    const key = try alloc.dupe(u8, std.mem.span(key_env));
    defer alloc.free(key);
    var io = std.Io.Threaded.init(alloc, .{});
    var client = stream_client.DeepSeekStreamClient.init(alloc, io.io(), null, null);

    const Ctx = struct {
        alloc: std.mem.Allocator,
        content: std.ArrayList(u8),
        reasoning: std.ArrayList(u8),
        tool: std.ArrayList(u8),
        fn onChunk(ctx: *anyopaque, kind: stream_client.ChunkKind, data: []const u8) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            switch (kind) {
                .content => c.content.appendSlice(c.alloc, data) catch {},
                .reasoning => c.reasoning.appendSlice(c.alloc, data) catch {},
                .tool => c.tool.appendSlice(c.alloc, data) catch {},
            }
        }
    };
    var ctx = Ctx{ .alloc = alloc, .content = .empty, .reasoning = .empty, .tool = .empty };
    defer ctx.tool.deinit(alloc);
    defer ctx.content.deinit(alloc);
    defer ctx.reasoning.deinit(alloc);

    const sink = stream_client.ChunkSink{ .ctx = &ctx, .on_chunk = Ctx.onChunk };
    const model = "deepseek-chat";
    const CacheDecision = enum { none, hit, miss };
    stream_client.streamMessageH2(&client, key, "hi", &.{}, model, CacheDecision.none, "", null, sink) catch |e| {
        std.debug.print("SMH2 ERR: {s}\n", .{@errorName(e)});
        return;
    };
    std.debug.print("SMH2 content={d} bytes reasoning={d} has hello: {any}\n", .{
        ctx.content.items.len, ctx.reasoning.items.len,
        std.mem.indexOf(u8, ctx.content.items, "Hello") != null,
    });
}

test "extract tool_calls from h2 delta" {
    const alloc = std.testing.allocator;
    const delta = "{\"id\":\"x\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}}]}";
    const ex = try stream_client.extractContentAndReasoningPlain(alloc, delta);
    defer {
        if (ex.content.len > 0) alloc.free(ex.content);
        if (ex.reasoning.len > 0) alloc.free(ex.reasoning);
        if (ex.tool.len > 0) alloc.free(ex.tool);
    }
    try std.testing.expectEqual(@as(usize, 0), ex.content.len);
    try std.testing.expect(ex.tool.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ex.tool, "\"tool_calls\"") != null);
    std.debug.print("TOOL: extracted {d} bytes\n", .{ex.tool.len});
}
