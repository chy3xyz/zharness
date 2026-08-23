#!/usr/bin/env python3
"""zharness vendored-build helper: headless boot smoke for the fixture carrier.

Loads http://localhost:<port>/ in headless Chromium (playwright),
captures console errors and failed requests, waits for the cordis plugin
tree to activate, and reports whether the app mounted (#root populated)
or the boot failure page rendered (assertEntriesActive failures list).
"""
import json
import sys
from playwright.sync_api import sync_playwright

PORT = sys.argv[1] if len(sys.argv) > 1 else "4173"
URL = f"http://localhost:{PORT}/"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/dsh-boot.png"

console_errors = []
console_messages = []
failed_requests = []
page_errors = []

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1440, "height": 900})
    page.on("console", lambda m: (
        console_errors.append(f"{m.type}: {m.text}") if m.type == "error"
        else console_messages.append(f"{m.type}: {m.text[:200]}")))
    page.on("pageerror", lambda e: page_errors.append(str(e)))
    page.on("requestfailed", lambda r: failed_requests.append(
        f"{r.url} :: {r.failure}"))
    page.on("response", lambda r: failed_requests.append(
        f"{r.url} :: HTTP {r.status}") if r.status >= 400 else None)

    page.goto(URL, wait_until="domcontentloaded", timeout=30000)
    # The boot chain: queue facade -> modules/runtime preloads -> vite shell
    # fetches 15 plugin bundles -> cordis activation -> mountApp into #root.
    try:
        page.wait_for_function(
            "() => document.querySelector('#root') && document.querySelector('#root').children.length > 0",
            timeout=30000)
        mounted = True
    except Exception:
        mounted = False
    page.wait_for_timeout(2500)  # let fixture-mode connection settle

    state = page.evaluate("""() => ({
        rootChildren: document.querySelector('#root')?.children.length ?? -1,
        rootHtmlBytes: document.querySelector('#root')?.innerHTML.length ?? -1,
        bootGraph: window.__DSH_BOOT__ ? { rev: window.__DSH_BOOT__.rev, entries: window.__DSH_BOOT__.entries.length } : null,
        loaderMode: window.__ModuleLoader__?.mode ?? null,
        bodyText: document.body.innerText.slice(0, 600),
        textareaCount: document.querySelectorAll('textarea').length,
        buttonSample: [...document.querySelectorAll('button')].slice(0, 12).map(b => b.textContent.trim()).filter(Boolean),
    })""")
    page.screenshot(path=OUT, full_page=False)
    browser.close()

report = {
    "url": URL,
    "mounted": mounted,
    "state": state,
    "console_errors": console_errors[:20],
    "page_errors": page_errors[:10],
    "failed_requests": sorted(set(failed_requests))[:20],
    "console_message_count": len(console_messages),
}
print(json.dumps(report, indent=1))
ok = (mounted and state["rootChildren"] > 0 and state["rootHtmlBytes"] > 500
      and not console_errors and not page_errors and not failed_requests)
print("BOOT-SMOKE:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
