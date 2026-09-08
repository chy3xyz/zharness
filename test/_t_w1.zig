//! W1-integration self-test root (swarm plan, ground rule 7).
//!
//! Standalone runner for every module this agent wired or fixed. Kept at
//! TOP-LEVEL src/ so `..` imports stay inside the module path. The integrator
//! folds these into src/tests.zig and deletes the file.
//!
//! Run with:
//!   zig test -lc --dep cordis -Mroot=test/_t_w1.zig -Mcordis=../zcordis/src/cordis.zig
//!
//! (-lc is required: sandbox/checkpoint use libc popen/time; the cordis dep is
//! required because tool/builtin.zig ← agent/agent.zig pulls in zcordis.)
//!
//! NOTE: src/tests.zig also imports all of these files — `zig build test`
//! runs the same test blocks through the official build graph.

test {
    // Fixed + wired by W1.
    _ = @import("../src/sandbox/sandbox.zig");
    _ = @import("../src/tool/builtin.zig");
    _ = @import("../src/agent/agent.zig");

    // Wired orphan modules.
    _ = @import("../src/session/checkpoint.zig");
    _ = @import("../src/skill/skill.zig");
    _ = @import("../src/skill/loader.zig");
    _ = @import("../src/memory/persistent.zig");
    _ = @import("../src/memory/working.zig");
    _ = @import("../src/agent/plan.zig");
    _ = @import("../src/agent/goal.zig");
}
