// ── Trash · view — recycle-bin rendering, tabs, DOM wiring, dialogs ────────
//
// Owns rendering of file/session cards, tab switching, toolbar wiring, and all
// confirm/toast dialogs. Reads through TrashStore.state and drives every data
// mutation through store actions, re-rendering on store change events.
//
// Augments the `Trash` facade with onPanelShow.
//
// Depends on: TrashStore, I18n, Modal, Sessions.
// ───────────────────────────────────────────────────────────────────────────

const TrashView = (() => {
  let _activeTab = null;
  let _wired     = false;

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

  // ── Project filter select helpers ────────────────────────────────────

  function _refreshProjectOptions() {
    const wrap = $("trash-filter-project");
    if (!wrap) return;
    const dropdown = wrap.querySelector(".custom-select-dropdown");
    if (!dropdown) return;
    const ctl = dropdown.__customSelect;
    const currentVal = ctl ? ctl.value : "";

    const projects = (typeof Projects !== "undefined") ? Projects.all() : [];
    const allLabel = I18n.t ? I18n.t("trash.filterAllProjects") : "所有项目";

    dropdown.innerHTML = "";
    const all = document.createElement("div");
    all.className = "custom-select-option";
    all.dataset.value = "";
    all.textContent = allLabel;
    dropdown.appendChild(all);
    projects.forEach(p => {
      const opt = document.createElement("div");
      opt.className = "custom-select-option";
      opt.dataset.value = p.id;
      opt.textContent = p.name || p.id;
      dropdown.appendChild(opt);
    });

    if (ctl) {
      const restore = (currentVal && projects.some(p => String(p.id) === currentVal)) ? currentVal : "";
      ctl.setValue(restore);
    }
  }

  // ── Tab switching ────────────────────────────────────────────────────

  function _switchTab(tab) {
    if (_activeTab === tab) return;
    _activeTab = tab;

    document.querySelectorAll(".trash-tab").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.tab === tab);
    });

    const filePane    = $("trash-tab-file");
    const sessionPane = $("trash-tab-session");
    const filterBar   = $("trash-filter-bar");
    if (filePane)    filePane.style.display    = tab === "file-trash" ? "" : "none";
    if (sessionPane) sessionPane.style.display = tab === "session-trash" ? "" : "none";
    if (filterBar)   filterBar.style.display   = tab === "session-trash" ? "" : "none";

    const hint = $("trash-session-hint");
    if (hint) hint.style.display = tab === "session-trash" ? "" : "none";

    const btnOrphans = $("btn-trash-empty-orphans");
    if (btnOrphans) btnOrphans.style.display = tab === "file-trash" ? "" : "none";

    _load();
  }

  function _load() {
    if (_activeTab === "file-trash") {
      Trash.loadFiles();
    } else {
      Trash.loadSessions();
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

    const files       = Trash.state.files;
    const totals      = Trash.state.totals;
    const orphanCount = Trash.state.orphanCount();

    if (summary) {
      summary.textContent = files.length
        ? I18n.t("trash.summary", {
            count: totals.count,
            size:  _humanBytes(totals.size)
          }) + (orphanCount > 0 ? "  •  " + I18n.t("trash.summaryOrphans", { count: orphanCount }) : "")
        : "";
    }
    if (btnOld)     btnOld.disabled     = files.length === 0;
    if (btnOrphans) btnOrphans.disabled = orphanCount === 0;
    if (btnAll)     btnAll.disabled     = files.length === 0;

    if (files.length === 0) {
      list.innerHTML = `<div class="trash-empty">${_t("trash.empty")}</div>`;
      return;
    }

    list.innerHTML = "";
    files.forEach(f => list.appendChild(_buildFileCard(f)));
  }

  function _buildFileCard(file) {
    const card = document.createElement("div");
    card.className = "trash-card";
    card.dataset.project = file.project_root;
    card.dataset.path    = file.original_path;

    const original = file.original_path || "";
    const basename = original.split("/").pop() || original;
    const parts    = original.split("/").filter(Boolean);
    const shortPath = parts.length > 3
      ? ".../" + parts.slice(-3).join("/")
      : original;
    const sizeStr  = _humanBytes(file.file_size || 0);
    const whenStr  = _humanTime(file.deleted_at);
    const orphan   = Trash.state.isOrphan(file);

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
      _deleteFile(file));

    return card;
  }

  // ── Session trash rendering ──────────────────────────────────────────

  function _renderSkeleton() {
    const isSession = _activeTab === "session-trash";
    const list = $(isSession ? "trash-session-list" : "trash-list");
    if (!list) return;
    let html = "";
    for (let i = 0; i < 3; i++) {
      html += `
        <div class="trash-session-skeleton">
          <div class="trash-session-skeleton-info">
            <div class="skel skel-title"></div>
            <div class="skel skel-subtitle"></div>
            <div class="skel skel-text-sm"></div>
          </div>
          <div class="trash-skeleton-actions">
            <div class="skel trash-skeleton-btn"></div>
            <div class="skel trash-skeleton-btn"></div>
          </div>
        </div>`;
    }
    list.innerHTML = html;
  }

  function _renderSessions() {
    const list       = $("trash-session-list");
    const summary    = $("trash-summary");
    const btnOld     = $("btn-trash-empty-old");
    const btnAll     = $("btn-trash-empty-all");
    const filterBar  = $("trash-filter-bar");
    if (!list) return;

    const sessions = Trash.state.sessions;
    const totals   = Trash.state.sessionTotals;

    if (summary) {
      summary.textContent = sessions.length
        ? I18n.t("trash.summarySessions", {
            count: totals.count,
            size:  _humanBytes(totals.size)
          })
        : "";
    }
    if (btnOld) btnOld.disabled = sessions.length === 0;
    if (btnAll) btnAll.disabled = sessions.length === 0;
    if (filterBar) filterBar.style.display = "";
    _refreshProjectOptions();

    if (sessions.length === 0) {
      list.innerHTML = `<div class="trash-empty">${_t("trash.noSessionTrash")}</div>`;
      return;
    }

    list.innerHTML = "";
    sessions.forEach(s => list.appendChild(_buildSessionCard(s)));
  }

  function _buildSessionCard(session) {
    const card = document.createElement("div");
    card.className = "trash-session-card";
    card.dataset.sessionId = session.session_id;

    const name      = session.name || session.session_id || "";
    const taskCount = session.total_tasks || 0;
    const sizeStr   = _humanBytes(session.file_size || 0);
    const whenStr   = _humanTime(session.deleted_at || session.created_at);
    const taskLabel = I18n.t("trash.sessionTasks", { n: taskCount });

    // Project badge — resolve name + color from Projects store if available
    let projectBadgeHtml = "";
    if (session.project_id && typeof Projects !== "undefined") {
      const proj = Projects.find(session.project_id);
      if (proj) {
        const projName  = escapeHtml(proj.name || "");
        const dotColor  = proj.color ? `style="background:${escapeHtml(proj.color)}"` : "";
        projectBadgeHtml = `
          <span class="trash-session-project-badge" title="${projName}">
            <span class="trash-session-project-dot" ${dotColor}></span>
            ${projName}
          </span>`;
      }
    }

    card.innerHTML = `
      <div class="trash-session-card-info">
        <div class="trash-session-card-name" title="${escapeHtml(name)}">${escapeHtml(name)}</div>
        <div class="trash-session-card-id" title="${escapeHtml(session.session_id || '')}">${escapeHtml(session.session_id || '')}</div>
        <div class="trash-session-card-meta">
          <span>${escapeHtml(taskLabel)}</span>
          <span>${sizeStr}</span>
          <span title="${escapeHtml(session.deleted_at || session.created_at || '')}">${escapeHtml(whenStr)}</span>
          ${projectBadgeHtml}
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
      _deleteSession(session));

    return card;
  }

  // ── File actions ─────────────────────────────────────────────────────

  async function _restoreFile(file, card) {
    const btn = card.querySelector(".btn-trash-restore");
    btn.disabled = true;
    const res = await Trash.restoreFile(file);
    if (!res.ok) {
      Modal.toast(I18n.t("trash.restoreFail", { msg: res.error }), "error");
      btn.disabled = false;
    } else {
      Modal.toast(I18n.t("trash.restoreOk", {
        path: (file.original_path || "").split("/").pop()
      }), "success");
    }
  }

  async function _deleteFile(file) {
    const basename = (file.original_path || "").split("/").pop() || file.original_path;
    const confirmed = await Modal.confirm(
      I18n.t("trash.confirmDeleteOne", { name: basename })
    );
    if (!confirmed) return;
    const res = await Trash.deleteFile(file);
    if (!res.ok) Modal.toast(I18n.t("trash.deleteFail", { msg: res.error }), "error");
  }

  // ── Session actions ──────────────────────────────────────────────────

  async function _restoreSession(session, card) {
    const btn = card.querySelector(".btn-trash-session-restore");
    btn.disabled = true;
    const res = await Trash.restoreSession(session);
    if (!res.ok) {
      Modal.toast(I18n.t("trash.sessionRestoreFail", { msg: res.error }), "error");
      btn.disabled = false;
      return;
    }
    const restored = res.session;
    Modal.toast(I18n.t("trash.sessionRestoreOk"), "success", restored && restored.id ? {
      action: {
        label:   I18n.t("trash.sessionRestoreOkAction"),
        onClick: () => Sessions.select(restored.id)
      }
    } : {});
  }

  async function _deleteSession(session) {
    const name = session.name || (session.session_id || "").slice(0, 8);
    const confirmed = await Modal.confirm(
      I18n.t("trash.confirmDeleteSession", { name: name })
    );
    if (!confirmed) return;
    const res = await Trash.deleteSession(session);
    if (!res.ok) Modal.toast(I18n.t("trash.deleteFail", { msg: res.error }), "error");
  }

  // ── Bulk actions ─────────────────────────────────────────────────────

  async function _emptyBulk(daysOld, confirmKey) {
    const isSession  = _activeTab === "session-trash";
    const items      = isSession ? Trash.state.sessions : Trash.state.files;
    const matchCount = Trash.countMatching(items, daysOld);

    if (matchCount === 0) {
      Modal.toast(_t(daysOld > 0 ? "trash.nothingOld" : "trash.empty"), "info");
      return;
    }

    const confirmed = await Modal.confirm(I18n.t(confirmKey, { count: matchCount }));
    if (!confirmed) return;

    if (isSession) {
      const res = await Trash.emptySessionsBulk(daysOld);
      if (!res.ok) { Modal.toast(I18n.t("trash.cleanFail", { msg: res.error }), "error"); return; }
      Modal.toast(I18n.t("trash.sessionsCleaned", { count: res.deleted_count }), "success");
    } else {
      const res = await Trash.emptyFilesBulk(daysOld);
      if (!res.ok) { Modal.toast(I18n.t("trash.cleanFail", { msg: res.error }), "error"); return; }
      Modal.toast(I18n.t("trash.emptied", {
        count: res.deleted_count,
        size:  _humanBytes(res.freed_size)
      }), "success");
    }
  }

  async function _emptyOrphans() {
    const orphans = Trash.orphans();
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
      const r = await Trash.deleteOneFileRaw(f);
      if (r.ok) { deleted += 1; freed += r.freed_size; }
      else        failed  += 1;
    }
    Modal.toast(I18n.t("trash.orphansCleaned", {
      count:  deleted,
      size:   _humanBytes(freed),
      failed: failed
    }), failed > 0 ? "warning" : "success");
    await Trash.loadFiles();
  }

  // ── Event wiring ─────────────────────────────────────────────────────

  function _wire() {
    if (_wired) return;
    _wired = true;

    const tabFile    = $("tab-file-trash");
    const tabSession = $("tab-session-trash");
    if (tabFile)    tabFile.addEventListener("click",    () => _switchTab("file-trash"));
    if (tabSession) tabSession.addEventListener("click", () => _switchTab("session-trash"));

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

    // Filter chips
    document.querySelectorAll(".trash-filter-chip").forEach(chip => {
      chip.addEventListener("click", () => {
        const val = chip.dataset.filter;
        Trash.setFilterSource(val);
        document.querySelectorAll(".trash-filter-chip").forEach(c => c.classList.toggle("active", c.dataset.filter === val));
      });
    });

    // Project filter select
    const projWrap = $("trash-filter-project");
    if (projWrap && window.CustomSelect) {
      const dropdown = projWrap.querySelector(".custom-select-dropdown");
      if (!dropdown.__customSelect) {
        window.CustomSelect.init({
          trigger: projWrap.querySelector(".custom-select-trigger"),
          dropdown: dropdown,
          onSelect: (value) => Trash.setFilterProject(value || null)
        });
      }
    }
  }

  function _subscribe() {
    Trash.on("trash:filesLoading",    _renderSkeleton);
    Trash.on("trash:sessionsLoading", _renderSkeleton);
    Trash.on("trash:filesChanged",    _renderFiles);
    Trash.on("trash:sessionsChanged", _renderSessions);
    Trash.on("trash:filesError", (e) => {
      const list = $("trash-list");
      if (list) list.innerHTML = `<div class="trash-empty trash-error">${escapeHtml(e.message)}</div>`;
    });
    Trash.on("trash:sessionsError", (e) => {
      const list = $("trash-session-list");
      if (list) list.innerHTML = `<div class="trash-empty trash-error">${escapeHtml(e.message)}</div>`;
    });
  }

  const viewApi = {
    onPanelShow() {
      _wire();
      _activeTab = null;
      _switchTab("file-trash");
    }
  };

  return { init: _subscribe, api: viewApi };
})();

Object.assign(Trash, TrashView.api);
TrashView.init();
