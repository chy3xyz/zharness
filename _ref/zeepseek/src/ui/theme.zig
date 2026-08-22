const std = @import("std");
const zz = @import("zigzag");

pub const Color = zz.Color;

pub const ColorPalette = struct {
    bg: Color,
    bg_alt: Color,
    bg_hover: Color,
    bg_active: Color,
    bg_selected: Color,
    fg: Color,
    fg_dim: Color,
    fg_bright: Color,
    fg_inverse: Color,
    user_msg_bg: Color,
    assistant_msg_bg: Color,
    system_msg_bg: Color,
    border: Color,
    border_focused: Color,
    scrollbar: Color,
    success: Color,
    warning: Color,
    error_color: Color,
    info: Color,
    link: Color,
    thinking: Color,
    tool_call: Color,
    prompt: Color,
};

pub const ThemeId = enum(u8) {
    catppuccin_mocha,
    catppuccin_latte,
    tokyo_night,
    dracula,
    gruvbox,
    monokai,
    github_dark,
    solarized_dark,
    high_contrast,
    one_dark,
    custom,

    pub fn isValid(id: u8) bool {
        return id <= @intFromEnum(ThemeId.custom);
    }
};

pub const Theme = struct {
    id: ThemeId,
    name: []const u8,
    palette: ColorPalette,
};

fn rgb(r: u8, g: u8, b: u8) Color {
    return Color.fromRgb(r, g, b);
}

pub const themes = [_]Theme{
    .{
        .id = .catppuccin_mocha,
        .name = "Catppuccin Mocha",
        .palette = ColorPalette{
            .bg = rgb(30, 30, 46),
            .bg_alt = rgb(35, 35, 58),
            .bg_hover = rgb(40, 40, 65),
            .bg_active = rgb(45, 45, 72),
            .bg_selected = rgb(50, 50, 80),
            .fg = rgb(205, 214, 244),
            .fg_dim = rgb(108, 112, 134),
            .fg_bright = rgb(245, 245, 245),
            .fg_inverse = rgb(30, 30, 46),
            .user_msg_bg = rgb(49, 52, 68),
            .assistant_msg_bg = rgb(35, 35, 58),
            .system_msg_bg = rgb(40, 40, 60),
            .border = rgb(75, 78, 96),
            .border_focused = rgb(137, 180, 250),
            .scrollbar = rgb(75, 78, 96),
            .success = rgb(166, 227, 161),
            .warning = rgb(249, 226, 175),
            .error_color = rgb(243, 139, 168),
            .info = rgb(137, 220, 235),
            .link = rgb(137, 180, 250),
            .thinking = rgb(245, 194, 231),
            .tool_call = rgb(148, 226, 213),
            .prompt = rgb(166, 173, 200),
        },
    },
    .{
        .id = .catppuccin_latte,
        .name = "Catppuccin Latte",
        .palette = ColorPalette{
            .bg = rgb(239, 241, 245),
            .bg_alt = rgb(234, 237, 241),
            .bg_hover = rgb(228, 232, 237),
            .bg_active = rgb(223, 227, 234),
            .bg_selected = rgb(216, 221, 230),
            .fg = rgb(76, 79, 105),
            .fg_dim = rgb(140, 144, 165),
            .fg_bright = rgb(32, 34, 44),
            .fg_inverse = rgb(239, 241, 245),
            .user_msg_bg = rgb(199, 206, 225),
            .assistant_msg_bg = rgb(223, 227, 234),
            .system_msg_bg = rgb(216, 221, 230),
            .border = rgb(174, 179, 196),
            .border_focused = rgb(30, 102, 245),
            .scrollbar = rgb(174, 179, 196),
            .success = rgb(64, 160, 43),
            .warning = rgb(223, 142, 29),
            .error_color = rgb(210, 15, 57),
            .info = rgb(4, 165, 229),
            .link = rgb(30, 102, 245),
            .thinking = rgb(194, 59, 34),
            .tool_call = rgb(21, 114, 88),
            .prompt = rgb(108, 112, 134),
        },
    },
    .{
        .id = .tokyo_night,
        .name = "Tokyo Night",
        .palette = ColorPalette{
            .bg = rgb(32, 34, 44),
            .bg_alt = rgb(37, 40, 55),
            .bg_hover = rgb(42, 45, 62),
            .bg_active = rgb(47, 50, 68),
            .bg_selected = rgb(52, 56, 76),
            .fg = rgb(192, 202, 245),
            .fg_dim = rgb(126, 133, 155),
            .fg_bright = rgb(255, 255, 255),
            .fg_inverse = rgb(32, 34, 44),
            .user_msg_bg = rgb(58, 62, 84),
            .assistant_msg_bg = rgb(37, 40, 55),
            .system_msg_bg = rgb(44, 48, 66),
            .border = rgb(82, 88, 110),
            .border_focused = rgb(98, 130, 252),
            .scrollbar = rgb(82, 88, 110),
            .success = rgb(158, 227, 146),
            .warning = rgb(239, 213, 126),
            .error_color = rgb(247, 140, 154),
            .info = rgb(139, 216, 234),
            .link = rgb(98, 130, 252),
            .thinking = rgb(210, 168, 238),
            .tool_call = rgb(156, 220, 204),
            .prompt = rgb(152, 162, 184),
        },
    },
    .{
        .id = .dracula,
        .name = "Dracula",
        .palette = ColorPalette{
            .bg = rgb(40, 42, 54),
            .bg_alt = rgb(45, 47, 61),
            .bg_hover = rgb(50, 52, 68),
            .bg_active = rgb(55, 57, 74),
            .bg_selected = rgb(60, 62, 80),
            .fg = rgb(248, 248, 242),
            .fg_dim = rgb(98, 102, 116),
            .fg_bright = rgb(255, 255, 255),
            .fg_inverse = rgb(40, 42, 54),
            .user_msg_bg = rgb(68, 71, 90),
            .assistant_msg_bg = rgb(45, 47, 61),
            .system_msg_bg = rgb(52, 55, 72),
            .border = rgb(68, 71, 90),
            .border_focused = rgb(139, 233, 253),
            .scrollbar = rgb(68, 71, 90),
            .success = rgb(80, 250, 123),
            .warning = rgb(255, 184, 108),
            .error_color = rgb(255, 85, 85),
            .info = rgb(139, 233, 253),
            .link = rgb(189, 147, 249),
            .thinking = rgb(255, 121, 198),
            .tool_call = rgb(50, 250, 200),
            .prompt = rgb(124, 134, 156),
        },
    },
    .{
        .id = .gruvbox,
        .name = "Gruvbox Dark",
        .palette = ColorPalette{
            .bg = rgb(40, 40, 40),
            .bg_alt = rgb(45, 45, 45),
            .bg_hover = rgb(50, 50, 50),
            .bg_active = rgb(55, 55, 55),
            .bg_selected = rgb(60, 60, 60),
            .fg = rgb(235, 219, 178),
            .fg_dim = rgb(146, 131, 116),
            .fg_bright = rgb(251, 241, 199),
            .fg_inverse = rgb(40, 40, 40),
            .user_msg_bg = rgb(70, 60, 50),
            .assistant_msg_bg = rgb(45, 45, 45),
            .system_msg_bg = rgb(55, 50, 45),
            .border = rgb(100, 90, 76),
            .border_focused = rgb(215, 153, 107),
            .scrollbar = rgb(100, 90, 76),
            .success = rgb(152, 192, 124),
            .warning = rgb(215, 153, 107),
            .error_color = rgb(204, 102, 102),
            .info = rgb(129, 179, 210),
            .link = rgb(215, 153, 107),
            .thinking = rgb(211, 134, 155),
            .tool_call = rgb(142, 192, 124),
            .prompt = rgb(156, 146, 126),
        },
    },
    .{
        .id = .monokai,
        .name = "Monokai",
        .palette = ColorPalette{
            .bg = rgb(39, 40, 34),
            .bg_alt = rgb(43, 44, 38),
            .bg_hover = rgb(48, 49, 42),
            .bg_active = rgb(53, 54, 47),
            .bg_selected = rgb(58, 59, 52),
            .fg = rgb(248, 248, 242),
            .fg_dim = rgb(155, 157, 145),
            .fg_bright = rgb(255, 255, 255),
            .fg_inverse = rgb(39, 40, 34),
            .user_msg_bg = rgb(68, 68, 54),
            .assistant_msg_bg = rgb(43, 44, 38),
            .system_msg_bg = rgb(50, 51, 44),
            .border = rgb(115, 115, 95),
            .border_focused = rgb(102, 217, 239),
            .scrollbar = rgb(115, 115, 95),
            .success = rgb(166, 226, 46),
            .warning = rgb(250, 205, 76),
            .error_color = rgb(249, 38, 114),
            .info = rgb(102, 217, 239),
            .link = rgb(102, 217, 239),
            .thinking = rgb(255, 0, 183),
            .tool_call = rgb(166, 226, 46),
            .prompt = rgb(155, 157, 145),
        },
    },
    .{
        .id = .github_dark,
        .name = "GitHub Dark",
        .palette = ColorPalette{
            .bg = rgb(13, 17, 23),
            .bg_alt = rgb(22, 27, 34),
            .bg_hover = rgb(29, 35, 44),
            .bg_active = rgb(36, 43, 54),
            .bg_selected = rgb(44, 51, 64),
            .fg = rgb(201, 209, 217),
            .fg_dim = rgb(110, 118, 129),
            .fg_bright = rgb(255, 255, 255),
            .fg_inverse = rgb(13, 17, 23),
            .user_msg_bg = rgb(33, 38, 45),
            .assistant_msg_bg = rgb(22, 27, 34),
            .system_msg_bg = rgb(28, 33, 40),
            .border = rgb(48, 54, 61),
            .border_focused = rgb(88, 166, 255),
            .scrollbar = rgb(48, 54, 61),
            .success = rgb(63, 185, 80),
            .warning = rgb(210, 153, 34),
            .error_color = rgb(248, 81, 73),
            .info = rgb(56, 139, 253),
            .link = rgb(88, 166, 255),
            .thinking = rgb(210, 168, 255),
            .tool_call = rgb(56, 209, 173),
            .prompt = rgb(130, 139, 148),
        },
    },
    .{
        .id = .solarized_dark,
        .name = "Solarized Dark",
        .palette = ColorPalette{
            .bg = rgb(0, 43, 54),
            .bg_alt = rgb(7, 54, 66),
            .bg_hover = rgb(14, 61, 74),
            .bg_active = rgb(20, 68, 82),
            .bg_selected = rgb(26, 75, 90),
            .fg = rgb(131, 148, 150),
            .fg_dim = rgb(88, 110, 117),
            .fg_bright = rgb(147, 161, 161),
            .fg_inverse = rgb(0, 43, 54),
            .user_msg_bg = rgb(14, 61, 74),
            .assistant_msg_bg = rgb(7, 54, 66),
            .system_msg_bg = rgb(11, 58, 70),
            .border = rgb(60, 80, 88),
            .border_focused = rgb(38, 139, 210),
            .scrollbar = rgb(60, 80, 88),
            .success = rgb(133, 153, 0),
            .warning = rgb(181, 137, 0),
            .error_color = rgb(220, 50, 47),
            .info = rgb(38, 139, 210),
            .link = rgb(38, 139, 210),
            .thinking = rgb(203, 75, 22),
            .tool_call = rgb(42, 161, 152),
            .prompt = rgb(100, 118, 120),
        },
    },
    .{
        .id = .high_contrast,
        .name = "High Contrast",
        .palette = ColorPalette{
            .bg = rgb(0, 0, 0),
            .bg_alt = rgb(10, 10, 10),
            .bg_hover = rgb(20, 20, 20),
            .bg_active = rgb(30, 30, 30),
            .bg_selected = rgb(255, 255, 0),
            .fg = rgb(255, 255, 255),
            .fg_dim = rgb(192, 192, 192),
            .fg_bright = rgb(255, 255, 255),
            .fg_inverse = rgb(0, 0, 0),
            .user_msg_bg = rgb(20, 20, 20),
            .assistant_msg_bg = rgb(10, 10, 10),
            .system_msg_bg = rgb(15, 15, 15),
            .border = rgb(255, 255, 255),
            .border_focused = rgb(0, 255, 255),
            .scrollbar = rgb(128, 128, 128),
            .success = rgb(0, 255, 0),
            .warning = rgb(255, 255, 0),
            .error_color = rgb(255, 0, 0),
            .info = rgb(0, 255, 255),
            .link = rgb(0, 255, 255),
            .thinking = rgb(255, 0, 255),
            .tool_call = rgb(0, 255, 128),
            .prompt = rgb(192, 192, 192),
        },
    },
    .{
        .id = .one_dark,
        .name = "One Dark",
        .palette = ColorPalette{
            .bg = rgb(40, 44, 52),
            .bg_alt = rgb(50, 54, 62),
            .bg_hover = rgb(55, 59, 67),
            .bg_active = rgb(60, 64, 72),
            .bg_selected = rgb(66, 70, 78),
            .fg = rgb(171, 178, 191),
            .fg_dim = rgb(108, 115, 128),
            .fg_bright = rgb(220, 223, 228),
            .fg_inverse = rgb(40, 44, 52),
            .user_msg_bg = rgb(55, 59, 67),
            .assistant_msg_bg = rgb(50, 54, 62),
            .system_msg_bg = rgb(52, 56, 64),
            .border = rgb(75, 80, 90),
            .border_focused = rgb(97, 175, 239),
            .scrollbar = rgb(75, 80, 90),
            .success = rgb(152, 195, 121),
            .warning = rgb(229, 192, 123),
            .error_color = rgb(224, 108, 117),
            .info = rgb(97, 175, 239),
            .link = rgb(97, 175, 239),
            .thinking = rgb(198, 120, 221),
            .tool_call = rgb(86, 182, 194),
            .prompt = rgb(128, 135, 148),
        },
    },
};

pub const ThemeManager = struct {
    current: ThemeId,
    custom: ?ColorPalette,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) ThemeManager {
        return .{
            .current = .catppuccin_mocha,
            .custom = null,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ThemeManager) void {
        _ = self;
    }

    pub fn setTheme(self: *ThemeManager, id: ThemeId) void {
        self.current = id;
        self.custom = null;
    }

    pub fn setCustomPalette(self: *ThemeManager, palette: ColorPalette) void {
        self.custom = palette;
        self.current = .custom;
    }

    pub fn getPalette(self: *const ThemeManager) ColorPalette {
        if (self.current == .custom) {
            return self.custom orelse themes[0].palette;
        }
        for (themes) |theme| {
            if (theme.id == self.current) {
                return theme.palette;
            }
        }
        return themes[0].palette;
    }

    pub fn cycle(self: *ThemeManager) void {
        const builtin_count = themes.len - 1;
        const current_idx = for (themes, 0..) |t, i| {
            if (t.id == self.current) break i;
        } else 0;

        if (self.current == .custom) {
            self.current = themes[0].id;
        } else {
            const next_idx = (current_idx + 1) % builtin_count;
            self.current = themes[next_idx].id;
        }
    }

    pub fn getThemeName(self: *const ThemeManager) []const u8 {
        if (self.current == .custom) {
            return "Custom";
        }
        for (themes) |theme| {
            if (theme.id == self.current) {
                return theme.name;
            }
        }
        return "Unknown";
    }
};

test "theme manager init" {
    const alloc = std.testing.allocator;
    var tm = ThemeManager.init(alloc);
    defer tm.deinit();
    try std.testing.expect(tm.current == .catppuccin_mocha);
    const palette = tm.getPalette();
    _ = palette;
}

test "theme manager cycle" {
    const alloc = std.testing.allocator;
    var tm = ThemeManager.init(alloc);
    defer tm.deinit();
    const first = tm.current;
    tm.cycle();
    try std.testing.expect(tm.current != first);
}

test "theme manager custom palette" {
    const alloc = std.testing.allocator;
    var tm = ThemeManager.init(alloc);
    defer tm.deinit();
    const custom_palette = ColorPalette{
        .bg = rgb(0, 0, 0),
        .bg_alt = rgb(10, 10, 10),
        .bg_hover = rgb(20, 20, 20),
        .bg_active = rgb(30, 30, 30),
        .bg_selected = rgb(40, 40, 40),
        .fg = rgb(255, 255, 255),
        .fg_dim = rgb(200, 200, 200),
        .fg_bright = rgb(255, 255, 255),
        .fg_inverse = rgb(0, 0, 0),
        .user_msg_bg = rgb(20, 20, 20),
        .assistant_msg_bg = rgb(10, 10, 10),
        .system_msg_bg = rgb(15, 15, 15),
        .border = rgb(50, 50, 50),
        .border_focused = rgb(100, 100, 100),
        .scrollbar = rgb(50, 50, 50),
        .success = rgb(0, 255, 0),
        .warning = rgb(255, 255, 0),
        .error_color = rgb(255, 0, 0),
        .info = rgb(0, 0, 255),
        .link = rgb(0, 200, 255),
        .thinking = rgb(255, 200, 0),
        .tool_call = rgb(200, 0, 255),
        .prompt = rgb(150, 150, 150),
    };
    tm.setCustomPalette(custom_palette);
    try std.testing.expect(tm.current == .custom);
    const palette = tm.getPalette();
    _ = palette;
}

// ═══════════════════════════════════════════════════════════════════════
// ANSI Bridge — converts ColorPalette to ANSI escape strings for TUI rendering
// ═══════════════════════════════════════════════════════════════════════

/// Convert a zz.Color to ANSI foreground escape sequence (24-bit)
fn colorToAnsi(comptime c: Color) []const u8 {
    const rgb_val = c.rgb;
    return std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ rgb_val.r, rgb_val.g, rgb_val.b });
}

/// Pre-computed ANSI escape strings derived from a ColorPalette.
/// Use this for string-based TUI rendering (app.zig view functions).
pub const Pal = struct {
    // Base styles
    pub const R = "\x1b[0m";
    pub const B = "\x1b[1m";
    pub const D = "\x1b[2m";
    pub const U = "\x1b[4m";

    // Semantic colors (Catppuccin Mocha defaults)
    pub const fg = colorToAnsi(rgb(205, 214, 244));
    pub const fg_dim = colorToAnsi(rgb(108, 112, 134));
    pub const fg_bright = colorToAnsi(rgb(245, 245, 245));

    // Role colors
    pub const user = colorToAnsi(rgb(137, 180, 250));    // Blue
    pub const assistant = colorToAnsi(rgb(166, 227, 161)); // Green
    pub const system = colorToAnsi(rgb(249, 226, 175));   // Yellow
    pub const tool = colorToAnsi(rgb(255, 184, 108));     // Orange

    // Accent colors
    pub const cyan = colorToAnsi(rgb(139, 233, 253));
    pub const green = colorToAnsi(rgb(166, 227, 161));
    pub const yellow = colorToAnsi(rgb(249, 226, 175));
    pub const pink = colorToAnsi(rgb(245, 194, 231));
    pub const red = colorToAnsi(rgb(243, 139, 168));
    pub const orange = colorToAnsi(rgb(255, 184, 108));
    pub const blue = colorToAnsi(rgb(137, 180, 250));
    pub const mauve = colorToAnsi(rgb(203, 166, 247));

    // Semantic
    pub const success = colorToAnsi(rgb(166, 227, 161));
    pub const warning = colorToAnsi(rgb(249, 226, 175));
    pub const error_color = colorToAnsi(rgb(243, 139, 168));
    pub const info = colorToAnsi(rgb(139, 233, 253));
    pub const thinking = colorToAnsi(rgb(245, 194, 231));
    pub const tool_call = colorToAnsi(rgb(148, 226, 213));
    pub const prompt_color = colorToAnsi(rgb(166, 173, 200));

    // Code
    pub const code_fg = colorToAnsi(rgb(245, 245, 245));

    // Backgrounds (24-bit)
    pub const bg_surface = "\x1b[48;2;30;30;46m";
    pub const bg_code = "\x1b[48;2;40;42;54m";
    pub const bg_code_inline = "\x1b[48;2;50;52;64m";
    pub const bg_highlight = "\x1b[48;2;249;226;175;38;2;30;30;46m";
};

// ═══════════════════════════════════════════════════════════════════════
// ZigZag Style Bridge — converts ColorPalette to zz.Style values
// ═══════════════════════════════════════════════════════════════════════

/// Pre-built styles derived from a ColorPalette.
/// Regenerate whenever the active palette changes.
pub const SemanticStyles = struct {
    fg: zz.Style,
    fg_dim: zz.Style,
    fg_bright: zz.Style,
    user: zz.Style,
    assistant: zz.Style,
    system: zz.Style,
    tool: zz.Style,
    cyan: zz.Style,
    green: zz.Style,
    yellow: zz.Style,
    pink: zz.Style,
    red: zz.Style,
    orange: zz.Style,
    blue: zz.Style,
    mauve: zz.Style,
    success: zz.Style,
    warning: zz.Style,
    error_color: zz.Style,
    info: zz.Style,
    thinking: zz.Style,
    tool_call: zz.Style,
    prompt_color: zz.Style,
    border: zz.Style,
    border_focused: zz.Style,
    bg_surface: zz.Style,
    bg_code: zz.Style,
    bg_code_inline: zz.Style,

    pub fn fromPalette(p: ColorPalette) SemanticStyles {
        var base = zz.Style{};
        base = base.inline_style(true);
        var dim = base;
        dim = dim.dim(true);
        var bold = base;
        bold = bold.bold(true);
        return .{
            .fg = base.fg(p.fg),
            .fg_dim = dim.fg(p.fg_dim),
            .fg_bright = bold.fg(p.fg_bright),
            .user = base.fg(p.link),
            .assistant = base.fg(p.success),
            .system = base.fg(p.warning),
            .tool = base.fg(p.warning),
            .cyan = base.fg(Color.fromRgb(139, 233, 253)),
            .green = base.fg(p.success),
            .yellow = base.fg(p.warning),
            .pink = base.fg(p.thinking),
            .red = base.fg(p.error_color),
            .orange = base.fg(p.warning),
            .blue = base.fg(p.link),
            .mauve = base.fg(p.thinking),
            .success = base.fg(p.success),
            .warning = base.fg(p.warning),
            .error_color = base.fg(p.error_color),
            .info = base.fg(p.info),
            .thinking = base.fg(p.thinking),
            .tool_call = base.fg(p.tool_call),
            .prompt_color = base.fg(p.prompt),
            .border = dim.fg(p.border),
            .border_focused = base.fg(p.border_focused),
            .bg_surface = base.bg(p.bg),
            .bg_code = base.bg(Color.fromRgb(40, 42, 54)),
            .bg_code_inline = base.bg(Color.fromRgb(50, 52, 64)),
        };
    }
};

test "semantic styles from palette" {
    const palette = themes[0].palette;
    const styles = SemanticStyles.fromPalette(palette);
    _ = styles;
}
