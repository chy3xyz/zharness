const std = @import("std");

fn nowSeconds() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) == 0) {
        return tv.sec;
    }
    return 0;
}

pub const NotificationLevel = enum(u8) {
    debug = 0,
    info = 1,
    success = 2,
    warning = 3,
    err = 4,
};

pub const Notification = struct {
    title: []const u8,
    body: []const u8,
    level: NotificationLevel = .info,
};

pub const NotificationManager = struct {
    const Self = @This();

    enabled: bool,
    minimum_level: NotificationLevel,
    use_osc_9: bool = false,
    use_osc_99: bool = false,
    use_osc_777: bool = true,

    // Inline toast storage (no allocator needed)
    active_title: [64]u8 = undefined,
    active_body: [256]u8 = undefined,
    active_level: NotificationLevel = .info,
    active_time: i64 = 0,
    active_title_len: usize = 0,
    active_body_len: usize = 0,

    pub fn init() Self {
        return Self{
            .enabled = false,
            .minimum_level = .info,
            .use_osc_777 = false,
            .active_time = 0,
            .active_title_len = 0,
            .active_body_len = 0,
        };
    }

    pub fn notify(self: *Self, _: anytype, notif: Notification) !void {
        if (self.enabled and @intFromEnum(notif.level) < @intFromEnum(self.minimum_level)) return;
        self.setActive(notif.title, notif.body, notif.level);
    }

    pub fn info(self: *Self, w: anytype, title: []const u8, body: []const u8) !void {
        try self.notify(w, .{ .title = title, .body = body, .level = .info });
    }

    pub fn success(self: *Self, w: anytype, title: []const u8, body: []const u8) !void {
        try self.notify(w, .{ .title = title, .body = body, .level = .success });
    }

    pub fn warning(self: *Self, w: anytype, title: []const u8, body: []const u8) !void {
        try self.notify(w, .{ .title = title, .body = body, .level = .warning });
    }

    pub fn notifyError(self: *Self, w: anytype, title: []const u8, body: []const u8) !void {
        try self.notify(w, .{ .title = title, .body = body, .level = .err });
    }

    fn setActive(self: *Self, title: []const u8, body: []const u8, level: NotificationLevel) void {
        const tlen = @min(title.len, self.active_title.len);
        const blen = @min(body.len, self.active_body.len);
        @memcpy(self.active_title[0..tlen], title[0..tlen]);
        @memcpy(self.active_body[0..blen], body[0..blen]);
        self.active_title_len = tlen;
        self.active_body_len = blen;
        self.active_level = level;
        self.active_time = nowSeconds();
    }

    pub fn clearActive(self: *Self) void {
        self.active_time = 0;
        self.active_title_len = 0;
        self.active_body_len = 0;
    }

    pub fn getActive(self: *const Self) ?Notification {
        if (self.active_time == 0) return null;
        return .{
            .title = self.active_title[0..self.active_title_len],
            .body = self.active_body[0..self.active_body_len],
            .level = self.active_level,
        };
    }

    pub fn isExpired(self: *const Self, now: i64, timeout_secs: i64) bool {
        if (self.active_time == 0) return true;
        return now - self.active_time > timeout_secs;
    }

    pub fn setLevel(self: *Self, level: NotificationLevel) void {
        self.minimum_level = level;
    }

    pub fn enable(self: *Self) void {
        self.enabled = true;
    }

    pub fn disable(self: *Self) void {
        self.enabled = false;
    }
};

const NullWriter = struct {
    pub fn writeAll(_: *const @This(), _: []const u8) !void {}
};

test "notify records active notification when disabled" {
    var mgr = NotificationManager.init();
    try mgr.notify(NullWriter{}, .{ .title = "t", .body = "b", .level = .success });

    const active = mgr.getActive().?;
    try std.testing.expectEqualStrings("t", active.title);
    try std.testing.expectEqualStrings("b", active.body);
    try std.testing.expectEqual(NotificationLevel.success, active.level);
    try std.testing.expectEqual(NotificationLevel.info, mgr.minimum_level);
}

test "minimum_level gates sub-threshold notifications when enabled" {
    var mgr = NotificationManager.init();
    mgr.enable();
    mgr.setLevel(.warning);

    try mgr.info(NullWriter{}, "skipped", "no body");
    try std.testing.expect(mgr.getActive() == null);

    try mgr.warning(NullWriter{}, "kept", "yes");
    const active = mgr.getActive().?;
    try std.testing.expectEqualStrings("kept", active.title);
    try std.testing.expectEqual(NotificationLevel.warning, active.level);
}

test "title and body are truncated to fixed buffers" {
    var mgr = NotificationManager.init();
    var long: [300]u8 = undefined;
    @memset(long[0..], 'x');
    try mgr.info(NullWriter{}, &long, &long);

    const active = mgr.getActive().?;
    try std.testing.expectEqual(@as(usize, 64), active.title.len);
    try std.testing.expectEqual(@as(usize, 256), active.body.len);
}

test "clearActive and isExpired" {
    var mgr = NotificationManager.init();
    try mgr.success(NullWriter{}, "t", "b");
    try std.testing.expect(!mgr.isExpired(0, 100));

    mgr.clearActive();
    try std.testing.expect(mgr.getActive() == null);
    try std.testing.expect(mgr.isExpired(0, 100));

    try mgr.info(NullWriter{}, "t", "b");
    try std.testing.expect(mgr.isExpired(mgr.active_time + 11, 10));
}
