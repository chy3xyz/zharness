//! Pure ANSI / markdown rendering helpers (no App state) — split out of
//! app.zig so the UI shell stays focused on state + event flow.

const std = @import("std");
const theme = @import("theme.zig");

const Pal = theme.Pal;
const R = Pal.R;
const B = Pal.B;
const D = Pal.D;
const U = Pal.U;
const I = "\x1b[3m"; // italic

const CodeBg = Pal.bg_code;
const CodeInlineBg = Pal.bg_code_inline;
const SearchHighlight = Pal.bg_highlight;

fn appendFmt(buf: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (std.fmt.allocPrint(a, fmt, args)) |s| {
        buf.appendSlice(a, s) catch {};
    } else |_| {}
}

pub fn renderMarkdownAnsi(buf: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8, width: u16) void {
    var in_code_block = false;
    var code_lang: []const u8 = "";
    var code_lines: [512][]const u8 = undefined;
    var code_count: usize = 0;
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| {
        // Code block fence
        if (std.mem.startsWith(u8, line, "```")) {
            if (in_code_block) {
                // Render accumulated code block with line numbers
                renderCodeBlockWithLineNums(buf, a, &code_lines, code_count, code_lang, width);
                code_count = 0;
                in_code_block = false;
            } else {
                in_code_block = true;
                code_lang = if (line.len > 3) std.mem.trim(u8, line[3..], " ") else "";
                code_count = 0;
            }
            continue;
        }

        if (in_code_block) {
            if (code_count < code_lines.len) {
                code_lines[code_count] = line;
                code_count += 1;
            }
            continue;
        }

        // Headings
        if (std.mem.startsWith(u8, line, "# ")) {
            appendFmt(buf, a, "{s}{s}{s}{s}\n", .{ B, Pal.blue, line[2..], R });
            continue;
        }
        if (std.mem.startsWith(u8, line, "## ")) {
            appendFmt(buf, a, "{s}{s}{s}{s}\n", .{ B, Pal.green, line[3..], R });
            continue;
        }
        if (std.mem.startsWith(u8, line, "### ")) {
            appendFmt(buf, a, "{s}{s}{s}{s}\n", .{ B, Pal.yellow, line[4..], R });
            continue;
        }

        // Horizontal rule
        if (line.len >= 3 and std.mem.allEqual(u8, line, '-')) {
            appendFmt(buf, a, "{s}", .{D});
            var col: u16 = 0;
            while (col < width) : (col += 1) { buf.appendSlice(a, "x") catch {}; }
            appendFmt(buf, a, "{s}\n", .{R});
            continue;
        }

        // List items
        if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
            appendFmt(buf, a, "  {s}•{s} ", .{ Pal.green, R });
            renderInlineAnsi(buf, a, line[2..]);
            buf.appendSlice(a, "\n") catch {};
            continue;
        }
        if (line.len >= 3 and line[0] >= '1' and line[0] <= '9' and (line[1] == '.' or (line[1] >= '0' and line[1] <= '9' and line[2] == '.'))) {
            const dot = std.mem.indexOfScalar(u8, line, '.') orelse 0;
            appendFmt(buf, a, "  {s}{s}{s} ", .{ Pal.green, line[0 .. dot + 1], R });
            renderInlineAnsi(buf, a, std.mem.trim(u8, line[dot + 1 ..], " "));
            buf.appendSlice(a, "\n") catch {};
            continue;
        }

        // Blockquote
        if (std.mem.startsWith(u8, line, "> ")) {
            appendFmt(buf, a, "  {s}|{s} {s}", .{ D, R, line[2..] });
            buf.appendSlice(a, R) catch {};
            buf.appendSlice(a, "\n") catch {};
            continue;
        }

        // Regular paragraph
        renderInlineAnsi(buf, a, line);
        buf.appendSlice(a, "\n") catch {};
    }
    // Unclosed code block
    if (in_code_block) {
        renderCodeBlockWithLineNums(buf, a, &code_lines, code_count, code_lang, width);
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Code block renderer with line numbers
// ═══════════════════════════════════════════════════════════════════════

pub fn renderCodeBlockWithLineNums(
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,
    code_lines: [][]const u8,
    count: usize,
    lang: []const u8,
    width: u16,
) void {
    if (count == 0) {
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, "+---") catch {};
        if (lang.len > 0) {
            buf.appendSlice(a, " ") catch {};
            buf.appendSlice(a, Pal.cyan) catch {};
            buf.appendSlice(a, lang) catch {};
            buf.appendSlice(a, R) catch {};
            buf.appendSlice(a, D) catch {};
        }
        buf.appendSlice(a, " ---") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, "\n") catch {};
        return;
    }

    // Line number width: enough digits for max line number
    var digits: usize = 1;
    if (count >= 100) digits = 3 else if (count >= 10) digits = 2;
    const gutter_w = @as(u16, @intCast(digits + 2)); // " N │ "
    const content_w = if (width > gutter_w) width - gutter_w else 10;

    // Header
    buf.appendSlice(a, D) catch {};
    buf.appendSlice(a, "┌─") catch {};
    buf.appendSlice(a, R) catch {};
    buf.appendSlice(a, B) catch {};
    buf.appendSlice(a, Pal.cyan) catch {};
    buf.appendSlice(a, lang) catch {};
    buf.appendSlice(a, R) catch {};
    if (lang.len > 0) {
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, "|") catch {};
        buf.appendSlice(a, R) catch {};
    }
    // " X lines\n"
    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, " {d} line{s}\n", .{ count, if (count == 1) "" else "s" }) catch " lines\n";
    buf.appendSlice(a, num_str) catch {};

    // Code lines
    for (0..count) |i| {
        const line = code_lines[i];
        // Line number with manual padding to digits width
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, "│") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, Pal.blue) catch {};
        // Line number
        var line_num_buf: [16]u8 = undefined;
        const ln_str = std.fmt.bufPrint(&line_num_buf, "{d}", .{i + 1}) catch "0";
        buf.appendSlice(a, ln_str) catch {};
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, "│") catch {};
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, R) catch {};
        // Pad line number to fixed width
        var pd: usize = ln_str.len;
        while (pd < digits) : (pd += 1) buf.appendSlice(a, " ") catch {};

        // Code content with background
        buf.appendSlice(a, CodeBg) catch {};
        buf.appendSlice(a, Pal.code_fg) catch {};
        if (line.len > content_w) {
            buf.appendSlice(a, line[0..content_w]) catch {};
        } else {
            buf.appendSlice(a, line) catch {};
        }
        buf.appendSlice(a, R) catch {};

        // Pad
        const used = if (line.len > content_w) content_w else line.len;
        const pad = content_w - used;
        var p: u16 = 0;
        while (p < pad) : (p += 1) { buf.appendSlice(a, " ") catch {}; }
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, "│") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, "\n") catch {};
    }

    // Footer
    buf.appendSlice(a, D) catch {};
    buf.appendSlice(a, "└─") catch {};
    buf.appendSlice(a, R) catch {};
    buf.appendSlice(a, "\n") catch {};
}

pub fn renderInlineAnsi(buf: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        // Inline code `...`
        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                appendFmt(buf, a, "{s}{s}{s}{s}{s}", .{ CodeInlineBg, Pal.fg, text[i + 1 .. end], R, R });
                i = end + 1;
                continue;
            }
        }
        // Bold **...**
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                buf.appendSlice(a, B) catch {};
                buf.appendSlice(a, text[i + 2 .. end]) catch {};
                buf.appendSlice(a, R) catch {};
                i = end + 2;
                continue;
            }
        }
        // Italic _..._ (single underscore)
        if (text[i] == '_' and i + 1 < text.len and text[i + 1] != '_') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '_')) |end| {
                buf.appendSlice(a, U) catch {};
                buf.appendSlice(a, text[i + 1 .. end]) catch {};
                buf.appendSlice(a, R) catch {};
                i = end + 1;
                continue;
            }
        }
        // Strikethrough ~~...~~
        if (i + 1 < text.len and text[i] == '~' and text[i + 1] == '~') {
            if (std.mem.indexOfPos(u8, text, i + 2, "~~")) |end| {
                buf.appendSlice(a, "\x1b[9m") catch {};
                buf.appendSlice(a, text[i + 2 .. end]) catch {};
                buf.appendSlice(a, R) catch {};
                i = end + 2;
                continue;
            }
        }
        // Link [text](url) — render as underlined text
        if (text[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |cb| {
                if (cb + 1 < text.len and text[cb + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, cb + 2, ')')) |cp| {
                        buf.appendSlice(a, Pal.cyan) catch {};
                        buf.appendSlice(a, text[i + 1 .. cb]) catch {};
                        buf.appendSlice(a, R) catch {};
                        i = cp + 1;
                        continue;
                    }
                }
            }
        }
        // Plain text — emit until next special char
        var j = i;
        while (j < text.len) {
            if (text[j] == '`' or text[j] == '*' or text[j] == '_' or text[j] == '~' or text[j] == '[') break;
            j += 1;
        }
        if (j > i) {
            buf.appendSlice(a, text[i..j]) catch {};
        }
        i = @max(j, i + 1);
    }
}

pub fn appendHighlighted(buf: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8, query: []const u8) void {
    if (query.len == 0 or text.len == 0) {
        buf.appendSlice(a, text) catch {};
        return;
    }
    var pos: usize = 0;
    while (pos < text.len) {
        if (std.mem.indexOfPos(u8, text, pos, query)) |match| {
            // Text before match
            if (match > pos) buf.appendSlice(a, text[pos..match]) catch {};
            // Highlighted match
            buf.appendSlice(a, SearchHighlight) catch {};
            buf.appendSlice(a, text[match .. match + query.len]) catch {};
            buf.appendSlice(a, R) catch {};
            pos = match + query.len;
        } else {
            buf.appendSlice(a, text[pos..]) catch {};
            break;
        }
    }
}
