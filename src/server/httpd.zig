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
    payload_too_large = 413,
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
            .payload_too_large => "Payload Too Large",
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
            if (std.mem.indexOf(u8, buf.items, "\r\n\r\n") != null) break;
            if (buf.items.len > MaxHeadBytes) {
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
