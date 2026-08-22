//! Tool-execution helpers (MCP routing, tool dispatch) — split out of app.zig.

const std = @import("std");
const App = @import("app.zig").App;
const tools_mod = @import("../tools/mod.zig");
const tool_registry_mod = @import("../utils/tool_registry.zig");
const stream_client_mod = @import("../net/stream_client.zig");
const mcp_client_mod = @import("../net/mcp_client.zig");
const dangerous_patterns = @import("../utils/dangerous_patterns.zig");
const git_worker_mod = @import("../utils/git_worker.zig");
const extractJsonString = @import("stream_flow.zig").extractJsonString;
const isSensitivePath = @import("stream_flow.zig").isSensitivePath;
const ToolRunState = @import("app.zig").ToolRunState;
const kToolMaxTurns = @import("app.zig").kToolMaxTurns;

fn isBuiltinToolName(name: []const u8) bool {
    for (tool_registry_mod.builtinNames) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

/// Forward a tool call to the connected MCP server via tools/call.
/// The response envelope (`result.content[].text`) is flattened into a plain
/// string so the model receives the tool output rather than raw JSON-RPC.
pub fn callMcpTool(app: *App, name: []const u8, arguments: []const u8) []const u8 {
    const sess = &(app.mcp_session orelse return toolErr(app, "Error: no MCP session", .{}));
    const req = mcp_client_mod.buildToolsCall(app.alloc, 1, name, arguments) catch return toolErr(app, "Error: MCP call build failed", .{});
    defer app.alloc.free(req);
    const resp = sess.roundTrip(req, 8000) catch |e| return toolErr(app, "Error: MCP call: {s}", .{@errorName(e)});
    defer app.alloc.free(resp);

    var parsed = std.json.parseFromSlice(std.json.Value, app.alloc, resp, .{}) catch return app.alloc.dupe(u8, resp) catch "";
    defer parsed.deinit();
    const result = (parsed.value.object.get("result") orelse return app.alloc.dupe(u8, resp) catch "").object;
    const content = result.get("content") orelse return app.alloc.dupe(u8, resp) catch "";
    if (content != .array) return app.alloc.dupe(u8, resp) catch "";

    var out = std.ArrayList(u8).empty;
    defer out.deinit(app.alloc);
    for (content.array.items) |item| {
        if (item == .object) {
            if (item.object.get("text")) |t| {
                if (t == .string) {
                    if (out.items.len > 0) out.append(app.alloc, '\n') catch {};
                    out.appendSlice(app.alloc, t.string) catch {};
                    continue;
                }
            }
        }
        // Non-text item (image, resource link, …): keep the raw JSON so no
        // data is silently dropped from the model's view.
        const raw = std.json.fmt(item, .{});
        const frag = std.fmt.allocPrint(app.alloc, "{f}", .{raw}) catch continue;
        defer app.alloc.free(frag);
        if (out.items.len > 0) out.append(app.alloc, '\n') catch {};
        out.appendSlice(app.alloc, frag) catch {};
    }
    if (out.items.len == 0) return app.alloc.dupe(u8, resp) catch "";
    return out.toOwnedSlice(app.alloc) catch "";
}

pub fn runTool(app: *App, call: tools_mod.ToolCall, cwd: []const u8) []const u8 {
    // MCP tool forwarding: names outside the built-in set are routed to
    // the connected MCP server's tools/call.
    if (app.mcp_session != null and !isBuiltinToolName(call.name)) {
        return callMcpTool(app, call.name, call.arguments);
    }
    // Extra guards on top of the sandbox: dangerous shell commands and
    // sensitive paths are refused before anything executes.
    if (std.mem.eql(u8, call.name, "shell")) {
        if (extractJsonString(app, call.arguments, "command")) |cmd| {
            if (app.run_mode != .yolo) {
            if (dangerous_patterns.checkDangerousCommand(cmd)) |p| {
                return toolErr(app, "Error: blocked dangerous command ({s}). Prefer a direct command (e.g. 'ls' instead of 'sh -c \"ls\"')", .{p.description});
            }
            // Execute through the worker process (pipe I/O, 30s timeout,
            // kill on hang) so a long-running command can never freeze
            // the UI indefinitely.
            if (app.git_worker) |*gw| {
                if (gw.runShell(app.alloc, cwd, cmd)) |out| {
                    return out;
                }
                return toolErr(app, "Error: shell execution failed or timed out", .{});
            }
        }
    }
    }
    if (std.mem.eql(u8, call.name, "file_read") or
        std.mem.eql(u8, call.name, "file_write") or
        std.mem.eql(u8, call.name, "file_edit"))
    {
        if (extractJsonString(app, call.arguments, "path")) |path| {
            if (isSensitivePath(path)) {
                return toolErr(app, "Error: blocked sensitive path", .{});
            }
        }
    }

    // Recovery guardrail (Reasonix borrow): consecutive tool failures
    // stop the tool to avoid a retry loop.
    const res = tools_mod.executeTool(app.alloc, app.sandbox, cwd, call) catch {
        app.tool_fail_streak += 1;
        if (app.tool_fail_streak >= 3) {
            app.tool_fail_streak = 0;
            app.setNotification("Tool failed 3x in a row — stopped (use /clear to reset)");
        }
        return toolErr(app, "Error: tool execution failed", .{});
    };
    // ToolResult.output is allocator-owned when non-empty, static "" on error.
    app.tool_fail_streak = 0;
    if (res.output.len > 0) {
        const owned = app.alloc.dupe(u8, res.output) catch "";
        app.alloc.free(res.output);
        return owned;
    }
    return toolErr(app, "Error: {s}", .{res.err_msg orelse "tool failed"});
}

/// Allocate an error/status string owned by the caller (freed by
/// handleToolCalls). Returns an empty slice on allocation failure —
/// callers must not free empty results.
pub fn toolErr(app: *App, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(app.alloc, fmt, args) catch "";
}

pub fn processNextTool(app: *App) void {
    const tr = app.tool_run orelse return;
    if (tr.idx >= tr.calls.items.len) {
        finishToolRun(app, );
        return;
    }
    const call = tr.calls.items[tr.idx];
    app.onToolStart(call.name, call.arguments, call.id);

    const approval_needed = switch (app.run_mode) {
        .auto => tools_mod.requiresApproval(app.sandbox, call),
        .plan => true,
        .yolo => false,
    };
    if (approval_needed) {
        const cwd_ptr = std.c.getenv("PWD") orelse ".";
        const cwd = std.mem.sliceTo(cwd_ptr, 0);
        app.pending_tool = .{
            .idx = tr.idx,
            .cwd = app.alloc.dupe(u8, cwd) catch return,
        };
        app.setNotification("Tool approval required — Enter to allow, Esc to deny");
        return;
    }

    executeCurrentTool(app, );
}

pub fn executeCurrentTool(app: *App) void {
    const tr = app.tool_run orelse return;
    const call = tr.calls.items[tr.idx];
    const cwd_ptr = std.c.getenv("PWD") orelse ".";
    const cwd = std.mem.sliceTo(cwd_ptr, 0);

    const result = runTool(app, call, cwd);
    defer {
        if (result.len > 0) app.alloc.free(result);
    }
    const success = result.len > 0 and !std.mem.startsWith(u8, result, "Error:");
    app.onToolOutput(call.name, result, success);

    tr.results.appendSlice(app.alloc, "Tool ") catch {};
    tr.results.appendSlice(app.alloc, call.name) catch {};
    tr.results.appendSlice(app.alloc, " result:\n") catch {};
    tr.results.appendSlice(app.alloc, result) catch {};
    tr.results.appendSlice(app.alloc, "\n\n") catch {};

    tr.idx += 1;
    processNextTool(app, );
}

pub fn approvePendingTool(app: *App) void {
    const pt = app.pending_tool orelse return;
    app.alloc.free(pt.cwd);
    app.pending_tool = null;
    executeCurrentTool(app, );
}

pub fn rejectPendingTool(app: *App) void {
    const pt = app.pending_tool orelse return;
    const tr = app.tool_run orelse return;
    const call = tr.calls.items[pt.idx];
    const denied = toolErr(app, "Rejected by user", .{});
    defer app.alloc.free(denied);
    app.onToolOutput(call.name, denied, false);
    tr.results.appendSlice(app.alloc, "Tool ") catch {};
    tr.results.appendSlice(app.alloc, call.name) catch {};
    tr.results.appendSlice(app.alloc, " result:\nRejected by user\n\n") catch {};
    app.alloc.free(pt.cwd);
    app.pending_tool = null;
    tr.idx += 1;
    processNextTool(app, );
}

/// All calls executed (or rejected) — re-submit the accumulated results.
pub fn finishToolRun(app: *App) void {
    const tr = app.tool_run orelse return;
    if (tr.results.items.len > 0) {
        const result_text = app.alloc.dupe(u8, tr.results.items) catch return;
        app.messages.append(app.alloc, .{
            .role = .tool,
            .content = result_text,
            .tool_call_id = if (tr.calls.items.len > 0) tr.calls.items[0].id else "",
            .owns = true,
        }) catch {};

        // Start a new stream with the tool results in context
        app.startStreaming("(tool results)", "");
    }
    // Cleanup run state
    for (tr.calls.items) |c| {
        if (c.id.len > 0) app.alloc.free(c.id);
        app.alloc.free(c.name);
        app.alloc.free(c.arguments);
    }
    tr.calls.deinit(app.alloc);
    tr.results.deinit(app.alloc);
    app.alloc.destroy(tr);
    app.tool_run = null;
}

pub fn handleToolCalls(app: *App, tc_json: []const u8) void {
    var pipeline = stream_client_mod.ToolCallRepairPipeline.init(app.alloc);
    defer pipeline.deinit();

    const parse_result = pipeline.processChunk(tc_json) catch return;
    defer {
        for (parse_result.calls) |call| {
            app.alloc.free(call.name);
            app.alloc.free(call.arguments);
            app.alloc.free(call.signature);
        }
        app.alloc.free(parse_result.calls);
    }

    if (parse_result.calls.len == 0) return;

    // Hard iteration cap on the tool loop: the model may re-request tools
    // every turn, and an unbounded cycle would burn tokens forever. The counter
    // resets on each real user message (see App.startStreaming).
    if (app.tool_turn_count >= kToolMaxTurns) {
        app.setNotification("Tool loop reached its cap — stopping to avoid an endless cycle");
        return;
    }
    app.tool_turn_count += 1;

    // Duplicate calls into a run state that survives approval pauses.
    const tr = app.alloc.create(ToolRunState) catch return;
    tr.* = .{
        .calls = std.ArrayList(tools_mod.ToolCall).empty,
        .idx = 0,
        .results = std.ArrayList(u8).empty,
    };
    for (parse_result.calls) |call| {
        const id = app.alloc.dupe(u8, call.id) catch continue;
        const name = app.alloc.dupe(u8, call.name) catch {
            app.alloc.free(id);
            continue;
        };
        const arguments = app.alloc.dupe(u8, call.arguments) catch {
            app.alloc.free(id);
            app.alloc.free(name);
            continue;
        };
        tr.calls.append(app.alloc, .{ .index = call.index, .id = id, .name = name, .arguments = arguments }) catch {
            app.alloc.free(id);
            app.alloc.free(name);
            app.alloc.free(arguments);
        };
    }
    if (tr.calls.items.len == 0) {
        app.alloc.destroy(tr);
        return;
    }
    app.tool_run = tr;

    processNextTool(app);
}
