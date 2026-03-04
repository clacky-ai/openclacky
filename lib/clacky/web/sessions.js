// ── Sessions — session state, rendering, message cache ────────────────────
//
// Responsibilities:
//   - Maintain the canonical sessions list (updated from WS events)
//   - Render the session sidebar list
//   - Manage per-session message DOM cache (fast panel switch)
//   - Select / deselect sessions; show/hide the chat panel
//   - No polling: sessions arrive exclusively via WS session_list / session_update
//
// Depends on: WS (ws.js), global $ helper, global escapeHtml helper
// ─────────────────────────────────────────────────────────────────────────

const Sessions = (() => {
  // ── Private state ──────────────────────────────────────────────────────
  const _sessions     = [];     // [{ id, name, status, total_tasks, total_cost }]
  const _messageCache = {};     // { [session_id]: DocumentFragment }
  let   _activeId     = null;

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

  function _showPanel() {
    $("welcome").style.display            = "none";
    $("task-detail-panel").style.display  = "none";
    $("chat-panel").style.display         = "flex";
    $("chat-panel").style.flexDirection   = "column";
  }

  // ── Public API ─────────────────────────────────────────────────────────
  return {
    // ── Data access ─────────────────────────────────────────────────────
    get all()      { return _sessions; },
    get activeId() { return _activeId; },
    find: id => _sessions.find(s => s.id === id),

    // ── State mutations ──────────────────────────────────────────────────

    /** Replace the full sessions list (from session_list event). */
    setAll(list) {
      _sessions.length = 0;
      _sessions.push(...list);
    },

    /** Patch a single session's fields (from session_update event). */
    patch(id, fields) {
      const s = _sessions.find(s => s.id === id);
      if (s) Object.assign(s, fields);
    },

    /** Remove a session from the list. */
    remove(id) {
      const idx = _sessions.findIndex(s => s.id === id);
      if (idx !== -1) _sessions.splice(idx, 1);
    },

    // ── Selection ────────────────────────────────────────────────────────

    /** Select a session: update state, switch panel, restore message cache. */
    select(id) {
      const s = _sessions.find(s => s.id === id);
      if (!s) return;

      const isSwitch = _activeId !== id;

      _cacheActiveMessages();
      _activeId = id;

      _showPanel();
      $("chat-title").textContent = s.name;
      Sessions.updateStatusBar(s.status);

      _restoreMessages(id);

      // Only send subscribe when actually switching to a different session,
      // preventing duplicate registrations on re-renders.
      if (isSwitch) {
        WS.setSubscribedSession(id);
        WS.send({ type: "subscribe", session_id: id });
      }

      Sessions.renderList();
      $("user-input").focus();
    },

    /** Deselect and show the welcome screen. */
    deselect() {
      _cacheActiveMessages();
      _activeId = null;
      WS.setSubscribedSession(null);
      $("welcome").style.display           = "";
      $("chat-panel").style.display        = "none";
      $("task-detail-panel").style.display = "none";
      Sessions.renderList();
    },

    // ── Rendering ────────────────────────────────────────────────────────

    /** Render the session list in the sidebar. */
    renderList() {
      const list = $("session-list");
      list.innerHTML = "";
      _sessions.forEach(s => {
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

    /** Update the status bar in the chat header. */
    updateStatusBar(status) {
      $("chat-status").textContent = status || "idle";
      $("chat-status").className   = status === "running" ? "status-running" : "status-idle";
      const running = status === "running";
      $("btn-send").disabled           = running;
      $("btn-interrupt").style.display = running ? "" : "none";
    },

    // ── Message helpers ──────────────────────────────────────────────────

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
      Sessions._progressEl   = el;
      messages.scrollTop = messages.scrollHeight;
    },

    clearProgress() {
      if (Sessions._progressEl) {
        Sessions._progressEl.remove();
        Sessions._progressEl = null;
      }
    },

    _progressEl: null,

    // ── Create session ───────────────────────────────────────────────────

    async create() {
      const name = prompt("Session name (leave blank for default):");
      if (name === null) return;

      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name: name || undefined })
      });
      const data = await res.json();
      if (!res.ok) { alert("Error: " + (data.error || "unknown")); return; }

      // The new session will arrive via WS session_list; wait for it
      const newId = data.session?.id;
      if (newId) Sessions._waitAndSelect(newId);
    },

    /** Wait for a session to appear in the list (via WS), then select it.
     *  Uses a MutationObserver-like approach: just listen for the next
     *  session_list event via a one-shot WS handler registered in app.js.
     *  Here we use a simple retry with a hard limit. */
    _waitAndSelect(id, attempts = 0) {
      const s = _sessions.find(s => s.id === id);
      if (s) { Sessions.select(id); return; }
      if (attempts > 30) { console.warn("[Sessions] gave up waiting for session", id); return; }
      // Request a fresh list and retry
      WS.send({ type: "list_sessions" });
      setTimeout(() => Sessions._waitAndSelect(id, attempts + 1), 200);
    },
  };
})();
