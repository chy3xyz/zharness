//! zharness test root — compiled by `zig build test` (build.zig test module
//! root is `src/tests.zig`). Imports every module so the whole suite runs, and
//! adds integration-level tests that need no network / API key.
//!
//! NOTE: `session/session.zig` is authored in parallel by another agent. It is
//! imported directly per the spec; until that file lands this module will not
//! compile, but `zig build` is intentionally not run here.

const std = @import("std");
const clib = @import("clib.zig");
const cordis = @import("cordis");
const config = @import("config.zig");
const model = @import("model/model.zig");
const tool_reg = @import("tool/registry.zig");
const tool_builtin = @import("tool/builtin.zig");
const agent = @import("agent/agent.zig");
const session = @import("session/session.zig");

test "config load defaults" {
    const alloc = std.testing.allocator;
    var cfg = try config.load(alloc);
    defer cfg.deinit();
    try std.testing.expectEqualSlices(u8, "deepseek-chat", cfg.model);
    try std.testing.expectEqualSlices(u8, "deepseek", cfg.provider);
}

test "tool registry builds json" {
    const alloc = std.testing.allocator;
    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try tool_reg.registerBuiltins(&reg);
    const json = try reg.buildToolsJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "file_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "shell") != null);
}

test "builtin shell echo" {
    const alloc = std.testing.allocator;
    var res = try tool_builtin.execute(alloc, "/tmp", .{ .name = "shell", .arguments = "{\"command\":\"echo hi\"}" });
    defer tool_builtin.freeResult(alloc, &res);
    try std.testing.expect(res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "hi") != null);
}

test "builtin file read write edit roundtrip" {
    const alloc = std.testing.allocator;
    const path = "/tmp/zharness_test_file.txt";

    var w = try tool_builtin.execute(alloc, "/tmp", .{ .name = "file_write", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\",\"content\":\"hello\\n\"}" });
    defer tool_builtin.freeResult(alloc, &w);
    try std.testing.expect(w.success);

    var r = try tool_builtin.execute(alloc, "/tmp", .{ .name = "file_read", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\"}" });
    defer tool_builtin.freeResult(alloc, &r);
    try std.testing.expect(r.success);
    try std.testing.expectEqualSlices(u8, "hello\n", r.output);

    var e = try tool_builtin.execute(alloc, "/tmp", .{ .name = "file_edit", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\",\"old_string\":\"hello\",\"new_string\":\"world\"}" });
    defer tool_builtin.freeResult(alloc, &e);
    try std.testing.expect(e.success);

    var r2 = try tool_builtin.execute(alloc, "/tmp", .{ .name = "file_read", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\"}" });
    defer tool_builtin.freeResult(alloc, &r2);
    try std.testing.expect(r2.success);
    try std.testing.expectEqualSlices(u8, "world\n", r2.output);

    clib.removeFile(path);
}

test "agent loop construct" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try tool_reg.registerBuiltins(&reg);

    const cfg = agent.AgentConfig{ .system_prompt = "be brief", .max_turns = 4, .reasoning_effort = null };
    const ag = try agent.Agent.init(alloc, ctx.root, &cfg);
    defer ag.deinit(alloc);

    const io = ctx.io();
    const client = model.ChatClient.init(alloc, io, "https://api.deepseek.com/chat/completions", "deepseek-chat", "");

    var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null);
    defer loop.deinit();

    try std.testing.expect(true);
}

test "session roundtrip" {
    const alloc = std.testing.allocator;
    const path = "/tmp/zharness_session_test.json";

    var s = try session.Session.init(alloc, "s1");
    defer s.deinit();
    try s.addUser("hi");
    try s.addAssistant("ok", null);
    try s.save(path);

    var s2 = try session.Session.init(alloc, "s2");
    defer s2.deinit();
    try s2.load(path);

    try std.testing.expectEqual(s2.count(), s.count());

    clib.removeFile(path);
}

test "model findMatchingBracket sample" {
    const alloc = std.testing.allocator;
    _ = alloc;
    // "[1,2]" — bracket starts at index 0, matching ']' is at index 4, so
    // the matcher returns the index past it (5).
    try std.testing.expectEqual(@as(?usize, 5), model.findMatchingBracket("[1,2]", 0));
}
