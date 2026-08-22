//! Lightweight HTTP/1.1 client with connect and read timeouts.
//!
//! Uses a raw POSIX socket (not std.Io.Threaded's event-loop sockets) so that
//! SO_RCVTIMEO-based read timeouts work cleanly: Threaded io panics on EAGAIN
//! in Debug and its futex bookkeeping misbehaves when a blocking read is
//! bypassed with poll. With a raw fd, read() returning EAGAIN is just our
//! Timeout signal.
//!
//! TLS is a separate, larger effort (requires a custom Io.Reader/Writer
//! vtable around the socket for std.crypto.tls.Client); this module proves
//! the HTTP framing + timeout layer and is what stream_client will use.

const std = @import("std");
const posix = std.posix;
const net = std.Io.net;

/// Minimal libc bindings for raw sockets (std.posix.system does not expose
/// these on macOS; linux.zig has them as syscalls only).
const libc = struct {
    extern "c" fn socket(domain: i32, socket_type: i32, protocol: i32) i32;
    extern "c" fn connect(fd: i32, addr: *const anyopaque, len: u32) i32;
    extern "c" fn close(fd: i32) i32;
};

pub const Header = std.http.Header;

pub const Config = struct {
    read_timeout_ms: u64 = 30_000,
};

pub const ResponseError = error{
    Timeout,
    ConnectionFailed,
    ConnectionClosed,
    InvalidResponse,
    OutOfMemory,
};

fn setReadTimeout(fd: posix.fd_t, timeout_ms: u64) void {
    const sec: i64 = @intCast(timeout_ms / 1000);
    const usec: i32 = @intCast((timeout_ms % 1000) * 1000);
    const tv = posix.timeval{ .sec = sec, .usec = usec };
    posix.setsockopt(fd, posix.SOL.SOCKET, std.c.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// Streaming HTTP response. Single-use connection; close with deinit().
///
/// Two modes, matching the zigmodu approach: plain HTTP uses a raw socket
/// with read timeouts; HTTPS is delegated to std.http.Client (TLS + CA
/// verification are internal to std and not externally reproducible).
pub const StreamingResponse = struct {
    const Mode = enum { raw, std_http };

    allocator: std.mem.Allocator,
    mode: Mode = .raw,
    status: u16 = 0,
    // raw mode
    fd: posix.fd_t = -1,
    content_length: ?u64 = null,
    content_remaining: u64 = 0,
    chunked: bool = false,
    chunk_remaining: u64 = 0,
    raw: []u8 = &.{},
    raw_start: usize = 0,
    raw_end: usize = 0,
    // std_http mode
    https_client: ?*std.http.Client = null,
    https_req: ?*std.http.Client.Request = null,
    https_response: ?*std.http.Client.Response = null,
    https_reader: ?*std.Io.Reader = null,
    https_transfer: ?[]u8 = null,

    pub fn readBody(self: *StreamingResponse, buf: []u8) ResponseError!usize {
        switch (self.mode) {
            .raw => return self.readBodyRaw(buf),
            .std_http => {
                const n = self.https_reader.?.readSliceShort(buf) catch |e| switch (e) {
                    error.ReadFailed => return 0,
                };
                return n;
            },
        }
    }

    fn readBodyRaw(self: *StreamingResponse, buf: []u8) ResponseError!usize {
        if (self.chunked) {
            while (self.chunk_remaining == 0) {
                var line = std.ArrayList(u8).empty;
                defer line.deinit(self.allocator);
                const size_line = (try self.readLine(&line)) orelse return error.ConnectionClosed;
                const semi = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
                const size_str = std.mem.trim(u8, size_line[0..semi], " \t\r\n");
                if (size_str.len == 0) return error.InvalidResponse;
                const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch return error.InvalidResponse;
                if (chunk_size == 0) {
                    while (true) {
                        var tl = std.ArrayList(u8).empty;
                        defer tl.deinit(self.allocator);
                        const t = (try self.readLine(&tl)) orelse break;
                        if (t.len == 0) break;
                    }
                    self.chunked = false;
                    return 0;
                }
                self.chunk_remaining = chunk_size;
            }
            const take = @min(buf.len, self.chunk_remaining);
            const n = try self.readExactRaw(buf[0..take]);
            self.chunk_remaining -= n;
            if (self.chunk_remaining == 0) {
                var cr = std.ArrayList(u8).empty;
                defer cr.deinit(self.allocator);
                const trail = (try self.readLine(&cr)) orelse return error.InvalidResponse;
                _ = trail;
            }
            return n;
        }

        if (self.content_length != null) {
            if (self.content_remaining == 0) return 0;
            const take = @min(buf.len, self.content_remaining);
            const n = try self.readExactRaw(buf[0..take]);
            self.content_remaining -= n;
            return n;
        }
        return self.readRaw(buf);
    }

    /// Bounded read: SO_RCVTIMEO makes the blocking read return EAGAIN
    /// (-> Timeout) when the server stalls.
    fn readWithTimeout(self: *StreamingResponse, buf: []u8) ResponseError!usize {
        return posix.read(self.fd, buf) catch |e| switch (e) {
            error.WouldBlock => error.Timeout,
            error.ConnectionResetByPeer => error.ConnectionClosed,
            else => error.InvalidResponse,
        };
    }

    fn readRaw(self: *StreamingResponse, buf: []u8) ResponseError!usize {
        if (self.raw_start < self.raw_end) {
            const n = @min(buf.len, self.raw_end - self.raw_start);
            @memcpy(buf[0..n], self.raw[self.raw_start .. self.raw_start + n]);
            self.raw_start += n;
            return n;
        }
        return self.readWithTimeout(buf);
    }

    fn readExactRaw(self: *StreamingResponse, buf: []u8) ResponseError!usize {
        if (self.raw_start < self.raw_end) {
            const n = @min(buf.len, self.raw_end - self.raw_start);
            @memcpy(buf[0..n], self.raw[self.raw_start .. self.raw_start + n]);
            self.raw_start += n;
            return n;
        }
        const n = try self.readWithTimeout(buf);
        if (n == 0) return error.ConnectionClosed;
        return n;
    }

    /// Read a line (up to and including '\n'). Returns null on clean EOF.
    fn readLine(self: *StreamingResponse, out: *std.ArrayList(u8)) ResponseError!?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.raw[self.raw_start..self.raw_end], '\n')) |rel| {
                const nl = self.raw_start + rel;
                const line = self.raw[self.raw_start .. nl + 1];
                self.raw_start = nl + 1;
                try out.appendSlice(self.allocator, line);
                return std.mem.trimEnd(u8, out.items, "\r\n");
            }
            if (self.raw_start < self.raw_end) {
                try out.appendSlice(self.allocator, self.raw[self.raw_start..self.raw_end]);
            }
            const n = try self.readWithTimeout(self.raw);
            if (n == 0) {
                if (out.items.len == 0) return null;
                return std.mem.trimEnd(u8, out.items, "\r\n");
            }
            self.raw_start = 0;
            self.raw_end = n;
        }
    }

    pub fn deinit(self: *StreamingResponse) void {
        switch (self.mode) {
            .raw => {
                _ = libc.close(@intCast(self.fd));
                self.allocator.free(self.raw);
            },
            .std_http => {
                if (self.https_transfer) |t| self.allocator.free(t);
                if (self.https_response) |response| self.allocator.destroy(response);
                if (self.https_req) |req| {
                    req.deinit();
                    self.allocator.destroy(req);
                }
                if (self.https_client) |c| {
                    c.deinit();
                    self.allocator.destroy(c);
                }
            },
        }
    }
};

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) HttpClient {
        return .{ .allocator = allocator, .io = io };
    }

    fn writeAllRaw(fd: posix.fd_t, bytes: []const u8) ResponseError!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return error.ConnectionFailed;
            off += @intCast(n);
        }
    }

    /// HTTPS via std.http.Client (TLS + CA verification handled by std).
    pub fn openHttps(
        self: *HttpClient,
        host: []const u8,
        port: u16,
        method: []const u8,
        path: []const u8,
        headers: []const Header,
        body: []const u8,
    ) ResponseError!StreamingResponse {
        const client = self.allocator.create(std.http.Client) catch return error.OutOfMemory;
        client.* = std.http.Client{ .allocator = self.allocator, .io = self.io };
        errdefer {
            client.deinit();
            self.allocator.destroy(client);
        }

        var url_buf: [2048]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://{s}:{d}{s}", .{ host, port, path }) catch return error.OutOfMemory;
        const uri = std.Uri.parse(url) catch return error.InvalidResponse;

        const req = self.allocator.create(std.http.Client.Request) catch return error.OutOfMemory;
        const http_method: std.http.Method = if (std.ascii.eqlIgnoreCase(method, "GET")) .GET else .POST;
        req.* = client.request(http_method, uri, .{ .extra_headers = headers, .keep_alive = false }) catch return error.ConnectionFailed;
        errdefer {
            req.deinit();
            self.allocator.destroy(req);
        }
        if (body.len > 0) {
            const body_owned = self.allocator.dupe(u8, body) catch return error.OutOfMemory;
            defer self.allocator.free(body_owned);
            req.sendBodyComplete(body_owned) catch return error.ConnectionFailed;
        }

        const response = self.allocator.create(std.http.Client.Response) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(response);
        response.* = req.receiveHead(undefined) catch return error.ConnectionFailed;
        const status: u16 = @intFromEnum(response.head.status);

        const transfer = self.allocator.alloc(u8, 64 * 1024) catch return error.OutOfMemory;
        errdefer self.allocator.free(transfer);
        const reader = response.reader(transfer);

        return StreamingResponse{
            .allocator = self.allocator,
            .mode = .std_http,
            .status = status,
            .https_client = client,
            .https_req = req,
            .https_response = response,
            .https_reader = reader,
            .https_transfer = transfer,
        };
    }

    /// Unified entry: scheme "https" -> std.http, else raw socket with timeouts.
    pub fn open(
        self: *HttpClient,
        scheme: []const u8,
        host: []const u8,
        port: u16,
        method: []const u8,
        path: []const u8,
        headers: []const Header,
        body: []const u8,
    ) ResponseError!StreamingResponse {
        if (std.ascii.eqlIgnoreCase(scheme, "https")) {
            return self.openHttps(host, port, method, path, headers, body);
        }
        return self.openRaw(host, port, method, path, headers, body);
    }

    fn openRaw(
        self: *HttpClient,
        host: []const u8,
        port: u16,
        method: []const u8,
        path: []const u8,
        headers: []const Header,
        body: []const u8,
    ) ResponseError!StreamingResponse {
        // DNS via Threaded io (short, no timeout concerns); then a raw socket.
        const addr = net.IpAddress.resolve(self.io, host, port) catch return error.ConnectionFailed;
        const fd = libc.socket(@intCast(posix.AF.INET), @intCast(posix.SOCK.STREAM), 0);
        if (fd < 0) return error.ConnectionFailed;
        errdefer _ = libc.close(fd);
        const sa: posix.sockaddr.in = switch (addr) {
            .ip4 => |a| .{
                .port = std.mem.nativeToBig(u16, a.port),
                // sockaddr.in.addr holds the address in network byte order
                // (memory bytes = the dotted quad). On a little-endian host
                // that is bytes[0] | bytes[1]<<8 | ... .
                .addr = std.mem.readInt(u32, &a.bytes, .little),
            },
            .ip6 => return error.ConnectionFailed,
        };
        const rc = libc.connect(fd, &sa, @sizeOf(posix.sockaddr.in));
        if (rc != 0) return error.ConnectionFailed;
        setReadTimeout(fd, self.config.read_timeout_ms);

        var req = std.ArrayList(u8).empty;
        defer req.deinit(self.allocator);
        try req.appendSlice(self.allocator, method);
        try req.appendSlice(self.allocator, " ");
        try req.appendSlice(self.allocator, path);
        try req.appendSlice(self.allocator, " HTTP/1.1\r\nHost: ");
        try req.appendSlice(self.allocator, host);
        if (port != 80) {
            var port_buf: [16]u8 = undefined;
            const port_str = std.fmt.bufPrint(&port_buf, ":{d}", .{port}) catch return error.OutOfMemory;
            try req.appendSlice(self.allocator, port_str);
        }
        try req.appendSlice(self.allocator, "\r\n");
        for (headers) |h| {
            try req.appendSlice(self.allocator, h.name);
            try req.appendSlice(self.allocator, ": ");
            try req.appendSlice(self.allocator, h.value);
            try req.appendSlice(self.allocator, "\r\n");
        }
        try req.appendSlice(self.allocator, "Content-Length: ");
        var len_buf: [32]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}\r\n", .{body.len}) catch return error.OutOfMemory;
        try req.appendSlice(self.allocator, len_str);
        try req.appendSlice(self.allocator, "\r\n");
        try req.appendSlice(self.allocator, body);
        try writeAllRaw(fd, req.items);

        var resp = StreamingResponse{
            .allocator = self.allocator,
            .fd = fd,
            .status = 0,
            .content_length = null,
            .chunked = false,
            .raw = try self.allocator.alloc(u8, 8192),
        };
        errdefer resp.deinit();

        var line = std.ArrayList(u8).empty;
        defer line.deinit(self.allocator);
        const status_line = try resp.readLine(&line) orelse return error.InvalidResponse;
        if (status_line.len < 12 or !std.mem.startsWith(u8, status_line, "HTTP/")) return error.InvalidResponse;
        resp.status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.InvalidResponse;

        var content_length: ?u64 = null;
        var chunked = false;
        while (true) {
            line.clearRetainingCapacity();
            const hdr = try resp.readLine(&line) orelse break;
            if (hdr.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, hdr, ':') orelse continue;
            const name = std.mem.trim(u8, hdr[0..colon], " ");
            const value = std.mem.trim(u8, hdr[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(u64, value, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                if (std.mem.indexOf(u8, value, "chunked") != null or
                    std.mem.indexOf(u8, value, "Chunked") != null) chunked = true;
            }
        }

        resp.content_length = content_length;
        resp.content_remaining = content_length orelse 0;
        resp.chunked = chunked;
        return resp;
    }
};
