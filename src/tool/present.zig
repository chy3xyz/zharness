//! `present` — declare the final files a turn delivers to the user
//! (alignment with upstream dsh deliverables: the presentation half of a turn).
//!
//! The model calls it with a `files` array of `{path, description?}`; the
//! executor resolves relative paths against the workspace and returns a
//! human-readable manifest. main.zig records the call as a log-only
//! `deliverable/presented` observability event.

const std = @import("std");
const model = @import("../model/model.zig");
const tool_reg = @import("registry.zig");
const builtin = @import("builtin.zig");

pub const ToolCall = builtin.ToolCall;
pub const ToolResult = builtin.ToolResult;
pub const freeResult = builtin.freeResult;

pub const definition = tool_reg.ToolDefinition{
    .name = "present",
    .description = "Declare the final files this turn delivers to the user. Each entry is a workspace path plus an optional one-line description; clients render them as deliverables.",
    .category = .general,
    .parameters_json =
    \\{"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative or absolute path delivered to the user"},"description":{"type":"string","description":"One-line description of the file"}},"required":["path"]}},"note":{"type":"string","description":"Optional summary shown with the deliverables"}},"required":["files"]}
    ,
};

pub fn register(reg: *tool_reg.ToolRegistry) !void {
    try reg.register(definition);
}

const Entry = struct {
    path: []const u8,
    description: ?[]const u8,
};

/// Locate `"key":[...]` and return the array slice including brackets.
fn findArrayField(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, json, idx, needle)) |p| {
        var i = p + needle.len;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
        if (i < json.len and json[i] == '[') {
            const end = model.findMatchingBracket(json, i) orelse return null;
            return json[i..end];
        }
        idx = p + needle.len;
    }
    return null;
}

fn fail(alloc: std.mem.Allocator, msg: []const u8) !ToolResult {
    return .{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, msg) };
}

/// Execute a `present` call. `io` is unused (declaration only) but kept for
/// the shared executor signature.
pub fn execute(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    _ = io;
    const arr = findArrayField(call.arguments, "files") orelse
        return fail(alloc, "present: missing 'files' array");

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| {
            alloc.free(e.path);
            if (e.description) |d| alloc.free(d);
        }
        entries.deinit(alloc);
    }

    var i: usize = 1; // skip '['
    while (i < arr.len) {
        while (i < arr.len and (arr[i] == ' ' or arr[i] == '\t' or arr[i] == '\r' or arr[i] == '\n' or arr[i] == ',')) i += 1;
        if (i >= arr.len or arr[i] == ']') break;
        if (arr[i] != '{') break;
        const end = model.findMatchingBrace(arr, i) orelse break;
        const obj = arr[i..end];
        i = end;
        const path = try model.extractStringField(alloc, obj, "path") orelse continue;
        errdefer alloc.free(path);
        const desc = try model.extractStringField(alloc, obj, "description");
        try entries.append(alloc, .{ .path = path, .description = desc });
    }
    if (entries.items.len == 0) return fail(alloc, "present: 'files' must name at least one path");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var nbuf: [32]u8 = undefined;
    const n = std.fmt.bufPrint(&nbuf, "{d}", .{entries.items.len}) catch unreachable;
    try out.appendSlice(alloc, "Presented ");
    try out.appendSlice(alloc, n);
    try out.appendSlice(alloc, " deliverable(s):\n");
    for (entries.items) |e| {
        try out.appendSlice(alloc, "  - ");
        if (std.fs.path.isAbsolute(e.path)) {
            try out.appendSlice(alloc, e.path);
        } else {
            const abs = try std.fs.path.resolve(alloc, &.{ cwd, e.path });
            defer alloc.free(abs);
            try out.appendSlice(alloc, abs);
        }
        if (e.description) |d| {
            try out.appendSlice(alloc, " — ");
            try out.appendSlice(alloc, d);
        }
        try out.append(alloc, '\n');
    }
    return .{ .success = true, .output = try out.toOwnedSlice(alloc) };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "present parses entries and resolves relative paths" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const args = "{\"files\":[{\"path\":\"out/a.txt\",\"description\":\"first\"},{\"path\":\"/tmp/b.txt\"}]}";
    var r = try execute(alloc, io, "/tmp/ws", .{ .name = "present", .arguments = args });
    defer freeResult(alloc, &r);
    try testing.expect(r.success);
    try testing.expect(std.mem.indexOf(u8, r.output, "Presented 2 deliverable(s)") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "/tmp/ws/out/a.txt — first") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "/tmp/b.txt") != null);
}

test "present rejects an empty or missing files array" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var r = try execute(alloc, io, "/tmp", .{ .name = "present", .arguments = "{\"files\":[]}" });
    defer freeResult(alloc, &r);
    try testing.expect(!r.success);
    var r2 = try execute(alloc, io, "/tmp", .{ .name = "present", .arguments = "{}" });
    defer freeResult(alloc, &r2);
    try testing.expect(!r2.success);
}
