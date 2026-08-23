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

const SYSTEM_PROMPT =
    \\You are zharness, a coding agent running inside a workspace. You help the user by
    \\reading, editing, and searching files, running shell commands, and using git. Prefer
    \\small, focused changes and verify them. Use the provided tools to inspect and modify
    \\the codebase rather than guessing. When you finish, give a concise final answer that
    \\summarizes what you did and any follow-up needed.
;

fn onEvent(kind: agent.AgentLoop.EventKind, payload: []const u8) void {
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

// ── loop extensions: skills / memory / plan / goal (dev.md §XIII–XVII) ─────

fn homeDir() ?[]const u8 {
    const p = std.c.getenv("HOME") orelse return null;
    const h = std.mem.span(p);
    if (h.len == 0) return null;
    return h;
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

fn printUsage() void {
    std.debug.print(
        \\zharness - a native coding-agent harness
        \\
        \\Usage:
        \\  zharness run "prompt"      Run a single agent task
        \\  zharness chat              Start an interactive REPL
        \\  zharness serve [--port N]  Start a server (not yet implemented)
        \\  zharness --help            Show this help
        \\
        \\Flags (run/chat):
        \\  --model X        Override the model
        \\  --provider Y     Override the provider
        \\  --no-stream     Disable streaming
        \\  --session ID     Resume/save a named session (persisted under .zharness/sessions/)
        \\
        \\Wired subsystems:
        \\  skills           <workspace>/skills + ~/.zharness/skills (SKILL.md)
        \\  memory           ~/.zharness/memory (memory_get / memory_set tools)
        \\  checkpoints      .zharness/checkpoints (saved per turn + tool batch)
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

    /// Tear everything down in strict reverse-creation order (the previous
    /// inline defer chain destroyed heap objects before deinitializing them).
    pub fn deinit(self: *Built, alloc: std.mem.Allocator) void {
        self.loop.deinit();
        alloc.destroy(self.loop);
        self.ag.deinit(alloc);
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

fn buildLoop(alloc: std.mem.Allocator, cfg: *config.Config) !Built {
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

    // ── checkpoints: <cwd>/.zharness/checkpoints (main-owned store) ───────
    const cp_dir = try std.fmt.allocPrint(alloc, "{s}/.zharness/checkpoints", .{cfg.cwd});
    defer alloc.free(cp_dir);
    const checkpoints = try alloc.create(checkpoint.CheckpointStore);
    errdefer alloc.destroy(checkpoints);
    checkpoints.* = try checkpoint.CheckpointStore.init(alloc, cp_dir);
    errdefer checkpoints.deinit();

    // Streamed deltas print live; wire the sink before the client value is
    // copied into the agent loop.
    var client = model.ChatClient.init(alloc, ctx.io(), cfg.endpoint, cfg.model, cfg.api_key);
    client.stream_sink = onStreamDelta;

    // Heap-allocate the config so the pointer `Agent` holds stays valid after
    // buildLoop returns (a stack-local would dangle and corrupt system_prompt).
    const acfg = try alloc.create(agent.AgentConfig);
    errdefer alloc.destroy(acfg);
    acfg.* = .{
        .system_prompt = SYSTEM_PROMPT,
        .max_turns = cfg.max_turns,
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
    };
}

fn runTask(alloc: std.mem.Allocator, cfg: *config.Config, prompt: []const u8, session_id: ?[]const u8) !void {
    var built = try buildLoop(alloc, cfg);
    defer built.deinit(alloc);

    const io = built.ctx.io();

    // Task scratchpad: the current prompt is visible in context sections.
    if (built.lext.working) |wm| wm.set("task", prompt) catch {};

    // Optional named session: load any prior transcript and seed the loop so
    // the run continues the conversation (dev.md §XV).
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
    // onEvent already prints the final answer; print a trailing newline for run too
    std.debug.print("\n", .{});
    alloc.free(answer);

    if (session_ptr) |s| {
        try built.loop.syncToSession(s);
        try s.save(io, session_path.?);
        std.debug.print("\nsession saved: {s}\n", .{session_path.?});
    }
}

fn chatLoop(alloc: std.mem.Allocator, cfg: *config.Config, session_id: ?[]const u8) !void {
    var built = try buildLoop(alloc, cfg);
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
        const model_opt = flags.model;
        const provider_opt = flags.provider;
        const no_stream = flags.no_stream;
        const session_id = flags.session_id;
        const prompt: ?[]const u8 = flags.prompt;

        if (prompt == null) {
            std.debug.print("error: 'run' requires a prompt argument.\n", .{});
            std.process.exit(1);
        }

        // load config in a sub-allocator to apply overrides + api-key check
        var cfg = try config.load(alloc);
        defer cfg.deinit();
        try cfg.applyOverrides(model_opt, provider_opt, no_stream);

        if (cfg.api_key.len == 0) {
            std.debug.print(
                "error: no API key found. Set ZHARNESS_API_KEY or DEEPSEEK_API_KEY.\n",
                .{},
            );
            std.process.exit(1);
        }

        runTask(alloc, &cfg, prompt.?, session_id) catch |e| {
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
        const model_opt = flags.model;
        const provider_opt = flags.provider;
        const no_stream = flags.no_stream;
        const session_id = flags.session_id;

        var cfg = try config.load(alloc);
        defer cfg.deinit();
        try cfg.applyOverrides(model_opt, provider_opt, no_stream);

        if (cfg.api_key.len == 0) {
            std.debug.print(
                "error: no API key found. Set ZHARNESS_API_KEY or DEEPSEEK_API_KEY.\n",
                .{},
            );
            std.process.exit(1);
        }

        chatLoop(alloc, &cfg, session_id) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, sub, "serve")) {
        var port: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--port")) {
                i += 1;
                if (i < args.len) port = args[i];
            }
        }
        var port_msg: [64]u8 = undefined;
        const port_str = if (port) |p|
            std.fmt.bufPrint(&port_msg, "Requested port: {s}", .{p}) catch "Requested port: <too long>"
        else
            "No port specified.";
        std.debug.print(
            \\zharness serve is not yet implemented (planned per dev.md §XXIII).
            \\{s}
            \\Use `zharness run "..."` or `zharness chat` for now.
            \\
        , .{port_str});
        return;
    }

    std.debug.print("error: unknown subcommand '{s}'\n", .{sub});
    printUsage();
    std.process.exit(1);
}
