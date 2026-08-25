//! run_code tool — Code Mode (upstream PTC parity), JSON orchestration variant.
//!
//! Upstream's PTC (programmatic tool calling / Code Mode) preset lets the
//! model write a TypeScript program that composes many tool calls into ONE
//! execution instead of paying one round trip per call. zharness has no Node
//! runtime, so this module implements the same value proposition over a JSON
//! orchestration envelope:
//!
//!   {"steps":[{"tool":"shell","args":{"command":"ls"}},
//!             {"tool":"file_read","args":{"path":"README.md"}}],
//!    "mode":"sequential"}
//!
//! Every step dispatches through the SAME builtin executor the agent loop
//! uses (`tool/builtin.zig::execute`), so sandbox policy, workspace scoping
//! and output caps apply unchanged. The combined result is a JSON array:
//!
//!   [{"step":0,"tool":"shell","ok":true,"output":"..."},
//!    {"step":1,"tool":"file_read","ok":false,"output":"","error":"..."}]
//!
//! Mode semantics:
//!   - "sequential" (default): steps run in order; execution STOPS at the
//!     first failing step (later steps are not attempted) — the natural
//!     dependency-chain reading. Overall success requires every step ok.
//!   - "parallel": every step is independent; ALL steps are attempted even
//!     after failures. Steps carry no cross-state today, so they are
//!     dispatched in order on one thread — behaviorally identical to
//!     independent calls, minus the round trips.
//!
//! ── Integrator contract (READ BEFORE WIRING) ────────────────────────────
//! Registry executors are PLAIN FUNCTIONS and `builtin.execute` needs an
//! io/cwd/sandbox triple the ToolRegistry cannot carry. Since registry.zig
//! must not change, this module keeps exactly ONE module-level context slot
//! (same pattern as tool/spawn_agent.zig):
//!
//!     var g_ctx: ?*Deps = null;
//!     pub fn setCtx(ctx: *Deps) void;    // once at startup
//!     pub fn clearCtx() void;            // once at shutdown
//!
//! The integrator MUST:
//!   1. Build a Deps{ .io, .cwd, .sandbox_mode } after the chat client exists.
//!   2. Call run_code.setCtx(&deps) before the first model turn.
//!   3. Register the schema:  try tools.register(run_code.definition);
//!   4. Route calls named "run_code" to run_code.execute in the extension
//!      dispatcher (main.zig LoopExtensions.execTool), re-tagging the
//!      ToolResult onto tool_builtin.ToolResult like spawn_agent does.
//!   5. Call run_code.clearCtx() at shutdown.
//!
//! Until setCtx runs, `execute` returns a FAILED ToolResult explaining the
//! missing wiring — it never executes anything. The slot is NOT
//! synchronized: single-threaded agent-loop contract only.
//!
//! Ownership of tool results follows tool/builtin.zig conventions: `execute`
//! allocates its ToolResult.output/err_msg with the given allocator; the
//! caller frees them via run_code.freeResult.

const std = @import("std");
const builtin_tools = @import("builtin.zig");
const config = @import("../config.zig");
const tool_reg = @import("registry.zig");

/// Hard cap on steps per invocation — one oversized batch must not turn into
/// an unbounded command queue (and keeps the combined result within the
/// model's context budget).
pub const max_steps: usize = 10;

// ── module-level wiring slot (see header contract) ──────────────────────────

var g_ctx: ?*Deps = null;

pub fn setCtx(ctx: *Deps) void {
    g_ctx = ctx;
}

pub fn clearCtx() void {
    g_ctx = null;
}

/// Current wiring (null until setCtx). Exposed for tests/introspection.
pub fn currentCtx() ?*Deps {
    return g_ctx;
}

pub const Deps = struct {
    /// Passed through to builtin.execute (file tools need the io handle).
    io: std.Io,
    /// Workspace root every step runs inside.
    cwd: []const u8,
    /// Shell-tool sandbox level forwarded to builtin.execute (dev.md §XII).
    sandbox_mode: config.Config.SandboxMode = .native,
};

// ── registry-facing definition (matches registry schema style) ─────────────

pub const definition = tool_reg.ToolDefinition{
    .name = "run_code",
    .description =
    \\Batch multiple tool calls into ONE invocation (Code Mode). Provide a
    \\list of steps; each names a tool and its arguments object. Use this
    \\instead of several separate tool calls whenever the operations are
    \\known up front — it removes one model round trip per call. In
    \\sequential mode execution stops at the first failed step; in parallel
    \\mode every step runs independently. Results come back as a JSON array
    \\of {step, tool, ok, output} entries in order.
    ,
    .category = .general,
    .parameters_json =
    \\{"type":"object","properties":{"steps":{"type":"array","description":"Up to 10 steps to execute in order","items":{"type":"object","properties":{"tool":{"type":"string","description":"Tool name, e.g. shell, file_read, glob, grep"},"args":{"type":"object","description":"Arguments object passed verbatim to the tool"}},"required":["tool","args"]}},"mode":{"type":"string","enum":["sequential","parallel"],"description":"sequential (default) stops at the first failed step; parallel attempts every step independently"}},"required":["steps"]}
    ,
};

// ── executor types (mirror tool/builtin.zig shape) ─────────────────────────

pub const ToolCall = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    err_msg: ?[]const u8 = null,
};

/// Free a result returned by `execute` (allocated with the same allocator).
pub fn freeResult(alloc: std.mem.Allocator, res: *const ToolResult) void {
    alloc.free(res.output);
    if (res.err_msg) |m| alloc.free(m);
}

fn fail(alloc: std.mem.Allocator, msg: []const u8) ToolResult {
    return .{
        .success = false,
        .output = alloc.dupe(u8, "") catch "",
        .err_msg = alloc.dupe(u8, msg) catch null,
    };
}

// ── hand-rolled JSON scanning (model.zig exemplar style; no JSON library) ───

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// Given `s` and the index of a value start ('"', '{', '[' or literal),
/// return the index ONE PAST the value's last character, honoring nesting
/// and string escapes. Returns null on unbalanced input.
fn skipValue(s: []const u8, start: usize) ?usize {
    if (start >= s.len) return null;
    switch (s[start]) {
        '"' => return skipString(s, start),
        '{', '[' => {
            var depth: usize = 0;
            var i = start;
            while (i < s.len) : (i += 1) {
                switch (s[i]) {
                    '"' => {
                        i = skipString(s, i) orelse return null;
                        i -= 1; // compensate for the loop increment
                    },
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    },
                    else => {},
                }
            }
            return null;
        },
        else => {
            var i = start;
            while (i < s.len and s[i] != ',' and s[i] != '}' and s[i] != ']') : (i += 1) {}
            return i;
        },
    }
}

/// Index one past the closing quote of the string starting at `open`.
fn skipString(s: []const u8, open: usize) ?usize {
    var i = open + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '"') return i + 1;
    }
    return null;
}

/// Find `key` among the TOP-LEVEL pairs of a JSON object `obj` ("{...}") and
/// return the raw value slice (delimiters included for strings/arrays/
/// objects). Nested objects are jumped over wholesale, so a nested key with
/// the same name never shadows the outer one.
fn topLevelValue(obj: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    // Position after the opening brace.
    while (i < obj.len and obj[i] != '{') i += 1;
    if (i >= obj.len) return null;
    i += 1;
    while (i < obj.len) {
        while (i < obj.len and (isWs(obj[i]) or obj[i] == ',')) i += 1;
        if (i >= obj.len or obj[i] == '}') return null;
        if (obj[i] != '"') return null;
        const key_end = skipString(obj, i) orelse return null;
        const k_raw = obj[i + 1 .. key_end - 1];
        var j = key_end;
        while (j < obj.len and isWs(obj[j])) j += 1;
        if (j >= obj.len or obj[j] != ':') return null;
        j += 1;
        while (j < obj.len and isWs(obj[j])) j += 1;
        const vend = skipValue(obj, j) orelse return null;
        if (std.mem.eql(u8, k_raw, key)) return obj[j..vend];
        i = vend;
    }
    return null;
}

/// Inner content of a raw JSON string slice (quotes stripped), with the
/// simple escapes decoded. Caller owns the returned slice.
fn stringValue(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len < 2 or t[0] != '"' or t[t.len - 1] != '"') return alloc.dupe(u8, t);
    const inner = t[1 .. t.len - 1];
    var out = try std.ArrayList(u8).initCapacity(alloc, inner.len);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 1;
            switch (inner[i]) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                '/' => try out.append(alloc, '/'),
                'n' => try out.append(alloc, '\n'),
                't' => try out.append(alloc, '\t'),
                'r' => try out.append(alloc, '\r'),
                else => {
                    try out.append(alloc, '\\');
                    try out.append(alloc, inner[i]);
                },
            }
        } else {
            try out.append(alloc, inner[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Escape `input` for embedding inside a JSON string literal.
fn appendEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, ch),
        }
    }
}

// ── executor ────────────────────────────────────────────────────────────────

/// One parsed step awaiting execution.
const Step = struct {
    tool: []const u8,
    args: []const u8,
};

/// Dispatch a run_code call. Signature mirrors tool/builtin.zig's execute
/// convention: allocations use `alloc`; the caller frees via freeResult.
pub fn execute(alloc: std.mem.Allocator, call: ToolCall) !ToolResult {
    const deps = g_ctx orelse return fail(
        alloc,
        "run_code is not wired: the host must call run_code.setCtx(&Deps{...}) at startup",
    );

    const steps_val_raw = topLevelValue(call.arguments, "steps") orelse
        return fail(alloc, "missing steps");

    // steps must be a JSON array.
    const steps_trim = std.mem.trim(u8, steps_val_raw, " \t\r\n");
    if (steps_trim.len < 2 or steps_trim[0] != '[' or steps_trim[steps_trim.len - 1] != ']')
        return fail(alloc, "steps must be a JSON array");
    const inner = steps_trim[1 .. steps_trim.len - 1];

    // Collect element slices FIRST so the cap is enforced before anything
    // executes (a 500-step batch must not partially run).
    var elems: std.ArrayList([]const u8) = .empty;
    defer elems.deinit(alloc);
    {
        var i: usize = 0;
        while (i < inner.len) {
            while (i < inner.len and (isWs(inner[i]) or inner[i] == ',')) i += 1;
            if (i >= inner.len) break;
            const end = skipValue(inner, i) orelse return fail(alloc, "malformed steps array");
            try elems.append(alloc, inner[i..end]);
            i = end;
        }
    }
    if (elems.items.len == 0) return fail(alloc, "steps must contain at least one step");
    if (elems.items.len > max_steps) {
        const msg = try std.fmt.allocPrint(
            alloc,
            "too many steps ({d}); cap is {d} per invocation",
            .{ elems.items.len, max_steps },
        );
        defer alloc.free(msg);
        return fail(alloc, msg);
    }

    // Parse each element into a Step.
    var steps = try alloc.alloc(Step, elems.items.len);
    defer alloc.free(steps);
    for (elems.items, 0..) |el, idx| {
        const el_t = std.mem.trim(u8, el, " \t\r\n");
        if (el_t.len == 0 or el_t[0] != '{')
            return fail(alloc, "each step must be a JSON object with tool and args");
        const tool_raw = topLevelValue(el_t, "tool") orelse
            return fail(alloc, "step missing tool");
        const args_val = topLevelValue(el_t, "args") orelse "{}";
        steps[idx] = .{
            .tool = try stringValue(alloc, tool_raw),
            .args = try alloc.dupe(u8, std.mem.trim(u8, args_val, " \t\r\n")),
        };
    }
    defer for (steps) |s| {
        alloc.free(s.tool);
        alloc.free(s.args);
    };

    // Resolve mode (default sequential; unknown values are rejected rather
    // than silently reinterpreted).
    var sequential = true;
    if (topLevelValue(call.arguments, "mode")) |raw| {
        const mode = try stringValue(alloc, raw);
        defer alloc.free(mode);
        if (std.mem.eql(u8, mode, "sequential")) {
            sequential = true;
        } else if (std.mem.eql(u8, mode, "parallel")) {
            sequential = false;
        } else {
            const msg = try std.fmt.allocPrint(alloc, "invalid mode '{s}' (sequential|parallel)", .{mode});
            defer alloc.free(msg);
            return fail(alloc, msg);
        }
    }

    // Execute + accumulate the combined JSON result.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '[');

    var any_failed = false;
    var stopped_early = false;
    for (steps, 0..) |step, idx| {
        if (sequential and any_failed) {
            stopped_early = true;
            break;
        }

        // Owned copies: builtin results are freed at once (their slices die
        // with them), so we snapshot into our own allocations first.
        var ok = false;
        var out_copy: ?[]const u8 = null;
        var err_copy: ?[]const u8 = null;
        defer if (out_copy) |s| alloc.free(s);
        defer if (err_copy) |m| alloc.free(m);

        if (std.mem.eql(u8, step.tool, "run_code")) {
            // Recursion guard: a batch invoking itself is unbounded by design.
            err_copy = try alloc.dupe(u8, "run_code cannot invoke itself");
        } else {
            const r = builtin_tools.execute(
                alloc,
                deps.io,
                deps.cwd,
                .{ .name = step.tool, .arguments = step.args },
                deps.sandbox_mode,
            ) catch |e| blk: {
                break :blk builtin_tools.ToolResult{
                    .success = false,
                    .output = "",
                    .err_msg = try alloc.dupe(u8, @errorName(e)),
                };
            };
            defer builtin_tools.freeResult(alloc, &r);
            ok = r.success;
            out_copy = try alloc.dupe(u8, r.output);
            if (r.err_msg) |m| err_copy = try alloc.dupe(u8, m);
        }
        if (!ok) any_failed = true;

        if (idx > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"step\":");
        var num_buf: [16]u8 = undefined;
        try out.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{idx}));
        try out.appendSlice(alloc, ",\"tool\":\"");
        try appendEscaped(alloc, &out, step.tool);
        try out.appendSlice(alloc, "\",\"ok\":");
        try out.appendSlice(alloc, if (ok) "true" else "false");
        try out.appendSlice(alloc, ",\"output\":\"");
        try appendEscaped(alloc, &out, out_copy orelse "");
        try out.appendSlice(alloc, "\"");
        if (err_copy) |m| {
            try out.appendSlice(alloc, ",\"error\":\"");
            try appendEscaped(alloc, &out, m);
            try out.appendSlice(alloc, "\"");
        }
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]");
    if (stopped_early) {
        // Non-fatal annotation AFTER the JSON array keeps the payload valid
        // machine-readable data while telling the model why it is short.
        try out.appendSlice(alloc, "\n[sequential mode: stopped at first failed step]");
    }

    return .{
        .success = !any_failed,
        .output = try out.toOwnedSlice(alloc),
        .err_msg = if (any_failed) try alloc.dupe(u8, "one or more steps failed") else null,
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

pub const TestIo = struct {
    t: std.Io.Threaded,

    pub fn init() TestIo {
        // Threaded must own a threadsafe allocator for its worker machinery
        // (same caveat as session/checkpoint.zig's TestEnv).
        return .{ .t = std.Io.Threaded.init(std.heap.page_allocator, .{}) };
    }
    pub fn io(self: *TestIo) std.Io {
        return self.t.io();
    }
};

test "definition registers into registry and serializes as OpenAI fragment" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqualStrings("run_code", definition.name);
    try std.testing.expect(std.mem.indexOf(u8, definition.description, "ONE invocation") != null);

    var reg = try tool_reg.ToolRegistry.init(alloc);
    defer reg.deinit();
    try reg.register(definition);
    const got = reg.get("run_code") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, got.parameters_json, "\"required\":[\"tool\",\"args\"]") != null);

    const tools_json = try reg.buildToolsJson(alloc);
    defer alloc.free(tools_json);
    try std.testing.expect(std.mem.startsWith(u8, tools_json, "{\"type\":\"function\",\"function\":{\"name\":\"run_code\""));
}

test "unwired executor fails gracefully" {
    const alloc = std.testing.allocator;
    clearCtx(); // guarantee the unwired state regardless of test order
    var res = try execute(alloc, .{ .name = "run_code", .arguments = "{\"steps\":[]}" });
    defer freeResult(alloc, &res);
    try std.testing.expect(!res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.err_msg.?, "setCtx") != null);
}

// Per-test wiring preamble (Threaded must not be copied after init, so the
// io env lives as a local in each test rather than inside a returned helper):
//   var tio = TestIo.init();  defer tio.t.deinit();
//   var deps = Deps{...};     setCtx(&deps); defer clearCtx();

test "sequential happy path batches two shell steps into one result" {
    const alloc = std.testing.allocator;
    var tio = TestIo.init();
    defer tio.t.deinit();
    var deps = Deps{ .io = tio.io(), .cwd = "/tmp", .sandbox_mode = .none };
    setCtx(&deps);
    defer clearCtx();

    var res = try execute(alloc, .{
        .name = "run_code",
        .arguments =
        \\{"steps":[
        \\ {"tool":"shell","args":{"command":"echo alpha"}},
        \\ {"tool":"shell","args":{"command":"echo beta"}}
        \\],"mode":"sequential"}
        ,
    });
    defer freeResult(alloc, &res);

    try std.testing.expect(res.success);
    try std.testing.expect(res.err_msg == null);
    // Both outputs present, in submission order, wrapped as JSON entries.
    const a_pos = std.mem.indexOf(u8, res.output, "alpha").?;
    const b_pos = std.mem.indexOf(u8, res.output, "beta").?;
    try std.testing.expect(a_pos < b_pos);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "{\"step\":0,\"tool\":\"shell\",\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "{\"step\":1,\"tool\":\"shell\",\"ok\":true") != null);
    try std.testing.expect(std.mem.endsWith(u8, res.output, "]"));
}

test "unknown tool yields ok:false entry and sequential mode skips later steps" {
    const alloc = std.testing.allocator;
    var tio = TestIo.init();
    defer tio.t.deinit();
    var deps = Deps{ .io = tio.io(), .cwd = "/tmp", .sandbox_mode = .none };
    setCtx(&deps);
    defer clearCtx();

    var res = try execute(alloc, .{
        .name = "run_code",
        .arguments =
        \\{"steps":[
        \\ {"tool":"shell","args":{"command":"echo first"}},
        \\ {"tool":"nosuch_tool","args":{}},
        \\ {"tool":"shell","args":{"command":"echo third"}}
        \\]}
        ,
    });
    defer freeResult(alloc, &res);

    try std.testing.expect(!res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.err_msg.?, "failed") != null);
    // Steps 0 and 1 ran; step 2 was skipped by sequential stop-on-failure.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, res.output, "\"step\":"));
    try std.testing.expect(std.mem.indexOf(u8, res.output, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "unknown tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "stopped at first failed step") != null);
}

test "parallel mode attempts every step even after failures" {
    const alloc = std.testing.allocator;
    var tio = TestIo.init();
    defer tio.t.deinit();
    var deps = Deps{ .io = tio.io(), .cwd = "/tmp", .sandbox_mode = .none };
    setCtx(&deps);
    defer clearCtx();

    var res = try execute(alloc, .{
        .name = "run_code",
        .arguments =
        \\{"mode":"parallel","steps":[
        \\ {"tool":"nosuch_tool","args":{}},
        \\ {"tool":"shell","args":{"command":"echo independent"}}
        \\]}
        ,
    });
    defer freeResult(alloc, &res);

    try std.testing.expect(!res.success); // one step failed...
    // ...but the independent step still executed.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, res.output, "\"step\":"));
    try std.testing.expect(std.mem.indexOf(u8, res.output, "independent") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "stopped at first failed step") == null);
}

test "step cap rejects oversized batches before executing anything" {
    const alloc = std.testing.allocator;
    var tio = TestIo.init();
    defer tio.t.deinit();
    var deps = Deps{ .io = tio.io(), .cwd = "/tmp", .sandbox_mode = .none };
    setCtx(&deps);
    defer clearCtx();

    // Build an 11-step batch programmatically.
    var args: std.ArrayList(u8) = .empty;
    defer args.deinit(alloc);
    try args.appendSlice(alloc, "{\"steps\":[");
    var i: usize = 0;
    while (i <= max_steps) : (i += 1) { // 11 elements
        if (i > 0) try args.append(alloc, ',');
        try args.appendSlice(alloc, "{\"tool\":\"shell\",\"args\":{\"command\":\"echo x\"}}");
    }
    try args.appendSlice(alloc, "]}");

    var res = try execute(alloc, .{ .name = "run_code", .arguments = args.items });
    defer freeResult(alloc, &res);
    try std.testing.expect(!res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.err_msg.?, "cap is 10") != null);
    try std.testing.expectEqual(@as(usize, 0), res.output.len); // nothing executed
}

test "recursion guard: run_code cannot invoke itself" {
    const alloc = std.testing.allocator;
    var tio = TestIo.init();
    defer tio.t.deinit();
    var deps = Deps{ .io = tio.io(), .cwd = "/tmp", .sandbox_mode = .none };
    setCtx(&deps);
    defer clearCtx();

    var res = try execute(alloc, .{
        .name = "run_code",
        .arguments =
        \\{"steps":[{"tool":"run_code","args":{"steps":[]}}]}
        ,
    });
    defer freeResult(alloc, &res);
    try std.testing.expect(!res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "cannot invoke itself") != null);
}

test "argument validation: missing/malformed steps and bad mode fail cleanly" {
    const alloc = std.testing.allocator;
    var tio = TestIo.init();
    defer tio.t.deinit();
    var deps = Deps{ .io = tio.io(), .cwd = "/tmp", .sandbox_mode = .none };
    setCtx(&deps);
    defer clearCtx();

    const cases = [_][]const u8{
        "{}",
        "{\"steps\":\"nope\"}",
        "{\"steps\":[]}",
        "{\"steps\":[{\"args\":{}}]}",
        "[{\"tool\":\"shell\"}]",
        "{\"steps\":[{\"tool\":\"shell\",\"args\":{}}],\"mode\":\"concurrent\"}",
        "{\"steps\":{\"tool\":\"shell\"}}",
    };
    for (cases) |args| {
        var res = try execute(alloc, .{ .name = "run_code", .arguments = args });
        defer freeResult(alloc, &res);
        try std.testing.expect(!res.success);
        try std.testing.expect(res.err_msg != null);
    }
}

test "nested shadowing: args containing a tool key does not confuse parsing" {
    const alloc = std.testing.allocator;
    var tio = TestIo.init();
    defer tio.t.deinit();
    var deps = Deps{ .io = tio.io(), .cwd = "/tmp", .sandbox_mode = .none };
    setCtx(&deps);
    defer clearCtx();

    var res = try execute(alloc, .{
        .name = "run_code",
        .arguments =
        \\{"steps":[{"tool":"shell","args":{"command":"echo nested-ok"}}]}
        ,
    });
    defer freeResult(alloc, &res);
    try std.testing.expect(res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "nested-ok") != null);
}
