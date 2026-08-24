//! Image attachment pipeline for `session.prompt` (wave 6 H-image).
//!
//! Contract (docs/dsh-reuse-spec.md §4 + upstream sessions.schema.ts):
//! prompt content parts are
//!   {type:'text',text:string}
//!   {type:'image',mediaType:'image/png'|'image/jpeg'|'image/webp'|'image/gif',
//!                   data:string(base64), name?:string}
//!
//! This module is the single place that knows how such a payload becomes
//! harness state:
//!
//!  1. `contentPartsValid` — the validator the router's hSessionPrompt
//!     calls (replaces the wave-3 text-only rejection; same false conditions
//!     plus acceptance of well-formed image parts).
//!  2. `extractParts` — splits the content array into joined text and
//!     validated images (base64 decoded ONCE, magic-byte sniffed, size
//!     capped at `max_image_bytes`).
//!  3. `processPromptContent` — end-to-end: persists every image under
//!     `<root>/<sessionId>/<n>-<sha256-16hex>.<ext>` and returns
//!     `PromptImages`: the rewritten prompt text (original text plus one
//!     honest `[image attached: <path>]` note per image) and, when the
//!     provider profile is vision-capable, ready-to-render
//!     `model.ImagePart`s for the wire builders.
//!
//! Honesty policy for NON-vision providers (deepseek text models): the image
//! NEVER reaches the wire (their APIs reject it). Instead the file stays on
//! disk where `file_read` / `attachment_read` tools can inspect it and the
//! prompt carries the path. Vision pass-through happens only when
//! `vision_capable` is true (ProviderProfile.vision).
//!
//! All IO goes through the injected `std.Io`; `root_dir` is a parameter so
//! tests can point at a scratch directory (production passes
//! `default_attachments_root`, relative to the serve process cwd).

const std = @import("std");
const jsonx = @import("jsonx.zig");
const model = @import("../../model/model.zig");

/// Default on-disk store, relative to the process working directory.
pub const default_attachments_root = ".zharness/attachments";

/// Hard cap on ONE decoded image (mirrors upstream's per-image bound).
pub const max_image_bytes: usize = 10 * 1024 * 1024;

/// Media types accepted on the browser wire (upstream imageMediaTypeSchema).
pub const MediaType = enum {
    png,
    jpeg,
    webp,
    gif,

    pub fn iana(self: MediaType) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
            .gif => "image/gif",
        };
    }

    pub fn extension(self: MediaType) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpg",
            .webp => "webp",
            .gif => "gif",
        };
    }
};

/// Magic-byte sniffing over DECODED image bytes. Returns null for anything
/// that is not one of the four supported raster formats — the declared
/// `mediaType` field is never trusted on its own.
pub fn sniffMediaType(bytes: []const u8) ?MediaType {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return .jpeg;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return .gif;
    return null;
}

/// Exact decoded length of a standard-alphabet base64 payload (padding
/// required). Errors without allocating, so the size cap can be enforced
/// BEFORE any buffer exists.
pub fn decodedBase64Len(b64: []const u8) !usize {
    return std.base64.standard.Decoder.calcSizeForSlice(b64);
}

// ── extraction ──────────────────────────────────────────────────────────────

/// One validated image part. Strings are owned by the parent `Extraction`.
pub const ExtractedImage = struct {
    /// Canonical media type SNIFFED from the decoded bytes (iana() form).
    media_type: []u8,
    /// Decoded image bytes (already capped).
    bytes: []u8,
    name: ?[]const u8,
};

/// Result of splitting a prompt content array. `text` is the text parts
/// joined with "\n" ("" when the prompt was images-only); images may be
/// empty. Owned; free via deinit.
pub const Extraction = struct {
    text: []u8,
    images: []ExtractedImage,

    pub fn deinit(self: *Extraction, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        for (self.images) |img| {
            alloc.free(img.media_type);
            alloc.free(img.bytes);
            if (img.name) |n| alloc.free(n);
        }
        alloc.free(self.images);
    }
};

pub const ExtractError = error{
    BadContentArray,
    BadImagePart,
    BadBase64,
    ImageTooLarge,
    UnsupportedImage,
    OutOfMemory,
};

/// Split a `session.prompt` content array into text + validated images.
/// Pure-text payloads follow the exact legacy shape (joined text, zero
/// images) and cannot fail short of OOM/malformed array. The FIRST bad image
/// part aborts with the corresponding error so the router can answer
/// bad-request instead of silently dropping user data.
pub fn extractParts(alloc: std.mem.Allocator, content_json: []const u8) ExtractError!Extraction {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var images: std.ArrayList(ExtractedImage) = .empty;
    errdefer {
        for (images.items) |*img| {
            alloc.free(img.media_type);
            alloc.free(img.bytes);
            if (img.name) |n| alloc.free(n);
        }
        images.deinit(alloc);
    }

    const raw_arr = jsonx.trimWs(content_json);
    if (raw_arr.len < 2 or raw_arr[0] != '[' or raw_arr[raw_arr.len - 1] != ']') return error.BadContentArray;
    const inner = raw_arr[1 .. raw_arr.len - 1];

    var i: usize = 0;
    var seen: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ',' or inner[i] == ' ' or inner[i] == '\n' or inner[i] == '\t' or inner[i] == '\r')) : (i += 1) {}
        if (i >= inner.len) break;
        if (inner[i] != '{') return error.BadContentArray;
        const end = jsonx.matchBraceFrom(inner, i) orelse return error.BadContentArray;
        const part = inner[i..end];
        i = end;
        seen += 1;

        const ty_raw = jsonx.getRaw(part, "type") orelse return error.BadContentArray;
        if (std.mem.eql(u8, ty_raw, "\"text\"")) {
            const txt = (try jsonx.getStringAlloc(alloc, part, "text")) orelse return error.BadContentArray;
            defer alloc.free(txt);
            if (text.items.len > 0) try text.appendSlice(alloc, "\n");
            try text.appendSlice(alloc, txt);
            continue;
        }
        if (!std.mem.eql(u8, ty_raw, "\"image\"")) return error.BadContentArray;

        // ── image part ──
        const data_b64 = (try jsonx.getStringAlloc(alloc, part, "data")) orelse return error.BadImagePart;
        defer alloc.free(data_b64);
        const decoded_len = decodedBase64Len(data_b64) catch return error.BadBase64;
        if (decoded_len > max_image_bytes) return error.ImageTooLarge;
        const bytes = try alloc.alloc(u8, decoded_len);
        errdefer alloc.free(bytes);
        std.base64.standard.Decoder.decode(bytes, data_b64) catch return error.BadBase64;
        const mt = sniffMediaType(bytes) orelse return error.UnsupportedImage;
        const name = try jsonx.getStringAlloc(alloc, part, "name"); // optional

        try images.append(alloc, .{
            .media_type = try alloc.dupe(u8, mt.iana()),
            .bytes = bytes,
            .name = name,
        });
    }
    if (seen < 1) return error.BadContentArray;

    return .{
        .text = try text.toOwnedSlice(alloc),
        .images = try images.toOwnedSlice(alloc),
    };
}

// ── persistence ─────────────────────────────────────────────────────────────

/// One image persisted under the attachment store. `path` is the workspace-
/// relative path handed to models (owned by `PromptImages`).
pub const StoredAttachment = struct {
    path: []u8,
    media_type: []const u8,
    size: usize,
};

fn sanitizeSessionId(alloc: std.mem.Allocator, session_id: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, session_id);
    for (out) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '-' and ch.* != '_') ch.* = '_';
    }
    if (out.len == 0) {
        alloc.free(out);
        return alloc.dupe(u8, "unknown");
    }
    return out;
}

/// Persist extracted images as
///   `<root_dir>/<sanitized-session-id>/<index>-<sha256[0..16]hex>.<ext>`
/// creating directories on demand. Deterministic names: identical bytes in
/// the same slot collapse to the same file (idempotent retries are free).
pub fn storeImages(
    alloc: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    session_id: []const u8,
    images: []const ExtractedImage,
) ![]StoredAttachment {
    const cwd = std.Io.Dir.cwd();
    const sid = try sanitizeSessionId(alloc, session_id);
    defer alloc.free(sid);

    // Nothing to persist: do not even require the root directory to exist.
    if (images.len == 0) return alloc.alloc(StoredAttachment, 0);

    const out = try alloc.alloc(StoredAttachment, images.len);
    errdefer {
        for (out) |s| alloc.free(s.path);
        alloc.free(out);
    }

    if (images.len > 0) {
        const session_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root_dir, sid });
        defer alloc.free(session_path);
        try std.Io.Dir.createDirPath(cwd, io, session_path);
    }

    const root_h = try std.Io.Dir.openDir(cwd, io, root_dir, .{});
    defer std.Io.Dir.close(root_h, io);

    for (images, 0..) |img, idx| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(img.bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);

        const mt = sniffMediaType(img.bytes) orelse return error.UnsupportedImage;
        const fname = try std.fmt.allocPrint(alloc, "{d}-{s}.{s}", .{ idx, hex[0..16], mt.extension() });
        defer alloc.free(fname);
        const sub_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ sid, fname });
        defer alloc.free(sub_path);

        try std.Io.Dir.writeFile(root_h, io, .{
            .sub_path = sub_path,
            .data = img.bytes,
        });

        out[idx] = .{
            .path = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ root_dir, sid, fname }),
            .media_type = mt.iana(),
            .size = img.bytes.len,
        };
    }
    return out;
}

// ── end-to-end prompt processing ────────────────────────────────────────────

/// Everything the promptSession path needs from one multimodal prompt.
/// Owned; free via deinit.
pub const PromptImages = struct {
    /// Rewritten prompt: original text parts plus one
    /// `[image attached: <path>]` line per stored image.
    prompt_text: []u8,
    /// Wire-ready image parts for VISION-capable providers. Empty when
    /// `vision_capable` was false (honest degradation: path note only).
    image_parts: []model.ImagePart,
    /// Persisted files (paths owned here).
    stored: []StoredAttachment,

    pub fn deinit(self: *PromptImages, alloc: std.mem.Allocator) void {
        alloc.free(self.prompt_text);
        for (self.image_parts) |p| {
            alloc.free(p.media_type);
            alloc.free(p.data_b64);
            if (p.name) |n| alloc.free(n);
        }
        alloc.free(self.image_parts);
        for (self.stored) |s| alloc.free(s.path);
        alloc.free(self.stored);
    }
};

/// Process one `session.prompt` content array end to end:
/// extract → validate (sniff/cap) → persist → rewrite text → build wire
/// parts. Text-only payloads skip the store entirely and return the original
/// text unchanged, so the legacy path costs one parse and nothing else.
pub fn processPromptContent(
    alloc: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    session_id: []const u8,
    content_json: []const u8,
    vision_capable: bool,
) !PromptImages {
    var ex = try extractParts(alloc, content_json);
    defer ex.deinit(alloc);

    const stored = try storeImages(alloc, io, root_dir, session_id, ex.images);
    errdefer {
        for (stored) |s| alloc.free(s.path);
        alloc.free(stored);
    }

    // Rewritten prompt text: original text + one honest note per image.
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    try text.appendSlice(alloc, ex.text);
    for (stored) |s| {
        if (text.items.len > 0) try text.appendSlice(alloc, "\n");
        try text.appendSlice(alloc, "[image attached: ");
        try text.appendSlice(alloc, s.path);
        try text.append(alloc, ' ');
        try text.print(alloc, "({s}, {d} bytes)]", .{ s.media_type, s.size });
    }

    // Wire parts only for vision-capable profiles. Each field is an owned
    // copy so the result never borrows from content_json or the extraction.
    var parts = try alloc.alloc(model.ImagePart, if (vision_capable) ex.images.len else 0);
    errdefer alloc.free(parts);
    var filled: usize = 0;
    errdefer {
        for (parts[0..filled]) |p| {
            alloc.free(p.media_type);
            alloc.free(p.data_b64);
            if (p.name) |n| alloc.free(n);
        }
    }
    if (vision_capable) {
        for (ex.images) |img| {
            // Re-encode from the verified-decoded bytes rather than borrowing
            // the client's payload: guarantees canonical padding/alphabet and
            // clear ownership.
            const b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(img.bytes.len));
            errdefer alloc.free(b64);
            _ = std.base64.standard.Encoder.encode(b64, img.bytes);
            const name: ?[]u8 = if (img.name) |n| try alloc.dupe(u8, n) else null;
            parts[filled] = .{
                .media_type = try alloc.dupe(u8, img.media_type),
                .data_b64 = b64,
                .name = name,
            };
            filled += 1;
        }
    }

    return .{
        .prompt_text = try text.toOwnedSlice(alloc),
        .image_parts = parts,
        .stored = stored,
    };
}

/// Validator for the router's `hSessionPrompt` (replaces the wave-3
/// text-only `promptContentValid`). Accepts exactly the upstream union:
/// every part must be `{type:'text',text:string}` or a well-formed image
/// part (`data` string whose declared shape parses and sniffs; full
/// validation happens in `extractParts`). At least one part required.
pub fn contentPartsValid(content_json: []const u8) bool {
    const raw_arr = jsonx.trimWs(content_json);
    if (raw_arr.len < 2 or raw_arr[0] != '[' or raw_arr[raw_arr.len - 1] != ']') return false;
    const inner = raw_arr[1 .. raw_arr.len - 1];
    var seen: usize = 0;
    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ',' or inner[i] == ' ' or inner[i] == '\n' or inner[i] == '\t' or inner[i] == '\r')) : (i += 1) {}
        if (i >= inner.len) break;
        if (inner[i] != '{') return false;
        const end = jsonx.matchBraceFrom(inner, i) orelse return false;
        const part = inner[i..end];
        i = end;
        seen += 1;
        const t = jsonx.getRaw(part, "type") orelse return false;
        if (std.mem.eql(u8, t, "\"text\"")) {
            const txt = jsonx.getRaw(part, "text") orelse return false;
            if (!jsonx.isString(txt)) return false;
            continue;
        }
        if (std.mem.eql(u8, t, "\"image\"")) {
            const data = jsonx.getRaw(part, "data") orelse return false;
            if (!jsonx.isString(data)) return false;
            continue;
        }
        return false;
    }
    return seen >= 1;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Smallest valid 1x1 PNG (67 bytes) — real magic bytes, real IHDR/IDAT.
pub const tiny_png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

test "sniffMediaType recognizes the four supported formats" {
    const png = "\x89PNG\r\n\x1a\n rest";
    try testing.expectEqual(MediaType.png, sniffMediaType(png).?);
    const jpeg = "\xFF\xD8\xFF\xE0 JFIF";
    try testing.expectEqual(MediaType.jpeg, sniffMediaType(jpeg).?);
    const webp = "RIFF\x24\x00\x00\x00WEBPVP8 ";
    try testing.expectEqual(MediaType.webp, sniffMediaType(webp).?);
    try testing.expectEqual(MediaType.gif, sniffMediaType("GIF89a03a").?);
    try testing.expect(sniffMediaType("hello world!") == null);
    try testing.expect(sniffMediaType("") == null);
    try testing.expect(sniffMediaType("\x89PNG too short") == null);
}

test "decodedBase64Len computes exact sizes before allocation" {
    // The 1x1 PNG fixture is 96 chars -> 70 bytes.
    try testing.expectEqual(@as(usize, tiny_png_b64.len / 4 * 3 - 2), try decodedBase64Len(tiny_png_b64));
    try testing.expectError(error.InvalidPadding, decodedBase64Len("abc")); // missing padding
}

test "contentPartsValid accepts text and image parts, rejects garbage" {
    try testing.expect(contentPartsValid("[{\"type\":\"text\",\"text\":\"hi\"}]"));
    try testing.expect(contentPartsValid(
        "[{\"type\":\"text\",\"text\":\"look\"},{\"type\":\"image\",\"mediaType\":\"image/png\",\"data\":\"aGk=\"}]",
    ));
    try testing.expect(contentPartsValid(
        "[{\"type\":\"image\",\"mediaType\":\"image/png\",\"data\":\"aGk=\",\"name\":\"shot.png\"}]",
    ));
    // Legacy rejections stay rejections.
    try testing.expect(!contentPartsValid("[]"));
    try testing.expect(!contentPartsValid("[{\"type\":\"video\",\"url\":\"x\"}]"));
    try testing.expect(!contentPartsValid("[{\"type\":\"image\",\"data\":42}]"));
    try testing.expect(!contentPartsValid("[{\"type\":\"text\"}]"));
    try testing.expect(!contentPartsValid("not json"));
}

test "extractParts joins text parts and validates images" {
    const alloc = testing.allocator;
    const doc = "[{\"type\":\"text\",\"text\":\"first\"},{\"type\":\"text\",\"text\":\"second\"}," ++
        "{\"type\":\"image\",\"mediaType\":\"image/png\",\"data\":\"" ++ tiny_png_b64 ++ "\",\"name\":\"dot.png\"}]";
    var ex = try extractParts(alloc, doc);
    defer ex.deinit(alloc);
    try testing.expectEqualStrings("first\nsecond", ex.text);
    try testing.expectEqual(@as(usize, 1), ex.images.len);
    try testing.expectEqualStrings("image/png", ex.images[0].media_type);
    try testing.expectEqual(@as(usize, 70), ex.images[0].bytes.len);
    try testing.expectEqualStrings("dot.png", ex.images[0].name.?);
    // Sniffed, not just declared: PNG magic must lead the decoded bytes.
    try testing.expectEqual(@as(u8, 0x89), ex.images[0].bytes[0]);
}

test "extractParts rejects lying media types and oversize payloads" {
    const alloc = testing.allocator;
    // Declared png, actually text.
    try testing.expectError(
        error.UnsupportedImage,
        extractParts(alloc, "[{\"type\":\"image\",\"mediaType\":\"image/png\",\"data\":\"aGVsbG8=\"}]"),
    );
    // Broken base64.
    try testing.expectError(
        error.BadBase64,
        extractParts(alloc, "[{\"type\":\"image\",\"mediaType\":\"image/png\",\"data\":\"!!!!\"}]"),
    );
    // Oversize: craft a b64 payload whose DECODED size exceeds the 10MB cap
    // (decoded = len/4*3; keep len a multiple of 4 so padding stays valid)
    // without ever decoding the bytes.
    const big_len = (max_image_bytes / 3) * 4 + 8;
    const big = try alloc.alloc(u8, big_len);
    defer alloc.free(big);
    @memset(big, 'A');
    const wrapped = try std.fmt.allocPrint(alloc, "[{{\"type\":\"image\",\"mediaType\":\"image/gif\",\"data\":\"{s}\"}}]", .{big});
    defer alloc.free(wrapped);
    try testing.expectError(error.ImageTooLarge, extractParts(alloc, wrapped));
}

test "prompt round-trip: store, rewrite, vision parts, idempotent names" {
    const alloc = testing.allocator;
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();

    const root = ".zharness_attachments_test";
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, root) catch {};
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, root);

    const doc = "[{\"type\":\"text\",\"text\":\"what is this?\"}," ++
        "{\"type\":\"image\",\"mediaType\":\"image/png\",\"data\":\"" ++ tiny_png_b64 ++ "\",\"name\":\"dot.png\"}]";

    // Vision-capable profile: parts ride along.
    var pi = try processPromptContent(alloc, io, root, "sess/abc-1", doc, true);
    defer pi.deinit(alloc);
    try testing.expect(std.mem.startsWith(u8, pi.prompt_text, "what is this?\n[image attached: "));
    try testing.expect(std.mem.indexOf(u8, pi.prompt_text, ".png (image/png, 70 bytes)]") != null);
    try testing.expectEqual(@as(usize, 1), pi.image_parts.len);
    try testing.expectEqualStrings("image/png", pi.image_parts[0].media_type);
    try testing.expectEqualStrings(tiny_png_b64, pi.image_parts[0].data_b64);
    try testing.expectEqualStrings("dot.png", pi.image_parts[0].name.?);

    // File actually on disk at the advertised path with identical bytes.
    const raw = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, pi.stored[0].path, alloc, .limited(max_image_bytes)) catch |e| {
        std.debug.print("read failed: {any} path={s}\n", .{ e, pi.stored[0].path });
        return e;
    };
    defer alloc.free(raw);
    try testing.expectEqual(@as(usize, 70), raw.len);
    try testing.expectEqual(@as(u8, 0x89), raw[0]);

    // Non-vision profile: NO wire parts, but the note + file remain.
    var pv = try processPromptContent(alloc, io, root, "sess/abc-1", doc, false);
    defer pv.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), pv.image_parts.len);
    try testing.expect(std.mem.indexOf(u8, pv.prompt_text, "[image attached: ") != null);
    try testing.expectEqualStrings(pi.stored[0].path, pv.stored[0].path); // deterministic name

    // Images-only prompt: text empty, note still present.
    const img_only = "[{\"type\":\"image\",\"mediaType\":\"image/png\",\"data\":\"" ++ tiny_png_b64 ++ "\"}]";
    var po = try processPromptContent(alloc, io, root, "sess_2", img_only, false);
    defer po.deinit(alloc);
    try testing.expect(std.mem.startsWith(u8, po.prompt_text, "[image attached: "));
}

test "pure-text prompts pass through unchanged with no side effects" {
    const alloc = testing.allocator;
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();

    const root = ".zharness_attachments_test_empty";
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, root) catch {};

    var pi = try processPromptContent(alloc, io, root, "s", "[{\"type\":\"text\",\"text\":\"just text\"}]", false);
    defer pi.deinit(alloc);
    try testing.expectEqualStrings("just text", pi.prompt_text);
    try testing.expectEqual(@as(usize, 0), pi.image_parts.len);
    try testing.expectEqual(@as(usize, 0), pi.stored.len);
}
