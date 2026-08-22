const std = @import("std");
const http2 = @import("http_client2.zig");

const PORT: u16 = 18472;

fn client(alloc: std.mem.Allocator, io: std.Io, read_timeout_ms: u64) http2.HttpClient {
    var c = http2.HttpClient.init(alloc, io);
    c.config = .{ .read_timeout_ms = read_timeout_ms };
    return c;
}

test "content-length body" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    var c = client(alloc, threaded.io(), 2000);

    var resp = try c.open("http", "127.0.0.1", PORT, "POST", "/echo", &.{}, "");
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    var buf: [256]u8 = undefined;
    const n = try resp.readBody(&buf);
    try std.testing.expectEqualSlices(u8, "hello from server", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), try resp.readBody(&buf));
}

test "chunked body reassembled" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    var c = client(alloc, threaded.io(), 2000);

    var resp = try c.open("http", "127.0.0.1", PORT, "POST", "/chunked", &.{}, "");
    defer resp.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var buf: [32]u8 = undefined;
    while (true) {
        const n = try resp.readBody(&buf);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    try std.testing.expectEqualSlices(u8, "chunk1-chunk2-done", out.items);
}

test "read timeout returns error.Timeout" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    var c = client(alloc, threaded.io(), 1000);

    // The server sleeps 6s before sending headers; with a 1s read timeout,
    // open() itself (which reads the status line) must time out.
    var resp = c.open("http", "127.0.0.1", PORT, "POST", "/slow", &.{}, "") catch |e| {
        try std.testing.expectEqual(http2.ResponseError.Timeout, e);
        return;
    };
    defer resp.deinit();
    var buf: [64]u8 = undefined;
    const err = resp.readBody(&buf) catch |e| e;
    try std.testing.expectEqual(http2.ResponseError.Timeout, err);
}

test "https via std.http branch works (network)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    var c = client(alloc, threaded.io(), 5000);

    var resp = c.open("https", "example.com", 443, "GET", "/", &.{}, "") catch return error.SkipZigTest;
    defer resp.deinit();
    try std.testing.expect(resp.status >= 200 and resp.status < 400);
    var buf: [512]u8 = undefined;
    const n = try resp.readBody(&buf);
    try std.testing.expect(n > 0);
}
