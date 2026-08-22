# Zeepseek TUI 整改方案 (Remediation Plan)

> Scope: four user-reported items — `/` command menu + arrow-key selection +
> secondary-confirmation dialogs; blinking input cursor; benchmarking the TUI
> against the official ZigZag demo/app; and this remediation plan.

Reference for "对标": the official ZigZag example suite at
`vendor/zigzag/../examples/` (esp. `modal.zig`, `showcase.zig`) plus the
vendored component sources (`src/components/modal.zig`,
`src/components/text_input.zig`, `src/components/command_palette.zig`).

---

## 1. 验收矩阵 (Acceptance Matrix — currently ALL GREEN)

| Check | Command | Status |
|-------|---------|--------|
| Debug build | `zig build` | ✅ |
| Unit tests | `zig build test` | ✅ (305/305, no leaks) |
| Optimized build | `zig build -Doptimize=ReleaseFast` | ✅ |
| Integration compile | `zig build integration-test-compile` | ✅ |

---

## 2. What was already correct (no change needed)

- **Command palette arrow-key navigation.** The palette is ZigZag's
  `zz.components.CommandPalette`; `handleKey` already handles `.up` / `.down`
  (cursor moves), `.enter` (accept), `.escape` (cancel), backspace, and fuzzy
  filtering (`src/components/command_palette.zig:240`). The overlay is placed
  with an ANSI-aware overlay in `app.zig view()`.
- **Parameterized ("secondary") commands already prompt.** `/apikey`,
  `/model`, `/provider`, `/theme` return `.prompt` from the dispatcher and open
  the `slash_prompt` TextInput overlay (`slash_commands.openSlashPrompt`),
  with Enter submit / Esc cancel.

---

## 3. Fixes implemented this pass

### 3.1 ` / ` now opens the command menu (arrow keys already worked)

- `src/ui/app.zig` `onKey()`: typing `/` as the **first character of an empty
  input** opens the command palette and resets its filter. Previously `/` was
  always a literal character; the menu was only reachable via Ctrl+P.
- Parameterized commands remain fully usable: selecting `/model`, `/apikey`,
  etc. opens the existing prompt overlay, so nothing is lost.

### 3.2 Destructive commands now require a confirmation dialog

Benchmark-aligned with the official `Modal.confirm` pattern
(`examples/modal.zig` uses `Modal.confirm` + `viewWithBackdrop` +
`getResult()`):

- `src/ui/slash_command_dispatcher.zig`: added `Dispatcher.needsConfirm(id)`
  covering `/clear`, `/new`, `/save`, `/compact`, `/exit`.
- `src/ui/slash_commands.zig`:
  - `executeSlashCommand` now **gates** destructive commands into
    `openConfirmSlash` (a `zz.components.Modal.confirm` with backdrop) instead
    of running them.
  - `runSlashCommand` is the ungated executor (also used by the gate's Yes
    branch). `clearPendingConfirm` releases the pending id/body.
- `src/ui/app.zig`:
  - New state: `confirm_modal`, `pending_confirm_cmd`, `pending_confirm_body`.
  - `onKey`: while visible, the modal owns input; **Yes (y/Enter/Tab) runs the
    command, No (n) / Esc dismisses** — arrow keys cycle the button.
  - `view()`: the dialog renders as the topmost overlay via
    `viewWithBackdrop`, covering all other overlays.
- Tests updated: `/clear` and `/exit` now assert the confirm gate, then drive
  Enter through `onKey` and assert the side effect fires.

### 3.3 Blinking input cursor (root cause fixed)

The bug: `render_ui.renderClaudeInput` appended a `|` cursor to the input
string, but `display_input` only used that string **when the input overflowed**
— otherwise it fell back to the plain `input_view`, so the cursor never
appeared (and never blinked) for normal-length input.

- Vendored `text_input.zig`: added a `cursor_visible` field. When false, the
  component renders the text without its reverse-video caret
  (`view()` → `.normal` branch); when true it renders the caret at the exact
  `cursor` position via `renderWithCursor`.
- `renderClaudeInput` now sets `app.text_input.cursor_visible =
  app.cursor_visible` **before** calling `view()` and renders the component
  output directly (the manual `|` hack is deleted).
- `app.cursor_visible` already toggles every 500ms in the `.tick` handler, so
  the caret now blinks at the correct position. Password (`echo_mode
  .password`) and prompt/placeholder rendering are unaffected.

### 3.4 Latent test-build breakage fixed (keeps the matrix green)

`zig build test` was failing to compile because of pre-existing code that only
ever runs when the test runner analyzes `src/tools/*` (git/web):

- `src/tools/git.zig` test used `std.crypto.random` and
  `std.posix.getpid`/`std.time.milliTimestamp` — all removed in Zig 0.17 dev.
  Replaced with the repo's own wall-clock idiom
  (`std.c.clock_gettime(.REALTIME)`), and fixed the variadic `std.c.open`
  mode cast to `@as(std.c.mode_t, 0o644)`.
- `src/tools/web.zig` `resolveUrl` test asserted incorrect URL semantics
  (root-relative instead of directory-relative, dropped scheme). Fixed the
  assertions to match real relative-URL resolution
  (`https://a.com/dir/page` + `y` → `https://a.com/dir/y`).

---

## 4. Remaining recommendations (follow-up, non-blocking)

These would push the TUI further toward the official ZigZag demo structure but
were intentionally deferred to keep this pass surgical:

| Item | Current | ZigZag-official approach | Priority |
|------|---------|--------------------------|----------|
| **Tool-approval overlay** | Hand-rolled ASCII box (`app.zig:1973`) | `zz.Modal.confirm` + `viewWithBackdrop` (consistent with confirm dialog) | Medium |
| **Slash prompt overlay** | Custom TextInput + `Style.render` | `Modal` with an embedded `TextInput` (or `Form` component) | Low |
| **Focus management** | None; overlays capture keys ad-hoc | `zz.FocusGroup` for Tab-cycling between input/menus | Low |
| **Search overlay** | Custom (`renderSearchOverlay`) | `CommandPalette`-style filter or `Form` input | Low |
| **Cursor theme** | TextInput default reverse-video caret | Expose `cursor_style` from the theme so it matches the Zenburn Noir palette | Low |

General direction (benchmark): keep every overlay as a ZigZag component
(Modal / CommandPalette / Toast), drive blink state from the `.tick` message,
and avoid hand-drawing borders — all already true after this pass except the
tool-approval box noted above.

---

## 5. Files touched

| File | Change |
|------|--------|
| `src/ui/app.zig` | `/` opens palette; confirm-modal state + key routing + topmost render; deinit cleanup; tests updated |
| `src/ui/slash_commands.zig` | `executeSlashCommand` gate → `runSlashCommand`; `openConfirmSlash` / `clearPendingConfirm` |
| `src/ui/slash_command_dispatcher.zig` | `Dispatcher.needsConfirm` |
| `src/ui/render_ui.zig` | Drive `cursor_visible` before `view()`; drop `\|` hack |
| `vendor/zigzag/src/components/text_input.zig` | `cursor_visible` blink gate |
| `src/tools/git.zig` | Test-build fix (Zig 0.17 API removals) |
| `src/tools/web.zig` | `resolveUrl` test corrected to real URL semantics |
