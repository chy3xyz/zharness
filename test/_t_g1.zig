//! G1-tier1 (wave 6) self-test root — cordis-aware like _t_w1/_t_apiproxy.
//!
//! Covers the five Tier-1 RPC domains wired into server/apiproxy/router.zig:
//!   - goals_rpc.zig   (goal.create/edit/pause/resume/complete/clear +
//!                      'goal' projection emit contract)
//!   - skills_rpc.zig  (skill.list fresh disk scan)
//!   - models_rpc.zig  (session.models / session.selectModel / llm.providers)
//!   - presets_rpc.zig (agentPreset.list/select + [general] agent_preset)
//!   - perms_rpc.zig   (permission preset ↔ sandbox_mode mapping)
//!
//! Run with:
//!   zig test -lc --dep cordis -Mroot=test/_t_g1.zig -Mcordis=../zcordis/src/cordis.zig

const std = @import("std");
const cordis = @import("cordis");

comptime {
    _ = @import("../src/server/apiproxy/jsonx.zig");
    _ = @import("../src/server/apiproxy/goals_rpc.zig");
    _ = @import("../src/server/apiproxy/skills_rpc.zig");
    _ = @import("../src/server/apiproxy/models_rpc.zig");
    _ = @import("../src/server/apiproxy/presets_rpc.zig");
    _ = @import("../src/server/apiproxy/perms_rpc.zig"); // table round-trip tests inside
}

const testing = std.testing;
const jsonx = @import("../src/server/apiproxy/jsonx.zig");
const router = @import("../src/server/apiproxy/router.zig");
const goals_rpc = @import("../src/server/apiproxy/goals_rpc.zig");
const skills_rpc = @import("../src/server/apiproxy/skills_rpc.zig");
const models_rpc = @import("../src/server/apiproxy/models_rpc.zig");
const presets_rpc = @import("../src/server/apiproxy/presets_rpc.zig");
const perms_rpc = @import("../src/server/apiproxy/perms_rpc.zig");
const apx_settings = @import("../src/server/apiproxy/settings.zig");
const config = @import("config.zig");

extern "c" fn time(tloc: ?*c_long) c_long;

var home_counter: std.atomic.Value(u32) = .init(0);

/// Unique temp home per call ("<tmp>/zh_g1_<stamp>_<pid>_<n>/") — tests run
/// in arbitrary order and share the process, so stamp+pid alone collides.
fn tempHome(buf: []u8) ![]const u8 {
    const stamp: i64 = time(null);
    const pid = std.c.getpid();
    const n = home_counter.fetchAdd(1, .monotonic);
    const path = try std.fmt.bufPrint(buf, "/tmp/zh_g1_{d}_{d}_{d}", .{ stamp, pid, n });
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    std.Io.Dir.createDirPath(.cwd(), t.io(), path) catch {};
    return path;
}

fn writeFile(home: []const u8, rel: []const u8, data: []const u8) !void {
    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();
    const full = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ home, rel });
    defer std.heap.page_allocator.free(full);
    if (std.fs.path.dirname(full)) |parent| {
        std.Io.Dir.createDirPath(.cwd(), io, parent) catch {};
    }
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = full, .data = data });
}

// ── envelope helpers ────────────────────────────────────────────────────────

fn parseBody(alloc: std.mem.Allocator, resp: router.UnaryResponse) !struct {
    ok: bool,
    value_or_error: []const u8,
} {
    // resp.body: {"type":"server-response","rpcId":…,"result":{"ok":…,…}}
    const result_raw = jsonx.getRaw(resp.body, "result") orelse return error.TestUnexpectedResult;
    const ok = if (jsonx.getRaw(result_raw, "ok")) |o| std.mem.eql(u8, o, "true") else false;
    const inner = jsonx.getRaw(result_raw, if (ok) "value" else "error") orelse return error.TestUnexpectedResult;
    return .{ .ok = ok, .value_or_error = try alloc.dupe(u8, inner) };
}

fn unaryCall(
    deps: *const router.ApiProxyDeps,
    alloc: std.mem.Allocator,
    method: []const u8,
    payload: []const u8,
) !router.UnaryResponse {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"type\":\"client-request\",\"rpcId\":\"test-rpc-1\",\"method\":");
    try jsonx.appendJsonString(alloc, &body, method);
    try body.appendSlice(alloc, ",\"payload\":");
    try body.appendSlice(alloc, payload);
    try body.appendSlice(alloc, "}");
    const env = (try router.parseEnvelope(alloc, body.items)).?;
    return router.dispatch(deps, alloc, &env);
}

/// Build {"sessionId":…,"ref":{"id":…,"revision":…}} without fmt brace games.
fn refPayload(alloc: std.mem.Allocator, session_id: []const u8, id: []const u8, revision: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"sessionId\":");
    try jsonx.appendJsonString(alloc, &out, session_id);
    try out.appendSlice(alloc, ",\"ref\":{\"id\":");
    try jsonx.appendJsonString(alloc, &out, id);
    try out.appendSlice(alloc, ",\"revision\":");
    try jsonx.appendInt(alloc, &out, @intCast(revision));
    try out.appendSlice(alloc, "}}");
    return out.toOwnedSlice(alloc);
}

// ── deps stubs (required members) ──────────────────────────────────────────

fn listSessionsStub(ctx: ?*anyopaque, alloc: std.mem.Allocator) anyerror![]router.SessionSummary {
    const mode: *const bool = @ptrCast(@alignCast(ctx.?));
    const rows = try alloc.alloc(router.SessionSummary, 1);
    rows[0] = .{
        .session_id = "sess-1",
        .updated_at_ms = 0,
        .running = false,
        .blank = mode.*,
    };
    return rows;
}
fn historyStub(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: ?i64, _: ?u32) anyerror!router.HistoryPage {
    return .{ .entries = &.{} };
}
fn createStub(_: ?*anyopaque, _: std.mem.Allocator, _: router.CreateOptions) anyerror![]const u8 {
    return "sess-x";
}
fn promptStub(_: ?*anyopaque, _: std.mem.Allocator, _: router.PromptRequest) anyerror!router.PromptAck {
    return .{};
}
fn cancelStub(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!void {}
fn renameStub(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!router.RenameResult {
    return .{ .title = "t", .seq = 0 };
}

var blank_mode: bool = true;

fn stubDeps(home: []const u8) router.ApiProxyDeps {
    return .{
        .ctx = @ptrCast(&blank_mode),
        .home = home,
        .cwd = ".",
        .listSessions = listSessionsStub,
        .sessionHistory = historyStub,
        .createSession = createStub,
        .promptSession = promptStub,
        .cancelSession = cancelStub,
        .renameSession = renameStub,
    };
}

// ── goals domain ────────────────────────────────────────────────────────────

test "goal snapshot + projection builders produce upstream fold bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const snap = goals_rpc.Snapshot{
        .id = "goal-7",
        .revision = 3,
        .objective = "ship zharness",
        .phase = .active,
        .max_goal_rounds = 16,
    };
    const event_data = try goals_rpc.changeEventDataJson(a, "edit", &snap, 2, 1000, 2000);
    try testing.expectEqualStrings(
        "{\"kind\":\"goal/change\",\"version\":1,\"operation\":\"edit\"," ++
            "\"goal\":{\"id\":\"goal-7\",\"revision\":3,\"objective\":\"ship zharness\"," ++
            "\"phase\":\"active\",\"maxGoalRounds\":16}," ++
            "\"roundsStarted\":2,\"createdAt\":1000,\"updatedAt\":2000}",
        event_data,
    );

    const tomb = try goals_rpc.clearEventDataJson(a, "goal-7", 3, 3000);
    try testing.expectEqualStrings(
        "{\"kind\":\"goal/change\",\"version\":1,\"operation\":\"clear\"," ++
            "\"cleared\":{\"id\":\"goal-7\",\"revision\":3},\"clearedAt\":3000}",
        tomb,
    );

    var proj = goals_rpc.Projection{ .snapshot = snap, .rounds_started = 2, .created_at_ms = 1000, .updated_at_ms = 2000 };
    const pv = try goals_rpc.projectionValueJson(a, &proj);
    try testing.expectEqualStrings(
        "{\"goal\":{\"id\":\"goal-7\",\"revision\":3,\"objective\":\"ship zharness\"," ++
            "\"phase\":\"active\",\"maxGoalRounds\":16}," ++
            "\"roundsStarted\":2,\"createdAt\":1000,\"updatedAt\":2000}",
        pv,
    );

    proj = .{}; // cleared posture folds to null
    const null_proj = try goals_rpc.projectionValueJson(a, &proj);
    try testing.expectEqualStrings("null", null_proj);
}

test "blocked phase carries blockedReason exactly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const snap = goals_rpc.Snapshot{
        .id = "g",
        .revision = 9,
        .objective = "x",
        .phase = .blocked,
        .blocked_code = "awaiting-input",
        .blocked_message = "need user decision",
        .max_goal_rounds = 4,
    };
    var out: std.ArrayList(u8) = .empty;
    try goals_rpc.appendSnapshotJson(a, &out, &snap);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"blockedReason\":{\"code\":\"awaiting-input\",\"message\":\"need user decision\"}") != null);
    // Key set matches the strict decoder: blockedReason,id,maxGoalRounds,objective,phase,revision
    // (blockedReason sits between phase and maxGoalRounds in render order).
    try testing.expect(std.mem.indexOf(u8, out.items, "\"phase\":\"blocked\",\"blockedReason\":") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"maxGoalRounds\":4}") != null);
}

test "goal store lifecycle CAS verbs over the wire handlers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deps = stubDeps("");

    // create
    var resp = try unaryCall(&deps, a, "goal.create", "{\"sessionId\":\"wire-s\",\"objective\":\"write docs\",\"maxGoalRounds\":5}");
    var parsed = try parseBody(a, resp);
    try testing.expect(parsed.ok);
    // id depends on the global counter; assert SHAPE instead of exact id.
    try testing.expect(std.mem.startsWith(u8, parsed.value_or_error, "{\"ref\":{\"id\":\"goal-"));
    try testing.expect(std.mem.endsWith(u8, parsed.value_or_error, "\",\"revision\":1}}"));

    // stale-ref edit → bad-request (CAS failure, documented deviation)
    resp = try unaryCall(&deps, a, "goal.edit", "{\"sessionId\":\"wire-s\",\"ref\":{\"id\":\"nope\",\"revision\":99},\"objective\":\"x\"}");
    parsed = try parseBody(a, resp);
    try testing.expect(!parsed.ok);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"code\":\"bad-request\"") != null);

    // pause requires the CURRENT ref
    const cur = (try currentRef(a, "wire-s")).?;
    resp = try unaryCall(&deps, a, "goal.pause", try refPayload(a, "wire-s", cur.id, cur.rev));
    parsed = try parseBody(a, resp);
    try testing.expect(parsed.ok);

    // double pause → bad-request (phase machine)
    resp = try unaryCall(&deps, a, "goal.pause", try refPayload(a, "wire-s", cur.id, cur.rev + 1));
    parsed = try parseBody(a, resp);
    try testing.expect(!parsed.ok);

    // resume back to active, complete, clear
    const rev_after_resume = blk: {
        resp = try unaryCall(&deps, a, "goal.resume", try refPayload(a, "wire-s", cur.id, cur.rev + 1));
        parsed = try parseBody(a, resp);
        try testing.expect(parsed.ok);
        break :blk cur.rev + 2;
    };
    resp = try unaryCall(&deps, a, "goal.complete", try refPayload(a, "wire-s", cur.id, rev_after_resume));
    parsed = try parseBody(a, resp);
    try testing.expect(parsed.ok);

    // clear tombstones
    resp = try unaryCall(&deps, a, "goal.clear", try refPayload(a, "wire-s", cur.id, rev_after_resume + 1));
    parsed = try parseBody(a, resp);
    try testing.expect(parsed.ok);
    try testing.expectEqualStrings("{\"cleared\":true}", parsed.value_or_error);

    // projection folds to null after clear
    const store_c = try goals_rpc.shared();
    const proj = try store_c.projectionOf(a, "wire-s");
    try testing.expect(proj != null); // entry exists…
    try testing.expect(proj.?.snapshot == null); // …but folded to the tombstone
}

fn currentRef(alloc: std.mem.Allocator, session_id: []const u8) !?struct { id: []const u8, rev: u64 } {
    const store = try goals_rpc.shared();
    const p = (try store.projectionOf(alloc, session_id)) orelse return null;
    const s = p.snapshot orelse return null;
    return .{ .id = try alloc.dupe(u8, s.id), .rev = s.revision };
}

test "agentObjective hook bridges native board writes into the store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    goals_rpc.agentObjective("hook-s", "first objective");
    const store1 = try goals_rpc.shared();
    const p1 = (try store1.projectionOf(a, "hook-s")).?;
    try testing.expect(p1.snapshot != null);
    try testing.expectEqualStrings("first objective", p1.snapshot.?.objective);
    try testing.expectEqual(@as(u64, 1), p1.snapshot.?.revision);

    // Second call edits in place (native board holds single-writer authority).
    goals_rpc.agentObjective("hook-s", "second objective");
    const p2 = (try store1.projectionOf(a, "hook-s")).?;
    try testing.expectEqualStrings("second objective", p2.snapshot.?.objective);
    try testing.expectEqual(@as(u64, 2), p2.snapshot.?.revision);
}

// ── skills domain ───────────────────────────────────────────────────────────

test "skill.list scans workspace + home roots and renders SkillEntry rows" {
    var home_buf: [128]u8 = undefined;
    const home = try tempHome(&home_buf);
    var ws_buf: [160]u8 = undefined;
    const ws = try std.fmt.bufPrint(&ws_buf, "{s}/ws", .{home});

    try writeFile(ws, "skills/coding/SKILL.md", "---\nname: coding\ndescription: Code review guidance\n---\nbody\n");
    try writeFile(home, ".zharness/skills/zdebug/SKILL.md", "---\nname: zdebug\ndescription: Debug playbook\n---\nbody\n");
    // Broken candidate is skipped silently.
    try writeFile(ws, "skills/broken/SKILL.md", "not a skill");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ws_skills: [160]u8 = undefined;
    var home_skills: [160]u8 = undefined;
    const value = try skills_rpc.listValueFromDisk(
        a,
        try std.fmt.bufPrint(&ws_skills, "{s}/skills", .{ws}),
        try std.fmt.bufPrint(&home_skills, "{s}/.zharness/skills", .{home}),
    );
    try testing.expectEqualStrings(
        "{\"skills\":[" ++
            "{\"name\":\"coding\",\"description\":\"Code review guidance\",\"modelInvocable\":true}," ++
            "{\"name\":\"zdebug\",\"description\":\"Debug playbook\",\"modelInvocable\":true}" ++
            "]}",
        value,
    );
}

// ── models domain ───────────────────────────────────────────────────────────

test "session.models lists all provider groups and reflects the document selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = "[model]\nprovider = \"anthropic\"\nmodel = \"claude-sonnet-4-20250514\"\nmodels = [{\"id\":\"custom-gw-model\",\"name\":\"Gateway model\"}]\n\n[agent]\nreasoning_effort = \"low\"\n";
    const entries = try config.parseTomlFlat(a, doc);

    var value: std.ArrayList(u8) = .empty;
    const sel = models_rpc.currentSelection(entries);
    try testing.expectEqualStrings("anthropic", sel.provider);
    try testing.expectEqualStrings("claude-sonnet-4-20250514", sel.model);
    try testing.expectEqualStrings("low", sel.reasoning_effort.?);
    try value.appendSlice(a, "{\"current\":");
    try models_rpc.appendSelectionJson(a, &value, sel);
    try value.appendSlice(a, ",\"routable\":true,\"groups\":[");
    try models_rpc.appendGroupsJson(a, &value, entries);
    try value.appendSlice(a, "],\"failures\":[]}");

    // deepseek group carries the configured row FIRST plus deduped seeds.
    try testing.expect(std.mem.indexOf(u8, value.items, "{\"id\":\"deepseek\",\"name\":\"DeepSeek\",\"models\":[{\"id\":\"custom-gw-model\",\"name\":\"Gateway model\"},{\"id\":\"deepseek-chat\",\"name\":\"DeepSeek Chat\"}") != null);
    try testing.expect(std.mem.indexOf(u8, value.items, "{\"id\":\"anthropic\",\"name\":\"Anthropic\",\"models\":[{\"id\":\"claude-sonnet-4-20250514\",\"name\":\"Claude Sonnet 4\"}") != null);
    try testing.expect(std.mem.indexOf(u8, value.items, "{\"id\":\"ollama\"") != null);
    try testing.expect(std.mem.indexOf(u8, value.items, "{\"id\":\"openai-compat\"") != null);
}

test "selectInto persists provider/model/reasoningEffort through the settings Store" {
    var home_buf: [128]u8 = undefined;
    const home = try tempHome(&home_buf);

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    _ = threaded.io();
    var store = apx_settings.Store{ .gpa = std.heap.page_allocator, .home = home, .io = threaded.io() };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try models_rpc.selectInto(&store, a, "ollama", "llama3.1", "high");
    const doc = (try store.readDoc(a)).?;
    try testing.expect(std.mem.indexOf(u8, doc, "provider = \"ollama\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "model = \"llama3.1\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "reasoning_effort = \"high\"") != null);

    // Unknown providers rejected.
    try testing.expectError(error.UnknownProvider, models_rpc.selectInto(&store, a, "openrouter", "m", null));
}

// ── presets + perms domains (document-backed round trips) ──────────────────

test "agentPreset roster renders system trust and document default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const value = try presets_rpc.listValue(a, "ptc");
    try testing.expect(std.mem.indexOf(u8, value, "{\"id\":\"standard\",\"trust\":\"system\",\"isDefault\":false") != null);
    try testing.expect(std.mem.indexOf(u8, value, "{\"id\":\"ptc\",\"trust\":\"system\",\"isDefault\":true") != null);
    try testing.expect(std.mem.indexOf(u8, value, "\"authorable\":false,\"hasDocument\":false}") != null);

    // Default resolution falls back to standard without a document.
    try testing.expectEqualStrings("standard", presets_rpc.defaultPresetOf(null));
}

test "permission preset mapping and pseudo-namespace views" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("workspace-write", perms_rpc.currentPresetOf(null));

    var v: std.ArrayList(u8) = .empty;
    try perms_rpc.appendNamespaceViewJson(a, &v, 4, "danger-full-access");
    try testing.expect(std.mem.indexOf(u8, v.items, "\"ns\":\"permission\"") != null);
    // The schema advertises the union-of-consts enum the UI introspects.
    try testing.expect(std.mem.indexOf(u8, v.items, "\"value\":\"read-only\"") != null);
    try testing.expect(std.mem.indexOf(u8, v.items, "\"value\":\"danger-full-access\"") != null);
    try testing.expect(std.mem.indexOf(u8, v.items, "\"defaultPreset\":\"danger-full-access\"") != null);
    try testing.expect(std.mem.indexOf(u8, v.items, "\"revision\":4") != null);
}

// ── dispatch-level integration (singleton store, real temp home) ────────────

test "settings.describe carries permission + agent-presets; intercepted writes persist" {
    router.resetSettingsStoreForTests();
    perms_rpc.revisionPtr().* = 0;
    presets_rpc.revisionPtr().* = 0;
    var home_buf: [128]u8 = undefined;
    const home = try tempHome(&home_buf);
    // The singleton store keys off deps.home; give it stable storage.
    const stable_home = try std.heap.page_allocator.dupe(u8, home);
    var deps = stubDeps(stable_home);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 1) describe exposes both pseudo-namespaces alongside the real ones.
    var resp = try unaryCall(&deps, a, "settings.describe", "{}");
    var parsed = try parseBody(a, resp);
    try testing.expect(parsed.ok);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"ns\":\"permission\"") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"ns\":\"agent-presets\"") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"defaultPreset\":\"workspace-write\"") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"default\":\"standard\"") != null);

    // 2) intercepted update on agent-presets persists [general] agent_preset.
    resp = try unaryCall(&deps, a, "settings.update", "{\"ns\":\"agent-presets\",\"patch\":{\"default\":\"creative\"}}");
    parsed = try parseBody(a, resp);
    try testing.expect(parsed.ok);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"value\":{\"default\":\"creative\"}") != null);

    // 3) unknown preset id → settings-rejected.
    resp = try unaryCall(&deps, a, "settings.update", "{\"ns\":\"agent-presets\",\"patch\":{\"default\":\"bogus\"}}");
    parsed = try parseBody(a, resp);
    try testing.expect(!parsed.ok);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"code\":\"settings-rejected\"") != null);

    // 4) intercepted mutate on permission writes the mapped sandbox mode.
    resp = try unaryCall(&deps, a, "settings.mutate", "{\"ns\":\"permission\",\"ops\":[{\"op\":\"set\",\"path\":[\"defaultPreset\"],\"value\":\"danger-full-access\"}],\"expectedRevision\":0}");
    parsed = try parseBody(a, resp);
    try testing.expect(parsed.ok);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"value\":{\"defaultPreset\":\"danger-full-access\"}") != null);

    // Document truth: canonical knobs landed in config.toml.
    const store = router.settingsStoreOf(stable_home).?;
    const doc = (try store.readDoc(a)).?;
    try testing.expect(std.mem.indexOf(u8, doc, "agent_preset = \"creative\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "sandbox_mode = \"none\"") != null);

    // 5) stale expectedRevision → settings-conflict with {ns,expected,actual}.
    resp = try unaryCall(&deps, a, "settings.mutate", "{\"ns\":\"permission\",\"ops\":[{\"op\":\"set\",\"path\":[\"defaultPreset\"],\"value\":\"read-only\"}],\"expectedRevision\":0}");
    parsed = try parseBody(a, resp);
    try testing.expect(!parsed.ok);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"code\":\"settings-conflict\"") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"expected\":0") != null);

    // 6) describe now mirrors the persisted values.
    resp = try unaryCall(&deps, a, "settings.describe", "{}");
    parsed = try parseBody(a, resp);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"defaultPreset\":\"danger-full-access\"") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"default\":\"creative\"") != null);
}

test "agentPreset.select validates roster and blank-gates via sessions dep" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var deps = stubDeps("");
    presets_rpc.clearSelections();

    // unknown preset
    var resp = try unaryCall(&deps, a, "agentPreset.select", "{\"sessionId\":\"sess-1\",\"agentPreset\":\"bogus\"}");
    var parsed = try parseBody(a, resp);
    try testing.expect(!parsed.ok);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"code\":\"agent-preset-not-found\"") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"available\":[\"standard\",\"minimal\",\"ptc\",\"creative\"]") != null);

    // blank session accepts
    blank_mode = true;
    resp = try unaryCall(&deps, a, "agentPreset.select", "{\"sessionId\":\"sess-1\",\"agentPreset\":\"minimal\"}");
    parsed = try parseBody(a, resp);
    try testing.expect(parsed.ok);
    try testing.expectEqualStrings("{\"agentPreset\":\"minimal\"}", parsed.value_or_error);
    try testing.expectEqualStrings("minimal", presets_rpc.selectionFor("sess-1").?);

    // started session locks
    blank_mode = false;
    resp = try unaryCall(&deps, a, "agentPreset.select", "{\"sessionId\":\"sess-1\",\"agentPreset\":\"ptc\"}");
    parsed = try parseBody(a, resp);
    try testing.expect(!parsed.ok);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"code\":\"agent-preset-locked\"") != null);
    // …and the recorded selection was not overwritten.
    try testing.expectEqualStrings("minimal", presets_rpc.selectionFor("sess-1").?);
}

test "llm.providers renders the four-route matrix with the live route flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var deps = stubDeps("");
    deps.provider = "anthropic";

    const resp = try unaryCall(&deps, a, "llm.providers", "{}");
    const parsed = try parseBody(a, resp);
    try testing.expect(parsed.ok);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "{\"provider\":\"deepseek\",\"displayName\":\"DeepSeek\",\"settingsNs\":\"llm-deepseek\",\"settingsPath\":[],\"active\":false,\"declared\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "{\"provider\":\"anthropic\",\"displayName\":\"Anthropic\",\"settingsNs\":\"agent\",\"settingsPath\":[\"provider\"],\"active\":true,\"declared\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"provider\":\"ollama\"") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"provider\":\"openai-compat\"") != null);
}

test "session.models + selectModel answer through dispatch with a real home" {
    router.resetSettingsStoreForTests();
    perms_rpc.revisionPtr().* = 0;
    presets_rpc.revisionPtr().* = 0;
    var home_buf: [128]u8 = undefined;
    const home = try tempHome(&home_buf);
    const stable_home = try std.heap.page_allocator.dupe(u8, home);
    var deps = stubDeps(stable_home);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var resp = try unaryCall(&deps, a, "session.models", "{\"sessionId\":\"sess-1\"}");
    var parsed = try parseBody(a, resp);
    try testing.expect(parsed.ok);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"current\":{\"provider\":\"deepseek\",\"model\":\"deepseek-v4-flash\",\"reasoningEffort\":\"medium\"}") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"routable\":true") != null);

    resp = try unaryCall(&deps, a, "session.selectModel", "{\"sessionId\":\"sess-1\",\"provider\":\"deepseek\",\"model\":\"deepseek-reasoner\",\"reasoningEffort\":\"low\"}");
    parsed = try parseBody(a, resp);
    try testing.expect(parsed.ok);
    try testing.expectEqualStrings("{\"selected\":{\"provider\":\"deepseek\",\"model\":\"deepseek-reasoner\",\"reasoningEffort\":\"low\"}}", parsed.value_or_error);

    // Persisted: the next models read reports the new selection.
    resp = try unaryCall(&deps, a, "session.models", "{\"sessionId\":\"sess-1\"}");
    parsed = try parseBody(a, resp);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"current\":{\"provider\":\"deepseek\",\"model\":\"deepseek-reasoner\",\"reasoningEffort\":\"low\"}") != null);

    // Unknown provider → model-unavailable {provider,model}.
    resp = try unaryCall(&deps, a, "session.selectModel", "{\"sessionId\":\"sess-1\",\"provider\":\"openrouter\",\"model\":\"m\"}");
    parsed = try parseBody(a, resp);
    try testing.expect(!parsed.ok);
    try testing.expect(std.mem.indexOf(u8, parsed.value_or_error, "\"code\":\"model-unavailable\"") != null);
}
