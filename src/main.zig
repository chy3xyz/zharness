const std = @import("std");
const clib = @import("clib.zig");
const cordis = @import("cordis");

const cli_flags = @import("cli_flags.zig");
const config = @import("config.zig");
const model = @import("model/model.zig");
const tool_reg = @import("tool/registry.zig");
const tool_builtin = @import("tool/builtin.zig");
const agent = @import("agent/agent.zig");
const session = @import("session/session.zig");

const SYSTEM_PROMPT =
    \\You are zharness, a coding agent running inside a workspace. You help the user by
    \\reading, editing, and searching files, running shell commands, and using git. Prefer
    \\small, focused changes and verify them. Use the provided tools to inspect and modify
    \\the codebase rather than guessing. When you finish, give a concise final answer that
    \\summarizes what you did and any follow-up needed.
;

fn onEvent(kind: agent.AgentLoop.EventKind, payload: []const u8) void {
    switch (kind) {
        .thinking => std.debug.print("[thinking] {s}\n", .{payload}),
        .text => std.debug.print("{s}", .{payload}),
        .tool_call => std.debug.print("\n> calling {s}\n", .{payload}),
        .tool_result => std.debug.print("  -> {s}\n", .{payload}),
        .turn_start => {},
        .done => std.debug.print("\n=== Final answer ===\n{s}\n", .{payload}),
        .err => std.debug.print("\n[error] {s}\n", .{payload}),
    }
}

/// Live-delta sink for streamed chat completions: text prints as it arrives;
/// reasoning prints dimmed so it reads as scaffolding, not the answer.
fn onStreamDelta(kind: model.StreamKind, delta: []const u8) void {
    switch (kind) {
        .text => std.debug.print("{s}", .{delta}),
        .reasoning => std.debug.print("\x1b[2m{s}\x1b[0m", .{delta}),
    }
}

fn printUsage() void {
    std.debug.print(
        \\zharness - a native coding-agent harness
        \\
        \\Usage:
        \\  zharness run "prompt"      Run a single agent task
        \\  zharness chat              Start an interactive REPL
        \\  zharness serve [--port N]  Start a server (not yet implemented)
        \\  zharness --help            Show this help
        \\
        \\Flags (run/chat):
        \\  --model X        Override the model
        \\  --provider Y     Override the provider
        \\  --no-stream     Disable streaming
        \\  --session ID     Resume/save a named session (persisted under .zharness/sessions/)
        \\
    , .{});
}

fn buildLoop(alloc: std.mem.Allocator, cfg: *config.Config) !struct {
    ctx: *cordis.Context,
    tools: *tool_reg.ToolRegistry,
    loop: *agent.AgentLoop,
    ag: *agent.Agent,
    acfg: *agent.AgentConfig,
} {
    var ctx = try cordis.Context.init(alloc);
    errdefer ctx.deinit();

    const tools = try alloc.create(tool_reg.ToolRegistry);
    errdefer alloc.destroy(tools);
    tools.* = try tool_reg.ToolRegistry.init(alloc);
    try tool_reg.registerBuiltins(tools);

    // Streamed deltas print live; wire the sink before the client value is
    // copied into the agent loop.
    var client = model.ChatClient.init(alloc, ctx.io(), cfg.endpoint, cfg.model, cfg.api_key);
    client.stream_sink = onStreamDelta;

    // Heap-allocate the config so the pointer `Agent` holds stays valid after
    // buildLoop returns (a stack-local would dangle and corrupt system_prompt).
    const acfg = try alloc.create(agent.AgentConfig);
    errdefer alloc.destroy(acfg);
    acfg.* = .{
        .system_prompt = SYSTEM_PROMPT,
        .max_turns = cfg.max_turns,
        .reasoning_effort = cfg.reasoning_effort,
        .stream = cfg.stream,
    };
    const ag = try agent.Agent.init(alloc, ctx.root, acfg);

    const loop = try alloc.create(agent.AgentLoop);
    errdefer alloc.destroy(loop);
    loop.* = try agent.AgentLoop.init(alloc, ctx, ag, client, tools, cfg.cwd, onEvent);

    return .{ .ctx = ctx, .tools = tools, .loop = loop, .ag = ag, .acfg = acfg };
}

fn runTask(alloc: std.mem.Allocator, cfg: *config.Config, prompt: []const u8, session_id: ?[]const u8) !void {
    const built = try buildLoop(alloc, cfg);
    defer built.ctx.deinit();
    defer built.ag.deinit(alloc);
    defer built.tools.deinit();
    defer built.loop.deinit();
    defer alloc.destroy(built.loop);
    defer alloc.destroy(built.tools);
    defer alloc.destroy(built.acfg);

    const io = built.ctx.io();

    // Optional named session: load any prior transcript and seed the loop so
    // the run continues the conversation (dev.md §XV).
    var session_ptr: ?*session.Session = null;
    var session_path: ?[]u8 = null;
    if (session_id) |sid| {
        const dir = try std.fs.path.join(alloc, &.{ cfg.cwd, ".zharness", "sessions" });
        std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, sid });
        alloc.free(dir);
        session_path = p;
        const s = try alloc.create(session.Session);
        errdefer alloc.destroy(s);
        s.* = try session.Session.init(alloc, sid);
        errdefer s.deinit();
        s.load(io, p) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        for (s.messages.items) |m| try built.loop.seed(alloc, m);
        session_ptr = s;
    }
    defer if (session_ptr) |s| {
        s.deinit();
        alloc.destroy(s);
    };
    defer if (session_path) |p| alloc.free(p);

    const answer = try built.loop.run(prompt);
    // onEvent already prints the final answer; print a trailing newline for run too
    std.debug.print("\n", .{});
    alloc.free(answer);

    if (session_ptr) |s| {
        try built.loop.syncToSession(s);
        try s.save(io, session_path.?);
        std.debug.print("\nsession saved: {s}\n", .{session_path.?});
    }
}

fn chatLoop(alloc: std.mem.Allocator, cfg: *config.Config, session_id: ?[]const u8) !void {
    const built = try buildLoop(alloc, cfg);
    defer built.ctx.deinit();
    defer built.ag.deinit(alloc);
    defer built.tools.deinit();
    defer built.loop.deinit();
    defer alloc.destroy(built.loop);
    defer alloc.destroy(built.tools);
    defer alloc.destroy(built.acfg);

    const io = built.ctx.io();

    // Optional named session: load prior transcript, resume across turns and
    // process invocations, and persist after every exchange.
    var session_ptr: ?*session.Session = null;
    var session_path: ?[]u8 = null;
    if (session_id) |sid| {
        const dir = try std.fs.path.join(alloc, &.{ cfg.cwd, ".zharness", "sessions" });
        std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, sid });
        alloc.free(dir);
        session_path = p;
        const s = try alloc.create(session.Session);
        errdefer alloc.destroy(s);
        s.* = try session.Session.init(alloc, sid);
        errdefer s.deinit();
        s.load(io, p) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        for (s.messages.items) |m| try built.loop.seed(alloc, m);
        session_ptr = s;
    }
    defer if (session_ptr) |s| {
        s.deinit();
        alloc.destroy(s);
    };
    defer if (session_path) |p| alloc.free(p);

    std.debug.print("zharness chat", .{});
    if (session_ptr) |s| std.debug.print(" — session '{s}' ({d} messages)", .{ s.id, s.count() });
    std.debug.print(" — type 'exit' or 'quit' to leave.\n\n", .{});

    while (true) {
        std.debug.print("you> ", .{});
        const owned = clib.readLineStdin(alloc) catch |e| switch (e) {
            else => return e,
        } orelse break;
        if (std.mem.eql(u8, owned, "exit") or std.mem.eql(u8, owned, "quit")) {
            alloc.free(owned);
            break;
        }
        if (owned.len == 0) {
            alloc.free(owned);
            continue;
        }
        const answer = built.loop.run(owned) catch |e| {
            std.debug.print("\n[error] {s}\n", .{@errorName(e)});
            alloc.free(owned);
            continue;
        };
        std.debug.print("\n", .{});
        alloc.free(answer);

        if (session_ptr) |s| {
            try built.loop.syncToSession(s);
            try s.save(io, session_path.?);
        }
        alloc.free(owned);
    }

    if (session_ptr) |s| {
        try s.save(io, session_path.?);
        std.debug.print("\nsession saved: {s}\n", .{session_path.?});
    }
    std.debug.print("\nbye.\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    // Collect argv into a slice of sentinel strings (Zig 0.17: args come via
    // the init.args iterator, not std.process.argsAlloc).
    var args_list: std.ArrayList([:0]const u8) = .empty;
    defer args_list.deinit(alloc);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |arg| {
        try args_list.append(alloc, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const sub = args[1];

    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, sub, "run")) {
        if (args.len < 3) {
            std.debug.print("error: 'run' requires a prompt argument.\n", .{});
            printUsage();
            std.process.exit(1);
        }
        // flags may appear before/after the prompt; one strict parser for all
        // subcommands (missing flag values are hard errors everywhere).
        const flags = cli_flags.parseSubFlags(args[2..], 1) catch |e| {
            std.debug.print("error: invalid flags ({s}).\n", .{@errorName(e)});
            printUsage();
            std.process.exit(1);
        };
        const model_opt = flags.model;
        const provider_opt = flags.provider;
        const no_stream = flags.no_stream;
        const session_id = flags.session_id;
        const prompt: ?[]const u8 = flags.prompt;

        if (prompt == null) {
            std.debug.print("error: 'run' requires a prompt argument.\n", .{});
            std.process.exit(1);
        }

        // load config in a sub-allocator to apply overrides + api-key check
        var cfg = try config.load(alloc);
        defer cfg.deinit();
        try cfg.applyOverrides(model_opt, provider_opt, no_stream);

        if (cfg.api_key.len == 0) {
            std.debug.print(
                "error: no API key found. Set ZHARNESS_API_KEY or DEEPSEEK_API_KEY.\n",
                .{},
            );
            std.process.exit(1);
        }

        runTask(alloc, &cfg, prompt.?, session_id) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, sub, "chat")) {
        // chat honors the same strict flag set; positionals are not accepted.
        const flags = cli_flags.parseSubFlags(args[2..], 0) catch |e| {
            std.debug.print("error: invalid flags ({s}).\n", .{@errorName(e)});
            printUsage();
            std.process.exit(1);
        };
        const model_opt = flags.model;
        const provider_opt = flags.provider;
        const no_stream = flags.no_stream;
        const session_id = flags.session_id;

        var cfg = try config.load(alloc);
        defer cfg.deinit();
        try cfg.applyOverrides(model_opt, provider_opt, no_stream);

        if (cfg.api_key.len == 0) {
            std.debug.print(
                "error: no API key found. Set ZHARNESS_API_KEY or DEEPSEEK_API_KEY.\n",
                .{},
            );
            std.process.exit(1);
        }

        chatLoop(alloc, &cfg, session_id) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, sub, "serve")) {
        var port: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--port")) {
                i += 1;
                if (i < args.len) port = args[i];
            }
        }
        var port_msg: [64]u8 = undefined;
        const port_str = if (port) |p|
            std.fmt.bufPrint(&port_msg, "Requested port: {s}", .{p}) catch "Requested port: <too long>"
        else
            "No port specified.";
        std.debug.print(
            \\zharness serve is not yet implemented (planned per dev.md §XXIII).
            \\{s}
            \\Use `zharness run "..."` or `zharness chat` for now.
            \\
        , .{port_str});
        return;
    }

    std.debug.print("error: unknown subcommand '{s}'\n", .{sub});
    printUsage();
    std.process.exit(1);
}
