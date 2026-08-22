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
    try std.testing.expectEqualSlices(u8, "deepseek-v4-flash", cfg.model);
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
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();
    var res = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "shell", .arguments = "{\"command\":\"echo hi\"}" });
    defer tool_builtin.freeResult(alloc, &res);
    try std.testing.expect(res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "hi") != null);
}

test "builtin file read write edit roundtrip" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();
    const path = "/tmp/zharness_test_file.txt";

    var w = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "file_write", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\",\"content\":\"hello\\n\"}" });
    defer tool_builtin.freeResult(alloc, &w);
    try std.testing.expect(w.success);

    var r = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "file_read", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\"}" });
    defer tool_builtin.freeResult(alloc, &r);
    try std.testing.expect(r.success);
    try std.testing.expectEqualSlices(u8, "hello\n", r.output);

    var e = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "file_edit", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\",\"old_string\":\"hello\",\"new_string\":\"world\"}" });
    defer tool_builtin.freeResult(alloc, &e);
    try std.testing.expect(e.success);

    var r2 = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "file_read", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\"}" });
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

test "agent loop seed and syncToSession" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try tool_reg.registerBuiltins(&reg);

    const cfg = agent.AgentConfig{ .system_prompt = "be brief", .max_turns = 4, .reasoning_effort = null };
    const ag = try agent.Agent.init(alloc, ctx.root, &cfg);
    defer ag.deinit(alloc);

    const client = model.ChatClient.init(alloc, ctx.io(), "https://api.deepseek.com/chat/completions", "deepseek-chat", "");
    var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null);
    defer loop.deinit();

    // Seed a prior transcript (as a resumed session would) and verify it can
    // be mirrored back into a session for persistence.
    try loop.seed(alloc, model.Message{ .role = .user, .content = "hello" });
    try loop.seed(alloc, model.Message{ .role = .assistant, .content = "hi", .tool_calls_json = null });
    try loop.seed(alloc, model.Message{ .role = .tool, .content = "ok", .tool_call_id = "1" });

    var s = try session.Session.init(alloc, "bridge");
    defer s.deinit();
    try loop.syncToSession(&s);

    try std.testing.expectEqual(@as(usize, 3), s.count());
    try std.testing.expectEqualStrings("hello", s.messages.items[0].content);
    try std.testing.expectEqual(model.Role.tool, s.messages.items[2].role);
    try std.testing.expectEqualStrings("1", s.messages.items[2].tool_call_id.?);
}

// Faithful multi-turn resume test: exercises the exact load -> seed -> sync
// -> save cycle that `main.zig` performs per turn (run/chat --session),
// using the real AgentLoop transcript and on-disk Session file I/O. The
// model round-trip is simulated by appending assistant replies directly, so
// this validates the resume wiring without needing an API key.
test "session multi-turn resume" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try tool_reg.registerBuiltins(&reg);

    const cfg = agent.AgentConfig{ .system_prompt = "sys", .max_turns = 4, .reasoning_effort = null };
    const ag = try agent.Agent.init(alloc, ctx.root, &cfg);
    defer ag.deinit(alloc);
    const client = model.ChatClient.init(alloc, io, "https://api.deepseek.com/chat/completions", "deepseek-chat", "");

    const path = "/tmp/zharness_resume_test.json";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    // Turn 1: fresh conversation -> persist.
    {
        var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null);
        defer loop.deinit();
        try loop.seed(alloc, model.Message{ .role = .user, .content = "q1" });
        try loop.seed(alloc, model.Message{ .role = .assistant, .content = "a1" });
        var s = try session.Session.init(alloc, "resume");
        defer s.deinit();
        try loop.syncToSession(&s);
        try s.save(io, path);
    }

    // Turn 2: resume (load + seed), append a turn, persist again.
    {
        var s = try session.Session.init(alloc, "resume");
        defer s.deinit();
        try s.load(io, path);
        try std.testing.expectEqual(@as(usize, 2), s.count()); // resumed with q1,a1

        var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null);
        defer loop.deinit();
        for (s.messages.items) |m| try loop.seed(alloc, m);
        try std.testing.expectEqual(@as(usize, 2), loop.messages.items.len); // seeded prior turns
        try loop.seed(alloc, model.Message{ .role = .user, .content = "q2" });
        try loop.seed(alloc, model.Message{ .role = .assistant, .content = "a2" });
        try loop.syncToSession(&s);
        try s.save(io, path);
    }

    // Turn 3: resume again, confirm both prior turns survived.
    {
        var s = try session.Session.init(alloc, "resume");
        defer s.deinit();
        try s.load(io, path);
        try std.testing.expectEqual(@as(usize, 4), s.count()); // q1,a1,q2,a2

        var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null);
        defer loop.deinit();
        for (s.messages.items) |m| try loop.seed(alloc, m);
        try loop.seed(alloc, model.Message{ .role = .user, .content = "q3" });
        try loop.seed(alloc, model.Message{ .role = .assistant, .content = "a3" });
        try loop.syncToSession(&s);
        try s.save(io, path);
    }

    // Final: full transcript intact and correctly ordered.
    {
        var s = try session.Session.init(alloc, "resume");
        defer s.deinit();
        try s.load(io, path);
        try std.testing.expectEqual(@as(usize, 6), s.count());
        try std.testing.expectEqualStrings("q1", s.messages.items[0].content);
        try std.testing.expectEqualStrings("a1", s.messages.items[1].content);
        try std.testing.expectEqualStrings("q2", s.messages.items[2].content);
        try std.testing.expectEqualStrings("a2", s.messages.items[3].content);
        try std.testing.expectEqualStrings("q3", s.messages.items[4].content);
        try std.testing.expectEqualStrings("a3", s.messages.items[5].content);
    }
}

test "session roundtrip" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();
    const path = "/tmp/zharness_session_test.json";

    var s = try session.Session.init(alloc, "s1");
    defer s.deinit();
    try s.addUser("hi");
    try s.addAssistant("ok", null);
    try s.save(io, path);

    var s2 = try session.Session.init(alloc, "s2");
    defer s2.deinit();
    try s2.load(io, path);

    try std.testing.expectEqual(s2.count(), s.count());

    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

test "model findMatchingBracket sample" {
    const alloc = std.testing.allocator;
    _ = alloc;
    // "[1,2]" — bracket starts at index 0, matching ']' is at index 4, so
    // the matcher returns the index past it (5).
    try std.testing.expectEqual(@as(?usize, 5), model.findMatchingBracket("[1,2]", 0));
}

// Regression test: the wire `tools` schema must be valid JSON. A stray
// literal `\n` (as previously existed in the git_status schema) makes the
// serialized request unparseable, and the API rejects the whole call with
// HTTP 400. Verify brace balance and absence of unexpected backslash-n.
test "tool registry builds valid json" {
    const alloc = std.testing.allocator;
    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try tool_reg.registerBuiltins(&reg);
    const j = try reg.buildToolsJson(alloc);
    defer alloc.free(j);

    const wrapped = try std.fmt.allocPrint(alloc, "[{s}]", .{j});
    defer alloc.free(wrapped);

    var depth: i32 = 0;
    for (wrapped) |c| {
        if (c == '{') depth += 1;
        if (c == '}') depth -= 1;
        try std.testing.expect(depth >= 0);
    }
    try std.testing.expectEqual(@as(i32, 0), depth);

    // No unescaped backslash followed by 'n' outside of string escapes.
    // Since our generators never emit a literal '\n', this catches the
    // regression where raw `\n` leaked into parameters_json.
    var i: usize = 0;
    while (i < j.len) : (i += 1) {
        if (j[i] == '\\') {
            i += 1;
            try std.testing.expect(i < j.len and j[i] != 'n');
        }
    }
}

// Multi-turn session resume integration test. Drives the real AgentLoop +
// Session + on-disk std.Io.Dir file I/O through a 3-turn conversation,
// exactly as `main.zig` does per turn for `run --session` / `chat --session`.
// The model round-trip is simulated by appending assistant messages directly
// (no API key needed), so this locks the resume + persistence contract:
//   turn 1 (fresh)  -> save [q1, a1]
//   turn 2 (resume) -> load, seed loop, append [q2, a2], save [q1,a1,q2,a2]
//   turn 3 (resume) -> load, seed loop, append [q3, a3], save [..,q3,a3]
//   final           -> load and assert full ordered transcript survives.
test "session multi-turn resume integration" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try tool_reg.registerBuiltins(&reg);

    const cfg = agent.AgentConfig{ .system_prompt = "sys", .max_turns = 4, .reasoning_effort = null };
    const ag = try agent.Agent.init(alloc, ctx.root, &cfg);
    defer ag.deinit(alloc);
    const client = model.ChatClient.init(alloc, io, "https://api.deepseek.com/chat/completions", "deepseek-chat", "");

    const path = "/tmp/zharness_resume_integration.json";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    // Helper that simulates a turn: resume (load+seed) if a session exists,
    // append user/assistant pair, then persist.
    const runTurn = struct {
        fn call(
            a: std.mem.Allocator,
            context: *cordis.Context,
            agent_p: *agent.Agent,
            cli: model.ChatClient,
            registry: *tool_reg.ToolRegistry,
            p: []const u8,
            q: []const u8,
            ans: []const u8,
            seed_only: bool,
        ) !usize {
            var s = try session.Session.init(a, "resume");
            defer s.deinit();
            s.load(context.io(), p) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            };
            var loop = try agent.AgentLoop.init(a, context, agent_p, cli, registry, "/tmp", null);
            defer loop.deinit();
            for (s.messages.items) |m| try loop.seed(a, m);
            if (!seed_only) {
                try loop.seed(a, model.Message{ .role = .user, .content = q });
                try loop.seed(a, model.Message{ .role = .assistant, .content = ans });
            }
            try loop.syncToSession(&s);
            try s.save(context.io(), p);
            return s.count();
        }
    }.call;

    // Turn 1: fresh.
    const n1 = try runTurn(alloc, ctx, ag, client, &reg, path, "q1", "a1", false);
    try std.testing.expectEqual(@as(usize, 2), n1);

    // Turn 2: resume (load + seed prior turns), append, save.
    const n2 = try runTurn(alloc, ctx, ag, client, &reg, path, "q2", "a2", false);
    try std.testing.expectEqual(@as(usize, 4), n2);

    // Turn 3: resume again, append.
    const n3 = try runTurn(alloc, ctx, ag, client, &reg, path, "q3", "a3", false);
    try std.testing.expectEqual(@as(usize, 6), n3);

    // Final: full ordered transcript survived all resumes.
    var s = try session.Session.init(alloc, "resume");
    defer s.deinit();
    try s.load(io, path);
    try std.testing.expectEqual(@as(usize, 6), s.count());
    const expect = [_][]const u8{ "q1", "a1", "q2", "a2", "q3", "a3" };
    for (expect, 0..) |e, idx| {
        try std.testing.expectEqualStrings(e, s.messages.items[idx].content);
    }
    // Roles are interleaved user/assistant correctly.
    try std.testing.expectEqual(model.Role.user, s.messages.items[0].role);
    try std.testing.expectEqual(model.Role.assistant, s.messages.items[1].role);
    try std.testing.expectEqual(model.Role.user, s.messages.items[4].role);
    try std.testing.expectEqual(model.Role.assistant, s.messages.items[5].role);
}

