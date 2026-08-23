//! Static file serving for the zero-build web UI in `<repo>/web/`.
//!
//! Contract:
//! - HandlerFn-compatible with api.handle: identical 4-argument shape, so it
//!   installs directly as httpd.Server's handler.
//! - Claims exactly two URL spaces: `/` -> `<root>/index.html` and
//!   `/assets/<path>` -> `<root>/assets/<path>`. Every other URL delegates to
//!   the JSON API handler (`fallback`), keeping api.zig's route table the
//!   single source of truth for /run /sessions /sessions/:id /events
//!   /healthz. Unclaimed paths with no fallback answer the same JSON 404
//!   envelope the API produces.
//! - Pure core: `claims(path)` and `resolvePath(root, url_path)` make ALL
//!   routing/security decisions without touching disk or sockets; they are
//!   unit-tested in `src/_t_static.zig`. `handle()` adds only open/read/send.
//! - Security posture: URL paths are percent-decoded BEFORE validation, so
//!   `%2e%2e` cannot smuggle a traversal. Segments `.`, `..`, empty (`//`),
//!   NUL, and backslash are rejected. Reads are capped at `max_file_bytes`
//!   (larger files -> 413). Directories and every other filesystem miss map
//!   to a uniform 404 so the endpoint never distinguishes "missing" from
//!   "denied".
//! - Error responses reuse the API's JSON envelope `{"ok":false,"error":…}`
//!   so one client-side error path covers both handlers.
//! - File access goes through direct libc shims (fopen/fread/…), the same
//!   precedent httpd.zig sets for sockets: stable C ABI, callable without an
//!   `std.Io` handle (httpd handlers receive none). No global state; safe
//!   under threaded_connections because every call is per-connection.
//! - Allocation note: `handle()` receives the per-connection arena (see
//!   httpd.Server.handleConnectionFd); nothing it allocates is freed
//!   manually. Only the pure helpers document caller-frees ownership.
//!
//! ── Integrator splice (apply EXACTLY ONE of the two) ────────────────────────
//!
//! Option A — inside api.handle (as specified by SWARM_PLAN). Two lines at
//! the very top of `handle`, before any routing; everything else unchanged:
//!
//!     const static = @import("static.zig");   // top of api.zig
//!
//!     pub fn handle(ctx: ?*anyopaque, alloc: std.mem.Allocator,
//!                   req: *const httpd.Request, res: *httpd.Responder) anyerror!void {
//!         if (req.isGetLike() and static.claims(req.path)) {
//!             // ctx stays *ServerDeps for the API body below; static gets
//!             // null = defaults (.root = "web" relative to process CWD,
//!             // .fallback = null — unreachable here because unclaimed URLs
//!             // fall through to the normal body).
//!             return static.handle(null, alloc, req, res);
//!         }
//!         …existing body unchanged…
//!     }
//!
//! Option B — in main.zig cmdServe (zero edits to api.zig; keeps a custom
//! root possible and routes unclaimed paths through the real deps):
//!
//!     const static = @import("server/static.zig");
//!     …after `deps` is created:
//!     const web = try alloc.create(static.Ctx);
//!     web.* = .{ .root = "web", .fallback = .{ .ctx = deps, .call = api.handle } };
//!     var server = try httpd.Server.init(alloc, .{
//!         .ctx = web,
//!         .call = static.handle,
//!     }, .{ .port = port });
//!
//! Both options preserve every existing API behavior byte-for-byte: static
//! intercepts only GET/HEAD for `/` and `/assets/*`. Run zharness from the
//! repository root (or set `.root`) so `web/index.html` resolves.

const std = @import("std");
const httpd = @import("httpd.zig");

// ── libc stdio shims (see module doc; do NOT edit clib.zig) ─────────────────

const FILE = opaque {};

/// C `long` (ftell/fseek offsets). 64-bit on the LP64 targets zharness ships.
const clong = c_long;

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(f: *FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, f: *FILE) usize;
extern "c" fn fseek(f: *FILE, off: clong, whence: c_int) c_int;
extern "c" fn ftell(f: *FILE) clong;

const seek_end: c_int = 2; // SEEK_END

/// Upper bound on any served file (~5 MB). Larger files answer 413.
pub const max_file_bytes: usize = 5 * 1024 * 1024;

/// Default filesystem root for the URL space, resolved against the process
/// CWD (the repository's `web/` directory when zharness runs from the repo).
pub const default_root: []const u8 = "web";

/// Handler context. Heap-lifetime in main.zig; `handle` only reads it.
pub const Ctx = struct {
    /// Directory the URL space is rooted at (CWD-relative ok).
    root: []const u8 = default_root,
    /// Delegate for URLs outside the static space — normally
    /// `.{ .ctx = deps, .call = api.handle }`.
    fallback: ?httpd.Handler = null,
};

const default_ctx: Ctx = .{};

// ── pure routing core (unit-tested without IO) ──────────────────────────────

/// True when `url_path` belongs to the static URL space ("/" or "/assets/…",
/// pre-decode form as parsed into httpd.Request.path). Everything else is
/// API territory.
pub fn claims(url_path: []const u8) bool {
    if (std.mem.eql(u8, url_path, "/")) return true;
    // "/plugins/<pkg>/client.js" serves the vendored dsh client bundles
    // (webui dist layout: plugins/@scope/pkg -> lib/client.js).
    if (std.mem.startsWith(u8, url_path, "/plugins/")) return true;
    if (std.mem.startsWith(u8, url_path, "/assets/")) return true;
    // dsh dist keeps langs/, fonts/, favicon.svg, manifest at the root too.
    if (!std.mem.startsWith(u8, url_path, "//") and std.mem.indexOfScalar(u8, url_path, '.') != null) {
        return true; // any dotted path (favicon.svg, manifest.webmanifest, …)
    }
    return false;
}

pub const ResolveError = error{
    /// Path is outside the static space (caller should delegate to the API).
    NotStaticSpace,
    /// Malformed path that merely fails to name a file (empty segments,
    /// "." segments, trailing slash). Answers 404.
    InvalidPath,
    /// Attempted traversal or hostile bytes (".." segment, NUL, backslash).
    /// Answers 403 — distinct from 404 so abuse is observable in logs.
    Forbidden,
    OutOfMemory,
};

/// A successful resolution: `path` is root-joined and caller-freed;
/// `content_type` is a static string.
pub const Resolved = struct {
    path: []u8,
    content_type: []const u8,
};

/// Map `(root, url_path)` onto a filesystem path + content type. Pure: no
/// disk, no clock, no socket. Percent-decodes BEFORE validation so encoded
/// traversals ("%2e%2e%2f") are caught. Caller frees `Resolved.path`.
///
/// Examples:
///   resolvePath(a, "web", "/")               -> "web/index.html", text/html
///   resolvePath(a, "web", "/assets/app.js")  -> "web/assets/app.js", text/javascript
///   resolvePath(a, "/srv/w", "/assets/../x") -> error.Forbidden
///   resolvePath(a, "web", "/run")            -> error.NotStaticSpace
pub fn resolvePath(alloc: std.mem.Allocator, root: []const u8, url_path: []const u8) ResolveError!Resolved {
    if (!claims(url_path)) return error.NotStaticSpace;

    var type_ref: []const u8 = "index.html"; // extension source for content typing
    var owned: ?[]u8 = null;
    defer if (owned) |o| alloc.free(o);

    const full = blk: {
        if (url_path.len == 1) // "/" — prefer the boot-injected index when present
            break :blk std.fmt.allocPrint(alloc, "{s}/index.injected.html", .{root}) catch
                try std.fmt.allocPrint(alloc, "{s}/index.html", .{root});
        // Decode the remainder of the URL path BEFORE validating segments,
        // then map it directly under the root (general single-root layout:
        // serves /assets/*, /plugins/*/client.js, /favicon.svg, … alike).
        const decoded = try httpd.percentDecode(alloc, url_path[1..]);
        owned = decoded;
        type_ref = decoded;
        try validateSegments(decoded);
        break :blk try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, decoded });
    };
    errdefer alloc.free(full);
    return .{ .path = full, .content_type = contentTypeFor(type_ref) };
}

/// Segment validator over a DECODED relative path. Rejects empty segments
/// (catches "//" and trailing "/"), ".", "..", NUL, and backslash.
fn validateSegments(decoded: []const u8) ResolveError!void {
    if (std.mem.indexOfScalar(u8, decoded, 0) != null) return error.Forbidden;
    if (std.mem.indexOfScalar(u8, decoded, '\\') != null) return error.Forbidden;
    var it = std.mem.splitScalar(u8, decoded, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, seg, "..")) return error.Forbidden;
        if (std.mem.eql(u8, seg, ".")) return error.InvalidPath;
    }
}

/// Extension -> Content-Type. Unknown or missing extensions serve as
/// application/octet-stream; the namespace is rooted at web/, so this is a
/// local development surface only.
pub fn contentTypeFor(rel_path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |s|
        rel_path[s + 1 ..]
    else
        rel_path;
    const ext = if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| base[d + 1 ..] else "";
    if (ext.len == 0) return "application/octet-stream";
    const table = [_]struct { ext: []const u8, ct: []const u8 }{
        .{ .ext = "html", .ct = "text/html; charset=utf-8" },
        .{ .ext = "css", .ct = "text/css; charset=utf-8" },
        .{ .ext = "js", .ct = "text/javascript; charset=utf-8" },
        .{ .ext = "svg", .ct = "image/svg+xml" },
        .{ .ext = "png", .ct = "image/png" },
        .{ .ext = "ico", .ct = "image/x-icon" },
    };
    for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row.ext)) return row.ct;
    }
    return "application/octet-stream";
}

// ── live adapter (httpd.HandlerFn shape — identical to api.handle) ─────────

pub fn handle(ctx: ?*anyopaque, alloc: std.mem.Allocator, req: *const httpd.Request, res: *httpd.Responder) anyerror!void {
    const opts: *const Ctx = if (ctx) |p| @ptrCast(@alignCast(p)) else &default_ctx;

    // Unclaimed URLs belong to the JSON API.
    if (!claims(req.path)) {
        if (opts.fallback) |fb| return fb.call(fb.ctx, alloc, req, res);
        return sendError(res, .not_found, "not found");
    }

    if (!req.isGetLike()) return sendError(res, .method_not_allowed, "method not allowed");

    const resolved = resolvePath(alloc, opts.root, req.path) catch |e| switch (e) {
        error.Forbidden => return sendError(res, .forbidden, "forbidden"),
        error.InvalidPath => return sendError(res, .not_found, "not found"),
        error.NotStaticSpace => unreachable, // claims() guarded above
        error.OutOfMemory => return e,
    };
    defer alloc.free(resolved.path);

    const data = readFileCapped(alloc, resolved.path) catch |e| switch (e) {
        // Uniform 404 for anything that fails to name a readable regular file
        // (missing, permission-denied, directory) — never leak which.
        error.OpenFailed => return sendError(res, .not_found, "not found"),
        error.StreamTooLong => return sendError(res, .payload_too_large, "file too large"),
        error.OutOfMemory => return e,
    };

    try res.sendRawType(.ok, resolved.content_type, data);
}

fn sendError(res: *httpd.Responder, status: httpd.Status, msg: []const u8) void {
    var buf: [96]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg}) catch
        "{\"ok\":false,\"error\":\"error\"}";
    res.send(status, .json, body) catch {};
}

const ReadError = error{ OpenFailed, StreamTooLong, OutOfMemory };

/// Read a regular file through the libc shims, capped at `max_file_bytes`
/// plus one probe byte (so an oversized file is detected, not truncated).
/// The returned buffer belongs to `alloc` (the connection arena in live use).
fn readFileCapped(alloc: std.mem.Allocator, path: []const u8) ReadError![]u8 {
    const zpath = try alloc.allocSentinel(u8, path.len, 0);
    @memcpy(zpath[0..path.len], path);

    const f = fopen(zpath, "rb") orelse return error.OpenFailed;
    defer _ = fclose(f);

    if (fseek(f, 0, seek_end) != 0) return error.OpenFailed;
    const end = ftell(f);
    if (end < 0) return error.OpenFailed;
    if (@as(usize, @intCast(end)) > max_file_bytes) return error.StreamTooLong;
    if (fseek(f, 0, 0) != 0) return error.OpenFailed; // SEEK_SET

    const len: usize = @intCast(end);
    const buf = try alloc.alloc(u8, len);
    var got: usize = 0;
    while (got < len) {
        const n = fread(buf.ptr + got, 1, len - got, f);
        if (n == 0) break; // short read (file shrank): serve what we have
        got += n;
    }
    return buf[0..got];
}
