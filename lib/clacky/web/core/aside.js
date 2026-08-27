// ── Session aside chrome — resize / collapse / opener ─────────────────────
//
// Host-owned controls for the right column (#session-aside). The tab bar and
// bodies inside are rendered by Clacky.ext; this only drives the surrounding
// chrome so slot re-renders never disturb width or collapse state.
//
//   - drag #session-aside-resize to change width (persisted)
//   - #btn-aside-collapse hides the column; #btn-aside-open brings it back
//   - when the slot is empty (no panels for this agent) CSS collapses the
//     column on its own; the opener stays hidden in that case
//
// Depends on: nothing (loads right after core/ext.js).
// ───────────────────────────────────────────────────────────────────────────
"use strict";

(() => {
  const WIDTH_KEY = "clacky.aside.width";
  const OPEN_KEY  = "clacky.aside.open";
  const MIN_W = 256;
  const maxW = () => Math.max(MIN_W, Math.round(window.innerWidth * 0.8));

  const $ = (id) => document.getElementById(id);

  function slotEmpty() {
    const slot = $("ext-slot-session-aside");
    return !slot || slot.childElementCount === 0;
  }

  function applyOpenState() {
    const aside   = $("session-aside");
    const opener  = $("btn-aside-open");
    const overlay = $("workspace-overlay");
    if (!aside) return;
    let open = false;
    try {
      const stored = localStorage.getItem(OPEN_KEY);
      open = stored === null ? false : stored !== "0";
    } catch (_e) { /* ignore */ }
    const empty = slotEmpty();
    aside.classList.toggle("collapsed", !open);
    if (opener)  opener.style.display = (!open && !empty) ? "" : "none";
    if (overlay) overlay.classList.toggle("active", open && !empty);
  }

  function isOpen() {
    try {
      const stored = localStorage.getItem(OPEN_KEY);
      return stored !== null && stored !== "0";
    } catch (_e) { return false; }
  }

  function setOpen(open) {
    try { localStorage.setItem(OPEN_KEY, open ? "1" : "0"); } catch (_e) { /* ignore */ }
    applyOpenState();
  }

  function initResize() {
    const aside  = $("session-aside");
    const handle = $("session-aside-resize");
    if (!aside || !handle) return;

    try {
      const saved = parseFloat(localStorage.getItem(WIDTH_KEY));
      if (saved >= MIN_W && saved <= maxW()) aside.style.setProperty("--session-aside-width", saved + "px");
    } catch (_e) { /* ignore */ }

    let dragging = false;
    let startX = 0;
    let startW = 0;

    handle.addEventListener("mousedown", (e) => {
      e.preventDefault();
      dragging = true;
      startX = e.clientX;
      startW = parseFloat(getComputedStyle(aside).getPropertyValue("--session-aside-width"));
      handle.classList.add("active");
      aside.style.transition = "none";
      document.body.style.cursor = "col-resize";
      document.body.style.userSelect = "none";
    });

    document.addEventListener("mousemove", (e) => {
      if (!dragging) return;
      const dx = startX - e.clientX;
      const w = Math.min(maxW(), Math.max(MIN_W, startW + dx));
      aside.style.setProperty("--session-aside-width", w + "px");
    });

    document.addEventListener("mouseup", () => {
      if (!dragging) return;
      dragging = false;
      handle.classList.remove("active");
      aside.style.transition = "";
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
      const w = parseFloat(getComputedStyle(aside).getPropertyValue("--session-aside-width"));
      try { localStorage.setItem(WIDTH_KEY, w); } catch (_e) { /* ignore */ }
    });
  }

  // ── Public API ────────────────────────────────────────────────────────
  // Expose setOpen so external code (e.g. WS dispatcher) can open/close the
  // aside panel programmatically without duplicating localStorage logic here.
  // open() is a no-op when the panel is already open — safe to call unconditionally.
  if (window.Clacky) Clacky.Aside = {
    open:  () => { if (!isOpen()) setOpen(true); },
    close: () => setOpen(false),
  };

  function init() {
    // Re-assign in case Clacky was not yet defined when the IIFE ran.
    if (window.Clacky) Clacky.Aside = {
      open:  () => { if (!isOpen()) setOpen(true); },
      close: () => setOpen(false),
    };
    const collapse = $("btn-aside-collapse");
    const opener   = $("btn-aside-open");
    const overlay  = $("workspace-overlay");
    if (collapse) collapse.addEventListener("click", () => setOpen(false));
    if (opener)   opener.addEventListener("click", () => setOpen(true));
    if (overlay)  overlay.addEventListener("click", () => setOpen(false));
    initResize();
    applyOpenState();

    // Re-evaluate opener visibility whenever the slot content changes (panels
    // re-render on session / agent switch).
    const slot = $("ext-slot-session-aside");
    if (slot && window.MutationObserver) {
      new MutationObserver(() => applyOpenState()).observe(slot, { childList: true });
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
