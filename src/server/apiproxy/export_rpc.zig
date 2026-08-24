//! Session export — the downloads-domain data layer (wave-6 task spec).
//!
//! Upstream contract (recon truth):
//!   - `_ref/deepseek-harness/packages/host/apiproxy/src/api/downloads*.ts`:
//!     the download channel has NO wire envelope. The carrier answers
//!     `GET /api/session.export?sessionId=<id>[&includeDescendants=true]`
//!     directly (fetch/handler.ts:260): 400 on bad query params, 404 when the
//!     root session has no stored log, otherwise an ATTACHMENT response whose
//!     body streams one ZIP archive.
//!   - `session-export.ts`: the archive holds each included session's stored
//!     artifact VERBATIM — the root under its original base name, every
//!     subagent descendant under `subagents/<safe-id>/<filename>` (lineage
//!     order). No manifest; files are byte-identical to the durable store.
//!   - Filename: `dsh-session-<sanitized-id>.zip`, sanitized by upstream
//!     safeSessionIdSegment (`[^A-Za-z0-9_-] → '_'`; 'a/b' → 'a_b').
//!   - The vendored UI names the file CLIENT-side
//!     (session-log-export/src/client/controller.ts:122), so zharness v1 can
//!     answer with a bare application/zip body and still work; the
//!     content-disposition line is documented for integrators who add the
//!     one-liner Responder header extension later.
//!
//! ── zharness v1 mapping ───────────────────────────────────────────────────
//!   - Stored artifact = `.zharness/sessions/<id>.json` transcript verbatim
//!     (zharness stores JSON arrays, not JSONL — same file, byte-exact).
//!   - Descendants: subagents_rpc.zig registry rows whose parentSessionId is
//!     the exported session AND whose `<child>.json` transcript exists.
//!     spawn_agent runs do not persist child transcripts today (documented),
//!     so the descendants section is usually empty — fail-SOFT here (upstream
//!     fails LOUD on a missing descendant artifact) because our lineage comes
//!     from an in-memory registry that may outlive nothing. Documented
//!     deviation, honest degrade.
//!   - Plus the task-spec extras: markdown + JSON VALUE builders over the
//!     decoded transcript for non-zip consumers (docs/tests).
//!
//! ── INTEGRATOR WIRING (GET route inside router.handleApiRequest's /api/
//!    segment handling, BEFORE the POST-only fence) ─────────────────────────
//!   if (std.mem.eql(u8, seg, "session.export") and GET/HEAD) {
//!       parse query: sessionId required; includeDescendants ∈ {absent,
//!         "true","false"} else 400 text;
//!       const dl = export_rpc.sessionLogDownload(alloc, cfg.io, cfg.cwd,
//!           session_id, include_descendants) catch |e| switch (e) {
//!           error.SessionNotFound => res.send(.not_found, .text, "no such session"),
//!           else => return e, };
//!       // optional header: Content-Disposition: attachment; filename="<dl.filename>"
//!       return res.sendRawType(.ok, dl.content_type, dl.body);
//!   }
//!   HEAD answers identically minus the body (upstream parity).
//!
//! All allocations go to the caller's allocator (the request arena).

const std = @import("std");
const sessions = @import("sessions.zig");
const jsonx = @import("jsonx.zig");
const subagents_rpc = @import("subagents_rpc.zig");
const clib = @import("../../clib.zig");

/// One ZIP entry in upstream zip order: path + verbatim text content.
pub const Entry = struct {
    path: []const u8,
    content: []const u8,
};

// ── naming ──────────────────────────────────────────────────────────────────

/// Upstream safeSessionIdSegment: one filesystem-safe path segment from an
/// untrusted id (`[^A-Za-z0-9_-] → '_'`). Writes into `buf`, returns the slice.
pub fn safeSessionIdSegment(buf: []u8, id: []const u8) []const u8 {
    const n = @min(buf.len, id.len);
    for (id[0..n], 0..) |c, i| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        buf[i] = if (ok) c else '_';
    }
    if (id.len > buf.len) {
        // Caller buffer too small: sanitize the prefix we can keep (never
        // happens with 64+ byte buffers and real session ids).
        return buf[0..n];
    }
    return buf[0..id.len];
}

/// Upstream sessionLogZipFilename ("dsh-session-<seg>.zip").
pub fn zipFilenameAlloc(alloc: std.mem.Allocator, session_id: []const u8) ![]u8 {
    var seg_buf: [128]u8 = undefined;
    const seg = safeSessionIdSegment(&seg_buf, session_id);
    return std.fmt.allocPrint(alloc, "dsh-session-{s}.zip", .{seg});
}

// ── entry collection ────────────────────────────────────────────────────────

fn readTranscriptVerbatim(io: std.Io, alloc: std.mem.Allocator, cwd: []const u8, id: []const u8) ![]u8 {
    const dir = try sessions.transcriptDir(alloc, cwd);
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, id });
    defer alloc.free(path);
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => error.SessionNotFound,
        else => e,
    };
}

/// Collect the export entries in upstream zip order: root artifact first,
/// then every recorded subagent descendant's transcript (when it exists on
/// disk), depth-first in registry order.
pub fn collectEntries(
    io: std.Io,
    alloc: std.mem.Allocator,
    cwd: []const u8,
    session_id: []const u8,
    include_descendants: bool,
) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(alloc);

    const root_name = try std.fmt.allocPrint(alloc, "{s}.json", .{session_id});
    try out.append(alloc, .{
        .path = root_name,
        .content = try readTranscriptVerbatim(io, alloc, cwd, session_id),
    });

    if (include_descendants) {
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(alloc);
        try seen.append(alloc, session_id);

        // Registry rows are best-effort: a dead/unwired registry simply
        // contributes zero descendants (documented fail-soft deviation).
        var runs: []const subagents_rpc.Snapshot = &.{};
        if ((try subagents_rpc.shared()).list(alloc, session_id)) |r| {
            runs = r;
        } else |_| {}
        defer if (runs.len > 0) subagents_rpc.Snapshot.freeSnapshots(alloc, runs);

        for (runs) |run| {
            var already = false;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, run.id)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            try seen.append(alloc, run.id);

            const child = readTranscriptVerbatim(io, alloc, cwd, run.id) catch continue; // fail-soft (see header)
            const seg_buf = try alloc.alloc(u8, run.id.len);
            const seg = safeSessionIdSegment(seg_buf, run.id);
            try out.append(alloc, .{
                .path = try std.fmt.allocPrint(alloc, "subagents/{s}/{s}.json", .{ seg, run.id }),
                .content = child,
            });
        }
    }

    return out.toOwnedSlice(alloc);
}

// ── ZIP writer (store method, no compression — upstream default is deflate
//    level 6 but method 0 archives are valid ZIP everywhere and keep this
//    module dependency-free; documented deviation) ───────────────────────────

fn put16(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(alloc, b[0..]);
}

fn put32(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(alloc, b[0..]);
}

/// Build one ZIP archive over `entries` (STORE method). Deterministic:
/// timestamps zeroed, no extra fields, no data descriptors.
pub fn buildZipStore(alloc: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    const Central = struct { name: []const u8, crc: u32, size: u32, offset: u32 };
    var centrals: std.ArrayList(Central) = .empty;
    defer centrals.deinit(alloc);

    for (entries) |e| {
        const offset: u32 = @intCast(out.items.len);
        const crc = std.hash.Crc32.hash(e.content);
        const size: u32 = @intCast(e.content.len);
        const name_len: u16 = @intCast(e.path.len);

        try out.appendSlice(alloc, "PK\x03\x04"); // local file header
        try put16(alloc, &out, 20); // version needed
        try put16(alloc, &out, 0); // flags
        try put16(alloc, &out, 0); // method: store
        try put16(alloc, &out, 0); // mod time
        try put16(alloc, &out, 0); // mod date
        try put32(alloc, &out, crc);
        try put32(alloc, &out, size); // compressed
        try put32(alloc, &out, size); // uncompressed
        try put16(alloc, &out, name_len);
        try put16(alloc, &out, 0); // extra len
        try out.appendSlice(alloc, e.path);
        try out.appendSlice(alloc, e.content);

        try centrals.append(alloc, .{ .name = e.path, .crc = crc, .size = size, .offset = offset });
    }

    const cd_offset: u32 = @intCast(out.items.len);
    for (centrals.items) |c| {
        try out.appendSlice(alloc, "PK\x01\x02"); // central directory header
        try put16(alloc, &out, 20); // version made by
        try put16(alloc, &out, 20); // version needed
        try put16(alloc, &out, 0); // flags
        try put16(alloc, &out, 0); // method
        try put16(alloc, &out, 0); // time
        try put16(alloc, &out, 0); // date
        try put32(alloc, &out, c.crc);
        try put32(alloc, &out, c.size);
        try put32(alloc, &out, c.size);
        try put16(alloc, &out, @intCast(c.name.len));
        try put16(alloc, &out, 0); // extra
        try put16(alloc, &out, 0); // comment
        try put16(alloc, &out, 0); // disk start
        try put16(alloc, &out, 0); // internal attrs
        try put32(alloc, &out, 0); // external attrs
        try put32(alloc, &out, c.offset);
        try out.appendSlice(alloc, c.name);
    }
    const cd_size: u32 = @intCast(out.items.len - cd_offset);

    try out.appendSlice(alloc, "PK\x05\x06"); // EOCD
    try put16(alloc, &out, 0); // this disk
    try put16(alloc, &out, 0); // cd disk
    try put16(alloc, &out, @intCast(centrals.items.len)); // entries this disk
    try put16(alloc, &out, @intCast(centrals.items.len)); // entries total
    try put32(alloc, &out, cd_size);
    try put32(alloc, &out, cd_offset);
    try put16(alloc, &out, 0); // comment len

    return out.toOwnedSlice(alloc);
}

// ── value builders (markdown / JSON per the wave-6 task spec) ───────────────

/// Human-readable markdown rendering of one decoded transcript.
pub fn buildMarkdownExport(
    alloc: std.mem.Allocator,
    session_id: []const u8,
    msgs: []const sessions.MsgRec,
    updated_at_ms: i64,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "# Session ");
    try out.appendSlice(alloc, session_id);
    try out.appendSlice(alloc, "\n\n");
    var iso: std.ArrayList(u8) = .empty;
    defer iso.deinit(alloc);
    try jsonx.appendIso8601(alloc, &iso, updated_at_ms);
    try out.appendSlice(alloc, "- Exported: ");
    try out.appendSlice(alloc, iso.items);
    try out.print(alloc, "\n- Messages: {d}\n", .{msgs.len});

    for (msgs, 0..) |m, i| {
        try out.print(alloc, "\n## {d}. ", .{i + 1});
        if (std.mem.eql(u8, m.role, "user")) {
            try out.appendSlice(alloc, "User");
        } else if (std.mem.eql(u8, m.role, "assistant")) {
            try out.appendSlice(alloc, "Assistant");
        } else if (std.mem.eql(u8, m.role, "tool")) {
            try out.appendSlice(alloc, "Tool result");
            if (m.tool_call_id) |cid| try out.print(alloc, " ({s})", .{cid});
        } else {
            try out.print(alloc, "{s}", .{m.role});
        }
        try out.appendSlice(alloc, "\n\n");
        try out.appendSlice(alloc, m.content);
        try out.appendSlice(alloc, "\n");
        if (m.tool_calls_json) |tcj| {
            const slots = sessions.parseToolCallSlots(alloc, tcj) catch continue;
            defer sessions.freeToolCallSlots(alloc, slots);
            for (slots) |slot| {
                try out.print(alloc, "\n> tool call `{s}` args: {s}\n", .{ slot.name, slot.arguments_json });
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

// ── downloads-domain surface ────────────────────────────────────────────────

/// One attachment response body (the carrier renders status/headers).
pub const Download = struct {
    filename: []const u8,
    content_type: []const u8,
    body: []const u8,
};

/// The upstream `downloads.sessionLog` value builder: one ZIP attachment of
/// the root transcript (+ recorded descendants when asked). Errors:
/// SessionNotFound (→ carrier 404), OutOfMemory, IO errors (→ 500 class).
pub fn sessionLogDownload(
    io: std.Io,
    alloc: std.mem.Allocator,
    cwd: []const u8,
    session_id: []const u8,
    include_descendants: bool,
) !Download {
    const entries = try collectEntries(io, alloc, cwd, session_id, include_descendants);
    const body = try buildZipStore(alloc, entries);
    return .{
        .filename = try zipFilenameAlloc(alloc, session_id),
        .content_type = "application/zip",
        .body = body,
    };
}

/// Markdown flavor of the export (task-spec extra): readable transcript doc.
pub fn markdownDownload(
    io: std.Io,
    alloc: std.mem.Allocator,
    cwd: []const u8,
    session_id: []const u8,
) !Download {
    const msgs = try sessions.loadTranscript(io, alloc, try transcriptPathOf(alloc, cwd, session_id));
    const updated = sessions.mtimeMs(io, try transcriptPathOf(alloc, cwd, session_id));
    return .{
        .filename = try std.fmt.allocPrint(alloc, "dsh-session-{s}.md", .{safeSegDup(alloc, session_id)}),
        .content_type = "text/markdown",
        .body = try buildMarkdownExport(alloc, session_id, msgs, updated),
    };
}

/// JSON flavor: the stored artifact bytes verbatim (already valid JSON).
pub fn jsonDownload(
    io: std.Io,
    alloc: std.mem.Allocator,
    cwd: []const u8,
    session_id: []const u8,
) !Download {
    return .{
        .filename = try std.fmt.allocPrint(alloc, "dsh-session-{s}.json", .{safeSegDup(alloc, session_id)}),
        .content_type = "application/json",
        .body = try readTranscriptVerbatim(io, alloc, cwd, session_id),
    };
}

fn transcriptPathOf(alloc: std.mem.Allocator, cwd: []const u8, id: []const u8) ![]u8 {
    return sessions.transcriptPath(alloc, cwd, id);
}

fn safeSegDup(alloc: std.mem.Allocator, id: []const u8) []const u8 {
    var buf: [128]u8 = undefined;
    return alloc.dupe(u8, safeSessionIdSegment(&buf, id)) catch "";
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "safeSessionIdSegment matches upstream examples" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abc-DEF_123", safeSessionIdSegment(&buf, "abc-DEF_123"));
    try testing.expectEqualStrings("a_b", safeSessionIdSegment(&buf, "a/b"));
    // Every disallowed char (dots and slashes alike) collapses to '_'.
    try testing.expectEqualStrings("______etc_pass", safeSessionIdSegment(&buf, "../../etc/pass"));
}

test "zipFilenameAlloc matches upstream fixture" {
    const f = try zipFilenameAlloc(testing.allocator, "a/b");
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("dsh-session-a_b.zip", f);
}

test "buildZipStore produces a parseable store-method archive" {
    const entries = [_]Entry{
        .{ .path = "root.json", .content = "[{\"role\":\"user\",\"content\":\"hi\"}]" },
        .{ .path = "subagents/child_x/child_x.json", .content = "[]" },
    };
    const zip = try buildZipStore(testing.allocator, &entries);
    defer testing.allocator.free(zip);

    try testing.expect(zip.len > 4);
    try testing.expectEqualStrings("PK\x03\x04", zip[0..4]);
    // EOCD signature at the tail; comment length 0 means it ends the file.
    try testing.expectEqualStrings("PK\x05\x06", zip[zip.len - 22 ..][0..4]);
    const eocd = zip[zip.len - 22 ..];
    const total_entries = std.mem.readInt(u16, eocd[10..12], .little);
    try testing.expectEqual(entries.len, total_entries);
    const cd_size = std.mem.readInt(u32, eocd[12..16], .little);
    const cd_offset = std.mem.readInt(u32, eocd[16..20], .little);
    try testing.expectEqual(zip.len - 22, cd_offset + cd_size);

    // First local header: store method, sizes + CRC match the content.
    const content0 = entries[0].content;
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, zip[8..10], .little));
    const crc0 = std.mem.readInt(u32, zip[14..18], .little);
    try testing.expectEqual(std.hash.Crc32.hash(content0), crc0);
    const size0 = std.mem.readInt(u32, zip[18..22], .little);
    try testing.expectEqual(content0.len, size0);
    // Entry content appears verbatim after its local header (30 + name len).
    const name_len0 = std.mem.readInt(u16, zip[26..28], .little);
    const data_at = 30 + name_len0;
    try testing.expectEqualSlices(u8, content0, zip[data_at .. data_at + content0.len]);

    // Second entry's CRC via its central directory record.
    const cd = zip[cd_offset..];
    try testing.expectEqualStrings("PK\x01\x02", cd[0..4]);
    // Walk to the second central record: 46 fixed + name0 len.
    const rec1 = cd[46 + entries[0].path.len ..];
    try testing.expectEqualStrings("PK\x01\x02", rec1[0..4]);
    const crc1 = std.mem.readInt(u32, rec1[16..20], .little);
    try testing.expectEqual(std.hash.Crc32.hash(entries[1].content), crc1);
}

test "buildMarkdownExport renders roles, tool calls, and counts" {
    const alloc = testing.allocator;
    var slots_json = std.ArrayList(u8).empty;
    defer slots_json.deinit(alloc);
    try slots_json.appendSlice(alloc, "[{\"id\":\"call_1\",\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}]");

    const msgs = [_]sessions.MsgRec{
        .{ .role = "user", .content = "what dir" },
        .{ .role = "assistant", .content = "checking", .tool_calls_json = slots_json.items },
        .{ .role = "tool", .content = "/home/x", .tool_call_id = "call_1" },
        .{ .role = "assistant", .content = "it is /home/x" },
    };
    const md = try buildMarkdownExport(alloc, "sess-9", &msgs, 1755946500000);
    defer alloc.free(md);

    try testing.expect(std.mem.startsWith(u8, md, "# Session sess-9\n"));
    try testing.expect(std.mem.indexOf(u8, md, "- Messages: 4") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## 1. User") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## 3. Tool result (call_1)") != null);
    try testing.expect(std.mem.indexOf(u8, md, "> tool call `shell`") != null);
    try testing.expect(std.mem.indexOf(u8, md, "it is /home/x") != null);
}

test "sessionLogDownload zips the root transcript verbatim; missing session 404s" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var name_buf: [64]u8 = undefined;
    const uniq = clib.nowTimestamp();
    const cwd_abs = try std.fmt.bufPrint(&name_buf, "/tmp/zh_g2_export_{d}", .{uniq});

    const threaded = try alloc.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(alloc, .{});
    const io = threaded.io();
    defer {
        if (std.Io.Dir.openDir(.cwd(), io, "/tmp", .{})) |tmp_dir_res| {
            var tmp_dir = tmp_dir_res;
            defer std.Io.Dir.close(tmp_dir, io);
            tmp_dir.deleteTree(io, std.fs.path.basename(cwd_abs)) catch {};
        } else |_| {}
        threaded.deinit();
        alloc.destroy(threaded);
    }

    // Missing root → SessionNotFound before any byte is produced.
    try testing.expectError(error.SessionNotFound, sessionLogDownload(io, alloc, cwd_abs, "ghost", false));

    const sessions_rel = ".zharness/sessions";
    var dir_path = std.ArrayList(u8).empty;
    defer dir_path.deinit(alloc);
    try dir_path.appendSlice(alloc, cwd_abs);
    try dir_path.append(alloc, '/');
    try dir_path.appendSlice(alloc, sessions_rel);
    try std.Io.Dir.createDirPath(.cwd(), io, dir_path.items);
    const root_body = "[{\"role\":\"user\",\"content\":\"export me\"}]";
    const root_path = try std.fmt.allocPrint(alloc, "{s}/rooty.json", .{dir_path.items});
    defer alloc.free(root_path);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = root_path, .data = root_body });

    const dl = try sessionLogDownload(io, alloc, cwd_abs, "rooty", true);
    try testing.expectEqualStrings("dsh-session-rooty.zip", dl.filename);
    try testing.expectEqualStrings("application/zip", dl.content_type);
    // Root content rides verbatim inside the archive.
    try testing.expect(std.mem.indexOf(u8, dl.body, root_body) != null);
    try testing.expectEqualStrings("PK\x03\x04", dl.body[0..4]);
}
