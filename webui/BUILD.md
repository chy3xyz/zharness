# webui — Vendored DSH Frontend (build contract)

`webui/dsh/` is a pruned vendored copy of the DeepSeek Harness web frontend
(upstream MIT, vendored at commit `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`
— see `webui/dsh/VENDOR-NOTICE.md`). Scope and protocol rationale live in
`docs/dsh-reuse-spec.md`; this file is the operational build/serve contract.

## Layout

```
webui/dsh/                     vendored pnpm workspace (pruned closure, 94 packages + vendor/)
  apps/web/dist/               PRODUCTION DIST — final static assets (the integrator serves this)
  build-artifacts/
    boot-manifest.json         trimmed window.__DSH_BOOT__ graph: { graph, injections, roster }
  packages/*/*/lib/            build intermediates (gitignored): lib/types (tsc), client.js (tsdown)
  vendor/                      upstream's pinned Cordis framework sources
  tsconfig.vendor.json         zharness-added tsc solution over the pruned closure
  tsdown.vendor-libs.ts        zharness-added scoped vendor-library pass
webui/tools/                   zharness-side helpers (not part of the app):
  gen-typert.mjs               typert generation step (replaces upstream's host-face plugin)
  gen-boot-manifest.mjs        composes the trimmed 15-row boot manifest
  serve-fixture.mjs            static server implementing the hosting contract (dist + /plugins + boot injection)
  boot-smoke.py                headless boot assertion (?fixture carrier)
  roundtrip-smoke.py           headless prompt round-trip through the fixture carrier
```

## Rebuild from scratch (exact chain)

Requirements: Node ≥ 24 (`node --version`: v24.18.0 verified). No env vars
needed for fixture-mode builds; `DSH_CLIENT_*` variables are optional and
only affect branding/build-record metadata.

```sh
# 1. toolchain (once per machine) — upstream pins packageManager: pnpm@11.7.0
corepack enable
corepack prepare pnpm@11.7.0 --activate

# 2. install (from webui/dsh)
cd webui/dsh
pnpm install --no-frozen-lockfile     # lockfile was rewritten once at vendor time; see Deviations

# 3. typecheck + emit lib/types for the whole pruned closure
./node_modules/.bin/tsc -b tsconfig.vendor.json

# 4. typert generation (writes lib/typert.* + ./remote subpath artifacts;
#    upstream does this inside its host-face tsdown pass — we drive the
#    generator directly because the host aggregate references dropped packages)
node ../tools/gen-typert.mjs

# NOTE on ordering: steps 3 and 4 are mutually dependent the first time only —
# step 3 fails on missing ./remote modules until step 4 has run once, and
# step 4's analyzer consumes lib/types of the typert generator package.
# First build order: 3 → (expect /remote errors) → 4 → 3 again. Subsequent
# incremental builds can run either order. A clean-tree one-liner:
#   ./node_modules/.bin/tsc -b tsconfig.vendor.json ; \
#   node ../tools/gen-typert.mjs ; \
#   ./node_modules/.bin/tsc -b tsconfig.vendor.json

# 5. bundle all node halves + client bundles + static-channel libs
pnpm exec tsdown --env.DSH_BUILD_FACE client

# 6. bundle the vendored framework libraries (cordis et al.) for the vite seed chunk
pnpm exec tsdown --config tsdown.vendor-libs.ts

# 7. production dist → apps/web/dist/
pnpm --filter @deepseek-ai/dsh-web-frontend run build

# 8. regenerate the trimmed boot manifest (after any rebuild — revs are content hashes)
node ../tools/gen-boot-manifest.mjs

# 9. link plugin bundles into dist + render the boot-injected index
#    (vite wipes dist on every build — BOTH steps are mandatory after step 7)
python3 ../tools/link-plugins.py     # symlinks /plugins/<pkg> -> packages/*/lib
node ../tools/inject-index.mjs       # index.injected.html (static.zig serves it for "/")
```

Steps 5–6–7 are incremental and fast (~2s combined when warm).

## Serve locally (fixture mode, no backend)

```sh
cd webui/dsh
node ../tools/serve-fixture.mjs 4173          # http://localhost:4173/?fixture
python3 ../tools/boot-smoke.py 4173           # headless boot assertion
python3 ../tools/roundtrip-smoke.py 4173      # headless prompt round-trip
```

The URL query `?fixture` makes the vendored connection plugin swap in its
in-browser mock carrier (`FixtureApiClient`) — no Zig server, no API routes,
no WebSocket endpoints needed. The server implements exactly three things:
static dist serving, `/plugins/<id>/client.js(.map)` with correct
content-type, and index.html head injection of the boot rows (queue facade +
two preload scripts + `globalThis.__DSH_BOOT__`), byte-mirroring
`packages/host/webserver/src/injections.ts` rendering semantics.

## Boot-manifest trim (40+ → 15 rows)

`gen-boot-manifest.mjs` composes rows only for this roster (spec §6):

```
dsh-client-modules · dsh-client-connection · dsh-typert-registry ·
dsh-api-gateway · dsh-api-remotes · dsh-client-runtime · dsh-client-locale ·
dsh-client-ui-theme · dsh-client-ui-layout · dsh-client-ui-renderer ·
dsh-client-ui-sidebar · dsh-client-ui-settings · dsh-client-ui-conversation ·
dsh-client-ui-tool · dsh-client-ui-brand-official
```

Every row's `inject` target is asserted to be inside the roster at generation
time; a violation aborts the manifest build. One built-but-unlisted bundle
exists (`dsh-client-ui-input-trigger`, dropped as a §7 non-goal) — not
listing a plugin is upstream's supported degradation mechanism
(`packages/client/web/src/boot.ts::assertEntriesActive` hard-fails only
listed entries).

**zharness deviation (16 rows, not 15):** `dsh-client-ui-workspace` was added
to the roster after integration testing — the conversation hero's workspace
picker slot is registered by that package, and without it the composer stays
permanently gated behind "Choose workspace" (the slot renders nothing and no
selection can be made). The original 15-row trim is preserved in git history;
the picker is a load-bearing UI piece, not an optional feature plugin.

Current graph rev: `5b2376411f33` (changes whenever any lib/client.js changes).

## Integrator notes (Zig side, NOT wired yet)

- Serve `apps/web/dist/**` at `/`, `/plugins/<id>/client.js`(+`.map`) from
  `webui/dsh/packages/*/*/lib/`, and inject the four `injections` rows from
  `build-artifacts/boot-manifest.json` into every served index.html.
- Implement the §4 wire surface (13 unary methods + 2 WS downlinks).
- Attribution per spec §8: ship `webui/dsh/LICENSE` next to deployed
  artifacts; add the root `THIRD_PARTY_NOTICES.md` entry ("deepseek-harness
  Web GUI — Copyright (c) 2026 DeepSeek — MIT") and README note.

## Commit policy

- **Commit**: everything under `webui/` EXCEPT gitignored paths — i.e.
  vendored sources (~8 MB) + `apps/web/dist/` (**11 MB ≤ 20 MB threshold ⇒
  committed**) + `build-artifacts/`. Total ≈ 19.5 MB.
- **Never commit**: `webui/dsh/node_modules/` (536 MB),
  `webui/dsh/packages/*/*/lib/`, `webui/dsh/vendor/*/lib/`,
  `*.tsbuildinfo` — all already covered by `webui/dsh/.gitignore`
  (upstream's own ignore rules; the nested file applies repo-wide below
  `webui/dsh/`). Note: upstream ignored `apps/web/dist/`; that line was
  removed so dist can be committed.
- After pulling changes to vendored sources, rerun the full chain above;
  `lib/` artifacts stay local-only.

## Deviations from upstream (all recorded, all inside webui/**)

1. **Pruned tree** — python/, native/, examples/, website/, apps/cli, .github,
   .agents/.claude, docs/, and non-closure packages excluded; package
   `tests/` dirs dropped. Closure computed from package.json dep fields +
   tsconfig project references (both directions audited; 94 leaf packages).
2. **`package.json`: `postinstall` script removed** — it installed lefthook
   git hooks and would have mutated the enclosing zharness `.git` config.
   Nothing else in the manifest was edited; license/repository metadata
   preserved per spec §8(4).
3. **`--no-frozen-lockfile`** — required because workspace members absent
   from the original lockfile (python/sdk-runtime, native/*, examples,
   website, apps/cli, non-closure packages) had importer entries. The
   rewritten `pnpm-lock.yaml` matches the pruned member set and is committed.
4. **Additive files**: `tsconfig.vendor.json`, `tsdown.vendor-libs.ts`,
   `VENDOR-NOTICE.md`, `build-artifacts/` (zharness tooling outputs).
5. **`.gitignore`: removed the `apps/web/dist/` line** so the production
   dist can be committed per the ≤20 MB rule.
6. **Build orchestration replaced** by the 8-step chain above because
   upstream's aggregates (`tsconfig.client.json`, `scripts/build.ts`) span
   packages that are deliberately absent here.

## Verification achieved (2026-08-23)

- `tsc -b tsconfig.vendor.json`: clean across 94 packages + 7 vendor packages.
- vite build: succeeds; `apps/web/dist/` = 114 files, 11 MB.
- Static contract: index + all 89 non-map dist assets + all 15 plugin bundles
  + source maps return 200 with correct MIME via `serve-fixture.mjs`.
- Headless Chromium (playwright): full boot against `?fixture` — module
  loader reaches `live` mode, cordis activates all 15 entries, UI mounts
  (sidebar, hero, composer, fixture carrier chip), zero console errors, zero
  page errors, zero failed requests.
- Interactive round-trip: prompt submitted through the real composer renders
  the user bubble and the fixture carrier's streamed assistant reply with
  turn stats (1 turn · 1 step, TTFT/tok-s metered) — the complete
  session-event fold path works without a backend.
