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
const log_mod = @import("session/log.zig");

// Orphan modules wired by W1-integration — imported so their inline test
// blocks join `zig build test`.
const checkpoint = @import("session/checkpoint.zig");
const sandbox_mod = @import("sandbox/sandbox.zig");
const skill_mod = @import("skill/skill.zig");
const skill_loader = @import("skill/loader.zig");
const mem_persistent = @import("memory/persistent.zig");
const mem_working = @import("memory/working.zig");
const plan_mod = @import("agent/plan.zig");
const goal_mod = @import("agent/goal.zig");
const todo_mod = @import("todo/todo.zig");
const main_mod = @import("main.zig");
const preset_tools = @import("dynamic/preset_tools.zig");

// Swarm wave-2 modules (A/B/C/D/E/F/G) — pulled in via comptime so their
// inline test blocks join `zig build test` even where nothing references them.
comptime {
    _ = @import("model/provider.zig");
    _ = @import("model/anthropic.zig");
    _ = @import("model/ollama.zig");
    _ = @import("server/httpd.zig");
    _ = @import("server/api.zig");
    _ = @import("tool/webfetch.zig");
    _ = @import("agent/subagent.zig");
    _ = @import("agent/compaction.zig"); // context compaction: pure helpers + tests
    _ = @import("session/log.zig"); // append-only JSONL session log
    _ = @import("tool/present.zig"); // present (deliverables) tool
    _ = @import("tool/spawn_agent.zig");
    _ = @import("workflow/workflow.zig");
    _ = @import("workflow/executor.zig");
    _ = @import("workflow/run_report.zig");
    _ = @import("protocol/jsonrpc.zig");
    _ = @import("protocol/mcp.zig");
    _ = @import("tool/mcp_bridge.zig");
    _ = @import("obs.zig");
    _ = @import("presets.zig");
    _ = @import("pluginabi/capi.zig");
    _ = @import("pluginabi/ffi.zig");
    _ = @import("pluginabi/loader.zig");
    _ = @import("pluginabi/wasm_loader.zig");
    _ = @import("sandbox/wasm.zig");
    _ = @import("sandbox/native.zig"); // OS confinement (Seatbelt/bwrap)
    _ = @import("server/events.zig");
    _ = @import("server/static.zig");
    // Wave-4 hardening suites (corpus-driven parser robustness).
    _ = @import("fuzz/mutator.zig");
    _ = @import("fuzz/json.zig");
    _ = @import("fuzz/jsonrpc.zig");
    _ = @import("fuzz/mcp.zig");
    _ = @import("fuzz/http.zig");
    _ = @import("fuzz/workflow.zig");
    _ = @import("fuzz/skill.zig");
    _ = @import("fuzz/sse.zig");
    _ = @import("fuzz/checkpoint_session.zig");
    _ = @import("fuzz/manifest.zig");
    _ = @import("fuzz/envelope.zig");
    // Wave-5: dsh apiproxy surface + SSE run pump.
    _ = @import("server/apiproxy/jsonx.zig");
    _ = @import("server/apiproxy/router.zig");
    _ = @import("server/apiproxy/events_ws.zig");
    _ = @import("server/apiproxy/sessions.zig");
    _ = @import("server/apiproxy/inventory.zig");
    _ = @import("server/sse_run.zig");
    // Wave-6 feature domains.
    _ = @import("server/apiproxy/goals_rpc.zig");
    _ = @import("server/apiproxy/skills_rpc.zig");
    _ = @import("server/apiproxy/models_rpc.zig");
    _ = @import("server/apiproxy/presets_rpc.zig");
    _ = @import("server/apiproxy/perms_rpc.zig");
    _ = @import("server/apiproxy/search_rpc.zig");
    _ = @import("server/apiproxy/export_rpc.zig");
    _ = @import("server/apiproxy/subagents_rpc.zig");
    _ = @import("server/apiproxy/questions.zig");
    _ = @import("server/apiproxy/plan_frames.zig");
    _ = @import("server/apiproxy/jobs_rpc.zig");
    _ = @import("server/apiproxy/trajectory.zig");
    _ = @import("server/apiproxy/wf_replay.zig");
    _ = @import("server/apiproxy/attachments.zig");
    _ = @import("tool/ask_user.zig");
    _ = @import("tool/commands.zig");
    _ = @import("tool/attachments.zig");
    _ = @import("todo/todo.zig");
    _ = @import("web/provider.zig");
    // Dynamic Cordis runtime — pulls in src/dynamic/{registry,sandbox,lifecycle,wire}.zig.
    _ = @import("dynamic/lifecycle.zig");
    _ = @import("dynamic/registry.zig");
    _ = @import("dynamic/sandbox.zig");
    _ = @import("dynamic/wire.zig");
}

comptime {
    // Pull in the CLI flag parser so its inline tests join the suite.
    _ = @import("cli_flags.zig");
    _ = @import("sandbox/sandbox.zig");
}

test "config load defaults" {
    const alloc = std.testing.allocator;
    // Pure defaults: no env, no file layer (load() would read the real
    // ~/.zharness/config.toml — tests must not depend on the host machine).
    var cfg = try config.loadFromSnapshot(alloc, .{});
    defer cfg.deinit();
    try std.testing.expectEqualSlices(u8, "deepseek-v4-flash", cfg.model);
    try std.testing.expectEqualSlices(u8, "deepseek", cfg.provider);
}

test "config file layer applies and env beats file" {
    const alloc = std.testing.allocator;
    const doc =
        \\[model]
        \\provider = "ollama"
        \\model = "file-model"
        \\api_key = "file-key"
        \\endpoint = "http://file-endpoint"
        \\
        \\[agent]
        \\max_turns = 32
        \\stream = false
        \\
        \\[general]
        \\sandbox_mode = "none"
    ;
    // File only:
    var cfg = try config.loadFromSnapshot(alloc, .{ .config_toml = doc });
    defer cfg.deinit();
    try std.testing.expectEqualSlices(u8, "ollama", cfg.provider);
    try std.testing.expectEqualSlices(u8, "file-model", cfg.model);
    try std.testing.expectEqualSlices(u8, "file-key", cfg.api_key);
    try std.testing.expectEqual(@as(usize, 32), cfg.max_turns);
    try std.testing.expect(!cfg.stream);
    try std.testing.expect(cfg.sandbox_mode == .none);
    // Env beats file per key:
    var cfg2 = try config.loadFromSnapshot(alloc, .{
        .deepseek_api_key = "env-key",
        .endpoint = "http://env-endpoint",
        .config_toml = doc,
    });
    defer cfg2.deinit();
    try std.testing.expectEqualSlices(u8, "env-key", cfg2.api_key);
    try std.testing.expectEqualSlices(u8, "http://env-endpoint", cfg2.endpoint);
    // ...while file-only keys still apply:
    try std.testing.expectEqualSlices(u8, "file-model", cfg2.model);
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
    var res = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "shell", .arguments = "{\"command\":\"echo hi\"}" }, .none);
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

    var w = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "file_write", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\",\"content\":\"hello\\n\"}" }, .none);
    defer tool_builtin.freeResult(alloc, &w);
    try std.testing.expect(w.success);

    var r = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "file_read", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\"}" }, .none);
    defer tool_builtin.freeResult(alloc, &r);
    try std.testing.expect(r.success);
    try std.testing.expectEqualSlices(u8, "hello\n", r.output);

    var e = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "file_edit", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\",\"old_string\":\"hello\",\"new_string\":\"world\"}" }, .none);
    defer tool_builtin.freeResult(alloc, &e);
    try std.testing.expect(e.success);

    var r2 = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "file_read", .arguments = "{\"path\":\"/tmp/zharness_test_file.txt\"}" }, .none);
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

    var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null, null, null);
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
    var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null, null, null);
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
        var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null, null, null);
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

        var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null, null, null);
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

        var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null, null, null);
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
    std.Io.Dir.deleteFileAbsolute(io, "/tmp/zharness_session_test.json.jsonl") catch {};
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
            var loop = try agent.AgentLoop.init(a, context, agent_p, cli, registry, "/tmp", null, null, null);
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

test "session JSONL log round-trips and migrates from legacy JSON" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    const dir = try w1TempDir(alloc, "sessionlog");
    defer alloc.free(dir);
    try std.Io.Dir.createDirPath(.cwd(), io, dir);
    const path = try std.fmt.allocPrint(alloc, "{s}/s.json", .{dir});
    defer alloc.free(path);
    const log_path = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{path});
    defer alloc.free(log_path);

    // Save writes both the legacy JSON transcript and the JSONL log.
    var s = try session.Session.init(alloc, "s-log");
    defer s.deinit();
    try s.addUser("hello");
    try s.addAssistant("world", null);
    try s.save(io, path);

    const logged = try log_mod.readMessages(alloc, io, log_path);
    defer {
        for (logged) |*m| {
            alloc.free(m.content);
            if (m.tool_call_id) |t| alloc.free(t);
            if (m.tool_calls_json) |t| alloc.free(t);
        }
        alloc.free(logged);
    }
    try std.testing.expectEqual(@as(usize, 2), logged.len);
    try std.testing.expectEqualStrings("hello", logged[0].content);

    // A fresh Session loads from the log (preferred over the legacy JSON).
    var s2 = try session.Session.init(alloc, "s-log2");
    defer s2.deinit();
    try s2.load(io, path);
    try std.testing.expectEqual(@as(usize, 2), s2.count());

    // Incremental save appends only the new message.
    try s2.addUser("third");
    try s2.save(io, path);
    const logged2 = try log_mod.readMessages(alloc, io, log_path);
    defer {
        for (logged2) |*m| {
            alloc.free(m.content);
            if (m.tool_call_id) |t| alloc.free(t);
            if (m.tool_calls_json) |t| alloc.free(t);
        }
        alloc.free(logged2);
    }
    try std.testing.expectEqual(@as(usize, 3), logged2.len);
    try std.testing.expectEqualStrings("third", logged2[2].content);
}

// ── W1-integration tests (sandbox / checkpoint / extension wiring) ──────────

var w1_dir_counter: u32 = 0;

/// Fresh unique /tmp dir path (caller frees).
fn w1TempDir(alloc: std.mem.Allocator, prefix: []const u8) ![]u8 {
    w1_dir_counter += 1;
    return std.fmt.allocPrint(alloc, "/tmp/zh_w1_{s}_{d}_{d}", .{ prefix, clib.nowTimestamp(), w1_dir_counter });
}

test "builtin execute routes shell through sandbox in process mode" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    // Benign command runs fine under .process.
    var ok = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "shell", .arguments = "{\"command\":\"echo routed\"}" }, .process);
    defer tool_builtin.freeResult(alloc, &ok);
    try std.testing.expect(ok.success);
    try std.testing.expect(std.mem.indexOf(u8, ok.output, "routed") != null);

    // Denied command never executes; reason surfaces as err_msg.
    var denied = try tool_builtin.execute(
        alloc,
        io,
        "/tmp",
        .{ .name = "shell", .arguments = "{\"command\":\"echo nope && rm -rf /\"}" },
        .process,
    );
    defer tool_builtin.freeResult(alloc, &denied);
    try std.testing.expect(!denied.success);
    try std.testing.expect(std.mem.indexOf(u8, denied.err_msg.?, "blocked by sandbox policy") != null);
    try std.testing.expectEqualStrings("", denied.output);

    // Unknown tools still report as unknown in both modes.
    for ([_]config.Config.SandboxMode{ .none, .process }) |mode| {
        var unk = try tool_builtin.execute(alloc, io, "/tmp", .{ .name = "nope", .arguments = "{}" }, mode);
        defer tool_builtin.freeResult(alloc, &unk);
        try std.testing.expect(!unk.success);
        try std.testing.expectEqualStrings("unknown tool", unk.err_msg.?);
    }
}

test "agent loop saves checkpoints at boundaries and post-tool-batch" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try tool_reg.registerBuiltins(&reg);

    const cfg = agent.AgentConfig{ .system_prompt = "sys", .max_turns = 4, .reasoning_effort = null, .sandbox_mode = .none };
    const ag = try agent.Agent.init(alloc, ctx.root, &cfg);
    defer ag.deinit(alloc);
    const client = model.ChatClient.init(alloc, io, "https://localhost.invalid", "m", "");

    const dir = try w1TempDir(alloc, "cp");
    defer alloc.free(dir);
    defer std.Io.Dir.deleteTree(.cwd(), io, dir) catch {};

    var store = try checkpoint.CheckpointStore.init(alloc, dir);
    defer store.deinit();

    var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null, &store, null);
    defer loop.deinit();

    try loop.seed(alloc, model.Message{ .role = .user, .content = "q1" });
    try loop.seed(alloc, model.Message{ .role = .assistant, .content = "working", .tool_calls_json = "[{\"id\":\"c1\"}]" });

    // Turn boundary snapshot.
    loop.saveCheckpoint("turn 1");
    const latest = (try store.latest(io)).?;
    defer latest.deinit(alloc);
    try std.testing.expectEqualStrings("turn 1", latest.label);
    try std.testing.expectEqual(@as(usize, 2), latest.message_count);

    // Post-tool-batch snapshot appends another entry and captures tool state.
    try loop.seed(alloc, model.Message{ .role = .tool, .content = "result", .tool_call_id = "c1" });
    loop.saveCheckpoint("turn 1 post-tools");

    const metas = try store.list(io, alloc);
    defer {
        for (metas) |m| m.deinit(alloc);
        alloc.free(metas);
    }
    try std.testing.expectEqual(@as(usize, 2), metas.len);
    try std.testing.expectEqualStrings("turn 1", metas[0].label);
    try std.testing.expectEqualStrings("turn 1 post-tools", metas[1].label);
    try std.testing.expectEqual(@as(usize, 3), metas[1].message_count);

    // Round-trip: the stored snapshot decodes back into loop-shaped messages.
    var cp = try store.load(io, alloc, metas[1].id);
    defer cp.deinit(alloc);
    try std.testing.expectEqual(checkpoint.Role.tool, cp.messages[2].role);
    try std.testing.expectEqualStrings("c1", cp.messages[2].tool_call_id.?);

    // Without a wired store this must be a silent no-op.
    var bare_loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null, null, null);
    defer bare_loop.deinit();
    bare_loop.saveCheckpoint("ignored"); // must not crash
}

// Fake extension used to prove the loop-side plumbing without any of the
// concrete main.zig subsystems.
const FakeExt = struct {
    renders: usize = 0,

    fn render(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]const u8 {
        const self: *FakeExt = @ptrCast(@alignCast(ctx));
        self.renders += 1;
        return try alloc.dupe(u8, "## Fake section\nhello");
    }

    fn exec(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, call: tool_builtin.ToolCall) anyerror!?tool_builtin.ToolResult {
        _ = io;
        const self: *FakeExt = @ptrCast(@alignCast(ctx));
        _ = self;
        if (std.mem.eql(u8, call.name, "fake_ping")) {
            return tool_builtin.ToolResult{ .success = true, .output = try alloc.dupe(u8, "pong"), .err_msg = null };
        }
        return null; // unknown → builtin fallback
    }
};

test "agent loop extensions serve tools and fall back to builtins" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try tool_reg.registerBuiltins(&reg);

    const cfg = agent.AgentConfig{ .system_prompt = "base prompt", .max_turns = 4, .reasoning_effort = null, .sandbox_mode = .none };
    const ag = try agent.Agent.init(alloc, ctx.root, &cfg);
    defer ag.deinit(alloc);
    const client = model.ChatClient.init(alloc, io, "https://localhost.invalid", "m", "");

    var fake = FakeExt{};
    const ext = agent.Extensions{ .ctx = &fake, .renderContext = FakeExt.render, .executeTool = FakeExt.exec };

    var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null, null, &ext);
    defer loop.deinit();

    // Extension-served tool.
    var pong = try loop.dispatchTool(.{ .id = "1", .name = "fake_ping", .arguments = "{}" });
    defer tool_builtin.freeResult(alloc, &pong);
    try std.testing.expect(pong.success);
    try std.testing.expectEqualStrings("pong", pong.output);

    // Unknown name falls through to the builtin executors.
    var echo = try loop.dispatchTool(.{ .id = "2", .name = "shell", .arguments = "{\"command\":\"echo fallback-ok\"}" });
    defer tool_builtin.freeResult(alloc, &echo);
    try std.testing.expect(echo.success);
    try std.testing.expect(std.mem.indexOf(u8, echo.output, "fallback-ok") != null);

    // Context rendering hook works and reports through its own state.
    const section = try ext.renderContext(ext.ctx, alloc);
    defer alloc.free(section);
    try std.testing.expectEqualStrings("## Fake section\nhello", section);
    try std.testing.expectEqual(@as(usize, 1), fake.renders);
}

test "permission gate blocks mutating tools under read-only preset" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try tool_reg.registerBuiltins(&reg);

    const client = model.ChatClient.init(alloc, io, "https://localhost.invalid", "m", "");

    // read-only + ask: mutating tools are gated. No answerer is wired here, so
    // the ask fails closed into a denial.
    const cfg_ro = agent.AgentConfig{
        .system_prompt = "sys",
        .max_turns = 4,
        .reasoning_effort = null,
        .sandbox_mode = .none,
        .permission_preset = .read_only,
    };
    const ag_ro = try agent.Agent.init(alloc, ctx.root, &cfg_ro);
    defer ag_ro.deinit(alloc);
    var loop_ro = try agent.AgentLoop.init(alloc, ctx, ag_ro, client, &reg, "/tmp", null, null, null);
    defer loop_ro.deinit();

    var write = try loop_ro.dispatchTool(.{ .id = "1", .name = "file_write", .arguments = "{\"path\":\"/tmp/zh_gate.txt\",\"content\":\"x\"}" });
    defer tool_builtin.freeResult(alloc, &write);
    try std.testing.expect(!write.success);
    try std.testing.expect(std.mem.indexOf(u8, write.err_msg.?, "blocked by permission policy") != null);

    // A read-only tool is not permission-blocked (it never runs the gate).
    var read = try loop_ro.dispatchTool(.{ .id = "2", .name = "glob", .arguments = "{\"pattern\":\"*\"}" });
    defer tool_builtin.freeResult(alloc, &read);
    try std.testing.expect(!std.mem.startsWith(u8, read.err_msg orelse "", "blocked by permission policy"));

    // approval policy "never" rejects deterministically.
    const cfg_never = agent.AgentConfig{
        .system_prompt = "sys",
        .max_turns = 4,
        .reasoning_effort = null,
        .sandbox_mode = .none,
        .permission_preset = .read_only,
        .approval_mode = .never,
    };
    const ag_never = try agent.Agent.init(alloc, ctx.root, &cfg_never);
    defer ag_never.deinit(alloc);
    var loop_never = try agent.AgentLoop.init(alloc, ctx, ag_never, client, &reg, "/tmp", null, null, null);
    defer loop_never.deinit();
    var never = try loop_never.dispatchTool(.{ .id = "3", .name = "shell", .arguments = "{\"command\":\"echo nope\"}" });
    defer tool_builtin.freeResult(alloc, &never);
    try std.testing.expect(!never.success);
    try std.testing.expect(std.mem.indexOf(u8, never.err_msg.?, "approval policy 'never'") != null);

    // danger-full-access leaves mutating tools ungated.
    const cfg_danger = agent.AgentConfig{
        .system_prompt = "sys",
        .max_turns = 4,
        .reasoning_effort = null,
        .sandbox_mode = .none,
        .permission_preset = .danger_full_access,
    };
    const ag_danger = try agent.Agent.init(alloc, ctx.root, &cfg_danger);
    defer ag_danger.deinit(alloc);
    var loop_danger = try agent.AgentLoop.init(alloc, ctx, ag_danger, client, &reg, "/tmp", null, null, null);
    defer loop_danger.deinit();
    var ok = try loop_danger.dispatchTool(.{ .id = "4", .name = "shell", .arguments = "{\"command\":\"echo gate-ok\"}" });
    defer tool_builtin.freeResult(alloc, &ok);
    try std.testing.expect(ok.success);
}

const RecApprove = struct {
    tool_buf: [64]u8 = undefined,
    tool_len: usize = 0,

    fn render(_: *anyopaque, alloc: std.mem.Allocator) anyerror![]const u8 {
        return alloc.dupe(u8, "");
    }
    fn exec(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: tool_builtin.ToolCall) anyerror!?tool_builtin.ToolResult {
        return null;
    }
    fn approve(ctx: *anyopaque, tool_name: []const u8, _: []const u8) agent.ApprovalVerdict {
        const self: *RecApprove = @ptrCast(@alignCast(ctx));
        const n = @min(tool_name.len, self.tool_buf.len);
        @memcpy(self.tool_buf[0..n], tool_name[0..n]);
        self.tool_len = n;
        return .allowed;
    }
};

test "permission gate hands the tool name to the approval callback" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try tool_reg.registerBuiltins(&reg);

    const cfg = agent.AgentConfig{
        .system_prompt = "sys",
        .max_turns = 4,
        .reasoning_effort = null,
        .sandbox_mode = .none,
        .permission_preset = .read_only,
    };
    const ag = try agent.Agent.init(alloc, ctx.root, &cfg);
    defer ag.deinit(alloc);
    const client = model.ChatClient.init(alloc, io, "https://localhost.invalid", "m", "");

    var rec = RecApprove{};
    const ext = agent.Extensions{
        .ctx = &rec,
        .renderContext = RecApprove.render,
        .executeTool = RecApprove.exec,
        .approve = RecApprove.approve,
    };
    var loop = try agent.AgentLoop.init(alloc, ctx, ag, client, &reg, "/tmp", null, null, &ext);
    defer loop.deinit();

    var r = try loop.dispatchTool(.{ .id = "1", .name = "shell", .arguments = "{\"command\":\"echo approved\"}" });
    defer tool_builtin.freeResult(alloc, &r);
    try std.testing.expect(r.success);
    try std.testing.expectEqualStrings("shell", rec.tool_buf[0..rec.tool_len]);
}

test "loop extensions wiring: plan goal memory skills end to end" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    // Boards + working memory.
    var pb = plan_mod.PlanBoard.init(alloc);
    defer pb.deinit();
    var gb = goal_mod.GoalBoard.init(alloc);
    defer gb.deinit();
    var tb = todo_mod.TodoBoard.init(alloc);
    defer tb.deinit();
    var wm = mem_working.WorkingMemory.init(alloc);
    defer wm.deinit();

    // One sample skill.
    var reg = skill_mod.SkillRegistry.init(alloc);
    defer reg.deinit();
    const sample_doc =
        \\---
        \\name: debugging
        \\description: Root-cause playbook
        \\---
        \\## Steps
        \\1. Reproduce
        \\
    ;
    try reg.add(try skill_mod.parseSkillMd(alloc, sample_doc, "/skills/debugging/SKILL.md"));

    // Persistent memory in a fresh dir.
    const dir = try w1TempDir(alloc, "mem");
    defer alloc.free(dir);
    defer std.Io.Dir.deleteTree(.cwd(), io, dir) catch {};
    var store = try mem_persistent.PersistentStore.init(alloc, dir);
    defer store.deinit();
    try store.open(io);

    var lext = main_mod.LoopExtensions{
        .alloc = alloc,
        .io = io,
        .skills = &reg,
        .memory = &store,
        .working = &wm,
        .plan_board = &pb,
        .goal_board = &gb,
        .todo_board = &tb,
        .plugins = null,
        .cwd = dir,
    };
    const ext = lext.extensions();

    // plan_set replaces the checklist (markers parsed into statuses).
    {
        var r = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "plan_set",
            .arguments = "{\"tasks\":\"[x] done one\\n[~] working\\nplain pending\\n\\n[!] blocked one\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &r);
        try std.testing.expect(r.success);
        try std.testing.expectEqual(@as(usize, 4), pb.count());
        try std.testing.expectEqual(plan_mod.TaskStatus.done, pb.tasks.items[0].status);
        try std.testing.expectEqual(plan_mod.TaskStatus.in_progress, pb.tasks.items[1].status);
        try std.testing.expectEqual(plan_mod.TaskStatus.pending, pb.tasks.items[2].status);
        try std.testing.expectEqual(plan_mod.TaskStatus.blocked, pb.tasks.items[3].status);
    }

    // plan_update delegation + plan_add.
    {
        var r = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "plan_update",
            .arguments = "{\"task_id\":2,\"status\":\"done\",\"note\":\"verified\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &r);
        try std.testing.expect(r.success);
        try std.testing.expectEqual(plan_mod.TaskStatus.done, pb.tasks.items[1].status);

        var r2 = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "plan_add",
            .arguments = "{\"text\":\"extra task\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &r2);
        try std.testing.expect(r2.success);
        try std.testing.expectEqual(@as(usize, 5), pb.count());

        // Bad args become failed results, not errors.
        var bad = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "plan_update",
            .arguments = "{\"task_id\":999,\"status\":\"done\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &bad);
        try std.testing.expect(!bad.success);
    }

    // goal_set text mirrors into working memory; status transition works.
    {
        var r = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "goal_set",
            .arguments = "{\"text\":\"ship zharness\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &r);
        try std.testing.expect(r.success);
        try std.testing.expectEqualStrings("ship zharness", gb.current().?.text);
        try std.testing.expectEqualStrings("ship zharness", wm.get("goal").?);

        var r2 = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "goal_set",
            .arguments = "{\"status\":\"achieved\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &r2);
        try std.testing.expect(r2.success);
        try std.testing.expectEqual(goal_mod.Status.achieved, gb.current().?.status);

        var bad = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "goal_set",
            .arguments = "{}",
        })).?;
        defer tool_builtin.freeResult(alloc, &bad);
        try std.testing.expect(!bad.success);
    }

    // skill_use returns the body; unknown names fail gracefully.
    {
        var r = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "skill_use",
            .arguments = "{\"name\":\"debugging\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &r);
        try std.testing.expect(r.success);
        try std.testing.expect(std.mem.indexOf(u8, r.output, "1. Reproduce") != null);

        var bad = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "skill_use",
            .arguments = "{\"name\":\"missing\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &bad);
        try std.testing.expect(!bad.success);
    }

    // memory_set / memory_get round-trip against the real backing file.
    {
        var set = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "memory_set",
            .arguments = "{\"key\":\"user.color\",\"value\":\"cobalt\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &set);
        try std.testing.expect(set.success);

        var get = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "memory_get",
            .arguments = "{\"key\":\"user.color\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &get);
        try std.testing.expect(get.success);
        try std.testing.expectEqualStrings("cobalt", get.output);

        var miss = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "memory_get",
            .arguments = "{\"key\":\"absent.key\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &miss);
        try std.testing.expect(miss.success);
        try std.testing.expect(std.mem.indexOf(u8, miss.output, "no value stored") != null);

        var badkey = (try ext.executeTool(ext.ctx, alloc, io, .{
            .name = "memory_set",
            .arguments = "{\"key\":\"bad key!\",\"value\":\"v\"}",
        })).?;
        defer tool_builtin.freeResult(alloc, &badkey);
        try std.testing.expect(!badkey.success);
    }

    // Unhandled names return null so builtin executors take over.
    try std.testing.expect((try ext.executeTool(ext.ctx, alloc, io, .{
        .name = "file_read",
        .arguments = "{}",
    })) == null);

    // Dynamic context section joins every active subsystem.
    {
        const section = try ext.renderContext(ext.ctx, alloc);
        defer alloc.free(section);
        try std.testing.expect(std.mem.indexOf(u8, section, "Available skills") != null);
        try std.testing.expect(std.mem.indexOf(u8, section, "## Current goal [achieved]") != null);
        try std.testing.expect(std.mem.indexOf(u8, section, "## Plan") != null);
        try std.testing.expect(std.mem.indexOf(u8, section, "## Working memory") != null);
        try std.testing.expect(std.mem.indexOf(u8, section, "goal: ship zharness") != null);
    }
}

test "registerExtensionTools respects availability flags" {
    const alloc = std.testing.allocator;

    var full = try tool_reg.ToolRegistry.init(alloc);
    defer full.deinit();
    try main_mod.registerExtensionTools(&full, .{ .skills = true, .memory = true });
    for ([_][]const u8{ "plan_add", "plan_update", "plan_set", "goal_set", "todo_write", "skill_use", "memory_get", "memory_set" }) |n| {
        try std.testing.expect(full.contains(n));
    }
    // Wire schema must be valid JSON-ish: braces balanced overall.
    const j = try full.buildToolsJson(alloc);
    defer alloc.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"skill_use\"") != null);

    var minimal = try tool_reg.ToolRegistry.init(alloc);
    defer minimal.deinit();
    try main_mod.registerExtensionTools(&minimal, .{ .skills = false, .memory = false });
    try std.testing.expect(!minimal.contains("skill_use"));
    try std.testing.expect(!minimal.contains("memory_get"));
    try std.testing.expect(minimal.contains("plan_add"));
    try std.testing.expect(minimal.contains("todo_write"));
    // Dynamic-Cordis tools register unconditionally (ask_user precedent):
    // availability is decided at execute time by the setCordisCtx slot.
    for ([_][]const u8{ "cordis_define", "cordis_run", "cordis_stop", "cordis_undefine", "cordis_inspect" }) |n| {
        try std.testing.expect(minimal.contains(n));
        try std.testing.expect(full.contains(n));
    }
}

test "cordis tools route through loop extensions to preset_tools" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();

    var pb = plan_mod.PlanBoard.init(alloc);
    defer pb.deinit();
    var gb = goal_mod.GoalBoard.init(alloc);
    defer gb.deinit();
    var tb = todo_mod.TodoBoard.init(alloc);
    defer tb.deinit();

    var lext = main_mod.LoopExtensions{
        .alloc = alloc,
        .io = io,
        .plan_board = &pb,
        .goal_board = &gb,
        .todo_board = &tb,
        .cwd = "/tmp",
    };
    const ext = lext.extensions();

    // No wiring slot installed: the call must degrade to the teaching error,
    // never touch the lifecycle.
    preset_tools.clearCordisCtx();
    var r = (try ext.executeTool(ext.ctx, alloc, io, .{
        .name = "cordis_inspect",
        .arguments = "{}",
    })).?;
    defer tool_builtin.freeResult(alloc, &r);
    try std.testing.expect(!r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.err_msg.?, "not wired") != null);
}

test "durable goal revisions survive session restart" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();
    const path = "/tmp/zharness_goal_durable_test.json";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    defer std.Io.Dir.deleteFile(.cwd(), io, "/tmp/zharness_goal_durable_test.json.projections") catch {};

    var s1 = try session.Session.init(alloc, "dur-goal");
    defer s1.deinit();
    var gb1 = goal_mod.GoalBoard.init(alloc);
    defer gb1.deinit();

    try gb1.set("ship feature");
    try std.testing.expectEqual(@as(u64, 1), gb1.current().?.revision);
    _ = gb1.pause();
    try std.testing.expectEqual(goal_mod.Phase.paused, gb1.current().?.phase);
    _ = gb1.@"resume"();
    try std.testing.expectEqual(goal_mod.Phase.active, gb1.current().?.phase);
    // edit bumps revision again
    try gb1.set("ship feature v2");
    try std.testing.expectEqual(@as(u64, 4), gb1.current().?.revision);
    // sync to session and persist
    try gb1.syncToSession(&s1);
    try s1.addUser("hello");
    try s1.save(io, path);

    // load into fresh board/session
    var s2 = try session.Session.init(alloc, "dur-goal");
    defer s2.deinit();
    try s2.load(io, path);
    var gb2 = goal_mod.GoalBoard.init(alloc);
    defer gb2.deinit();
    try gb2.restoreFromSession(&s2);
    try std.testing.expectEqualStrings("ship feature v2", gb2.current().?.text);
    try std.testing.expectEqual(@as(u64, 4), gb2.current().?.revision);
    try std.testing.expectEqual(goal_mod.Phase.active, gb2.current().?.phase);
    try std.testing.expect(s2.stored_goal != null);
    try std.testing.expectEqual(@as(usize, 4), s2.goal_history.items.len); // 4 mutations logged
}

test "durable todo_write projection survives restart distinct from plan" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();
    const path = "/tmp/zharness_todo_durable_test.json";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    defer std.Io.Dir.deleteFile(.cwd(), io, "/tmp/zharness_todo_durable_test.json.projections") catch {};

    var s1 = try session.Session.init(alloc, "dur-todo");
    defer s1.deinit();

    var tb1 = todo_mod.TodoBoard.init(alloc);
    defer tb1.deinit();
    var pb1 = plan_mod.PlanBoard.init(alloc);
    defer pb1.deinit();

    // todo_write replaces whole list
    const r = try todo_mod.executeTool(&tb1, "todo_write", "{\"todos\":[{\"content\":\"a\",\"status\":\"pending\"},{\"content\":\"b\",\"status\":\"in_progress\"}]}", alloc);
    defer alloc.free(r);
    try std.testing.expectEqual(@as(usize, 2), tb1.count());
    // plan remains empty distinct
    try std.testing.expectEqual(@as(usize, 0), pb1.count());
    _ = try pb1.addTask("plan task");
    try std.testing.expectEqual(@as(usize, 1), pb1.count());
    try std.testing.expectEqual(@as(usize, 2), tb1.count());

    try tb1.syncToSession(&s1);
    try s1.save(io, path);

    var s2 = try session.Session.init(alloc, "dur-todo");
    defer s2.deinit();
    try s2.load(io, path);
    var tb2 = todo_mod.TodoBoard.init(alloc);
    defer tb2.deinit();
    try tb2.restoreFromSession(&s2);
    try std.testing.expectEqual(@as(usize, 2), tb2.count());
    try std.testing.expectEqualStrings("a", tb2.items.items[0].content);
    try std.testing.expectEqual(todo_mod.TodoStatus.in_progress, tb2.items.items[1].status);
    // plan not persisted via todo sidecar: fresh plan remains empty
    var pb2 = plan_mod.PlanBoard.init(alloc);
    defer pb2.deinit();
    try std.testing.expectEqual(@as(usize, 0), pb2.count());
    // but todo revision preserved
    try std.testing.expectEqual(tb1.revision, tb2.revision);
}

test "loop extensions todo_write distinct from plan_*" {
    const alloc = std.testing.allocator;
    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();
    const io = ctx.io();
    var pb = plan_mod.PlanBoard.init(alloc);
    defer pb.deinit();
    var gb = goal_mod.GoalBoard.init(alloc);
    defer gb.deinit();
    var tb = todo_mod.TodoBoard.init(alloc);
    defer tb.deinit();
    var wm = mem_working.WorkingMemory.init(alloc);
    defer wm.deinit();
    var lext = main_mod.LoopExtensions{
        .alloc = alloc,
        .io = io,
        .working = &wm,
        .plan_board = &pb,
        .goal_board = &gb,
        .todo_board = &tb,
        .cwd = "/tmp",
    };
    const ext = lext.extensions();
    // todo_write works
    var r1 = (try ext.executeTool(ext.ctx, alloc, io, .{ .name = "todo_write", .arguments = "{\"todos\":[{\"content\":\"t1\",\"status\":\"pending\"}]}" })).?;
    defer tool_builtin.freeResult(alloc, &r1);
    try std.testing.expect(r1.success);
    try std.testing.expectEqual(@as(usize, 1), tb.count());
    // plan_* still works distinct
    var r2 = (try ext.executeTool(ext.ctx, alloc, io, .{ .name = "plan_add", .arguments = "{\"text\":\"p1\"}" })).?;
    defer tool_builtin.freeResult(alloc, &r2);
    try std.testing.expect(r2.success);
    try std.testing.expectEqual(@as(usize, 1), pb.count());
    try std.testing.expectEqual(@as(usize, 1), tb.count());
    // context rendering contains both sections
    const sec = try ext.renderContext(ext.ctx, alloc);
    defer alloc.free(sec);
    try std.testing.expect(std.mem.indexOf(u8, sec, "## Todos") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec, "## Plan") != null);
}

test "P2 ask_user alias and canonical" {
    const ask_user = @import("tool/ask_user.zig");
    try std.testing.expectEqualStrings("ask_user_question", ask_user.canonical_name);
    try std.testing.expectEqualStrings("ask_user", ask_user.alias_name);
    try std.testing.expect(ask_user.isCanonicalName("ask_user_question"));
    try std.testing.expect(!ask_user.isCanonicalName("ask_user"));
    try std.testing.expect(ask_user.isAskUserTool("ask_user"));
    try std.testing.expect(ask_user.isAskUserTool("ask_user_question"));
    try std.testing.expect(!ask_user.isAskUserTool("other"));

    const alloc = std.testing.allocator;
    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try ask_user.registerAll(&reg);
    try std.testing.expect(reg.contains("ask_user"));
    try std.testing.expect(reg.contains("ask_user_question"));
    // second register is idempotent
    try ask_user.registerAll(&reg);
}

test "P2 ask_user subagent exclusion fails fast" {
    const ask_user = @import("tool/ask_user.zig");
    const questions = @import("server/apiproxy/questions.zig");
    const alloc = std.testing.allocator;
    var store: questions.Store = undefined;
    store.initInPlace(alloc);
    defer store.pendings.deinit(alloc);
    var g: ask_user.AskCtx = .{ .store = &store, .session_id = "s1", .publish = struct {
        fn f(_: []const u8) void {}
    }.f, .is_subagent = true };
    ask_user.setAskCtx(&g);
    defer ask_user.clearAskCtx();
    const r = try ask_user.execute(alloc, .{ .name = "ask_user", .arguments = "{\"question\":\"hi\"}" });
    defer ask_user.freeResult(alloc, &r);
    try std.testing.expect(!r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.err_msg.?, "owned by another live agent") != null);
    // Non-subagent with Canonical name still hits not-wired / validation path, not delegated
    g.is_subagent = false;
    g.timeout_ms = 10;
    g.poll_ms = 1;
    const r2 = try ask_user.execute(alloc, .{ .name = "ask_user_question", .arguments = "{\"questions\":[{\"id\":\"q1\",\"question\":\"pick?\"}]}" });
    defer ask_user.freeResult(alloc, &r2);
    // Should attempt to ask (publish present) then timeout quickly, not delegated.
    try std.testing.expect(std.mem.indexOf(u8, r2.err_msg orelse "", "owned by another") == null);
    try std.testing.expect(std.mem.indexOf(u8, r2.err_msg orelse "", "cancelled or timed out") != null);
}

test "P2 approval fail-closed before escalation" {
    const questions = @import("server/apiproxy/questions.zig");
    const alloc = std.testing.allocator;
    var store: questions.ApprovalStore = undefined;
    store.initInPlace(alloc);
    defer store.deinit();
    // Default is ask without answerer => unavailable => check fails closed
    try std.testing.expectEqual(questions.ApprovalOutcome.unavailable, store.check("sess-1"));
    try std.testing.expect(!store.checkFailClosed("sess-1"));
    // never => rejected
    try store.setPolicy("sess-1", .never);
    try std.testing.expectEqual(questions.ApprovalPolicy.never, store.effectivePolicy("sess-1"));
    try std.testing.expectEqual(questions.ApprovalOutcome.rejected, store.check("sess-1"));
    // ask with answerer => allowed_once
    try store.setPolicy("sess-1", .ask);
    store.setHasAnswerer(true);
    try std.testing.expectEqual(questions.ApprovalOutcome.allowed_once, store.check("sess-1"));
    try std.testing.expect(store.checkFailClosed("sess-1"));
    store.setHasAnswerer(false);
    try std.testing.expectEqual(questions.ApprovalOutcome.unavailable, store.check("sess-1"));
}

test "P2 permission presets map to sandbox+approval" {
    const sandbox = @import("sandbox/sandbox.zig");
    try std.testing.expectEqual(sandbox.PresetId.workspace_write, sandbox.presetForConfig(.process, "ask"));
    try std.testing.expectEqual(sandbox.PresetId.danger_full_access, sandbox.presetForConfig(.off, "never"));
    try std.testing.expectEqual(sandbox.PresetId.custom, sandbox.presetForConfig(.process, "never"));
    const m = sandbox.configForPreset("workspace-write").?;
    try std.testing.expectEqual(sandbox.Level.process, m.level);
    try std.testing.expectEqualStrings("ask", m.approval);
    try std.testing.expect(sandbox.configForPreset("custom") == null);
    try std.testing.expect(sandbox.configForPreset("bogus") == null);
    // cli_flags parsing of new flags
    const cli = @import("cli_flags.zig");
    const f = try cli.parseSubFlags(&.{ "--approval", "never", "--permission-preset", "danger-full-access" }, 0);
    try std.testing.expectEqualStrings("never", f.approval.?);
    try std.testing.expectEqualStrings("danger-full-access", f.permission_preset.?);
}

test "P2 command registry only interactive" {
    const commands = @import("tool/commands.zig");
    const alloc = std.testing.allocator;
    var reg: commands.Registry = undefined;
    reg.initInPlace(alloc);
    defer reg.deinit();
    try reg.register(.{ .name = "permission", .description = "Switch preset" }, null);
    // CLI mode (not interactive) => invisible
    try std.testing.expect(!reg.isInteractive());
    {
        const lst = try reg.list(alloc);
        defer alloc.free(lst);
        try std.testing.expectEqual(@as(usize, 0), lst.len);
    }
    try std.testing.expect((try reg.execute(alloc, "/permission foo")) == null);
    // Interactive adapter enables it
    reg.setInteractive(true);
    try std.testing.expect(reg.isInteractive());
    {
        const lst = try reg.list(alloc);
        defer alloc.free(lst);
        try std.testing.expectEqual(@as(usize, 1), lst.len);
        try std.testing.expectEqualStrings("permission", lst[0].name);
    }
    const res = (try reg.execute(alloc, "/permission workspace-write")).?;
    defer alloc.free(res.text);
    try std.testing.expect(res.kind == .success);
    reg.setInteractive(false);
}

test "P2 web provider seam selection and tool schemas" {
    const web_provider = @import("web/provider.zig");
    const webfetch = @import("tool/webfetch.zig");
    const mcp_bridge = @import("tool/mcp_bridge.zig");
    const alloc = std.testing.allocator;
    web_provider.clearAll(alloc);
    defer web_provider.clearAll(alloc);

    // Seam starts empty; ensureWebProviders seeds the two native providers.
    try std.testing.expectEqual(@as(usize, 0), web_provider.fetchProviderCount());
    try webfetch.ensureWebProviders(alloc);
    try std.testing.expectEqual(@as(usize, 1), web_provider.fetchProviderCount());
    try std.testing.expectEqual(@as(usize, 1), web_provider.searchProviderCount());
    try std.testing.expect(web_provider.hasFetchProvider("curl"));
    try std.testing.expect(web_provider.hasSearchProvider("duckduckgo"));
    try std.testing.expectEqualStrings("curl", web_provider.activeFetchName().?);
    try std.testing.expectEqualStrings("duckduckgo", web_provider.activeSearchName().?);

    // Mock provider proves selection is respected.
    const mockFetch = struct {
        fn f(_: ?*anyopaque, a: std.mem.Allocator, _: []const u8, _: usize) anyerror!@import("tool/builtin.zig").ToolResult {
            return .{ .success = true, .output = try a.dupe(u8, "mock-ok"), .err_msg = null };
        }
    }.f;
    try web_provider.registerFetchProvider(alloc, .{ .name = "alt-fetch", .description = "alt", .fetchFn = mockFetch });
    try web_provider.setActiveFetchProvider(alloc, "alt-fetch");
    try std.testing.expectEqualStrings("alt-fetch", web_provider.activeFetchName().?);
    const p = web_provider.getActiveFetchProvider().?;
    var r = try p.fetchFn(p.ctx, alloc, "http://example.com", 1024);
    defer @import("tool/builtin.zig").freeResult(alloc, &r);
    try std.testing.expectEqualStrings("mock-ok", r.output);

    // Unknown provider switch is rejected.
    try std.testing.expectError(error.UnknownProvider, web_provider.setActiveFetchProvider(alloc, "ghost"));

    // Tool schemas remain valid through the seam.
    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try webfetch.registerWebTools(&reg);
    try std.testing.expect(reg.contains("web_fetch"));
    try std.testing.expect(reg.contains("web_search"));
    const def = reg.get("web_fetch").?;
    try std.testing.expect(std.mem.indexOf(u8, def.parameters_json, "\"required\":[\"url\"]") != null);
    const sdef = reg.get("web_search").?;
    try std.testing.expect(std.mem.indexOf(u8, sdef.parameters_json, "\"required\":[\"query\"]") != null);
    const json = try reg.buildToolsJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "web_fetch") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "web_search") != null);

    // Third-party web providers must go via MCP, not native seam.
    try std.testing.expect(web_provider.shouldUseMcpForWebProvider("exa"));
    try std.testing.expect(web_provider.shouldUseMcpForWebProvider("perplexity"));
    try std.testing.expect(!web_provider.shouldUseMcpForWebProvider("curl"));
    try std.testing.expect(mcp_bridge.isBridgedName("mcp_exa_search"));
}

test "P2 web provider seam preserves direct web tools for MVP" {
    const web_provider = @import("web/provider.zig");
    const webfetch = @import("tool/webfetch.zig");
    const alloc = std.testing.allocator;
    web_provider.clearAll(alloc);
    defer web_provider.clearAll(alloc);
    // Direct file:// fetch still works through the seam (provider delegates to curl).
    var r = try webfetch.execute(alloc, "/tmp", .{ .name = "web_fetch", .arguments = "{\"url\":\"file:///etc/hosts\"}" });
    defer webfetch.freeResult(alloc, &r);
    // Either succeeds (file exists) or fails with a curl error — but must not be "unknown tool".
    try std.testing.expect(r.err_msg == null or std.mem.indexOf(u8, r.err_msg.?, "unknown tool") == null);
}
