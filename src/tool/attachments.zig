//! Attachment inspection tools (wave 6 H-image): `attachment_list` and
//! `attachment_read`.
//!
//! Contract (mirrors tool/webfetch.zig):
//! - Two registerable `ToolDefinition`s matching the tool/registry.zig schema
//!   style, plus executors that are pure functions of (alloc, io, cwd,
//!   args_json) like the builtin executors in tool/builtin.zig — same
//!   ToolCall / ToolResult types, same ownership rules (`freeResult`).
//! - The store is `<cwd>/.zharness/attachments/<session>/*` as written by
//!   server/apiproxy/attachments.zig. `attachment_read` refuses paths outside
//!   that tree (same traversal posture as builtin file_read).
//!
//! What the agent learns about an image WITHOUT vision:
//!   path / media type (magic-byte sniffed) / byte size / pixel dimensions
//!   (header-parsed for png, gif, jpeg, webp) plus base64 content when small
//!   enough to be useful. This is the honest v1: text models can reason about
//!   provenance and metadata; actual pixels reach only vision-capable
//!   providers on the wire.
//!
//! Offline: every parser here is a pure function tested against fixture
//! bytes; the executors round-trip through a real temp store.

const std = @import("std");
const clib = @import("../clib.zig");
const apx_attachments = @import("../server/apiproxy/attachments.zig");
const builtin_tools = @import("builtin.zig");
const registry_mod = @import("registry.zig");

pub const ToolCall = builtin_tools.ToolCall;
pub const ToolResult = builtin_tools.ToolResult;
pub const freeResult = builtin_tools.freeResult;

/// Store root relative to the workspace cwd (matches the apiproxy default).
pub const attachments_dirname = ".zharness/attachments";

/// Cap on emitted base64 payload inside attachment_read output. The binary
/// is read whole (≤10MB) but base64 beyond this is elided with a note —
/// model context is scarcer than disk.
pub const max_embedded_base64_bytes: usize = 192 * 1024;

// ── registration ────────────────────────────────────────────────────────────

pub fn registerAttachments(reg: *registry_mod.ToolRegistry) !void {
    try reg.register(.{
        .name = "attachment_list",
        .description = "List image attachments stored from user prompts under .zharness/attachments. One line per file: path, sniffed media type, size.",
        .category = .filesystem,
        .parameters_json =
        \\{"type":"object","properties":{},"required":[]}
        ,
    });
    try reg.register(.{
        .name = "attachment_read",
        .description = "Inspect one stored image attachment: media type (magic-byte sniffed), size, pixel dimensions parsed from headers, and base64 content when it fits the output budget.",
        .category = .filesystem,
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path of the attachment (as shown by attachment_list or the [image attached: …] prompt note)"}},"required":["path"]}
        ,
    });
}

/// Dispatch a tool call to an attachment executor (mirror of
/// builtin.execute's shape). `io` backs the filesystem access.
pub fn execute(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    if (std.mem.eql(u8, call.name, "attachment_list")) return attachmentList(alloc, io, cwd);
    if (std.mem.eql(u8, call.name, "attachment_read")) return attachmentRead(alloc, io, cwd, call);
    // err_msg must be allocator-owned: callers release results via freeResult.
    return ToolResult{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, "unknown tool") };
}

// ── shared helpers ──────────────────────────────────────────────────────────

fn failMsg(alloc: std.mem.Allocator, msg: []const u8) !ToolResult {
    return ToolResult{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, msg) };
}

fn resolvePath(alloc: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = std.c.getenv("HOME") orelse return alloc.dupe(u8, path);
        const home_slice = std.mem.sliceTo(home, 0);
        return std.fs.path.resolve(alloc, &.{ home_slice, path[2..] });
    }
    return std.fs.path.resolve(alloc, &.{ cwd, path });
}

fn readFileCapped(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    return std.Io.Dir.readFileAlloc(cwd, io, path, alloc, .limited(apx_attachments.max_image_bytes + 1));
}

/// Pixel dimensions parsed from container headers. Null when the format's
/// header is malformed/truncated — metadata is best-effort by design.
pub const Dimensions = struct { width: u32, height: u32 };

/// Header dimension parser (pure): PNG IHDR, GIF logical screen, JPEG SOFn
/// scan, WebP VP8X/VP8 ' '/VP8L. Tested against fixture headers.
pub fn parseDimensions(mt: apx_attachments.MediaType, b: []const u8) ?Dimensions {
    switch (mt) {
        .png => {
            if (b.len < 24 or !std.mem.eql(u8, b[12..16], "IHDR")) return null;
            const w = std.mem.readInt(u32, b[16..20], .big);
            const h = std.mem.readInt(u32, b[20..24], .big);
            if (w == 0 or h == 0) return null;
            return .{ .width = w, .height = h };
        },
        .gif => {
            if (b.len < 10) return null;
            const w = std.mem.readInt(u16, b[6..8], .little);
            const h = std.mem.readInt(u16, b[8..10], .little);
            if (w == 0 or h == 0) return null;
            return .{ .width = w, .height = h };
        },
        .jpeg => {
            // Walk segment markers until a SOFn carries the dimensions.
            var i: usize = 2;
            while (i + 9 <= b.len) {
                if (b[i] != 0xFF) return null;
                const marker = b[i + 1];
                if (marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) {
                    i += 2;
                    continue;
                }
                if (i + 4 > b.len) return null;
                const seg_len: usize = (@as(usize, b[i + 2]) << 8) | b[i + 3];
                // SOF0-SOF15 except DHT(C4), JPG(C8), DAC(CC).
                if ((marker >= 0xC0 and marker <= 0xCF) and marker != 0xC4 and marker != 0xC8 and marker != 0xCC) {
                    if (i + 9 > b.len) return null;
                    const h: u32 = (@as(u32, b[i + 5]) << 8) | b[i + 6];
                    const w: u32 = (@as(u32, b[i + 7]) << 8) | b[i + 8];
                    if (w == 0 or h == 0) return null;
                    return .{ .width = w, .height = h };
                }
                if (seg_len < 2) return null;
                i += 2 + seg_len;
            }
            return null;
        },
        .webp => {
            if (b.len < 30 or !std.mem.eql(u8, b[0..4], "RIFF") or !std.mem.eql(u8, b[8..12], "WEBP")) return null;
            if (std.mem.eql(u8, b[12..16], "VP8X")) {
                // Canvas size minus one, 24-bit LE each at offset 24/27.
                if (b.len < 30) return null;
                const w: u32 = 1 + (@as(u32, b[24]) | (@as(u32, b[25]) << 8) | (@as(u32, b[26]) << 16));
                const h: u32 = 1 + (@as(u32, b[27]) | (@as(u32, b[28]) << 8) | (@as(u32, b[29]) << 16));
                return .{ .width = w, .height = h };
            }
            if (std.mem.eql(u8, b[12..16], "VP8 ")) {
                // Lossy keyframe: dims at frame tag+6, masked 14-bit LE.
                if (b.len < 30) return null;
                const w: u32 = @as(u32, std.mem.readInt(u16, b[26..28], .little)) & 0x3FFF;
                const h: u32 = @as(u32, std.mem.readInt(u16, b[28..30], .little)) & 0x3FFF;
                if (w == 0 or h == 0) return null;
                return .{ .width = w, .height = h };
            }
            if (std.mem.eql(u8, b[12..16], "VP8L")) {
                if (b.len < 25) return null;
                const bits = std.mem.readInt(u32, b[21..25], .little);
                const w: u32 = (bits & 0x3FFF) + 1;
                const h: u32 = ((bits >> 14) & 0x3FFF) + 1;
                return .{ .width = w, .height = h };
            }
            return null;
        },
    }
}

// ── attachment_list ─────────────────────────────────────────────────────────

fn attachmentList(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) !ToolResult {
    const root_abs = try resolvePath(alloc, cwd, attachments_dirname);
    defer alloc.free(root_abs);

    const root_h = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, root_abs, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return failMsg(alloc, "no attachments stored yet (.zharness/attachments does not exist)"),
        else => return failMsg(alloc, @errorName(e)),
    };
    defer std.Io.Dir.close(root_h, io);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // Session dirs first (collected so the iterating handle stays untouched),
    // then files within, via fresh handles per session dir.
    var sessions: std.ArrayList([]u8) = .empty;
    defer {
        for (sessions.items) |s| alloc.free(s);
        sessions.deinit(alloc);
    }
    var sit = root_h.iterate();
    while (sit.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        try sessions.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, sessions.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var count: usize = 0;
    for (sessions.items) |sid| {
        const sdir = root_h.openDir(io, sid, .{ .iterate = true }) catch continue;
        defer std.Io.Dir.close(sdir, io);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| alloc.free(n);
            names.deinit(alloc);
        }
        var fit = sdir.iterate();
        while (fit.next(io) catch null) |f| {
            if (f.kind == .directory) continue;
            try names.append(alloc, try alloc.dupe(u8, f.name));
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |n| {
            const rel = try std.fmt.allocPrint(alloc, attachments_dirname ++ "/{s}/{s}", .{ sid, n });
            defer alloc.free(rel);
            const abs = try resolvePath(alloc, cwd, rel);
            defer alloc.free(abs);
            const bytes = readFileCapped(alloc, io, abs) catch continue;
            defer alloc.free(bytes);
            const mt_desc = if (apx_attachments.sniffMediaType(bytes)) |mt| mt.iana() else "unknown";
            try out.appendSlice(alloc, rel);
            try out.append(alloc, '\t');
            try out.appendSlice(alloc, mt_desc);
            try out.print(alloc, "\t{d} bytes\n", .{bytes.len});
            count += 1;
        }
    }

    if (count == 0) return failMsg(alloc, "no attachments stored yet");
    return ToolResult{ .success = true, .output = try out.toOwnedSlice(alloc) };
}

// ── attachment_read ─────────────────────────────────────────────────────────

fn attachmentRead(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = try builtin_tools.parseArgs(alloc, call.arguments);
    defer builtin_tools.freeArgs(alloc, &map);
    const raw_path = map.get("path") orelse return failMsg(alloc, "missing path");

    const resolved = try resolvePath(alloc, cwd, raw_path);
    defer alloc.free(resolved);

    // Containment: only files under the attachment store are readable here.
    const root_abs = try resolvePath(alloc, cwd, attachments_dirname);
    defer alloc.free(root_abs);
    const root_prefix = try std.fmt.allocPrint(alloc, "{s}/", .{root_abs});
    defer alloc.free(root_prefix);
    if (!std.mem.startsWith(u8, resolved, root_prefix)) {
        return failMsg(alloc, "path is outside the attachment store");
    }

    const bytes = readFileCapped(alloc, io, resolved) catch |e| switch (e) {
        error.FileNotFound => return failMsg(alloc, "attachment not found"),
        error.FileTooBig => return failMsg(alloc, "attachment exceeds the 10MB store cap"),
        else => return failMsg(alloc, @errorName(e)),
    };
    defer alloc.free(bytes);

    const mt = apx_attachments.sniffMediaType(bytes) orelse
        return failMsg(alloc, "file is not a recognizable png/jpeg/webp/gif image");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.print(alloc, "path: {s}\nmedia_type: {s}\nsize: {d} bytes\n", .{ raw_path, mt.iana(), bytes.len });
    if (parseDimensions(mt, bytes)) |d| {
        try out.print(alloc, "dimensions: {d}x{d}\n", .{ d.width, d.height });
    } else {
        try out.appendSlice(alloc, "dimensions: unknown (header not parsable)\n");
    }

    const enc_len = std.base64.standard.Encoder.calcSize(bytes.len);
    if (enc_len <= max_embedded_base64_bytes) {
        const b64 = try alloc.alloc(u8, enc_len);
        defer alloc.free(b64);
        _ = std.base64.standard.Encoder.encode(b64, bytes);
        try out.appendSlice(alloc, "base64: ");
        try out.appendSlice(alloc, b64);
        try out.append(alloc, '\n');
    } else {
        try out.print(alloc, "base64: omitted ({d} encoded bytes exceed the {d}-byte budget; use shell+base64(1) to slice)\n", .{ enc_len, max_embedded_base64_bytes });
    }

    return ToolResult{ .success = true, .output = try out.toOwnedSlice(alloc) };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseDimensions reads real container headers" {
    // PNG: magic + IHDR length/type + 16-bit-per-dimension... full header.
    var png: [33]u8 = undefined;
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    @memcpy(png[8..16], "\x00\x00\x00\x0dIHDR");
    std.mem.writeInt(u32, png[16..20], 640, .big);
    std.mem.writeInt(u32, png[20..24], 480, .big);
    const pd = parseDimensions(.png, &png).?;
    try testing.expectEqual(@as(u32, 640), pd.width);
    try testing.expectEqual(@as(u32, 480), pd.height);
    try testing.expect(parseDimensions(.png, png[0..20]) == null); // truncated

    // GIF87a with little-endian logical screen size.
    var gif: [10]u8 = undefined;
    @memcpy(gif[0..6], "GIF87a");
    std.mem.writeInt(u16, gif[6..8], 32, .little);
    std.mem.writeInt(u16, gif[8..10], 200, .little);
    const gd = parseDimensions(.gif, &gif).?;
    try testing.expectEqual(@as(u32, 32), gd.width);
    try testing.expectEqual(@as(u32, 200), gd.height);

    // JPEG SOF0: FFD8 FFE00004 ... FFC0 0011 08 0064 00c8 ...
    const jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x64, 0x00, 0xC8 };
    const jd = parseDimensions(.jpeg, &jpeg).?;
    try testing.expectEqual(@as(u32, 200), jd.width);
    try testing.expectEqual(@as(u32, 100), jd.height);

    // WebP VP8X canvas (minus-one encoding).
    const webp = "RIFF\x1a\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00\x63\x00\x00\x2f\x00\x00"[0..];
    const wd = parseDimensions(.webp, webp).?;
    try testing.expectEqual(@as(u32, 0x63 + 1), wd.width);
    try testing.expectEqual(@as(u32, 0x2f + 1), wd.height);
}

// Shared fixture environment: a temp workspace with two stored images.
const Fixture = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    tmp: []u8,

    fn init(alloc: std.mem.Allocator, io: std.Io) !Fixture {
        const counter = next_counter();
        const tmp = try std.fmt.allocPrint(alloc, "/tmp/zh_attachments_tool_{d}_{d}", .{ std.Io.Timestamp.now(io, .real).toMilliseconds(), counter });
        errdefer alloc.free(tmp);
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, tmp);
        // Store one real PNG through the production pipeline, under the same
        // `.zharness/attachments` layout the executors browse.
        const root = try std.fmt.allocPrint(alloc, "{s}/" ++ attachments_dirname, .{tmp});
        defer alloc.free(root);
        const bytes = try alloc.alloc(u8, try apx_attachments.decodedBase64Len(tiny_png));
        defer alloc.free(bytes);
        std.base64.standard.Decoder.decode(bytes, tiny_png) catch return error.BadBase64;
        const ex_img = apx_attachments.ExtractedImage{
            .media_type = try alloc.dupe(u8, "image/png"),
            .bytes = bytes,
            .name = null,
        };
        defer alloc.free(ex_img.media_type);
        const stored = try apx_attachments.storeImages(alloc, io, root, "sess-1", &.{ex_img});
        defer {
            for (stored) |s| alloc.free(s.path);
            alloc.free(stored);
        }
        return .{ .alloc = alloc, .io = io, .tmp = tmp };
    }

    fn deinit(self: *Fixture) void {
        std.Io.Dir.deleteTree(std.Io.Dir.cwd(), self.io, self.tmp) catch {};
        self.alloc.free(self.tmp);
    }
};

var fixture_counter: usize = 0;
fn next_counter() usize {
    fixture_counter += 1;
    return fixture_counter;
}

/// Minimal valid PNG (magic + minimal chunks) — 70-byte 1x1 black pixel.
const tiny_png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

test "attachment_list enumerates stored files with sniffed types" {
    const alloc = testing.allocator;
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();

    var fx = try Fixture.init(alloc, io);
    defer fx.deinit();

    const res = try execute(alloc, io, fx.tmp, .{ .name = "attachment_list", .arguments = "{}" });
    defer freeResult(alloc, &res);
    try testing.expect(res.success);
    try testing.expect(std.mem.indexOf(u8, res.output, ".zharness/attachments/sess-1/") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "image/png\t70 bytes") != null);
}

test "attachment_read reports metadata and base64 for a small image" {
    const alloc = testing.allocator;
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();

    var fx = try Fixture.init(alloc, io);
    defer fx.deinit();

    // Discover the stored name via list first (keeps the test honest).
    const lst = try execute(alloc, io, fx.tmp, .{ .name = "attachment_list", .arguments = "{}" });
    defer freeResult(alloc, &lst);
    const tab1 = std.mem.indexOfScalar(u8, lst.output, '\t').?;
    const stored_rel = lst.output[0..tab1];

    var args_buf: [512]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"path\":\"{s}\"}}", .{stored_rel});
    const res = try execute(alloc, io, fx.tmp, .{ .name = "attachment_read", .arguments = args });
    defer freeResult(alloc, &res);
    try testing.expect(res.success);
    try testing.expect(std.mem.indexOf(u8, res.output, "media_type: image/png\n") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "size: 70 bytes\n") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "dimensions: 1x1\n") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "base64: iVBORw0KGgo") != null);
}

test "attachment_read containment: outside paths are refused" {
    const alloc = testing.allocator;
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();

    var fx = try Fixture.init(alloc, io);
    defer fx.deinit();

    const res = try execute(alloc, io, fx.tmp, .{
        .name = "attachment_read",
        .arguments = "{\"path\":\"../../../etc/passwd\"}",
    });
    defer freeResult(alloc, &res);
    try testing.expect(!res.success);
    try testing.expectEqualStrings("path is outside the attachment store", res.err_msg.?);

    const missing = try execute(alloc, io, fx.tmp, .{
        .name = "attachment_read",
        .arguments = "{\"path\":\".zharness/attachments/nope/dead.png\"}",
    });
    defer freeResult(alloc, &missing);
    try testing.expect(!missing.success);
    try testing.expectEqualStrings("attachment not found", missing.err_msg.?);
}
