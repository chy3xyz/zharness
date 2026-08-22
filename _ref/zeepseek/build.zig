const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/zeepseek_c.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_mod = translate_c.createModule();

    // ── ZigZag dependency ─────────────────────────────────────────────
    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Single root module at src/main.zig ────────────────────────────
    // Lets all subdirectories (ui, dispatch, net, cache, utils, storage,
    // tools, etc.) cross-import via relative paths. Only the two named
    // imports actually referenced by source are registered below.
    const root_mod = b.addModule("zeepseek", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addImport("c", c_mod);
    root_mod.addImport("zigzag", zigzag_dep.module("zigzag"));

    const exe = b.addExecutable(.{
        .name = "zeepseek",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    const run_step = b.step("run", "Run zeepseek TUI");
    run_step.dependOn(&run.step);

    // ── Unit tests ────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("c", c_mod);
    test_mod.addImport("zigzag", zigzag_dep.module("zigzag"));

    const test_build = b.addTest(.{ .root_module = test_mod });
    const test_run = b.addRunArtifact(test_build);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&test_run.step);

    // ── Integration tests ─────────────────────────────────────────────
    // Require external services and are intentionally NOT part of `zig build
    // test`: http2_tests.zig expects an echo server on 127.0.0.1:18472,
    // h2_live_test.zig needs DEEPSEEK_API_KEY (skips when absent).
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("src/integration_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_mod.addImport("c", c_mod);

    const integration_build = b.addTest(.{ .root_module = integration_mod });
    const integration_run = b.addRunArtifact(integration_build);
    const integration_step = b.step("integration-test", "Run integration tests (echo server on :18472, DEEPSEEK_API_KEY)");
    integration_step.dependOn(&integration_run.step);

    const integration_compile_step = b.step("integration-test-compile", "Compile integration tests without running (no external services required)");
    integration_compile_step.dependOn(&integration_build.step);
}
