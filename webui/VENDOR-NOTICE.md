# Vendor Notice — deepseek-harness Web GUI

This subtree (`webui/dsh/`) is a pruned vendored copy of the DeepSeek Harness
repository's web frontend, licensed MIT ("Copyright (c) 2026 DeepSeek").

- Upstream source: https://github.com/deepseek-ai/deepseek-harness
- Vendored upstream commit: `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`
- License: MIT — preserved in `LICENSE` (this directory)
- Scope decision + build contract: `docs/dsh-reuse-spec.md` (zharness repo),
  `webui/BUILD.md` (rebuild commands)

## What is vendored

- `apps/web/` — the vite shell (`@deepseek-ai/dsh-web-frontend`)
- 94 workspace packages under `packages/` — the transitive closure of the
  frontend build graph (client plugins, statics, typert, apiproxy contracts,
  and the node-half dependencies their manifests declare)
- `vendor/` — upstream's pinned Cordis framework sources (cordis, loader,
  cosmokit, schemastery, group, include, timer; each keeps its own LICENSE)
- Root build config: `package.json`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`,
  `tsconfig*.json`, `tsdown.config.ts`, `patches/`
- `scripts/` — upstream scripts minus vitest specs (the tsdown preset and
  vite config import from here at build time)

Package `tests/` directories were dropped; everything else in scope is
unmodified except the deviations listed in `webui/BUILD.md`.

## zharness-side additions inside this tree

- `tsconfig.vendor.json` — tsc solution over the pruned closure
- `tsdown.vendor-libs.ts` — scoped vendor-library bundle pass

Both are additive; no upstream file was edited except `package.json`
(postinstall removed — see BUILD.md).

## Attribution obligations (docs/dsh-reuse-spec.md §8)

1. This LICENSE (DeepSeek, MIT) ships alongside the artifacts.
2. zharness root `THIRD_PARTY_NOTICES.md` must carry an entry:
   "deepseek-harness Web GUI — Copyright (c) 2026 DeepSeek — MIT", listing
   the vendored package names and pointing at this tree's
   `THIRD_PARTY_NOTICES.md` for upstream's own vendored Cordis libraries.
3. zharness `README.md` notes the derivation when the GUI ships.
4. `license: MIT` / repository metadata in vendored package.json files is
   preserved untouched.
