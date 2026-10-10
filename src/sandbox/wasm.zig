//! WASM sandbox — hardening wrapper around the zcordis wasm interpreter
//! (dev.md §XII, swarm wave 4 / H-wasm).
//!
//! The kernel (`cordis.wasm`, i.e. ../zcordis/src/abi/wasm.zig) already
//! bounds-checks every memory access and traps cleanly on bad opcodes. This
//! module adds the policy layer an untrusted plugin host needs on top:
//!
//!   ┌──────────────────────┬──────────────────────────────────────────────┐
//!   │ Control              │ Mechanism                                    │
//!   ├──────────────────────┼──────────────────────────────────────────────┤
//!   │ Compute fuel         │ Per-instance step budget (`setStepBudget`).  │
//!   │                      │ Every executed instruction costs one step;   │
//!   │                      │ exhaustion yields error.ExecutionLimit.      │
//!   │                      │ Default 10M steps.                           │
//!   ├──────────────────────┼──────────────────────────────────────────────┤
//!   │ Linear-memory cap    │ `limits.max_memory_pages` checked at load    │
//!   │                      │ time (memory-section min) AND at runtime via │
//!   │                      │ a byte-capped allocator wrapping every       │
//!   │                      │ instance allocation — so `memory.grow` (and  │
//!   │                      │ runaway frame/local growth) hits a hard      │
//!   │                      │ ceiling far below the kernel's 4 GiB max.    │
//!   ├──────────────────────┼──────────────────────────────────────────────┤
//!   │ Import allowlist     │ Modules requesting ANY import outside        │
//!   │                      │ `policy.allowed_fns` are rejected before     │
//!   │                      │ instantiation. Table/global imports are      │
//!   │                      │ always denied under ABI v1 (plugins need     │
//!   │                      │ none). Default policy: deny everything.      │
//!   ├──────────────────────┼──────────────────────────────────────────────┤
//!   │ Malformed input      │ Truncated/corrupt/unsupported binaries map   │
//!   │                      │ onto small closed error sets                 │
//!   │                      │ (LoadError / CallError) — never a crash,     │
//!   │                      │ never a leak.                                │
//!   └──────────────────────┴──────────────────────────────────────────────┘
//!
//! Ownership: `WasmVm.load` DUPLICATES the module bytes (the kernel borrows
//! slices of them for import names) and owns Module + Instance; `deinit`
//! releases everything in reverse order and is safe to call after any failed
//! call (kernel errors unwind without corrupting instance state).
//!
//! Decoupling: plain params only (allocator + bytes + Limits/Policy); the
//! loader (pluginabi/wasm_loader.zig) supplies ABI policy, main.zig wires it.

const std = @import("std");
pub const wasm = @import("cordis").wasm;

// ─────────────────────────────────────────────────────────────────────────
// Policy knobs
// ─────────────────────────────────────────────────────────────────────────

/// Default compute fuel: 10M instructions per instance.
pub const default_step_budget: usize = 10_000_000;
/// Default linear-memory ceiling: 256 pages = 16 MiB.
pub const default_max_memory_pages: u32 = 256;
/// Default recursion ceiling (call frames per instance). Tighter than the
/// zcordis default of 1024.
pub const default_max_call_depth: usize = 256;
/// Default on-disk module size cap: 8 MiB.
pub const default_max_module_bytes: usize = 8 * 1024 * 1024;
/// Headroom added ON TOP of `max_memory_pages * page_size` for interpreter
/// structures (operand stack, frames, locals, table). Without it a guest
/// could consume its entire legal allocation with linear memory and starve
/// the VM interpreter itself.
const interpreter_overhead_bytes: usize = 1024 * 1024;

pub const Limits = struct {
    /// Total instructions across ALL calls made on one instance.
    step_budget: usize = default_step_budget,
    /// Hard ceiling for linear memory (declared min pages must fit; runtime
    /// growth stops here too).
    max_memory_pages: u32 = default_max_memory_pages,
    /// Recursion ceiling: calls deeper than this trap instead of growing the
    /// frame stack without bound (kernel `setMaxCallDepth`, zcordis v0.2.0).
    max_call_depth: usize = default_max_call_depth,
    /// Refuse modules larger than this before parsing.
    max_module_bytes: usize = default_max_module_bytes,
};

pub const ImportPolicy = struct {
    /// One permitted function import ("module"."name").
    pub const AllowedFn = struct { module: []const u8, name: []const u8 };

    /// Exact set of function imports a module may request. Empty (default)
    /// denies ALL imports — ABI v1 plugins are pure computation over their
    /// arguments and linear memory.
    allowed_fns: []const AllowedFn = &.{},
};

pub const default_limits: Limits = .{};
pub const default_policy: ImportPolicy = .{};

// ─────────────────────────────────────────────────────────────────────────
// Closed error sets (the whole point: malformed input never crashes)
// ─────────────────────────────────────────────────────────────────────────

pub const LoadError = error{
    /// Truncated, corrupt, or unsupported feature — mapped from every kernel
    /// parse/instantiation error so callers handle ONE name.
    MalformedModule,
    /// Byte size exceeds limits.max_module_bytes.
    ModuleTooLarge,
    /// Memory section declares more pages than limits.max_memory_pages.
    MemoryTooLarge,
    /// Requests imports outside the allowlist.
    ImportDenied,
    /// The start function burned the whole step budget while instantiating.
    ExecutionLimit,
    /// The start function recursed past limits.max_call_depth.
    CallDepthExceeded,
    OutOfMemory,
};

pub const CallError = error{
    /// Step budget exhausted (fuel model).
    ExecutionLimit,
    /// Recursion past limits.max_call_depth.
    CallDepthExceeded,
    /// Guest bug: trap, stack underflow, div-by-zero, bad opcode, indirect
    /// call type mismatch … folded into one name — guest faults are data,
    /// not crashes.
    GuestTrap,
    /// Linear-memory fault: access past the end OR growth refused by the
    /// memory cap (the kernel maps capped-allocator OOM → MemoryOutOfBounds;
    /// we re-map to the sandbox-meaningful name).
    MemoryFault,
    UnknownExport,
    ArityMismatch,
    OutOfMemory,
};

// ─────────────────────────────────────────────────────────────────────────
// Byte-capped allocator
// ─────────────────────────────────────────────────────────────────────────

/// Proxy allocator enforcing a total-outstanding-bytes ceiling. The wasm
/// Instance allocates EVERYTHING through it (linear memory, operand stack,
/// frames, locals), so one counter caps guest-driven allocation of every
/// kind. Thread-safety: instances are single-threaded (agent loop thread),
/// matching the plugin ABI contract in pluginabi/capi.zig.
const CappedAllocator = struct {
    parent: std.mem.Allocator,
    cap: usize,
    outstanding: usize = 0,

    fn iface(self: *CappedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = cAlloc,
        .resize = cResize,
        .remap = cRemap,
        .free = cFree,
    };

    fn cAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (len > self.cap -| self.outstanding) return null;
        const p = self.parent.rawAlloc(len, alignment, ret_addr);
        if (p != null) self.outstanding += len;
        return p;
    }

    fn cResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len <= memory.len) {
            // Shrinks always fit the ceiling.
            if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
            self.outstanding -= memory.len - new_len;
            return true;
        }
        const delta = new_len - memory.len;
        if (delta > self.cap -| self.outstanding) return false;
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.outstanding += delta;
        return true;
    }

    fn cRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and new_len - memory.len > self.cap -| self.outstanding) return null;
        const p = self.parent.rawRemap(memory, alignment, new_len, ret_addr);
        if (p != null) {
            if (new_len >= memory.len) {
                self.outstanding += new_len - memory.len;
            } else {
                self.outstanding -= memory.len - new_len;
            }
        }
        return p;
    }

    fn cFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        self.outstanding -= memory.len;
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};

// ─────────────────────────────────────────────────────────────────────────
// WasmVm — loaded module + hardened instance
// ─────────────────────────────────────────────────────────────────────────

pub const WasmVm = struct {
    alloc: std.mem.Allocator,
    limits: Limits,
    /// Duplicated module bytes — the kernel's Module borrows slices of this
    /// buffer (import names, code bodies), so it outlives module+instance.
    bytes: []u8,
    /// Heap-anchored: Instance stores a `*const Module`, so the Module must
    /// not live inside a movable struct.
    module: *wasm.Module,
    inst: *wasm.Instance,
    /// Heap-anchored so `inst.alloc.ptr` stays valid for the VM's lifetime.
    capped: *CappedAllocator,

    /// Parse, validate against limits/policy, and instantiate. Any start
    /// function runs UNDER the configured budget (a hostile start function
    /// cannot hang or balloon the load).
    pub fn load(
        alloc: std.mem.Allocator,
        module_bytes: []const u8,
        limits: Limits,
        policy: ImportPolicy,
    ) LoadError!*WasmVm {
        if (module_bytes.len > limits.max_module_bytes) return error.ModuleTooLarge;

        const capped = try alloc.create(CappedAllocator);
        errdefer alloc.destroy(capped);
        capped.* = .{
            .parent = alloc,
            // One ceiling for linear memory + interpreter structures.
            .cap = @as(usize, limits.max_memory_pages) * wasm.page_size + interpreter_overhead_bytes,
        };

        const bytes = try alloc.dupe(u8, module_bytes);
        errdefer alloc.free(bytes);

        const module = try alloc.create(wasm.Module);
        errdefer alloc.destroy(module);
        // NOTE: on parse failure the kernel has already released any partial
        // state; the shell here was never assigned, so ONLY destroy it.
        module.* = wasm.Module.load(alloc, bytes) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedModule,
        };
        // Armed only after a successful load — deinit requires valid contents.
        errdefer module.deinit();

        if (module.memory_min > limits.max_memory_pages) return error.MemoryTooLarge;

        // Import gate: functions only, and only from the explicit allowlist;
        // table/global imports are never linkable under ABI v1.
        for (module.imports.items) |imp| {
            var ok = false;
            for (policy.allowed_fns) |allow| {
                if (std.mem.eql(u8, imp.module, allow.module) and std.mem.eql(u8, imp.name, allow.name)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) return error.ImportDenied;
        }
        if (module.table_imports.items.len > 0) return error.ImportDenied;
        if (module.global_imports.items.len > 0) return error.ImportDenied;

        const inst = wasm.Instance.create(
            capped.iface(),
            module,
            null, // host_ctx — unused under the default (empty) allowlist
            &.{}, // host_fns — must match allowed_fns if policy grants any
            wasm.no_globals,
        ) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ExecutionLimit => return error.ExecutionLimit, // start fn burned the budget
            error.CallDepthExceeded => return error.CallDepthExceeded, // start fn recursed too deep
            else => return error.MalformedModule, // start fn trapped / bad link
        };
        errdefer inst.deinit();
        inst.setStepBudget(limits.step_budget);
        inst.setMaxCallDepth(limits.max_call_depth);

        const self = try alloc.create(WasmVm);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .limits = limits,
            .bytes = bytes,
            .module = module,
            .inst = inst,
            .capped = capped,
        };
        return self;
    }

    pub fn deinit(self: *WasmVm) void {
        self.inst.deinit();
        self.module.deinit();
        self.alloc.destroy(self.module);
        self.alloc.free(self.bytes);
        const alloc = self.alloc;
        alloc.destroy(self.capped);
        alloc.destroy(self);
    }

    /// Call an exported function. Kernel errors fold onto CallError so hosts
    /// handle a closed set; a failed call leaves the instance reusable (the
    /// kernel unwinds its own frames).
    pub fn call(self: *WasmVm, name: []const u8, args: []const i64) CallError!i64 {
        return self.inst.callExport(name, args) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.ExecutionLimit => error.ExecutionLimit,
            error.CallDepthExceeded => error.CallDepthExceeded,
            error.MemoryOutOfBounds => error.MemoryFault,
            error.UnknownExport => error.UnknownExport,
            error.NotAFunction => error.UnknownExport,
            error.ArityMismatch => error.ArityMismatch,
            else => error.GuestTrap,
        };
    }

    /// Current linear memory (read side).
    pub fn memory(self: *WasmVm) []const u8 {
        return self.inst.memory.items;
    }

    /// Mutable linear memory view — the ABI host writes call inputs into
    /// guest space here (see pluginabi/wasm_loader.zig).
    pub fn memoryMut(self: *WasmVm) []u8 {
        return self.inst.memory.items;
    }

    /// Append `n` zero bytes of scratch to linear memory and return the byte
    /// offset of the new region (where the host places call inputs). Doubly
    /// enforced: explicit page-cap check, then the capped allocator backstop.
    pub fn growScratch(self: *WasmVm, n: usize) CallError!u32 {
        const old_len = self.inst.memory.items.len;
        const mem_cap = @as(usize, self.limits.max_memory_pages) * wasm.page_size;
        if (old_len + n > mem_cap) return error.MemoryFault;
        self.inst.memory.appendNTimes(self.inst.alloc, 0, n) catch return error.MemoryFault;
        return @intCast(old_len);
    }

    /// Steps remaining before the fuel light comes on (diagnostics/tests).
    pub fn remainingSteps(self: *const WasmVm) usize {
        return self.inst.step_budget;
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Tests (small fixtures; full ABI round-trips live in test/_t_wasm.zig)
// ─────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Minimal valid module exporting `run: () -> ()` with the given body.
fn buildTinyModule(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    var b = wasm.Builder{ .alloc = alloc };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    try b.code(&.{body});
    return alloc.dupe(u8, b.buf.items);
}

test "CappedAllocator enforces ceiling and keeps accounting clean" {
    const alloc = testing.allocator;
    var capped = CappedAllocator{ .parent = alloc, .cap = 64 };
    const a = capped.iface();

    const p1 = try a.alloc(u8, 32);
    try testing.expectEqual(@as(usize, 32), capped.outstanding);

    // Over-ceiling allocation refused (only 32 bytes of headroom left).
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 33));

    // In-place growth within ceiling works; beyond fails. A successful
    // resize obliges the CALLER to adopt the new length.
    try testing.expect(a.resize(p1, 48));
    try testing.expect(!a.resize(p1, 100));

    const p2 = try a.alloc(u8, 16);
    try testing.expectEqual(@as(usize, 64), capped.outstanding);

    a.free(p2);
    // Keep the bound opaque to comptime so free() receives []u8, not *[48]u8.
    const grown_len: usize = p1.len + 16; // runtime value: 48
    a.free(p1.ptr[0..grown_len]);
    try testing.expectEqual(@as(usize, 0), capped.outstanding);
}

test "truncated module maps onto LoadError.MalformedModule" {
    const alloc = testing.allocator;
    const full = try buildTinyModule(alloc, &.{ 0x00, 0x0b }); // nop, end
    defer alloc.free(full);
    // Kernel sanity: raw load of truncated bytes fails too.
    try testing.expect(wasm.Module.load(alloc, full[0 .. full.len - 4]) == error.TrailingData);
    try testing.expectError(error.MalformedModule, WasmVm.load(alloc, full[0 .. full.len - 4], default_limits, default_policy));
}

test "oversized module rejected by size limit" {
    const alloc = testing.allocator;
    const junk = try alloc.alloc(u8, 300_000);
    defer alloc.free(junk);
    @memset(junk, 0);
    var lim = default_limits;
    lim.max_module_bytes = 128 * 1024;
    try testing.expectError(error.ModuleTooLarge, WasmVm.load(alloc, junk, lim, default_policy));
}

test "import request outside allowlist is denied; listed import links" {
    const alloc = testing.allocator;
    var b = wasm.Builder{ .alloc = alloc };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // Type 0: the (denied-by-default) import signature; type 1: () -> i32.
    try b.types(&.{
        .{ .params = &.{0x7f}, .returns = &.{0x7f} },
        .{ .params = &.{}, .returns = &.{0x7f} },
    });
    try b.imports(&.{.{ .module = "env", .name = "sneaky", .type_idx = 0 }}, &.{});
    try b.functions(&.{1}); // defined func idx 1 has type 1
    try b.exports(&.{.{ .name = "answer", .index = 1 }});
    // Defined function: plain i32.const 42.
    const body = [_]u8{ 0x00, 0x41, 0x2a, 0x0b };
    try b.code(&.{&body});

    try testing.expectError(error.ImportDenied, WasmVm.load(alloc, b.buf.items, default_limits, default_policy));

    // With the exact import allowlisted, instantiation succeeds and the
    // defined function still runs (the import is never called here).
    var pol = ImportPolicy{};
    pol.allowed_fns = &.{.{ .module = "env", .name = "sneaky" }};
    var vm = try WasmVm.load(alloc, b.buf.items, default_limits, pol);
    defer vm.deinit();
    try testing.expectEqual(@as(i64, 42), try vm.call("answer", &.{}));
}

test "table/global imports are always denied" {
    const alloc = testing.allocator;
    var b = wasm.Builder{ .alloc = alloc };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{});
    try b.imports(
        &.{},
        &.{.{ .module = "env", .name = "g", .valtype = 0x7f, .mutable = false }},
    );
    try b.functions(&.{});
    try b.code(&.{});
    try testing.expectError(error.ImportDenied, WasmVm.load(alloc, b.buf.items, default_limits, default_policy));
}

test "memory_min above page cap is MemoryTooLarge" {
    const alloc = testing.allocator;
    var b = wasm.Builder{ .alloc = alloc };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{});
    try b.functions(&.{});
    try b.exports(&.{});
    try b.memory(1000); // ~65 MiB > default 256-page cap
    try b.code(&.{});
    try testing.expectError(error.MemoryTooLarge, WasmVm.load(alloc, b.buf.items, default_limits, default_policy));
}

test "step budget exhaustion surfaces as error.ExecutionLimit" {
    const alloc = testing.allocator;
    // Infinite loop: block { loop { br 0 } }
    const body = [_]u8{ 0x00, 0x02, 0x40, 0x03, 0x40, 0x0c, 0x00, 0x0b, 0x0b, 0x0b };
    const bytes = try buildTinyModule(alloc, &body);
    defer alloc.free(bytes);
    var lim = default_limits;
    lim.step_budget = 1000;
    var vm = try WasmVm.load(alloc, bytes, lim, default_policy);
    defer vm.deinit();
    try testing.expectError(error.ExecutionLimit, vm.call("run", &.{}));
}

test "runtime memory growth beyond the sandbox page cap is MemoryFault" {
    const alloc = testing.allocator;
    var b = wasm.Builder{ .alloc = alloc };
    defer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.memory(1); // declared min legal under the cap…
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    // …but i32.const 299, memory.grow, drop requests 300 pages (~19 MiB),
    // past the 256-page (+1 MiB interpreter headroom) ceiling. The kernel
    // would happily allocate this; the capped allocator refuses and the
    // kernel surfaces it as MemoryOutOfBounds → MemoryFault.
    const body = [_]u8{ 0x00, 0x41, 0xab, 0x02, 0x40, 0x1a, 0x0b };
    try b.code(&.{&body});

    var vm = try WasmVm.load(alloc, b.buf.items, default_limits, default_policy);
    defer vm.deinit();
    try testing.expectError(error.MemoryFault, vm.call("run", &.{}));

    // Sanity: the same module with a generous cap grows fine (declared
    // 1 page + 299 grown = 300 pages fits under 512 + headroom).
    var big_lim = default_limits;
    big_lim.max_memory_pages = 512;
    var vm2 = try WasmVm.load(alloc, b.buf.items, big_lim, default_policy);
    defer vm2.deinit();
    _ = try vm2.call("run", &.{});
    try testing.expectEqual(@as(usize, 300 * wasm.page_size), vm2.memory().len);
}

test "recursion past max_call_depth is rejected, not fatal" {
    const alloc = testing.allocator;
    // run() calls itself (call 0) unconditionally: the depth cap must trip
    // before the frame stack grows unbounded (zcordis v0.2.0 hardening).
    // Body = locals-count 0, then call 0, then end.
    const body = [_]u8{ 0x00, 0x10, 0x00, 0x0b };
    const bytes = try buildTinyModule(alloc, &body);
    defer alloc.free(bytes);
    var limits = default_limits;
    limits.max_call_depth = 16;
    var vm = try WasmVm.load(alloc, bytes, limits, default_policy);
    defer vm.deinit();
    try testing.expectError(error.CallDepthExceeded, vm.call("run", &.{}));
}
