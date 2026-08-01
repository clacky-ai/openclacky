/**
 * thread-nav.js — In-thread navigation rail for the chat panel.
 *
 * Renders a vertical strip of dash markers on the left edge of #chat-main,
 * one per user message in the active session. Hovering a dash shows a
 * preview card (rendered in a global portal so it is never clipped by the
 * rail's overflow). Clicking scrolls the message into view.
 *
 * Design notes:
 *  - Purely DOM-driven: we observe #messages via MutationObserver and
 *    rebuild the rail from .msg-user-wrap elements. No changes to
 *    sessions.js internals — the module is self-contained.
 *  - Zero-cost when the chat panel is hidden or there are no user
 *    messages (rail hides itself).
 *  - The preview card lives in a separate #thread-nav-tooltip element
 *    appended to <body> (position:fixed). This decouples it from the
 *    rail's overflow so the rail can scroll freely without clipping.
 *  - Reuses existing theme variables so it fits both light and dark
 *    mode without extra configuration. Visible strings go through i18n
 *    (see data-i18n-aria-label on #thread-nav in index.html).
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

  function railEl() {
    return document.getElementById("thread-nav");
  }

  function messagesEl() {
    return document.getElementById("messages");
  }

  function chatMainEl() {
    return document.getElementById("chat-main");
  }

  /**
   * Lazily create (or return existing) the single global tooltip element
   * used for all dash previews. Lives in <body> so it is never clipped by
   * the rail's overflow-y:auto.
   */
  function _tooltip() {
    let el = document.getElementById("thread-nav-tooltip");
    if (!el) {
      el = document.createElement("div");
      el.id = "thread-nav-tooltip";
      el.className = "thread-nav-card";
      el.setAttribute("role", "tooltip");
      document.body.appendChild(el);
    }
    return el;
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
   * Collect one entry per .msg-user-wrap in #messages, each paired with
   * the first .msg-assistant that follows it (if any). Single linear
   * pass over the children of #messages — O(n).
   * Returns [{ wrap, question, reply, time }].
   */
  function _collectEntries() {
    const container = messagesEl();
    if (!container) return [];
    const entries = [];
    // Walk children once; remember the most recent user entry that has
    // not yet been paired with a reply.
    for (const node of container.children) {
      if (node.nodeType !== 1) continue;
      if (node.classList.contains("msg-user-wrap")) {
        const userEl = node.querySelector(".msg-user");
        if (!userEl) continue;
        const question = _truncate(userEl.textContent || "", 80);
        if (!question) continue;
        const timeEl = node.querySelector(".msg-time");
        entries.push({
          wrap: node,
          question,
          reply: "",
          time: timeEl ? timeEl.textContent.trim() : "",
        });
        continue;
      }
      // An assistant reply: assign to the last entry that still has none.
      let replyEl = null;
      if (node.classList.contains("msg-assistant")) {
        replyEl = node;
      } else if (node.querySelector) {
        // A submodel / nested container can wrap the assistant bubble —
        // peek inside one level to be safe.
        replyEl = node.querySelector(".msg-assistant");
      }
      if (replyEl && entries.length) {
        const last = entries[entries.length - 1];
        if (!last.reply) last.reply = _truncate(replyEl.textContent || "", 120);
      }
    }
    return entries;
  }

  // ── Tooltip (preview card portal) ─────────────────────────────────────

  /**
   * Show the preview card for `entry`, anchored vertically on `item`.
   * The card is position:fixed so it ignores the rail's overflow entirely.
   */
  function _showTooltip(entry, item) {
    const tip = _tooltip();
    tip.innerHTML = "";

    const q = document.createElement("div");
    q.className = "thread-nav-q";
    q.textContent = entry.question;
    tip.appendChild(q);

    if (entry.reply) {
      const a = document.createElement("div");
      a.className = "thread-nav-a";
      a.textContent = entry.reply;
      tip.appendChild(a);
    }
    if (entry.time) {
      const t = document.createElement("div");
      t.className = "thread-nav-time";
      t.textContent = entry.time;
      tip.appendChild(t);
    }

    // Position: right of the rail, vertically centred on the item — clamped
    // to the viewport so the card never bleeds off-screen.
    const r = item.getBoundingClientRect();
    tip.style.left = r.right + 4 + "px";
    const halfH = tip.offsetHeight / 2;
    let top = r.top + r.height / 2;
    top = Math.max(halfH + 8, Math.min(top, window.innerHeight - halfH - 8));
    tip.style.top = top + "px";
    tip.classList.add("visible");
  }

  function _hideTooltip() {
    const tip = document.getElementById("thread-nav-tooltip");
    if (tip) tip.classList.remove("visible");
  }

  /**
   * Render the rail from the current DOM. Idempotent — clears and rebuilds.
   */
  function _rebuildRail() {
    const rail = railEl();
    const container = messagesEl();
    if (!rail || !container) return;

    const entries = _collectEntries();
    // The DOM was rebuilt, so any stale highlight index is invalid — reset
    // so _setActive re-applies the class to the freshly created items.
    _activeIdx = -1;
    rail.innerHTML = "";
    _hideTooltip();

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

      // No card child — the card is a global portal (see _showTooltip).

      item.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        _scrollToEntry(entry, idx);
      });

      // Preview card via global tooltip — immune to rail overflow.
      item.addEventListener("mouseenter", () => _showTooltip(entry, item));
      item.addEventListener("mouseleave", _hideTooltip);

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
    // .msg-user-wrap has position:relative, so its offsetParent is
    // #chat-main (position:relative), NOT #messages (static). Subtract the
    // container's own offset so the target is measured within the scroll
    // viewport — otherwise the jump lands off by the banner-slot height.
    const target = wrap.offsetTop - container.offsetTop - 24;
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

    // See _scrollToEntry: offsetParent is #chat-main, so subtract the
    // container offset to align with container.scrollTop.
    const base = container.offsetTop;
    const mid = container.scrollTop + container.clientHeight / 2;
    let active = 0;
    wraps.forEach((wrap, i) => {
      if (wrap.offsetTop - base <= mid) active = i;
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

      // Hide tooltip when the rail itself scrolls (dash moves away from cursor).
      const rail = railEl();
      if (rail) {
        rail.addEventListener("scroll", _hideTooltip, { passive: true });

        // Wheel containment: when the cursor is over the rail, wheel events
        // must scroll the rail ONLY — never chain through to #messages.
        // Without this, a non-overflowing (or boundary-hit) rail passes the
        // wheel to the sibling messages panel, which is what the user sees
        // as "scrolling the content instead of the sidebar".
        rail.addEventListener("wheel", function (e) {
          const maxScroll = rail.scrollHeight - rail.clientHeight;
          if (maxScroll <= 0) {
            // Rail has nothing to scroll — swallow the event so messages
            // don't move either.
            e.preventDefault();
            return;
          }
          const atTop = rail.scrollTop <= 0 && e.deltaY < 0;
          var atBottom = rail.scrollTop >= maxScroll - 1 && e.deltaY > 0;
          if (atTop || atBottom) {
            // Reached an edge — stop here, don't chain to #messages.
            e.preventDefault();
          }
        }, { passive: false });
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
      _hideTooltip();
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
