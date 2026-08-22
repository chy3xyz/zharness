//! Real web_search / web_scrape tools.
//!
//! Both tools fetch over HTTPS using the shared HttpClient2 (std.http + TLS +
//! CA verification under the hood) with a bounded read timeout, then extract
//! human-readable text. No external API keys required: search hits the
//! DuckDuckGo HTML endpoint; scrape fetches the URL directly.

const std = @import("std");
const httpc = @import("../net/http_client2.zig");
const tools_mod = @import("mod.zig");
const ToolCall = tools_mod.ToolCall;
const ToolResult = tools_mod.ToolResult;
const sandbox_mod = @import("../utils/sandbox.zig");
const Sandbox = sandbox_mod.Sandbox;

fn appendFmt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

const MAX_READ_BYTES: usize = 2 * 1024 * 1024;
const MAX_TEXT_BYTES: usize = 8 * 1024;
const MAX_LINKS: usize = 40;
const READ_TIMEOUT_MS: u64 = 15_000;

/// Split `scheme://host[:port]/path?query` into parts. Manual so we don't
/// depend on std.Uri's evolving field names across Zig versions.
const UrlParts = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    /// Raw path (including query), starting with '/'.
    path: []const u8,
};

fn splitUrl(url: []const u8) ?UrlParts {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..scheme_end];
    const rest = url[scheme_end + 3 ..];
    const host_end = std.mem.indexOfAny(u8, rest, ":/?") orelse rest.len;
    const host = rest[0..host_end];
    if (host.len == 0) return null;

    const default_port: u16 = if (std.ascii.eqlIgnoreCase(scheme, "https")) 443 else 80;
    var port: u16 = default_port;
    var path_start = host_end;

    if (host_end < rest.len and rest[host_end] == ':') {
        const colon = host_end;
        const after = colon + 1;
        const port_end = std.mem.indexOfAny(u8, rest[after..], "/?") orelse rest.len;
        const port_slice = rest[after .. after + port_end];
        port = std.fmt.parseInt(u16, port_slice, 10) catch default_port;
        path_start = after + port_end;
    }
    if (path_start >= rest.len or rest[path_start] == '?') {
        return UrlParts{ .scheme = scheme, .host = host, .port = port, .path = "/" };
    }
    return UrlParts{ .scheme = scheme, .host = host, .port = port, .path = rest[path_start..] };
}

/// Minimal percent-encoding for a query string (space -> %20).
fn urlEncode(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const hex = "0123456789ABCDEF";
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '+') {
            try out.append(alloc, c);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, hex[c >> 4]);
            try out.append(alloc, hex[c & 0xF]);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn decodeEntities(alloc: std.mem.Allocator, input: []const u8, out: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, input, i + 1, ';') orelse {
                try out.append(alloc, input[i]);
                i += 1;
                continue;
            };
            const entity = input[i + 1 .. semi];
            const replacement: ?[]const u8 = if (std.mem.eql(u8, entity, "amp"))
                "&"
            else if (std.mem.eql(u8, entity, "lt"))
                "<"
            else if (std.mem.eql(u8, entity, "gt"))
                ">"
            else if (std.mem.eql(u8, entity, "quot"))
                "\""
            else if (std.mem.eql(u8, entity, "apos") or std.mem.eql(u8, entity, "#39"))
                "'"
            else if (std.mem.eql(u8, entity, "nbsp"))
                " "
            else if (std.mem.startsWith(u8, entity, "#x") or std.mem.startsWith(u8, entity, "#"))
                null
            else
                null;
            if (replacement) |r| {
                try out.appendSlice(alloc, r);
                i = semi + 1;
                continue;
            }
        }
        try out.append(alloc, input[i]);
        i += 1;
    }
}

/// Strip tags from an HTML fragment, decode entities, collapse whitespace.
fn textFromHtml(alloc: std.mem.Allocator, html: []const u8, out: *std.ArrayList(u8)) !void {
    var raw = std.ArrayList(u8).empty;
    defer raw.deinit(alloc);
    var in_tag = false;
    for (html) |c| {
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (in_tag) {
            if (c == '>') in_tag = false;
            continue;
        }
        if (c == '\n' or c == '\r' or c == '\t') {
            try raw.append(alloc, ' ');
        } else {
            try raw.append(alloc, c);
        }
    }
    var decoded = std.ArrayList(u8).empty;
    defer decoded.deinit(alloc);
    try decodeEntities(alloc, raw.items, &decoded);

    var prev_space = false;
    for (decoded.items) |c| {
        if (c == ' ') {
            if (!prev_space and out.items.len > 0) try out.append(alloc, ' ');
            prev_space = true;
        } else {
            try out.append(alloc, c);
            prev_space = false;
        }
    }
}

fn resolveUrl(base: []const u8, href: []const u8) []const u8 {
    if (std.mem.indexOf(u8, href, "://") != null) return href;
    if (std.mem.startsWith(u8, href, "//")) {
        const scheme_end = std.mem.indexOf(u8, base, "://") orelse return href;
        var buf: [2048]u8 = undefined;
        const scheme = base[0..scheme_end];
        return std.fmt.bufPrint(&buf, "{s}:{s}", .{ scheme, href }) catch href;
    }
    if (std.mem.startsWith(u8, href, "#") or std.mem.startsWith(u8, href, "javascript:") or std.mem.startsWith(u8, href, "mailto:") or std.mem.startsWith(u8, href, "tel:")) {
        return href;
    }
    if (std.mem.startsWith(u8, href, "/")) {
        const scheme_end = std.mem.indexOf(u8, base, "://") orelse return href;
        const rest = base[scheme_end + 3 ..];
        const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        var buf: [2048]u8 = undefined;
        return std.fmt.bufPrint(&buf, "{s}{s}", .{ base[0 .. scheme_end + 3 + host_end], href }) catch href;
    }
    // Relative: resolve against the directory of the base path.
    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return href;
    const slash = std.mem.lastIndexOfScalar(u8, base[scheme_end + 3 ..], '/');
    const dir_end = if (slash) |s| scheme_end + 3 + s + 1 else scheme_end + 3;
    var buf: [2048]u8 = undefined;
    return std.fmt.bufPrint(&buf, "{s}{s}", .{ base[0..dir_end], href }) catch href;
}

fn fetch(
    alloc: std.mem.Allocator,
    url: []const u8,
    max_bytes: usize,
) ![]const u8 {
    const parts = splitUrl(url) orelse return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(parts.scheme, "https") and !std.ascii.eqlIgnoreCase(parts.scheme, "http")) {
        return error.UnsupportedScheme;
    }

    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    var client = httpc.HttpClient.init(alloc, threaded.io());
    client.config = .{ .read_timeout_ms = READ_TIMEOUT_MS };

    const resp = client.openHttps(parts.host, parts.port, "GET", parts.path, &.{}, "") catch |e| switch (e) {
        error.Timeout => return error.Timeout,
        error.ConnectionFailed => return error.ConnectionFailed,
        error.ConnectionClosed => return error.ConnectionClosed,
        error.InvalidResponse => return error.InvalidResponse,
        error.OutOfMemory => return error.OutOfMemory,
    };
    var resp_var = resp;
    defer resp_var.deinit();

    if (resp.status >= 400) return error.HttpStatus;

    var body = std.ArrayList(u8).empty;
    errdefer body.deinit(alloc);
    var buf: [64 * 1024]u8 = undefined;
    while (body.items.len < max_bytes) {
        const n = resp_var.readBody(&buf) catch return error.ReadFailed;
        if (n == 0) break;
        const room = max_bytes - body.items.len;
        try body.appendSlice(alloc, buf[0..@min(n, room)]);
        if (n < buf.len) {
            // A short read may be a full buffer read in std_http mode; keep
            // looping — readBody returning 0 is the only EOF signal.
        }
    }
    return body.toOwnedSlice(alloc);
}

fn ddgHref(alloc: std.mem.Allocator, href: []const u8) ![]const u8 {
    // DDG wraps results through /l/?uddg=<urlencoded>. Decode it when present.
    if (std.mem.indexOf(u8, href, "uddg=")) |p| {
        const encoded = href[p + 5 ..];
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);
        var i: usize = 0;
        while (i < encoded.len) {
            if (encoded[i] == '%' and i + 2 < encoded.len) {
                const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch {
                    try out.append(alloc, encoded[i]);
                    i += 1;
                    continue;
                };
                const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch {
                    try out.append(alloc, encoded[i]);
                    i += 1;
                    continue;
                };
                try out.append(alloc, @intCast(hi * 16 + lo));
                i += 3;
                continue;
            }
            try out.append(alloc, encoded[i]);
            i += 1;
        }
        return out.toOwnedSlice(alloc);
    }
    return alloc.dupe(u8, href);
}

fn parseDdgSearch(
    alloc: std.mem.Allocator,
    html: []const u8,
    limit: usize,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var found: usize = 0;
    var pos: usize = 0;
    while (found < limit) {
        const marker = std.mem.indexOfPos(u8, html, pos, "result__a") orelse break;
        const tag_end = std.mem.indexOfScalarPos(u8, html, marker, '>') orelse break;
        const tag = html[marker..tag_end];

        var href: []const u8 = "";
        if (std.mem.indexOf(u8, tag, "href=\"")) |hp| {
            const start = marker + hp + "href=\"".len;
            const end = std.mem.indexOfScalarPos(u8, html, start, '"') orelse start;
            href = html[start..end];
        }
        if (href.len == 0 or std.mem.indexOf(u8, href, "duckduckgo.com") != null) {
            pos = tag_end + 1;
            continue;
        }

        const after_tag = tag_end + 1;
        const close = std.mem.indexOfPos(u8, html, after_tag, "</a>") orelse break;
        var title = std.ArrayList(u8).empty;
        defer title.deinit(alloc);
        textFromHtml(alloc, html[after_tag..close], &title) catch {};
        if (title.items.len == 0) {
            pos = close + 4;
            continue;
        }

        // Snippet: next `result__snippet` before the following `result__a`.
        const next_a = std.mem.indexOfPos(u8, html, close, "result__a");
        var snippet = std.ArrayList(u8).empty;
        defer snippet.deinit(alloc);
        if (std.mem.indexOfPos(u8, html, close, "result__snippet")) |sp| {
            const in_block = next_a == null or sp < next_a.?;
            if (in_block) {
                const s_tag_end = std.mem.indexOfScalarPos(u8, html, sp, '>') orelse 0;
                const s_close = std.mem.indexOfPos(u8, html, s_tag_end + 1, "</a>") orelse std.mem.indexOfPos(u8, html, s_tag_end + 1, "</div>");
                if (s_close) |sc| {
                    textFromHtml(alloc, html[s_tag_end + 1 .. sc], &snippet) catch {};
                }
            }
        }

        const url = ddgHref(alloc, href) catch alloc.dupe(u8, href) catch "";
        defer if (url.len > 0) alloc.free(url);

        try appendFmt(alloc, &out, "{d}. {s}\n   {s}\n", .{ found + 1, title.items, url });
        if (snippet.items.len > 0) {
            try appendFmt(alloc, &out, "   {s}\n", .{snippet.items});
        }
        try out.append(alloc, '\n');

        found += 1;
        pos = if (next_a) |na| na else close + 4;
    }

    if (found == 0) {
        try out.appendSlice(alloc, "No results found.\n");
    }
    return out.toOwnedSlice(alloc);
}

/// Fetch a page and reduce it to readable text + a link list.
fn extractPage(
    alloc: std.mem.Allocator,
    base_url: []const u8,
    html: []const u8,
) ![]const u8 {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(alloc);
    var links = std.ArrayList([]const u8).empty;
    defer {
        for (links.items) |l| alloc.free(l);
        links.deinit(alloc);
    }

    var i: usize = 0;
    while (i < html.len) {
        // Skip <script> / <style> / comments wholesale.
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            const end = std.mem.indexOf(u8, html[i..], "-->") orelse html.len;
            i += end + 3;
            continue;
        }
        if (html[i] == '<') {
            const lower = html[i..];
            if (std.mem.startsWith(u8, lower, "<script") or
                std.mem.startsWith(u8, lower, "<style") or
                std.mem.startsWith(u8, lower, "<SCRIPT") or
                std.mem.startsWith(u8, lower, "<STYLE"))
            {
                const close_tag = if (std.mem.startsWith(u8, lower, "<script") or std.mem.startsWith(u8, lower, "<SCRIPT"))
                    std.mem.indexOf(u8, lower, "</script>") orelse std.mem.indexOf(u8, lower, "</SCRIPT>")
                else
                    std.mem.indexOf(u8, lower, "</style>") orelse std.mem.indexOf(u8, lower, "</STYLE>");
                if (close_tag) |ct| {
                    i += ct + 8;
                    continue;
                }
            }
            const tag_end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse break;
            const tag = html[i + 1 .. tag_end];
            // Collect anchor links.
            if (tag.len > 0 and (tag[0] == 'a' or (tag.len > 1 and tag[0] == 'a' and tag[1] == ' '))) {
                if (std.mem.indexOf(u8, tag, "href=\"")) |hp| {
                    const href_start = i + 1 + hp + "href=\"".len;
                    const href_end = std.mem.indexOfScalarPos(u8, html, href_start, '"') orelse href_start;
                    const href = html[href_start..href_end];
                    if (href.len > 0 and !std.mem.startsWith(u8, href, "javascript:") and
                        !std.mem.startsWith(u8, href, "#") and !std.mem.startsWith(u8, href, "mailto:"))
                    {
                        const resolved = resolveUrl(base_url, href);
                        if (links.items.len < MAX_LINKS) {
                            links.append(alloc, alloc.dupe(u8, resolved) catch continue) catch {};
                        }
                    }
                }
            }
            i = tag_end + 1;
            continue;
        }
        if (text.items.len < MAX_TEXT_BYTES) {
            try text.append(alloc, html[i]);
        }
        i += 1;
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    if (text.items.len == 0) {
        try out.appendSlice(alloc, "Page returned no readable text.\n");
    } else {
        var clean = std.ArrayList(u8).empty;
        defer clean.deinit(alloc);
        try textFromHtml(alloc, text.items, &clean);
        const max = @min(clean.items.len, MAX_TEXT_BYTES);
        try out.appendSlice(alloc, clean.items[0..max]);
        if (clean.items.len > max) try out.appendSlice(alloc, "\n…[truncated]");
    }
    if (links.items.len > 0) {
        try out.appendSlice(alloc, "\n\nLinks:\n");
        for (links.items, 0..) |l, li| {
            try appendFmt(alloc, &out, "- {s}\n", .{l});
            _ = li;
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn executeSearch(alloc: std.mem.Allocator, sandbox: ?*Sandbox, call: ToolCall) !ToolResult {
    _ = sandbox;
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const query = map.get("query") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing query argument" };
    };
    if (query.len == 0) {
        return ToolResult{ .success = false, .output = "", .err_msg = "Empty query" };
    }
    const limit = std.fmt.parseInt(usize, map.get("limit") orelse "5", 10) catch 5;

    const encoded = urlEncode(alloc, query) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Query encode failed" };
    };
    defer alloc.free(encoded);
    const url = std.fmt.allocPrint(alloc, "https://html.duckduckgo.com/html/?q={s}&kl=us-en", .{encoded}) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "URL build failed" };
    };
    defer alloc.free(url);

    const html = fetch(alloc, url, MAX_READ_BYTES) catch |e| {
        return ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(alloc, "Web search failed: {s}", .{@errorName(e)}),
            .err_msg = "Search fetch failed",
        };
    };
    defer alloc.free(html);

    const results = parseDdgSearch(alloc, html, limit) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Search parse failed" };
    };
    return ToolResult{ .success = true, .output = results };
}

pub fn executeScrape(alloc: std.mem.Allocator, sandbox: ?*Sandbox, call: ToolCall) !ToolResult {
    _ = sandbox;
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const url = map.get("url") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing url argument" };
    };
    if (std.mem.indexOf(u8, url, "://") == null) {
        return ToolResult{ .success = false, .output = "", .err_msg = "URL must include scheme (http:// or https://)" };
    }

    const html = fetch(alloc, url, MAX_READ_BYTES) catch |e| {
        return ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(alloc, "Fetch failed: {s}", .{@errorName(e)}),
            .err_msg = "Scrape fetch failed",
        };
    };
    defer alloc.free(html);

    const page = extractPage(alloc, url, html) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Scrape parse failed" };
    };
    return ToolResult{ .success = true, .output = page };
}

test "splitUrl parses https with port" {
    const p = splitUrl("https://example.com:8443/foo/bar?q=1").?;
    try std.testing.expectEqualStrings("https", p.scheme);
    try std.testing.expectEqualStrings("example.com", p.host);
    try std.testing.expectEqual(@as(u16, 8443), p.port);
    try std.testing.expectEqualStrings("/foo/bar?q=1", p.path);
}

test "splitUrl default port and bare host" {
    const p = splitUrl("https://example.com").?;
    try std.testing.expectEqual(@as(u16, 443), p.port);
    try std.testing.expectEqualStrings("/", p.path);
}

test "splitUrl rejects garbage" {
    try std.testing.expect(splitUrl("not-a-url") == null);
}

test "urlEncode escapes spaces and quotes" {
    const alloc = std.testing.allocator;
    const enc = try urlEncode(alloc, "a b&c");
    defer alloc.free(enc);
    try std.testing.expectEqualStrings("a%20b%26c", enc);
}

test "textFromHtml strips tags and decodes entities" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try textFromHtml(alloc, "<p>Hello <b>World</b> &amp; friends</p>", &out);
    try std.testing.expectEqualStrings("Hello World & friends", out.items);
}

test "resolveUrl handles relative and root paths" {
    try std.testing.expectEqualStrings("https://a.com/x", resolveUrl("https://a.com/page", "/x"));
    try std.testing.expectEqualStrings("https://a.com/dir/y", resolveUrl("https://a.com/dir/page", "y"));
    try std.testing.expectEqualStrings("https://a.com/z", resolveUrl("https://a.com", "//a.com/z"));
}
