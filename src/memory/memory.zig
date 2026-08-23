//! Memory subsystem (dev.md §XIV): four kinds of agent memory.
//!
//! - `session`   : conversation transcript (see src/session/session.zig)
//! - `working`   : current task/plan/state scratchpad (src/memory/working.zig)
//! - `persistent`: durable key/value facts across sessions
//!                 (src/memory/persistent.zig, file-backed JSON at
//!                 ~/.zharness/memory/memory.json)
//! - `artifact`  : produced files inside the workspace (not modeled here)
//!
//! Pragmatic deviation from dev.md §XIV: persistent memory v1 is a single
//! JSON document instead of SQLite — dependency-free, atomic writes, and the
//! access pattern (few small facts) does not justify an embedded database.
//! The public surface mirrors a kv store so a SQLite backend can slot in
//! behind it later.

const std = @import("std");

pub const MemoryKind = enum {
    session,
    working,
    persistent,
    artifact,

    pub fn asStr(self: MemoryKind) []const u8 {
        return @tagName(self);
    }
};

test {
    _ = @import("working.zig");
    _ = @import("persistent.zig");
}
