//! Fuzz suite: protocol/mcp.zig line framing (SWARM wave-4, agent J-fuzz).
//!
//! The client's framing lives behind fd-based I/O, so the suite drives the
//! REAL pub surface (`connectFds` / `pump` / `callTool` / `initialize` /
//! `takeNotifications` / `deinit`) over in-process pipe pairs — no spawned
//! processes, no network, fully offline and deterministic (short timeouts).
//!
//! Properties: partial lines, CRLF mixtures, junk interleavings, oversized
//! ids and 4 MiB line-overflow attempts are all either tolerated silently
//! or surface as clean McpError values. Never panic, never hang, never leak
//! (fds included — every harness teardown closes both pipe pairs).

const std = @import("std");
const mutator = @import("mutator.zig");
const mcp = @import("../protocol/mcp.zig");
const jsonrpc = @import("../protocol/jsonrpc.zig");

/// close(2) via libc (McpClient.sysClose is file-private; this mirrors it).
fn closeFd(fd: std.posix.fd_t) void {
    if (fd >= 0) _ = std.c.close(@intCast(fd));
}

const corpus_raw = @embedFile("corpus/mcp_lines.txt");

const seed_mcp = 0x3C9E;
/// Keep every blocking window tiny; suites must stay fast.
const test_timeout_ms: i32 = 40;

/// Two pipe pairs = a bidirectional fake server, mirroring mcp.zig's own
/// test harness but local to this suite.
const Harness = struct {
    client: mcp.McpClient,
    req_r: std.posix.fd_t,
    res_w: std.posix.fd_t,

    fn setup(alloc: std.mem.Allocator) !Harness {
        const upstream = try mcp.createPipePair(); // client -> fake
        errdefer closeBoth(upstream);
        const downstream = try mcp.createPipePair(); // fake -> client
        return .{
            .client = mcp.McpClient.connectFds(alloc, upstream[1], downstream[0]),
            .req_r = upstream[0],
            .res_w = downstream[1],
        };
    }

    fn closeBoth(pair: [2]std.posix.fd_t) void {
        closeFd(pair[0]);
        closeFd(pair[1]);
    }

    /// Queue bytes for the client to read (single write; cases stay far
    /// below pipe capacity).
    fn feed(self: *Harness, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.posix.system.write(self.res_w, bytes[off..].ptr, bytes.len - off);
            switch (std.posix.errno(rc)) {
                .SUCCESS => off += @intCast(rc),
                .INTR => continue,
                else => return error.BrokenPipe,
            }
        }
    }

    /// Close the scripted-write end early (EOF simulation).
    fn closeResWrite(self: *Harness) void {
        closeFd(self.res_w);
        self.res_w = -1;
    }

    fn teardown(self: *Harness) void {
        self.client.deinit();
        closeFd(self.req_r);
        closeFd(self.res_w);
        self.req_r = -1;
        self.res_w = -1;
    }
};

fn initResultLine(alloc: std.mem.Allocator) ![]u8 {
    return jsonrpc.encodeResult(
        alloc,
        0,
        "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"9\"}}",
    );
}

test "fuzz: pump tolerates mutated junk lines" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rnd = mutator.Rnd.init(seed_mcp);

    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| {
        var h = try Harness.setup(alloc);
        defer h.teardown();
        h.client.timeout_ms = test_timeout_ms;

        try mutator.mutate(alloc, &out, &rnd, seed);
        // Terminate like a wire write would; junk stays junk either way.
        try h.feed(out.items);
        try h.feed("\n");

        // Instant sweep: consumes buffered bytes; Timeout is success here.
        h.client.pump(0) catch {};
        const n = h.client.pendingNotificationCount();
        if (n > 0) {
            const notifs = try h.client.takeNotifications();
            defer {
                for (notifs) |*nt| nt.deinit(alloc);
                alloc.free(notifs);
            }
            try std.testing.expect(notifs.len <= out.items.len); // ≤ one per line fed
        }
    }
}

test "framing: partial lines split across writes assemble exactly" {
    const alloc = std.testing.allocator;
    var h = try Harness.setup(alloc);
    defer h.teardown();
    h.client.timeout_ms = test_timeout_ms;

    const note =
        \\{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}
    ;
    // First half without newline: nothing stashed yet.
    try h.feed(note[0 .. note.len / 2]);
    h.client.pump(0) catch {};
    try std.testing.expectEqual(@as(usize, 0), h.client.pendingNotificationCount());

    // Second half completes the line; CRLF variant on a second note.
    try h.feed(note[note.len / 2 ..]);
    try h.feed("\r\n");
    try h.feed(note);
    try h.feed("\n");
    h.client.pump(0) catch {};

    try std.testing.expectEqual(@as(usize, 2), h.client.pendingNotificationCount());
    const notifs = try h.client.takeNotifications();
    defer {
        for (notifs) |*nt| nt.deinit(alloc);
        alloc.free(notifs);
    }
    try std.testing.expectEqualStrings("notifications/message", notifs[0].method);
    try std.testing.expectEqualStrings("{\"level\":\"info\"}", notifs[0].params_json);
}

test "regression: oversized id responses are dropped, real response still matched" {
    const alloc = std.testing.allocator;
    var h = try Harness.setup(alloc);
    defer h.teardown();
    h.client.timeout_ms = test_timeout_ms;

    // An id beyond i64 range cannot match any request id; decodeMessage must
    // reject it as MalformedMessage and awaitResponse must keep scanning.
    const oversized =
        "{\"jsonrpc\":\"2.0\",\"id\":99999999999999999999,\"result\":{\"ghost\":true}}\n";
    const good = try jsonrpc.encodeResult(alloc, 0, "{\"content\":[{\"type\":\"text\",\"text\":\"real\"}]}");
    defer alloc.free(good);

    try h.feed(oversized);
    try h.feed(good);
    try h.feed("\n");

    var outcome = try h.client.callTool("echo", "{}");
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome.ok);
    try std.testing.expectEqualStrings("real", outcome.text);
}

test "regression: 4 MiB line overflow surfaces LineTooLong, not OOM or hang" {
    const alloc = std.testing.allocator;
    var h = try Harness.setup(alloc);
    defer h.teardown();
    h.client.timeout_ms = test_timeout_ms;

    // Feed > max_line_bytes (4 MiB) of newline-free junk in 4 KB chunks —
    // small enough for atomic pipe writes — draining between writes so the
    // single-threaded loop can never block on a full pipe.
    var chunk: [4 * 1024]u8 = undefined;
    @memset(&chunk, 'x');
    const target: usize = (4 << 20) + 2 * chunk.len;
    var wrote: usize = 0;
    while (wrote <= target) : (wrote += chunk.len) {
        try h.feed(&chunk);
        h.client.pump(0) catch |e| switch (e) {
            error.LineTooLong => return, // clean rejection reached
            else => {}, // Timeout etc. are fine mid-flood
        };
    }
    // If the cap never tripped, the bounded-line property is violated.
    return error.TestUnexpectedResult;
}

test "framing: EOF mid-line and clean EOF surface distinct errors" {
    const alloc = std.testing.allocator;

    // EOF with a partial line pending -> ConnectionClosed.
    {
        var h = try Harness.setup(alloc);
        defer h.teardown();
        h.client.timeout_ms = test_timeout_ms;
        try h.feed("{\"partial\":");
        h.closeResWrite();
        try std.testing.expectError(error.ConnectionClosed, h.client.pump(test_timeout_ms));
    }

    // EOF with nothing pending during initialize -> InitializeRejected path
    // degenerates to ConnectionClosed from the dead server.
    {
        var h = try Harness.setup(alloc);
        defer h.teardown();
        h.client.timeout_ms = test_timeout_ms;
        h.closeResWrite();
        try std.testing.expectError(error.ConnectionClosed, h.client.initialize());
    }
}

test "initialize round-trip still exact after hostile preamble" {
    const alloc = std.testing.allocator;
    var h = try Harness.setup(alloc);
    defer h.teardown();
    h.client.timeout_ms = test_timeout_ms;

    // Hostile preamble first: junk line + CRLF-framed valid envelope +
    // notification + stale-id response.
    try h.feed("total garbage\n\r\n");
    const note_line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/other\",\"params\":{}}\n";
    try h.feed(note_line);
    const stale = "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{}}\n";
    try h.feed(stale);

    const init_line = try initResultLine(alloc);
    defer alloc.free(init_line);
    try h.feed(init_line);
    try h.feed("\n");

    var info = try h.client.initialize();
    defer info.deinit(alloc);
    try std.testing.expectEqualStrings("fake", info.server_name);
    try std.testing.expectEqualStrings("2024-11-05", info.protocol_version);
}
