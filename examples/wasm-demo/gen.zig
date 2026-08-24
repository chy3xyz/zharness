// One-off fixture generator: emits a full WASM ABI v1 plugin module
// (demo.wasm) using the hand-assembler from src/_t_wasm.zig.
const std = @import("std");
const fixture = @import("_t_wasm.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;

    const manifest =
        \\{"name":"demo","version":"0.1.0","kind":"tool","tools":[{"name":"demo_ping","description":"Answer pong.","schema":{"type":"object","properties":{},"required":[]}}]}
    ;
    const result =
        \\{"ok":true,"pong":true}
    ;
    const bytes = try fixture.buildAbiModule(alloc, 1, .succeed, manifest, result);
    var args_list: std.ArrayList([:0]const u8) = .empty;
    defer args_list.deinit(alloc);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |arg| try args_list.append(alloc, arg);
    if (args_list.items.len < 2) return error.MissingArg;
    try std.Io.Dir.writeFile(.cwd(), init.io, .{ .sub_path = args_list.items[1], .data = bytes });
    std.debug.print("wrote {s} ({d} bytes)\n", .{ args_list.items[1], bytes.len });
}
