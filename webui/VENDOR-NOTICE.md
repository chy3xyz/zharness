# Vendor Notice — deepseek-harness Web GUI

This subtree (`webui/`) is a pruned vendored copy of the DeepSeek Harness
repository's web frontend, licensed MIT ("Copyright (c) 2026 DeepSeek").

- Upstream source: https://github.com/deepseek-ai/deepseek-harness
- Vendored upstream commit: `0d1f50007f9bca3f52b06e1c3074fa14d5fb0720`
  (master, just past `dsh-v0.1.6-alpha.1`; previous baseline was
  `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`, v0.1.1-rc.2)
- License: MIT — preserved in `LICENSE` (this directory)
- Scope decision + build contract: `docs/dsh-reuse-spec.md` (zharness repo),
  `webui/BUILD.md` (rebuild commands)

## What is vendored

- `apps/web/` — the vite shell (`@deepseek-ai/dsh-web-frontend`)
- ~238 workspace packages under `packages/` — the transitive closure of the
  frontend build graph at the v0.1.6 line (api controllers, client store /
  session / chat / sidebar-right / dockkit, fs / shell / web / spill /
  ptc-runtime, session-format migrations, dynamic-cordis runner + UI, and the
  node-half dependencies their manifests declare)
- `vendor/` — upstream's pinned Cordis framework sources (cordis, loader,
  cosmokit, schemastery, group, include, timer, hmr, logger-console; each
  keeps its own LICENSE)
- `native/system/packages/entry` + `native/system/tsconfig.base.json` — the
  `@deepseek-ai/node-addon-system` package (BSD-3-Clause, upstream DeepSeek),
  vendored because sandbox-local / session-persistence-jsonl declare it as a
  workspace dependency and pnpm install validates workspace closure
- Root build config: `package.json`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`,
  `tsconfig*.json`, `tsdown.config.ts`, `patches/` (node-pty only; the
  desktop-only electron/yao-pkg patch declarations were dropped)
- `scripts/` — upstream scripts minus vitest specs (the tsdown preset and
  vite config import from here at build time)

Package `tests/` directories were dropped; everything else in scope is
unmodified except the deviations listed in `webui/VENDOR-PATCHES.md` and
`webui/BUILD.md`.

## zharness-side additions inside this tree

- `tsconfig.vendor.json` — tsc solution over the pruned closure (references
  leaf tsconfig.host/tsconfig.client configs so typert sees real fileNames)
- `tsdown.vendor-libs.ts` — scoped vendor-library bundle pass
- `tools/` — zharness build/serve/smoke helpers (gen-typert, boot-manifest,
  link-plugins, inject-index, serve-fixture, boot-smoke, roundtrip-smoke)
- `packages/client/ui-zharness-general` — zharness-authored settings plugin

No upstream file is edited beyond the recorded deviations.

## Attribution obligations (docs/dsh-reuse-spec.md §8)

1. This LICENSE (DeepSeek, MIT) ships alongside the artifacts.
2. zharness root `THIRD-PARTY_NOTICES.md` must carry an entry:
   "deepseek-harness Web GUI — Copyright (c) 2026 DeepSeek — MIT", listing
   the vendored package names and pointing at this tree's
   `THIRD_PARTY_NOTICES.md` for upstream's own vendored Cordis libraries;
   `native/system/packages/entry` is BSD-3-Clause and is disclosed there too.
3. zharness `README.md` notes the derivation when the GUI ships.
4. `license` / repository metadata in vendored package.json files is
   preserved untouched.
