//! Wave-7 A-code test root — run_code (Code Mode) + agent-instructions loader.
//! Run: zig test -lc test/_t_acode.zig

const std = @import("std");

test {
    _ = @import("../src/tool/run_code.zig");
    _ = @import("../src/agent/instructions.zig");
}
