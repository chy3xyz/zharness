# Third-Party Notices

## Vendored frontend — DeepSeek Harness web client

This repository vendors a pruned subset of the
[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) web
frontend under `webui/` (sources + production dist).

- **License:** MIT
- **Upstream commit:** `0d1f50007f9bca3f52b06e1c3074fa14d5fb0720` (master, past dsh-v0.1.6-alpha.1)
- **Upstream license file:** `webui/LICENSE` (preserved verbatim)
- **Scope of modifications:** pruned package closure (see `webui/BUILD.md`
  "Deviations"), added zharness build glue (`tsconfig.vendor.json`,
  `tsdown.vendor-libs.ts`, `webui/tools/*`), removed `postinstall` hook.
  All product source files under `packages/**` and `apps/web/src/**` are
  unmodified upstream code unless a header comment states otherwise.

Copyright (c) 2026 DeepSeek — MIT License. The full license text is
reproduced in `webui/LICENSE`.

## Runtime dependencies of the vendored frontend

Bundled into `webui/apps/web/dist/` at build time and covered by their
upstream licenses (React, and the packages listed in
`webui/VENDOR-NOTICE.md`). No npm packages are shipped as source in this
repository outside `webui/node_modules` (gitignored, rebuilt via pnpm).

### `@deepseek-ai/node-addon-system` (`webui/native/system/packages/entry`)

Vendored with the frontend workspace because sandbox and session-persistence
packages declare it as a workspace dependency.

- **License:** BSD-3-Clause
- **Upstream path:** `native/system/packages/entry` in the pinned commit

Copyright (c) 2026 DeepSeek. Redistribution and use in source and binary
forms, with or without modification, are permitted provided that the three
BSD-3-Clause conditions (upstream `LICENSE`-carrying source headers) are met.
