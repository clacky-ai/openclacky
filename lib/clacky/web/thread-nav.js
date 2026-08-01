/**
 * thread-nav.js — In-thread navigation rail for the chat panel.
 *
 * Renders a vertical strip of dash markers on the left edge of #chat-main,
 * one per user message in the active session. Hovering a dash shows a
 * preview card with the user's question and the first line of the AI
 * reply. Clicking scrolls the message into view.
 *
 * Design notes:
 *  - Purely DOM-driven: we observe #messages via MutationObserver and
 *    rebuild the rail from .msg-user-wrap elements. No changes to
 *    sessions.js internals — the module is self-contained.
 *  - Zero-cost when the chat panel is hidden or there are no user
 *    messages (rail hides itself).
 *  - Reuses existing i18n / theme variables so it fits both light and
 *    dark mode without extra configuration.
 *
 * Public API (window.ThreadNav):
 *   init()     — wire observers & event listeners (idempotent)
 *   refresh()  — force a rebuild of the rail from the current DOM
 *   show()     — unhide the rail (called when a session is active)
 *   hide()     — hide the rail (called when leaving a session)
 */

(function () {
  "use strict";

  // ── State ──────────────────────────────────────────────────────────────
  let _inited = false;
  let _observer = null;
  let _rebuildTimer = null;
  let _scrollTimer = null;
  let _activeIdx = -1;

  // ── DOM helpers ────────────────────────────────────────────────────────

  function $(id) { return document.getElementById(id); }

  function railEl() {
    return $("thread-nav");
  }

  function messagesEl() {
    return $("messages");
  }

  function chatMainEl() {
    return $("chat-main");
  }

  // ── Rail construction ─────────────────────────────────────────────────

  /**
   * Truncate text for preview. Keeps CJK / Latin readable and avoids
   * cutting in the middle of surrogate pairs.
   */
  function _truncate(text, max) {
    if (!text) return "";
    const t = String(text).replace(/\s+/g, " ").trim();
    if (t.length <= max) return t;
    return Array.from(t).slice(0, max).join("") + "…";
  }

  /**
   * Find the first assistant reply following a user wrap element, walking
   * forward through siblings. Returns the .msg-assistant element or null.
   */
  function _findReplyFor(userWrap) {
    let node = userWrap.nextElementSibling;
    // Skip info / tool / progress messages until we hit the next assistant
    // or the next user wrap (means the assistant never replied).
    while (node) {
      if (node.classList && node.classList.contains("msg-user-wrap")) return null;
      if (node.classList && node.classList.contains("msg-assistant")) return node;
      // A submodel / nested container can wrap the assistant bubble — peek
      // inside one level to be safe.
      if (node.querySelector) {
        const inner = node.querySelector(".msg-assistant");
        if (inner) return inner;
      }
      node = node.nextElementSibling;
    }
    return null;
  }

  /**
   * Collect one entry per .msg-user-wrap in #messages. Returns
   * [{ wrap, question, reply, time }].
   */
  function _collectEntries() {
    const container = messagesEl();
    if (!container) return [];
    const wraps = container.querySelectorAll(".msg-user-wrap");
    const entries = [];
    wraps.forEach((wrap) => {
      const userEl = wrap.querySelector(".msg-user");
      if (!userEl) return;
      // The raw markdown of the user's message lives in the user bubble's
      // text content; fall back to innerText for safety.
      const question = _truncate(userEl.textContent || "", 80);
      if (!question) return;
      const replyEl = _findReplyFor(wrap);
      const reply = replyEl ? _truncate(replyEl.textContent || "", 120) : "";
      const time = wrap.querySelector(".msg-time");
      entries.push({
        wrap,
        question,
        reply,
        time: time ? time.textContent.trim() : "",
      });
    });
    return entries;
  }

  /**
   * Render the rail from the current DOM. Idempotent — clears and rebuilds.
   */
  function _rebuildRail() {
    const rail = railEl();
    const container = messagesEl();
    if (!rail || !container) return;

    const entries = _collectEntries();
    rail.innerHTML = "";

    if (!entries.length) {
      rail.classList.add("thread-nav-empty");
      return;
    }
    rail.classList.remove("thread-nav-empty");

    entries.forEach((entry, idx) => {
      const item = document.createElement("div");
      item.className = "thread-nav-item";
      item.dataset.idx = String(idx);

      const dash = document.createElement("div");
      dash.className = "thread-nav-dash";
      item.appendChild(dash);

      // Preview card (positioned on hover via CSS)
      const card = document.createElement("div");
      card.className = "thread-nav-card";
      const q = document.createElement("div");
      q.className = "thread-nav-q";
      q.textContent = entry.question;
      card.appendChild(q);
      if (entry.reply) {
        const a = document.createElement("div");
        a.className = "thread-nav-a";
        a.textContent = entry.reply;
        card.appendChild(a);
      }
      if (entry.time) {
        const t = document.createElement("div");
        t.className = "thread-nav-time";
        t.textContent = entry.time;
        card.appendChild(t);
      }
      item.appendChild(card);

      item.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        _scrollToEntry(entry, idx);
      });

      rail.appendChild(item);
    });

    _updateActiveFromScroll();
  }

  /**
   * Scroll the messages container so the target user wrap is near the top.
   */
  function _scrollToEntry(entry, idx) {
    const container = messagesEl();
    if (!container) return;
    const wrap = entry.wrap;
    if (!wrap || !wrap.isConnected) {
      _rebuildRail();
      return;
    }
    // Offset slightly so the bubble isn't flush against the top edge.
    const target = wrap.offsetTop - 24;
    container.scrollTo({ top: target, behavior: "smooth" });
    _setActive(idx);
  }

  /**
   * Highlight the dash at `idx`, clear all others.
   */
  function _setActive(idx) {
    if (idx === _activeIdx) return;
    _activeIdx = idx;
    const rail = railEl();
    if (!rail) return;
    rail.querySelectorAll(".thread-nav-item").forEach((el) => {
      const i = Number(el.dataset.idx || -1);
      el.classList.toggle("thread-nav-active", i === idx);
    });
  }

  /**
   * Update the active dash based on the messages container scroll position.
   * The "active" entry is the last user wrap whose top edge is above the
   * container's vertical midpoint.
   */
  function _updateActiveFromScroll() {
    const rail = railEl();
    const container = messagesEl();
    if (!rail || !container) return;
    const items = rail.querySelectorAll(".thread-nav-item");
    if (!items.length) return;

    const wraps = container.querySelectorAll(".msg-user-wrap");
    if (!wraps.length) return;

    const mid = container.scrollTop + container.clientHeight / 2;
    let active = 0;
    wraps.forEach((wrap, i) => {
      if (wrap.offsetTop <= mid) active = i;
    });
    _setActive(active);
  }

  // ── Event wiring ───────────────────────────────────────────────────────

  function _scheduleRebuild() {
    if (_rebuildTimer) clearTimeout(_rebuildTimer);
    _rebuildTimer = setTimeout(_rebuildRail, 60);
  }

  function _scheduleActiveUpdate() {
    if (_scrollTimer) clearTimeout(_scrollTimer);
    _scrollTimer = setTimeout(_updateActiveFromScroll, 80);
  }

  function _startObserver() {
    const container = messagesEl();
    if (!container || _observer) return;
    _observer = new MutationObserver((mutations) => {
      // Cheap early-out: if no user-wrap was added/removed, skip.
      let relevant = false;
      for (const m of mutations) {
        if (m.type !== "childList") continue;
        const touched = [...m.addedNodes, ...m.removedNodes];
        for (const n of touched) {
          if (!n || n.nodeType !== 1) continue;
          if (n.classList && n.classList.contains("msg-user-wrap")) { relevant = true; break; }
          if (n.querySelector && n.querySelector(".msg-user-wrap, .msg-assistant")) { relevant = true; break; }
        }
        if (relevant) break;
      }
      if (relevant) _scheduleRebuild();
    });
    _observer.observe(container, { childList: true, subtree: true });
  }

  function _stopObserver() {
    if (_observer) { _observer.disconnect(); _observer = null; }
  }

  // ── Public API ─────────────────────────────────────────────────────────

  const ThreadNav = {
    init() {
      if (_inited) return;
      _inited = true;

      // Rebuild on panel visibility changes (session switching shows/hides
      // #chat-panel and re-renders #messages).
      window.addEventListener("hashchange", () => setTimeout(_scheduleRebuild, 0));

      // Track scroll to update the active dash.
      const container = messagesEl();
      if (container) {
        container.addEventListener("scroll", _scheduleActiveUpdate, { passive: true });
      }

      // Track resizes — long sessions can change height when fonts load,
      // images expand, etc.
      window.addEventListener("resize", _scheduleRebuild);

      _startObserver();
      _rebuildRail();
    },

    refresh() {
      _rebuildRail();
    },

    show() {
      const rail = railEl();
      if (rail) rail.classList.remove("thread-nav-hidden");
      _startObserver();
      _rebuildRail();
    },

    hide() {
      const rail = railEl();
      if (rail) rail.classList.add("thread-nav-hidden");
      _stopObserver();
    },
  };

  // Expose globally so app.js / sessions.js can call it.
  window.ThreadNav = ThreadNav;

  // Auto-init once DOM is ready. The module is idempotent, so calling
  // init() again later is harmless.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => ThreadNav.init());
  } else {
    ThreadNav.init();
  }
})();
