//! Minimal OpenTelemetry (OTLP/JSON) span export.
//!
//! zharness already logs structured events through the observability sink
//! (obsEmit). This module mirrors those events as OTLP resourceSpans JSON
//! lines so an external collector can ingest them. Opt-in via the environment
//! variable ZHARNESS_OTEL_PATH (a file path); unset means no-op.

const std = @import("std");
const model = @import("../model/model.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn time(tloc: ?*c_long) c_long;

pub const Attr = struct { key: []const u8, value: []const u8 };

pub const Span = struct {
    name: []const u8,
    start_ms: i64,
    end_ms: i64,
    trace_id: [16]u8 = @splat(0),
    span_id: [8]u8 = @splat(0),
    attributes: []const Attr = &.{},
};

var g_seq: u64 = 0;

fn nowMs() i64 {
    return @as(i64, @intCast(time(null))) * 1000;
}

fn hex(buf: []u8, bytes: []const u8) void {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[i * 2] = digits[b >> 4];
        buf[i * 2 + 1] = digits[b & 0xf];
    }
}

fn appendAttr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, a: Attr) !void {
    try out.appendSlice(alloc, "{\"key\":\"");
    try out.appendSlice(alloc, a.key);
    try out.appendSlice(alloc, "\",\"value\":{\"stringValue\":\"");
    try model.escape(alloc, a.value, out);
    try out.appendSlice(alloc, "\"}}");
}

fn appendI128(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: i128) !void {
    var buf: [40]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return error.OutOfMemory;
    try out.appendSlice(alloc, s);
}

/// Encode spans as an OTLP/JSON resourceSpans document. Caller frees.
pub fn encodeResourceSpans(alloc: std.mem.Allocator, service: []const u8, spans: []const Span) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"");
    try model.escape(alloc, service, &out);
    try out.appendSlice(alloc, "\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"");
    try model.escape(alloc, service, &out);
    try out.appendSlice(alloc, "\"},\"spans\":[");
    for (spans, 0..) |sp, i| {
        if (i > 0) try out.append(alloc, ',');
        var tid: [32]u8 = undefined;
        var sid: [16]u8 = undefined;
        hex(&tid, &sp.trace_id);
        hex(&sid, &sp.span_id);
        try out.appendSlice(alloc, "{\"traceId\":\"");
        try out.appendSlice(alloc, &tid);
        try out.appendSlice(alloc, "\",\"spanId\":\"");
        try out.appendSlice(alloc, &sid);
        try out.appendSlice(alloc, "\",\"name\":\"");
        try model.escape(alloc, sp.name, &out);
        try out.appendSlice(alloc, "\",\"startTimeUnixNano\":\"");
        try appendI128(&out, alloc, @as(i128, sp.start_ms) * std.time.ns_per_ms);
        try out.appendSlice(alloc, "\",\"endTimeUnixNano\":\"");
        try appendI128(&out, alloc, @as(i128, sp.end_ms) * std.time.ns_per_ms);
        try out.appendSlice(alloc, "\",\"attributes\":[");
        for (sp.attributes, 0..) |a, j| {
            if (j > 0) try out.append(alloc, ',');
            try appendAttr(&out, alloc, a);
        }
        try out.appendSlice(alloc, "]}]");
    }
    try out.appendSlice(alloc, "]}]}]}");
    return out.toOwnedSlice(alloc);
}

/// Append one OTLP JSON line (best effort). No-op when path is null/empty.
pub fn appendSpanLine(io: std.Io, path: []const u8, line: []const u8) !void {
    const a = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, line);
    try buf.append(a, '\n');

    const cwd = std.Io.Dir.cwd();
    var file: std.Io.File = undefined;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        const parent = path[0..slash];
        const name = path[slash + 1 ..];
        if (parent.len == 0) {
            file = try cwd.createFile(io, name, .{ .truncate = false });
        } else {
            try std.Io.Dir.createDirPath(cwd, io, parent);
            var dir = try std.Io.Dir.openDir(cwd, io, parent, .{});
            defer std.Io.Dir.close(dir, io);
            file = try dir.createFile(io, name, .{ .truncate = false });
        }
    } else {
        file = try cwd.createFile(io, path, .{ .truncate = false });
    }
    defer file.close(io);
    const end = try file.length(io);
    try file.writePositionalAll(io, buf.items, end);
}

/// Export one event as a span when ZHARNESS_OTEL_PATH is set. Never fails
/// loudly: telemetry must not disturb the run.
pub fn emitEvent(event_name: []const u8, payload: []const u8) void {
    const path_ptr = getenv("ZHARNESS_OTEL_PATH") orelse return;
    const path = std.mem.span(path_ptr);
    if (path.len == 0) return;

    const alloc = std.heap.page_allocator;
    g_seq += 1;
    var sp = Span{
        .name = event_name,
        .start_ms = nowMs(),
        .end_ms = nowMs(),
        .attributes = &.{.{ .key = "event.detail", .value = payload }},
    };
    sp.span_id = @bitCast(g_seq);
    const doc = encodeResourceSpans(alloc, "zharness", &.{sp}) catch return;
    defer alloc.free(doc);
    const io = std.Io.Threaded.global_single_threaded.io();
    appendSpanLine(io, path, doc) catch {};
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "encodeResourceSpans emits a valid OTLP/JSON envelope" {
    const alloc = testing.allocator;
    var tid: [16]u8 = @splat(0);
    tid[15] = 0xab;
    var sid: [8]u8 = @splat(0);
    sid[7] = 0xcd;
    const sp = Span{
        .name = "tool.started",
        .start_ms = 1000,
        .end_ms = 1500,
        .trace_id = tid,
        .span_id = sid,
        .attributes = &.{.{ .key = "event.detail", .value = "hello \"world\"" }},
    };
    const doc = try encodeResourceSpans(alloc, "zharness", &.{sp});
    defer alloc.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"resourceSpans\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "service.name") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"name\":\"tool.started\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "000000000000000000000000000000ab") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "00000000000000cd") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "1500000000") != null); // 1500ms in ns
    try testing.expect(std.mem.indexOf(u8, doc, "\\\"world\\\"") != null);
}

test "appendSpanLine appends newline-delimited JSON" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = ".zig-cache/zh_otel_test.jsonl";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    try appendSpanLine(io, path, "{\"a\":1}");
    try appendSpanLine(io, path, "{\"b\":2}");
    const raw = try std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .unlimited);
    defer alloc.free(raw);
    try testing.expectEqualStrings("{\"a\":1}\n{\"b\":2}\n", raw);
}

test "emitEvent writes an OTLP line when ZHARNESS_OTEL_PATH is set" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = ".zig-cache/zh_otel_emit.jsonl";
    std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    _ = setenv("ZHARNESS_OTEL_PATH", path, 1);
    defer _ = unsetenv("ZHARNESS_OTEL_PATH");
    emitEvent("tool.started", "hello");
    const raw = try std.Io.Dir.readFileAlloc(.cwd(), io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "tool.started") != null);
    try testing.expect(std.mem.endsWith(u8, raw, "\n"));
}
