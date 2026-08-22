//! Streaming flow helpers — split out of app.zig.

const std = @import("std");
const App = @import("app.zig").App;
const app_mod = @import("app.zig");
const tools_run = @import("tools_run.zig");
const tokenizer_mod = @import("../utils/tokenizer.zig");

pub fn pollStream(app: *App) void {
    const ss = app.stream_state orelse return;

    // Drain content
    if (ss.drainContent(app.alloc)) |content| {
        defer app.alloc.free(content);
        onStreamContent(app, content);
    }

    // Drain reasoning
    if (ss.drainReasoning(app.alloc)) |reasoning| {
        defer app.alloc.free(reasoning);
        onStreamReasoning(app, reasoning);
    }

    // Check done
    if (ss.isDone()) {
        // Check for tool calls BEFORE marking done
        const has_tc = ss.has_tool_calls.load(.acquire);
        const tc_json = if (has_tc) ss.drainToolCallJson(app.alloc) else null;

        if (ss.error_msg) |msg| {
            onStreamError(app, msg);
            if (msg.len > 0) app.alloc.free(msg);
            ss.error_msg = null;
        } else if (tc_json != null) {
            // Handle tool calls — don't mark stream done yet
            tools_run.handleToolCalls(app, tc_json.?);
            app.alloc.free(tc_json.?);
            // Cleanup stream state but keep streaming_idx alive
            if (app.stream_thread) |t| {
                t.join();
                app.stream_thread = null;
            }
            ss.deinit();
            app.alloc.destroy(ss);
            app.stream_state = null;
            return;
        } else {
            onStreamDone(app);
        }
        // Cleanup
        if (app.stream_thread) |t| {
            t.join();
            app.stream_thread = null;
        }
        ss.deinit();
        app.alloc.destroy(ss);
        app.stream_state = null;
    }
}


/// Process the next queued tool call. Pauses at the first call that
/// requires user approval (pending_tool) and resumes on Enter/Esc.
/// Execute one tool through the unified tools/ pipeline with extra guards.
/// Returns a caller-owned string (empty slice on failure).

pub fn isSensitivePath(path: []const u8) bool {
const sensitive_dirs = [_][]const u8{ ".ssh", ".aws", ".gnupg", ".kube", ".config" };
const sensitive_files = [_][]const u8{ "id_rsa", "id_ed25519", "authorized_keys", "known_hosts", "shadow", "sudoers", "apikey" };
const sensitive_prefixes = [_][]const u8{ "/etc/", "/proc/", "/sys/", "/dev/", "/boot/", "/private/" };

var it = std.mem.splitScalar(u8, path, '/');
while (it.next()) |seg| {
    if (seg.len == 0) continue;
    for (sensitive_dirs) |d| {
        if (std.mem.eql(u8, seg, d)) return true;
    }
    for (sensitive_files) |f| {
        if (std.mem.eql(u8, seg, f)) return true;
    }
}
for (sensitive_prefixes) |p| {
    if (std.mem.startsWith(u8, path, p)) return true;
}
return false;
}

pub fn extractJsonString(_: *App, json: []const u8, key: []const u8) ?[]const u8 {
    // JSON string extractor: finds "key":"value" and stops at the *unescaped*
    // closing quote, so values containing \" or \\ are read in full.
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    if (std.mem.indexOf(u8, json, search)) |start| {
        const val_start = start + search.len;
        var i = val_start;
        while (i < json.len) : (i += 1) {
            if (json[i] == '\\') {
                i += 1; // skip the escaped character
            } else if (json[i] == '"') {
                return json[val_start..i];
            }
        }
    }
    return null;
}

test "extractJsonString handles escaped quotes in value" {
    // The App pointer is unused by the extractor; an undefined pointer is
    // safe because it is never dereferenced.
    const app_ptr: *App = undefined;
    const json = "{\"command\":\"echo \\\"hi\\\" && rm -rf /\"}";
    const cmd = extractJsonString(app_ptr, json, "command") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("echo \\\"hi\\\" && rm -rf /", cmd);
    const simple = extractJsonString(app_ptr, "{\"path\":\"/tmp/a b\"}", "path") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/tmp/a b", simple);
    try std.testing.expect(extractJsonString(app_ptr, "{}", "nope") == null);
}

pub fn onStreamContent(app: *App, text: []const u8) void {
    if (app.streaming_idx) |idx| {
        if (idx < app.messages.items.len) {
            const old = app.messages.items[idx].content;
            const new = std.mem.concat(app.alloc, u8, &.{ old, text }) catch return;
            if (app.messages.items[idx].owns and old.len > 0) app.alloc.free(old);
            app.messages.items[idx].content = new;
            app.messages.items[idx].owns = true;
        }
    } else {
        const idx = app.messages.items.len;
        const duped = app.alloc.dupe(u8, text) catch return;
        app.messages.append(app.alloc, .{
            .role = .assistant,
            .content = duped,
            .status = .streaming,
            .timestamp = @intCast(app_mod.monotonicNs()),
            .owns = true,
        }) catch return;
        app.streaming_idx = idx;
    }
    if (app.auto_scroll) app.scroll_offset = 0;
}

pub fn onStreamReasoning(app: *App, text: []const u8) void {
    if (app.streaming_idx) |idx| {
        if (idx < app.messages.items.len) {
            const old = app.messages.items[idx].thinking orelse "";
            const new = std.mem.concat(app.alloc, u8, &.{ old, text }) catch return;
            if (old.len > 0) app.alloc.free(old);
            app.messages.items[idx].thinking = new;
        }
    }
}

pub fn onStreamDone(app: *App) void {
    // Cache successful (non-tool) replies for exact-prompt reuse.
    if (app.reasonix) |rx| {
        if (app.streaming_idx) |si| {
            if (si > 0 and si < app.messages.items.len) {
                const user_msg = app.messages.items[si - 1];
                const asst_msg = app.messages.items[si];
                if (user_msg.role == .user and user_msg.content.len >= 15 and asst_msg.content.len > 0) {
                    rx.put(user_msg.content, asst_msg.content) catch {};
                }
            }
        }
    }
    if (app.streaming_idx) |idx| {
        if (idx < app.messages.items.len) {
            app.messages.items[idx].status = .complete;
        }
    }
    app.streaming_idx = null;
    app.turn += 1;

    // Auto-send the next queued input, if any (streaming/tool loop done).
    if (app.pending_inputs.items.len > 0) {
        const queued = app.pending_inputs.orderedRemove(0);
        app.messages.append(app.alloc, .{
            .role = .user,
            .content = queued,
            .timestamp = 0,
            .owns = true,
        }) catch {
            app.alloc.free(queued);
            return;
        };
        app.history_edit_idx = null;
        app.auto_scroll = true;
        app.turn += 1;
        if (app.api_key.len > 0) {
            app.startStreaming(queued, "");
        }
    }

    // One-shot context water-level hint (aligned with reasonix fold
    // thresholds): suggest /compact once the conversation passes 70%.
    if (!app.compact_hinted) {
        var total: usize = 0;
        for (app.messages.items) |m| total += tokenizer_mod.Tokenizer.count(m.content);
        if (app.ctx_max > 0) {
            const pct = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(app.ctx_max)) * 100.0;
            if (pct > 70) {
                const hint = std.fmt.allocPrint(app.alloc, "Context at {d:.0}% — run /compact to summarize", .{pct}) catch null;
                if (hint) |h| {
                    app.setNotification(h);
                    app.alloc.free(h);
                }
                app.compact_hinted = true;
            }
        }
    }
}

pub fn onStreamError(app: *App, err_msg: []const u8) void {
    if (app.streaming_idx) |idx| {
        if (idx < app.messages.items.len) {
            app.messages.items[idx].status = .failed;
            const old = app.messages.items[idx].content;
            const new = std.fmt.allocPrint(app.alloc, "{s}\n[Error: {s}]", .{ old, err_msg }) catch return;
            if (app.messages.items[idx].owns and old.len > 0) app.alloc.free(old);
            app.messages.items[idx].content = new;
            app.messages.items[idx].owns = true;
        }
    }
    app.streaming_idx = null;
}

pub fn pollCompact(app: *App) void {
    const run = app.compact_run orelse return;
    if (!run.isDone()) return;
    run.thread.join();
    const failed = run.failed.load(.acquire);
    const result = run.drainResult(app.alloc);
    defer {
        if (result) |r| app.alloc.free(r);
    }
    if (failed or result == null or result.?.len == 0) {
        app.setNotification("Compaction failed (check API key / network)");
    } else {
        applyCompact(app, run.keep_end, result.?);
    }
    run.deinit();
    std.heap.page_allocator.destroy(run);
    app.compact_run = null;
}

pub fn applyCompact(app: *App, keep_end: usize, summary: []const u8) void {
    const replaced = @min(keep_end, app.messages.items.len);
    // Free the compacted messages
    for (app.messages.items[0..replaced]) |*m| {
        if (m.owns and m.content.len > 0) app.alloc.free(m.content);
        if (m.thinking) |t| app.alloc.free(t);
        for (m.tool_calls.items) |tc| {
            app.freeToolCall(tc);
        }
        m.tool_calls.deinit(app.alloc);
    }
    for (0..replaced) |_| {
        _ = app.messages.orderedRemove(0);
    }
    // Insert the LLM summary as a system message
    const duped = app.alloc.dupe(u8, summary) catch return;
    app.messages.insert(app.alloc, 0, .{
        .role = .system,
        .content = duped,
        .owns = true,
        .status = .complete,
    }) catch {};
    app.setNotification("Context compacted via LLM summary");
}

// ═════════════════════════════════════════════════════════════════════
// View & Renderers — Claude CLI inspired layout
// ═════════════════════════════════════════════════════════════════════

