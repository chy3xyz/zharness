# VENDOR-PATCHES — wave-6 feature-plugin vendoring deviations

Upstream sources are otherwise copied verbatim from `_ref/deepseek-harness`
(pinned commit `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`). Every deviation
made to vendored files or zharness build tooling during the wave-6 vendor pass
is listed here. No TypeScript source was patched and no package-local tsconfig
relaxation (`noImplicitAny`) was needed — the full `tsc -b tsconfig.vendor.json`
pass came up clean on first try.

## Vendored-file edits

| File | Reason | Diff summary |
|---|---|---|
| `webui/packages/workflow/tool-workflow/package.json` | devDependency `@deepseek-ai/dsh-workflow-worker-thread` is not vendored (its own closure pulls subagent spawn drivers); `src/` never imports it — it is test-only. Left in place it would break `pnpm install` workspace resolution. | removed one `devDependencies` entry |

That is the only edit to any upstream file. The 14 UI plugin packages
(`ui-goal`, `ui-skill`, `ui-model-selection`, `ui-agent-preset`,
`ui-permission-presets`, `ui-subagent`, `ui-plan`, `ui-trajectory`,
`ui-user-questions`, `ui-jobs`, `ui-workflow-run`, `ui-commands`,
`ui-message-feedback`, `ui-reference`) and the two support packages
(`workflow/workflow`, `workflow/tool-workflow`) were copied with only their
`tests/` dirs dropped (existing precedent).

## Tooling changes (zharness-side, not vendored code)

- `webui/tools/gen-boot-manifest.mjs`
  - Roster 21 → 36 rows: added `dsh-client-ui-input-trigger` (previously
    dropped as a §7 non-goal; four wave-6 plugins inject it, so it is now
    load-bearing) plus all 14 wave-6 feature plugins.
  - Inject-closure check relaxed: an `inject` target may now be a workspace
    package **without** a web `dsh.client` declaration (statically linked into
    the vite seed — e.g. `dsh-client-ui-primitives`, injected by ui-jobs /
    ui-subagent but never a plugin row, upstream included). Targets that ARE
    client packages but unlisted still abort the manifest build.
- `webui/tsconfig.vendor.json`: added project references for the 14 UI
  plugins + `packages/workflow/{workflow,tool-workflow}`.

## New npm dependencies

None added to the root `package.json`. All new npm deps arrive through the
copied packages' own manifests and are small pure-JS libraries already in the
pnpm store: `clsx` ^2 (ui-model-selection / ui-user-questions / ui-commands),
`diff` ^9 + `@tanstack/react-virtual` ^3.14 (ui-trajectory).

---

# v0.1.6 re-vendor deviations (baseline 0d1f500, was b150a55 / v0.1.1-rc.2)

The 4025-commit upstream jump restructured the client runtime (client-runtime
split into client-store / ui-session; api/* controller split), so the tree was
re-synced wholesale: 237 closure dirs + 201 group-level loose files, closure
recomputed from apps/web + prior roster (115 → 243 packages). Deviations,
all recorded per the vendor contract:

## Vendored-file edits

| File | Reason |
|---|---|
| root `package.json` | `postinstall` (lefthook) removed (existing deviation); 9 out-of-closure `workspace:` devDependencies dropped (browser-use / computer-use / experimental-* / llm-replay — upstream dev-only tooling whose packages are not vendored) |
| `pnpm-workspace.yaml` | `@electron/osx-sign` + `@yao-pkg/pkg` `patchedDependencies` entries removed (desktop packaging only; pnpm errors on unused patches) |
| `packages/client/tsdown.client.ts` | `REPOSITORY_ROOT` anchored with a `process.cwd()` fallback — the `unrun` config loader inlines the module into its cache dir, detaching `import.meta.url` from the checkout |
| `packages/client/web/src/platform.ts` + `seed.ts` | `@deepseek-ai/dsh-brand` / `dsh-util-crypto` / `dsh-util-values` added to `PLATFORM_MODULES` + the static seed table (see below) |
| `packages/client/web/tsconfig.json` + `package.json` | project references + workspace deps for the three seed words above |
| `packages/client/ui-zharness-general/*` | zharness plugin re-targeted after `dsh-client-runtime` was deleted upstream: `ClientContext` now from `@deepseek-ai/cordis`, `SettingsScope` from `@deepseek-ai/dsh-client-ui-settings/client`, `ctx.slots` merge via a type-only `@deepseek-ai/dsh-client-ui-renderer/client` import; tsconfig reference `../runtime` removed; manifest dsh.client.inject entry dropped |
| `patches/` | desktop patches deleted (declarations removed above); node-pty patch kept (still in-graph via pi-ai) |

## Seed-word extension (why)

The v0.1.6 client bundles keep a few shared pure-value libraries external
(`dsh-brand`, `dsh-util-crypto`, `dsh-util-values`); the loader resolves them
only against the platform seed or a graph row, and none of the three ships a
`dsh.client` declaration (so it can never be a row). Registering them as
platform seed words is the designed extension point — `platform.ts` and
`seed.ts` fail to compile if the two lists drift.

## Tooling changes (zharness-side)

- `tsconfig.vendor.json` regenerated: 9 vendor + 229 package references, with
  dual-face packages referenced through their LEAF `tsconfig.host.json` /
  `tsconfig.client.json` configs — the solution-style directory references of
  v0.1.1 give the typert `WorkspaceAnalyzer` empty `fileNames` and
  `gen-typert.mjs` then cannot see entry sources
- `tools/gen-boot-manifest.mjs`: roster is now EVERY web client plugin in the
  closure except `dsh-client-hmr` (upstream dev-server machinery) and the
  `ui-directory-picker-browse`/`-native` pair (§7 non-goal; the browse variant
  hard-fails without the host directoryPicker RPC); graph composition mirrors
  `ClientModuleRegistry.compose()` — framedHash bundle revs, bootstrap/
  application combo batches with the 3 KiB URL partition, graph rev over
  `{entries, batches}`; inject-closure check kept
- `tools/link-plugins.py`: roster→dir mapping derives from scanning
  `packages/*/*/package.json` names (extensions/session-query plugins no
  longer match the old hard-coded prefix table)
- `tools/serve-fixture.mjs`: serves the new `/plugins/??a/client.js,b/…&rev=`
  combo route (buildComboScript concatenation semantics), renders the
  `script-preload` injection row, scans all package groups
- unrun added as a root devDependency (tsdown 0.22's config loader)
- The root workspace client pass (`tsdown --env.DSH_BUILD_FACE client`) and
  per-package `pnpm exec tsdown` produce different externals for some api
  packages; the rebuild chain therefore uses a per-package tsdown loop over
  every dir carrying a `tsdown.config.ts` (see BUILD.md)

## New npm dependencies

`unrun` (root devDependency, tsdown config loader). Everything else arrives
through the copied packages' own manifests.
