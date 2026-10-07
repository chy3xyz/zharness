# Contributing to zharness

Thanks for your interest in improving zharness! This document explains how to
build, test, and contribute changes.

## Prerequisites

- **Zig `0.17.0`** (stable) — the project pins `minimum_zig_version = "0.17.0"`.
  Install via [zigup](https://github.com/marler8997/zigup) or your package
  manager and make sure `zig` is on `PATH`.
- **`curl`** — zharness posts chat requests through `curl`, so it must be
  available on `PATH`.
- A local checkout of **zcordis** at `../zcordis` (referenced by relative path
  in `build.zig.zon`). Clone it alongside this repo:

  ```bash
  git clone <zcordis-url> ../zcordis
  ```

## Building

```bash
zig build            # produces ./zig-out/bin/zh
```

## Running

```bash
export ZHARNESS_API_KEY="sk-..."
./zig-out/bin/zh run "fix the failing tests in this project"
```

## Testing

```bash
zig build test                             # full suite (410 tests)
zig build test -Dtest-filter="shell echo"  # a single test by name
```

Tests live inline in each module as `test { ... }` blocks; `src/tests.zig` is
the test root that links everything via the `cordis` module. The DebugAllocator
is enabled in the binary, so memory leaks surface as panics at exit — please
keep the suite green and leak-free.

## Code style

- One module namespace under `src/` (single root module `src/main.zig`). Files
  cross-import with relative paths, e.g. `@import("agent/agent.zig")`.
  Do **not** add a separate `addModule` per subdirectory.
- **No JSON or HTTP library.** Requests are hand-rolled JSON posted via
  `curl`; parsing uses a hand-rolled brace/bracket matcher. Keep new parsing in
  this style — do not pull in dependencies.
- Free allocator-owned slices (`tool_builtin.freeResult`,
  `ChatResponse.deinit`, `Config.deinit`). The DebugAllocator will catch leaks.
- Prefer `const` over `var` for anything never mutated.

## Adding a tool

Tools are the unit of capability. See [`docs/authoring-tools.md`](docs/authoring-tools.md)
for a full walkthrough. In short:

1. Declare the tool in `src/tool/registry.zig` via `registerBuiltins` with a
   name, description, category, and a complete `parameters_json` OpenAI
   function schema.
2. Implement its executor in `src/tool/builtin.zig`'s `execute` dispatch.
3. Keep paths inside the workspace root (`isInsideWorkspace`).

`buildToolsJson` serializes every registered definition, so the wire schema
can never drift from the executor.

## Commit / PR guidelines

- Keep commits focused; write clear, imperative subject lines
  (`fix ...`, `add ...`, `refactor ...`).
- Run `zig build` and `zig build test` before opening a PR.
- For user-visible behavior changes, update `README.md` and the relevant
  `docs/` page.
- Open an issue first for large or architectural changes so we can agree on
  direction.

## Reporting issues

Please open a GitHub issue with:

- zharness version / git rev
- Zig version (`zig version`)
- the exact command run
- expected vs. actual output (include the request body at
  `/tmp/zharness_req.json` if the failure is API-related)
