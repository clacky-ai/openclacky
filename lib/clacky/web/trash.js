// trash.js — File Recall & Session Recycle Bin
//
// Two-tab panel under the "File Recall" sidebar item:
//   Tab 1 (文件回收 / Agent Files): AI-deleted files from all projects
//   Tab 2 (会话回收 / Sessions):     soft-deleted sessions that can be restored
//
// Each tab has its own toolbar actions (refresh, empty by age, empty all).
// The "Clean orphans" button is file-trash-only and hidden on the session tab.
//
// Load order: after app.js modules (I18n, Modal), before app.js boot.

const Trash = (() => {
  // ── Private state ────────────────────────────────────────────────────
  let _files       = [];
  let _totals      = { count: 0, size: 0 };
  let _sessions    = [];
  let _sessionTotals = { count: 0, size: 0 };
  let _activeTab   = null;  // null = no tab shown yet; set on first _switchTab
  let _loading     = false;
  let _wired       = false;

  // ── Helpers ──────────────────────────────────────────────────────────

  function $(id) { return document.getElementById(id); }

  function escapeHtml(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function _t(key) {
    return I18n.t ? I18n.t(key) : key;
  }

  function _humanBytes(n) {
    if (!n || n < 0) return "0 B";
    const units = ["B", "KB", "MB", "GB"];
    let i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n.toFixed(0) : n.toFixed(2)) + " " + units[i];
  }

  function _humanTime(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (isNaN(d.getTime())) return iso;
    const now   = new Date();
    const ms    = now - d;
    const mins  = Math.floor(ms / 60000);
    const hours = Math.floor(ms / 3600000);
    const days  = Math.floor(ms / 86400000);
    if (mins < 1)   return I18n.t("time.justNow");
    if (mins < 60)  return I18n.t("time.minsAgo",  { n: mins });
    if (hours < 24) return I18n.t("time.hoursAgo", { n: hours });
    if (days < 7)   return I18n.t("time.daysAgo",  { n: days });
    return d.toLocaleDateString();
  }

  // ── Tab switching ────────────────────────────────────────────────────

  function _switchTab(tab) {
    if (_activeTab === tab) return;
    _activeTab = tab;

    // Update tab button active states
    document.querySelectorAll(".trash-tab").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.tab === tab);
    });

    // Show/hide tab content panels
    const filePane    = $("trash-tab-file");
    const sessionPane = $("trash-tab-session");
    if (filePane)    filePane.style.display    = tab === "file-trash" ? "" : "none";
    if (sessionPane) sessionPane.style.display = tab === "session-trash" ? "" : "none";

    // Show/hide "Clean orphans" button — only relevant for file trash
    const btnOrphans = $("btn-trash-empty-orphans");
    if (btnOrphans) btnOrphans.style.display = tab === "file-trash" ? "" : "none";

    // Reload the active tab's data
    _load();
  }

  // ── Data loading ─────────────────────────────────────────────────────

  async function _load() {
    if (_loading) return;
    _loading = true;

    if (_activeTab === "file-trash") {
      await _loadFiles();
    } else {
      await _loadSessions();
    }

    _loading = false;
  }

  async function _loadFiles() {
    const list = $("trash-list");
    if (list) list.innerHTML =
      `<div class="creator-loading">${_t("trash.loading")}</div>`;
    try {
      const res  = await fetch("/api/trash");
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Load failed");
      _files  = data.files  || [];
      _totals = { count: data.total_count || 0, size: data.total_size || 0 };
      _renderFiles();
    } catch (e) {
      console.error("[Trash] load files failed", e);
      if (list) list.innerHTML =
        `<div class="creator-empty creator-error">${escapeHtml(e.message)}</div>`;
    }
  }

  async function _loadSessions() {
    const list = $("trash-session-list");
    if (list) list.innerHTML =
      `<div class="creator-loading">${_t("trash.loading")}</div>`;
    try {
      const res  = await fetch("/api/trash/sessions");
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Load failed");
      _sessions      = data.sessions || [];
      _sessionTotals = { count: data.count || 0, size: data.total_size || 0 };
      _renderSessions();
    } catch (e) {
      console.error("[Trash] load sessions failed", e);
      if (list) list.innerHTML =
        `<div class="creator-empty creator-error">${escapeHtml(e.message)}</div>`;
    }
  }

  // ── File trash rendering ─────────────────────────────────────────────

  function _renderFiles() {
    const list        = $("trash-list");
    const summary     = $("trash-summary");
    const btnOld      = $("btn-trash-empty-old");
    const btnOrphans  = $("btn-trash-empty-orphans");
    const btnAll      = $("btn-trash-empty-all");
    if (!list) return;

    const orphanCount = _files.filter(f => {
      const root = f.project_root || "";
      return /^\/(?:var\/folders|tmp|private\/var\/folders)\b/.test(root) ||
             /\/d\d{8}-\d+-[a-z0-9]+(?:\/|$)/.test(root);
    }).length;

    if (summary) {
      summary.textContent = _files.length
        ? I18n.t("trash.summary", {
            count: _totals.count,
            size:  _humanBytes(_totals.size)
          }) + (orphanCount > 0 ? "  •  " + I18n.t("trash.summaryOrphans", { count: orphanCount }) : "")
        : "";
    }
    if (btnOld)     btnOld.disabled     = _files.length === 0;
    if (btnOrphans) btnOrphans.disabled = orphanCount === 0;
    if (btnAll)     btnAll.disabled     = _files.length === 0;

    if (_files.length === 0) {
      list.innerHTML = `<div class="creator-empty">${_t("trash.empty")}</div>`;
      return;
    }

    list.innerHTML = "";
    _files.forEach(f => list.appendChild(_buildFileCard(f)));
  }

  function _buildFileCard(file) {
    const card = document.createElement("div");
    card.className = "trash-card";
    card.dataset.project = file.project_root;
    card.dataset.path    = file.original_path;

    const original = file.original_path || "";
    const basename = original.split("/").pop() || original;
    const parts    = original.split("/").filter(Boolean);
    // Show last three path segments so same-named files (index.js, package.json, …)
    // are still distinguishable in the card title area.
    const shortPath = parts.length > 3
      ? ".../" + parts.slice(-3).join("/")
      : original;
    const sizeStr  = _humanBytes(file.file_size || 0);
    const whenStr  = _humanTime(file.deleted_at);
    // Heuristic: if project_root lives under a temp-dir prefix or matches the
    // Ruby Tempdir pattern (dYYYYMMDD-PID-random), the original project is gone.
    // We mark it as an orphan so the user can bulk-clean it confidently.
    const orphan = /^\/(?:var\/folders|tmp|private\/var\/folders)\b/.test(file.project_root || "") ||
                   /\/d\d{8}-\d+-[a-z0-9]+(?:\/|$)/.test(file.project_root || "");

    card.innerHTML = `
      <div class="trash-card-info">
        <div class="trash-card-title" title="${escapeHtml(original)}">${escapeHtml(basename)}</div>
        <div class="trash-card-path" title="${escapeHtml(original)}">${escapeHtml(shortPath)}</div>
        <div class="trash-card-meta">
          <span class="trash-project" title="${escapeHtml(file.project_root)}">
            <svg xmlns="http://www.w3.org/2000/svg" width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
            </svg>
            ${escapeHtml(file.project_name || "")}
          </span>
          <span>${sizeStr}</span>
          <span title="${escapeHtml(file.deleted_at || "")}">${escapeHtml(whenStr)}</span>
          ${orphan ? `<span class="trash-missing" title="${_t("trash.orphanHint")}">⚠ ${_t("trash.orphan")}</span>` : ""}
        </div>
      </div>
      <div class="trash-card-actions">
        <button class="btn-trash-restore" title="${_t("trash.restore")}" ${orphan ? "disabled" : ""}>
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="1 4 1 10 7 10"/>
            <path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/>
          </svg>
          ${_t("trash.restore")}
        </button>
        <button class="btn-trash-delete" title="${_t("trash.delete")}">
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="3 6 5 6 21 6"/>
            <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>
            <path d="M10 11v6"/><path d="M14 11v6"/>
          </svg>
        </button>
      </div>`;

    card.querySelector(".btn-trash-restore").addEventListener("click", () =>
      _restoreFile(file, card));
    card.querySelector(".btn-trash-delete").addEventListener("click", () =>
      _deleteFile(file, card));

    return card;
  }

  // ── Session trash rendering ──────────────────────────────────────────

  function _renderSessions() {
    const list     = $("trash-session-list");
    const summary  = $("trash-summary");
    const btnOld   = $("btn-trash-empty-old");
    const btnAll   = $("btn-trash-empty-all");
    if (!list) return;

    if (summary) {
      summary.textContent = _sessions.length
        ? I18n.t("trash.summarySessions", {
            count: _sessionTotals.count,
            size:  _humanBytes(_sessionTotals.size)
          })
        : "";
    }
    if (btnOld) btnOld.disabled = _sessions.length === 0;
    if (btnAll) btnAll.disabled = _sessions.length === 0;

    if (_sessions.length === 0) {
      list.innerHTML = `<div class="creator-empty">${_t("trash.noSessionTrash")}</div>`;
      return;
    }

    list.innerHTML = "";
    _sessions.forEach(s => list.appendChild(_buildSessionCard(s)));
  }

  function _buildSessionCard(session) {
    const card = document.createElement("div");
    card.className = "trash-session-card";
    card.dataset.sessionId = session.session_id;

    const name      = session.name || session.session_id || "";
    const shortId   = (session.session_id || "").slice(0, 8);
    const taskCount = session.total_tasks || 0;
    const sizeStr   = _humanBytes(session.file_size || 0);
    const whenStr   = _humanTime(session.deleted_at || session.created_at);
    const taskLabel = I18n.t("trash.sessionTasks", { n: taskCount });

    card.innerHTML = `
      <div class="trash-session-card-info">
        <div class="trash-session-card-name" title="${escapeHtml(name)}">${escapeHtml(name)}</div>
        <div class="trash-session-card-id" title="${escapeHtml(session.session_id || '')}">${escapeHtml(session.session_id || '')}</div>
        <div class="trash-session-card-meta">
          <span>${escapeHtml(taskLabel)}</span>
          <span>${sizeStr}</span>
          <span title="${escapeHtml(session.deleted_at || session.created_at || '')}">${escapeHtml(whenStr)}</span>
        </div>
      </div>
      <div class="trash-session-card-actions">
        <button class="btn-trash-session-restore" title="${_t("trash.restoreSession")}">
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="1 4 1 10 7 10"/>
            <path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/>
          </svg>
          ${_t("trash.restoreSession")}
        </button>
        <button class="btn-trash-session-delete" title="${_t("trash.deleteSession")}">
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="3 6 5 6 21 6"/>
            <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>
            <path d="M10 11v6"/><path d="M14 11v6"/>
          </svg>
        </button>
      </div>`;

    card.querySelector(".btn-trash-session-restore").addEventListener("click", () =>
      _restoreSession(session, card));
    card.querySelector(".btn-trash-session-delete").addEventListener("click", () =>
      _deleteSession(session, card));

    return card;
  }

  // ── File actions ─────────────────────────────────────────────────────

  async function _restoreFile(file, card) {
    const btn = card.querySelector(".btn-trash-restore");
    btn.disabled = true;
    try {
      const res = await fetch("/api/trash/restore", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          project_root:  file.project_root,
          original_path: file.original_path
        })
      });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        Modal.toast(I18n.t("trash.restoreFail", {
          msg: data.error || res.statusText
        }), "error");
      } else {
        // Optimistic update — remove from local state and re-render immediately
        // so the UI feels instant without waiting for a full reload.
        _files = _files.filter(f =>
          !(f.project_root === file.project_root && f.original_path === file.original_path));
        _totals = {
          count: Math.max(0, _totals.count - 1),
          size:  Math.max(0, _totals.size - (file.file_size || 0))
        };
        _renderFiles();
        Modal.toast(I18n.t("trash.restoreOk", {
          path: (file.original_path || "").split("/").pop()
        }), "success");
      }
    } catch (e) {
      Modal.toast(I18n.t("trash.restoreFail", { msg: e.message }), "error");
    } finally {
      btn.disabled = false;
    }
  }

  async function _deleteFile(file, card) {
    const basename = (file.original_path || "").split("/").pop() || file.original_path;
    const confirmed = await Modal.confirm(
      I18n.t("trash.confirmDeleteOne", { name: basename })
    );
    if (!confirmed) return;

    const url = "/api/trash?" + new URLSearchParams({
      project: file.project_root,
      file:    file.original_path
    }).toString();

    try {
      const res  = await fetch(url, { method: "DELETE" });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        Modal.toast(I18n.t("trash.deleteFail", { msg: data.error || res.statusText }), "error");
        return;
      }
      // Optimistic update — same pattern as _restoreFile.
      _files = _files.filter(f =>
        !(f.project_root === file.project_root && f.original_path === file.original_path));
      _totals = {
        count: Math.max(0, _totals.count - 1),
        size:  Math.max(0, _totals.size - (file.file_size || 0))
      };
      _renderFiles();
    } catch (e) {
      Modal.toast(I18n.t("trash.deleteFail", { msg: e.message }), "error");
    }
  }

  // ── Session actions ──────────────────────────────────────────────────

  async function _restoreSession(session, card) {
    const btn = card.querySelector(".btn-trash-session-restore");
    btn.disabled = true;
    try {
      const res = await fetch("/api/trash/sessions/restore", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ session_id: session.session_id })
      });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        Modal.toast(I18n.t("trash.sessionRestoreFail", {
          msg: data.error || res.statusText
        }), "error");
      } else {
        _sessions = _sessions.filter(s => s.session_id !== session.session_id);
        _sessionTotals = {
          count: Math.max(0, _sessionTotals.count - 1),
          size:  Math.max(0, _sessionTotals.size - (session.file_size || 0))
        };
        _renderSessions();
        // Optimistically add the restored session to the sidebar — same pattern
        // as the WS session_restored handler, but covers the case where the WS
        // event is lost (offline tab, slow reconnect). Sessions.add is idempotent.
        const restored = data.session;
        if (restored && typeof Sessions !== "undefined") {
          Sessions.add(restored);
          Sessions.renderList();
        }
        Modal.toast(I18n.t("trash.sessionRestoreOk"), "success", restored && restored.id ? {
          action: {
            label:   I18n.t("trash.sessionRestoreOkAction"),
            onClick: () => Sessions.select(restored.id)
          }
        } : {});
      }
    } catch (e) {
      Modal.toast(I18n.t("trash.sessionRestoreFail", { msg: e.message }), "error");
    } finally {
      btn.disabled = false;
    }
  }

  async function _deleteSession(session, card) {
    const name = session.name || (session.session_id || "").slice(0, 8);
    const confirmed = await Modal.confirm(
      I18n.t("trash.confirmDeleteSession", { name: name })
    );
    if (!confirmed) return;

    try {
      const res  = await fetch(`/api/trash/sessions/${encodeURIComponent(session.session_id)}`, {
        method: "DELETE"
      });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        Modal.toast(I18n.t("trash.deleteFail", { msg: data.error || res.statusText }), "error");
        return;
      }
      _sessions = _sessions.filter(s => s.session_id !== session.session_id);
      _renderSessions();
    } catch (e) {
      Modal.toast(I18n.t("trash.deleteFail", { msg: e.message }), "error");
    }
  }

  // ── Bulk actions ─────────────────────────────────────────────────────

  // Count locally how many entries would be wiped by a bulk operation,
  // so the confirmation dialog can show "delete N items" instead of a vague
  // "all eligible". daysOld=0 means "everything", otherwise filter by deleted_at.
  function _countMatching(items, daysOld) {
    if (!Array.isArray(items)) return 0;
    if (!daysOld || daysOld <= 0) return items.length;
    const cutoff = Date.now() - daysOld * 86400000;
    return items.filter(it => {
      const t = Date.parse(it.deleted_at || "");
      return !isNaN(t) && t < cutoff;
    }).length;
  }

  async function _emptyBulk(daysOld, confirmKey) {
    const isSession = _activeTab === "session-trash";
    const matchCount = _countMatching(isSession ? _sessions : _files, daysOld);

    if (matchCount === 0) {
      Modal.toast(_t(daysOld > 0 ? "trash.nothingOld" : "trash.empty"), "info");
      return;
    }

    const confirmed = await Modal.confirm(
      I18n.t(confirmKey, { count: matchCount })
    );
    if (!confirmed) return;

    if (isSession) return _emptySessionsBulk(daysOld);

    const qs  = new URLSearchParams();
    qs.set("days_old", String(daysOld));
    const url = "/api/trash?" + qs.toString();

    try {
      const res  = await fetch(url, { method: "DELETE" });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        Modal.toast(I18n.t("trash.cleanFail", { msg: data.error || res.statusText }), "error");
        return;
      }
      Modal.toast(I18n.t("trash.emptied", {
        count: data.deleted_count || 0,
        size:  _humanBytes(data.freed_size || 0)
      }), "success");
      await _loadFiles();
    } catch (e) {
      Modal.toast(I18n.t("trash.cleanFail", { msg: e.message }), "error");
    }
  }

  async function _emptySessionsBulk(daysOld) {
    const qs  = new URLSearchParams();
    qs.set("days_old", String(daysOld));
    const url = "/api/trash/sessions?" + qs.toString();

    try {
      const res  = await fetch(url, { method: "DELETE" });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        Modal.toast(I18n.t("trash.cleanFail", { msg: data.error || res.statusText }), "error");
        return;
      }
      Modal.toast(I18n.t("trash.sessionsCleaned", {
        count: data.deleted_count || 0
      }), "success");
      await _loadSessions();
    } catch (e) {
      Modal.toast(I18n.t("trash.cleanFail", { msg: e.message }), "error");
    }
  }

  async function _emptyOrphans() {
    // Same heuristic as in _buildFileCard — keep both in sync if you ever change it.
    const orphans = _files.filter(f => {
      const root = f.project_root || "";
      return /^\/(?:var\/folders|tmp|private\/var\/folders)\b/.test(root) ||
             /\/d\d{8}-\d+-[a-z0-9]+(?:\/|$)/.test(root);
    });
    if (orphans.length === 0) {
      Modal.toast(_t("trash.noOrphans"), "info");
      return;
    }
    const confirmed = await Modal.confirm(
      I18n.t("trash.confirmEmptyOrphans", { count: orphans.length })
    );
    if (!confirmed) return;

    let deleted = 0, freed = 0, failed = 0;
    for (const f of orphans) {
      const url = "/api/trash?" + new URLSearchParams({
        project: f.project_root,
        file:    f.original_path
      }).toString();
      try {
        const r = await fetch(url, { method: "DELETE" });
        const d = await r.json();
        if (r.ok && d.ok) {
          deleted += 1;
          freed   += d.freed_size || 0;
        } else {
          failed += 1;
        }
      } catch (_e) {
        failed += 1;
      }
    }
    Modal.toast(I18n.t("trash.orphansCleaned", {
      count:  deleted,
      size:   _humanBytes(freed),
      failed: failed
    }), failed > 0 ? "warning" : "success");
    await _loadFiles();
  }

  // ── Event wiring ─────────────────────────────────────────────────────

  function _wire() {
    if (_wired) return;
    _wired = true;

    // Tab switches
    const tabFile    = $("tab-file-trash");
    const tabSession = $("tab-session-trash");
    if (tabFile)    tabFile.addEventListener("click",    () => _switchTab("file-trash"));
    if (tabSession) tabSession.addEventListener("click", () => _switchTab("session-trash"));

    // Toolbar buttons
    const btnRefresh = $("btn-trash-refresh");
    const btnOld     = $("btn-trash-empty-old");
    const btnOrphans = $("btn-trash-empty-orphans");
    const btnAll     = $("btn-trash-empty-all");
    if (btnRefresh) btnRefresh.addEventListener("click", () => _load());
    if (btnOld)     btnOld.addEventListener("click",
      () => _emptyBulk(7, _activeTab === "session-trash"
        ? "trash.confirmEmptySessionOld" : "trash.confirmEmptyOld"));
    if (btnOrphans) btnOrphans.addEventListener("click", () => _emptyOrphans());
    if (btnAll)     btnAll.addEventListener("click",
      () => _emptyBulk(0, _activeTab === "session-trash"
        ? "trash.confirmEmptySessionAll" : "trash.confirmEmptyAll"));
  }

  // ── Public API ────────────────────────────────────────────────────────

  return {
    /** Called by Router when the trash panel becomes active. */
    onPanelShow() {
      _wire();
      // Reset to file-trash tab on each panel show so the user always
      // starts on the familiar "agent files" view.
      _switchTab("file-trash");
    },
  };
})();
