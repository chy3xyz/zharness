//! Self-test root for the F-obs-preset area (obs.zig + presets.zig).
//! Ground rule 7: lives at top-level src/ so relative imports stay inside
//! the module path. The integrator folds these imports into tests.zig.
//! Run: zig test -lc test/_t_obs.zig

test {
    _ = @import("obs.zig");
    _ = @import("presets.zig");
}
