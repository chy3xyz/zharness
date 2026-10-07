//! MCP (Model Context Protocol) client over the stdio transport —
//! newline-delimited JSON-RPC 2.0 exchanged with a spawned server process
//! through its stdin/stdout pipes (dev.md §XX, SWARM task E-mcp).
//!
//! Transport decision: child processes are spawned with `std.process.spawn`
//! (Zig 0.17's Io-aware API), NOT with clib's `popen` — popen is read-only and
//! cannot feed a child's stdin, while MCP requires bidirectional pipes. All
//! byte I/O goes through raw POSIX fds (`File.handle`) with a poll(2)-based
//! timeout guard, which lets the exact same code path serve BOTH spawned
//! children and pre-connected fd pairs (`connectFds` — used by the offline
//! fake-server tests; no real process is ever launched in tests).
//!
//! Wire rules implemented here:
//! - One JSON-RPC envelope per line; requests carry monotonically increasing
//!   numeric ids; responses are matched by id; notifications are stashed for
//!   `takeNotifications`; stale/unknown-id responses and server-initiated
//!   *requests* are dropped (single-flight client: one call in flight at a
//!   time, so any response seen is either ours or garbage from an earlier
//!   timed-out call).
//! - Reads never block longer than `timeout_ms`; EOF mid-frame and protocol
//!   violations surface as errors, never panics.

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");

/// Protocol version advertised during the initialize handshake.
pub const protocol_version = "2024-11-05";

pub const client_name = "zharness";
pub const client_version = "0.1.0";

/// Default per-request read timeout.
pub const default_timeout_ms: i32 = 10_000;

/// Hard cap on one framed line (MCP tool schemas can be large; 4 MiB is
/// generous and prevents unbounded memory growth from a hostile server).
const max_line_bytes: usize = 4 << 20;

const read_chunk_size: usize = 4096;

pub const McpError = error{
    /// Writing to the server's stdin failed.
    TransportWrite,
    /// poll(2) itself failed on the read side.
    TransportRead,
    /// Server closed the pipe or died mid-exchange.
    ConnectionClosed,
    /// No response within `timeout_ms`.
    Timeout,
    /// A single line exceeded `max_line_bytes`.
    LineTooLong,
    /// Server answered in a shape this client cannot interpret.
    ProtocolViolation,
    /// The server answered `initialize` with a JSON-RPC error.
    InitializeRejected,
    /// The server answered a request (e.g. tools/list) with a JSON-RPC error.
    ServerRejectedRequest,
    /// `callTool` arguments were not a JSON object.
    InvalidArguments,
    OutOfMemory,
};

// ── result types ────────────────────────────────────────────────────────────

/// Successful `initialize` response, fully owned.
pub const InitInfo = struct {
    protocol_version: []const u8,
    /// Verbatim capabilities object text ("{}" when absent).
    capabilities_json: []const u8,
    server_name: []const u8,
    server_version: []const u8,
    /// Server-provided operating guidance from the initialize result ("" when
    /// absent). Injected into the agent system prompt when non-empty.
    instructions: []const u8,

    pub fn deinit(self: *const InitInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.protocol_version);
        alloc.free(self.capabilities_json);
        alloc.free(self.server_name);
        alloc.free(self.server_version);
        alloc.free(self.instructions);
    }
};

/// One tool advertised by `tools/list`, translated toward the local registry.
pub const RemoteTool = struct {
    name: []const u8,
    description: []const u8,
    /// Verbatim `inputSchema` object text ("{}" when absent).
    schema_json: []const u8,

    pub fn deinit(self: *const RemoteTool, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        alloc.free(self.schema_json);
    }
};

pub const ToolList = struct {
    tools: []RemoteTool = &.{},

    pub fn deinit(self: *const ToolList, alloc: std.mem.Allocator) void {
        for (self.tools) |t| t.deinit(alloc);
        alloc.free(self.tools);
    }
};

/// Result of `tools/call`: content blocks of type "text" joined with "\n".
pub const CallOutcome = struct {
    /// False when the RPC failed or the server flagged `isError`.
    ok: bool,
    /// Joined text content, or the RPC error message on failure.
    text: []const u8,
    /// Full MCP result object text ("" for RPC-level errors).
    raw_result_json: []const u8,

    pub fn deinit(self: *const CallOutcome, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        if (self.raw_result_json.len > 0) alloc.free(self.raw_result_json);
    }
};

/// Server-initiated notification captured while waiting for responses.
pub const ServerNotification = struct {
    method: []const u8,
    params_json: []const u8,

    pub fn deinit(self: *const ServerNotification, alloc: std.mem.Allocator) void {
        alloc.free(self.method);
        alloc.free(self.params_json);
    }
};

// ── client ──────────────────────────────────────────────────────────────────

pub const McpClient = struct {
    alloc: std.mem.Allocator,
    /// Required only for the child transport (spawn/wait). Null for fd pairs.
    io: ?std.Io,
    conn: Conn,
    next_id: i64 = 0,
    timeout_ms: i32 = default_timeout_ms,
    shut_down: bool = false,

    /// Read-side leftovers between lines (compacted to index 0 after each
    /// consumed line so buffered bytes survive across calls).
    accum: std.ArrayList(u8) = .empty,
    notifications: std.ArrayList(ServerNotification) = .empty,

    const Conn = union(enum) {
        child: std.process.Child,
        fds: struct { write_fd: std.posix.fd_t, read_fd: std.posix.fd_t },
    };

    /// Spawn an MCP server process with piped stdin/stdout. `argv[0]` is the
    /// program (PATH-resolved unless it contains '/'). stderr is discarded.
    /// Requires an `Io` instance (e.g. `std.Io.Threaded.init(...)`).
    pub fn spawnChild(
        alloc: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
    ) (std.process.SpawnError || McpError)!McpClient {
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        return .{
            .alloc = alloc,
            .io = io,
            .conn = .{ .child = child },
        };
    }

    /// Wrap pre-connected fds (test/fake-server usage): writes go to
    /// `write_fd`, reads come from `read_fd`. The client takes ownership of
    /// both descriptors and closes them in `deinit`.
    pub fn connectFds(
        alloc: std.mem.Allocator,
        write_fd: std.posix.fd_t,
        read_fd: std.posix.fd_t,
    ) McpClient {
        return .{
            .alloc = alloc,
            .io = null,
            .conn = .{ .fds = .{ .write_fd = write_fd, .read_fd = read_fd } },
        };
    }

    fn writeFd(self: *const McpClient) std.posix.fd_t {
        return switch (self.conn) {
            .child => |c| c.stdin.?.handle,
            .fds => |f| f.write_fd,
        };
    }

    fn readFd(self: *const McpClient) std.posix.fd_t {
        return switch (self.conn) {
            .child => |c| c.stdout.?.handle,
            .fds => |f| f.read_fd,
        };
    }

    // ── low-level I/O ───────────────────────────────────────────────────

    /// One write(2) attempt through libc (`std.posix` no longer wraps write).
    fn sysWrite(fd: std.posix.fd_t, bytes: []const u8) (McpError || error{WouldBlock})!usize {
        while (true) {
            const rc = std.posix.system.write(fd, bytes.ptr, bytes.len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => return error.TransportWrite,
            }
        }
    }

    /// close(2) through libc; errors ignored (best-effort teardown).
    fn sysClose(fd: std.posix.fd_t) void {
        _ = std.posix.system.close(fd);
    }

    fn writeAll(self: *McpClient, bytes: []const u8) McpError!void {
        var off: usize = 0;
        while (off < bytes.len) {
            var n: usize = 0;
            if (sysWrite(self.writeFd(), bytes[off..])) |wrote| {
                n = wrote;
            } else |e| switch (e) {
                error.WouldBlock => {
                    // Pipe full: wait for writability instead of spinning.
                    var pf = [_]std.posix.pollfd{.{
                        .fd = self.writeFd(),
                        .events = std.posix.POLL.OUT,
                        .revents = 0,
                    }};
                    _ = std.posix.poll(&pf, self.timeout_ms) catch return error.TransportWrite;
                    if ((pf[0].revents & std.posix.POLL.OUT) == 0 and
                        (pf[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
                    {
                        return error.ConnectionClosed;
                    }
                },
                else => return error.TransportWrite,
            }
            if (n == 0) continue;
            off += n;
        }
    }

    fn sendLine(self: *McpClient, line: []const u8) McpError!void {
        try self.writeAll(line);
        try self.writeAll("\n");
    }

    /// Monotonic milliseconds (libc clock_gettime; no Io instance needed).
    fn monotonicMs() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
    }

    /// Read one '\n'-terminated line. Returns an owned slice without the
    /// newline, null on clean EOF (no partial data pending), error.Timeout
    /// when nothing arrives within `timeout_ms`. Bytes past a line stay
    /// buffered for the next call.
    fn readLine(self: *McpClient, timeout_ms: i32) McpError!?[]u8 {
        var search_off: usize = 0;
        const deadline = monotonicMs() + timeout_ms;
        var polled_once = false;
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.accum.items, search_off, '\n')) |nl| {
                const line = self.alloc.dupe(u8, self.accum.items[0..nl]) catch
                    return error.OutOfMemory;
                errdefer self.alloc.free(line);
                // Compact the remainder to the front.
                const rest = self.accum.items.len - (nl + 1);
                std.mem.copyForwards(u8, self.accum.items[0..rest], self.accum.items[nl + 1 ..]);
                self.accum.shrinkRetainingCapacity(rest);
                return line;
            }
            search_off = if (self.accum.items.len > 0) self.accum.items.len - 1 else 0;
            if (self.accum.items.len > max_line_bytes) return error.LineTooLong;

            if (polled_once and monotonicMs() >= deadline) return error.Timeout;
            const remaining = @max(deadline - monotonicMs(), 0);
            var pfds = [_]std.posix.pollfd{.{
                .fd = self.readFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&pfds, @intCast(remaining)) catch
                return error.TransportRead;
            polled_once = true;
            if (ready == 0) return error.Timeout;
            if (pfds[0].revents & std.posix.POLL.IN == 0) {
                if (pfds[0].revents &
                    (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0)
                {
                    return error.ConnectionClosed;
                }
                continue; // spurious wakeup
            }
            var chunk: [read_chunk_size]u8 = undefined;
            const n = std.posix.read(self.readFd(), &chunk) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => return error.ConnectionClosed,
            };
            if (n == 0) {
                // EOF: clean only when no partial line is pending.
                if (self.accum.items.len == 0) return null;
                return error.ConnectionClosed;
            }
            self.accum.appendSlice(self.alloc, chunk[0..n]) catch return error.OutOfMemory;
        }
    }

    // ── request/response plumbing ───────────────────────────────────────

    fn sendRequest(self: *McpClient, method: []const u8, params_json: []const u8) McpError!i64 {
        const id = self.next_id;
        self.next_id += 1;
        const wire = jsonrpc.encodeRequest(self.alloc, id, method, params_json) catch
            return error.OutOfMemory;
        defer self.alloc.free(wire);
        try self.sendLine(wire);
        return id;
    }

    fn sendNotification(self: *McpClient, method: []const u8, params_json: []const u8) McpError!void {
        const wire = jsonrpc.encodeNotification(self.alloc, method, params_json) catch
            return error.OutOfMemory;
        defer self.alloc.free(wire);
        try self.sendLine(wire);
    }

    /// Wait for the response carrying `id`. Notifications encountered on the
    /// way are stashed; foreign-id responses and server-initiated requests are
    /// dropped. Caller owns the returned Decoded (deinit with self.alloc).
    fn awaitResponse(self: *McpClient, id: i64) McpError!jsonrpc.Decoded {
        while (true) {
            const maybe_line = try self.readLine(self.timeout_ms);
            const line = maybe_line orelse return error.ConnectionClosed;
            defer self.alloc.free(line);

            var decoded = jsonrpc.decodeMessage(self.alloc, line) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MalformedMessage => continue, // tolerate junk lines
            };
            switch (decoded) {
                .notification => |nt| {
                    // Ownership moves into the stash; skip deinit.
                    self.notifications.append(self.alloc, .{
                        .method = nt.method,
                        .params_json = nt.params_json,
                    }) catch {
                        decoded.deinit(self.alloc);
                        return error.OutOfMemory;
                    };
                },
                .request => decoded.deinit(self.alloc), // unsupported; dropped
                .response_ok => |r| {
                    if (r.id == .number and r.id.number == id) return decoded;
                    decoded.deinit(self.alloc); // stale/garbage id
                },
                .response_err => |r| {
                    if (r.id == .number and r.id.number == id) return decoded;
                    decoded.deinit(self.alloc);
                },
            }
        }
    }

    // ── MCP operations ──────────────────────────────────────────────────

    /// Perform the initialize handshake followed by the required
    /// `notifications/initialized` announcement.
    pub fn initialize(self: *McpClient) McpError!InitInfo {
        const init_params =
            "{\"protocolVersion\":\"" ++ protocol_version ++
            "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"" ++ client_name ++
            "\",\"version\":\"" ++ client_version ++ "\"}}";
        const id = try self.sendRequest("initialize", init_params);
        var resp = try self.awaitResponse(id);
        defer resp.deinit(self.alloc);
        const result_text = switch (resp) {
            .response_ok => |r| r.result_json,
            .response_err => |r| {
                std.log.scoped(.mcp).warn(
                    "initialize rejected: code={d} msg={s}",
                    .{ r.err.code, r.err.message },
                );
                return error.InitializeRejected;
            },
            else => return error.ProtocolViolation,
        };

        var info = InitInfo{
            .protocol_version = try stringFieldOrDefault(self.alloc, result_text, 0, "protocolVersion", ""),
            .capabilities_json = try rawFieldOrDefault(self.alloc, result_text, 0, "capabilities", "{}"),
            // All fields are heap-owned so deinit can free unconditionally.
            .server_name = try allocEmpty(self.alloc),
            .server_version = try allocEmpty(self.alloc),
            .instructions = try stringFieldOrDefault(self.alloc, result_text, 0, "instructions", ""),
        };
        errdefer info.deinit(self.alloc);
        if (try findField(result_text, 0, "serverInfo")) |srv| {
            if (srv.kind == .object) {
                // memberFind takes the index of the object's opening '{'.
                const name = try stringFieldOrDefault(self.alloc, result_text, srv.span.start, "name", "");
                self.alloc.free(info.server_name);
                info.server_name = name;
                const ver = try stringFieldOrDefault(self.alloc, result_text, srv.span.start, "version", "");
                self.alloc.free(info.server_version);
                info.server_version = ver;
            }
        }
        try self.sendNotification("notifications/initialized", "");
        return info;
    }

    /// Fetch the server's tool catalog. Descriptors keep the remote schema
    /// VERBATIM in `schema_json` so the bridge can pass it through unchanged.
    pub fn listTools(self: *McpClient) McpError!ToolList {
        const id = try self.sendRequest("tools/list", "{}");
        var resp = try self.awaitResponse(id);
        defer resp.deinit(self.alloc);
        const result_text = switch (resp) {
            .response_ok => |r| r.result_json,
            .response_err => return error.ServerRejectedRequest,
            else => return error.ProtocolViolation,
        };

        var tools: std.ArrayList(RemoteTool) = .empty;
        errdefer {
            for (tools.items) |t| t.deinit(self.alloc);
            tools.deinit(self.alloc);
        }
        const tools_val = (try findField(result_text, 0, "tools")) orelse
            return error.ProtocolViolation; // spec: tools/list result has tools[]
        if (tools_val.kind != .array) return error.ProtocolViolation;

        var it = jsonrpc.ArrayIter.init(result_text, tools_val.span.start);
        while (try arrayNext(&it)) |elem| {
            if (elem.kind != .object) return error.ProtocolViolation;
            const name_v = (try findField(result_text, elem.span.start, "name")) orelse
                return error.ProtocolViolation; // name is mandatory
            const tool = RemoteTool{
                .name = try unescapeString(self.alloc, result_text, name_v),
                .description = try stringFieldOrDefault(self.alloc, result_text, elem.span.start, "description", ""),
                .schema_json = try rawFieldOrDefault(self.alloc, result_text, elem.span.start, "inputSchema", "{}"),
            };
            tools.append(self.alloc, tool) catch {
                tool.deinit(self.alloc);
                return error.OutOfMemory;
            };
        }
        const slice = tools.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
        return .{ .tools = slice };
    }

    /// Invoke a remote tool. `args_json` must be a JSON object (empty string
    /// means `{}`). Text content blocks are joined with "\n"; non-text blocks
    /// are skipped; an `isError:true` result flips `ok` but keeps the text.
    pub fn callTool(self: *McpClient, name: []const u8, args_json: []const u8) McpError!CallOutcome {
        const trimmed = std.mem.trim(u8, args_json, " \t\r\n");
        if (trimmed.len > 0 and (trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}')) {
            return error.InvalidArguments;
        }
        const effective_args: []const u8 = if (trimmed.len == 0) "{}" else trimmed;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.alloc);
        params.appendSlice(self.alloc, "{\"name\":\"") catch return error.OutOfMemory;
        jsonrpc.appendEscaped(self.alloc, &params, name) catch return error.OutOfMemory;
        params.appendSlice(self.alloc, "\",\"arguments\":") catch return error.OutOfMemory;
        params.appendSlice(self.alloc, effective_args) catch return error.OutOfMemory;
        params.append(self.alloc, '}') catch return error.OutOfMemory;

        const id = try self.sendRequest("tools/call", params.items);
        var resp = try self.awaitResponse(id);
        // NOTE: no blanket `defer resp.deinit` — each branch below MOVES the
        // slices it keeps into the outcome and frees the rest itself.
        switch (resp) {
            .response_err => |r| {
                if (r.err.data_json) |d| self.alloc.free(d);
                freeIdContents(self.alloc, r.id);
                const empty = self.alloc.dupe(u8, "") catch return error.OutOfMemory;
                return .{ .ok = false, .text = r.err.message, .raw_result_json = empty };
            },
            .response_ok => |r| {
                errdefer resp.deinit(self.alloc);
                const result_text = r.result_json;
                const is_err = (try boolField(result_text, 0, "isError")) orelse false;
                var joined: std.ArrayList(u8) = .empty;
                errdefer joined.deinit(self.alloc);
                if (try findField(result_text, 0, "content")) |content_v| {
                    if (content_v.kind == .array) {
                        var it = jsonrpc.ArrayIter.init(result_text, content_v.span.start);
                        while (try arrayNext(&it)) |elem| {
                            if (elem.kind != .object) continue;
                            const type_v = (try findField(result_text, elem.span.start, "type")) orelse continue;
                            if (type_v.kind != .string) continue;
                            if (!std.mem.eql(u8, result_text[type_v.inner.start..type_v.inner.end], "text")) continue;
                            const text_v = (try findField(result_text, elem.span.start, "text")) orelse continue;
                            if (text_v.kind != .string) continue;
                            if (joined.items.len > 0) joined.append(self.alloc, '\n') catch return error.OutOfMemory;
                            const piece = jsonrpc.unescapeInner(self.alloc, result_text, text_v.inner) catch
                                return error.OutOfMemory;
                            joined.appendSlice(self.alloc, piece) catch {
                                self.alloc.free(piece);
                                return error.OutOfMemory;
                            };
                            self.alloc.free(piece);
                        }
                    }
                }
                // Ownership moves from the envelope into the outcome; only
                // the id string still needs freeing.
                freeIdContents(self.alloc, r.id);
                return .{
                    .ok = !is_err,
                    .text = try joined.toOwnedSlice(self.alloc),
                    .raw_result_json = result_text,
                };
            },
            else => {
                resp.deinit(self.alloc);
                return error.ProtocolViolation;
            },
        }
    }

    /// Drain inbound messages for up to `wait_ms` (0 = instant sweep),
    /// stashing notifications. Stale responses are discarded.
    pub fn pump(self: *McpClient, wait_ms: i32) McpError!void {
        while (true) {
            const maybe_line = self.readLine(wait_ms) catch |e| switch (e) {
                error.Timeout => return,
                else => return e,
            };
            const line = maybe_line orelse return; // connection closed
            defer self.alloc.free(line);
            var decoded = jsonrpc.decodeMessage(self.alloc, line) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MalformedMessage => continue,
            };
            switch (decoded) {
                .notification => |nt| {
                    self.notifications.append(self.alloc, .{
                        .method = nt.method,
                        .params_json = nt.params_json,
                    }) catch {
                        decoded.deinit(self.alloc);
                        return error.OutOfMemory;
                    };
                },
                else => decoded.deinit(self.alloc),
            }
        }
    }

    /// Number of stashed notifications waiting for `takeNotifications`.
    pub fn pendingNotificationCount(self: *const McpClient) usize {
        return self.notifications.items.len;
    }

    /// Hand over all stashed notifications (caller owns the slice and every
    /// entry; free entries then the slice with the client's allocator).
    pub fn takeNotifications(self: *McpClient) McpError![]ServerNotification {
        return self.notifications.toOwnedSlice(self.alloc) catch error.OutOfMemory;
    }

    /// Close transports and reap a spawned server: stdin EOF first, SIGTERM,
    /// then blocking wait (which also closes stdout/stderr per std.Io).
    /// Safe against double-deinit via the `shut_down` guard.
    pub fn deinit(self: *McpClient) void {
        if (self.shut_down) return;
        self.shut_down = true;
        switch (self.conn) {
            .child => |*ch| {
                if (ch.stdin) |in| {
                    McpClient.sysClose(in.handle);
                    ch.stdin = null; // wait()'s cleanup must not double-close
                }
                if (ch.id) |pid| {
                    std.posix.kill(pid, std.posix.SIG.TERM) catch {};
                    if (self.io) |io| {
                        _ = ch.wait(io) catch {};
                    }
                }
                // Defensive: if wait() was skipped or failed, close leftovers.
                if (ch.stdout) |out| {
                    McpClient.sysClose(out.handle);
                    ch.stdout = null;
                }
                if (ch.stderr) |err_f| {
                    McpClient.sysClose(err_f.handle);
                    ch.stderr = null;
                }
            },
            .fds => |f| {
                McpClient.sysClose(f.write_fd);
                McpClient.sysClose(f.read_fd);
            },
        }
        self.accum.deinit(self.alloc);
        for (self.notifications.items) |*n| n.deinit(self.alloc);
        self.notifications.deinit(self.alloc);
    }
};

fn freeIdContents(alloc: std.mem.Allocator, id: jsonrpc.Id) void {
    switch (id) {
        .string => |s| alloc.free(s),
        else => {},
    }
}

/// Allocated empty string (uniform ownership for defaulted fields).
fn allocEmpty(alloc: std.mem.Allocator) McpError![]u8 {
    return alloc.dupe(u8, "") catch error.OutOfMemory;
}

/// memberFind with MCP-flavored error mapping (malformed ⇒ ProtocolViolation).
fn findField(
    text: []const u8,
    obj_open: usize,
    key: []const u8,
) McpError!?jsonrpc.ScannedValue {
    return jsonrpc.memberFind(text, obj_open, key) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.MalformedMessage => error.ProtocolViolation,
    };
}

/// Unescape a scanned string value into an owned slice.
fn unescapeString(
    alloc: std.mem.Allocator,
    text: []const u8,
    v: jsonrpc.ScannedValue,
) McpError![]u8 {
    if (v.kind != .string) return error.ProtocolViolation;
    return jsonrpc.unescapeInner(alloc, text, v.inner) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.MalformedMessage => error.ProtocolViolation,
    };
}

/// Helper for ArrayIter whose element type carries DecodeError → McpError.
fn arrayNext(it: *jsonrpc.ArrayIter) McpError!?jsonrpc.ScannedValue {
    return it.next() catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.MalformedMessage => error.ProtocolViolation,
    };
}

/// String member of the object opening at `obj_open`, unescaped; `def` when
/// missing (or not a string). Returned slice is owned by the caller.
fn stringFieldOrDefault(
    alloc: std.mem.Allocator,
    text: []const u8,
    obj_open: usize,
    key: []const u8,
    def: []const u8,
) McpError![]u8 {
    const v = (try findField(text, obj_open, key)) orelse
        return alloc.dupe(u8, def) catch error.OutOfMemory;
    if (v.kind != .string) return alloc.dupe(u8, def) catch error.OutOfMemory;
    return jsonrpc.unescapeInner(alloc, text, v.inner) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.MalformedMessage => error.ProtocolViolation,
    };
}

/// Raw member text of the object opening at `obj_open`; `def` when missing.
fn rawFieldOrDefault(
    alloc: std.mem.Allocator,
    text: []const u8,
    obj_open: usize,
    key: []const u8,
    def: []const u8,
) McpError![]u8 {
    const v = (try findField(text, obj_open, key)) orelse
        return alloc.dupe(u8, def) catch error.OutOfMemory;
    return alloc.dupe(u8, text[v.span.start..v.span.end]) catch error.OutOfMemory;
}

/// Boolean literal member of the object opening at `obj_open`.
fn boolField(text: []const u8, obj_open: usize, key: []const u8) McpError!?bool {
    const v = (try findField(text, obj_open, key)) orelse return null;
    if (v.kind != .literal) return null;
    const raw = text[v.span.start..v.span.end];
    if (std.mem.eql(u8, raw, "true")) return true;
    if (std.mem.eql(u8, raw, "false")) return false;
    return null;
}

/// Create a POSIX pipe pair `{read_end, write_end}`. Intended for in-process
/// fake servers (offline tests) and embedding scenarios; production clients
/// use `spawnChild`.
pub fn createPipePair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.pipe(&fds))) {
        .SUCCESS => return fds,
        else => return error.PipeUnavailable,
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// In-process fake server: two pipe pairs replace a real child process, so
/// tests stay offline, deterministic, and leak-free. Scripted responses are
/// written BEFORE the client call runs; request framing is verified by
/// draining the client→fake pipe afterwards.
const FakeHarness = struct {
    client: McpClient,
    req_r: std.posix.fd_t, // read what the client sends
    res_w: std.posix.fd_t, // write scripted responses

    fn setup(alloc: std.mem.Allocator) !FakeHarness {
        const upstream = try createPipePair(); // client → fake
        const downstream = try createPipePair(); // fake → client
        return .{
            .client = McpClient.connectFds(alloc, upstream[1], downstream[0]),
            .req_r = upstream[0],
            .res_w = downstream[1],
        };
    }

    /// Queue response lines (newline-terminated) for the client to consume.
    fn script(self: *FakeHarness, lines: []const []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        for (lines) |l| {
            try buf.appendSlice(testing.allocator, l);
            try buf.append(testing.allocator, '\n');
        }
        var off: usize = 0;
        while (off < buf.items.len) {
            const rc = std.posix.system.write(self.res_w, buf.items[off..].ptr, buf.items.len - off);
            switch (std.posix.errno(rc)) {
                .SUCCESS => off += @intCast(rc),
                .INTR => continue,
                else => return error.BrokenPipe,
            }
        }
    }

    /// Non-blocking sweep of everything the client has sent so far.
    fn drainSent(self: *FakeHarness, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var chunk: [4096]u8 = undefined;
        while (true) {
            var pf = [_]std.posix.pollfd{.{
                .fd = self.req_r,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&pf, 0) catch break;
            if (ready == 0) break;
            if (pf[0].revents & std.posix.POLL.IN == 0) break;
            const n = std.posix.read(self.req_r, &chunk) catch break;
            if (n == 0) break;
            try out.appendSlice(alloc, chunk[0..n]);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Close one scripted-write end early (EOF simulation).
    fn closeWriteEnd(self: *FakeHarness) void {
        if (self.res_w >= 0) {
            McpClient.sysClose(self.res_w);
            self.res_w = -1;
        }
    }

    fn teardown(self: *FakeHarness) void {
        self.client.deinit();
        if (self.req_r >= 0) McpClient.sysClose(self.req_r);
        if (self.res_w >= 0) McpClient.sysClose(self.res_w);
        self.req_r = -1;
        self.res_w = -1;
    }
};

test "initialize handshake round-trip over pipe pair" {
    const alloc = testing.allocator;
    var h = try FakeHarness.setup(alloc);
    defer h.teardown();

    const init_result =
        "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1.2\"},\"instructions\":\"Use rtk.\"}";
    const init_wire = try jsonrpc.encodeResult(alloc, 0, init_result);
    defer alloc.free(init_wire);
    try h.script(&.{init_wire});

    var info = try h.client.initialize();
    defer info.deinit(alloc);
    try testing.expectEqualStrings("2024-11-05", info.protocol_version);
    try testing.expectEqualStrings("fake", info.server_name);
    try testing.expectEqualStrings("1.2", info.server_version);
    try testing.expectEqualStrings("{\"tools\":{}}", info.capabilities_json);
    try testing.expectEqualStrings("Use rtk.", info.instructions);

    // Verify wire: initialize request then the initialized notification.
    const sent = try h.drainSent(alloc);
    defer alloc.free(sent);
    try testing.expect(std.mem.indexOf(u8, sent, "\"method\":\"initialize\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"id\":0") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "zharness") != null);
    var d0 = try jsonrpc.decodeMessage(alloc, sent[0..std.mem.indexOfScalar(u8, sent, '\n').?]);
    defer d0.deinit(alloc);
    try testing.expect(d0 == .request);
    var d1 = try jsonrpc.decodeMessage(alloc, sent[std.mem.indexOfScalar(u8, sent, '\n').? + 1 ..]);
    defer d1.deinit(alloc);
    try testing.expect(d1 == .notification);
    try testing.expectEqualStrings("notifications/initialized", d1.notification.method);
}

test "listTools translates descriptors with schema passthrough" {
    const alloc = testing.allocator;
    var h = try FakeHarness.setup(alloc);
    defer h.teardown();

    const result =
        "{\"tools\":[" ++
        "{\"name\":\"echo\",\"description\":\"Echo input.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"msg\":{\"type\":\"string\"}}}}" ++
        ",{\"name\":\"nodesc\"}]}";
    const wire = try jsonrpc.encodeResult(alloc, 0, result);
    defer alloc.free(wire);
    try h.script(&.{wire});

    var list = try h.client.listTools();
    defer list.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), list.tools.len);
    try testing.expectEqualStrings("echo", list.tools[0].name);
    try testing.expectEqualStrings("Echo input.", list.tools[0].description);
    try testing.expect(
        std.mem.indexOf(u8, list.tools[0].schema_json, "\"properties\":{\"msg\":{\"type\":\"string\"}}") != null,
    );
    // Missing optional fields fall back to documented defaults.
    try testing.expectEqualStrings("nodesc", list.tools[1].name);
    try testing.expectEqualStrings("", list.tools[1].description);
    try testing.expectEqualStrings("{}", list.tools[1].schema_json);
}

test "callTool joins text content and passes isError=false as ok" {
    const alloc = testing.allocator;
    var h = try FakeHarness.setup(alloc);
    defer h.teardown();

    const result =
        "{\"content\":[{\"type\":\"text\",\"text\":\"alpha\"}," ++
        "{\"type\":\"image\",\"data\":\"ignored\"}," ++
        "{\"type\":\"text\",\"text\":\"beta\"}]}";
    const wire = try jsonrpc.encodeResult(alloc, 0, result);
    defer alloc.free(wire);
    try h.script(&.{wire});

    var outcome = try h.client.callTool("echo", "{\"msg\":\"hi\"}");
    defer outcome.deinit(alloc);
    try testing.expect(outcome.ok);
    try testing.expectEqualStrings("alpha\nbeta", outcome.text);
    try testing.expect(std.mem.indexOf(u8, outcome.raw_result_json, "\"image\"") != null);

    const sent = try h.drainSent(alloc);
    defer alloc.free(sent);
    try testing.expect(std.mem.indexOf(u8, sent, "\"method\":\"tools/call\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"arguments\":{\"msg\":\"hi\"}") != null);
}

test "callTool surfaces rpc-level errors" {
    const alloc = testing.allocator;
    var h = try FakeHarness.setup(alloc);
    defer h.teardown();

    const wire = try jsonrpc.encodeError(alloc, 0, -32601, "No such tool");
    defer alloc.free(wire);
    try h.script(&.{wire});

    var outcome = try h.client.callTool("ghost", "");
    defer outcome.deinit(alloc);
    try testing.expect(!outcome.ok);
    try testing.expectEqualStrings("No such tool", outcome.text);
    try testing.expectEqualStrings("", outcome.raw_result_json);
}

test "callTool flags tool-level errors via isError" {
    const alloc = testing.allocator;
    var h = try FakeHarness.setup(alloc);
    defer h.teardown();

    const wire = try jsonrpc.encodeResult(alloc, 0, "{\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],\"isError\":true}");
    defer alloc.free(wire);
    try h.script(&.{wire});

    var outcome = try h.client.callTool("fragile", "{}");
    defer outcome.deinit(alloc);
    try testing.expect(!outcome.ok);
    try testing.expectEqualStrings("boom", outcome.text);
}

test "notifications stash during calls; stale ids ignored" {
    const alloc = testing.allocator;
    var h = try FakeHarness.setup(alloc);
    defer h.teardown();

    const fine_wire = try jsonrpc.encodeResult(alloc, 0, "{\"content\":[{\"type\":\"text\",\"text\":\"fine\"}]}");
    defer alloc.free(fine_wire);
    try h.script(&.{
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":{\"stale\":true}}",
        fine_wire,
    });

    var outcome = try h.client.callTool("echo", "{}");
    defer outcome.deinit(alloc);
    try testing.expect(outcome.ok);
    try testing.expectEqualStrings("fine", outcome.text);
    try testing.expectEqual(@as(usize, 1), h.client.pendingNotificationCount());

    const notifs = try h.client.takeNotifications();
    defer {
        for (notifs) |*n| n.deinit(alloc);
        alloc.free(notifs);
    }
    try testing.expectEqualStrings("notifications/message", notifs[0].method);
    try testing.expectEqualStrings("{\"level\":\"info\"}", notifs[0].params_json);
    try testing.expectEqual(@as(usize, 0), h.client.pendingNotificationCount());
}

test "silent server times out without hanging" {
    const alloc = testing.allocator;
    var h = try FakeHarness.setup(alloc);
    defer h.teardown();

    h.client.timeout_ms = 60; // keep the test fast
    try testing.expectError(error.Timeout, h.client.callTool("echo", "{}"));
}

test "clean EOF surfaces ConnectionClosed" {
    const alloc = testing.allocator;
    var h = try FakeHarness.setup(alloc);
    defer h.teardown();

    h.closeWriteEnd(); // fake server exits before answering
    try testing.expectError(error.ConnectionClosed, h.client.callTool("echo", "{}"));
}

test "pump sweeps standalone notifications" {
    const alloc = testing.allocator;
    var h = try FakeHarness.setup(alloc);
    defer h.teardown();

    try h.script(&.{
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}",
        "not json at all", // malformed line tolerated
    });
    try h.client.pump(30);
    try testing.expectEqual(@as(usize, 1), h.client.pendingNotificationCount());
    const notifs = try h.client.takeNotifications();
    defer {
        for (notifs) |*n| n.deinit(alloc);
        alloc.free(notifs);
    }
    try testing.expectEqualStrings("notifications/tools/list_changed", notifs[0].method);
}

test "invalid arguments rejected before any I/O" {
    const alloc = testing.allocator;
    var h = try FakeHarness.setup(alloc);
    defer h.teardown();

    try testing.expectError(error.InvalidArguments, h.client.callTool("echo", "{bad"));
    try testing.expectError(error.InvalidArguments, h.client.callTool("echo", "[1]"));
}
