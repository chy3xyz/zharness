//! Web tools (dev.md §XXII): `web_fetch` and `web_search`.
//!
//! Contract:
//! - Two registerable `ToolDefinition`s matching the tool/registry.zig schema
//!   style, plus executors that are pure functions of (alloc, cwd, args_json)
//!   exactly like the builtin executors in tool/builtin.zig — same ToolCall /
//!   ToolResult types, same ownership rules (`freeResult`).
//! - Transport is curl through the clib popen helpers (no std.http — see
//!   docs/architecture.md "Why curl, not std.http"). All user-controlled
//!   strings are shell-quoted before reaching /bin/sh.
//! - `web_fetch`: GET a URL, size-capped (~1 MB default) with both a curl-side
//!   `--max-filesize` and an in-Zig read cap, guarded to textual content
//!   types; binary payloads are refused.
//! - `web_search`: DuckDuckGo HTML endpoint (`https://html.duckduckgo.com/html/?q=…`)
//!   parsed with a small fixture-testable extractor for result titles/hrefs,
//!   unwrapping DDG's `uddg=` redirect links.
//!
//! Offline testing: every parser/encoder here is a pure function exercised
//! against fixture strings; the popen paths are covered by a `file://`
//! round-trip which never touches the network.

const std = @import("std");
const stdc = std.c;
const clib = @import("../clib.zig");
const builtin_tools = @import("builtin.zig");
const registry_mod = @import("registry.zig");
const web_provider = @import("../web/provider.zig");

pub const ToolCall = builtin_tools.ToolCall;
pub const ToolResult = builtin_tools.ToolResult;
pub const freeResult = builtin_tools.freeResult;

/// Default response size cap for web_fetch (~1 MB).
pub const MaxFetchBytes: usize = 1024 * 1024;
/// Hard wall for search pages (HTML is verbose; results live near the top).
pub const MaxSearchBytes: usize = 2 * 1024 * 1024;

// ── native web provider seam ────────────────────────────────────────────────

/// Built-in fetch provider name (curl). The search provider is "duckduckgo".
pub const curl_provider_name = "curl";
pub const ddg_provider_name = "duckduckgo";

fn providerFetchImpl(ctx: ?*anyopaque, alloc: std.mem.Allocator, url: []const u8, max_bytes: usize) anyerror!ToolResult {
    _ = ctx;
    return fetchViaCurl(alloc, url, max_bytes);
}

fn providerSearchImpl(ctx: ?*anyopaque, alloc: std.mem.Allocator, query: []const u8, limit: usize) anyerror!ToolResult {
    _ = ctx;
    return searchViaDdg(alloc, query, limit);
}

/// Ensure the native provider seam has its two built-in providers registered.
/// Idempotent — safe to call on every tool invocation and at wiring time.
/// Third-party providers (Exa, Perplexity, etc.) are NOT registered here;
/// they remain behind MCP (`tool/mcp_bridge.zig`).
pub fn ensureWebProviders(alloc: std.mem.Allocator) !void {
    if (!web_provider.hasFetchProvider(curl_provider_name)) {
        try web_provider.registerFetchProvider(alloc, .{
            .name = curl_provider_name,
            .description = "Native HTTP fetch via curl (text-only, size-capped)",
            .fetchFn = providerFetchImpl,
        });
    }
    if (!web_provider.hasSearchProvider(ddg_provider_name)) {
        try web_provider.registerSearchProvider(alloc, .{
            .name = ddg_provider_name,
            .description = "Web search via DuckDuckGo HTML endpoint",
            .searchFn = providerSearchImpl,
        });
    }
}

/// Expose provider seam for tests / wiring introspection.
pub fn activeFetchProviderName() ?[]const u8 {
    return web_provider.activeFetchName();
}
pub fn activeSearchProviderName() ?[]const u8 {
    return web_provider.activeSearchName();
}

// ── registration ────────────────────────────────────────────────────────────

/// Register both web tools into a registry. Call alongside
/// `registry.registerBuiltins` at wiring time (main.zig owns the registry).
pub fn registerWebTools(reg: *registry_mod.ToolRegistry) !void {
    try reg.register(.{
        .name = "web_fetch",
        .description = "Fetch a URL over HTTP(S) and return its body as text. Textual content types only (text/*, JSON, XML, YAML, JS, CSV) — binary downloads are refused. Output is capped at ~1MB.",
        .category = .search,
        .parameters_json =
        \\{"type":"object","properties":{"url":{"type":"string","description":"Absolute http(s) URL to fetch"},"max_bytes":{"type":"integer","description":"Optional response size cap in bytes (default 1048576)"}},"required":["url"]}
        ,
    });
    try reg.register(.{
        .name = "web_search",
        .description = "Search the web via the DuckDuckGo HTML endpoint. Returns numbered [title](url) links for the top matches.",
        .category = .search,
        .parameters_json =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Search query text"},"limit":{"type":"integer","description":"Maximum number of results to return (default 5)"}},"required":["query"]}
        ,
    });
}

/// Dispatch a tool call to a web executor (mirror of builtin.execute's shape).
/// `cwd` exists for signature parity with the other executors; web tools do
/// not touch the workspace filesystem.
pub fn execute(alloc: std.mem.Allocator, cwd: []const u8, call: ToolCall) !ToolResult {
    _ = cwd;
    if (std.mem.eql(u8, call.name, "web_fetch")) return webFetch(alloc, call);
    if (std.mem.eql(u8, call.name, "web_search")) return webSearch(alloc, call);
    // err_msg must be allocator-owned: callers release results via freeResult.
    return failMsg(alloc, "unknown tool");
}

// ── web_fetch ───────────────────────────────────────────────────────────────

fn webFetch(alloc: std.mem.Allocator, call: ToolCall) !ToolResult {
    var map = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &map);
    const url = map.get("url") orelse
        return failMsg(alloc, "missing url");
    if (!schemeAllowed(url))
        return failMsg(alloc, "url must start with http:// or https://");

    var max_bytes: usize = MaxFetchBytes;
    if (map.get("max_bytes")) |v| {
        max_bytes = std.fmt.parseInt(usize, std.mem.trim(u8, v, " "), 10) catch MaxFetchBytes;
    }
    if (max_bytes == 0) max_bytes = MaxFetchBytes;

    // Route through the native provider seam when an active fetch provider is
    // selected. The seam is additive: if no provider is active (or registry
    // was cleared in tests), fall back to the direct curl path. ensureWebProviders
    // seeds the two built-in providers (curl + duckduckgo) on first use so
    // MVP keeps working without explicit init.
    try ensureWebProviders(alloc);
    if (web_provider.getActiveFetchProvider()) |p| {
        return try p.fetchFn(p.ctx, alloc, url, max_bytes);
    }
    return fetchViaCurl(alloc, url, max_bytes);
}

/// Core curl fetch implementation — shared by the direct path and the
/// "curl" provider. Pure IO via curl/DuckDuckGo helpers; testable via file://.
pub fn fetchViaCurl(alloc: std.mem.Allocator, url: []const u8, max_bytes: usize) !ToolResult {
    // curl writes "<body>\n<<ZH_META>><content_type>\t<http_code>". A plain
    // sentinel is used because curl's -w only interprets \n/\r/\t escapes
    // (no \x01) across versions; lastIndexOf makes collisions harmless.
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(alloc);
    try cmd.appendSlice(alloc, "curl --silent --show-error --location --fail --max-time 60 --max-filesize ");
    try cmd.print(alloc, "{d}", .{max_bytes});
    try cmd.appendSlice(alloc, " --write-out '\\n<<ZH_META>>%{content_type}\\t%{http_code}' -- ");
    try appendQuoted(alloc, &cmd, url);

    const fetched = try runCapturing(alloc, cmd.items, max_bytes + 4096);
    defer alloc.free(fetched.output);

    const parts = splitFetchOutput(fetched.output);
    if (!fetched.ok) {
        if (parts.meta) |m| {
            const msg = try std.fmt.allocPrint(alloc, "fetch failed ({s})", .{m});
            return ToolResult{ .success = false, .output = "", .err_msg = msg };
        }
        return failMsg(alloc, "fetch failed");
    }
    if (parts.body.len == 0)
        return failMsg(alloc, "empty response body");

    if (parts.content_type) |ct| {
        if (!contentTypeIsText(ct)) {
            const msg = try std.fmt.allocPrint(alloc, "refusing non-text content-type '{s}'", .{ct});
            return ToolResult{ .success = false, .output = "", .err_msg = msg };
        }
    } else if (fetched.hit_cap) {
        return failMsg(alloc, "response exceeded size cap before content-type could be verified");
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const keep = @min(parts.body.len, max_bytes);
    try out.appendSlice(alloc, parts.body[0..keep]);
    if (keep < parts.body.len) try out.appendSlice(alloc, "\n... [truncated]");
    return ToolResult{ .success = true, .output = try out.toOwnedSlice(alloc) };
}

/// Sentinel curl appends before its `%{content_type}\t%{http_code}` trailer.
const fetch_meta_marker = "<<ZH_META>>";

const FetchParts = struct {
    body: []const u8,
    /// "<content_type>\t<http_code>" when the curl trailer arrived.
    meta: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

/// Split a captured fetch output into body and meta trailer. Pure.
fn splitFetchOutput(raw: []const u8) FetchParts {
    const marker_pos = std.mem.lastIndexOf(u8, raw, fetch_meta_marker) orelse
        return .{ .body = std.mem.trimEnd(u8, raw, "\r\n") };
    const meta = std.mem.trim(u8, raw[marker_pos + fetch_meta_marker.len ..], "\r\n");
    // Body loses only the newline of the trailer template, not page bytes.
    const body = std.mem.trimEnd(u8, raw[0..marker_pos], "\n\r");
    var parts = FetchParts{ .body = body, .meta = meta };
    if (std.mem.indexOfScalar(u8, meta, '\t')) |tab| {
        parts.content_type = meta[0..tab];
    }
    return parts;
}

/// Guard: allow textual content types only. Empty (missing header, file://)
/// counts as allowed — curl could not know better than us.
fn contentTypeIsText(ct: []const u8) bool {
    if (ct.len == 0) return true;
    if (std.mem.startsWith(u8, ct, "text/")) return true;
    // Lowercase the type into a bounded buffer; all allow-list needles are
    // ASCII and already lowercase.
    var lower: [128]u8 = undefined;
    const n = @min(ct.len, lower.len);
    const hay = lower[0..n];
    for (ct[0..n], 0..) |ch, i| hay[i] = std.ascii.toLower(ch);
    const allow_substrings = [_][]const u8{
        "json", "xml", "yaml", "javascript", "csv", "rss", "atom",
    };
    for (allow_substrings) |s| {
        if (std.mem.indexOf(u8, hay, s) != null) return true;
    }
    return false;
}

fn schemeAllowed(url: []const u8) bool {
    // file:// stays allowed: zharness already grants the shell tool, so local
    // reads grant no new privilege — and they let the fetch pipeline be
    // exercised fully offline (tests rely on this).
    return std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "file://");
}

// ── web_search ──────────────────────────────────────────────────────────────

pub const SearchResult = struct {
    title: []u8,
    url: []u8,
};

const duckduckgo_html_endpoint = "https://html.duckduckgo.com/html/";

fn webSearch(alloc: std.mem.Allocator, call: ToolCall) !ToolResult {
    var map = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &map);
    const query = map.get("query") orelse
        return failMsg(alloc, "missing query");
    if (std.mem.trim(u8, query, " \t\r\n").len == 0)
        return failMsg(alloc, "empty query");

    var limit: usize = 5;
    if (map.get("limit")) |v| {
        limit = std.fmt.parseInt(usize, std.mem.trim(u8, v, " "), 10) catch 5;
    }
    if (limit == 0) limit = 1;
    if (limit > 20) limit = 20;

    try ensureWebProviders(alloc);
    if (web_provider.getActiveSearchProvider()) |p| {
        return try p.searchFn(p.ctx, alloc, query, limit);
    }
    return searchViaDdg(alloc, query, limit);
}

/// Core DuckDuckGo search implementation — shared by direct path and
/// "duckduckgo" provider.
pub fn searchViaDdg(alloc: std.mem.Allocator, query: []const u8, limit: usize) !ToolResult {
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(alloc);
    try cmd.appendSlice(alloc, "curl --silent --show-error --location --fail --max-time 30 --get ");
    try appendQuoted(alloc, &cmd, duckduckgo_html_endpoint);
    try cmd.appendSlice(alloc, " --data-urlencode ");
    try appendQuoted(alloc, &cmd, query);

    const fetched = runCapturing(alloc, cmd.items, MaxSearchBytes) catch |e|
        return failMsg(alloc, @errorName(e));
    defer alloc.free(fetched.output);
    if (!fetched.ok)
        return failMsg(alloc, "search request failed");

    const results = try parseResults(alloc, fetched.output, limit);
    defer {
        for (results) |r| {
            alloc.free(r.title);
            alloc.free(r.url);
        }
        alloc.free(results);
    }

    if (results.len == 0)
        return ToolResult{ .success = true, .output = try alloc.dupe(u8, "no results") };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (results, 1..) |r, i| {
        try out.print(alloc, "{d}. [{s}]({s})\n", .{ i, r.title, r.url });
    }
    return ToolResult{ .success = true, .output = try out.toOwnedSlice(alloc) };
}

/// Parse DuckDuckGo HTML result anchors:
///   <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2F…&rut=x">Title</a>
/// Titles may carry inner tags (&lt;b&gt;) and entities; hrefs may be wrapped
/// in the uddg= redirect. Pure and fixture-testable.
pub fn parseResults(alloc: std.mem.Allocator, html: []const u8, limit: usize) ![]SearchResult {
    var out: std.ArrayList(SearchResult) = .empty;
    errdefer {
        for (out.items) |r| {
            alloc.free(r.title);
            alloc.free(r.url);
        }
        out.deinit(alloc);
    }
    var cursor: usize = 0;
    while (out.items.len < limit) {
        const anchor = std.mem.indexOfPos(u8, html, cursor, "class=\"result__a\"") orelse break;
        // Confine scanning to this anchor tag.
        const tag_close_rel = std.mem.indexOfPos(u8, html, anchor, ">") orelse break;
        const title_close = std.mem.indexOfPos(u8, html, tag_close_rel, "</a>") orelse break;

        var href: ?[]const u8 = null;
        if (std.mem.indexOf(u8, html[anchor..tag_close_rel], "href=\"")) |hpos| {
            const hstart = anchor + hpos + "href=\"".len;
            const hend_rel = std.mem.indexOfScalarPos(u8, html, hstart, '"') orelse tag_close_rel;
            href = html[hstart..hend_rel];
        }
        const title_raw = html[tag_close_rel + 1 .. title_close];

        if (href) |h| {
            const stripped = try stripTags(alloc, title_raw);
            defer alloc.free(stripped);
            const title = try decodeEntities(alloc, stripped);
            errdefer alloc.free(title);
            const url = try normalizeHref(alloc, std.mem.trim(u8, h, " \t\r\n"));
            errdefer alloc.free(url);
            if (title.len > 0 and url.len > 0) {
                try out.append(alloc, .{ .title = title, .url = url });
            } else {
                alloc.free(title);
                alloc.free(url);
            }
        }
        cursor = title_close + 4;
    }
    return out.toOwnedSlice(alloc);
}

/// Unwrap DDG redirect links (`…/l/?uddg=<percent-encoded>&rut=…`) and make
/// protocol-relative hrefs absolute. Caller owns the result.
fn normalizeHref(alloc: std.mem.Allocator, href: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, href, "uddg=")) |upos| {
        const vstart = upos + "uddg=".len;
        const vend = std.mem.indexOfScalarPos(u8, href, vstart, '&') orelse href.len;
        return percentDecode(alloc, href[vstart..vend]);
    }
    if (std.mem.startsWith(u8, href, "//")) {
        return std.fmt.allocPrint(alloc, "https:{s}", .{href});
    }
    return alloc.dupe(u8, href);
}

/// Remove `<tag>` spans (case-insensitive scan; no attribute parsing needed
/// because we drop everything between '<' and '>').
fn stripTags(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    // Covers both success and error exits; the returned value is a dupe, so
    // only this work buffer is released here.
    defer out.deinit(alloc);
    var in_tag = false;
    for (input) |ch| {
        if (ch == '<') {
            in_tag = true;
            continue;
        }
        if (ch == '>') {
            in_tag = false;
            continue;
        }
        if (!in_tag) try out.append(alloc, ch);
    }
    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    return alloc.dupe(u8, trimmed);
}

/// Decode the HTML entities DDG actually emits (plus numeric decimal refs).
/// Unknown entities pass through unchanged.
fn decodeEntities(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '&') {
            try out.append(alloc, input[i]);
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, input, i, ';') orelse {
            try out.append(alloc, input[i]);
            continue;
        };
        const ent = input[i + 1 .. semi];
        const replacement: ?[]const u8 = if (std.mem.eql(u8, ent, "amp")) "&" else if (std.mem.eql(u8, ent, "lt")) "<" else if (std.mem.eql(u8, ent, "gt")) ">" else if (std.mem.eql(u8, ent, "quot")) "\"" else if (std.mem.eql(u8, ent, "#x27") or std.mem.eql(u8, ent, "#39")) "'" else if (std.mem.eql(u8, ent, "nbsp")) " " else if (std.mem.eql(u8, ent, "hellip")) "…" else null;
        if (replacement) |rep| {
            try out.appendSlice(alloc, rep);
            i = semi;
            continue;
        }
        // Numeric decimal entity: &#NN;
        if (ent.len > 1 and ent[0] == '#') {
            if (std.fmt.parseInt(u21, ent[1..], 10)) |cp| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                if (n > 0) {
                    try out.appendSlice(alloc, buf[0..n]);
                    i = semi;
                    continue;
                }
            } else |_| {}
        }
        // Unknown: emit verbatim.
        try out.appendSlice(alloc, input[i .. semi + 1]);
        i = semi;
    }
    return out.toOwnedSlice(alloc);
}

/// Percent-decode %XX escapes; malformed sequences stay literal.
pub fn percentDecode(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try out.append(alloc, input[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try out.append(alloc, input[i]);
                continue;
            };
            try out.append(alloc, hi * 16 + lo);
            i += 2;
            continue;
        }
        try out.append(alloc, input[i]);
    }
    return out.toOwnedSlice(alloc);
}

// ── subprocess plumbing ─────────────────────────────────────────────────────

const CapturedRun = struct {
    ok: bool,
    output: []u8,
    /// True when output exceeded `cap_bytes` (excess was drained, not stored).
    hit_cap: bool = false,
};

/// Run `command` via /bin/sh, capturing stdout capped at `cap_bytes`
/// (excess output is drained but discarded). Never throws for command
/// failures — the exit status lands in `.ok`.
fn runCapturing(alloc: std.mem.Allocator, command: []const u8, cap_bytes: usize) !CapturedRun {
    const cmd_z = try alloc.dupeSentinel(u8, command, 0);
    defer alloc.free(cmd_z);
    const fp = clib.popenRead(cmd_z.ptr) orelse return error.SpawnFailed;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var hit_cap = false;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = stdc.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        if (out.items.len < cap_bytes) {
            const room = cap_bytes - out.items.len;
            try out.appendSlice(alloc, buf[0..@min(n, room)]);
            if (room < n) hit_cap = true;
        } else {
            hit_cap = true;
        }
    }
    const status = clib.pclosePipe(fp);
    const exited = (status & 0x7f) == 0;
    const exit_code: i32 = if (exited) @intCast((status >> 8) & 0xff) else -1;
    return .{ .ok = exited and exit_code == 0, .output = try out.toOwnedSlice(alloc), .hit_cap = hit_cap };
}

fn failMsg(alloc: std.mem.Allocator, msg: []const u8) !ToolResult {
    return ToolResult{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, msg) };
}

// ── arg helpers (mirrors of builtin.zig's private ones) ────────────────────

fn appendQuoted(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '\'');
    for (s) |ch| {
        if (ch == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, ch);
        }
    }
    try out.append(alloc, '\'');
}

fn unescapeJson(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                '/' => try out.append(alloc, '/'),
                'n' => try out.append(alloc, '\n'),
                't' => try out.append(alloc, '\t'),
                'r' => try out.append(alloc, '\r'),
                else => try out.append(alloc, raw[i]),
            }
        } else {
            try out.append(alloc, raw[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn parseArgs(alloc: std.mem.Allocator, json_args: []const u8) !std.StringHashMap([]u8) {
    var map = std.StringHashMap([]u8).init(alloc);
    errdefer {
        var it = map.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        map.deinit();
    }
    var i: usize = 0;
    while (i < json_args.len) : (i += 1) {
        if (json_args[i] != '"') continue;
        i += 1;
        const key_start = i;
        while (i < json_args.len and json_args[i] != '"') : (i += 1) {
            if (json_args[i] == '\\' and i + 1 < json_args.len) i += 1;
        }
        if (i >= json_args.len) break;
        const key_un = try unescapeJson(alloc, json_args[key_start..i]);
        errdefer alloc.free(key_un);
        i += 1;
        while (i < json_args.len and json_args[i] != ':') : (i += 1) {}
        if (i >= json_args.len) break;
        i += 1;
        while (i < json_args.len and (json_args[i] == ' ' or json_args[i] == '\t')) : (i += 1) {}
        if (i >= json_args.len) break;
        var value: []u8 = try alloc.dupe(u8, "");
        errdefer alloc.free(value);
        if (json_args[i] == '"') {
            i += 1;
            const v_start = i;
            while (i < json_args.len and json_args[i] != '"') : (i += 1) {
                if (json_args[i] == '\\' and i + 1 < json_args.len) i += 1;
            }
            value = try unescapeJson(alloc, json_args[v_start..i]);
            if (i < json_args.len) i += 1;
        } else if (json_args[i] == '-' or std.ascii.isDigit(json_args[i])) {
            const n_start = i;
            while (i < json_args.len and (std.ascii.isDigit(json_args[i]) or json_args[i] == '.' or json_args[i] == '-')) : (i += 1) {}
            value = try alloc.dupe(u8, json_args[n_start..i]);
        } else if (json_args[i] == 't' or json_args[i] == 'f') {
            const b_start = i;
            while (i < json_args.len and std.ascii.isAlphabetic(json_args[i])) : (i += 1) {}
            value = try alloc.dupe(u8, json_args[b_start..i]);
        }
        try map.put(key_un, value);
    }
    return map;
}

fn freeArgs(alloc: std.mem.Allocator, map: *std.StringHashMap([]u8)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        alloc.free(e.key_ptr.*);
        alloc.free(e.value_ptr.*);
    }
    map.deinit();
}

// ── tests ───────────────────────────────────────────────────────────────────

test "splitFetchOutput separates body from meta trailer" {
    const raw = "<html>hi</html>\n<<ZH_META>>text/html; charset=utf-8\t200\n";
    const parts = splitFetchOutput(raw);
    try std.testing.expectEqualStrings("<html>hi</html>", parts.body);
    try std.testing.expectEqualStrings("200", parts.meta.?["text/html; charset=utf-8\t".len..]);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", parts.content_type.?);
}

test "splitFetchOutput tolerates missing marker" {
    const parts = splitFetchOutput("plain body");
    try std.testing.expectEqualStrings("plain body", parts.body);
    try std.testing.expect(parts.meta == null);
    try std.testing.expect(parts.content_type == null);
}

test "contentTypeIsText matrix" {
    try std.testing.expect(contentTypeIsText(""));
    try std.testing.expect(contentTypeIsText("text/plain"));
    try std.testing.expect(contentTypeIsText("text/html; charset=utf-8"));
    try std.testing.expect(contentTypeIsText("application/json"));
    try std.testing.expect(contentTypeIsText("application/vnd.api+json"));
    try std.testing.expect(contentTypeIsText("application/xml"));
    try std.testing.expect(contentTypeIsText("application/javascript"));
    try std.testing.expect(!contentTypeIsText("image/png"));
    try std.testing.expect(!contentTypeIsText("application/octet-stream"));
    try std.testing.expect(!contentTypeIsText("application/pdf"));
    try std.testing.expect(!contentTypeIsText("video/mp4"));
}

test "percentDecode decodes escapes and keeps stray percent literal" {
    const alloc = std.testing.allocator;
    const a = try percentDecode(alloc, "https%3A%2F%2Fexample.com%2Fa%20b");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("https://example.com/a b", a);
    const b = try percentDecode(alloc, "50%off %zz");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("50%off %zz", b);
}

test "normalizeHref unwraps uddg redirects and upgrades protocol-relative" {
    const alloc = std.testing.allocator;
    const a = try normalizeHref(alloc, "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&rut=abc123");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("https://example.com/page", a);
    const b = try normalizeHref(alloc, "//example.org/direct");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("https://example.org/direct", b);
    const c = try normalizeHref(alloc, "https://plain.example/");
    defer alloc.free(c);
    try std.testing.expectEqualStrings("https://plain.example/", c);
}

test "stripTags removes markup and trims edge whitespace" {
    const alloc = std.testing.allocator;
    const stripped = try stripTags(alloc, "  Zig  <b>Lang</b> Guide\n");
    defer alloc.free(stripped);
    // Interior spacing is preserved verbatim; only tag spans and edge
    // whitespace disappear.
    try std.testing.expectEqualStrings("Zig  Lang Guide", stripped);
}

test "decodeEntities decodes named, numeric and hex refs" {
    const alloc = std.testing.allocator;
    const a = try decodeEntities(alloc, "A &amp; B &lt;tag&gt; &#39;q&#x27; &quot;s&quot; end");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("A & B <tag> 'q' \"s\" end", a);
    // Unknown entities pass through unchanged; stray ampersands survive.
    const b = try decodeEntities(alloc, "100% &amp; &mystery; plain");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("100% & &mystery; plain", b);
}

// Fixture modeled on DuckDuckGo html.duckduckgo.com/html/ output: redirect-
// wrapped link with encoded URL + entity-laden title, a direct link, and
// snippet noise that must NOT be picked up as a result.
const ddg_fixture =
    \\<div class="result results_links results_links_deep web-result ">
    \\<h2 class="result__title">
    \\  <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2F&amp;rut=a1b2"><b>Zig</b> Programming Language</a>
    \\</h2>
    \\<a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fsnippets.example%2Fx&amp;rut=z9">should not appear</a>
    \\</div>
    \\<div class="result results_links results_links_deep web-result ">
    \\<h2 class="result__title">
    \\  <a rel="nofollow" class="result__a" href="https://zig.news/">Zig NEWS &amp; More</a>
    \\</h2>
    \\</div>
;

test "parseResults extracts titles and urls from fixture HTML" {
    const alloc = std.testing.allocator;
    const results = try parseResults(alloc, ddg_fixture, 10);
    defer {
        for (results) |r| {
            alloc.free(r.title);
            alloc.free(r.url);
        }
        alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("Zig Programming Language", results[0].title);
    try std.testing.expectEqualStrings("https://ziglang.org/", results[0].url);
    try std.testing.expectEqualStrings("Zig NEWS & More", results[1].title);
    try std.testing.expectEqualStrings("https://zig.news/", results[1].url);
}

test "parseResults honors limit" {
    const alloc = std.testing.allocator;
    const results = try parseResults(alloc, ddg_fixture, 1);
    defer {
        for (results) |r| {
            alloc.free(r.title);
            alloc.free(r.url);
        }
        alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "registerWebTools registers schema-valid definitions" {
    const alloc = std.testing.allocator;
    var reg = try registry_mod.ToolRegistry.init(alloc);
    defer reg.deinit();
    try registerWebTools(&reg);
    try std.testing.expect(reg.contains("web_fetch"));
    try std.testing.expect(reg.contains("web_search"));
    const def = reg.get("web_fetch").?;
    try std.testing.expect(std.mem.indexOf(u8, def.parameters_json, "\"required\":[\"url\"]") != null);
    const json = try reg.buildToolsJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "web_search") != null);
}

test "execute rejects unknown tool names and missing args" {
    const alloc = std.testing.allocator;
    var r1 = try execute(alloc, "/tmp", .{ .name = "nope", .arguments = "{}" });
    defer freeResult(alloc, &r1);
    try std.testing.expect(!r1.success);

    var r2 = try execute(alloc, "/tmp", .{ .name = "web_fetch", .arguments = "{}" });
    defer freeResult(alloc, &r2);
    try std.testing.expect(!r2.success);
    try std.testing.expectEqualStrings("missing url", r2.err_msg.?);

    var r3 = try execute(alloc, "/tmp", .{ .name = "web_search", .arguments = "{\"query\":\"\"}" });
    defer freeResult(alloc, &r3);
    try std.testing.expect(!r3.success);
}

test "webFetch refuses unsupported schemes" {
    const alloc = std.testing.allocator;
    var r = try execute(alloc, "/tmp", .{ .name = "web_fetch", .arguments = "{\"url\":\"ftp://example.com/x\"}" });
    defer freeResult(alloc, &r);
    try std.testing.expect(!r.success);
}

// End-to-end smoke over the real popen path using curl's file:// support —
// exercises quoting, the meta-trailer split and the content-type guard with
// zero network access.
//
// Note: the mkstemp path comes from clib.createPrivateTemp, whose returned
// slice aliases an over-capacity work buffer; freeing it through the exact
// tracking allocator trips a size mismatch (a clib.zig quirk we must not
// edit around here), so the path lives in an untracked arena instead.
test "webFetch round-trips a local file through curl" {
    const alloc = std.testing.allocator;
    // Isolate from provider registry leaks (global GPA now, but still clear for determinism).
    const wp = @import("../web/provider.zig");
    wp.clearAll(alloc);
    defer wp.clearAll(alloc);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const tmp_path = (try clib.createPrivateTemp(arena.allocator(), "zharness_webfetch_test_")) orelse return error.TestUnexpectedResult;
    defer clib.unlinkPath(tmp_path);

    // Write fixture content via libc FILE (same pattern as model.zig).
    {
        const f = stdc.fopen(tmp_path.ptr, "wb") orelse return error.TestUnexpectedResult;
        _ = stdc.fwrite("hello from zharness webfetch", 1, 28, f);
        _ = stdc.fclose(f);
    }

    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "file://{s}", .{tmp_path});
    var args_buf: [640]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\"}}", .{url});

    var r = try execute(alloc, "/tmp", .{ .name = "web_fetch", .arguments = args });
    defer freeResult(alloc, &r);
    try std.testing.expect(r.success);
    try std.testing.expectEqualStrings("hello from zharness webfetch", r.output);
}

test "web provider seam registers two native providers" {
    const alloc = std.testing.allocator;
    const wp = @import("../web/provider.zig");
    wp.clearAll(alloc);
    defer wp.clearAll(alloc);
    try ensureWebProviders(alloc);
    try std.testing.expect(wp.hasFetchProvider(curl_provider_name));
    try std.testing.expect(wp.hasSearchProvider(ddg_provider_name));
    try std.testing.expectEqual(@as(usize, 1), wp.fetchProviderCount());
    try std.testing.expectEqual(@as(usize, 1), wp.searchProviderCount());
    try std.testing.expectEqualStrings(curl_provider_name, wp.activeFetchName().?);
    try std.testing.expectEqualStrings(ddg_provider_name, wp.activeSearchName().?);
}

test "web provider seam selection is respected by executors" {
    const alloc = std.testing.allocator;
    const wp = @import("../web/provider.zig");
    wp.clearAll(alloc);
    defer wp.clearAll(alloc);

    const mockFetch = struct {
        fn f(_: ?*anyopaque, a: std.mem.Allocator, _: []const u8, _: usize) anyerror!ToolResult {
            return ToolResult{ .success = true, .output = try a.dupe(u8, "mock-fetch-ok"), .err_msg = null };
        }
    }.f;
    const mockSearch = struct {
        fn f(_: ?*anyopaque, a: std.mem.Allocator, _: []const u8, _: usize) anyerror!ToolResult {
            return ToolResult{ .success = true, .output = try a.dupe(u8, "mock-search-ok"), .err_msg = null };
        }
    }.f;

    try wp.registerFetchProvider(alloc, .{ .name = "curl", .description = "curl", .fetchFn = mockFetch });
    try wp.registerSearchProvider(alloc, .{ .name = "duckduckgo", .description = "ddg", .searchFn = mockSearch });
    // Register a second fetch provider and switch to it.
    try wp.registerFetchProvider(alloc, .{ .name = "alt-fetch", .description = "alt", .fetchFn = mockFetch });
    try wp.setActiveFetchProvider(alloc, "alt-fetch");
    try std.testing.expectEqualStrings("alt-fetch", wp.activeFetchName().?);

    // Executor should now hit the mock (not curl) — verify via direct provider call.
    const p = wp.getActiveFetchProvider().?;
    var r = try p.fetchFn(p.ctx, alloc, "http://example.com", 1024);
    defer freeResult(alloc, &r);
    try std.testing.expectEqualStrings("mock-fetch-ok", r.output);

    // Tool schemas remain valid after provider seam wiring.
    var reg = try registry_mod.ToolRegistry.init(alloc);
    defer reg.deinit();
    try registerWebTools(&reg);
    const def = reg.get("web_fetch").?;
    try std.testing.expect(std.mem.indexOf(u8, def.parameters_json, "\"url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.parameters_json, "\"required\":[\"url\"]") != null);
    const sdef = reg.get("web_search").?;
    try std.testing.expect(std.mem.indexOf(u8, sdef.parameters_json, "\"query\"") != null);

    // Unknown third-party web provider must be routed via MCP, not embedded.
    try std.testing.expect(wp.shouldUseMcpForWebProvider("exa"));
    try std.testing.expect(wp.shouldUseMcpForWebProvider("perplexity"));
    try std.testing.expect(!wp.shouldUseMcpForWebProvider("curl"));
}

test "web provider seam tool schemas are JSON-valid" {
    const alloc = std.testing.allocator;
    var reg = try registry_mod.ToolRegistry.init(alloc);
    defer reg.deinit();
    try registerWebTools(&reg);
    const json = try reg.buildToolsJson(alloc);
    defer alloc.free(json);
    // Both tools appear and produce balanced JSON.
    try std.testing.expect(std.mem.indexOf(u8, json, "web_fetch") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "web_search") != null);
    var depth: i32 = 0;
    for (json) |c| {
        if (c == '{') depth += 1;
        if (c == '}') depth -= 1;
        try std.testing.expect(depth >= 0);
    }
    try std.testing.expectEqual(@as(i32, 0), depth);
}
