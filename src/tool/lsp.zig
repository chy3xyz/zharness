//! Model-facing lsp tool (upstream dsh lsp): run a language server over one
//! workspace file and return the diagnostics it publishes. One-shot: the
//! server is spawned per call.

const std = @import("std");
const model = @import("../model/model.zig");
const tool_reg = @import("registry.zig");
const builtin = @import("builtin.zig");
const jsonx = @import("../server/apiproxy/jsonx.zig");
const lsp = @import("../protocol/lsp.zig");

pub const ToolCall = builtin.ToolCall;
pub const ToolResult = builtin.ToolResult;
pub const freeResult = builtin.freeResult;

pub const default_server = "clangd";
pub const default_window_ms: u64 = 6000;

pub const definition = tool_reg.ToolDefinition{
    .name = "lsp_diagnostics",
    .description = "Run a language server (default clangd) over a workspace file and return the diagnostics it publishes for that file. The server binary must be on PATH.",
    .category = .filesystem,
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative file to check"},"command":{"type":"string","description":"Language server command line (default clangd)"},"timeout_ms":{"type":"integer","description":"Diagnostics window in milliseconds"}},"required":["path"]}
    ,
};

pub fn register(reg: *tool_reg.ToolRegistry) !void {
    try reg.register(definition);
}

pub fn isLspTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "lsp_diagnostics");
}

fn fail(a: std.mem.Allocator, msg: []const u8) !ToolResult {
    return .{ .success = false, .output = "", .err_msg = try a.dupe(u8, msg) };
}

/// LSP languageId for a path, by extension.
pub fn languageIdFor(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const map = [_]struct { ext: []const u8, id: []const u8 }{
        .{ .ext = ".c", .id = "c" },
        .{ .ext = ".h", .id = "c" },
        .{ .ext = ".cpp", .id = "cpp" },
        .{ .ext = ".cc", .id = "cpp" },
        .{ .ext = ".cxx", .id = "cpp" },
        .{ .ext = ".hpp", .id = "cpp" },
        .{ .ext = ".rs", .id = "rust" },
        .{ .ext = ".zig", .id = "zig" },
        .{ .ext = ".ts", .id = "typescript" },
        .{ .ext = ".tsx", .id = "typescriptreact" },
        .{ .ext = ".js", .id = "javascript" },
        .{ .ext = ".jsx", .id = "javascriptreact" },
        .{ .ext = ".py", .id = "python" },
        .{ .ext = ".go", .id = "go" },
    };
    for (map) |m| {
        if (std.ascii.eqlIgnoreCase(ext, m.ext)) return m.id;
    }
    return "plaintext";
}

fn uriFor(a: std.mem.Allocator, abs: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "file://{s}", .{abs});
}

pub fn execute(a: std.mem.Allocator, io: std.Io, cwd: []const u8, call: ToolCall) !ToolResult {
    const path = (try model.extractStringField(a, call.arguments, "path")) orelse
        return fail(a, "lsp_diagnostics: missing 'path'");
    defer a.free(path);
    const command = (try model.extractStringField(a, call.arguments, "command")) orelse
        try a.dupe(u8, default_server);
    defer a.free(command);
    var window: u64 = model.extractU64Field(call.arguments, "timeout_ms");
    if (window == 0) window = default_window_ms;

    const abs = if (std.fs.path.isAbsolute(path))
        try a.dupe(u8, path)
    else
        try std.fs.path.resolve(a, &.{ cwd, path });
    defer a.free(abs);

    const text = std.Io.Dir.readFileAlloc(.cwd(), io, abs, a, .limited(2 * 1024 * 1024)) catch |e|
        return fail(a, @errorName(e));
    defer a.free(text);

    // Tokenize the command line; the slices borrow the command string, which
    // outlives the spawn call.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    var it = std.mem.tokenizeAny(u8, command, " \t");
    while (it.next()) |tok| try argv.append(a, tok);

    var client = lsp.LspClient.spawnChild(a, io, argv.items) catch |e|
        return fail(a, @errorName(e));
    defer client.deinit();
    client.timeout_ms = 10_000;

    const root_uri = try uriFor(a, cwd);
    defer a.free(root_uri);
    client.initialize(root_uri) catch |e| {
        client.shutdown();
        return fail(a, @errorName(e));
    };

    const uri = try uriFor(a, abs);
    defer a.free(uri);
    client.didOpen(uri, languageIdFor(abs), text) catch |e| {
        client.shutdown();
        return fail(a, @errorName(e));
    };

    const diag = client.collectDiagnostics(uri, @intCast(window)) catch null;
    defer if (diag) |d| a.free(d);
    client.shutdown();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "{\"path\":");
    try jsonx.appendJsonString(a, &out, abs);
    try out.appendSlice(a, ",\"server\":");
    try jsonx.appendJsonString(a, &out, command);
    try out.appendSlice(a, ",\"result\":");
    if (diag) |d| {
        try out.appendSlice(a, d);
    } else {
        try out.appendSlice(a, "null");
    }
    try out.append(a, '}');
    return .{ .success = true, .output = try out.toOwnedSlice(a) };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "languageIdFor maps common extensions" {
    try testing.expectEqualStrings("c", languageIdFor("a/b.c"));
    try testing.expectEqualStrings("cpp", languageIdFor("x.cpp"));
    try testing.expectEqualStrings("rust", languageIdFor("m.rs"));
    try testing.expectEqualStrings("plaintext", languageIdFor("notes.txt"));
}

test "lsp_diagnostics requires a path" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var r = try execute(alloc, io, "/tmp", .{ .name = "lsp_diagnostics", .arguments = "{}" });
    defer freeResult(alloc, &r);
    try testing.expect(!r.success);
}

test "lsp_diagnostics runs clangd when available" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "/tmp/zh_lsp_probe.c";
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = "int main(void) { return 0 }\n" });
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    var r = try execute(alloc, io, "/tmp", .{
        .name = "lsp_diagnostics",
        .arguments = "{\"path\":\"zh_lsp_probe.c\",\"command\":\"clangd\",\"timeout_ms\":8000}",
    });
    defer freeResult(alloc, &r);
    if (!r.success) return error.SkipZigTest;
    try testing.expect(std.mem.indexOf(u8, r.output, "\"result\"") != null);
}
