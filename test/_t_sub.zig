//! Self-test root for the C-subagent area (SWARM_PLAN ownership row
//! C-subagent). Kept at TOP-LEVEL src/ so relative imports stay inside the
//! module path. Run offline:
//!
//!     zig test -lc test/_t_sub.zig
//!
//! The integrator folds these imports into src/tests.zig later.

test {
    _ = @import("../src/agent/subagent.zig");
    _ = @import("../src/tool/spawn_agent.zig");
}
