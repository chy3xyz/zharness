# AGENTS.md — for AI coding agents

Guidance for automated coding agents working in `zharness`: a native coding-agent
harness written in Zig 0.17, built on the [zcordis](https://github.com/chy3xyz/zcordis)
runtime kernel. Read `README.md` and `docs/` for intent and architecture; this
file is the quick operational cheat-sheet. `CODEBUDDY.md` has a deeper module
walkthrough.

## Toolchain

Zig `0.17.0` stable (pinned in `.zigversion` and `build.zig.zon`'s
`minimum_zig_version`). The build has a **path dependency** on `../zcordis`
(see `build.zig.zon`), so clone zcordis as a sibling first:

```bash
git clone https://github.com/chy3xyz/zcordis.git ../zcordis
```

## Build / test / run commands

```bash
zig build                                  # build ./zig-out/bin/zh
zig build test                             # full suite (435 tests)
zig build test -Dtest-filter="shell echo"  # a single test by name
zig build run -- run "..."                 # run the agent (needs ZHARNESS_API_KEY)
zig build -Doptimize=ReleaseSafe           # optimized test build
zig fmt src/ test examples/ build.zig      # MUST run before committing Zig changes
```

## Layout / invariants

- One module namespace: `src/main.zig` is the single root module; files
  cross-import with relative paths (e.g. `@import("agent/agent.zig")`). Do **not**
  add a separate module per subdirectory.
- **No JSON or HTTP library.** HTTPS goes through `curl` via libc `popen`; JSON
  is hand-rolled. Keep new parsing in this style.
- `src/tests.zig` is the test root that pulls in every module; `zig build test`
  is the gate and runs 435 tests. The binary installs as `zh` (not `zharness`).
- `_ref/` is read-only reference material — do **not** compile it:
  `_ref/deepseek-harness` (original TypeScript project) and `_ref/zeepseek`
  (reusable Zig 0.17 patterns).

## CI

`.github/workflows/ci.yml` builds and tests on macOS with Zig 0.17.0, checking
out `zcordis` as a sibling so the `../zcordis` path dependency resolves.
