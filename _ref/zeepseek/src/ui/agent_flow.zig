//! Sub-agent flow (start/poll/update) — split out of app.zig.

const std = @import("std");
const App = @import("app.zig").App;
const SubAgentRole = @import("app.zig").SubAgentRole;
const MsgStatus = @import("app.zig").MsgStatus;
const SubAgentRun = @import("app.zig").SubAgentRun;
const context_mod = @import("../dispatch/context_manager.zig");
const reasonix_mod = @import("../cache/reasonix.zig");
const loop_mod = @import("../dispatch/cache_first_loop.zig");
const sub_worker_mod = @import("../agent/sub_worker.zig");
const config_mod = @import("../utils/config.zig");
const subagent_mod = @import("../agent/subagent.zig");

const role_prompt = "You are a focused research sub-agent. Complete the assigned goal, then reply with a concise summary of what you did and found.";
/// Wall-clock ceiling for one sub-agent run. Guards against a stalled socket
/// (no read deadline) leaving the panel on a spinner forever.
const sub_agent_timeout_s: i64 = 300;

pub fn onSubAgentStart(app: *App, id: []const u8, role: SubAgentRole, goal: []const u8) void {
    app.subagents.append(app.alloc, .{
        .id = id,
        .role = role,
        .goal = goal,
        .status = .pending,
    }) catch {};
}

pub fn onSubAgentUpdate(app: *App, id: []const u8, summary: []const u8, status: MsgStatus) void {
    for (app.subagents.items) |*sa| {
        if (std.mem.eql(u8, sa.id, id)) {
            sa.status = status;
            if (summary.len > 0) {
                if (sa.summary.len > 0) app.alloc.free(sa.summary);
                sa.summary = app.alloc.dupe(u8, summary) catch "";
            }
            break;
        }
    }
}

pub fn startSubAgent(app: *App, goal: []const u8) void {
    const g = std.mem.trim(u8, goal, " ");
    if (g.len == 0) {
        app.setNotification("Usage: /subagent <goal>");
        return;
    }
    if (app.api_key.len == 0) {
        app.setNotification("Set an API key first (/apikey sk-...)");
        return;
    }
    if (app.subagent_runs.items.len >= 4) {
        app.setNotification("Too many concurrent sub-agents (max 4)");
        return;
    }
    // Reserve the slot up front so appending after spawn cannot fail: the
    // alternative error path would have to join a possibly-blocked thread on
    // the UI thread (deinit explicitly avoids joining running threads).
    app.subagent_runs.ensureUnusedCapacity(app.alloc, 1) catch {
        app.setNotification("Failed to register sub-agent (out of memory?)");
        return;
    };

    const sa_index = app.subagents.items.len;
    const id = std.fmt.allocPrint(app.alloc, "sa-{d}", .{sa_index}) catch return;
    const goal_owned = app.alloc.dupe(u8, g) catch {
        app.alloc.free(id);
        return;
    };
    // id/goal ownership moves into subagents (released by deinit)
    onSubAgentStart(app, id, .researcher, goal_owned);

    const run = std.heap.page_allocator.create(SubAgentRun) catch return;
    run.* = SubAgentRun.init(std.heap.page_allocator, sa_index);
    const ra = run.allocator();

    const api_key_owned = ra.dupe(u8, app.api_key) catch {
        run.deinit();
        std.heap.page_allocator.destroy(run);
        return;
    };
    const model_owned = ra.dupe(u8, app.model) catch {
        run.deinit();
        std.heap.page_allocator.destroy(run);
        return;
    };
    const prompt_owned = ra.dupe(u8, g) catch {
        run.deinit();
        std.heap.page_allocator.destroy(run);
        return;
    };
    const ep = app.provider_mgr.resolveEndpoint(app.provider);
    const ep_owned = ra.dupe(u8, ep) catch {
        run.deinit();
        std.heap.page_allocator.destroy(run);
        return;
    };

    const thread = std.Thread.spawn(.{}, struct {
        fn runSubAgent(api_k: []const u8, prompt: []const u8, mdl: []const u8, endpoint: []const u8, a: std.mem.Allocator, rr: *SubAgentRun) void {
            // a is the run's arena allocator — freed wholesale by deinit.
            // Use a dedicated Io so a blocked network connect cannot stall
            // the UI thread's shared std.Io (would deadlock Ctrl+C exit).
            var threaded = std.Io.Threaded.init(a, .{ .argv0 = .empty, .environ = .empty });
            const sio_own = threaded.io();
            defer threaded.deinit();
            // Record a failure reason in the panel summary before flagging the
            // run, so the ✗ in the sub-agents panel isn't a silent mystery.
            const failWith = struct {
                fn apply(target: *SubAgentRun, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
                    const note = std.fmt.allocPrint(alloc, fmt, args) catch "";
                    defer alloc.free(note);
                    target.pushSummary(note);
                    target.setFailed();
                }
            };

            // Dedicated context manager + reasonix + cache-first loop for this
            // run. The app's shared cache_loop wraps the live main-conversation
            // ctx_mgr, so reusing it here would race submit() and pollute the
            // user's context with sub-agent turns.
            var cm = context_mod.ContextManager.init(a);
            defer cm.deinit();
            var rx = reasonix_mod.Reasonix.init(a, .{});
            defer rx.deinit();
            const prefix = context_mod.ImmutablePrefix.init(a, role_prompt, "", "");
            var loop = loop_mod.CacheFirstLoop.init(a, .{
                .prefix = prefix,
                .context = &cm,
                .reasonix = &rx,
                .model = config_mod.ModelType.fromApiName(mdl),
                .io = sio_own,
                .api_key = api_k,
                .endpoint = endpoint,
            });
            defer loop.deinit();
            loop.model_name = mdl;

            var worker = sub_worker_mod.SubWorker.init(0, .explore, prompt, null, 0);
            defer worker.deinit();

            worker.start(&loop) catch |err| {
                failWith.apply(rr, a, "[failed: {s}]\n", .{@errorName(err)});
                return;
            };

            const deadline_s = subagent_mod.nowTimestamp() + sub_agent_timeout_s;
            while (true) {
                // Wall-clock guard: pollWithTimeout is only honored by
                // WorkerPool.pollAll; here we enforce the deadline directly so
                // a socket with no read deadline can't spin forever.
                if (subagent_mod.nowTimestamp() >= deadline_s) {
                    worker.abort();
                    failWith.apply(rr, a, "[failed: timed out after {d}s]\n", .{sub_agent_timeout_s});
                    return;
                }
                const res = worker.poll() catch |err| {
                    worker.abort();
                    failWith.apply(rr, a, "[failed: {s}]\n", .{@errorName(err)});
                    return;
                };
                switch (res) {
                    .chunk => rr.pushSummary(worker.current_chunk),
                    .done => break,
                    .timed_out => {
                        worker.abort();
                        failWith.apply(rr, a, "[failed: timed out]\n", .{});
                        return;
                    },
                    .poll_error => {
                        worker.abort();
                        failWith.apply(rr, a, "[failed: stream poll error]\n", .{});
                        return;
                    },
                    .pending => {},
                }
            }
            // Close the stream; the UI reads content from rr, not the worker.
            if (worker.stream) |*s| {
                s.deinit();
                worker.stream = null;
            }
            rr.setDone();
        }
    }.runSubAgent, .{ api_key_owned, prompt_owned, model_owned, ep_owned, ra, run }) catch {
        run.deinit();
        std.heap.page_allocator.destroy(run);
        app.setNotification("Failed to start sub-agent thread");
        return;
    };
    run.thread = thread;
    // Capacity was reserved before spawn, so append cannot fail here and no
    // error path needs to join a live (possibly network-blocked) thread.
    app.subagent_runs.appendAssumeCapacity(run);
    // Flip the panel entry to streaming so the spinner shows while it runs.
    if (sa_index < app.subagents.items.len) {
        app.subagents.items[sa_index].status = .streaming;
    }
    // Surface the live panel automatically — a user who just ran /subagent
    // shouldn't need to know the Ctrl+S toggle to see progress.
    app.show_subagents = true;
    app.setNotification("Sub-agent started");
}

pub fn pollSubAgents(app: *App) void {
    var i: usize = 0;
    while (i < app.subagent_runs.items.len) {
        const run = app.subagent_runs.items[i];
        if (run.isDone()) {
            run.thread.join();
            const failed = run.failed.load(.acquire);
            const summary = run.drainSummary(app.alloc);
            defer {
                if (summary) |s| app.alloc.free(s);
            }
            if (run.sa_index < app.subagents.items.len) {
                const sa = &app.subagents.items[run.sa_index];
                sa.status = if (failed) .failed else .complete;
                if (summary) |s| {
                    if (s.len > 0) {
                        if (sa.summary.len > 0) app.alloc.free(sa.summary);
                        sa.summary = app.alloc.dupe(u8, s) catch "";
                    }
                }
            }
            run.deinit();
            std.heap.page_allocator.destroy(run);
            _ = app.subagent_runs.orderedRemove(i);
        } else {
            // Live-stream newly accumulated output into the panel while the
            // run is still active, so long runs aren't a silent spinner.
            if (run.sa_index < app.subagents.items.len) {
                const len = run.summaryLen();
                if (len > run.shown_summary_len and len > app.subagents.items[run.sa_index].summary.len) {
                    const partial = run.drainSummary(app.alloc);
                    defer {
                        if (partial) |s| app.alloc.free(s);
                    }
                    if (partial) |s| {
                        if (s.len > 0) {
                            const sa = &app.subagents.items[run.sa_index];
                            if (sa.summary.len > 0) app.alloc.free(sa.summary);
                            sa.summary = app.alloc.dupe(u8, s) catch "";
                            run.shown_summary_len = len;
                        }
                    }
                }
            }
            i += 1;
        }
    }
}
