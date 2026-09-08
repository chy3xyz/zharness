//! B-net self-test root — run with:
//!     zig test -lc test/_t_net.zig
//!
//! Top-level placement keeps every `@import("../src/../…")` inside the module path.
//! The integrator folds these modules into src/tests.zig at wave 3.

const std = @import("std");

comptime {
    _ = @import("../src/server/httpd.zig");
    _ = @import("../src/server/api.zig");
    _ = @import("../src/tool/webfetch.zig");
}

// ── integration: live server round-trip over loopback ──────────────────────
// Binds 127.0.0.1:0 (ephemeral port), serves the fake api deps, queries
// /healthz through real curl, then stops gracefully. No external network is
// touched — this is purely offline loopback I/O.

const httpd = @import("../src/server/httpd.zig");
const api = @import("../src/server/api.zig");
const webfetch = @import("../src/tool/webfetch.zig");

test "http server serves healthz over loopback and stops cleanly" {
    const alloc = std.testing.allocator;
    const clib = @import("clib.zig");

    const deps = try alloc.create(api.ServerDeps);
    defer alloc.destroy(deps);
    deps.* = .{
        .ctx = null,
        .runTask = stubRun,
        .listSessions = stubList,
        .getSession = stubGet,
    };

    var srv = try httpd.Server.init(
        // The accept thread allocates (per-connection arenas) concurrently
        // with this test thread; std.testing.allocator is single-threaded,
        // so the server gets the plain page allocator instead. Response
        // memory is arena-owned and released at connection end.
        std.heap.page_allocator,
        .{ .ctx = deps, .call = api.handle },
        .{ .port = 0 },
    );
    defer srv.deinit();
    try srv.spawn();
    const port = srv.boundPort();
    try std.testing.expect(port > 0);

    // Query via curl (popen), same transport the repo uses everywhere.
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/healthz", .{port});
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(alloc);
    try cmd.appendSlice(alloc, "curl --silent --max-time 10 ");
    try model_appendQuoted(alloc, &cmd, url);

    const cmd_z = try alloc.dupeSentinel(u8, cmd.items, 0);
    defer alloc.free(cmd_z);
    const fp = clib.popenRead(cmd_z.ptr) orelse return error.TestUnexpectedResult;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    _ = clib.pclosePipe(fp);

    try std.testing.expectEqualStrings("{\"ok\":true}", out.items);

    // Graceful stop: flag + tick wake, join, close.
    srv.stop();
    srv.join();
}

fn stubRun(ctx: ?*anyopaque, alloc: std.mem.Allocator, prompt: []const u8, session_id: ?[]const u8) anyerror![]const u8 {
    _ = ctx;
    _ = prompt;
    _ = session_id;
    return alloc.dupe(u8, "");
}

fn stubList(ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]api.ServerDeps.SessionSummary {
    _ = ctx;
    return alloc.alloc(api.ServerDeps.SessionSummary, 0);
}

fn stubGet(ctx: ?*anyopaque, alloc: std.mem.Allocator, id: []const u8) anyerror!?api.ServerDeps.SessionDetail {
    _ = ctx;
    _ = alloc;
    _ = id;
    return null;
}

// Local shell-quoting mirror (webfetch's copy is private to that module).
fn model_appendQuoted(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '\'');
    for (s) |ch| {
        if (ch == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, ch);
        }
    }
    try out.append(alloc, '\'');
}

comptime {
    // Silence unused-import warnings if integration test above is removed.
    _ = webfetch;
}
