//! H-wasm self-test root (swarm wave 4, ground rule 7).
//!
//! Standalone runner for sandbox/wasm.zig + pluginabi/wasm_loader.zig. Kept
//! at TOP-LEVEL src/ so `..` imports stay inside the module path; the
//! integrator folds these tests into src/tests.zig and deletes this file.
//!
//! Run with:
//!   zig test -lc --dep cordis -Mroot=test/_t_wasm.zig -Mcordis=../zcordis/src/cordis.zig
//!
//! The fixtures below are HAND-ASSEMBLED wasm binaries implementing WASM ABI
//! v1 end-to-end (see pluginabi/wasm_loader.zig contract table): memory +
//! zh_abi_version + zh_manifest + zh_tool_call over a data-segment-backed
//! manifest/result region.

const std = @import("std");
const sandbox_wasm = @import("../src/sandbox/wasm.zig");
const wasm_loader = @import("../src/pluginabi/wasm_loader.zig");

test {
    // Pull in every inline test block of both owned modules too.
    _ = @import("../src/sandbox/wasm.zig");
    _ = @import("../src/pluginabi/wasm_loader.zig");
}

const wasm = sandbox_wasm.wasm;
const testing = std.testing;
// Global test I/O handle (std.Io); fixture methods take it as `io_h`
// because a parameter may not shadow this declaration.
const io = testing.io;

// ─────────────────────────────────────────────────────────────────────────
// Hand-assembled ABI v1 fixture modules
// ─────────────────────────────────────────────────────────────────────────

const MANIFEST_ADDR: u32 = 16;
const RESULT_ADDR: u32 = 512;

/// Tool-call behavior of the fixture module.
const ToolBehavior = enum {
    /// Return packed(RESULT_ADDR, result.len) — success JSON.
    succeed,
    /// Return 0 (len==0) — NULL-equivalent failure.
    fail,
};

/// Assemble a full WASM ABI v1 module.
///   manifest_json lives at MANIFEST_ADDR (data segment),
///   zh_abi_version returns `version`,
///   zh_manifest returns packed(MANIFEST_ADDR, len),
///   zh_tool_call ignores its inputs and behaves per `behavior`.
pub fn buildAbiModule(
    alloc: std.mem.Allocator,
    version: i64,
    behavior: ToolBehavior,
    manifest_json: []const u8,
    result_json: []const u8,
) ![]u8 {
    var b = wasm.Builder{ .alloc = alloc };
    errdefer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    try b.types(&.{
        .{ .params = &.{}, .returns = &.{0x7e} }, // 0: () -> i64
        .{ .params = &.{ 0x7e, 0x7e, 0x7e, 0x7e }, .returns = &.{0x7e} }, // 1: tool call
    });
    try b.functions(&.{ 0, 0, 1 });
    try b.memory(1);

    // Export section WITH the memory entry (kernel Builder can't emit it).
    var p = wasm.Builder{ .alloc = alloc };
    defer p.deinit();
    try p.uleb(4);
    try p.name(wasm_loader.EXP_MEMORY);
    try p.emitByte(0x02); // kind: memory
    try p.uleb(0);
    try p.name(wasm_loader.EXP_ABI_VERSION);
    try p.emitByte(0x00);
    try p.uleb(0);
    try p.name(wasm_loader.EXP_MANIFEST);
    try p.emitByte(0x00);
    try p.uleb(1);
    try p.name(wasm_loader.EXP_TOOL_CALL);
    try p.emitByte(0x00);
    try p.uleb(2);
    try b.section(7, p.buf.items);

    // Data segments: manifest + canned result.
    try b.data(&.{
        .{ .offset = MANIFEST_ADDR, .bytes = manifest_json },
        .{ .offset = RESULT_ADDR, .bytes = result_json },
    });

    // zh_abi_version: i64.const <version>
    const body_ver = try packedReturnBody(alloc, null, version, 0, "");
    defer alloc.free(body_ver);

    // zh_manifest: packed(MANIFEST_ADDR, manifest.len)
    const body_man = try packedReturnBody(alloc, MANIFEST_ADDR, @intCast(manifest_json.len), 0, "");
    defer alloc.free(body_man);

    // zh_tool_call: per behavior.
    var body_tool: []u8 = undefined;
    switch (behavior) {
        .succeed => body_tool = try packedReturnBody(alloc, RESULT_ADDR, @intCast(result_json.len), 0, ""),
        .fail => body_tool = try packedReturnBody(alloc, null, 0, 0, ""),
    }
    defer alloc.free(body_tool);

    try b.code(&.{ body_ver, body_man, body_tool });

    const owned = try alloc.dupe(u8, b.buf.items);
    b.deinit();
    return owned;
}

/// Emit `00 ... 42 <v> 0b` for plain returns (addr == null), or
/// `00 42 <ptr> 42 20 86 42 <len> 84 0b` for packed ptr<<32|len returns
/// (i64.shl = 0x86, i64.or = 0x84).
fn packedReturnBody(
    alloc: std.mem.Allocator,
    addr: ?u32,
    v2: i64,
    pad: u8,
    tail: []const u8,
) ![]u8 {
    _ = pad;
    _ = tail;
    var v = wasm.Builder{ .alloc = alloc };
    defer v.deinit();
    try v.emitByte(0x00); // no locals
    if (addr) |a| {
        // packed return: ptr << 32 | len
        try v.i64Const(@intCast(a));
        try v.i64Const(32);
        try v.op(0x86); // i64.shl
        try v.i64Const(v2);
        try v.op(0x84); // i64.or
    } else {
        try v.i64Const(v2);
    }
    try v.op(0x0b); // end
    return alloc.dupe(u8, v.buf.items);
}

/// Module whose zh_abi_version loops forever (budget-exhaustion fixture).
pub fn buildInfiniteLoopModule(alloc: std.mem.Allocator, manifest_json: []const u8) ![]u8 {
    var b = wasm.Builder{ .alloc = alloc };
    errdefer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // Type 0: () -> i64 (version + manifest); type 1: the 4×i64 tool call.
    try b.types(&.{
        .{ .params = &.{}, .returns = &.{0x7e} },
        .{ .params = &.{ 0x7e, 0x7e, 0x7e, 0x7e }, .returns = &.{0x7e} },
    });

    // Three defined functions — idx 0 = zh_abi_version (the loop),
    // idx 1 = zh_manifest, idx 2 = zh_tool_call (trivial but well-typed so
    // the loader's signature gate passes and the version call is reached).
    try b.functions(&.{ 0, 0, 1 });
    try b.memory(1);

    var p = wasm.Builder{ .alloc = alloc };
    defer p.deinit();
    try p.uleb(4);
    try p.name(wasm_loader.EXP_MEMORY);
    try p.emitByte(0x02); // kind: memory
    try p.uleb(0);
    try p.name(wasm_loader.EXP_ABI_VERSION);
    try p.emitByte(0x00);
    try p.uleb(0);
    try p.name(wasm_loader.EXP_MANIFEST);
    try p.emitByte(0x00);
    try p.uleb(1);
    try p.name(wasm_loader.EXP_TOOL_CALL);
    try p.emitByte(0x00);
    try p.uleb(2);
    try b.section(7, p.buf.items);

    try b.data(&.{.{ .offset = MANIFEST_ADDR, .bytes = manifest_json }});

    // zh_abi_version: block { loop { br 0 } } — burns budget forever.
    const body = [_]u8{ 0x00, 0x02, 0x40, 0x03, 0x40, 0x0c, 0x00, 0x0b, 0x0b, 0x42, 0x01, 0x0b };

    // zh_manifest: packed return (valid so earlier gates pass).
    var m = wasm.Builder{ .alloc = alloc };
    defer m.deinit();
    try m.emitByte(0x00);
    try m.i64Const(@intCast(MANIFEST_ADDR));
    try m.i64Const(32);
    try m.op(0x86);
    try m.i64Const(@intCast(manifest_json.len));
    try m.op(0x84);
    try m.op(0x0b);
    const man_body = try alloc.dupe(u8, m.buf.items);
    defer alloc.free(man_body);

    // zh_tool_call: well-typed stub (4 i64 params, returns 1). Never called
    // in these fixtures — the version call traps first.
    const tool_body = [_]u8{ 0x00, 0x42, 0x01, 0x0b };

    // code section: idx 0 = version loop/grow, idx 1 = manifest, idx 2 = tool.
    try b.code(&.{ &body, man_body, &tool_body });

    const owned = try alloc.dupe(u8, b.buf.items);
    b.deinit();
    return owned;
}

/// Module whose zh_abi_version grows linear memory past the sandbox cap.
pub fn buildGrowerModule(alloc: std.mem.Allocator, manifest_json: []const u8) ![]u8 {
    var b = wasm.Builder{ .alloc = alloc };
    errdefer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // Type 0: () -> i64 (version + manifest); type 1: the 4×i64 tool call.
    try b.types(&.{
        .{ .params = &.{}, .returns = &.{0x7e} },
        .{ .params = &.{ 0x7e, 0x7e, 0x7e, 0x7e }, .returns = &.{0x7e} },
    });
    // Three defined functions — idx 0 = zh_abi_version (grow), idx 1 =
    // zh_manifest, idx 2 = zh_tool_call (typed stub, never reached).
    try b.functions(&.{ 0, 0, 1 });
    try b.memory(1);

    var p = wasm.Builder{ .alloc = alloc };
    defer p.deinit();
    try p.uleb(4);
    try p.name(wasm_loader.EXP_MEMORY);
    try p.emitByte(0x02);
    try p.uleb(0);
    try p.name(wasm_loader.EXP_ABI_VERSION);
    try p.emitByte(0x00);
    try p.uleb(0);
    try p.name(wasm_loader.EXP_MANIFEST);
    try p.emitByte(0x00);
    try p.uleb(1);
    try p.name(wasm_loader.EXP_TOOL_CALL);
    try p.emitByte(0x00);
    try p.uleb(2);
    try b.section(7, p.buf.items);

    try b.data(&.{.{ .offset = MANIFEST_ADDR, .bytes = manifest_json }});

    // i32.const 299; memory.grow(reserved 0x00); drop; i64.const 1
    const body = [_]u8{ 0x00, 0x41, 0xab, 0x02, 0x40, 0x00, 0x1a, 0x42, 0x01, 0x0b };

    var m = wasm.Builder{ .alloc = alloc };
    defer m.deinit();
    try m.emitByte(0x00);
    try m.i64Const(@intCast(MANIFEST_ADDR));
    try m.i64Const(32);
    try m.op(0x86);
    try m.i64Const(@intCast(manifest_json.len));
    try m.op(0x84);
    try m.op(0x0b);
    const man_body = try alloc.dupe(u8, m.buf.items);
    defer alloc.free(man_body);

    const tool_body = [_]u8{ 0x00, 0x42, 0x01, 0x0b };

    try b.code(&.{ &body, man_body, &tool_body });

    const owned = try alloc.dupe(u8, b.buf.items);
    b.deinit();
    return owned;
}

// ── Fixture manifests ────────────────────────────────────────────────────

const demo_manifest =
    \\{"name":"demo","version":"1.0.0","kind":"tool","tools":[{"name":"ping","description":"Demo ping tool.","schema":{"type":"object"}}]}
;
const dud_manifest =
    \\{"name":"dud","version":"0.2.0","kind":"tool","tools":[{"name":"fizzle","description":"Always fails.","schema":{"type":"object"}}]}
;

const demo_result = "{\"pong\":\"demo\"}";

// ── tmpdir helper (dlopen-free; loader reads real files) ────────────────

const FixtureDir = struct {
    tmp: testing.TmpDir,
    dir_path: []u8,

    fn create(alloc: std.mem.Allocator) !FixtureDir {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        // TmpDir lives under <cwd>/.zig-cache/tmp/<sub>; rebuild that path
        // (same trick as pluginabi/loader.zig tests).
        const dir_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer alloc.free(dir_path);
        return .{ .tmp = tmp, .dir_path = dir_path };
    }

    fn write(self: *const FixtureDir, io_h: std.Io, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(io_h, .{ .sub_path = name, .data = data });
    }

    fn pathFor(self: *const FixtureDir, alloc: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fs.path.join(alloc, &.{ self.dir_path, name });
    }

    fn cleanup(self: *FixtureDir, alloc: std.mem.Allocator) void {
        self.tmp.cleanup();
        alloc.free(self.dir_path);
    }
};

fn reportContains(reg: *wasm_loader.WasmRegistry, needle: []const u8) bool {
    for (reg.report.items) |e| {
        if (std.mem.indexOf(u8, e.reason, needle) != null) return true;
    }
    return false;
}

// ─────────────────────────────────────────────────────────────────────────
// End-to-end tests
// ─────────────────────────────────────────────────────────────────────────

test "happy round-trip: load demo module, list tool, execute via scratch window" {
    const alloc = testing.allocator;
    const module_bytes = try buildAbiModule(alloc, 1, .succeed, demo_manifest, demo_result);
    defer alloc.free(module_bytes);

    var fx = try FixtureDir.create(alloc);
    defer fx.cleanup(alloc);
    try fx.write(io, "demo.wasm", module_bytes);
    const full = try fx.pathFor(alloc, "demo.wasm");
    defer alloc.free(full);

    var reg = wasm_loader.WasmRegistry.init(alloc);
    defer reg.deinit();
    reg.loadPath(io, full);

    // Loaded cleanly: one plugin, one projected tool, empty report.
    try testing.expectEqual(@as(usize, 1), reg.plugins.items.len);
    try testing.expectEqual(@as(usize, 1), reg.tools.items.len);
    try testing.expectEqual(@as(usize, 0), reg.report.items.len);
    try testing.expect(reg.findTool("w_demo_ping") != null);

    // Registry-definition view is wired correctly.
    const defs = try reg.definitions(alloc);
    defer alloc.free(defs);
    try testing.expectEqualStrings("w_demo_ping", defs[0].name);
    try testing.expectEqualStrings("Demo ping tool.", defs[0].description);
    try testing.expectEqualStrings("{\"type\":\"object\"}", defs[0].parameters_json);

    // Execute: host places name+args into guest scratch, guest returns
    // packed(ptr,len), host copies the JSON back out.
    const outcome = (try reg.execute(alloc, "w_demo_ping", "{\"x\":1}")).?;
    defer alloc.free(outcome.output);
    try testing.expect(outcome.ok);
    try testing.expectEqualStrings(demo_result, outcome.output);

    // Repeated calls reuse the SAME scratch window (memory must not grow).
    const vm = reg.plugins.items[0].vm;
    const mem_len_before = vm.memory().len;
    for (0..5) |_| {
        const o = (try reg.execute(alloc, "w_demo_ping", "{}")).?;
        alloc.free(o.output);
    }
    try testing.expectEqual(mem_len_before, vm.memory().len);

    // Empty args arrive as "{}" (contract) — still succeeds here.
    const o2 = (try reg.execute(alloc, "w_demo_ping", "")).?;
    defer alloc.free(o2.output);
    try testing.expect(o2.ok);

    // Unknown tool → clean null.
    try testing.expect((try reg.execute(alloc, "nope", "{}")) == null);
}

test "multi-plugin registry incl. failure-signalling module" {
    const alloc = testing.allocator;
    const demo_bytes = try buildAbiModule(alloc, 1, .succeed, demo_manifest, demo_result);
    defer alloc.free(demo_bytes);
    const dud_bytes = try buildAbiModule(alloc, 1, .fail, dud_manifest, "");
    defer alloc.free(dud_bytes);

    var fx = try FixtureDir.create(alloc);
    defer fx.cleanup(alloc);
    try fx.write(io, "a_demo.wasm", demo_bytes);
    try fx.write(io, "b_dud.wasm", dud_bytes);

    var reg = wasm_loader.WasmRegistry.init(alloc);
    defer reg.deinit();
    const loaded = reg.loadDir(io, fx.dir_path);
    try testing.expectEqual(@as(usize, 2), loaded);
    try testing.expectEqual(@as(usize, 0), reg.report.items.len);

    // Successing module still fine next to the failing one.
    const ok_out = (try reg.execute(alloc, "w_demo_ping", "{}")).?;
    defer alloc.free(ok_out.output);
    try testing.expect(ok_out.ok);

    // Failure-signalling module: len==0 becomes ok=false + message.
    const bad_out = (try reg.execute(alloc, "w_dud_fizzle", "{}")).?;
    defer alloc.free(bad_out.output);
    try testing.expect(!bad_out.ok);
    try testing.expect(std.mem.indexOf(u8, bad_out.output, "reported failure") != null);
}

test "wrong abi version is rejected with a report entry" {
    const alloc = testing.allocator;
    const bytes = try buildAbiModule(alloc, 2, .succeed, demo_manifest, demo_result);
    defer alloc.free(bytes);

    var fx = try FixtureDir.create(alloc);
    defer fx.cleanup(alloc);
    try fx.write(io, "future.wasm", bytes);
    const full = try fx.pathFor(alloc, "future.wasm");
    defer alloc.free(full);

    var reg = wasm_loader.WasmRegistry.init(alloc);
    defer reg.deinit();
    reg.loadPath(io, full);

    try testing.expectEqual(@as(usize, 0), reg.plugins.items.len);
    try testing.expectEqual(@as(usize, 1), reg.report.items.len);
    try testing.expect(reportContains(&reg, "ABI version 2 unsupported"));
}

test "truncated and junk modules are skipped with reasons, never crash" {
    const alloc = testing.allocator;
    const full_bytes = try buildAbiModule(alloc, 1, .succeed, demo_manifest, demo_result);
    defer alloc.free(full_bytes);

    var fx = try FixtureDir.create(alloc);
    defer fx.cleanup(alloc);
    try fx.write(io, "trunc.wasm", full_bytes[0 .. full_bytes.len - 12]);
    try fx.write(io, "junk.wasm", "definitely not wasm \xff\xfe");
    try fx.write(io, "notes.txt", "wrong suffix");

    var reg = wasm_loader.WasmRegistry.init(alloc);
    defer reg.deinit();
    const loaded = reg.loadDir(io, fx.dir_path);
    try testing.expectEqual(@as(usize, 0), loaded);
    try testing.expectEqual(@as(usize, 3), reg.report.items.len);
    try testing.expect(reportContains(&reg, "malformed or truncated"));
    try testing.expect(reportContains(&reg, "missing required 'memory' export") or
        reportContains(&reg, "malformed or truncated"));
    try testing.expect(reportContains(&reg, "not a wasm module"));

    // Registry stays fully usable after all the skips.
    try testing.expect((try reg.execute(alloc, "anything", "{}")) == null);
}

test "step-budget exhaustion during load is reported cleanly" {
    const alloc = testing.allocator;
    const bytes = try buildInfiniteLoopModule(alloc, demo_manifest);
    defer alloc.free(bytes);

    var fx = try FixtureDir.create(alloc);
    defer fx.cleanup(alloc);
    try fx.write(io, "spinner.wasm", bytes);
    const full = try fx.pathFor(alloc, "spinner.wasm");
    defer alloc.free(full);

    var reg = wasm_loader.WasmRegistry.init(alloc);
    defer reg.deinit();
    reg.limits.step_budget = 1000; // tight fuel for the test
    reg.loadPath(io, full);

    try testing.expectEqual(@as(usize, 0), reg.plugins.items.len);
    try testing.expect(reportContains(&reg, "exceeded step budget"));
}

test "oversized memory.grow during load is rejected by the sandbox cap" {
    const alloc = testing.allocator;
    const bytes = try buildGrowerModule(alloc, demo_manifest);
    defer alloc.free(bytes);

    var fx = try FixtureDir.create(alloc);
    defer fx.cleanup(alloc);
    try fx.write(io, "grower.wasm", bytes);
    const full = try fx.pathFor(alloc, "grower.wasm");
    defer alloc.free(full);

    var reg = wasm_loader.WasmRegistry.init(alloc);
    defer reg.deinit();
    reg.loadPath(io, full);

    try testing.expectEqual(@as(usize, 0), reg.plugins.items.len);
    try testing.expect(reportContains(&reg, "'zh_abi_version' hit the memory cap"));
}

test "duplicate host tools collide into the w_ namespace safely" {
    const alloc = testing.allocator;
    const bytes = try buildAbiModule(alloc, 1, .succeed, demo_manifest, demo_result);
    defer alloc.free(bytes);

    var fx = try FixtureDir.create(alloc);
    defer fx.cleanup(alloc);
    try fx.write(io, "one.wasm", bytes);
    try fx.write(io, "two.wasm", bytes); // same module name → same host names

    var reg = wasm_loader.WasmRegistry.init(alloc);
    defer reg.deinit();
    _ = reg.loadDir(io, fx.dir_path);

    // First copy owns the name; second reports duplicates then "no usable".
    try testing.expectEqual(@as(usize, 1), reg.plugins.items.len);
    try testing.expectEqual(@as(usize, 1), reg.tools.items.len);
    try testing.expect(reportContains(&reg, "duplicate host tool 'w_demo_ping' ignored"));

    // The surviving instance still executes correctly.
    const out = (try reg.execute(alloc, "w_demo_ping", "{}")).?;
    defer alloc.free(out.output);
    try testing.expect(out.ok);
}
