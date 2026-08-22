//! MCP stdio runner — spawns an MCP server subprocess and drives the
//! JSON-RPC handshake (initialize -> tools/list) over stdin/stdout pipes.
//!
//! Uses the same independent-worker pattern as git_worker: the child runs
//! outside the zigzag runtime, so no fork-in-multithreaded-interaction
//! issues. Responses are read with a poll timeout so a slow/absent server
//! cannot hang the UI thread indefinitely.

const std = @import("std");
const posix = std.posix;

pub const McpServer = struct {
    cfg_name: []const u8, // name from ~/.zeepseek/mcp.json
    command: []const u8,
    args: []const []const u8,
};

pub const McpSession = struct {
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    child_pid: posix.pid_t,
    alloc: std.mem.Allocator,
    id: u64 = 0,
    initialized: bool = false,

    pub fn spawn(io: std.Io, alloc: std.mem.Allocator, server: McpServer) !McpSession {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(alloc);
        try argv.append(alloc, server.command);
        for (server.args) |a| try argv.append(alloc, a);

        const child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        return .{
            .stdin_fd = child.stdin.?.handle,
            .stdout_fd = child.stdout.?.handle,
            .child_pid = child.id orelse 0,
            .alloc = alloc,
        };
    }

    /// Write a JSON-RPC request and read one response line (Content-Length
    /// framed) with a poll timeout.
    pub fn roundTrip(self: *McpSession, body: []const u8, timeout_ms: u64) ![]const u8 {
        self.id += 1;
        var framed = std.ArrayList(u8).empty;
        defer framed.deinit(self.alloc);
        const hdr = try std.fmt.allocPrint(self.alloc, "Content-Length: {d}\r\n\r\n", .{body.len});
        defer self.alloc.free(hdr);
        try framed.appendSlice(self.alloc, hdr);
        try framed.appendSlice(self.alloc, body);

        const n = framed.items.len;
        var off: usize = 0;
        while (off < n) {
            const w = std.c.write(self.stdin_fd, framed.items[off..].ptr, framed.items.len - off);
            if (w <= 0) return error.TransportClosed;
            off += @intCast(w);
        }

        // Read headers (until \r\n\r\n) then the payload.
        var buf: [65536]u8 = undefined;
        var total: usize = 0;
        var polls_left: u32 = @intCast(@max(timeout_ms / 100, 1));
        var content_len: usize = 0;
        while (true) {
            if (polls_left == 0) return error.Timeout;
            polls_left -= 1;
            var pollfd = [1]posix.pollfd{.{ .fd = self.stdout_fd, .events = posix.POLL.IN, .revents = 0 }};
            const pr = try posix.poll(pollfd[0..], 100);
            if (pr == 0) continue;
            const r = try posix.read(self.stdout_fd, buf[total..]);
            if (r == 0) return error.TransportClosed;
            total += r;
            const head_end = std.mem.indexOfPos(u8, buf[0..total], 0, "\r\n\r\n");
            if (head_end) |he| {
                const headers = buf[0..he];
                var it = std.mem.splitScalar(u8, headers, '\n');
                while (it.next()) |line| {
                    if (std.ascii.startsWithIgnoreCase(line, "content-length")) {
                        content_len = std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \r"), 10) catch 0;
                    }
                }
                const body_start = he + 4;
                while (total < body_start + content_len) {
                    const r2 = try posix.read(self.stdout_fd, buf[total..]);
                    if (r2 == 0) return error.TransportClosed;
                    total += r2;
                }
                return self.alloc.dupe(u8, buf[body_start .. body_start + content_len]);
            }
        }
    }

    pub fn deinit(self: *McpSession) void {
        _ = std.c.close(self.stdin_fd);
        _ = std.c.close(self.stdout_fd);
        _ = posix.kill(self.child_pid, posix.SIG.KILL) catch {};
    }
};

test "roundTrip handshake against a local demo server" {
    // Requires /tmp/zz_mcp_demo.py (a tiny stdio MCP server) to exist.
    var path_buf: [512:0]u8 = undefined;
    const demo_path = "/tmp/zz_mcp_demo.py";
    @memcpy(path_buf[0..demo_path.len], demo_path);
    path_buf[demo_path.len] = 0;
    if (std.c.access(&path_buf, std.posix.F_OK) != 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const srv = McpServer{ .cfg_name = "demo", .command = "/usr/bin/python3", .args = &.{"/tmp/zz_mcp_demo.py"} };
    var sess = try McpSession.spawn(threaded.io(), alloc, srv);
    defer sess.deinit();
    const init = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{}}}}", .{});
    defer alloc.free(init);
    const resp = try sess.roundTrip(init, 4000);
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "serverInfo") != null);
    const tl = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{{}}}}", .{});
    defer alloc.free(tl);
    const tl_resp = try sess.roundTrip(tl, 4000);
    defer alloc.free(tl_resp);
    try std.testing.expect(std.mem.indexOf(u8, tl_resp, "demo_tool") != null);
    // tools/call: invoke demo_tool and verify the text result comes back.
    const call = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{{\"name\":\"demo_tool\",\"arguments\":{{}}}}}}", .{});
    defer alloc.free(call);
    const call_resp = try sess.roundTrip(call, 4000);
    defer alloc.free(call_resp);
    try std.testing.expect(std.mem.indexOf(u8, call_resp, "demo result from mcp") != null);
}

test "spawn fails cleanly for missing command" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const srv = McpServer{ .cfg_name = "missing", .command = "/nonexistent/mcp-server-xyz", .args = &.{} };
    _ = McpSession.spawn(threaded.io(), alloc, srv) catch |e| {
        try std.testing.expect(e == error.FileNotFound);
        return;
    };
    return error.TestUnexpectedResult;
}
