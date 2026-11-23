// ── Session aside shell — resize / collapse / opener ─────────────────────
//
// Host-owned controls for the right column (#session-aside). The tab bar and
// bodies inside are rendered by Clacky.ext; this only drives the surrounding
// shell so slot re-renders never disturb width or collapse state.
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
  const SESSION_WIDTH_PREFIX = "clacky.aside.width.";  // + sessionId → px
  const OPEN_KEY  = "clacky.aside.open";               // global default — the last choice
  const SESSION_OPEN_PREFIX = "clacky.aside.open.";    // + sessionId → "1" | "0"
  const FULLSCREEN_KEY = "clacky.aside.fullscreen";
  const DEFAULT_SESSION_KEY = "__default__";
  // Open/closed and width are both remembered per session: one conversation
  // keeps a diff open and needs the room, the next keeps a file list and does
  // not. Width has no shared fallback — a conversation that was never dragged
  // starts at the CSS default, otherwise every session would look like it
  // shares whatever the previous one was left at.
  let activeSessionId = null;
  let boundSessionId = null;
  // An empty slot hides the mode without touching the stored preference: the
  // panels render a frame after init, and clearing the flag there would throw
  // away the fullscreen the user left behind before a reload.
  let fullscreenSuppressed = false;
  const MIN_W = 256;
  // Narrower than this the chat column stops being readable — composer and
  // message bubbles fold into a one-character-wide strip. Once the aside
  // crosses the line it takes the whole workspace instead.
  const CHAT_MIN_W = 300;
  const maxW = () => Math.max(MIN_W, Math.round(window.innerWidth * 0.8));
  // Matches the CSS breakpoint where the aside becomes a fixed overlay drawer.
  const isNarrow = () => window.matchMedia("(max-width: 768px)").matches;
  const widthRequests = new Map();
  let nextWidthRequestId = 1;
  let widthBeforeRequests = null;
  let appliedRequestWidth = null;
  let manuallyResizedWhileRequested = false;
  let fullscreenChatSnapshot = null;

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

  function writeAsideWidth(px) {
    const aside = $("session-aside");
    if (aside) aside.style.setProperty("--session-aside-width", px + "px");
  }

  function setWidth(px) {
    writeAsideWidth(px);
    syncChatCollapse();
  }

  // The aside takes the whole workspace as soon as it would leave the chat
  // column below CHAT_MIN_W. That is the fullscreen state, not a second one, so
  // the button, Esc and the divider share a single exit. Widths are written
  // directly — setWidth() calls back in here and would recurse.
  function syncChatCollapse() {
    const panel = $("chat-panel");
    if (!panel || isNarrow() || !isOpen() || slotEmpty() || isFullscreen()) return;
    const panelWidth = panel.getBoundingClientRect().width;
    if (panelWidth <= CHAT_MIN_W) return;
    if (panelWidth - currentWidth() >= CHAT_MIN_W) return;
    const legal = panelWidth - CHAT_MIN_W;
    if (legal >= MIN_W) writeAsideWidth(legal);
    setFullscreen(true);
  }

  // Fullscreen paints over the pixel width, so the split has to be pulled back
  // inside the floor on exit — otherwise syncChatCollapse would re-enter it.
  // The pulled-back width is the one the user now sees, so it is persisted: a
  // reload has to land on the same split instead of the pre-fullscreen width
  // that no longer fits. One pixel of slack keeps sub-pixel rounding on reload
  // from counting as an overflow.
  function clampSplitWidth() {
    const panel = $("chat-panel");
    if (!panel || isNarrow()) return;
    const legal = panel.getBoundingClientRect().width - CHAT_MIN_W - 1;
    if (legal < MIN_W || currentWidth() <= legal) return;
    writeAsideWidth(legal);
    persistWidth(legal);
  }

  // Reconcile temporary requests centrally so nested panels can close in any
  // order. For example, closing a Files preview while an 860px Git diff is
  // still open must not make the later Git release restore a stale 700px width.
  function reconcileRequestedWidths() {
    if (!$('session-aside')) return;
    const width = currentWidth();

    if (widthRequests.size === 0) {
      if (!manuallyResizedWhileRequested && widthBeforeRequests !== null &&
          appliedRequestWidth !== null && Math.round(width) === appliedRequestWidth) {
        setWidth(widthBeforeRequests);
      }
      widthBeforeRequests = null;
      appliedRequestWidth = null;
      manuallyResizedWhileRequested = false;
      return;
    }

    if (widthBeforeRequests === null) widthBeforeRequests = width;
    if (manuallyResizedWhileRequested) return;
    const requested = Math.min(maxW(), Math.max(...widthRequests.values()));
    const desired = Math.max(widthBeforeRequests, requested);
    if (Math.round(width) !== Math.round(desired)) setWidth(desired);
    appliedRequestWidth = Math.round(desired);
  }

  // Panels that need horizontal room (diff, file preview) ask for a wider
  // aside. Narrow layouts deliberately ignore temporary requests because the
  // aside is a fixed mobile drawer there. Persistent requests remain available
  // for legacy panels that intentionally update the user's preferred width.
  function requestWidth(px, opts) {
    const aside = $("session-aside");
    if (!aside || isNarrow()) return null;
    const requested = Number(px);
    if (!Number.isFinite(requested) || requested <= 0) return null;
    const target = Math.min(maxW(), Math.max(MIN_W, requested));
    if (opts && opts.persist) {
      const preferred = Math.max(currentWidth(), target);
      setWidth(preferred);
      persistWidth(preferred);
      if (widthRequests.size > 0) widthBeforeRequests = preferred;
      return null;
    }

    const id = nextWidthRequestId++;
    widthRequests.set(id, target);
    reconcileRequestedWidths();
    let released = false;
    return () => {
      if (released) return;
      released = true;
      widthRequests.delete(id);
      reconcileRequestedWidths();
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

  function sessionKey() {
    return activeSessionId == null || activeSessionId === "" ? DEFAULT_SESSION_KEY : String(activeSessionId);
  }

  function readWidth() {
    try {
      const own = parseFloat(localStorage.getItem(SESSION_WIDTH_PREFIX + sessionKey()));
      if (isFinite(own) && own >= MIN_W) return own;
    } catch (_e) { /* private mode — fall back to the CSS default */ }
    return null;
  }

  function persistWidth(px) {
    try { localStorage.setItem(SESSION_WIDTH_PREFIX + sessionKey(), String(px)); } catch (_e) { /* ignore */ }
  }

  function readSessionOpen() {
    try {
      const raw = localStorage.getItem(SESSION_OPEN_PREFIX + sessionKey());
      if (raw === "1") return true;
      if (raw === "0") return false;
    } catch (_e) { /* private mode — treat as no record */ }
    return null;
  }

  function writeSessionOpen(open) {
    try { localStorage.setItem(SESSION_OPEN_PREFIX + sessionKey(), open ? "1" : "0"); } catch (_e) { /* ignore */ }
  }

  function applyOpenState() {
    const aside   = $("session-aside");
    const opener  = $("btn-aside-open");
    const overlay = $("workspace-overlay");
    if (!aside) return;
    const open = isOpen();
    const empty = slotEmpty();
    aside.classList.toggle("collapsed", !open);
    if (opener)  opener.style.display = (!open && !empty) ? "" : "none";
    if (overlay) overlay.classList.toggle("active", open && !empty);
    // A fullscreen class with an empty slot would show an empty column over
    // the whole workspace (the fullscreen rule outranks the empty-slot one).
    fullscreenSuppressed = empty;
    applyFullscreenState();
    syncChatCollapse();
  }

  // initResize only runs once per page load, so a switch has to swap the
  // visible number itself. A session with no record drops the inline override
  // rather than keeping the previous session's width — otherwise a conversation
  // that was never dragged looks like it shares the one it came from.
  function applyStoredWidth() {
    const saved = readWidth();
    const aside = $("session-aside");
    if (aside) {
      if (saved === null || saved > maxW()) aside.style.removeProperty("--session-aside-width");
      else aside.style.setProperty("--session-aside-width", saved + "px");
    }
    syncChatCollapse();
  }

  function isOpen() {
    const own = readSessionOpen();
    if (own !== null) return own;
    try {
      const stored = localStorage.getItem(OPEN_KEY);
      return stored !== null && stored !== "0";
    } catch (_e) { return false; }
  }

  function setOpen(open) {
    writeSessionOpen(!!open);
    // Mirrors the last choice globally, so a session with no record yet opens
    // the way the user last left the column.
    try { localStorage.setItem(OPEN_KEY, open ? "1" : "0"); } catch (_e) { /* ignore */ }
    if (!open) setFullscreen(false);
    applyOpenState();
  }

  // Host calls this on every session switch. Fullscreen is left behind: it is
  // about the screen you were concentrating on, not about the conversation.
  function onSession(sessionId) {
    const next = sessionId == null || sessionId === "" ? null : String(sessionId);
    if (next === activeSessionId) return;
    activeSessionId = next;
    // Fullscreen is about the screen you were concentrating on, not about the
    // conversation: switching leaves it behind, but the first bind after a
    // reload must keep what the user left on screen.
    const switching = boundSessionId !== null && next !== boundSessionId;
    if (next !== null) boundSessionId = next;
    // Leaving fullscreen on a switch must not re-clamp the width it was
    // hiding: the incoming session brings its own, and clamping here would
    // overwrite a number the user never saw go wrong.
    if (switching) setFullscreen(false, { keepWidth: true });
    // Freeze the inherited default into this session's own record, so it keeps
    // its state even after another session moves the shared fallback.
    if (readSessionOpen() === null) writeSessionOpen(isOpen());
    applyStoredWidth();
    applyOpenState();
  }

  function forgetSession(sessionId) {
    if (sessionId == null || sessionId === "") return;
    try { localStorage.removeItem(SESSION_OPEN_PREFIX + String(sessionId)); } catch (_e) { /* ignore */ }
    try { localStorage.removeItem(SESSION_WIDTH_PREFIX + String(sessionId)); } catch (_e) { /* ignore */ }
  }

  function isFullscreen() {
    if (fullscreenSuppressed) return false;
    try { return localStorage.getItem(FULLSCREEN_KEY) === "1"; } catch (_e) { return false; }
  }

  // Preserve the user's reading anchor while fullscreen temporarily removes
  // the chat column from layout. A raw scrollTop is not enough: restoring the
  // column changes line wrapping, so the same pixel offset can point at a
  // different message until the final width has settled.
  function captureChatScrollPosition() {
    const messages = $("messages");
    if (!messages) return null;
    const bounds = messages.getBoundingClientRect();
    let anchor = null;
    let anchorOffset = 0;
    for (const child of messages.children) {
      const rect = child.getBoundingClientRect();
      if (rect.bottom > bounds.top && rect.top < bounds.bottom) {
        anchor = child;
        anchorOffset = rect.top - bounds.top;
        break;
      }
    }
    return {
      messages,
      marker: messages.firstElementChild,
      anchor,
      anchorOffset,
      scrollTop: messages.scrollTop,
      atBottom: messages.scrollHeight - messages.scrollTop - messages.clientHeight <= 1,
    };
  }

  function restoreChatScrollPosition(snapshot) {
    const messages = $("messages");
    if (!snapshot || snapshot.messages !== messages) return;
    // A session switch replaces the message children while fullscreen. Do not
    // apply an anchor captured from the previous conversation to the new one.
    if (snapshot.marker) {
      if (!messages.contains(snapshot.marker)) return;
    } else if (messages.firstElementChild) {
      return;
    }
    if (snapshot.atBottom) {
      messages.scrollTop = messages.scrollHeight;
      return;
    }
    if (snapshot.anchor && messages.contains(snapshot.anchor)) {
      const bounds = messages.getBoundingClientRect();
      const rect = snapshot.anchor.getBoundingClientRect();
      messages.scrollTop += rect.top - bounds.top - snapshot.anchorOffset;
    } else if (!snapshot.anchor) {
      messages.scrollTop = snapshot.scrollTop;
    }
  }

  function shortcutLabel() {
    const uaData = navigator.userAgentData && navigator.userAgentData.platform;
    const platform = (uaData || navigator.platform || "").toString();
    return /mac/i.test(platform) ? "⌘L" : "Ctrl+L";
  }

  // Both hints carry the shortcut, so they are composed here rather than
  // through data-i18n-tooltip (which would drop the suffix on a lang switch).
  function applyAsideTitles() {
    if (!window.Clacky || !Clacky.I18n) return;
    const label = (key) => Clacky.I18n.t(key) + " (" + shortcutLabel() + ")";
    const collapse = $("btn-aside-collapse");
    if (collapse) collapse.setAttribute("data-tooltip", label("aside.collapse"));
    const opener = $("btn-aside-open");
    if (opener) opener.setAttribute("data-tooltip", label("aside.expand"));
  }

  function applyFullscreenState() {
    const chatPanel = $("chat-panel");
    if (chatPanel) chatPanel.classList.toggle("aside-fullscreen", isFullscreen());
    const btn = $("btn-aside-fullscreen");
    if (btn && window.Clacky && Clacky.I18n) {
      btn.setAttribute("data-tooltip", Clacky.I18n.t(isFullscreen() ? "aside.exitFullscreen" : "aside.fullscreen"));
    }
  }

  function setFullscreen(on, opts) {
    on = !!on;
    const wasFullscreen = isFullscreen();
    if (on === wasFullscreen) {
      applyFullscreenState();
      return;
    }
    if (on) fullscreenChatSnapshot = captureChatScrollPosition();

    const aside = $("session-aside");
    const previousTransition = aside ? aside.style.transition : "";
    // On exit, skip the width animation that would repeatedly reflow the
    // restored chat column. One forced layout gives us its final geometry,
    // after which the semantic message anchor can be restored exactly.
    if (!on && aside) aside.style.transition = "none";
    try { localStorage.setItem(FULLSCREEN_KEY, on ? "1" : "0"); } catch (_e) { /* ignore */ }
    applyFullscreenState();
    if (!on) {
      if (aside) void aside.offsetWidth;
      if (!(opts && opts.keepWidth)) clampSplitWidth();
      restoreChatScrollPosition(fullscreenChatSnapshot);
      fullscreenChatSnapshot = null;
      if (aside) aside.style.transition = previousTransition;
    }
  }

  function initResize() {
    const aside  = $("session-aside");
    const handle = $("session-aside-resize");
    if (!aside || !handle) return;

    const saved = readWidth();
    if (saved !== null && saved <= maxW()) setWidth(saved);

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
      setWidth(w);
    });

    document.addEventListener("mouseup", () => {
      if (!dragging) return;
      dragging = false;
      handle.classList.remove("active");
      aside.style.transition = "";
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
      const w = currentWidth();
      persistWidth(w);
      if (widthRequests.size > 0) {
        widthBeforeRequests = w;
        appliedRequestWidth = null;
        manuallyResizedWhileRequested = true;
      }
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
    onSession: onSession,
    forgetSession: forgetSession,
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
    applyAsideTitles();
    document.addEventListener("langchange", applyAsideTitles);
    document.addEventListener("langchange", applyFullscreenState);
    document.addEventListener("keydown", (e) => {
      // ⌘L is the advertised shortcut; browsers keep it for the address bar,
      // so ⌘\ stays as a working fallback wherever the keystroke is swallowed.
      const isBackslash = e.key === "\\" || e.code === "Backslash";
      const isL = e.key === "l" || e.key === "L" || e.code === "KeyL";
      if (!isL && !isBackslash) return;
      if (e.altKey || e.shiftKey) return;
      if (!(e.metaKey || e.ctrlKey)) return;
      if (slotEmpty()) return;
      e.preventDefault();
      setOpen(!isOpen());
    });
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

    // Sidebar collapse, session switches and window resizes all change how
    // much room the chat panel has without going through setWidth.
    const chatPanel = $("chat-panel");
    if (chatPanel && window.ResizeObserver) {
      new ResizeObserver(() => syncChatCollapse()).observe(chatPanel);
    }

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
