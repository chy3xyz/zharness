const std = @import("std");
const store_api = @import("../storage/store_api.zig");
const Keyspace = store_api.Keyspace;
const Store = @import("../storage/mmap_store.zig").MmapStore;

pub fn nowTimestamp() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return tv.sec;
}

pub const SubAgentRole = enum {
    general,
    explore,
    plan,
    review,
    implementer,
    verifier,
    custom,

    pub fn canWriteFiles(self: SubAgentRole) bool {
        return switch (self) {
            .general, .implementer => true,
            .explore, .plan, .review, .verifier => false,
            .custom => true,
        };
    }

    pub fn canUseShell(self: SubAgentRole) bool {
        return switch (self) {
            .general, .implementer => true,
            .explore => false,
            .plan => true,
            .review, .verifier => false,
            .custom => true,
        };
    }
};

pub const SubAgentState = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,
    interrupted,
    timed_out,

    pub fn jsonString(self: SubAgentState) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
            .interrupted => "interrupted",
            .timed_out => "timed_out",
        };
    }

    pub fn fromJsonString(s: []const u8) SubAgentState {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "cancelled")) return .cancelled;
        if (std.mem.eql(u8, s, "interrupted")) return .interrupted;
        if (std.mem.eql(u8, s, "timed_out")) return .timed_out;
        return .pending;
    }
};

pub const Severity = enum {
    low,
    medium,
    high,
    critical,

    pub fn jsonString(self: Severity) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
            .critical => "critical",
        };
    }

    pub fn fromJsonString(s: []const u8) Severity {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "critical")) return .critical;
        return .medium;
    }
};

pub const Change = struct {
    path: []const u8,
    description: []const u8,
    lines_added: u32,
    lines_removed: u32,

    pub fn jsonString(self: *const Change, alloc: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"description\":\"{s}\",\"lines_added\":{},\"lines_removed\":{}}}",
            .{ self.path, self.description, self.lines_added, self.lines_removed });
    }
};

pub const Evidence = struct {
    path: []const u8,
    line: u32,
    snippet: []const u8,

    pub fn jsonString(self: *const Evidence, alloc: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"line\":{},\"snippet\":\"{s}\"}}",
            .{ self.path, self.line, self.snippet });
    }
};

pub const Risk = struct {
    severity: Severity,
    description: []const u8,
};

pub const Blocker = struct {
    description: []const u8,
    dependency: []const u8,
};

pub const MergedResult = struct {
    summary: []const u8,
    changes: []Change,
    evidence: []Evidence,
    risks: []Risk,
    blockers: []Blocker,
    total_duration_ms: u64,

    pub fn jsonString(self: *const MergedResult, alloc: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        errdefer buf.deinit();
        try buf.appendSlice("{\"summary\":");
        {
            const escaped = try jsonEscape(self.summary, alloc);
            defer alloc.free(escaped);
            try buf.append('"');
            try buf.appendSlice(escaped);
            try buf.appendSlice("\",\"changes\":[");
        }
        for (self.changes, 0..) |ch, i| {
            if (i > 0) try buf.append(',');
            const cs = try ch.jsonString(alloc);
            defer alloc.free(cs);
            try buf.appendSlice(cs);
        }
        try buf.appendSlice("],\"evidence\":[");
        for (self.evidence, 0..) |ev, i| {
            if (i > 0) try buf.append(',');
            const es = try ev.jsonString(alloc);
            defer alloc.free(es);
            try buf.appendSlice(es);
        }
        try buf.appendSlice("],\"risks\":[");
        for (self.risks, 0..) |r, i| {
            if (i > 0) try buf.append(',');
            try buf.appendSlice("{\"severity\":\"");
            try buf.appendSlice(r.severity.jsonString());
            try buf.appendSlice("\",\"description\":\"");
            const ed = try jsonEscape(r.description, alloc);
            defer alloc.free(ed);
            try buf.appendSlice(ed);
            try buf.appendSlice("\"}");
        }
        try buf.appendSlice("],\"blockers\":[");
        for (self.blockers, 0..) |bl, i| {
            if (i > 0) try buf.append(',');
            try buf.appendSlice("{\"description\":\"");
            const ed = try jsonEscape(bl.description, alloc);
            defer alloc.free(ed);
            try buf.appendSlice(ed);
            try buf.appendSlice("\",\"dependency\":\"");
            const ed2 = try jsonEscape(bl.dependency, alloc);
            defer alloc.free(ed2);
            try buf.appendSlice(ed2);
            try buf.appendSlice("\"}");
        }
        try buf.appendSlice("\"],\"total_duration_ms\":");
        try buf.appendSlice(try std.fmt.allocPrint(alloc, "{}", .{self.total_duration_ms}));
        try buf.append('}');
        return try buf.toOwnedSlice();
    }

    pub fn deinit(self: *MergedResult, alloc: std.mem.Allocator) void {
        for (self.changes) |*ch| {
            alloc.free(ch.path);
            alloc.free(ch.description);
        }
        alloc.free(self.changes);
        for (self.evidence) |*ev| {
            alloc.free(ev.path);
            alloc.free(ev.snippet);
        }
        alloc.free(self.evidence);
        for (self.risks) |*r| {
            alloc.free(r.description);
        }
        alloc.free(self.risks);
        for (self.blockers) |*bl| {
            alloc.free(bl.description);
            alloc.free(bl.dependency);
        }
        alloc.free(self.blockers);
        alloc.free(self.summary);
    }
};

pub const AgentResult = struct {
    summary: []const u8,
    changes: []const []const u8,
    evidence: []const []const u8,
    risks: []const []const u8,
    blockers: []const []const u8,
};

pub const TaskState = struct {
    id: []const u8,
    role: SubAgentRole,
    prompt: []const u8,
    status: SubAgentState,
    created_at: i64,
    updated_at: i64,
    result: ?MergedResult,
    error_msg: ?[]const u8,

    pub fn jsonString(self: *const TaskState, alloc: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        errdefer buf.deinit();
        try buf.appendSlice("{\"id\":\"");
        try buf.appendSlice(self.id);
        try buf.appendSlice("\",\"role\":\"");
        try buf.appendSlice(@tagName(self.role));
        try buf.appendSlice("\",\"prompt\":");
        {
            const ep = try jsonEscape(self.prompt, alloc);
            defer alloc.free(ep);
            try buf.append('"');
            try buf.appendSlice(ep);
            try buf.append('"');
        }
        try buf.appendSlice(",\"status\":\"");
        try buf.appendSlice(self.status.jsonString());
        try buf.appendSlice("\",\"created_at\":");
        try buf.appendSlice(try std.fmt.allocPrint(alloc, "{}", .{self.created_at}));
        try buf.appendSlice(",\"updated_at\":");
        try buf.appendSlice(try std.fmt.allocPrint(alloc, "{}", .{self.updated_at}));
        if (self.result) |res| {
            try buf.appendSlice(",\"result\":");
            const rs = try res.jsonString(alloc);
            defer alloc.free(rs);
            try buf.appendSlice(rs);
        } else {
            try buf.appendSlice(",\"result\":null");
        }
        if (self.error_msg) |e| {
            try buf.appendSlice(",\"error\":");
            const ee = try jsonEscape(e, alloc);
            defer alloc.free(ee);
            try buf.append('"');
            try buf.appendSlice(ee);
            try buf.append('"');
        } else {
            try buf.appendSlice(",\"error\":null");
        }
        if (self.err_msg) |err| {
            try buf.appendSlice(",\"error\":");
            const ee = try jsonEscape(err, alloc);
            defer alloc.free(ee);
            try buf.append('"');
            try buf.appendSlice(ee);
            try buf.append('"');
        } else {
            try buf.appendSlice(",\"error\":null");
        }
        try buf.append('}');
        return try buf.toOwnedSlice();
    }
};

fn jsonEscape(s: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            else => try buf.append(c),
        }
    }
    return try buf.toOwnedSlice();
}

pub const SubAgent = struct {
    id: u32,
    task_id: []const u8,
    role: SubAgentRole,
    task: []const u8,
    state: SubAgentState = .pending,
    result: ?AgentResult = null,
    started_at: i64 = 0,
    finished_at: i64 = 0,
};

pub const Options = struct {
    max_concurrent: u32 = 10,
    timeout_ms: ?u64 = null,
    checkpoint_interval_ms: u32 = 60_000,
};

pub const SubAgentScheduler = struct {
    agents: std.ArrayList(SubAgent),
    active_count: u32 = 0,
    max_concurrent: u32,
    timeout_ms: ?u64,
    checkpoint_interval_ms: u32,
    arena: std.heap.ArenaAllocator,
    store: ?*Store = null,
    merge_allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, options: Options) SubAgentScheduler {
        return .{
            .agents = .empty,
            .max_concurrent = options.max_concurrent,
            .timeout_ms = options.timeout_ms,
            .checkpoint_interval_ms = options.checkpoint_interval_ms,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .merge_allocator = alloc,
        };
    }

    pub fn deinit(self: *SubAgentScheduler) void {
        self.agents.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn setStore(self: *SubAgentScheduler, store: *Store) void {
        self.store = store;
    }

    pub fn schedule(
        self: *SubAgentScheduler,
        task_id: []const u8,
        task: []const u8,
        role: SubAgentRole,
    ) !u32 {
        if (self.active_count >= self.max_concurrent) {
            return error.TooManyAgents;
        }

        const id = @as(u32, @intCast(self.agents.items.len));
        try self.agents.append(self.arena.allocator(), .{
            .id = id,
            .task_id = task_id,
            .role = role,
            .task = task,
        });
        self.active_count += 1;
        return id;
    }

    pub fn setRunning(self: *SubAgentScheduler, id: u32) void {
        for (self.agents.items) |*agent| {
            if (agent.id == id) {
                agent.state = .running;
                agent.started_at = nowTimestamp();
                return;
            }
        }
    }

    pub fn complete(self: *SubAgentScheduler, id: u32, result: AgentResult) void {
        for (self.agents.items) |*agent| {
            if (agent.id == id) {
                agent.state = .completed;
                agent.result = result;
                agent.finished_at = nowTimestamp();
                self.active_count -= 1;
                return;
            }
        }
    }

    pub fn fail(self: *SubAgentScheduler, id: u32, error_msg: []const u8) void {
        _ = error_msg;
        for (self.agents.items) |*agent| {
            if (agent.id == id) {
                agent.state = .failed;
                agent.finished_at = nowTimestamp();
                self.active_count -= 1;
                return;
            }
        }
    }

    pub fn abortAll(self: *SubAgentScheduler) void {
        for (self.agents.items) |*agent| {
            if (agent.state == .running) {
                agent.state = .cancelled;
                agent.finished_at = nowTimestamp();
                self.active_count -= 1;
            }
        }
    }

    pub fn list(self: *const SubAgentScheduler) []const SubAgent {
        return self.agents.items;
    }

    pub fn getCompleted(self: *const SubAgentScheduler) []const SubAgent {
        var result: std.ArrayList(SubAgent) = .{ .items = &.{}, .capacity = 0 };
        for (self.agents.items) |agent| {
            if (agent.state == .completed or agent.state == .failed or agent.state == .timed_out) {
                result.append(self.merge_allocator, agent) catch {};
            }
        }
        return result.toOwnedSlice(self.merge_allocator) catch &.{};
    }

    pub fn mergeResults(self: *SubAgentScheduler) !MergedResult {
        const completed = self.getCompleted();
        defer self.merge_allocator.free(completed);

        var all_changes: std.ArrayList(Change) = .{ .items = &.{}, .capacity = 0 };
        var all_evidence: std.ArrayList(Evidence) = .{ .items = &.{}, .capacity = 0 };
        var all_risks: std.ArrayList(Risk) = .{ .items = &.{}, .capacity = 0 };
        var all_blockers: std.ArrayList(Blocker) = .{ .items = &.{}, .capacity = 0 };
        var summary_parts: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
        defer all_changes.deinit(self.merge_allocator);
        defer all_evidence.deinit(self.merge_allocator);
        defer all_risks.deinit(self.merge_allocator);
        defer all_blockers.deinit(self.merge_allocator);
        defer summary_parts.deinit(self.merge_allocator);
        var total_duration: u64 = 0;

        for (completed) |agent| {
            total_duration += if (agent.finished_at > agent.started_at)
                @as(u64, @intCast(agent.finished_at - agent.started_at)) * 1000
            else
                0;

            if (agent.result) |res| {
                if (res.summary.len > 0) {
                    summary_parts.append(self.merge_allocator, res.summary) catch {};
                }
                for (res.changes) |ch| {
                    all_changes.append(self.merge_allocator, .{
                        .path = self.merge_allocator.dupe(u8, ch) catch ch,
                        .description = self.merge_allocator.dupe(u8, "") catch "",
                        .lines_added = 0,
                        .lines_removed = 0,
                    }) catch {};
                }
                for (res.evidence) |ev| {
                    if (ev.len > 0) {
                        const ev_parsed = parseEvidenceSnippet(ev, self.merge_allocator);
                        all_evidence.append(self.merge_allocator, ev_parsed) catch {};
                    }
                }
                for (res.risks) |r| {
                    const sev = inferSeverity(r, self.merge_allocator);
                    all_risks.append(self.merge_allocator, .{ .severity = sev, .description = self.merge_allocator.dupe(u8, r) catch r }) catch {};
                }
                for (res.blockers) |bl| {
                    const parsed = parseBlocker(bl, self.merge_allocator);
                    all_blockers.append(self.merge_allocator, parsed) catch {};
                }
            }
        }

        const merged_changes = deduplicateChanges(all_changes.items, self.merge_allocator);
        const merged_evidence = deduplicateEvidence(all_evidence.items, self.merge_allocator);
        const merged_risks = deduplicateRisks(all_risks.items, self.merge_allocator);
        const merged_blockers = deduplicateBlockers(all_blockers.items, self.merge_allocator);

        const summary = if (summary_parts.items.len > 0)
            try synthesizeSummary(summary_parts.items, self.merge_allocator)
        else
            try self.merge_allocator.dupe(u8, "No results from subagents.");

        return MergedResult{
            .summary = summary,
            .changes = merged_changes,
            .evidence = merged_evidence,
            .risks = merged_risks,
            .blockers = merged_blockers,
            .total_duration_ms = total_duration,
        };
    }

    pub fn saveTask(self: *SubAgentScheduler, task: *const TaskState) !void {
        const store = self.store orelse return;
        var key_buf: [256]u8 = undefined;
        const key = store_api.makeKeyBounded(.agent, &.{task.id}, &key_buf);
        const json = try task.jsonString(self.merge_allocator);
        defer self.merge_allocator.free(json);
        try store.put(key, json);
    }

    pub fn loadTasks(self: *SubAgentScheduler) ![]TaskState {
        const store = self.store orelse return &.{};
        const prefix = "a:";
        var results: std.ArrayList(TaskState) = .{};
        var keys: std.ArrayList([]const u8) = .{};
        defer {
            for (keys.items) |k| self.merge_allocator.free(k);
            keys.deinit(self.merge_allocator);
        }
        store.listBounded(prefix, &keys);
        for (keys.items) |key| {
            if (store.get(key)) |val| {
                const task = try parseTaskState(val, self.merge_allocator);
                results.append(self.merge_allocator, task) catch {};
            }
        }
        return try results.toOwnedSlice(self.merge_allocator);
    }

    pub fn loadPendingTasks(self: *SubAgentScheduler) ![]TaskState {
        const all = try self.loadTasks();
        var pending: std.ArrayList(TaskState) = .{};
        for (all) |task| {
            if (task.status == .pending or task.status == .running or task.status == .interrupted) {
                pending.append(self.merge_allocator, task) catch {};
            }
        }
        return try pending.toOwnedSlice(self.merge_allocator);
    }

    pub fn createCheckpoint(self: *SubAgentScheduler, task_id: []const u8) !void {
        const store = self.store orelse return;
        var key_buf: [256]u8 = undefined;
        const key = store_api.makeKeyBounded(.checkpoint, &.{task_id}, &key_buf);

        var checkpoint: std.ArrayList(u8) = .{};

        for (self.agents.items) |agent| {
            if (std.mem.eql(u8, agent.task_id, task_id)) {
                const header = try std.fmt.allocPrint(self.merge_allocator,
                    "{{\"id\":{},\"state\":\"{s}\",\"task\":\"{s}\",\"result_summary\":\"",
                    .{ agent.id, @tagName(agent.state), agent.task });
                try checkpoint.appendSlice(self.merge_allocator, header);
                self.merge_allocator.free(header);
                if (agent.result) |res| {
                    const esc = try jsonEscape(res.summary, self.merge_allocator);
                    defer self.merge_allocator.free(esc);
                    try checkpoint.appendSlice(self.merge_allocator, esc);
                }
                try checkpoint.appendSlice(self.merge_allocator, "\"}");
                break;
            }
        }

        const data = try checkpoint.toOwnedSlice(self.merge_allocator);
        try store.put(key, data);
        self.merge_allocator.free(data);
    }

    pub fn restoreFromCheckpoint(self: *SubAgentScheduler, task_id: []const u8) !void {
        const store = self.store orelse return;
        var key_buf: [256]u8 = undefined;
        const key = store_api.makeKeyBounded(.checkpoint, &.{task_id}, &key_buf);
        if (store.get(key)) |val| {
            _ = val;
        }
    }
};

fn parseEvidenceSnippet(snippet: []const u8, alloc: std.mem.Allocator) Evidence {
    var path: []const u8 = "";
    var line: u32 = 0;
    var rest = snippet;

    if (std.mem.indexOfScalar(u8, snippet, ':')) |colon| {
        path = snippet[0..colon];
        rest = snippet[colon + 1..];
        line = std.fmt.parseInt(u32, rest, 10) catch 0;
        if (std.mem.indexOf(u8, rest, ":") != null) {
            if (std.mem.indexOfScalar(u8, rest, ':')) |c| {
                rest = rest[c + 1..];
            }
        }
    }

    return Evidence{
        .path = alloc.dupe(u8, path) catch path,
        .line = line,
        .snippet = alloc.dupe(u8, rest) catch rest,
    };
}

fn parseBlocker(bl: []const u8, alloc: std.mem.Allocator) Blocker {
    if (std.mem.indexOf(u8, bl, " -> ")) |arrow| {
        return .{
            .description = alloc.dupe(u8, bl[0..arrow]) catch bl,
            .dependency = alloc.dupe(u8, bl[arrow + 4..]) catch "",
        };
    }
    return .{ .description = alloc.dupe(u8, bl) catch bl, .dependency = "" };
}

fn inferSeverity(risk: []const u8, alloc: std.mem.Allocator) Severity {
    const lower = alloc.dupe(u8, risk) catch risk;
    defer if (lower.ptr != risk.ptr) alloc.free(lower);
    if (std.mem.indexOf(u8, lower, "critical") != null) return .critical;
    if (std.mem.indexOf(u8, lower, "high") != null) return .high;
    if (std.mem.indexOf(u8, lower, "medium") != null) return .medium;
    return .low;
}

fn deduplicateChanges(changes: []const Change, alloc: std.mem.Allocator) []Change {
    var result: std.ArrayList(Change) = .empty;
    defer result.deinit(alloc);
    for (changes) |ch| {
        var dup = false;
        for (result.items) |existing| {
            if (std.mem.eql(u8, existing.path, ch.path)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            alloc.free(ch.path);
            alloc.free(ch.description);
        } else {
            result.append(alloc, ch) catch {
                alloc.free(ch.path);
                alloc.free(ch.description);
            };
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn deduplicateEvidence(evidence: []const Evidence, alloc: std.mem.Allocator) []Evidence {
    var result: std.ArrayList(Evidence) = .empty;
    defer result.deinit(alloc);
    for (evidence) |ev| {
        var dup = false;
        for (result.items) |existing| {
            if (existing.line == ev.line and std.mem.eql(u8, existing.path, ev.path)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            alloc.free(ev.path);
            alloc.free(ev.snippet);
        } else {
            result.append(alloc, ev) catch {
                alloc.free(ev.path);
                alloc.free(ev.snippet);
            };
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn deduplicateRisks(risks: []const Risk, alloc: std.mem.Allocator) []Risk {
    var result: std.ArrayList(Risk) = .empty;
    defer result.deinit(alloc);
    for (risks) |r| {
        var dup = false;
        for (result.items) |existing| {
            if (std.mem.eql(u8, existing.description, r.description)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            alloc.free(r.description);
        } else {
            result.append(alloc, r) catch alloc.free(r.description);
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn deduplicateBlockers(blockers: []const Blocker, alloc: std.mem.Allocator) []Blocker {
    var result: std.ArrayList(Blocker) = .empty;
    defer result.deinit(alloc);
    for (blockers) |bl| {
        var dup = false;
        for (result.items) |existing| {
            if (std.mem.eql(u8, existing.dependency, bl.dependency)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            alloc.free(bl.description);
            alloc.free(bl.dependency);
        } else {
            result.append(alloc, bl) catch {
                alloc.free(bl.description);
                alloc.free(bl.dependency);
            };
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn synthesizeSummary(parts: [][]const u8, alloc: std.mem.Allocator) ![]const u8 {
    if (parts.len == 0) return alloc.dupe(u8, "");
    if (parts.len == 1) return alloc.dupe(u8, parts[0]);

    var combined: std.ArrayList(u8) = .empty;
    for (parts, 0..) |part, i| {
        if (i > 0) {
            if (i == parts.len - 1) {
                try combined.appendSlice(alloc, " Also, ");
            } else {
                try combined.appendSlice(alloc, " ");
            }
        }
        try combined.appendSlice(alloc, part);
    }
    return try combined.toOwnedSlice(alloc);
}

fn parseTaskState(json: []const u8, alloc: std.mem.Allocator) !TaskState {
    var id: []const u8 = "";
    var role: SubAgentRole = .general;
    var prompt: []const u8 = "";
    var status: SubAgentState = .pending;
    var created_at: i64 = 0;
    var updated_at: i64 = 0;
    const result: ?MergedResult = null;
    var err_msg: ?[]const u8 = null;

    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        if (json[i] != '"') continue;
        if (i + 4 > json.len) break;
        const field = json[i + 1..i + 4];
        if (std.mem.eql(u8, field, "id\":")) {
            i += 5;
            if (json[i - 1] == ':') {
                const extracted = extractJsonString(json, &i, alloc);
                if (extracted.len > 0) id = extracted;
            }
        } else if (std.mem.eql(u8, field, "rol")) {
            i += 6;
            if (json[i - 2] == ':') {
                const rname = extractJsonString(json, &i, alloc);
                if (std.mem.eql(u8, rname, "general")) {
                    role = .general;
                } else if (std.mem.eql(u8, rname, "explore")) {
                    role = .explore;
                } else if (std.mem.eql(u8, rname, "plan")) {
                    role = .plan;
                } else if (std.mem.eql(u8, rname, "review")) {
                    role = .review;
                } else if (std.mem.eql(u8, rname, "implementer")) {
                    role = .implementer;
                } else if (std.mem.eql(u8, rname, "verifier")) {
                    role = .verifier;
                } else {
                    role = .custom;
                }
            }
        } else if (std.mem.eql(u8, field, "sta")) {
            i += 8;
            if (json[i - 4] == ':') {
                const sname = extractJsonString(json, &i, alloc);
                status = SubAgentState.fromJsonString(sname);
            }
        } else if (std.mem.eql(u8, field, "pro")) {
            i += 7;
            if (json[i - 3] == ':') {
                prompt = extractJsonString(json, &i, alloc);
            }
        } else if (std.mem.eql(u8, field, "err")) {
            i += 7;
            if (json[i - 3] == ':') {
                err_msg = extractJsonString(json, &i, alloc);
            }
        } else if (std.mem.eql(u8, field, "cre")) {
            i += 7;
            while (i < json.len and json[i] == ' ') : (i += 1) {}
            created_at = parseJsonInt(json, &i);
        } else if (std.mem.eql(u8, field, "upd")) {
            i += 7;
            while (i < json.len and json[i] == ' ') : (i += 1) {}
            updated_at = parseJsonInt(json, &i);
        }
    }
    return TaskState{
        .id = id,
        .role = role,
        .prompt = prompt,
        .status = status,
        .created_at = created_at,
        .updated_at = updated_at,
        .result = result,
        .error_msg = err_msg,
    };
}

fn parseJsonInt(json: []const u8, pos: *usize) i64 {
    var value: i64 = 0;
    var negative = false;
    if (pos.* < json.len and json[pos.*] == '-') {
        negative = true;
        pos.* += 1;
    }
    while (pos.* < json.len) : (pos.* += 1) {
        const c = json[pos.*];
        if (c >= '0' and c <= '9') {
            value = value * 10 + @as(i64, c - '0');
        } else {
            break;
        }
    }
    return if (negative) -value else value;
}

fn extractJsonString(json: []const u8, pos: *usize, alloc: std.mem.Allocator) []const u8 {
    if (pos.* >= json.len or json[pos.*] != '"') return "";
    pos.* += 1;
    const start = pos.*;
    while (pos.* < json.len) : (pos.* += 1) {
        if (json[pos.*] == '"' and (pos.* == start or json[pos.* - 1] != '\\')) {
            const result = json[start..pos.*];
            pos.* += 1;
            return alloc.dupe(u8, result) catch result;
        }
    }
    return "";
}

pub fn getRoleSystemPrompt(role: SubAgentRole) []const u8 {
    return switch (role) {
        .general => "You are a general-purpose coding assistant. You can read and write files, run shell commands, and use git. Be thorough and precise. Think step by step before acting. Always prefer safe, minimal changes.",
        .explore => "You are a read-only code exploration agent. Your job is to map and understand code without modifying it. Read files, follow imports, trace call graphs, and summarize structure. Do NOT write files, run commands, or make changes. Focus on identifying relevant code paths, dependencies, and architecture.",
        .plan => "You are a strategic planning agent. Analyze requirements and produce a structured plan. Break down tasks into subtasks, identify dependencies, estimate complexity, and prioritize. Output a clear sequence of steps with rationale. You may use shell for lightweight exploration but prefer analysis over implementation.",
        .review => "You are a code review agent. Read code carefully and grade it. Assess correctness, security, performance, maintainability, and style. Provide severity scores (low/medium/high/critical) for each finding. Be constructive and specific. Reference exact lines with path:line format.",
        .implementer => "You are a focused implementation agent. Your job is to land specific, targeted changes described in the task. Read existing code first, make minimal necessary changes, test locally, and ensure the change is correct. Prefer conservative, reversible changes. Report exactly what changed with line counts.",
        .verifier => "You are a verification and testing agent. Your job is to validate changes by running tests, linters, type checkers, and manual checks. Report pass/fail for each verification step. Identify regressions or breaking changes. Do NOT modify code unless explicitly asked.",
        .custom => "You are a coding agent. Execute the assigned task using your available tools. Follow the output contract format strictly. Be precise and concise.",
    };
}

pub fn getRoleOutputContract(role: SubAgentRole) []const u8 {
    return switch (role) {
        .general => "Output your response using this exact contract:\n\nSUMMARY: One paragraph synthesizing what was accomplished.\n\nCHANGES: List each file modified. Format: - path/to/file: description\n\nEVIDENCE: List specific path:line citations that support your findings. Format: - path/file.zig:42: relevant snippet\n\nRISKS: Potential issues or concerns. Format: - severity: description\n\nBLOCKERS: External dependencies or blockers. Format: - description -> dependency",
        .explore => "Output your response using this exact contract:\n\nSUMMARY: One paragraph describing the codebase structure and relevant areas.\n\nCHANGES: List files examined (read-only). Format: - path/to/file: what was learned\n\nEVIDENCE: Key path:line citations. Format: - path/file.zig:42: key finding\n\nRISKS: Potential architectural concerns or technical debt found.\n\nBLOCKERS: Dependencies or unknowns that prevent full understanding.",
        .plan => "Output your response using this exact contract:\n\nSUMMARY: One paragraph outlining the proposed plan and approach.\n\nCHANGES: List of subtasks with priority. Format: - [P1] task description\n\nEVIDENCE: Reference paths that informed the plan. Format: - path/file.zig:42: rationale\n\nRISKS: Risks in the proposed approach.\n\nBLOCKERS: Dependencies that must be resolved first.",
        .review => "Output your response using this exact contract:\n\nSUMMARY: One paragraph overall assessment.\n\nCHANGES: Findings by file. Format: - path/to/file: [CRITICAL/HIGH/MEDIUM/LOW] issue description\n\nEVIDENCE: Exact citations. Format: - path/file.zig:42: code snippet showing the issue\n\nRISKS: Severity-coded issues. Format: - critical: security vulnerability in auth flow\n\nBLOCKERS: Blocking issues that must be resolved before merge.",
        .implementer => "Output your response using this exact contract:\n\nSUMMARY: One paragraph describing what was implemented.\n\nCHANGES: Files modified with diff stats. Format: - path/to/file: +N -N lines changed\n\nEVIDENCE: path:line of key implementation decisions.\n\nRISKS: Potential issues introduced.\n\nBLOCKERS: Remaining work or external dependencies.",
        .verifier => "Output your response using this exact contract:\n\nSUMMARY: One paragraph overall test/verification results.\n\nCHANGES: Verification steps and results. Format: - test/lint/typecheck: PASS/FAIL\n\nEVIDENCE: Output snippets showing test results.\n\nRISKS: Regressions or failures found.\n\nBLOCKERS: Tests that block progress.",
        .custom => "Output your response using this exact contract:\n\nSUMMARY: One paragraph.\n\nCHANGES: Files.\n\nEVIDENCE: Citations.\n\nRISKS: Issues.\n\nBLOCKERS: Dependencies.",
    };
}

test "subagent scheduler" {
    const alloc = std.testing.allocator;
    var scheduler = SubAgentScheduler.init(alloc, .{});
    defer scheduler.deinit();

    const id = try scheduler.schedule("task-1", "test task", .general);
    try std.testing.expectEqual(@as(u32, 0), id);

    scheduler.setRunning(id);
    try std.testing.expectEqual(SubAgentState.running, scheduler.agents.items[0].state);

    scheduler.complete(id, .{
        .summary = "Done",
        .changes = &.{},
        .evidence = &.{},
        .risks = &.{},
        .blockers = &.{},
    });
    try std.testing.expectEqual(SubAgentState.completed, scheduler.agents.items[0].state);
    try std.testing.expectEqual(@as(u32, 0), scheduler.active_count);
}

test "subagent role permissions" {
    try std.testing.expectEqual(true, SubAgentRole.general.canWriteFiles());
    try std.testing.expectEqual(false, SubAgentRole.explore.canWriteFiles());
    try std.testing.expectEqual(true, SubAgentRole.general.canUseShell());
    try std.testing.expectEqual(false, SubAgentRole.explore.canUseShell());
}

test "severity parsing" {
    try std.testing.expectEqual(@as(u3, @intFromEnum(Severity.critical)), @as(u3, @intFromEnum(Severity.fromJsonString("critical"))));
    try std.testing.expectEqual(Severity.low, Severity.fromJsonString("low"));
    try std.testing.expectEqual(Severity.high, Severity.fromJsonString("high"));
}

test "subagent state parsing" {
    try std.testing.expectEqual(SubAgentState.timed_out, SubAgentState.fromJsonString("timed_out"));
    try std.testing.expectEqual(SubAgentState.interrupted, SubAgentState.fromJsonString("interrupted"));
    try std.testing.expectEqual(SubAgentState.pending, SubAgentState.fromJsonString("pending"));
}

test "role system prompts non-empty" {
    inline for (std.enums.values(SubAgentRole)) |role| {
        try std.testing.expect(getRoleSystemPrompt(role).len > 0);
        try std.testing.expect(getRoleOutputContract(role).len > 0);
    }
}

test "merge results aggregates correctly" {
    const alloc = std.testing.allocator;
    var scheduler = SubAgentScheduler.init(alloc, .{});
    defer scheduler.deinit();

    _ = try scheduler.schedule("t1", "task1", .explore);
    _ = try scheduler.schedule("t2", "task2", .review);

    scheduler.complete(0, .{
        .summary = "Explored the codebase",
        .changes = &.{"src/main.zig"},
        .evidence = &.{"src/main.zig:10:function definition"},
        .risks = &.{"high: no error handling in main"},
        .blockers = &.{"needs auth module -> auth.zig"},
    });
    scheduler.complete(1, .{
        .summary = "Reviewed code",
        .changes = &.{"src/main.zig", "src/utils.zig"},
        .evidence = &.{"src/utils.zig:5:helper function"},
        .risks = &.{"medium: style inconsistency"},
        .blockers = &.{"needs auth module -> auth.zig"},
    });

    var merged = try scheduler.mergeResults();
    defer merged.deinit(alloc);

    try std.testing.expect(merged.summary.len > 0);
    try std.testing.expect(merged.changes.len > 0);
    try std.testing.expect(merged.evidence.len > 0);
    try std.testing.expect(merged.risks.len > 0);
    try std.testing.expect(merged.blockers.len > 0);
}
