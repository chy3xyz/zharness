//! Pure ANSI layout helpers (no App state) — split out of app.zig.

const std = @import("std");
const zz = @import("zigzag");
const theme = @import("theme.zig");
const Pal = theme.Pal;
const R = Pal.R;
const B = Pal.B;
const D = Pal.D;
const U = Pal.U;
const I = "\x1b[3m";
const CodeBg = Pal.bg_code;
const CodeInlineBg = Pal.bg_code_inline;
const SearchHighlight = Pal.bg_highlight;
const App = @import("app.zig").App;
const render_text = @import("render_text.zig");
const join = zz.join;

pub fn padToCol(out: *std.ArrayList(u8), a: std.mem.Allocator, target: u16, used: usize) void {
    if (used < target) {
        var p = used;
        while (p < target) : (p += 1) { out.appendSlice(a, " ") catch {}; }
    }
}

pub fn enforceWidth(a: std.mem.Allocator, text: []const u8, target: u16) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try result.appendSlice(a, "\n");
        first = false;
        const line_w = zz.layout.measure.width(line);
        if (line_w > target) {
            const trunc = try zz.layout.measure.truncate(a, line, target);
            defer a.free(trunc);
            try result.appendSlice(a, trunc);
        } else {
            try result.appendSlice(a, line);
            var p = line_w;
            while (p < target) : (p += 1) { try result.appendSlice(a, " "); }
        }
    }
    return result.toOwnedSlice(a);
}

/// Return the last `target_h` lines of `text`, shifted up by `scroll_offset`
/// lines from the bottom. Pads with blank lines at the bottom so the result
/// always contains exactly `target_h` lines. This keeps the footer fixed.
pub fn clipFromBottom(a: std.mem.Allocator, text: []const u8, target_h: u16, scroll_offset: u16) ![]const u8 {
    if (target_h == 0) return try a.dupe(u8, "");
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    var list = std.ArrayList([]const u8).empty;
    defer list.deinit(a);
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| try list.append(a, line);

    const total = list.items.len;
    const th = @min(total, @as(usize, target_h));
    const max_offset = if (total > target_h) total - target_h else 0;
    const offset = @min(scroll_offset, max_offset);
    const end = total - offset;
    const start = if (end > th) end - th else 0;

    var result = std.ArrayList(u8).empty;
    defer result.deinit(a);
    for (start..end) |i| {
        if (i > start) try result.appendSlice(a, "\n");
        try result.appendSlice(a, list.items[i]);
    }
    var visible: usize = end - start;
    while (visible < target_h) : (visible += 1) {
        try result.appendSlice(a, "\n");
    }
    return result.toOwnedSlice(a);
}

/// Return the first `max_width` display columns of `str`, preserving any
/// ANSI escape sequences that appear before the cut-off point. Wide chars
/// are not split. No ellipsis is added.
pub fn ansiClip(a: std.mem.Allocator, str: []const u8, max_width: usize) ![]const u8 {
    if (max_width == 0) return try a.dupe(u8, "");
    var result = std.ArrayList(u8).empty;
    defer result.deinit(a);
    var w: usize = 0;
    var i: usize = 0;
    while (i < str.len and w < max_width) {
        const c = str[i];
        if (c == 0x1b) {
            const start = i;
            i += 1;
            if (i < str.len and str[i] == '[') {
                i += 1;
                while (i < str.len and !((str[i] >= 'A' and str[i] <= 'Z') or (str[i] >= 'a' and str[i] <= 'z'))) {
                    i += 1;
                }
                if (i < str.len) i += 1;
            } else if (i < str.len) {
                i += 1;
            }
            try result.appendSlice(a, str[start..i]);
            continue;
        }
        const byte_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + byte_len > str.len) {
            try result.appendSlice(a, str[i..]);
            break;
        }
        const cp = std.unicode.utf8Decode(str[i..][0..byte_len]) catch {
            try result.appendSlice(a, str[i..i + 1]);
            w += 1;
            i += 1;
            continue;
        };
        const cw = zz.unicode.charWidth(cp);
        if (w + cw > max_width) break;
        try result.appendSlice(a, str[i..i + byte_len]);
        w += cw;
        i += byte_len;
    }
    return result.toOwnedSlice(a);
}

/// ANSI-aware overlay: places `content` onto `base` at (x, y), preserving
/// escape sequences in both layers. Unlike zz.place.overlay, this does not
/// corrupt ANSI codes by indexing into their byte sequences.
pub fn ansiOverlay(a: std.mem.Allocator, base: []const u8, content: []const u8, x: usize, y: usize) ![]const u8 {
    const base_w = zz.layout.measure.maxLineWidth(base);
    const base_h = zz.layout.measure.height(base);
    const content_w = zz.layout.measure.maxLineWidth(content);
    const content_h = zz.layout.measure.height(content);

    var base_lines = std.ArrayList([]const u8).empty;
    defer base_lines.deinit(a);
    var base_iter = std.mem.splitScalar(u8, base, '\n');
    while (base_iter.next()) |line| try base_lines.append(a, line);

    var content_lines = std.ArrayList([]const u8).empty;
    defer content_lines.deinit(a);
    var content_iter = std.mem.splitScalar(u8, content, '\n');
    while (content_iter.next()) |line| try content_lines.append(a, line);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(a);

    var row: usize = 0;
    while (row < base_h) : (row += 1) {
        if (row > 0) try result.appendSlice(a, "\n");
        const base_line = if (row < base_lines.items.len) base_lines.items[row] else "";
        if (row < y or row >= y + content_h or content_lines.items.len == 0) {
            try result.appendSlice(a, base_line);
            continue;
        }
        const content_row = row - y;
        const content_line = if (content_row < content_lines.items.len) content_lines.items[content_row] else "";
        const content_line_w = zz.layout.measure.width(content_line);
        var overlay_w = if (content_line_w > content_w) content_line_w else content_w;
        const max_overlay_w = if (x < base_w) base_w - x else 0;
        if (overlay_w > max_overlay_w) overlay_w = max_overlay_w;

        // Prefix: base columns [0, x)
        const prefix = try ansiClip(a, base_line, x);
        defer a.free(prefix);
        // Suffix: base columns [x + overlay_w, base_w)
        const up_to_overlay_end = try ansiClip(a, base_line, x + overlay_w);
        defer a.free(up_to_overlay_end);
        const suffix = base_line[up_to_overlay_end.len..];

        // Pad content to the overlay width
        const padded_content = if (overlay_w > 0)
            try zz.layout.measure.padRight(a, content_line, overlay_w)
        else
            try a.dupe(u8, "");
        defer a.free(padded_content);

        try result.appendSlice(a, prefix);
        try result.appendSlice(a, R); // reset before overlay
        try result.appendSlice(a, padded_content);
        try result.appendSlice(a, R); // reset after overlay
        try result.appendSlice(a, suffix);

        // Ensure the output line visually matches base_w
        const out_w = zz.layout.measure.width(prefix) + overlay_w + zz.layout.measure.width(suffix);
        if (out_w < base_w) {
            var p = out_w;
            while (p < base_w) : (p += 1) try result.appendSlice(a, " ");
        }
    }

    return result.toOwnedSlice(a);
}

pub fn appendIntFn(out: *std.ArrayList(u8), a: std.mem.Allocator, val: anytype) void {
    if (std.fmt.allocPrint(a, "{d}", .{val})) |s| {
        defer a.free(s);
        out.appendSlice(a, s) catch {};
    } else |_| {}
}

pub fn appendFmtFn(out: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (std.fmt.allocPrint(a, fmt, args)) |s| {
        defer a.free(s);
        out.appendSlice(a, s) catch {};
    } else |_| {}
}

pub fn ansiVisibleLen(text: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and text[i] != 'm') : (i += 1) {}
            i += 1;
        } else {
            len += 1;
            i += 1;
        }
    }
}

pub fn renderSearchOverlay(app: *const App, lines: *std.ArrayList([]const u8), a: std.mem.Allocator, w: u16, h: u16) void {
    _ = h; _ = w;
    const bo = Pal.fg_dim;
    lines.append(a, std.fmt.allocPrint(a, "{s}┌─ Search ─────────────────────────────────────────┐{s}", .{ bo, R }) catch "") catch {};
    lines.append(a, std.fmt.allocPrint(a, "{s}│{s} {s}▸{s} {s}{s}{s}", .{ bo, R, Pal.yellow, R, Pal.fg, app.search_query.items, R }) catch "") catch {};
    lines.append(a, std.fmt.allocPrint(a, "{s}└────────────────────────────────────────────────────┘{s}", .{ bo, R }) catch "") catch {};
}

pub fn updateHelpModal(app: *App) void {
    app.help_modal.title = "Keybindings";
    app.help_modal.body =
        \\Ctrl+C      Quit
        \\Ctrl+P      Open command palette
        \\Ctrl+F      Search messages
        \\Ctrl+N      Toggle thinking display
        \\Ctrl+S      Toggle sub-agent panel
        \\Ctrl+T      Cycle color theme
        \\Ctrl+O      Message detail
        \\Enter       Send message
        \\Shift+Enter Newline in input
        \\↑/↓         Scroll / navigate
        \\/           Open command palette
        \\F1 / ?      Toggle this help
        \\Esc         Close overlay
    ;
}

pub fn updateDetailModal(app: *App) void {
    if (app.detail_idx >= app.messages.items.len) {
        app.detail_modal.title = "Message Detail";
        app.detail_modal.body = "";
        return;
    }
    const m = app.messages.items[app.detail_idx];
    app.detail_modal.title = std.fmt.allocPrint(app.alloc, "Message Detail ({d}/{d})", .{ app.detail_idx + 1, app.messages.items.len }) catch "Message Detail";
    app.detail_modal.body = m.content;
}

// ── Claude-style header: border box with title + model info ──

pub fn renderClaudeHeader(app: *const App, out: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
    const streaming = app.streaming_idx != null;
    const cell_w = if (w >= 2) w - 2 else 0;

    // Top border
    out.appendSlice(a, D) catch {};
    out.appendSlice(a, Pal.fg_dim) catch {};
    out.appendSlice(a, "┌") catch {};
    var c: u16 = 1;
    while (c < w - 1) : (c += 1) { out.appendSlice(a, "─") catch {}; }
    out.appendSlice(a, "┐") catch {};
    out.appendSlice(a, R) catch {};
    out.appendSlice(a, "\n") catch {};

    // Title row: left, center=model, right=status (+ ● generating)
    // Pre-compute the right segment so we know its visual width.
    const ctx_pct: f64 = if (app.ctx_max > 0) @as(f64, @floatFromInt(app.tokens_used)) / @as(f64, @floatFromInt(app.ctx_max)) * 100.0 else 0.0;
    var right_buf = std.ArrayList(u8).empty;
    right_buf.appendSlice(a, " ") catch {};
    if (streaming) {
        right_buf.appendSlice(a, Pal.red) catch {};
        right_buf.appendSlice(a, "● ") catch {};
        right_buf.appendSlice(a, R) catch {};
    }
    right_buf.appendSlice(a, Pal.fg_dim) catch {};
    right_buf.appendSlice(a, "turn ") catch {};
    right_buf.appendSlice(a, R) catch {};
    right_buf.appendSlice(a, Pal.yellow) catch {};
    appendIntFn(&right_buf, a, app.turn);
    right_buf.appendSlice(a, R) catch {};
    right_buf.appendSlice(a, D) catch {};
    right_buf.appendSlice(a, " ctx ") catch {};
    right_buf.appendSlice(a, R) catch {};
    // Context water level, color-banded to reasonix fold thresholds
    // (fold_warn 50 / aggressive 70 / exit 80): green <50, yellow 50-70,
    // orange 70-80, red >80.
    const ctx_color: []const u8 = if (ctx_pct > 80) Pal.red else if (ctx_pct > 70) Pal.orange else if (ctx_pct > 50) Pal.yellow else Pal.green;
    right_buf.appendSlice(a, ctx_color) catch {};
    appendFmtFn(&right_buf, a, "{d:.0}%", .{ctx_pct});
    right_buf.appendSlice(a, R) catch {};
    right_buf.appendSlice(a, D) catch {};
    right_buf.appendSlice(a, " cache ") catch {};
    right_buf.appendSlice(a, R) catch {};
    right_buf.appendSlice(a, Pal.cyan) catch {};
    appendFmtFn(&right_buf, a, "{d:.0}%", .{app.cacheHitRate() * 100.0});
    right_buf.appendSlice(a, R) catch {};
    if (streaming) {
        right_buf.appendSlice(a, " ") catch {};
        right_buf.appendSlice(a, B) catch {};
        right_buf.appendSlice(a, Pal.yellow) catch {};
        right_buf.appendSlice(a, "◐") catch {};
        right_buf.appendSlice(a, R) catch {};
    }
    const right_text = right_buf.toOwnedSlice(a) catch "";
    defer if (right_text.len > 0) a.free(right_text);
    const right_len = zz.layout.measure.width(right_text);

    const left_text = " zeepseek ";
    const left_len: u16 = 10;
    const model_len: u16 = @min(@as(u16, @intCast(app.model.len)), if (cell_w > left_len + right_len) cell_w - left_len - right_len else 0);

    // Distribute remaining space: center the model between left and right.
    const total_fixed = left_len + model_len + @as(u16, @intCast(right_len));
    const remaining = if (cell_w > total_fixed) cell_w - total_fixed else 0;
    const left_pad = remaining / 2;
    const right_pad = remaining - left_pad;

    out.appendSlice(a, D) catch {};
    out.appendSlice(a, "│") catch {};
    out.appendSlice(a, R) catch {};

    // Left: zeepseek
    out.appendSlice(a, B) catch {};
    out.appendSlice(a, Pal.yellow) catch {};
    out.appendSlice(a, left_text) catch {};
    out.appendSlice(a, R) catch {};

    // Center: model name
    out.appendSlice(a, D) catch {};
    var pad: u16 = 0;
    while (pad < left_pad) : (pad += 1) { out.appendSlice(a, " ") catch {}; }
    out.appendSlice(a, Pal.fg) catch {};
    if (model_len < app.model.len) {
        out.appendSlice(a, app.model[0..model_len]) catch {};
        out.appendSlice(a, "…") catch {};
    } else {
        out.appendSlice(a, app.model) catch {};
    }
    out.appendSlice(a, R) catch {};
    pad = 0;
    while (pad < right_pad) : (pad += 1) { out.appendSlice(a, " ") catch {}; }

    // Right: turn + ctx + cache
    out.appendSlice(a, right_text) catch {};

    out.appendSlice(a, D) catch {};
    out.appendSlice(a, "│") catch {};
    out.appendSlice(a, R) catch {};
    out.appendSlice(a, "\n") catch {};

    // Bottom border
    out.appendSlice(a, D) catch {};
    out.appendSlice(a, Pal.fg_dim) catch {};
    out.appendSlice(a, "└") catch {};
    c = 1;
    while (c < w - 1) : (c += 1) { out.appendSlice(a, "─") catch {}; }
    out.appendSlice(a, "┘") catch {};
    out.appendSlice(a, R) catch {};
}

// ── Claude-style input line ──

pub fn renderClaudeInput(app: *App, out: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
    out.appendSlice(a, D) catch {};
    out.appendSlice(a, "│ ") catch {};
    out.appendSlice(a, R) catch {};

    if (app.pending_tool != null) {
        app.text_input.setEchoMode(.normal);
        app.text_input.setPrompt("⚠ ");
        app.text_input.setPlaceholder(app.i18n.t().prompt_tool_approval);
    } else if (app.pending_action == .await_api_key) {
        app.text_input.setEchoMode(.password);
        app.text_input.setPrompt("🔑 ");
        app.text_input.setPlaceholder(app.i18n.t().prompt_api_key);
    } else if (app.streaming_idx != null) {
        app.text_input.setEchoMode(.normal);
        app.text_input.setPrompt("▸ ");
        // Input stays active during streaming; submissions are queued.
        app.text_input.setPlaceholder(app.i18n.t().prompt_queue);
    } else {
        app.text_input.setEchoMode(.normal);
        app.text_input.setPrompt("▸ ");
        app.text_input.setPlaceholder(app.i18n.t().prompt_placeholder);
    }

    // The caret is rendered by the TextInput component itself at the correct
    // cursor position; drive its blink gate each frame (set before view()).
    app.text_input.cursor_visible = app.cursor_visible;
    const input_view = app.text_input.view(a) catch "Error";
    defer if (input_view.ptr != "Error".ptr) a.free(input_view);
    const input_vis = zz.layout.measure.width(input_view);
    const max_input = if (w > 4) w - 4 else 0;
    const display_input = if (input_vis > max_input)
        (ansiClip(a, input_view, max_input) catch input_view)
    else
        input_view;
    defer if (display_input.ptr != input_view.ptr) a.free(display_input);
    out.appendSlice(a, display_input) catch {};

    // Pad to fill the cell (inside width is w - 2, leading "│ " consumes 2)
    const display_vis = zz.layout.measure.width(display_input);
    const pad_target = if (w > 3) w - 3 else 0;
    var p = display_vis;
    while (p < pad_target) : (p += 1) { out.appendSlice(a, " ") catch {}; }

    out.appendSlice(a, D) catch {};
    out.appendSlice(a, "│") catch {};
    out.appendSlice(a, R) catch {};
    out.appendSlice(a, "\n") catch {};
}

// ── Vertical separator between chat and sidebar ──

pub fn buildVerticalSeparator(app: *const App, a: std.mem.Allocator, h: u16) []const u8 {
    _ = app;
    var buf = std.ArrayList(u8).empty;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "│") catch {};
        buf.appendSlice(a, R) catch {};
        if (row + 1 < h) buf.appendSlice(a, "\n") catch {};
    }
    return buf.toOwnedSlice(a) catch "";
}

// ── Separator line ──

pub fn renderClaudeSeparator(app: *const App, out: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
    _ = app;
    out.appendSlice(a, D) catch {};
    out.appendSlice(a, "│") catch {};
    out.appendSlice(a, R) catch {};
    var c: u16 = 2;
    while (c < w) : (c += 1) { out.appendSlice(a, "─") catch {}; }
    out.appendSlice(a, "│") catch {};
    out.appendSlice(a, "\n") catch {};
}

// ── Claude-style status bar ──

pub fn renderClaudeStatus(app: *const App, out: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
    const streaming = app.streaming_idx != null;
    const spin = if (app.cursor_visible) "◐" else "◑";
    // The spinner is prepended to the regular shortcut/status hint instead
    // of replacing it, so the hint (and the sidebar stats) stay visible.
    const hint_full = if (streaming)
        (std.fmt.allocPrint(a, "{s} generating  {s}", .{ spin, "Ctrl+P palette  Ctrl+F search  Ctrl+S subagents  Ctrl+N thinking  Ctrl+C quit" }) catch "generating…")
    else
        "Ctrl+P palette  Ctrl+F search  Ctrl+S subagents  Ctrl+N thinking  Ctrl+C quit";
    defer if (streaming) a.free(@constCast(hint_full));
    const cell_w = if (w >= 2) w - 2 else 0;
    const content_w = if (cell_w > 1) cell_w - 1 else 0; // leading space

    out.appendSlice(a, D) catch {};
    out.appendSlice(a, "│") catch {};
    out.appendSlice(a, R) catch {};
    out.appendSlice(a, " ") catch {};
    out.appendSlice(a, Pal.fg_dim) catch {};

    // Truncate hint if the terminal is too narrow
    const hint = if (hint_full.len > content_w) hint_full[0..content_w] else hint_full;
    out.appendSlice(a, hint) catch {};

    var used: u16 = @as(u16, @intCast(1 + hint.len));
    while (used < cell_w) : (used += 1) { out.appendSlice(a, " ") catch {}; }
    out.appendSlice(a, D) catch {};
    out.appendSlice(a, "│") catch {};
    out.appendSlice(a, R) catch {};
}

// ── Claude-style chat rendering with markdown ──

pub fn renderClaudeChat(app: *const App, a: std.mem.Allocator, w: u16, h: u16) []const u8 {
    _ = h;
    var lines = std.ArrayList(u8).empty;
    defer lines.deinit(a);

    const total = app.messages.items.len;
    if (total == 0) {
        // Welcome / empty state
        renderClaudeWelcome(app, &lines, a, w);
        return lines.toOwnedSlice(a) catch "";
    }

    for (0..total) |i| {
        const m = &app.messages.items[i];
        const is_streaming = (app.streaming_idx == i);

        // Role label
        const role_color: []const u8 = switch (m.role) {
            .user => Pal.blue, .assistant => Pal.green, .system => Pal.mauve, .tool => Pal.yellow,
        };
        const role_label: []const u8 = switch (m.role) {
            .user => "You", .assistant => "Zeep", .system => "System", .tool => "Tool",
        };
        const spin = if (app.cursor_visible) " ◐" else " ◑";
        const status_icon: []const u8 = if (is_streaming) spin else "";

        lines.appendSlice(a, D) catch {};
        lines.appendSlice(a, "│") catch {};
        lines.appendSlice(a, R) catch {};
        lines.appendSlice(a, " ") catch {};
        lines.appendSlice(a, B) catch {};
        lines.appendSlice(a, role_color) catch {};
        lines.appendSlice(a, role_label) catch {};
        lines.appendSlice(a, R) catch {};
        if (status_icon.len > 0) {
            lines.appendSlice(a, D) catch {};
            lines.appendSlice(a, status_icon) catch {};
            lines.appendSlice(a, R) catch {};
        }
        lines.appendSlice(a, "  ") catch {};

        // Content — render markdown for assistant, plain for others
        if (m.content.len > 0) {
            if (m.role == .assistant) {
                renderClaudeMarkdownContent(app, &lines, a, m.content, w - 10);
            } else {
                renderClaudePlainContent(app, &lines, a, m.content, w - 10);
            }
        } else if (is_streaming) {
            lines.appendSlice(a, D) catch {};
            lines.appendSlice(a, Pal.fg_dim) catch {};
            lines.appendSlice(a, "(waiting...)") catch {};
            lines.appendSlice(a, R) catch {};
        }

        // Thinking collapse toggle (only for assistant with thinking)
        if (m.thinking) |th| {
            if (th.len > 0) {
                lines.appendSlice(a, "\n") catch {};
                lines.appendSlice(a, D) catch {};
                lines.appendSlice(a, "│   ") catch {};
                lines.appendSlice(a, R) catch {};
                const toggle_icon: []const u8 = if (m.think_collapsed) "▸" else "▾";
                lines.appendSlice(a, Pal.cyan) catch {};
                lines.appendSlice(a, toggle_icon) catch {};
                lines.appendSlice(a, " ") catch {};
                lines.appendSlice(a, Pal.fg_dim) catch {};
                if (m.think_collapsed) {
                    lines.appendSlice(a, "thinking...") catch {};
                } else {
                    lines.appendSlice(a, "thinking: ") catch {};
                    lines.appendSlice(a, Pal.orange) catch {};
                    lines.appendSlice(a, th) catch {};
                }
                lines.appendSlice(a, R) catch {};
            }
        }

        // Tool calls
        if (m.tool_calls.items.len > 0) {
            lines.appendSlice(a, "\n") catch {};
            lines.appendSlice(a, D) catch {};
            lines.appendSlice(a, "│   ") catch {};
            for (m.tool_calls.items) |tc| {
                const tc_icon: []const u8 = switch (tc.status) {
                    .running => "◐", .success => "✓", .failed => "✗",
                };
                const tc_clr: []const u8 = switch (tc.status) {
                    .running => Pal.yellow, .success => Pal.green, .failed => Pal.red,
                };
                lines.appendSlice(a, tc_clr) catch {};
                lines.appendSlice(a, tc_icon) catch {};
                lines.appendSlice(a, R) catch {};
                lines.appendSlice(a, " ") catch {};
                lines.appendSlice(a, Pal.tool_call) catch {};
                lines.appendSlice(a, tc.name) catch {};
                lines.appendSlice(a, R) catch {};
                lines.appendSlice(a, "  ") catch {};
            }
        }

        if (i + 1 < total) {
            // Faint separator line between messages.
            lines.appendSlice(a, "\n") catch {};
            lines.appendSlice(a, D) catch {};
            lines.appendSlice(a, Pal.fg_dim) catch {};
            lines.appendSlice(a, "  ············································") catch {};
            lines.appendSlice(a, R) catch {};
            lines.appendSlice(a, "\n") catch {};
        }
    }

    return lines.toOwnedSlice(a) catch "";
}

pub fn renderClaudeWelcome(app: *const App, lines: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
    _ = app; _ = w;
    lines.appendSlice(a, D) catch {};
    lines.appendSlice(a, "│") catch {};
    lines.appendSlice(a, R) catch {};
    lines.appendSlice(a, "\n") catch {};
    lines.appendSlice(a, D) catch {};
    lines.appendSlice(a, "│") catch {};
    lines.appendSlice(a, R) catch {};
    lines.appendSlice(a, "  ") catch {};
    lines.appendSlice(a, B) catch {};
    lines.appendSlice(a, Pal.yellow) catch {};
    lines.appendSlice(a, "zeepseek") catch {};
    lines.appendSlice(a, R) catch {};
    lines.appendSlice(a, D) catch {};
    lines.appendSlice(a, " — Claude CLI style TUI") catch {};
    lines.appendSlice(a, R) catch {};
    lines.appendSlice(a, "\n") catch {};
    lines.appendSlice(a, D) catch {};
    lines.appendSlice(a, "│") catch {};
    lines.appendSlice(a, R) catch {};
    lines.appendSlice(a, "  ") catch {};
    lines.appendSlice(a, D) catch {};
    lines.appendSlice(a, "Type a message to chat, or / for commands") catch {};
    lines.appendSlice(a, R) catch {};
    lines.appendSlice(a, "\n") catch {};
    lines.appendSlice(a, D) catch {};
    lines.appendSlice(a, "│") catch {};
    lines.appendSlice(a, R) catch {};
    lines.appendSlice(a, "\n") catch {};
    lines.appendSlice(a, D) catch {};
    lines.appendSlice(a, "│") catch {};
    lines.appendSlice(a, R) catch {};
    lines.appendSlice(a, "  ") catch {};
    lines.appendSlice(a, Pal.fg_dim) catch {};
    lines.appendSlice(a, "Ctrl+P palette   Ctrl+F search   Ctrl+S sub-agents   Ctrl+N thinking   / commands") catch {};
    lines.appendSlice(a, R) catch {};
    lines.appendSlice(a, "\n") catch {};
    lines.appendSlice(a, D) catch {};
    lines.appendSlice(a, "│") catch {};
    lines.appendSlice(a, R) catch {};
    lines.appendSlice(a, "  ") catch {};
    lines.appendSlice(a, D) catch {};
    lines.appendSlice(a, "Press Ctrl+P or / to open command palette") catch {};
    lines.appendSlice(a, R) catch {};
}

pub fn renderClaudeMarkdownContent(app: *const App, lines: *std.ArrayList(u8), a: std.mem.Allocator, content: []const u8, w: u16) void {
    _ = app;
    var buf = std.ArrayList(u8).empty;
    render_text.renderMarkdownAnsi(&buf, a, content, w);
    lines.appendSlice(a, buf.items) catch {};
    buf.deinit(a);
}

pub fn renderClaudePlainContent(app: *const App, lines: *std.ArrayList(u8), a: std.mem.Allocator, content: []const u8, w: u16) void {
    _ = app; _ = w;
    lines.appendSlice(a, Pal.fg) catch {};
    lines.appendSlice(a, content) catch {};
    lines.appendSlice(a, R) catch {};
}

// ── Claude-style right sidebar ──

pub fn renderClaudeSidebar(app: *const App, a: std.mem.Allocator, w: u16, h: u16) []const u8 {
    var lines = std.ArrayList(u8).empty;
    defer lines.deinit(a);

    const ctx_pct: f64 = if (app.ctx_max > 0) @as(f64, @floatFromInt(app.tokens_used)) / @as(f64, @floatFromInt(app.ctx_max)) * 100.0 else 0.0;
    const cache_pct: f64 = app.cacheHitRate() * 100.0;
    const streaming = app.streaming_idx != null;

    const rows = [_]struct { label: []const u8, value: []const u8, color: []const u8 }{
        .{ .label = "model", .value = app.model, .color = Pal.fg },
        .{ .label = "provider", .value = app.provider, .color = Pal.cyan },
        .{ .label = "turn", .value = "", .color = Pal.yellow },
        .{ .label = "context", .value = "", .color = if (ctx_pct > 70) Pal.red else Pal.green },
        .{ .label = "cache", .value = "", .color = Pal.cyan },
        .{ .label = "git", .value = "", .color = if (app.git_changes > 0) Pal.yellow else Pal.fg_dim },
        .{ .label = "mode", .value = @tagName(app.run_mode), .color = switch (app.run_mode) { .auto => Pal.green, .plan => Pal.yellow, .yolo => Pal.red } },
        .{ .label = "status", .value = if (streaming) "streaming" else "idle", .color = if (streaming) Pal.yellow else Pal.fg_dim },
    };

    var r: u16 = 0;
    while (r < h) : (r += 1) {
        lines.appendSlice(a, D) catch {};
        lines.appendSlice(a, "│") catch {};
        lines.appendSlice(a, R) catch {};
        lines.appendSlice(a, " ") catch {};

        if (r == 0) {
            // Title
            lines.appendSlice(a, B) catch {};
            lines.appendSlice(a, Pal.fg_dim) catch {};
            lines.appendSlice(a, "INFO") catch {};
            lines.appendSlice(a, R) catch {};
            padToCol(&lines, a, w - 2, 5); // leading space + "INFO"
        } else if (r - 1 < rows.len) {
            const row = rows[r - 1];
            lines.appendSlice(a, Pal.fg_dim) catch {};
            lines.appendSlice(a, row.label) catch {};
            lines.appendSlice(a, "  ") catch {};
            lines.appendSlice(a, R) catch {};
            lines.appendSlice(a, row.color) catch {};
            const val: []const u8 = if (row.value.len > 0) row.value else val: {
                if (std.mem.eql(u8, row.label, "turn")) {
                    break :val std.fmt.allocPrint(a, "{d}", .{app.turn}) catch "";
                } else if (std.mem.eql(u8, row.label, "git")) {
                    // Always allocate so the free on static strings never fires.
                    break :val if (app.git_changes > 0)
                        std.fmt.allocPrint(a, "{d} changed", .{app.git_changes}) catch a.dupe(u8, "clean") catch ""
                    else
                        a.dupe(u8, "clean") catch "";
                } else if (std.mem.eql(u8, row.label, "context")) {
                    break :val std.fmt.allocPrint(a, "{d:.0}%", .{ctx_pct}) catch "";
                } else if (std.mem.eql(u8, row.label, "cache")) {
                    break :val std.fmt.allocPrint(a, "{d:.0}%", .{cache_pct}) catch "";
                }
                break :val "";
            };
            defer if (row.value.len == 0 and val.len > 0) a.free(@constCast(val));
            lines.appendSlice(a, val) catch {};
            lines.appendSlice(a, R) catch {};
            const used = 1 + row.label.len + 2 + val.len; // leading space + label + gap + value
            padToCol(&lines, a, w - 2, used);
        } else {
            // Empty rows
            padToCol(&lines, a, w - 2, 1); // leading space only
        }

        lines.appendSlice(a, D) catch {};
        lines.appendSlice(a, "│") catch {};
        lines.appendSlice(a, R) catch {};
        if (r + 1 < h) lines.appendSlice(a, "\n") catch {};
    }

    return lines.toOwnedSlice(a) catch "";
}

pub fn renderClaudeSubAgentPanel(app: *const App, a: std.mem.Allocator, w: u16, h: u16) []const u8 {
    _ = h;
    const panel_w: u16 = @min(w, 48);
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(a);
    var owned = std.ArrayList([]const u8).empty;
    defer owned.deinit(a);
    defer for (owned.items) |s| if (s.len > 0) a.free(s);

    const bo = Pal.fg_dim;
    const title_owned = std.fmt.allocPrint(a, "{s}┌─ Sub-Agents {s}", .{ bo, R });
    const title: []const u8 = title_owned catch "";
    const top_pad = panel_w -| 15;
    var top_line = std.ArrayList(u8).empty;
    top_line.appendSlice(a, title) catch {};
    var i: u16 = 0;
    while (i < top_pad) : (i += 1) { top_line.appendSlice(a, "─") catch {}; }
    top_line.appendSlice(a, "┐") catch {};
    top_line.appendSlice(a, R) catch {};
    // top is line 0; on OOM it aliases title, so register exactly one of the
    // two for cleanup (the reusable defer loop would otherwise free twice).
    // A failed allocPrint leaves title as a non-freable literal "", and when
    // top aliases title owned's cleanup frees it once as well.
    const top = top_line.toOwnedSlice(a) catch title;
    owned.append(a, top) catch {};
    if (title_owned) |owned_title| {
        if (top.ptr != owned_title.ptr) {
            a.free(owned_title);
        }
    } else |_| {}
    lines.append(a, top) catch {};

    if (app.subagents.items.len == 0) {
        const no_sub = std.fmt.allocPrint(a, "{s}│{s}  No active sub-agents  {s}│{s}", .{ bo, R, bo, R }) catch "";
        owned.append(a, no_sub) catch {};
        lines.append(a, no_sub) catch {};
    } else {
        for (app.subagents.items) |sa| {
            const status_icon: []const u8 = switch (sa.status) {
                .pending => "○",
                .streaming => "◐",
                .complete => "✓",
                .failed => "✗",
            };
            const role_name = @tagName(sa.role);
            const line = std.fmt.allocPrint(a, "{s}│{s} {s} {s}: {s}{s}│{s}", .{
                bo, R, status_icon, sa.id, role_name, bo, R,
            }) catch "";
            owned.append(a, line) catch {};
            lines.append(a, line) catch {};
            // Goal line + live/accumulated summary line, truncated to the
            // panel width so long goals don't widen the box.
            const max_body = panel_w -| 5;
            for ([_][]const u8{ sa.goal, sa.summary }) |body| {
                if (body.len == 0) continue;
                const trunc = zz.layout.measure.truncate(a, body, max_body) catch null;
                const truncated = trunc orelse body;
                const body_line = std.fmt.allocPrint(a, "{s}│{s}  {s}{s}│{s}", .{
                    bo, R, truncated, bo, R,
                }) catch "";
                if (trunc) |t| owned.append(a, t) catch {};
                owned.append(a, body_line) catch {};
                lines.append(a, body_line) catch {};
            }
        }
    }
    const bottom = std.fmt.allocPrint(a, "{s}└──────────────────────────────────────┘{s}", .{ bo, R }) catch "";
    owned.append(a, bottom) catch {};
    lines.append(a, bottom) catch {};

    return join.vertical(a, .left, lines.items) catch "";
}

