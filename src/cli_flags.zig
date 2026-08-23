//! Strict CLI subcommand flag parsing shared by `run` and `chat`.
//!
//! One parser, one behavior: every flag takes exactly the values it declares,
//! unknown `--*` flags are rejected, and a missing value is an error — the
//! previous split implementation silently ignored missing values on the
//! `chat` path while erroring on `run`.

const std = @import("std");

pub const ParseError = error{
    MissingFlagValue,
    UnknownFlag,
    ExtraPositional,
};

pub const SubFlags = struct {
    /// First positional argument after the flags (the prompt), if any.
    prompt: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    no_stream: bool = false,
    session_id: ?[]const u8 = null,
};

/// Parse flags from `args` (already sliced past the subcommand).
/// `max_positionals` caps how many positional args are accepted before
/// error.ExtraPositional (`run` uses 1 — the prompt; `chat` uses 0).
pub fn parseSubFlags(args: []const []const u8, max_positionals: usize) ParseError!SubFlags {
    var out = SubFlags{};
    var positionals: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingFlagValue;
            out.model = args[i];
        } else if (std.mem.eql(u8, a, "--provider")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingFlagValue;
            out.provider = args[i];
        } else if (std.mem.eql(u8, a, "--session")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingFlagValue;
            out.session_id = args[i];
        } else if (std.mem.eql(u8, a, "--no-stream")) {
            out.no_stream = true;
        } else if (std.mem.startsWith(u8, a, "--") and a.len > 2) {
            return error.UnknownFlag;
        } else {
            if (positionals >= max_positionals) return error.ExtraPositional;
            positionals += 1;
            if (positionals == 1) out.prompt = a;
        }
    }
    return out;
}

test "parseSubFlags extracts prompt and options" {
    const f = try parseSubFlags(&.{ "fix the build", "--model", "m1", "--no-stream", "--session", "s1" }, 1);
    try std.testing.expectEqualStrings("fix the build", f.prompt.?);
    try std.testing.expectEqualStrings("m1", f.model.?);
    try std.testing.expectEqualStrings("s1", f.session_id.?);
    try std.testing.expect(f.no_stream);
}

test "parseSubFlags rejects missing value" {
    try std.testing.expectError(error.MissingFlagValue, parseSubFlags(&.{"--model"}, 1));
    try std.testing.expectError(error.MissingFlagValue, parseSubFlags(&.{ "--session", "--no-stream" }, 1));
}

test "parseSubFlags rejects unknown flag and extra positional" {
    try std.testing.expectError(error.UnknownFlag, parseSubFlags(&.{"--bogus"}, 1));
    try std.testing.expectError(error.ExtraPositional, parseSubFlags(&.{ "a", "b" }, 1));
}

test "parseSubFlags chat allows no positional" {
    const f = try parseSubFlags(&.{"--no-stream"}, 0);
    try std.testing.expect(f.prompt == null);
    try std.testing.expect(f.no_stream);
}
