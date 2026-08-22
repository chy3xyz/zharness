const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zcordis — the runtime kernel zharness is built on top of.
    const cordis_dep = b.dependency("zcordis", .{
        .target = target,
        .optimize = optimize,
    });
    const cordis_mod = cordis_dep.module("cordis");

    // ── zharness executable ───────────────────────────────────────────────
    // Single root module: src/ shares one namespace (zcordis/zeepseek pattern),
    // so files cross-import via relative `@import("agent/agent.zig")` paths.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("cordis", cordis_mod);

    const exe = b.addExecutable(.{
        .name = "zharness",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run zharness");
    run_step.dependOn(&run_exe.step);

    // ── unit tests ────────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("cordis", cordis_mod);

    const test_exe = b.addTest(.{
        .name = "zharness-tests",
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(test_exe);
    if (b.option([]const u8, "test-filter", "Only run tests whose name contains this string")) |filter| {
        run_tests.addArg("--test-filter");
        run_tests.addArg(filter);
    }
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
