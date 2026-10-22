// ── Archive · view — archived-chat rendering, filters, DOM wiring ─────────
//
// Renders the archive list grouped by project, drives the toolbar (search,
// project / type filters, delete-all, load more) and all confirm/toast dialogs.
// Reads through ArchiveStore.state and mutates only via store actions.
//
// Augments the `Archive` facade with onPanelShow.
//
// Depends on: ArchiveStore, Projects, I18n, Modal.
// ───────────────────────────────────────────────────────────────────────────

const ArchiveView = (() => {
  let _wired         = false;
  let _query         = "";
  let _filterProject = null;   // null = every project (including "no project")
  let _filterType    = "";     // "" = every source

  function $(id) { return document.getElementById(id); }

  function escapeHtml(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function _t(key) {
    return I18n.t ? I18n.t(key) : key;
  }

  function _humanTime(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (isNaN(d.getTime())) return iso;
    const ms    = Date.now() - d;
    const mins  = Math.floor(ms / 60000);
    const hours = Math.floor(ms / 3600000);
    const days  = Math.floor(ms / 86400000);
    if (mins < 1)   return I18n.t("time.justNow");
    if (mins < 60)  return I18n.t("time.minsAgo",  { n: mins });
    if (hours < 24) return I18n.t("time.hoursAgo", { n: hours });
    if (days < 7)   return I18n.t("time.daysAgo",  { n: days });
    return d.toLocaleDateString();
  }

  // ── Filtering & grouping ─────────────────────────────────────────────

  function _visibleItems() {
    const q = _query.trim().toLowerCase();
    return Archive.state.items.filter(s => {
      if (_filterProject !== null && String(s.project_id ?? "") !== _filterProject) return false;
      if (_filterType && (s.source || "manual") !== _filterType) return false;
      if (q) {
        const name = (s.name || "").toLowerCase();
        const id   = (s.id || s.session_id || "").toLowerCase();
        if (!name.includes(q) && !id.includes(q)) return false;
      }
      return true;
    });
  }

  // Projects keep their sidebar identity (name + colour); everything without a
  // project falls into one trailing bucket, which is what the API returns too.
  function _groups(items) {
    const known = (typeof Projects !== "undefined" && Projects.all) ? Projects.all() : [];
    const byId  = new Map();
    const order = [];

    items.forEach(s => {
      const key = String(s.project_id ?? "");
      if (!byId.has(key)) {
        const project = key && known.find(p => String(p.id) === key);
        byId.set(key, {
          key,
          name:  project ? (project.name || key) : (key ? key : _t("archive.groupNoProject")),
          color: project ? project.color : null,
          items: [],
        });
        order.push(key);
      }
      byId.get(key).items.push(s);
    });

    // Named projects first (in sidebar order), "no project" last.
    return order
      .sort((a, b) => (a === "" ? 1 : b === "" ? -1 : 0))
      .map(k => byId.get(k));
  }

  function _isNarrowed() {
    return _query.trim() !== "" || _filterProject !== null || _filterType !== "";
  }

  // ── Rendering ────────────────────────────────────────────────────────

  function _renderSkeleton() {
    const list = $("archive-list");
    if (!list) return;
    list.innerHTML = Array.from({ length: 3 }, () => `
      <div class="trash-session-skeleton">
        <div class="trash-session-skeleton-info">
          <div class="skel" style="width:40%;height:10px"></div>
          <div class="skel" style="width:65%;height:9px"></div>
        </div>
      </div>`).join("");
  }

  // Appending a page keeps the rows on screen, so the button carries the progress
  // itself — same "Loading…" swap the session list and extensions page use.
  function _setMoreLoading(loading) {
    const btn = $("btn-archive-load-more");
    if (!btn) return;
    btn.disabled = loading;
    btn.textContent = loading ? _t("archive.loadingMore") : _t("archive.loadMore");
  }

  function _renderError(message) {
    const list = $("archive-list");
    if (!list) return;
    _setMoreLoading(false);
    list.innerHTML = `<div class="archive-empty">${escapeHtml(message)}</div>`;
  }

  function _buildRow(session) {
    const id    = session.id || session.session_id || "";
    const name  = session.name || id.slice(0, 8);
    const tasks = I18n.t("trash.sessionTasks", { n: session.total_tasks || 0 });
    const when  = _humanTime(session.archived_at || session.updated_at || session.created_at);

    const row = document.createElement("div");
    row.className = "trash-session-card";
    row.dataset.sessionId = id;
    row.innerHTML = `
      <div class="trash-session-card-info">
        <div class="trash-session-card-name" title="${escapeHtml(name)}">${escapeHtml(name)}</div>
        <div class="trash-session-card-meta">
          ${session.model ? `<span>${escapeHtml(session.model)}</span>` : ""}
          <span>${escapeHtml(tasks)}</span>
          ${when ? `<span title="${escapeHtml(session.archived_at || "")}">${escapeHtml(when)}</span>` : ""}
        </div>
      </div>
      <div class="trash-session-card-actions">
        <button class="btn-archive-unarchive" data-action="unarchive">${escapeHtml(_t("archive.unarchive"))}</button>
        <button class="btn-archive-delete" data-action="delete"
                title="${escapeHtml(_t("archive.deleteOne"))}" aria-label="${escapeHtml(_t("archive.deleteOne"))}">
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="3 6 5 6 21 6"/>
            <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>
            <path d="M10 11v6"/><path d="M14 11v6"/>
          </svg>
        </button>
      </div>`;
    return row;
  }

  function _render() {
    const list    = $("archive-list");
    const summary = $("archive-summary");
    const btnAll  = $("btn-archive-delete-all");
    const btnMore = $("btn-archive-load-more");
    if (!list) return;

    _refreshProjectOptions();

    const items = _visibleItems();
    const narrowed = _isNarrowed();
    if (summary) {
      // With a filter or a search on, the number describes what the toolbar is
      // showing. Without one it describes the whole archive, which can be
      // bigger than the loaded page.
      const n = narrowed ? items.length : (Archive.state.archivedTotal || items.length);
      summary.textContent = n ? I18n.t("archive.summary", { n }) : "";
    }
    if (btnAll)  btnAll.disabled = (narrowed ? items.length : Archive.state.archivedTotal) === 0;
    if (btnMore) {
      btnMore.style.display = Archive.state.hasMore ? "" : "none";
      _setMoreLoading(false);
    }

    if (items.length === 0) {
      list.innerHTML = `<div class="archive-empty">${escapeHtml(
        Archive.state.archivedTotal === 0 ? _t("archive.empty") : _t("archive.noMatch"))}</div>`;
      return;
    }

    list.innerHTML = "";
    _groups(items).forEach(group => {
      const section = document.createElement("section");
      section.className = "archive-group";

      const header = document.createElement("div");
      header.className = "archive-group-header";
      header.innerHTML = group.color
        ? `<span class="archive-group-dot" style="background:${escapeHtml(group.color)}"></span>`
        : `<svg class="archive-group-icon" xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
             <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
           </svg>`;
      const label = document.createElement("span");
      label.textContent = group.name;
      const count = document.createElement("span");
      count.className = "archive-group-count";
      count.textContent = String(group.items.length);
      header.append(label, count);
      section.appendChild(header);

      const wrap = document.createElement("div");
      wrap.className = "archive-group-items";
      group.items.forEach(s => wrap.appendChild(_buildRow(s)));
      section.appendChild(wrap);

      list.appendChild(section);
    });
  }

  // ── Project / type filter selects ────────────────────────────────────

  function _refreshProjectOptions() {
    const wrap = $("archive-filter-project");
    if (!wrap) return;
    const dropdown = wrap.querySelector(".custom-select-dropdown");
    if (!dropdown) return;
    const ctl = dropdown.__customSelect;

    const projects = (typeof Projects !== "undefined" && Projects.all) ? Projects.all() : [];
    const allLabel = _t("archive.filterAllProjects");

    dropdown.innerHTML = "";
    const all = document.createElement("div");
    all.className = "custom-select-option";
    all.dataset.value = "";
    all.dataset.label = allLabel;
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
      const restore = (_filterProject !== null && projects.some(p => String(p.id) === _filterProject))
        ? _filterProject : "";
      ctl.setValue(restore);
    }
  }

  function _buildTypeOptions() {
    const wrap = $("archive-filter-type");
    if (!wrap) return;
    const dropdown = wrap.querySelector(".custom-select-dropdown");
    if (!dropdown || dropdown.dataset.built === "1") return;

    const opts = [
      { value: "",        label: _t("archive.filterAllTypes") },
      { value: "manual",  label: _t("archive.filterRegular") },
      { value: "cron",    label: _t("archive.filterCron") },
      { value: "channel", label: _t("archive.filterChannel") },
    ];
    dropdown.innerHTML = "";
    opts.forEach(o => {
      const el = document.createElement("div");
      el.className = "custom-select-option";
      el.dataset.value = o.value;
      el.textContent = o.label;
      dropdown.appendChild(el);
    });
    dropdown.dataset.built = "1";
  }

  // ── Actions ──────────────────────────────────────────────────────────

  async function _unarchive(session) {
    const res = await Archive.unarchive(session);
    if (!res.ok) {
      Modal.toast(I18n.t("archive.unarchiveFail", { msg: res.error }), "error");
      return;
    }
    // The row is gone from this page by now, so the toast is the only way back
    // to the chat the user just restored — same shortcut the recycle bin offers.
    const id = session.id || session.session_id;
    Modal.toast(I18n.t("archive.unarchived", { name: session.name || "" }), "success",
      id ? { action: { label: _t("archive.unarchivedAction"), onClick: () => Sessions.select(id) } } : {});
  }

  async function _deleteOne(session) {
    const name = session.name || (session.id || "").slice(0, 8);
    const confirmed = await Modal.confirm(I18n.t("archive.confirmDelete", { name }));
    if (!confirmed) return;
    const res = await Archive.remove(session);
    if (!res.ok) Modal.toast(I18n.t("archive.deleteFail", { msg: res.error }), "error");
    else         Modal.toast(I18n.t("archive.deleted", { name }), "success");
  }

  async function _deleteAll() {
    // What the toolbar shows is what goes: the visible rows when search or a
    // filter is on, otherwise the whole archive, whose size only the server
    // knows (`archivedTotal`) because the list is paged.
    const selection = _isNarrowed() ? _visibleItems() : null;
    const count     = selection ? selection.length : Archive.state.archivedTotal;
    if (count === 0) {
      Modal.toast(_t(selection ? "archive.noMatch" : "archive.empty"), "info");
      return;
    }
    const confirmed = await Modal.confirm(I18n.t("archive.confirmDeleteAll", { count }));
    if (!confirmed) return;
    const res = await Archive.deleteMany(selection);
    if (!res.ok) Modal.toast(I18n.t("archive.deleteFail", { msg: res.error }), "error");
    else         Modal.toast(I18n.t("archive.deletedAll", { count: res.deleted_count }), "success");
  }

  // ── Event wiring ─────────────────────────────────────────────────────

  function _wire() {
    if (_wired) return;
    _wired = true;

    const search = $("archive-search");
    if (search) {
      let timer = null;
      search.addEventListener("input", () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          _query = search.value || "";
          _render();
        }, 150);
      });
    }

    _buildTypeOptions();

    const projWrap = $("archive-filter-project");
    if (projWrap && window.CustomSelect) {
      const dropdown = projWrap.querySelector(".custom-select-dropdown");
      if (!dropdown.__customSelect) {
        window.CustomSelect.init({
          trigger: projWrap.querySelector(".custom-select-trigger"),
          dropdown: dropdown,
          onSelect: (value) => {
            _filterProject = value ? String(value) : null;
            _render();
          },
        });
      }
    }

    const typeWrap = $("archive-filter-type");
    if (typeWrap && window.CustomSelect) {
      const dropdown = typeWrap.querySelector(".custom-select-dropdown");
      if (!dropdown.__customSelect) {
        window.CustomSelect.init({
          trigger: typeWrap.querySelector(".custom-select-trigger"),
          dropdown: dropdown,
          onSelect: (value) => {
            _filterType = value || "";
            _render();
          },
        });
      }
    }

    const btnAll = $("btn-archive-delete-all");
    if (btnAll) btnAll.addEventListener("click", _deleteAll);

    const btnMore = $("btn-archive-load-more");
    if (btnMore) btnMore.addEventListener("click", () => Archive.load({ reset: false }));

    const list = $("archive-list");
    if (list) {
      list.addEventListener("click", (e) => {
        const btn = e.target.closest("button[data-action]");
        if (!btn) return;
        const row = btn.closest("[data-session-id]");
        if (!row) return;
        const session = Archive.state.items.find(s => (s.id || s.session_id) === row.dataset.sessionId);
        if (!session) return;
        if (btn.dataset.action === "unarchive") _unarchive(session);
        if (btn.dataset.action === "delete")    _deleteOne(session);
      });
    }
  }

  function _subscribe() {
    Archive.on("archive:loading", (payload) => {
      if (payload && payload.append) _setMoreLoading(true);
      else _renderSkeleton();
    });
    Archive.on("archive:changed", _render);
    Archive.on("archive:error", (e) => _renderError(e.message));
  }

  const viewApi = {
    onPanelShow() {
      _wire();
      Archive.load({ reset: true });
    },
  };

  return { init: _subscribe, api: viewApi };
})();

Object.assign(Archive, ArchiveView.api);
ArchiveView.init();
