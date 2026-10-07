//! directoryPicker browse primitives — wire truth:
//! `webui/packages/api/workspace-controller/src/directory-picker.ts`
//! (namespace "directoryPicker": list/createDirectory serve the browse
//! capability; pick is native-only and intentionally unserved).
//!
//! ── CONTRACT ──────────────────────────────────────────────────────────────
//! directoryPicker/list {path?} → DirectoryListing
//!   {path, home, crumbs:[{name,path,hidden}], entries:[{name,path,hidden}],
//!    truncated:boolean} — directories only, name-sorted; absent path lists
//!   the host home. Backs ui-directory-picker-browse, whose flow adds the
//!   新增工作区 entry to the workspace picker.
//! directoryPicker/createDirectory {path, name} → "<abs path>" — one new
//!   child directory; single-segment name, no overwrite.
//!
//! Directory detection is opendir-based (the CDirIterator pattern): macOS
//! d_type is unreliable through std.c and a GUI picker scans few entries.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const router = @import("router.zig");

extern "c" fn mkdir(path: [*:0]const u8, mode: c_int) c_int;

/// Directory-ness probe: opendir succeeds ⇒ directory (and closes it).
pub fn isDirectory(path: []const u8) bool {
    var buf: [512]u8 = undefined;
    if (path.len > buf.len - 1) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const d = std.c.opendir(@ptrCast(&buf)) orelse return false;
    _ = std.c.closedir(d);
    return true;
}

fn homePath() []const u8 {
    const env = std.c.getenv("HOME") orelse return ".";
    return std.mem.span(env);
}

/// One child directory row being sorted before rendering.
const Child = struct {
    base: [256]u8,
    base_len: usize,
    path: []u8,

    fn name(self: *const Child) []const u8 {
        return self.base[0..self.base_len];
    }
};

fn childLess(_: void, a: Child, b: Child) bool {
    return std.mem.lessThan(u8, a.name(), b.name());
}

/// Append one {name,path,hidden} row.
fn appendEntryJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, path: []const u8, first: *bool) !void {
    if (!first.*) try out.append(alloc, ',');
    first.* = false;
    try out.append(alloc, '{');
    try out.appendSlice(alloc, "\"name\":");
    try jsonx.appendJsonString(alloc, out, name);
    try out.appendSlice(alloc, ",\"path\":");
    try jsonx.appendJsonString(alloc, out, path);
    try out.appendSlice(alloc, ",\"hidden\":");
    try out.appendSlice(alloc, if (std.mem.startsWith(u8, name, ".")) "true" else "false");
    try out.append(alloc, '}');
}

/// Join `base` + one segment into buf; null when it cannot fit.
fn joinInto(buf: []u8, base: []const u8, seg: []const u8) ?[]const u8 {
    if (base.len + 1 + seg.len > buf.len - 1) return null;
    @memcpy(buf[0..base.len], base);
    buf[base.len] = '/';
    @memcpy(buf[base.len + 1 ..][0..seg.len], seg);
    return buf[0 .. base.len + 1 + seg.len];
}

pub fn handleList(deps: *const router.ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !router.UnaryResponse {
    const home = homePath();
    // Absent (or null) path lists the host home.
    const requested: ?[]const u8 = blk: {
        const raw = jsonx.getRaw(payload, "path") orelse break :blk null;
        if (!jsonx.isString(raw)) break :blk null;
        break :blk jsonx.decodeString(alloc, raw[1 .. raw.len - 1]) catch return error.OutOfMemory;
    };
    var dir_buf: [1024]u8 = undefined;
    const dir: []const u8 = if (requested) |p|
        if (p.len > 0 and p[0] == '/') p else (std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ deps.cwd, p }) catch
            return badPath(alloc, rpc_id))
    else
        home;
    if (!isDirectory(dir)) return badPath(alloc, rpc_id);

    // Crumbs: ancestry from the filesystem root, inclusive.
    var crumbs: std.ArrayList(u8) = .empty;
    defer crumbs.deinit(alloc);
    {
        var first = true;
        try crumbs.append(alloc, '[');
        if (dir.len > 0 and dir[0] == '/') {
            try appendEntryJson(alloc, &crumbs, "/", "/", &first);
        }
        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(alloc);
        var it = std.mem.splitScalar(u8, dir, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            prefix.append(alloc, '/') catch break;
            prefix.appendSlice(alloc, seg) catch break;
            appendEntryJson(alloc, &crumbs, seg, prefix.items, &first) catch break;
        }
        try crumbs.append(alloc, ']');
    }

    // Child directories, name-sorted, hidden flag per platform convention.
    var children: std.ArrayList(Child) = .empty;
    defer children.deinit(alloc);
    var it = DirScan.init(alloc, dir) orelse return badPath(alloc, rpc_id);
    defer it.deinit();
    while (it.next()) |name| {
        if (children.items.len >= 500) break;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var child_path_buf: [1024]u8 = undefined;
        const child_path = joinInto(&child_path_buf, dir, name) orelse continue;
        if (!isDirectory(child_path)) continue;
        var child: Child = .{ .base = undefined, .base_len = name.len, .path = undefined };
        if (name.len > child.base.len) continue;
        @memcpy(child.base[0..name.len], name);
        child.path = alloc.dupe(u8, child_path) catch return error.OutOfMemory;
        children.append(alloc, child) catch return error.OutOfMemory;
    }
    std.mem.sort(Child, children.items, {}, childLess);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"path\":");
    try jsonx.appendJsonString(alloc, &out, dir);
    try out.appendSlice(alloc, ",\"home\":");
    try jsonx.appendJsonString(alloc, &out, home);
    try out.appendSlice(alloc, ",\"crumbs\":");
    try out.appendSlice(alloc, crumbs.items);
    try out.appendSlice(alloc, ",\"entries\":[");
    var first = true;
    var truncated = false;
    for (children.items, 0..) |child, i| {
        if (i >= 500) {
            truncated = true;
            break;
        }
        try appendEntryJson(alloc, &out, child.name(), child.path, &first);
    }
    try out.appendSlice(alloc, "],\"truncated\":");
    try out.appendSlice(alloc, if (truncated) "true" else "false");
    try out.append(alloc, '}');
    return router.okValue(alloc, rpc_id, out.items);
}

pub fn handleCreateDirectory(deps: *const router.ApiProxyDeps, alloc: std.mem.Allocator, rpc_id: []const u8, payload: []const u8) !router.UnaryResponse {
    const parent = try router.reqString(alloc, payload, "path");
    const name = try router.reqString(alloc, payload, "name");
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.indexOfAny(u8, name, "/\\") != null) {
        return router.badRequest(alloc, rpc_id, "directory name must be a single path segment");
    }
    var joined_buf: [1024]u8 = undefined;
    const joined = joinInto(&joined_buf, parent, name) orelse
        return router.badRequest(alloc, rpc_id, "directory path too long");
    if (isDirectory(joined)) {
        return router.errValue(alloc, rpc_id, .directory_picker_exists, "directory already exists", "{}");
    }
    var z_buf: [1024]u8 = undefined;
    if (joined.len > z_buf.len - 1) return router.badRequest(alloc, rpc_id, "directory path too long");
    @memcpy(z_buf[0..joined.len], joined);
    z_buf[joined.len] = 0;
    if (mkdir(@ptrCast(&z_buf), 0o755) != 0) {
        return router.errValue(alloc, rpc_id, .directory_picker_create_failed, "directory creation failed", "{}");
    }
    _ = deps;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try jsonx.appendJsonString(alloc, &out, joined);
    return router.okValue(alloc, rpc_id, out.items);
}

fn badPath(alloc: std.mem.Allocator, rpc_id: []const u8) !router.UnaryResponse {
    return router.errValue(alloc, rpc_id, .workspace_invalid_path, "directory is not readable", "{}");
}

/// std.c.readdir-based directory scan (the remote_mux CDirIterator pattern,
/// with an allocator-owned NUL-terminated path buffer).
const DirScan = struct {
    dir: ?*std.c.DIR,
    path_z: []u8,

    fn init(alloc: std.mem.Allocator, path: []const u8) ?DirScan {
        _ = alloc;
        if (path.len > 1023) return null;
        const path_z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return null;
        @memcpy(path_z[0..path.len], path);
        const d = std.c.opendir(@ptrCast(path_z.ptr)) orelse {
            std.heap.page_allocator.free(path_z);
            return null;
        };
        return .{ .dir = d, .path_z = path_z };
    }
    fn deinit(self: *DirScan) void {
        if (self.dir) |d| _ = std.c.closedir(d);
        std.heap.page_allocator.free(self.path_z);
        self.dir = null;
    }
    fn next(self: *DirScan) ?[]const u8 {
        const entry = std.c.readdir(self.dir orelse return null) orelse return null;
        // macOS dirent: d_name sits at a non-zero offset inside the struct.
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.*.name)), 0);
    }
};
