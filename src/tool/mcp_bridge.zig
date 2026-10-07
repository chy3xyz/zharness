//! Bridge remote MCP server tools into the local tool namespace (dev.md §XX,
//! SWARM task E-mcp).
//!
//! Contract:
//! - Every remote tool becomes a local `ToolDefinition` named
//!   `mcp_<server>_<tool>` (lowercased, non-alphanumerics collapsed to '_';
//!   no collapsing of runs so distinct remotes never collide).
//! - Schemas pass through VERBATIM (`parameters_json` = the remote
//!   inputSchema text), so the model sees exactly what the server declared.
//! - Executors resolve through a module-level instance map keyed by the
//!   local tool name. The registry has no executor/context slot and MUST NOT
//!   be edited (ownership matrix), so this file owns the side table instead;
//!   the integrator dispatches `mcp_*` calls to `execute`.
//! - Lifecycle: `registerServerTools` populates registry + map in one call;
//!   `removeInstance`/`clearInstances` tear down map state. The McpClient
//!   itself is OWNED BY THE CALLER (deinit it yourself after clearing).

const std = @import("std");
const registry = @import("registry.zig");
const builtin = @import("builtin.zig");
const model = @import("../model/model.zig");
const mcp = @import("../protocol/mcp.zig");

/// Longest permitted local tool name (keeps provider-side name limits safe).
pub const max_local_name_len: usize = 120;

/// Prefix marking a tool as MCP-bridged.
pub const name_prefix = "mcp_";

/// True when `name` looks like a bridged tool (dispatch hint for hosts).
pub fn isBridgedName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, name_prefix);
}

/// Sanitize one token in place inside `buf`: ASCII letters/digits kept
/// (letters lowercased), everything else becomes '_'. Returns the written
/// slice, or null when the token does not fit. Deliberately NOT collapsing
/// runs of '_' so distinct remote names cannot collide.
pub fn sanitizeToken(buf: []u8, raw: []const u8) ?[]const u8 {
    if (raw.len > buf.len) return null;
    for (raw, 0..) |ch, i| {
        buf[i] = switch (ch) {
            'A'...'Z' => ch + ('a' - 'A'),
            'a'...'z', '0'...'9', '_' => ch,
            else => '_',
        };
    }
    return buf[0..raw.len];
}

/// Build the local tool name `mcp_<server>_<tool>` inside `buf`. Returns
/// null when the parts do not fit within `buf.len`.
pub fn localToolName(buf: []u8, server_label: []const u8, remote_name: []const u8) ?[]const u8 {
    var off: usize = 0;
    const pieces = [_][]const u8{ name_prefix, server_label, "_", remote_name };
    for (pieces) |piece| {
        const dst = buf[off..];
        const written = sanitizeToken(dst, piece) orelse return null;
        off += written.len;
    }
    if (off > max_local_name_len) return null;
    return buf[0..off];
}

/// Translate a remote tool descriptor into a registry-shaped definition.
/// All three strings are freshly allocated with `alloc`; free them with
/// `freeDefinitionTemp` once `ToolRegistry.register` has duplicated them.
pub fn makeDefinition(
    alloc: std.mem.Allocator,
    server_label: []const u8,
    remote: mcp.RemoteTool,
) std.mem.Allocator.Error!registry.ToolDefinition {
    var name_buf: [128]u8 = undefined;
    const local = localToolName(&name_buf, server_label, remote.name) orelse
        return error.OutOfMemory; // name overflow surfaces as OOM-shaped failure

    const name = try alloc.dupe(u8, local);
    errdefer alloc.free(name);

    const description = blk: {
        if (remote.description.len > 0) {
            break :blk try alloc.dupe(u8, remote.description);
        }
        break :blk try std.fmt.allocPrint(
            alloc,
            "MCP tool '{s}' from server '{s}'.",
            .{ remote.name, server_label },
        );
    };
    errdefer alloc.free(description);

    // Schema passthrough; fall back to the empty object schema when the
    // remote sent nothing usable.
    const trimmed_schema = std.mem.trim(u8, remote.schema_json, " \t\r\n");
    const parameters_json = if (trimmed_schema.len > 0 and trimmed_schema[0] == '{')
        try alloc.dupe(u8, trimmed_schema)
    else
        try alloc.dupe(u8, "{}");
    errdefer alloc.free(parameters_json);

    return .{
        .name = name,
        .description = description,
        .parameters_json = parameters_json,
        .category = .general,
    };
}

/// Free the temporaries created by `makeDefinition` (after register duped
/// them, or on the error path).
pub fn freeDefinitionTemp(alloc: std.mem.Allocator, def: *const registry.ToolDefinition) void {
    alloc.free(def.name);
    alloc.free(def.description);
    alloc.free(def.parameters_json);
}

// ── module-level instance map ───────────────────────────────────────────────

const Entry = struct {
    /// Not owned by the map: the spawner keeps the client alive.
    client: *mcp.McpClient,
    /// Map-owned duplicate of the remote tool name.
    remote_name: []const u8,
};

var instances: ?std.StringHashMap(Entry) = null;

/// server label -> client, for the resource inspection tools. Clients are
/// owned by the spawner, not this map.
var servers: ?std.StringHashMap(*mcp.McpClient) = null;

pub fn putServer(alloc: std.mem.Allocator, label: []const u8, client: *mcp.McpClient) std.mem.Allocator.Error!void {
    if (servers == null) servers = std.StringHashMap(*mcp.McpClient).init(alloc);
    const map = &servers.?;
    if (map.getPtr(label)) |slot| {
        slot.* = client;
        return;
    }
    const key = try alloc.dupe(u8, label);
    errdefer alloc.free(key);
    try map.put(key, client);
}

pub fn getServer(label: []const u8) ?*mcp.McpClient {
    const map = &(servers orelse return null);
    return map.get(label);
}

fn firstServer() ?*mcp.McpClient {
    const map = &(servers orelse return null);
    var it = map.valueIterator();
    if (it.next()) |p| return p.*;
    return null;
}

fn ensureMap(alloc: std.mem.Allocator) std.mem.Allocator.Error!*std.StringHashMap(Entry) {
    if (instances == null) {
        instances = std.StringHashMap(Entry).init(alloc);
    }
    return &instances.?;
}

/// Wire `local_name` to `client` + `remote_name`. Both names are duplicated
/// into the map, so callers may pass stack buffers. Overwrites any previous
/// binding for `local_name`.
pub fn putInstance(
    alloc: std.mem.Allocator,
    local_name: []const u8,
    client: *mcp.McpClient,
    remote_name: []const u8,
) std.mem.Allocator.Error!void {
    const map = try ensureMap(alloc);
    if (map.getPtr(local_name)) |slot| {
        // Replace: release the old binding's remote name.
        const rn = try alloc.dupe(u8, remote_name);
        alloc.free(slot.remote_name);
        slot.* = .{ .client = client, .remote_name = rn };
        return;
    }
    const key = try alloc.dupe(u8, local_name);
    errdefer alloc.free(key);
    const rn = try alloc.dupe(u8, remote_name);
    errdefer alloc.free(rn);
    try map.put(key, .{ .client = client, .remote_name = rn });
}

/// Look up the binding for a local tool name (copy out; the slices stay
/// valid until the binding is removed or cleared).
pub fn getInstance(local_name: []const u8) ?Entry {
    const map = &(instances orelse return null);
    return map.get(local_name);
}

/// Drop one binding. Returns true when it existed.
pub fn removeInstance(local_name: []const u8) bool {
    const map = &(instances orelse return false);
    if (map.fetchRemove(local_name)) |kv| {
        instances.?.allocator.free(kv.key);
        instances.?.allocator.free(kv.value.remote_name);
        return true;
    }
    return false;
}

/// Drop ALL bindings and the map itself (test/lifecycle teardown). Clients
/// are untouched — their owner deinits them.
pub fn clearInstances() void {
    if (instances) |*map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            map.allocator.free(entry.key_ptr.*);
            map.allocator.free(entry.value_ptr.remote_name);
        }
        map.deinit();
        instances = null;
    }
    if (servers) |*map| {
        var it = map.iterator();
        while (it.next()) |entry| map.allocator.free(entry.key_ptr.*);
        map.deinit();
        servers = null;
    }
}

// ── execution ───────────────────────────────────────────────────────────────

fn failedResult(alloc: std.mem.Allocator, msg: []const u8) builtin.ToolResult {
    const out = alloc.dupe(u8, "") catch "";
    const err = alloc.dupe(u8, msg) catch msg;
    return .{ .success = false, .output = out, .err_msg = err };
}

/// Execute a bridged tool by its LOCAL name. Output/err_msg are allocated
/// with `alloc`; free them via `builtin.freeResult`.
pub fn execute(alloc: std.mem.Allocator, name: []const u8, arguments: []const u8) builtin.ToolResult {
    if (std.mem.eql(u8, name, "list_mcp_resources")) return resourceTool(alloc, arguments, .list);
    if (std.mem.eql(u8, name, "list_mcp_resource_templates")) return resourceTool(alloc, arguments, .templates);
    if (std.mem.eql(u8, name, "read_mcp_resource")) return resourceRead(alloc, arguments);
    const entry = getInstance(name) orelse
        return failedResult(alloc, "unknown bridged MCP tool");
    return executeEntry(alloc, entry, arguments);
}

const ResourceOp = enum { list, templates };

fn pickServer(alloc: std.mem.Allocator, arguments: []const u8) ?*mcp.McpClient {
    const want = model.extractStringField(alloc, arguments, "server") catch null;
    defer if (want) |w| alloc.free(w);
    if (want) |w| return getServer(w);
    return firstServer();
}

fn transportFail(alloc: std.mem.Allocator, what: []const u8, e: anyerror) builtin.ToolResult {
    const detail = std.fmt.allocPrint(alloc, "{s}: {s}", .{ what, @errorName(e) }) catch what;
    return .{ .success = false, .output = alloc.dupe(u8, "") catch "", .err_msg = detail };
}

fn resourceTool(alloc: std.mem.Allocator, arguments: []const u8, op: ResourceOp) builtin.ToolResult {
    const client = pickServer(alloc, arguments) orelse
        return failedResult(alloc, "no attached MCP server matches 'server'");
    const raw = (switch (op) {
        .list => client.listResources(),
        .templates => client.listResourceTemplates(),
    }) catch |e| return transportFail(alloc, "mcp resources", e);
    defer alloc.free(raw);
    const out = alloc.dupe(u8, raw) catch return failedResult(alloc, "oom copying mcp output");
    return .{ .success = true, .output = out, .err_msg = null };
}

fn resourceRead(alloc: std.mem.Allocator, arguments: []const u8) builtin.ToolResult {
    const client = pickServer(alloc, arguments) orelse
        return failedResult(alloc, "no attached MCP server matches 'server'");
    const uri = (model.extractStringField(alloc, arguments, "uri") catch null) orelse
        return failedResult(alloc, "read_mcp_resource: missing 'uri'");
    defer alloc.free(uri);
    const raw = client.readResource(uri) catch |e| return transportFail(alloc, "mcp read_resource", e);
    defer alloc.free(raw);
    const out = alloc.dupe(u8, raw) catch return failedResult(alloc, "oom copying mcp output");
    return .{ .success = true, .output = out, .err_msg = null };
}

fn executeEntry(
    alloc: std.mem.Allocator,
    entry: Entry,
    arguments: []const u8,
) builtin.ToolResult {
    var outcome = entry.client.callTool(entry.remote_name, arguments) catch |e| {
        const detail = std.fmt.allocPrint(alloc, "mcp transport: {s}", .{@errorName(e)}) catch
            "mcp transport error";
        return .{ .success = false, .output = alloc.dupe(u8, "") catch "", .err_msg = detail };
    };
    defer outcome.deinit(entry.client.alloc);
    const output = alloc.dupe(u8, outcome.text) catch
        return failedResult(alloc, "oom copying mcp output");
    if (outcome.ok) {
        return .{ .success = true, .output = output, .err_msg = null };
    }
    const err = alloc.dupe(u8, "MCP tool reported isError") catch "MCP tool reported isError";
    return .{ .success = false, .output = output, .err_msg = err };
}

// ── registration ────────────────────────────────────────────────────────────

pub const RegisterError = error{
    OutOfMemory,
    NameTooLong,
} || mcp.McpError || std.mem.Allocator.Error;

/// List the server's tools and register each as a bridged definition +
/// executor binding. Returns how many tools were registered. On a mid-loop
/// failure the tools registered so far REMAIN (callers may clearInstances +
/// rebuild); the returned error reports the first failure.
pub fn registerServerTools(
    alloc: std.mem.Allocator,
    reg: *registry.ToolRegistry,
    server_label: []const u8,
    client: *mcp.McpClient,
) RegisterError!usize {
    var list = try client.listTools();
    // listTools allocates with the client's own allocator.
    defer list.deinit(client.alloc);

    var registered: usize = 0;
    var name_buf: [128]u8 = undefined;
    for (list.tools) |tool| {
        const local = localToolName(&name_buf, server_label, tool.name) orelse
            return error.NameTooLong;
        var def = try makeDefinition(alloc, server_label, tool);
        if (reg.register(def)) |_| {
            freeDefinitionTemp(alloc, &def);
        } else |e| {
            freeDefinitionTemp(alloc, &def);
            return e;
        }
        try putInstance(alloc, local, client, tool.name);
        registered += 1;
    }
    if (registered > 0) try putServer(alloc, server_label, client);
    return registered;
}

/// Register the MCP resource inspection tools (once, when any server is
/// attached). They resolve a server by optional label, else the first.
pub fn registerResourceTools(reg: *registry.ToolRegistry) !void {
    try reg.register(.{
        .name = "list_mcp_resources",
        .description = "List resources exposed by an attached MCP server. Optional 'server' label; defaults to the first attached server.",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"server":{"type":"string","description":"MCP server label (mcp0, mcp1, ...)"}},"required":[]}
        ,
    });
    try reg.register(.{
        .name = "list_mcp_resource_templates",
        .description = "List parameterized resource templates exposed by an attached MCP server.",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"server":{"type":"string"}},"required":[]}
        ,
    });
    try reg.register(.{
        .name = "read_mcp_resource",
        .description = "Read one MCP resource by URI from an attached server.",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"server":{"type":"string"},"uri":{"type":"string","description":"Resource URI from list_mcp_resources"}},"required":["uri"]}
        ,
    });
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "resource tools register and fail closed without a server" {
    const alloc = testing.allocator;
    var reg = try registry.ToolRegistry.init(alloc);
    defer reg.deinit();
    clearInstances();
    try registerResourceTools(&reg);
    try testing.expect(reg.contains("list_mcp_resources"));
    try testing.expect(reg.contains("list_mcp_resource_templates"));
    try testing.expect(reg.contains("read_mcp_resource"));

    var r = execute(alloc, "list_mcp_resources", "{}");
    defer builtin.freeResult(alloc, &r);
    try testing.expect(!r.success);
    try testing.expect(std.mem.indexOf(u8, r.err_msg.?, "no attached MCP server") != null);
}

test "sanitizeToken lowercases and replaces invalid characters" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("my_server", sanitizeToken(&buf, "My Server").?);
    try testing.expectEqualStrings("fs_read_file_", sanitizeToken(&buf, "fs.read-file!").?);
    try testing.expectEqualStrings("already_clean_42", sanitizeToken(&buf, "already_Clean_42").?);
    try testing.expect(sanitizeToken(buf[0..3], "too-long-for-buf") == null);
}

test "localToolName formats mcp_<server>_<tool>" {
    var buf: [128]u8 = undefined;
    const n = localToolName(&buf, "My Server", "fs.read-file").?;
    try testing.expectEqualStrings("mcp_my_server_fs_read_file", n);
    try testing.expect(isBridgedName(n));
    try testing.expect(!isBridgedName("shell"));

    // Overflow yields null instead of truncation collisions.
    var tiny: [10]u8 = undefined;
    try testing.expect(localToolName(&tiny, "server", "tool-name-that-is-way-too-long") == null);
}

test "definition translation passes the schema through" {
    const alloc = testing.allocator;
    const remote = mcp.RemoteTool{
        .name = "echo",
        .description = "Echo input.",
        .schema_json = "{\"type\":\"object\",\"properties\":{\"msg\":{\"type\":\"string\"}}}",
    };
    const def = try makeDefinition(alloc, "fake", remote);
    defer freeDefinitionTemp(alloc, &def);
    try testing.expectEqualStrings("mcp_fake_echo", def.name);
    try testing.expectEqualStrings("Echo input.", def.description);
    try testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"msg\":{\"type\":\"string\"}}}",
        def.parameters_json,
    );
    try testing.expect(def.category == .general);

    // Empty description/schema get documented fallbacks.
    const bare = mcp.RemoteTool{ .name = "b", .description = "", .schema_json = "" };
    const def2 = try makeDefinition(alloc, "fake", bare);
    defer freeDefinitionTemp(alloc, &def2);
    try testing.expect(std.mem.indexOf(u8, def2.description, "'b'") != null);
    try testing.expectEqualStrings("{}", def2.parameters_json);
}

test "instance map put/get/remove/overwrite/clear" {
    const alloc = testing.allocator;
    defer clearInstances();

    var dummy_client: mcp.McpClient = undefined; // never used for I/O here
    try putInstance(alloc, "mcp_a_one", &dummy_client, "one");
    try putInstance(alloc, "mcp_a_two", &dummy_client, "two");

    const e1 = getInstance("mcp_a_one").?;
    try testing.expectEqualStrings("one", e1.remote_name);
    try testing.expect(getInstance("mcp_a_missing") == null);

    // Stack-buffer names are safe: the map duplicates them.
    var stack_name: [16]u8 = undefined;
    const tmp = std.fmt.bufPrint(&stack_name, "mcp_{d}_x", .{7}) catch unreachable;
    try putInstance(alloc, tmp, &dummy_client, "seven");
    try testing.expectEqualStrings("seven", getInstance(tmp).?.remote_name);

    // Overwrite releases the previous binding.
    try putInstance(alloc, "mcp_a_one", &dummy_client, "one-v2");
    try testing.expectEqualStrings("one-v2", getInstance("mcp_a_one").?.remote_name);

    try testing.expect(removeInstance("mcp_a_two"));
    try testing.expect(!removeInstance("mcp_a_two"));
    try testing.expect(getInstance("mcp_a_two") == null);

    clearInstances();
    try testing.expect(getInstance("mcp_a_one") == null);
}

test "execute resolves through the map against a fake server" {
    const alloc = testing.allocator;
    defer clearInstances();

    // Fake transport: two pipe pairs, no real process.
    const up = try mcp.createPipePair(); // client -> fake
    const down = try mcp.createPipePair(); // fake -> client
    var client = mcp.McpClient.connectFds(alloc, up[1], down[0]);
    defer {
        client.deinit();
        _ = std.posix.system.close(up[0]);
        _ = std.posix.system.close(down[1]);
    }

    try putInstance(alloc, "mcp_fake_echo", &client, "echo");

    // Script the response for tools/call id 0 BEFORE executing.
    const wire =
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"echoed: hi\"}]}}\n";
    var off: usize = 0;
    while (off < wire.len) {
        const rc = std.posix.system.write(down[1], wire.ptr + off, wire.len - off);
        switch (std.posix.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }

    var res = execute(alloc, "mcp_fake_echo", "{\"msg\":\"hi\"}");
    defer builtin.freeResult(alloc, &res);
    try testing.expect(res.success);
    try testing.expectEqualStrings("echoed: hi", res.output);
    try testing.expect(res.err_msg == null);

    // Unknown local name fails cleanly.
    var bad = execute(alloc, "mcp_nope_ghost", "{}");
    defer builtin.freeResult(alloc, &bad);
    try testing.expect(!bad.success);
    try testing.expect(bad.err_msg != null);
}

test "registerServerTools bridges the whole catalog end-to-end" {
    const alloc = testing.allocator;
    defer clearInstances();

    const up = try mcp.createPipePair();
    const down = try mcp.createPipePair();
    var client = mcp.McpClient.connectFds(alloc, up[1], down[0]);
    defer {
        client.deinit();
        _ = std.posix.system.close(up[0]);
        _ = std.posix.system.close(down[1]);
    }
    var reg = try registry.ToolRegistry.init(alloc);
    defer reg.deinit();

    // Script tools/list (id 0) with two tools; one has a messy remote name
    // to prove sanitization, one lacks optional fields.
    const result =
        "{\"tools\":[" ++
        "{\"name\":\"Echo!\",\"description\":\"Echo input.\"," ++
        "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"msg\":{\"type\":\"string\"}},\"required\":[\"msg\"]}}" ++
        ",{\"name\":\"bare\"}]}";
    const wire = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{s}}}\n",
        .{result},
    );
    defer alloc.free(wire);
    var off: usize = 0;
    while (off < wire.len) {
        const rc = std.posix.system.write(down[1], wire.ptr + off, wire.len - off);
        switch (std.posix.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }

    const count = try registerServerTools(alloc, &reg, "Fake Server", &client);
    try testing.expectEqual(@as(usize, 2), count);

    // Registry holds sanitized names with passthrough schemas.
    try testing.expect(reg.contains("mcp_fake_server_echo_"));
    try testing.expect(reg.contains("mcp_fake_server_bare"));
    const def = reg.get("mcp_fake_server_echo_").?;
    try testing.expectEqualStrings("Echo input.", def.description);
    try testing.expect(
        std.mem.indexOf(u8, def.parameters_json, "\"required\":[\"msg\"]") != null,
    );

    // Executor bindings resolve and can run a scripted tools/call (id 1 —
    // id 0 was consumed by tools/list).
    const call_wire =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"pong\"}]}}\n";
    var coff: usize = 0;
    while (coff < call_wire.len) {
        const rc = std.posix.system.write(down[1], call_wire.ptr + coff, call_wire.len - coff);
        switch (std.posix.errno(rc)) {
            .SUCCESS => coff += @intCast(rc),
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }
    var res = execute(alloc, "mcp_fake_server_echo_", "{\"msg\":\"ping\"}");
    defer builtin.freeResult(alloc, &res);
    try testing.expect(res.success);
    try testing.expectEqualStrings("pong", res.output);
}
