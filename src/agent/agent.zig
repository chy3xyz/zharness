//! Agent core + loop (dev.md §IV–V, §VIII, §XXXIV).
//!
//! The agent is intentionally thin: identity, state and a scope. The actual
//! turn logic is the `AgentLoop`, which drives the model and tools through the
//! zcordis `Context` — each model request and tool execution is an event so the
//! runtime stays decoupled from any concrete tool or provider.
//!
//! Wiring surface (swarm integration contract):
//!   - `checkpoints`: optional CheckpointStore (main-owned). The loop saves a
//!     best-effort transcript snapshot at every turn boundary and after each
//!     tool batch (dev.md §XVI).
//!   - `ext`: optional `Extensions` vtable (plain fn pointers). It serves the
//!     loop-native tools (skills / memory / plan / goal) and re-renders the
//!     dynamic part of the system prompt (plan checklist, goal, working
//!     memory, skill index) fresh on every turn.

const std = @import("std");
const cordis = @import("cordis");

const clib = @import("../clib.zig");
const config_mod = @import("../config.zig");
const checkpoint_mod = @import("../session/checkpoint.zig");

const model_mod = @import("../model/model.zig");
const tool_reg = @import("../tool/registry.zig");
const tool_builtin = @import("../tool/builtin.zig");
const session_mod = @import("../session/session.zig");
const Message = model_mod.Message;
const Role = model_mod.Role;
const ChatClient = model_mod.ChatClient;
const ChatResponse = model_mod.ChatResponse;
const ToolCall = model_mod.ToolCall;

pub const AgentState = enum {
    idle,
    preparing,
    thinking,
    awaiting_tool,
    executing_tool,
    observing,
    completed,
    failed,
    cancelled,
};

pub const Agent = struct {
    id: []const u8,
    state: AgentState,
    scope: *cordis.Scope,
    config: *const AgentConfig,

    pub fn init(alloc: std.mem.Allocator, scope: *cordis.Scope, config: *const AgentConfig) !*Agent {
        const self = try alloc.create(Agent);
        self.* = .{
            .id = try alloc.dupe(u8, "agent-1"),
            .state = .idle,
            .scope = scope,
            .config = config,
        };
        return self;
    }

    pub fn deinit(self: *Agent, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.destroy(self);
    }
};

pub const AgentConfig = struct {
    system_prompt: []const u8,
    max_turns: usize,
    reasoning_effort: ?[]const u8 = null,
    /// Stream chat completions via SSE when the provider supports it.
    /// Disable for fully buffered turns (`--no-stream`).
    stream: bool = true,
    /// Shell-tool sandbox level routed into builtin.execute (dev.md §XII).
    sandbox_mode: config_mod.Config.SandboxMode = .process,
};

/// Optional extension surface wired by main.zig (plain fn pointers, no
/// concrete imports — swarm decoupling rule). Lets the loop serve the
/// loop-native tools (skill_use / memory_* / plan_* / goal_set) from
/// main-owned state and refresh dynamic system-prompt sections each turn.
pub const Extensions = struct {
    ctx: *anyopaque,
    /// Extra system-prompt text appended after the configured prompt, rendered
    /// fresh on every turn. Caller frees; "" contributes nothing.
    renderContext: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]const u8,
    /// Try to serve a tool call from extension state. Return `null` when the
    /// tool name is unknown so the loop falls back to the builtin executors.
    executeTool: *const fn (
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        call: tool_builtin.ToolCall,
    ) anyerror!?tool_builtin.ToolResult,
};

/// The driver: a loop that alternates model inference and tool execution.
pub const AgentLoop = struct {
    alloc: std.mem.Allocator,
    ctx: *cordis.Context,
    agent: *Agent,
    client: ChatClient,
    tools: *tool_reg.ToolRegistry,
    cwd: []const u8,
    messages: std.ArrayList(Message),
    on_event: ?*const fn (kind: EventKind, payload: []const u8) void,
    /// Main-owned checkpoint store; null disables checkpointing.
    checkpoints: ?*checkpoint_mod.CheckpointStore,
    /// Loop-native tools + dynamic prompt sections; null when unwired.
    ext: ?*const Extensions,
    /// Optional image parts attached to the next user prompt. Borrowed for
    /// the duration of run(); the caller owns the backing slices.
    first_user_images: []const model_mod.ImagePart = &.{},

    pub const EventKind = enum {
        turn_start,
        thinking,
        tool_call,
        tool_result,
        text,
        done,
        err,
    };

    pub fn init(
        alloc: std.mem.Allocator,
        ctx: *cordis.Context,
        agent: *Agent,
        client: ChatClient,
        tools: *tool_reg.ToolRegistry,
        cwd: []const u8,
        on_event: ?*const fn (kind: EventKind, payload: []const u8) void,
        checkpoints: ?*checkpoint_mod.CheckpointStore,
        ext: ?*const Extensions,
    ) !AgentLoop {
        return .{
            .alloc = alloc,
            .ctx = ctx,
            .agent = agent,
            .client = client,
            .tools = tools,
            .cwd = cwd,
            .messages = std.ArrayList(Message).empty,
            .on_event = on_event,
            .checkpoints = checkpoints,
            .ext = ext,
        };
    }

    pub fn deinit(self: *AgentLoop) void {
        for (self.messages.items) |m| {
            self.alloc.free(m.content);
            if (m.tool_call_id) |t| self.alloc.free(t);
            if (m.tool_calls_json) |t| self.alloc.free(t);
        }
        self.messages.deinit(self.alloc);
    }

    /// Seed the loop's transcript from a previously-loaded session so a
    /// conversation can be resumed (dev.md §XV). Each message is cloned into
    /// the loop's allocator.
    pub fn seed(self: *AgentLoop, alloc: std.mem.Allocator, m: Message) !void {
        try self.messages.append(alloc, Message{
            .role = m.role,
            .content = try alloc.dupe(u8, m.content),
            .tool_call_id = if (m.tool_call_id) |v| try alloc.dupe(u8, v) else null,
            .tool_calls_json = if (m.tool_calls_json) |v| try alloc.dupe(u8, v) else null,
        });
    }

    /// Mirror the loop's full transcript into a session (replacing any prior
    /// content) so it can be persisted. The system prompt is not part of the
    /// message list and is intentionally omitted.
    pub fn syncToSession(self: *AgentLoop, s: *session_mod.Session) !void {
        s.clear();
        for (self.messages.items) |m| {
            switch (m.role) {
                .user => try s.addUser(m.content),
                .assistant => try s.addAssistant(m.content, m.tool_calls_json),
                .tool => try s.addToolResult(m.tool_call_id orelse "", m.content),
                .system => {},
            }
        }
    }

    /// Best-effort transcript snapshot (dev.md §XVI). Filesystem failures are
    /// swallowed on purpose — checkpointing must never break the agent loop.
    /// No-op when no store is wired.
    pub fn saveCheckpoint(self: *AgentLoop, label: []const u8) void {
        const store = self.checkpoints orelse return;
        const snap = snapshotMessages(self.alloc, self.messages.items) catch return;
        defer self.alloc.free(snap);
        _ = store.save(self.client.io, label, clib.nowTimestamp(), snap) catch {};
    }

    /// Execute one model-requested tool call: extension-wired tools first
    /// (skills / memory / plan / goal), then the builtin executors with the
    /// configured sandbox level.
    pub fn dispatchTool(self: *AgentLoop, tc: ToolCall) !tool_builtin.ToolResult {
        const call = tool_builtin.ToolCall{ .name = tc.name, .arguments = tc.arguments };
        if (self.ext) |e| {
            if (try e.executeTool(e.ctx, self.alloc, self.client.io, call)) |r| return r;
        }
        return tool_builtin.execute(self.alloc, self.client.io, self.cwd, call, self.agent.config.sandbox_mode);
    }

    fn emit(self: *AgentLoop, kind: EventKind, payload: []const u8) void {
        if (self.on_event) |cb| cb(kind, payload);
        // Also surface through the zcordis event bus (dev.md §VIII, §XXXIII).
        switch (kind) {
            .tool_call => self.ctx.emit(ToolCallEvent, &.{ .name = payload }) catch {},
            .tool_result => self.ctx.emit(ToolResultEvent, &.{ .output = payload }) catch {},
            .done => self.ctx.emit(AgentDoneEvent, &.{ .final = payload }) catch {},
            else => {},
        }
    }

    /// Run the agent on a single user prompt and return the final answer text
    /// (caller frees). Drives model <-> tool loop up to max_turns.
    pub fn run(self: *AgentLoop, prompt: []const u8) ![]const u8 {
        self.agent.state = .preparing;
        try self.messages.append(self.alloc, Message{
            .role = .user,
            .content = try self.alloc.dupe(u8, prompt),
            .images = self.first_user_images,
        });
        self.first_user_images = &.{};

        const tools_json = try self.tools.buildToolsJson(self.alloc);
        defer self.alloc.free(tools_json);

        var turn: usize = 0;
        var final_answer: []const u8 = try self.alloc.dupe(u8, "");

        while (turn < self.agent.config.max_turns) {
            turn += 1;
            self.agent.state = .thinking;
            const turn_msg = try std.fmt.allocPrint(self.alloc, "turn {d}", .{turn});
            defer self.alloc.free(turn_msg);
            self.emit(.turn_start, turn_msg);

            // Checkpoint the transcript at the turn boundary (best-effort).
            self.saveCheckpoint(turn_msg);

            // Effective system prompt = configured base + dynamic sections
            // (plan checklist, goal, working memory, skill index) rendered
            // fresh each turn by the wired extensions.
            var extra_sections: ?[]const u8 = null;
            defer if (extra_sections) |e| self.alloc.free(e);
            if (self.ext) |e| {
                extra_sections = e.renderContext(e.ctx, self.alloc) catch null;
            }
            var sys_owned: ?[]const u8 = null;
            defer if (sys_owned) |s| self.alloc.free(s);
            if (extra_sections) |extra| {
                if (extra.len > 0) {
                    sys_owned = try std.fmt.allocPrint(
                        self.alloc,
                        "{s}\n\n{s}",
                        .{ self.agent.config.system_prompt, extra },
                    );
                }
            }
            const system_prompt = sys_owned orelse self.agent.config.system_prompt;

            const req = model_mod.ChatRequest{
                .messages = self.messages.items,
                .tools_json = tools_json,
                .system_prompt = system_prompt,
                .reasoning_effort = self.agent.config.reasoning_effort orelse null,
                .stream = self.agent.config.stream,
            };

            var resp = self.client.chat(req) catch |e| {
                self.agent.state = .failed;
                const msg = try describeModelError(self.alloc, &self.client, e);
                self.emit(.err, msg);
                return msg;
            };
            defer resp.deinit(self.alloc);

            // When the transport streamed live deltas through a wired sink,
            // the user already watched this content arrive — don't reprint it.
            // With no sink wired, fall back to emitting whole messages here so
            // event consumers never lose output.
            const streamed_live = req.stream and self.client.stream_sink != null;
            if (resp.reasoning.len > 0 and !streamed_live) {
                self.emit(.thinking, resp.reasoning);
            }

            if (resp.content.len > 0 and !streamed_live) {
                self.emit(.text, resp.content);
            }

            // Record the assistant message (echo tool_calls if any).
            const assistant_msg = Message{
                .role = .assistant,
                .content = try self.alloc.dupe(u8, resp.content),
                .tool_calls_json = if (resp.has_tools) tool_mod: {
                    const echo = try tool_mod_echo(self.alloc, resp);
                    break :tool_mod if (echo.len > 0) echo else null;
                } else null,
            };
            try self.messages.append(self.alloc, assistant_msg);

            if (!resp.has_tools) {
                // Final answer — stop the loop.
                self.alloc.free(final_answer);
                final_answer = try self.alloc.dupe(u8, resp.content);
                self.agent.state = .completed;
                self.emit(.done, final_answer);
                return final_answer;
            }

            // Execute each requested tool call (dev.md §VIII pipeline).
            self.agent.state = .executing_tool;
            for (resp.tool_calls) |tc| {
                const tc_msg = try std.fmt.allocPrint(self.alloc, "{s}({s})", .{ tc.name, tc.arguments });
                self.emit(.tool_call, tc_msg);
                self.alloc.free(tc_msg);

                var result = self.dispatchTool(tc) catch |e| tool_builtin.ToolResult{
                    .success = false,
                    // freeResult frees both slices; keep them heap-owned.
                    .output = "",
                    .err_msg = try self.alloc.dupe(u8, @errorName(e)),
                };
                self.emit(.tool_result, result.output);
                defer tool_builtin.freeResult(self.alloc, &result);

                // Feed the result back as a tool message.
                const tool_msg = Message{
                    .role = .tool,
                    .content = try self.alloc.dupe(u8, result.format(self.alloc)),
                    .tool_call_id = try self.alloc.dupe(u8, tc.id),
                };
                try self.messages.append(self.alloc, tool_msg);
            }

            // Checkpoint after the tool batch so a crash mid-run never loses
            // executed work (best-effort).
            const post_label = try std.fmt.allocPrint(self.alloc, "turn {d} post-tools", .{turn});
            defer self.alloc.free(post_label);
            self.saveCheckpoint(post_label);

            self.agent.state = .observing;
        }

        self.agent.state = .completed;
        self.emit(.done, final_answer);
        return final_answer;
    }
};

/// Map a chat failure into a user-facing message. When the client captured a
/// provider detail (e.g. the envelope's error.message), lead with that instead
/// of a bare errno-style name.
fn describeModelError(alloc: std.mem.Allocator, client: *const ChatClient, e: anyerror) ![]const u8 {
    const detail = client.lastError();
    if (detail.len > 0) return std.fmt.allocPrint(alloc, "model request failed: {s}", .{detail});
    return switch (e) {
        error.HttpError => try alloc.dupe(u8, "model request failed (network/HTTP). Check endpoint, API key and connectivity."),
        error.BodyTooLarge => try alloc.dupe(u8, "provider response exceeded the size limit"),
        error.MalformedResponse => try alloc.dupe(u8, "provider returned a response zharness could not parse"),
        else => try std.fmt.allocPrint(alloc, "model error: {s}", .{@errorName(e)}),
    };
}

/// Map loop messages into checkpoint snapshots (trivial shape copy; the
/// Role enums are tag-compatible but kept explicit).
fn snapshotMessages(alloc: std.mem.Allocator, messages: []const Message) ![]checkpoint_mod.SnapshotMessage {
    const out = try alloc.alloc(checkpoint_mod.SnapshotMessage, messages.len);
    for (messages, 0..) |m, i| {
        out[i] = .{
            .role = switch (m.role) {
                .system => .system,
                .user => .user,
                .assistant => .assistant,
                .tool => .tool,
            },
            .content = m.content,
            .tool_call_id = m.tool_call_id,
            .tool_calls_json = m.tool_calls_json,
        };
    }
    return out;
}

fn tool_mod_echo(alloc: std.mem.Allocator, resp: ChatResponse) ![]const u8 {
    // Reconstruct the tool_calls array to echo. The arguments MUST be valid
    // JSON — the provider rejects the entire request otherwise. If the model
    // returned malformed arguments (SSE assembly glitch, truncation), fall
    // back to an empty object so the conversation can continue.
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "[");
    for (resp.tool_calls, 0..) |tc, i| {
        if (i > 0) try buf.append(alloc, ',');
        // Validate arguments as JSON: must start with '{' or '[' and have a
        // matching close. Degrad to "{}" otherwise.
        const args = blk: {
            const a = std.mem.trim(u8, tc.arguments, " \t\r\n");
            if (a.len == 0) break :blk "{}";
            if (a[0] != '{' and a[0] != '[') break :blk "{}";
            // Quick balance check
            var depth: i32 = 0;
            var in_str = false;
            for (a) |ch| {
                if (in_str) {
                    if (ch == '\\') continue; // skip escaped char (simplified)
                    if (ch == '"') in_str = false;
                } else {
                    if (ch == '"') in_str = true;
                    if (ch == '{' or ch == '[') depth += 1;
                    if (ch == '}' or ch == ']') depth -= 1;
                }
            }
            if (depth != 0 or in_str) break :blk "{}";
            if (std.c.getenv("ZH_DEBUG_ARGS") != null) {
                std.debug.print("[args-echo] len={d} first_100={s}\n", .{ a.len, a[0..@min(a.len,100)] });
            }
            break :blk a;
        };
        // The OpenAI/DeepSeek function-calling format requires arguments to
        // be a JSON STRING. `args` already contains properly escaped JSON
        // text (extractField preserves the \-escape sequences from the API
        // response), so wrapping in quotes is sufficient — no re-escaping
        // needed (double-escaping produces invalid JSON).
        const piece = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}", .{ tc.id, tc.name, args });
        defer alloc.free(piece);
        try buf.appendSlice(alloc, piece);
    }
    try buf.append(alloc, ']');
    const result = try buf.toOwnedSlice(alloc);
    if (std.c.getenv("ZH_DEBUG_ARGS") != null) {
        std.debug.print("[echo] {s}\n", .{result});
    }
    return result;
}

// ── zcordis events (dev.md §XXXIII) ────────────────────────────────────────
pub const ToolCallEvent = struct { name: []const u8 };
pub const ToolResultEvent = struct { output: []const u8 };
pub const AgentDoneEvent = struct { final: []const u8 };
pub const TurnStartEvent = struct { turn: usize };

test "agent loop construction" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    var tools = try tool_reg.ToolRegistry.init(alloc);
    defer tools.deinit();
    const cfg = AgentConfig{ .system_prompt = "be brief", .max_turns = 4, .reasoning_effort = null };
    const agent = try Agent.init(alloc, ctx.root, &cfg);
    defer agent.deinit(alloc);
    try std.testing.expect(true);
}
