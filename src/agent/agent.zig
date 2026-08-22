//! Agent core + loop (dev.md §IV–V, §VIII, §XXXIV).
//!
//! The agent is intentionally thin: identity, state and a scope. The actual
//! turn logic is the `AgentLoop`, which drives the model and tools through the
//! zcordis `Context` — each model request and tool execution is an event so the
//! runtime stays decoupled from any concrete tool or provider.

const std = @import("std");
const cordis = @import("cordis");

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
        try self.messages.append(self.alloc, Message{ .role = .user, .content = try self.alloc.dupe(u8, prompt) });

        const tools_json = try self.tools.buildToolsJson(self.alloc);
        defer self.alloc.free(tools_json);

        var turn: usize = 0;
        var final_answer: []const u8 = try self.alloc.dupe(u8, "");

        while (turn < self.agent.config.max_turns) {
            turn += 1;
            self.agent.state = .thinking;
            const turn_msg = try std.fmt.allocPrint(self.alloc, "turn {d}", .{turn});
            self.emit(.turn_start, turn_msg);
            self.alloc.free(turn_msg);

            const req = model_mod.ChatRequest{
                .messages = self.messages.items,
                .tools_json = tools_json,
                .system_prompt = self.agent.config.system_prompt,
                .reasoning_effort = self.agent.config.reasoning_effort orelse null,
                .stream = false,
            };

            var resp = self.client.chat(req) catch |e| {
                self.agent.state = .failed;
                const msg = try std.fmt.allocPrint(self.alloc, "model error: {s}", .{@errorName(e)});
                self.emit(.err, msg);
                return msg;
            };
            defer resp.deinit(self.alloc);

            if (resp.reasoning.len > 0) {
                self.emit(.thinking, resp.reasoning);
            }

            if (resp.content.len > 0) {
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

                const call = tool_builtin.ToolCall{ .name = tc.name, .arguments = tc.arguments };
                var result = tool_builtin.execute(self.alloc, self.client.io, self.cwd, call) catch |e| tool_builtin.ToolResult{
                    .success = false,
                    .output = "",
                    .err_msg = @errorName(e),
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
            self.agent.state = .observing;
        }

        self.agent.state = .completed;
        self.emit(.done, final_answer);
        return final_answer;
    }
};

fn tool_mod_echo(alloc: std.mem.Allocator, resp: ChatResponse) ![]const u8 {
    // Reconstruct the tool_calls array to echo. We need the raw JSON that the
    // model sent; since we parsed it, rebuild from the structured calls.
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "[");
    for (resp.tool_calls, 0..) |tc, i| {
        if (i > 0) try buf.append(alloc, ',');
        const piece = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ tc.id, tc.name, tc.arguments });
        defer alloc.free(piece);
        try buf.appendSlice(alloc, piece);
    }
    try buf.append(alloc, ']');
    return buf.toOwnedSlice(alloc);
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
