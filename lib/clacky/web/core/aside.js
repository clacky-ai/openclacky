// ── Session aside chrome — resize / collapse / opener ─────────────────────
//
// Host-owned controls for the right column (#session-aside). The tab bar and
// bodies inside are rendered by Clacky.ext; this only drives the surrounding
// chrome so slot re-renders never disturb width or collapse state.
//
//   - drag #session-aside-resize to change width (persisted)
//   - panels ask for extra width via Clacky.Aside.requestWidth(); the clamp
//     lives here so no caller can push the mobile drawer off-screen
//   - #btn-aside-collapse hides the column; #btn-aside-open brings it back
//   - #btn-aside-fullscreen hides the chat column and lets the aside take
//     the whole workspace (Esc or the button again to leave; collapsing the
//     panel also leaves fullscreen)
//   - when the slot is empty (no panels for this agent) CSS collapses the
//     column on its own; the opener stays hidden in that case
//
// Depends on: nothing (loads right after core/ext.js).
// ───────────────────────────────────────────────────────────────────────────
"use strict";

(() => {
  const WIDTH_KEY = "clacky.aside.width";
  const OPEN_KEY  = "clacky.aside.open";
  const FULLSCREEN_KEY = "clacky.aside.fullscreen";
  const MIN_W = 256;
  const maxW = () => Math.max(MIN_W, Math.round(window.innerWidth * 0.8));
  // Matches the CSS breakpoint where the aside becomes a fixed overlay drawer.
  const isNarrow = () => window.matchMedia("(max-width: 768px)").matches;

  const $ = (id) => document.getElementById(id);

  // Custom properties resolve to the authored token, not px — the CSS default
  // is 16rem, so it needs converting. Every width set here (and the persisted
  // one) is already px.
  function currentWidth() {
    const aside = $("session-aside");
    if (!aside) return 0;
    let raw = "";
    try {
      raw = getComputedStyle(aside).getPropertyValue("--session-aside-width").trim();
    } catch (_e) { return 0; }
    const n = parseFloat(raw);
    if (!isFinite(n)) return 0;
    if (/rem$/.test(raw)) {
      const root = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
      return n * root;
    }
    return n;
  }

  function setWidth(px) {
    const aside = $("session-aside");
    if (aside) aside.style.setProperty("--session-aside-width", px + "px");
  }

  // Panels that need horizontal room (diff, file preview) ask for a wider
  // aside. The request is clamped to maxW(): an unclamped target wider than
  // the viewport would push the fixed-position mobile drawer off-screen,
  // taking the tab bar and the close button with it.
  //
  // Returns a function that gives borrowed width back, or null when nothing
  // was borrowed — so a caller can always call the result without tracking
  // whether its request actually did anything.
  function requestWidth(px, opts) {
    const aside = $("session-aside");
    if (!aside || isNarrow()) return null;
    const target = Math.min(maxW(), Math.max(MIN_W, px));
    const previous = currentWidth();
    if (previous >= target) return null;
    setWidth(target);
    if (opts && opts.persist) {
      try { localStorage.setItem(WIDTH_KEY, String(target)); } catch (_e) { /* non-fatal */ }
      return null;
    }
    // Only give the width back if it is still the one we set: the user may have
    // dragged the handle, or another panel may have widened further, and their
    // width wins.
    return () => {
      if (Math.round(currentWidth()) === Math.round(target)) setWidth(previous);
    };
  }

  function clampWidth() {
    const w = currentWidth();
    if (!w) return;
    const max = maxW();
    if (w > max) setWidth(max);
  }

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
    // A fullscreen class with an empty slot would show an empty column over
    // the whole workspace (the fullscreen rule outranks the empty-slot one).
    if (empty) setFullscreen(false);
  }

  function isOpen() {
    try {
      const stored = localStorage.getItem(OPEN_KEY);
      return stored !== null && stored !== "0";
    } catch (_e) { return false; }
  }

  function setOpen(open) {
    try { localStorage.setItem(OPEN_KEY, open ? "1" : "0"); } catch (_e) { /* ignore */ }
    if (!open) setFullscreen(false);
    applyOpenState();
  }

  function isFullscreen() {
    try { return localStorage.getItem(FULLSCREEN_KEY) === "1"; } catch (_e) { return false; }
  }

  function applyFullscreenState() {
    const chatPanel = $("chat-panel");
    if (chatPanel) chatPanel.classList.toggle("aside-fullscreen", isFullscreen());
    const btn = $("btn-aside-fullscreen");
    if (btn && window.Clacky && Clacky.I18n) {
      btn.title = Clacky.I18n.t(isFullscreen() ? "aside.exitFullscreen" : "aside.fullscreen");
    }
  }

  function setFullscreen(on) {
    try { localStorage.setItem(FULLSCREEN_KEY, on ? "1" : "0"); } catch (_e) { /* ignore */ }
    applyFullscreenState();
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
      startW = currentWidth();
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
      const w = currentWidth();
      try { localStorage.setItem(WIDTH_KEY, w); } catch (_e) { /* ignore */ }
    });
  }

  // ── Public API ────────────────────────────────────────────────────────
  // Expose setOpen so external code (e.g. WS dispatcher) can open/close the
  // aside panel programmatically without duplicating localStorage logic here.
  // open() is a no-op when the panel is already open — safe to call unconditionally.
  const publicApi = () => ({
    open:  () => { if (!isOpen()) setOpen(true); },
    close: () => setOpen(false),
    fullscreen: (on) => setFullscreen(on !== false),
    requestWidth: requestWidth,
  });

  if (window.Clacky) Clacky.Aside = publicApi();

  function init() {
    // Re-assign in case Clacky was not yet defined when the IIFE ran.
    if (window.Clacky) Clacky.Aside = publicApi();
    const collapse = $("btn-aside-collapse");
    const opener   = $("btn-aside-open");
    const overlay  = $("workspace-overlay");
    const fsBtn    = $("btn-aside-fullscreen");
    if (collapse) collapse.addEventListener("click", () => setOpen(false));
    if (opener)   opener.addEventListener("click", () => setOpen(true));
    if (overlay)  overlay.addEventListener("click", () => setOpen(false));
    if (fsBtn)    fsBtn.addEventListener("click", () => setFullscreen(!isFullscreen()));
    document.addEventListener("keydown", (e) => {
      if (e.key !== "Escape" || !isFullscreen()) return;
      // Let overlay panels (settings / skills) consume Esc first.
      const blocked = ["settings-panel", "skills-panel"].some((id) => {
        const el = document.getElementById(id);
        return el && el.style.display && el.style.display !== "none";
      });
      if (!blocked) setFullscreen(false);
    });
    initResize();
    applyOpenState();
    applyFullscreenState();

    // A width set while the window was wide survives into the narrow layout,
    // where the aside is a fixed drawer — clamp it back on resize so it cannot
    // sit off-screen. (Persisted widths are already filtered on load.)
    let clampScheduled = false;
    window.addEventListener("resize", () => {
      if (clampScheduled) return;
      clampScheduled = true;
      requestAnimationFrame(() => { clampScheduled = false; clampWidth(); });
    });

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
