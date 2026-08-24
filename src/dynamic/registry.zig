// Dynamic package registry — session-scoped, process-heap, metadata-only log.
// Implements docs/dynamic-cordis-spec.md §4-6 revisioning and ownership.
//
// Transport note (spec §5): mutations ride WS /api/events.mux + POST /api/* .
// This registry is process-local memory only; no write to
// .zharness/sessions/<id>.json, cordis.yml, or disk plugins. Session log carries
// only cordis_define metadata (name, purpose, pluginId, packageId) — never source.
// Revisit after a process restart renders "unloaded / Plugin removed".
//
// Revisioning (spec §5): pluginId = "<prefix>-<n>" (monotonic, never reused),
// pkg = "pkg-<n>" immutable define order, run = "run-<n>" exact activation identity.
// Dual lifetimes: latestRun (diagnostic history, survives failure) vs activeRun
// (physical Run with renderFailure dual lifetime). currentPackageId moves only on
// complete success; failures set nextPackageId and preserve error.

const std = @import("std");
const types = @import("types.zig");

pub const RegistryError = error{
    InvalidPrefix,
    InvalidName,
    InvalidPurpose,
    MissingCode,
    SyntaxError,
    CodeTooLarge,
    PluginNotFound,
    NotOwner,
    PackageNotFound,
    InvalidMode,
    TransitionInFlight,
    PendingExists,
    StaleRevision,
    OutOfMemory,
};

pub const DynamicRegistry = struct {
    alloc: std.mem.Allocator,
    plugins: std.StringHashMap(*types.Plugin),
    pendingRequests: std.StringHashMap(types.PendingRequest),
    // in-flight host-half start gate per plugin (serialized per id, coalesced)
    starting: std.StringHashMap(void),
    next_plugin: u64,
    next_package: u64,
    next_run: u64,
    next_approval: u64,
    config: types.DynamicConfig,

    pub fn init(alloc: std.mem.Allocator) DynamicRegistry {
        return .{
            .alloc = alloc,
            .plugins = std.StringHashMap(*types.Plugin).init(alloc),
            .pendingRequests = std.StringHashMap(types.PendingRequest).init(alloc),
            .starting = std.StringHashMap(void).init(alloc),
            .next_plugin = 1,
            .next_package = 1,
            .next_run = 1,
            .next_approval = 1,
            .config = .{},
        };
    }

    pub fn deinit(self: *DynamicRegistry) void {
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.plugins.deinit();
        var it2 = self.pendingRequests.iterator();
        while (it2.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.agentId);
            self.alloc.free(entry.value_ptr.pluginId);
            self.alloc.free(entry.value_ptr.packageId);
            self.alloc.free(entry.value_ptr.pluginRunId);
        }
        self.pendingRequests.deinit();
        var it3 = self.starting.iterator();
        while (it3.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.starting.deinit();
    }

    // ── id mints ─────────────────────────────────────────────────────────────

    pub fn mintPluginId(self: *DynamicRegistry, prefix: []const u8) ![]u8 {
        // monotonic suffix never reused; do-while safety like registry.ts
        while (true) {
            const id = try std.fmt.allocPrint(self.alloc, "{s}-{d}", .{ prefix, self.next_plugin });
            self.next_plugin += 1;
            if (!self.plugins.contains(id)) return id;
            self.alloc.free(id);
        }
    }

    pub fn mintPackageId(self: *DynamicRegistry) ![]u8 {
        const id = try std.fmt.allocPrint(self.alloc, "pkg-{d}", .{self.next_package});
        self.next_package += 1;
        return id;
    }

    pub fn mintRunId(self: *DynamicRegistry) ![]u8 {
        const id = try std.fmt.allocPrint(self.alloc, "run-{d}", .{self.next_run});
        self.next_run += 1;
        return id;
    }

    pub fn mintApprovalId(self: *DynamicRegistry) ![]u8 {
        const id = try std.fmt.allocPrint(self.alloc, "approval-{d}", .{self.next_approval});
        self.next_approval += 1;
        return id;
    }

    // ── syntax precheck (mirrors sandbox.ts precheckCode gate) ──────────────
    // In the full runtime this compiles via `new Function` + vm.Script caret.
    // Here we enforce the teachable subset without executing: rejects empty,
    // oversize, obvious TypeScript `as` / `: type` annotations, unbalanced
    // delimiters, and the `});` bracket trap so unparseable input never mints.

    pub fn precheckCode(self: *DynamicRegistry, code: []const u8, field: []const u8) RegistryError!void {
        _ = field;
        const trimmed = std.mem.trim(u8, code, " \t\r\n");
        if (trimmed.len == 0) return error.SyntaxError;
        if (code.len > self.config.maxClientSourceBytes) return error.CodeTooLarge;
        // teaching traps: TypeScript `as` annotation, colon-type hint, stray `});`
        // (lightweight heuristics sufficient for registry gate; full vm does caret)
        if (containsTypeAnnotationHint(trimmed)) return error.SyntaxError;
        if (!balancedDelims(trimmed)) return error.SyntaxError;
    }

    fn containsTypeAnnotationHint(s: []const u8) bool {
        // very small heuristic: ` as ` or `: string`/`: number`/`: boolean` suggests TS
        if (std.mem.indexOf(u8, s, " as ") != null) return true;
        const hints = [_][]const u8{ ": string", ": number", ": boolean", ": any", ": void" };
        for (hints) |h| if (std.mem.indexOf(u8, s, h) != null) return true;
        return false;
    }

    fn balancedDelims(s: []const u8) bool {
        var depth_paren: i32 = 0;
        var depth_brace: i32 = 0;
        var depth_brack: i32 = 0;
        var in_str: u8 = 0; // 0 none, '"' or '\''
        var escaped = false;
        for (s) |c| {
            if (in_str != 0) {
                if (escaped) { escaped = false; continue; }
                if (c == '\\') { escaped = true; continue; }
                if (c == in_str) in_str = 0;
                continue;
            }
            if (c == '"' or c == '\'') { in_str = c; continue; }
            switch (c) {
                '(' => depth_paren += 1,
                ')' => { depth_paren -= 1; if (depth_paren < 0) return false; },
                '{' => depth_brace += 1,
                '}' => { depth_brace -= 1; if (depth_brace < 0) return false; },
                '[' => depth_brack += 1,
                ']' => { depth_brack -= 1; if (depth_brack < 0) return false; },
                else => {},
            }
        }
        return depth_paren == 0 and depth_brace == 0 and depth_brack == 0 and in_str == 0;
    }

    // ── ownership helpers ────────────────────────────────────────────────────

    fn owned(self: *DynamicRegistry, sessionId: []const u8, pluginId: []const u8) ?*types.Plugin {
        const p = self.plugins.get(pluginId) orelse return null;
        if (!std.mem.eql(u8, p.session_id, sessionId)) return null;
        return p;
    }

    /// Physical plugin pointer (any session — callers enforce their own
    /// scoping; lifecycle uses this for session-less reads under its lock).
    pub fn getPlugin(self: *DynamicRegistry, pluginId: []const u8) ?*types.Plugin {
        return self.plugins.get(pluginId);
    }

    // ── define ───────────────────────────────────────────────────────────────

    pub fn define(self: *DynamicRegistry, req: types.DefineRequest) RegistryError!types.DefineReceipt {
        const name_raw = types.trimmedNonEmpty(req.name) orelse return error.InvalidName;
        const purpose_raw = types.trimmedNonEmpty(req.purpose) orelse return error.InvalidPurpose;
        if (req.code.host == null and req.code.client == null) return error.MissingCode;
        if (req.code.host) |c| try self.precheckCode(c, "code.host");
        if (req.code.client) |c| try self.precheckCode(c, "code.client");

        var plugin: *types.Plugin = undefined;
        switch (req.plugin) {
            .new => |n| {
                const prefix_raw = std.mem.trim(u8, n.idPrefix, " \t\r\n");
                if (!types.isValidPrefix(prefix_raw)) return error.InvalidPrefix;
                const plugin_id = try self.mintPluginId(prefix_raw);
                errdefer self.alloc.free(plugin_id);
                const sess_dup = try self.alloc.dupe(u8, req.session_id);
                errdefer self.alloc.free(sess_dup);
                const p = try self.alloc.create(types.Plugin);
                errdefer self.alloc.destroy(p);
                p.* = .{
                    .plugin_id = plugin_id,
                    .session_id = sess_dup,
                    .packages = std.StringHashMap(types.Package).init(self.alloc),
                    .package_order = std.ArrayList([]const u8).initCapacity(self.alloc, 0) catch return error.OutOfMemory,
                    .approved_client_packages = std.StringHashMap(void).init(self.alloc),
                };
                const key_dup = try self.alloc.dupe(u8, plugin_id);
                errdefer self.alloc.free(key_dup);
                try self.plugins.put(key_dup, p);
                plugin = p;
            },
            .existing => |pid| {
                const found = self.plugins.get(pid) orelse return error.PluginNotFound;
                if (!std.mem.eql(u8, found.session_id, req.session_id)) return error.NotOwner;
                plugin = found;
            },
        }

        const pkg_id = try self.mintPackageId();
        errdefer self.alloc.free(pkg_id);
        const name_dup = try self.alloc.dupe(u8, name_raw);
        errdefer self.alloc.free(name_dup);
        const purpose_dup = try self.alloc.dupe(u8, purpose_raw);
        errdefer self.alloc.free(purpose_dup);
        const host_dup: ?[]const u8 = if (req.code.host) |c| try self.alloc.dupe(u8, c) else null;
        errdefer if (host_dup) |v| self.alloc.free(v);
        const client_dup: ?[]const u8 = if (req.code.client) |c| try self.alloc.dupe(u8, c) else null;
        errdefer if (client_dup) |v| self.alloc.free(v);

        const pkg_key = try self.alloc.dupe(u8, pkg_id);
        errdefer self.alloc.free(pkg_key);

        const pkg = types.Package{
            .package_id = pkg_id,
            .name = name_dup,
            .purpose = purpose_dup,
            .hostCode = host_dup,
            .clientCode = client_dup,
        };
        try plugin.packages.put(pkg_key, pkg);
        // order list holds non-owned view onto pkg_key (same alloc as map key)
        try plugin.package_order.append(self.alloc, pkg_key);

        return types.DefineReceipt{
            .plugin_id = plugin.plugin_id,
            .package_id = pkg_id,
            .name = name_dup,
            .purpose = purpose_dup,
            .has_host = host_dup != null,
            .has_client = client_dup != null,
        };
    }

    // ── run ──────────────────────────────────────────────────────────────────
    // Validates mode vs currentPackageId, arms approval when client half needs it,
    // and advances latestRun / nextPackageId. Host-only paths commit synchronously.
    // Full vm evaluation + WS broadcasts live in lifecycle.zig / wire.zig; this
    // registry owns only the revision pointers and pending map.

    pub fn run(
        self: *DynamicRegistry,
        sessionId: []const u8,
        pluginId: []const u8,
        packageId: []const u8,
        mode: types.RunMode,
    ) RegistryError!types.RunReceipt {
        const plugin = self.owned(sessionId, pluginId) orelse return error.PluginNotFound;
        const pkg = plugin.packages.get(packageId) orelse return error.PackageNotFound;

        const current = plugin.current_package_id;
        if (mode == .update) {
            if (current == null) return error.InvalidMode;
            if (std.mem.eql(u8, current.?, packageId)) return error.InvalidMode;
        } else {
            if (current != null and !std.mem.eql(u8, current.?, packageId)) return error.InvalidMode;
        }
        if (self.starting.contains(pluginId)) return error.TransitionInFlight;
        if (self.pendingRequestFor(pluginId) != null) return error.TransitionInFlight;

        const run_id = try self.mintRunId();
        errdefer self.alloc.free(run_id);

        // Build latestRun attempt
        const host_status: types.HalfStatus = if (pkg.hostCode == null) .absent else .pending;
        const client_status: types.HalfStatus = if (pkg.clientCode == null) .absent else .pending;

        // free old next
        if (plugin.next_package_id) |old| self.alloc.free(old);
        plugin.next_package_id = try self.alloc.dupe(u8, packageId);

        // free old latest_run if any
        if (plugin.latest_run) |lr| {
            self.alloc.free(lr.pluginRunId);
            self.alloc.free(lr.packageId);
            if (lr.approvalRequestId) |a| self.alloc.free(a);
            if (lr.err) |e| self.alloc.free(e);
            if (lr.phase) |p| self.alloc.free(p);
            if (lr.host.err) |e| self.alloc.free(e);
            if (lr.client.err) |e| self.alloc.free(e);
        }

        // Host-only: commit synchronously
        if (pkg.clientCode == null) {
            const attempt = types.RunAttempt{
                .pluginRunId = try self.alloc.dupe(u8, run_id),
                .packageId = try self.alloc.dupe(u8, packageId),
                .mode = mode,
                .status = .running,
                .host = .{ .status = if (host_status == .absent) .absent else .running },
                .client = .{ .status = .absent },
            };
            plugin.latest_run = attempt;

            // commit activation
            if (plugin.current_package_id) |old| self.alloc.free(old);
            plugin.current_package_id = try self.alloc.dupe(u8, packageId);
            if (plugin.next_package_id) |old| {
                self.alloc.free(old);
                plugin.next_package_id = null;
            }
            // active run
            if (plugin.run) |r| {
                self.alloc.free(r.pluginRunId);
                self.alloc.free(r.packageId);
                if (r.startedForRequest) |a| self.alloc.free(a);
            }
            plugin.run = .{
                .pluginRunId = try self.alloc.dupe(u8, run_id),
                .packageId = try self.alloc.dupe(u8, packageId),
            };
            // Receipt strings are distinct owned dupes so caller can free independently
            // and registry mutations don't dangle the returned slices.
            const cur_for_receipt = try self.alloc.dupe(u8, plugin.current_package_id.?);
            errdefer self.alloc.free(cur_for_receipt);
            return types.RunReceipt{
                .pluginRunId = run_id,
                .packageId = try self.alloc.dupe(u8, packageId),
                .pluginId = plugin.plugin_id,
                .mode = mode,
                .status = .running,
                .currentPackageId = cur_for_receipt,
                .nextPackageId = try self.alloc.dupe(u8, packageId),
            };
        }

        // Client-bearing: requires approval decision unless already granted
        const already_approved = plugin.client_version_updates_approved or plugin.approved_client_packages.contains(packageId);
        const requires_approval = !already_approved;

        const approval_id = try self.mintApprovalId();
        errdefer self.alloc.free(approval_id);

        const attempt_status: types.RunStatus = if (requires_approval) .awaiting_approval else .starting_host;

        const attempt = types.RunAttempt{
            .pluginRunId = try self.alloc.dupe(u8, run_id),
            .packageId = try self.alloc.dupe(u8, packageId),
            .mode = mode,
            .status = attempt_status,
            .approvalRequestId = try self.alloc.dupe(u8, approval_id),
            .requiresApproval = requires_approval,
            .host = .{ .status = host_status },
            .client = .{ .status = client_status },
        };
        plugin.latest_run = attempt;

        // arm pending request
        const aid_key = try self.alloc.dupe(u8, approval_id);
        errdefer self.alloc.free(aid_key);
        const pending = types.PendingRequest{
            .agentId = try self.alloc.dupe(u8, sessionId),
            .pluginId = try self.alloc.dupe(u8, pluginId),
            .packageId = try self.alloc.dupe(u8, packageId),
            .pluginRunId = try self.alloc.dupe(u8, run_id),
            .mode = mode,
            .requiresApproval = requires_approval,
        };
        errdefer {
            self.alloc.free(pending.agentId);
            self.alloc.free(pending.pluginId);
            self.alloc.free(pending.packageId);
            self.alloc.free(pending.pluginRunId);
        }
        try self.pendingRequests.put(aid_key, pending);

        // WS broadcast cordis/request-run happens in wire.zig; registry just arms.

        const status: @FieldType(types.RunReceipt, "status") = if (requires_approval) .awaiting_approval else .starting;
        const receipt = types.RunReceipt{
            .pluginRunId = run_id,
            .packageId = try self.alloc.dupe(u8, packageId),
            .pluginId = plugin.plugin_id,
            .mode = mode,
            .status = status,
            .requiresApproval = requires_approval,
            .approvalRequestId = try self.alloc.dupe(u8, approval_id),
            .currentPackageId = if (plugin.current_package_id) |c| try self.alloc.dupe(u8, c) else null,
            .nextPackageId = try self.alloc.dupe(u8, packageId),
        };
        self.alloc.free(approval_id);
        return receipt;
    }

    // ── pending request map ──────────────────────────────────────────────────

    pub fn armRequest(self: *DynamicRegistry, id: []const u8, pending: types.PendingRequest) !void {
        const key = try self.alloc.dupe(u8, id);
        try self.pendingRequests.put(key, pending);
    }

    pub fn peekRequest(self: *DynamicRegistry, id: []const u8) ?types.PendingRequest {
        return self.pendingRequests.get(id);
    }

    pub fn claimRequest(self: *DynamicRegistry, id: []const u8) ?types.PendingRequest {
        const entry = self.pendingRequests.fetchRemove(id) orelse return null;
        self.alloc.free(entry.key);
        return entry.value;
    }

    pub fn disarmRequest(self: *DynamicRegistry, id: []const u8) void {
        if (self.pendingRequests.fetchRemove(id)) |entry| {
            self.alloc.free(entry.key);
            self.alloc.free(entry.value.agentId);
            self.alloc.free(entry.value.pluginId);
            self.alloc.free(entry.value.packageId);
            self.alloc.free(entry.value.pluginRunId);
        }
    }

    pub fn pendingRequestFor(self: *DynamicRegistry, pluginId: []const u8) ?[]const u8 {
        var it = self.pendingRequests.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.pluginId, pluginId)) return entry.key_ptr.*;
        }
        return null;
    }

    // ── approval settlement hooks (called by lifecycle.zig) ──────────────────
    // The registry owns only pointers + pending map; the sandbox evaluation
    // and frame broadcasts live in lifecycle.zig. These hooks mutate state
    // under the CALLER's lock — lifecycle serializes them.

    /// Grant one client package revision (page-approved). Idempotent.
    pub fn grantClientPackage(self: *DynamicRegistry, pluginId: []const u8, packageId: []const u8) !void {
        const p = self.plugins.get(pluginId) orelse return error.PluginNotFound;
        if (p.approved_client_packages.contains(packageId)) return;
        const key = try self.alloc.dupe(u8, packageId);
        try p.approved_client_packages.put(key, {});
    }

    /// Stale-revision-safe commit of an approved activation (spec §5):
    /// validates latest_run identity against `(pluginRunId, packageId)`,
    /// moves `currentPackageId` only on this complete success, clears
    /// `nextPackageId`, installs the physical run (carrying the approval id
    /// as `startedForRequest`), and settles latestRun half statuses.
    pub fn commitApprovedRun(
        self: *DynamicRegistry,
        pluginId: []const u8,
        pluginRunId: []const u8,
        packageId: []const u8,
    ) RegistryError!void {
        const p = self.plugins.get(pluginId) orelse return error.PluginNotFound;
        const lr_ptr = &(p.latest_run orelse return error.StaleRevision);
        if (!std.mem.eql(u8, lr_ptr.pluginRunId, pluginRunId)) return error.StaleRevision;
        if (!std.mem.eql(u8, lr_ptr.packageId, packageId)) return error.StaleRevision;
        const pkg = p.packages.get(packageId) orelse return error.PackageNotFound;

        // Allocate everything before mutating so failure cannot strand state.
        const started_for: ?[]u8 = if (lr_ptr.approvalRequestId) |a| try self.alloc.dupe(u8, a) else null;
        errdefer if (started_for) |s| self.alloc.free(s);
        const cur_dupe = try self.alloc.dupe(u8, packageId);
        errdefer self.alloc.free(cur_dupe);
        const run_id_d = try self.alloc.dupe(u8, pluginRunId);
        errdefer self.alloc.free(run_id_d);
        const run_pkg_d = try self.alloc.dupe(u8, packageId);
        errdefer self.alloc.free(run_pkg_d);

        // Move current pointer; next pointer cleared on complete success.
        if (p.current_package_id) |old| self.alloc.free(old);
        p.current_package_id = cur_dupe;
        if (p.next_package_id) |old| {
            self.alloc.free(old);
            p.next_package_id = null;
        }

        // Replace the physical run.
        if (p.run) |r| {
            self.alloc.free(r.pluginRunId);
            self.alloc.free(r.packageId);
            if (r.startedForRequest) |a| self.alloc.free(a);
            if (r.renderFailure) |rf| {
                self.alloc.free(rf.slot);
                self.alloc.free(rf.message);
                if (rf.stack) |s| self.alloc.free(s);
            }
        }
        p.run = .{ .pluginRunId = run_id_d, .packageId = run_pkg_d, .startedForRequest = started_for };

        // Settle latestRun diagnostics: host running, client waiting for its
        // page bind (delivery is broadcast best-effort from lifecycle.zig).
        lr_ptr.status = .running;
        lr_ptr.host = .{ .status = if (pkg.hostCode == null) .absent else .running };
        lr_ptr.client = .{ .status = if (pkg.clientCode == null) .absent else .waiting };
        if (lr_ptr.approvalRequestId) |a| {
            self.alloc.free(a);
            lr_ptr.approvalRequestId = null;
        }
        lr_ptr.requiresApproval = null;
    }

    /// Record host-half failure diagnostics on latestRun (spec §5:
    /// currentPackageId preserved untouched, error retained).
    pub fn failRun(
        self: *DynamicRegistry,
        pluginId: []const u8,
        pluginRunId: []const u8,
        phase: []const u8,
        err_msg: []const u8,
    ) void {
        const p = self.plugins.get(pluginId) orelse return;
        const lr_ptr = &(p.latest_run orelse return);
        if (!std.mem.eql(u8, lr_ptr.pluginRunId, pluginRunId)) return;
        lr_ptr.status = .failed;
        if (lr_ptr.err) |e| self.alloc.free(e);
        lr_ptr.err = self.alloc.dupe(u8, err_msg) catch null;
        if (lr_ptr.phase) |ph| self.alloc.free(ph);
        lr_ptr.phase = self.alloc.dupe(u8, phase) catch null;
        if (lr_ptr.host.status != .absent) {
            if (lr_ptr.host.err) |e| self.alloc.free(e);
            lr_ptr.host = .{ .status = .failed, .err = self.alloc.dupe(u8, err_msg) catch null };
        }
    }

    /// Mark latestRun rejected (page declined); clears approval linkage,
    /// keeps nextPackageId for diagnostics.
    pub fn rejectRun(self: *DynamicRegistry, pluginId: []const u8, pluginRunId: []const u8) void {
        const p = self.plugins.get(pluginId) orelse return;
        const lr_ptr = &(p.latest_run orelse return);
        if (!std.mem.eql(u8, lr_ptr.pluginRunId, pluginRunId)) return;
        lr_ptr.status = .rejected;
        if (lr_ptr.approvalRequestId) |a| {
            self.alloc.free(a);
            lr_ptr.approvalRequestId = null;
        }
        lr_ptr.requiresApproval = null;
    }

    /// Mark latestRun cancelled (stop / abort signal path); same shape as
    /// reject without the decline semantics.
    pub fn cancelLatestRun(self: *DynamicRegistry, pluginId: []const u8, pluginRunId: []const u8) void {
        const p = self.plugins.get(pluginId) orelse return;
        const lr_ptr = &(p.latest_run orelse return);
        if (!std.mem.eql(u8, lr_ptr.pluginRunId, pluginRunId)) return;
        lr_ptr.status = .cancelled;
        if (lr_ptr.approvalRequestId) |a| {
            self.alloc.free(a);
            lr_ptr.approvalRequestId = null;
        }
        lr_ptr.requiresApproval = null;
    }

    /// Session-less metadata read for the wire/invoke paths (spec §6:
    /// resolveRequestRun/invoke carry no session). Slices are valid while
    /// the caller holds its lock and the plugin is not undefined.
    pub const PackageMeta = struct {
        name: []const u8,
        purpose: []const u8,
        host_code: ?[]const u8,
    };

    pub fn packageMeta(self: *DynamicRegistry, pluginId: []const u8, packageId: []const u8) ?PackageMeta {
        const p = self.plugins.get(pluginId) orelse return null;
        const pkg = p.packages.get(packageId) orelse return null;
        return .{ .name = pkg.name, .purpose = pkg.purpose, .host_code = pkg.hostCode };
    }

    /// Live attempt identity for stale-revision checks by the resolver.
    pub const RunIdentity = struct {
        plugin_run_id: []const u8,
        package_id: []const u8,
        status: types.RunStatus,
        err: ?[]const u8 = null,
    };

    pub fn latestRunIdentity(self: *DynamicRegistry, pluginId: []const u8) ?RunIdentity {
        const p = self.plugins.get(pluginId) orelse return null;
        const lr = p.latest_run orelse return null;
        return .{
            .plugin_run_id = lr.pluginRunId,
            .package_id = lr.packageId,
            .status = lr.status,
            .err = lr.err,
        };
    }

    // ── stop / undefine ──────────────────────────────────────────────────────

    pub fn stop(self: *DynamicRegistry, sessionId: []const u8, pluginId: []const u8) RegistryError!types.StopResult {
        const plugin = self.owned(sessionId, pluginId) orelse return error.PluginNotFound;
        const pending = self.pendingRequestFor(pluginId);
        const has_run = plugin.run != null;
        if (pending == null and !has_run) return .{ .not_running = {} };

        if (pending) |pid| {
            const dup = try self.alloc.dupe(u8, pid);
            defer self.alloc.free(dup);
            self.disarmRequest(dup);
            if (plugin.latest_run) |*lr| {
                lr.status = .cancelled;
                // clear approval linkage
                if (lr.approvalRequestId) |a| {
                    self.alloc.free(a);
                    lr.approvalRequestId = null;
                }
                lr.requiresApproval = null;
            }
        }
        if (plugin.run) |r| {
            // retract broadcast happens in wire.zig; registry just clears state
            self.alloc.free(r.pluginRunId);
            self.alloc.free(r.packageId);
            if (r.startedForRequest) |a| self.alloc.free(a);
            if (r.renderFailure) |rf| {
                self.alloc.free(rf.slot);
                self.alloc.free(rf.message);
                if (rf.stack) |s| self.alloc.free(s);
            }
            plugin.run = null;
        }
        if (plugin.latest_run) |*lr| {
            lr.status = .stopped;
            if (lr.host.status != .absent) lr.host = .{ .status = .stopped };
            if (lr.client.status != .absent) lr.client = .{ .status = .stopped };
        }
        return .{ .ok = {} };
    }

    pub fn undefine(self: *DynamicRegistry, sessionId: []const u8, pluginId: []const u8) RegistryError!types.UndefineResult {
        const plugin = self.owned(sessionId, pluginId) orelse return error.PluginNotFound;
        const wasRunning = plugin.run != null or self.pendingRequestFor(pluginId) != null;
        // stop first (idempotent)
        if (self.pendingRequestFor(pluginId)) |pid| {
            const dup = try self.alloc.dupe(u8, pid);
            defer self.alloc.free(dup);
            self.disarmRequest(dup);
        }
        if (plugin.run) |r| {
            self.alloc.free(r.pluginRunId);
            self.alloc.free(r.packageId);
            if (r.startedForRequest) |a| self.alloc.free(a);
            if (r.renderFailure) |rf| {
                self.alloc.free(rf.slot);
                self.alloc.free(rf.message);
                if (rf.stack) |s| self.alloc.free(s);
            }
            plugin.run = null;
        }
        // remove from map
        const entry = self.plugins.fetchRemove(pluginId) orelse return error.PluginNotFound;
        self.alloc.free(entry.key);
        entry.value.deinit(self.alloc);
        self.alloc.destroy(entry.value);
        return .{ .wasRunning = wasRunning };
    }

    // ── inventory (global) vs snapshot (session-scoped) ──────────────────────

    pub fn inventory(self: *DynamicRegistry, alloc: std.mem.Allocator) ![]types.InventoryRow {
        var out: std.ArrayList(types.InventoryRow) = .empty;
        errdefer out.deinit(alloc);
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            var pkgs: std.ArrayList(types.InventoryPackage) = .empty;
            errdefer pkgs.deinit(alloc);
            for (p.package_order.items) |pid| {
                const pkg = p.packages.get(pid) orelse continue;
                try pkgs.append(alloc, .{
                    .packageId = pkg.package_id,
                    .name = pkg.name,
                    .purpose = pkg.purpose,
                    .hasHostHalf = pkg.hostCode != null,
                    .hasClientHalf = pkg.clientCode != null,
                });
            }
            const row = types.InventoryRow{
                .pluginId = p.plugin_id,
                .agentId = p.session_id,
                .packages = try pkgs.toOwnedSlice(alloc),
                .currentPackageId = p.current_package_id,
                .nextPackageId = p.next_package_id,
                .activeRun = if (p.run) |r| .{ .pluginRunId = r.pluginRunId, .packageId = r.packageId } else null,
                .latestRun = p.latest_run,
            };
            try out.append(alloc, row);
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn snapshot(self: *DynamicRegistry, alloc: std.mem.Allocator, sessionId: []const u8) ![]types.SnapshotRow {
        var out: std.ArrayList(types.SnapshotRow) = .empty;
        errdefer out.deinit(alloc);
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            if (!std.mem.eql(u8, p.session_id, sessionId)) continue;
            var pkgs: std.ArrayList(types.SnapshotPackage) = .empty;
            errdefer pkgs.deinit(alloc);
            for (p.package_order.items) |pid| {
                const pkg = p.packages.get(pid) orelse continue;
                try pkgs.append(alloc, .{
                    .packageId = pkg.package_id,
                    .name = pkg.name,
                    .purpose = pkg.purpose,
                    .hasHostHalf = pkg.hostCode != null,
                    .hasClientHalf = pkg.clientCode != null,
                });
            }
            const row = types.SnapshotRow{
                .pluginId = p.plugin_id,
                .currentPackageId = p.current_package_id,
                .nextPackageId = p.next_package_id,
                .packages = try pkgs.toOwnedSlice(alloc),
                .activeRun = if (p.run) |r| .{ .pluginRunId = r.pluginRunId, .packageId = r.packageId, .renderFailure = r.renderFailure } else null,
                .latestRun = p.latest_run,
            };
            try out.append(alloc, row);
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn listPlugins(self: *DynamicRegistry, alloc: std.mem.Allocator, sessionId: []const u8) ![]types.PluginInspection {
        var out: std.ArrayList(types.PluginInspection) = .empty;
        errdefer out.deinit(alloc);
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            if (!std.mem.eql(u8, p.session_id, sessionId)) continue;
            const ref = try self.referenceAlloc(alloc, sessionId, p.plugin_id);
            if (ref == null) continue;
            const r = ref.?;
            var pkgs: std.ArrayList(types.InventoryPackage) = .empty;
            errdefer pkgs.deinit(alloc);
            for (p.package_order.items) |pid| {
                const pkg = p.packages.get(pid) orelse continue;
                try pkgs.append(alloc, .{
                    .packageId = pkg.package_id,
                    .name = pkg.name,
                    .purpose = pkg.purpose,
                    .hasHostHalf = pkg.hostCode != null,
                    .hasClientHalf = pkg.clientCode != null,
                });
            }
            try out.append(alloc, .{
                .pluginId = r.pluginId,
                .packageId = r.packageId,
                .name = r.name,
                .purpose = r.purpose,
                .currentPackageId = r.currentPackageId,
                .nextPackageId = r.nextPackageId,
                .activeRun = r.activeRun,
                .latestRun = r.latestRun,
                .packages = try pkgs.toOwnedSlice(alloc),
            });
        }
        return out.toOwnedSlice(alloc);
    }

    // ── reference (@-mention) — session-scoped, reads as absent not forbidden ─

    pub fn reference(self: *DynamicRegistry, sessionId: []const u8, pluginId: []const u8) ?types.Reference {
        const p = self.owned(sessionId, pluginId) orelse return null;
        // preferred base: next ?? current ?? last defined
        const base_id: []const u8 = if (p.next_package_id) |v| v else if (p.current_package_id) |v| v else blk: {
            if (p.package_order.items.len == 0) return null;
            break :blk p.package_order.items[p.package_order.items.len - 1];
        };
        const pkg = p.packages.get(base_id) orelse return null;
        return types.Reference{
            .pluginId = p.plugin_id,
            .packageId = pkg.package_id,
            .name = pkg.name,
            .purpose = pkg.purpose,
            .currentPackageId = p.current_package_id,
            .nextPackageId = p.next_package_id,
            .activeRun = if (p.run) |r| .{ .pluginRunId = r.pluginRunId, .packageId = r.packageId } else null,
            .latestRun = p.latest_run,
        };
    }

    fn referenceAlloc(self: *DynamicRegistry, alloc: std.mem.Allocator, sessionId: []const u8, pluginId: []const u8) !?types.Reference {
        _ = alloc;
        return self.reference(sessionId, pluginId);
    }

    pub fn inspectPlugin(self: *DynamicRegistry, sessionId: []const u8, pluginId: []const u8) RegistryError!types.PluginInspection {
        const p = self.owned(sessionId, pluginId) orelse return error.PluginNotFound;
        const ref = self.reference(sessionId, pluginId) orelse return error.PackageNotFound;
        var pkgs: std.ArrayList(types.InventoryPackage) = .empty;
        errdefer pkgs.deinit(self.alloc);
        for (p.package_order.items) |pid| {
            const pkg = p.packages.get(pid) orelse continue;
            try pkgs.append(self.alloc, .{
                .packageId = pkg.package_id,
                .name = pkg.name,
                .purpose = pkg.purpose,
                .hasHostHalf = pkg.hostCode != null,
                .hasClientHalf = pkg.clientCode != null,
            });
        }
        const owned_pkgs = try self.alloc.alloc(types.InventoryPackage, pkgs.items.len);
        @memcpy(owned_pkgs, pkgs.items);
        pkgs.deinit(self.alloc);
        return types.PluginInspection{
            .pluginId = ref.pluginId,
            .packageId = ref.packageId,
            .name = ref.name,
            .purpose = ref.purpose,
            .currentPackageId = ref.currentPackageId,
            .nextPackageId = ref.nextPackageId,
            .activeRun = ref.activeRun,
            .latestRun = ref.latestRun,
            .packages = owned_pkgs,
        };
    }

    pub fn inspectPackage(
        self: *DynamicRegistry,
        sessionId: []const u8,
        pluginId: []const u8,
        packageId: []const u8,
    ) RegistryError!types.PackageInspection {
        const p = self.owned(sessionId, pluginId) orelse return error.PluginNotFound;
        const pkg = p.packages.get(packageId) orelse return error.PackageNotFound;
        return types.PackageInspection{
            .pluginId = p.plugin_id,
            .packageId = pkg.package_id,
            .name = pkg.name,
            .purpose = pkg.purpose,
            .code = .{ .host = pkg.hostCode, .client = pkg.clientCode },
            .currentPackageId = p.current_package_id,
            .nextPackageId = p.next_package_id,
            .activeRun = if (p.run) |r| .{ .pluginRunId = r.pluginRunId, .packageId = r.packageId } else null,
            .latestRun = p.latest_run,
        };
    }

    pub fn peekManifest(self: *DynamicRegistry, sessionId: []const u8, pluginId: []const u8) ?[]const u8 {
        const p = self.owned(sessionId, pluginId) orelse return null;
        _ = p;
        return null;
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

test "mint ids are monotonic and prefixed" {
    var reg = DynamicRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const a = try reg.mintPluginId("foo");
    defer std.testing.allocator.free(a);
    const b = try reg.mintPluginId("foo");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("foo-1", a);
    try std.testing.expectEqualStrings("foo-2", b);
    const pkg1 = try reg.mintPackageId();
    defer std.testing.allocator.free(pkg1);
    const pkg2 = try reg.mintPackageId();
    defer std.testing.allocator.free(pkg2);
    try std.testing.expectEqualStrings("pkg-1", pkg1);
    try std.testing.expectEqualStrings("pkg-2", pkg2);
    const run1 = try reg.mintRunId();
    defer std.testing.allocator.free(run1);
    try std.testing.expectEqualStrings("run-1", run1);
    const appr1 = try reg.mintApprovalId();
    defer std.testing.allocator.free(appr1);
    try std.testing.expectEqualStrings("approval-1", appr1);
}

test "define new plugin mints pluginId and pkg-1" {
    var reg = DynamicRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const r = try reg.define(.{
        .session_id = "sess-1",
        .plugin = .{ .new = .{ .idPrefix = "demo" } },
        .name = "My Plugin",
        .purpose = "does stuff",
        .code = .{ .host = "return { apply(ctx){} }", .client = null },
    });
    try std.testing.expect(std.mem.startsWith(u8, r.plugin_id, "demo-"));
    try std.testing.expectEqualStrings("pkg-1", r.package_id);
    try std.testing.expect(r.has_host);
    try std.testing.expect(!r.has_client);
    try std.testing.expectEqual(@as(usize, 1), reg.plugins.count());
}

test "define existing appends pkg-N with ownership check" {
    var reg = DynamicRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const r1 = try reg.define(.{
        .session_id = "sess-1",
        .plugin = .{ .new = .{ .idPrefix = "abc" } },
        .name = "p1",
        .purpose = "first",
        .code = .{ .host = "return {}" },
    });
    const r2 = try reg.define(.{
        .session_id = "sess-1",
        .plugin = .{ .existing = r1.plugin_id },
        .name = "p2",
        .purpose = "second",
        .code = .{ .client = "return {}" },
    });
    try std.testing.expectEqualStrings(r1.plugin_id, r2.plugin_id);
    try std.testing.expectEqualStrings("pkg-2", r2.package_id);
    // cross-session must fail
    try std.testing.expectError(error.NotOwner, reg.define(.{
        .session_id = "sess-2",
        .plugin = .{ .existing = r1.plugin_id },
        .name = "evil",
        .purpose = "hijack",
        .code = .{ .host = "return {}" },
    }));
}

test "session-scoped visibility: inventory global, snapshot filtered, reference absent not forbidden" {
    var reg = DynamicRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const r1 = try reg.define(.{
        .session_id = "sess-1",
        .plugin = .{ .new = .{ .idPrefix = "abc" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "return {}" },
    });
    _ = r1;
    // inventory sees it with agentId
    const inv = try reg.inventory(std.testing.allocator);
    defer {
        for (inv) |row| std.testing.allocator.free(row.packages);
        std.testing.allocator.free(inv);
    }
    try std.testing.expectEqual(@as(usize, 1), inv.len);
    try std.testing.expectEqualStrings("sess-1", inv[0].agentId);
    // snapshot for other session is empty
    const snap_other = try reg.snapshot(std.testing.allocator, "sess-2");
    defer {
        for (snap_other) |row| std.testing.allocator.free(row.packages);
        std.testing.allocator.free(snap_other);
    }
    try std.testing.expectEqual(@as(usize, 0), snap_other.len);
    // reference cross-session reads absent (null) not error leak
    try std.testing.expect(reg.reference("sess-2", inv[0].pluginId) == null);
    try std.testing.expect(reg.reference("sess-1", inv[0].pluginId) != null);
}

test "run validates mode vs currentPackageId" {
    var reg = DynamicRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const d1 = try reg.define(.{
        .session_id = "s",
        .plugin = .{ .new = .{ .idPrefix = "abc" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "return {}" },
    });
    const d2 = try reg.define(.{
        .session_id = "s",
        .plugin = .{ .existing = d1.plugin_id },
        .name = "n2",
        .purpose = "p2",
        .code = .{ .host = "return {}" },
    });
    // first run with mode run succeeds (host-only commits to running)
    const run1 = try reg.run("s", d1.plugin_id, d1.package_id, .run);
    defer {
        std.testing.allocator.free(run1.pluginRunId);
        std.testing.allocator.free(run1.packageId);
        if (run1.currentPackageId) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(run1.nextPackageId);
        if (run1.approvalRequestId) |v| std.testing.allocator.free(v);
    }
    try std.testing.expect(run1.status == .running);
    // run same again is restart allowed
    const run_same = try reg.run("s", d1.plugin_id, d1.package_id, .run);
    defer {
        std.testing.allocator.free(run_same.pluginRunId);
        std.testing.allocator.free(run_same.packageId);
        if (run_same.currentPackageId) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(run_same.nextPackageId);
        if (run_same.approvalRequestId) |v| std.testing.allocator.free(v);
    }
    try std.testing.expect(run_same.status == .running);
    // run different with mode run must fail (needs update)
    try std.testing.expectError(error.InvalidMode, reg.run("s", d1.plugin_id, d2.package_id, .run));
    // update to different succeeds
    const upd = try reg.run("s", d1.plugin_id, d2.package_id, .update);
    defer {
        std.testing.allocator.free(upd.pluginRunId);
        std.testing.allocator.free(upd.packageId);
        if (upd.currentPackageId) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(upd.nextPackageId);
        if (upd.approvalRequestId) |v| std.testing.allocator.free(v);
    }
    try std.testing.expect(upd.status == .running);
}

test "stop and undefine retain packages, clear run" {
    var reg = DynamicRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const d = try reg.define(.{
        .session_id = "s",
        .plugin = .{ .new = .{ .idPrefix = "xyz" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "return {}" },
    });
    {
        const r = try reg.run("s", d.plugin_id, d.package_id, .run);
        defer {
            std.testing.allocator.free(r.pluginRunId);
            std.testing.allocator.free(r.packageId);
            if (r.currentPackageId) |v| std.testing.allocator.free(v);
            std.testing.allocator.free(r.nextPackageId);
            if (r.approvalRequestId) |v| std.testing.allocator.free(v);
        }
    }
    const st = try reg.stop("s", d.plugin_id);
    try std.testing.expect(st == .ok);
    // idempotent second stop returns not_running
    const st2 = try reg.stop("s", d.plugin_id);
    try std.testing.expect(st2 == .not_running);
    // packages retained until undefine
    const p = reg.getPlugin(d.plugin_id).?;
    try std.testing.expectEqual(@as(usize, 1), p.packages.count());
    const ud = try reg.undefine("s", d.plugin_id);
    try std.testing.expect(ud.wasRunning == false); // already stopped
    try std.testing.expect(reg.getPlugin(d.plugin_id) == null);
}

test "define rejects bad prefix and missing code" {
    var reg = DynamicRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectError(error.InvalidPrefix, reg.define(.{
        .session_id = "s",
        .plugin = .{ .new = .{ .idPrefix = "AB" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "return {}" },
    }));
    try std.testing.expectError(error.MissingCode, reg.define(.{
        .session_id = "s",
        .plugin = .{ .new = .{ .idPrefix = "abc" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = null, .client = null },
    }));
}

test "client-bearing run arms pending approval" {
    var reg = DynamicRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const d = try reg.define(.{
        .session_id = "s",
        .plugin = .{ .new = .{ .idPrefix = "abc" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "return {}", .client = "return {}" },
    });
    const r = try reg.run("s", d.plugin_id, d.package_id, .run);
    defer {
        std.testing.allocator.free(r.pluginRunId);
        std.testing.allocator.free(r.packageId);
        if (r.currentPackageId) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(r.nextPackageId);
        if (r.approvalRequestId) |v| std.testing.allocator.free(v);
    }
    try std.testing.expect(r.status == .awaiting_approval);
    try std.testing.expect(r.requiresApproval.? == true);
    try std.testing.expect(reg.pendingRequestFor(d.plugin_id) != null);
}

test "settlement hooks: stale guard, commit, reject, fail" {
    const alloc = std.testing.allocator;
    var reg = DynamicRegistry.init(alloc);
    defer reg.deinit();
    const d = try reg.define(.{
        .session_id = "s",
        .plugin = .{ .new = .{ .idPrefix = "abc" } },
        .name = "n",
        .purpose = "p",
        .code = .{ .host = "return {}", .client = "return {}" },
    });
    const r = try reg.run("s", d.plugin_id, d.package_id, .run);
    defer {
        alloc.free(r.pluginRunId);
        alloc.free(r.packageId);
        if (r.currentPackageId) |v| alloc.free(v);
        alloc.free(r.nextPackageId);
        if (r.approvalRequestId) |v| alloc.free(v);
    }
    try std.testing.expect(r.status == .awaiting_approval);

    // Wrong run id → stale.
    try std.testing.expectError(error.StaleRevision, reg.commitApprovedRun(d.plugin_id, "run-999", d.package_id));
    // Correct identity commits; currentPackageId moves, grant recorded.
    try reg.grantClientPackage(d.plugin_id, d.package_id);
    try reg.grantClientPackage(d.plugin_id, d.package_id); // idempotent
    try reg.commitApprovedRun(d.plugin_id, r.pluginRunId, d.package_id);
    const p = reg.getPlugin(d.plugin_id).?;
    try std.testing.expectEqualStrings(d.package_id, p.current_package_id.?);
    try std.testing.expect(p.next_package_id == null);
    try std.testing.expect(p.approved_client_packages.contains(d.package_id));
    try std.testing.expectEqual(types.RunStatus.running, p.latest_run.?.status);
    try std.testing.expect(p.run != null);
    try std.testing.expect(p.latest_run.?.approvalRequestId == null);
    // Committed identity no longer matches a second commit attempt shape-wise
    // but same ids still pass validation (idempotent re-commit is harmless).
    try reg.commitApprovedRun(d.plugin_id, r.pluginRunId, d.package_id);
    try std.testing.expectEqualStrings(d.package_id, p.current_package_id.?);

    // Reject + cancel settle latestRun on matching identity only.
    reg.rejectRun(d.plugin_id, "run-999");
    try std.testing.expectEqual(types.RunStatus.running, p.latest_run.?.status);
    reg.cancelLatestRun(d.plugin_id, r.pluginRunId);
    try std.testing.expectEqual(types.RunStatus.cancelled, p.latest_run.?.status);

    reg.failRun(d.plugin_id, r.pluginRunId, "starting-host", "boom");
    try std.testing.expectEqual(types.RunStatus.failed, p.latest_run.?.status);
    try std.testing.expectEqualStrings("starting-host", p.latest_run.?.phase.?);
    try std.testing.expectEqualStrings("boom", p.latest_run.?.err.?);

    // packageMeta / latestRunIdentity accessors
    const meta = reg.packageMeta(d.plugin_id, d.package_id).?;
    try std.testing.expectEqualStrings("n", meta.name);
    try std.testing.expect(meta.host_code != null);
    const ident = reg.latestRunIdentity(d.plugin_id).?;
    try std.testing.expectEqual(types.RunStatus.failed, ident.status);
    try std.testing.expect(reg.packageMeta(d.plugin_id, "pkg-999") == null);
}
