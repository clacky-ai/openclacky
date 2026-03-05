// ── Sessions — session state, rendering, message cache ────────────────────
//
// Responsibilities:
//   - Maintain the canonical sessions list
//   - session_list (WS) is used ONLY on initial connect to populate the list
//   - After that, the list is maintained locally:
//       add: from POST /api/sessions response
//       update: from session_update WS event
//       remove: from session_deleted WS event
//   - Render the session sidebar list
//   - Manage per-session message DOM cache (fast panel switch)
//   - Select / deselect sessions — panel switching is delegated to Router
//
// Depends on: WS (ws.js), Router (app.js), global $ / escapeHtml helpers
// ─────────────────────────────────────────────────────────────────────────

const Sessions = (() => {
  const _sessions     = [];  // [{ id, name, status, total_tasks, total_cost }]
  const _messageCache = {};  // { [session_id]: DocumentFragment }
  let   _activeId     = null;
  let   _pendingRunTaskId = null;  // session_id waiting to send "run_task" after subscribe

  // ── Private helpers ────────────────────────────────────────────────────

  function _cacheActiveMessages() {
    if (!_activeId) return;
    const messages = $("messages");
    const frag = document.createDocumentFragment();
    while (messages.firstChild) frag.appendChild(messages.firstChild);
    _messageCache[_activeId] = frag;
  }

  function _restoreMessages(id) {
    const messages = $("messages");
    messages.innerHTML = "";
    if (_messageCache[id]) {
      messages.appendChild(_messageCache[id]);
      delete _messageCache[id];
      messages.scrollTop = messages.scrollHeight;
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────
  return {
    get all()      { return _sessions; },
    get activeId() { return _activeId; },
    find: id => _sessions.find(s => s.id === id),

    // ── List management ───────────────────────────────────────────────────

    /** Populate list from initial session_list WS event (connect only). */
    setAll(list) {
      _sessions.length = 0;
      _sessions.push(...list);
    },

    /** Insert a newly created session into the local list. */
    add(session) {
      if (!_sessions.find(s => s.id === session.id)) {
        _sessions.push(session);
      }
    },

    /** Patch a single session's fields (from session_update event). */
    patch(id, fields) {
      const s = _sessions.find(s => s.id === id);
      if (s) Object.assign(s, fields);
    },

    /** Remove a session from the list (from session_deleted event). */
    remove(id) {
      const idx = _sessions.findIndex(s => s.id === id);
      if (idx !== -1) _sessions.splice(idx, 1);
    },

    // ── Selection ─────────────────────────────────────────────────────────
    //
    // Panel switching is handled by Router — Sessions only manages state.

    /** Navigate to a session. Delegates panel switching to Router. */
    select(id) {
      const s = _sessions.find(s => s.id === id);
      if (!s) return;
      Router.navigate("session", { id });
    },

    /** Deselect active session and go to welcome screen. */
    deselect() {
      _cacheActiveMessages();
      _activeId = null;
      WS.setSubscribedSession(null);
      Router.navigate("welcome");
    },

    // ── Router interface ──────────────────────────────────────────────────
    // These methods are called exclusively by Router._apply() to mutate
    // session state as part of a coordinated view transition. They must NOT
    // trigger further Router.navigate() calls to avoid infinite loops.

    /** Set _activeId directly (called by Router when activating a session). */
    _setActiveId(id) {
      _activeId = id;
    },

    /** Restore cached messages for a session into the #messages container. */
    _restoreMessagesPublic(id) {
      _restoreMessages(id);
    },

    /** Cache messages + clear activeId without touching panel visibility.
     *  Called by Router before switching away from a session view. */
    _cacheActiveAndDeselect() {
      _cacheActiveMessages();
      _activeId = null;
      WS.setSubscribedSession(null);
      Sessions.renderList();
    },

    // ── Rendering ─────────────────────────────────────────────────────────

    renderList() {
      const list = $("session-list");
      list.innerHTML = "";

      // Split into manual sessions and scheduled (⏰) sessions, each sorted
      // newest-first by created_at (falling back to array order).
      const byTime = (a, b) => {
        const ta = a.created_at ? new Date(a.created_at) : 0;
        const tb = b.created_at ? new Date(b.created_at) : 0;
        return tb - ta;
      };
      const manual    = _sessions.filter(s => !s.name.startsWith("⏰")).sort(byTime);
      const scheduled = _sessions.filter(s =>  s.name.startsWith("⏰")).sort(byTime);

      [...manual, ...scheduled].forEach(s => {
        const el = document.createElement("div");
        el.className = "session-item" + (s.id === _activeId ? " active" : "");
        el.innerHTML = `
          <div class="session-name">
            <span class="session-dot dot-${s.status || "idle"}"></span>${escapeHtml(s.name)}
          </div>
          <div class="session-meta">${s.total_tasks || 0} tasks · $${(s.total_cost || 0).toFixed(4)}</div>`;
        el.onclick = () => Sessions.select(s.id);
        list.appendChild(el);
      });
    },

    updateStatusBar(status) {
      $("chat-status").textContent = status || "idle";
      $("chat-status").className   = status === "running" ? "status-running" : "status-idle";
      $("btn-interrupt").style.display = status === "running" ? "" : "none";
    },

    // ── Message helpers ────────────────────────────────────────────────────

    appendMsg(type, html) {
      const messages = $("messages");
      const el = document.createElement("div");
      el.className = `msg msg-${type}`;
      el.innerHTML = html;
      messages.appendChild(el);
      messages.scrollTop = messages.scrollHeight;
    },

    appendInfo(text) {
      const messages = $("messages");
      const el = document.createElement("div");
      el.className   = "msg msg-info";
      el.textContent = text;
      messages.appendChild(el);
      messages.scrollTop = messages.scrollHeight;
    },

    showProgress(text) {
      Sessions.clearProgress();
      const messages = $("messages");
      const el = document.createElement("div");
      el.className   = "progress-msg";
      el.textContent = "⟳ " + text;
      messages.appendChild(el);
      Sessions._progressEl = el;
      messages.scrollTop = messages.scrollHeight;
    },

    clearProgress() {
      if (Sessions._progressEl) {
        Sessions._progressEl.remove();
        Sessions._progressEl = null;
      }
    },

    _progressEl: null,

    // ── Create ─────────────────────────────────────────────────────────────

    /** Create a new session and navigate to it. */
    async create() {
      const maxN = _sessions.reduce((max, s) => {
        const m = s.name.match(/^Session (\d+)$/);
        return m ? Math.max(max, parseInt(m[1], 10)) : max;
      }, 0);
      const name = "Session " + (maxN + 1);

      const res  = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name })
      });
      const data = await res.json();
      if (!res.ok) { alert("Error: " + (data.error || "unknown")); return; }

      const session = data.session;
      if (!session) return;

      Sessions.add(session);
      Sessions.renderList();
      Sessions.select(session.id);
    },

    /** Mark a session as having a pending task that should start after subscribe. */
    setPendingRunTask(sessionId) {
      _pendingRunTaskId = sessionId;
    },

    /** Consume and return the pending run-task session id (clears it). */
    takePendingRunTask() {
      const id = _pendingRunTaskId;
      _pendingRunTaskId = null;
      return id;
    },
  };
})();
