const std = @import("std");
const builtin = @import("builtin");
const skill_mod = @import("skill.zig");
const Skill = skill_mod.Skill;
const SkillError = skill_mod.SkillError;
const manifest_mod = @import("manifest.zig");
const ManifestParser = manifest_mod.ManifestParser;
const git_worker_mod = @import("../utils/git_worker.zig");

pub const Installer = struct {
    allocator: std.mem.Allocator,
    user_agent: []const u8,

    pub fn init(allocator: std.mem.Allocator) !Installer {
        return .{
            .allocator = allocator,
            .user_agent = try allocator.dupe(u8, "zeepseek/0.1.0"),
        };
    }

    pub fn deinit(self: *Installer) void {
        self.allocator.free(self.user_agent);
    }

    /// Clones a skills repo from GitHub into `dest`.
    ///
    /// `git_worker` is the app-side worker subprocess (safe inside the
    /// zigzag runtime). When null, `io` must be provided and the clone is
    /// spawned directly. Both paths run `git` with verbatim argv (no shell),
    /// so owner/repo cannot inject shell operators.
    pub fn cloneFromGithub(
        self: *Installer,
        git_worker: ?*git_worker_mod.Client,
        io: std.Io,
        owner: []const u8,
        repo: []const u8,
        dest: []const u8,
    ) !void {
        const url = try std.fmt.allocPrint(self.allocator, "https://github.com/{s}/{s}.git", .{ owner, repo });
        defer self.allocator.free(url);
        try self.cloneUrl(git_worker, io, url, dest);
    }

    /// Clones `url` into `dest` (directory created as needed). See
    /// `cloneFromGithub` for the worker/spawn contract.
    pub fn cloneUrl(
        self: *Installer,
        git_worker: ?*git_worker_mod.Client,
        io: std.Io,
        url: []const u8,
        dest: []const u8,
    ) !void {
        const dest_z = try self.allocator.dupeSentinel(u8, dest, 0);
        defer self.allocator.free(dest_z);
        const mk_rc = std.c.mkdir(dest_z.ptr, 0o755);
        if (mk_rc != 0 and std.c.errno(mk_rc) != .EXIST) return error.CloneFailed;

        const args = [_][]const u8{ "clone", "--depth", "1", url, dest };
        if (git_worker) |gw| {
            const res = gw.runGit(self.allocator, dest, &args) orelse return error.CloneFailed;
            defer self.allocator.free(res);
            return;
        }

        var child = std.process.spawn(io, .{
            .argv = &.{ "git", "clone", "--depth", "1", url, dest },
            .cwd = .{ .path = dest },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return error.CloneFailed;
        const term = child.wait(io) catch return error.CloneFailed;
        if (!isExitedOk(term)) return error.CloneFailed;
    }

    /// Term uses field name `exited` in 0.17.
    fn isExitedOk(term: std.process.Child.Term) bool {
        return switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    pub fn parseManifest(self: *Installer, path: []const u8) !Skill {
        var parser = ManifestParser.init(self.allocator);
        return parser.parseFile(path);
    }

    pub fn validate(_: *Installer, skill: *const Skill) void {
        if (skill.name.len == 0) return;
        if (skill.version.len == 0) return;

        for (skill.commands) |cmd| {
            if (cmd.name.len == 0) return;
            if (cmd.handler.len == 0) return;
        }
    }

    pub fn listGithubSkills(self: *Installer) ![]const []const u8 {
        var skills = std.ArrayList([]const u8).init(self.allocator);
        try skills.append(try self.allocator.dupe(u8, "design-review"));
        try skills.append(try self.allocator.dupe(u8, "investigate"));
        try skills.append(try self.allocator.dupe(u8, "health"));
        try skills.append(try self.allocator.dupe(u8, "qa"));
        return skills.toOwnedSlice();
    }

    pub fn getSkillsDir(self: *Installer) ![]const u8 {
        if (comptime builtin.os.tag == .windows) {
            return std.fs.getAppDataDir(self.allocator, "zeepseek");
        } else if (comptime builtin.os.tag == .macos) {
            const home = std.c.getenv("HOME") orelse return SkillError.SkillsDirNotFound;
            const home_slice = std.mem.sliceTo(home, 0);
            return try std.fs.path.join(self.allocator, &.{ home_slice, "Library", "Application Support", "zeepseek", "skills" });
        } else {
            const home = std.c.getenv("HOME") orelse return SkillError.SkillsDirNotFound;
            const home_slice = std.mem.sliceTo(home, 0);
            return try std.fs.path.join(self.allocator, &.{ home_slice, ".local", "share", "zeepseek", "skills" });
        }
    }

    pub fn getSkillPath(self: *Installer, name: []const u8) ![]const u8 {
        const skills_dir = try self.getSkillsDir();
        defer self.allocator.free(skills_dir);
        // Reject path separators and dot-dot segments so a hostile name can
        // never escape the skills directory.
        if (std.mem.indexOfAny(u8, name, "/\\") != null or
            std.mem.eql(u8, name, "..") or std.mem.eql(u8, name, "."))
        {
            return error.InvalidSkillName;
        }
        return try std.fs.path.join(self.allocator, &.{ skills_dir, name });
    }

    pub fn findManifest(self: *Installer, dir_path: []const u8) !?[]const u8 {
        const manifest_names = [_][]const u8{ "skill.yaml", "skill.yml", "skill.json" };
        for (manifest_names) |name| {
            const manifest_path = try std.fs.path.join(self.allocator, &.{ dir_path, name });
            const manifest_path_z = std.heap.page_allocator.dupeSentinel(u8, manifest_path, 0) catch {
                self.allocator.free(manifest_path);
                return error.OutOfMemory;
            };
            defer std.heap.page_allocator.free(manifest_path_z);
            if (std.c.access(manifest_path_z.ptr, std.posix.F_OK) == 0) {
                return manifest_path;
            }
            self.allocator.free(manifest_path);
        }
        return null;
    }
};

test "cloneUrl copies a local repo via direct git spawn" {
    const alloc = std.testing.allocator;

    var tmp_root = std.testing.tmpDir(.{});
    defer tmp_root.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_path_len = try tmp_root.dir.realPath(std.testing.io, &path_buf);
    const src_path = path_buf[0..src_path_len];

    // Build a real git repo to act as the "remote" source.
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    const src = try std.fs.path.join(alloc, &.{ src_path, "src-repo" });
    defer alloc.free(src);
    const src_z = try std.heap.page_allocator.dupeSentinel(u8, src, 0);
    defer std.heap.page_allocator.free(src_z);
    const mk_rc = std.c.mkdir(src_z.ptr, 0o755);
    if (mk_rc != 0 and std.c.errno(mk_rc) != .EXIST) return error.TestUnexpectedResult;
    const skill_file = try std.fs.path.join(alloc, &.{ src, "skill.yaml" });
    defer alloc.free(skill_file);
    const skill_file_z = try std.heap.page_allocator.dupeSentinel(u8, skill_file, 0);
    defer std.heap.page_allocator.free(skill_file_z);
    const fp = std.c.fopen(skill_file_z.ptr, "wb") orelse return error.TestUnexpectedResult;
    const payload = "name: test-skill\nversion: 1.0.0\n";
    const written = std.c.fwrite(payload.ptr, 1, payload.len, fp);
    if (written != payload.len) return error.TestUnexpectedResult;
    _ = std.c.fclose(fp);

    // git init && add && commit in the src repo.
    try runGitForTest(io, alloc, src, &.{ "init", "-q" });
    try runGitForTest(io, alloc, src, &.{ "add", "." });
    try runGitForTest(io, alloc, src, &.{ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init" });

    var installer = try Installer.init(alloc);
    defer installer.deinit();

    const dest = try std.fs.path.join(alloc, &.{ src_path, "cloned" });
    defer alloc.free(dest);

    const url = try std.fmt.allocPrint(alloc, "file://{s}", .{src});
    defer alloc.free(url);

    try installer.cloneUrl(null, io, url, dest);

    // Cloned repo must contain the manifest.
    const manifest_path = try std.fs.path.join(alloc, &.{ dest, "skill.yaml" });
    defer alloc.free(manifest_path);

    const manifest_path_z = try std.heap.page_allocator.dupeSentinel(u8, manifest_path, 0);
    defer std.heap.page_allocator.free(manifest_path_z);
    const f = std.c.fopen(manifest_path_z.ptr, "rb") orelse return error.TestUnexpectedResult;
    defer _ = std.c.fclose(f);
    var content: [128]u8 = undefined;
    const n = std.c.fread(&content, 1, content.len, f);
    try std.testing.expect(std.mem.indexOf(u8, content[0..n], "test-skill") != null);
}

test "cloneUrl fails cleanly when source is missing" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();

    var installer = try Installer.init(alloc);
    defer installer.deinit();

    var tmp_root = std.testing.tmpDir(.{});
    defer tmp_root.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp_root.dir.realPath(std.testing.io, &path_buf);
    const dest = try std.fs.path.join(alloc, &.{ path_buf[0..base_len], "nope" });
    defer alloc.free(dest);
    try std.testing.expectError(error.CloneFailed, installer.cloneUrl(null, threaded.io(), "file:///nonexistent-src-xyz", dest));
}

/// Helper: run `git <args>` in `cwd`, expecting success.
fn runGitForTest(io: std.Io, alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "git");
    for (args) |a| try argv.append(alloc, a);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);
}
