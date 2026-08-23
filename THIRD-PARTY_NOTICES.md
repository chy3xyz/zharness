# Third-Party Notices

## Vendored frontend — DeepSeek Harness web client

This repository vendors a pruned subset of the
[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) web
frontend under `webui/dsh/` (sources + production dist).

- **License:** MIT
- **Upstream commit:** `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`
- **Upstream license file:** `webui/dsh/LICENSE` (preserved verbatim)
- **Scope of modifications:** pruned package closure (see `webui/BUILD.md`
  "Deviations"), added zharness build glue (`tsconfig.vendor.json`,
  `tsdown.vendor-libs.ts`, `webui/tools/*`), removed `postinstall` hook.
  All product source files under `packages/**` and `apps/web/src/**` are
  unmodified upstream code unless a header comment states otherwise.

Copyright (c) 2026 DeepSeek — MIT License. The full license text is
reproduced in `webui/dsh/LICENSE`.

## Runtime dependencies of the vendored frontend

Bundled into `webui/dsh/apps/web/dist/` at build time and covered by their
upstream licenses (React, and the packages listed in
`webui/dsh/VENDOR-NOTICE.md`). No npm packages are shipped as source in this
repository outside `webui/dsh/node_modules` (gitignored, rebuilt via pnpm).
