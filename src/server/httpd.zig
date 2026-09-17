//! Minimal HTTP/1.1 server on raw POSIX sockets (dev.md §XXIII).
//!
//! Contract:
//! - Bind/listen on an address (127.0.0.1 by default), blocking accept loop,
//!   one request per connection (`Connection: close` semantics only — no
//!   keep-alive, no pipelining, no chunked bodies).
//! - Request line + headers + `Content-Length` body are parsed by the pure
//!   `parseRequest`; responses are produced by the pure `formatResponse`.
//!   Both are unit-testable without sockets.
//! - Handlers are function pointers receiving a parsed `Request` and a
//!   `Responder` that owns the only socket-writing surface (including SSE).
//! - Graceful stop: `stop()` flips an atomic flag; the accept loop parks in
//!   `poll()` with a bounded timeout (`accept_tick_ms`), re-checks the flag
//!   at most one tick later, and exits cleanly. No signal handling required.
//!
//! Why not std.http.Server / std.Io.net: both are mid-churn in Zig 0.17-dev;
//! the libc socket calls below are stable ABI and mirror the clib.zig extern
//! pattern already used for popen/mkstemp. SIGPIPE is neutralized via
//! SO_NOSIGPIPE (Darwin) or MSG_NOSIGNAL (Linux) so a client hanging up never
//! kills the process.

const std = @import("std");
const builtin = @import("builtin");

// ── libc socket shims (see module doc; do NOT edit clib.zig) ───────────────

extern fn socket(domain: c_int, ty: c_int, protocol: c_int) c_int;
extern fn bind(fd: c_int, addr: *const std.c.sockaddr, len: std.c.socklen_t) c_int;
extern fn listen(fd: c_int, backlog: c_int) c_int;
extern fn accept(fd: c_int, addr: ?*std.c.sockaddr, len: ?*std.c.socklen_t) c_int;
extern fn getsockname(fd: c_int, addr: *std.c.sockaddr, len: *std.c.socklen_t) c_int;
extern fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: std.c.socklen_t) c_int;
extern fn recv(fd: c_int, buf: [*]u8, n: usize, flags: c_int) isize;
extern "c" fn shutdown(fd: c_int, how: c_int) c_int;

/// libc send(2). Declared via `@extern` with the real C symbol name because a
/// plain `extern fn send` would ambiguously shadow `Responder.send` inside
/// that struct's methods.
const libc_send: *const fn (fd: c_int, buf: [*]const u8, n: usize, flags: c_int) callconv(.c) isize =
    @extern(*const fn (fd: c_int, buf: [*]const u8, n: usize, flags: c_int) callconv(.c) isize, .{ .name = "send" });

/// Sleep without an `Io` handle (std.Thread.sleep was removed in 0.17).
extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

fn sleepMs(ms: u64) void {
    const req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&req, null);
}

/// MSG_NOSIGNAL exists on Linux; Darwin uses SO_NOSIGPIPE at socket setup.
const send_flags: c_int = if (@hasDecl(std.c.MSG, "NOSIGNAL")) std.c.MSG.NOSIGNAL else 0;

// ── limits ──────────────────────────────────────────────────────────────────

/// Cap on the request head (request line + headers). Oversized heads get 413.
pub const MaxHeadBytes: usize = 16 * 1024;
/// Cap on request bodies. Oversized bodies get 413.
pub const MaxBodyBytes: usize = 4 * 1024 * 1024;
/// Maximum number of header lines parsed per request.
pub const MaxHeaders: usize = 32;
/// How often the blocked accept() wakes to check the stop flag.
pub const accept_tick_ms: u32 = 200;
/// Per-connection receive timeout (dead clients cannot wedge the loop).
pub const conn_timeout_secs: u32 = 10;

// ── status + content types ──────────────────────────────────────────────────

pub const Status = enum(u16) {
    ok = 200,
    created = 201,
    no_content = 204,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    /// 409 Conflict — added additively in wave 5 for session-rename/create
    /// id collisions (api.zig); no existing mapping changed.
    conflict = 409,
    payload_too_large = 413,
    /// 415 Unsupported Media Type — added additively in wave 5 for the
    /// apiproxy cross-site write fence (non-JSON POSTs to /api/*); no
    /// existing mapping changed.
    unsupported_media_type = 415,
    internal_server_error = 500,
    not_implemented = 501,
    service_unavailable = 503,

    pub fn code(self: Status) u16 {
        return @backingInt(self);
    }

    pub fn reason(self: Status) []const u8 {
        return switch (self) {
            .ok => "OK",
            .created => "Created",
            .no_content => "No Content",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .conflict => "Conflict",
            .payload_too_large => "Payload Too Large",
            .unsupported_media_type => "Unsupported Media Type",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .service_unavailable => "Service Unavailable",
        };
    }
};

pub const ContentType = enum {
    json,
    text,
    html,
    event_stream,

    pub fn asStr(self: ContentType) []const u8 {
        return switch (self) {
            .json => "application/json",
            .text => "text/plain; charset=utf-8",
            .html => "text/html; charset=utf-8",
            .event_stream => "text/event-stream",
        };
    }
};

// ── requests ────────────────────────────────────────────────────────────────

pub const Header = struct {
    name: []u8,
    value: []u8,
};

pub const ParseError = error{
    BadRequest,
    HeadTooLarge,
    BodyTooLarge,
    /// Transfer-Encoding requested; only identity/Content-Length framing is
    /// supported (see module doc).
    NotImplementedTransfer,
    OutOfMemory,
};

/// A fully-parsed HTTP request. All slices are allocated with the parser's
/// allocator (typically a per-connection arena); release everything at once
/// with `deinit` when NOT arena-backed.
pub const Request = struct {
    method: []u8,
    /// Raw request target as received (path + optional "?query").
    target: []u8,
    /// Path portion of the target (before '?', undecoded).
    path: []u8,
    /// Query portion of the target ("", or after '?' undecoded).
    query: []u8,
    version: []u8,
    headers: []Header,
    body: []u8,

    /// Case-insensitive single-header lookup (first match wins).
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// True for GET/HEAD-style requests that carry no body.
    pub fn isGetLike(self: *const Request) bool {
        return std.mem.eql(u8, self.method, "GET") or std.mem.eql(u8, self.method, "HEAD");
    }

    /// Free everything (only needed when parsed with a non-arena allocator).
    pub fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        alloc.free(self.method);
        alloc.free(self.target);
        alloc.free(self.path);
        alloc.free(self.query);
        alloc.free(self.version);
        for (self.headers) |h| {
            alloc.free(h.name);
            alloc.free(h.value);
        }
        alloc.free(self.headers);
        alloc.free(self.body);
    }
};

/// Parse a complete raw HTTP request (head CRLFCRLF + body). Pure: no I/O.
/// The result owns copies of all slices; caller applies `deinit` unless the
/// allocation came from an arena.
/// Bytes of body still expected after `head_end`, from the Content-Length
/// header (0 when absent — bodyless GET/HEAD). Case-insensitive scan over
/// the raw header block ending at `head_end`.
fn bodyBytesPending(raw: []const u8, head_end: usize) usize {
    var it = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "content-length")) continue;
        const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, v, 10) catch 0;
    }
    return 0;
}

pub fn parseRequest(alloc: std.mem.Allocator, raw: []const u8) ParseError!Request {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadRequest;
    const head = raw[0..sep];
    const rest = raw[sep + 4 ..];

    // Request line: METHOD SP TARGET SP VERSION
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const req_line = lines.next() orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, req_line, ' ');
    const method_raw = parts.next() orelse return error.BadRequest;
    const target_raw = parts.next() orelse return error.BadRequest;
    const version_raw = parts.next() orelse return error.BadRequest;
    if (parts.next() != null) return error.BadRequest;
    if (method_raw.len == 0 or target_raw.len == 0) return error.BadRequest;
    if (!std.mem.startsWith(u8, version_raw, "HTTP/")) return error.BadRequest;

    // Headers (bounded count; values keep inner spacing, trimmed edges).
    var headers: std.ArrayList(Header) = .empty;
    errdefer {
        for (headers.items) |h| {
            alloc.free(h.name);
            alloc.free(h.value);
        }
        headers.deinit(alloc);
    }
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (headers.items.len >= MaxHeaders) return error.HeadTooLarge;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        if (colon == 0) return error.BadRequest;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        try headers.append(alloc, .{
            .name = try alloc.dupe(u8, name),
            .value = try alloc.dupe(u8, value),
        });
    }

    // Content-Length body. Transfer-Encoding is refused outright: this server
    // implements identity framing only.
    var content_length: usize = 0;
    for (headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) return error.NotImplementedTransfer;
        if (std.ascii.eqlIgnoreCase(h.name, "content-length")) {
            content_length = std.fmt.parseInt(usize, h.value, 10) catch return error.BadRequest;
        }
    }
    if (content_length > MaxBodyBytes) return error.BodyTooLarge;
    // A truncated read is a transport problem, not a parse problem: callers
    // (serveConnection) only call us once the head arrived, so a short body
    // means the peer hung up mid-request. Report it as BadRequest.
    if (rest.len < content_length) return error.BadRequest;

    // Split target into path + query.
    const qmark = std.mem.indexOfScalar(u8, target_raw, '?');
    const path_raw = if (qmark) |q| target_raw[0..q] else target_raw;
    const query_raw = if (qmark) |q| target_raw[q + 1 ..] else "";

    return .{
        .method = try alloc.dupe(u8, method_raw),
        .target = try alloc.dupe(u8, target_raw),
        .path = try alloc.dupe(u8, path_raw),
        .query = try alloc.dupe(u8, query_raw),
        .version = try alloc.dupe(u8, version_raw),
        .headers = try headers.toOwnedSlice(alloc),
        .body = try alloc.dupe(u8, rest[0..content_length]),
    };
}

/// Percent-decode a URL component (%XX; '+' is left alone — it is only a
/// space in form encoding, which we deliberately do not apply here).
pub fn percentDecode(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try out.append(alloc, input[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try out.append(alloc, input[i]);
                continue;
            };
            try out.append(alloc, hi * 16 + lo);
            i += 2;
            continue;
        }
        try out.append(alloc, input[i]);
    }
    return out.toOwnedSlice(alloc);
}

// ── responses ───────────────────────────────────────────────────────────────

/// Serialize a full HTTP/1.1 response. Pure; used both by the connection
/// writer and directly by tests. Always emits `Connection: close` plus an
/// accurate Content-Length.
pub fn formatResponse(
    alloc: std.mem.Allocator,
    status: Status,
    content_type: ContentType,
    body: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.print(alloc, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
        status.code(),
        status.reason(),
        content_type.asStr(),
        body.len,
    });
    try out.appendSlice(alloc, body);
    return out.toOwnedSlice(alloc);
}

// ── handler surface ─────────────────────────────────────────────────────────

/// A handler receives the parsed request plus a responder bound to the live
/// connection. `alloc` is a per-connection arena: allocations made with it are
/// released wholesale when the connection ends; handlers must NOT free them.
pub const HandlerFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    req: *const Request,
    res: *Responder,
) anyerror!void;

pub const Handler = struct {
    ctx: ?*anyopaque = null,
    call: HandlerFn,
};

/// Write-only view over one accepted connection. Handlers emit exactly one
/// response via `send*`, OR take the SSE path via `startEventStream`. Nothing
/// here frees memory (the connection arena owns everything).
pub const Responder = struct {
    fd: std.posix.socket_t,
    alloc: std.mem.Allocator,
    /// Set when a write fails (peer gone); handlers can check to abort early.
    failed: bool = false,
    /// Set once any bytes were written; guards double-response bugs.
    responded: bool = false,

    /// Send a buffered response with one of the well-known content types.
    pub fn send(self: *Responder, status: Status, ct: ContentType, body: []const u8) !void {
        std.debug.assert(!self.responded);
        self.responded = true;
        const raw = try formatResponse(self.alloc, status, ct, body);
        try self.writeAll(raw);
    }

    /// Send a buffered response with a custom Content-Type string.
    pub fn sendRawType(self: *Responder, status: Status, content_type: []const u8, body: []const u8) !void {
        std.debug.assert(!self.responded);
        self.responded = true;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        try out.print(self.alloc, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
            status.code(), status.reason(), content_type, body.len,
        });
        try out.appendSlice(self.alloc, body);
        try self.writeAll(out.items);
    }

    /// Switch the connection into SSE mode. Returns a streaming writer; after
    /// this call no regular `send*` may be used.
    pub fn startEventStream(self: *Responder) !EventStream {
        std.debug.assert(!self.responded);
        self.responded = true;
        const head =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: close\r\n" ++
            "\r\n";
        try self.writeAll(head);
        return .{ .fd = self.fd, .responder = self };
    }

    /// Switch the connection into WebSocket mode (wave-5 apiproxy addition).
    /// Writes the RFC 6455 101 handshake computed from the validated upgrade
    /// request, then returns a frame-level connection. After this call no
    /// regular `send*` may be used; see the WebSocket section's threading
    /// contract for ownership rules.
    pub fn startWebSocket(self: *Responder, upgrade: *const WsUpgrade) StartWsResult {
        std.debug.assert(!self.responded);
        const resp = upgrade.formatResponse(self.alloc) catch return error.OutOfMemory;
        defer self.alloc.free(resp);
        self.responded = true;
        self.writeAll(resp) catch {
            self.failed = true;
            return error.HandshakeWriteFailed;
        };
        return WsConn.init(self.fd, self.alloc);
    }

    fn writeAll(self: *Responder, data: []const u8) !void {
        var off: usize = 0;
        while (off < data.len) {
            const n = libc_send(self.fd, data.ptr + off, data.len - off, send_flags);
            if (n <= 0) {
                self.failed = true;
                return error.WriteFailed;
            }
            off += @intCast(n);
        }
    }
};

/// Streaming writer for `text/event-stream` connections (SSE). Frames follow
/// the WHATWG wire format: comments (`:` prefix) double as heartbeats.
pub const EventStream = struct {
    fd: std.posix.socket_t,
    responder: *Responder,

    /// Emit an SSE comment line (": <text>") — the heartbeat idiom.
    pub fn comment(self: *EventStream, text: []const u8) !void {
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.responder.alloc);
        try frame.appendSlice(self.responder.alloc, ": ");
        try frame.appendSlice(self.responder.alloc, text);
        try frame.appendSlice(self.responder.alloc, "\n\n");
        try self.writeFrame(frame.items);
    }

    /// Emit a named event whose data is one JSON document (or plain text).
    pub fn event(self: *EventStream, name: []const u8, data: []const u8) !void {
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.responder.alloc);
        try frame.appendSlice(self.responder.alloc, "event: ");
        try frame.appendSlice(self.responder.alloc, name);
        try frame.appendSlice(self.responder.alloc, "\ndata: ");
        try frame.appendSlice(self.responder.alloc, data);
        try frame.appendSlice(self.responder.alloc, "\n\n");
        try self.writeFrame(frame.items);
    }

    /// Sleep in small ticks so callers can poll `peerGone()` between beats.
    pub fn sleepTicks(self: *EventStream, total_ms: u64, tick_ms: u64) void {
        _ = self;
        var remaining: u64 = total_ms;
        while (remaining > 0) {
            const step = @min(remaining, tick_ms);
            sleepMs(step);
            remaining -= step;
        }
    }

    /// True once a write has failed (client disconnected / reset).
    pub fn peerGone(self: *const EventStream) bool {
        return self.responder.failed;
    }

    fn writeFrame(self: *EventStream, frame: []const u8) !void {
        var off: usize = 0;
        while (off < frame.len) {
            const n = libc_send(self.fd, frame.ptr + off, frame.len - off, send_flags);
            if (n <= 0) {
                self.responder.failed = true;
                return error.WriteFailed;
            }
            off += @intCast(n);
        }
    }
};

// ── server ──────────────────────────────────────────────────────────────────

pub const ServerError = error{
    SocketFailed,
    BindFailed,
    ListenFailed,
};

pub const Options = struct {
    /// Port to bind; 0 lets the kernel pick an ephemeral port (use
    /// `boundPort()` to discover it).
    port: u16 = 8080,
    /// Serve each connection on its own detached thread instead of the accept
    /// thread. Required for long-lived SSE streams not to starve other routes.
    threaded_connections: bool = false,
};

/// Blocking TCP HTTP/1.1 server. Create with `init`, then either call
/// `serveBlocking` on the current thread or `spawn` + later `stop`/`join`.
pub const Server = struct {
    alloc: std.mem.Allocator,
    handler: Handler,
    options: Options,
    listen_fd: std.posix.socket_t = -1,
    port_requested: u16 = 0,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// Bind + listen. Does not accept yet.
    pub fn init(alloc: std.mem.Allocator, handler: Handler, options: Options) ServerError!Server {
        const fd = socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;

        // SO_REUSEADDR so restarts after crash don't fight TIME_WAIT.
        const one: c_int = 1;
        _ = setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &one, @sizeOf(c_int));
        // Darwin lacks MSG_NOSIGNAL; suppress SIGPIPE per-socket instead.
        if (builtin.os.tag.isDarwin()) {
            _ = setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
        }

        const addr = std.c.sockaddr.in{
            .family = std.c.AF.INET,
            .port = std.mem.nativeToBig(u16, options.port),
            .addr = std.mem.nativeToBig(u32, 0x7f00_0001), // 127.0.0.1
        };
        if (bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) {
            _ = std.c.close(fd);
            return error.BindFailed;
        }
        if (listen(fd, 64) != 0) {
            _ = std.c.close(fd);
            return error.ListenFailed;
        }

        return .{
            .alloc = alloc,
            .handler = handler,
            .options = options,
            .listen_fd = fd,
            .port_requested = options.port,
        };
    }

    /// Actual bound port (differs from `options.port` when 0 was requested).
    pub fn boundPort(self: *const Server) u16 {
        var addr: std.c.sockaddr.in = undefined;
        var addr_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        if (getsockname(self.listen_fd, @ptrCast(&addr), &addr_len) != 0) return 0;
        return std.mem.bigToNative(u16, addr.port);
    }

    /// Run the accept loop on the calling thread until `stop()`.
    ///
    /// Stop mechanism: the loop parks in `poll()` with a bounded timeout
    /// (`accept_tick_ms`), then re-checks the flag — portable across macOS
    /// and Linux (macOS accept() ignores SO_RCVTIMEO, so a receive-timeout
    /// wake does NOT work there; poll's own timeout always does).
    pub fn serveBlocking(self: *Server) void {
        while (!self.stopping.load(.acquire)) {
            var pfd = [1]std.c.pollfd{.{
                .fd = self.listen_fd,
                .events = std.c.POLL.IN,
                .revents = 0,
            }};
            const ready = std.c.poll(&pfd, 1, @intCast(accept_tick_ms));
            if (self.stopping.load(.acquire)) break;
            if (ready <= 0) continue; // tick timeout (or poll error): retry
            if ((pfd[0].revents & std.c.POLL.IN) == 0) continue;

            const conn_fd = accept(self.listen_fd, null, null);
            if (conn_fd < 0) continue; // spurious wakeup / aborted conn
            configureConnSocket(conn_fd);
            if (self.options.threaded_connections) {
                const t = std.Thread.spawn(.{}, connectionThreadMain, .{ self, conn_fd }) catch {
                    _ = std.c.close(conn_fd);
                    continue;
                };
                t.detach();
            } else {
                self.handleConnectionFd(conn_fd);
            }
        }
    }

    /// Start the accept loop on a background thread.
    pub fn spawn(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, serverThreadMain, .{self});
    }

    /// Graceful stop: flip the flag; the accept loop notices within
    /// `accept_tick_ms`. Idempotent.
    pub fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        // Best-effort unblock; harmless where unsupported (e.g. Darwin listen
        // sockets simply return ENOTCONN).
        _ = shutdown(self.listen_fd, 2); // SHUT_RDWR
    }

    /// Join the background accept thread (if spawned).
    pub fn join(self: *Server) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Close the listening socket. Only after the loop has exited.
    pub fn deinit(self: *Server) void {
        if (self.listen_fd >= 0) {
            _ = std.c.close(self.listen_fd);
            self.listen_fd = -1;
        }
    }

    fn serverThreadMain(self: *Server) void {
        self.serveBlocking();
    }

    fn connectionThreadMain(self: *Server, conn_fd: std.posix.socket_t) void {
        self.handleConnectionFd(conn_fd);
    }

    /// One request per connection: read head+body, dispatch, write, close.
    /// All per-request memory lives in a local arena freed on exit.
    fn handleConnectionFd(self: *Server, conn_fd: std.posix.socket_t) void {
        defer _ = std.c.close(conn_fd);

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Read until end of head (or caps).
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        var chunk: [4096]u8 = undefined;
        var timeouts: u32 = 0;
        var res = Responder{ .fd = conn_fd, .alloc = alloc };

        while (true) {
            if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |head_end| {
                // Head complete: keep reading until the full Content-Length
                // body has arrived. The head and a large body frequently land
                // in separate TCP segments — parsing here would report a
                // spurious 400 on every multi-segment request.
                const need = bodyBytesPending(buf.items, head_end + 4);
                if (need == 0) break;
                if (buf.items.len >= head_end + 4 + need) break;
                if (head_end + 4 + need > MaxBodyBytes) {
                    failEarly(&res, .payload_too_large, "body too large") catch {};
                    return;
                }
            } else if (buf.items.len > MaxHeadBytes) {
                failEarly(&res, .payload_too_large, "head too large") catch {};
                return;
            }
            const n = recv(conn_fd, &chunk, chunk.len, 0);
            if (n < 0) {
                const err = std.c.errno(n);
                if (err == .AGAIN or err == .INTR) {
                    timeouts += 1;
                    if (timeouts >= 3) return; // dead client
                    continue;
                }
                return; // hard read error
            }
            if (n == 0) {
                // Peer closed. Empty buffer → benign probe (e.g. port scan);
                // partial request → fall through so parseRequest answers 400.
                if (buf.items.len == 0) return;
                break;
            }
            timeouts = 0;
            buf.appendSlice(alloc, chunk[0..@intCast(n)]) catch return;
        }

        // If the peer closed early the head may be truncated: answer 400.
        var req = parseRequest(alloc, buf.items) catch |e| switch (e) {
            error.HeadTooLarge => {
                failEarly(&res, .payload_too_large, "head too large") catch {};
                return;
            },
            error.BodyTooLarge => {
                failEarly(&res, .payload_too_large, "body too large") catch {};
                return;
            },
            else => {
                failEarly(&res, .bad_request, "malformed request") catch {};
                return;
            },
        };
        defer req.deinit(alloc);

        self.handler.call(self.handler.ctx, alloc, &req, &res) catch |e| {
            // Handler failed before responding: best-effort 500.
            if (!res.responded) {
                var msg_buf: [128]u8 = undefined;
                const body = std.fmt.bufPrint(&msg_buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}) catch "{\"ok\":false}";
                failEarly(&res, .internal_server_error, body) catch {};
            }
        };
    }
};

/// Respond from the server layer itself (parse errors etc.). Safe even when
/// nothing was ever written.
fn failEarly(res: *Responder, status: Status, body: []const u8) !void {
    if (res.responded) return;
    try res.send(status, .json, body);
}

fn configureConnSocket(fd: std.posix.socket_t) void {
    // Per-connection receive timeout so half-open clients cannot stall a
    // sequential accept loop forever.
    const tv: std.c.timeval = .{ .sec = @intCast(conn_timeout_secs), .usec = 0 };
    _ = setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &tv, @sizeOf(std.c.timeval));
    if (builtin.os.tag.isDarwin()) {
        const one: c_int = 1;
        _ = setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
    }
}

// ── WebSocket transport (RFC 6455) — wave-5 apiproxy addition ──────────────
//
// ADDITIVE layer over the one-request-per-connection server above: existing
// routes, `parseRequest`, `formatResponse`, and SSE behavior are untouched.
// A handler that recognizes a WebSocket upgrade request calls
// `Responder.startWebSocket`, which writes the 101 handshake and hands back
// a `WsConn` bound to the live fd.
//
// Threading contract (mirrors the SSE streams):
// - An upgraded connection occupies its thread until the stream ends, so
//   servers hosting WS streams MUST run with
//   `Options.threaded_connections = true`; otherwise one open socket
//   starves every other route (same rule as server/events.zig).
// - `handleConnectionFd` closes the fd when the handler returns, so the
//   pump loop runs INSIDE the handler call, exactly like SSE loops.
// - `WsConn.init` disables SO_RCVTIMEO on the fd: long-lived idle sockets
//   must not trip the 10 s per-request timeout. Liveness relies on loopback
//   TCP teardown (the server binds 127.0.0.1; peer death always produces
//   FIN/RST there) plus write-failure detection on push. No application-
//   level heartbeat is implemented; the browser carrier's reconnect
//   machine owns stale-socket recovery.
// - Fan-out from publisher threads is safe: every write path takes the
//   per-connection `wlock`, so a header+payload pair is never interleaved.

/// The RFC 6455 §1.3 handshake GUID (fixed by the protocol, not tunable).
pub const ws_magic_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Reassembled-message cap (~1 MiB): an inbound text/binary message whose
/// fragments sum beyond this fails the connection with close code 1009.
pub const ws_max_message_bytes: usize = 1024 * 1024;

pub const WsOpcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,

    pub fn toByte(self: WsOpcode) u8 {
        return @backingInt(self);
    }

    /// Strict decode: reserved/unknown opcodes are protocol errors.
    pub fn fromByte(raw: u8) ?WsOpcode {
        return switch (raw) {
            0 => .continuation,
            1 => .text,
            2 => .binary,
            8 => .close,
            9 => .ping,
            10 => .pong,
            else => null,
        };
    }
};

pub const WsError = error{
    /// Inbound framing violated RFC 6455 (bad opcode, unmasked client frame,
    /// fragmented control frame, oversized control payload, RSV bits set).
    ProtocolError,
    /// Reassembled message exceeded `ws_max_message_bytes`.
    MessageTooLarge,
    WriteFailed,
    ReadFailed,
    /// Peer closed (clean close handshake completed or EOF mid-stream).
    ConnectionClosed,
    OutOfMemory,
};

/// Sec-WebSocket-Accept = base64(SHA-1(client_key ++ magic GUID)).
/// Verified against the RFC 6455 §1.3 example vector in the tests below.
pub fn computeWsAcceptKey(alloc: std.mem.Allocator, client_key: []const u8) ![]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(client_key);
    sha.update(ws_magic_guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    const enc = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(digest.len));
    errdefer alloc.free(out);
    _ = enc.encode(out, &digest);
    return out;
}

// ── frame codec (pure halves are unit-testable without sockets) ────────────

pub const WsFrameHeader = struct {
    fin: bool,
    opcode: WsOpcode,
    masked: bool,
    payload_len: u64,
    /// Total header bytes INCLUDING the 4-byte masking key when masked.
    header_len: usize,
};

pub const FrameParseError = error{ NeedMoreData, ProtocolError };

/// Parse a frame header from the front of `buf`. `NeedMoreData` means more
/// bytes are required; `ProtocolError` means the header violates the RFC
/// (RSV bits set without extension negotiation is checked by the caller —
/// this pure function does not know negotiation state — plus non-minimal
/// extended lengths and reserved opcodes).
pub fn parseWsFrameHeader(buf: []const u8) FrameParseError!WsFrameHeader {
    if (buf.len < 2) return error.NeedMoreData;
    const b0 = buf[0];
    const b1 = buf[1];
    if (b0 & 0x70 != 0) return error.ProtocolError; // RSV bits: no extensions
    const opcode_raw: u8 = b0 & 0x0F;
    const opcode = WsOpcode.fromByte(opcode_raw) orelse return error.ProtocolError;
    const masked = b1 & 0x80 != 0;

    var payload_len: u64 = b1 & 0x7F;
    var header_len: usize = 2;
    if (payload_len == 126) {
        if (buf.len < 4) return error.NeedMoreData;
        payload_len = std.mem.readInt(u16, buf[2..4], .big);
        header_len = 4;
        if (payload_len < 126) return error.ProtocolError; // non-minimal
    } else if (payload_len == 127) {
        if (buf.len < 10) return error.NeedMoreData;
        payload_len = std.mem.readInt(u64, buf[2..10], .big);
        header_len = 10;
        if (payload_len <= 0xFFFF) return error.ProtocolError; // non-minimal
    }
    if (masked) header_len += 4;
    if (buf.len < header_len) return error.NeedMoreData;
    return .{
        .fin = b0 & 0x80 != 0,
        .opcode = opcode,
        .masked = masked,
        .payload_len = payload_len,
        .header_len = header_len,
    };
}

/// Serialize one frame. Server-to-client frames are UNMASKED (`mask_key ==
/// null`); test doubles playing the client pass a key to exercise the XOR
/// path. Pure: returns freshly allocated bytes.
pub fn encodeWsFrame(
    alloc: std.mem.Allocator,
    opcode: WsOpcode,
    fin: bool,
    payload: []const u8,
    mask_key: ?[4]u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, payload.len + 14);

    const b0: u8 = (if (fin) @as(u8, 0x80) else 0) | opcode.toByte();
    try out.append(alloc, b0);
    if (mask_key) |_| {
        try out.append(alloc, 0x80 | encodeLenBits(payload.len));
    } else {
        try out.append(alloc, encodeLenBits(payload.len));
    }
    switch (encodeExtendedLen(payload.len)) {
        .none => {},
        .u16 => |v| {
            var ext: [2]u8 = undefined;
            std.mem.writeInt(u16, &ext, v, .big);
            try out.appendSlice(alloc, &ext);
        },
        .u64 => |v| {
            var ext: [8]u8 = undefined;
            std.mem.writeInt(u64, &ext, v, .big);
            try out.appendSlice(alloc, &ext);
        },
    }
    if (mask_key) |key| {
        try out.appendSlice(alloc, &key);
        try out.ensureTotalCapacity(alloc, out.items.len + payload.len);
        const start = out.items.len;
        try out.appendSlice(alloc, payload);
        applyMask(out.items[start..], key);
    } else {
        try out.appendSlice(alloc, payload);
    }
    return out.toOwnedSlice(alloc);
}

const LenExt = union(enum) { none, u16: u16, u64: u64 };

fn encodeExtendedLen(len: usize) LenExt {
    if (len < 126) return .none;
    if (len <= 0xFFFF) return .{ .u16 = @intCast(len) };
    return .{ .u64 = len };
}

fn encodeLenBits(len: usize) u8 {
    return switch (encodeExtendedLen(len)) {
        .none => @intCast(len),
        .u16 => 126,
        .u64 => 127,
    };
}

/// RFC 6455 §5.3 XOR obfuscation, in place, rotating the 4-byte key.
pub fn applyMask(payload: []u8, key: [4]u8) void {
    for (payload, 0..) |*b, i| {
        b.* ^= key[i % 4];
    }
}

// ── opening handshake ───────────────────────────────────────────────────────

pub const WsUpgradeError = error{
    NotWebSocket,
    MissingKey,
    BadVersion,
    OutOfMemory,
};

/// Validated opening-handshake request (RFC 6455 §4.2.1). Borrows slices
/// from the parsed request; valid as long as the request memory.
pub const WsUpgrade = struct {
    key: []const u8,

    /// Validate a GET request's upgrade headers. Header token lists
    /// ("Connection: keep-alive, Upgrade") are split on ',' and matched
    /// case-insensitively, per the RFC.
    pub fn fromRequest(req: *const Request) WsUpgradeError!WsUpgrade {
        if (!std.mem.eql(u8, req.method, "GET")) return error.NotWebSocket;

        const upg = req.header("upgrade") orelse return error.NotWebSocket;
        if (!tokenListContains(upg, "websocket")) return error.NotWebSocket;

        const conn = req.header("connection") orelse return error.NotWebSocket;
        if (!tokenListContains(conn, "upgrade")) return error.NotWebSocket;

        const key = req.header("sec-websocket-key") orelse return error.MissingKey;
        // A valid key is base64 of 16 random bytes (24 chars unpadded).
        const dec = std.base64.standard.Decoder;
        const decoded_len = dec.calcSizeForSlice(key) catch return error.MissingKey;
        if (decoded_len != 16) return error.MissingKey;

        const ver = req.header("sec-websocket-version") orelse return error.BadVersion;
        if (!std.mem.eql(u8, std.mem.trim(u8, ver, " \t"), "13")) return error.BadVersion;

        return .{ .key = key };
    }

    /// The exact 101 response bytes (pure; testable without sockets).
    pub fn formatResponse(self: *const WsUpgrade, alloc: std.mem.Allocator) ![]u8 {
        const ws_accept = try computeWsAcceptKey(alloc, self.key);
        defer alloc.free(ws_accept);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: ");
        try out.appendSlice(alloc, ws_accept);
        try out.appendSlice(alloc, "\r\n\r\n");
        return out.toOwnedSlice(alloc);
    }
};

/// Case-insensitive token membership in a comma-separated header value.
fn tokenListContains(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(t, token)) return true;
    }
    return false;
}

// ── per-connection lock (same design as server/events.zig's private copy) ──
// (nanosleep extern shared with the module-level decl above)

const WsSpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *WsSpinLock) void {
        var spins: u32 = 0;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins >= 16) {
                const req: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                _ = nanosleep(&req, null);
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    fn unlock(self: *WsSpinLock) void {
        self.locked.store(false, .release);
    }
};

/// Switch an accepted connection into WebSocket mode. Writes the 101
/// handshake, then returns a `WsConn` owning the socket for frame traffic.
/// After this call no regular `send*` may be used.
pub const StartWsError = error{
    HandshakeWriteFailed,
    SocketSetupFailed,
    OutOfMemory,
};

pub const StartWsResult = StartWsError!WsConn;

// ── live connection ─────────────────────────────────────────────────────────

/// One upgraded WebSocket connection. Reads assemble fragments into complete
/// messages (bounded by `max_message`); control frames are answered inline
/// (ping→pong) or surfaced (close→echo + ConnectionClosed). All writes are
/// serialized through the connection's `wlock`.
pub const WsConn = struct {
    fd: std.posix.socket_t,
    alloc: std.mem.Allocator,
    max_message: usize = ws_max_message_bytes,
    close_sent: bool = false,
    wlock: WsSpinLock = .{},

    // Buffered reader state (rbuf[rpos..rend] holds unconsumed bytes).
    rbuf: [4096]u8 = undefined,
    rpos: usize = 0,
    rend: usize = 0,

    /// Bind to a live socket. Disables SO_RCVTIMEO (reads block until loopback
    /// FIN/RST — see module doc) and bounds SO_SNDTIMEO at 2 s so hub fan-out
    /// to a wedged client fails instead of stalling publisher threads.
    pub fn init(fd: std.posix.socket_t, alloc: std.mem.Allocator) WsConn {
        const tv: std.c.timeval = .{ .sec = 0, .usec = 0 }; // 0 = block forever
        _ = setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &tv, @sizeOf(std.c.timeval));
        const send_tv: std.c.timeval = .{ .sec = 2, .usec = 0 };
        _ = setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, &send_tv, @sizeOf(std.c.timeval));
        return .{ .fd = fd, .alloc = alloc };
    }

    // ---- reading ----

    fn fill(self: *WsConn) WsError!void {
        if (self.rpos == self.rend) {
            self.rpos = 0;
            self.rend = 0;
        }
        if (self.rend == self.rbuf.len) {
            // Compaction: reader consumed some head room.
            const remaining = self.rend - self.rpos;
            std.mem.copyForwards(u8, self.rbuf[0..remaining], self.rbuf[self.rpos..self.rend]);
            self.rpos = 0;
            self.rend = remaining;
            if (remaining == self.rbuf.len) return error.ProtocolError; // header > buffer
        }
        while (true) {
            const n = recv(self.fd, self.rbuf[self.rend..].ptr, self.rbuf.len - self.rend, 0);
            if (n > 0) {
                self.rend += @intCast(n);
                return;
            }
            if (n == 0) return error.ConnectionClosed; // FIN
            const err = std.c.errno(n);
            if (err == .INTR) continue;
            if (err == .AGAIN) continue; // timeout disabled post-upgrade; belt & braces
            return error.ReadFailed;
        }
    }

    fn readByte(self: *WsConn) WsError!u8 {
        if (self.rpos == self.rend) try self.fill();
        const b = self.rbuf[self.rpos];
        self.rpos += 1;
        return b;
    }

    fn readInto(self: *WsConn, dst: []u8) WsError!void {
        var off: usize = 0;
        while (off < dst.len) {
            if (self.rpos == self.rend) try self.fill();
            const avail = self.rend - self.rpos;
            const take = @min(avail, dst.len - off);
            @memcpy(dst[off .. off + take], self.rbuf[self.rpos .. self.rpos + take]);
            self.rpos += take;
            off += take;
        }
    }

    /// Read ONE complete data message (fragments reassembled) appending its
    /// payload to `out` (cleared first). Interleaved ping frames are answered
    /// automatically; pong frames are dropped; a close frame completes the
    /// closing handshake (echo) and yields `error.ConnectionClosed`.
    ///
    /// Any CLIENT-originated data frame received here is by definition a
    /// protocol violation for our downstream-only streams — callers wanting
    /// echo behavior should compare opcodes themselves; this layer delivers
    /// whatever the peer legally sent.
    pub fn readMessage(self: *WsConn, out: *std.ArrayList(u8)) WsError!WsOpcode {
        out.clearRetainingCapacity();
        var msg_opcode: ?WsOpcode = null;

        while (true) {
            const b0 = try self.readByte();
            const fin = b0 & 0x80 != 0;
            if (b0 & 0x70 != 0) return self.failProtocol(); // RSV bits
            const opcode = WsOpcode.fromByte(b0 & 0x0F) orelse return self.failProtocol();

            const b1 = try self.readByte();
            const masked = b1 & 0x80 != 0;
            if (!masked) return self.failProtocol(); // client frames MUST mask
            var payload_len: u64 = b1 & 0x7F;
            if (payload_len == 126) {
                var ext: [2]u8 = undefined;
                try self.readInto(&ext);
                payload_len = std.mem.readInt(u16, &ext, .big);
                if (payload_len < 126) return self.failProtocol();
            } else if (payload_len == 127) {
                var ext: [8]u8 = undefined;
                try self.readInto(&ext);
                payload_len = std.mem.readInt(u64, &ext, .big);
                if (payload_len <= 0xFFFF) return self.failProtocol();
            }

            var mask_key: [4]u8 = undefined;
            try self.readInto(&mask_key);

            switch (opcode) {
                .ping, .pong, .close => {
                    // Control frames: never fragmented, payload ≤ 125.
                    if (!fin or payload_len > 125) return self.failProtocol();
                    var ctrl_buf: [125]u8 = undefined;
                    const ctrl = ctrl_buf[0..@intCast(payload_len)];
                    try self.readInto(ctrl);
                    applyMask(ctrl, mask_key);
                    switch (opcode) {
                        .ping => try self.writeControlRaw(.pong, ctrl),
                        .pong => {}, // unsolicited pongs are dropped
                        .close => {
                            // Echo the close (same code; default 1000 when empty).
                            var close_code: u16 = 1000;
                            if (ctrl.len >= 2) {
                                close_code = std.mem.readInt(u16, ctrl[0..2], .big);
                                // Unknown/invalid codes echo as 1002 protocol error.
                                if (!isValidCloseCode(close_code)) close_code = 1002;
                            }
                            self.writeClose(close_code, "") catch {};
                            return error.ConnectionClosed;
                        },
                        else => unreachable,
                    }
                    continue;
                },
                .continuation => {
                    if (msg_opcode == null) return self.failProtocol();
                },
                .text, .binary => {
                    if (msg_opcode != null) return self.failProtocol();
                    msg_opcode = opcode;
                },
            }

            // Data frame: enforce the reassembly cap, then consume payload.
            const total = out.items.len + payload_len;
            if (total > self.max_message) {
                self.writeClose(1009, "") catch {}; // MESSAGE_TOO_BIG
                self.close_sent = true;
                return error.MessageTooLarge;
            }
            const start = out.items.len;
            try out.resize(self.alloc, start + @as(usize, @intCast(payload_len)));
            try self.readInto(out.items[start..]);
            applyMask(out.items[start..], mask_key);

            if (fin) return msg_opcode.?;
        }
    }

    fn isValidCloseCode(code: u16) bool {
        return switch (code) {
            1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011 => true,
            3000...4999 => true,
            else => false,
        };
    }

    /// Fail the connection with a 1002 close and surface ProtocolError.
    fn failProtocol(self: *WsConn) WsError {
        self.writeClose(1002, "") catch {};
        self.close_sent = true;
        return error.ProtocolError;
    }

    // ---- writing ----

    fn writeAllLocked(self: *WsConn, data: []const u8) WsError!void {
        self.wlock.lock();
        defer self.wlock.unlock();
        self.writeAllUnlocked(data) catch return error.WriteFailed;
    }

    /// Caller must hold `wlock` (header+payload pairs must not interleave).
    fn writeAllUnlocked(self: *WsConn, data: []const u8) !void {
        var off: usize = 0;
        while (off < data.len) {
            const n = libc_send(self.fd, data.ptr + off, data.len - off, send_flags);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    /// Send one complete unmasked frame: header from a stack buffer, payload
    /// straight from caller memory (server frames are never masked, so no
    /// payload copy is needed). Zero heap allocation.
    pub fn writeFrame(self: *WsConn, opcode: WsOpcode, payload: []const u8) WsError!void {
        var hdr: [10]u8 = undefined;
        hdr[0] = 0x80 | opcode.toByte(); // server data frames: fin=1
        const ext = encodeExtendedLen(payload.len);
        hdr[1] = encodeLenBits(payload.len);
        var hdr_len: usize = 2;
        switch (ext) {
            .none => {},
            .u16 => |v| {
                std.mem.writeInt(u16, hdr[2..4], v, .big);
                hdr_len = 4;
            },
            .u64 => |v| {
                std.mem.writeInt(u64, hdr[2..10], v, .big);
                hdr_len = 10;
            },
        }
        self.wlock.lock();
        defer self.wlock.unlock();
        self.writeAllUnlocked(hdr[0..hdr_len]) catch return error.WriteFailed;
        if (payload.len > 0) {
            self.writeAllUnlocked(payload) catch return error.WriteFailed;
        }
    }

    pub fn writeText(self: *WsConn, payload: []const u8) WsError!void {
        return self.writeFrame(.text, payload);
    }

    pub fn writeBinary(self: *WsConn, payload: []const u8) WsError!void {
        return self.writeFrame(.binary, payload);
    }

    pub fn writePing(self: *WsConn, payload: []const u8) WsError!void {
        return self.writeControlRaw(.ping, payload);
    }

    pub fn writePong(self: *WsConn, payload: []const u8) WsError!void {
        return self.writeControlRaw(.pong, payload);
    }

    /// Control frames carry ≤125 bytes; longer payloads are truncated to the
    /// RFC limit rather than failing the connection.
    fn writeControlRaw(self: *WsConn, opcode: WsOpcode, payload: []const u8) WsError!void {
        const n = @min(payload.len, 125);
        var hdr: [2]u8 = .{ 0x80 | opcode.toByte(), @intCast(n) };
        self.wlock.lock();
        defer self.wlock.unlock();
        self.writeAllUnlocked(&hdr) catch return error.WriteFailed;
        if (n > 0) {
            self.writeAllUnlocked(payload[0..n]) catch return error.WriteFailed;
        }
    }

    /// Begin the closing handshake: send a close frame with `code` and
    /// `reason` (reason truncated so the total payload stays ≤123 bytes).
    /// Idempotent per connection (`close_sent` guard). Does NOT wait for the
    /// peer's close reply; the fd owner closes the socket afterwards.
    pub fn writeClose(self: *WsConn, code: u16, reason: []const u8) WsError!void {
        if (self.close_sent) return;
        self.close_sent = true;
        var payload: [125]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], code, .big);
        const max_reason = @min(reason.len, 123);
        @memcpy(payload[2 .. 2 + max_reason], reason[0..max_reason]);
        return self.writeControlRaw(.close, payload[0 .. 2 + max_reason]);
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

test "parseRequest round-trips method/path/query/headers/body" {
    const alloc = std.testing.allocator;
    const raw =
        "POST /run?debug=1 HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 11\r\n" ++
        "\r\n" ++
        "{\"a\":12345}";
    var req = try parseRequest(alloc, raw);
    defer req.deinit(alloc);

    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/run", req.path);
    try std.testing.expectEqualStrings("debug=1", req.query);
    try std.testing.expectEqualStrings("HTTP/1.1", req.version);
    try std.testing.expectEqualStrings("{\"a\":12345}", req.body);
    try std.testing.expect(req.headers.len == 3);
    try std.testing.expectEqualStrings("localhost", req.header("host").?);
    // Case-insensitive lookup.
    try std.testing.expectEqualStrings("application/json", req.header("CONTENT-TYPE").?);
    try std.testing.expect(req.header("absent") == null);
    try std.testing.expect(!req.isGetLike());
}

test "parseRequest handles bodyless GET and empty query absence" {
    const alloc = std.testing.allocator;
    var req = try parseRequest(alloc, "GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n");
    defer req.deinit(alloc);
    try std.testing.expectEqualStrings("", req.body);
    try std.testing.expectEqualStrings("/healthz", req.path);
    try std.testing.expectEqualStrings("", req.query);
    try std.testing.expect(req.isGetLike());
}

test "parseRequest rejects malformed inputs" {
    try std.testing.expectError(error.BadRequest, parseRequest(std.testing.allocator, "garbage"));
    try std.testing.expectError(error.BadRequest, parseRequest(std.testing.allocator, "GET /x HTTP/1.1 extra\r\n\r\n"));
    try std.testing.expectError(error.BadRequest, parseRequest(std.testing.allocator, "POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nab")); // incomplete body
    try std.testing.expectError(error.BodyTooLarge, parseRequest(std.testing.allocator, "POST /x HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n"));
    try std.testing.expectError(error.NotImplementedTransfer, parseRequest(std.testing.allocator, "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"));
}

test "formatResponse exact bytes" {
    const alloc = std.testing.allocator;
    const raw = try formatResponse(alloc, .ok, .json, "{\"ok\":true}");
    defer alloc.free(raw);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}",
        raw,
    );
}

test "percentDecode decodes escapes and tolerates stray percent" {
    const alloc = std.testing.allocator;
    const a = try percentDecode(alloc, "hello%20world%2Ffile.zig");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("hello world/file.zig", a);
    const b = try percentDecode(alloc, "100%done%zz");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("100%done%zz", b);
}

// ── WebSocket tests (wave-5 additive layer) ────────────────────────────────

const ws_testing = std.testing;

test "computeWsAcceptKey matches the RFC 6455 §1.3 example vector" {
    // RFC: key "dGhlIHNhbXBsZSBub25jZQ==" → accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    const key = try computeWsAcceptKey(ws_testing.allocator, "dGhlIHNhbXBsZSBub25jZQ==");
    defer ws_testing.allocator.free(key);
    try ws_testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", key);
}

/// Parse a request into an arena owned by the returned holder struct so
/// upgrade tests can borrow header slices without manual frees.
const ReqHolder = struct {
    arena: std.heap.ArenaAllocator,
    req: Request,

    fn deinit(self: *ReqHolder) void {
        self.arena.deinit();
    }
};

fn makeWsRequest(raw: []const u8) !ReqHolder {
    var holder = ReqHolder{
        .arena = std.heap.ArenaAllocator.init(ws_testing.allocator),
        .req = undefined,
    };
    errdefer holder.arena.deinit();
    holder.req = try parseRequest(holder.arena.allocator(), raw);
    return holder;
}

test "WsUpgrade.fromRequest validates handshake headers and rejects bad ones" {
    const good_raw = "GET /api/events.mux HTTP/1.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    {
        var h = try makeWsRequest(good_raw);
        defer h.deinit();
        const upg = try WsUpgrade.fromRequest(&h.req);
        const resp = try upg.formatResponse(h.arena.allocator());
        try ws_testing.expect(std.mem.indexOf(u8, resp, "HTTP/1.1 101 Switching Protocols\r\n") != null);
        try ws_testing.expect(std.mem.indexOf(u8, resp, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != null);
    }
    // POST → NotWebSocket.
    {
        const raw = "POST /api/x HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
        var h = try makeWsRequest(raw);
        defer h.deinit();
        try ws_testing.expectError(error.NotWebSocket, WsUpgrade.fromRequest(&h.req));
    }
    // Missing key.
    {
        const raw = "GET /api/events.mux HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n";
        var h = try makeWsRequest(raw);
        defer h.deinit();
        try ws_testing.expectError(error.MissingKey, WsUpgrade.fromRequest(&h.req));
    }
    // Bad version.
    {
        const raw = "GET /api/events.mux HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 8\r\n\r\n";
        var h = try makeWsRequest(raw);
        defer h.deinit();
        try ws_testing.expectError(error.BadVersion, WsUpgrade.fromRequest(&h.req));
    }
    // Upgrade header absent entirely.
    {
        const raw = "GET /api/events.mux HTTP/1.1\r\nHost: x\r\n\r\n";
        var h = try makeWsRequest(raw);
        defer h.deinit();
        try ws_testing.expectError(error.NotWebSocket, WsUpgrade.fromRequest(&h.req));
    }
}

test "encodeWsFrame/parseWsFrameHeader round-trip unmasked small frame" {
    const alloc = ws_testing.allocator;
    const payload = "hello ws";
    const frame = try encodeWsFrame(alloc, .text, true, payload, null);
    defer alloc.free(frame);
    try ws_testing.expectEqual(@as(usize, 2 + payload.len), frame.len);

    const hdr = try parseWsFrameHeader(frame);
    try ws_testing.expect(hdr.fin);
    try ws_testing.expectEqual(WsOpcode.text, hdr.opcode);
    try ws_testing.expect(!hdr.masked);
    try ws_testing.expectEqual(payload.len, hdr.payload_len);
    try ws_testing.expectEqual(@as(usize, 2), hdr.header_len);
    try ws_testing.expectEqualStrings(payload, frame[hdr.header_len..]);
}

test "frame codec round-trips masked payloads (client-style) of all length classes" {
    const alloc = ws_testing.allocator;
    const key: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };

    // 7-bit class, 16-bit class (300 bytes), 64-bit class is capped by the
    // test below at 70000 bytes — all through the same encode/parse/unmask.
    const sizes = [_]usize{ 0, 1, 125, 126, 300, 65535, 65536, 70000 };
    for (sizes) |n| {
        const payload = try alloc.alloc(u8, n);
        defer alloc.free(payload);
        for (payload, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

        const frame = try encodeWsFrame(alloc, .binary, true, payload, key);
        defer alloc.free(frame);

        const hdr = try parseWsFrameHeader(frame);
        try ws_testing.expect(hdr.fin);
        try ws_testing.expect(hdr.masked);
        try ws_testing.expectEqual(n, hdr.payload_len);
        const body = frame[hdr.header_len..];
        try ws_testing.expectEqual(n, body.len);
        // Masked on the wire…
        if (n > 4) try ws_testing.expect(!std.mem.eql(u8, body[0..8], payload[0..8]));
        // …and unmasks back exactly.
        applyMask(@constCast(body), key);
        try ws_testing.expectEqualSlices(u8, payload, body);
    }
}

test "parseWsFrameHeader needs more data for truncated headers" {
    const alloc = ws_testing.allocator;
    var payload: [400]u8 = undefined;
    @memset(&payload, 0xAB);
    const frame = try encodeWsFrame(alloc, .text, false, &payload, null);
    defer alloc.free(frame);
    try ws_testing.expectError(error.NeedMoreData, parseWsFrameHeader(frame[0..1]));
    try ws_testing.expectError(error.NeedMoreData, parseWsFrameHeader(frame[0..3]));
    const hdr = try parseWsFrameHeader(frame);
    try ws_testing.expect(!hdr.fin); // fragmented first frame
}

test "parseWsFrameHeader rejects RSV bits and reserved opcodes" {
    // RSV1 set on a text frame.
    const rsv = [4]u8{ 0x81 | 0x40, 0x80, 0, 0 };
    try ws_testing.expectError(error.ProtocolError, parseWsFrameHeader(&rsv));
    // Reserved opcode 0x3.
    const resv_op = [2]u8{ 0x83, 0x00 };
    try ws_testing.expectError(error.ProtocolError, parseWsFrameHeader(&resv_op));
    // Non-minimal 16-bit length (len 5 declared as extended).
    const nonmin = [4]u8{ 0x81, 126, 0x00, 0x05 };
    try ws_testing.expectError(error.ProtocolError, parseWsFrameHeader(&nonmin));
}

test "close frame payload packs big-endian code plus reason" {
    const alloc = ws_testing.allocator;
    var close_payload: [128]u8 = undefined;
    std.mem.writeInt(u16, close_payload[0..2], 1008, .big);
    @memcpy(close_payload[2..9], "no dice");
    const frame = try encodeWsFrame(alloc, .close, true, close_payload[0..9], null);
    defer alloc.free(frame);
    const hdr = try parseWsFrameHeader(frame);
    try ws_testing.expectEqual(WsOpcode.close, hdr.opcode);
    try ws_testing.expectEqual(@as(u64, 9), hdr.payload_len);
    try ws_testing.expectEqual(@as(u16, 1008), std.mem.readInt(u16, frame[2..4], .big));
}
