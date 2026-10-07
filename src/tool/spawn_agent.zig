//! spawn_agent tool (dev.md §XVIII): lets the MAIN agent delegate a bounded
//! task to an isolated SubAgent (agent/subagent.zig) and receive the final
//! text back as a tool result, with a turn-count footer.
//!
//! ── Integrator contract (READ BEFORE WIRING) ────────────────────────────
//! Registry executors are PLAIN FUNCTIONS — `tool/registry.zig` stores only
//! ToolDefinition data (name/description/parameters_json) and gives executors
//! no per-tool context slot. Since we may NOT edit registry.zig, this module
//! keeps exactly ONE module-level context slot:
//!
//!     var g_spawn_ctx: ?*SpawnDeps = null;
//!     pub fn setSpawnCtx(ctx: *SpawnDeps) void;   // call once at startup
//!     pub fn clearSpawnCtx() void;                // call once at shutdown
//!
//! The integrator MUST:
//!   1. Build a SpawnDeps (see struct doc) after ChatClient + registry exist.
//!   2. Call `spawn_agent.setSpawnCtx(&deps)` before the first model turn.
//!   3. Register the definition:  try reg.register(spawn_agent.definition);
//!      and route calls named "spawn_agent" to spawn_agent.execute in the
//!      dispatcher (main.zig / builtin dispatch — integrator side).
//!   4. Call clearSpawnCtx() at shutdown.
//!
//! Until setSpawnCtx runs, `execute` returns a FAILED ToolResult explaining
//! the missing wiring — it never crashes and never spawns anything. The slot
//! is NOT synchronized: single-threaded (per agent loop) contract only.
//!
//! ── SpawnDeps fields ─────────────────────────────────────────────────────
//!   .deps               — an agent/subagent.zig SubAgentDeps bundle:
//!                         .alloc (executor-result allocator), .ctx (opaque),
//!                         .chat_fn, .exec_fn, .tools (shared parent
//!                         registry). Ready-made production thunks live
//!                         below: chatThunk + execThunk over SpawnEnv.
//!   .default_max_turns  — used when the model omits max_turns.
//!   .default_output_cap — output_char_cap for every spawned child.
//!
//! Ownership of tool results follows tool/builtin.zig conventions:
//! `execute` allocates its ToolResult.output/err_msg with the allocator it is
//! given; the caller frees them (same pattern as builtin.freeResult).

const std = @import("std");
const model_mod = @import("../model/model.zig");
const builtin = @import("builtin.zig");
const subagents_rpc = @import("../server/apiproxy/subagents_rpc.zig");
const tool_reg = @import("registry.zig");
const subagent = @import("../agent/subagent.zig");

/// Hard ceiling on max_turns requested through tool arguments — a runaway or
/// adversarial model cannot request an unbounded child loop.
pub const hard_max_turns: usize = 64;

// ── module-level wiring slot (see header contract) ──────────────────────────

var g_spawn_ctx: ?*SpawnDeps = null;

pub fn setSpawnCtx(ctx: *SpawnDeps) void {
    g_spawn_ctx = ctx;
}

pub fn clearSpawnCtx() void {
    g_spawn_ctx = null;
}

/// Current wiring (null until setSpawnCtx). Exposed for tests/introspection.
pub fn spawnCtx() ?*SpawnDeps {
    return g_spawn_ctx;
}

pub const SpawnDeps = struct {
    /// Injected transport + executor handed to subagent.runSubagent.
    deps: subagent.SubAgentDeps,
    /// Turn budget when the caller does not override max_turns.
    default_max_turns: usize = subagent.default_max_turns,
    /// Output byte cap for the child's accumulated answer.
    default_output_cap: usize = subagent.default_output_cap,
    /// Parent session for optional GUI subagent inventory tracking.
    parent_session_id: []const u8 = "",
};

/// Production environment for the ready-made thunks: point SpawnDeps.deps.ctx
/// at one of these and use chatThunk/execThunk as chat_fn/exec_fn.
pub const SpawnEnv = struct {
    client: *model_mod.ChatClient,
    io: std.Io,
    cwd: []const u8,
    /// Parent's sandbox policy, forwarded to builtin.execute (see W1 wiring).
    sandbox_mode: @import("../config.zig").Config.SandboxMode = .native,
    parent_session_id: []const u8 = "",
};

/// Ready-made SubAgentDeps.chat_fn: ctx = *SpawnEnv.
pub fn chatThunk(d: *subagent.SubAgentDeps, req: model_mod.ChatRequest) anyerror!model_mod.ChatResponse {
    const env: *SpawnEnv = @ptrCast(@alignCast(d.ctx.?));
    return env.client.chat(req);
}

/// Ready-made SubAgentDeps.exec_fn: ctx = *SpawnEnv. Dispatches through the
/// builtin executor with the parent's io/cwd so children share the parent's
/// tool surface + sandbox policy. Output allocated with d.alloc (the
/// subagent loop frees it).
pub fn execThunk(d: *subagent.SubAgentDeps, call: model_mod.ToolCall) anyerror!subagent.ToolResult {
    const env: *SpawnEnv = @ptrCast(@alignCast(d.ctx.?));
    // Recursion guard: children never spawn further agents (depth is
    // unbounded otherwise). The schema stays visible to them via the shared
    // registry, so enforcement has to happen here at dispatch time.
    if (std.mem.eql(u8, call.name, "spawn_agent")) {
        const msg = try std.fmt.allocPrint(
            d.alloc,
            "[error] sub-agents cannot spawn further agents; finish your task and report back",
            .{},
        );
        return .{ .success = false, .output = msg };
    }
    const r = try builtin.execute(d.alloc, env.io, env.cwd, .{
        .name = call.name,
        .arguments = call.arguments,
    }, env.sandbox_mode);
    return .{ .success = r.success, .output = r.output };
}

// ── registry-facing definition (matches registry schema style) ─────────────

pub const definition = tool_reg.ToolDefinition{
    .name = "spawn_agent",
    .description =
    \\Spawn an isolated sub-agent to work on one bounded task with its own
    \\context window and message history, then hand back only its final text.
    \\Use for focused subtasks (research a file, draft a summary) that would
    \\clutter the main conversation. The sub-agent shares this workspace's
    \\tools but not your conversation.
    ,
    .category = .general,
    .parameters_json =
    \\{"type":"object","properties":{"task":{"type":"string","description":"Complete self-contained task description for the sub-agent"},"name":{"type":"string","description":"Optional short name for the sub-agent (e.g. 'researcher')"},"max_turns":{"type":"integer","description":"Optional turn budget (1-64). Defaults to the harness setting"}},"required":["task"]}
    ,
};

/// Upstream agent-team shape: a named teammate. Maps onto the same synchronous
/// subagent run (context=fork is accepted but treated as fresh).
pub const teammate_definition = tool_reg.ToolDefinition{
    .name = "spawn_teammate",
    .description =
    \\Create one named teammate that works a delegated task in its own context and
    \\reports back its final text. Like spawn_agent, but addressed by a required
    \\lower-kebab name. context=fork is accepted but behaves like fresh.
    ,
    .category = .general,
    .parameters_json =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Unique lower-kebab-case teammate name"},"description":{"type":"string","description":"Short description of the responsibility"},"prompt":{"type":"string","description":"Complete initial task for the teammate"},"context":{"type":"string","enum":["fresh","fork"],"description":"Defaults to fresh (fork accepted, treated as fresh)"},"max_turns":{"type":"integer","description":"Optional turn budget (1-64)"}},"required":["name","description","prompt"]}
    ,
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

/// Dispatch a spawn_agent call. Signature mirrors tool/builtin.zig's execute
/// convention: allocations use `alloc`; the caller frees via freeResult.
pub fn execute(alloc: std.mem.Allocator, call: ToolCall) !ToolResult {
    const is_teammate = std.mem.eql(u8, call.name, teammate_definition.name);
    if (!is_teammate and !std.mem.eql(u8, call.name, definition.name))
        return fail(alloc, "unknown spawn tool");
    const wiring = g_spawn_ctx orelse return fail(
        alloc,
        "spawn_agent is not wired: the host must call spawn_agent.setSpawnCtx(&SpawnDeps{...}) at startup",
    );

    var args = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &args);

    const task = args.get("task") orelse args.get("prompt") orelse
        return fail(alloc, if (is_teammate) "missing prompt" else "missing task");
    if (task.len == 0)
        return fail(alloc, "task must be a non-empty string");
    if (is_teammate) {
        const nm = args.get("name") orelse return fail(alloc, "missing name");
        if (nm.len == 0) return fail(alloc, "name must be a non-empty string");
    }

    // Always dupe name/system_prompt into `alloc` so the defers below have a
    // single, unconditional ownership story.
    var spec = subagent.SubAgentSpec{
        .name = try alloc.dupe(u8, "subagent"),
        .system_prompt = "",
        .max_turns = wiring.default_max_turns,
        .output_char_cap = wiring.default_output_cap,
    };
    defer alloc.free(spec.name);
    defer alloc.free(spec.system_prompt);

    if (args.get("name")) |n| {
        if (n.len > 0) {
            const new_name = try alloc.dupe(u8, n);
            alloc.free(spec.name);
            spec.name = new_name;
        }
    }
    spec.system_prompt = try std.fmt.allocPrint(
        alloc,
        "You are '{s}', a focused sub-agent spawned by the main zharness agent. Work autonomously on the single task you are given. When finished, reply with the complete final result as plain text.",
        .{spec.name},
    );

    if (args.get("max_turns")) |raw| {
        const parsed = std.fmt.parseInt(usize, std.mem.trim(u8, raw, " "), 10) catch null;
        if (parsed) |mt| spec.max_turns = @min(@max(mt, 1), hard_max_turns);
    }

    const child_id = if (wiring.parent_session_id.len > 0)
        subagents_rpc.beginRun(alloc, wiring.parent_session_id, spec.name, task) catch null
    else
        null;
    // Per-run deps copy so the cooperative hooks can address this run by id
    // (send_message queues text, interrupt_agent requests cancellation).
    var run_deps = wiring.deps;
    if (child_id) |id| {
        run_deps.hook_run_id = id;
        run_deps.should_cancel = cancelHook;
        run_deps.drain_inbox = inboxHook;
    }
    var outcome = subagent.runSubagent(alloc, &run_deps, spec, task) catch |e| {
        if (child_id) |id| {
            subagents_rpc.endRun(id, false, null);
            alloc.free(id);
        }
        return fail(alloc, @errorName(e));
    };
    defer outcome.deinit(alloc);
    if (child_id) |id| {
        subagents_rpc.endRun(id, !outcome.cancelled, outcome.text);
        alloc.free(id);
    }

    // Final text plus a small footer so the parent can see the cost.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, outcome.text);
    try out.appendSlice(alloc, "\n\n[subagent '");
    try out.appendSlice(alloc, spec.name);
    try out.appendSlice(alloc, "' finished: ");
    try appendTurnSummary(alloc, &out, outcome.turns_used, outcome.truncated);
    if (outcome.cancelled) try out.appendSlice(alloc, ", cancelled by request");
    try out.appendSlice(alloc, "]");
    return .{ .success = true, .output = try out.toOwnedSlice(alloc), .err_msg = null };
}

fn cancelHook(d: *subagent.SubAgentDeps) bool {
    if (d.hook_run_id.len == 0) return false;
    const reg = subagents_rpc.shared() catch return false;
    return reg.cancelRequested(d.hook_run_id);
}

fn inboxHook(d: *subagent.SubAgentDeps, alloc: std.mem.Allocator) anyerror!?[]const u8 {
    if (d.hook_run_id.len == 0) return null;
    const reg = subagents_rpc.shared() catch return null;
    return reg.drainInbox(alloc, d.hook_run_id);
}

fn appendTurnSummary(alloc: std.mem.Allocator, out: *std.ArrayList(u8), turns: usize, truncated: bool) !void {
    var buf: [32]u8 = undefined;
    const n = try std.fmt.bufPrint(&buf, "{d} turn(s)", .{turns});
    try out.appendSlice(alloc, n);
    if (truncated) try out.appendSlice(alloc, ", truncated");
}

// ── flat JSON arg parsing (same pattern as tool/builtin.zig) ───────────────

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

/// Parse a flat JSON object of string/number/boolean values into a map.
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

test "definition registers into registry and matches schema fixture" {
    const alloc = std.testing.allocator;

    // Fixture: exact wire schema the model sees for spawn_agent.
    const fixture =
        \\{"type":"object","properties":{"task":{"type":"string","description":"Complete self-contained task description for the sub-agent"},"name":{"type":"string","description":"Optional short name for the sub-agent (e.g. 'researcher')"},"max_turns":{"type":"integer","description":"Optional turn budget (1-64). Defaults to the harness setting"}},"required":["task"]}
    ;
    try std.testing.expectEqualStrings(fixture, definition.parameters_json);
    try std.testing.expectEqualStrings("spawn_agent", definition.name);
    try std.testing.expect(definition.description.len > 0);

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try reg.register(definition);
    const got = reg.get("spawn_agent") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("spawn_agent", got.name);
    try std.testing.expect(std.mem.indexOf(u8, got.parameters_json, "\"required\":[\"task\"]") != null);

    // buildToolsJson serializes it as a valid OpenAI tools fragment.
    const tools_json = try reg.buildToolsJson(alloc);
    defer alloc.free(tools_json);
    try std.testing.expect(std.mem.startsWith(u8, tools_json, "{\"type\":\"function\",\"function\":{\"name\":\"spawn_agent\""));
}

test "unwired executor fails gracefully" {
    const alloc = std.testing.allocator;
    clearSpawnCtx(); // guarantee the unwired state regardless of test order
    var res = try execute(alloc, .{ .name = "spawn_agent", .arguments = "{\"task\":\"x\"}" });
    defer freeResult(alloc, &res);
    try std.testing.expect(!res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.err_msg.?, "setSpawnCtx") != null);
}

test "wired execute returns subagent text with turn footer" {
    const alloc = std.testing.allocator;

    var scripted = subagent.ScriptedChat.init(alloc, &.{
        .{ .content = "research complete: 42" },
    });
    defer scripted.deinit();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try reg.register(.{ .name = "shell", .description = "sh", .parameters_json = "{}" });

    var wiring = SpawnDeps{ .deps = scripted.deps(&reg) };
    setSpawnCtx(&wiring);
    defer clearSpawnCtx();

    var res = try execute(alloc, .{
        .name = "spawn_agent",
        .arguments =
        \\{"task":"find the answer","name":"researcher","max_turns":2}
        ,
    });
    defer freeResult(alloc, &res);

    try std.testing.expect(res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "research complete: 42") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, res.output, "[subagent 'researcher' finished: 1 turn(s)]") != null,
    );
    try std.testing.expectEqual(@as(usize, 1), scripted.chat_calls);

    // Missing task argument → clean failure, no spawn.
    var bad = try execute(alloc, .{ .name = "spawn_agent", .arguments = "{\"name\":\"x\"}" });
    defer freeResult(alloc, &bad);
    try std.testing.expect(!bad.success);
    try std.testing.expectEqualStrings("missing task", bad.err_msg.?);
}

test "max_turns clamped to hard ceiling" {
    const alloc = std.testing.allocator;

    // Always requests another tool round: the clamp is the only thing that
    // stops the child after hard_max_turns rounds.
    var scripted = subagent.ScriptedChat.init(alloc, &.{
        .{ .content = "still working", .tool_name = "shell" },
    });
    defer scripted.deinit();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try reg.register(.{ .name = "shell", .description = "sh", .parameters_json = "{}" });

    var wiring = SpawnDeps{ .deps = scripted.deps(&reg) };
    setSpawnCtx(&wiring);
    defer clearSpawnCtx();

    var res = try execute(alloc, .{
        .name = "spawn_agent",
        .arguments = "{\"task\":\"runaway\",\"max_turns\":99999}",
    });
    defer freeResult(alloc, &res);

    try std.testing.expect(res.success); // capped run still yields text back
    try std.testing.expectEqual(@as(usize, hard_max_turns), scripted.chat_calls);
    try std.testing.expect(
        std.mem.indexOf(u8, res.output, "[subagent 'subagent' finished: 64 turn(s), truncated]") != null,
    );
}

test "spawn_teammate runs via prompt and requires a name" {
    const alloc = std.testing.allocator;
    var scripted = subagent.ScriptedChat.init(alloc, &.{
        .{ .content = "teammate done" },
    });
    defer scripted.deinit();
    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    var wiring = SpawnDeps{ .deps = scripted.deps(&reg) };
    setSpawnCtx(&wiring);
    defer clearSpawnCtx();

    var res = try execute(alloc, .{
        .name = "spawn_teammate",
        .arguments = "{\"name\":\"scout\",\"description\":\"look\",\"prompt\":\"find it\"}",
    });
    defer freeResult(alloc, &res);
    try std.testing.expect(res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "teammate done") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "[subagent 'scout' finished") != null);

    var bad = try execute(alloc, .{
        .name = "spawn_teammate",
        .arguments = "{\"description\":\"look\",\"prompt\":\"find it\"}",
    });
    defer freeResult(alloc, &bad);
    try std.testing.expect(!bad.success);
    try std.testing.expectEqualStrings("missing name", bad.err_msg.?);
}
