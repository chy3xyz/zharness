// Dynamic Cordis runtime types — session-scoped, process-heap, metadata-only.
// Mirrors docs/dynamic-cordis-spec.md §5-6 and _ref/deepseek-harness/packages/extensions/cordis-host-runner/src/types.ts + registry.ts
//
// Branded ids: PluginId = "<prefix>-<n>"  PackageId = "pkg-<n>"  RunId = "run-<n>"  ApprovalId = "approval-<n>"
// Session-scoped visibility: a definition is visible and controllable only in the
// session that defined it (sessionId on Plugin). Inventory lists global rows with
// agentId for display but acting verbs (run/stop/undefine/inspect) enforce owner.
// Process-heap: registry lives in process memory, never written to
// ~/.zharness/sessions/<id>.json, cordis.yml, or disk plugins. Session log carries
// only cordis_define metadata (name, purpose, pluginId, packageId) — never source.

const std = @import("std");

pub const PluginId = []const u8;
pub const PackageId = []const u8;
pub const RunId = []const u8;
pub const ApprovalId = []const u8;
pub const SessionId = []const u8;

pub const RunMode = enum {
    run,
    update,

    pub fn fromStr(s: []const u8) ?RunMode {
        if (std.mem.eql(u8, s, "run")) return .run;
        if (std.mem.eql(u8, s, "update")) return .update;
        return null;
    }
    pub fn asStr(self: RunMode) []const u8 {
        return switch (self) {
            .run => "run",
            .update => "update",
        };
    }
};

pub const RunStatus = enum {
    awaiting_approval,
    starting_host,
    client_pending,
    running,
    waiting,
    rejected,
    failed,
    cancelled,
    stopped,

    pub fn asStr(self: RunStatus) []const u8 {
        return switch (self) {
            .awaiting_approval => "awaiting-approval",
            .starting_host => "starting-host",
            .client_pending => "client-pending",
            .running => "running",
            .waiting => "waiting",
            .rejected => "rejected",
            .failed => "failed",
            .cancelled => "cancelled",
            .stopped => "stopped",
        };
    }
};

pub const HalfStatus = enum {
    absent,
    pending,
    stopped,
    running,
    waiting,
    failed,

    pub fn asStr(self: HalfStatus) []const u8 {
        return switch (self) {
            .absent => "absent",
            .pending => "pending",
            .stopped => "stopped",
            .running => "running",
            .waiting => "waiting",
            .failed => "failed",
        };
    }
};

/// One platform half within an activation attempt.
pub const HalfState = struct {
    status: HalfStatus,
    waitingFor: []const []const u8 = &.{},
    err: ?[]const u8 = null,
};

/// Immutable package version (definition). Source never leaves heap.
pub const Package = struct {
    package_id: PackageId,
    name: []const u8,
    purpose: []const u8,
    hostCode: ?[]const u8 = null,
    clientCode: ?[]const u8 = null,

    pub fn hasHost(self: *const Package) bool {
        return self.hostCode != null;
    }
    pub fn hasClient(self: *const Package) bool {
        return self.clientCode != null;
    }
};

/// Physical active run (lifecycle owned). Distinct from latestRun (diagnostic history).
pub const Run = struct {
    pluginRunId: RunId,
    packageId: PackageId,
    // Render failure dual lifetime: page-kept vs host-kept
    renderFailure: ?RenderFailure = null,
    startedForRequest: ?ApprovalId = null,
};

/// Latest activation attempt — retained independently from physical run.
pub const RunAttempt = struct {
    pluginRunId: RunId,
    packageId: PackageId,
    mode: RunMode,
    status: RunStatus,
    approvalRequestId: ?ApprovalId = null,
    requiresApproval: ?bool = null,
    host: HalfState,
    client: HalfState,
    err: ?[]const u8 = null,
    // Diagnostic phase when failed
    phase: ?[]const u8 = null,
};

pub const RenderFailure = struct {
    slot: []const u8,
    message: []const u8,
    stack: ?[]const u8 = null,
    abdicated: bool = false,
};

/// Stable plugin instance containing immutable package versions.
pub const Plugin = struct {
    plugin_id: PluginId,
    session_id: SessionId,
    packages: std.StringHashMap(Package),
    /// Preserve define order for inventory/reference (map iteration is hash order).
    package_order: std.ArrayList([]const u8),
    approved_client_packages: std.StringHashMap(void),
    client_version_updates_approved: bool = false,
    current_package_id: ?PackageId = null,
    next_package_id: ?PackageId = null,
    run: ?Run = null,
    latest_run: ?RunAttempt = null,
    // per-plugin owned allocator reference not stored; registry owns alloc

    pub fn deinit(self: *Plugin, alloc: std.mem.Allocator) void {
        // packages: free keys + package strings
        var it = self.packages.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.package_id);
            alloc.free(entry.value_ptr.name);
            alloc.free(entry.value_ptr.purpose);
            if (entry.value_ptr.hostCode) |c| alloc.free(c);
            if (entry.value_ptr.clientCode) |c| alloc.free(c);
        }
        self.packages.deinit();
        // package_order holds non-owned views onto map keys; just deinit list
        self.package_order.deinit(alloc);
        var it2 = self.approved_client_packages.iterator();
        while (it2.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }
        self.approved_client_packages.deinit();
        if (self.current_package_id) |v| alloc.free(v);
        if (self.next_package_id) |v| alloc.free(v);
        if (self.run) |r| {
            alloc.free(r.pluginRunId);
            alloc.free(r.packageId);
            if (r.startedForRequest) |a| alloc.free(a);
            if (r.renderFailure) |rf| {
                alloc.free(rf.slot);
                alloc.free(rf.message);
                if (rf.stack) |s| alloc.free(s);
            }
        }
        if (self.latest_run) |lr| {
            alloc.free(lr.pluginRunId);
            alloc.free(lr.packageId);
            if (lr.approvalRequestId) |a| alloc.free(a);
            if (lr.err) |e| alloc.free(e);
            if (lr.phase) |p| alloc.free(p);
            if (lr.host.err) |e| alloc.free(e);
            if (lr.client.err) |e| alloc.free(e);
            // waitingFor slices are statically empty in this registry layer
        }
        alloc.free(self.plugin_id);
        alloc.free(self.session_id);
    }
};

pub const DefineRequest = struct {
    session_id: SessionId,
    plugin: union(enum) {
        new: struct { idPrefix: []const u8 },
        existing: PluginId,
    },
    name: []const u8,
    purpose: []const u8,
    code: struct {
        host: ?[]const u8 = null,
        client: ?[]const u8 = null,
    },
};

pub const DefineReceipt = struct {
    plugin_id: PluginId,
    package_id: PackageId,
    name: []const u8,
    purpose: []const u8,
    has_host: bool,
    has_client: bool,
};

pub const DynamicConfig = struct {
    vmTimeoutMs: u32 = 5000,
    maxClientSourceBytes: u32 = 256_000,
    maxInvokeBytes: u32 = 64_000,
};

pub const PendingRequest = struct {
    agentId: SessionId,
    pluginId: PluginId,
    packageId: PackageId,
    pluginRunId: RunId,
    mode: RunMode,
    requiresApproval: bool,
};

pub const InventoryPackage = struct {
    packageId: PackageId,
    name: []const u8,
    purpose: []const u8,
    hasHostHalf: bool,
    hasClientHalf: bool,
};

pub const InventoryRow = struct {
    pluginId: PluginId,
    agentId: SessionId,
    packages: []InventoryPackage,
    currentPackageId: ?PackageId = null,
    nextPackageId: ?PackageId = null,
    activeRun: ?struct {
        pluginRunId: RunId,
        packageId: PackageId,
    } = null,
    latestRun: ?RunAttempt = null,
};

pub const SnapshotPackage = struct {
    packageId: PackageId,
    name: []const u8,
    purpose: []const u8,
    hasHostHalf: bool,
    hasClientHalf: bool,
};

pub const SnapshotRow = struct {
    pluginId: PluginId,
    currentPackageId: ?PackageId = null,
    nextPackageId: ?PackageId = null,
    packages: []SnapshotPackage,
    activeRun: ?struct {
        pluginRunId: RunId,
        packageId: PackageId,
        renderFailure: ?RenderFailure = null,
    } = null,
    latestRun: ?RunAttempt = null,
};

pub const Reference = struct {
    pluginId: PluginId,
    packageId: PackageId,
    name: []const u8,
    purpose: []const u8,
    currentPackageId: ?PackageId = null,
    nextPackageId: ?PackageId = null,
    activeRun: ?struct {
        pluginRunId: RunId,
        packageId: PackageId,
    } = null,
    latestRun: ?RunAttempt = null,
};

pub const PluginInspection = struct {
    pluginId: PluginId,
    packageId: PackageId,
    name: []const u8,
    purpose: []const u8,
    currentPackageId: ?PackageId = null,
    nextPackageId: ?PackageId = null,
    activeRun: ?struct {
        pluginRunId: RunId,
        packageId: PackageId,
    } = null,
    latestRun: ?RunAttempt = null,
    packages: []InventoryPackage,
};

pub const PackageInspection = struct {
    pluginId: PluginId,
    packageId: PackageId,
    name: []const u8,
    purpose: []const u8,
    code: struct {
        host: ?[]const u8 = null,
        client: ?[]const u8 = null,
    },
    currentPackageId: ?PackageId = null,
    nextPackageId: ?PackageId = null,
    activeRun: ?struct {
        pluginRunId: RunId,
        packageId: PackageId,
    } = null,
    latestRun: ?RunAttempt = null,
};

pub const RunReceipt = struct {
    pluginRunId: RunId,
    packageId: PackageId,
    pluginId: PluginId,
    mode: RunMode,
    status: enum { awaiting_approval, starting, running },
    requiresApproval: ?bool = null,
    approvalRequestId: ?ApprovalId = null,
    currentPackageId: ?PackageId = null,
    nextPackageId: PackageId,
};

pub const StopResult = union(enum) {
    ok: void,
    not_running: void,
    plugin_missing: []const u8,
};

pub const UndefineResult = struct {
    wasRunning: bool,
};

// ── helpers ──────────────────────────────────────────────────────────────────

pub fn isValidPrefix(s: []const u8) bool {
    if (s.len < 3 or s.len > 6) return false;
    for (s) |c| {
        if (c < 'a' or c > 'z') return false;
    }
    return true;
}

pub fn trimmedNonEmpty(s: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return null;
    return t;
}
