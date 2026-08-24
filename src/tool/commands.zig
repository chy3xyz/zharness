//! Minimal interactive command registry — upstream dsh-commands parity.
//!
//! Upstream `@deepseek-ai/dsh-commands` is a human-command registry shared by
//! interactive UI adapters (Web GUI). Commands are slash lines (`/name args`)
//! dispatched through `CommandRuntime.execute` without touching the model.
//! Plain CLI runs (`run`/`chat`) never see this registry — zharness keeps the
//! same posture: the registry exists but is inert until an interactive adapter
//! explicitly enables it.
//!
//! Ownership note: this module is intentionally tiny. It does NOT own session
//! persistence or approval gating; those belong to `questions.zig` (approval
//! store) and `sandbox.zig` (permission presets). It only stores definitions
//! and routes slash lines to handlers.
//!
//! Threading: one SpinLock (same design as `questions.zig`).

const std = @import("std");
const questions = @import("../server/apiproxy/questions.zig");

pub const CommandSpec = struct {
    /// Lowercase name without leading slash, e.g. "permission".
    name: []const u8,
    description: []const u8,
    /// Optional hint shown in discovery UI, e.g. "<preset>".
    input_hint: ?[]const u8 = null,
};

pub const Handler = *const fn (alloc: std.mem.Allocator, raw_input: []const u8) anyerror![]const u8;

// ── registry ────────────────────────────────────────────────────────────────

pub const Registry = struct {
    alloc: std.mem.Allocator,
    lock: questions.SpinLock = .{},
    // name (dupe) -> spec (duped strings). Handler stored alongside.
    entries: std.StringHashMap(Entry) = undefined,
    interactive_enabled: bool = false,

    const Entry = struct {
        spec: CommandSpec,
        handler: ?Handler = null,
    };

    pub fn initInPlace(self: *Registry, alloc: std.mem.Allocator) void {
        self.* = .{
            .alloc = alloc,
            .entries = std.StringHashMap(Entry).init(alloc),
            .interactive_enabled = false,
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.spec.name);
            self.alloc.free(e.value_ptr.spec.description);
            if (e.value_ptr.spec.input_hint) |h| self.alloc.free(h);
        }
        self.entries.deinit();
    }

    /// Enable or disable interactive exposure. Only when enabled does `list`
    /// return entries and `execute` dispatch. CLI runs leave this false.
    pub fn setInteractive(self: *Registry, v: bool) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.interactive_enabled = v;
    }

    pub fn isInteractive(self: *Registry) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.interactive_enabled;
    }

    pub fn register(self: *Registry, spec: CommandSpec, handler: ?Handler) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (!isValidName(spec.name)) return error.BadName;
        if (spec.description.len == 0) return error.BadDescription;
        if (self.entries.contains(spec.name)) return error.AlreadyRegistered;
        const key = try self.alloc.dupe(u8, spec.name);
        errdefer self.alloc.free(key);
        const name_dup = try self.alloc.dupe(u8, spec.name);
        errdefer self.alloc.free(name_dup);
        const desc_dup = try self.alloc.dupe(u8, spec.description);
        errdefer self.alloc.free(desc_dup);
        var hint_dup: ?[]const u8 = null;
        if (spec.input_hint) |h| {
            hint_dup = try self.alloc.dupe(u8, h);
        }
        try self.entries.put(key, .{
            .spec = .{ .name = name_dup, .description = desc_dup, .input_hint = hint_dup },
            .handler = handler,
        });
    }

    pub fn unregister(self: *Registry, name: []const u8) bool {
        self.lock.lock();
        defer self.lock.unlock();
        const entry = self.entries.fetchRemove(name) orelse return false;
        self.alloc.free(entry.key);
        self.alloc.free(entry.value.spec.name);
        self.alloc.free(entry.value.spec.description);
        if (entry.value.spec.input_hint) |h| self.alloc.free(h);
        return true;
    }

    /// List descriptors. Returns empty slice when interactive is disabled.
    pub fn list(self: *Registry, alloc: std.mem.Allocator) ![]CommandSpec {
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.interactive_enabled) return try alloc.alloc(CommandSpec, 0);
        var out: std.ArrayList(CommandSpec) = .empty;
        errdefer out.deinit(alloc);
        var it = self.entries.iterator();
        while (it.next()) |e| {
            try out.append(alloc, e.value_ptr.spec);
        }
        // Sort by name for stable discovery order.
        std.mem.sort(CommandSpec, out.items, {}, struct {
            fn less(_: void, a: CommandSpec, b: CommandSpec) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.less);
        return out.toOwnedSlice(alloc);
    }

    pub const ExecResult = struct {
        kind: enum { success, err },
        text: []const u8,
    };

    /// Parse and execute a slash line. Returns null when syntax unknown or not
    /// registered, or when interactive is disabled. Caller owns `result.text`
    /// (dupe with `alloc`).
    pub fn execute(self: *Registry, alloc: std.mem.Allocator, line: []const u8) !?ExecResult {
        const parsed = parseCommand(line) orelse return null;
        self.lock.lock();
        const entry = self.entries.get(parsed.name) orelse {
            self.lock.unlock();
            return null;
        };
        const enabled = self.interactive_enabled;
        const handler = entry.handler;
        const spec_name = entry.spec.name;
        _ = spec_name;
        self.lock.unlock();
        if (!enabled) return null;
        if (handler) |h| {
            const out = try h(alloc, parsed.raw_input);
            return .{ .kind = .success, .text = out };
        }
        // No handler: still succeeds with acknowledgement.
        const txt = try std.fmt.allocPrint(alloc, "command {s}", .{parsed.name});
        return .{ .kind = .success, .text = txt };
    }
};

fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Parsed slash command without normalizing trailing input.
pub const Parsed = struct { name: []const u8, raw_input: []const u8 };

pub fn parseCommand(line: []const u8) ?Parsed {
    if (line.len == 0 or line[0] != '/') return null;
    var i: usize = 1;
    // name: [a-z][a-z0-9_-]*
    if (i >= line.len) return null;
    const c0 = line[i];
    if (c0 < 'a' or c0 > 'z') return null;
    i += 1;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        const is_name = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!is_name) break;
    }
    const name = line[1..i];
    // Next char must be terminator or whitespace.
    if (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != '\n' and line[i] != '\r') return null;
    const raw = if (i < line.len) line[i..] else "";
    return .{ .name = name, .raw_input = raw };
}

// ── singleton (interactive-adapter gating) ──────────────────────────────────

var g_reg: ?*Registry = null;

pub fn sharedRegistry() !*Registry {
    if (g_reg) |r| return r;
    const r = try std.heap.page_allocator.create(Registry);
    r.initInPlace(std.heap.page_allocator);
    g_reg = r;
    return r;
}

pub fn takeSharedRegistry() ?*Registry {
    const r = g_reg;
    g_reg = null;
    return r;
}

// ── tests ───────────────────────────────────────────────────────────────────

test "parseCommand basics" {
    try std.testing.expect(parseCommand("") == null);
    try std.testing.expect(parseCommand("hello") == null);
    try std.testing.expect(parseCommand("/Bad") == null);
    const p = parseCommand("/permission workspace-write").?;
    try std.testing.expectEqualStrings("permission", p.name);
    try std.testing.expectEqualStrings(" workspace-write", p.raw_input);
    const q = parseCommand("/a").?;
    try std.testing.expectEqualStrings("a", q.name);
    try std.testing.expectEqualStrings("", q.raw_input);
}

test "registry only lists/executes when interactive enabled" {
    const alloc = std.testing.allocator;
    var reg: Registry = undefined;
    reg.initInPlace(alloc);
    defer reg.deinit();

    try reg.register(.{ .name = "permission", .description = "Switch preset" }, null);
    try reg.register(.{ .name = "help", .description = "Show help" }, null);

    // Disabled: list empty, execute null.
    {
        const lst = try reg.list(alloc);
        defer alloc.free(lst);
        try std.testing.expectEqual(@as(usize, 0), lst.len);
        try std.testing.expect((try reg.execute(alloc, "/permission")) == null);
    }
    reg.setInteractive(true);
    {
        const lst = try reg.list(alloc);
        defer alloc.free(lst);
        try std.testing.expectEqual(@as(usize, 2), lst.len);
        // Sorted: help, permission
        try std.testing.expectEqualStrings("help", lst[0].name);
        const res = (try reg.execute(alloc, "/permission foo")).?;
        defer alloc.free(res.text);
        try std.testing.expect(res.kind == .success);
    }
    reg.setInteractive(false);
    {
        const lst = try reg.list(alloc);
        defer alloc.free(lst);
        try std.testing.expectEqual(@as(usize, 0), lst.len);
    }
}

test "registry rejects bad names and duplicates" {
    const alloc = std.testing.allocator;
    var reg: Registry = undefined;
    reg.initInPlace(alloc);
    defer reg.deinit();
    try std.testing.expectError(error.BadName, reg.register(.{ .name = "Bad", .description = "x" }, null));
    try std.testing.expectError(error.BadDescription, reg.register(.{ .name = "ok", .description = "" }, null));
    try reg.register(.{ .name = "ok", .description = "x" }, null);
    try std.testing.expectError(error.AlreadyRegistered, reg.register(.{ .name = "ok", .description = "y" }, null));
    try std.testing.expect(reg.unregister("ok"));
    try std.testing.expect(!reg.unregister("ok"));
}
