#!/usr/bin/env python3
"""zharness vendored-build helper: interactive round-trip against the REAL host.

Boots the app at http://localhost:<port>/ and drives the full protocol chain:
workspace pick (when gated) -> session.create -> mux event frames -> UI fold.
Pass criteria: the composer unlocks, a submitted prompt renders the user
bubble AND a turn end (assistant text or an error card — no API key makes an
error card the expected assistant side).
"""
import json
import sys
from playwright.sync_api import sync_playwright

PORT = sys.argv[1] if len(sys.argv) > 1 else "4173"
URL = f"http://localhost:{PORT}/"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/dsh-roundtrip.png"
PROMPT = "Hello from zharness vendored-build verification"

console_errors = []
failed_requests = []

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1440, "height": 900})
    page.on("console", lambda m: console_errors.append(m.text) if m.type == "error" else None)
    page.on("pageerror", lambda e: console_errors.append(str(e)))
    page.on("response", lambda r: failed_requests.append(f"{r.url} :: {r.status}") if r.status >= 400 else None)
    page.on("requestfailed", lambda r: failed_requests.append(f"{r.url} :: {r.failure}"))

    page.goto(URL, wait_until="domcontentloaded", timeout=30000)
    page.wait_for_selector("#root > *", timeout=30000)
    page.wait_for_timeout(2000)

    # Fresh identity: the persisted-selection cell must not pre-open a stale
    # session from a previous browser profile.
    page.evaluate("() => localStorage.clear()")
    page.reload(wait_until="domcontentloaded")
    page.wait_for_selector("#root > *", timeout=30000)
    page.wait_for_timeout(2500)

    def composer_state():
        return page.evaluate("""() => {
            const t = document.querySelector('textarea')
            return t ? { readOnly: t.readOnly, placeholder: t.placeholder } : null
        }""")

    # Real-host mode may gate the composer behind workspace selection: the
    # inert trigger opens the picker on click. Fixture mode / already-selected
    # hosts skip straight to an editable composer. Both paths must work.
    composer = page.locator("textarea").first
    try:
        composer.click(timeout=3000)
    except Exception:
        pass  # overlay/interception: the picker probe below decides
    picked = False
    try:
        ws_item = page.locator("[class*='_itemLabel_']").first
        ws_item.wait_for(state="visible", timeout=3500)
        ws_item.click()
        picked = True
    except Exception:
        try:
            page.get_by_text("default", exact=False).first.click(timeout=1500)
        except Exception:
            pass  # fixture mode or auto-selection already opened a session

    # THE GATE: the composer must unlock (readOnly=false) once the picked
    # workspace owns a session — session.create -> host frames -> UI fold.
    try:
        page.wait_for_function(
            "() => { const t = document.querySelector('textarea');"
            " return t && !t.readOnly }",
            timeout=15000)
        unlocked = True
    except Exception:
        unlocked = False

    state = {"picked_via_picker": picked, "composer_unlocked": unlocked,
             "post_pick_state": composer_state()}

    if unlocked:
        # Keyboard-driven submit: fill() needs pointer actionability, which
        # decorative hero layers can legitimately intercept in headless runs.
        page.locator("textarea").first.focus()
        page.keyboard.insert_text(PROMPT)
        page.keyboard.press("Enter")

        # User bubble renders from the accepted prompt's user/message fold.
        try:
            page.wait_for_function(
                "(p) => document.body.innerText.includes(p)", arg=PROMPT, timeout=15000)
            user_bubble = True
        except Exception:
            user_bubble = False

        # Turn end: either assistant-side content streams in, or the run ends
        # in an error card (expected when no API key is configured).
        def turn_end_visible():
            return page.evaluate("""(p) => {
                const body = document.body.innerText
                // assistant text beyond the user echo: any message-ish node
                // whose text is not just the prompt itself
                const nodes = [...document.querySelectorAll(
                    '[class*="message" i], [class*="bubble" i], [class*="markdown" i]')]
                const hasAssistantText = nodes.some(n => {
                    const txt = n.textContent.trim()
                    return txt.length > 0 && !txt.includes(p)
                })
                // vendored turn-error row ("This turn failed …") or any alert
                const errNode = document.querySelector(
                    '[class*="turnError" i], [class*="error" i][class*="card" i], [role="alert"]')
                return hasAssistantText || errNode !== null ||
                    /this turn failed|run failed|错误/i.test(body)
            }""", PROMPT)

        turn_end = False
        import time
        end_by = time.time() + 20
        while time.time() < end_by:
            if turn_end_visible():
                turn_end = True
                break
            page.wait_for_timeout(500)
        page.wait_for_timeout(1500)  # let any final frames land

    state["user_prompt_rendered"] = unlocked and user_bubble
    state["turn_end_rendered"] = unlocked and turn_end

    body_text = page.evaluate("() => document.body.innerText.slice(0, 1200)")
    page.screenshot(path=OUT, full_page=False)
    browser.close()

report = {
    **state,
    "empty_state_gone": "Into the Unknown" not in body_text or state.get("user_prompt_rendered", False),
    "console_errors": console_errors[:10],
    "failed_requests": sorted(set(failed_requests))[:10],
    "body_text_head": body_text[:500],
}
print(json.dumps(report, indent=1))
ok = (state.get("composer_unlocked") and state.get("user_prompt_rendered")
      and state.get("turn_end_rendered") and not console_errors and not failed_requests)
print("ROUND-TRIP:", "PASS" if ok else "PARTIAL/FAIL")
sys.exit(0 if ok else 1)
