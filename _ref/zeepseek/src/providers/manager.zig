const std = @import("std");
const Provider = @import("mod.zig").Provider;
const Model = @import("models.zig").Model;

/// Default model used when no explicit model is selected.
pub const DefaultModel: []const u8 = "deepseek-v4-flash";

pub const ProviderConfig = struct {
    provider_id: []const u8,
    api_key: []const u8,
    base_url: ?[]const u8 = null,
    default_model: []const u8,
    extra_headers: ?std.StringHashMap([]const u8) = null,
};

pub const ProviderManager = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    active: []const u8,
    configs: std.StringHashMap(ProviderConfig),

    pub fn init(allocator: std.mem.Allocator) ProviderManager {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
            .active = "deepseek",
            .configs = std.StringHashMap(ProviderConfig).init(allocator),
        };
    }

    pub fn deinit(self: *ProviderManager) void {
        self.configs.deinit();
        self.arena.deinit();
    }

    pub fn addProvider(self: *ProviderManager, config: ProviderConfig) !void {
        const id = try self.arena.allocator().dupe(u8, config.provider_id);
        const api_key = try self.arena.allocator().dupe(u8, config.api_key);
        const default_model = try self.arena.allocator().dupe(u8, config.default_model);

        var cfg = config;
        cfg.provider_id = id;
        cfg.api_key = api_key;
        cfg.default_model = default_model;

        if (config.base_url) |url| {
            cfg.base_url = try self.arena.allocator().dupe(u8, url);
        }

        if (config.extra_headers) |_| {
            const headers = std.StringHashMap([]const u8).init(self.arena.allocator());
            cfg.extra_headers = headers;
        }

        try self.configs.put(id, cfg);
    }

    pub fn removeProvider(self: *ProviderManager, id: []const u8) void {
        _ = self.configs.remove(id);
        if (std.mem.eql(u8, self.active, id)) {
            self.active = "deepseek";
        }
    }

    pub fn setActive(self: *ProviderManager, id: []const u8) !void {
        if (self.configs.contains(id)) {
            self.active = try self.arena.allocator().dupe(u8, id);
        }
    }

    pub fn getActive(self: *const ProviderManager) ?ProviderConfig {
        return self.configs.get(self.active);
    }

    pub fn getProvider(self: *const ProviderManager, id: []const u8) ?ProviderConfig {
        return self.configs.get(id);
    }

    pub fn listProviders(self: *ProviderManager) ![]const []const u8 {
        const max = self.configs.count();
        const result = try self.arena.allocator().alloc([]const u8, max);
        var count: usize = 0;

        var it = self.configs.iterator();
        while (it.next()) |entry| {
            result[count] = entry.key_ptr.*;
            count += 1;
        }

        return result[0..count];
    }

    pub fn resolveEndpoint(self: *const ProviderManager, id: []const u8) []const u8 {
        if (self.configs.get(id)) |cfg| {
            if (cfg.base_url) |url| {
                return url;
            }
        }

        if (self.configs.get(id)) |cfg| {
            const provider = @import("mod.zig").findProvider(cfg.provider_id);
            if (provider) |p| {
                return p.endpoint;
            }
        }

        const provider = @import("mod.zig").findProvider(id);
        if (provider) |p| {
            return p.endpoint;
        }

        return "";
    }

    pub fn resolveApiKey(self: *const ProviderManager, provider_id: []const u8) ?[]const u8 {
        if (self.configs.get(provider_id)) |cfg| {
            return cfg.api_key;
        }
        return null;
    }

    pub fn resolveModel(self: *const ProviderManager, provider_id: []const u8) []const u8 {
        if (self.configs.get(provider_id)) |cfg| {
            return cfg.default_model;
        }
        return DefaultModel;
    }
};

test "provider manager init" {
    const alloc = std.testing.allocator;
    var mgr = ProviderManager.init(alloc);
    defer mgr.deinit();

    try std.testing.expectEqualSlices(u8, "deepseek", mgr.active);
}

test "provider manager add and get" {
    const alloc = std.testing.allocator;
    var mgr = ProviderManager.init(alloc);
    defer mgr.deinit();

    try mgr.addProvider(.{
        .provider_id = "openai",
        .api_key = "sk-test",
        .default_model = "gpt-4o",
    });

    const cfg = mgr.getProvider("openai");
    try std.testing.expect(cfg != null);
    try std.testing.expectEqualSlices(u8, "openai", cfg.?.provider_id);
    try std.testing.expectEqualSlices(u8, "sk-test", cfg.?.api_key);
}

test "provider manager set active" {
    const alloc = std.testing.allocator;
    var mgr = ProviderManager.init(alloc);
    defer mgr.deinit();

    try mgr.addProvider(.{
        .provider_id = "openai",
        .api_key = "sk-test",
        .default_model = "gpt-4o",
    });

    try mgr.setActive("openai");
    try std.testing.expectEqualSlices(u8, "openai", mgr.active);

    const active = mgr.getActive();
    try std.testing.expect(active != null);
    try std.testing.expectEqualSlices(u8, "openai", active.?.provider_id);
}

test "provider manager remove provider" {
    const alloc = std.testing.allocator;
    var mgr = ProviderManager.init(alloc);
    defer mgr.deinit();

    try mgr.addProvider(.{
        .provider_id = "openai",
        .api_key = "sk-test",
        .default_model = "gpt-4o",
    });

    try mgr.setActive("openai");
    mgr.removeProvider("openai");

    try std.testing.expectEqualSlices(u8, "deepseek", mgr.active);
    try std.testing.expect(mgr.getProvider("openai") == null);
}

test "provider manager resolve endpoint" {
    const alloc = std.testing.allocator;
    var mgr = ProviderManager.init(alloc);
    defer mgr.deinit();

    try mgr.addProvider(.{
        .provider_id = "ollama",
        .api_key = "local",
        .base_url = "http://custom:9000/v1",
        .default_model = "llama3",
    });

    const endpoint = mgr.resolveEndpoint("ollama");
    try std.testing.expectEqualSlices(u8, "http://custom:9000/v1", endpoint);
}

test "provider manager resolve default endpoint" {
    const alloc = std.testing.allocator;
    var mgr = ProviderManager.init(alloc);
    defer mgr.deinit();

    try mgr.addProvider(.{
        .provider_id = "ollama",
        .api_key = "local",
        .default_model = "llama3",
    });

    const endpoint = mgr.resolveEndpoint("ollama");
    try std.testing.expectEqualSlices(u8, "http://localhost:11434/v1", endpoint);
}

test "provider manager resolve model" {
    const alloc = std.testing.allocator;
    var mgr = ProviderManager.init(alloc);
    defer mgr.deinit();

    try mgr.addProvider(.{
        .provider_id = "openai",
        .api_key = "sk-test",
        .default_model = "gpt-4o",
    });

    const model = mgr.resolveModel("openai");
    try std.testing.expectEqualSlices(u8, "gpt-4o", model);
}
