// ── app.js — Main entry point ──────────────────────────────────────────────
//
// Coordinates WS, Sessions, Tasks, Skills and Settings modules.
// Handles WS event dispatch and wires up all DOM event listeners.
//
// Load order (in index.html):
//   ws.js → sessions.js → tasks.js → skills.js → app.js
// ─────────────────────────────────────────────────────────────────────────

// ── DOM helper (shared by all modules loaded after this) ──────────────────
const $ = id => document.getElementById(id);

// ── Inject X-Lang header into every fetch request ─────────────────────────
const _nativeFetch = window.fetch;
window.fetch = function(input, init = {}) {
  const headers = new Headers(init.headers || {});
  if (!headers.has("X-Lang")) headers.set("X-Lang", I18n.lang());
  return _nativeFetch.call(this, input, { ...init, headers });
};

// ── Utilities (shared) ────────────────────────────────────────────────────
function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// ── Router ────────────────────────────────────────────────────────────────
//
// Single source of truth for panel visibility and URL hash.
//
// Views:
//   welcome            → /#new     (new-session landing page)
//   session/{id}       → /#session/{id}
//   tasks              → /#tasks
//   skills             → /#skills
//   settings           → /#settings
//
// Usage:
//   Router.navigate("session", { id: "abc123" })
//   Router.navigate("tasks")
//   Router.navigate("welcome")
//
// All panels must be listed in PANELS so they are hidden before the active
// one is shown. Modules must NOT touch panel display styles directly.
// ─────────────────────────────────────────────────────────────────────────
const PANELS = [
  "setup-panel",
  "onboard-panel",
  "welcome",
  "chat-panel",
  "task-detail-panel",
  "skills-panel",
  "channels-panel",
  "mcp-panel",
  "extensions-panel",
  "trash-panel",
  "profile-panel",
  "billing-panel",
  "settings-panel",
  "ext-slot-main-workspace",
];

const Router = (() => {
  let _current     = null;  // current view name
  let _params      = {};    // current params (e.g. { id: "abc" } for session view)
  let _skipNextHashChange = false;  // prevent echo loop when we set hash ourselves

  // Hide all panels.
  function _hideAll() {
    PANELS.forEach(p => {
      const el = $(p);
      if (el) el.style.display = "none";
    });
  }

  // Update the URL hash without triggering a hashchange handler loop.
  // Only arm the skip-flag if the hash is actually going to change — otherwise
  // the browser fires no hashchange event and the flag would linger and
  // silently swallow the next real hashchange.
  function _setHash(hash) {
    const target = hash ? "#" + hash : "";
    if (location.hash === target || (target === "" && location.hash === "")) return;
    _skipNextHashChange = true;
    location.hash = hash;
  }

  // Resolve a hash string into { view, params }.
  function _parseHash(hash) {
    const h = (hash || "").replace(/^#\/?/, "");
    if (!h)                           return { view: "welcome",  params: {} };
    if (h === "new")                  return { view: "welcome",  params: {} };
    if (h === "tasks")                return { view: "tasks",    params: {} };
    if (h === "skills")               return { view: "skills",   params: {} };
    if (h === "channels")             return { view: "channels", params: {} };
    if (h === "mcp")                  return { view: "mcp",      params: {} };
    if (h === "extensions")           return { view: "extensions", params: {} };
    const mExtDetail = h.match(/^extensions\/(.+)$/);
    if (mExtDetail)                   return { view: "extensions", params: { detailId: mExtDetail[1] } };
    if (h === "trash")                return { view: "trash",    params: {} };
    if (h === "profile")              return { view: "profile",  params: {} };
    // Legacy: #memories redirects to #profile (memories are now merged into
    // the profile panel). Kept so bookmarks / external links don't 404.
    if (h === "memories")             return { view: "profile",  params: {} };
    if (h === "billing")              return { view: "billing",  params: {} };
    if (h === "settings")             return { view: "settings", params: {} };
    const mExt = h.match(/^ext\/(.+)$/);
    if (mExt)                         return { view: "ext-workspace", params: { id: mExt[1] } };
    const m = h.match(/^session\/(.+)$/);
    if (m)                            return { view: "session",  params: { id: m[1] } };
    return { view: "welcome", params: {} };
  }

  // Sidebar items managed by Router (keyed by view name → element id).
  // Router is the single authority for active highlight — modules must NOT
  // add/remove the "active" class on these elements themselves.
  const SIDEBAR_ITEMS = {
    tasks:    "tasks-sidebar-item",
    skills:   "skills-sidebar-item",
    channels: "channels-sidebar-item",
    mcp:      "mcp-sidebar-item",
    extensions: "extensions-sidebar-item",
    trash:    "trash-sidebar-item",
    profile:  "profile-sidebar-item",
    billing:  "billing-sidebar-item",
  };

  // Remove active highlight from all Router-managed sidebar items.
  function _clearSidebarActive() {
    Object.values(SIDEBAR_ITEMS).forEach(id => {
      const el = $(id);
      if (el) el.classList.remove("active");
    });
    // Extension workspace nav items tag themselves with data-ext-workspace;
    // the Router owns their active highlight the same way as built-in items.
    document.querySelectorAll("[data-ext-workspace].active")
      .forEach(el => el.classList.remove("active"));
  }

  // Core: apply a view change. Called both from navigate() and hashchange.
  // Async because the "session" case may need to fetch /api/sessions/:id when
  // the target session isn't in the paged sidebar list (search clicks, URL
  // deep links, share links, browser back/forward, notification jumps).
  async function _apply(view, params = {}) {
    _current = view;
    _params  = params;

    // Close sidebar on mobile when navigating to any view
    _mobileCloseSidebar();

    // ── Clean up previous state ──────────────────────────────────────────
    if (Sessions.activeId) {
      Sessions._cacheActiveAndDeselect();
    }
    Sessions.updateInfoBar(null);  // hide info bar when leaving any session
    // Clear all sidebar highlights and settings button active state
    _clearSidebarActive();
    const btnSettings = $("btn-settings");
    if (btnSettings) btnSettings.classList.remove("active");

    _hideAll();

    // Leaving a session view → clear agent scope so agent panels don't linger
    // over non-session views. The session case re-sets it below.
    if (view !== "session" && window.Clacky && Clacky.ext && Clacky.ext.context.agentProfile) {
      Clacky.ext.setContext({ agentProfile: null, sessionId: null });
    }

    // Reveal #app on first navigation — ensures the correct view (and language)
    // is already in place before the user sees anything.
    // #app covers sidebar + main, so data-i18n elements in the sidebar are also
    // hidden until applyAll() has run (prevents flash of English sidebar labels).
    const appEl = document.getElementById("app");
    if (appEl && appEl.style.visibility === "hidden") {
      I18n.applyAll();  // Translate all data-i18n elements before revealing
      appEl.style.visibility = "";
    }

    // ── Activate target panel + sidebar highlight ────────────────────────
    switch (view) {

      case "session": {
        const id = params.id;
        // findOrFetch falls back to the backend when the session isn't in the
        // sidebar's paged `_sessions` (search results, URL deep links, share
        // links, browser back/forward). On success it caches the row in the
        // local `_extraSessions` pool so subsequent sync `find` calls hit too.
        const s  = await Sessions.findOrFetch(id);
        if (!s) {
          // Truly not found (deleted, or never existed) — fall back to welcome.
          await _apply("welcome");
          return;
        }
        _setHash(`session/${id}`);
        $("chat-panel").style.display       = "flex";
        Sessions.updateChatHeader(s);
        Sessions.updateStatusBar(s.status);
        Sessions.updateInfoBar(s);
        Sessions._restoreMessagesPublic(id);
        Sessions._setActiveId(id);
        // Scope agent UI / official panels to this session's agent profile, then
        // re-render every slot so the right panels appear (and a previous
        // agent's panels are cleared).
        if (window.Clacky && Clacky.ext) {
          Clacky.ext.setContext({ agentProfile: s.agent_profile || "general", sessionId: id });
          Clacky.ext.emit("session:agent-changed", { sessionId: id, agentProfile: s.agent_profile || "general" });
        }
        // Immediately re-attach saved progress UI (timer + spinner) so it appears
        // instantly without waiting for the async history fetch or WS replay.
        Sessions._attachProgressUI(id);
        WS.setSubscribedSession(id);
        // Only disable send button until server confirms subscription
        // Input field remains usable so user can type while waiting
        $("btn-send").disabled = true;
        WS.send({ type: "subscribe", session_id: id });
        Sessions.renderList({ scrollToActive: true });
        $("user-input").focus();

        // Load session-scoped skill list (filtered by agent profile) for slash autocomplete
        SkillAC.loadForSession(id);

        // Always reload history on every switch (cache is not used)
        Sessions.loadHistory(id);
        break;
      }

      case "tasks":
        _setHash("tasks");
        $("task-detail-panel").style.display = "flex";
        Tasks.onPanelShow();
        Sessions.renderList();
        break;

      case "skills":
        _setHash("skills");
        $("skills-panel").style.display = "flex";
        Skills.onPanelShow();
        Sessions.renderList();
        break;

      case "channels":
        _setHash("channels");
        $("channels-panel").style.display = "flex";
        Channels.onPanelShow();
        Sessions.renderList();
        break;

      case "mcp":
        _setHash("mcp");
        $("mcp-panel").style.display = "flex";
        Mcp.onPanelShow();
        Sessions.renderList();
        break;

      case "extensions":
        $("extensions-panel").style.display = "flex";
        if (params.detailId) {
          _setHash(`extensions/${params.detailId}`);
          Extensions.onPanelShow({ detailId: params.detailId });
        } else {
          _setHash("extensions");
          Extensions.onPanelShow();
        }
        Sessions.renderList();
        break;

      case "trash":
        _setHash("trash");
        $("trash-panel").style.display = "flex";
        Trash.onPanelShow();
        Sessions.renderList();
        break;

      case "profile":
        _setHash("profile");
        $("profile-panel").style.display = "flex";
        Profile.onPanelShow();
        Sessions.renderList();
        break;

      case "billing":
        _setHash("billing");
        $("billing-panel").style.display = "flex";
        Billing.open();
        Sessions.renderList();
        break;

      case "settings":
        _setHash("settings");
        $("settings-panel").style.display = "";
        if (btnSettings) btnSettings.classList.add("active");
        Settings.open();
        Sessions.renderList();
        break;

      case "setup":
        // Full-screen mandatory setup (language + API key). No hash — keep URL clean.
        $("setup-panel").style.display = "flex";
        break;

      case "onboard":
        // Kept for compatibility; setup-panel is now used for first-run setup.
        $("onboard-panel").style.display = "flex";
        break;

      case "ext-workspace": {
        const ws = window.Clacky && Clacky.ext && Clacky.ext._getWorkspace(params.id);
        if (!ws) { await _apply("welcome"); return; }
        _setHash(`ext/${params.id}`);
        const container = $("ext-slot-main-workspace");
        container.replaceChildren();
        container.style.display = "block";
        try { ws.render(container, {}); }
        catch (err) { console.error("ext workspace render failed:", err); }
        Sessions.renderList();
        break;
      }

      default:  // "welcome"
        _setHash("new");
        $("welcome").style.display = "";
        Sessions.renderList();
        if (window.NewSessionView && NewSessionView.onPanelShow) {
          NewSessionView.onPanelShow();
        }
        break;
    }

    // Re-apply sidebar active highlight after all rendering is done.
    // renderSection() rebuilds the DOM element, so we stamp active *after*.
    _clearSidebarActive();
    const activeItem = SIDEBAR_ITEMS[view];
    if (activeItem) $(activeItem)?.classList.add("active");
    if (view === "ext-workspace" && params.id) {
      document.querySelector(`[data-ext-workspace="${params.id}"]`)?.classList.add("active");
    }
  }

  // Listen for browser back/forward (or manual hash edits).
  window.addEventListener("hashchange", () => {
    if (_skipNextHashChange) {
      _skipNextHashChange = false;
      return;
    }
    const { view, params } = _parseHash(location.hash);
    _apply(view, params).catch(err => console.error("Router._apply failed:", err));
  });

  // Extensions request navigation via a CustomEvent so ext.js has no direct
  // dependency on Router. Detail is { view, params } — same shape as navigate().
  document.addEventListener("clacky:ext:navigate", (e) => {
    const { view, params } = e.detail || {};
    if (!view) return;
    _apply(view, params || {}).catch(err => console.error("Router._apply failed:", err));
  });

  return {
    get current() { return _current; },
    get params()  { return _params; },

    /** Navigate to a view. This is the only way panels should change. */
    navigate(view, params = {}) {
      // Fire-and-forget: _apply is async (may fetch /api/sessions/:id), but
      // navigate() keeps a sync signature so all existing call sites are
      // unaffected. Errors are logged; UI falls back to welcome on missing id.
      _apply(view, params).catch(err => console.error("Router._apply failed:", err));
    },

    /** Restore state from current URL hash (called once on boot after data loads). */
    restoreFromHash() {
      const { view, params } = _parseHash(location.hash);
      _apply(view, params).catch(err => console.error("Router._apply failed:", err));
    },
  };
})();

Clacky.Router = Router;

// ── Modal utility ─────────────────────────────────────────────────────────
const Modal = (() => {
  /** Show a yes/no confirmation dialog. Returns a Promise<boolean>. */
  function confirm(message) {
    return new Promise(resolve => {
      const overlay = $("modal-overlay");
      $("modal-message").textContent = message;
      $("modal-skip-label").style.display = "none";
      $("modal-skip-cb").checked = false;
      if (overlay.parentNode !== document.body || overlay.nextSibling) {
        document.body.appendChild(overlay);
      }
      overlay.style.display = "flex";

      const cleanup = (result) => {
        overlay.style.display = "none";
        $("modal-yes").onclick = null;
        $("modal-no").onclick  = null;
        resolve(result);
      };
      $("modal-yes").onclick = () => cleanup(true);
      $("modal-no").onclick  = () => cleanup(false);
    });
  }

  /**
   * Like confirm(), but shows a "don't show again" checkbox.
   * If localStorage[storageKey] === "1", resolves true immediately.
   * Returns Promise<boolean>.
   */
  function confirmOnce(storageKey, message, skipLabel) {
    if (localStorage.getItem(storageKey) === "1") return Promise.resolve(true);

    return new Promise(resolve => {
      const overlay = $("modal-overlay");
      $("modal-message").textContent   = message;
      $("modal-skip-text").textContent = skipLabel;
      $("modal-skip-cb").checked       = false;
      $("modal-skip-label").style.display = "flex";
      if (overlay.parentNode !== document.body || overlay.nextSibling) {
        document.body.appendChild(overlay);
      }
      overlay.style.display = "flex";

      const cleanup = (result) => {
        overlay.style.display = "none";
        $("modal-skip-label").style.display = "none";
        $("modal-yes").onclick = null;
        $("modal-no").onclick  = null;
        if (result && $("modal-skip-cb").checked) {
          localStorage.setItem(storageKey, "1");
        }
        resolve(result);
      };
      $("modal-yes").onclick = () => cleanup(true);
      $("modal-no").onclick  = () => cleanup(false);
    });
  }

  /**
   * Like confirm(), but shows an extra opt-in checkbox (unchecked by default).
   * Resolves { ok, checked } so the caller can act on both the decision and
   * the checkbox state.
   */
  function confirmWithCheckbox(message, checkboxLabel) {
    return new Promise(resolve => {
      const overlay = $("modal-overlay");
      $("modal-message").textContent   = message;
      $("modal-skip-text").textContent = checkboxLabel;
      $("modal-skip-cb").checked       = false;
      $("modal-skip-label").style.display = "flex";
      if (overlay.parentNode !== document.body || overlay.nextSibling) {
        document.body.appendChild(overlay);
      }
      overlay.style.display = "flex";

      const cleanup = (ok) => {
        overlay.style.display = "none";
        $("modal-skip-label").style.display = "none";
        $("modal-yes").onclick = null;
        $("modal-no").onclick  = null;
        resolve({ ok, checked: ok && $("modal-skip-cb").checked });
      };
      $("modal-yes").onclick = () => cleanup(true);
      $("modal-no").onclick  = () => cleanup(false);
    });
  }
  function prompt(message, defaultValue = "") {
    return new Promise(resolve => {
      const overlay = $("prompt-modal-overlay");
      $("prompt-modal-message").textContent = message;
      const input = $("prompt-modal-input");
      input.value = defaultValue;
      // Re-attach to <body> end so it stacks above dynamically-appended overlays.
      if (overlay.parentNode !== document.body || overlay.nextSibling) {
        document.body.appendChild(overlay);
      }
      overlay.style.display = "flex";
      
      // Auto-focus and select all text
      setTimeout(() => {
        input.focus();
        input.select();
      }, 50);

      const cleanup = (result) => {
        $("prompt-modal-overlay").style.display = "none";
        $("prompt-modal-ok").onclick = null;
        $("prompt-modal-cancel").onclick = null;
        input.onkeydown = null;
        unbindEnter();
        resolve(result);
      };

      $("prompt-modal-ok").onclick = () => cleanup(input.value.trim() || null);
      $("prompt-modal-cancel").onclick = () => cleanup(null);

      const unbindEnter = IME.bindEnter(input, () => cleanup(input.value.trim() || null));
      input.onkeydown = (e) => {
        if (e.key === "Escape") cleanup(null);
      };
    });
  }

  /** Show a rename dialog. Returns a Promise<string|null>. */
  function rename(currentName = "") {
    return new Promise(resolve => {
      const overlay = $("rename-modal-overlay");
      const input = $("rename-modal-input");
      input.value = currentName;
      input.classList.remove("input-error");
      // Re-attach to <body> end so it stacks above dynamically-appended overlays.
      if (overlay.parentNode !== document.body || overlay.nextSibling) {
        document.body.appendChild(overlay);
      }
      overlay.style.display = "flex";
      
      setTimeout(() => {
        input.focus();
        input.select();
      }, 50);

      const cleanup = (result) => {
        $("rename-modal-overlay").style.display = "none";
        $("rename-modal-save").onclick = null;
        $("rename-modal-cancel").onclick = null;
        $("rename-modal-overlay").onclick = null;
        input.onkeydown = null;
        input.oninput = null;
        unbindEnter();
        resolve(result);
      };

      const saveHandler = () => {
        const newName = input.value.trim();
        if (!newName) {
          input.classList.add("input-error");
          input.focus();
          return;
        }
        cleanup(newName === currentName ? null : newName);
      };

      input.oninput = () => input.classList.remove("input-error");

      $("rename-modal-save").onclick = saveHandler;
      $("rename-modal-cancel").onclick = () => cleanup(null);

      const unbindEnter = IME.bindEnter(input, saveHandler);
      input.onkeydown = (e) => {
        if (e.key === "Escape") cleanup(null);
      };

      // Close on overlay click
      $("rename-modal-overlay").onclick = (e) => {
        if (e.target.id === "rename-modal-overlay") cleanup(null);
      };
    });
  }

  return { confirm, confirmOnce, confirmWithCheckbox, prompt, rename };
})();

Clacky.Modal = Modal;

// ── Toast helper ──────────────────────────────────────────────────────────
// Non-blocking notification stack. Replaces alert() for success/error/info
// feedback. Supports an optional action button (e.g. "Go check").
//
//   Modal.toast("Saved")
//   Modal.toast("Failed: …", "error")
//   Modal.toast("Restored", "success", { action: { label: "Go", onClick } })
Modal.toast = function (message, typeOrOptions = "info", maybeOptions = {}) {
  const opts = typeof typeOrOptions === "object"
    ? typeOrOptions
    : { type: typeOrOptions, ...maybeOptions };
  const type     = opts.type     || "info";
  const duration = opts.duration ?? (type === "error" ? 6000 : 3500);
  const action   = opts.action;

  const stack = document.getElementById("toast-stack");
  if (!stack) { console.warn("[toast] #toast-stack missing"); return; }

  const icons = {
    success: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><polyline points="20 6 9 17 4 12"/></svg>',
    error:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>',
    warning: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>',
    info:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>'
  };

  const escape = s => String(s ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  const el = document.createElement("div");
  el.className = "toast toast-" + type;
  el.setAttribute("role", type === "error" ? "alert" : "status");
  el.innerHTML =
    '<span class="toast-icon">' + (icons[type] || icons.info) + '</span>' +
    '<div class="toast-body">' +
      '<div class="toast-message">' + escape(message) + '</div>' +
      (action ? '<button type="button" class="toast-action">' + escape(action.label) + '</button>' : '') +
    '</div>' +
    '<button type="button" class="toast-close" aria-label="Close">' +
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="14" height="14"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>' +
    '</button>';

  let timer = null;
  const dismiss = () => {
    if (timer) { clearTimeout(timer); timer = null; }
    el.classList.add("toast-leave");
    el.addEventListener("animationend", () => el.remove(), { once: true });
  };

  el.querySelector(".toast-close").onclick = dismiss;
  if (action) {
    el.querySelector(".toast-action").onclick = () => {
      try { action.onClick && action.onClick(); } finally { dismiss(); }
    };
  }
  el.onmouseenter = () => { if (timer) { clearTimeout(timer); timer = null; } };
  el.onmouseleave = () => { if (duration > 0) timer = setTimeout(dismiss, 1500); };

  stack.appendChild(el);
  if (duration > 0) timer = setTimeout(dismiss, duration);
};

// ── Confirmation modal ────────────────────────────────────────────────────
function showConfirmModal(confId, message) {
  $("modal-message").textContent   = message;
  $("modal-overlay").style.display = "flex";

  const answer = result => {
    $("modal-overlay").style.display = "none";
    WS.send({ type: "confirmation", session_id: Sessions.activeId, id: confId, result });
  };
  $("modal-yes").onclick = () => answer("yes");
  $("modal-no").onclick  = () => answer("no");
}


// ── WS event dispatcher ───────────────────────────────────────────────────
// Moved to ws-dispatcher.js.

// ── Image & file attachments ──────────────────────────────────────────────
// Moved to sessions.js (Composer section — _initComposer() in Sessions.init()).
// All state (_pendingImages/_pendingFiles), helpers (_addAttachmentFile/etc.),
// preview rendering, and sendMessage() now live there as private members.

// ── DOM event listeners ───────────────────────────────────────────────────
// Sidebar toggle (with mobile overlay support)
function _isMobile() { return window.innerWidth <= 768; }

function _closeSidebar() {
  $("sidebar").classList.add("hidden");
  $("sidebar-overlay").classList.remove("active");
}

function _openSidebar() {
  $("sidebar").classList.remove("hidden");
  if (_isMobile()) $("sidebar-overlay").classList.add("active");
}

function _toggleSidebar() {
  const isHidden = $("sidebar").classList.contains("hidden");
  isHidden ? _openSidebar() : _closeSidebar();
}

if ($("btn-toggle-sidebar")) {
  $("btn-toggle-sidebar").addEventListener("click", _toggleSidebar);
}

// Tap overlay to close sidebar on mobile
$("sidebar-overlay").addEventListener("click", _closeSidebar);

// ── Sidebar resize ──────────────────────────────────────────────────────
(function _initSidebarResize() {
  const sidebar = $("sidebar");
  const handle = $("sidebar-resize-handle");
  if (!sidebar || !handle) return;

  const MIN_W = 12;  // rem
  const MAX_W = 32;  // rem
  const baseFontSize = parseFloat(getComputedStyle(document.documentElement).fontSize);

  let startX = 0;
  let startW = 0;

  // Restore saved width
  const saved = localStorage.getItem("clacky-sidebar-width");
  if (saved) {
    const w = parseFloat(saved);
    if (w >= MIN_W && w <= MAX_W) {
      sidebar.style.setProperty("--sidebar-width", w + "rem");
    }
  }

  function _getWidth() {
    return parseFloat(getComputedStyle(sidebar).getPropertyValue("--sidebar-width"));
  }

  handle.addEventListener("mousedown", (e) => {
    e.preventDefault();
    startX = e.clientX;
    startW = _getWidth();
    handle.classList.add("active");
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
  });

  document.addEventListener("mousemove", (e) => {
    if (!handle.classList.contains("active")) return;
    const dx = (e.clientX - startX) / baseFontSize;
    const newW = Math.min(MAX_W, Math.max(MIN_W, startW + dx));
    sidebar.style.setProperty("--sidebar-width", newW + "rem");
  });

  document.addEventListener("mouseup", () => {
    if (!handle.classList.contains("active")) return;
    handle.classList.remove("active");
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
    localStorage.setItem("clacky-sidebar-width", _getWidth());
  });
})();

// On mobile: start with sidebar hidden
if (_isMobile()) _closeSidebar();

// On mobile: auto-close sidebar when switching sessions/pages
function _mobileCloseSidebar() {
  if (_isMobile()) _closeSidebar();
}
// Expose for use in sessions.js (rename/delete dialogs need to close sidebar first)
window.mobileCloseSidebar = _mobileCloseSidebar;

// ── New session controls ───────────────────────────────────────────────────
// Moved to sessions.js (_initNewSessionControls, called from Sessions.init()).

// ── Session search bar ─────────────────────────────────────────────────────
// Moved to sessions.js (_initSearch in Sessions.init()).

// ── Theme / session-scoped message panel bindings ──────────────────────────

// Theme toggle in header
if ($("theme-toggle-header")) {
  $("theme-toggle-header").addEventListener("click", () => Theme.toggle());
}
// btn-delete-session, #messages scroll-to-top (load history), and btn-interrupt
// moved to sessions.js (_initMessageHistory in Sessions.init()).

// btn-send, btn-attach, image-file-input change, input-area drag/drop, and
// user-input paste handlers moved to sessions.js (_initComposer).


// ── Skill autocomplete + composer bindings ───────────────────────────────
// Moved to skills.js (SkillAC IIFE, initialized from SkillAC.init()).


// ── Boot ──────────────────────────────────────────────────────────────────
Sidebar.init();
Settings.init();
Channels.init();
Sessions.init();

// Boot sequence:
//   1. Brand check    — shows a dismissible top banner if license activation is needed.
//                       Never blocks boot; user can activate at any time via the banner.
//   2. Onboard check  — first-run setup (key_setup / soul_setup)
//   3. Normal UI boot — WS + sessions + tasks + skills
//
// key_setup  → hard block: shows full-screen setup-panel (language + API key).
//              On success, setup-panel auto-launches /onboard session then boots UI.
// soul_setup → soft: auto-launches /onboard session and boots UI immediately.
//              No blocking panel shown.

window.bootAfterBrand = async function() {
  const { needsOnboard, phase } = await Onboard.check();
  // key_setup blocks boot entirely; onboard.js calls _bootUI() when done.
  if (needsOnboard && phase === "key_setup") return;

  // Initialize skill autocomplete
  SkillAC.init();

  // soul_setup: Onboard.check() already launched the session and called _bootUI().
  // For any other state, boot normally here.
  if (!needsOnboard) {
    // Auth already checked at app boot — safe to make API calls
    WS.connect();
    Tasks.load();
    Skills.load();
  }
};

(async () => {
  // Auth check MUST run first — all API calls depend on it
  const authOk = await Auth.check();
  if (!authOk) {
    // User cancelled auth prompt — stop boot
    return;
  }

  // Brand.check() now only shows a top banner when activation is needed;
  // it never returns true to block boot, so we always continue to bootAfterBrand().
  await Brand.check();
  await window.bootAfterBrand();
})();

// ── Image Lightbox ────────────────────────────────────────────────────────────
// Global lightbox: click any .msg-image-thumb to open; click backdrop or ✕ or
// press ESC to close.
(function () {
  let _overlay = null;

  function _open(src, alt) {
    if (_overlay) return;
    _overlay = document.createElement("div");
    _overlay.className = "img-lightbox";
    _overlay.innerHTML =
      `<span class="img-lightbox-close" title="Close">✕</span>` +
      `<img src="${src}" alt="${alt || "image"}">`;

    // Click on backdrop or ✕ → close
    _overlay.addEventListener("click", function (e) {
      if (e.target === _overlay || e.target.classList.contains("img-lightbox-close")) {
        _close();
      }
    });

    document.body.appendChild(_overlay);
  }

  function _close() {
    if (_overlay) { _overlay.remove(); _overlay = null; }
  }

  // ESC key closes lightbox
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") _close();
  });

  // Event delegation: any click on .msg-image-thumb anywhere in the page
  document.addEventListener("click", function (e) {
    if (e.target.classList.contains("msg-image-thumb")) {
      _open(e.target.src, e.target.alt);
    }
  });
})();

// Session Info Bar (model switcher + working-directory switcher) moved to sessions.js

// Logo hover shake with debounce
(function () {
  const logo = document.getElementById('header-logo-img');
  if (!logo) return;
  let timer = null;
  logo.addEventListener('mouseenter', function () {
    clearTimeout(timer);
    timer = setTimeout(function () {
      logo.style.animation = 'none';
      logo.offsetHeight;
      logo.style.animation = 'logo-shake 0.5s ease';
    }, 100);
  });
  logo.addEventListener('mouseleave', function () {
    clearTimeout(timer);
  });
  logo.addEventListener('animationend', function () {
    logo.style.animation = 'none';
  });
})();

