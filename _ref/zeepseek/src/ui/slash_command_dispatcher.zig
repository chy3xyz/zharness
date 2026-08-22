const std = @import("std");
const ProviderManager = @import("../providers/manager.zig").ProviderManager;
const model_catalog = @import("../providers/models.zig").model_catalog;
const SkillRegistry = @import("../skills/registry.zig").SkillRegistry;
const theme = @import("theme.zig");
const Sandbox = @import("../utils/sandbox.zig").Sandbox;

pub const CommandKind = enum {
    instant,
    prompt,
    output,
    insert, // palette-only shortcut: fill the input box
};

pub const Command = struct {
    id: []const u8,
    label: []const u8,
    desc: []const u8,
    kind: CommandKind = .instant,
};

pub const CommandContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: []const u8,
    model: []const u8,
    subsystems_initialized: bool,
    provider_mgr: *ProviderManager,
    sandbox: ?*Sandbox,
    skill_registry: ?*SkillRegistry = null,
    tokens_used: usize,
    ctx_max: usize,
    cache_hit_rate: f64,
    session_id: []const u8,
};

pub const Prompt = struct {
    title: []const u8,
    placeholder: []const u8,
};

pub const TableData = struct {
    title: []const u8,
    headers: []const []const u8,
    rows: []const []const []const u8,
};

pub const ListData = struct {
    title: []const u8,
    items: []const []const u8,
};

/// One entry in a second-level ("二级") command menu. `action` is a slash line
/// (e.g. "/model deepseek-v4-pro") that the app routes after the user selects.
pub const SubItem = struct {
    label: []const u8,
    desc: []const u8,
    action: []const u8,
};

/// A second-level menu rendered as a selectable palette. All strings are owned
/// by the request allocator and freed once the palette has cloned them.
pub const SubMenu = struct {
    title: []const u8,
    items: []const SubItem,
};

pub const Result = union(enum) {
    none,
    set_input: []const u8,
    notify: []const u8,
    quit,
    clear_chat,
    save_session,
    load_session,
    toggle_thinking,
    toggle_tools,
    toggle_subagents,
    scroll_top,
    scroll_bottom,
    compact_context,
    show_help,
    prompt: Prompt,
    show_table: TableData,
    show_list: ListData,
    submenu: SubMenu,
    set_model: []const u8,
    set_provider: []const u8,
    set_apikey: []const u8,
    set_theme: []const u8,
    set_lang: []const u8,
};

const commands_table = [_]Command{
    .{ .id = "help", .label = "/help", .desc = "Show help information" },
    .{ .id = "clear", .label = "/clear", .desc = "Clear conversation history" },
    .{ .id = "exit", .label = "/exit", .desc = "Quit the application" },
    .{ .id = "model", .label = "/model", .desc = "Switch model", .kind = .prompt },
    .{ .id = "provider", .label = "/provider", .desc = "Switch API provider and set key", .kind = .prompt },
    .{ .id = "models", .label = "/models", .desc = "List available models", .kind = .output },
    .{ .id = "save", .label = "/save", .desc = "Save current session" },
    .{ .id = "load", .label = "/load", .desc = "Load a session from file" },
    .{ .id = "sessions", .label = "/sessions", .desc = "List saved sessions", .kind = .output },
    .{ .id = "workspace", .label = "/workspace", .desc = "Show workspace path", .kind = .output },
    .{ .id = "context", .label = "/context", .desc = "Show context usage statistics", .kind = .output },
    .{ .id = "status", .label = "/status", .desc = "Show system status", .kind = .output },
    .{ .id = "compact", .label = "/compact", .desc = "Compact conversation context" },
    .{ .id = "note", .label = "/note", .desc = "Manage notes", .kind = .insert },
    .{ .id = "memory", .label = "/memory", .desc = "Manage agent memory", .kind = .insert },
    .{ .id = "subagents", .label = "/subagents", .desc = "Show sub-agent panel" },
    .{ .id = "subagent", .label = "/subagent", .desc = "Spawn a research sub-agent", .kind = .insert },
    .{ .id = "theme", .label = "/theme", .desc = "Switch color theme", .kind = .prompt },
    .{ .id = "think", .label = "/think", .desc = "Toggle reasoning visibility" },
    .{ .id = "tools", .label = "/tools", .desc = "Toggle tool call visibility" },
    .{ .id = "top", .label = "/top", .desc = "Scroll to top" },
    .{ .id = "bottom", .label = "/bottom", .desc = "Scroll to bottom" },
    .{ .id = "new", .label = "/new", .desc = "Start a new session" },
    .{ .id = "apikey", .label = "/apikey", .desc = "Set API key", .kind = .prompt },
    .{ .id = "key", .label = "/key", .desc = "Set API key (alias)", .kind = .prompt },
    .{ .id = "skills", .label = "/skills", .desc = "List available skills", .kind = .output },
    .{ .id = "sandbox", .label = "/sandbox", .desc = "Show sandbox status", .kind = .output },
    .{ .id = "providers", .label = "/providers", .desc = "List configured providers", .kind = .output },
    .{ .id = "lang", .label = "/lang", .desc = "Switch interface language (en/ja/zh/pt)" },
};

pub const Dispatcher = struct {
    pub fn commands() []const Command {
        return &commands_table;
    }

    /// Commands whose side effects are destructive enough to warrant an
    /// explicit confirmation dialog before running.
    pub fn needsConfirm(id: []const u8) bool {
        return std.mem.eql(u8, id, "clear") or
            std.mem.eql(u8, id, "new") or
            std.mem.eql(u8, id, "save") or
            std.mem.eql(u8, id, "compact") or
            std.mem.eql(u8, id, "exit");
    }

    pub fn execute(ctx: CommandContext, id: []const u8, args: []const u8)
        error{ UnknownCommand, InvalidArgs, OutOfMemory }!Result
    {
        if (std.mem.eql(u8, id, "help")) return .show_help;
        if (std.mem.eql(u8, id, "exit")) return .quit;
        if (std.mem.eql(u8, id, "clear") or std.mem.eql(u8, id, "new")) return .clear_chat;
        if (std.mem.eql(u8, id, "save")) return .save_session;
        if (std.mem.eql(u8, id, "load")) return .load_session;
        if (std.mem.eql(u8, id, "think")) return .toggle_thinking;
        if (std.mem.eql(u8, id, "tools")) return .toggle_tools;
        if (std.mem.eql(u8, id, "top")) return .scroll_top;
        if (std.mem.eql(u8, id, "bottom")) return .scroll_bottom;
        if (std.mem.eql(u8, id, "subagents")) return .toggle_subagents;
        if (std.mem.eql(u8, id, "subagent")) {
            if (args.len > 0) {
                return .{ .set_input = try ctx.allocator.dupe(u8, args) };
            }
            // Palette selection: pre-fill the input with the goal prefix so
            // the user just types the research goal and presses Enter.
            return .{ .set_input = try ctx.allocator.dupe(u8, "/subagent ") };
        }
        if (std.mem.eql(u8, id, "compact")) return .compact_context;

        if (std.mem.eql(u8, id, "model")) {
            if (args.len == 0) {
                return menuModels(ctx);
            }
            return .{ .set_model = try ctx.allocator.dupe(u8, args) };
        }

        if (std.mem.eql(u8, id, "theme")) {
            if (args.len == 0) {
                return menuThemes(ctx);
            }
            return .{ .set_theme = try ctx.allocator.dupe(u8, args) };
        }

        if (std.mem.eql(u8, id, "apikey") or std.mem.eql(u8, id, "key")) {
            if (args.len == 0) {
                const title = try std.fmt.allocPrint(ctx.allocator, "Set API key for {s}", .{ctx.provider});
                return .{ .prompt = .{ .title = title, .placeholder = try ctx.allocator.dupe(u8, "sk-...") } };
            }
            return .{ .set_apikey = try ctx.allocator.dupe(u8, args) };
        }

        if (std.mem.eql(u8, id, "provider")) {
            if (args.len == 0) {
                return menuProviders(ctx);
            }
            return .{ .set_provider = try ctx.allocator.dupe(u8, args) };
        }

        if (std.mem.eql(u8, id, "lang")) {
            if (args.len == 0) {
                return .{ .notify = try ctx.allocator.dupe(u8, "Usage: /lang <en|ja|zh|pt>") };
            }
            return .{ .set_lang = try ctx.allocator.dupe(u8, args) };
        }

        if (std.mem.eql(u8, id, "status") or std.mem.eql(u8, id, "context")) return try handleStatus(ctx);
        if (std.mem.eql(u8, id, "workspace")) return try handleWorkspace(ctx);
        if (std.mem.eql(u8, id, "sessions")) return menuSessions(ctx);
        if (std.mem.eql(u8, id, "models")) return menuModels(ctx);
        if (std.mem.eql(u8, id, "providers")) return menuProviders(ctx);
        if (std.mem.eql(u8, id, "skills")) return menuSkills(ctx);
        if (std.mem.eql(u8, id, "sandbox")) return try handleSandbox(ctx);

        if (std.mem.eql(u8, id, "load")) {
            if (args.len == 0) return menuSessions(ctx);
            return .load_session;
        }
        if (std.mem.eql(u8, id, "note")) return menuNotes(ctx);
        if (std.mem.eql(u8, id, "memory")) return menuMemory(ctx);

        return error.UnknownCommand;
    }
};

pub fn dupeRow(allocator: std.mem.Allocator, cells: []const []const u8) ![]const []const u8 {
    var row: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (row.items) |c| allocator.free(c);
        row.deinit(allocator);
    }
    for (cells) |c| {
        try row.append(allocator, try allocator.dupe(u8, c));
    }
    return row.toOwnedSlice(allocator);
}

pub fn freeRow(allocator: std.mem.Allocator, row: []const []const u8) void {
    for (row) |c| allocator.free(c);
    allocator.free(row);
}

fn handleStatus(ctx: CommandContext) !Result {
    const pct: f64 = if (ctx.ctx_max > 0)
        @as(f64, @floatFromInt(ctx.tokens_used)) / @as(f64, @floatFromInt(ctx.ctx_max)) * 100.0
    else
        0.0;

    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| freeRow(ctx.allocator, row);
        rows.deinit(ctx.allocator);
    }

    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Model", ctx.model }));
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Provider", ctx.provider }));

    const tokens_str = try std.fmt.allocPrint(ctx.allocator, "{d}/{d}K", .{ ctx.tokens_used / 1000, ctx.ctx_max / 1000 });
    defer ctx.allocator.free(tokens_str);
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Tokens", tokens_str }));

    const usage_str = try std.fmt.allocPrint(ctx.allocator, "{d:.0}%", .{pct});
    defer ctx.allocator.free(usage_str);
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Usage", usage_str }));

    const cache_str = try std.fmt.allocPrint(ctx.allocator, "{d:.0}%", .{ctx.cache_hit_rate * 100.0});
    defer ctx.allocator.free(cache_str);
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Cache hit", cache_str }));

    return .{ .show_table = .{
        .title = "Status",
        .headers = &.{ "Key", "Value" },
        .rows = try rows.toOwnedSlice(ctx.allocator),
    } };
}

fn handleWorkspace(ctx: CommandContext) !Result {
    const cwd_ptr = std.c.getenv("PWD") orelse ".";
    const cwd = std.mem.sliceTo(cwd_ptr, 0);

    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |it| ctx.allocator.free(it);
        items.deinit(ctx.allocator);
    }
    try items.append(ctx.allocator, try ctx.allocator.dupe(u8, cwd));

    return .{ .show_list = .{
        .title = "Workspace",
        .items = try items.toOwnedSlice(ctx.allocator),
    } };
}

fn menuModels(ctx: CommandContext) !Result {
    var temp: std.ArrayList(SubItem) = .empty;
    defer {
        for (temp.items) |it| {
            ctx.allocator.free(it.label);
            ctx.allocator.free(it.desc);
            ctx.allocator.free(it.action);
        }
        temp.deinit(ctx.allocator);
    }
    for (model_catalog) |m| {
        const action = std.fmt.allocPrint(ctx.allocator, "/model {s}", .{m.id}) catch continue;
        const desc = std.fmt.allocPrint(ctx.allocator, "{s} — {d}K ctx", .{ m.provider, m.context_window / 1000 }) catch {
            ctx.allocator.free(action);
            continue;
        };
        const label = ctx.allocator.dupe(u8, m.name) catch {
            ctx.allocator.free(action);
            ctx.allocator.free(desc);
            continue;
        };
        temp.append(ctx.allocator, .{ .label = label, .desc = desc, .action = action }) catch {
            ctx.allocator.free(label);
            ctx.allocator.free(action);
            ctx.allocator.free(desc);
            continue;
        };
    }
    if (temp.items.len == 0) return .{ .notify = try ctx.allocator.dupe(u8, "No models available") };
    return .{ .submenu = try buildSubMenu(ctx.allocator, "Switch model", temp.items) };
}

fn menuSkills(ctx: CommandContext) !Result {
    var temp: std.ArrayList(SubItem) = .empty;
    defer {
        for (temp.items) |it| {
            ctx.allocator.free(it.label);
            ctx.allocator.free(it.desc);
            ctx.allocator.free(it.action);
        }
        temp.deinit(ctx.allocator);
    }
    if (ctx.skill_registry) |reg| {
        for (reg.list()) |sk| {
            const action = std.fmt.allocPrint(ctx.allocator, "/skill {s}", .{sk.name}) catch continue;
            const desc = std.fmt.allocPrint(ctx.allocator, "{s}", .{if (sk.description.len > 0) sk.description else "Skill"}) catch {
                ctx.allocator.free(action);
                continue;
            };
            const label = ctx.allocator.dupe(u8, sk.name) catch {
                ctx.allocator.free(action);
                ctx.allocator.free(desc);
                continue;
            };
            temp.append(ctx.allocator, .{ .label = label, .desc = desc, .action = action }) catch {
                ctx.allocator.free(label);
                ctx.allocator.free(action);
                ctx.allocator.free(desc);
                continue;
            };
        }
    }
    if (temp.items.len == 0) return .{ .notify = try ctx.allocator.dupe(u8, "No skills registered") };
    return .{ .submenu = try buildSubMenu(ctx.allocator, "Available skills", temp.items) };
}

fn menuNotes(ctx: CommandContext) !Result {
    const items = [_]SubItem{
        .{ .label = "Add a note", .desc = "Type note text after the prefix", .action = "/note add " },
        .{ .label = "List notes", .desc = "Show all saved notes", .action = "/note list" },
        .{ .label = "Clear notes", .desc = "Delete all notes", .action = "/note clear" },
    };
    return .{ .submenu = try buildSubMenu(ctx.allocator, "Notes", &items) };
}

fn menuMemory(ctx: CommandContext) !Result {
    const items = [_]SubItem{
        .{ .label = "Save a fact", .desc = "Type the fact after the prefix", .action = "/memory " },
        .{ .label = "Recall", .desc = "Query stored memory", .action = "/memory recall " },
    };
    return .{ .submenu = try buildSubMenu(ctx.allocator, "Agent memory", &items) };
}

fn buildSubMenu(allocator: std.mem.Allocator, title: []const u8, src: []const SubItem) !SubMenu {
    const items = try allocator.alloc(SubItem, src.len);
    var n: usize = 0;
    errdefer {
        for (items[0..n]) |it| {
            allocator.free(it.label);
            allocator.free(it.desc);
            allocator.free(it.action);
        }
        allocator.free(items);
    }
    for (src) |s| {
        items[n] = .{
            .label = try allocator.dupe(u8, s.label),
            .desc = try allocator.dupe(u8, s.desc),
            .action = try allocator.dupe(u8, s.action),
        };
        n += 1;
    }
    return .{ .title = try allocator.dupe(u8, title), .items = items };
}

pub fn freeSubMenu(allocator: std.mem.Allocator, menu: SubMenu) void {
    for (menu.items) |it| {
        allocator.free(it.label);
        allocator.free(it.desc);
        allocator.free(it.action);
    }
    allocator.free(menu.items);
    allocator.free(menu.title);
}

fn menuThemes(ctx: CommandContext) !Result {
    var temp: std.ArrayList(SubItem) = .empty;
    defer {
        for (temp.items) |it| {
            ctx.allocator.free(it.label);
            ctx.allocator.free(it.action);
        }
        temp.deinit(ctx.allocator);
    }

    for (theme.themes) |t| {
        const label = try ctx.allocator.dupe(u8, t.name);
        const action = try std.fmt.allocPrint(ctx.allocator, "/theme {s}", .{@tagName(t.id)});
        try temp.append(ctx.allocator, .{ .label = label, .desc = "Switch to this theme", .action = action });
    }

    const menu = try buildSubMenu(ctx.allocator, "Switch theme", temp.items);
    return .{ .submenu = menu };
}

fn menuProviders(ctx: CommandContext) !Result {
    var list: std.ArrayList(SubItem) = .empty;
    defer {
        for (list.items) |it| {
            ctx.allocator.free(it.label);
            ctx.allocator.free(it.action);
        }
        list.deinit(ctx.allocator);
    }

    if (ctx.subsystems_initialized) {
        const active = ctx.provider_mgr.active;
        const ids = try ctx.provider_mgr.listProviders();
        for (ids) |pid| {
            const resolved = ctx.provider_mgr.resolveModel(pid);
            const label = try std.fmt.allocPrint(ctx.allocator, "{s} ({s})", .{ pid, resolved });
            const action = try std.fmt.allocPrint(ctx.allocator, "/provider {s}", .{pid});
            const current = std.mem.eql(u8, pid, active);
            try list.append(ctx.allocator, .{
                .label = label,
                .desc = if (current) "Currently active provider" else "Activate this provider",
                .action = action,
            });
        }
    } else {
        try list.append(ctx.allocator, .{
            .label = try ctx.allocator.dupe(u8, "DeepSeek (default)"),
            .desc = "Activate this provider",
            .action = try ctx.allocator.dupe(u8, "/provider deepseek"),
        });
    }

    const menu = try buildSubMenu(ctx.allocator, "Switch provider", list.items);
    return .{ .submenu = menu };
}

fn menuSessions(ctx: CommandContext) !Result {
    const home_ptr = std.c.getenv("HOME") orelse {
        return .{ .notify = try ctx.allocator.dupe(u8, "HOME not set") };
    };
    const home = std.mem.sliceTo(home_ptr, 0);
    const dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/.zeepseek/sessions", .{home});
    defer ctx.allocator.free(dir_path);

    var list: std.ArrayList(SubItem) = .empty;
    defer {
        for (list.items) |it| {
            ctx.allocator.free(it.label);
            ctx.allocator.free(it.action);
        }
        list.deinit(ctx.allocator);
    }

    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch {
        return .{ .submenu = try buildSubMenu(ctx.allocator, "Saved sessions", &.{}) };
    };
    defer dir.close(ctx.io);

    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind == .file or entry.kind == .unknown) {
            const label = try ctx.allocator.dupe(u8, entry.name);
            const action = try std.fmt.allocPrint(ctx.allocator, "/load {s}", .{entry.name});
            try list.append(ctx.allocator, .{
                .label = label,
                .desc = "Load this session",
                .action = action,
            });
        }
    }

    const menu = try buildSubMenu(ctx.allocator, "Saved sessions", list.items);
    return .{ .submenu = menu };
}

fn handleSandbox(ctx: CommandContext) !Result {
    const status: []const u8 = if (ctx.sandbox != null) "active (Seatbelt)" else "not initialized";

    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| freeRow(ctx.allocator, row);
        rows.deinit(ctx.allocator);
    }

    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Sandbox", status }));
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Shell", "prompt" }));
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "File read", "auto_allow" }));
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "File write", "prompt" }));

    return .{ .show_table = .{
        .title = "Sandbox",
        .headers = &.{ "Policy", "Mode" },
        .rows = try rows.toOwnedSlice(ctx.allocator),
    } };
}

test "instant commands return direct results" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    try std.testing.expectEqual(Result.show_help, try Dispatcher.execute(ctx, "help", ""));
    try std.testing.expectEqual(Result.quit, try Dispatcher.execute(ctx, "exit", ""));
    try std.testing.expectEqual(Result.clear_chat, try Dispatcher.execute(ctx, "clear", ""));
}

test "model with args returns set_model" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    const result = try Dispatcher.execute(ctx, "model", "deepseek-v4");
    try std.testing.expectEqualStrings("deepseek-v4", result.set_model);
    alloc.free(result.set_model);
}

test "model without args returns submenu from catalog" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    const result = try Dispatcher.execute(ctx, "model", "");
    try std.testing.expectEqual(.submenu, std.meta.activeTag(result));
    try std.testing.expectEqualStrings("Switch model", result.submenu.title);
    try std.testing.expect(result.submenu.items.len > 0);
    try std.testing.expectEqualStrings("/model deepseek-chat", result.submenu.items[0].action);
    var found_catalog_item = false;
    for (result.submenu.items) |it| {
        if (std.mem.eql(u8, it.action, "/model deepseek-v4-flash")) found_catalog_item = true;
    }
    try std.testing.expect(found_catalog_item);
    freeSubMenu(alloc, result.submenu);
}

test "skills submenu is built from registry" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    var reg = try SkillRegistry.init(alloc);
    defer reg.deinit();
    var builtin_skills = @import("../skills/builtin.zig").BuiltinSkills{};
    const skills = try builtin_skills.loadAll(alloc);
    defer {
        for (skills) |*sk| sk.deinit(alloc);
        alloc.free(skills);
    }
    for (skills) |*sk| try reg.registerSkill(sk);

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .skill_registry = &reg,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    const result = try Dispatcher.execute(ctx, "skills", "");
    try std.testing.expectEqual(.submenu, std.meta.activeTag(result));
    try std.testing.expectEqualStrings("Available skills", result.submenu.title);
    try std.testing.expect(result.submenu.items.len > 0);
    var found_investigate = false;
    for (result.submenu.items) |it| {
        if (std.mem.eql(u8, it.action, "/skill investigate")) found_investigate = true;
    }
    try std.testing.expect(found_investigate);
    freeSubMenu(alloc, result.submenu);
}

test "subagent command fills input with the goal prefix" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    // Palette selection (no args) pre-fills the goal prefix.
    const result = try Dispatcher.execute(ctx, "subagent", "");
    defer alloc.free(result.set_input);
    try std.testing.expectEqual(.set_input, std.meta.activeTag(result));
    try std.testing.expectEqualStrings("/subagent ", result.set_input);

    // With an explicit goal, the args are forwarded as the input text.
    const with_goal = try Dispatcher.execute(ctx, "subagent", "scan the zephyr protocol");
    defer alloc.free(with_goal.set_input);
    try std.testing.expectEqualStrings("scan the zephyr protocol", with_goal.set_input);
}

test "provider without args returns submenu" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    const result = try Dispatcher.execute(ctx, "provider", "");
    try std.testing.expectEqual(.submenu, std.meta.activeTag(result));
    try std.testing.expectEqualStrings("Switch provider", result.submenu.title);
    try std.testing.expect(result.submenu.items.len > 0);
    try std.testing.expectEqualStrings("/provider deepseek", result.submenu.items[0].action);
    freeSubMenu(alloc, result.submenu);
}

test "provider with args returns set_provider" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    const result = try Dispatcher.execute(ctx, "provider", "openai");
    try std.testing.expectEqualStrings("openai", result.set_provider);
    alloc.free(result.set_provider);
}

test "unknown command returns error" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    try std.testing.expectError(error.UnknownCommand, Dispatcher.execute(ctx, "nope", ""));
}
