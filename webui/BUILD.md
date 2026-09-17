# webui — Vendored DSH Frontend (build contract)

`webui/` is a pruned vendored copy of the DeepSeek Harness web frontend
(upstream MIT, vendored at commit `0d1f50007f9bca3f52b06e1c3074fa14d5fb0720`,
master just past `dsh-v0.1.6-alpha.1` — see `webui/VENDOR-NOTICE.md`). Scope
and protocol rationale live in `docs/dsh-reuse-spec.md`; this file is the
operational build/serve contract.

## Layout

```
webui/                          vendored pnpm workspace (pruned closure, 94 packages + vendor/)
  dist/                         PRODUCTION DIST — final static assets (the integrator serves this)
  build-artifacts/
    boot-manifest.json          trimmed window.__DSH_BOOT__ graph: { graph, injections, roster }
  packages/*/*/lib/             build intermediates (gitignored): lib/types (tsc), client.js (tsdown)
  vendor/                       upstream's pinned Cordis framework sources
  tsconfig.vendor.json          zharness-added tsc solution over the pruned closure
  tsdown.vendor-libs.ts         zharness-added scoped vendor-library pass
  tools/                        zharness-side helpers (not part of the app):
    gen-typert.mjs              typert generation step (replaces upstream's host-face plugin)
    gen-boot-manifest.mjs       composes the trimmed 15-row boot manifest
    serve-fixture.mjs           static server implementing the hosting contract (dist + /plugins + boot injection)
    boot-smoke.py               headless boot assertion (?fixture carrier)
    roundtrip-smoke.py          headless prompt round-trip through the fixture carrier
```

## Rebuild from scratch (exact chain)

Requirements: Node ≥ 24 (`node --version`: v24.18.0 verified). No env vars
needed for fixture-mode builds; `DSH_CLIENT_*` variables are optional and
only affect branding/build-record metadata.

```sh
# 1. toolchain (once per machine) — upstream pins packageManager: pnpm@11.7.0
corepack enable
corepack prepare pnpm@11.7.0 --activate

# 2. install (from webui/)
cd webui
pnpm install --no-frozen-lockfile     # lockfile was rewritten once at vendor time; see Deviations

# 3. typecheck + emit lib/types for the whole pruned closure
./node_modules/.bin/tsc -b tsconfig.vendor.json

# 4. typert generation (writes lib/typert.* + ./remote subpath artifacts;
#    upstream does this inside its host-face tsdown pass — we drive the
#    generator directly because the host aggregate references dropped packages)
node tools/gen-typert.mjs

# NOTE on ordering: steps 3 and 4 are mutually dependent the first time only —
# step 3 fails on missing ./remote modules until step 4 has run once, and
# step 4's analyzer consumes lib/types of the typert generator package.
# First build order: 3 → (expect /remote errors) → 4 → 3 again. Subsequent
# incremental builds can run either order. A clean-tree one-liner:
#   ./node_modules/.bin/tsc -b tsconfig.vendor.json ; \
#   node tools/gen-typert.mjs ; \
#   ./node_modules/.bin/tsc -b tsconfig.vendor.json

# 5. bundle client halves — PER PACKAGE, not via the root workspace pass:
#    the root pass keeps different externals for some api/* packages than the
#    package-local configs do (unrun-config inlining difference), which leaves
#    require() calls the loader cannot answer at boot. Loop every dir with a
#    tsdown.config.ts instead:
for cfg in $(find packages native -name tsdown.config.ts -not -path "*/node_modules/*"); do
  (cd "$(dirname "$cfg")" && pnpm exec tsdown)
done
#    plus the three pure util libs the seed table imports (no local config —
#    they mirror the root host face's lib/types → lib/index.js):
for d in packages/util/brand packages/util/crypto packages/util/values; do
  cp "$d/lib/types/index.js" "$d/lib/index.js"
done

# 6. bundle the vendored framework libraries (cordis et al.) for the vite seed chunk
pnpm exec tsdown --config tsdown.vendor-libs.ts

# 7. production dist → dist/ (apps/web/dist is a symlink → ../../dist)
pnpm --filter @deepseek-ai/dsh-web-frontend run build

# 8. regenerate the boot manifest (after any rebuild — revs are content hashes;
#    mirrors ClientModuleRegistry.compose(): framedHash revs, combo batches)
node tools/gen-boot-manifest.mjs

# 9. link plugin bundles into dist + render the boot-injected index
#    (vite wipes dist on every build — BOTH steps are mandatory after step 7)
python3 tools/link-plugins.py     # symlinks /plugins/<pkg> -> packages/*/lib
node tools/inject-index.mjs       # index.injected.html (static.zig serves it for "/")
```

Steps 6–7 are incremental and fast when warm. The boot graph addresses
bundles through the `/plugins/??<id>/client.js,…&rev=<rev>` combo route;
`src/server/static.zig` serves it with upstream's buildComboScript semantics
(trailer stripping, `;\n` joins, stamped combo map URL), so no combo artifacts
are materialized on disk.

## Serve locally (fixture mode, no backend)

```sh
cd webui
node tools/serve-fixture.mjs 4173          # http://localhost:4173/?fixture
python3 tools/boot-smoke.py 4173           # headless boot assertion
python3 tools/roundtrip-smoke.py 4173      # headless prompt round-trip
```

The URL query `?fixture` makes the vendored connection plugin swap in its
in-browser mock carrier (`FixtureApiClient`) — no Zig server, no API routes,
no WebSocket endpoints needed. The server implements exactly three things:
static dist serving, `/plugins/<id>/client.js(.map)` with correct
content-type, and index.html head injection of the boot rows (queue facade +
two preload scripts + `globalThis.__DSH_BOOT__`), byte-mirroring
`packages/host/webserver/src/injections.ts` rendering semantics.

## Boot-manifest roster (v0.1.6: full parity)

The v0.1.6 re-vendor takes the opposite policy to the old trimmed roster:
EVERY web client plugin in the vendored closure is a manifest row (56 rows,
see `tools/gen-boot-manifest.mjs`), except:

- `dsh-client-hmr` — upstream's dev-server machinery; zharness serves a
  static production dist;
- `ui-directory-picker-browse` / `ui-directory-picker-native` — §7 non-goal;
  the browse variant hard-fails activation without the host directoryPicker
  RPC.

Plugins whose Host-facing RPC zharness does not implement follow upstream's
degradation rules: unknown methods answer bad-request envelopes and the
panels idle. The graph itself mirrors `ClientModuleRegistry.compose()`:
framedHash bundle revs, bootstrap/application combo batches partitioned at the
3 KiB URL limit, graph rev = shortHash(JSON.stringify({entries, batches})).

## Integrator notes (Zig side — WIRED)

- `src/server/static.zig` serves `dist/**` at `/` (index.injected.html for
  "/"); `src/server/apiproxy/router.zig` implements the RPC surface (well
  beyond the original §4 minimum — see its dispatch) plus the two WS
  downlinks (`/api/events.mux`, `/api/events.host`).
- Attribution per spec §8 shipped: `webui/LICENSE`, root
  `THIRD_PARTY_NOTICES.md`, and the README note.

## Commit policy

- **Commit**: everything under `webui/` EXCEPT gitignored paths — i.e.
  vendored sources (~9 MB) + `dist/` (**11 MB ≤ 20 MB threshold ⇒
  committed**) + `build-artifacts/`. Total ≈ 20.5 MB.
- **Never commit**: `webui/node_modules/` (536 MB),
  `webui/packages/*/*/lib/`, `webui/vendor/*/lib/`,
  `*.tsbuildinfo` — all already covered by `webui/.gitignore`
  (upstream's own ignore rules; the nested file applies repo-wide below
  `webui/`). Note: upstream ignored `dist/`; that line was
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
5. **`.gitignore`: removed the `dist/` line** so the production
   dist can be committed per the ≤20 MB rule.
6. **Build orchestration replaced** by the 8-step chain above because
   upstream's aggregates (`tsconfig.client.json`, `scripts/build.ts`) span
   packages that are deliberately absent here.

## Verification achieved (2026-08-23)

- `tsc -b tsconfig.vendor.json`: clean across 94 packages + 7 vendor packages.
- vite build: succeeds; `dist/` = 114 files, 11 MB.
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

## Verification achieved (2026-08-24, wave-6 vendor pass)

- `tsc -b tsconfig.vendor.json` clean across the full closure including the 16
  newly vendored packages (14 feature plugins + workflow/{workflow,
  tool-workflow}) — no source patches, no strictness relaxations.
- tsdown client pass emitted all 14 new `lib/client.js` bundles; vite build +
  manifest (36 rows, rev `cdf63c698b20`) + link-plugins + inject-index clean.
- Live-server smokes (`zharness serve --port 3080`): boot-smoke PASS — 36
  entries live, zero console errors / page errors / failed requests;
  roundtrip-smoke PASS — composer unlocked, user bubble + assistant turn
  rendered; settings page opens with zero console errors.

## Verification achieved (2026-09-17, v0.1.6 re-vendor)

- `tsc -b tsconfig.vendor.json`: clean across 9 vendor + 229 closure packages
  (leaf host/client references).
- Per-package tsdown loop: 98 configs + 3 util lib entries + vendor-libs
  (9 frameworks), zero failures.
- vite build: succeeds; `dist/` regenerated with the v0.1.6 shell.
- `gen-boot-manifest.mjs`: 56 rows / 2 combo batches, graph rev `92b7b7e42bcf`;
  inject closure check green.
- Live-server boot smoke (`zharness serve --port 3210`, headless Chromium):
  **PASS** — 56/56 entries activate, loader reaches `live` mode, UI mounts
  (sidebar, workspaces, settings, composer), zero console errors, zero failed
  requests, zero page errors.
- Zig-side additions verified by the live smoke: `/plugins/??…` combo route,
  `/api/remote.mux` WS (accept + structured `unavailable` stream errors),
  slash-form RPC normalization (`namespace/method` → handlers),
  `dynamicCordisRunner.inventory` / `.syncInspectManifest`, and the
  `/open-in-app/apps` empty catalog.

### Known gaps (next phase)

- **Remote streams**: `/api/remote.mux` accepts and degrades; the real
  `session.follow` / `session.control` / `$events` stream providers (prompt
  streaming + live transcript over the new protocol) are not implemented —
  the legacy `/api/events.mux` hub still drives the current prompt path.
- Fixture roundtrip (`roundtrip-smoke.py` against `serve-fixture.mjs`) is
  partial: the v0.1.6 composer gates on workspace selection and the fixture
  carrier does not yet model the new workspace/session controller RPCs.
- `zharness.general` settings rows and the models page render against the
  renamed settings contract; panel-level review against the live backend is
  still pending.
