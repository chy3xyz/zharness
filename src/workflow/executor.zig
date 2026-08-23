//! Workflow execution (dev.md §XIX): run a validated `Workflow` as a DAG of
//! agent tasks, wave by wave.
//!
//! Contract:
//!   - The step runner is INJECTED as a plain fn pointer
//!     (`StepRunner`) so this module stays decoupled from the agent loop /
//!     cordis. main.zig wraps AgentLoop invocation in one function.
//!   - Execution is sequential, wave by wave: wave k contains every step all
//!     of whose dependencies landed in earlier waves (Kahn layering); within
//!     a wave steps run in declaration order. `computeWaves` is exposed for
//!     integrators that want to display progress grouping.
//!   - Every completed step's result is captured in-memory as an artifact
//!     (id -> result). Later steps see earlier artifacts through
//!     `StepContext.artifacts` — that is how downstream prompts are assembled
//!     from upstream output.
//!   - Failure policy: stop on first failure by default
//!     (`stop_on_first_failure = true`); remaining steps are not executed.
//!     Completed artifacts survive in the outcome regardless.
//!   - Runner errors never propagate; they become `failed_step` + `error`
//!     text (the error name) on the outcome. Only structural problems
//!     (cycles in an unvalidated workflow, OOM) return as errors.
//!
//! Ownership: the runner allocates its result from the passed allocator;
//! the outcome takes ownership and frees everything in
//! `WorkflowOutcome.deinit`.

const std = @import("std");
const wf_mod = @import("workflow.zig");

pub const Workflow = wf_mod.Workflow;

/// One completed step's captured output.
pub const Artifact = struct {
    id: []u8,
    result: []u8,
};

/// Read-only view over artifacts accumulated so far, handed to runners so
/// they can compose prompts from dependency results.
pub const Artifacts = struct {
    items: std.ArrayList(Artifact) = .empty,

    /// Result string for `id`, or null when the step has not completed.
    pub fn get(self: *const Artifacts, id: []const u8) ?[]const u8 {
        for (self.items.items) |*a| {
            if (std.mem.eql(u8, a.id, id)) return a.result;
        }
        return null;
    }

    pub fn count(self: *const Artifacts) usize {
        return self.items.items.len;
    }

    fn put(self: *Artifacts, alloc: std.mem.Allocator, id: []const u8, result: []u8) !void {
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        try self.items.append(alloc, .{ .id = owned_id, .result = result });
    }

    fn deinit(self: *Artifacts, alloc: std.mem.Allocator) void {
        for (self.items.items) |*a| {
            alloc.free(a.id);
            alloc.free(a.result);
        }
        self.items.deinit(alloc);
    }
};

/// Context threaded into every runner invocation.
pub const StepContext = struct {
    step_id: []const u8,
    workflow_name: []const u8,
    /// Per-step turn cap from the workflow definition (null = runner default).
    max_turns: ?u32,
    /// Artifacts completed before this step started (dependency results).
    artifacts: *const Artifacts,
    /// Opaque caller context (e.g. pointer to the agent/session wiring).
    user: ?*anyopaque = null,
};

/// Runs ONE step. Implementations should invoke the agent loop with
/// `step_prompt` (usually enriched with ctx.artifacts) and honor
/// `ctx.max_turns`. Return a fresh allocation from `alloc`; ownership passes
/// to the executor. Any error fails the step per the failure policy.
pub const StepRunner = *const fn (
    alloc: std.mem.Allocator,
    io: std.Io,
    step_prompt: []const u8,
    ctx: *const StepContext,
) anyerror![]u8;

pub const StepStatus = enum { completed, skipped, failed };

pub const OutcomeStatus = enum { completed, failed };

/// Terminal result of a run. Free with deinit(alloc).
pub const WorkflowOutcome = struct {
    status: OutcomeStatus,
    /// Completed step results in execution order (wave by wave).
    artifacts: []Artifact,
    /// Id of the first failing step, when status == .failed.
    failed_step: ?[]u8,
    /// Error NAME of the first failure ("StepExploded" style); the spec's
    /// "error?" field, renamed because `error` is a Zig keyword.
    err: ?[]u8,

    pub fn deinit(self: *WorkflowOutcome, alloc: std.mem.Allocator) void {
        for (self.artifacts) |*a| {
            alloc.free(a.id);
            alloc.free(a.result);
        }
        alloc.free(self.artifacts);
        if (self.failed_step) |s| alloc.free(s);
        if (self.err) |s| alloc.free(s);
    }

    /// Result of the step with the given id, or null when it did not
    /// complete (failed / skipped / never reached).
    pub fn artifactOf(self: *const WorkflowOutcome, id: []const u8) ?[]const u8 {
        for (self.artifacts) |*a| {
            if (std.mem.eql(u8, a.id, id)) return a.result;
        }
        return null;
    }
};

pub const RunError = error{ CyclicDependency, OutOfMemory };

pub const Executor = struct {
    alloc: std.mem.Allocator,
    runner: StepRunner,
    /// Opaque context forwarded verbatim inside every StepContext.user.
    user: ?*anyopaque = null,
    /// Default true: abort at the first failed step. When false, later waves
    /// still run unless they (transitively) depend on a failed/skipped step.
    stop_on_first_failure: bool = true,

    pub fn init(alloc: std.mem.Allocator, runner: StepRunner) Executor {
        return .{ .alloc = alloc, .runner = runner };
    }

    /// Execute the whole workflow sequentially, honoring depends_on.
    /// The workflow should be validated first; an unvalidated cyclic graph is
    /// rejected here with error.CyclicDependency rather than looping forever.
    pub fn run(self: *Executor, io: std.Io, wf: *const Workflow) RunError!WorkflowOutcome {
        const alloc = self.alloc;

        const waves = try computeWaves(alloc, wf);
        defer freeWaves(alloc, waves);

        var arts: Artifacts = .{};
        var failed_index: ?usize = null;
        var failed_msg: ?[]u8 = null;
        // Any error past this point must release what the run captured so
        // far (runner results, failure text).
        errdefer {
            arts.deinit(alloc);
            if (failed_msg) |m| alloc.free(m);
        }

        // Track states only for the failure-policy bookkeeping.
        const State = enum { pending, completed, skipped, failed };
        const states = try alloc.alloc(State, wf.steps.len);
        defer alloc.free(states);
        @memset(states, .pending);

        var aborted = false;
        for (waves) |wave| {
            for (wave) |si| {
                if (aborted) break;

                const step = &wf.steps[si];

                // Failure policy: once a failure happened...
                if (failed_index != null) {
                    if (self.stop_on_first_failure) {
                        // ...stop everything; untouched steps stay pending
                        // (they simply never ran).
                        aborted = true;
                        break;
                    }
                    // Continue mode: skip this step iff it depends (directly
                    // or transitively via earlier decisions) on a failed or
                    // skipped step.
                    var blocked = false;
                    for (step.depends_on) |d| {
                        const di = wf.indexOfId(d) orelse continue;
                        if (states[di] == .failed or states[di] == .skipped) blocked = true;
                    }
                    if (blocked) {
                        states[si] = .skipped;
                        continue;
                    }
                }

                var sctx = StepContext{
                    .step_id = step.id,
                    .workflow_name = wf.name,
                    .max_turns = step.max_turns,
                    .artifacts = &arts,
                    .user = self.user,
                };

                const result = self.runner(alloc, io, step.prompt, &sctx) catch |e| {
                    states[si] = .failed;
                    if (failed_index == null) {
                        failed_index = si;
                        failed_msg = try alloc.dupe(u8, @errorName(e));
                    }
                    if (self.stop_on_first_failure) {
                        aborted = true;
                        break;
                    }
                    continue;
                };

                try arts.put(alloc, step.id, result);
                states[si] = .completed;
            }
            if (aborted) break;
        }

        const artifacts = try arts.items.toOwnedSlice(alloc);
        errdefer alloc.free(artifacts);

        const failed_step: ?[]u8 = if (failed_index) |si|
            try alloc.dupe(u8, wf.steps[si].id)
        else
            null;

        return WorkflowOutcome{
            .status = if (failed_index != null) .failed else .completed,
            .artifacts = artifacts,
            .failed_step = failed_step,
            .err = failed_msg,
        };
    }
};

/// Kahn-style layered topological sort: wave k lists indices of every step
/// whose dependencies all live in waves < k. Steps keep declaration order
/// inside their wave. Returns error.CyclicDependency when no progress is
/// possible (unvalidated input).
pub fn computeWaves(alloc: std.mem.Allocator, wf: *const Workflow) RunError![][]const usize {
    var waves: std.ArrayList([]const usize) = .empty;
    errdefer freeWaves(alloc, waves.items);

    const assigned = try alloc.alloc(bool, wf.steps.len);
    defer alloc.free(assigned);
    @memset(assigned, false);

    var done: usize = 0;
    while (done < wf.steps.len) {
        var wave: std.ArrayList(usize) = .empty;
        errdefer wave.deinit(alloc);

        for (wf.steps, 0..) |*step, si| {
            if (assigned[si]) continue;
            var ready = true;
            for (step.depends_on) |d| {
                const di = wf.indexOfId(d) orelse {
                    ready = false; // unknown dep — treat as never-ready
                    break;
                };
                if (!assigned[di]) {
                    ready = false;
                    break;
                }
            }
            if (ready) try wave.append(alloc, si);
        }

        if (wave.items.len == 0) {
            // No progress possible ⇒ dependency cycle (or unknown dep id).
            // errdefer above releases `wave`; earlier waves via the outer one.
            return error.CyclicDependency;
        }
        for (wave.items) |si| assigned[si] = true;
        done += wave.items.len;
        const w = try wave.toOwnedSlice(alloc);
        waves.append(alloc, w) catch {
            alloc.free(w);
            return error.OutOfMemory; // errdefer frees earlier waves
        };
    }

    return waves.toOwnedSlice(alloc);
}

fn freeWaves(alloc: std.mem.Allocator, waves: [][]const usize) void {
    for (waves) |w| alloc.free(w);
    if (waves.len > 0) alloc.free(waves);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Shared fake-runner state: records invocation order, optionally explodes on
/// a given step id, and composes each result from dependency artifacts so
/// tests can prove cross-wave data flow through StepContext.
const Rec = struct {
    alloc: std.mem.Allocator,
    call_order: std.ArrayList([]u8) = .empty,
    fail_on: ?[]const u8 = null,
    fail_count: usize = 0,

    fn recordAndCompose(
        alloc: std.mem.Allocator,
        io: std.Io,
        step_prompt: []const u8,
        ctx: *const StepContext,
    ) anyerror![]u8 {
        _ = io;
        _ = step_prompt;
        const rec: *Rec = @ptrCast(@alignCast(ctx.user.?));
        try rec.call_order.append(rec.alloc, try rec.alloc.dupe(u8, ctx.step_id));

        if (rec.fail_on) |target| {
            if (std.mem.eql(u8, ctx.step_id, target)) {
                rec.fail_count += 1;
                return error.StepExploded;
            }
        }

        // Result = "<id>(" + [dep_result,...] joined by "," + ")".
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, ctx.step_id);
        try out.appendSlice(alloc, "(");
        for (ctx.artifacts.items.items, 0..) |a, i| {
            if (i > 0) try out.appendSlice(alloc, ",");
            try out.appendSlice(alloc, a.result);
        }
        try out.appendSlice(alloc, ")");
        return out.toOwnedSlice(alloc);
    }
};

fn diamondJson() []const u8 {
    return "{\"name\":\"diamond\",\"steps\":[" ++
        "{\"id\":\"a\",\"prompt\":\"pa\"}," ++
        "{\"id\":\"b\",\"prompt\":\"pb\",\"depends_on\":[\"a\"]}," ++
        "{\"id\":\"c\",\"prompt\":\"pc\",\"depends_on\":[\"a\"]}," ++
        "{\"id\":\"d\",\"prompt\":\"pd\",\"depends_on\":[\"b\",\"c\"]}]}";
}

test "computeWaves layers a diamond correctly" {
    const alloc = testing.allocator;
    var wf = try Workflow.parseValidated(alloc, diamondJson());
    defer wf.deinit(alloc);

    const waves = try computeWaves(alloc, &wf);
    defer freeWaves(alloc, waves);

    try testing.expectEqual(@as(usize, 3), waves.len);
    try testing.expectEqual(@as(usize, 1), waves[0].len);
    try testing.expectEqualStrings("a", wf.steps[waves[0][0]].id);
    try testing.expectEqual(@as(usize, 2), waves[1].len); // b and c, decl order
    try testing.expectEqualStrings("b", wf.steps[waves[1][0]].id);
    try testing.expectEqualStrings("c", wf.steps[waves[1][1]].id);
    try testing.expectEqual(@as(usize, 1), waves[2].len);
    try testing.expectEqualStrings("d", wf.steps[waves[2][0]].id);
}

test "execution order honors deps and artifacts accumulate across waves" {
    const alloc = testing.allocator;
    var wf = try Workflow.parseValidated(alloc, diamondJson());
    defer wf.deinit(alloc);

    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();

    var rec = Rec{ .alloc = alloc };
    defer {
        for (rec.call_order.items) |s| alloc.free(s);
        rec.call_order.deinit(alloc);
    }

    var ex = Executor.init(alloc, &Rec.recordAndCompose);
    ex.user = &rec;

    var outcome = try ex.run(t.io(), &wf);
    defer outcome.deinit(alloc);

    try testing.expect(outcome.status == .completed);
    try testing.expect(outcome.failed_step == null);
    try testing.expect(outcome.err == null);

    // Wave-by-wave order: a first, then b/c, d last.
    try testing.expectEqual(@as(usize, 4), rec.call_order.items.len);
    try testing.expectEqualStrings("a", rec.call_order.items[0]);
    try testing.expectEqualStrings("d", rec.call_order.items[3]);

    // Artifacts accumulate: d's composer saw every earlier result (a, b, c).
    try testing.expectEqual(@as(usize, 4), outcome.artifacts.len);
    const art_d = blk: {
        for (outcome.artifacts) |a| {
            if (std.mem.eql(u8, a.id, "d")) break :blk a.result;
        }
        break :blk null;
    };
    try testing.expect(art_d != null);
    // Within-wave declaration order holds (b before c), and cross-wave
    // results are all visible. Note sequential-in-wave semantics: by the
    // time c runs, b's artifact is already accumulated, so compositions
    // nest — this is exactly what downstream prompt assembly relies on.
    try testing.expectEqualStrings("d(a(),b(a()),c(a(),b(a())))", art_d.?);
}

test "stop on first failure keeps completed artifacts and reports culprit" {
    const alloc = testing.allocator;
    var wf = try Workflow.parseValidated(alloc, diamondJson());
    defer wf.deinit(alloc);

    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();

    var rec = Rec{ .alloc = alloc, .fail_on = "b" };
    defer {
        for (rec.call_order.items) |s| alloc.free(s);
        rec.call_order.deinit(alloc);
    }

    var ex = Executor.init(alloc, &Rec.recordAndCompose);
    ex.user = &rec;

    var outcome = try ex.run(t.io(), &wf);
    defer outcome.deinit(alloc);

    try testing.expect(outcome.status == .failed);
    try testing.expectEqualStrings("b", outcome.failed_step.?);
    try testing.expectEqualStrings("StepExploded", outcome.err.?);

    // Only 'a' completed before the abort; neither c nor d ever ran.
    try testing.expectEqual(@as(usize, 1), outcome.artifacts.len);
    try testing.expectEqualStrings("a", outcome.artifacts[0].id);
    try testing.expectEqualStrings("a()", outcome.artifacts[0].result);
    try testing.expectEqual(@as(usize, 2), rec.call_order.items.len); // a, b
}

test "continue-on-failure skips dependents runs independent branches" {
    const alloc = testing.allocator;
    const json = "{\"name\":\"branchy\",\"steps\":[" ++
        "{\"id\":\"a\",\"prompt\":\"pa\"}," ++
        "{\"id\":\"boom\",\"prompt\":\"px\"}," ++
        "{\"id\":\"kid\",\"prompt\":\"pk\",\"depends_on\":[\"boom\"]}," ++
        "{\"id\":\"solo\",\"prompt\":\"ps\"}]}";
    var wf = try Workflow.parseValidated(alloc, json);
    defer wf.deinit(alloc);

    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();

    var rec = Rec{ .alloc = alloc, .fail_on = "boom" };
    defer {
        for (rec.call_order.items) |s| alloc.free(s);
        rec.call_order.deinit(alloc);
    }

    var ex = Executor.init(alloc, &Rec.recordAndCompose);
    ex.user = &rec;
    ex.stop_on_first_failure = false;

    var outcome = try ex.run(t.io(), &wf);
    defer outcome.deinit(alloc);

    try testing.expect(outcome.status == .failed);
    try testing.expectEqualStrings("boom", outcome.failed_step.?);
    // a and solo (independent) completed; kid (dependent of boom) was
    // skipped and produced nothing; boom itself added no artifact.
    try testing.expectEqual(@as(usize, 2), outcome.artifacts.len);
    var saw_kid = false;
    for (outcome.artifacts) |a| {
        if (std.mem.eql(u8, a.id, "kid")) saw_kid = true;
    }
    try testing.expect(!saw_kid);

    // Execution order: a, boom (failed but invoked), solo — kid skipped.
    try testing.expectEqual(@as(usize, 3), rec.call_order.items.len);
    try testing.expectEqualStrings("a", rec.call_order.items[0]);
    try testing.expectEqualStrings("boom", rec.call_order.items[1]);
    try testing.expectEqualStrings("solo", rec.call_order.items[2]);
}

test "executor rejects cyclic workflows defensively" {
    const alloc = testing.allocator;
    const json = "{\"name\":\"loop\",\"steps\":[" ++
        "{\"id\":\"a\",\"prompt\":\"p\",\"depends_on\":[\"b\"]}," ++
        "{\"id\":\"b\",\"prompt\":\"q\",\"depends_on\":[\"a\"]}]}";
    var wf = try Workflow.parse(alloc, json); // deliberately NOT validated
    defer wf.deinit(alloc);

    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();

    var rec = Rec{ .alloc = alloc };
    defer {
        for (rec.call_order.items) |s| alloc.free(s);
        rec.call_order.deinit(alloc);
    }

    var ex = Executor.init(alloc, &Rec.recordAndCompose);
    ex.user = &rec;
    try testing.expectError(error.CyclicDependency, ex.run(t.io(), &wf));
}

test "single step workflow completes with empty dep list everywhere" {
    const alloc = testing.allocator;
    var wf = try Workflow.parseValidated(
        alloc,
        "{\"name\":\"one\",\"steps\":[{\"id\":\"only\",\"prompt\":\"do it\",\"max_turns\":2}]}",
    );
    defer wf.deinit(alloc);

    var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer t.deinit();

    var rec = Rec{ .alloc = alloc };
    defer {
        for (rec.call_order.items) |s| alloc.free(s);
        rec.call_order.deinit(alloc);
    }

    var ex = Executor.init(alloc, &Rec.recordAndCompose);
    ex.user = &rec;

    var outcome = try ex.run(t.io(), &wf);
    defer outcome.deinit(alloc);

    try testing.expect(outcome.status == .completed);
    try testing.expectEqual(@as(usize, 1), outcome.artifacts.len);
    try testing.expectEqualStrings("only()", outcome.artifacts[0].result);
}
