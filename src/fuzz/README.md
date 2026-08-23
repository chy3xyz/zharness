# src/fuzz — production-hardening suites (SWARM wave-4, agent J-fuzz)

Corpus-driven robustness suites over EVERY zharness parser surface.
Deterministic and hermetic: fixed PRNG seeds, compile-time-embedded corpora,
short bounded timeouts — no fuzzer toolchain required, everything runs inside
plain `zig build test` (via tests.zig folding) or the standalone root
`src/_t_fuzz.zig`.

## Run

```sh
# Standalone root (all 11 suites; same test blocks as zig build test):
zig test -lc --dep cordis -Mroot=src/_t_fuzz.zig -Mcordis=../zcordis/src/cordis.zig

# Through the official build graph (after the integrator folds _t_fuzz.zig
# imports into src/tests.zig):
zig build test
```

The `-Mcordis` alias is required because `session/session.zig` imports
zcordis — identical shape to `src/_t_w1.zig`. `-lc` is needed for the libc
popen/time helpers used by modules under test.

## Method

Per surface:

1. **Seed corpus** (`corpus/*.txt`, committed): valid documents, boundary
   documents, and known-hostile documents separated by `%%%%` lines,
   embedded via `@embedFile` (no cwd assumptions).
2. **Structured mutators** (`mutator.zig`): deterministic xorshift64* PRNG;
   bit flips, byte substitution from JSON-interesting set, truncation,
   chunk deletion/duplication, unicode injection (raw surrogate halves,
   lone `\uD800` escapes, malformed `\uZZZZ`), deep nesting (≤512), huge
   repeat counts (≤256), separator spam. Output hard-capped at 64 KiB.
3. **Property**: every case must *return cleanly OR error cleanly* under
   `std.testing.allocator` — never panic, never leak (leak detector fails
   the suite), never hang (bounded iterations everywhere; MCP pipe cases
   use 40 ms timeouts).

| Suite | Surface |
|---|---|
| `json.zig` | model.zig findMatchingBrace/Bracket, escape/unescape round-trip, isErrorEnvelope/errorMessage/extractStringField |
| `jsonrpc.zig` | protocol/jsonrpc.zig encode⇄decode round-trips, oversized ids, unescapeInner |
| `mcp.zig` | protocol/mcp.zig line framing via in-process pipe pairs: partial lines, CRLF mixes, junk pumps, 4 MiB line overflow, EOF variants |
| `http.zig` | server/httpd.zig parseRequest (already pub — no factoring needed), percentDecode, formatResponse |
| `workflow.zig` | workflow/workflow.zig parse/validate/findCyclePath |
| `skill.zig` | skill/skill.zig parseSkillMd (+ registry); skill/loader.zig delegates front-matter parsing here |
| `sse.zig` | model.zig SseParser.feed/finish: chunking-independent content assembly, hostile events |
| `checkpoint_session.zig` | session/checkpoint.zig CheckpointStore.load + session/session.zig load with corrupt files on disk |
| `manifest.zig` | pluginabi/loader.zig pure fns: parseManifest/validateManifest/hostToolName/abiVersionOk (no dlopen) |
| `envelope.zig` | obs.zig parseEnvelope incl. writer→parser field-equal round-trips |

Optional native fuzzing entry points (`std.testing.fuzz`) were evaluated and
**skipped**: this toolchain (0.17.0-dev.1567) exposes no such API.

## Bugs found & fixed (minimal diffs, regression cases pinned)

1. **session/checkpoint.zig — load-path leak** (`CheckpointStore.load`):
   when a later array element failed `Role.fromStr`, the early return leaked
   the current message's `tool_call_id` / `tool_calls_json` AND every prior
   appended message's strings (the errdefer freed only list storage).
   Fix: errdefer now frees item contents; optionals get their own errdefers.
   Regression: `fuzz/checkpoint_session.zig` "bad role mid-array".
2. **pluginabi/loader.zig — stack-overflow crash** (`MemberIter.nextMember`):
   one recursion frame per leading `,`; a manifest with a long comma run
   (≈200k) aborted the process (>10k frames, SIGABRT). Hostile manifests are
   attacker-reachable input (any `.so/.dylib` in plugins dir).
   Fix: separator runs consumed iteratively.
   Regression: `fuzz/manifest.zig` "comma flood".
3. **workflow/workflow.zig — uninitialized byte emitted** (`ownedQuoted`):
   `\uD800`-style escapes hit `utf8Encode(...) catch 1`, appending ONE BYTE
   OF UNINITIALIZED STACK BUFFER instead of the documented replacement char
   (Debug builds leak 0xAA into prompts/names).
   Fix: explicit U+FFFD replacement on encode failure.
   Regression: `fuzz/workflow.zig` "lone surrogate escape".

Note (behavior, not bug): workflow's string decoder deliberately does NOT
combine surrogate pairs (jsonrpc's does); each half maps to its own U+FFFD.
Pinned as contract in the workflow suite.
