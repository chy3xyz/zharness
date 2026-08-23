/* zharness web client — zero-build vanilla JS over the zharness HTTP API.
 *
 * Endpoints consumed (all same-origin, no auth — server binds 127.0.0.1):
 *   POST /run          {prompt, session?} -> {ok, answer?, session?, error?}
 *   GET  /sessions                        -> {ok, sessions:[{id, created_at, message_count}]}
 *   GET  /sessions/:id                    -> {ok, session:{id, created_at, messages:[{role, content}]}}
 *   GET  /healthz                         -> {ok:true}
 *   GET  /events       SSE: `data: {…}` envelopes drive the ticker;
 *                        heartbeat-only streams (`: comment` frames) stay silent.
 *
 * Rendering rules:
 *   role "user"      -> right-aligned bubble
 *   role "assistant" -> plain canvas text (+ inline tool-trace badges)
 *   role "tool"      -> tool-call badge row
 *   role "system"    -> dim divider
 *   {"ok":false}     -> red error card
 *
 * All DOM insertion uses textContent (no innerHTML with data) so transcript
 * content can never inject markup. */
"use strict";

(function () {
  // ── tiny helpers ────────────────────────────────────────────────────────
  const $ = (id) => document.getElementById(id);
  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  };
  const trunc = (s, n) =>
    s.length <= n ? s : s.slice(0, Math.max(0, n - 1)) + "…";

  // ── state ────────────────────────────────────────────────────────────────
  const state = {
    sessionId: null,
    readOnly: false,
    busy: false,
    online: null, // null = unknown until first health poll
  };

  // ── element handles ────────────────────────────────────────────────────
  const ui = {
    list: $("session-list"),
    newBtn: $("btn-new"),
    navBtn: $("btn-nav"),
    sidebar: $("sidebar"),
    title: $("view-title"),
    transcript: $("transcript"),
    prompt: $("prompt"),
    send: $("btn-send"),
    dot: $("health-dot"),
    healthLabel: $("health-label"),
    offline: $("offline-banner"),
    ticker: $("ticker"),
    readonlyNote: $("readonly-note"),
  };

  // ── API plumbing ────────────────────────────────────────────────────────
  async function apiJson(url, opts) {
    let res;
    try {
      res = await fetch(url, opts);
    } catch (e) {
      throw new Error("network unreachable");
    }
    let body = null;
    try {
      body = await res.json();
    } catch (e) {
      /* non-JSON error page: fall through to status check */
    }
    if (!res.ok || !body || body.ok === false) {
      const msg =
        body && typeof body.error === "string"
          ? body.error
          : "HTTP " + res.status;
      throw new Error(msg);
    }
    return body;
  }

  function mintSessionId() {
    const d = new Date();
    const p = (x) => String(x).padStart(2, "0");
    return (
      "web-" + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) +
      "-" + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds())
    );
  }

  function fmtRelative(unixSeconds) {
    if (!unixSeconds || unixSeconds <= 0) return ""; // server may not set it yet
    const s = Date.now() / 1000 - unixSeconds;
    if (s < 60) return "just now";
    if (s < 3600) return Math.floor(s / 60) + " min ago";
    if (s < 86400) return Math.floor(s / 3600) + " h ago";
    return Math.floor(s / 86400) + " d ago";
  }

  // ── rendering ───────────────────────────────────────────────────────────
  function column() {
    let col = ui.transcript.querySelector(".msg-column");
    if (!col) {
      col = el("div", "msg-column");
      ui.transcript.replaceChildren(col);
    }
    return col;
  }

  function showHero() {
    const hero = el("div", "hero");
    hero.appendChild(el("div", "hero-title", "zharness"));
    hero.appendChild(
      el("p", "", "Zero-build chat client for the local agent harness.")
    );
    hero.appendChild(
      el("p", "", "Send a task below, or pick a past session from the sidebar.")
    );
    ui.transcript.replaceChildren(hero);
  }

  function scrollToBottom() {
    ui.transcript.scrollTop = ui.transcript.scrollHeight;
  }

  // Tool-trace heuristics for assistant text: lines that look like tool
  // activity become badge chips instead of raw prose lines.
  const TOOL_LINE = /^\s*(?:\[(?:tool|Tool|TOOL)[\]:]|tool_use\b|tool_call\b|⚙|→\s*tool\b|Tool:\s)/;

  function renderAssistantText(container, text) {
    const badges = [];
    const plain = [];
    for (const line of String(text).split("\n")) {
      if (TOOL_LINE.test(line)) badges.push(line.trim());
      else plain.push(line);
    }
    if (badges.length) container.appendChild(toolRow(badges.join("\n")));
    const body = plain.join("\n").replace(/^\n+|\n+$/g, "");
    if (body) container.appendChild(el("div", "row-assistant", body));
  }

  function toolRow(detail) {
    const row = el("div", "row-tool");
    const chip = el("span", "tool-badge");
    chip.appendChild(el("span", "tool-gear", "⚙"));
    chip.appendChild(el("span", "tool-name", "tool"));
    chip.appendChild(el("span", "tool-detail", trunc(detail.replace(/\n+/g, " ⏎ "), 90)));
    row.appendChild(chip);
    return row;
  }

  function renderMessage(role, content) {
    const col = column();
    switch (role) {
      case "user": {
        const wrap = el("div", "row-user");
        wrap.appendChild(el("div", "bubble-user", content));
        col.appendChild(wrap);
        break;
      }
      case "assistant":
        renderAssistantText(col, content);
        break;
      case "tool":
        col.appendChild(toolRow(content));
        break;
      case "system":
        col.appendChild(el("div", "row-system", trunc(content, 80)));
        break;
      default:
        col.appendChild(el("div", "row-assistant", content));
    }
    scrollToBottom();
  }

  function renderTranscript(messages) {
    if (!messages.length) return showHero();
    const col = column();
    col.replaceChildren();
    for (const m of messages) renderMessage(m.role, m.content);
  }

  function showError(message) {
    column().appendChild(
      el("div", "row-error", "⚠ " + message)
    );
    scrollToBottom();
  }

  function showBusy() {
    const b = el("div", "turn-status", "working…");
    b.id = "busy";
    column().appendChild(b);
    scrollToBottom();
  }
  const clearBusy = () => $("busy")?.remove();

  // ── composer state ──────────────────────────────────────────────────────
  function syncComposer() {
    const disabled = state.busy || state.readOnly;
    ui.prompt.disabled = disabled;
    ui.prompt.placeholder = state.readOnly
      ? "This history is read-only…"
      : "Send a task to zharness…  (Enter to send · Shift+Enter for a newline)";
    ui.send.disabled = disabled || ui.prompt.value.trim() === "";
    ui.readonlyNote.classList.toggle("hidden", !state.readOnly);
  }

  function autoresize() {
    ui.prompt.style.height = "auto";
    ui.prompt.style.height = Math.min(ui.prompt.scrollHeight, 160) + "px";
  }

  // ── sessions sidebar ────────────────────────────────────────────────────
  async function refreshSessions() {
    try {
      const body = await apiJson("/sessions");
      renderSessionList(body.sessions || []);
    } catch (e) {
      /* offline or empty: leave current list alone */
    }
  }

  function renderSessionList(sessions) {
    ui.list.replaceChildren();
    if (!sessions.length) {
      ui.list.appendChild(
        el("div", "session-empty", "No saved sessions yet.")
      );
      return;
    }
    for (const s of sessions) {
      const item = el("button", "session-item");
      item.type = "button";
      if (s.id === state.sessionId) item.classList.add("active");
      item.appendChild(el("span", "session-name", s.id));
      const meta = [s.message_count + (s.message_count === 1 ? " msg" : " msgs"), fmtRelative(s.created_at)]
        .filter(Boolean).join(" · ");
      item.appendChild(el("span", "session-meta", meta));
      item.addEventListener("click", () => loadSession(s.id));
      ui.list.appendChild(item);
    }
  }

  async function loadSession(id) {
    ui.sidebar.classList.remove("open"); // mobile nav
    try {
      const body = await apiJson("/sessions/" + encodeURIComponent(id));
      state.sessionId = id;
      state.readOnly = true;
      ui.title.textContent = id;
      renderTranscript(body.session.messages || []);
      markActiveItem();
    } catch (e) {
      showError("Could not load session “" + id + "”: " + e.message);
    }
    syncComposer();
  }

  function markActiveItem() {
    ui.list.querySelectorAll(".session-item").forEach((n) => {
      n.classList.toggle(
        "active",
        n.querySelector(".session-name")?.textContent === state.sessionId
      );
    });
  }

  function newSession() {
    state.sessionId = null;
    state.readOnly = false;
    ui.title.textContent = "New session";
    showHero();
    markActiveItem();
    syncComposer();
    ui.prompt.focus();
  }

  // ── send flow ───────────────────────────────────────────────────────────
  async function send() {
    const text = ui.prompt.value.trim();
    if (!text || state.busy || state.readOnly) return;

    // Fresh conversations get a client-minted id so the run persists under a
    // name the sidebar can list; existing sessions keep theirs.
    if (!state.sessionId) state.sessionId = mintSessionId();

    state.busy = true;
    syncComposer();
    ui.prompt.value = "";
    autoresize();

    renderMessage("user", text);
    showBusy();

    try {
      const body = await apiJson("/run", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ prompt: text, session: state.sessionId }),
      });
      clearBusy();
      renderMessage("assistant", body.answer ?? "(empty answer)");
      refreshSessions(); // the new turn is now on disk
    } catch (e) {
      clearBusy();
      showError(e.message);
    } finally {
      state.busy = false;
      syncComposer();
    }
  }

  // ── health polling (15s cadence per spec) ───────────────────────────────
  async function pollHealth() {
    try {
      await apiJson("/healthz");
      state.online = true;
    } catch (e) {
      state.online = false;
    }
    ui.dot.className = "dot " + (state.online ? "dot-ok" : "dot-down");
    ui.healthLabel.textContent = state.online ? "online" : "offline";
    ui.offline.classList.toggle("hidden", state.online !== false);
  }

  // ── SSE activity ticker ─────────────────────────────────────────────────
  // Tolerant by design: heartbeat-only servers emit only `: comment` frames,
  // which EventSource never surfaces as messages, so the ticker stays hidden.
  function startEvents() {
    if (typeof EventSource === "undefined") return;
    let fadeTimer = null;
    const es = new EventSource("/events");
    es.onmessage = (ev) => {
      let env = null;
      try {
        env = JSON.parse(ev.data);
      } catch (e) {
        return; // tolerate non-JSON payloads silently
      }
      const type = env.event_type || env.type || env.event || "event";
      const detailRaw =
        env.payload_json ?? env.payload ?? env.detail ?? env.data ?? "";
      const detail =
        typeof detailRaw === "string"
          ? detailRaw
          : JSON.stringify(detailRaw) || "";
      ui.ticker.textContent = type + " · " + trunc(detail, 80);
      ui.ticker.classList.add("visible");
      clearTimeout(fadeTimer);
      fadeTimer = setTimeout(() => ui.ticker.classList.remove("visible"), 6000);
    };
    es.onerror = () => {
      /* EventSource reconnects on its own; healthz drives the banner */
    };
  }

  // ── wiring ──────────────────────────────────────────────────────────────
  ui.newBtn.addEventListener("click", newSession);
  ui.send.addEventListener("click", send);
  ui.navBtn.addEventListener("click", () => ui.sidebar.classList.toggle("open"));
  ui.prompt.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  });
  ui.prompt.addEventListener("input", () => {
    autoresize();
    syncComposer();
  });

  newSession();
  refreshSessions();
  pollHealth();
  setInterval(pollHealth, 15000);
  startEvents();
})();
