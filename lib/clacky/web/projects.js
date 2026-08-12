// ── Projects — project state, CRUD, sidebar rendering ─────────────────────
//
// Responsibilities:
//   - Maintain the canonical projects list (received via session_list WS event)
//   - CRUD: create / update / delete projects via REST API
//   - Move sessions in / out of projects via PATCH /api/sessions/:id/project
//   - Render the #project-section sidebar area (two modes: grouped / flat)
//
// Depends on: Sessions (sessions.js), global $ / escapeHtml helpers
// ─────────────────────────────────────────────────────────────────────────────

const Projects = (() => {
  let _projects = [];  // [{ id, name, description, color, created_at, updated_at }]

  // "grouped" (default) — each project is a collapsible row
  // "flat"    — all project-sessions listed in one flat list with project tag
  let _viewMode  = "grouped";

  // "recent" (default) — sort by updated_at desc
  // "priority" — oldest-created project first
  const _LS_SORT_KEY            = "clacky_projects_sort_mode";
  const _LS_COLLAPSED_KEY       = "clacky_projects_collapsed";
  const _LS_SECTION_COLLAPSE_KEY = "clacky_projects_section_collapsed";
  let _sortMode         = localStorage.getItem(_LS_SORT_KEY) || "recent";
  let _sectionCollapsed = localStorage.getItem(_LS_SECTION_COLLAPSE_KEY) === "1";

  // Track which project groups are collapsed: Set of project IDs (persisted to localStorage)
  const _collapsed = new Set(
    JSON.parse(localStorage.getItem(_LS_COLLAPSED_KEY) || "[]")
  );

  function _saveCollapsed() {
    localStorage.setItem(_LS_COLLAPSED_KEY, JSON.stringify([..._collapsed]));
  }

  /** Return a sorted copy of _projects according to _sortMode. */
  function _sortProjects(projects) {
    return [...projects].sort((a, b) => {
      if (_sortMode === "priority") {
        // Oldest project first (by created_at)
        return (a.created_at || "").localeCompare(b.created_at || "");
      }
      // Default "recent": most recently updated first
      const ta = a.updated_at || a.created_at || "";
      const tb = b.updated_at || b.created_at || "";
      return tb.localeCompare(ta);
    });
  }

  // ── Shared icon helper ────────────────────────────────────────────────────
  const _FOLDER_PATH      = `<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>`;
  const _FOLDER_OPEN_PATH = `<path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/>`;

  const _ICON_PATHS = {
    folder: _FOLDER_PATH,
    code:    `<polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>`,
    book:    `<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/>`,
    globe:   `<circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/>`,
    zap:     `<polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/>`,
    star:    `<polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/>`,
    heart:   `<path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/>`,
    tool:     `<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>`,
    database: `<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/>`,
    image:   `<rect x="3" y="3" width="16" height="16" rx="2" ry="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/>`,
    music:   `<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>`,
    coffee:  `<path d="M18 8h1a4 4 0 0 1 0 8h-1"/><path d="M2 8h16v9a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V8z"/><line x1="6" y1="1" x2="6" y2="4"/><line x1="10" y1="1" x2="10" y2="4"/><line x1="14" y1="1" x2="14" y2="4"/>`,
    briefcase: `<rect x="2" y="7" width="20" height="14" rx="2" ry="2"/><path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/>`,
    flask:   `<path d="M9 3h6"/><path d="M10 3v6l-4 8a1 1 0 0 0 .9 1.5h10.2a1 1 0 0 0 .9-1.5L14 9V3"/>`,
    chart:   `<line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/>`,
    rocket:  `<path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z"/><path d="m12 15-3-3a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.35 22.35 0 0 1-4 2z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0"/><path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/>`,
    dollar:  `<line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>`,
    cpu:     `<rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><line x1="9" y1="1" x2="9" y2="4"/><line x1="15" y1="1" x2="15" y2="4"/><line x1="9" y1="20" x2="9" y2="23"/><line x1="15" y1="20" x2="15" y2="23"/><line x1="20" y1="9" x2="23" y2="9"/><line x1="20" y1="14" x2="23" y2="14"/><line x1="1" y1="9" x2="4" y2="9"/><line x1="1" y1="14" x2="4" y2="14"/>`,
    paint:   `<circle cx="13.5" cy="6.5" r=".5"/><circle cx="17.5" cy="10.5" r=".5"/><circle cx="8.5" cy="7.5" r=".5"/><circle cx="6.5" cy="12.5" r=".5"/><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10c.926 0 1.648-.746 1.648-1.688 0-.437-.18-.835-.437-1.125-.29-.289-.438-.652-.438-1.125a1.64 1.64 0 0 1 1.668-1.668h1.996c3.051 0 5.555-2.503 5.555-5.554C21.965 6.012 17.461 2 12 2z"/>`,
    leaf:    `<path d="M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.48 19 2c1 2 2 4.18 2 8 0 5.5-4.78 10-10 10z"/><path d="M2 21c0-3 1.85-5.36 5.08-6C9.5 14.52 12 13 13 12"/>`,
    trophy:  `<polyline points="8 21 8 14 4 9 4 4 20 4 20 9 16 14 16 21"/><line x1="8" y1="21" x2="16" y2="21"/><path d="M4 9H2a1 1 0 0 0-1 1 6 6 0 0 0 6 6"/><path d="M20 9h2a1 1 0 0 1 1 1 6 6 0 0 1-6 6"/>`,
    smile:   `<circle cx="12" cy="12" r="10"/><path d="M8 14s1.5 2 4 2 4-2 4-2"/><line x1="9" y1="9" x2="9.01" y2="9"/><line x1="15" y1="9" x2="15.01" y2="9"/>`,
    map:     `<polygon points="1 6 1 22 8 18 16 22 23 18 23 2 16 6 8 2 1 6"/><line x1="8" y1="2" x2="8" y2="18"/><line x1="16" y1="6" x2="16" y2="22"/>`,
    flower:  `<path d="M12 7.5a4.5 4.5 0 1 1 4.5 4.5M12 7.5A4.5 4.5 0 1 0 7.5 12M12 7.5V9m-4.5 3a4.5 4.5 0 1 0 4.5 4.5M7.5 12H9m7.5 0a4.5 4.5 0 1 1-4.5 4.5m4.5-4.5H15m-3 4.5V15"/><circle cx="12" cy="12" r="3"/>`,
  };

  function _getIconSvg(iconName, size = 15.5) {
    if (iconName === "folder-open") {
      return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${_FOLDER_OPEN_PATH}</svg>`;
    }
    const inner = _ICON_PATHS[iconName] || _FOLDER_PATH;
    return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>`;
  }

  // ── State accessors ────────────────────────────────────────────────────────

  function all()    { return _projects; }

  function find(id) { return id != null ? (_projects.find(p => p.id === String(id)) || null) : null; }

  /** Called by ws-dispatcher when session_list arrives — replaces full list. */
  function setAll(list) {
    _projects = Array.isArray(list) ? [...list] : [];
  }

  // ── REST API ───────────────────────────────────────────────────────────────

  /** POST /api/projects — create a project. Returns { project } or throws. */
  async function create({ name, description = null, color = null, icon = null, working_dir = null } = {}) {
    const res  = await fetch("/api/projects", {
      method:  "POST",
      headers: { "Content-Type": "application/json" },
      body:    JSON.stringify({ name, description, color, icon, working_dir }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || "Failed to create project");

    const project = data.project;
    _projects.push(project);
    return project;
  }

  /** PATCH /api/projects/:id — update a project's name / description / color. */
  async function update(id, fields = {}) {
    const res  = await fetch(`/api/projects/${id}`, {
      method:  "PATCH",
      headers: { "Content-Type": "application/json" },
      body:    JSON.stringify(fields),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || "Failed to update project");

    const updated = data.project;
    const idx     = _projects.findIndex(p => p.id === id);
    if (idx !== -1) _projects[idx] = updated;
    return updated;
  }

  /**
   * DELETE /api/projects/:id — delete a project and all its sessions.
   * The server soft-deletes the sessions; we remove them from local state
   * and trigger a re-render.
   */
  async function remove(id) {
    const res  = await fetch(`/api/projects/${id}`, { method: "DELETE" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || "Failed to delete project");

    _projects = _projects.filter(p => p.id !== id);
    _collapsed.delete(id);
    _saveCollapsed();
    // Remove all sessions belonging to this project from local memory,
    // then re-render both sections in one pass.
    Sessions.removeByProjectId(id);
    Sessions.renderList();
    renderSection();
  }

  /**
   * PATCH /api/sessions/:sessionId/project — assign or remove a session's project.
   * Pass projectId=null to remove from project.
   */
  async function moveSession(sessionId, projectId) {
    const res  = await fetch(`/api/sessions/${sessionId}/project`, {
      method:  "PATCH",
      headers: { "Content-Type": "application/json" },
      body:    JSON.stringify({ project_id: projectId }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || "Failed to move session");

    Sessions.patch(sessionId, { project_id: projectId });
    Sessions.renderList();
    renderSection();
  }

  /**
   * Render the #project-list container.
   * Reads _viewMode to decide between "grouped" and "flat" layout.
   * Called by ws-dispatcher after every list/update/delete event.
   */
  function renderSection() {
    const list = document.getElementById("project-list");
    if (!list) return;
    list.innerHTML = "";

    if (_projects.length === 0) {
      // Show an empty hint so the section doesn't look broken
      const hint = document.createElement("div");
      hint.className = "project-empty-hint";
      hint.textContent = I18n.t("projects.emptyHint", "No projects yet");
      list.appendChild(hint);
      return;
    }

    if (_viewMode === "flat") {
      _renderFlat(list);
    } else {
      _renderGrouped(list);
    }
  }

  /** Flat mode: all project-sessions in one list, each tagged with project name. */
  function _renderFlat(container) {
    const sortedProjects = _sortProjects(_projects);
    const allSessions = Sessions.all;
    const projectSessions = allSessions
      .filter(s => s.project_id)
      .sort((a, b) => {
        // Primary: group by project, ordered by sortedProjects
        if (a.project_id !== b.project_id) {
          const ai = sortedProjects.findIndex(p => p.id === a.project_id);
          const bi = sortedProjects.findIndex(p => p.id === b.project_id);
          return ai - bi;
        }
        // Secondary: within project, newest session first
        const ta = a.updated_at || a.created_at || "";
        const tb = b.updated_at || b.created_at || "";
        return tb.localeCompare(ta);
      });

    // Render with project tag only on first session of each project group
    let lastProjectId = null;
    projectSessions.forEach(s => {
      // Show project tag header when project changes
      if (s.project_id !== lastProjectId) {
        lastProjectId = s.project_id;
        const project = find(s.project_id);
        if (project) {
          const tag = document.createElement("div");
          tag.className = "project-session-tag";
          tag.textContent = project.name;
          tag.style.setProperty("--project-color", project.color || "var(--color-accent-primary)");
          container.appendChild(tag);
        }
      }

      Sessions.renderSessionItem(container, s);
    });
  }

  /** Grouped mode: each project is a collapsible row with indented sessions. */
  function _renderGrouped(container) {
    const sortedProjects = _sortProjects(_projects);

    sortedProjects.forEach(project => {
      const sessions = Sessions.all
        .filter(s => s.project_id === project.id)
        .sort((a, b) => {
          // Sessions within a project: always newest first
          const ta = a.updated_at || a.created_at || "";
          const tb = b.updated_at || b.created_at || "";
          return tb.localeCompare(ta);
        });

      const isCollapsed = _collapsed.has(project.id);

      // ── Project header row ──────────────────────────────────────────
      const header = document.createElement("div");
      header.className = "project-group-header" + (isCollapsed ? " collapsed" : "");
      header.dataset.projectId = project.id;

      // Icon or color dot — use shared _getIconSvg helper (size=14)
      // When icon is "folder", switch to folder-open when the group is expanded
      const color = project.color || null;
      const iconName = project.icon || "folder";
      const displayIcon = (iconName === "folder" && !isCollapsed) ? "folder-open" : iconName;
      const iconSvg  = _getIconSvg(displayIcon);

      const dot = document.createElement("span");
      dot.className = "project-icon-badge";
      if (color) dot.style.color = color;
      dot.innerHTML = iconSvg;
      header.appendChild(dot);

      // Project name
      const nameEl = document.createElement("span");
      nameEl.className = "project-name";
      nameEl.textContent = project.name;
      header.appendChild(nameEl);

      // New session button (✎)
      const newSessionBtn = document.createElement("button");
      newSessionBtn.className = "project-actions-btn project-new-session-btn";
      newSessionBtn.title = "New session";
      newSessionBtn.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M7.9 20A9 9 0 1 0 4 16.1L2 22z"/>
        <path d="M12 8v8"/>
        <path d="M8 12h8"/>
      </svg>`;
      newSessionBtn.addEventListener("click", e => {
        e.stopPropagation();
        const dir = project.working_dir || (NewSessionStore.state && NewSessionStore.state.defaultDir) || "";
        NewSessionStore.updateAdvanced({ projectId: project.id, workingDir: dir });
        Router.navigate("welcome");
      });
      // Actions button (⋯)
      const actionsBtn = document.createElement("button");
      actionsBtn.className = "project-actions-btn";
      actionsBtn.title = "Project options";
      actionsBtn.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
        <circle cx="5"  cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/>
      </svg>`;
      actionsBtn.addEventListener("click", e => {
        e.stopPropagation();
        _showProjectMenu(project.id, actionsBtn);
      });
      header.appendChild(actionsBtn);
      header.appendChild(newSessionBtn);

      // Toggle collapse on header click — in-place DOM toggle, no full re-render
      header.addEventListener("click", () => {
        const nowCollapsed = _collapsed.has(project.id);
        if (nowCollapsed) {
          _collapsed.delete(project.id);
        } else {
          _collapsed.add(project.id);
        }
        const willCollapse = !nowCollapsed;
        _saveCollapsed();

        // Toggle header class
        header.classList.toggle("collapsed", willCollapse);

        // Toggle folder icon in-place
        const iconName = project.icon || "folder";
        if (iconName === "folder") {
          const dot = header.querySelector(".project-icon-badge");
          if (dot) dot.innerHTML = _getIconSvg(willCollapse ? "folder" : "folder-open");
        }

        // Toggle session group visibility
        const sessionGroup = header.nextElementSibling;
        if (sessionGroup && sessionGroup.classList.contains("project-session-group")) {
          sessionGroup.style.display = willCollapse ? "none" : "";
        }
      });

      container.appendChild(header);

      // ── Session items — always in DOM, hidden when collapsed ────────
      const sessionGroup = document.createElement("div");
      sessionGroup.className = "project-session-group";
      if (isCollapsed) sessionGroup.style.display = "none";

      if (sessions.length === 0) {
        const empty = document.createElement("div");
        empty.className = "project-sessions-empty";
        empty.textContent = I18n.t("projects.noSessions", "No sessions");
        sessionGroup.appendChild(empty);
      } else {
        sessions.forEach(s => Sessions.renderSessionItem(sessionGroup, s));
      }

      container.appendChild(sessionGroup);
    });
  }

  

  /** Show a small context menu for project actions (edit / delete). */
  function _showProjectMenu(projectId, anchor) {
    // Remove any existing project menu
    document.querySelectorAll(".project-actions-menu").forEach(m => m.remove());

    const menu = document.createElement("div");
    menu.className = "project-actions-menu";

    const addItem = (labelKey, defaultLabel, danger, onClick) => {
      const item = document.createElement("button");
      item.className = "project-actions-menu-item" + (danger ? " danger" : "");
      item.textContent = I18n.t(labelKey, defaultLabel);
      item.addEventListener("click", e => {
        e.stopPropagation();
        menu.remove();
        onClick();
      });
      menu.appendChild(item);
    };

    addItem("projects.menu.edit", "Edit Project", false, () => promptEdit(projectId));
    addItem("projects.menu.deleteSessions", "Delete Sessions", false, () => promptDeleteSessions(projectId));
    addItem("projects.menu.delete", "Delete",  true,  () => promptDelete(projectId));

    // Position near anchor
    const rect = anchor.getBoundingClientRect();
    menu.style.position = "fixed";
    menu.style.top  = `${rect.bottom + 4}px`;
    menu.style.left = `${rect.left}px`;
    document.body.appendChild(menu);

    // Close on click outside
    const dismiss = e => {
      if (!menu.contains(e.target)) {
        menu.remove();
        document.removeEventListener("mousedown", dismiss, true);
      }
    };
    document.addEventListener("mousedown", dismiss, true);
  }

  /** Show the organize menu (toggle view mode + sort mode). */
  function _showOrganizeMenu(anchor) {
    document.querySelectorAll(".project-organize-menu").forEach(m => m.remove());

    const menu = document.createElement("div");
    menu.className = "project-organize-menu";

    // ── View mode section ──────────────────────────────────────────────
    const viewSection = document.createElement("div");
    viewSection.className = "project-organize-section";

    const addViewItem = (labelKey, defaultLabel, mode) => {
      const item = document.createElement("button");
      item.className = "project-organize-item" + (_viewMode === mode ? " active" : "");
      item.textContent = I18n.t(labelKey, defaultLabel);
      item.addEventListener("click", e => {
        e.stopPropagation();
        menu.remove();
        _viewMode = mode;
        renderSection();
      });
      viewSection.appendChild(item);
    };

    addViewItem("projects.organize.grouped", "By Project",    "grouped");
    addViewItem("projects.organize.flat",    "In a flat list", "flat");
    menu.appendChild(viewSection);

    // ── Divider ────────────────────────────────────────────────────────
    const divider = document.createElement("div");
    divider.className = "project-organize-divider";
    menu.appendChild(divider);

    // ── Sort mode section ──────────────────────────────────────────────
    const sortLabel = document.createElement("div");
    sortLabel.className = "project-organize-section-label";
    sortLabel.textContent = I18n.t("projects.organize.sortLabel", "Sort by");
    menu.appendChild(sortLabel);

    const sortSection = document.createElement("div");
    sortSection.className = "project-organize-section";

    const addSortItem = (labelKey, defaultLabel, mode) => {
      const item = document.createElement("button");
      item.className = "project-organize-item" + (_sortMode === mode ? " active" : "");
      item.textContent = I18n.t(labelKey, defaultLabel);
      item.addEventListener("click", e => {
        e.stopPropagation();
        menu.remove();
        _sortMode = mode;
        localStorage.setItem(_LS_SORT_KEY, mode);
        renderSection();
      });
      sortSection.appendChild(item);
    };

    addSortItem("projects.organize.sortPriority", "Priority",      "priority");
    addSortItem("projects.organize.sortRecent",   "Last updated",  "recent");
    menu.appendChild(sortSection);

    const rect = anchor.getBoundingClientRect();
    menu.style.position = "fixed";
    menu.style.top  = `${rect.bottom + 4}px`;
    menu.style.right = `${window.innerWidth - rect.right}px`;
    document.body.appendChild(menu);

    const dismiss = e => {
      if (!menu.contains(e.target)) {
        menu.remove();
        document.removeEventListener("mousedown", dismiss, true);
      }
    };
    document.addEventListener("mousedown", dismiss, true);
  }

  // ── Create project modal ───────────────────────────────────────────────────

  // ── Create project modal ───────────────────────────────────────────────────

  /**
   * Lazily inject the picker popup + create-project modal DOM into <body>.
   * Called once before the modal is shown; subsequent calls are no-ops.
   */
  function _ensureModalDOM() {
    if (document.getElementById("project-picker-popup")) return;

    let iconsHTML = "";
    for (const [name, path] of Object.entries(_ICON_PATHS)) {
      const sel = name === "folder" ? " project-picker-icon-option--selected" : "";
      iconsHTML += `<button class="project-picker-icon-option${sel}" data-icon="${name}" title="${name[0].toUpperCase()}${name.slice(1)}"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${path}</svg></button>`;
    }

    const tpl = document.createElement("div");
    tpl.innerHTML = `
<div id="project-picker-popup" class="project-picker-popup" style="display:none">
  <!-- Color row -->
  <div class="project-picker-colors" id="project-picker-colors">
    <button class="project-picker-color-option project-picker-color-option--selected project-picker-color-none" data-color="" title="Default"></button>
    <button class="project-picker-color-option" data-color="#ef4444" style="background:#ef4444" title="Red"></button>
    <button class="project-picker-color-option" data-color="#f97316" style="background:#f97316" title="Orange"></button>
    <button class="project-picker-color-option" data-color="#eab308" style="background:#eab308" title="Yellow"></button>
    <button class="project-picker-color-option" data-color="#22c55e" style="background:#22c55e" title="Green"></button>
    <button class="project-picker-color-option" data-color="#3b82f6" style="background:#3b82f6" title="Blue"></button>
    <button class="project-picker-color-option" data-color="#8b5cf6" style="background:#8b5cf6" title="Purple"></button>
    <button class="project-picker-color-option" data-color="#ec4899" style="background:#ec4899" title="Pink"></button>
  </div>
  <!-- Divider -->
  <div class="project-picker-divider"></div>
  <!-- Icon grid -->
  <div class="project-picker-icons" id="project-picker-icons">
    ${iconsHTML}
  </div>
  <!-- Done button -->
  <div class="project-picker-footer">
    <button id="picker-popup-done" class="project-picker-done-btn" data-i18n="projects.picker.done">Done</button>
  </div>
</div>
<div id="create-project-modal-overlay" class="modal-overlay" style="display:none">
  <div class="modal-box sm">
    <div class="modal-header">
      <h3 class="modal-title" data-i18n="projects.create.title">New Project</h3>
    </div>
    <div class="modal-body">
      <div class="create-project-input-row">
        <button id="create-project-icon-trigger" class="project-icon-trigger" type="button" title="Choose icon &amp; color">
          <svg id="create-project-trigger-svg" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>
        </button>
        <input type="text" id="create-project-modal-input" class="modal-input create-project-name-input" autocomplete="off" spellcheck="false" placeholder="" data-i18n-placeholder="projects.create.placeholder">
      </div>
      <div class="create-project-folder-section">
        <div class="create-project-folder-label" data-i18n="projects.create.sourceFolders">Source folders</div>
        <div id="create-project-folder-area" class="create-project-folder-area">
          <div id="create-project-folder-empty" class="create-project-folder-empty">
            <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
              <line x1="12" y1="11" x2="12" y2="17"/><line x1="9" y1="14" x2="15" y2="14"/>
            </svg>
            <span data-i18n="projects.create.folderHint">Add a working folder</span>
          </div>
          <div id="create-project-folder-card" class="create-project-folder-card" style="display:none">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
            </svg>
            <span id="create-project-folder-name" class="create-project-folder-name"></span>
            <button id="create-project-folder-remove" class="create-project-folder-remove" type="button" title="Remove">
              <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
            </button>
          </div>
        </div>
        <div id="create-project-folder-hint" class="create-project-folder-hint" data-i18n="projects.create.folderDefaultHint">If not set, the default working directory ~/clacky_workspace will be used</div>
      </div>
    </div>
    <div class="modal-footer">
      <button id="create-project-modal-cancel" class="btn-secondary" data-i18n="modal.cancel">Cancel</button>
      <button id="create-project-modal-save" class="btn-primary" data-i18n="projects.create.submit">Create Project</button>
    </div>
  </div>
</div>`;
    // Append all top-level nodes to body
    while (tpl.firstChild) document.body.appendChild(tpl.firstChild);
    // Apply i18n to newly injected nodes
    if (typeof I18n !== "undefined") I18n.applyAll();
  }

  /**
   * Show the create-project modal and resolve with { name, color, icon, working_dir }
   * or null if cancelled. Pass an existing project to edit it (prefilled values,
   * edit title/button). Owned here because all DOM nodes belong to project UI.
   */
  function _showCreateProjectModal(existingProject = null) {
    _ensureModalDOM();
    return new Promise(resolve => {
      const $ = id => document.getElementById(id);
      const overlay = $("create-project-modal-overlay");
      const input   = $("create-project-modal-input");
      const trigger = $("create-project-icon-trigger");
      const popup   = $("project-picker-popup");
      const popupColors = $("project-picker-colors");
      const popupIcons  = $("project-picker-icons");
      const doneBtn     = $("picker-popup-done");
      const folderArea  = $("create-project-folder-area");
      const folderEmpty = $("create-project-folder-empty");
      const folderCard  = $("create-project-folder-card");
      const folderName  = $("create-project-folder-name");
      const folderRemoveBtn = $("create-project-folder-remove");
      const folderHint  = $("create-project-folder-hint");

      // State
      let selectedColor = "";       // "" = default (accent)
      let selectedIcon  = "folder";
      let selectedDir   = null;     // absolute path chosen by directory picker
      let popupOpen     = false;
      let pickerBusy    = false;    // prevent double-open of directory picker

      // Icon SVGs lookup (same set as popup, keyed by data-icon)
      const _getIconSvg = (icon) => {
        const btn = popupIcons.querySelector(`[data-icon="${icon}"]`);
        return btn ? btn.innerHTML : popupIcons.querySelector("[data-icon]").innerHTML;
      };

      // Update trigger button appearance
      const _updateTrigger = () => {
        if (selectedColor) {
          trigger.style.background  = selectedColor;
          trigger.style.color       = "#fff";
          trigger.style.borderColor = "transparent";
        } else {
          trigger.style.background  = "";
          trigger.style.color       = "";
          trigger.style.borderColor = "";
        }
        trigger.innerHTML = _getIconSvg(selectedIcon);
      };

      // Helper: extract the last path segment (folder name) from an absolute path
      const _dirBasename = (p) => p ? p.replace(/\/+$/, "").split("/").pop() || p : "";

      // Show / hide folder card vs empty state; also auto-fill project name from dir
      const _updateFolderArea = () => {
        if (selectedDir) {
          folderEmpty.style.display = "none";
          folderCard.style.display  = "flex";
          folderName.textContent    = selectedDir;
          folderName.title          = selectedDir;
          folderArea.style.cursor   = "default";
          // Auto-fill name if user hasn't typed anything yet
          if (!input.value.trim()) {
            input.value = _dirBasename(selectedDir);
            input.classList.remove("input-error");
          }
        } else {
          folderEmpty.style.display = "";
          folderCard.style.display  = "none";
          folderArea.style.cursor   = "pointer";
        }
        folderHint.style.display = selectedDir ? "none" : "";
      };

      // Reset all state (prefill when editing an existing project)
      input.value = existingProject ? (existingProject.name || "") : "";
      input.classList.remove("input-error");
      selectedColor = existingProject ? (existingProject.color || "") : "";
      selectedIcon  = existingProject ? (existingProject.icon  || "folder") : "folder";
      selectedDir   = existingProject ? (existingProject.working_dir || null) : null;
      _updateTrigger();
      _updateFolderArea();

      // Reset popup selections (reflect prefilled values in edit mode)
      popupColors.querySelectorAll(".project-picker-color-option").forEach(b => {
        b.classList.toggle("project-picker-color-option--selected", b.dataset.color === selectedColor);
      });
      popupIcons.querySelectorAll(".project-picker-icon-option").forEach(b => {
        b.classList.toggle("project-picker-icon-option--selected", b.dataset.icon === selectedIcon);
      });

      // Show/hide icon/color popup
      const _openPopup = () => {
        popupOpen = true;
        const rect = trigger.getBoundingClientRect();
        popup.style.display = "block";
        requestAnimationFrame(() => {
          const pw = popup.offsetWidth;
          const ph = popup.offsetHeight;
          let left = rect.left;
          let top  = rect.bottom + 6;
          if (left + pw > window.innerWidth - 8) left = window.innerWidth - pw - 8;
          if (top  + ph > window.innerHeight - 8) top = rect.top - ph - 6;
          popup.style.left = `${left}px`;
          popup.style.top  = `${top}px`;
        });
      };
      const _closePopup = () => {
        popupOpen = false;
        popup.style.display = "none";
      };

      // Move popup / overlay to top of body to avoid clipping
      if (popup.parentNode !== document.body) document.body.appendChild(popup);
      if (overlay.parentNode !== document.body || overlay.nextSibling) document.body.appendChild(overlay);

      // Switch title / submit button text for edit vs create mode
      const titleEl = overlay.querySelector(".modal-title");
      const saveBtn = $("create-project-modal-save");
      if (existingProject) {
        titleEl.textContent = I18n.t("projects.edit.title", "Edit Project");
        saveBtn.textContent  = I18n.t("projects.edit.submit", "Save");
      } else {
        titleEl.textContent = I18n.t("projects.create.title", "New Project");
        saveBtn.textContent  = I18n.t("projects.create.submit", "Create Project");
      }

      overlay.style.display = "flex";
      setTimeout(() => { input.focus(); }, 50);

      // ── Event handlers ──────────────────────────────────────────────

      const onTriggerClick = (e) => {
        e.stopPropagation();
        if (popupOpen) _closePopup(); else _openPopup();
      };

      const onPopupColorClick = (e) => {
        const btn = e.target.closest(".project-picker-color-option");
        if (!btn) return;
        selectedColor = btn.dataset.color;
        popupColors.querySelectorAll(".project-picker-color-option").forEach(b =>
          b.classList.toggle("project-picker-color-option--selected", b === btn)
        );
        _updateTrigger();
      };

      const onPopupIconClick = (e) => {
        const btn = e.target.closest(".project-picker-icon-option");
        if (!btn) return;
        selectedIcon = btn.dataset.icon;
        popupIcons.querySelectorAll(".project-picker-icon-option").forEach(b =>
          b.classList.toggle("project-picker-icon-option--selected", b === btn)
        );
        _updateTrigger();
      };

      const onDoneClick = (e) => {
        e.stopPropagation();
        _closePopup();
      };

      const onDocClick = (e) => {
        if (popupOpen && !popup.contains(e.target) && e.target !== trigger) {
          _closePopup();
        }
      };

      // Folder area click: open directory picker (session-less mode)
      const onFolderAreaClick = async (e) => {
        if (e.target.closest(".create-project-folder-remove")) return;
        if (selectedDir) return;
        if (pickerBusy) return;
        pickerBusy = true;
        try {
          let startDir = null;
          try {
            const r = await fetch("/api/dirs");
            if (r.ok) { const d = await r.json(); startDir = d.default || d.root || null; }
          } catch (_) { /* ignore, picker will fall back to home */ }
          const chosen = await window.openDirectoryPicker(startDir, null);
          if (chosen) {
            selectedDir = chosen;
            _updateFolderArea();
          }
        } finally {
          pickerBusy = false;
        }
      };

      // Remove button clears the selected folder
      const onFolderRemove = (e) => {
        e.stopPropagation();
        const prevDir = selectedDir;
        selectedDir = null;
        if (input.value === _dirBasename(prevDir)) input.value = "";
        _updateFolderArea();
      };

      trigger.addEventListener("click", onTriggerClick);
      popupColors.addEventListener("click", onPopupColorClick);
      popupIcons.addEventListener("click", onPopupIconClick);
      doneBtn.addEventListener("click", onDoneClick);
      document.addEventListener("click", onDocClick);
      folderArea.addEventListener("click", onFolderAreaClick);
      folderRemoveBtn.addEventListener("click", onFolderRemove);

      // ── Cleanup & resolve ───────────────────────────────────────────
      const cleanup = (result) => {
        _closePopup();
        overlay.style.display = "none";
        $("create-project-modal-save").onclick   = null;
        $("create-project-modal-cancel").onclick = null;
        overlay.onclick = null;
        input.onkeydown = null;
        input.oninput   = null;
        trigger.removeEventListener("click", onTriggerClick);
        popupColors.removeEventListener("click", onPopupColorClick);
        popupIcons.removeEventListener("click", onPopupIconClick);
        doneBtn.removeEventListener("click", onDoneClick);
        document.removeEventListener("click", onDocClick);
        folderArea.removeEventListener("click", onFolderAreaClick);
        folderRemoveBtn.removeEventListener("click", onFolderRemove);
        unbindEnter();
        resolve(result);
      };

      const saveHandler = () => {
        const rawName     = input.value.trim();
        const name        = rawName || _dirBasename(selectedDir) || I18n.t("projects.defaultName", "New Project");
        const color       = selectedColor || null;
        const icon        = selectedIcon  || null;
        const working_dir = selectedDir   || null;
        cleanup({ name, color, icon, working_dir });
      };

      input.oninput   = () => input.classList.remove("input-error");
      $("create-project-modal-save").onclick   = saveHandler;
      $("create-project-modal-cancel").onclick = () => cleanup(null);

      const unbindEnter = IME.bindEnter(input, saveHandler);
      input.onkeydown = (e) => { if (e.key === "Escape") cleanup(null); };

      overlay.onclick = (e) => {
        if (e.target.id === "create-project-modal-overlay") cleanup(null);
      };
    });
  }

  // ── UI helpers ─────────────────────────────────────────────────────────────

  /**
   * Prompt for a project name and create it.
   * Returns the created project, or null if the user cancels.
   */
  async function promptCreate() {
    const result = await _showCreateProjectModal();
    if (!result || !result.name || !result.name.trim()) return null;

    try {
      const project = await create({
        name:        result.name.trim(),
        color:       result.color       || null,
        icon:        result.icon        || null,
        working_dir: result.working_dir || null,
      });
      renderSection();
      return project;
    } catch (err) {
      console.error("[Projects] create error:", err);
      return null;
    }
  }

  /** Open the edit-project modal (same as create, prefilled) and save changes. */
  async function promptEdit(id) {
    const project = find(id);
    if (!project) return;

    const result = await _showCreateProjectModal(project);
    if (!result || !result.name || !result.name.trim()) return;

    try {
      await update(id, {
        name:        result.name.trim(),
        color:       result.color       || null,
        icon:        result.icon        || null,
        working_dir: result.working_dir || null,
      });
      renderSection();
    } catch (err) {
      console.error("[Projects] edit error:", err);
    }
  }

  /** Confirm and delete all sessions in a project (keeps the project itself). */
  async function promptDeleteSessions(id) {
    const project = find(id);
    if (!project) return;

    const confirmed = await Modal.confirm(
      I18n.t("projects.deleteSessions.confirm", { name: project.name })
    );
    if (!confirmed) return;

    try {
      const res  = await fetch(`/api/projects/${id}/sessions`, { method: "DELETE" });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Failed to delete sessions");

      Sessions.removeByProjectId(id);
      Sessions.renderList();
      renderSection();
    } catch (err) {
      console.error("[Projects] delete sessions error:", err);
    }
  }

  /** Confirm and delete a project. */
  async function promptDelete(id) {
    const project = find(id);
    if (!project) return;

    const confirmed = await Modal.confirm(
      I18n.t("projects.delete.confirm", { name: project.name })
    );
    if (!confirmed) return;

    try {
      await remove(id);
      // remove() already calls Sessions.renderList() + renderSection()
    } catch (err) {
      console.error("[Projects] delete error:", err);
    }
  }

  function expand(projectId) {
    if (!projectId) return;
    _collapsed.delete(String(projectId));
    _saveCollapsed();
  }

  // ── Init ───────────────────────────────────────────────────────────────────

  function init() {
    const btnNew      = document.getElementById("btn-new-project");
    const btnOrganize = document.getElementById("btn-projects-organize");
    const sectionHeader = document.getElementById("projects-section-header");
    const projectList   = document.getElementById("project-list");

    // Section-level collapse (click on title / chevron area, not on action buttons)
    if (sectionHeader && projectList) {
      // Apply persisted state on init
      if (_sectionCollapsed) {
        projectList.classList.add("project-list-collapsed");
        sectionHeader.classList.add("projects-section-collapsed");
      }
      sectionHeader.addEventListener("click", e => {
        // Don't collapse when clicking the action buttons
        if (e.target.closest("#btn-new-project") || e.target.closest("#btn-projects-organize")) return;
        _sectionCollapsed = !_sectionCollapsed;
        localStorage.setItem(_LS_SECTION_COLLAPSE_KEY, _sectionCollapsed ? "1" : "0");
        projectList.classList.toggle("project-list-collapsed", _sectionCollapsed);
        sectionHeader.classList.toggle("projects-section-collapsed", _sectionCollapsed);
      });
    }

    if (btnNew) {
      btnNew.addEventListener("click", () => promptCreate());
    }

    if (btnOrganize) {
      btnOrganize.addEventListener("click", e => {
        e.stopPropagation();
        _showOrganizeMenu(btnOrganize);
      });
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  return {
    all,
    find,
    setAll,
    create,
    update,
    remove,
    moveSession,
    promptCreate,
    promptEdit,
    promptDelete,
    renderSection,
    expand,
    init,
  };
})();

// Auto-init when DOM is ready
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => Projects.init());
} else {
  Projects.init();
}
