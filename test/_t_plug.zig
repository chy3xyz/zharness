//! pluginabi self-test root (G-pluginabi).
//!
//! Run from the repo root:  `zig test -lc test/_t_plug.zig`
//!
//! Pulls in every pluginabi module so their inline tests run, then adds the
//! ONE dlopen-dependent smoke test: it loads examples/plugin-hello/build/
//! ONLY if build.sh has produced a dylib there — otherwise it skips, keeping
//! CI hermetic (no compiler invocation from tests, no network).

const std = @import("std");

test {
    _ = @import("../src/pluginabi/capi.zig");
    _ = @import("../src/pluginabi/ffi.zig");
    _ = @import("../src/pluginabi/loader.zig");
}

// End-to-end round trip against the real C example plugin:
// discover → load → validate manifest → project tool names → execute →
// copy result → free plugin-side buffer → unload. Skipped when
// examples/plugin-hello/build/ has no built artifact.
test "smoke: load hello plugin dylib and execute its tool" {
    const alloc = std.testing.allocator;
    const loader = @import("../src/pluginabi/loader.zig");

    // Locate the built artifact (macOS name first, Linux second).
    const build_dir = "examples/plugin-hello/build";
    const io = std.testing.io;
    const candidates = [_][]const u8{ build_dir ++ "/hello.dylib", build_dir ++ "/hello.so" };
    var have_artifact = false;
    for (candidates) |p| {
        std.Io.Dir.cwd().access(io, p, .{}) catch continue;
        have_artifact = true;
        break;
    }
    if (!have_artifact) {
        std.debug.print("smoke test skipped: run ./examples/plugin-hello/build.sh to build the fixture\n", .{});
        return error.SkipZigTest;
    }

    var reg = loader.PluginRegistry.init(alloc);
    defer reg.deinit();

    const loaded = reg.loadDir(io, build_dir);
    try std.testing.expectEqual(@as(usize, 1), loaded);
    try std.testing.expectEqual(@as(usize, 0), reg.report.items.len);

    // Manifest projection: host name is sanitized into the plugin namespace.
    try std.testing.expectEqual(@as(usize, 1), reg.tools.items.len);
    const idx = reg.findTool("p_hello_hello_echo") orelse return error.TestUnexpectedResult;

    // Definition is registry-compatible (schema survived as raw JSON).
    const def = reg.definitionFor(idx);
    try std.testing.expectEqualStrings("p_hello_hello_echo", def.name);
    try std.testing.expect(std.mem.indexOf(u8, def.parameters_json, "\"required\":[\"name\"]") != null);

    // Execute through the ABI: args marshaled in, JSON copied out, freed.
    const outcome = (try reg.execute(alloc, "p_hello_hello_echo", "{\"name\":\"World\"}")) orelse
        return error.TestUnexpectedResult;
    defer alloc.free(outcome.output);
    try std.testing.expect(outcome.ok);
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"greeting\":\"Hello, World!\"}",
        outcome.output,
    );

    // Plugin-side failure path (missing required arg → NULL → failed outcome).
    const bad = (try reg.execute(alloc, "p_hello_hello_echo", "{}")) orelse
        return error.TestUnexpectedResult;
    defer alloc.free(bad.output);
    try std.testing.expect(!bad.ok);

    // Empty args arrive at the plugin as "{}" per contract (same NULL path,
    // no crash).
    const empty_args = (try reg.execute(alloc, "p_hello_hello_echo", "")) orelse
        return error.TestUnexpectedResult;
    defer alloc.free(empty_args.output);
    try std.testing.expect(!empty_args.ok);

    // deinit unloads everything — testing.allocator proves zero leaks.
}
