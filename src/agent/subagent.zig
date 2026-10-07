//! SubAgent (dev.md §XVIII): an isolated mini AgentLoop used to delegate a
//! bounded task from a parent agent and hand back only the final text.
//!
//! Design notes / integration contract:
//!   - Plain params ONLY — this module never imports cordis. The per-SubAgent
//!     "independent Scope / independent Session" from dev.md §XVIII is
//!     approximated by a fresh, private message list per run: nothing leaks
//!     into the parent transcript, the parent receives just `SubAgentOutcome`.
//!   - Transport + execution are injected as FUNCTION POINTERS through
//!     `SubAgentDeps`, so tests script fake models (`ScriptedChat` below) and
//!     production wires `ChatClient.chat` + the parent tool dispatcher (see
//!     tool/spawn_agent.zig for the ready-made wiring thunks).
//!   - `deps.tools` is the SHARED parent registry, read-only: it supplies tool
//!     SCHEMAS for the request payload, filtered through `spec.allowed_tools`
//!     when set (unknown names are skipped). Actual EXECUTION always flows
//!     through `deps.exec_fn` so policy/sandboxing stays injectable.
//!   - Allocator contract (mirrors how AgentLoop pairs client.alloc with the
//!     loop's allocator):
//!       * `chat_fn` must allocate its ChatResponse buffers with the SAME
//!         allocator that `runSubagent` is invoked with;
//!       * `exec_fn` must allocate its `ToolResult.output` with
//!         `deps.alloc` — runSubagent frees it right after copying the text
//!         into the transcript.
//!   - Caps: the loop stops after `spec.max_turns` model rounds; the
//!     accumulated answer is cut to `spec.output_char_cap` bytes (at a UTF-8
//!     boundary) with a visible marker. Either budget being hit marks the
//!     outcome `truncated = true` ("the subagent did not finish naturally").

const std = @import("std");
const model_mod = @import("../model/model.zig");
const tool_reg = @import("../tool/registry.zig");

const Message = model_mod.Message;
const ChatRequest = model_mod.ChatRequest;
const ChatResponse = model_mod.ChatResponse;
const ToolCall = model_mod.ToolCall;

pub const default_max_turns: usize = 8;
/// Default answer budget in bytes (ASCII chars == bytes; multibyte sequences
/// are never split mid-codepoint).
pub const default_output_cap: usize = 16 * 1024;

/// What the parent wants from the child. All slices are borrowed — the caller
/// keeps them alive for the duration of `runSubagent`.
pub const SubAgentSpec = struct {
    /// Human-readable name (used in logs / the spawn_agent footer).
    name: []const u8 = "subagent",
    system_prompt: []const u8,
    max_turns: usize = default_max_turns,
    /// Byte budget for the accumulated final text (0 disables the cap).
    output_char_cap: usize = default_output_cap,
    /// When set, only these registry tools are advertised to the child.
    allowed_tools: ?[]const []const u8 = null,
};

/// Result of one tool execution inside the subagent run. Allocated by
/// `deps.exec_fn` with `deps.alloc`; freed by runSubagent via freeExecResult.
pub const ToolResult = struct {
    success: bool,
    output: []const u8,
};

pub fn freeExecResult(alloc: std.mem.Allocator, r: *const ToolResult) void {
    alloc.free(r.output);
}

/// Injection point for transport + execution. `ctx` is opaque — production
/// points it at whatever its thunks need (e.g. *ChatClient); tests point it
/// at a ScriptedChat.
pub const SubAgentDeps = struct {
    /// Allocator exec_fn must use for ToolResult.output.
    alloc: std.mem.Allocator,
    /// Opaque context handed back verbatim to both callbacks.
    ctx: ?*anyopaque = null,
    chat_fn: *const fn (deps: *SubAgentDeps, req: ChatRequest) anyerror!ChatResponse,
    /// Null means "no executor wired": any requested tool call is answered
    /// with an `[error] ...` tool message instead of crashing.
    exec_fn: ?*const fn (deps: *SubAgentDeps, call: ToolCall) anyerror!ToolResult = null,
    /// Shared parent registry (read-only schema source). Null → no tools are
    /// advertised at all.
    tools: ?*const tool_reg.ToolRegistry = null,
    /// Per-run registry id handed back to the optional cooperative hooks.
    hook_run_id: []const u8 = "",
    /// Cooperative cancellation probe, consulted at the top of every turn.
    should_cancel: ?*const fn (deps: *SubAgentDeps) bool = null,
    /// Cooperative inbox drain, consulted before every turn; non-empty text is
    /// appended as a user message. Allocated with `deps.alloc`.
    drain_inbox: ?*const fn (deps: *SubAgentDeps, alloc: std.mem.Allocator) anyerror!?[]const u8 = null,
};

/// Final answer handed back to the parent. `text` is owned by the caller:
/// release with `deinit(alloc)`.
pub const SubAgentOutcome = struct {
    text: []const u8,
    turns_used: usize,
    /// True when the run did NOT finish naturally within its budgets (turn
    /// cap exhausted mid-work, or output cut by output_char_cap).
    truncated: bool,
    /// True when a cooperative cancel request stopped the run.
    cancelled: bool = false,

    pub fn deinit(self: *const SubAgentOutcome, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
    }
};

/// Run an isolated mini-loop on `task` and return the accumulated final text.
///
/// The message list starts fresh every call: [user task]. The spec's system
/// prompt rides in `ChatRequest.system_prompt`, exactly like the main
/// AgentLoop does on the wire. Each round: chat → if no tool calls, stop;
/// otherwise execute each call via deps.exec_fn and feed results back as
/// `role=.tool` messages carrying the original call id (same wire shape as
/// agent.zig, so providers accept the transcript).
pub fn runSubagent(
    alloc: std.mem.Allocator,
    deps: *SubAgentDeps,
    spec: SubAgentSpec,
    task: []const u8,
) !SubAgentOutcome {
    var messages: std.ArrayList(Message) = .empty;
    defer {
        for (messages.items) |*m| freeMessage(alloc, m);
        messages.deinit(alloc);
    }
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, task) });

    const tools_json = try resolveToolsJson(alloc, deps, &spec);
    defer alloc.free(tools_json);

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);

    var turns_used: usize = 0;
    var finished_naturally = false;
    var cancelled = false;

    while (turns_used < spec.max_turns) {
        if (deps.should_cancel) |f| {
            if (f(deps)) {
                cancelled = true;
                break;
            }
        }
        if (deps.drain_inbox) |f| {
            if (try f(deps, alloc)) |text| {
                defer alloc.free(text);
                if (text.len > 0) try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, text) });
            }
        }
        turns_used += 1;

        var resp = try deps.chat_fn(deps, .{
            .messages = messages.items,
            .tools_json = tools_json,
            .system_prompt = spec.system_prompt,
            .reasoning_effort = null,
            .stream = false,
        });
        defer resp.deinit(alloc);

        // Accumulate narration + the final answer across all rounds.
        if (resp.content.len > 0) {
            if (acc.items.len > 0) try acc.appendSlice(alloc, "\n\n");
            try acc.appendSlice(alloc, resp.content);
        }

        var msg = try buildAssistantMessage(alloc, resp);
        errdefer freeMessage(alloc, &msg);
        try messages.append(alloc, msg);

        if (!resp.has_tools or resp.tool_calls.len == 0) {
            finished_naturally = true;
            break;
        }
        for (resp.tool_calls) |tc| {
            var tmsg = try buildToolMessage(alloc, deps, tc);
            errdefer freeMessage(alloc, &tmsg);
            try messages.append(alloc, tmsg);
        }
    }

    const truncated = !finished_naturally;

    if (spec.output_char_cap > 0 and acc.items.len > spec.output_char_cap) {
        // Back off to a UTF-8 codepoint boundary so the prefix stays valid.
        var cut = spec.output_char_cap;
        while (cut > 0 and cut < acc.items.len and (acc.items[cut] & 0xC0) == 0x80) cut -= 1;
        const marker = try std.fmt.allocPrint(
            alloc,
            "\n\n[subagent output truncated: showing {d} of {d} chars]",
            .{ cut, acc.items.len },
        );
        defer alloc.free(marker);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, acc.items[0..cut]);
        try out.appendSlice(alloc, marker);
        return .{ .text = try out.toOwnedSlice(alloc), .turns_used = turns_used, .truncated = true, .cancelled = cancelled };
    }

    return .{
        .text = try acc.toOwnedSlice(alloc),
        .turns_used = turns_used,
        .truncated = truncated,
        .cancelled = cancelled,
    };
}

fn freeMessage(alloc: std.mem.Allocator, m: *const Message) void {
    alloc.free(m.content);
    if (m.tool_call_id) |v| alloc.free(v);
    if (m.tool_calls_json) |v| alloc.free(v);
}

fn buildAssistantMessage(alloc: std.mem.Allocator, resp: ChatResponse) !Message {
    const content = try alloc.dupe(u8, resp.content);
    errdefer alloc.free(content);
    var echo: ?[]const u8 = null;
    if (resp.has_tools) echo = try echoToolCallsJson(alloc, resp.tool_calls);
    return .{ .role = .assistant, .content = content, .tool_calls_json = echo };
}

/// Rebuild the OpenAI-style tool_calls array to echo back on the next
/// request (same wire shape as agent.zig). Arguments are inserted RAW — they
/// are already JSON text as the provider sent them.
fn echoToolCallsJson(alloc: std.mem.Allocator, calls: []const ToolCall) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (calls, 0..) |tc, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"id\":\"");
        try escapeJsonString(alloc, tc.id, &buf);
        try buf.appendSlice(alloc, "\",\"type\":\"function\",\"function\":{\"name\":\"");
        try escapeJsonString(alloc, tc.name, &buf);
        try buf.appendSlice(alloc, "\",\"arguments\":");
        try buf.appendSlice(alloc, if (tc.arguments.len > 0) tc.arguments else "{}");
        try buf.appendSlice(alloc, "}}");
    }
    try buf.append(alloc, ']');
    return buf.toOwnedSlice(alloc);
}

fn buildToolMessage(alloc: std.mem.Allocator, deps: *SubAgentDeps, tc: ToolCall) !Message {
    const rendered = try renderExecResult(alloc, deps, tc);
    errdefer alloc.free(rendered);
    const cid = try alloc.dupe(u8, tc.id);
    errdefer alloc.free(cid);
    return .{ .role = .tool, .content = rendered, .tool_call_id = cid };
}

fn renderExecResult(alloc: std.mem.Allocator, deps: *SubAgentDeps, tc: ToolCall) ![]const u8 {
    const ef = deps.exec_fn orelse
        return std.fmt.allocPrint(alloc, "[error] tool '{s}' skipped: no executor wired for this subagent", .{tc.name});
    var r = ef(deps, tc) catch |e|
        return std.fmt.allocPrint(alloc, "[error] tool '{s}' failed: {s}", .{ tc.name, @errorName(e) });
    defer freeExecResult(deps.alloc, &r);
    if (r.success) return alloc.dupe(u8, r.output);
    return std.fmt.allocPrint(alloc, "[error] {s}", .{r.output});
}

/// Serialize the tool-schema fragment for the request payload. Full registry
/// set unless spec.allowed_tools filters it down (unknown names skipped).
fn resolveToolsJson(
    alloc: std.mem.Allocator,
    deps: *SubAgentDeps,
    spec: *const SubAgentSpec,
) ![]const u8 {
    const reg = deps.tools orelse return alloc.dupe(u8, "");
    const allowed = spec.allowed_tools orelse return reg.buildToolsJson(alloc);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var first = true;
    for (allowed) |name| {
        const def = reg.get(name) orelse continue;
        if (!first) try out.append(alloc, ',');
        first = false;
        try out.appendSlice(alloc, "{\"type\":\"function\",\"function\":{\"name\":\"");
        try out.appendSlice(alloc, def.name);
        try out.appendSlice(alloc, "\",\"description\":\"");
        try escapeJsonString(alloc, def.description, &out);
        try out.appendSlice(alloc, "\",\"parameters\":");
        try out.appendSlice(alloc, def.parameters_json);
        try out.appendSlice(alloc, "}}");
    }
    return out.toOwnedSlice(alloc);
}

fn escapeJsonString(alloc: std.mem.Allocator, input: []const u8, out: *std.ArrayList(u8)) !void {
    for (input) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, ch),
        }
    }
}

// ── Offline test support ────────────────────────────────────────────────────

/// Scripted model + executor for OFFLINE tests. Responses replay in order;
/// once the steps run out, the LAST step repeats forever so turn-cap tests
/// converge without extra setup. Also used by tool/spawn_agent.zig tests.
pub const ScriptedChat = struct {
    alloc: std.mem.Allocator,
    steps: []const Step,
    idx: usize = 0,
    chat_calls: usize = 0,
    exec_log: std.ArrayList(ExecRecord) = .empty,
    /// Per chat() call: duped tool_call_id of the transcript's LAST message
    /// when it is a tool result, "" otherwise. Lets tests assert the
    /// tool-result feedback actually reached the wire payload.
    last_tool_ids: std.ArrayList([]const u8) = .empty,

    pub const Step = struct {
        content: []const u8 = "",
        /// Non-null → this step is a tool-call round.
        tool_name: ?[]const u8 = null,
        tool_arguments: []const u8 = "{}",
        tool_id: []const u8 = "call_1",
    };

    pub const ExecRecord = struct { name: []const u8, arguments: []const u8 };

    pub fn init(alloc: std.mem.Allocator, steps: []const Step) ScriptedChat {
        return .{ .alloc = alloc, .steps = steps };
    }

    pub fn deinit(self: *ScriptedChat) void {
        for (self.exec_log.items) |r| {
            self.alloc.free(r.name);
            self.alloc.free(r.arguments);
        }
        self.exec_log.deinit(self.alloc);
        for (self.last_tool_ids.items) |s| self.alloc.free(s);
        self.last_tool_ids.deinit(self.alloc);
    }

    /// Assemble the SubAgentDeps bundle pointing at this scripted instance.
    pub fn deps(self: *ScriptedChat, tools: ?*const tool_reg.ToolRegistry) SubAgentDeps {
        return .{
            .alloc = self.alloc,
            .ctx = self,
            .chat_fn = chatFn,
            .exec_fn = execFn,
            .tools = tools,
        };
    }

    pub fn chatFn(d: *SubAgentDeps, req: ChatRequest) anyerror!ChatResponse {
        const self: *ScriptedChat = @ptrCast(@alignCast(d.ctx.?));
        self.chat_calls += 1;
        if (req.messages.len > 0) {
            const last = req.messages[req.messages.len - 1];
            const snap = if (last.role == .tool)
                try self.alloc.dupe(u8, last.tool_call_id orelse "")
            else
                try self.alloc.dupe(u8, "");
            try self.last_tool_ids.append(self.alloc, snap);
        }
        const step = self.steps[@min(self.idx, self.steps.len - 1)];
        self.idx += 1;

        var calls: []ToolCall = &.{};
        if (step.tool_name) |n| {
            calls = try self.alloc.alloc(ToolCall, 1);
            calls[0] = .{
                .id = try self.alloc.dupe(u8, step.tool_id),
                .name = try self.alloc.dupe(u8, n),
                .arguments = try self.alloc.dupe(u8, step.tool_arguments),
            };
        }
        return .{
            .content = try self.alloc.dupe(u8, step.content),
            .reasoning = try self.alloc.dupe(u8, ""),
            .finish_reason = try self.alloc.dupe(u8, "stop"),
            .tool_calls = calls,
            .has_tools = step.tool_name != null,
        };
    }

    pub fn execFn(d: *SubAgentDeps, call: ToolCall) anyerror!ToolResult {
        const self: *ScriptedChat = @ptrCast(@alignCast(d.ctx.?));
        try self.exec_log.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, call.name),
            .arguments = try self.alloc.dupe(u8, call.arguments),
        });
        // Contract: output must be allocated with d.alloc (freed by the loop).
        return .{ .success = true, .output = try d.alloc.dupe(u8, "tool-ok") };
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

test "simple task returns final text" {
    const alloc = std.testing.allocator;
    var scripted = ScriptedChat.init(alloc, &.{
        .{ .content = "final answer" },
    });
    defer scripted.deinit();
    var d = scripted.deps(null);

    var outcome = try runSubagent(alloc, &d, .{
        .system_prompt = "be brief",
        .max_turns = 4,
    }, "do the thing");
    defer outcome.deinit(alloc);

    try std.testing.expectEqualStrings("final answer", outcome.text);
    try std.testing.expectEqual(@as(usize, 1), outcome.turns_used);
    try std.testing.expectEqual(@as(usize, 1), scripted.chat_calls);
    try std.testing.expect(!outcome.truncated);
}

test "one tool-call round then finish feeds result back" {
    const alloc = std.testing.allocator;
    var scripted = ScriptedChat.init(alloc, &.{
        .{ .tool_name = "shell", .tool_arguments = "{\"command\":\"pwd\"}", .tool_id = "call_7" },
        .{ .content = "done after tool" },
    });
    defer scripted.deinit();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try reg.register(.{
        .name = "shell",
        .description = "run shell",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}",
    });

    var d = scripted.deps(&reg);
    var outcome = try runSubagent(alloc, &d, .{
        .system_prompt = "use tools",
        .max_turns = 4,
    }, "what dir am i in");
    defer outcome.deinit(alloc);

    try std.testing.expectEqualStrings("done after tool", outcome.text);
    try std.testing.expectEqual(@as(usize, 2), outcome.turns_used);
    try std.testing.expect(!outcome.truncated);

    // Executor saw the scripted call.
    try std.testing.expectEqual(@as(usize, 1), scripted.exec_log.items.len);
    try std.testing.expectEqualStrings("shell", scripted.exec_log.items[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", scripted.exec_log.items[0].arguments);

    // Request #2 carried the tool result back with the matching call id:
    // transcript was [user, assistant(tool_calls), tool(call_7)].
    try std.testing.expectEqual(@as(usize, 2), scripted.last_tool_ids.items.len);
    try std.testing.expectEqualStrings("", scripted.last_tool_ids.items[0]);
    try std.testing.expectEqualStrings("call_7", scripted.last_tool_ids.items[1]);

    // Narration from the tool round AND the final answer accumulate when
    // both carry content.
    var scripted2 = ScriptedChat.init(alloc, &.{
        .{ .content = "let me check", .tool_name = "shell" },
        .{ .content = "done after tool" },
    });
    defer scripted2.deinit();
    var d2 = scripted2.deps(&reg);
    var outcome2 = try runSubagent(alloc, &d2, .{
        .system_prompt = "use tools",
        .max_turns = 4,
    }, "again");
    defer outcome2.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, outcome2.text, "let me check") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome2.text, "done after tool") != null);
}

test "turn cap stops runaway tool loop" {
    const alloc = std.testing.allocator;
    // Single always-tool step: repeats forever once consumed.
    var scripted = ScriptedChat.init(alloc, &.{
        .{ .tool_name = "shell" },
    });
    defer scripted.deinit();
    var d = scripted.deps(null);

    var outcome = try runSubagent(alloc, &d, .{
        .system_prompt = "loop forever",
        .max_turns = 3,
    }, "never finish");
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), outcome.turns_used);
    try std.testing.expectEqual(@as(usize, 3), scripted.chat_calls);
    // The run was cut short mid-work → truncated.
    try std.testing.expect(outcome.truncated);
}

test "output cap truncates with marker" {
    const alloc = std.testing.allocator;
    var scripted = ScriptedChat.init(alloc, &.{
        .{ .content = "abcdefghijklmnopqrstuvwxyz" }, // 26 chars
    });
    defer scripted.deinit();
    var d = scripted.deps(null);

    var outcome = try runSubagent(alloc, &d, .{
        .system_prompt = "verbose",
        .max_turns = 2,
        .output_char_cap = 10,
    }, "talk a lot");
    defer outcome.deinit(alloc);

    try std.testing.expect(outcome.truncated);
    try std.testing.expect(std.mem.startsWith(u8, outcome.text, "abcdefghij"));
    try std.testing.expect(std.mem.indexOf(u8, outcome.text, "[subagent output truncated") != null);
}

test "multibyte output cut at utf-8 boundary" {
    const alloc = std.testing.allocator;
    // Each 'é' is 2 bytes; cap of 5 lands mid-sequence (byte 5 splits the
    // third 'é') — the cut must back off to byte 4.
    var scripted = ScriptedChat.init(alloc, &.{
        .{ .content = "éééééééé" },
    });
    defer scripted.deinit();
    var d = scripted.deps(null);

    var outcome = try runSubagent(alloc, &d, .{
        .system_prompt = "unicode",
        .max_turns = 2,
        .output_char_cap = 5,
    }, "unicode please");
    defer outcome.deinit(alloc);

    try std.testing.expect(std.unicode.utf8ValidateSlice(outcome.text));
    try std.testing.expect(std.mem.startsWith(u8, outcome.text, "éé"));
}

test "allowed_tools filters schema payload" {
    const alloc = std.testing.allocator;
    var scripted = ScriptedChat.init(alloc, &.{.{ .content = "ok" }});
    defer scripted.deinit();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try reg.register(.{ .name = "shell", .description = "sh", .parameters_json = "{}" });
    try reg.register(.{ .name = "grep", .description = "gr", .parameters_json = "{}" });

    var d = scripted.deps(&reg);

    // The filter is a pure helper — assert it directly: allowed names are
    // serialized, unknown names skipped, and the full set used when null.
    const filtered = try resolveToolsJson(alloc, &d, &.{
        .system_prompt = "x",
        .allowed_tools = &.{ "shell", "grep", "missing_tool" },
    });
    defer alloc.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "\"shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "\"grep\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "missing_tool") == null);

    // A run with an allowed_tools spec still completes normally.
    var outcome = try runSubagent(alloc, &d, .{
        .system_prompt = "scoped",
        .max_turns = 2,
        .allowed_tools = &.{"shell"},
    }, "task");
    defer outcome.deinit(alloc);
    try std.testing.expectEqualStrings("ok", outcome.text);
}

test "missing executor yields error tool message" {
    const alloc = std.testing.allocator;
    var scripted = ScriptedChat.init(alloc, &.{
        .{ .tool_name = "shell" },
        .{ .content = "gave up gracefully" },
    });
    defer scripted.deinit();
    var d = scripted.deps(null);
    d.exec_fn = null; // explicitly unwired

    var outcome = try runSubagent(alloc, &d, .{
        .system_prompt = "no hands",
        .max_turns = 3,
    }, "use a tool anyway");
    defer outcome.deinit(alloc);

    try std.testing.expectEqualStrings("gave up gracefully", outcome.text);
    try std.testing.expectEqual(@as(usize, 0), scripted.exec_log.items.len);
}

test "cooperative cancel stops before the first turn" {
    const alloc = std.testing.allocator;
    const H = struct {
        fn chat(d: *SubAgentDeps, req: ChatRequest) anyerror!ChatResponse {
            _ = d;
            _ = req;
            return error.ShouldNotBeCalled;
        }
        fn cancel(d: *SubAgentDeps) bool {
            _ = d;
            return true;
        }
    };
    var deps = SubAgentDeps{ .alloc = alloc, .chat_fn = H.chat, .should_cancel = H.cancel };
    const spec = SubAgentSpec{ .name = "x", .system_prompt = "s", .max_turns = 3, .output_char_cap = 1000 };
    var out = try runSubagent(alloc, &deps, spec, "task");
    defer out.deinit(alloc);
    try std.testing.expect(out.cancelled);
    try std.testing.expectEqual(@as(usize, 0), out.turns_used);
}
