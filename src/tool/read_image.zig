//! `read_image` — attach a workspace image to the conversation (alignment
//! with upstream dsh image-input / read_image).
//!
//! The loader reads + sniffs + base64-encodes one image. AgentLoop keeps the
//! owned bytes and injects them as a user message on the next model request;
//! only vision-capable provider profiles put them on the wire (model.zig).

const std = @import("std");
const tool_reg = @import("registry.zig");
const builtin = @import("builtin.zig");
const apx = @import("../server/apiproxy/attachments.zig");

pub const ToolCall = builtin.ToolCall;
pub const ToolResult = builtin.ToolResult;
pub const freeResult = builtin.freeResult;

pub const max_bytes: usize = apx.max_image_bytes;

pub const definition = tool_reg.ToolDefinition{
    .name = "read_image",
    .description = "Attach a workspace image (png/jpeg/webp/gif) to the conversation so a vision-capable model can see it. Returns a short note; the image rides the next model request.",
    .category = .filesystem,
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Image file inside the workspace"}},"required":["path"]}
    ,
};

pub fn register(reg: *tool_reg.ToolRegistry) !void {
    try reg.register(definition);
}

/// Owned, decoded image ready to ride a model message.
pub const Loaded = struct {
    media_type: []u8,
    data_b64: []u8,
    name: []u8,
    byte_len: usize,
};

pub fn freeLoaded(alloc: std.mem.Allocator, l: *Loaded) void {
    alloc.free(l.media_type);
    alloc.free(l.data_b64);
    alloc.free(l.name);
}

/// Read + validate + base64-encode one image file. Caller frees via
/// `freeLoaded`. Errors: ImageNotFound, ImageTooLarge, UnsupportedImageType.
pub fn load(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, path: []const u8) !Loaded {
    const resolved = if (std.fs.path.isAbsolute(path))
        try alloc.dupe(u8, path)
    else
        try std.fs.path.resolve(alloc, &.{ cwd, path });
    defer alloc.free(resolved);

    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, resolved, alloc, .limited(max_bytes)) catch |e| switch (e) {
        error.FileNotFound => return error.ImageNotFound,
        error.FileTooBig => return error.ImageTooLarge,
        else => return e,
    };
    defer alloc.free(bytes);

    const mt = apx.sniffMediaType(bytes) orelse return error.UnsupportedImageType;
    const enc_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const b64 = try alloc.alloc(u8, enc_len);
    errdefer alloc.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, bytes);

    return .{
        .media_type = try alloc.dupe(u8, mt.iana()),
        .data_b64 = b64,
        .name = try alloc.dupe(u8, std.fs.path.basename(resolved)),
        .byte_len = bytes.len,
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const tiny_png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

test "read_image loads and sniffs a png" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "/tmp/zh_read_image_probe.png";
    const bytes = try std.base64.standard.Decoder.calcSizeForSlice(tiny_png_b64);
    const raw = try alloc.alloc(u8, bytes);
    defer alloc.free(raw);
    try std.base64.standard.Decoder.decode(raw, tiny_png_b64);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = raw });
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    var l = try load(alloc, io, "/tmp", "zh_read_image_probe.png");
    defer freeLoaded(alloc, &l);
    try testing.expectEqualStrings("image/png", l.media_type);
    try testing.expectEqualStrings("zh_read_image_probe.png", l.name);
    try testing.expectEqual(raw.len, l.byte_len);
    try testing.expect(l.data_b64.len > 0);
}

test "read_image rejects non-images and missing files" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "/tmp/zh_read_image_notimage.txt";
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = "hello" });
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    try testing.expectError(error.UnsupportedImageType, load(alloc, io, "/tmp", "zh_read_image_notimage.txt"));
    try testing.expectError(error.ImageNotFound, load(alloc, io, "/tmp", "zh_read_image_absent.png"));
}
