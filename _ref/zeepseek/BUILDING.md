# Building zeepseek reproducibly

zeepseek targets the **Zig 0.17 development line**. The tree is built and
tested against exactly one compiler:

```
0.17.0-dev.1422+e863bf3be
```

A stable Zig release (0.13/0.14/…) will **not** build this tree — the code
uses 0.17-era std APIs (`std.Io`-parameterized I/O, `ArrayList.empty` +
allocator-taking methods, `std.c` POSIX wrappers, `b.createModule`,
`addPassthruArgs`, …) that do not exist or have different signatures in
stable releases.

## 1. Install the exact compiler (via zigup)

```sh
zigup install 0.17.0-dev.1422+e863bf3be
zigup use 0.17.0-dev.1422+e863bf3be
zig version   # must print 0.17.0-dev.1422+e863bf3be
```

If `zigup` can't reach the index (network-restricted environment), the
compiler can be placed manually under
`~/.local/share/zigup/0.17.0-dev.1422+e863bf3be/`.

## 2. Vendored dependencies (no network at build time)

`zigzag` is vendored at `vendor/zigzag` (pinned to its v0.1.3 line) and
referenced by path in `build.zig.zon` — no package fetch is needed.

### The vendor patch

Upstream zigzag's `build.zig` uses the removed `b.args` API, which the
0.17-dev compiler deleted. The vendored copy replaces it with:

```diff
-        run_cmd.addArgs(b.args);
+        run_cmd.addPassthruArgs();
```

`vendor/zigzag/build.zig:80`. This is the only deviation from upstream.
The `.zig-cache` build hash is pinned via the `fingerprint` field in
`build.zig.zon` (`0xd5ab6edee650d06c`).

## 3. Build & test

```sh
zig build                        # debug exe at zig-out/bin/zeepseek
zig build test                   # unit + integration tests (test_runner)
zig build -Doptimize=ReleaseFast # optimized build
```

Run:

```sh
DEEPSEEK_API_KEY=sk-... ./zig-out/bin/zeepseek
```

## 4. Sanity checklist after a change

```sh
zig build && zig build test
# then a TUI smoke test:
DEEPSEEK_API_KEY=sk-test HOME=/tmp/zzhome ./zig-out/bin/zeepseek
```

The integration tests that need external resources (the local MCP demo
server at `/tmp/zz_mcp_demo.py`) skip cleanly when absent.

## 5. Known build-environment notes

- macOS: the TUI needs a real pty (24x80 fallback exists for winsize=0).
- `reasonix.toml` / other local tool config is **not** part of the repo.
- If the compiler is upgraded, expect std-API breakage (this tree tracks
  0.17-dev, not a stable release).
