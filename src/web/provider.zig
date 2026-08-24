//! Native web provider seam — registry + interface for first-party web tools.
//!
//! Goal: P2 backlog item 8 — add a provider seam selectively. Start with a
//! native web provider seam if multiple first-party providers are required;
//! use MCP for third-party search/fetch rather than embedding upstream
//! TypeScript providers (Exa, Perplexity, DeepSeek web, etc.).
//!
//! - This module is the **registry + interface** only. Concrete providers
//!   (curl fetch, DuckDuckGo search) are registered from `tool/webfetch.zig`
//!   so the curl/DDG logic stays in that module and this file stays
//!   dependency-light and cycle-free.
//! - At least two native providers are expected: one fetch provider
//!   (`"curl"`) and one search provider (`"duckduckgo"`). Both are registered
//!   lazily by `tool/webfetch.zig` via `ensureProviders()`.
//! - Third-party web providers (Exa, Perplexity, Brave, etc.) MUST NOT be
//!   embedded here. They remain behind MCP (`tool/mcp_bridge.zig`) so a
//!   single transport (MCP) covers all upstream TypeScript providers without
//!   vendoring their SDKs. See `shouldUseMcpForWebProvider()`.
//! - The direct `web_fetch` / `web_search` tools stay available for MVP; the
//!   seam is additive — it routes through the active provider when one is
//!   selected, otherwise falls back to the built-in curl/DDG path.

const std = @import("std");
const builtin_tools = @import("../tool/builtin.zig");

pub const ToolResult = builtin_tools.ToolResult;

/// Fetch provider interface. `ctx` is optional opaque state (null for
/// stateless built-ins like curl). The function must return an owned
/// ToolResult (output/err_msg allocated with `alloc`, freed via
/// `builtin_tools.freeResult`).
pub const FetchProvider = struct {
    name: []const u8,
    description: []const u8,
    ctx: ?*anyopaque = null,
    fetchFn: *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, url: []const u8, max_bytes: usize) anyerror!ToolResult,
};

/// Search provider interface.
pub const SearchProvider = struct {
    name: []const u8,
    description: []const u8,
    ctx: ?*anyopaque = null,
    searchFn: *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, query: []const u8, limit: usize) anyerror!ToolResult,
};

// ── global registry ─────────────────────────────────────────────────────────

var fetch_map: ?std.StringHashMap(FetchProvider) = null;
var search_map: ?std.StringHashMap(SearchProvider) = null;
var active_fetch_name: ?[]const u8 = null; // owned dup (regAlloc)
var active_search_name: ?[]const u8 = null; // owned dup (regAlloc)

fn regAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn ensureFetchMap(alloc: std.mem.Allocator) !*std.StringHashMap(FetchProvider) {
    _ = alloc;
    if (fetch_map == null) fetch_map = std.StringHashMap(FetchProvider).init(regAlloc());
    return &fetch_map.?;
}

fn ensureSearchMap(alloc: std.mem.Allocator) !*std.StringHashMap(SearchProvider) {
    _ = alloc;
    if (search_map == null) search_map = std.StringHashMap(SearchProvider).init(regAlloc());
    return &search_map.?;
}

// ── fetch registry ──────────────────────────────────────────────────────────

pub fn registerFetchProvider(alloc: std.mem.Allocator, provider: FetchProvider) !void {
    const map = try ensureFetchMap(alloc);
    const ra = regAlloc();
    if (provider.name.len == 0) return error.InvalidProviderName;
    if (map.fetchRemove(provider.name)) |kv| {
        ra.free(kv.key);
        ra.free(kv.value.name);
        ra.free(kv.value.description);
    }
    const key = try ra.dupe(u8, provider.name);
    errdefer ra.free(key);
    const val_name = try ra.dupe(u8, provider.name);
    errdefer ra.free(val_name);
    const val_desc = try ra.dupe(u8, provider.description);
    errdefer ra.free(val_desc);
    const val = FetchProvider{
        .name = val_name,
        .description = val_desc,
        .ctx = provider.ctx,
        .fetchFn = provider.fetchFn,
    };
    try map.put(key, val);
    if (active_fetch_name == null) {
        active_fetch_name = try ra.dupe(u8, provider.name);
    }
}

pub fn hasFetchProvider(name: []const u8) bool {
    const m = fetch_map orelse return false;
    return m.contains(name);
}

pub fn fetchProviderCount() usize {
    const m = fetch_map orelse return 0;
    return m.count();
}

pub fn getFetchProvider(name: []const u8) ?FetchProvider {
    const m = fetch_map orelse return null;
    return m.get(name);
}

pub fn getActiveFetchProvider() ?FetchProvider {
    const n = active_fetch_name orelse return null;
    return getFetchProvider(n);
}

pub fn activeFetchName() ?[]const u8 {
    return active_fetch_name;
}

pub fn setActiveFetchProvider(alloc: std.mem.Allocator, name: []const u8) !void {
    _ = alloc;
    const ra = regAlloc();
    if (!hasFetchProvider(name)) return error.UnknownProvider;
    if (active_fetch_name) |old| ra.free(old);
    active_fetch_name = try ra.dupe(u8, name);
}

pub fn listFetchProviders(alloc: std.mem.Allocator) ![][]const u8 {
    const m = fetch_map orelse return try alloc.alloc([]const u8, 0);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = m.keyIterator();
    while (it.next()) |k| try out.append(alloc, k.*);
    return out.toOwnedSlice(alloc);
}

// ── search registry ─────────────────────────────────────────────────────────

pub fn registerSearchProvider(alloc: std.mem.Allocator, provider: SearchProvider) !void {
    const map = try ensureSearchMap(alloc);
    const ra = regAlloc();
    if (provider.name.len == 0) return error.InvalidProviderName;
    if (map.fetchRemove(provider.name)) |kv| {
        ra.free(kv.key);
        ra.free(kv.value.name);
        ra.free(kv.value.description);
    }
    const key = try ra.dupe(u8, provider.name);
    errdefer ra.free(key);
    const val_name = try ra.dupe(u8, provider.name);
    errdefer ra.free(val_name);
    const val_desc = try ra.dupe(u8, provider.description);
    errdefer ra.free(val_desc);
    const val = SearchProvider{
        .name = val_name,
        .description = val_desc,
        .ctx = provider.ctx,
        .searchFn = provider.searchFn,
    };
    try map.put(key, val);
    if (active_search_name == null) {
        active_search_name = try regAlloc().dupe(u8, provider.name);
    }
}

pub fn hasSearchProvider(name: []const u8) bool {
    const m = search_map orelse return false;
    return m.contains(name);
}

pub fn searchProviderCount() usize {
    const m = search_map orelse return 0;
    return m.count();
}

pub fn getSearchProvider(name: []const u8) ?SearchProvider {
    const m = search_map orelse return null;
    return m.get(name);
}

pub fn getActiveSearchProvider() ?SearchProvider {
    const n = active_search_name orelse return null;
    return getSearchProvider(n);
}

pub fn activeSearchName() ?[]const u8 {
    return active_search_name;
}

pub fn setActiveSearchProvider(alloc: std.mem.Allocator, name: []const u8) !void {
    _ = alloc;
    const ra = regAlloc();
    if (!hasSearchProvider(name)) return error.UnknownProvider;
    if (active_search_name) |old| ra.free(old);
    active_search_name = try ra.dupe(u8, name);
}

pub fn listSearchProviders(alloc: std.mem.Allocator) ![][]const u8 {
    const m = search_map orelse return try alloc.alloc([]const u8, 0);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = m.keyIterator();
    while (it.next()) |k| try out.append(alloc, k.*);
    return out.toOwnedSlice(alloc);
}

// ── lifecycle ───────────────────────────────────────────────────────────────

pub fn clearAll(alloc: std.mem.Allocator) void {
    _ = alloc;
    const ra = regAlloc();
    if (fetch_map) |*m| {
        var it = m.iterator();
        while (it.next()) |e| {
            ra.free(e.key_ptr.*);
            ra.free(e.value_ptr.name);
            ra.free(e.value_ptr.description);
        }
        m.deinit();
        fetch_map = null;
    }
    if (search_map) |*m| {
        var it = m.iterator();
        while (it.next()) |e| {
            ra.free(e.key_ptr.*);
            ra.free(e.value_ptr.name);
            ra.free(e.value_ptr.description);
        }
        m.deinit();
        search_map = null;
    }
    if (active_fetch_name) |n| {
        ra.free(n);
        active_fetch_name = null;
    }
    if (active_search_name) |n| {
        ra.free(n);
        active_search_name = null;
    }
}

// ── third-party guidance ────────────────────────────────────────────────────

/// Known third-party web providers that must go through MCP rather than being
/// embedded as native providers. Embedding their TypeScript SDKs would vendor
/// upstream code and complicate credential handling; MCP keeps them isolated.
const third_party_web_providers = [_][]const u8{ "exa", "perplexity", "brave", "tavily", "serper", "deepseek-web" };

pub fn shouldUseMcpForWebProvider(name: []const u8) bool {
    for (third_party_web_providers) |tp| {
        if (std.mem.eql(u8, tp, name)) return true;
        // also match prefixed forms like "exa-search"
        if (std.mem.startsWith(u8, name, tp)) return true;
    }
    return false;
}

pub fn isNativeWebProvider(name: []const u8) bool {
    return hasFetchProvider(name) or hasSearchProvider(name);
}

// ── tests ───────────────────────────────────────────────────────────────────

test "fetch provider registry register/select/list" {
    const alloc = std.testing.allocator;
    clearAll(alloc);
    defer clearAll(alloc);

    const dummyFetch = struct {
        fn f(_: ?*anyopaque, a: std.mem.Allocator, _: []const u8, _: usize) anyerror!ToolResult {
            return ToolResult{ .success = true, .output = try a.dupe(u8, "dummy"), .err_msg = null };
        }
    }.f;

    try registerFetchProvider(alloc, .{ .name = "curl", .description = "HTTP via curl", .fetchFn = dummyFetch });
    try registerFetchProvider(alloc, .{ .name = "custom-fetch", .description = "Custom", .fetchFn = dummyFetch });

    try std.testing.expectEqual(@as(usize, 2), fetchProviderCount());
    try std.testing.expect(hasFetchProvider("curl"));
    try std.testing.expect(!hasFetchProvider("missing"));

    // First provider becomes active by default.
    try std.testing.expectEqualStrings("curl", activeFetchName().?);
    try std.testing.expect(getActiveFetchProvider() != null);

    try setActiveFetchProvider(alloc, "custom-fetch");
    try std.testing.expectEqualStrings("custom-fetch", activeFetchName().?);

    // Unknown provider is rejected.
    try std.testing.expectError(error.UnknownProvider, setActiveFetchProvider(alloc, "ghost"));

    const list = try listFetchProviders(alloc);
    defer alloc.free(list);
    try std.testing.expectEqual(@as(usize, 2), list.len);
}

test "search provider registry register/select" {
    const alloc = std.testing.allocator;
    clearAll(alloc);
    defer clearAll(alloc);

    const dummySearch = struct {
        fn f(_: ?*anyopaque, a: std.mem.Allocator, _: []const u8, _: usize) anyerror!ToolResult {
            return ToolResult{ .success = true, .output = try a.dupe(u8, "results"), .err_msg = null };
        }
    }.f;

    try registerSearchProvider(alloc, .{ .name = "duckduckgo", .description = "DDG HTML", .searchFn = dummySearch });
    try registerSearchProvider(alloc, .{ .name = "mock-search", .description = "Mock", .searchFn = dummySearch });

    try std.testing.expectEqual(@as(usize, 2), searchProviderCount());
    try std.testing.expectEqualStrings("duckduckgo", activeSearchName().?);

    try setActiveSearchProvider(alloc, "mock-search");
    try std.testing.expectEqualStrings("mock-search", activeSearchName().?);

    const prov = getActiveSearchProvider().?;
    var r = try prov.searchFn(prov.ctx, alloc, "query", 5);
    defer builtin_tools.freeResult(alloc, &r);
    try std.testing.expect(r.success);
    try std.testing.expectEqualStrings("results", r.output);
}

test "provider dispatch via active selection" {
    const alloc = std.testing.allocator;
    clearAll(alloc);
    defer clearAll(alloc);

    const fetchA = struct {
        fn f(_: ?*anyopaque, a: std.mem.Allocator, _: []const u8, _: usize) anyerror!ToolResult {
            return ToolResult{ .success = true, .output = try a.dupe(u8, "A"), .err_msg = null };
        }
    }.f;
    const fetchB = struct {
        fn f(_: ?*anyopaque, a: std.mem.Allocator, _: []const u8, _: usize) anyerror!ToolResult {
            return ToolResult{ .success = true, .output = try a.dupe(u8, "B"), .err_msg = null };
        }
    }.f;

    try registerFetchProvider(alloc, .{ .name = "a", .description = "A", .fetchFn = fetchA });
    try registerFetchProvider(alloc, .{ .name = "b", .description = "B", .fetchFn = fetchB });

    // Default active is "a"
    var p = getActiveFetchProvider().?;
    var r1 = try p.fetchFn(p.ctx, alloc, "http://example.com", 1024);
    defer builtin_tools.freeResult(alloc, &r1);
    try std.testing.expectEqualStrings("A", r1.output);

    try setActiveFetchProvider(alloc, "b");
    p = getActiveFetchProvider().?;
    var r2 = try p.fetchFn(p.ctx, alloc, "http://example.com", 1024);
    defer builtin_tools.freeResult(alloc, &r2);
    try std.testing.expectEqualStrings("B", r2.output);
}

test "third-party providers should use MCP" {
    try std.testing.expect(shouldUseMcpForWebProvider("exa"));
    try std.testing.expect(shouldUseMcpForWebProvider("perplexity"));
    try std.testing.expect(shouldUseMcpForWebProvider("exa-search"));
    try std.testing.expect(shouldUseMcpForWebProvider("deepseek-web"));
    try std.testing.expect(!shouldUseMcpForWebProvider("curl"));
    try std.testing.expect(!shouldUseMcpForWebProvider("duckduckgo"));
    try std.testing.expect(!shouldUseMcpForWebProvider("custom-fetch"));
}

test "clearAll resets registry" {
    const alloc = std.testing.allocator;
    clearAll(alloc);
    const dummy = struct {
        fn f(_: ?*anyopaque, a: std.mem.Allocator, _: []const u8, _: usize) anyerror!ToolResult {
            return ToolResult{ .success = true, .output = try a.dupe(u8, "x"), .err_msg = null };
        }
    }.f;
    try registerFetchProvider(alloc, .{ .name = "curl", .description = "d", .fetchFn = dummy });
    try std.testing.expectEqual(@as(usize, 1), fetchProviderCount());
    clearAll(alloc);
    try std.testing.expectEqual(@as(usize, 0), fetchProviderCount());
    try std.testing.expect(activeFetchName() == null);
}
