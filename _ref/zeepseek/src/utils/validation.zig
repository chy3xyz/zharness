const std = @import("std");

pub const ValidationError = error{
    InvalidPath,
    PathTraversal,
    InvalidUrl,
    BlockedUrlScheme,
    BlockedHost,
};

pub fn validatePath(path: []const u8) ValidationError!void {
    if (std.mem.indexOfScalar(u8, path, 0)) |_| {
        return error.InvalidPath;
    }

    if (std.mem.indexOf(u8, path, "../") != null or std.mem.indexOf(u8, path, "..\\") != null) {
        return error.PathTraversal;
    }

    if (path.len > 0 and path[0] == '/') {
        return error.PathTraversal;
    }
}

pub fn validatePathWithWorkspace(workspace_dir: []const u8, relative_path: []const u8) ValidationError!void {
    try validatePath(relative_path);

    const candidate = std.fs.path.join(std.heap.page_allocator, &.{ workspace_dir, relative_path }) catch
        return error.InvalidPath;
    defer std.heap.page_allocator.free(candidate);

    const candidate_z = std.heap.page_allocator.allocSentinel(u8, candidate.len, 0) catch
        return error.InvalidPath;
    defer std.heap.page_allocator.free(candidate_z);
    @memcpy(candidate_z, candidate);

    const workspace_z = std.heap.page_allocator.allocSentinel(u8, workspace_dir.len, 0) catch
        return error.InvalidPath;
    defer std.heap.page_allocator.free(workspace_z);
    @memcpy(workspace_z, workspace_dir);

    var ws_buf: [4096]u8 = undefined;
    const real_ws_ptr = std.c.realpath(workspace_z.ptr, &ws_buf) orelse return error.InvalidPath;
    const real_ws_len = std.mem.indexOfSentinel(u8, 0, real_ws_ptr);

    var cand_buf: [4096]u8 = undefined;
    if (std.c.realpath(candidate_z.ptr, &cand_buf)) |resolved_ptr| {
        const resolved_len = std.mem.indexOfSentinel(u8, 0, resolved_ptr);
        if (!std.mem.startsWith(u8, resolved_ptr[0..resolved_len], real_ws_ptr[0..real_ws_len])) {
            return error.PathTraversal;
        }
    } else {
        const parent = std.fs.path.dirname(candidate) orelse return error.PathTraversal;
        const parent_z = std.heap.page_allocator.allocSentinel(u8, parent.len, 0) catch
            return error.InvalidPath;
        defer std.heap.page_allocator.free(parent_z);
        @memcpy(parent_z, parent);

        var parent_buf: [4096]u8 = undefined;
        const real_parent_ptr = std.c.realpath(parent_z.ptr, &parent_buf) orelse return error.PathTraversal;
        const parent_len = std.mem.indexOfSentinel(u8, 0, real_parent_ptr);
        if (!std.mem.startsWith(u8, real_parent_ptr[0..parent_len], real_ws_ptr[0..real_ws_len])) {
            return error.PathTraversal;
        }
    }
}

fn extractHostname(url: []const u8) ?[]const u8 {
    const proto_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const host_start = proto_end + 3;

    var host_end = url.len;
    for (url[host_start..], 0..) |c, i| {
        if (c == ':' or c == '/' or c == '?' or c == '#') {
            host_end = host_start + i;
            break;
        }
    }

    const hostname = url[host_start..host_end];
    if (hostname.len == 0) return null;

    if (hostname[0] == '[') {
        if (std.mem.indexOf(u8, hostname, "]")) |end| {
            return hostname[1..end];
        }
    }

    return hostname;
}

fn isPrivateIpv4(ip: []const u8) bool {
    var parts = std.mem.splitScalar(u8, ip, '.');
    var octets: [4]u32 = .{ 0, 0, 0, 0 };
    var idx: usize = 0;

    while (parts.next()) |part| {
        if (idx >= 4) return false;
        octets[idx] = std.fmt.parseInt(u32, part, 10) catch return false;
        idx += 1;
    }
    if (idx != 4) return false;

    if (octets[0] == 127) return true;
    if (octets[0] == 10) return true;
    if (octets[0] == 172 and octets[1] >= 16 and octets[1] <= 31) return true;
    if (octets[0] == 192 and octets[1] == 168) return true;
    if (octets[0] == 169 and octets[1] == 254) return true;
    if (octets[0] == 100 and octets[1] >= 64 and octets[1] <= 127) return true;
    if (octets[0] == 0) return true;

    return false;
}

pub fn validateUrl(url: []const u8) ValidationError!void {
    if (std.mem.indexOfScalar(u8, url, 0)) |_| {
        return error.InvalidUrl;
    }

    if (std.mem.startsWith(u8, url, "file://")) {
        return error.BlockedUrlScheme;
    }

    const hostname = extractHostname(url) orelse {
        return error.InvalidUrl;
    };

    const lower = std.ascii.allocLowerString(std.heap.page_allocator, hostname) catch return error.InvalidUrl;
    defer std.heap.page_allocator.free(lower);

    const blocked_hosts = &[_][]const u8{
        "localhost",
        "127.0.0.1",
        "0.0.0.0",
        "::1",
        "[::1]",
        "metadata.google.internal",
        "metadata.goog",
        "169.254.169.254",
        "metadata.aws.internal",
        "metadata.azure.internal",
        "metadata.alibabacloud.com",
    };
    for (blocked_hosts) |blocked| {
        if (std.mem.eql(u8, lower, blocked)) {
            return error.BlockedHost;
        }
    }

    if (std.mem.endsWith(u8, lower, ".nip.io") or
        std.mem.endsWith(u8, lower, ".xip.io") or
        std.mem.endsWith(u8, lower, ".sslip.io"))
    {
        return error.BlockedHost;
    }

    if (std.mem.indexOf(u8, lower, "metadata") != null) return error.BlockedHost;
    if (std.mem.indexOf(u8, lower, "internal") != null) return error.BlockedHost;

    if (std.Io.net.IpAddress.parseIp4(hostname, 0)) |_| {
        if (isPrivateIpv4(hostname)) return error.BlockedHost;
    } else |_| {}

    if (std.mem.eql(u8, lower, "::1")) return error.BlockedHost;

    if (isDecimalIp(hostname)) return error.BlockedHost;
}

fn isDecimalIp(hostname: []const u8) bool {
    if (hostname.len == 0) return false;
    for (hostname) |c| {
        if (c < '0' or c > '9') return false;
    }
    if (hostname.len > 10) return false;
    const num = std.fmt.parseInt(u32, hostname, 10) catch return false;
    return num <= 0xFFFFFFFF;
}

test "validatePath rejects null bytes" {
    try std.testing.expectError(error.InvalidPath, validatePath("file\x00.txt"));
}

test "validatePath rejects path traversal" {
    try std.testing.expectError(error.PathTraversal, validatePath("../etc/passwd"));
    try std.testing.expectError(error.PathTraversal, validatePath("..\\windows"));
}

test "validatePath rejects absolute paths" {
    try std.testing.expectError(error.PathTraversal, validatePath("/etc/passwd"));
}

test "validatePath allows safe paths" {
    try validatePath("src/main.zig");
    try validatePath("foo/bar/baz.txt");
}

test "validateUrl rejects file scheme" {
    try std.testing.expectError(error.BlockedUrlScheme, validateUrl("file:///etc/passwd"));
}

test "validateUrl rejects localhost" {
    try std.testing.expectError(error.BlockedHost, validateUrl("http://localhost:8080"));
    try std.testing.expectError(error.BlockedHost, validateUrl("https://127.0.0.1/api"));
}

test "validateUrl rejects private IPs" {
    try std.testing.expectError(error.BlockedHost, validateUrl("http://10.0.0.1/"));
    try std.testing.expectError(error.BlockedHost, validateUrl("http://192.168.1.1/"));
    try std.testing.expectError(error.BlockedHost, validateUrl("http://172.16.0.1/"));
}

test "validateUrl rejects metadata endpoints" {
    try std.testing.expectError(error.BlockedHost, validateUrl("http://metadata.google.internal/"));
    try std.testing.expectError(error.BlockedHost, validateUrl("http://169.254.169.254/"));
}

test "validateUrl allows safe URLs" {
    try validateUrl("https://example.com/path");
    try validateUrl("https://api.openai.com/v1/chat");
}

test "validateUrl blocks cloud metadata IP" {
    try std.testing.expectError(error.BlockedHost, validateUrl("http://169.254.169.254/latest/meta-data/"));
}

test "validateUrl rejects null bytes in URL" {
    try std.testing.expectError(error.InvalidUrl, validateUrl("http://evil.com\x00safe.com"));
}

test "validateUrl rejects URLs without protocol" {
    try std.testing.expectError(error.InvalidUrl, validateUrl("example.com/path"));
}

test "validatePath rejects backslash traversal" {
    try std.testing.expectError(error.PathTraversal, validatePath("..\\windows\\system32"));
}

test "validatePath rejects encoded traversal" {
    try std.testing.expectError(error.PathTraversal, validatePath("..\\etc\\passwd"));
}

test "validatePath allows dotfiles and normal paths" {
    try validatePath(".hidden_file");
    try validatePath(".gitignore");
    try validatePath("file-with-dashes.txt");
}

test "validatePath: fuzz - long paths" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 'a');
    buf[255] = 0;
    const long_path = std.mem.sliceTo(&buf, 0);
    try validatePath(long_path);
}

test "validatePath: fuzz - unicode paths" {
    try validatePath("src/你好/文件.txt");
    try validatePath("café/brûlée/baguette");
}

test "validatePath: fuzz - special but safe chars" {
    try validatePath("file_name.txt");
    try validatePath("path/to/file-v2.0_backup.tar.gz");
    try validatePath("project (1)/src/main.zig");
}

test "validatePath: fuzz - encoded traversal variants" {
    try std.testing.expectError(error.PathTraversal, validatePath("....//....//etc"));
}

test "validateUrl: fuzz - bypass attempts" {
    try std.testing.expectError(error.BlockedHost, validateUrl("http://127.0.0.1.nip.io/"));
    try std.testing.expectError(error.BlockedHost, validateUrl("http://10.0.0.1.xip.io/"));
    try std.testing.expectError(error.BlockedHost, validateUrl("http://2130706433/"));
}

test "validateUrl: fuzz - unicode domains" {
    try validateUrl("https://例子.中国/path");
    try validateUrl("https://münchen.de/schloss");
}

test "validateUrl: fuzz - valid edge cases" {
    try validateUrl("https://api.example.com:8443/v1/chat");
    try validateUrl("https://user:pass@example.com/resource");
    try validateUrl("https://example.com/path?q=hello%20world&lang=zh");
}
