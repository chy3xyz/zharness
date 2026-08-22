//! Session persistence (save/load/list) — split out of app.zig.

const std = @import("std");
const App = @import("app.zig").App;
const Role = @import("app.zig").Role;
const session_format = @import("../storage/session_format.zig");

pub fn saveSession(app: *App, name: []const u8) void {
    if (!isValidSessionName(name)) {
        app.setNotification("Invalid session name (letters, digits, - and _ only)");
        return;
    }
    const home_ptr = std.c.getenv("HOME") orelse return;
    const home = std.mem.sliceTo(home_ptr, 0);
    if (home.len == 0) return;
    // Ensure dirs exist (mkdir is not recursive; both levels needed)
    var home_dir_buf: [512:0]u8 = undefined;
    _ = std.fmt.bufPrintSentinel(&home_dir_buf, "{s}/.zeepseek", .{home}, 0) catch return;
    _ = std.c.mkdir(&home_dir_buf, 0o755);
    var dir_buf: [512:0]u8 = undefined;
    _ = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.zeepseek/sessions", .{home}, 0) catch return;
    _ = std.c.mkdir(&dir_buf, 0o755);
    // Build file path
    var path_buf: [512:0]u8 = undefined;
    _ = std.fmt.bufPrintSentinel(&path_buf, "{s}/.zeepseek/sessions/{s}.txt", .{ home, name }, 0) catch return;
    // Serialize via the shared length-prefixed format
    var msgs = std.ArrayList(session_format.SerializedMessage).empty;
    defer msgs.deinit(app.alloc);
    for (app.messages.items) |m| {
        const role: session_format.Role = switch (m.role) {
            .user => .user, .assistant => .assistant, .system => .system, .tool => .tool,
        };
        msgs.append(app.alloc, .{ .role = role, .content = m.content }) catch {};
    }
    const blob = session_format.serialize(app.alloc, msgs.items) catch {
        app.setNotification("Save failed: serialization error");
        return;
    };
    defer app.alloc.free(blob);

    // Atomic write: tmp file + full write with error checks + fsync +
    // rename, so a crash never leaves a truncated/partial session file.
    var tmp_buf: [512:0]u8 = undefined;
    _ = std.fmt.bufPrintSentinel(&tmp_buf, "{s}/.zeepseek/sessions/.{s}.tmp", .{ home, name }, 0) catch return;
    const flags = std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.c.open(&tmp_buf, flags, @as(std.c.mode_t, 0o644));
    if (fd < 0) {
        app.setNotification("Save failed: cannot open session file");
        return;
    }
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < blob.len) {
        const n = std.c.write(fd, blob.ptr + off, blob.len - off);
        if (n <= 0) {
            app.setNotification("Save failed: write error");
            return;
        }
        off += @intCast(n);
    }
    _ = std.c.fsync(fd);
    if (std.c.rename(&tmp_buf, &path_buf) != 0) {
        app.setNotification("Save failed: rename error");
        return;
    }
    const note = std.fmt.allocPrint(app.alloc, "Session saved: {s}", .{name}) catch return;
    defer app.alloc.free(note);
    app.setNotification(note);
}

fn isValidSessionName(name: []const u8) bool {
    if (name.len == 0 or name.len > 100) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn setSessionName(app: *App, name: []const u8) void {
    if (!isValidSessionName(name)) return;
    const new = app.alloc.dupe(u8, name) catch return;
    if (app.session_id_alloc) |a| a.free(app.session_id);
    app.session_id = new;
    app.session_id_alloc = app.alloc;
}

pub fn loadSession(app: *App, name: []const u8) void {
    if (!isValidSessionName(name)) {
        app.setNotification("Invalid session name (letters, digits, - and _ only)");
        return;
    }
    const home_ptr = std.c.getenv("HOME") orelse return;
    const home = std.mem.sliceTo(home_ptr, 0);
    var path_buf: [512:0]u8 = undefined;
    _ = std.fmt.bufPrintSentinel(&path_buf, "{s}/.zeepseek/sessions/{s}.txt", .{ home, name }, 0) catch return;
    const fd = std.c.open(&path_buf, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        const msg = std.fmt.allocPrint(app.alloc, "No saved session \"{s}\"", .{name}) catch return;
        defer app.alloc.free(msg);
        app.messages.append(app.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
        return;
    }
    defer _ = std.c.close(fd);
    // Read entire file
    var data = std.ArrayList(u8).empty;
    defer data.deinit(app.alloc);
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &read_buf, read_buf.len);
        if (n <= 0) break;
        data.appendSlice(app.alloc, read_buf[0..@intCast(n)]) catch break;
    }
    // Parse via the shared module; parsed content ownership moves into
    // the message list (owns = true).
    const parsed = session_format.parse(app.alloc, data.items) catch return;
    defer app.alloc.free(parsed);
    app.clearMessages();
    for (parsed) |pm| {
        const role: Role = switch (pm.role) {
            .user => .user, .assistant => .assistant, .system => .system, .tool => .tool,
        };
        app.messages.append(app.alloc, .{
            .role = role,
            .content = pm.content,
            .owns = true,
        }) catch {};
    }
    setSessionName(app, name);
    app.auto_scroll = true;
    app.streaming_idx = null;
}

pub fn listSessions(app: *App) void {
    const home_ptr = std.c.getenv("HOME") orelse return;
    const home = std.mem.sliceTo(home_ptr, 0);
    var dir_buf: [512:0]u8 = undefined;
    _ = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.zeepseek/sessions", .{home}, 0) catch return;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app.alloc);
    out.appendSlice(app.alloc, "Saved sessions:\n") catch {};
    var dir = std.Io.Dir.openDirAbsolute(app.io, std.mem.sliceTo(&dir_buf, 0), .{}) catch {
        out.appendSlice(app.alloc, "  (no sessions directory yet)\n") catch {};
        const msg = app.alloc.dupe(u8, out.items) catch return;
        app.messages.append(app.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
        return;
    };
    defer dir.close(app.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(app.io) catch null) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.name, ".txt")) continue;
        const name = e.name[0 .. e.name.len - 4];
        if (name.len == 0) continue;
        out.appendSlice(app.alloc, "  ") catch {};
        out.appendSlice(app.alloc, name) catch {};
        out.appendSlice(app.alloc, "\n") catch {};
        count += 1;
    }
    if (count == 0) out.appendSlice(app.alloc, "  (none)\n") catch {};
    const msg = app.alloc.dupe(u8, out.items) catch return;
    app.messages.append(app.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
}

pub fn jumpToMatch(app: *App) void {
    const q = app.search_query.items;
    if (q.len == 0) return;
    app.auto_scroll = false;
    for (app.messages.items, 0..) |m, idx| {
        if (std.mem.indexOf(u8, m.content, q) != null) {
            app.scroll_offset = @intCast(idx);
            return;
        }
    }
}

