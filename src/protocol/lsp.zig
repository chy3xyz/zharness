//! Minimal LSP client over stdio (Content-Length framed JSON-RPC 2.0).
//!
//! Scope: enough for one-shot diagnostics - spawn (or wrap fds), initialize,
//! textDocument/didOpen, collect textDocument/publishDiagnostics, shutdown.
//! No completion/hover/workspace sync.

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");

pub const LspError = error{
    TransportWrite,
    TransportRead,
    ConnectionClosed,
    Timeout,
    LineTooLong,
    ProtocolViolation,
    ServerRejectedRequest,
    OutOfMemory,
};

extern "c" fn time(tloc: ?*c_long) c_long;

pub const default_timeout_ms: i32 = 10_000;
const read_chunk_size: usize = 4096;
const max_accum: usize = 8 * 1024 * 1024;

pub const LspClient = struct {
    alloc: std.mem.Allocator,
    io: ?std.Io,
    conn: Conn,
    next_id: i64 = 1,
    timeout_ms: i32 = default_timeout_ms,
    accum: std.ArrayList(u8) = .empty,

    const Conn = union(enum) {
        child: std.process.Child,
        fds: struct { write_fd: std.posix.fd_t, read_fd: std.posix.fd_t },
    };

    pub fn spawnChild(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !LspClient {
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        return .{ .alloc = alloc, .io = io, .conn = .{ .child = child } };
    }

    pub fn connectFds(alloc: std.mem.Allocator, write_fd: std.posix.fd_t, read_fd: std.posix.fd_t) LspClient {
        return .{ .alloc = alloc, .io = null, .conn = .{ .fds = .{ .write_fd = write_fd, .read_fd = read_fd } } };
    }

    fn writeFd(self: *const LspClient) std.posix.fd_t {
        return switch (self.conn) {
            .child => |c| c.stdin.?.handle,
            .fds => |f| f.write_fd,
        };
    }

    fn readFd(self: *const LspClient) std.posix.fd_t {
        return switch (self.conn) {
            .child => |c| c.stdout.?.handle,
            .fds => |f| f.read_fd,
        };
    }

    fn monotonicMs() i64 {
        return @as(i64, @intCast(time(null))) * 1000;
    }

    fn writeAll(self: *LspClient, bytes: []const u8) LspError!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.posix.system.write(self.writeFd(), bytes[off..].ptr, bytes.len - off);
            switch (std.posix.errno(rc)) {
                .SUCCESS => off += @intCast(rc),
                .INTR => continue,
                .AGAIN => {
                    var pf = [_]std.posix.pollfd{.{ .fd = self.writeFd(), .events = std.posix.POLL.OUT, .revents = 0 }};
                    _ = std.posix.poll(&pf, self.timeout_ms) catch return error.TransportWrite;
                },
                else => return error.TransportWrite,
            }
        }
    }

    /// Write one framed message: Content-Length header + CRLF CRLF + payload.
    pub fn writeMessage(self: *LspClient, payload: []const u8) LspError!void {
        var hdr: [64]u8 = undefined;
        const head = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{payload.len}) catch
            return error.TransportWrite;
        try self.writeAll(head);
        try self.writeAll(payload);
    }

    /// Read one framed message; null on clean EOF; error.Timeout otherwise.
    pub fn readMessage(self: *LspClient, timeout_ms: i32) LspError!?[]u8 {
        const deadline = monotonicMs() + timeout_ms;
        while (true) {
            if (std.mem.indexOf(u8, self.accum.items, "\r\n\r\n")) |hdr_end| {
                const header = self.accum.items[0..hdr_end];
                const len = parseContentLength(header) orelse return error.ProtocolViolation;
                const body_start = hdr_end + 4;
                if (self.accum.items.len >= body_start + len) {
                    const body = self.alloc.dupe(u8, self.accum.items[body_start .. body_start + len]) catch
                        return error.OutOfMemory;
                    const rest = self.accum.items.len - (body_start + len);
                    std.mem.copyForwards(u8, self.accum.items[0..rest], self.accum.items[body_start + len ..]);
                    self.accum.shrinkRetainingCapacity(rest);
                    return body;
                }
            }
            if (self.accum.items.len > max_accum) return error.LineTooLong;
            const remaining = deadline - monotonicMs();
            if (remaining <= 0) return error.Timeout;
            var pfds = [_]std.posix.pollfd{.{ .fd = self.readFd(), .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&pfds, @intCast(remaining)) catch return error.TransportRead;
            if (ready == 0) return error.Timeout;
            if (pfds[0].revents & std.posix.POLL.IN == 0) {
                if (pfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0)
                    return error.ConnectionClosed;
                continue;
            }
            var chunk: [read_chunk_size]u8 = undefined;
            const n = std.posix.read(self.readFd(), &chunk) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => return error.ConnectionClosed,
            };
            if (n == 0) return if (self.accum.items.len == 0) null else error.ConnectionClosed;
            self.accum.appendSlice(self.alloc, chunk[0..n]) catch return error.OutOfMemory;
        }
    }

    fn request(self: *LspClient, method: []const u8, params_json: []const u8) LspError!i64 {
        const id = self.next_id;
        self.next_id += 1;
        const wire = jsonrpc.encodeRequest(self.alloc, id, method, params_json) catch return error.OutOfMemory;
        defer self.alloc.free(wire);
        try self.writeMessage(wire);
        return id;
    }

    fn notify(self: *LspClient, method: []const u8, params_json: []const u8) LspError!void {
        const wire = jsonrpc.encodeNotification(self.alloc, method, params_json) catch return error.OutOfMemory;
        defer self.alloc.free(wire);
        try self.writeMessage(wire);
    }

    /// initialize handshake plus the initialized notification.
    pub fn initialize(self: *LspClient, root_uri: []const u8) LspError!void {
        const params = std.fmt.allocPrint(
            self.alloc,
            "{{\"processId\":null,\"rootUri\":\"{s}\",\"capabilities\":{{}}}}",
            .{root_uri},
        ) catch return error.OutOfMemory;
        defer self.alloc.free(params);
        const want = try self.request("initialize", params);
        while (true) {
            const msg = (try self.readMessage(self.timeout_ms)) orelse return error.ConnectionClosed;
            defer self.alloc.free(msg);
            var decoded = jsonrpc.decodeMessage(self.alloc, msg) catch continue;
            defer decoded.deinit(self.alloc);
            switch (decoded) {
                .response_ok => |r| {
                    if (jsonrpc.Id.eql(r.id, .{ .number = want })) break;
                },
                .response_err => |r| {
                    if (jsonrpc.Id.eql(r.id, .{ .number = want })) return error.ServerRejectedRequest;
                },
                else => {},
            }
        }
        try self.notify("initialized", "{}");
    }

    pub fn didOpen(self: *LspClient, uri: []const u8, language_id: []const u8, text: []const u8) LspError!void {
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(self.alloc);
        p.appendSlice(self.alloc, "{\"textDocument\":{\"uri\":\"") catch return error.OutOfMemory;
        appendEscaped(self.alloc, &p, uri) catch return error.OutOfMemory;
        p.appendSlice(self.alloc, "\",\"languageId\":\"") catch return error.OutOfMemory;
        appendEscaped(self.alloc, &p, language_id) catch return error.OutOfMemory;
        p.appendSlice(self.alloc, "\",\"version\":1,\"text\":\"") catch return error.OutOfMemory;
        appendEscaped(self.alloc, &p, text) catch return error.OutOfMemory;
        p.appendSlice(self.alloc, "\"}}") catch return error.OutOfMemory;
        try self.notify("textDocument/didOpen", p.items);
    }

    /// Read until a textDocument/publishDiagnostics notification for uri
    /// arrives or the window elapses. Returns the raw params JSON (owned) or
    /// null on timeout.
    pub fn collectDiagnostics(self: *LspClient, uri: []const u8, window_ms: i32) LspError!?[]u8 {
        const deadline = monotonicMs() + window_ms;
        while (true) {
            const remaining = deadline - monotonicMs();
            if (remaining <= 0) return null;
            const msg = self.readMessage(@intCast(remaining)) catch |e| switch (e) {
                error.Timeout => return null,
                else => return e,
            };
            const m = msg orelse return null;
            defer self.alloc.free(m);
            var decoded = jsonrpc.decodeMessage(self.alloc, m) catch continue;
            defer decoded.deinit(self.alloc);
            if (decoded != .notification) continue;
            const nt = decoded.notification;
            if (!std.mem.eql(u8, nt.method, "textDocument/publishDiagnostics")) continue;
            if (std.mem.indexOf(u8, nt.params_json, uri) == null) continue;
            return self.alloc.dupe(u8, nt.params_json) catch error.OutOfMemory;
        }
    }

    pub fn shutdown(self: *LspClient) void {
        const id = self.next_id;
        self.next_id += 1;
        const wire = jsonrpc.encodeRequest(self.alloc, id, "shutdown", "null") catch null;
        if (wire) |w| {
            defer self.alloc.free(w);
            self.writeMessage(w) catch {};
        }
        self.notify("exit", "null") catch {};
    }

    pub fn deinit(self: *LspClient) void {
        self.accum.deinit(self.alloc);
        switch (self.conn) {
            .child => |*c| {
                // Child.wait owns pipe cleanup; closing first would double-close.
                if (self.io) |io| _ = c.wait(io) catch {};
            },
            .fds => |f| {
                _ = std.posix.system.close(f.write_fd);
                _ = std.posix.system.close(f.read_fd);
            },
        }
    }
};

fn sysClose(fd: std.posix.fd_t) void {
    _ = std.posix.system.close(fd);
}

fn parseContentLength(header: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, header, "\r\n");
    while (it.next()) |line| {
        if (line.len < 15) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) continue;
        const v = std.mem.trim(u8, line[15..], " \t");
        return std.fmt.parseInt(usize, v, 10) catch null;
    }
    return null;
}

fn appendEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseContentLength reads the header case-insensitively" {
    try testing.expectEqual(@as(?usize, 42), parseContentLength("Content-Length: 42"));
    try testing.expectEqual(@as(?usize, 7), parseContentLength("content-length: 7\r\nContent-Type: x"));
    try testing.expectEqual(@as(?usize, null), parseContentLength("Content-Type: x"));
}

test "appendEscaped escapes JSON control and quote bytes" {
    const alloc = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendEscaped(alloc, &out, "a\"b\\c\nd");
    try testing.expectEqualStrings("a\\\"b\\\\c\\nd", out.items);
}
