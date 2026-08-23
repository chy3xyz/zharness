const std = @import("std");
const clib = @import("clib.zig");
const cordis = @import("cordis");

const cli_flags = @import("cli_flags.zig");
const config = @import("config.zig");
const model = @import("model/model.zig");
const tool_reg = @import("tool/registry.zig");
const tool_builtin = @import("tool/builtin.zig");
const agent = @import("agent/agent.zig");
const session = @import("session/session.zig");

// Orphan modules wired by this pass (dev.md §XIII–XVII).
const checkpoint = @import("session/checkpoint.zig");
const skill_mod = @import("skill/skill.zig");
const skill_loader = @import("skill/loader.zig");
const mem_persistent = @import("memory/persistent.zig");
const mem_working = @import("memory/working.zig");
const plan_mod = @import("agent/plan.zig");
const goal_mod = @import("agent/goal.zig");

// Swarm wave-2 capabilities (dev.md §VI/§XVIII–XXVI/§XXVIII/§XXX).
const presets_mod = @import("presets.zig");
const obs_mod = @import("obs.zig");
const httpd = @import("server/httpd.zig");
const api = @import("server/api.zig");
const webfetch = @import("tool/webfetch.zig");
const spawn_agent = @import("tool/spawn_agent.zig");
const subagent_mod = @import("agent/subagent.zig");
const wf_mod = @import("workflow/workflow.zig");
const wf_exec = @import("workflow/executor.zig");
const wf_report = @import("workflow/run_report.zig");
const mcp_mod = @import("protocol/mcp.zig");
const mcp_bridge = @import("tool/mcp_bridge.zig");
const plugin_loader = @import("pluginabi/loader.zig");
const wasm_loader = @import("pluginabi/wasm_loader.zig");
const server_events = @import("server/events.zig");
const server_static = @import("server/static.zig");

const SYSTEM_PROMPT =
    \\You are zharness, a coding agent running inside a workspace. You help the user by
    \\reading, editing, and searching files, running shell commands, and using git. Prefer
    \\small, focused changes and verify them. Use the provided tools to inspect and modify
    \\the codebase rather than guessing. When you finish, give a concise final answer that
    \\summarizes what you did and any follow-up needed.
;

fn onEvent(kind: agent.AgentLoop.EventKind, payload: []const u8) void {
    obsEmit(kind, payload);
    switch (kind) {
        .thinking => std.debug.print("[thinking] {s}\n", .{payload}),
        .text => std.debug.print("{s}", .{payload}),
        .tool_call => std.debug.print("\n> calling {s}\n", .{payload}),
        .tool_result => std.debug.print("  -> {s}\n", .{payload}),
        .turn_start => {},
        .done => std.debug.print("\n=== Final answer ===\n{s}\n", .{payload}),
        .err => std.debug.print("\n[error] {s}\n", .{payload}),
    }
}

/// Live-delta sink for streamed chat completions: text prints as it arrives;
/// reasoning prints dimmed so it reads as scaffolding, not the answer.
fn onStreamDelta(kind: model.StreamKind, delta: []const u8) void {
    switch (kind) {
        .text => std.debug.print("{s}", .{delta}),
        .reasoning => std.debug.print("\x1b[2m{s}\x1b[0m", .{delta}),
    }
}

// ── observability (dev.md §XXX): JSONL event envelopes per run ──────────────

/// Module-level obs state for the current run. The loop's on_event callback
/// has no context slot, and the CLI is single-threaded per run, so a slot is
/// the same pattern spawn_agent uses. Null = observability disabled.
const ObsState = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    sink: *obs_mod.JsonlSink,
    trace: obs_mod.TraceCtx,
};

var g_obs: ?ObsState = null;

/// Long-lived Io for standalone commands (serve/workflow/plugin) that do not
/// go through a cordis Context. Null for run/chat (they use the ctx's io).
var g_io: ?std.Io = null;

fn obsBegin(alloc: std.mem.Allocator, io: std.Io, session_id: []const u8) void {
    const sink = alloc.create(obs_mod.JsonlSink) catch return;
    sink.* = obs_mod.JsonlSink.init(alloc, obs_mod.default_log_path) catch {
        alloc.destroy(sink);
        return;
    };
    g_obs = .{
        .alloc = alloc,
        .io = io,
        .sink = sink,
        .trace = obs_mod.TraceCtx.start(io, session_id, "agent-1"),
    };
}

fn obsEnd(alloc: std.mem.Allocator) void {
    if (g_obs) |st| {
        st.sink.deinit();
        alloc.destroy(st.sink);
        g_obs = null;
    }
}

/// Map the loop's event stream onto dev.md §XXX event types, emitting one
/// JSONL envelope per event when observability is active. Best-effort:
/// formatting/allocation failures drop the event instead of failing the turn.
fn obsEmit(kind: agent.AgentLoop.EventKind, payload: []const u8) void {
    const st = g_obs orelse return;
    const et: []const u8 = switch (kind) {
        .turn_start => "agent.turn_start",
        .thinking => "model.thinking",
        .text => "model.text",
        .tool_call => "tool.started",
        .tool_result => "tool.completed",
        .done => "agent.stopped",
        .err => "error",
    };
    var pj: std.ArrayList(u8) = .empty;
    defer pj.deinit(st.alloc);
    pj.appendSlice(st.alloc, "{\"detail\":\"") catch return;
    model.escape(st.alloc, payload, &pj) catch return;
    pj.appendSlice(st.alloc, "\"}") catch return;
    st.sink.emitAt(st.io, &st.trace, .info, et, pj.items);
}

// ── loop extensions: skills / memory / plan / goal (dev.md §XIII–XVII) ─────

fn homeDir() ?[]const u8 {
    const p = std.c.getenv("HOME") orelse return null;
    const h = std.mem.span(p);
    if (h.len == 0) return null;
    return h;
}

/// Split an --mcp command line on whitespace (no quote handling yet —
/// document this in --help). Returns an owned argv slice; empty input yields
/// an empty slice so callers can skip cheaply.
fn splitCommand(alloc: std.mem.Allocator, cmd: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    while (it.next()) |tok| try out.append(alloc, tok);
    return out.toOwnedSlice(alloc);
}

/// Preset gate for the CORE builtin toolset only (dev.md §XXVIII): names not
/// listed by the preset are removed from the registry. Harness capabilities
/// (plan/goal/memory/skill/web/mcp/plugin/spawn_agent) always stay available.
fn builtinAllowedByPreset(allowed: []const []const u8, name: []const u8) bool {
    for (allowed) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

/// Translate parsed CLI flags into loop options (preset selection + MCP
/// servers). Exits with a usage message on invalid preset names.
fn optsFromFlags(alloc: std.mem.Allocator, flags: *const cli_flags.SubFlags) !LoopOpts {
    var lopts = LoopOpts{};
    if (flags.preset) |pname| {
        lopts.preset = presets_mod.fromString(pname) catch {
            std.debug.print("error: unknown preset '{s}' (standard | minimal | ptc | creative)\n", .{pname});
            std.process.exit(1);
        };
    }
    if (flags.mcp_count > 0) {
        const cmds = try alloc.alloc([]const u8, flags.mcp_count);
        for (0..flags.mcp_count) |i| cmds[i] = flags.mcp_cmds[i].?;
        lopts.mcp_cmds = cmds;
    }
    return lopts;
}

/// Apply the --sandbox flag directly onto the loaded config.
fn applySandboxOverride(cfg: *config.Config, flag: ?[]const u8) void {
    const v = flag orelse return;
    cfg.sandbox_mode = config.Config.SandboxMode.fromString(v);
}

/// The agent-loop extension state. Everything here is main-owned; the loop
/// only sees the two fn pointers exposed via `extensions()`.
pub const LoopExtensions = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Discovered SKILL.md packages (null when none were found).
    skills: ?*skill_mod.SkillRegistry = null,
    /// Durable key/value facts at ~/.zharness/memory (null without HOME).
    memory: ?*mem_persistent.PersistentStore = null,
    /// In-RAM task/plan scratchpad rendered into context.
    working: ?*mem_working.WorkingMemory = null,
    plan_board: *plan_mod.PlanBoard,
    goal_board: *goal_mod.GoalBoard,
    /// Native dylib plugins (null when no plugin dirs had loadable entries).
    plugins: ?*plugin_loader.PluginRegistry = null,
    /// WASM plugin registry (null when no .wasm tools were discovered).
    wasm: ?*wasm_loader.WasmRegistry = null,
    /// Workspace cwd for cwd-aware extension tools (web_fetch etc.).
    cwd: []const u8,

    pub fn extensions(self: *LoopExtensions) agent.Extensions {
        return .{ .ctx = self, .renderContext = renderContext, .executeTool = execTool };
    }

    /// Dynamic system-prompt section: skill index + goal + plan checklist +
    /// working memory snapshot, joined with blank lines. "" when inactive.
    fn renderContext(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]const u8 {
        const self: *LoopExtensions = @ptrCast(@alignCast(ctx));
        var parts: std.ArrayList([]const u8) = .empty;
        defer {
            for (parts.items) |p| alloc.free(p);
            parts.deinit(alloc);
        }
        if (self.skills) |reg| {
            const s = try reg.renderPromptSection(alloc);
            if (s.len > 0) try parts.append(alloc, s) else alloc.free(s);
        }
        if (self.goal_board.current()) |g| {
            const s = try std.fmt.allocPrint(alloc, "## Current goal [{s}]\n{s}", .{ g.status.asStr(), g.text });
            try parts.append(alloc, s);
        }
        {
            const s = try self.plan_board.renderPrompt(alloc);
            if (s.len > 0) try parts.append(alloc, s) else alloc.free(s);
        }
        if (self.working) |wm| {
            const s = try wm.snapshotPrompt(alloc);
            if (s.len > 0) try parts.append(alloc, s) else alloc.free(s);
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        for (parts.items, 0..) |p, i| {
            if (i > 0) try out.appendSlice(alloc, "\n\n");
            try out.appendSlice(alloc, p);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Serve a loop-native tool call; `null` = unknown name (the loop then
    /// falls back to the builtin executors).
    fn execTool(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, call: tool_builtin.ToolCall) anyerror!?tool_builtin.ToolResult {
        const self: *LoopExtensions = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, call.name, "plan_add") or std.mem.eql(u8, call.name, "plan_update"))
            return try self.planBoardTool(alloc, call);
        if (std.mem.eql(u8, call.name, "plan_set")) return try self.planSet(alloc, call);
        if (std.mem.eql(u8, call.name, "goal_set")) return try self.goalSet(alloc, call);
        if (std.mem.eql(u8, call.name, skill_mod.skill_use_name)) return try self.skillUse(alloc, call);
        if (std.mem.eql(u8, call.name, "memory_get")) return try self.memoryGet(alloc, call);
        if (std.mem.eql(u8, call.name, "memory_set")) return try self.memorySet(alloc, io, call);
        // ── swarm wave-2 tool surfaces ────────────────────────────────────
        if (std.mem.eql(u8, call.name, "spawn_agent")) {
            const r = try spawn_agent.execute(alloc, .{ .name = call.name, .arguments = call.arguments });
            // spawn_agent's ToolResult mirrors the builtin shape; re-tag it so
            // the loop's freeResult path owns the memory uniformly.
            return tool_builtin.ToolResult{ .success = r.success, .output = r.output, .err_msg = r.err_msg };
        }
        if (std.mem.eql(u8, call.name, "web_fetch") or std.mem.eql(u8, call.name, "web_search"))
            return try webfetch.execute(alloc, self.cwd, call);
        if (std.mem.startsWith(u8, call.name, "mcp_")) {
            const res = mcp_bridge.execute(alloc, call.name, call.arguments);
            return res;
        }
        if (self.plugins) |p| {
            if (try p.execute(alloc, call.name, call.arguments)) |out| {
                return .{
                    .success = out.ok,
                    .output = out.output,
                    .err_msg = if (out.ok) null else try alloc.dupe(u8, "plugin tool failed"),
                };
            }
        }
        if (self.wasm) |w| {
            if (try w.execute(alloc, call.name, call.arguments)) |out| {
                return .{
                    .success = out.ok,
                    .output = out.output,
                    .err_msg = if (out.ok) null else try alloc.dupe(u8, "wasm tool failed"),
                };
            }
        }
        return null;
    }

    fn ok(alloc: std.mem.Allocator, msg: []const u8) !tool_builtin.ToolResult {
        return .{ .success = true, .output = try alloc.dupe(u8, msg), .err_msg = null };
    }

    fn fail(alloc: std.mem.Allocator, msg: []const u8) !tool_builtin.ToolResult {
        return .{ .success = false, .output = try alloc.dupe(u8, ""), .err_msg = try alloc.dupe(u8, msg) };
    }

    /// plan_add / plan_update delegate to plan.zig's own dispatcher.
    fn planBoardTool(self: *LoopExtensions, alloc: std.mem.Allocator, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        const msg = plan_mod.executeTool(self.plan_board, call.name, call.arguments, alloc) catch |e| switch (e) {
            error.MissingArgument => return fail(alloc, "missing argument"),
            error.BadArgument => return fail(alloc, "bad argument (unknown task id or invalid status)"),
            error.UnknownTool => return fail(alloc, "unknown plan tool"),
            error.OutOfMemory => return error.OutOfMemory,
        };
        // msg is allocated with `alloc`; ToolResult.output has the same
        // ownership contract (freed via tool_builtin.freeResult).
        return .{ .success = true, .output = msg, .err_msg = null };
    }

    /// Replace the whole checklist from a line-based payload: one task per
    /// line, optional leading status marker `[x]` done, `[~]` in_progress,
    /// `[!]` blocked, `[ ]`/none pending.
    fn planSet(self: *LoopExtensions, alloc: std.mem.Allocator, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        var map = try tool_builtin.parseArgs(alloc, call.arguments);
        defer tool_builtin.freeArgs(alloc, &map);
        const tasks = map.get("tasks") orelse return fail(alloc, "missing tasks");

        const board_alloc = self.plan_board.alloc;
        self.plan_board.deinit();
        self.plan_board.* = plan_mod.PlanBoard.init(board_alloc);

        var added: usize = 0;
        var lines = std.mem.splitScalar(u8, tasks, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var status: plan_mod.TaskStatus = .pending;
            var text = line;
            if (std.mem.startsWith(u8, text, "[x]")) {
                status = .done;
                text = text[3..];
            } else if (std.mem.startsWith(u8, text, "[~]")) {
                status = .in_progress;
                text = text[3..];
            } else if (std.mem.startsWith(u8, text, "[!]")) {
                status = .blocked;
                text = text[3..];
            } else if (std.mem.startsWith(u8, text, "[ ]")) {
                text = text[3..];
            }
            text = std.mem.trim(u8, text, " \t");
            if (text.len == 0) continue;
            const id = try self.plan_board.addTask(text);
            _ = self.plan_board.updateStatus(id, status);
            added += 1;
        }
        const msg = try std.fmt.allocPrint(alloc, "plan replaced with {d} task(s)", .{added});
        return .{ .success = true, .output = msg, .err_msg = null };
    }

    fn goalSet(self: *LoopExtensions, alloc: std.mem.Allocator, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        var map = try tool_builtin.parseArgs(alloc, call.arguments);
        defer tool_builtin.freeArgs(alloc, &map);
        if (map.get("text")) |text| {
            if (text.len == 0) return fail(alloc, "goal text must not be empty");
            try self.goal_board.set(text);
            if (self.working) |wm| wm.set("goal", text) catch {};
            return ok(alloc, "goal set");
        }
        if (map.get("status")) |st| {
            const s = goalStatusFromStr(st) orelse
                return fail(alloc, "invalid status (active | achieved | abandoned)");
            if (!self.goal_board.updateStatus(s))
                return fail(alloc, "no active goal to transition");
            const msg = try std.fmt.allocPrint(alloc, "goal -> {s}", .{st});
            return .{ .success = true, .output = msg, .err_msg = null };
        }
        return fail(alloc, "goal_set requires 'text' or 'status'");
    }

    fn skillUse(self: *LoopExtensions, alloc: std.mem.Allocator, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        const reg = self.skills orelse return fail(alloc, "no skills are available in this session");
        var map = try tool_builtin.parseArgs(alloc, call.arguments);
        defer tool_builtin.freeArgs(alloc, &map);
        const name = map.get("name") orelse return fail(alloc, "missing name");
        const body = (try reg.getBody(alloc, name)) orelse {
            const msg = try std.fmt.allocPrint(alloc, "unknown skill '{s}' (see Available skills)", .{name});
            defer alloc.free(msg);
            return fail(alloc, msg);
        };
        // body is allocated with `alloc` — same ownership as ToolResult.output.
        return .{ .success = true, .output = body, .err_msg = null };
    }

    fn memoryGet(self: *LoopExtensions, alloc: std.mem.Allocator, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        const store = self.memory orelse return fail(alloc, "persistent memory is not available");
        var map = try tool_builtin.parseArgs(alloc, call.arguments);
        defer tool_builtin.freeArgs(alloc, &map);
        const key = map.get("key") orelse return fail(alloc, "missing key");
        const value = (try store.get(alloc, key)) orelse {
            const msg = try std.fmt.allocPrint(alloc, "(no value stored for '{s}')", .{key});
            defer alloc.free(msg);
            return ok(alloc, msg);
        };
        return .{ .success = true, .output = value, .err_msg = null };
    }

    fn memorySet(self: *LoopExtensions, alloc: std.mem.Allocator, io: std.Io, call: tool_builtin.ToolCall) !tool_builtin.ToolResult {
        const store = self.memory orelse return fail(alloc, "persistent memory is not available");
        var map = try tool_builtin.parseArgs(alloc, call.arguments);
        defer tool_builtin.freeArgs(alloc, &map);
        const key = map.get("key") orelse return fail(alloc, "missing key");
        const value = map.get("value") orelse return fail(alloc, "missing value");
        store.put(io, key, value) catch |e| switch (e) {
            error.InvalidKey => return fail(alloc, "invalid key (use [A-Za-z0-9_.-], max 128 chars)"),
            error.ValueTooLarge => return fail(alloc, "value too large"),
            else => return fail(alloc, @errorName(e)),
        };
        const msg = try std.fmt.allocPrint(alloc, "saved '{s}'", .{key});
        defer alloc.free(msg);
        return ok(alloc, msg);
    }
};

fn goalStatusFromStr(s: []const u8) ?goal_mod.Status {
    if (std.mem.eql(u8, s, "active")) return .active;
    if (std.mem.eql(u8, s, "achieved")) return .achieved;
    if (std.mem.eql(u8, s, "abandoned")) return .abandoned;
    return null;
}

/// Register the loop-native tools so the model sees their schemas. Executors
/// live in LoopExtensions.execTool; the names are intercepted by the agent
/// loop before builtin dispatch. skill_use is offered only when skills were
/// discovered; memory_* only when the persistent store is available.
pub fn registerExtensionTools(reg: *tool_reg.ToolRegistry, opts: struct { skills: bool, memory: bool }) !void {
    try reg.register(.{
        .name = plan_mod.TOOL_SCHEMAS[0].name,
        .description = "Add a task to your plan checklist. Use for multi-step work so progress stays visible across turns.",
        .category = .general,
        .parameters_json = plan_mod.TOOL_SCHEMAS[0].parameters_json,
    });
    try reg.register(.{
        .name = plan_mod.TOOL_SCHEMAS[1].name,
        .description = "Update a plan task's status (and optionally attach a progress note).",
        .category = .general,
        .parameters_json = plan_mod.TOOL_SCHEMAS[1].parameters_json,
    });
    try reg.register(.{
        .name = "plan_set",
        .description = "Replace the whole plan checklist. One task per line; optional leading status marker: [x] done, [~] in_progress, [!] blocked, [ ] pending.",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"tasks":{"type":"string","description":"Full plan, one task per line with optional [x]/[~]/[!]/[ ] markers"}},"required":["tasks"]}
        ,
    });
    try reg.register(.{
        .name = "goal_set",
        .description = "Set or update the current high-level goal. Provide 'text' to set/replace it, or 'status' (active|achieved|abandoned) to transition it.",
        .category = .general,
        .parameters_json =
        \\{"type":"object","properties":{"text":{"type":"string","description":"The goal to pursue"},"status":{"type":"string","enum":["active","achieved","abandoned"],"description":"Transition the current goal instead of setting a new one"}},"required":[]}
        ,
    });
    if (opts.skills) {
        try reg.register(.{
            .name = skill_mod.skill_use_name,
            .description = "Load a skill's full instructions into context by name. See 'Available skills' in your prompt for the index.",
            .category = .general,
            .parameters_json = skill_mod.skill_use_parameters_json,
        });
    }
    if (opts.memory) {
        try reg.register(.{
            .name = "memory_get",
            .description = "Read a durable fact that survives restarts (stored under ~/.zharness/memory). Returns '(no value stored ...)' for unset keys.",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{"key":{"type":"string","description":"Memory key ([A-Za-z0-9_.-])"}},"required":["key"]}
            ,
        });
        try reg.register(.{
            .name = "memory_set",
            .description = "Persist a durable fact (max 64KB) that future sessions can read back via memory_get.",
            .category = .general,
            .parameters_json =
            \\{"type":"object","properties":{"key":{"type":"string","description":"Memory key ([A-Za-z0-9_.-])"},"value":{"type":"string","description":"Value to store"}},"required":["key","value"]}
            ,
        });
    }
}

// ── serve (dev.md §XXIII): HTTP API over the agent loop ─────────────────────

/// Shared state for the HTTP dependency callbacks.
const ServeState = struct {
    alloc: std.mem.Allocator,
    cfg: *config.Config,
    opts: LoopOpts,
};

fn serveRunTask(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    prompt: []const u8,
    session_id: ?[]const u8,
) anyerror![]const u8 {
    const st: *ServeState = @ptrCast(@alignCast(@constCast(ctx.?)));
    // Run on the server's long-lived allocator, then re-home the answer into
    // the request arena the API layer frees from.
    const answer = try agentRunOnce(st.alloc, st.cfg, st.opts, prompt, session_id);
    defer st.alloc.free(answer);
    return try alloc.dupe(u8, answer);
}

fn serveListSessions(ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]api.ServerDeps.SessionSummary {
    const st: *ServeState = @ptrCast(@alignCast(@constCast(ctx.?)));
    const io = g_io.?;
    var out: std.ArrayList(api.ServerDeps.SessionSummary) = .empty;
    errdefer out.deinit(alloc);
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.zharness/sessions", .{st.cfg.cwd});
    defer alloc.free(dir_path);
    const cwd = std.Io.Dir.cwd();
    const dir = std.Io.Dir.openDir(cwd, io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return out.toOwnedSlice(alloc),
        else => return e,
    };
    defer std.Io.Dir.close(dir, io);
    // Directory iteration proved flaky for checkpoint listing; here a single
    // pass is best-effort anyway — failures yield an empty list.
    var it = std.Io.Dir.iterate(dir);
    while (it.next(io) catch null) |entry| {
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        if (std.mem.eql(u8, name, "index.json")) continue;
        const id = name[0 .. name.len - 5];
        // Message count comes from loading the transcript; skip unloadable.
        var detail = (try serveGetSession(ctx, alloc, id)) orelse continue;
        const summary = api.ServerDeps.SessionSummary{
            .id = try alloc.dupe(u8, id),
            .created_at = detail.created_at,
            .message_count = detail.messages.len,
        };
        detail.deinit(alloc);
        try out.append(alloc, summary);
    }
    return out.toOwnedSlice(alloc);
}

fn serveGetSession(
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    id: []const u8,
) anyerror!?api.ServerDeps.SessionDetail {
    const st: *ServeState = @ptrCast(@alignCast(@constCast(ctx.?)));
    const io = g_io.?;
    const p = try std.fmt.allocPrint(
        alloc,
        "{s}/.zharness/sessions/{s}.json",
        .{ st.cfg.cwd, id },
    );
    defer alloc.free(p);
    const s = try alloc.create(session.Session);
    defer {
        s.deinit();
        alloc.destroy(s);
    }
    s.* = try session.Session.init(alloc, id);
    s.load(io, p) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    var msgs = try alloc.alloc(api.ServerDeps.MessageEntry, s.messages.items.len);
    for (s.messages.items, 0..) |m, i| {
        msgs[i] = .{
            .role = try alloc.dupe(u8, @tagName(m.role)),
            .content = try alloc.dupe(u8, m.content),
        };
    }
    // created_at: file mtime (best-effort — 0 when stat is unavailable).
    const created_at: i64 = blk: {
        const cwd = std.Io.Dir.cwd();
        const fstat = std.Io.Dir.statFile(cwd, io, p, .{}) catch break :blk 0;
        // Stat.mtime is an Io.Timestamp; its nanoseconds count real time.
        break :blk @intCast(@divTrunc(fstat.mtime.nanoseconds, std.time.ns_per_s));
    };
    return .{ .id = try alloc.dupe(u8, id), .created_at = created_at, .messages = msgs };
}

fn cmdServe(alloc: std.mem.Allocator, cfg: *config.Config, opts: LoopOpts, port_arg: ?[]const u8) !void {
    var port: u16 = 3080;
    if (port_arg) |pa| {
        port = std.fmt.parseInt(u16, pa, 10) catch {
            std.debug.print("error: invalid port '{s}'\n", .{pa});
            std.process.exit(1);
        };
    }

    // A long-lived Io for the accept loop + per-request runs.
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    g_io = io;

    const st = try alloc.create(ServeState);
    defer alloc.destroy(st);
    st.* = .{ .alloc = alloc, .cfg = cfg, .opts = opts };

    // api.handle casts its ctx straight to *ServerDeps — the state pointer
    // rides inside deps.ctx.
    const deps = try alloc.create(api.ServerDeps);
    defer alloc.destroy(deps);
    deps.* = .{
        .ctx = st,
        .runTask = serveRunTask,
        .listSessions = serveListSessions,
        .getSession = serveGetSession,
    };

    // Live event feed (dev.md §XXX): agent-loop envelopes fan out to every
    // /events subscriber. Install BEFORE the accept loop starts; obs.fanout
    // is a plain var so it must be set before any thread observes it.
    try server_events.install(alloc);
    obs_mod.fanout = &server_events.hubPublish;

    // Static Web UI (Option B from docs/web.md): static.handle claims "/" and
    // "/assets/*", everything else falls through to the JSON API.
    const static_ctx = try alloc.create(server_static.Ctx);
    defer alloc.destroy(static_ctx);
    static_ctx.* = .{ .root = server_static.default_root, .fallback = .{ .ctx = deps, .call = api.handle } };

    var server = try httpd.Server.init(alloc, .{
        .ctx = static_ctx,
        .call = server_static.handle,
        // Live SSE subscribers need per-connection threads or one open
        // /events stream starves every other route on the accept thread.
    }, .{ .port = port, .threaded_connections = true });
    defer server.deinit();
    defer {
        obs_mod.fanout = null;
        server_events.deinstall();
    }

    std.debug.print(
        \\zharness serve listening on http://127.0.0.1:{d}
        \\  Web UI:      http://127.0.0.1:{d}/          (web/ directory)
        \\  POST /run {{prompt, session?}}   POST /chat (same shape)
        \\  GET  /sessions  GET /sessions/<id>  GET /healthz  GET /events (live)
        \\Ctrl-C to stop.
        \\
    , .{ port, port });
    server.serveBlocking(); // never returns under normal operation
}

// ── workflow (dev.md §XIX): JSON-defined multi-step agent runs ──────────────

const WfRunState = struct {
    alloc: std.mem.Allocator,
    cfg: *config.Config,
};

/// Step runner: one agent task per workflow step. Dependency artifacts are
/// appended to the step prompt so later steps see earlier results.
fn wfStepRunner(
    alloc: std.mem.Allocator,
    io: std.Io,
    step_prompt: []const u8,
    ctx: *const wf_exec.StepContext,
) anyerror![]u8 {
    _ = io;
    const st: *WfRunState = @ptrCast(@alignCast(ctx.user.?));

    var prompt_buf: std.ArrayList(u8) = .empty;
    defer prompt_buf.deinit(alloc);
    try prompt_buf.appendSlice(alloc, step_prompt);

    // Inline dependency artifacts so the step has full local context.
    var first = true;
    for (ctx.artifacts.items.items) |*a| {
        if (first) {
            try prompt_buf.appendSlice(alloc, "\n\n--- Prior step results ---");
            first = false;
        }
        try prompt_buf.appendSlice(alloc, "\n[step ");
        try prompt_buf.appendSlice(alloc, a.id);
        try prompt_buf.appendSlice(alloc, "]\n");
        try prompt_buf.appendSlice(alloc, a.result);
    }

    const opts = LoopOpts{};
    if (ctx.max_turns) |mt| {
        // Per-step turn budget rides through a config copy.
        st.cfg.max_turns = mt;
    }
    const answer = try agentRunOnce(st.alloc, st.cfg, opts, prompt_buf.items, null);
    // Re-home into the executor's expected allocator (`alloc` here is the
    // caller-provided one; agentRunOnce used the state's allocator).
    defer st.alloc.free(answer);
    // An empty answer means the underlying turn produced nothing usable
    // (e.g. every model request failed). Surface that as a failed step so
    // the executor's failure policy engages instead of reporting success.
    if (std.mem.trim(u8, answer, " \t\r\n").len == 0) return error.EmptyStepOutput;
    return try alloc.dupe(u8, answer);
}

fn cmdWorkflow(alloc: std.mem.Allocator, cfg: *config.Config, path: []const u8) !void {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    g_io = io;

    const raw = std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(4 * 1024 * 1024)) catch |e| {
        std.debug.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        std.process.exit(1);
    };
    defer alloc.free(raw);

    var wf = wf_mod.Workflow.parseValidated(alloc, raw) catch |e| {
        if (e == error.CyclicDependency) {
            std.debug.print("error: workflow has a dependency cycle\n", .{});
        } else {
            std.debug.print("error: invalid workflow '{s}': {s}\n", .{ path, @errorName(e) });
        }
        std.process.exit(1);
    };
    defer wf.deinit(alloc);

    const st = try alloc.create(WfRunState);
    defer alloc.destroy(st);
    st.* = .{ .alloc = alloc, .cfg = cfg };

    var ex = wf_exec.Executor.init(alloc, wfStepRunner);
    ex.user = st;
    ex.stop_on_first_failure = true;

    std.debug.print("workflow '{s}': {d} step(s)\n", .{ wf.name, wf.steps.len });
    var outcome = try ex.run(io, &wf);
    defer outcome.deinit(alloc);

    // Atomic run report next to the session state.
    const report_path = try std.fmt.allocPrint(alloc, "{s}/.zharness/runs/{s}.json", .{ cfg.cwd, wf.name });
    defer alloc.free(report_path);
    if (std.fs.path.dirname(report_path)) |d| {
        // best-effort mkdir via Io layer happens inside generate; pre-create:
        std.Io.Dir.createDirPath(.cwd(), io, d) catch {};
    }
    wf_report.generate(alloc, io, report_path, &wf, &outcome) catch |e| {
        std.debug.print("[workflow] report not written: {s}\n", .{@errorName(e)});
    };

    switch (outcome.status) {
        .completed => std.debug.print("workflow completed — report: {s}\n", .{report_path}),
        .failed => {
            std.debug.print(
                "workflow FAILED at step '{s}' ({s}) — partial report: {s}\n",
                .{ outcome.failed_step orelse "?", outcome.err orelse "?", report_path },
            );
            std.process.exit(1);
        },
    }
}

// ── plugin CLI (dev.md §XXV): list / exec against native dylib tools ────────

fn cmdPluginList(alloc: std.mem.Allocator, dir_override: ?[]const u8) !void {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var reg = plugin_loader.PluginRegistry.init(alloc);
    defer reg.deinit();
    if (dir_override) |d| {
        const n = reg.loadDir(io, d);
        if (n == 0) std.debug.print("[plugin] no loadable plugins in {s}\n", .{d});
    } else {
        reg.loadDefaultDirs(io, ".");
    }

    if (reg.tools.items.len == 0 and reg.report.items.len == 0) {
        std.debug.print("no plugins found (~/.zharness/plugins, ./plugins)\n", .{});
        return;
    }
    for (reg.tools.items) |t| {
        std.debug.print("{s}\n  {s}\n", .{ t.host_name, t.description });
    }
    for (reg.report.items) |r| {
        std.debug.print("skipped {s}: {s}\n", .{ r.path, r.reason });
    }
}

fn cmdPluginExec(alloc: std.mem.Allocator, name: []const u8, args_json: []const u8, dir_override: ?[]const u8) !void {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var reg = plugin_loader.PluginRegistry.init(alloc);
    defer reg.deinit();
    if (dir_override) |d| {
        _ = reg.loadDir(io, d);
    } else {
        reg.loadDefaultDirs(io, ".");
    }

    const outcome = (try reg.execute(alloc, name, args_json)) orelse {
        std.debug.print("error: no plugin tool named '{s}'\n", .{name});
        std.process.exit(1);
    };
    defer alloc.free(outcome.output);
    std.debug.print("{s}\n", .{outcome.output});
    if (!outcome.ok) std.process.exit(1);
}

fn printUsage() void {
    std.debug.print(
        \\zharness - a native coding-agent harness
        \\
        \\Usage:
        \\  zharness run "prompt"          Run a single agent task
        \\  zharness chat                  Start an interactive REPL
        \\  zharness serve [--port N]      HTTP API (default port 3080)
        \\  zharness workflow <file.json>  Run a step workflow through the agent
        \\  zharness plugin list [--dir X] List native plugin tools
        \\  zharness plugin exec <name> '<json>'  Invoke a plugin tool directly
        \\  zharness --help                Show this help
        \\
        \\Flags (run/chat):
        \\  --model X        Override the model
        \\  --provider Y     deepseek | openai-compat | anthropic | ollama
        \\  --no-stream      Disable streaming
        \\  --session ID     Resume/save a named session (.zharness/sessions/)
        \\  --preset NAME    standard | minimal | ptc | creative
        \\  --sandbox MODE   off | process (shell policy + env allowlist)
        \\  --mcp "CMD"      Attach an MCP stdio server (repeatable, max 4;
        \\                   split on spaces — no quote handling)
        \\
        \\Wired subsystems:
        \\  skills           <workspace>/skills + ~/.zharness/skills (SKILL.md)
        \\  memory           ~/.zharness/memory (memory_get / memory_set tools)
        \\  checkpoints      .zharness/checkpoints (saved per turn + tool batch)
        \\  observability    .zharness/logs/events.jsonl (trace/span envelopes)
        \\  plugins          ~/.zharness/plugins + <workspace>/plugins (dylib ABI v1)
        \\
    , .{});
}

/// Everything buildLoop creates, with the exact teardown order in deinitBuilt.
pub const Built = struct {
    ctx: *cordis.Context,
    tools: *tool_reg.ToolRegistry,
    loop: *agent.AgentLoop,
    ag: *agent.Agent,
    acfg: *agent.AgentConfig,
    checkpoints: *checkpoint.CheckpointStore,
    lext: *LoopExtensions,
    ext_iface: *agent.Extensions,
    skills: ?*skill_mod.SkillRegistry,
    memory: ?*mem_persistent.PersistentStore,
    working: *mem_working.WorkingMemory,
    plan_board: *plan_mod.PlanBoard,
    goal_board: *goal_mod.GoalBoard,
    /// Heap copy of the chat client used by spawn_agent children (the loop
    /// holds its own by-value copy, so children need a stable one).
    spawn_client: ?*model.ChatClient = null,
    spawn_env: ?*spawn_agent.SpawnEnv = null,
    spawn_deps: ?*spawn_agent.SpawnDeps = null,
    /// Live MCP stdio clients (one per --mcp server), torn down last.
    mcp_clients: []*mcp_mod.McpClient = &.{},
    plugins: ?*plugin_loader.PluginRegistry = null,
    wasm: ?*wasm_loader.WasmRegistry = null,

    /// Tear everything down in strict reverse-creation order (the previous
    /// inline defer chain destroyed heap objects before deinitializing them).
    pub fn deinit(self: *Built, alloc: std.mem.Allocator) void {
        // Sub-agent wiring first: nothing may reach into these once the loop
        // is gone.
        if (self.spawn_deps) |d| {
            // d.deps.tools points at Built.tools — owned and freed there.
            alloc.destroy(d);
        }
        if (self.spawn_env) |e| alloc.destroy(e);
        if (self.spawn_client) |c| {
            c.* = undefined; // client has no deinit (plain value type)
            alloc.destroy(c);
        }
        spawn_agent.clearSpawnCtx();
        for (self.mcp_clients) |c| {
            c.deinit();
            alloc.destroy(c);
        }
        if (self.mcp_clients.len > 0) alloc.free(self.mcp_clients);
        mcp_bridge.clearInstances();
        if (self.wasm) |w| {
            w.deinit();
            alloc.destroy(w);
        }
        if (self.plugins) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        self.loop.deinit();
        alloc.destroy(self.loop);
        self.ag.deinit(alloc);
        // Preset mode heap-allocates the composed system prompt (base +
        // fragment); the default path points at the static literal and must
        // not be freed.
        if (self.acfg.system_prompt.ptr != SYSTEM_PROMPT.ptr) alloc.free(self.acfg.system_prompt);
        self.tools.deinit();
        alloc.destroy(self.tools);
        alloc.destroy(self.acfg);
        alloc.destroy(self.ext_iface);
        alloc.destroy(self.lext);
        self.working.deinit();
        alloc.destroy(self.working);
        self.goal_board.deinit();
        alloc.destroy(self.goal_board);
        self.plan_board.deinit();
        alloc.destroy(self.plan_board);
        if (self.memory) |m| {
            m.deinit();
            alloc.destroy(m);
        }
        if (self.skills) |s| {
            s.deinit();
            alloc.destroy(s);
        }
        self.checkpoints.deinit();
        alloc.destroy(self.checkpoints);
        self.ctx.deinit();
    }
};

/// Per-invocation loop options that do not belong in Config (they come from
/// CLI flags and are not persisted).
pub const LoopOpts = struct {
    /// MCP stdio servers: each entry is a raw command line, split on spaces.
    mcp_cmds: []const []const u8 = &.{},
    preset: ?presets_mod.Kind = null,
};

fn buildLoop(alloc: std.mem.Allocator, cfg: *config.Config, opts: LoopOpts) !Built {
    var ctx = try cordis.Context.init(alloc);
    errdefer ctx.deinit();

    const tools = try alloc.create(tool_reg.ToolRegistry);
    errdefer alloc.destroy(tools);
    tools.* = try tool_reg.ToolRegistry.init(alloc);
    errdefer tools.deinit();
    try tool_reg.registerBuiltins(tools);

    // ── skills: workspace `skills/` first, then ~/.zharness/skills ────────
    var skills_reg: ?*skill_mod.SkillRegistry = null;
    errdefer if (skills_reg) |s| {
        s.deinit();
        alloc.destroy(s);
    };
    {
        // From the moment of the create below, `skills_reg` is the single
        // owner of reg — every later failure unwinds through the errdefer.
        const reg = try alloc.create(skill_mod.SkillRegistry);
        skills_reg = reg;
        reg.* = skill_mod.SkillRegistry.init(alloc);
        const ws_root = try std.fmt.allocPrint(alloc, "{s}/skills", .{cfg.cwd});
        defer alloc.free(ws_root);
        if (homeDir()) |h| {
            const home_root = try std.fmt.allocPrint(alloc, "{s}/.zharness/skills", .{h});
            defer alloc.free(home_root);
            const roots = [_][]const u8{ ws_root, home_root };
            // Discovery is best-effort: unreadable roots yield nothing.
            _ = skill_loader.loadAll(alloc, ctx.io(), &roots, reg) catch {};
        } else {
            const roots = [_][]const u8{ws_root};
            _ = skill_loader.loadAll(alloc, ctx.io(), &roots, reg) catch {};
        }
        if (reg.count() == 0) {
            skills_reg = null;
            reg.deinit();
            alloc.destroy(reg);
        }
    }

    // ── persistent memory at ~/.zharness/memory ───────────────────────────
    var memory_store: ?*mem_persistent.PersistentStore = null;
    errdefer if (memory_store) |m| {
        m.deinit();
        alloc.destroy(m);
    };
    {
        if (homeDir()) |home| {
            const dir = try std.fmt.allocPrint(alloc, "{s}/.zharness/memory", .{home});
            defer alloc.free(dir);
            const st = try alloc.create(mem_persistent.PersistentStore);
            errdefer alloc.destroy(st);
            st.* = try mem_persistent.PersistentStore.init(alloc, dir);
            // Single owner from here: the outer errdefer / teardown path.
            memory_store = st;
            // Absent/corrupt backing files are tolerated by open; real IO
            // errors degrade to "no memory" instead of failing startup.
            st.open(ctx.io()) catch {
                memory_store = null;
                st.deinit();
                alloc.destroy(st);
            };
        }
    }

    // ── plan / goal / working-memory boards ────────────────────────────────
    const working = try alloc.create(mem_working.WorkingMemory);
    errdefer alloc.destroy(working);
    working.* = mem_working.WorkingMemory.init(alloc);
    errdefer working.deinit();

    const plan_board = try alloc.create(plan_mod.PlanBoard);
    errdefer alloc.destroy(plan_board);
    plan_board.* = plan_mod.PlanBoard.init(alloc);
    errdefer plan_board.deinit();

    const goal_board = try alloc.create(goal_mod.GoalBoard);
    errdefer alloc.destroy(goal_board);
    goal_board.* = goal_mod.GoalBoard.init(alloc);
    errdefer goal_board.deinit();

    // Native plugin registry slot — declared before lext (which borrows it);
    // discovery + registration happen further down, after tool schemas.
    var plugins_reg: ?*plugin_loader.PluginRegistry = null;
    // WASM registry slot — same early-declaration pattern.
    var wasm_reg: ?*wasm_loader.WasmRegistry = null;
    errdefer if (plugins_reg) |p| {
        p.deinit();
        alloc.destroy(p);
    };

    // Extension state + vtable instance (both must outlive the loop).
    const lext = try alloc.create(LoopExtensions);
    errdefer alloc.destroy(lext);
    lext.* = .{
        .alloc = alloc,
        .io = ctx.io(),
        .skills = skills_reg,
        .memory = memory_store,
        .working = working,
        .plan_board = plan_board,
        .goal_board = goal_board,
        .plugins = plugins_reg,
        .wasm = wasm_reg,
        .cwd = cfg.cwd,
    };
    const ext_iface = try alloc.create(agent.Extensions);
    errdefer alloc.destroy(ext_iface);
    ext_iface.* = lext.extensions();

    // Loop-native tool schemas (after builtin registration). The executors
    // are reached through AgentLoop.dispatchTool → ext.executeTool.
    try registerExtensionTools(tools, .{
        .skills = skills_reg != null,
        .memory = memory_store != null,
    });

    // ── web tools (dev.md §XI): web_fetch / web_search ────────────────────
    try webfetch.registerWebTools(tools);

    // spawn_agent (dev.md §XVIII) — schema registered now; the executor slot
    // is wired right after the chat client exists below.
    try tools.register(spawn_agent.definition);

    // ── native plugins (dev.md §XXV–XXVI): best-effort discovery ──────────
    {
        const p = try alloc.create(plugin_loader.PluginRegistry);
        p.* = plugin_loader.PluginRegistry.init(alloc);
        p.loadDefaultDirs(ctx.io(), cfg.cwd);
        if (p.tools.items.len > 0) {
            const defs = try p.definitions(alloc);
            defer alloc.free(defs);
            for (defs) |d| try tools.register(d);
            for (p.report.items) |r| {
                std.debug.print("[plugin] skipped {s}: {s}\n", .{ r.path, r.reason });
            }
            plugins_reg = p;
        } else {
            p.deinit();
            alloc.destroy(p);
        }
    }

    // ── WASM plugins (dev.md §XII L2): best-effort discovery ──────────────
    errdefer if (wasm_reg) |w| {
        w.deinit();
        alloc.destroy(w);
    };
    {
        const w = try alloc.create(wasm_loader.WasmRegistry);
        w.* = wasm_loader.WasmRegistry.init(alloc);
        w.loadDefaultDirs(ctx.io(), cfg.cwd);
        if (w.tools.items.len > 0) {
            const defs = try w.definitions(alloc);
            defer alloc.free(defs);
            for (defs) |d| try tools.register(d);
            for (w.report.items) |r| {
                std.debug.print("[wasm] skipped {s}: {s}\n", .{ r.path, r.reason });
            }
            wasm_reg = w;
        } else {
            w.deinit();
            alloc.destroy(w);
        }
    }

    // ── MCP stdio servers via --mcp "<command>" (dev.md §XX) ───────────────
    var mcp_clients: []*mcp_mod.McpClient = &.{};
    errdefer {
        for (mcp_clients) |c| {
            c.deinit();
            alloc.destroy(c);
        }
        if (mcp_clients.len > 0) alloc.free(mcp_clients);
        mcp_bridge.clearInstances();
    }
    if (opts.mcp_cmds.len > 0) {
        const clients = try alloc.alloc(*mcp_mod.McpClient, opts.mcp_cmds.len);
        mcp_clients = clients;
        var n: usize = 0;
        for (opts.mcp_cmds, 0..) |cmd, idx| {
            const argv = splitCommand(alloc, cmd) catch continue;
            defer alloc.free(argv);
            if (argv.len == 0) continue;
            const label = std.fmt.allocPrint(alloc, "mcp{d}", .{idx}) catch continue;
            defer alloc.free(label);
            const box = try alloc.create(mcp_mod.McpClient);
            box.* = mcp_mod.McpClient.spawnChild(alloc, ctx.io(), argv) catch |e| {
                std.debug.print("[mcp] {s} ({s}): spawn failed: {s}\n", .{ label, cmd, @errorName(e) });
                alloc.destroy(box);
                continue;
            };
            _ = box.initialize() catch |e| {
                std.debug.print("[mcp] {s} ({s}): initialize failed: {s}\n", .{ label, cmd, @errorName(e) });
                box.deinit();
                alloc.destroy(box);
                continue;
            };
            const registered = mcp_bridge.registerServerTools(alloc, tools, label, box) catch |e| blk: {
                std.debug.print("[mcp] {s} ({s}): tool listing failed: {s}\n", .{ label, cmd, @errorName(e) });
                break :blk 0;
            };
            if (registered > 0) {
                std.debug.print("[mcp] {s} ({s}): registered {d} remote tool(s)\n", .{ label, cmd, registered });
                clients[n] = box;
                n += 1;
            } else {
                box.deinit();
                alloc.destroy(box);
            }
        }
        // Exact-length shrink so Built's later free() matches the allocation.
        if (n == clients.len) {
            // already exact
        } else if (alloc.resize(clients, n)) {
            mcp_clients = clients[0..n];
        } else if (n == 0) {
            alloc.free(clients);
            mcp_clients = &.{};
        } else {
            const shrunk = try alloc.alloc(*mcp_mod.McpClient, n);
            @memcpy(shrunk, clients[0..n]);
            alloc.free(clients);
            mcp_clients = shrunk;
        }
    }

    // ── preset filtering (dev.md §XXVIII): narrow the core builtin surface.
    // Extension/web/mcp/plugin/subagent capabilities stay available; presets
    // constrain the classic coding-toolset only.
    if (opts.preset) |kind| {
        const spec = presets_mod.spec(kind);
        const names = try tools.list();
        defer alloc.free(names);
        for (names) |name| {
            if (!builtinAllowedByPreset(spec.tools, name)) _ = tools.remove(name);
        }
        std.debug.print("[preset] {s}: {d} builtin tool(s) allowed\n", .{ spec.name, spec.tools.len });
    }

    // ── checkpoints: <cwd>/.zharness/checkpoints (main-owned store) ───────
    const cp_dir = try std.fmt.allocPrint(alloc, "{s}/.zharness/checkpoints", .{cfg.cwd});
    defer alloc.free(cp_dir);
    const checkpoints = try alloc.create(checkpoint.CheckpointStore);
    errdefer alloc.destroy(checkpoints);
    checkpoints.* = try checkpoint.CheckpointStore.init(alloc, cp_dir);
    errdefer checkpoints.deinit();

    // Streamed deltas print live; wire the sink before the client value is
    // copied into the agent loop. Provider profiles (deepseek/openai-compat/
    // anthropic/ollama — dev.md §VI) select auth style + wire format here.
    var client = if (cfg.resolvedProfile()) |prof|
        model.ChatClient.initProvider(alloc, ctx.io(), prof, cfg.model, cfg.api_key)
    else
        model.ChatClient.init(alloc, ctx.io(), cfg.endpoint, cfg.model, cfg.api_key);
    client.stream_sink = onStreamDelta;

    // spawn_agent wiring (dev.md §XVIII): a heap copy of the client (the loop
    // holds its own by-value copy), plus env + deps thunks. Sub-agents are
    // NOT allowed to spawn further agents — allowed_tools excludes it.
    const spawn_client = try alloc.create(model.ChatClient);
    errdefer alloc.destroy(spawn_client);
    spawn_client.* = if (cfg.resolvedProfile()) |prof|
        model.ChatClient.initProvider(alloc, ctx.io(), prof, cfg.model, cfg.api_key)
    else
        model.ChatClient.init(alloc, ctx.io(), cfg.endpoint, cfg.model, cfg.api_key);

    const spawn_env = try alloc.create(spawn_agent.SpawnEnv);
    errdefer alloc.destroy(spawn_env);
    spawn_env.* = .{
        .client = spawn_client,
        .io = ctx.io(),
        .cwd = cfg.cwd,
        .sandbox_mode = cfg.sandbox_mode,
    };

    const spawn_deps = try alloc.create(spawn_agent.SpawnDeps);
    errdefer alloc.destroy(spawn_deps);
    spawn_deps.* = .{
        .deps = .{
            .alloc = alloc,
            .ctx = spawn_env,
            .chat_fn = spawn_agent.chatThunk,
            .exec_fn = spawn_agent.execThunk,
            // Children share the parent's tool surface minus spawn_agent
            // itself (the execThunk guard enforces that at runtime).
            .tools = tools,
        },
    };
    spawn_agent.setSpawnCtx(spawn_deps);
    errdefer spawn_agent.clearSpawnCtx();

    // Heap-allocate the config so the pointer `Agent` holds stays valid after
    // buildLoop returns (a stack-local would dangle and corrupt system_prompt).
    // A preset (dev.md §XXVIII) appends its prompt fragment and supplies the
    // default turn budget when config did not set one.
    var system_prompt: []const u8 = SYSTEM_PROMPT;
    var max_turns = cfg.max_turns;
    if (opts.preset) |kind| {
        const spec = presets_mod.spec(kind);
        system_prompt = try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ SYSTEM_PROMPT, spec.system_prompt_fragment });
        if (cfg.max_turns == 0) max_turns = spec.default_max_turns;
    }
    errdefer if (system_prompt.ptr != SYSTEM_PROMPT.ptr) alloc.free(system_prompt);

    const acfg = try alloc.create(agent.AgentConfig);
    errdefer alloc.destroy(acfg);
    acfg.* = .{
        .system_prompt = system_prompt,
        .max_turns = max_turns,
        .reasoning_effort = cfg.reasoning_effort,
        .stream = cfg.stream,
        .sandbox_mode = cfg.sandbox_mode,
    };
    const ag = try agent.Agent.init(alloc, ctx.root, acfg);

    const loop = try alloc.create(agent.AgentLoop);
    errdefer alloc.destroy(loop);
    loop.* = try agent.AgentLoop.init(alloc, ctx, ag, client, tools, cfg.cwd, onEvent, checkpoints, ext_iface);

    return .{
        .ctx = ctx,
        .tools = tools,
        .loop = loop,
        .ag = ag,
        .acfg = acfg,
        .checkpoints = checkpoints,
        .lext = lext,
        .ext_iface = ext_iface,
        .skills = skills_reg,
        .memory = memory_store,
        .working = working,
        .plan_board = plan_board,
        .goal_board = goal_board,
        .spawn_client = spawn_client,
        .spawn_env = spawn_env,
        .spawn_deps = spawn_deps,
        .mcp_clients = mcp_clients,
        .plugins = plugins_reg,
        .wasm = wasm_reg,
    };
}

/// Run one agent task end-to-end and return the final answer (caller frees).
/// Shared by `run`, the workflow step runner, and the HTTP server. When
/// `session_id` is given the prior transcript is seeded first and the merged
/// transcript is persisted after the run (dev.md §XV).
fn agentRunOnce(
    alloc: std.mem.Allocator,
    cfg: *config.Config,
    opts: LoopOpts,
    prompt: []const u8,
    session_id: ?[]const u8,
) ![]const u8 {
    var built = try buildLoop(alloc, cfg, opts);
    defer built.deinit(alloc);
    const io = built.ctx.io();

    // Task scratchpad: the current prompt is visible in context sections.
    if (built.lext.working) |wm| wm.set("task", prompt) catch {};

    // Observability for this run (dev.md §XXX): JSONL envelopes land in
    // .zharness/logs/events.jsonl; failures never break the turn.
    obsBegin(alloc, io, session_id orelse "adhoc");
    defer obsEnd(alloc);

    // Optional named session: load any prior transcript and seed the loop so
    // the run continues the conversation.
    var session_ptr: ?*session.Session = null;
    var session_path: ?[]u8 = null;
    if (session_id) |sid| {
        const dir = try std.fs.path.join(alloc, &.{ cfg.cwd, ".zharness", "sessions" });
        std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, sid });
        alloc.free(dir);
        session_path = p;
        const s = try alloc.create(session.Session);
        errdefer alloc.destroy(s);
        s.* = try session.Session.init(alloc, sid);
        errdefer s.deinit();
        s.load(io, p) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        for (s.messages.items) |m| try built.loop.seed(alloc, m);
        session_ptr = s;
    }
    defer if (session_ptr) |s| {
        s.deinit();
        alloc.destroy(s);
    };
    defer if (session_path) |p| alloc.free(p);

    const answer = try built.loop.run(prompt);

    if (session_ptr) |s| {
        try built.loop.syncToSession(s);
        try s.save(io, session_path.?);
    }
    return answer;
}

fn runTask(alloc: std.mem.Allocator, cfg: *config.Config, opts: LoopOpts, prompt: []const u8, session_id: ?[]const u8) !void {
    const answer = try agentRunOnce(alloc, cfg, opts, prompt, session_id);
    defer alloc.free(answer);
    // onEvent already printed the final answer; trailing newline for `run`.
    if (session_id) |sid| {
        std.debug.print("\nsession saved: {s}/.zharness/sessions/{s}.json\n", .{ cfg.cwd, sid });
    }
    std.debug.print("\n", .{});
}

fn chatLoop(alloc: std.mem.Allocator, cfg: *config.Config, opts: LoopOpts, session_id: ?[]const u8) !void {
    var built = try buildLoop(alloc, cfg, opts);
    defer built.deinit(alloc);

    const io = built.ctx.io();

    // Optional named session: load prior transcript, resume across turns and
    // process invocations, and persist after every exchange.
    var session_ptr: ?*session.Session = null;
    var session_path: ?[]u8 = null;
    if (session_id) |sid| {
        const dir = try std.fs.path.join(alloc, &.{ cfg.cwd, ".zharness", "sessions" });
        std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, sid });
        alloc.free(dir);
        session_path = p;
        const s = try alloc.create(session.Session);
        errdefer alloc.destroy(s);
        s.* = try session.Session.init(alloc, sid);
        errdefer s.deinit();
        s.load(io, p) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        for (s.messages.items) |m| try built.loop.seed(alloc, m);
        session_ptr = s;
    }
    defer if (session_ptr) |s| {
        s.deinit();
        alloc.destroy(s);
    };
    defer if (session_path) |p| alloc.free(p);

    std.debug.print("zharness chat", .{});
    if (session_ptr) |s| std.debug.print(" — session '{s}' ({d} messages)", .{ s.id, s.count() });
    std.debug.print(" — type 'exit' or 'quit' to leave.\n\n", .{});

    while (true) {
        std.debug.print("you> ", .{});
        const owned = clib.readLineStdin(alloc) catch |e| switch (e) {
            else => return e,
        } orelse break;
        if (std.mem.eql(u8, owned, "exit") or std.mem.eql(u8, owned, "quit")) {
            alloc.free(owned);
            break;
        }
        if (owned.len == 0) {
            alloc.free(owned);
            continue;
        }
        // Refresh the task scratchpad for this exchange.
        if (built.lext.working) |wm| wm.set("task", owned) catch {};
        const answer = built.loop.run(owned) catch |e| {
            std.debug.print("\n[error] {s}\n", .{@errorName(e)});
            alloc.free(owned);
            continue;
        };
        std.debug.print("\n", .{});
        alloc.free(answer);

        if (session_ptr) |s| {
            try built.loop.syncToSession(s);
            try s.save(io, session_path.?);
        }
        alloc.free(owned);
    }

    if (session_ptr) |s| {
        try s.save(io, session_path.?);
        std.debug.print("\nsession saved: {s}\n", .{session_path.?});
    }
    std.debug.print("\nbye.\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    // Collect argv into a slice of sentinel strings (Zig 0.17: args come via
    // the init.args iterator, not std.process.argsAlloc).
    var args_list: std.ArrayList([:0]const u8) = .empty;
    defer args_list.deinit(alloc);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |arg| {
        try args_list.append(alloc, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const sub = args[1];

    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, sub, "run")) {
        if (args.len < 3) {
            std.debug.print("error: 'run' requires a prompt argument.\n", .{});
            printUsage();
            std.process.exit(1);
        }
        // flags may appear before/after the prompt; one strict parser for all
        // subcommands (missing flag values are hard errors everywhere).
        const flags = cli_flags.parseSubFlags(args[2..], 1) catch |e| {
            std.debug.print("error: invalid flags ({s}).\n", .{@errorName(e)});
            printUsage();
            std.process.exit(1);
        };
        const prompt: ?[]const u8 = flags.prompt;

        if (prompt == null) {
            std.debug.print("error: 'run' requires a prompt argument.\n", .{});
            std.process.exit(1);
        }

        const lopts = try optsFromFlags(alloc, &flags);

        // load config in a sub-allocator to apply overrides + api-key check
        var cfg = try config.load(alloc);
        defer cfg.deinit();
        try cfg.applyOverrides(flags.model, flags.provider, flags.no_stream);
        applySandboxOverride(&cfg, flags.sandbox);

        if (cfg.api_key.len == 0) {
            std.debug.print(
                "error: no API key found. Set ZHARNESS_API_KEY or DEEPSEEK_API_KEY.\n",
                .{},
            );
            std.process.exit(1);
        }

        runTask(alloc, &cfg, lopts, prompt.?, flags.session_id) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, sub, "chat")) {
        // chat honors the same strict flag set; positionals are not accepted.
        const flags = cli_flags.parseSubFlags(args[2..], 0) catch |e| {
            std.debug.print("error: invalid flags ({s}).\n", .{@errorName(e)});
            printUsage();
            std.process.exit(1);
        };

        const lopts = try optsFromFlags(alloc, &flags);

        var cfg = try config.load(alloc);
        defer cfg.deinit();
        try cfg.applyOverrides(flags.model, flags.provider, flags.no_stream);
        applySandboxOverride(&cfg, flags.sandbox);

        if (cfg.api_key.len == 0) {
            std.debug.print(
                "error: no API key found. Set ZHARNESS_API_KEY or DEEPSEEK_API_KEY.\n",
                .{},
            );
            std.process.exit(1);
        }

        chatLoop(alloc, &cfg, lopts, flags.session_id) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, sub, "serve")) {
        // serve shares the run/chat flag set plus --port.
        const flags = cli_flags.parseSubFlags(args[2..], 0) catch |e| {
            std.debug.print("error: invalid flags ({s}).\n", .{@errorName(e)});
            printUsage();
            std.process.exit(1);
        };
        var cfg = try config.load(alloc);
        defer cfg.deinit();
        try cfg.applyOverrides(flags.model, flags.provider, flags.no_stream);
        applySandboxOverride(&cfg, flags.sandbox);
        const lopts = try optsFromFlags(alloc, &flags);
        applySandboxOverride(&cfg, flags.sandbox);
        cmdServe(alloc, &cfg, lopts, flags.port) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, sub, "workflow")) {
        if (args.len < 3) {
            std.debug.print("error: 'workflow' requires a JSON file argument.\n", .{});
            printUsage();
            std.process.exit(1);
        }
        var cfg = try config.load(alloc);
        defer cfg.deinit();
        cmdWorkflow(alloc, &cfg, args[2]) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, sub, "plugin")) {
        if (args.len < 3) {
            std.debug.print("error: 'plugin' requires a subcommand (list | exec).\n", .{});
            printUsage();
            std.process.exit(1);
        }
        if (std.mem.eql(u8, args[2], "list")) {
            var dir_override: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--dir")) {
                    i += 1;
                    if (i < args.len) dir_override = args[i];
                }
            }
            try cmdPluginList(alloc, dir_override);
            return;
        }
        if (std.mem.eql(u8, args[2], "exec")) {
            if (args.len < 5) {
                std.debug.print("error: 'plugin exec' requires <tool-name> '<args-json>'\n", .{});
                std.process.exit(1);
            }
            // Optional --dir (same semantics as list); default dirs otherwise.
            var dir_override: ?[]const u8 = null;
            var i: usize = 5;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--dir")) {
                    i += 1;
                    if (i < args.len) dir_override = args[i];
                }
            }
            try cmdPluginExec(alloc, args[3], args[4], dir_override);
            return;
        }
        std.debug.print("error: unknown plugin subcommand '{s}'\n", .{args[2]});
        std.process.exit(1);
    }

    std.debug.print("error: unknown subcommand '{s}'\n", .{sub});
    printUsage();
    std.process.exit(1);
}
