//! G2-sessions (wave 6) self-test root — sibling of _t_apiproxy.
//!
//! Covers everything this agent built:
//!   - server/apiproxy/search_rpc.zig    (session.search DATA layer)
//!   - server/apiproxy/export_rpc.zig    (downloads-domain session export)
//!   - server/apiproxy/subagents_rpc.zig (subagent registry + RPC values)
//! Module-internal unit tests ride along via comptime imports.
//!
//! Run with:
//!   zig test -lc --dep cordis -Mroot=test/_t_g2.zig -Mcordis=../zcordis/src/cordis.zig
//!
//! The integrator folds these three modules into src/tests.zig's comptime
//! block (same as every other apiproxy module) and deletes this file.
//! `zig build && zig build test` stay untouched by design until then.

const std = @import("std");
const cordis = @import("cordis");

comptime {
    _ = cordis; // linked for parity with the shared tree; unused here
    _ = @import("../src/server/apiproxy/jsonx.zig");
    _ = @import("../src/server/apiproxy/sessions.zig");
}

const testing = std.testing;
const jsonx = @import("../src/server/apiproxy/jsonx.zig");
const router = @import("../src/server/apiproxy/router.zig");
const sessions_store = @import("../src/server/apiproxy/sessions.zig");
const search_rpc = @import("../src/server/apiproxy/search_rpc.zig");
const export_rpc = @import("../src/server/apiproxy/export_rpc.zig");
const subagents_rpc = @import("../src/server/apiproxy/subagents_rpc.zig");
const clib = @import("clib.zig");

/// Process-unique scratch-dir suffix (no wall-clock/random in this toolchain's
/// std.time; combine the C-clock seconds with a monotonic counter).
var g_uniq: std.atomic.Value(u32) = .init(0);
fn nextUniq() u32 {
    const secs: u32 = @truncate(@as(u64, @intCast(clib.nowTimestamp())));
    return g_uniq.fetchAdd(1, .monotonic) +% secs;
}

// ── fixture scaffolding ─────────────────────────────────────────────────────

const Fixture = struct {
    io: std.Io,
    threaded: *std.Io.Threaded,
    cwd: []u8,
    alloc: std.mem.Allocator,

    fn create(alloc: std.mem.Allocator, tag: []const u8) !Fixture {
        const threaded = try alloc.create(std.Io.Threaded);
        threaded.* = std.Io.Threaded.init(alloc, .{});
        const uniq = nextUniq();
        const cwd = try std.fmt.allocPrint(alloc, "/tmp/zh_g2_{s}_{d}", .{ tag, uniq });
        var dir_path: std.ArrayList(u8) = .empty;
        defer dir_path.deinit(alloc);
        try dir_path.appendSlice(alloc, cwd);
        try dir_path.appendSlice(alloc, "/.zharness/sessions");
        try std.Io.Dir.createDirPath(.cwd(), threaded.io(), dir_path.items);
        return .{ .io = threaded.io(), .threaded = threaded, .cwd = cwd, .alloc = alloc };
    }

    fn transcriptPath(self: *const Fixture, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.alloc, "{s}/.zharness/sessions/{s}.json", .{ self.cwd, id });
    }

    fn writeTranscript(self: *const Fixture, id: []const u8, body: []const u8) !void {
        const path = try self.transcriptPath(id);
        defer self.alloc.free(path);
        try std.Io.Dir.writeFile(.cwd(), self.io, .{ .sub_path = path, .data = body });
    }

    fn destroy(self: *Fixture) void {
        if (std.Io.Dir.openDir(.cwd(), self.io, "/tmp", .{})) |open_res| {
            var tmp_dir = open_res;
            defer std.Io.Dir.close(tmp_dir, self.io);
            tmp_dir.deleteTree(self.io, std.fs.path.basename(self.cwd)) catch {};
        } else |_| {}
        self.threaded.deinit();
        self.alloc.destroy(self.threaded);
        self.alloc.free(self.cwd);
    }
};

/// Install a search config over `fx` and guarantee teardown afterwards.
fn installSearchOver(fx: Fixture) !void {
    _ = try search_rpc.installDefault(fx.cwd);
}

fn teardownSearch() void {
    if (search_rpc.takeConfig()) |cfg| {
        std.heap.c_allocator.free(cfg.cwd);
        cfg.threaded.deinit();
        std.heap.c_allocator.destroy(cfg.threaded);
        std.heap.c_allocator.destroy(cfg);
    }
}

// ── feature 1: session.search through the REAL router dispatch ──────────────

test "session.search end-to-end: router envelope, scoring order, snippets" {
    const alloc = testing.allocator;
    var fx = try Fixture.create(alloc, "search");
    defer fx.destroy();

    // alpha: 2 matches; gamma: 3 matches (user+assistant+assistant); beta: 0.
    try fx.writeTranscript("alpha", "[{\"role\":\"user\",\"content\":\"fix the login bug please\"},{\"role\":\"assistant\",\"content\":\"login bug fixed\"}]");
    try fx.writeTranscript("beta", "[{\"role\":\"user\",\"content\":\"what is rust\"}]");
    try fx.writeTranscript("gamma", "[{\"role\":\"user\",\"content\":\"LOGIN\"},{\"role\":\"assistant\",\"content\":\"login\"},{\"role\":\"assistant\",\"content\":\"login again\"}]");

    try installSearchOver(fx);
    defer teardownSearch();

    var deps = fixtureDeps();
    deps.searchSessions = search_rpc.searchSessionsFn;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const body =
        \\{"type":"client-request","rpcId":"rpc-s1","method":"session.search","payload":{"query":"  login  "}}
    ;
    const env = (try router.parseEnvelope(a, body)).?;
    const resp = try router.dispatch(&deps, a, &env);

    try testing.expect(resp.status == .ok);
    // gamma scores 3 → first; snippet windows wrap the FIRST match of each
    // session's first matching message in «…» (query trimmed, case-folded).
    try testing.expectEqualStrings(
        "{\"type\":\"server-response\",\"rpcId\":\"rpc-s1\",\"result\":{\"ok\":true,\"value\":{\"items\":[" ++
            "{\"sessionId\":\"gamma\",\"snippet\":\"\u{00AB}LOGIN\u{00BB}\"}," ++
            "{\"sessionId\":\"alpha\",\"snippet\":\"fix the \u{00AB}login\u{00BB} bug please\"}]," ++
            "\"hasMore\":false}}}",
        resp.body,
    );
}

test "session.search invalid query renders bad-request through the router" {
    const alloc = testing.allocator;
    var fx = try Fixture.create(alloc, "srchbad");
    defer fx.destroy();
    try installSearchOver(fx);
    defer teardownSearch();

    var deps = fixtureDeps();
    deps.searchSessions = search_rpc.searchSessionsFn;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const body =
        \\{"type":"client-request","rpcId":"rpc-s2","method":"session.search","payload":{"query":"   "}}
    ;
    const env = (try router.parseEnvelope(a, body)).?;
    const resp = try router.dispatch(&deps, a, &env);
    // bad-request rides INSIDE HTTP 200 per spec §4.
    try testing.expect(resp.status == .ok);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"code\":\"bad-request\"") != null);
}

// ── feature 2: export builders vs fixtures ─────────────────────────────────

test "export: markdown value builder matches its fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fx = try Fixture.create(alloc, "mdexp");
    defer fx.destroy();
    try fx.writeTranscript("doc1", "[{\"role\":\"user\",\"content\":\"hello world\"},{\"role\":\"assistant\",\"content\":\"hi!\"}]");

    const path = try fx.transcriptPath("doc1");
    defer alloc.free(path);
    const msgs = try sessions_store.loadTranscript(fx.io, alloc, path);
    const md = try export_rpc.buildMarkdownExport(alloc, "doc1", msgs, 0);

    // Shape contract: title, count line, numbered role sections.
    try testing.expect(std.mem.startsWith(u8, md, "# Session doc1\n\n"));
    try testing.expect(std.mem.indexOf(u8, md, "- Messages: 2") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## 1. User\n\nhello world\n") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## 2. Assistant\n\nhi!\n") != null);

    // JSON flavor is the stored artifact verbatim.
    const jd = try export_rpc.jsonDownload(fx.io, alloc, fx.cwd, "doc1");
    try testing.expectEqualStrings("application/json", jd.content_type);
    try testing.expectEqualStrings(
        "[{\"role\":\"user\",\"content\":\"hello world\"},{\"role\":\"assistant\",\"content\":\"hi!\"}]",
        jd.body,
    );
}

test "export: downloads-domain zip channel answers the upstream envelope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fx = try Fixture.create(alloc, "zipdl");
    defer fx.destroy();

    // Missing root → SessionNotFound (carrier maps to 404 BEFORE any bytes).
    try testing.expectError(
        error.SessionNotFound,
        export_rpc.sessionLogDownload(fx.io, alloc, fx.cwd, "absent", false),
    );

    try fx.writeTranscript("root9", "[{\"role\":\"user\",\"content\":\"payload\"}]");
    const dl = try export_rpc.sessionLogDownload(fx.io, alloc, fx.cwd, "root9", false);
    try testing.expectEqualStrings("dsh-session-root9.zip", dl.filename);
    try testing.expectEqualStrings("application/zip", dl.content_type);
    try testing.expectEqualStrings("PK\x03\x04", dl.body[0..4]);
    try testing.expect(std.mem.indexOf(u8, dl.body, "[{\"role\":\"user\",\"content\":\"payload\"}]") != null);
}

// ── feature 3: registry + RPC envelopes through the INTEGRATOR lines ────────

/// Exactly the dispatch lines reported for the integrator to splice into
/// router.dispatch (see subagents_rpc.zig header), including run()-style
/// error mapping so PayloadInvalid/SessionNotFound render in-band.
fn g2SubagentLine(
    alloc: std.mem.Allocator,
    rpc_id: []const u8,
    method: []const u8,
    payload_json: []const u8,
) !router.UnaryResponse {
    const value_res: anyerror![]u8 = if (std.mem.eql(u8, method, "subagent.list"))
        subagents_rpc.handleList(alloc, payload_json)
    else if (std.mem.eql(u8, method, "subagent.history"))
        subagents_rpc.handleHistory(alloc, payload_json)
    else
        unreachable;
    const value = value_res catch |e| return switch (e) {
        error.PayloadInvalid => router.errValue(alloc, rpc_id, .bad_request, "invalid payload", "{\"issues\":[]}"),
        error.SessionNotFound => router.errValue(alloc, rpc_id, .session_not_found, "session not found", "{}"),
        else => router.errValue(alloc, rpc_id, .internal, "backend failure", "{}"),
    };
    return router.okValue(alloc, rpc_id, value);
}

test "subagent RPC through integrator dispatch lines: lifecycle envelopes" {
    // The handler surfaces are arena-convention (values embedded into the
    // response, freed wholesale) so this test runs on one arena.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Deterministic registry instance swapped into the singleton slot.
    var reg = subagents_rpc.Registry{ .gpa = testing.allocator };
    const prev = subagents_rpc.swapShared(&reg);
    defer {
        _ = subagents_rpc.swapShared(prev);
        reg.deinit();
    }

    // beginRun → list shows running.
    const child = try subagents_rpc.beginRun(alloc, "sess-parent", "scout", "look around");

    var resp = try g2SubagentLine(alloc, "rpc-u1", "subagent.list",
        \\{"parentSessionId":"sess-parent"}
    );
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"kind\":\"child\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"activity\":\"running\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"label\":\"scout\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"parentAvailable\":true}") != null);

    // history while running → prompt only (summary-only degradation).
    const hist_payload = try std.fmt.allocPrint(alloc, "{{\"parentSessionId\":\"sess-parent\",\"childSessionId\":\"{s}\",\"mode\":\"one-shot\"}}", .{child});
    resp = try g2SubagentLine(alloc, "rpc-u2", "subagent.history", hist_payload);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"user/message\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"assistant/message\"") == null);

    // endRun → completed; catalog flips to inactive.
    subagents_rpc.endRun(child, true, "found it");
    resp = try g2SubagentLine(alloc, "rpc-u3", "subagent.list",
        \\{"parentSessionId":"sess-parent"}
    );
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"activity\":\"inactive\"") != null);

    // Completed child's history now carries the final answer.
    resp = try g2SubagentLine(alloc, "rpc-u6", "subagent.history", hist_payload);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"text\":\"found it\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"title\":\"scout\"") != null);

    // Unknown child → session-not-found error shape.
    resp = try g2SubagentLine(alloc, "rpc-u4", "subagent.history",
        \\{"parentSessionId":"nope","childSessionId":"subagent-999","mode":"one-shot"}
    );
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"code\":\"session-not-found\"") != null);

    // Bad payload → bad-request error shape.
    resp = try g2SubagentLine(alloc, "rpc-u5", "subagent.list", "{}");
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"code\":\"bad-request\"") != null);
}

// ── router dep fixture ──────────────────────────────────────────────────────

fn fixtureDeps() router.ApiProxyDeps {
    return .{
        .listSessions = listSessionsStub,
        .sessionHistory = sessionHistoryStub,
        .createSession = createSessionStub,
        .promptSession = promptSessionStub,
        .cancelSession = cancelSessionStub,
        .renameSession = renameSessionStub,
    };
}

fn listSessionsStub(ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]router.SessionSummary {
    _ = ctx;
    return try alloc.alloc(router.SessionSummary, 0);
}
fn sessionHistoryStub(ctx: ?*anyopaque, alloc: std.mem.Allocator, session_id: []const u8, before_seq: ?i64, max_messages: ?u32) anyerror!router.HistoryPage {
    _ = ctx;
    _ = alloc;
    _ = session_id;
    _ = before_seq;
    _ = max_messages;
    return error.SessionNotFound;
}
fn createSessionStub(ctx: ?*anyopaque, alloc: std.mem.Allocator, opts: router.CreateOptions) anyerror![]const u8 {
    _ = ctx;
    _ = alloc;
    _ = opts;
    return "";
}
fn promptSessionStub(ctx: ?*anyopaque, alloc: std.mem.Allocator, req: router.PromptRequest) anyerror!router.PromptAck {
    _ = ctx;
    _ = alloc;
    _ = req;
    return .{};
}
fn cancelSessionStub(ctx: ?*anyopaque, alloc: std.mem.Allocator, session_id: []const u8) anyerror!void {
    _ = ctx;
    _ = alloc;
    _ = session_id;
}
fn renameSessionStub(ctx: ?*anyopaque, alloc: std.mem.Allocator, session_id: []const u8, title: []const u8) anyerror!router.RenameResult {
    _ = ctx;
    _ = alloc;
    _ = session_id;
    _ = title;
    return .{ .title = "", .seq = 0 };
}
