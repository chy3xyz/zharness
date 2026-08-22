//! Zero-dependency BM25 long-term memory (borrowed from DeepSeek-Reasonix).
//!
//! Facts are stored as plain lines in ~/.zeepseek/memory.md. At query time
//! BM25 (token overlap scoring) retrieves the most relevant facts, which
//! are appended to the system prompt as a low-authority footnote (bounded
//! to keep token cost low). CJK text is split per character.

const std = @import("std");

pub const Memory = struct {
    alloc: std.mem.Allocator,
    facts: std.ArrayList([]const u8), // owned lines

    pub fn init(alloc: std.mem.Allocator) Memory {
        return .{ .alloc = alloc, .facts = .empty };
    }

    pub fn deinit(self: *Memory) void {
        for (self.facts.items) |f| self.alloc.free(f);
        self.facts.deinit(self.alloc);
    }

    /// Load facts from the memory file (one per line, '#' comments ignored).
    pub fn load(self: *Memory, path: []const u8) void {
        const fd = std.c.open(@ptrCast(path.ptr), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        var buf: [8192]u8 = undefined;
        const n: usize = @intCast(std.c.read(fd, &buf, buf.len));
        var it = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \r");
            if (t.len == 0 or t[0] == '#') continue;
            self.facts.append(self.alloc, self.alloc.dupe(u8, t) catch continue) catch {};
        }
    }

    /// Add a fact (appends to memory and the file).
    pub fn add(self: *Memory, path: []const u8, fact: []const u8) void {
        const owned = self.alloc.dupe(u8, std.mem.trim(u8, fact, " \r")) catch return;
        if (owned.len == 0) {
            self.alloc.free(owned);
            return;
        }
        self.facts.append(self.alloc, owned) catch {
            self.alloc.free(owned);
            return;
        };
        // Append to the file (best effort).
        const fd = std.c.open(@ptrCast(path.ptr), std.c.O{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        _ = std.c.lseek(fd, 0, std.c.SEEK.END);
        _ = std.c.write(fd, owned.ptr, owned.len);
        _ = std.c.write(fd, "\n", 1);
    }

    fn tokenize(alloc: std.mem.Allocator, text: []const u8, out: *std.ArrayList(u8)) void {
        // Lowercase ASCII words + single CJK chars. ASCII word tokens are
        // delimited with the 0x1f separator so they don't merge into one blob.
        var i: usize = 0;
        var in_word: bool = false;
        while (i < text.len) {
            const c = text[i];
            if (c >= 'a' and c <= 'z') {
                out.append(alloc, c) catch {};
                in_word = true;
                i += 1;
            } else if (c >= 'A' and c <= 'Z') {
                out.append(alloc, c + 32) catch {};
                in_word = true;
                i += 1;
            } else if (c >= '0' and c <= '9') {
                out.append(alloc, c) catch {};
                in_word = true;
                i += 1;
            } else if (c < 0x80) {
                if (in_word) {
                    out.append(alloc, 0x1f) catch {}; // token boundary
                    in_word = false;
                }
                i += 1; // punctuation/space: token boundary
            } else {
                // Multi-byte char: emit as a token of 4 bytes (its bytes).
                const end = std.unicode.utf8ByteSequenceLength(c) catch 1;
                var j: usize = 0;
                while (j < end and i + j < text.len) : (j += 1) {
                    out.append(alloc, text[i + j]) catch {};
                }
                out.append(alloc, 0x1f) catch {}; // separator
                in_word = false;
                i += end;
            }
        }
    }

    /// BM25-ish relevance: count query-token occurrences in the fact,
    /// weighted by inverse document frequency (rare tokens matter more).
    fn score(self: *Memory, query_tokens: []const u8, fact: []const u8) f64 {
        var total: f64 = 0;
        const qlen = query_tokens.len;
        if (qlen == 0) return 0;
        var qi: usize = 0;
        while (qi < qlen) {
            // Extract one query token (up to a separator or EOF).
            var tok: [8]u8 = undefined;
            var tl: usize = 0;
            while (qi < qlen and query_tokens[qi] != 0x1f) : (qi += 1) {
                if (tl < tok.len) {
                    tok[tl] = query_tokens[qi];
                    tl += 1;
                }
            }
            if (tl == 0) {
                qi += 1;
                continue;
            }
            const t = tok[0..tl];
            // Count occurrences in the fact.
            var cnt: usize = 0;
            var idx: usize = 0;
            while (idx < fact.len) {
                if (std.mem.indexOf(u8, fact[idx..], t)) |p| {
                    cnt += 1;
                    idx += p + t.len;
                } else break;
            }
            if (cnt > 0) {
                // Document frequency: how many facts contain this token.
                var df: usize = 0;
                for (self.facts.items) |f| {
                    if (std.mem.indexOf(u8, f, t) != null) df += 1;
                }
                const idf = @log(@as(f64, @floatFromInt(self.facts.items.len + 1)) / @as(f64, @floatFromInt(df + 1)) + 1.0);
                total += idf * @as(f64, @floatFromInt(cnt));
            }
            qi += 1;
        }
        return total;
    }

    /// Retrieve the top `max` facts for `query`, joined with newlines,
    /// bounded to `max_chars`. Returns an owned string ("" if none).
    pub fn recall(self: *Memory, query: []const u8, max: usize, max_chars: usize) []const u8 {
        if (self.facts.items.len == 0) return self.alloc.dupe(u8, "") catch "";
        var qt = std.ArrayList(u8).empty;
        defer qt.deinit(self.alloc);
        tokenize(self.alloc, query, &qt);

        // Simple selection: score each fact, keep the best few.
        var best: [4]struct { score: f64, fact: []const u8 } = undefined;
        var best_len: usize = 0;
        const cap = @min(max, 4);
        for (self.facts.items) |f| {
            const sc = self.score(qt.items, f);
            if (sc <= 0) continue;
            var pos = best_len;
            while (pos > 0 and best[pos - 1].score < sc) pos -= 1;
            if (pos < cap) {
                if (best_len < cap) best_len += 1;
                var k = best_len - 1;
                while (k > pos) : (k -= 1) best[k] = best[k - 1];
                best[pos] = .{ .score = sc, .fact = f };
            }
        }

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        var total: usize = 0;
        for (best[0..best_len]) |b| {
            if (total + b.fact.len + 2 > max_chars) break;
            out.appendSlice(self.alloc, b.fact) catch break;
            out.appendSlice(self.alloc, "\n") catch break;
            total += b.fact.len + 1;
        }
        return out.toOwnedSlice(self.alloc) catch "";
    }
};

test "memory add and recall" {
    const alloc = std.testing.allocator;
    var mem = Memory.init(alloc);
    defer mem.deinit();
    mem.facts.append(alloc, alloc.dupe(u8, "user prefers tabs over spaces") catch return) catch {};
    mem.facts.append(alloc, alloc.dupe(u8, "project uses zig 0.17") catch return) catch {};
    const r = mem.recall("tabs in code", 2, 200);
    defer alloc.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "tabs") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "zig") == null);
}

test "memory add writes the fact to the file" {
    const alloc = std.testing.allocator;
    var mem = Memory.init(alloc);
    defer mem.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.joinZ(alloc, &.{ path_buf[0..dir_len], "mem_add_test.md" });
    defer alloc.free(path);

    mem.add(path, "user prefers tabs");
    const fd = std.c.open(path.ptr, std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var buf: [256]u8 = undefined;
    const r = std.c.read(fd, &buf, buf.len);
    try std.testing.expect(r > 0);
    try std.testing.expectEqualStrings("user prefers tabs\n", buf[0..@intCast(r)]);
}

test "memory recall single token query" {
    const alloc = std.testing.allocator;
    var mem = Memory.init(alloc);
    defer mem.deinit();
    mem.facts.append(alloc, alloc.dupe(u8, "project uses zig") catch return) catch {};
    const r = mem.recall("zig", 4, 1200);
    defer alloc.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "zig") != null);
}

test "memory empty recall" {
    const alloc = std.testing.allocator;
    var mem = Memory.init(alloc);
    defer mem.deinit();
    const r = mem.recall("anything", 2, 200);
    defer alloc.free(r);
    try std.testing.expectEqual(@as(usize, 0), r.len);
}
