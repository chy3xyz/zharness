//! Structured observability events (dev.md §XXX).
//!
//! Every notable harness moment becomes an `EventEnvelope` serialized as ONE
//! JSON line and appended to a JSONL log (default
//! `.zharness/logs/events.jsonl`). Envelopes carry W3C-style correlation ids:
//! a 16-hex-char trace id shared by one agent run and an 8-hex-char span id
//! fresh per emit point.
//!
//! Integration contract:
//!   - main.zig owns one `JsonlSink` (path from config) and hands it down.
//!   - The agent loop calls `emit(&sink, io, &ctx, "tool.started", payload)`
//!     at its emit points (`agent.started` / `agent.stopped`,
//!     `model.request` / `model.response`, `tool.started` / `tool.completed`
//!     / `tool.failed`, `session.created` / `session.resumed`, ...).
//!   - Observability NEVER breaks the run: emit failures are swallowed and
//!     counted in `JsonlSink.dropped_events`.
//!
//! Filtering is deliberately simple: a minimum `Level` gate plus an optional
//! allow-list of event types (exact match, or dotted prefix such as "tool."
//! matching "tool.started").
//!
//! 0.17 notes: `std.time.nanoTimestamp` and `std.crypto.random` are gone;
//! wall-clock ms come from the Io real clock and id bytes from `io.random`
//! (the Io interface's OS-backed CSPRNG source). Writes are open-append-
//! close per event (no long-lived fd); the parent directory is created on
//! demand (mkdir -p semantics via `createDirPath`). Appends target the file
//! end via length + positional write — single-process by design, so no
//! O_APPEND inter-process locking is attempted.
//!
//! Live fan-out (`fanout`, dev.md §XXX ↔ §XXIII SSE bridge): an OPTIONAL
//! function pointer invoked from `JsonlSink.emitAt` after the jsonl append,
//! handing the serialized envelope line to a second sink (the serve-mode
//! broadcast hub in server/events.zig). It is ADDITIVE: null by default, so
//! CLI run/chat keep pure-jsonl logging and every existing caller is
//! source-compatible. See the `fanout` doc below for the threading rules.
//!
//! Deliberately self-contained (JSON helpers adapted from
//! src/session/checkpoint.zig): testable in isolation via
//! `zig test -lc src/_t_obs.zig`.

const std = @import("std");

pub const default_log_path = ".zharness/logs/events.jsonl";

/// Optional live fan-out hook (dev.md §XXX SSE feed). When non-null,
/// `JsonlSink.emitAt` calls it AFTER the jsonl append attempt, passing the
/// exact serialized envelope line WITHOUT trailing newline — the same bytes
/// the sink appends to disk (plus '\n'). Serve mode sets it once at startup
/// (`obs.fanout = &server_events.hubPublish`); CLI run/chat leave it null so
/// logging stays pure-jsonl with zero overhead.
///
/// Threading: a plain variable, deliberately not atomic. Assign it during
/// startup BEFORE any emitting thread exists (the httpd accept loop's spawn
/// establishes the happens-before edge). The callee must be thread-safe:
/// emitAt may run on any connection thread. Fan-out failures are invisible
/// here by design — observability never breaks the run.
pub var fanout: ?*const fn (envelope_json: []const u8) void = null;

/// trace_id length in ASCII hex chars (8 random bytes encoded).
pub const trace_id_hex_len = 16;
/// span_id length in ASCII hex chars (4 random bytes encoded).
pub const span_id_hex_len = 8;

pub const TraceId = [trace_id_hex_len]u8;
pub const SpanId = [span_id_hex_len]u8;

/// Severity attached at emit time (the wire envelope stays level-free, as
/// in dev.md §XXX). Ordered; `min_level` filtering compares ranks.
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub const Error = error{UnknownLevel};

    /// Strict lowercase parsing; accepts the spelled-out "error" alias.
    pub fn fromString(s: []const u8) Error!Level {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "err")) return .err;
        return error.UnknownLevel;
    }

    pub fn asStr(self: Level) []const u8 {
        return @tagName(self);
    }
};

/// True when `filters` is empty (allow-all) or contains an entry equal to
/// `event_type` or a dotted prefix of it ("tool." allows "tool.started").
pub fn eventTypeAllowed(filters: []const []const u8, event_type: []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |f| {
        if (f.len == 0) continue;
        if (std.mem.eql(u8, f, event_type)) return true;
        if (f[f.len - 1] == '.' and std.mem.startsWith(u8, event_type, f)) return true;
    }
    return false;
}

/// Fresh trace id (lowercase hex) from the Io CSPRNG source.
pub fn newTraceId(io: std.Io) TraceId {
    var raw: [trace_id_hex_len / 2]u8 = undefined;
    io.random(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

/// Fresh span id (lowercase hex) from the Io CSPRNG source.
pub fn newSpanId(io: std.Io) SpanId {
    var raw: [span_id_hex_len / 2]u8 = undefined;
    io.random(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

/// Correlation context for one agent run. `session_id` / `agent_id` are
/// borrowed (caller-owned, typically process-lifetime strings); ids are
/// generated from the Io passed to each call, so the context itself stays
/// allocation-free and trivially copyable.
pub const TraceCtx = struct {
    trace_id: TraceId,
    session_id: []const u8,
    agent_id: []const u8,

    /// Start a new trace rooted in this context.
    pub fn start(io: std.Io, session_id: []const u8, agent_id: []const u8) TraceCtx {
        return .{
            .trace_id = newTraceId(io),
            .session_id = session_id,
            .agent_id = agent_id,
        };
    }

    /// Fresh span under this context's trace (one per emit point). The
    /// context participates only in namespacing; id bytes come from `io`.
    pub fn newSpan(self: *const TraceCtx, io: std.Io) SpanId {
        _ = self;
        return newSpanId(io);
    }
};

pub const EventEnvelope = struct {
    timestamp_unix_ms: i64,
    trace_id: TraceId,
    span_id: SpanId,
    session_id: []const u8,
    agent_id: []const u8,
    /// Dotted event name, e.g. "tool.completed" (dev.md §XXX vocabulary).
    event_type: []const u8,
    /// Pre-rendered JSON value embedded VERBATIM as the `payload` field
    /// (object, array, string, number, or null). Empty means `{}`.
    payload_json: []const u8,

    /// Serialize as one JSON object WITHOUT trailing newline.
    pub fn appendJson(self: *const EventEnvelope, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(alloc, "{\"timestamp_unix_ms\":");
        try appendInt(alloc, out, self.timestamp_unix_ms);
        try out.appendSlice(alloc, ",\"trace_id\":\"");
        try out.appendSlice(alloc, self.trace_id[0..]);
        try out.appendSlice(alloc, "\",\"span_id\":\"");
        try out.appendSlice(alloc, self.span_id[0..]);
        try out.appendSlice(alloc, "\",\"session_id\":\"");
        try escapeInto(alloc, self.session_id, out);
        try out.appendSlice(alloc, "\",\"agent_id\":\"");
        try escapeInto(alloc, self.agent_id, out);
        try out.appendSlice(alloc, "\",\"event_type\":\"");
        try escapeInto(alloc, self.event_type, out);
        try out.appendSlice(alloc, "\",\"payload\":");
        try appendPayload(alloc, self.payload_json, out);
        try out.appendSlice(alloc, "}");
    }

    /// Heap-allocated serialization; caller frees.
    pub fn toJson(self: *const EventEnvelope, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try self.appendJson(alloc, &out);
        return out.toOwnedSlice(alloc);
    }
};

/// Decoded envelope with owned strings (free via deinit).
pub const ParsedEnvelope = struct {
    timestamp_unix_ms: i64,
    trace_id: TraceId,
    span_id: SpanId,
    session_id: []u8,
    agent_id: []u8,
    event_type: []u8,
    /// Verbatim payload slice as stored on the line (sanitized form).
    payload_json: []u8,

    pub fn deinit(self: *const ParsedEnvelope, alloc: std.mem.Allocator) void {
        alloc.free(self.session_id);
        alloc.free(self.agent_id);
        alloc.free(self.event_type);
        alloc.free(self.payload_json);
    }
};

pub const EnvelopeParseError = error{ MalformedEnvelope, OutOfMemory };

/// Parse one JSON line produced by `EventEnvelope.toJson` /
/// `JsonlSink.write`. Field order is writer-defined; every field is located
/// by key at object depth 0 (values containing decoy `"key":` substrings
/// cannot shadow real fields). Payload is matched generically (object,
/// array, string, number, null) and returned verbatim.
pub fn parseEnvelope(alloc: std.mem.Allocator, line_in: []const u8) EnvelopeParseError!ParsedEnvelope {
    const line = std.mem.trim(u8, line_in, " \t\r\n");
    if (line.len < 2 or line[0] != '{' or line[line.len - 1] != '}') return error.MalformedEnvelope;

    var env = ParsedEnvelope{
        .timestamp_unix_ms = 0,
        .trace_id = undefined,
        .span_id = undefined,
        .session_id = try alloc.dupe(u8, ""),
        .agent_id = try alloc.dupe(u8, ""),
        .event_type = try alloc.dupe(u8, ""),
        .payload_json = try alloc.dupe(u8, ""),
    };
    errdefer env.deinit(alloc);

    env.timestamp_unix_ms = try parseTimestamp(line);

    const trace_val = flatObjectValue(line, "trace_id") orelse return error.MalformedEnvelope;
    const trace_raw = quotedContent(trace_val) orelse return error.MalformedEnvelope;
    if (trace_raw.len != trace_id_hex_len or !isLowerHex(trace_raw)) return error.MalformedEnvelope;
    @memcpy(env.trace_id[0..], trace_raw);

    const span_val = flatObjectValue(line, "span_id") orelse return error.MalformedEnvelope;
    const span_raw = quotedContent(span_val) orelse return error.MalformedEnvelope;
    if (span_raw.len != span_id_hex_len or !isLowerHex(span_raw)) return error.MalformedEnvelope;
    @memcpy(env.span_id[0..], span_raw);

    if (try extractOwnedString(alloc, line, "session_id")) |s| {
        alloc.free(env.session_id);
        env.session_id = s;
    } else return error.MalformedEnvelope;

    if (try extractOwnedString(alloc, line, "agent_id")) |s| {
        alloc.free(env.agent_id);
        env.agent_id = s;
    } else return error.MalformedEnvelope;

    if (try extractOwnedString(alloc, line, "event_type")) |s| {
        alloc.free(env.event_type);
        env.event_type = s;
    } else return error.MalformedEnvelope;

    const payload = flatObjectValue(line, "payload") orelse return error.MalformedEnvelope;
    alloc.free(env.payload_json);
    env.payload_json = try alloc.dupe(u8, payload);

    return env;
}

// ── JSONL sink ──────────────────────────────────────────────────────────────

/// Append-only JSONL event log. One instance per destination; separate
/// instances pointed at the same path append cooperatively (each event is a
/// single open-append-close cycle).
pub const JsonlSink = struct {
    alloc: std.mem.Allocator,
    /// Owned destination path; parents are created on demand.
    path: []u8,
    /// Events below this rank are dropped before touching the filesystem.
    min_level: Level = .debug,
    /// Empty = allow all; entries match exactly or as dotted prefix.
    type_filters: []const []const u8 = &.{},
    /// Count of events swallowed by emit-path failures (disk full, bad
    /// path, ...). Purely informational — emitting never fails.
    dropped_events: usize = 0,

    pub fn init(alloc: std.mem.Allocator, path: []const u8) !JsonlSink {
        return .{
            .alloc = alloc,
            .path = try alloc.dupe(u8, path),
        };
    }

    pub fn deinit(self: *JsonlSink) void {
        self.alloc.free(self.path);
    }

    pub fn accepts(self: *const JsonlSink, level: Level, event_type: []const u8) bool {
        if (@backingInt(level) < @backingInt(self.min_level)) return false;
        return eventTypeAllowed(self.type_filters, event_type);
    }

    /// Fallible core: serialize + append one envelope as a single line.
    pub fn write(self: *JsonlSink, io: std.Io, env: EventEnvelope) !void {
        const body = try env.toJson(self.alloc);
        defer self.alloc.free(body);
        try self.appendSerialized(io, body);
    }

    /// Log-and-continue emit: builds a fresh span under `ctx.trace_id`,
    /// applies the filter, appends, and converts any failure into a bump of
    /// `dropped_events`. This is the hook the agent loop should call.
    ///
    /// Serialization happens exactly ONCE: the same line goes to disk AND
    /// (when `fanout` is installed) to the live feed, so both sinks observe
    /// byte-identical envelopes. The fan-out hook fires after the jsonl
    /// append attempt regardless of its outcome — the live stream must not
    /// depend on disk health.
    pub fn emitAt(
        self: *JsonlSink,
        io: std.Io,
        ctx: *const TraceCtx,
        level: Level,
        event_type: []const u8,
        payload_json: []const u8,
    ) void {
        if (!self.accepts(level, event_type)) return;
        const env = EventEnvelope{
            .timestamp_unix_ms = nowMs(io),
            .trace_id = ctx.trace_id,
            .span_id = ctx.newSpan(io),
            .session_id = ctx.session_id,
            .agent_id = ctx.agent_id,
            .event_type = event_type,
            .payload_json = payload_json,
        };
        const body = env.toJson(self.alloc) catch {
            self.dropped_events += 1;
            return;
        };
        defer self.alloc.free(body);

        self.appendSerialized(io, body) catch {
            self.dropped_events += 1;
        };
        if (fanout) |hook| hook(body);
    }

    /// Shared tail of `write` / `emitAt`: JSONL-frame one pre-serialized
    /// envelope body (append '\n', positional-append to file end).
    fn appendSerialized(self: *JsonlSink, io: std.Io, body: []const u8) !void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        try line.appendSlice(self.alloc, body);
        try line.append(self.alloc, '\n');
        try self.appendBytes(io, line.items);
    }

    /// Open-append-close one pre-serialized line (newline included).
    fn appendBytes(self: *JsonlSink, io: std.Io, bytes: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        var file: std.Io.File = undefined;
        if (std.mem.lastIndexOfScalar(u8, self.path, '/')) |slash| {
            const parent = self.path[0..slash];
            const name = self.path[slash + 1 ..];
            // mkdir -p semantics; missing parents are created, existing
            // ones tolerated.
            try std.Io.Dir.createDirPath(cwd, io, parent);
            var dir = try std.Io.Dir.openDir(cwd, io, parent, .{});
            defer std.Io.Dir.close(dir, io);
            file = try dir.createFile(io, name, .{ .truncate = false });
        } else {
            file = try cwd.createFile(io, self.path, .{ .truncate = false });
        }
        defer file.close(io);
        const end = try file.length(io);
        try file.writePositionalAll(io, bytes, end);
    }
};

/// Convenience one-liner for the agent loop: info-level emit with a fresh
/// span. Never fails (see `JsonlSink.emitAt`).
pub fn emit(
    sink: *JsonlSink,
    io: std.Io,
    ctx: *const TraceCtx,
    event_type: []const u8,
    payload_json: []const u8,
) void {
    sink.emitAt(io, ctx, .info, event_type, payload_json);
}

// ── internals ───────────────────────────────────────────────────────────────

/// Wall-clock milliseconds via the Io real clock (`std.time.nanoTimestamp`
/// no longer exists in 0.17).
fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

/// Embed the payload verbatim while keeping JSONL single-line framing:
/// literal '\n' / '\r' bytes become spaces. Valid JSON is unaffected (legal
/// strings already escape control characters, so raw newlines can only be
/// inter-token whitespace). Empty payloads become `{}`.
fn appendPayload(alloc: std.mem.Allocator, payload: []const u8, out: *std.ArrayList(u8)) !void {
    if (payload.len == 0) {
        try out.appendSlice(alloc, "{}");
        return;
    }
    for (payload) |c| {
        try out.append(alloc, if (c == '\n' or c == '\r') ' ' else c);
    }
}

fn isLowerHex(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

fn appendInt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: anytype) !void {
    var b: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{d}", .{v}) catch return;
    try out.appendSlice(alloc, s);
}

/// Adapted from src/session/checkpoint.zig escapeInto.
fn escapeInto(alloc: std.mem.Allocator, input: []const u8, buf: *std.ArrayList(u8)) !void {
    for (input) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
}

/// Adapted from src/session/checkpoint.zig unescapeInto.
fn unescapeInto(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            switch (input[i]) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                '/' => try out.append(alloc, '/'),
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                't' => try out.append(alloc, '\t'),
                else => try out.append(alloc, input[i]),
            }
        } else {
            try out.append(alloc, input[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Inner content of a JSON-string value slice (strip the delimiting
/// quotes); null when `raw` is not a quoted string.
fn quotedContent(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return raw[1 .. raw.len - 1];
}

/// Decoded copy of a top-level string value; caller frees. Null when absent
/// or not a JSON string.
fn extractOwnedString(alloc: std.mem.Allocator, hay: []const u8, key: []const u8) !?[]u8 {
    const raw = flatObjectValue(hay, key) orelse return null;
    const inner = quotedContent(raw) orelse return null;
    return try unescapeInto(alloc, inner);
}

/// Byte-position-free flat-object lookup: walk `{k:v,k:v}` fields in order,
/// skipping strings and nested structures correctly, and return the RAW
/// value slice for `key`. Values inside earlier fields cannot shadow later
/// ones because parsing is positional, not substring-based.
fn flatObjectValue(hay: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < hay.len and (hay[i] == ' ' or hay[i] == '\t')) : (i += 1) {}
    if (i >= hay.len or hay[i] != '{') return null;
    i += 1;

    while (true) {
        while (i < hay.len and (hay[i] == ' ' or hay[i] == '\t')) : (i += 1) {}
        if (i >= hay.len) return null;
        if (hay[i] == '}') return null; // end of object, key absent

        // Key: quoted string.
        if (hay[i] != '"') return null;
        const kraw_end = findStringEnd(hay, i + 1) orelse return null;
        const kraw = hay[i + 1 .. kraw_end];
        i = kraw_end + 1;

        while (i < hay.len and (hay[i] == ' ' or hay[i] == '\t')) : (i += 1) {}
        if (i >= hay.len or hay[i] != ':') return null;
        i += 1;
        while (i < hay.len and (hay[i] == ' ' or hay[i] == '\t')) : (i += 1) {}
        if (i >= hay.len) return null;

        // Value: string (consume through closing quote) or any other token
        // (stop at depth-0 ',' or the object-closing '}').
        const vs = i;
        if (hay[i] == '"') {
            i = (findStringEnd(hay, i + 1) orelse return null) + 1;
        } else {
            var depth: i32 = 0;
            while (i < hay.len) : (i += 1) {
                const c = hay[i];
                switch (c) {
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        if (depth == 0) break;
                        depth -= 1;
                    },
                    ',' => if (depth == 0) break,
                    else => {},
                }
            }
            if (i > hay.len) return null;
        }

        if (std.mem.eql(u8, kraw, key)) return std.mem.trim(u8, hay[vs..i], " \t");

        while (i < hay.len and (hay[i] == ' ' or hay[i] == '\t')) : (i += 1) {}
        if (i >= hay.len or hay[i] != ',') return null; // '}' / junk ends scan
        i += 1;
    }
}

/// Index of the closing quote of the string whose CONTENT starts at
/// `content_start`; handles backslash escapes. Null when unterminated.
fn findStringEnd(hay: []const u8, content_start: usize) ?usize {
    var i = content_start;
    while (i < hay.len) : (i += 1) {
        if (hay[i] == '\\') {
            i += 1;
            continue;
        }
        if (hay[i] == '"') return i;
    }
    return null;
}

fn parseUintSlice(s: []const u8) ?i128 {
    if (s.len == 0) return null;
    var neg = false;
    var v: i128 = 0;
    var i: usize = 0;
    if (s[0] == '-') {
        neg = true;
        i = 1;
        if (s.len == 1) return null;
    }
    for (s[i..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
        if (v > 1 << 100) return null;
    }
    return if (neg) -v else v;
}

fn parseTimestamp(line: []const u8) EnvelopeParseError!i64 {
    const raw = flatObjectValue(line, "timestamp_unix_ms") orelse return error.MalformedEnvelope;
    const v = parseUintSlice(raw) orelse return error.MalformedEnvelope;
    if (v > std.math.maxInt(i64) or v < std.math.minInt(i64)) return error.MalformedEnvelope;
    return @intCast(v);
}

// ── tests ───────────────────────────────────────────────────────────────────

extern "c" fn time(tloc: ?*c_long) c_long;

/// Seconds since epoch (libc time(2)); used only for unique temp dirs.
fn nowSecs() i64 {
    return @intCast(time(null));
}

var env_counter: u32 = 0;

/// Unique per-test scratch directory, torn down wholesale. Same pattern as
/// src/session/checkpoint.zig's TestEnv (Threaded must own a threadsafe
/// allocator for its internal machinery; test allocations stay on the
/// testing allocator).
const TestEnv = struct {
    t: std.Io.Threaded,
    dir: []u8,

    fn setup(alloc: std.mem.Allocator) !TestEnv {
        env_counter += 1;
        const t = std.Io.Threaded.init(std.heap.page_allocator, .{});
        return .{
            .t = t,
            .dir = try std.fmt.allocPrint(alloc, "/tmp/zh_obs_{d}_{d}", .{ nowSecs(), env_counter }),
        };
    }
    fn io(self: *TestEnv) std.Io {
        return self.t.io();
    }
    fn teardown(self: *TestEnv, alloc: std.mem.Allocator) void {
        defer self.t.deinit();
        defer alloc.free(self.dir);
        const slash = std.mem.lastIndexOfScalar(u8, self.dir, '/') orelse return;
        const cwd = std.Io.Dir.cwd();
        const parent = std.Io.Dir.openDir(cwd, self.io(), self.dir[0..slash], .{}) catch return;
        defer std.Io.Dir.close(parent, self.io());
        std.Io.Dir.deleteTree(parent, self.io(), self.dir[slash + 1 ..]) catch {};
    }
};

test "envelope serializes and round-trips field-equal" {
    const alloc = std.testing.allocator;

    const env = EventEnvelope{
        .timestamp_unix_ms = 1755900000123,
        .trace_id = "0123456789abcdef".*,
        .span_id = "a1b2c3d4".*,
        .session_id = "sess \"quoted\"\nline",
        .agent_id = "main-agent",
        .event_type = "tool.completed",
        .payload_json = "{\"tool\":\"shell\",\"exit\":{\"code\":0},\"note\":\"ok \\ end\"}",
    };

    const line = try env.toJson(alloc);
    defer alloc.free(line);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null); // single line

    var got = try parseEnvelope(alloc, line);
    defer got.deinit(alloc);

    try std.testing.expectEqual(env.timestamp_unix_ms, got.timestamp_unix_ms);
    try std.testing.expectEqualStrings(env.trace_id[0..], got.trace_id[0..]);
    try std.testing.expectEqualStrings(env.span_id[0..], got.span_id[0..]);
    try std.testing.expectEqualStrings(env.session_id, got.session_id);
    try std.testing.expectEqualStrings(env.agent_id, got.agent_id);
    try std.testing.expectEqualStrings(env.event_type, got.event_type);
    try std.testing.expectEqualStrings(env.payload_json, got.payload_json);
}

test "multiline payload is sanitized to keep JSONL framing" {
    const alloc = std.testing.allocator;

    const env = EventEnvelope{
        .timestamp_unix_ms = 42,
        .trace_id = "ffffffffffffffff".*,
        .span_id = "00000001".*,
        .session_id = "s",
        .agent_id = "a",
        .event_type = "model.chunk",
        // Raw newlines between tokens are legal JSON whitespace; the writer
        // flattens them so the envelope stays one line.
        .payload_json = "{\n  \"k\": \"v\",\r\n  \"n\": 7\n}",
    };

    const line = try env.toJson(alloc);
    defer alloc.free(line);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);

    var got = try parseEnvelope(alloc, line);
    defer got.deinit(alloc);
    try std.testing.expectEqualStrings("{   \"k\": \"v\",    \"n\": 7 }", got.payload_json);
}

test "malformed envelopes rejected" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MalformedEnvelope, parseEnvelope(alloc, ""));
    try std.testing.expectError(error.MalformedEnvelope, parseEnvelope(alloc, "not json"));
    try std.testing.expectError(error.MalformedEnvelope, parseEnvelope(alloc, "{}"));
    // Wrong trace/span lengths rejected.
    try std.testing.expectError(error.MalformedEnvelope, parseEnvelope(alloc,
        \\{"timestamp_unix_ms":1,"trace_id":"short","span_id":"a1b2c3d4","session_id":"s","agent_id":"a","event_type":"e","payload":null}
    ));
    // Decoy key inside session_id must not shadow the real payload field.
    var got = try parseEnvelope(alloc,
        \\{"timestamp_unix_ms":1,"trace_id":"0123456789abcdef","span_id":"a1b2c3d4","session_id":"decoy\",\"payload\":{\"fake\":1}","agent_id":"a","event_type":"e","payload":{"real":2}}
    );
    defer got.deinit(alloc);
    try std.testing.expectEqualStrings("{\"real\":2}", got.payload_json);
}

test "trace and span ids unique across many draws" {
    var tenv = try TestEnv.setup(std.testing.allocator);
    defer tenv.teardown(std.testing.allocator);
    const io = tenv.io();

    const n = 256;
    var ids: [n]TraceId = undefined;
    var spans: [n]SpanId = undefined;
    for (0..n) |i| {
        ids[i] = newTraceId(io);
        spans[i] = newSpanId(io);
    }
    for (0..n) |i| {
        for (i + 1..n) |j| {
            try std.testing.expect(!std.mem.eql(u8, ids[i][0..], ids[j][0..]));
            try std.testing.expect(!std.mem.eql(u8, spans[i][0..], spans[j][0..]));
        }
    }
    // Shape sanity: lowercase hex, fixed widths.
    try std.testing.expect(isLowerHex(ids[0][0..]));
    try std.testing.expect(isLowerHex(spans[0][0..]));
}

test "level gate and dotted type filters" {
    const alloc = std.testing.allocator;
    var sink = try JsonlSink.init(alloc, "/unused/events.jsonl");
    defer sink.deinit();

    // Default: everything passes.
    try std.testing.expect(sink.accepts(.debug, "anything"));
    try std.testing.expect(sink.accepts(.err, "anything"));

    sink.min_level = .warn;
    try std.testing.expect(!sink.accepts(.debug, "tool.started"));
    try std.testing.expect(!sink.accepts(.info, "tool.started"));
    try std.testing.expect(sink.accepts(.warn, "tool.failed"));
    try std.testing.expect(sink.accepts(.err, "tool.failed"));

    sink.min_level = .debug;
    sink.type_filters = &.{ "tool.", "agent.started" };
    try std.testing.expect(sink.accepts(.info, "tool.started"));
    try std.testing.expect(sink.accepts(.info, "tool.failed"));
    try std.testing.expect(sink.accepts(.info, "agent.started"));
    try std.testing.expect(!sink.accepts(.info, "agent.stopped"));
    try std.testing.expect(!sink.accepts(.info, "model.response"));

    try std.testing.expectEqual(Level.err, try Level.fromString("error"));
    try std.testing.expectEqual(Level.debug, try Level.fromString("debug"));
    try std.testing.expectError(error.UnknownLevel, Level.fromString("verbose"));
}

test "sink creates missing dirs and appends across instances" {
    const alloc = std.testing.allocator;
    var tenv = try TestEnv.setup(alloc);
    defer tenv.teardown(alloc);
    const io = tenv.io();

    const path = try std.fmt.allocPrint(alloc, "{s}/logs/deep/events.jsonl", .{tenv.dir});
    defer alloc.free(path);

    var ctx = TraceCtx.start(io, "sess-1", "agent-main");

    var first = try JsonlSink.init(alloc, path);
    defer first.deinit();
    first.emitAt(io, &ctx, .info, "agent.started", "{\"turns\":0}");
    first.emitAt(io, &ctx, .warn, "tool.failed", "{\"tool\":\"grep\"}");
    try std.testing.expectEqual(@as(usize, 0), first.dropped_events);

    // A second, independent sink instance continues the same file.
    var second = try JsonlSink.init(alloc, path);
    defer second.deinit();
    second.type_filters = &.{"model."}; // drops nothing here, proves filter wiring
    second.emitAt(io, &ctx, .info, "model.response", "{\"tokens\":11}");

    const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
    const cwd = std.Io.Dir.cwd();
    const dir = try std.Io.Dir.openDir(cwd, io, path[0..slash], .{});
    defer std.Io.Dir.close(dir, io);
    const raw = try std.Io.Dir.readFileAlloc(dir, io, path[slash + 1 ..], alloc, .limited(1 << 20));
    defer alloc.free(raw);

    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    var saw_started = false;
    var saw_failed = false;
    var saw_response = false;
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        lines += 1;
        var got = try parseEnvelope(alloc, ln);
        defer got.deinit(alloc);
        if (std.mem.eql(u8, got.event_type, "agent.started")) saw_started = true;
        if (std.mem.eql(u8, got.event_type, "tool.failed")) saw_failed = true;
        if (std.mem.eql(u8, got.event_type, "model.response")) saw_response = true;
    }
    try std.testing.expectEqual(@as(usize, 3), lines);
    try std.testing.expect(saw_started and saw_failed and saw_response);
}

test "emit swallows IO failures into dropped_events" {
    const alloc = std.testing.allocator;
    var tenv = try TestEnv.setup(alloc);
    defer tenv.teardown(alloc);
    const io = tenv.io();

    // A regular FILE where a directory is required: mkdir/open must fail.
    const blocker = try std.fmt.allocPrint(alloc, "{s}/blocker", .{tenv.dir});
    defer alloc.free(blocker);
    const cwd = std.Io.Dir.cwd();
    try std.Io.Dir.createDirPath(cwd, io, tenv.dir); // base dir must exist first
    try cwd.writeFile(io, .{ .sub_path = blocker, .data = "not a dir" });

    const path = try std.fmt.allocPrint(alloc, "{s}/inner/events.jsonl", .{blocker});
    defer alloc.free(path);

    var sink = try JsonlSink.init(alloc, path);
    defer sink.deinit();
    var ctx = TraceCtx.start(io, "s", "a");

    // Must not throw; failure recorded instead.
    emit(&sink, io, &ctx, "agent.started", "{}");
    try std.testing.expectEqual(@as(usize, 1), sink.dropped_events);

    // Filtered-out events neither touch disk nor count as drops.
    sink.type_filters = &.{"model."};
    sink.emitAt(io, &ctx, .info, "agent.stopped", "{}");
    try std.testing.expectEqual(@as(usize, 1), sink.dropped_events);
}
