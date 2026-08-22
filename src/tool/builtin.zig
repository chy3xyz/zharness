//! Builtin tool executors (dev.md §X–XI). Adapted from the proven zeepseek
//! file/shell/git implementations, kept dependency-free on cwd + libc popen.

const std = @import("std");
const c = std.c;
const clib = @import("../clib.zig");

pub const ToolCall = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    err_msg: ?[]const u8 = null,

    pub fn format(self: *const ToolResult, alloc: std.mem.Allocator) []const u8 {
        if (self.success) return alloc.dupe(u8, self.output) catch self.output;
        const msg = self.err_msg orelse "error";
        return std.fmt.allocPrint(alloc, "[error] {s}", .{msg}) catch self.output;
    }
};

const MaxOutputBytes: usize = 256 * 1024;

/// Resolve path against cwd, allowing ~/ expansion. Normalizes traversal so
/// sandbox prefix checks cannot be bypassed.
fn resolvePath(alloc: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = std.c.getenv("HOME") orelse return alloc.dupe(u8, path);
        const home_slice = std.mem.sliceTo(home, 0);
        return std.fs.path.resolve(alloc, &.{ home_slice, path[2..] });
    }
    return std.fs.path.resolve(alloc, &.{ cwd, path });
}

fn isInsideWorkspace(resolved: []const u8, cwd: []const u8) bool {
    if (std.mem.eql(u8, resolved, cwd)) return true;
    if (resolved.len > cwd.len and std.mem.startsWith(u8, resolved, cwd) and resolved[cwd.len] == '/') return true;
    return false;
}

/// Decode the simple JSON string escapes (\", \\, \n, \t, \r) found inside
/// `raw` (a slice without surrounding quotes) into a freshly allocated slice.
fn unescapeJson(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, raw.len);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                'n' => try out.append(alloc, '\n'),
                't' => try out.append(alloc, '\t'),
                'r' => try out.append(alloc, '\r'),
                else => try out.append(alloc, raw[i]),
            }
        } else {
            try out.append(alloc, raw[i]);
        }
    }
    return try out.toOwnedSlice(alloc);
}

/// Parse a flat JSON object of string/number/boolean values into a map.
fn parseArgs(alloc: std.mem.Allocator, json_args: []const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(alloc);
    errdefer {
        var it = map.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        map.deinit();
    }
    var i: usize = 0;
    while (i < json_args.len) : (i += 1) {
        if (json_args[i] != '"') continue;
        i += 1;
        const key_start = i;
        while (i < json_args.len and json_args[i] != '"') : (i += 1) {
            if (json_args[i] == '\\' and i + 1 < json_args.len) i += 1;
        }
        if (i >= json_args.len) break;
        const key = json_args[key_start..i];
        const key_un = try unescapeJson(alloc, key);
        errdefer alloc.free(key_un);
        i += 1;
        while (i < json_args.len and json_args[i] != ':') : (i += 1) {}
        if (i >= json_args.len) break;
        i += 1;
        while (i < json_args.len and (json_args[i] == ' ' or json_args[i] == '\t')) : (i += 1) {}
        if (i >= json_args.len) break;
        var value: []const u8 = "";
        if (json_args[i] == '"') {
            i += 1;
            const v_start = i;
            while (i < json_args.len and json_args[i] != '"') : (i += 1) {
                if (json_args[i] == '\\' and i + 1 < json_args.len) i += 1;
            }
            value = try unescapeJson(alloc, json_args[v_start..i]);
            if (i < json_args.len) i += 1;
        } else if (json_args[i] == 't' or json_args[i] == 'f') {
            const b_start = i;
            while (i < json_args.len and std.ascii.isAlphabetic(json_args[i])) : (i += 1) {}
            value = try alloc.dupe(u8, json_args[b_start..i]);
        } else if (json_args[i] == '-' or std.ascii.isDigit(json_args[i])) {
            const n_start = i;
            while (i < json_args.len and (std.ascii.isDigit(json_args[i]) or json_args[i] == '.' or json_args[i] == '-')) : (i += 1) {}
            value = try alloc.dupe(u8, json_args[n_start..i]);
        }
        try map.put(key_un, value);
    }
    return map;
}

fn freeArgs(alloc: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        alloc.free(e.key_ptr.*);
        alloc.free(e.value_ptr.*);
    }
    map.deinit();
}

/// Dispatch a tool call to the correct executor. `alloc` must outlive the
/// returned `ToolResult.output`/`err_msg` (caller frees via freeResult).
pub fn execute(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    if (std.mem.eql(u8, call.name, "file_read")) return fileRead(alloc, io, cwd, call);
    if (std.mem.eql(u8, call.name, "file_write")) return fileWrite(alloc, io, cwd, call);
    if (std.mem.eql(u8, call.name, "file_edit")) return fileEdit(alloc, io, cwd, call);
    if (std.mem.eql(u8, call.name, "glob")) return glob(alloc, cwd, call);
    if (std.mem.eql(u8, call.name, "grep")) return grepTool(alloc, io, cwd, call);
    if (std.mem.eql(u8, call.name, "shell")) return shell(alloc, cwd, call);
    if (std.mem.eql(u8, call.name, "git_status")) return gitRun(alloc, cwd, &.{ "status", "--porcelain" });
    if (std.mem.eql(u8, call.name, "git_diff")) return gitDiff(alloc, cwd, call);
    if (std.mem.eql(u8, call.name, "git_log")) return gitLog(alloc, cwd, call);
    if (std.mem.eql(u8, call.name, "git_commit")) return gitCommit(alloc, cwd, call);
    return ToolResult{ .success = false, .output = "", .err_msg = "unknown tool" };
}

/// Free a result produced by `execute` (the slices are allocated with `alloc`).
pub fn freeResult(alloc: std.mem.Allocator, res: *const ToolResult) void {
    alloc.free(res.output);
    if (res.err_msg) |m| alloc.free(m);
}

fn fileRead(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &map);
    const path = map.get("path") orelse return ToolResult{ .success = false, .output = "", .err_msg = "missing path" };
    const resolved = try resolvePath(alloc, cwd, path);
    defer alloc.free(resolved);
    if (!isInsideWorkspace(resolved, cwd)) {
        return ToolResult{ .success = false, .output = "", .err_msg = "path is outside the workspace" };
    }
    const content = readFileC(alloc, io, resolved) catch |e| {
        return ToolResult{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, @errorName(e)) };
    };
    return ToolResult{ .success = true, .output = content };
}

/// Read an entire file via `std.Io.Dir` (Zig 0.17's file API; `std.fs.cwd`
/// was relocated here). Caller owns the returned slice (allocated with
/// `alloc`). `path` may be absolute — on POSIX `openFile` resolves an
/// absolute `sub_path` against the process cwd regardless.
fn readFileC(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .unlimited);
}

fn fileWrite(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &map);
    const path = map.get("path") orelse return ToolResult{ .success = false, .output = "", .err_msg = "missing path" };
    const content = map.get("content") orelse return ToolResult{ .success = false, .output = "", .err_msg = "missing content" };
    const resolved = try resolvePath(alloc, cwd, path);
    defer alloc.free(resolved);
    if (!isInsideWorkspace(resolved, cwd)) {
        return ToolResult{ .success = false, .output = "", .err_msg = "path is outside the workspace" };
    }
    if (std.fs.path.dirname(resolved)) |dir| {
        ensureDir(alloc, dir);
    }
    writeFileC(alloc, io, resolved, content) catch |e| {
        return ToolResult{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, @errorName(e)) };
    };
    const msg = try std.fmt.allocPrint(alloc, "wrote {} bytes to {s}", .{ content.len, resolved });
    return ToolResult{ .success = true, .output = msg };
}

/// Create parent directories one segment at a time (libc mkdir, EEXIST
/// tolerated). Allocator is only used for the sentinel copy.
fn ensureDir(alloc: std.mem.Allocator, dir: []const u8) void {
    var buf: [4096:0]u8 = undefined;
    if (dir.len >= buf.len) return;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            @memcpy(buf[0..i], dir[0..i]);
            buf[i] = 0;
            _ = c.mkdir(&buf, 0o755);
        }
    }
    _ = alloc;
}

/// Write `content` to `path` via `std.Io.Dir` (Zig 0.17's file API;
/// `std.fs.cwd` was relocated here).
fn writeFileC(alloc: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !void {
    _ = alloc;
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = content });
}

fn fileEdit(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &map);
    const path = map.get("path") orelse return ToolResult{ .success = false, .output = "", .err_msg = "missing path" };
    const old_s = map.get("old_string") orelse return ToolResult{ .success = false, .output = "", .err_msg = "missing old_string" };
    const new_s = map.get("new_string") orelse return ToolResult{ .success = false, .output = "", .err_msg = "missing new_string" };
    const resolved = try resolvePath(alloc, cwd, path);
    defer alloc.free(resolved);
    if (!isInsideWorkspace(resolved, cwd)) {
        return ToolResult{ .success = false, .output = "", .err_msg = "path is outside the workspace" };
    }
    const original = readFileC(alloc, io, resolved) catch |e| {
        return ToolResult{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, @errorName(e)) };
    };
    defer alloc.free(original);
    const count = std.mem.count(u8, original, old_s);
    if (count == 0) {
        return ToolResult{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, "old_string not found") };
    }
    if (count > 1) {
        return ToolResult{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, "old_string is not unique (found multiple matches)") };
    }
    const idx = std.mem.indexOf(u8, original, old_s).?;
    const updated = try alloc.alloc(u8, original.len - old_s.len + new_s.len);
    @memcpy(updated[0..idx], original[0..idx]);
    @memcpy(updated[idx .. idx + new_s.len], new_s);
    @memcpy(updated[idx + new_s.len ..], original[idx + old_s.len ..]);
    defer alloc.free(updated);
    writeFileC(alloc, io, resolved, updated) catch |e| {
        return ToolResult{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, @errorName(e)) };
    };
    const msg = try std.fmt.allocPrint(alloc, "edited {s} ({} -> {} bytes)", .{ resolved, original.len, updated.len });
    return ToolResult{ .success = true, .output = msg };
}

fn glob(alloc: std.mem.Allocator, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &map);
    const pattern = map.get("pattern") orelse return ToolResult{ .success = false, .output = "", .err_msg = "missing pattern" };
    const base = if (map.get("path")) |p| p else cwd;
    const resolved_base = try resolvePath(alloc, cwd, base);
    defer alloc.free(resolved_base);

    // Enumerate files via `find` (libc popen), then filter in Zig using the
    // existing matchGlob so the glob semantics stay inside this module.
    const find = try runArgv(alloc, resolved_base, &.{ "find", ".", "-type", "f" });
    defer freeResult(alloc, &find);
    if (!find.success) {
        return ToolResult{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, "find failed") };
    }

    var out = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer out.deinit(alloc);
    var line_iter = std.mem.splitScalar(u8, find.output, '\n');
    while (line_iter.next()) |rel| {
        if (rel.len == 0) continue;
        const abs = std.fs.path.join(alloc, &.{ resolved_base, rel }) catch continue;
        if (matchGlob(abs, pattern)) {
            try out.appendSlice(alloc, abs);
            try out.append(alloc, '\n');
        }
        alloc.free(abs);
    }
    return ToolResult{ .success = true, .output = try out.toOwnedSlice(alloc) };
}

fn matchGlob(path: []const u8, pattern: []const u8) bool {
    // Iterative matcher supporting '*' (no slash), '**' (any chars incl.
    // slashes), and '?' (single char). Uses a small backtracking stack to
    // avoid deep recursion / stack overflow on long paths.
    var si: usize = 0;
    var pi: usize = 0;
    var star_s: usize = 0;
    var star_p: usize = 0;
    var has_star = false;

    while (si < path.len) {
        if (pi < pattern.len and (pattern[pi] == path[si] or pattern[pi] == '?')) {
            si += 1;
            pi += 1;
            continue;
        }
        // double star: consume pattern up to and including the next literal
        if (pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*') {
            // advance past "**" and an optional following '/'
            pi += 2;
            if (pi < pattern.len and pattern[pi] == '/') pi += 1;
            star_s = si;
            star_p = pi;
            has_star = true;
            continue;
        }
        if (pi < pattern.len and pattern[pi] == '*') {
            star_s = si;
            star_p = pi;
            has_star = true;
            pi += 1;
            continue;
        }
        if (has_star) {
            // single '*' cannot cross '/'; only try restarting the match
            // within the same path segment.
            const seg_end = blk: {
                var k = star_s;
                while (k < path.len and path[k] != '/') k += 1;
                break :blk k;
            };
            if (si <= seg_end) {
                // try matching the remainder of the pattern one char further
                // along in the path segment.
                star_s += 1;
                si = star_s;
                pi = star_p + 1;
                continue;
            }
            // double-star fallback: try matching from the next '/' boundary
            const next_slash = blk2: {
                var k = si + 1;
                while (k < path.len and path[k] != '/') k += 1;
                break :blk2 k;
            };
            if (next_slash < path.len) {
                star_s = next_slash + 1;
                si = star_s;
                pi = star_p;
                continue;
            }
            return false;
        }
        return false;
    }
    // consume trailing '*' in the pattern
    while (pi < pattern.len and pattern[pi] == '*') {
        if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
            pi += 2;
        } else {
            pi += 1;
        }
    }
    return pi == pattern.len;
}

fn grepTool(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &map);
    const pattern = map.get("pattern") orelse return ToolResult{ .success = false, .output = "", .err_msg = "missing pattern" };
    const base = if (map.get("path")) |p| p else cwd;
    const ic = if (map.get("ignore_case")) |v| std.mem.eql(u8, v, "true") else false;
    const resolved_base = try resolvePath(alloc, cwd, base);
    defer alloc.free(resolved_base);

    // Enumerate files via `find` (libc popen), then read each file in Zig via
    // readFileC and apply a simple substring match per line (no regex lib in
    // Zig 0.17 std).
    const find = try runArgv(alloc, resolved_base, &.{ "find", ".", "-type", "f" });
    defer freeResult(alloc, &find);
    if (!find.success) {
        return ToolResult{ .success = false, .output = "", .err_msg = try alloc.dupe(u8, "find failed") };
    }

    var out = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer out.deinit(alloc);
    var line_iter = std.mem.splitScalar(u8, find.output, '\n');
    while (line_iter.next()) |rel| {
        if (rel.len == 0) continue;
        const abs = std.fs.path.join(alloc, &.{ resolved_base, rel }) catch continue;
        const text = readFileC(alloc, io, abs) catch {
            alloc.free(abs);
            continue;
        };
        defer alloc.free(text);
        var lit = std.mem.splitScalar(u8, text, '\n');
        var line_no: usize = 0;
        while (lit.next()) |line| {
            line_no += 1;
            if (matchLine(line, pattern, ic)) {
                const line_out = try std.fmt.allocPrint(alloc, "{s}:{d}:{s}\n", .{ abs, line_no, line });
                defer alloc.free(line_out);
                try out.appendSlice(alloc, line_out);
            }
        }
        alloc.free(abs);
    }
    return ToolResult{ .success = true, .output = try out.toOwnedSlice(alloc) };
}

/// Substring match of `needle` in `hay` per line. Case-insensitive when `ic`.
fn matchLine(hay: []const u8, needle: []const u8, ic: bool) bool {
    if (needle.len == 0) return false;
    if (ic) {
        var i: usize = 0;
        while (i + needle.len <= hay.len) : (i += 1) {
            var ok = true;
            for (needle, 0..) |cn, k| {
                if (std.ascii.toLower(hay[i + k]) != std.ascii.toLower(cn)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// Run a command via /bin/sh -c with cwd prefix and 2>&1 merge.
fn shell(alloc: std.mem.Allocator, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &map);
    const cmd = map.get("command") orelse return ToolResult{ .success = false, .output = "", .err_msg = "missing command" };
    var full = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer full.deinit(alloc);
    try full.appendSlice(alloc, "cd ");
    try full.appendSlice(alloc, cwd);
    try full.appendSlice(alloc, " && ");
    try full.appendSlice(alloc, cmd);
    try full.appendSlice(alloc, " 2>&1");
    const full_z = try alloc.dupeSentinel(u8, full.items, 0);
    defer alloc.free(full_z);
    const fp = clib.popenRead(full_z.ptr) orelse return ToolResult{ .success = false, .output = "", .err_msg = "spawn failed" };
    var out = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer out.deinit(alloc);
    var buf: [8192]u8 = undefined;
    var truncated = false;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        if (out.items.len < MaxOutputBytes) {
            const room = MaxOutputBytes - out.items.len;
            const take = @min(n, room);
            try out.appendSlice(alloc, buf[0..take]);
            if (take < n) truncated = true;
        } else truncated = true;
    }
    const status = clib.pclosePipe(fp);
    const exited = (status & 0x7f) == 0;
    const exit_code: i32 = if (exited) @intCast((status >> 8) & 0xff) else -1;
    const success = exited and exit_code == 0;
    if (truncated) {
        try out.appendSlice(alloc, "\n... [output truncated]\n");
    }
    if (!success and out.items.len == 0) {
        return ToolResult{ .success = false, .output = try alloc.dupe(u8, ""), .err_msg = try std.fmt.allocPrint(alloc, "exit code {d}", .{exit_code}) };
    }
    return ToolResult{ .success = success, .output = try out.toOwnedSlice(alloc), .err_msg = if (success) null else try std.fmt.allocPrint(alloc, "exit code {d}", .{exit_code}) };
}

fn gitRun(alloc: std.mem.Allocator, repo: []const u8, args: []const []const u8) !ToolResult {
    var argv = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer argv.deinit(alloc);
    try argv.append(alloc, "git");
    for (args) |a| try argv.append(alloc, a);
    return runArgv(alloc, repo, argv.items);
}

fn gitDiff(alloc: std.mem.Allocator, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &map);
    const staged = if (map.get("staged")) |v| std.mem.eql(u8, v, "true") else false;
    var args: [2][]const u8 = undefined;
    if (staged) {
        args = .{ "diff", "--staged" };
    } else {
        args = .{ "diff", "." };
    }
    return gitRun(alloc, cwd, &args);
}

fn gitLog(alloc: std.mem.Allocator, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &map);
    const limit = if (map.get("limit")) |v| std.fmt.parseInt(usize, std.mem.trim(u8, v, " "), 10) catch 10 else 10;
    const limit_s = try std.fmt.allocPrint(alloc, "{d}", .{limit});
    defer alloc.free(limit_s);
    const args = [_][]const u8{ "log", "--oneline", "-n", limit_s };
    return gitRun(alloc, cwd, &args);
}

fn gitCommit(alloc: std.mem.Allocator, cwd: []const u8, call: ToolCall) !ToolResult {
    var map = try parseArgs(alloc, call.arguments);
    defer freeArgs(alloc, &map);
    const message = map.get("message") orelse return ToolResult{ .success = false, .output = "", .err_msg = "missing message" };
    var out = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer out.deinit(alloc);
    const add = try gitRun(alloc, cwd, &.{ "add", "-A" });
    defer freeResult(alloc, &add);
    if (!add.success) return add;
    try out.appendSlice(alloc, add.output);
    const msg_arg = try std.fmt.allocPrint(alloc, "{s}", .{message});
    defer alloc.free(msg_arg);
    const commit = try gitRun(alloc, cwd, &.{ "commit", "-m", msg_arg });
    defer freeResult(alloc, &commit);
    try out.appendSlice(alloc, commit.output);
    return ToolResult{ .success = commit.success, .output = try out.toOwnedSlice(alloc), .err_msg = commit.err_msg };
}

fn runArgv(alloc: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !ToolResult {
    var cmd = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer cmd.deinit(alloc);
    try cmd.appendSlice(alloc, "cd ");
    try cmd.appendSlice(alloc, cwd);
    try cmd.appendSlice(alloc, " && ");
    for (argv, 0..) |arg, i| {
        if (i > 0) try cmd.append(alloc, ' ');
        try cmd.append(alloc, '\'');
        try cmd.appendSlice(alloc, arg);
        try cmd.append(alloc, '\'');
    }
    try cmd.appendSlice(alloc, " 2>&1");
    const cmd_z = try alloc.dupeSentinel(u8, cmd.items, 0);
    defer alloc.free(cmd_z);
    const fp = clib.popenRead(cmd_z.ptr) orelse return ToolResult{ .success = false, .output = "", .err_msg = "spawn failed" };
    var out = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer out.deinit(alloc);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        if (out.items.len < MaxOutputBytes) {
            const room = MaxOutputBytes - out.items.len;
            try out.appendSlice(alloc, buf[0..@min(n, room)]);
        }
    }
    const status = clib.pclosePipe(fp);
    const exited = (status & 0x7f) == 0;
    const exit_code: i32 = if (exited) @intCast((status >> 8) & 0xff) else -1;
    const success = exited and exit_code == 0;
    return ToolResult{ .success = success, .output = try out.toOwnedSlice(alloc), .err_msg = if (success) null else try std.fmt.allocPrint(alloc, "exit code {d}", .{exit_code}) };
}

test "parseArgs flat object" {
    const alloc = std.testing.allocator;
    var map = try parseArgs(alloc, "{\"command\":\"ls -la\",\"path\":\"/tmp\"}");
    defer freeArgs(alloc, &map);
    try std.testing.expectEqual(@as(usize, 2), map.count());
    try std.testing.expectEqualSlices(u8, "ls -la", map.get("command").?);
}

test "shell echo" {
    const alloc = std.testing.allocator;
    var res = try shell(alloc, "/tmp", .{ .name = "shell", .arguments = "{\"command\":\"echo hello\"}" });
    defer freeResult(alloc, &res);
    try std.testing.expect(res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "hello") != null);
}

test "glob matches zig files" {
    const alloc = std.testing.allocator;
    var res = try glob(alloc, "/tmp", .{ .name = "glob", .arguments = "{\"pattern\":\"**/*.zig\",\"path\":\"/tmp\"}" });
    defer freeResult(alloc, &res);
    // We only assert it returns without error (no .zig files may exist).
    try std.testing.expect(res.success);
}
