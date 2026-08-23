//! WASM plugin loader — the wasm twin of pluginabi/loader.zig (dev.md
//! §XXV–XXVI + wave 4 L2 sandbox). Discovers `.wasm` plugins, validates them
//! against WASM ABI v1 (below), and projects their tools into the host
//! registry namespace `w_<module>_<tool>`.
//!
//! ───────────────────────────── WASM ABI v1 ────────────────────────────
//!
//! A plugin is a WebAssembly MVP binary exporting exactly:
//!
//!   ┌────────────────┬──────────────────┬─────────────────────────────────┐
//!   │ Export         │ Signature        │ Contract                        │
//!   ├────────────────┼──────────────────┼─────────────────────────────────┤
//!   │ memory         │ memory (min ≥ 1) │ The module's linear memory.     │
//!   │                │                  │ Host reads results from and     │
//!   │                │                  │ writes call inputs into it.     │
//!   ├────────────────┼──────────────────┼─────────────────────────────────┤
//!   │ zh_abi_version │ () -> i64        │ Must return 1                   │
//!   │                │                  │ (WASM_ABI_VERSION). Plugins     │
//!   │                │                  │ speaking another major ABI are  │
//!   │                │                  │ rejected before their manifest  │
//!   │                │                  │ is read.                        │
//!   ├────────────────┼──────────────────┼─────────────────────────────────┤
//!   │ zh_manifest    │ () -> i64        │ Returns a PACKED pointer        │
//!   │                │                  │ (ptr << 32 | len) into linear   │
//!   │                │                  │ memory: UTF-8 JSON identical in │
//!   │                │                  │ shape to the C-ABI manifest     │
//!   │                │                  │ ({"name","version","kind",      │
//!   │                │                  │ "tools":[{name,description,     │
//!   │                │                  │ schema}...]}). len == 0 is the  │
//!   │                │                  │ NULL-equivalent: failure.       │
//!   ├────────────────┼──────────────────┼─────────────────────────────────┤
//!   │ zh_tool_call   │ (i64,i64,i64,    │ name_ptr,name_len,args_ptr,     │
//!   │                │ i64) -> i64      │ args_len. Inputs were placed by │
//!   │                │                  │ the host into linear memory in  │
//!   │                │                  │ a scratch window (see below);   │
//!   │                │                  │ args_json is the model-supplied │
//!   │                │                  │ arguments verbatim ("{}" when   │
//!   │                │                  │ empty). Returns a packed ptr/len│
//!   │                │                  │ to result JSON the module WROTE │
//!   │                │                  │ INTO ITS OWN MEMORY before      │
//!   │                │                  │ returning; len == 0 signals     │
//!   │                │                  │ tool failure (host turns it     │
//!   │                │                  │ into a failed tool result).     │
//!   └────────────────┴──────────────────┴─────────────────────────────────┘
//!
//! Scratch window: before each call the host copies `name` then `args` into
//! guest linear memory — one fixed window per instance (default 64 KiB,
//! carved out of the page budget on first use and REUSED across calls so
//! repeated invocations cannot exhaust the sandbox memory cap). Guests must
//! not assume input stability across calls.
//!
//! Packing: little-endian u64 bit pattern `(u32 ptr << 32) | u32 len`,
//! transported as i64. Unpacking never traps (truncating casts).
//!
//! Failure policy (mirrors loader.zig): every rejected candidate produces a
//! skip-report entry (path + reason) and is skipped; the loader NEVER crashes
//! the host and NEVER leaks. Successful loads are unloaded by `deinit`.
//!
//! Sandbox contract: all instances run under sandbox.wasm.Limits — default
//! step budget 10M, memory cap 256 pages (16 MiB), imports denied.

const std = @import("std");
const sandbox = @import("../sandbox/wasm.zig");
const registry = @import("../tool/registry.zig");
// Manifest model/parser is SHARED with the C-ABI loader: the manifest JSON
// shape is byte-identical across both transports by design.
const native_loader = @import("loader.zig");

const wasm = sandbox.wasm;

/// Current WASM plugin ABI version (see contract table above).
pub const WASM_ABI_VERSION: i64 = 1;

// Required export names.
pub const EXP_MEMORY = "memory";
pub const EXP_ABI_VERSION = "zh_abi_version";
pub const EXP_MANIFEST = "zh_manifest";
pub const EXP_TOOL_CALL = "zh_tool_call";

/// Per-instance scratch window for call inputs (name + args), reused across
/// calls so repeated invocations cannot exhaust the memory cap.
pub const default_scratch_bytes: usize = 64 * 1024;
/// Cap on a single tool-result payload copied out of guest memory.
pub const default_max_result_bytes: usize = 4 * 1024 * 1024;

// ─────────────────────────────────────────────────────────────────────────
// Packing helpers (the ABI's pointer transport)
// ─────────────────────────────────────────────────────────────────────────

pub const PtrLen = struct { ptr: u32, len: u32 };

/// Pack (ptr, len) into the ABI's single i64 transport value.
pub fn packPtrLen(ptr: u32, len: u32) i64 {
    return @bitCast((@as(u64, ptr) << 32) | @as(u64, len));
}

/// Inverse of `packPtrLen`. Truncating casts — no trap on garbage input.
pub fn unpackPtrLen(v: i64) PtrLen {
    const bits: u64 = @bitCast(v);
    return .{ .ptr = @truncate(bits >> 32), .len = @truncate(bits) };
}

// ─────────────────────────────────────────────────────────────────────────
// Raw section scan: memory-export detection
// ─────────────────────────────────────────────────────────────────────────

/// Minimal ULEB128 reader over raw bytes; null on any overrun.
fn readUleb32(bytes: []const u8, pos: *usize) ?u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (pos.* >= bytes.len or shift == 28) return null;
        const b = bytes[pos.*];
        pos.* += 1;
        result |= @as(u32, b & 0x7f) << shift;
        if ((b & 0x80) == 0) return result;
        shift += 7;
    }
}

/// True iff the binary declares an EXPORT SECTION entry of kind 2 (memory)
/// named exactly "memory". Needed because the kernel keeps only function and
/// global exports in its map — memory exports are silently dropped there.
/// Tolerant by design: ANY structural surprise returns false (candidate gets
/// a clean skip report instead).
pub fn hasMemoryExport(bytes: []const u8) bool {
    if (bytes.len < 8) return false;
    var pos: usize = 8; // past magic + version
    while (pos < bytes.len) {
        const id = bytes[pos];
        pos += 1;
        const size = readUleb32(bytes, &pos) orelse return false;
        if (pos + size > bytes.len) return false;
        const payload = bytes[pos .. pos + size];
        defer pos += size;
        if (id != 7) continue; // not the export section

        var p: usize = 0;
        const count = readUleb32(payload, &p) orelse return false;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const nlen = readUleb32(payload, &p) orelse return false;
            if (p + nlen > payload.len) return false;
            const nm = payload[p .. p + nlen];
            p += nlen;
            if (p >= payload.len) return false;
            const kind = payload[p];
            p += 1;
            _ = readUleb32(payload, &p) orelse return false; // item index
            if (kind == 2 and std.mem.eql(u8, nm, EXP_MEMORY)) return true;
        }
    }
    return false;
}

// ─────────────────────────────────────────────────────────────────────────
// Naming (w_ namespace twin of loader.hostToolName)
// ─────────────────────────────────────────────────────────────────────────

/// Append `s` sanitized into the host tool namespace charset [a-z0-9_].
fn appendSanitized(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            'a'...'z', '0'...'9', '_' => try out.append(alloc, c),
            'A'...'Z' => try out.append(alloc, c + ('a' - 'A')),
            else => try out.append(alloc, '_'),
        }
    }
}

/// Host-visible tool name for module-local tool `<tool_name>` of wasm module
/// `<module_name>`: `w_<module>_<tool>`, sanitized to [a-z0-9_] so wasm tools
/// can never collide with builtins, C plugins (`p_*`) or MCP (`mcp_*`).
pub fn wasmHostToolName(alloc: std.mem.Allocator, module_name: []const u8, tool_name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, 'w');
    try out.append(alloc, '_');
    try appendSanitized(&out, alloc, module_name);
    try out.append(alloc, '_');
    try appendSanitized(&out, alloc, tool_name);
    return out.toOwnedSlice(alloc);
}

// ─────────────────────────────────────────────────────────────────────────
// Export signature validation
// ─────────────────────────────────────────────────────────────────────────

const SigSpec = struct { name: []const u8, params: usize };

/// Look up a required FUNCTION export and verify its declared signature has
/// `spec.params` parameters and exactly one result. Returns the kernel-level
/// error text via `why` on failure (null = OK).
fn checkExportSig(vm: *sandbox.WasmVm, spec: SigSpec, why: *[]const u8) bool {
    const exp = vm.module.exports.get(spec.name) orelse {
        why.* = "missing required export";
        return false;
    };
    // kind 0 == function export (kernel only maps functions/globals anyway).
    if (exp.kind != 0) {
        why.* = "required export is not a function";
        return false;
    }
    const ft = vm.module.funcType(exp.index) catch {
        why.* = "export has no resolvable type";
        return false;
    };
    if (ft.params.len != spec.params or ft.returns.len != 1) {
        why.* = "export signature does not match ABI v1";
        return false;
    }
    return true;
}

// ─────────────────────────────────────────────────────────────────────────
// Registry: discovery, validation, registration, execution
// ─────────────────────────────────────────────────────────────────────────

/// One skipped-candidate record (path + human-readable reason).
pub const ReportEntry = struct {
    path: []u8,
    reason: []u8,
};

/// A registered wasm plugin: file provenance + live sandboxed instance plus
/// its reusable input-scratch window.
const WasmPlugin = struct {
    path: []u8,
    vm: *sandbox.WasmVm,
    /// Offset of the scratch window inside linear memory; null until first use.
    scratch_base: ?u32 = null,

    fn ensureScratch(self: *WasmPlugin, alloc_for_err: std.mem.Allocator, need: usize) ?u32 {
        _ = alloc_for_err;
        const base = self.scratch_base orelse blk: {
            const b = self.vm.growScratch(default_scratch_bytes) catch return null;
            self.scratch_base = b;
            break :blk b;
        };
        if (@as(usize, base) + need > self.vm.memory().len) return null;
        return base;
    }
};

/// A registered plugin tool as seen by the host.
pub const LoadedTool = struct {
    /// Name the model calls: `w_<module>_<tool>`.
    host_name: []u8,
    /// Name passed to zh_tool_call (module-local).
    tool_name: []u8,
    description: []u8,
    /// Raw parameters-schema JSON (registry-compatible view below).
    schema: []u8,
    plugin_idx: usize,
};

/// Result of executing a wasm tool. `output` is owned by the caller;
/// `ok == false` means the module signalled failure (len==0 / trap / budget)
/// and `output` carries a host-side error message.
pub const ExecOutcome = struct {
    ok: bool,
    output: []u8,
};

pub const WasmRegistry = struct {
    alloc: std.mem.Allocator,
    limits: sandbox.Limits = sandbox.default_limits,
    policy: sandbox.ImportPolicy = sandbox.default_policy,
    plugins: std.ArrayList(*WasmPlugin),
    tools: std.ArrayList(LoadedTool),
    report: std.ArrayList(ReportEntry),

    pub fn init(alloc: std.mem.Allocator) WasmRegistry {
        return .{
            .alloc = alloc,
            .plugins = .empty,
            .tools = .empty,
            .report = .empty,
        };
    }

    /// Tear down every live instance and free all owned memory.
    pub fn deinit(self: *WasmRegistry) void {
        for (self.plugins.items) |p| {
            p.vm.deinit();
            self.alloc.free(p.path);
            self.alloc.destroy(p);
        }
        self.plugins.deinit(self.alloc);
        for (self.tools.items) |t| {
            self.alloc.free(t.host_name);
            self.alloc.free(t.tool_name);
            self.alloc.free(t.description);
            self.alloc.free(t.schema);
        }
        self.tools.deinit(self.alloc);
        for (self.report.items) |e| {
            self.alloc.free(e.path);
            self.alloc.free(e.reason);
        }
        self.report.deinit(self.alloc);
    }

    fn addReport(self: *WasmRegistry, path: []const u8, comptime fmt: []const u8, args: anytype) void {
        const path_copy = self.alloc.dupe(u8, path) catch return; // report best-effort
        const reason = std.fmt.allocPrint(self.alloc, fmt, args) catch {
            self.alloc.free(path_copy);
            return;
        };
        self.report.append(self.alloc, .{ .path = path_copy, .reason = reason }) catch {
            self.alloc.free(path_copy);
            self.alloc.free(reason);
        };
    }

    /// Load one candidate file. Never throws: failures land in `report`.
    pub fn loadPath(self: *WasmRegistry, io: std.Io, path: []const u8) void {
        // Suffix gate first so random files get a clear reason.
        if (!std.mem.endsWith(u8, path, ".wasm")) {
            self.addReport(path, "skipped: not a wasm module (.wasm)", .{});
            return;
        }
        const base = std.fs.path.basename(path);
        if (base.len == 0 or base[0] == '.') {
            self.addReport(path, "skipped: hidden file", .{});
            return;
        }

        const bytes_owned: ?[]u8 = blk: {
            const raw = std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                self.alloc,
                .limited(self.limits.max_module_bytes),
            ) catch |e| {
                if (e == error.OutOfMemory) {
                    self.addReport(path, "out of memory", .{});
                } else {
                    self.addReport(path, "unreadable: {s}", .{@errorName(e)});
                }
                break :blk null;
            };
            break :blk raw;
        };
        const bytes = bytes_owned orelse return;
        defer self.alloc.free(bytes);

        if (!hasMemoryExport(bytes)) {
            self.addReport(path, "missing required '{s}' export", .{EXP_MEMORY});
            return;
        }

        const vm = sandbox.WasmVm.load(self.alloc, bytes, self.limits, self.policy) catch |e| {
            switch (e) {
                error.ModuleTooLarge => self.addReport(path, "module exceeds size limit ({d} bytes)", .{self.limits.max_module_bytes}),
                error.MalformedModule => self.addReport(path, "malformed or truncated wasm module", .{}),
                error.MemoryTooLarge => self.addReport(path, "memory declaration exceeds sandbox cap ({d} pages)", .{self.limits.max_memory_pages}),
                error.ImportDenied => self.addReport(path, "requests imports outside the sandbox allowlist", .{}),
                error.ExecutionLimit => self.addReport(path, "start function exceeded step budget ({d})", .{self.limits.step_budget}),
                error.OutOfMemory => self.addReport(path, "out of memory", .{}),
            }
            return;
        };

        // Signature gate BEFORE calling anything.
        var why: []const u8 = "";
        inline for (.{ SigSpec{ .name = EXP_ABI_VERSION, .params = 0 }, SigSpec{ .name = EXP_MANIFEST, .params = 0 }, SigSpec{ .name = EXP_TOOL_CALL, .params = 4 } }) |spec| {
            if (!checkExportSig(vm, spec, &why)) {
                self.addReport(path, "'{s}': {s}", .{ spec.name, why });
                vm.deinit();
                return;
            }
        }

        // Version check BEFORE trusting anything else from the module.
        const ver = vm.call(EXP_ABI_VERSION, &.{}) catch |e| {
            self.addLoadCallFailure(path, vm, EXP_ABI_VERSION, e);
            return;
        };
        if (ver != WASM_ABI_VERSION) {
            self.addReport(path, "ABI version {d} unsupported (host speaks {d})", .{ ver, WASM_ABI_VERSION });
            vm.deinit();
            return;
        }

        // Fetch + copy the manifest out of guest memory.
        const manifest_src = self.fetchGuestJson(path, vm, EXP_MANIFEST) orelse return; // report already written
        defer self.alloc.free(manifest_src);

        var m = native_loader.parseManifest(self.alloc, manifest_src) catch |e| {
            self.addReport(path, "manifest rejected: {s}", .{@errorName(e)});
            vm.deinit();
            return;
        };
        defer m.deinit();

        native_loader.validateManifest(&m) catch |e| {
            self.addReport(path, "manifest invalid: {s}", .{@errorName(e)});
            vm.deinit();
            return;
        };

        // Project each tool into the w_ namespace.
        const plugin_idx = self.plugins.items.len;
        var added: usize = 0;
        for (m.tools) |t| {
            const host_name = wasmHostToolName(self.alloc, m.name, t.name) catch continue;
            if (self.findTool(host_name) != null) {
                self.addReport(path, "duplicate host tool '{s}' ignored", .{host_name});
                self.alloc.free(host_name);
                continue;
            }
            const row = LoadedTool{
                .host_name = host_name,
                .tool_name = self.alloc.dupe(u8, t.name) catch {
                    self.alloc.free(host_name);
                    continue;
                },
                .description = self.alloc.dupe(u8, t.description) catch {
                    self.alloc.free(host_name);
                    continue;
                },
                .schema = self.alloc.dupe(u8, t.schema) catch {
                    self.alloc.free(host_name);
                    continue;
                },
                .plugin_idx = plugin_idx,
            };
            // Roll back partial row if a later dupe failed.
            if (row.description.len != t.description.len or row.schema.len != t.schema.len) {
                self.freeToolRow(row);
                continue;
            }
            self.tools.append(self.alloc, row) catch {
                self.freeToolRow(row);
                continue; // OOM on this tool — skip it, keep the host alive
            };
            added += 1;
        }

        if (added == 0) {
            self.addReport(path, "no usable tools registered", .{});
            vm.deinit();
            return;
        }

        const stored = self.alloc.create(WasmPlugin) catch {
            var k = self.tools.items.len;
            while (k > 0) {
                k -= 1;
                if (self.tools.items[k].plugin_idx == plugin_idx) {
                    const row = self.tools.swapRemove(k);
                    self.freeToolRow(row);
                }
            }
            self.addReport(path, "out of memory", .{});
            vm.deinit();
            return;
        };
        const path_copy = self.alloc.dupe(u8, path) catch {
            self.alloc.destroy(stored);
            var k = self.tools.items.len;
            while (k > 0) {
                k -= 1;
                if (self.tools.items[k].plugin_idx == plugin_idx) {
                    const row = self.tools.swapRemove(k);
                    self.freeToolRow(row);
                }
            }
            self.addReport(path, "out of memory", .{});
            vm.deinit();
            return;
        };
        stored.* = .{ .path = path_copy, .vm = vm };
        self.plugins.append(self.alloc, stored) catch {
            self.alloc.free(path_copy);
            self.alloc.destroy(stored);
            self.addReport(path, "out of memory", .{});
            vm.deinit();
            return;
        };
    }

    /// Record a reason for a required-export CALL that failed mid-load, then
    /// tear the candidate down. Keeps loadPath readable.
    fn addLoadCallFailure(
        self: *WasmRegistry,
        path: []const u8,
        vm: *sandbox.WasmVm,
        export_name: []const u8,
        e: sandbox.CallError,
    ) void {
        switch (e) {
            error.ExecutionLimit => self.addReport(path, "'{s}' exceeded step budget ({d})", .{ export_name, self.limits.step_budget }),
            error.GuestTrap => self.addReport(path, "'{s}' trapped", .{export_name}),
            error.MemoryFault => self.addReport(path, "'{s}' hit the memory cap", .{export_name}),
            error.UnknownExport => self.addReport(path, "'{s}' vanished between validation and call", .{export_name}),
            error.ArityMismatch => self.addReport(path, "'{s}' arity mismatch", .{export_name}),
            error.OutOfMemory => self.addReport(path, "out of memory", .{}),
        }
        vm.deinit();
    }

    /// Call a manifest-style export returning packed(ptr,len) JSON, copy it
    /// into host memory, and return it (owned). Writes its own skip-report
    /// entry and deinits `vm` on every failure path; returns null then.
    fn fetchGuestJson(self: *WasmRegistry, path: []const u8, vm: *sandbox.WasmVm, export_name: []const u8) ?[]u8 {
        const ret = vm.call(export_name, &.{}) catch |e| {
            self.addLoadCallFailure(path, vm, export_name, e);
            return null;
        };
        const pl = unpackPtrLen(ret);
        if (pl.len == 0) {
            self.addReport(path, "'{s}' returned NULL-equivalent (len == 0)", .{export_name});
            vm.deinit();
            return null;
        }
        if (pl.len > default_max_result_bytes) {
            self.addReport(path, "'{s}' payload too large ({d} bytes)", .{ export_name, pl.len });
            vm.deinit();
            return null;
        }
        const mem = vm.memory();
        if (@as(usize, pl.ptr) + pl.len > mem.len) {
            self.addReport(path, "'{s}' points outside linear memory", .{export_name});
            vm.deinit();
            return null;
        }
        const copy = self.alloc.dupe(u8, mem[pl.ptr..][0..pl.len]) catch {
            self.addReport(path, "out of memory", .{});
            vm.deinit();
            return null;
        };
        return copy;
    }

    fn freeToolRow(self: *WasmRegistry, t: LoadedTool) void {
        self.alloc.free(t.host_name);
        self.alloc.free(t.tool_name);
        self.alloc.free(t.description);
        self.alloc.free(t.schema);
    }

    /// Scan `dir_path` for *.wasm (sorted for determinism) and load each.
    /// Missing directory is silently fine (nothing to discover). Returns the
    /// number of successfully loaded plugins.
    pub fn loadDir(self: *WasmRegistry, io: std.Io, dir_path: []const u8) usize {
        const before = self.plugins.items.len;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
        defer dir.close(io);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.alloc.free(n);
            names.deinit(self.alloc);
        }
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            const dup = self.alloc.dupe(u8, entry.name) catch continue;
            names.append(self.alloc, dup) catch {
                self.alloc.free(dup);
                continue;
            };
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (names.items) |n| {
            const full = std.fs.path.join(self.alloc, &.{ dir_path, n }) catch continue;
            defer self.alloc.free(full);
            self.loadPath(io, full);
        }
        return self.plugins.items.len - before;
    }

    /// Standard discovery order (mirrors loader.zig): ~/.zharness/plugins-wasm
    /// first, then the workspace's own plugins-wasm directory.
    pub fn loadDefaultDirs(self: *WasmRegistry, io: std.Io, workspace_root: []const u8) void {
        // std.posix.getenv was removed in this 0.17-dev build; use libc.
        if (std.c.getenv("HOME")) |home_ptr| {
            const home = std.mem.span(home_ptr);
            const user_dir = std.fs.path.join(self.alloc, &.{ home, ".zharness", "plugins-wasm" }) catch null;
            if (user_dir) |ud| {
                defer self.alloc.free(ud);
                _ = self.loadDir(io, ud);
            }
        }
        const ws_dir = std.fs.path.join(self.alloc, &.{ workspace_root, "plugins-wasm" }) catch return;
        defer self.alloc.free(ws_dir);
        _ = self.loadDir(io, ws_dir);
    }

    /// Index of the registered tool named `host_tool_name`, if any.
    pub fn findTool(self: *WasmRegistry, host_tool_name: []const u8) ?usize {
        for (self.tools.items, 0..) |t, idx| {
            if (std.mem.eql(u8, t.host_name, host_tool_name)) return idx;
        }
        return null;
    }

    /// registry.ToolDefinition view for tool `idx`. Strings point into
    /// registry-owned storage and stay valid until `deinit`.
    pub fn definitionFor(self: *WasmRegistry, idx: usize) registry.ToolDefinition {
        const t = self.tools.items[idx];
        return .{
            .name = t.host_name,
            .description = t.description,
            .parameters_json = t.schema,
            .category = .general,
        };
    }

    /// All definitions, ready to feed `tool_reg.ToolRegistry.register`
    /// (which duplicates strings itself).
    pub fn definitions(self: *WasmRegistry, alloc: std.mem.Allocator) ![]registry.ToolDefinition {
        const defs = try alloc.alloc(registry.ToolDefinition, self.tools.items.len);
        for (self.tools.items, 0..) |_, idx| defs[idx] = self.definitionFor(idx);
        return defs;
    }

    /// Execute a wasm tool previously discovered under `host_tool_name`.
    /// Copies name + args into the plugin's scratch window, calls
    /// zh_tool_call, validates the packed result, and COPIES the result JSON
    /// out of guest memory (guest faults can therefore never alias host
    /// state). Returns null when the name is not a wasm tool.
    pub fn execute(
        self: *WasmRegistry,
        alloc: std.mem.Allocator,
        host_tool_name: []const u8,
        args_json: []const u8,
    ) !?ExecOutcome {
        const idx = self.findTool(host_tool_name) orelse return null;
        const t = self.tools.items[idx];
        const plugin = self.plugins.items[t.plugin_idx];
        const vm = plugin.vm;

        const effective_args: []const u8 =
            if (args_json.len == 0) "{}" else args_json;
        const need = t.tool_name.len + effective_args.len;

        if (need > default_scratch_bytes) {
            const msg = try std.fmt.allocPrint(
                alloc,
                "tool '{s}' inputs exceed the {d}-byte scratch window",
                .{ host_tool_name, default_scratch_bytes },
            );
            return ExecOutcome{ .ok = false, .output = msg };
        }
        const base = plugin.ensureScratch(alloc, need) orelse {
            const msg = try std.fmt.allocPrint(
                alloc,
                "tool '{s}' could not provision its scratch window under the memory cap",
                .{host_tool_name},
            );
            return ExecOutcome{ .ok = false, .output = msg };
        };

        // Place [name][args] at the window start. Safe: guest code is not
        // running while the host writes.
        const mem_mut = vm.memoryMut();
        @memcpy(mem_mut[base..][0..t.tool_name.len], t.tool_name);
        @memcpy(mem_mut[base + t.tool_name.len ..][0..effective_args.len], effective_args);

        const ret = vm.call(EXP_TOOL_CALL, &.{
            @intCast(base),
            @intCast(t.tool_name.len),
            @intCast(@as(usize, base) + t.tool_name.len),
            @intCast(effective_args.len),
        }) catch |e| {
            const msg = switch (e) {
                error.ExecutionLimit => try std.fmt.allocPrint(alloc, "tool '{s}' exceeded its step budget", .{host_tool_name}),
                error.GuestTrap => try std.fmt.allocPrint(alloc, "tool '{s}' trapped", .{host_tool_name}),
                error.MemoryFault => try std.fmt.allocPrint(alloc, "tool '{s}' hit the memory cap", .{host_tool_name}),
                else => try std.fmt.allocPrint(alloc, "tool '{s}' failed: {s}", .{ host_tool_name, @errorName(e) }),
            };
            return ExecOutcome{ .ok = false, .output = msg };
        };

        const pl = unpackPtrLen(ret);
        if (pl.len == 0) {
            const msg = try std.fmt.allocPrint(
                alloc,
                "plugin tool '{s}' reported failure",
                .{host_tool_name},
            );
            return ExecOutcome{ .ok = false, .output = msg };
        }
        if (pl.len > default_max_result_bytes) {
            const msg = try std.fmt.allocPrint(
                alloc,
                "tool '{s}' result too large ({d} bytes)",
                .{ host_tool_name, pl.len },
            );
            return ExecOutcome{ .ok = false, .output = msg };
        }
        const mem = vm.memory();
        if (@as(usize, pl.ptr) + pl.len > mem.len) {
            const msg = try std.fmt.allocPrint(
                alloc,
                "tool '{s}' returned an out-of-bounds result pointer",
                .{host_tool_name},
            );
            return ExecOutcome{ .ok = false, .output = msg };
        }

        const copied = try alloc.dupe(u8, mem[pl.ptr..][0..pl.len]);
        return ExecOutcome{ .ok = true, .output = copied };
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Tests (pure helpers here; end-to-end fixtures live in src/_t_wasm.zig)
// ─────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "packPtrLen/unpackPtrLen round-trips incl. extremes" {
    const cases = [_]PtrLen{
        .{ .ptr = 0, .len = 0 },
        .{ .ptr = 16, .len = 200 },
        .{ .ptr = 0xDEADBEEF, .len = 0x7FFFFFFF },
        .{ .ptr = 0xFFFFFFFF, .len = 0xFFFFFFFF },
    };
    for (cases) |c| {
        const back = unpackPtrLen(packPtrLen(c.ptr, c.len));
        try testing.expectEqual(c.ptr, back.ptr);
        try testing.expectEqual(c.len, back.len);
    }
    // len==0 is the NULL-equivalent regardless of ptr.
    try testing.expectEqual(@as(u32, 0), unpackPtrLen(packPtrLen(1234, 0)).len);
    // Garbage negative i64 unpacks without trapping.
    _ = unpackPtrLen(-1);
}

test "wasmHostToolName sanitizes into w_module_tool namespace" {
    const alloc = testing.allocator;
    const cases = [_][3][]const u8{
        .{ "demo", "ping", "w_demo_ping" },
        .{ "My Module!", "do-Thing", "w_my_module__do_thing" },
        .{ "tool.shell", "run.cmd", "w_tool_shell_run_cmd" },
    };
    for (cases) |c| {
        const got = try wasmHostToolName(alloc, c[0], c[1]);
        defer alloc.free(got);
        try testing.expectEqualStrings(c[2], got);
    }
}

/// Build a module with a hand-written export section that includes a MEMORY
/// export (kernel Builder.exports only emits function entries).
fn buildWithMemoryExport(alloc: std.mem.Allocator, with_memory_export: bool) ![]u8 {
    var b = wasm.Builder{ .alloc = alloc };
    errdefer b.deinit();
    try b.raw(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try b.types(&.{.{ .params = &.{}, .returns = &.{} }});
    try b.functions(&.{0});
    try b.exports(&.{.{ .name = "run", .index = 0 }});
    if (with_memory_export) {
        var p = wasm.Builder{ .alloc = alloc };
        defer p.deinit();
        try p.uleb(2); // two export entries
        try p.name(EXP_MEMORY);
        try p.emitByte(0x02); // kind: memory
        try p.uleb(0);
        try p.name("run");
        try p.emitByte(0x00); // kind: function (duplicate name tolerated by kernel)
        try p.uleb(0);
        try b.section(7, p.buf.items);
    }
    try b.memory(1);
    try b.code(&.{&.{ 0x00, 0x0b }});
    const owned = try alloc.dupe(u8, b.buf.items);
    b.deinit();
    return owned;
}

test "hasMemoryExport detects memory exports and tolerates junk" {
    const alloc = testing.allocator;

    const yes = try buildWithMemoryExport(alloc, true);
    defer alloc.free(yes);
    try testing.expect(hasMemoryExport(yes));

    const no = try buildWithMemoryExport(alloc, false);
    defer alloc.free(no);
    try testing.expect(!hasMemoryExport(no));

    try testing.expect(!hasMemoryExport(""));
    try testing.expect(!hasMemoryExport(&.{ 0x00, 0x61, 0x73, 0x6d }));
    try testing.expect(!hasMemoryExport("\x00asm\x01\x00\x00\x00\xff\x99"));
}
