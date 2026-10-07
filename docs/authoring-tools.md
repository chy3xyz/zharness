# Authoring tools

Tools are the unit of capability in zharness. This guide walks through adding a
new builtin tool end to end. It assumes you have read
[`docs/architecture.md`](architecture.md).

## Mental model

A tool has two halves that must agree:

1. **Declaration** in `src/tool/registry.zig` — its name, description, category,
   and an OpenAI function-schema `parameters_json`. `buildToolsJson` serializes
   every declaration into the request, so the model always sees an accurate
   schema.
2. **Executor** in `src/tool/builtin.zig` — the code that actually runs when the
   model calls the tool, keyed by name in `execute`.

Because the schema is generated from declarations, the wire format can never
drift from the executor as long as you keep both in sync.

## Step 1 — declare the tool

In `registerBuiltins` (`src/tool/registry.zig`), add an entry:

```zig
try reg.register(.{
    .name = "file_append",
    .description = "Append text to a file in the workspace, creating it if missing.",
    .category = .filesystem,
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path relative to workspace"},"content":{"type":"string","description":"Text to append"}},"required":["path","content"]}
    ,
});
```

Rules for `parameters_json`:

- It must be a **complete** JSON object ending in `}` with **no trailing
  comma**. The build appends `"}}"` to close the `function` and outer wrappers,
  so a stray trailing comma here produces malformed JSON and an HTTP 400 from
  the provider.
- Use Zig `\\` line-continuation for multi-line literals; a single-line literal
  like the one above is fine too, but do not add a trailing `,` inside the
  braces.
- `required` lists the parameter names the model must supply.

The category is an enum (`general`, `filesystem`, `shell`, `vcs`, `search`);
add a variant in `ToolDefinition.Category` if needed.

## Step 2 — implement the executor

In `src/tool/builtin.zig`, extend `execute`'s dispatch. The signature is:

```zig
pub fn execute(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    call: ToolCall,
) !ToolResult
```

`ToolCall` gives you `name` and `arguments` (the raw JSON argument string).
Parse it with `parseArgs`, which returns a `std.StringHashMap([]const u8)` keyed
by argument name; look values up with `.get("name")`.

```zig
if (std.mem.eql(u8, call.name, "file_append")) {
    const map = try parseArgs(alloc, call.arguments);
    defer map.deinit();
    const path = map.get("path") orelse
        return ToolResult{ .success = false, .output = "", .err_msg = "missing 'path'" };
    const content = map.get("content") orelse
        return ToolResult{ .success = false, .output = "", .err_msg = "missing 'content'" };

    // Resolve against cwd and reject anything outside the workspace.
    const abs = try std.fs.path.resolve(alloc, &.{ cwd, path });
    defer alloc.free(abs);
    if (!isInsideWorkspace(abs, cwd)) {
        return ToolResult{ .success = false, .output = "", .err_msg = "path escapes workspace" };
    }

    // std.Io.Dir has no append; read existing bytes, concatenate, write back.
    const existing = std.Io.Dir.readFileAlloc(.cwd(), io, abs, alloc, .unlimited) catch "";
    const merged = try std.fmt.allocPrint(alloc, "{s}{s}", .{ existing, content });
    alloc.free(existing);
    std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = abs, .data = merged }) catch |e| {
        alloc.free(merged);
        return ToolResult{ .success = false, .output = "", .err_msg = @errorName(e) };
    };
    alloc.free(merged);
    return ToolResult{
        .success = true,
        .output = try std.fmt.allocPrint(alloc, "appended {d} bytes to {s}", .{ content.len, path }),
        .err_msg = "",
    };
}
```

### Returning results

Return `ToolResult{ .success, .output, .err_msg }`. The loop calls
`result.format(alloc)` to build the message sent back to the model, and frees it
with `tool_builtin.freeResult`. Allocate `output`/`err_msg` with the passed
`alloc` so ownership stays consistent.

### Workspace sandboxing

Always resolve paths against `cwd` and check `isInsideWorkspace(cwd, abs)`
before touching the filesystem. Tools must only operate inside the workspace
root. System-wide reads should go through the `shell` tool.

## Step 3 — test it

Add a unit test in `src/tests.zig` (or inline in `builtin.zig`) that registers
the builtins, builds the tools JSON, and asserts your tool appears with valid
schema. Use the `std.Io.Dir` API for any file I/O in tests and clean up temp
files with `std.Io.Dir.deleteFile(.cwd(), io, path)`.

Run:

```bash
zig build test                             # full suite (418 tests)
zig build test -Dtest-filter="<name>"       # only tests whose name matches
```

## Checklist

- [ ] Declared in `registerBuiltins` with description + complete `parameters_json`
- [ ] Dispatched in `execute` by exact name
- [ ] Arguments parsed via `parseArgs` map; missing required args return a clear `err_msg`
- [ ] Paths resolved against `cwd` and checked with `isInsideWorkspace`
- [ ] `ToolResult` allocations use the passed `alloc`
- [ ] Covered by a test; `zig build test` is green
