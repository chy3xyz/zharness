//! Fuzz suite: session/checkpoint.zig + session/session.zig LOAD paths fed
//! corrupt on-disk files (SWARM wave-4, agent J-fuzz).
//!
//! Surface under test:
//! - CheckpointStore.load / list against mutated snapshot JSON documents.
//! - Session.load against mutated transcript arrays.
//!
//! Property: for ANY file content the loaders either return a cleanly-owned
//! value or a clean error — never a panic and never a leak (every case runs
//! under std.testing.allocator, which fails the suite on any leak). Files
//! are written into one per-test temp dir; no fixture outside /tmp is
//! touched and everything is removed afterwards.
//!
//! Corpus: src/fuzz/corpus/checkpoint_files.txt (one seed document between
//! %%%% separators), embedded at compile time.

const std = @import("std");
const mutator = @import("mutator.zig");
const checkpoint = @import("../session/checkpoint.zig");
const session_mod = @import("../session/session.zig");

const corpus_raw = @embedFile("corpus/checkpoint_files.txt");

// Deterministic per-suite seeds.
const seed_checkpoint = 0xC401;
const seed_session = 0x5E55;

/// Seconds since epoch via libc (same pattern as session/checkpoint.zig).
extern "c" fn time(tloc: ?*c_long) c_long;

var env_counter: u32 = 0;

/// Unique scratch directory torn down wholesale (mirrors checkpoint.TestEnv).
const TempEnv = struct {
    t: std.Io.Threaded,
    dir: []u8,

    fn setup(alloc: std.mem.Allocator) !TempEnv {
        env_counter += 1;
        var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
        const dir = try std.fmt.allocPrint(alloc, "/tmp/zh_fuzz_{d}_{d}", .{ time(null), env_counter });
        errdefer alloc.free(dir);
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), t.io(), dir);
        return .{ .t = t, .dir = dir };
    }

    fn io(self: *TempEnv) std.Io {
        return self.t.io();
    }

    fn teardown(self: *TempEnv, alloc: std.mem.Allocator) void {
        defer self.t.deinit();
        const slash = std.mem.lastIndexOfScalar(u8, self.dir, '/') orelse {
            alloc.free(self.dir);
            return;
        };
        const cwd = std.Io.Dir.cwd();
        if (std.Io.Dir.openDir(cwd, self.io(), self.dir[0..slash], .{})) |parent| {
            defer std.Io.Dir.close(parent, self.io());
            std.Io.Dir.deleteTree(parent, self.io(), self.dir[slash + 1 ..]) catch {};
        } else |_| {}
        alloc.free(self.dir);
    }
};

/// Write `data` as `<env.dir>/<name>`; `name` must be ≤ 32 bytes.
fn writeCase(env: *TempEnv, name: []const u8, data: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ env.dir, name });
    try std.Io.Dir.cwd().writeFile(env.io(), .{ .sub_path = full, .data = data });
}

/// One corrupted-checkpoint case: store.load must yield a Checkpoint that
/// deinits cleanly OR MalformedCheckpoint/NotFound — never panic, never leak.
fn fuzzCheckpointLoad(env: *TempEnv, alloc: std.mem.Allocator, id: u32, data: []const u8) !void {
    var nb: [32]u8 = undefined;
    const fname = try std.fmt.bufPrint(&nb, "{d:0>6}.json", .{id});
    try writeCase(env, fname, data);

    var store = try checkpoint.CheckpointStore.init(alloc, env.dir);
    defer store.deinit();

    if (store.load(env.io(), alloc, id)) |cp| {
        var owned = cp;
        // Structural sanity on whatever parsed: label/messages owned.
        try std.testing.expect(owned.messages.len <= data.len); // ≥1 byte per message minimum bound is loose but safe
        owned.deinit(alloc);
    } else |e| switch (e) {
        error.MalformedCheckpoint => {}, // clean rejection: the property holds
        error.CheckpointNotFound => {}, // unreachable here, still clean
        else => |others| return others,
    }
}

/// Corrupt-transcript case for Session.load: appends messages or errors; the
/// session must stay fully deinit-able either way.
fn fuzzSessionLoad(env: *TempEnv, alloc: std.mem.Allocator, tag: usize, data: []const u8) !void {
    var nb: [64]u8 = undefined;
    const fname = try std.fmt.bufPrint(&nb, "sess_{d}.json", .{tag});
    try writeCase(env, fname, data);

    var s = try session_mod.Session.init(alloc, "fuzz");
    defer s.deinit();

    var nb2: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&nb2, "{s}/{s}", .{ env.dir, fname });
    s.load(env.io(), full) catch {}; // any error is clean; FileNotFound == empty

    // Whatever loaded, the transcript must be internally consistent.
    for (s.messages.items) |m| {
        try std.testing.expect(m.content.len <= data.len + 1);
    }
    s.clear(); // exercise the free path explicitly too
}

test "fuzz: checkpoint loads over corpus seeds" {
    const alloc = std.testing.allocator;
    var env = try TempEnv.setup(alloc);
    defer env.teardown(alloc);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var id: u32 = 1;
    var it = mutator.SeedIter.init(corpus_raw);
    while (it.next()) |seed| : (id += 1) {
        try fuzzCheckpointLoad(&env, alloc, id, seed);
    }

    // Structured mutations over every seed.
    var rnd = mutator.Rnd.init(seed_checkpoint);
    var round: usize = 0;
    const rounds = 12;
    while (round < rounds) : (round += 1) {
        var sit = mutator.SeedIter.init(corpus_raw);
        while (sit.next()) |seed| : (id += 1) {
            try mutator.mutate(alloc, &out, &rnd, seed);
            try fuzzCheckpointLoad(&env, alloc, id, out.items);
        }
    }
    try std.testing.expect(id > 1); // corpus non-empty guard
}

test "regression: bad role mid-array must not leak tool fields" {
    // Found by this suite pre-fix: when Role.fromStr failed on a later array
    // element, the early return leaked the CURRENT message's tool_call_id /
    // tool_calls_json allocations AND every previously appended message's
    // strings (the errdefer only freed the list storage itself).
    const alloc = std.testing.allocator;
    var env = try TempEnv.setup(alloc);
    defer env.teardown(alloc);

    const poison =
        \\{"id":7,"label":"l","created_at":5,"messages":[
        \\ {"role":"user","content":"good","tool_call_id":"t1","tool_calls_json":"[]"},
        \\ {"role":"boss","content":"bad","tool_call_id":"t2","tool_calls_json":"{}"}
        \\]}
    ;
    try fuzzCheckpointLoad(&env, alloc, 42, poison); // expects MalformedCheckpoint, zero leaks
}

test "regression: unterminated escapes and null optionals load clean" {
    const alloc = std.testing.allocator;
    var env = try TempEnv.setup(alloc);
    defer env.teardown(alloc);

    try fuzzCheckpointLoad(&env, alloc, 43,
        \\{"id":1,"label":"x","created_at":0,"messages":[{"role":"user","content":"back\\
    );
    try fuzzCheckpointLoad(&env, alloc, 44,
        \\{"id":2,"label":"y","created_at":9223372036854775807,"messages":[]}
    );
    try fuzzCheckpointLoad(&env, alloc, 45,
        \\{"id":3,"label":"z","created_at":1,"messages":[{"role":"assistant","content":"a","tool_call_id":null}]}
    );
}

test "fuzz: session load over corpus seeds" {
    const alloc = std.testing.allocator;
    var env = try TempEnv.setup(alloc);
    defer env.teardown(alloc);

    const session_corpus =
        \\[{"role":"user","content":"q"},{"role":"assistant","content":"a","tool_calls_json":"[{\"id\":\"1\"}]"}]
        \\%%%%
        \\[{"role":"tool","content":"r","tool_call_id":"1"},{"role":"weird","content":"?"}]
        \\%%%%
        \\[{"role":"system","content":"esc \" q \n nl"},{"role":"user","content":"trailing back\\"}]
        \\%%%%
        \\[{"no_role_here":true},{"role":"user"}
    ;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var rnd = mutator.Rnd.init(seed_session);
    var tag: usize = 1;

    var it = mutator.SeedIter.init(session_corpus);
    while (it.next()) |seed| : (tag += 1) {
        try fuzzSessionLoad(&env, alloc, tag, seed);
    }

    var round: usize = 0;
    while (round < 10) : (round += 1) {
        var sit = mutator.SeedIter.init(session_corpus);
        while (sit.next()) |seed| : (tag += 1) {
            try mutator.mutate(alloc, &out, &rnd, seed);
            try fuzzSessionLoad(&env, alloc, tag, out.items);
        }
    }
    try std.testing.expect(tag > 1);
}
