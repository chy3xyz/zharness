# webui — Vendored DeepSeek Harness Web GUI

This directory is a pruned vendored copy of the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
web frontend (upstream MIT, see `VENDOR-NOTICE.md` and
`../THIRD-PARTY_NOTICES.md`). It is NOT built or run with upstream's
`npx @deepseek-ai/dsh` toolchain — zharness serves the prebuilt `dist/`
bundle natively from Zig (`src/server/static.zig` +
`src/server/apiproxy/router.zig`).

- Build/serve contract and rebuild chain: [`BUILD.md`](BUILD.md)
- Vendoring scope + protocol rationale: [`../docs/dsh-reuse-spec.md`](../docs/dsh-reuse-spec.md)
- Per-package vendor deviations: [`VENDOR-PATCHES.md`](VENDOR-PATCHES.md)
- License: [MIT](LICENSE)

The upstream README (upstream run instructions, community links) is
preserved in git history — it lived at `webui/dsh/README.md` before the
webui/ promotion.
