// notify.js — Task-complete sound + desktop notification module
//
// Plays a short sound and (when permitted) shows a browser Notification when
// an agent task finishes, driven by the global `task_finished` event the
// server broadcasts (broadcast_all) the moment a task completes. We listen to
// this dedicated signal — rather than `complete` (only delivered to subscribers
// of that session) — so a background session finishing still reaches every
// browser. Whether a task *finished* is decided on the backend; this module
// only decides whether the user is looking.
//
// Alerts only fire when the user is NOT actively looking at the finished
// session. "Not looking" means ANY of:
//   1. The finished session is not the currently open one
//      (sid !== Sessions.activeId)
//   2. The browser window has lost focus      (!document.hasFocus())
//   3. The tab is hidden / minimised / behind another tab (document.hidden)
//
// If the user is focused on the very session that just finished, we stay
// silent — they can already see the result.
//
// The feature is gated behind a header toggle (🔔/🔕) next to the theme
// switcher. Default OFF; the choice is persisted to localStorage. Enabling
// the toggle also requests browser Notification permission (must happen in
// the click gesture) so desktop toasts work when the tab is in the background.
//
// No history replay: a chime/toast is a live cue, never re-fired on page
// refresh. The audio file is served as a static asset (/assets/notify.mp3).
//
// Depends on: Sessions (sessions.js) for activeId/find, Router (app.js) for
//             focus-on-click navigation, I18n (i18n.js) for tooltip text.
//             All are optional — guarded with typeof checks.
// ─────────────────────────────────────────────────────────────────────────
const Notify = (() => {
  // Historical key name kept for existing installs; value now means
  // "task alerts" (sound + desktop when permitted), not sound-only.
  const STORAGE_KEY = "clacky-notify-sound";
  const AUDIO_SRC   = "/assets/notify.mp3";

  let _audio = null;

  // ── State ────────────────────────────────────────────────────────────
  // Default OFF: only enabled when localStorage explicitly says "on".
  function enabled() {
    return localStorage.getItem(STORAGE_KEY) === "on";
  }

  function setEnabled(on) {
    localStorage.setItem(STORAGE_KEY, on ? "on" : "off");
    _updateToggleIcon();
  }

  async function toggle() {
    const next = !enabled();
    if (next) {
      // Prime audio inside the click gesture first, then request permission.
      // Awaiting permission before priming can drop the user-gesture token.
      _prime();
      const perm = await _ensurePermission();
      setEnabled(true);
      if (perm === "denied" && typeof Modal !== "undefined" && Modal.toast) {
        Modal.toast(
          (typeof I18n !== "undefined" && I18n.t("notify.toast.denied")) ||
            "Sound alerts enabled. Desktop notifications are blocked in browser settings.",
          "warning"
        );
      } else if (perm === "unsupported" && typeof Modal !== "undefined" && Modal.toast) {
        Modal.toast(
          (typeof I18n !== "undefined" && I18n.t("notify.toast.noDesktop")) ||
            "Sound alerts enabled. This browser has no desktop notifications.",
          "info"
        );
      }
    } else {
      setEnabled(false);
    }
  }

  // ── Browser Notification permission ──────────────────────────────────
  function _notificationsSupported() {
    return typeof window !== "undefined" && "Notification" in window;
  }

  function permission() {
    if (!_notificationsSupported()) return "unsupported";
    return Notification.permission; // "granted" | "denied" | "default"
  }

  async function _ensurePermission() {
    if (!_notificationsSupported()) return "unsupported";
    if (Notification.permission === "granted") return "granted";
    if (Notification.permission === "denied") return "denied";
    try {
      const result = await Notification.requestPermission();
      return result;
    } catch (_e) {
      return Notification.permission;
    }
  }

  // ── Audio ────────────────────────────────────────────────────────────
  function _ensureAudio() {
    if (!_audio) {
      _audio = new Audio(AUDIO_SRC);
      _audio.preload = "auto";
    }
    return _audio;
  }

  // Play+pause+reset muted once, triggered by the toggle click (a user
  // gesture), to satisfy autoplay policies for subsequent unmuted plays.
  function _prime() {
    const a = _ensureAudio();
    const prevMuted = a.muted;
    a.muted = true;
    const p = a.play();
    if (p && typeof p.then === "function") {
      p.then(() => {
        a.pause();
        a.currentTime = 0;
        a.muted = prevMuted;
      }).catch(() => { a.muted = prevMuted; });
    } else {
      a.muted = prevMuted;
    }
  }

  function _play() {
    const a = _ensureAudio();
    try {
      a.currentTime = 0;
      const p = a.play();
      // Swallow autoplay-policy rejections silently — better to miss a
      // chime than to throw an unhandled promise rejection.
      if (p && typeof p.catch === "function") p.catch(() => {});
    } catch (_e) { /* ignore */ }
  }

  // ── Desktop notification ─────────────────────────────────────────────
  function _notifyDesktop(sid) {
    if (!_notificationsSupported()) return;
    if (Notification.permission !== "granted") return;

    // Keep body generic on purpose — session names can be sensitive on shared
    // screens. Click focuses the window and navigates to the session.
    const title = typeof I18n !== "undefined"
      ? I18n.t("notify.desktop.title")
      : "Task complete";
    const body = typeof I18n !== "undefined"
      ? I18n.t("notify.desktop.body")
      : "A background task finished. Click to open it.";

    let n;
    try {
      n = new Notification(title, {
        body,
        tag: sid ? `clacky-task-${sid}` : "clacky-task",
        renotify: true,
        silent: true, // sound is handled by our own chime
      });
    } catch (_e) {
      return;
    }

    n.onclick = () => {
      try { window.focus(); } catch (_e) { /* ignore */ }
      if (sid && typeof Router !== "undefined" && typeof Router.navigate === "function") {
        Router.navigate("session", { id: sid });
      }
      try { n.close(); } catch (_e) { /* ignore */ }
    };

    // Auto-dismiss so toasts don't pile up forever.
    setTimeout(() => {
      try { n.close(); } catch (_e) { /* ignore */ }
    }, 8000);
  }

  // ── Trigger decision ───────────────────────────────────────────────────
  // Returns true when the user is NOT actively viewing the given session.
  function _userIsAway(sid) {
    // 1. Finished session is not the one currently open.
    const activeId = (typeof Sessions !== "undefined") ? Sessions.activeId : null;
    if (sid && sid !== activeId) return true;
    // 2. Browser window is not focused (e.g. another app / window on top).
    if (typeof document.hasFocus === "function" && !document.hasFocus()) return true;
    // 3. Tab is hidden (switched to another tab, or window minimised).
    if (document.hidden) return true;
    return false;
  }

  // Called from ws-dispatcher on the `task_finished` event — a transient global
  // signal the server broadcasts to every client the moment an agent task
  // completes. We only decide whether the user is looking at that session;
  // the "did a task just finish" judgement lives on the backend.
  function onTaskFinished(sid) {
    if (!enabled()) return;
    if (!_userIsAway(sid)) return;
    _play();
    _notifyDesktop(sid);
  }

  // ── Toggle button UI ───────────────────────────────────────────────────
  function _tooltipKey(on) {
    if (!on) return "notify.tooltip.off";
    const perm = permission();
    if (perm === "denied") return "notify.tooltip.onDenied";
    if (perm === "unsupported") return "notify.tooltip.onNoDesktop";
    if (perm === "default") return "notify.tooltip.onPending";
    return "notify.tooltip.on";
  }

  function _updateToggleIcon() {
    const btn = document.getElementById("notify-toggle-header");
    if (!btn) return;
    const on = enabled();
    // Bell when ON, bell-off (muted) when OFF.
    btn.innerHTML = on
      ? `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon-sm">
          <path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/>
          <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>
        </svg>`
      : `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon-sm">
          <path d="M8.7 3A6 6 0 0 1 18 8c0 1.5.2 2.8.5 3.9"/>
          <path d="M17 17H3s3-2 3-9a4.67 4.67 0 0 1 .3-1.7"/>
          <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>
          <line x1="2" y1="2" x2="22" y2="22"/>
        </svg>`;
    btn.classList.toggle("notify-on", on);
    if (typeof I18n !== "undefined") {
      const tip = I18n.t(_tooltipKey(on));
      btn.title = tip;
      btn.setAttribute("aria-label", tip);
      btn.setAttribute("data-i18n-title", _tooltipKey(on));
    }
  }

  // ── Init ─────────────────────────────────────────────────────────────
  function init() {
    _updateToggleIcon();
    const btn = document.getElementById("notify-toggle-header");
    if (btn) {
      btn.addEventListener("click", () => {
        // Fire-and-forget; permission prompt is awaited inside toggle.
        toggle().then(() => _updateToggleIcon()).catch(() => _updateToggleIcon());
      });
    }
    // Permission may change outside the page (browser settings); refresh tip.
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) _updateToggleIcon();
    });
    if (typeof I18n !== "undefined") {
      document.addEventListener("langchange", () => _updateToggleIcon());
    }
  }

  return {
    init,
    toggle,
    enabled,
    setEnabled,
    permission,
    onTaskFinished,
  };
})();

Clacky.Notify = Notify;

// Initialize on load (button binding + initial icon state).
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => Notify.init());
} else {
  Notify.init();
}
