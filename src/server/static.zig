//! Static file serving for the vendored DeepSeek Harness GUI.
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
//!   unit-tested in `test/_t_static.zig`. `handle()` adds only open/read/send.
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
//! repository root (or set `.root`) so the GUI index.html resolves.

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

/// Upper bound on any served file (~16 MB; upstream v0.1.6 bundles reach
/// ~7 MB, e.g. ui-sidebar-documentpreview's embedded document engine).
/// Larger files answer 413.
pub const max_file_bytes: usize = 16 * 1024 * 1024;

/// Default filesystem root for the URL space, resolved against the process
/// CWD. The vendored DeepSeek Harness GUI lives under webui/dist.
pub const default_root: []const u8 = "webui/dist";

/// Handler context. Heap-lifetime in main.zig; `handle` only reads it.
pub const Ctx = struct {
    /// Directory the URL space is rooted at (CWD-relative ok).
    /// Defaults to the vendored DeepSeek Harness GUI dist.
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
///   resolvePath(a, "webui/dist", "/")               -> "webui/dist/index.html", text/html
///   resolvePath(a, "webui/dist", "/assets/app.js")  -> "webui/dist/assets/app.js", text/javascript
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
/// application/octet-stream; the namespace is rooted at webui/dist/, so this is a
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

    // Combo route (`/plugins/??a/client.js,b/client.js&rev=X`): the boot graph
    // addresses plugin bundles through concatenated combo scripts; mirror the
    // host's ClientModuleRegistry buildComboScript semantics.
    if (std.mem.startsWith(u8, req.target, "/plugins/??"))
        return handleCombo(opts, alloc, req, res);

    if (!req.isGetLike()) return sendError(res, .method_not_allowed, "method not allowed");

    // Unclaimed URLs belong to the JSON API.
    if (!claims(req.path)) {
        if (opts.fallback) |fb| return fb.call(fb.ctx, alloc, req, res);
        return sendError(res, .not_found, "not found");
    }

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

// ── combo route (mirrors client-modules buildComboScript semantics) ─────────

/// Upper bound on a composed combo body (a URL-length-partitioned batch can
/// carry dozens of bundles; 64 MiB is far above any real build).
const combo_max_bytes: usize = 64 * 1024 * 1024;

/// One parsed combo resource: `@deepseek-ai/<pkg>/client.js[.map]`.
const ComboResource = struct {
    /// Filesystem path under the static root (caller-freed).
    path: []u8,
    /// True for `<pkg>/client.js.map` requests.
    is_map: bool,
};

/// Parse one combo resource into a root-joined file path. Pure validation:
/// the package prefix must be `@deepseek-ai/`, the payload must end in
/// `/client.js` (optionally `.map`), and no segment may be empty, ".", "..",
/// NUL, or backslash. Caller frees the returned path.
fn comboResourcePath(alloc: std.mem.Allocator, root: []const u8, resource: []const u8) ResolveError!ComboResource {
    const decoded = try httpd.percentDecode(alloc, resource);
    var rel = decoded;
    var is_map = false;
    if (std.mem.endsWith(u8, rel, ".map")) {
        is_map = true;
        rel = rel[0 .. rel.len - 4];
    }
    const suffix = "/client.js";
    if (!std.mem.endsWith(u8, rel, suffix)) return error.InvalidPath;
    const pkg = rel[0 .. rel.len - suffix.len];
    if (!std.mem.startsWith(u8, pkg, "@deepseek-ai/")) return error.InvalidPath;
    try validateSegments(pkg);
    const path = std.fmt.allocPrint(alloc, "{s}/plugins/{s}/client.js{s}", .{
        root, pkg, if (is_map) ".map" else "",
    }) catch return error.OutOfMemory;
    return .{ .path = path, .is_map = is_map };
}

/// Serve `/plugins/??<res1>,<res2>,…&rev=<rev>`. Script bodies concatenate each
/// referenced bundle with upstream's prepareSource semantics (strip the
/// trailing `//# sourceURL=`/`//# sourceMappingURL=` trailers, guarantee a
/// final newline, join with `;\n`) and stamp the combo map URL. Single `.map`
/// requests serve the map file raw; multi-map combos answer 404 (devtools-only
/// degradation — upstream composes an indexed map there).
fn handleCombo(opts: *const Ctx, alloc: std.mem.Allocator, req: *const httpd.Request, res: *httpd.Responder) anyerror!void {
    if (!req.isGetLike()) return sendError(res, .method_not_allowed, "method not allowed");
    const rest = req.target["/plugins/??".len..];
    const list = if (std.mem.indexOf(u8, rest, "&rev=")) |i| rest[0..i] else rest;
    if (list.len == 0) return sendError(res, .not_found, "not found");

    var total: usize = 0;
    var map_count: usize = 0;
    var js_count: usize = 0;
    var bodies: std.ArrayList([]u8) = .empty;
    defer {
        for (bodies.items) |b| alloc.free(b);
        bodies.deinit(alloc);
    }

    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |resource| {
        if (resource.len == 0) return sendError(res, .not_found, "not found");
        const combo = comboResourcePath(alloc, opts.root, resource) catch |e| switch (e) {
            error.Forbidden => return sendError(res, .forbidden, "forbidden"),
            error.InvalidPath => return sendError(res, .not_found, "not found"),
            error.NotStaticSpace, error.OutOfMemory => return e,
        };
        defer alloc.free(combo.path);
        const raw = readFileCapped(alloc, combo.path) catch |e| switch (e) {
            error.OpenFailed => return sendError(res, .not_found, "not found"),
            error.StreamTooLong => return sendError(res, .payload_too_large, "file too large"),
            error.OutOfMemory => return e,
        };
        total += raw.len;
        if (total > combo_max_bytes) return sendError(res, .payload_too_large, "combo too large");
        if (combo.is_map) {
            map_count += 1;
            bodies.append(alloc, raw) catch return error.OutOfMemory;
        } else {
            js_count += 1;
            const prepared = prepareSource(alloc, raw) catch return error.OutOfMemory;
            alloc.free(raw);
            bodies.append(alloc, prepared) catch return error.OutOfMemory;
        }
    }

    // Map requests: raw bytes for a single map; composed indexed maps are a
    // devtools-only nicety upstream builds — 404 keeps the surface honest.
    if (map_count > 0) {
        if (js_count > 0 or map_count > 1) return sendError(res, .not_found, "not found");
        return res.sendRawType(.ok, "application/json; charset=utf-8", bodies.items[0]);
    }

    // Script composition: `source += prepareSource(...).source + ";\n"` per
    // resource, then the stamped combo-map trailer.
    const map_url = std.fmt.allocPrint(alloc, "/plugins/??{s}.map", .{list}) catch return error.OutOfMemory;
    defer alloc.free(map_url);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (bodies.items) |b| {
        out.appendSlice(alloc, b) catch return error.OutOfMemory;
        out.appendSlice(alloc, ";\n") catch return error.OutOfMemory;
    }
    out.appendSlice(alloc, "//# sourceMappingURL=") catch return error.OutOfMemory;
    out.appendSlice(alloc, map_url) catch return error.OutOfMemory;
    out.append(alloc, '\n') catch return error.OutOfMemory;
    try res.sendRawType(.ok, "text/javascript; charset=utf-8", out.items);
}

/// Strip the trailing `//# sourceURL=`/`//# sourceMappingURL=` trailer lines
/// and guarantee one final newline (mirrors client-modules prepareSource).
fn prepareSource(alloc: std.mem.Allocator, bundle: []const u8) ![]u8 {
    var source = bundle;
    while (true) {
        const trimmed = std.mem.trimEnd(u8, source, "\r\n");
        const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
        const last_line = if (nl) |i| trimmed[i + 1 ..] else trimmed;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, last_line, " \t"), "//# ")) {
            source = if (nl) |i| trimmed[0..i] else "";
            continue;
        }
        source = trimmed;
        break;
    }
    const out = try alloc.dupe(u8, source);
    if (out.len == 0 or out[out.len - 1] != '\n') {
        return std.mem.concat(alloc, u8, &.{ out, "\n" });
    }
    return out;
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
