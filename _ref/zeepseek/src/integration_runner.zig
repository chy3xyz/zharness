//! Zeepseek integration-test runner.
//!
//! These tests require external services and are deliberately NOT part of
//! `zig build test` (the unit suite must run offline):
//!   - `net/http2_tests.zig` expects an echo server on 127.0.0.1:18472
//!   - `net/h2_live_test.zig` needs `DEEPSEEK_API_KEY` (skips when absent)
//!
//! Run with `zig build integration-test`.

const std = @import("std");

comptime {
    _ = @import("net/http2_tests.zig");
    _ = @import("net/h2_live_test.zig");
}