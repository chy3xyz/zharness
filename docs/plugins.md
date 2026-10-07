# zharness Plugins — Native C ABI (dev.md §XXV–XXVI)

Native plugins are shared libraries that export four C symbols. Any language
that can produce a `.dylib` (macOS) / `.so` (Linux) and call C works: C, C++,
Zig (`export fn ... callconv(.c)`), Rust (`extern "C"` + `cdylib`), Go
(`//export` + `-buildmode=c-shared`). The host discovers, loads, validates,
and unloads them — a broken plugin is skipped with a reason, never crashes
zharness.

Source of truth: `src/pluginabi/capi.zig` (contract), `src/pluginabi/ffi.zig`
(dlopen wrappers), `src/pluginabi/loader.zig` (discovery/validation/
execution). Working example: `examples/plugin-hello/`.

---

## 1. ABI contract (v1)

The plugin exports:

| Symbol                 | C signature                                            | Notes |
|------------------------|--------------------------------------------------------|-------|
| `zh_plugin_abi_version`| `uint32_t (*)(void)`                                    | Must return **1**. Anything else → plugin rejected before its manifest is even read. |
| `zh_plugin_manifest`   | `const char* (*)(void)`                                 | NUL-terminated UTF-8 JSON manifest (schema below). Lives in the plugin's own static storage; the host copies it and never frees it. |
| `zh_tool_execute`      | `char* (*)(const char* tool_name, const char* args_json)` | Runs one manifest-declared tool. `tool_name` is the **plugin-local** name (e.g. `hello_echo`, not `p_hello_hello_echo`). `args_json` is the model's arguments verbatim; an empty call arrives as `"{}"`. Returns NUL-terminated UTF-8 JSON on success or **NULL on failure** (host synthesizes the error message). Ownership transfers to the host. |
| `zh_string_free`       | `void (*)(char*)`                                       | Frees a buffer returned by this plugin. May be called with NULL. |

### Memory ownership rules

- **Returned** strings (`zh_plugin_manifest`, `zh_tool_execute`) belong to the
  caller. The host always **copies what it needs first, then calls
  `zh_string_free`** — copy-before-free is enforced in loader.zig so a bad
  free can never corrupt host memory.
- **Passed-in** strings (`tool_name`, `args_json`) are borrowed: valid only
  for the duration of the call.
- The manifest string is borrowed static storage owned by the plugin.
- Threading: all calls into one plugin come from the agent-loop thread;
  plugins need no internal locking for that guarantee.

### Lifecycle mapping (dev.md §XXVI)

```
Discover  → PluginRegistry.loadDefaultDirs (~/.zharness/plugins, <workspace>/plugins)
Load      → dlopen(RTLD_NOW|RTLD_LOCAL), resolve 4 symbols   [ffi.zig]
Resolve   → abi version == 1 gate                            [loader.zig]
Register  → manifest parse+validate → tools projected as p_<plugin>_<tool>
Start     → (implicit; stateless ABI v1 has no start hook)
Running   → zh_tool_execute per model tool-call
Stop      → PluginRegistry.deinit
Unload    → dlclose                                          [ffi.zig]
```

ABI v1 intentionally omits `init/start/stop/deinit` hooks: stateless tools
keep the surface minimal and crash-safe. A future ABI v2 can add optional
lifecycle symbols without breaking v1 plugins (version gate already exists).

---

## 2. Manifest schema

```json
{
  "name": "hello",
  "version": "0.1.0",
  "kind": "tool",
  "tools": [
    {
      "name": "hello_echo",
      "description": "Echo a friendly greeting.",
      "schema": {
        "type": "object",
        "properties": { "name": { "type": "string" } },
        "required": ["name"]
      }
    }
  ]
}
```

Field rules (enforced by `validateManifest`; unknown top-level keys ignored):

| Field | Rule |
|---|---|
| `name` | 1–64 chars; `[A-Za-z0-9_.-]` plus non-ASCII UTF-8; dots allowed (dev.md style `tool.shell`) |
| `version` | 1–32 chars, non-empty |
| `kind` | must be `"tool"` |
| `tools` | ≥ 1 entry |
| `tools[].name` | 1–64 chars `[A-Za-z0-9_-]` (no dots — it becomes part of the host name) |
| `tools[].description` | required (may be empty string); shown to the model |
| `tools[].schema` | OpenAI-style parameters object. Written **inline as a JSON object** (canonical) *or* as a JSON **string** containing the schema — both accepted. Must be balanced JSON. |

### Tool namespace

A plugin-local tool becomes host tool **`p_<plugin>_<tool>`**, sanitized to
`[a-z0-9_]`. Examples: plugin `hello` + tool `hello_echo` → `p_hello_hello_echo`;
plugin `My Plugin!` + tool `do-Thing` → `p_my_plugin__do_thing`.
This namespace can never collide with builtin tools or MCP bridges
(`mcp_*`). Duplicate host names within one load are reported and skipped.

---

## 3. Example walkthrough (`examples/plugin-hello/`)

Build:

```sh
./examples/plugin-hello/build.sh     # → examples/plugin-hello/build/hello.dylib (macOS) / hello.so
```

Install (either location):

```sh
mkdir -p plugins && cp examples/plugin-hello/build/hello.dylib plugins/
# or system-wide:
cp examples/plugin-hello/build/hello.dylib ~/.zharness/plugins/
```

What happens on next startup:

1. Loader scans `~/.zharness/plugins` then `<workspace>/plugins`
   (sorted, `.so`/`.dylib` only).
2. `hello.dylib` loads; all four symbols resolve; `abi_version == 1` ✓.
3. Manifest parses; kind `tool` ✓; one well-formed tool ✓.
4. Host registry gains `p_hello_hello_echo` with the schema above.

The agent then calls it like any builtin tool:

```json
{"name": "p_hello_hello_echo", "arguments": "{\"name\": \"World\"}"}
→ {"ok":true,"greeting":"Hello, World!"}
```

Missing required arg → plugin returns NULL → failed tool result
("plugin tool 'p_hello_hello_echo' reported failure"). No crash, no leak:
the result buffer was heap-allocated by the plugin and released through its
own `zh_string_free`.

### Writing your own plugin in C — checklist

1. Copy `examples/plugin-hello/hello.c`; keep the four exported functions
   (they carry `__attribute__((visibility("default")))`).
2. Manifest in static storage (`static const char[]`), one entry per tool.
3. In `zh_tool_execute`: dispatch on `tool_name`, parse `args_json`,
   return `malloc`'d JSON or NULL on failure.
4. `zh_string_free` = whatever matches your allocation (`free` for malloc).
5. Compile with `-shared -fPIC -O2` (macOS clang accepts `-shared`;
   `-dynamiclib` also works).

---

## 4. Failure policy

Every failure mode is contained and recorded in `PluginRegistry.report`
(`path` + human-readable `reason`):

| Situation | Behavior |
|---|---|
| File without `.so`/`.dylib` suffix | skipped, reported |
| dlopen failure (missing arch, undefined deps…) | skipped, reported with dlerror text |
| Missing any of the 4 symbols | skipped, reported |
| `abi_version != 1` | unloaded immediately, reported |
| Unparsable / policy-invalid manifest | unloaded, reported (`InvalidJson`, `NoTools`, …) |
| Duplicate projected tool name | duplicate row skipped, reported |
| Plugin yields zero usable tools | not registered, reported |
| Tool execution returns NULL | failed tool result back to the model; loop continues |

Nothing ever panics the host. Tests prove leak-freedom under
`std.testing.allocator` (covered by `zig build test`).

> Note: ABI v1 does not fork-isolate `zh_tool_execute`. A plugin that
> segfaults takes down the host process — same trust level as a native
> extension in neovim/emacs. Process isolation is future work.

## 5. Test layout

- Pure logic (manifest parse/validation, name sanitization, ABI-version
  check): inline tests in `src/pluginabi/loader.zig` — no dlopen needed.
- One smoke test in the plugin-loader test root loads
  `examples/plugin-hello/build/*` **only if it exists** (run `build.sh`
  once to enable it); otherwise it skips, keeping CI hermetic.

Run: `zig build test`

---

## 6. Integrator notes (main.zig wiring)

Startup (after config load):

```zig
var plugins = pluginabi.loader.PluginRegistry.init(alloc);
defer plugins.deinit();
plugins.loadDefaultDirs(io, cfg.workspace_root); // ~/.zharness/plugins, ./plugins
for (plugins.report.items) |r| warn("plugin skipped: {s}: {s}", .{ r.path, r.reason });

// Project into the existing registry (it duplicates strings itself):
const defs = try plugins.definitions(alloc);
defer alloc.free(defs);
for (defs) |d| try tool_registry.register(d);
```

Tool dispatch (agent loop fallback after builtins):

```zig
if (try plugins.execute(alloc, call.name, call.arguments)) |out| {
    defer alloc.free(out.output);
    if (!out.ok) → failed ToolResult with out.output as err_msg
    else         → success ToolResult with out.output verbatim
} else {
    // unknown tool (not ours) → builtin path already handled it
}
```

Suggested CLI surface:

```
zharness plugin list          # scan default dirs, print loaded tools + skip report
zharness plugin list --dir X  # scan an extra directory
zharness plugin exec <host_name> '<json>' [--dir X]   # manual invocation / debugging
```

`plugin list` = `loadDefaultDirs` + print `tools.items[*].host_name` +
description + source path; `plugin exec` = `execute(alloc, name, json)` and
print the outcome — useful while developing a plugin without burning model
tokens.
