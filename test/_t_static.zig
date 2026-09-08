//! Tests for server/static.zig — pure routing only (no sockets, no disk).
//!
//! Run: zig test -lc test/_t_static.zig
//! Coverage: path-traversal rejection matrix, content-type mapping, index
//! fallback ("/" -> index.html), static-space claims, and 404-class
//! resolution failures. The IO half of static.handle is intentionally NOT
//! exercised here; it is a thin fopen/fread wrapper around decisions that
//! these tests already cover.

const std = @import("std");
const static = @import("../src/server/static.zig");
const httpd = @import("../src/server/httpd.zig");

const alloc = std.testing.allocator;

fn expectResolved(root: []const u8, url: []const u8, want_path: []const u8, want_ct: []const u8) !void {
    const r = try static.resolvePath(alloc, root, url);
    defer alloc.free(r.path);
    try std.testing.expectEqualStrings(want_path, r.path);
    try std.testing.expectEqualStrings(want_ct, r.content_type);
}

fn expectError(root: []const u8, url: []const u8, want: static.ResolveError) !void {
    try std.testing.expectError(want, static.resolvePath(alloc, root, url));
}

// ── index fallback + happy paths ────────────────────────────────────────────

test "resolvePath maps / to index.html inside root" {
    try expectResolved("web", "/", "web/index.html", "text/html; charset=utf-8");
    try expectResolved("/srv/www", "/", "/srv/www/index.html", "text/html; charset=utf-8");
    // Root with trailing separator must not double-slash into a traversal.
    try expectResolved("web/", "/", "web//index.html", "text/html; charset=utf-8");
}

test "resolvePath maps /assets/* under the root, nested included" {
    try expectResolved("web", "/assets/styles.css", "web/assets/styles.css", "text/css; charset=utf-8");
    try expectResolved("web", "/assets/app.js", "web/assets/app.js", "text/javascript; charset=utf-8");
    try expectResolved("web", "/assets/img/logo.png", "web/assets/img/logo.png", "image/png");
    try expectResolved("w", "/assets/favicon.svg", "w/assets/favicon.svg", "image/svg+xml");
    try expectResolved("w", "/assets/f.ico", "w/assets/f.ico", "image/x-icon");
}

test "claims matches exactly the two static spaces" {
    try std.testing.expect(static.claims("/"));
    try std.testing.expect(static.claims("/assets/app.js"));
    try std.testing.expect(!static.claims("/assets")); // no trailing slash: API territory
    try std.testing.expect(!static.claims("/run"));
    try std.testing.expect(!static.claims("/sessions"));
    try std.testing.expect(!static.claims("/healthz"));
    try std.testing.expect(!static.claims("/events"));
    try std.testing.expect(!static.claims(""));
}

// ── content-type mapping ────────────────────────────────────────────────────

test "contentTypeFor covers html/css/js/svg/png/ico case-insensitively" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", static.contentTypeFor("index.html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", static.contentTypeFor("a/b.CSS"));
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", static.contentTypeFor("app.Js"));
    try std.testing.expectEqualStrings("image/svg+xml", static.contentTypeFor("icon.svg"));
    try std.testing.expectEqualStrings("image/png", static.contentTypeFor("x/y/z.PNG"));
    try std.testing.expectEqualStrings("image/x-icon", static.contentTypeFor("favicon.ico"));
}

test "contentTypeFor falls back to octet-stream for unknown or missing extension" {
    try std.testing.expectEqualStrings("application/octet-stream", static.contentTypeFor("data.bin"));
    try std.testing.expectEqualStrings("application/octet-stream", static.contentTypeFor("README"));
    try std.testing.expectEqualStrings("application/octet-stream", static.contentTypeFor("a.b.dots"));
    // Multi-dot names key on the LAST segment after the final dot.
    try std.testing.expectEqualStrings("text/css; charset=utf-8", static.contentTypeFor("a.style.css"));
    try std.testing.expectEqualStrings("image/png", static.contentTypeFor("logo.backup.png"));
}

// ── traversal / hostile-path rejection matrix ───────────────────────────────

test "resolvePath rejects dot-dot traversals in raw and percent-encoded forms" {
    const forbidden = static.ResolveError.Forbidden;
    try expectError("web", "/assets/../secret.txt", forbidden);
    try expectError("web", "/assets/../../etc/passwd", forbidden);
    try expectError("web", "/assets/img/../../../etc/passwd", forbidden);
    try expectError("web", "/assets/..%2F..%2Fetc%2Fpasswd", forbidden);
    try expectError("web", "/assets/%2e%2e/secret", forbidden); // lowercase enc
    try expectError("web", "/assets/%2E%2E/secret", forbidden); // uppercase enc
    try expectError("web", "/assets/sub/%2e%2e%2f%2e%2e%2fetc%2fpasswd", forbidden);
    try expectError("web", "/assets/..", forbidden);
}

test "resolvePath rejects absolute-style and malformed segment shapes with 404-class errors" {
    const invalid = static.ResolveError.InvalidPath;
    // Double slash inside the claimed space -> empty segment.
    try expectError("web", "/assets//etc/passwd", invalid);
    // Trailing slashes name directories, not files.
    try expectError("web", "/assets/", invalid);
    try expectError("web", "/assets/dir/", invalid);
    // Explicit current-directory segments are refused outright.
    try expectError("web", "/assets/./app.js", invalid);
    try expectError("web", "/assets/dir/./x.css", invalid);
}

test "resolvePath rejects NUL bytes and backslashes" {
    const forbidden = static.ResolveError.Forbidden;
    try expectError("web", "/assets/a%00b.html", forbidden); // encoded NUL
    try expectError("web", "/assets/win%5Cpath.js", forbidden); // encoded backslash
}

test "resolvePath leaves unclaimed URLs for the API" {
    const not_space = static.ResolveError.NotStaticSpace;
    try expectError("web", "/run", not_space);
    try expectError("web", "/sessions/alpha", not_space);
    try expectError("web", "/healthz", not_space);
    // Encoded traversal OUTSIDE the claimed space never touches the file
    // layer at all — it delegates to the API (which 404s JSON).
    try expectError("web", "/%2e%2e/etc/passwd", not_space);
}

test "resolvePath tolerates stray percent escapes as literal bytes" {
    // httpd.percentDecode passes "%zz" through verbatim; routing stays pure
    // and the eventual open() simply misses -> handled as a runtime 404.
    const r = try static.resolvePath(alloc, "web", "/assets/100%zz.txt");
    defer alloc.free(r.path);
    try std.testing.expectEqualStrings("web/assets/100%zz.txt", r.path);
    try std.testing.expectEqualStrings("application/octet-stream", r.content_type);
}
