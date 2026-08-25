//! Cordis creative-mode tools (docs/dynamic-cordis-spec.md §9 "Tools") — the
//! model-facing surface for defining/running dynamic packages. Five
//! ToolDefinitions that delegate ALL orchestration to lifecycle.Lifecycle:
//!
//!   cordis_define   {name, purpose, host_code?, client_code?, id_prefix?, plugin_id?}
//!   cordis_run      {plugin_id, mode?: "host"|"host+client", package_id?}
//!   cordis_stop     {plugin_id}
//!   cordis_undefine {plugin_id}
//!   cordis_inspect  {}
//!
//! ── Integrator contract (READ BEFORE WIRING) ────────────────────────────
//! Same module-level wiring slot pattern as tool/spawn_agent.zig: registry
//! executors are plain functions with no per-tool context slot, so this
//! module keeps exactly ONE slot carrying the Lifecycle handle plus the
//! owning session id (spec §6 — definitions are visible/controllable only
//! in the session that defined them):
//!
//!     var g_cordis_ctx: ?*CordisDeps = null;
//!     pub fn setCordisCtx(ctx: *CordisDeps) void;  // call once at startup
//!     pub fn clearCordisCtx() void;                // call once at shutdown
//!
//! main.zig wiring (integrator applies; do NOT edit main.zig from here):
//!
//!     const preset_tools = @import("dynamic/preset_tools.zig");
//!     // after DynamicRegistry + Sandbox + Lifecycle exist:
//!     var cordis_deps = preset_tools.CordisDeps{ .lc = &lifecycle, .session_id = session_id };
//!     try reg.register(preset_tools.cordis_define);
//!     try reg.register(preset_tools.cordis_run);
//!     try reg.register(preset_tools.cordis_stop);
//!     try reg.register(preset_tools.cordis_undefine);
//!     try reg.register(preset_tools.cordis_inspect);
//!     preset_tools.setCordisCtx(&cordis_deps);          // before first turn
//!     // ... route calls named "cordis_*" to preset_tools.execute ...
//!     preset_tools.clearCordisCtx();                    // at shutdown
//!
//! Until setCordisCtx runs, `execute` returns a FAILED ToolResult explaining
//! the missing wiring — it never touches the registry. The slot is NOT
//! synchronized: single-threaded agent-loop contract only (the Lifecycle
//! itself is internally locked).
//!
//! Result ownership follows tool/builtin.zig conventions: `execute`
//! allocates ToolResult.output/err_msg with the given allocator; the caller
//! frees via freeResult.
//!
//! Run semantics (spec §4-5): mode "host" refuses packages that carry a
//! browser half; "host+client" may SUSPEND awaiting page approval — wire an
//! approval budget via Lifecycle.approval_timeout_ms if a headless deployment
//! must not block. The run/update revision mode is picked automatically
//! (.run retried as .update when the plugin already has a current package).

const std = @import("std");
const tool_reg = @import("../tool/registry.zig");
const types = @import("types.zig");
const lifecycle_mod = @import("lifecycle.zig");
const jsonx = @import("../server/apiproxy/jsonx.zig");

// ── module-level wiring slot (see header contract) ──────────────────────────

var g_cordis_ctx: ?*CordisDeps = null;

pub fn setCordisCtx(ctx: *CordisDeps) void {
    g_cordis_ctx = ctx;
}

pub fn clearCordisCtx() void {
    g_cordis_ctx = null;
}

/// Current wiring (null until setCordisCtx). Exposed for tests/introspection.
pub fn cordisCtx() ?*CordisDeps {
    return g_cordis_ctx;
}

pub const CordisDeps = struct {
    /// Lifecycle orchestrator (owns its registry + sandbox references).
    lc: *lifecycle_mod.Lifecycle,
    /// Owning session id for define/run/stop/undefine ownership checks.
    session_id: []const u8,
};

// ── registry-facing definitions ─────────────────────────────────────────────

pub const cordis_define = tool_reg.ToolDefinition{
    .name = "cordis_define",
    .description =
    \\Define a dynamic Cordis package: name + purpose + source halves. The
    \\host half (`host_code`) is a JS function body returning a Cordis plugin
    \\and runs sandboxed in a Node vm; the optional browser half
    \\(`client_code`) renders UI in connected pages but requires page
    \\approval at run time. Both halves are syntax-prechecked BEFORE ids are
    \\minted — unparseable input returns teaching text instead of a package.
    \\Pass `plugin_id` to append a new immutable revision to an existing
    \\plugin instead of creating one.
    ,
    .parameters_json =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Short human-readable package name"},"purpose":{"type":"string","description":"What the package does and why it exists"},"host_code":{"type":"string","description":"JS function body returning the host-half plugin object; required unless client_code is given"},"client_code":{"type":"string","description":"Optional JS function body evaluated per page as the browser half"},"id_prefix":{"type":"string","description":"Optional 3-6 lowercase letters proposing the plugin id prefix (default 'cord')"},"plugin_id":{"type":"string","description":"Optional existing plugin id to append this revision to"}},"required":["name","purpose"]}
    ,
};

pub const cordis_run = tool_reg.ToolDefinition{
    .name = "cordis_run",
    .description =
    \\Run (or update) a defined dynamic package. mode "host" executes the
    \\host half only and resolves synchronously; "host+client" also delivers
    \\the browser half to every open page, which SUSPENDS the call until a
    \\page approves, declines, or the run is stopped/cancelled. Defaults to
    \\"host+client". Omitting package_id targets the latest defined revision;
    \\switching revisions while another is current uses update semantics
    \\automatically.
    ,
    .parameters_json =
    \\{"type":"object","properties":{"plugin_id":{"type":"string","description":"Plugin id returned by cordis_define"},"mode":{"type":"string","enum":["host","host+client"],"description":"'host' = host half only; 'host+client' = also deliver browser half (page approval may suspend). Default 'host+client'"},"package_id":{"type":"string","description":"Optional specific package revision; defaults to the latest defined"}},"required":["plugin_id"]}
    ,
};

pub const cordis_stop = tool_reg.ToolDefinition{
    .name = "cordis_stop",
    .description =
    \\Stop a running dynamic package: disposes the host half and retracts the
    \\browser half from pages, cancelling any open approval request.
    \\Idempotent — packages and their revisions are retained so the plugin
    \\can be re-run later.
    ,
    .parameters_json =
    \\{"type":"object","properties":{"plugin_id":{"type":"string","description":"Plugin id to stop"}},"required":["plugin_id"]}
    ,
};

pub const cordis_undefine = tool_reg.ToolDefinition{
    .name = "cordis_undefine",
    .description =
    \\Remove a dynamic package definition entirely: stops it first (idempotent)
    \\then deletes all packages and approval grants. Destructive — the plugin
    \\id becomes invalid ("Plugin removed") and cannot be re-run; define a new
    \\package to recreate equivalent behavior.
    ,
    .parameters_json =
    \\{"type":"object","properties":{"plugin_id":{"type":"string","description":"Plugin id to remove"}},"required":["plugin_id"]}
    ,
};

pub const cordis_inspect = tool_reg.ToolDefinition{
    .name = "cordis_inspect",
    .description =
    \\List this session's dynamic packages and their live status: plugin ids,
    \\package revisions, current/next pointers, and latest run state
    \\(awaiting-approval / running / failed / stopped ...). Takes no arguments.
    ,
    .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
};

/// All five in registration order (integrator convenience).
pub const definitions = [_]tool_reg.ToolDefinition{
    cordis_define,
    cordis_run,
    cordis_stop,
    cordis_undefine,
    cordis_inspect,
};

// ── executor ────────────────────────────────────────────────────────────────

pub const ToolCall = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    err_msg: ?[]const u8 = null,
};

/// Free a result returned by `execute` (allocated with the same allocator).
pub fn freeResult(alloc: std.mem.Allocator, res: *const ToolResult) void {
    alloc.free(res.output);
    if (res.err_msg) |m| alloc.free(m);
}

fn fail(alloc: std.mem.Allocator, msg: []const u8) ToolResult {
    return .{ .success = false, .output = alloc.dupe(u8, "") catch "", .err_msg = alloc.dupe(u8, msg) catch null };
}

/// Dispatch a cordis_* call. Signature mirrors tool/builtin.zig's execute
/// convention: allocations use `alloc`; the caller frees via freeResult.
pub fn execute(alloc: std.mem.Allocator, call: ToolCall) !ToolResult {
    const deps = g_cordis_ctx orelse return fail(
        alloc,
        "cordis tools are not wired: the host must call preset_tools.setCordisCtx(&CordisDeps{...}) at startup",
    );

    var args = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &args);

    if (std.mem.eql(u8, call.name, cordis_define.name)) return cordisDefineExec(alloc, deps, &args);
    if (std.mem.eql(u8, call.name, cordis_run.name)) return cordisRunExec(alloc, deps, &args);
    if (std.mem.eql(u8, call.name, cordis_stop.name)) return cordisStopExec(alloc, deps, &args);
    if (std.mem.eql(u8, call.name, cordis_undefine.name)) return cordisUndefineExec(alloc, deps, &args);
    if (std.mem.eql(u8, call.name, cordis_inspect.name)) return cordisInspectExec(alloc, deps);
    return fail(alloc, "unknown cordis tool");
}

// ── cordis_define ───────────────────────────────────────────────────────────

fn cordisDefineExec(
    alloc: std.mem.Allocator,
    deps: *CordisDeps,
    args: *std.StringHashMap([]const u8),
) !ToolResult {
    const name = args.get("name") orelse return fail(alloc, "missing name");
    const purpose = args.get("purpose") orelse return fail(alloc, "missing purpose");

    const req = types.DefineRequest{
        .session_id = deps.session_id,
        .plugin = if (args.get("plugin_id")) |pid|
            .{ .existing = pid }
        else
            .{ .new = .{ .idPrefix = args.get("id_prefix") orelse "cord" } },
        .name = name,
        .purpose = purpose,
        .code = .{
            .host = args.get("host_code"),
            .client = args.get("client_code"),
        },
    };

    var res = try deps.lc.define(req);
    defer res.deinit(deps.lc.alloc);

    switch (res) {
        .receipt => |r| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            try out.appendSlice(alloc, "{\"status\":\"defined\",\"pluginId\":");
            try jsonx.appendJsonString(alloc, &out, r.plugin_id);
            try out.appendSlice(alloc, ",\"packageId\":");
            try jsonx.appendJsonString(alloc, &out, r.package_id);
            try out.appendSlice(alloc, ",\"hasHostHalf\":");
            try out.appendSlice(alloc, if (r.has_host) "true" else "false");
            try out.appendSlice(alloc, ",\"hasClientHalf\":");
            try out.appendSlice(alloc, if (r.has_client) "true" else "false");
            try out.appendSlice(alloc, "}");
            return .{ .success = true, .output = try out.toOwnedSlice(alloc), .err_msg = null };
        },
        .refused => |r| {
            // r.message is owned by res (freed by deinit below) — dupe it into
            // the caller's allocator so freeResult owns its own copy.
            return .{ .success = false, .output = alloc.dupe(u8, "") catch "", .err_msg = alloc.dupe(u8, r.message) catch null };
        },
    }
}

// ── cordis_run ──────────────────────────────────────────────────────────────

fn cordisRunExec(
    alloc: std.mem.Allocator,
    deps: *CordisDeps,
    args: *std.StringHashMap([]const u8),
) !ToolResult {
    const lc = deps.lc;
    const plugin_id = args.get("plugin_id") orelse return fail(alloc, "missing plugin_id");

    const mode_raw = args.get("mode") orelse "host+client";
    const host_only: bool = blk: {
        if (std.mem.eql(u8, mode_raw, "host")) break :blk true;
        if (std.mem.eql(u8, mode_raw, "host+client")) break :blk false;
        return fail(alloc, "mode must be \"host\" or \"host+client\"");
    };

    // Resolve target package + client-half presence under the lifecycle lock
    // (cross-session reads as absent, spec §6). Released before lc.run.
    var pkg_id: []u8 = undefined;
    {
        lc.lock.lock();
        defer lc.lock.unlock();
        const p = lc.reg.getPlugin(plugin_id) orelse
            return fail(alloc, "unknown or foreign plugin_id");
        if (!std.mem.eql(u8, p.session_id, deps.session_id))
            return fail(alloc, "unknown or foreign plugin_id");

        const base: []const u8 = if (args.get("package_id")) |want| want else blk2: {
            if (p.package_order.items.len == 0)
                return fail(alloc, "plugin has no defined packages");
            break :blk2 p.package_order.items[p.package_order.items.len - 1];
        };
        const pkg = p.packages.get(base) orelse
            return fail(alloc, "unknown package_id for this plugin");

        if (host_only and pkg.clientCode != null)
            return fail(alloc, "package has a client half: rerun with mode \"host+client\" (page approval applies) or define a host-only revision");

        pkg_id = try alloc.dupe(u8, base);
    }
    defer alloc.free(pkg_id);

    // Revision semantics: prefer restart (.run); fall back to .update when a
    // different package is already current.
    var oc = lc.run(deps.session_id, plugin_id, pkg_id, .run) catch |e| switch (e) {
        error.InvalidMode => blk: {
            break :blk lc.run(deps.session_id, plugin_id, pkg_id, .update) catch |e2|
                return fail(alloc, @errorName(e2));
        },
        else => return fail(alloc, @errorName(e)),
    };
    defer oc.deinit(lc.alloc);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"status\":");
    try jsonx.appendJsonString(alloc, &out, oc.status.asStr());
    try out.appendSlice(alloc, ",\"pluginId\":");
    try jsonx.appendJsonString(alloc, &out, plugin_id);
    try out.appendSlice(alloc, ",\"packageId\":");
    try jsonx.appendJsonString(alloc, &out, oc.package_id);
    try out.appendSlice(alloc, ",\"pluginRunId\":");
    try jsonx.appendJsonString(alloc, &out, oc.plugin_run_id);
    if (oc.approval_request_id) |aid| {
        try out.appendSlice(alloc, ",\"approvalRequestId\":");
        try jsonx.appendJsonString(alloc, &out, aid);
    }
    if (oc.err) |e| {
        try out.appendSlice(alloc, ",\"error\":");
        try jsonx.appendJsonString(alloc, &out, e);
    }
    try out.appendSlice(alloc, "}");
    return .{ .success = true, .output = try out.toOwnedSlice(alloc), .err_msg = null };
}

// ── cordis_stop ─────────────────────────────────────────────────────────────

fn cordisStopExec(
    alloc: std.mem.Allocator,
    deps: *CordisDeps,
    args: *std.StringHashMap([]const u8),
) !ToolResult {
    const plugin_id = args.get("plugin_id") orelse return fail(alloc, "missing plugin_id");
    const res = deps.lc.stop(deps.session_id, plugin_id) catch |e|
        return fail(alloc, stopErrorText(e));
    const status: []const u8 = switch (res) {
        .ok => "stopped",
        .not_running => "not-running",
        .plugin_missing => "unknown-or-foreign-plugin",
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"status\":");
    try jsonx.appendJsonString(alloc, &out, status);
    try out.appendSlice(alloc, ",\"pluginId\":");
    try jsonx.appendJsonString(alloc, &out, plugin_id);
    try out.appendSlice(alloc, "}");
    return .{ .success = true, .output = try out.toOwnedSlice(alloc), .err_msg = null };
}

fn stopErrorText(e: anyerror) []const u8 {
    return if (e == error.PluginNotFound) "unknown or foreign plugin_id" else @errorName(e);
}

// ── cordis_undefine ─────────────────────────────────────────────────────────

fn cordisUndefineExec(
    alloc: std.mem.Allocator,
    deps: *CordisDeps,
    args: *std.StringHashMap([]const u8),
) !ToolResult {
    const lc = deps.lc;
    const plugin_id = args.get("plugin_id") orelse return fail(alloc, "missing plugin_id");
    const res = lc.undefine(deps.session_id, plugin_id) catch |e|
        return fail(alloc, stopErrorText(e));
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"status\":\"removed\",\"pluginId\":");
    try jsonx.appendJsonString(alloc, &out, plugin_id);
    try out.appendSlice(alloc, ",\"wasRunning\":");
    try out.appendSlice(alloc, if (res.wasRunning) "true" else "false");
    try out.appendSlice(alloc, "}");
    return .{ .success = true, .output = try out.toOwnedSlice(alloc), .err_msg = null };
}

// ── cordis_inspect ──────────────────────────────────────────────────────────

fn cordisInspectExec(alloc: std.mem.Allocator, deps: *CordisDeps) !ToolResult {
    const lc = deps.lc;
    lc.lock.lock();
    defer lc.lock.unlock();

    // NOTE: registry.listPlugins() currently fails to compile (Reference vs
    // PluginInspection anonymous activeRun struct mismatch, registry.zig:764),
    // so inspection rides the session-scoped snapshot() view instead — same
    // ownership filtering, no borrowed-name field needed.
    const rows = lc.reg.snapshot(alloc, deps.session_id) catch |e|
        return fail(alloc, @errorName(e));
    defer {
        for (rows) |r| alloc.free(r.packages);
        alloc.free(rows);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    if (rows.len == 0) {
        try out.appendSlice(alloc, "no dynamic packages defined in this session");
        return .{ .success = true, .output = try out.toOwnedSlice(alloc), .err_msg = null };
    }

    try appendCount(alloc, &out, rows.len);
    try out.appendSlice(alloc, " plugin(s):\n");
    for (rows) |r| {
        // Display name: first defined package's name (snapshot rows carry
        // per-package names, not a plugin-level one).
        const display: []const u8 = if (r.packages.len > 0) r.packages[0].name else "";
        try out.appendSlice(alloc, "- ");
        try out.appendSlice(alloc, r.pluginId);
        try out.appendSlice(alloc, " '");
        try out.appendSlice(alloc, display);
        try out.appendSlice(alloc, "' current=");
        try out.appendSlice(alloc, r.currentPackageId orelse "none");
        try out.appendSlice(alloc, " next=");
        try out.appendSlice(alloc, r.nextPackageId orelse "none");
        try out.appendSlice(alloc, " latest=");
        if (r.latestRun) |lr| {
            try out.appendSlice(alloc, lr.status.asStr());
        } else {
            try out.appendSlice(alloc, "idle");
        }
        try out.appendSlice(alloc, "\n");
        for (r.packages) |pkg| {
            try out.appendSlice(alloc, "    ");
            try out.appendSlice(alloc, pkg.packageId);
            try out.appendSlice(alloc, " '");
            try out.appendSlice(alloc, pkg.name);
            try out.appendSlice(alloc, "' host=");
            try out.appendSlice(alloc, if (pkg.hasHostHalf) "y" else "n");
            try out.appendSlice(alloc, " client=");
            try out.appendSlice(alloc, if (pkg.hasClientHalf) "y" else "n");
            try out.appendSlice(alloc, ": ");
            try out.appendSlice(alloc, pkg.purpose);
            try out.appendSlice(alloc, "\n");
        }
    }
    return .{ .success = true, .output = try out.toOwnedSlice(alloc), .err_msg = null };
}

fn appendCount(alloc: std.mem.Allocator, out: *std.ArrayList(u8), n: usize) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    try out.appendSlice(alloc, s);
}

// ── flat JSON arg parsing (same pattern as tool/builtin.zig/spawn_agent) ────

fn unescapeJson(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
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

/// Parse a flat JSON object of string values into a map (host_code /
/// client_code arrive as plain strings — no nested objects in these schemas).
fn parseArgs(alloc: std.mem.Allocator, json_args: []const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(alloc);
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
        const key = json_args[key_start..i];
        const key_un = try unescapeJson(alloc, key);
        errdefer alloc.free(key_un);
        i += 1;
        while (i < json_args.len and json_args[i] != ':') : (i += 1) {}
        if (i >= json_args.len) break;
        i += 1;
        while (i < json_args.len and (json_args[i] == ' ' or json_args[i] == '\t')) : (i += 1) {}
        if (i >= json_args.len) break;
        var value: []const u8 = "";
        if (json_args[i] == '"') {
            i += 1;
            const v_start = i;
            while (i < json_args.len and json_args[i] != '"') : (i += 1) {
                if (json_args[i] == '\\' and i + 1 < json_args.len) i += 1;
            }
            value = try unescapeJson(alloc, json_args[v_start..i]);
            if (i < json_args.len) i += 1;
        } else if (json_args[i] == 't' or json_args[i] == 'f') {
            const b_start = i;
            while (i < json_args.len and std.ascii.isAlphabetic(json_args[i])) : (i += 1) {}
            value = try alloc.dupe(u8, json_args[b_start..i]);
        } else if (json_args[i] == '-' or std.ascii.isDigit(json_args[i])) {
            const n_start = i;
            while (i < json_args.len and (std.ascii.isDigit(json_args[i]) or json_args[i] == '.' or json_args[i] == '-')) : (i += 1) {}
            value = try alloc.dupe(u8, json_args[n_start..i]);
        }
        try map.put(key_un, value);
    }
    return map;
}

fn freeArgs(alloc: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        alloc.free(e.key_ptr.*);
        alloc.free(e.value_ptr.*);
    }
    map.deinit();
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "all five definitions register into the registry" {
    const alloc = testing.allocator;
    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    for (definitions) |def| try reg.register(def);
    inline for (.{ "cordis_define", "cordis_run", "cordis_stop", "cordis_undefine", "cordis_inspect" }) |n| {
        const got = reg.get(n) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(n, got.name);
        try testing.expect(got.description.len > 0);
    }
    // buildToolsJson serializes them as valid OpenAI tools fragments.
    const tools_json = try reg.buildToolsJson(alloc);
    defer alloc.free(tools_json);
    try testing.expect(std.mem.indexOf(u8, tools_json, "\"cordis_define\"") != null);
    try testing.expect(std.mem.indexOf(u8, tools_json, "\"required\":[\"name\",\"purpose\"]") != null);
}

test "unwired executor fails gracefully" {
    const alloc = testing.allocator;
    clearCordisCtx(); // guarantee unwired state regardless of test order
    var res = try execute(alloc, .{ .name = "cordis_inspect", .arguments = "{}" });
    defer freeResult(alloc, &res);
    try testing.expect(!res.success);
    try testing.expect(std.mem.indexOf(u8, res.err_msg.?, "setCordisCtx") != null);

    var unknown = try execute(alloc, .{ .name = "cordis_bogus", .arguments = "{}" });
    defer freeResult(alloc, &unknown);
    try testing.expect(!unknown.success);
}

test "wired flow: define → inspect → run-mode guard → undefine (no node needed)" {
    const alloc = testing.allocator;
    var reg_dyn = @import("registry.zig").DynamicRegistry.init(alloc);
    defer reg_dyn.deinit();
    const sbx = @import("sandbox.zig").Sandbox.initDefault(alloc);
    var lc = lifecycle_mod.Lifecycle.init(alloc, &reg_dyn, sbx);
    lc.poll_ms = 2;
    lc.approval_timeout_ms = 30; // headless test budget: suspensions cancel fast
    defer lc.deinit();

    var deps = CordisDeps{ .lc = &lc, .session_id = "sess-w7" };
    setCordisCtx(&deps);
    defer clearCordisCtx();

    // define host-only package
    var d = try execute(alloc, .{
        .name = "cordis_define",
        .arguments =
        \\{"name":"counter","purpose":"demo counting","host_code":"return {};","id_prefix":"abc"}
        ,
    });
    defer freeResult(alloc, &d);
    try testing.expect(d.success);
    try testing.expect(std.mem.indexOf(u8, d.output, "\"status\":\"defined\"") != null);
    try testing.expect(std.mem.indexOf(u8, d.output, "\"hasClientHalf\":false") != null);
    try testing.expect(std.mem.indexOf(u8, d.output, "\"pluginId\":\"abc-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, d.output, "\"packageId\":\"pkg-1\"") != null);

    // inspect lists it
    var insp = try execute(alloc, .{ .name = "cordis_inspect", .arguments = "{}" });
    defer freeResult(alloc, &insp);
    try testing.expect(insp.success);
    try testing.expect(std.mem.indexOf(u8, insp.output, "abc-1 'counter' current=none") != null);
    try testing.expect(std.mem.indexOf(u8, insp.output, "host=y client=n") != null);

    // define refusal carries teaching text (TypeScript annotation trap)
    var bad = try execute(alloc, .{
        .name = "cordis_define",
        .arguments = "{\"name\":\"ts\",\"purpose\":\"bad\",\"host_code\":\"const x = y as const;\"}",
    });
    defer freeResult(alloc, &bad);
    try testing.expect(!bad.success);
    try testing.expect(std.mem.indexOf(u8, bad.err_msg.?, "TypeScript") != null);

    // missing args fail cleanly
    var no_name = try execute(alloc, .{ .name = "cordis_define", .arguments = "{\"purpose\":\"p\"}" });
    defer freeResult(alloc, &no_name);
    try testing.expectEqualStrings("missing name", no_name.err_msg.?);

    var no_pid = try execute(alloc, .{ .name = "cordis_stop", .arguments = "{}" });
    defer freeResult(alloc, &no_pid);
    try testing.expectEqualStrings("missing plugin_id", no_pid.err_msg.?);

    // unknown plugin reads as absent
    var ghost = try execute(alloc, .{ .name = "cordis_stop", .arguments = "{\"plugin_id\":\"zzz-9\"}" });
    defer freeResult(alloc, &ghost);
    try testing.expect(!ghost.success);
    try testing.expect(std.mem.indexOf(u8, ghost.err_msg.?, "unknown or foreign") != null);

    // host mode refuses a client-bearing package before any evaluation
    var dc = try execute(alloc, .{
        .name = "cordis_define",
        .arguments = "{\"name\":\"panel\",\"purpose\":\"ui\",\"host_code\":\"return {}\",\"client_code\":\"return {}\"}",
    });
    defer freeResult(alloc, &dc);
    try testing.expect(dc.success); // default id_prefix 'cord' mints cord-1
    var guarded = try execute(alloc, .{
        .name = "cordis_run",
        .arguments =
        \\{"plugin_id":"cord-2","mode":"host"}
        ,
    });
    defer freeResult(alloc, &guarded);
    try testing.expect(!guarded.success);
    try testing.expect(std.mem.indexOf(u8, guarded.err_msg.?, "client half") != null);

    // stop before any run is idempotent not-running
    var st = try execute(alloc, .{ .name = "cordis_stop", .arguments = "{\"plugin_id\":\"abc-1\"}" });
    defer freeResult(alloc, &st);
    try testing.expect(st.success);
    try testing.expect(std.mem.indexOf(u8, st.output, "\"status\":\"not-running\"") != null);

    // undefine removes both plugins
    var ud = try execute(alloc, .{ .name = "cordis_undefine", .arguments = "{\"plugin_id\":\"abc-1\"}" });
    defer freeResult(alloc, &ud);
    try testing.expect(ud.success);
    try testing.expect(std.mem.indexOf(u8, ud.output, "\"status\":\"removed\"") != null);
    try testing.expect(reg_dyn.getPlugin("abc-1") == null);
    var ud2 = try execute(alloc, .{ .name = "cordis_undefine", .arguments = "{\"plugin_id\":\"cord-2\"}" });
    defer freeResult(alloc, &ud2);
    try testing.expect(ud2.success);
    try testing.expect(reg_dyn.getPlugin("cord-2") == null);

    // inspect now empty again
    var insp2 = try execute(alloc, .{ .name = "cordis_inspect", .arguments = "{}" });
    defer freeResult(alloc, &insp2);
    try testing.expect(std.mem.indexOf(u8, insp2.output, "no dynamic packages") != null);
}

test "run of client-bearing package suspends then cancels within timeout budget" {
    const alloc = testing.allocator;
    var reg_dyn = @import("registry.zig").DynamicRegistry.init(alloc);
    defer reg_dyn.deinit();
    const sbx = @import("sandbox.zig").Sandbox.initDefault(alloc);
    var lc = lifecycle_mod.Lifecycle.init(alloc, &reg_dyn, sbx);
    lc.poll_ms = 2;
    lc.approval_timeout_ms = 30;
    defer lc.deinit();

    var deps = CordisDeps{ .lc = &lc, .session_id = "sess-w7b" };
    setCordisCtx(&deps);
    defer clearCordisCtx();

    var d0 = try execute(alloc, .{
        .name = "cordis_define",
        .arguments = "{\"name\":\"widget\",\"purpose\":\"needs page\",\"host_code\":\"return {}\",\"client_code\":\"return {}\"}",
    });
    defer freeResult(alloc, &d0);
    try testing.expect(d0.success);

    var r = try execute(alloc, .{
        .name = "cordis_run",
        .arguments = "{\"plugin_id\":\"cord-1\",\"mode\":\"host+client\"}",
    });
    defer freeResult(alloc, &r);
    try testing.expect(r.success);
    try testing.expect(std.mem.indexOf(u8, r.output, "\"status\":\"cancelled\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "\"approvalRequestId\":\"approval-1\"") != null);
}
