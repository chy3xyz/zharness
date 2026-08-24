//! Jobs surface — background work as the DSH `session/jobs` frame list
//! (contract truth: `_ref/deepseek-harness/packages/host/apiproxy/src/api/
//! {jobs.ts,jobs.schema.ts,events.schema.ts}` + ui-jobs recon).
//!
//! ── TRANSPORT (recon verdict) ──────────────────────────────────────────────
//!
//! Jobs are FRAME-ONLY upstream: ui-jobs renders the client's `jobsBySession`
//! mirror fed by mux frames and "issues no RPC" (ui-jobs/src/client/index.ts).
//! There is no jobs.* unary method in rpc-map.ts — so this module ships frame
//! builders + a publish helper, NOT a polled RPC. For zharness-side tooling
//! an optional extension method `zharness.jobs.list` is exposed via
//! handleJobsList (the vendored GUI never calls it; harmless addition).
//!
//! Frame payload (taskViewSchema):
//!
//!   {"type":"session/jobs","sessionId":"…","jobs":[
//!     {"id":"workflow-1","kind":"workflow","label":"smoke",
//!      "status":"completed","startedAt":1755946500000,"finishedAt":…}, …]}
//!
//! status ∈ running|stopping|completed|killed|failed; finishedAt absent while
//! live. detail optional.
//!
//! ── SOURCES (zharness mapping) ──────────────────────────────────────────────
//!
//! 1. LIVE registry (`JobRegistry` singleton): detached GUI runs / background
//!    tasks registered by integrator code. Process-global SpinLock singleton
//!    on the C allocator (settings.Store / events_ws.Hubs precedent). The one-
//!    line integrator hook is reported in the module report: call
//!    `registry.register(...)` when a detached run starts and `.settle(...)`
//!    when it ends.
//! 2. DURABLE workflow runs: every `.zharness/runs/<name>.json` (run_report.zig
//!    shape) becomes one settled job row — id `wf-<name>`, kind `workflow`,
//!    label `<name>`, status completed|failed, startedAt = created_at×1000.
//!    GAP: run reports carry no completion timestamp, so finishedAt is omitted
//!    for disk rows even though they are settled.
//!
//! Unknown/malformed run files are skipped (never fail the whole list); an
//! empty sources set renders `"jobs":[]`.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const router = @import("router.zig");
const events_ws = @import("events_ws.zig");

extern "c" fn time(tloc: ?*c_long) c_long;

fn nowMs() i64 {
    return @as(i64, @intCast(time(null))) * std.time.ms_per_s;
}

// ── job view DTO ────────────────────────────────────────────────────────────

pub const JobStatus = enum {
    running,
    stopping,
    completed,
    killed,
    failed,

    pub fn asStr(self: JobStatus) []const u8 {
        return @tagName(self);
    }
};

/// One wire task view (taskViewSchema field order). String slices are owned
/// by whoever produced the snapshot (see JobRegistry.listSnapshot).
pub const JobView = struct {
    id: []const u8,
    kind: []const u8,
    label: []const u8,
    status: JobStatus = .running,
    detail: ?[]const u8 = null,
    started_at_ms: i64,
    finished_at_ms: ?i64 = null,
};

/// Append one task view in schema declaration order.
pub fn appendJobViewJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), j: *const JobView) !void {
    try out.appendSlice(alloc, "{\"id\":");
    try jsonx.appendJsonString(alloc, out, j.id);
    try out.appendSlice(alloc, ",\"kind\":");
    try jsonx.appendJsonString(alloc, out, j.kind);
    try out.appendSlice(alloc, ",\"label\":");
    try jsonx.appendJsonString(alloc, out, j.label);
    try out.appendSlice(alloc, ",\"status\":");
    try jsonx.appendJsonString(alloc, out, j.status.asStr());
    if (j.detail) |d| {
        try out.appendSlice(alloc, ",\"detail\":");
        try jsonx.appendJsonString(alloc, out, d);
    }
    try out.appendSlice(alloc, ",\"startedAt\":");
    try jsonx.appendInt(alloc, out, j.started_at_ms);
    if (j.finished_at_ms) |f| {
        try out.appendSlice(alloc, ",\"finishedAt\":");
        try jsonx.appendInt(alloc, out, f);
    }
    try out.append(alloc, '}');
}

// ── live registry (process-global singleton, SpinLock pattern) ──────────────

const RegistryEntry = struct {
    id: []u8,
    kind: []u8,
    label: []u8,
    detail: ?[]u8,
    status: JobStatus,
    started_at_ms: i64,
    finished_at_ms: ?i64,
};

pub const JobRegistry = struct {
    gpa: std.mem.Allocator,
    lock: std.atomic.Value(bool) = .init(false),
    entries: std.ArrayList(RegistryEntry) = .empty,
    counter: u64 = 0,
    /// Register/settle calls refused because a string could not be stored.
    dropped: usize = 0,

    fn lockSlow(self: *JobRegistry) void {
        var spins: u32 = 0;
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins >= 16) {
                const req: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
                _ = nanosleep(&req, null);
            } else std.atomic.spinLoopHint();
        }
    }

    /// Register a live job. Returns the minted `<kind>-N` id (registry-owned;
    /// valid for the process lifetime — copy it if you must keep it longer).
    pub fn register(self: *JobRegistry, kind: []const u8, label: []const u8) ?[]const u8 {
        return self.registerAt(kind, label, nowMs());
    }

    /// Register a live job at an explicit start time (test seam). Returns the
    /// minted `<kind>-N` id (registry-owned; valid for the process lifetime —
    /// copy it if you must keep it longer).
    pub fn registerAt(self: *JobRegistry, kind: []const u8, label: []const u8, started_ms: i64) ?[]const u8 {
        self.lockSlow();
        defer self.lock.store(false, .release);

        self.counter += 1;
        const id = std.fmt.allocPrint(self.gpa, "{s}-{d}", .{ kind, self.counter }) catch {
            self.counter -= 1;
            self.dropped += 1;
            return null;
        };
        const kind_c = self.gpa.dupe(u8, kind) catch {
            self.gpa.free(id);
            self.dropped += 1;
            return null;
        };
        const label_c = self.gpa.dupe(u8, label) catch {
            self.gpa.free(id);
            self.gpa.free(kind_c);
            self.dropped += 1;
            return null;
        };
        self.entries.append(self.gpa, .{
            .id = id,
            .kind = kind_c,
            .label = label_c,
            .detail = null,
            .status = .running,
            .started_at_ms = started_ms,
            .finished_at_ms = null,
        }) catch {
            self.gpa.free(id);
            self.gpa.free(kind_c);
            self.gpa.free(label_c);
            self.dropped += 1;
            return null;
        };
        return id;
    }

    /// Settle a previously registered job. Unknown ids return false.
    pub fn settle(self: *JobRegistry, id: []const u8, status: JobStatus, detail: ?[]const u8) bool {
        self.lockSlow();
        defer self.lock.store(false, .release);
        for (self.entries.items) |*e| {
            if (!std.mem.eql(u8, e.id, id)) continue;
            e.status = status;
            e.finished_at_ms = nowMs();
            if (detail) |d| {
                if (e.detail) |old| self.gpa.free(old);
                e.detail = self.gpa.dupe(u8, d) catch null;
            }
            return true;
        }
        return false;
    }

    /// Snapshot of all entries; strings are duped with `alloc` (typically the
    /// request arena). Caller owns the slice AND each string.
    pub fn listSnapshot(self: *JobRegistry, alloc: std.mem.Allocator) ![]JobView {
        self.lockSlow();
        var out: std.ArrayList(JobView) = .empty;
        errdefer out.deinit(alloc);
        for (self.entries.items) |*e| {
            const id = try alloc.dupe(u8, e.id);
            errdefer alloc.free(id);
            const kind = try alloc.dupe(u8, e.kind);
            errdefer alloc.free(kind);
            const label = try alloc.dupe(u8, e.label);
            errdefer alloc.free(label);
            const detail: ?[]const u8 = if (e.detail) |d| try alloc.dupe(u8, d) else null;
            try out.append(alloc, .{
                .id = id,
                .kind = kind,
                .label = label,
                .status = e.status,
                .detail = detail,
                .started_at_ms = e.started_at_ms,
                .finished_at_ms = e.finished_at_ms,
            });
        }
        self.lock.store(false, .release);
        return out.toOwnedSlice(alloc);
    }

    pub fn count(self: *JobRegistry) usize {
        self.lockSlow();
        defer self.lock.store(false, .release);
        return self.entries.items.len;
    }

    fn freeEntry(self: *JobRegistry, e: *RegistryEntry) void {
        self.gpa.free(e.id);
        self.gpa.free(e.kind);
        self.gpa.free(e.label);
        if (e.detail) |d| self.gpa.free(d);
    }

    /// Release all entries (used by tests and process teardown).
    pub fn deinit(self: *JobRegistry) void {
        self.lockSlow();
        defer self.lock.store(false, .release);
        for (self.entries.items) |*e| self.freeEntry(e);
        self.entries.deinit(self.gpa);
    }

    /// Drop settled entries older than everything currently listed (simple
    /// compaction the integrator may call occasionally; keeps the registry
    /// bounded across long server lifetimes).
    pub fn pruneSettled(self: *JobRegistry, keep_last: usize) void {
        self.lockSlow();
        defer self.lock.store(false, .release);
        var alive: std.ArrayList(RegistryEntry) = .empty;
        var settled_seen: usize = 0;
        // Count from the end: retain at most `keep_last` settled entries.
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = &self.entries.items[i];
            const settled = e.status != .running and e.status != .stopping;
            if (settled and settled_seen < keep_last) {
                settled_seen += 1;
                alive.append(self.gpa, e.*) catch self.freeEntry(e);
            } else if (!settled) {
                alive.append(self.gpa, e.*) catch self.freeEntry(e);
            } else {
                self.freeEntry(e);
            }
        }
        // Reverse back into chronological order.
        std.mem.reverse(RegistryEntry, alive.items);
        self.entries.deinit(self.gpa);
        self.entries = alive;
    }
};

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

var g_registry: ?*JobRegistry = null;

/// Process-wide live-job registry, created on first use on the C allocator
/// (it outlives every request arena). Idempotent.
pub fn sharedRegistry() !*JobRegistry {
    if (g_registry) |r| return r;
    const r = try std.heap.c_allocator.create(JobRegistry);
    r.* = .{ .gpa = std.heap.c_allocator };
    g_registry = r;
    return r;
}

/// Test hook: detach the singleton (caller destroys nothing — test registries
/// should be local instances instead).
pub fn takeSharedRegistry() ?*JobRegistry {
    const r = g_registry;
    g_registry = null;
    return r;
}

// ── durable workflow runs as job rows ───────────────────────────────────────

/// One parsed `.zharness/runs/<file>.json` row (tolerant subset of the
/// run_report.zig document).
pub const RunRow = struct {
    name: []const u8,
    status_str: []const u8,
    created_at_secs: i64,
    file_name: []const u8,
};

/// Map a run-report status string onto the closed JobStatus union.
fn jobStatusFromRun(status: []const u8) JobStatus {
    if (std.mem.eql(u8, status, "failed")) return .failed;
    return .completed;
}

fn appendRunJobs(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    out: *std.ArrayList(u8),
    first: *bool,
) !void {
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.zharness/runs", .{cwd});
    defer alloc.free(dir_path);

    const dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch return;
    defer std.Io.Dir.close(dir, io);

    var it = std.Io.Dir.iterate(dir);
    while (it.next(io) catch null) |entry| {
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        if (std.mem.startsWith(u8, name, ".")) continue;

        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, name });
        defer alloc.free(path);
        const raw = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, .limited(4 << 20)) catch continue;
        defer alloc.free(raw);

        const run_name = blk: {
            const s = (jsonx.getStringAlloc(alloc, raw, "workflow") catch null) orelse break :blk null;
            if (s.len == 0) {
                alloc.free(s);
                break :blk null;
            }
            break :blk s;
        } orelse continue;
        defer alloc.free(run_name);
        const status = ((jsonx.getStringAlloc(alloc, raw, "status") catch null)) orelse {
            // Parse produced nothing; raw is freed by its defer above.
            continue;
        };
        defer alloc.free(status);
        const created = jsonx.getInt(raw, "created_at") orelse 0;

        if (!first.*) try out.append(alloc, ',');
        first.* = false;
        const view = JobView{
            .id = try std.fmt.allocPrint(alloc, "wf-{s}", .{run_name}),
            .kind = "workflow",
            .label = run_name,
            .status = jobStatusFromRun(status),
            .detail = null,
            .started_at_ms = created * std.time.ms_per_s,
            // GAP: no completion timestamp in the durable report.
            .finished_at_ms = null,
        };
        defer alloc.free(view.id);
        try appendJobViewJson(alloc, out, &view);
    }
}

// ── value + frame builders ──────────────────────────────────────────────────

/// Build the combined jobs VALUE (`{"jobs":[…]}`): live registry rows first,
/// then durable workflow runs. All allocations on `alloc` (request arena).
pub fn jobsListValue(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]u8 {
    return jobsListValueFrom(alloc, io, cwd, g_registry);
}

/// Same builder against an explicit registry (test seam; null = disk only).
pub fn jobsListValueFrom(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    reg: ?*JobRegistry,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jobs\":[");

    var first = true;
    if (reg) |r| {
        const snapshot = try r.listSnapshot(alloc);
        defer {
            for (snapshot) |j| {
                alloc.free(j.id);
                alloc.free(j.kind);
                alloc.free(j.label);
                if (j.detail) |d| alloc.free(d);
            }
            alloc.free(snapshot);
        }
        for (snapshot) |*j| {
            if (!first) try out.append(alloc, ',');
            first = false;
            try appendJobViewJson(alloc, &out, j);
        }
    }
    try appendRunJobs(alloc, io, cwd, &out, &first);

    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

/// Full `session/jobs` frame PAYLOAD around a pre-rendered jobs array JSON.
/// Caller frees. `jobs_array_json` is the bare `[…]` array text.
pub fn jobsFramePayload(
    alloc: std.mem.Allocator,
    session_id: []const u8,
    jobs_array_json: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"type\":\"session/jobs\",\"sessionId\":");
    try jsonx.appendJsonString(alloc, &out, session_id);
    try out.appendSlice(alloc, ",\"jobs\":");
    try out.appendSlice(alloc, jobs_array_json);
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

/// Publish the CURRENT combined jobs list as a session/jobs frame on the
/// shared mux hub. No-op without hubs; failures swallowed (bridge contract).
pub fn publishJobs(io: std.Io, session_id: []const u8, cwd: []const u8) void {
    const hubs = events_ws.sharedHubs() catch return;
    publishJobsOn(&hubs.mux, io, session_id, cwd);
}

/// Same against an explicit hub (test seam).
pub fn publishJobsOn(hub: *events_ws.FrameHub, io: std.Io, session_id: []const u8, cwd: []const u8) void {
    const alloc = hub.alloc;
    const value = jobsListValue(alloc, io, cwd) catch return;
    defer alloc.free(value);
    // Splice the bare array out of {"jobs":[…]} to reuse jobsFramePayload.
    const arr = jsonx.getRaw(value, "jobs") orelse return;
    const payload = jobsFramePayload(alloc, session_id, arr) catch return;
    defer alloc.free(payload);
    hub.publish("session/jobs", payload);
}

// ── optional unary handler (zharness extension `zharness.jobs.list`) ───────

/// Handler for the zharness-only polling method. G1 wires it in
/// router.dispatch as:
///   if (std.mem.eql(u8, m, "zharness.jobs.list"))
///       return jobs_rpc.handleJobsList(alloc, env.rpc_id, deps.cwd);
/// (io comes from the request's threaded Io; cwd from ApiProxyDeps.cwd.)
pub fn handleJobsList(
    alloc: std.mem.Allocator,
    rpc_id: []const u8,
    io: std.Io,
    cwd: []const u8,
) !router.UnaryResponse {
    const value = try jobsListValue(alloc, io, cwd);
    return router.okValue(alloc, rpc_id, value);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "job view serializes in schema declaration order" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const j = JobView{
        .id = "bash-3",
        .kind = "bash",
        .label = "cargo build",
        .status = .completed,
        .detail = "exit code: 0",
        .started_at_ms = 1000,
        .finished_at_ms = 2500,
    };
    try appendJobViewJson(testing.allocator, &out, &j);
    try testing.expectEqualStrings(
        "{\"id\":\"bash-3\",\"kind\":\"bash\",\"label\":\"cargo build\"," ++
            "\"status\":\"completed\",\"detail\":\"exit code: 0\"," ++
            "\"startedAt\":1000,\"finishedAt\":2500}",
        out.items,
    );

    var live: std.ArrayList(u8) = .empty;
    defer live.deinit(testing.allocator);
    const j2 = JobView{ .id = "x-1", .kind = "k", .label = "l", .started_at_ms = 5 };
    try appendJobViewJson(testing.allocator, &live, &j2);
    try testing.expectEqualStrings(
        "{\"id\":\"x-1\",\"kind\":\"k\",\"label\":\"l\",\"status\":\"running\",\"startedAt\":5}",
        live.items,
    );
}

test "registry lifecycle: register settle snapshot prune" {
    var reg = JobRegistry{ .gpa = testing.allocator };

    const id1 = reg.registerAt("bash", "sleep 10", 100).?;
    const id2 = reg.registerAt("workflow", "ship-it", 200).?;
    try testing.expectEqualStrings("bash-1", id1);
    try testing.expectEqualStrings("workflow-2", id2);
    try testing.expectEqual(@as(usize, 2), reg.count());

    try testing.expect(reg.settle(id1, .completed, "exit code: 0"));
    try testing.expect(!reg.settle("nope-9", .failed, null));

    const snap = try reg.listSnapshot(testing.allocator);
    defer {
        for (snap) |j| {
            testing.allocator.free(j.id);
            testing.allocator.free(j.kind);
            testing.allocator.free(j.label);
            if (j.detail) |d| testing.allocator.free(d);
        }
        testing.allocator.free(snap);
    }
    try testing.expectEqual(@as(usize, 2), snap.len);
    try testing.expectEqualStrings("completed", snap[0].status.asStr());
    try testing.expectEqualStrings("exit code: 0", snap[0].detail.?);
    try testing.expect(snap[0].finished_at_ms != null);
    try testing.expectEqual(JobStatus.running, snap[1].status);
    try testing.expect(snap[1].finished_at_ms == null);

    // Prune keeps running entries and at most `keep_last` settled ones.
    reg.pruneSettled(0);
    try testing.expectEqual(@as(usize, 1), reg.count());
    reg.deinit();
}
