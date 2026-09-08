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
