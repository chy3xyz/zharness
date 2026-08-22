//! Slash-command handling — split out of app.zig (submit path).

const std = @import("std");
const zz = @import("zigzag");
const App = @import("app.zig").App;
const OutputData = App.OutputData;
const RunMode = @import("app.zig").RunMode;
const stream_client_mod = @import("../net/stream_client.zig");
const mcp_runner_mod = @import("../net/mcp_runner.zig");
const mcp_client_mod = @import("../net/mcp_client.zig");
const dangerous_patterns = @import("../utils/dangerous_patterns.zig");
const tools_mod = @import("../tools/mod.zig");
const session_format = @import("../storage/session_format.zig");
const SlashDispatcher = @import("slash_command_dispatcher.zig");
const memory_mod = @import("../cache/memory.zig");
const git_worker_mod = @import("../utils/git_worker.zig");
const render_ui = @import("render_ui.zig");
const sessions = @import("sessions.zig");
const agent_flow = @import("agent_flow.zig");

/// Read a file into a caller-owned buffer (raw syscalls), or null if unreadable.
fn readNoteFile(alloc: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(alloc, buf[0..@intCast(n)]) catch return null;
    }
    return out.toOwnedSlice(alloc) catch null;
}

/// Handle the inline slash commands in the submit path. Returns true if the
/// input was consumed as a command.
pub fn handleSlashCommand(app: *App, text_slice: []const u8) bool {
    if (std.mem.eql(u8, text_slice, "/rewind")) {
        app.text_input.setValue("") catch {};
        app.text_input.cursor = 0;
        var removed: usize = 0;
        while (app.messages.items.len > 0) {
            const last = app.messages.items[app.messages.items.len - 1];
            if (last.role == .user and removed > 0) break;
            // Free owned content and pop.
            if (last.owns) {
                app.alloc.free(last.content);
                if (last.tool_call_id.len > 0) app.alloc.free(last.tool_call_id);
            }
            _ = app.messages.pop();
            removed += 1;
            if (last.role == .user) break;
        }
        app.setNotification(if (removed > 0) "Rewound one turn" else "Nothing to rewind");
        return true;
    }

    // /skills: list registered skills; /skill <name>: activate (prompt inject).
    if (std.mem.eql(u8, text_slice, "/skills")) {
        app.text_input.setValue("") catch {};
        app.text_input.cursor = 0;
        var list_buf = std.ArrayList(u8).empty;
        defer list_buf.deinit(app.alloc);
        if (app.skill_registry) |reg| {
            for (reg.list()) |sk| {
                list_buf.appendSlice(app.alloc, sk.name) catch {};
                list_buf.appendSlice(app.alloc, "  ") catch {};
                list_buf.appendSlice(app.alloc, sk.description) catch {};
                list_buf.appendSlice(app.alloc, "\n") catch {};
            }
        }
        app.setNotification(if (list_buf.items.len > 0) list_buf.items else "No skills registered");
        return true;
    }
    if (std.mem.eql(u8, text_slice, "/mcp")) {
        app.text_input.setValue("") catch {};
        app.text_input.cursor = 0;
        var info_buf = std.ArrayList(u8).empty;
        defer info_buf.deinit(app.alloc);
        // Lazy-load ~/.zeepseek/mcp.json ({"servers":[{"name","command"}]}).
        if (app.mcp_servers.items.len == 0) {
            var cfg_buf: [4096]u8 = undefined;
            var cfg_len: usize = 0;
            if (std.c.getenv("HOME")) |home_z| {
                const home = std.mem.sliceTo(home_z, 0);
                var path_buf: [512:0]u8 = undefined;
                if (std.fmt.bufPrintSentinel(&path_buf, "{s}/.zeepseek/mcp.json", .{home}, 0)) |pb| {
                    const fd = std.c.open(pb, std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
                    if (fd >= 0) {
                        defer _ = std.c.close(fd);
                        const rlen = std.c.read(fd, &cfg_buf, @as(usize, cfg_buf.len));
                        cfg_len = if (rlen > 0) @intCast(rlen) else 0;
                    }
                } else |_| {}
            }
            if (cfg_len > 0) {
                var parsed = std.json.parseFromSlice(std.json.Value, app.alloc, cfg_buf[0..cfg_len], .{}) catch null;
                if (parsed) |pdoc| {
                    defer parsed.?.deinit();
                    if (pdoc.value.object.get("servers")) |arr| {
                        if (arr == .array) {
                            for (arr.array.items) |srv| {
                                const obj = srv.object;
                                const nm = if (obj.get("name")) |v| (if (v == .string) v.string else "?") else "?";
                                const cmd = if (obj.get("command")) |v| (if (v == .string) v.string else "") else "";
                                if (cmd.len > 0) {
                                    var arg_list = std.ArrayList([]const u8).empty;
                                    if (obj.get("args")) |av| {
                                        if (av == .array) {
                                            for (av.array.items) |a| {
                                                if (a == .string) arg_list.append(app.alloc, a.string) catch {};
                                            }
                                        }
                                    }
                                    const args_owned = arg_list.toOwnedSlice(app.alloc) catch &.{};
                                    app.mcp_servers.append(app.alloc, .{ .cfg_name = nm, .command = cmd, .args = args_owned }) catch {};
                                }
                            }
                        }
                    }
                }
            }
        }
        if (app.mcp_servers.items.len == 0) {
            app.setNotification("No MCP servers in ~/.zeepseek/mcp.json");
            return true;
        }
        for (app.mcp_servers.items) |srv| {
            info_buf.appendSlice(app.alloc, srv.cfg_name) catch {};
            info_buf.appendSlice(app.alloc, ": ") catch {};
            info_buf.appendSlice(app.alloc, srv.command) catch {};
            info_buf.appendSlice(app.alloc, "\n") catch {};
        }
        if (app.mcp_session == null) {
            app.mcp_session = mcp_runner_mod.McpSession.spawn(app.app_io, app.alloc, app.mcp_servers.items[0]) catch |e| {
                info_buf.appendSlice(app.alloc, " spawn error: ") catch {};
                info_buf.appendSlice(app.alloc, @errorName(e)) catch {};
                app.setNotification(info_buf.items);
                return true;
            };
        }
        const req = mcp_client_mod.buildInitialize(app.alloc, 1) catch return true;
        defer app.alloc.free(req);
        const resp = app.mcp_session.?.roundTrip(req, 4000) catch |e| {
            info_buf.appendSlice(app.alloc, " init error: ") catch {};
            info_buf.appendSlice(app.alloc, @errorName(e)) catch {};
            app.setNotification(info_buf.items);
            return true;
        };
        defer app.alloc.free(resp);
        info_buf.appendSlice(app.alloc, " init ok\n") catch {};
        const tl_req = mcp_client_mod.buildToolsList(app.alloc, 2) catch return true;
        defer app.alloc.free(tl_req);
        const tl_resp = app.mcp_session.?.roundTrip(tl_req, 4000) catch |e| {
            info_buf.appendSlice(app.alloc, " tools/list error: ") catch {};
            info_buf.appendSlice(app.alloc, @errorName(e)) catch {};
            app.setNotification(info_buf.items);
            return true;
        };
        defer app.alloc.free(tl_resp);
        // Parse MCP tools into OpenAI-format definitions for the model.
        var mcp_tools = std.ArrayList(u8).empty;
        defer mcp_tools.deinit(app.alloc);
        var parsed_tl = std.json.parseFromSlice(std.json.Value, app.alloc, tl_resp, .{}) catch null;
        if (parsed_tl) |pdoc| {
            defer parsed_tl.?.deinit();
            if (pdoc.value.object.get("result")) |res| {
                if (res.object.get("tools")) |tarr| {
                    if (tarr == .array) {
                        var first = true;
                        for (tarr.array.items) |t| {
                            if (t != .object) continue;
                            const obj = t.object;
                            const nm = if (obj.get("name")) |v| (if (v == .string) v.string else "") else "";
                            if (nm.len == 0) continue;
                            const desc = if (obj.get("description")) |v| (if (v == .string) v.string else "") else "";
                            const name_json = std.fmt.allocPrint(app.alloc, "{f}", .{std.json.fmt(nm, .{})}) catch continue;
                            defer app.alloc.free(name_json);
                            const desc_json = std.fmt.allocPrint(app.alloc, "{f}", .{std.json.fmt(desc, .{})}) catch continue;
                            defer app.alloc.free(desc_json);
                            if (!first) mcp_tools.appendSlice(app.alloc, ",") catch {};
                            first = false;
                            mcp_tools.appendSlice(app.alloc, "{\"type\":\"function\",\"function\":{\"name\":") catch {};
                            mcp_tools.appendSlice(app.alloc, name_json) catch {};
                            mcp_tools.appendSlice(app.alloc, ",\"description\":") catch {};
                            mcp_tools.appendSlice(app.alloc, desc_json) catch {};
                            mcp_tools.appendSlice(app.alloc, ",\"parameters\":") catch {};
                            if (obj.get("inputSchema")) |schema_v| {
                                const schema_json = std.fmt.allocPrint(app.alloc, "{f}", .{std.json.fmt(schema_v, .{})}) catch continue;
                                defer app.alloc.free(schema_json);
                                mcp_tools.appendSlice(app.alloc, schema_json) catch {};
                            } else {
                                mcp_tools.appendSlice(app.alloc, "{\"type\":\"object\"}") catch {};
                            }
                            mcp_tools.appendSlice(app.alloc, "}}") catch {};
                        }
                    }
                }
            }
        }
        if (app.mcp_tools_json.len > 0) app.alloc.free(app.mcp_tools_json);
        app.mcp_tools_json = mcp_tools.toOwnedSlice(app.alloc) catch "";
        info_buf.appendSlice(app.alloc, "tools: ") catch {};
        info_buf.appendSlice(app.alloc, tl_resp[0..@min(tl_resp.len, 400)]) catch {};
        app.setNotification(info_buf.items);
        return true;
    }

    if (std.mem.startsWith(u8, text_slice, "/skill ")) {
        const arg_slice = std.mem.trim(u8, text_slice["/skill ".len..], " ");
        // /skill install <owner>/<repo>: clone + register a GitHub-hosted skill.
        if (std.mem.startsWith(u8, arg_slice, "install ")) {
            const spec = std.mem.trim(u8, arg_slice["install ".len..], " ");
            app.text_input.setValue("") catch {};
            app.text_input.cursor = 0;
            const sep = std.mem.indexOfScalar(u8, spec, '/') orelse {
                app.setNotification("Usage: /skill install <owner>/<repo>");
                return true;
            };
            if (sep == 0 or sep + 1 >= spec.len) {
                app.setNotification("Usage: /skill install <owner>/<repo>");
                return true;
            }
            const owner = spec[0..sep];
            const repo = spec[sep + 1 ..];
            const reg = app.skill_registry orelse {
                app.setNotification("Skill registry unavailable");
                return true;
            };
            const gw: ?*git_worker_mod.Client = if (app.git_worker) |_| &app.git_worker.? else null;
            const installed = reg.installFromGithub(
                gw,
                app.app_io,
                owner,
                repo,
                "",
            ) catch |e| {
                app.setNotification(std.fmt.allocPrint(app.alloc, "Skill install failed: {s}", .{@errorName(e)}) catch "");
                return true;
            };
            defer app.alloc.free(installed);
            app.setNotification(std.fmt.allocPrint(app.alloc, "Installed skill: {s}", .{installed}) catch "");
            return true;
        }
        const name = app.alloc.dupe(u8, arg_slice) catch null;
        defer if (name) |n| app.alloc.free(n);
        app.text_input.setValue("") catch {};
        app.text_input.cursor = 0;
        var found = false;
        if (name) |n| {
            if (app.skill_registry) |reg| {
                if (reg.findByName(n) != null or reg.findByCommand(n) != null) {
                    const owned = app.alloc.dupe(u8, n) catch null;
                    if (owned) |o| {
                        if (app.active_skill.len > 0) app.alloc.free(app.active_skill);
                        app.active_skill = o;
                    }
                    found = true;
                }
            }
        }
        const skill_msg = if (found)
            std.fmt.allocPrint(app.alloc, "Skill activated: {s}", .{name orelse ""}) catch ""
        else
            std.fmt.allocPrint(app.alloc, "Unknown skill: {s}", .{name orelse ""}) catch "";
        defer if (skill_msg.len > 0) app.alloc.free(skill_msg);
        app.setNotification(skill_msg);
        return true;
    }

    // /memory <fact>: add a long-term fact; /memory recall <q>: show matches.
    if (std.mem.startsWith(u8, text_slice, "/memory")) {
        const arg_slice = std.mem.trim(u8, text_slice["/memory".len..], " ");
        // Dupe BEFORE setValue("") — the input buffer is recycled below.
        const arg = app.alloc.dupe(u8, arg_slice) catch return true;
        defer app.alloc.free(arg);
        app.text_input.setValue("") catch {};
        app.text_input.cursor = 0;
        if (std.mem.startsWith(u8, arg, "recall ")) {
            const q = std.mem.trim(u8, arg["recall ".len..], " ");
            if (app.memory) |mem| {
                const recalled = mem.recall(q, 4, 1200);
                // recalled is allocated with memory's allocator (page_allocator).
                defer std.heap.page_allocator.free(recalled);
                app.setNotification(if (recalled.len > 0) recalled else "No memory matches");
            }
        } else if (arg.len > 0) {
            if (app.memory) |mem| {
                var mem_path_buf: [512:0]u8 = undefined;
                if (std.c.getenv("HOME")) |home_z| {
                    const home = std.mem.sliceTo(home_z, 0);
                    _ = std.fmt.bufPrintSentinel(&mem_path_buf, "{s}/.zeepseek/memory.md", .{home}, 0) catch null;
                    mem.add(mem_path_buf[0..], arg);
                    app.setNotification("Memory saved");
                }
            }
        } else {
            app.setNotification("Usage: /memory <fact> | /memory recall <query>");
        }
        return true;
    }

    // /mode auto|plan|yolo: switch tool execution mode.
    if (std.mem.startsWith(u8, text_slice, "/mode")) {
        const arg_dup = app.alloc.dupe(u8, std.mem.trim(u8, text_slice["/mode".len..], " ")) catch null;
        defer if (arg_dup) |ad| app.alloc.free(ad);
        const arg = arg_dup orelse "";
        app.text_input.setValue("") catch {};
        app.text_input.cursor = 0;
        const new_mode: ?RunMode = if (std.mem.eql(u8, arg, "plan"))
            .plan
        else if (std.mem.eql(u8, arg, "yolo"))
            .yolo
        else if (std.mem.eql(u8, arg, "auto") or arg.len == 0)
            .auto
        else
            null;
        if (new_mode) |m| {
            app.run_mode = m;
            const mode_msg = std.fmt.allocPrint(app.alloc, "Mode: {s}", .{@tagName(m)}) catch "";
            defer if (mode_msg.len > 0) app.alloc.free(mode_msg);
            app.setNotification(mode_msg);
        } else {
            app.setNotification("Usage: /mode auto|plan|yolo");
        }
        return true;
    }

    // /note: add / list / clear persistent notes.
    if (std.mem.startsWith(u8, text_slice, "/note")) {
        const arg_slice = std.mem.trim(u8, text_slice["/note".len..], " ");
        const arg = app.alloc.dupe(u8, arg_slice) catch return true;
        defer app.alloc.free(arg);
        app.text_input.setValue("") catch {};
        app.text_input.cursor = 0;

        const home_z = std.c.getenv("HOME") orelse null;
        if (home_z == null) {
            app.setNotification("HOME not set");
            return true;
        }
        const home = std.mem.sliceTo(home_z.?, 0);
        var buf: [1024:0]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buf, "{s}/.zeepseek/notes.md", .{home}, 0) catch {
            app.setNotification("Note path too long");
            return true;
        };

        if (std.mem.eql(u8, arg, "clear")) {
            if (std.c.open(path.ptr, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0)) != -1) {
                _ = std.c.unlink(path.ptr);
            }
            app.setNotification("Notes cleared");
            return true;
        }

        if (std.mem.startsWith(u8, arg, "add ")) {
            const body = std.mem.trim(u8, arg["add ".len..], " ");
            if (body.len == 0) {
                app.setNotification("Empty note ignored — usage: /note add <text>");
                return true;
            }
            var dir_buf: [512:0]u8 = undefined;
            _ = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.zeepseek", .{home}, 0) catch return true;
            _ = std.c.mkdir(&dir_buf, 0o755);
            const existing_owned = readNoteFile(app.alloc, &buf);
            defer if (existing_owned) |e| app.alloc.free(e);
            const existing: []const u8 = existing_owned orelse "";
            var line = std.ArrayList(u8).empty;
            defer line.deinit(app.alloc);
            line.appendSlice(app.alloc, existing) catch {};
            if (existing.len > 0 and existing[existing.len - 1] != '\n') line.append(app.alloc, '\n') catch {};
            line.appendSlice(app.alloc, "- ") catch {};
            line.appendSlice(app.alloc, body) catch {};
            line.append(app.alloc, '\n') catch {};
            const flags = std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
            const fd = std.c.open(path.ptr, flags, @as(std.c.mode_t, 0o644));
            if (fd < 0) {
                app.setNotification("Cannot write notes");
                return true;
            }
            defer _ = std.c.close(fd);
            var off: usize = 0;
            while (off < line.items.len) {
                const n = std.c.write(fd, line.items.ptr + off, line.items.len - off);
                if (n <= 0) {
                    app.setNotification("Cannot write notes");
                    return true;
                }
                off += @intCast(n);
            }
            app.setNotification("Note saved");
            return true;
        }

        // /note list (default when not add/clear)
        const content_owned = readNoteFile(app.alloc, &buf);
        defer if (content_owned) |c| app.alloc.free(c);
        const raw: []const u8 = content_owned orelse "";
        const trimmed = std.mem.trim(u8, raw, "\n");
        if (trimmed.len == 0) {
            app.setNotification("No notes yet");
        } else {
            const suffix: []const u8 = if (trimmed.len > 600) "\n…(truncated)" else "";
            const shown = std.fmt.allocPrint(app.alloc, "{s}{s}", .{ trimmed, suffix }) catch "";
            defer if (shown.len > 0) app.alloc.free(shown);
            app.setNotification(shown);
        }
        return true;
    }

    // /copy: copy the whole conversation (plain text) to the clipboard.
    if (std.mem.eql(u8, text_slice, "/copy") or std.mem.startsWith(u8, text_slice, "/copy ")) {
        app.text_input.setValue("") catch {};
        app.text_input.cursor = 0;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(app.alloc);
        for (app.messages.items) |m| {
            const role_str: []const u8 = switch (m.role) {
                .user => "You",
                .assistant => "Zeep",
                .system => "System",
                .tool => "Tool",
            };
            buf.appendSlice(app.alloc, role_str) catch break;
            buf.appendSlice(app.alloc, ": ") catch break;
            buf.appendSlice(app.alloc, m.content) catch break;
            buf.appendSlice(app.alloc, "\n\n") catch break;
        }
        if (app.git_worker) |*gw| {
            if (gw.copy(buf.items)) {
                app.setNotification("Conversation copied to clipboard");
            } else {
                app.setNotification("Copy failed");
            }
        } else {
            app.setNotification("Clipboard worker unavailable");
        }
        return true;
    }

    // /subagent <goal>: spawn a background research sub-agent. The panel
    // toggle is /subagents (handled by the dispatcher), so guard against
    // intercepting both when the user types the plural form.
    if (std.mem.eql(u8, text_slice, "/subagent") or std.mem.startsWith(u8, text_slice, "/subagent ")) {
        const goal = std.mem.trim(u8, text_slice["/subagent".len..], " ");
        app.text_input.setValue("") catch {};
        app.text_input.cursor = 0;
        agent_flow.startSubAgent(app, goal);
        return true;
    }

    return false;
}

/// Entry point used by the submit path, the palette, and the slash-prompt
/// overlay. Destructive commands are intercepted and routed to a confirmation
/// dialog (see `runSlashCommand` for the actual side effect).
pub fn executeSlashCommand(app: *App, id: []const u8, args: []const u8) void {
    if (SlashDispatcher.Dispatcher.needsConfirm(id)) {
        openConfirmSlash(app, id);
        return;
    }
    runSlashCommand(app, id, args);
}

/// Run a slash command after the confirmation gate has been satisfied.
pub fn runSlashCommand(app: *App, id: []const u8, args: []const u8) void {
    const ctx = SlashDispatcher.CommandContext{
        .allocator = app.alloc,
        .io = app.io,
        .provider = app.provider,
        .model = app.model,
        .subsystems_initialized = app.subsystems_initialized,
        .provider_mgr = &app.provider_mgr,
        .sandbox = if (app.sandbox) |s| s else null,
        .tokens_used = app.tokens_used,
        .ctx_max = app.ctx_max,
        .cache_hit_rate = app.cache_hit_rate,
        .session_id = app.session_id,
    };

    const result = SlashDispatcher.Dispatcher.execute(ctx, id, args) catch |err| {
        if (err == error.UnknownCommand) {
            const msg = std.fmt.allocPrint(app.alloc, "Unknown command: /{s}", .{id}) catch return;
            app.messages.append(app.alloc, .{ .role = .system, .content = msg, .timestamp = 0, .owns = true }) catch {
                app.alloc.free(msg);
                return;
            };
            return;
        }
        const msg = std.fmt.allocPrint(app.alloc, "Command error: {s}", .{@errorName(err)}) catch return;
        defer app.alloc.free(msg);
        app.setNotification(msg);
        return;
    };

    switch (result) {
        .none => {},

        .set_input => |text| {
            app.text_input.setValue(text) catch {};
            app.text_input.cursor = app.text_input.getValue().len;
            app.alloc.free(text);
        },

        .notify => |msg| {
            app.setNotification(msg);
            app.alloc.free(msg);
        },

        .quit => app.should_quit = true,
        .clear_chat => app.clearMessages(),
        .save_session => sessions.saveSession(app, if (args.len > 0) args else app.session_id),
        .load_session => sessions.loadSession(app, if (args.len > 0) args else app.session_id),
        .toggle_thinking => app.show_thinking = !app.show_thinking,
        .toggle_tools => app.toggleToolCollapse(),
        .toggle_subagents => app.show_subagents = !app.show_subagents,
        .scroll_top => {
            app.scroll_offset = 0;
            app.auto_scroll = false;
        },
        .scroll_bottom => {
            app.scroll_offset = 0;
            app.auto_scroll = true;
        },
        .compact_context => app.compactContext(),
        .show_help => {
            render_ui.updateHelpModal(app);
            app.help_modal.show();
        },

        .set_model => |name| {
            app.model = app.alloc.dupe(u8, name) catch app.model;
            if (app.subsystems_initialized) {
                if (app.provider_mgr.getActive()) |cfg| {
                    var new_cfg = cfg;
                    new_cfg.default_model = name;
                    app.provider_mgr.addProvider(new_cfg) catch {};
                }
            }
            const msg = std.fmt.allocPrint(app.alloc, "Model: {s} (via {s})", .{ name, app.provider }) catch return;
            defer app.alloc.free(msg);
            app.setNotification(msg);
            app.alloc.free(name);
        },

        .set_theme => |name| {
            app.setThemeByName(name);
            app.alloc.free(name);
        },

        .set_lang => |name| {
            app.i18n.setLocaleByName(name);
            app.alloc.free(name);
            const msg = std.fmt.allocPrint(app.alloc, "Language: {s}", .{app.i18n.localeName()}) catch return;
            defer app.alloc.free(msg);
            app.setNotification(msg);
        },

        .set_apikey => |key| {
            app.setApiKey(key);
            app.alloc.free(key);
            app.setNotification("API key set");
        },

        .set_provider => |name| {
            if (app.subsystems_initialized) {
                app.provider_mgr.setActive(name) catch {};
            }
            app.provider = app.alloc.dupe(u8, name) catch app.provider;
            const resolved_model = if (app.subsystems_initialized)
                app.provider_mgr.resolveModel(name)
            else
                @import("../providers/manager.zig").DefaultModel;
            app.model = app.alloc.dupe(u8, resolved_model) catch app.model;

            const title = std.fmt.allocPrint(app.alloc, "Enter API key for {s}", .{name}) catch return;
            app.alloc.free(name);
            openSlashPrompt(app, "apikey", title, "sk-...");
            app.alloc.free(title);
        },

        .prompt => |p| {
            const title = app.alloc.dupe(u8, p.title) catch return;
            const placeholder = app.alloc.dupe(u8, p.placeholder) catch {
                app.alloc.free(title);
                return;
            };
            app.alloc.free(p.title);
            app.alloc.free(p.placeholder);
            openSlashPrompt(app, id, title, placeholder);
        },

        .show_table => |t| {
            setSlashOutput(app, .{ .table = t });
        },

        .show_list => |l| {
            setSlashOutput(app, .{ .list = l });
        },

        .submenu => |m| {
            openSubMenu(app, m);
        },
    }
}

/// Render a second-level command menu using the palette component. The palette
/// clones every string, so the passed `SubMenu` can be freed immediately.
pub fn openSubMenu(app: *App, menu: SlashDispatcher.SubMenu) void {
    var cmds: std.ArrayList(zz.components.Command) = .empty;
    defer cmds.deinit(app.alloc);
    for (menu.items) |item| {
        cmds.append(app.alloc, .{
            .id = item.action,
            .label = item.label,
            .description = item.desc,
        }) catch break;
    }
    app.palette.setCommands(cmds.items) catch {};
    app.palette.clear() catch {};
    app.palette.open();
    app.submenu_active = true;
    SlashDispatcher.freeSubMenu(app.alloc, menu);
}

/// Restore the top-level "/" command list after a sub-menu was opened. Used
/// when Esc is pressed in a sub-menu: instead of dismissing everything, the
/// user returns one level up to the main command list.
pub fn restoreMainMenu(app: *App) void {
    var cmds: std.ArrayList(zz.components.Command) = .empty;
    defer cmds.deinit(app.alloc);
    for (SlashDispatcher.Dispatcher.commands()) |cmd| {
        cmds.append(app.alloc, .{
            .id = cmd.id,
            .label = cmd.label,
            .description = cmd.desc,
        }) catch break;
    }
    app.palette.setCommands(cmds.items) catch {};
    app.palette.clear() catch {};
    app.palette.open();
    app.submenu_active = false;
}

/// Route a sub-menu selection. `action` is the slash line stored on the item
/// (e.g. "/model deepseek-v4-pro", "/note list", "/memory recall ").
pub fn applySubmenuAction(app: *App, action: []const u8) void {
    const a = std.mem.trim(u8, action, " ");
    if (a.len == 0) return;
    const sp = std.mem.indexOfScalar(u8, a, ' ');
    const word_slice = if (sp) |i| a[0..i] else a;
    const rest = if (sp) |i| std.mem.trim(u8, a[i + 1 ..], " ") else "";
    const word = if (word_slice.len > 0 and word_slice[0] == '/') word_slice[1..] else word_slice;

    // Inline-only commands (handled in handleSlashCommand, not the Dispatcher)
    // are filled back into the input box so the user confirms with Enter. This
    // avoids re-dispatching them through the menu and re-opening it.
    if (std.mem.eql(u8, word, "memory") or
        std.mem.eql(u8, word, "note") or
        std.mem.eql(u8, word, "rewind") or
        std.mem.eql(u8, word, "mode") or
        std.mem.eql(u8, word, "copy") or
        std.mem.eql(u8, word, "mcp"))
    {
        const text = if (rest.len > 0)
            std.fmt.allocPrint(app.alloc, "/{s} {s}", .{ word, rest }) catch return
        else
            std.fmt.allocPrint(app.alloc, "/{s} ", .{word}) catch return;
        return setInputText(app, text);
    }

    if (std.mem.eql(u8, word, "skill")) {
        if (rest.len > 0) {
            const full = std.fmt.allocPrint(app.alloc, "/skill {s}", .{rest}) catch return;
            _ = handleSlashCommand(app, full);
            app.alloc.free(full);
        } else {
            setInputText(app, "/skill ");
        }
        return;
    }

    runSlashCommand(app, word, rest);
}

fn setInputText(app: *App, text: []const u8) void {
    app.text_input.setValue(text) catch {
        app.alloc.free(text);
        return;
    };
    app.text_input.cursor = text.len;
    app.alloc.free(text);
}

pub fn openSlashPrompt(app: *App, cmd_id: []const u8, title: []const u8, placeholder: []const u8) void {
    if (app.slash_awaiting_cmd) |old| app.alloc.free(old);
    if (app.slash_prompt_title) |old| app.alloc.free(old);
    if (app.slash_prompt_placeholder) |old| app.alloc.free(old);

    app.slash_awaiting_cmd = app.alloc.dupe(u8, cmd_id) catch return;
    app.slash_prompt_title = app.alloc.dupe(u8, title) catch return;
    app.slash_prompt_placeholder = app.alloc.dupe(u8, placeholder) catch return;

    app.slash_prompt_input.setValue("") catch {};
    app.slash_prompt_input.setPlaceholder(placeholder);
}

/// Show a destructive-command confirmation dialog using the ZigZag Modal
/// component (arrow keys navigate, Enter selects, shortkeys y/n act).
pub fn openConfirmSlash(app: *App, cmd_id: []const u8) void {
    if (app.confirm_modal.isVisible()) app.confirm_modal.hide();
    if (app.pending_confirm_cmd) |old| app.alloc.free(old);
    if (app.pending_confirm_body) |old| app.alloc.free(old);

    const body = std.fmt.allocPrint(app.alloc, "Run /{s}?\nThis action may be irreversible.", .{cmd_id}) catch "";
    app.pending_confirm_cmd = app.alloc.dupe(u8, cmd_id) catch {
        if (body.len > 0) app.alloc.free(body);
        return;
    };
    app.pending_confirm_body = if (body.len > 0) body else null;

    app.confirm_modal = zz.components.Modal.confirm("Confirm action", app.pending_confirm_body orelse "");
    app.confirm_modal.backdrop = .{};
    app.confirm_modal.show();
}

/// Release the pending confirmation and dismiss the dialog.
pub fn clearPendingConfirm(app: *App) void {
    if (app.pending_confirm_cmd) |s| app.alloc.free(s);
    if (app.pending_confirm_body) |s| app.alloc.free(s);
    app.pending_confirm_cmd = null;
    app.pending_confirm_body = null;
    app.confirm_modal.hide();
}

pub fn closeSlashPrompt(app: *App) void {
    if (app.slash_awaiting_cmd) |s| app.alloc.free(s);
    if (app.slash_prompt_title) |s| app.alloc.free(s);
    if (app.slash_prompt_placeholder) |s| app.alloc.free(s);
    app.slash_awaiting_cmd = null;
    app.slash_prompt_title = null;
    app.slash_prompt_placeholder = null;
    app.slash_prompt_input.setValue("") catch {};
}

pub fn setSlashOutput(app: *App, data: OutputData) void {
    if (app.slash_output_data) |*old| {
        old.deinit(app.alloc);
    }
    app.slash_output_data = data;

    app.slash_output_title = switch (data) {
        .table => |t| t.title,
        .list => |l| l.title,
    };
    app.slash_output_active = true;
}

pub fn closeSlashOutput(app: *App) void {
    app.slash_output_active = false;
    if (app.slash_output_data) |*d| {
        d.deinit(app.alloc);
        app.slash_output_data = null;
    }
}
