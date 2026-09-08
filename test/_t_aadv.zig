//! Self-test root for wave-7 agent A-advanced (SWARM_PLAN ownership row:
//! src/agent/compaction.zig + src/dynamic/preset_tools.zig). Kept at
//! TOP-LEVEL src/ so relative imports stay inside the module path. Run
//! offline:
//!
//!     zig test -lc test/_t_aadv.zig
//!
//! The integrator folds these imports into src/tests.zig later.

test {
    _ = @import("../src/agent/compaction.zig");
    _ = @import("../src/dynamic/preset_tools.zig");
}
