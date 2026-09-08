//! J-fuzz self-test root (SWARM wave-4). Top-level src/ so `..` imports stay
//! inside the module path; the integrator folds these imports into
//! src/tests.zig later.
//!
//! Run with:
//!   zig test -lc --dep cordis -Mroot=test/_t_fuzz.zig -Mcordis=../zcordis/src/cordis.zig
//!
//! (-lc: libc popen/time used by modules under test; the cordis alias is
//! required because session/session.zig imports zcordis — same shape as
//! test/_t_w1.zig. `zig build test` runs the identical test blocks through
//! the official build graph.)

test {
    _ = @import("../src/fuzz/mutator.zig");
    _ = @import("../src/fuzz/checkpoint_session.zig");
    _ = @import("../src/fuzz/workflow.zig");
    _ = @import("../src/fuzz/manifest.zig");
    _ = @import("../src/fuzz/json.zig");
    _ = @import("../src/fuzz/jsonrpc.zig");
    _ = @import("../src/fuzz/http.zig");
    _ = @import("../src/fuzz/skill.zig");
    _ = @import("../src/fuzz/sse.zig");
    _ = @import("../src/fuzz/mcp.zig");
    _ = @import("../src/fuzz/envelope.zig");
}
