//! D-workflow selftest root: folds the workflow engine's modules into one
//! `zig test -lc test/_t_wf.zig` entry point. The integrator moves these
//! imports into tests.zig.

test {
    _ = @import("../src/workflow/workflow.zig");
    _ = @import("../src/workflow/executor.zig");
    _ = @import("../src/workflow/run_report.zig");
}
