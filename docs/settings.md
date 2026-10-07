# Settings — the GUI's face over `~/.zharness/config.toml`

The vendored dsh web GUI renders its **Settings** page from the
`settings.describe` RPC; every edit travels back through
`settings.update` / `settings.mutate` / `settings.replace`. This document is
the zharness-side contract: which namespaces exist, where each field lives in
`~/.zharness/config.toml`, and what the guarantees and limits are.

Wire truth: `_ref/deepseek-harness/packages/host/apiproxy/src/api/settings*.ts`
(zod schemas) and `webui/packages/client/ui-settings/src/**` (the browser
mirror). Implementation: `src/server/apiproxy/settings.zig` (document model),
`src/server/apiproxy/router.zig` (RPC surface), `src/config.zig`
(flat-TOML reader/writer).

## Namespaces

`settings.describe` answers:

```json
{
  "writable": true,
  "hasDocument": true,
  "namespaces": [ /* agent, llm-deepseek, ui-theme, locale, ui-onboarding */ ]
}
```

Each namespace row carries a schemastery envelope (`{uid, refs}` — the exact
serialization of `Schema.toJSON()`, rehydrated client-side with
`new Schema(json)`), the effective value, the raw user layer (`user`), an
`applies` marker, `secrets`, and a monotonic per-process `revision`.
`expectedRevision` on a write fences against stale editors; a mismatch is the
upstream `settings-conflict` error.

| ns | value shape | config.toml mapping | applies |
|---|---|---|---|
| `agent` | `{provider, model, maxTurns, reasoningEffort, stream, sandboxMode}` | `[model] provider/model`, `[agent] max_turns/reasoning_effort/stream`, `[general] sandbox_mode` | restart |

`[agent] compact_threshold` / `compact_keep_recent` are read by the runtime at
startup (context compaction, see `src/agent/compaction.zig`); they are not part
of the `agent` settings RPC namespace, and the settings writer preserves them.
| `llm-deepseek` | `{baseURL, apiKeyEnv?, models?: [{id,…}]}` | `[model] endpoint/api_key/models` | restart |
| `ui-theme` | `{preference: light\|dark\|system}` | `[preferences] theme` | live* |
| `locale` | `{preference?: zh\|en}` | `[preferences] locale` | live* |
| `ui-onboarding` | `{welcomeNoticeVersion}` | `[preferences] welcome_notice_version` | live* |

(\*) the Host only persists these; the owning client plugin applies them
live. `ui-theme` / `locale` are consumed by the vendored Appearance/Language
rows; `ui-onboarding` is the vendored GUI's WelcomeNotice acknowledgement
(pre-acknowledged at the shipped notice version — see
`apiproxy.settings.onboarding_notice_version`).

### Document example

```toml
[model]
provider = "deepseek"
model = "deepseek-v4-flash"
api_key = "sk-…"            # written via credentials.set (DEEPSEEK_API_KEY)
endpoint = "https://api.deepseek.com/chat/completions"

[agent]
max_turns = 64
reasoning_effort = "medium"
stream = true
compact_threshold = 480000  # transcript char budget; 0 disables compaction
compact_keep_recent = 16    # verbatim tail messages compaction keeps

[general]
sandbox_mode = "process"

[preferences]
theme = "dark"              # absent ⇒ system
# locale = "en"             # absent ⇒ browser default
```

## Precedence with environment variables

`config.load()` resolves env FIRST at boot: `ZHARNESS_API_KEY` /
`DEEPSEEK_API_KEY` beat the document's `api_key`; `ZHARNESS_ENDPOINT` beats
the document's `endpoint`. Consequences surfaced here deliberately:

- The describe VALUE reports document truth; `apiKeyEnv` presence reflects
  the EFFECTIVE credential state.
- When a key comes from the environment, `credentials.describe` reports
  `writable:false` and the Models page locks the key field — editing it in
  the GUI would silently lose to the env var at the next boot.
- All `agent` / `llm-deepseek` fields are `applies:"restart"`: writes persist
  immediately but a running server keeps its boot-time values.

## Credentials domain

zharness has no credential vault. The two harness-managed references map onto
the document:

- `DEEPSEEK_API_KEY` and `ZHARNESS_API_KEY` ⇄ `[model] api_key`
  (`credentials.set` overwrites, `unset` removes the line).
- Any other reference: reported absent and non-writable.

## Writer guarantees and limits

`src/config.zig` implements a minimal flat TOML round-trip
(`parseTomlFlat` / `applyConfigKvs`):

- Preserved across edits: comments, blank lines, unknown keys, unknown
  sections, key ordering.
- Updated keys rewrite in place; new known keys append inside their section;
  missing sections are created at EOF.
- Inline comments AFTER a value being updated are dropped (the line is
  rewritten).
- Values may be basic strings, integers, booleans, or verbatim raw arrays /
  inline tables (JSON-compatible syntax, e.g. `models = [{"id":"m1"}]`) — raw
  values are stored and re-emitted byte-exact without parsing.
- Writes are atomic: tmp file + rename into `~/.zharness/.` (checkpoint-writer
  style), all under one store mutex.

### Models-list projection

`llm-deepseek.models` is an array client-side while the runtime runs ONE
model. Projection rule: `describe` renders `models:[{id:<model>}]` from
`[model] model`; a write takes row 0 as the new `model` and stores any extra
rows verbatim under `[model] models` for lossless re-display. The runtime v1
ignores rows beyond index 0.

## main.zig wiring (integrator note)

Router.zig lazily self-installs the settings store from `ApiProxyDeps.home`
on the first settings/credentials/llm RPC — zero main.zig changes required.
To make installation explicit instead (recommended final form), add ONE line
in serve startup after `homeDir()` is known:

```zig
// Explicit settings-store install (optional; router lazy-inits otherwise):
_ = try apiproxy.installDefaultSettings(alloc, apx_deps.home);
```

Full dep-pointer form (overrides the built-ins; only needed to replace the
config.toml backend):

```zig
apx_deps.* = .{
    // … existing fields …
    .settingsDescribe   = mySettingsDescribe,   // fn (?*anyopaque, Allocator) ![]u8
    .settingsUpdate     = mySettingsWrite,      // fn (?*anyopaque, Allocator, payload []const u8) ![]u8
    .settingsMutate     = mySettingsWrite,
    .settingsReplace    = mySettingsWrite,
    .llmProviders       = myLlmProviders,       // fn (?*anyopaque, Allocator) ![]u8
    .credentialsDescribe= myCredsDescribe,      // payload → value JSON
    .credentialsSet     = myCredsWrite,         // payload → void
    .credentialsUnset   = myCredsWrite,
};
```

With no pointer and no installed store, `settings.describe` answers the
legacy read-only stub (one pre-acknowledged `ui-onboarding` row) and every
write reports not-implemented — the wave-4 behavior, preserved.
