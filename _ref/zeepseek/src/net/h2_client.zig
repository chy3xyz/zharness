//! Minimal HTTP/2 client over TLS.
//!
//! Uses the vendored tls_client (std.crypto.tls.Client copy with ALPN support)
//! + raw-io socket layer (bypasses std.Io.Threaded's macOS read bugs) +
//! zigmodu's h2 frame/HPACK primitives.

const std = @import("std");
const posix = std.posix;
const net = std.Io.net;
const tls_mod = @import("vendor/tls_client.zig");
const raw_io = @import("vendor/raw_io.zig");
const h2 = @import("vendor/h2_frames.zig");
extern "c" fn usleep(usec: u32) c_int;
const hpack = @import("vendor/hpack.zig");

pub const H2Error = error{
    Timeout,
    ConnectionFailed,
    TlsFailed,
    H2Protocol,
    HttpStatus,
    OutOfMemory,
};

const libc = struct {
    extern "c" fn socket(domain: i32, socket_type: i32, protocol: i32) i32;
    extern "c" fn connect(fd: i32, addr: *const anyopaque, len: u32) i32;
    extern "c" fn close(fd: i32) i32;
    extern "c" fn getaddrinfo(node: [*:0]const u8, service: [*:0]const u8, hints: *const std.c.addrinfo, res: *?*std.c.addrinfo) i32;
    extern "c" fn freeaddrinfo(res: *std.c.addrinfo) void;
};

pub const H2Response = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    tls: tls_mod,
    raw_reader: *raw_io.RawReader,
    raw_writer: *raw_io.RawWriter,
    socket_read_buf: []u8,
    socket_write_buf: []u8,
    read_buf: []u8,
    write_buf: []u8,
    status: u16 = 0,
    body: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *H2Response) void {
        self.tls.end() catch {};
        self.body.deinit(self.allocator);
        self.allocator.destroy(self.raw_reader);
        self.allocator.destroy(self.raw_writer);
        self.allocator.free(self.socket_read_buf);
        self.allocator.free(self.socket_write_buf);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        _ = libc.close(@intCast(self.fd));
    }
};

/// Streaming sink: called with each DATA frame payload as it arrives.
pub const StreamSink = struct {
    ctx: *anyopaque,
    on_data: *const fn (ctx: *anyopaque, data: []const u8) void,
};

pub const H2Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    read_timeout_ms: u64 = 60_000,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) H2Client {
        return .{ .allocator = allocator, .io = io };
    }

    /// Resolve host (IP literal or getaddrinfo) and open a TCP socket.
    fn connectTcp(self: *H2Client, host: []const u8, port: u16) H2Error!posix.fd_t {
        var sa: posix.sockaddr.in = undefined;
        if (net.IpAddress.parseIp4(host, port)) |addr| {
            const ip4 = addr.ip4;
            sa = .{
                .port = std.mem.nativeToBig(u16, port),
                .addr = std.mem.readInt(u32, &ip4.bytes, .little),
            };
        } else |_| {
            const host_z = try self.allocator.dupeSentinel(u8, host, 0);
            defer self.allocator.free(host_z);
            var port_buf: [8]u8 = undefined;
            const port_str = std.fmt.bufPrintSentinel(&port_buf, "{d}", .{port}, 0) catch return error.ConnectionFailed;
            var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
            hints.family = @intCast(std.c.AF.INET);
            hints.socktype = @intCast(std.c.SOCK.STREAM);
            var res: ?*std.c.addrinfo = null;
            if (libc.getaddrinfo(host_z.ptr, port_str.ptr, &hints, &res) != 0) return error.ConnectionFailed;
            defer libc.freeaddrinfo(res.?);
            const ai = res.?;
            if (ai.addr) |addr_ptr| {
                @memcpy(std.mem.asBytes(&sa), @as([*]const u8, @ptrCast(addr_ptr))[0..@sizeOf(posix.sockaddr.in)]);
            } else return error.ConnectionFailed;
        }

        // Retry the connect a couple of times with backoff: transient network
        // blips are common, and retrying only at the connect stage is safe
        // (once the stream starts we never retry mid-response).
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const fd = libc.socket(@intCast(posix.AF.INET), @intCast(posix.SOCK.STREAM), 0);
            if (fd < 0) return error.ConnectionFailed;
            if (libc.connect(fd, &sa, @sizeOf(posix.sockaddr.in)) == 0) return fd;
            _ = libc.close(fd);
            if (attempt >= 2) return error.ConnectionFailed;
            // ~200ms * 2^attempt backoff (usleep).
            _ = usleep(200_000 * (@as(u32, 1) << @intCast(attempt)));
        }
    }

    fn setReadTimeout(fd: posix.fd_t, timeout_ms: u64) void {
        const sec: i64 = @intCast(timeout_ms / 1000);
        const usec: i32 = @intCast((timeout_ms % 1000) * 1000);
        const tv = posix.timeval{ .sec = sec, .usec = usec };
        posix.setsockopt(fd, posix.SOL.SOCKET, std.c.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        posix.setsockopt(fd, posix.SOL.SOCKET, std.c.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    }

    fn writeTlsPlain(tls: *tls_mod, bytes: []const u8) H2Error!void {
        const w = tls_mod.plaintextWriter(tls);
        w.writeAll(bytes) catch return error.ConnectionFailed;
        w.flush() catch return error.ConnectionFailed;
    }

    fn readExactTls(tls: *tls_mod, buf: []u8) H2Error!void {
        var filled: usize = 0;
        while (filled < buf.len) {
            const n = tls_mod.plaintextReader(tls).readSliceShort(buf[filled..]) catch return error.Timeout;
            if (n == 0) return error.ConnectionFailed;
            filled += n;
        }
    }

    fn readFrame(_: *H2Client, tls: *tls_mod, header_buf: []u8, payload: []u8) H2Error!h2.Frame {
        try readExactTls(tls, header_buf[0..9]);
        const header = h2.FrameHeader.decode(header_buf[0..9]) catch return error.H2Protocol;
        if (header.length > payload.len) return error.H2Protocol;
        if (header.length > 0) {
            try readExactTls(tls, payload[0..header.length]);
        }
        return h2.Frame{ .header = header, .payload = payload[0..header.length] };
    }

    pub fn request(
        self: *H2Client,
        host: []const u8,
        port: u16,
        path: []const u8,
        headers: []const struct { []const u8, []const u8 },
        body: []const u8,
        stream: ?*const StreamSink,
    ) H2Error!H2Response {
        // Writes to a peer that closed the connection must not kill the process.
        const ign = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.PIPE, &ign, null);

        const alloc = self.allocator;

        // 1) DNS + Raw TCP connect
        const fd = try self.connectTcp(host, port);
        errdefer _ = libc.close(fd);
        setReadTimeout(fd, self.read_timeout_ms);

        // 2) TLS (vendored client with ALPN "h2")
        // Buffers/raw IO are owned by the returned H2Response (freed in
        // deinit); on the error path they are released here instead.
        var owned_by_resp = false;
        errdefer { if (!owned_by_resp) _ = libc.close(fd); }
        const socket_read_buf = try alloc.alloc(u8, tls_mod.min_buffer_len);
        errdefer { if (!owned_by_resp) alloc.free(socket_read_buf); }
        const socket_write_buf = try alloc.alloc(u8, tls_mod.min_buffer_len);
        errdefer { if (!owned_by_resp) alloc.free(socket_write_buf); }
        const read_buf = try alloc.alloc(u8, tls_mod.min_buffer_len);
        errdefer { if (!owned_by_resp) alloc.free(read_buf); }
        const write_buf = try alloc.alloc(u8, tls_mod.min_buffer_len);
        errdefer { if (!owned_by_resp) alloc.free(write_buf); }
        const raw_reader = try alloc.create(raw_io.RawReader);
        errdefer { if (!owned_by_resp) alloc.destroy(raw_reader); }
        const raw_writer = try alloc.create(raw_io.RawWriter);
        errdefer { if (!owned_by_resp) alloc.destroy(raw_writer); }
        raw_reader.* = raw_io.RawReader.init(fd, socket_read_buf);
        raw_writer.* = raw_io.RawWriter.init(fd, socket_write_buf);
        var random_buf: [tls_mod.Options.entropy_len]u8 = undefined;
        self.io.random(&random_buf);

        var tls = tls_mod.init(
            &raw_reader.io_reader,
            &raw_writer.io_writer,
            .{
                .host = .{ .explicit = host },
                .ca = .no_verification,
                .write_buffer = write_buf,
                .read_buffer = read_buf,
                .entropy = &random_buf,
                .realtime_now = std.Io.Timestamp.now(self.io, .real),
            },
        ) catch {
            return error.TlsFailed;
        };
        // 3) HTTP/2 preface + SETTINGS
        try writeTlsPlain(&tls, h2.connection_preface);
        const settings_frame = h2.encodeSettings(alloc, false, &.{}) catch return error.OutOfMemory;
        defer alloc.free(settings_frame);
        try writeTlsPlain(&tls, settings_frame);

        // Read a few frames: server SETTINGS (+ maybe ACK)
        var header_buf: [9]u8 = undefined;
        var payload_buf: [16384]u8 = undefined;
        var got_settings = false;
        var frames_read: usize = 0;
        while (frames_read < 4 and !got_settings) : (frames_read += 1) {
            const frame = self.readFrame(&tls, &header_buf, &payload_buf) catch {
                return error.H2Protocol;
            };
            if (frame.header.typ == .settings) {
                if ((frame.header.flags & h2.FrameFlags.ack) == 0) {
                    got_settings = true;
                    // Send SETTINGS ACK
                    const ack = h2.encodeSettings(alloc, true, &.{}) catch return error.OutOfMemory;
                    defer alloc.free(ack);
                    try writeTlsPlain(&tls, ack);
                }
            }
        }

        // 4) HEADERS + DATA
        var hdr_list = std.ArrayList(hpack.Header).empty;
        defer hdr_list.deinit(alloc);
        const hdr_entries = [_]struct { []const u8, []const u8 }{
            .{ ":method", "POST" },
            .{ ":path", path },
            .{ ":scheme", "https" },
            .{ ":authority", host },
        };
        for (hdr_entries) |e| {
            try hdr_list.append(alloc, .{ .name = e[0], .value = e[1] });
        }
        for (headers) |e| {
            try hdr_list.append(alloc, .{ .name = e[0], .value = e[1] });
        }
        var encoder = hpack.Encoder.init(alloc);
        const block = encoder.encodeLiterals(hdr_list.items) catch return error.OutOfMemory;
        defer alloc.free(block);
        var headers_flags = h2.FrameFlags.end_headers;
        if (body.len == 0) headers_flags |= h2.FrameFlags.end_stream;
        const headers_frame = h2.encodeFrame(alloc, .headers, headers_flags, 1, block) catch return error.OutOfMemory;
        defer alloc.free(headers_frame);
        try writeTlsPlain(&tls, headers_frame);

        if (body.len > 0) {
            const data_frame = h2.encodeData(alloc, 1, body, true) catch return error.OutOfMemory;
            defer alloc.free(data_frame);
            try writeTlsPlain(&tls, data_frame);
        }

        // 5) Read response frames until END_STREAM
        var response = H2Response{
            .allocator = alloc,
            .fd = fd,
            .tls = tls,
            .raw_reader = raw_reader,
            .raw_writer = raw_writer,
            .socket_read_buf = socket_read_buf,
            .socket_write_buf = socket_write_buf,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .body = .empty,
        };
        owned_by_resp = true;
        errdefer response.deinit();

        var end_stream = false;
        var header_block = std.ArrayList(u8).empty;
        defer header_block.deinit(alloc);
        var hpack_dec = hpack.Decoder.init(alloc);
        defer hpack_dec.deinit();

        while (!end_stream) {
            const frame = self.readFrame(&tls, &header_buf, &payload_buf) catch {
                return error.H2Protocol;
            };
            switch (frame.header.typ) {
                .headers => {
                    if (frame.header.length > 0) {
                        try header_block.appendSlice(alloc, frame.payload);
                    }
                    if ((frame.header.flags & h2.FrameFlags.end_headers) != 0) {
                        const decoded = hpack_dec.decode(header_block.items) catch return error.H2Protocol;
                        defer hpack.freeHeaders(alloc, decoded);
                        for (decoded) |hdr| {
                            if (std.mem.eql(u8, hdr.name, ":status")) {
                                response.status = std.fmt.parseInt(u16, hdr.value, 10) catch 0;
                            }
                        }
                        header_block.clearRetainingCapacity();
                    }
                    if ((frame.header.flags & h2.FrameFlags.end_stream) != 0) end_stream = true;
                },
                .data => {
                    if (stream) |sink| {
                        sink.on_data(sink.ctx, frame.payload);
                    }
                    try response.body.appendSlice(alloc, frame.payload);
                    if ((frame.header.flags & h2.FrameFlags.end_stream) != 0) end_stream = true;
                },
                else => {},
            }
        }

        return response;
    }
};
