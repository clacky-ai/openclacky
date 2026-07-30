// ── Projects · store — explicit project folders for the sidebar ───────────
//
// Projects are first-class opened directories. Sessions still carry working_dir;
// the sidebar groups sessions whose working_dir matches a project path.
// Active project is remembered in localStorage so "New Session" inherits it.
//
// Depends on: window.openDirectoryPicker (sessions.js), I18n, Clacky.ext
// ───────────────────────────────────────────────────────────────────────────

const ProjectsStore = (() => {
  const LS_ACTIVE_KEY = "openclacky.projects.activeId";
  const LS_COLLAPSED_KEY = "openclacky.projects.collapsed";
  const LS_EXPANDED_MORE_KEY = "openclacky.projects.expandedMore";
  // Sidebar preview limit per project folder; overflow is hidden until expanded.
  const SESSION_PREVIEW_LIMIT = 5;

  const _state = {
    projects: [],
    activeId: localStorage.getItem(LS_ACTIVE_KEY) || null,
    collapsed: _loadCollapsed(),
    expandedMore: _loadExpandedMore(),
    loaded: false,
    loading: false,
  };

  const _listeners = {};

  function _loadCollapsed() {
    try {
      const raw = JSON.parse(localStorage.getItem(LS_COLLAPSED_KEY) || "{}");
      return raw && typeof raw === "object" ? raw : {};
    } catch (_) {
      return {};
    }
  }

  function _saveCollapsed() {
    localStorage.setItem(LS_COLLAPSED_KEY, JSON.stringify(_state.collapsed));
  }

  function _loadExpandedMore() {
    try {
      const raw = JSON.parse(localStorage.getItem(LS_EXPANDED_MORE_KEY) || "{}");
      return raw && typeof raw === "object" ? raw : {};
    } catch (_) {
      return {};
    }
  }

  function _saveExpandedMore() {
    localStorage.setItem(LS_EXPANDED_MORE_KEY, JSON.stringify(_state.expandedMore));
  }

  function _on(event, handler) {
    (_listeners[event] ||= []).push(handler);
    return () => {
      const list = _listeners[event];
      const i = list ? list.indexOf(handler) : -1;
      if (i >= 0) list.splice(i, 1);
    };
  }

  function _emit(event, payload) {
    (_listeners[event] || []).forEach((h) => {
      try { h(payload); } catch (e) { console.error(e); }
    });
    if (window.Clacky && Clacky.ext) Clacky.ext.emit(event, payload);
  }

  // Best-effort path collapse for sidebar grouping. Backend already stores
  // canonical paths via ProjectManager; this mainly strips trailing slashes
  // and collapses . / .. segments so older or hand-edited working_dir values
  // still match.
  function _normalizePath(path) {
    if (!path) return "";
    let p = String(path).trim().replace(/\\/g, "/");
    if (!p) return "";

    const abs = p.startsWith("/");
    const parts = p.split("/");
    const out = [];
    for (const part of parts) {
      if (!part || part === ".") continue;
      if (part === "..") {
        if (out.length && out[out.length - 1] !== "..") out.pop();
        else if (!abs) out.push("..");
        continue;
      }
      out.push(part);
    }
    const joined = out.join("/");
    if (abs) return "/" + joined;
    return joined || ".";
  }

  function activeProject() {
    if (!_state.activeId) return null;
    return _state.projects.find((p) => p.id === _state.activeId) || null;
  }

  function findByPath(path) {
    const normalized = _normalizePath(path);
    if (!normalized) return null;
    return _state.projects.find((p) => _normalizePath(p.path) === normalized) || null;
  }

  function setActive(id, { persist = true, touch = false } = {}) {
    const next = id || null;
    // Same project: no-op. Skips redundant /touch from repeated session selects.
    if (_state.activeId === next) return activeProject();
    _state.activeId = next;
    if (persist) {
      if (next) localStorage.setItem(LS_ACTIVE_KEY, next);
      else localStorage.removeItem(LS_ACTIVE_KEY);
    }
    _emit("projects:active-changed", { project: activeProject() });
    if (touch && next) {
      fetch(`/api/projects/${encodeURIComponent(next)}/touch`, { method: "POST" })
        .then((res) => res.ok ? res.json() : null)
        .then((data) => {
          if (!data || !data.project) return;
          const idx = _state.projects.findIndex((p) => p.id === data.project.id);
          if (idx >= 0) _state.projects[idx] = data.project;
          _emit("projects:changed", { projects: _state.projects });
        })
        .catch(() => {});
    }
    return activeProject();
  }

  function isCollapsed(id) {
    // Default expanded for active project, collapsed otherwise only if marked.
    if (Object.prototype.hasOwnProperty.call(_state.collapsed, id)) {
      return !!_state.collapsed[id];
    }
    return _state.activeId !== id;
  }

  function setCollapsed(id, collapsed) {
    _state.collapsed[id] = !!collapsed;
    _saveCollapsed();
    _emit("projects:changed", { projects: _state.projects });
  }

  function toggleCollapsed(id) {
    setCollapsed(id, !isCollapsed(id));
  }

  function isExpandedMore(id) {
    return !!_state.expandedMore[id];
  }

  function setExpandedMore(id, expanded) {
    if (expanded) _state.expandedMore[id] = true;
    else delete _state.expandedMore[id];
    _saveExpandedMore();
    _emit("projects:changed", { projects: _state.projects });
  }

  function toggleExpandedMore(id) {
    setExpandedMore(id, !isExpandedMore(id));
  }

  async function load() {
    if (_state.loading) return _state.projects;
    _state.loading = true;
    try {
      const res = await fetch("/api/projects");
      if (!res.ok) throw new Error("failed to load projects");
      const data = await res.json();
      _state.projects = (data && data.projects) || [];
      _state.loaded = true;
      if (_state.activeId && !_state.projects.find((p) => p.id === _state.activeId)) {
        _state.activeId = null;
        localStorage.removeItem(LS_ACTIVE_KEY);
      }
      _emit("projects:changed", { projects: _state.projects });
      return _state.projects;
    } catch (e) {
      console.error("ProjectsStore.load failed:", e);
      return _state.projects;
    } finally {
      _state.loading = false;
    }
  }

  async function openPath(path, name) {
    const res = await fetch("/api/projects", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path, name }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((data && data.error) || "Failed to open project");
    const project = data.project;
    const idx = _state.projects.findIndex((p) => p.id === project.id);
    if (idx >= 0) _state.projects[idx] = project;
    else _state.projects.unshift(project);
    // Keep most-recent first for UX even before reload.
    _state.projects.sort((a, b) => String(b.last_opened_at || "").localeCompare(String(a.last_opened_at || "")));
    setActive(project.id, { persist: true });
    setCollapsed(project.id, false);
    _emit("projects:changed", { projects: _state.projects });
    return project;
  }

  async function defaultPickerRoot() {
    try {
      const res = await fetch("/api/dirs");
      if (!res.ok) return null;
      const data = await res.json();
      return (data && (data.default || data.home || data.path || data.root)) || null;
    } catch (_) {
      return null;
    }
  }

  async function openWithPicker(startPath) {
    if (typeof window.openDirectoryPicker !== "function") {
      throw new Error("Directory picker unavailable");
    }
    // Prefer the backend default workspace so non-Docker hosts don't hardcode
    // /root/clacky_workspace. Explicit startPath still wins.
    let start = (startPath && String(startPath).trim()) || "";
    if (!start) start = (await defaultPickerRoot()) || "";
    const picked = await window.openDirectoryPicker(start || null, null);
    if (!picked) return null;
    return openPath(picked);
  }

  async function rename(id, name) {
    const res = await fetch(`/api/projects/${encodeURIComponent(id)}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((data && data.error) || "Failed to rename project");
    const project = data.project;
    if (project) {
      const idx = _state.projects.findIndex((p) => p.id === project.id);
      if (idx >= 0) _state.projects[idx] = project;
      _emit("projects:changed", { projects: _state.projects });
    }
    return project;
  }

  async function remove(id) {
    const res = await fetch(`/api/projects/${encodeURIComponent(id)}`, { method: "DELETE" });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((data && data.error) || "Failed to remove project");
    _state.projects = _state.projects.filter((p) => p.id !== id);
    delete _state.collapsed[id];
    delete _state.expandedMore[id];
    _saveCollapsed();
    _saveExpandedMore();
    if (_state.activeId === id) setActive(null);
    _emit("projects:changed", { projects: _state.projects });
    return true;
  }

  // Most-recent activity timestamp for sidebar MRU ordering.
  // Prefer live session activity; fall back to last_opened_at for empty projects.
  function _activityTs(value) {
    const t = Date.parse(String(value || ""));
    return Number.isFinite(t) ? t : 0;
  }

  function _projectActivityTs(project, sessions) {
    let latest = _activityTs(project && (project.last_opened_at || project.created_at));
    (sessions || []).forEach((s) => {
      const ts = _activityTs(s && (s.updated_at || s.created_at));
      if (ts > latest) latest = ts;
    });
    return latest;
  }

  function groupSessions(sessions) {
    const byPath = new Map();
    _state.projects.forEach((p) => {
      byPath.set(_normalizePath(p.path), { project: p, sessions: [] });
    });

    const ungrouped = [];
    (sessions || []).forEach((s) => {
      const key = _normalizePath(s.working_dir);
      const bucket = key ? byPath.get(key) : null;
      if (bucket) bucket.sessions.push(s);
      else ungrouped.push(s);
    });

    // International MRU convention (VS Code / Cursor / chat sidebars):
    // whichever project has newer session activity floats to the top.
    const groups = _state.projects.map((p) => {
      const bucket = byPath.get(_normalizePath(p.path));
      return {
        project: p,
        sessions: bucket ? bucket.sessions : [],
        collapsed: isCollapsed(p.id),
        active: p.id === _state.activeId,
      };
    }).sort((a, b) => {
      const diff = _projectActivityTs(b.project, b.sessions) - _projectActivityTs(a.project, a.sessions);
      if (diff !== 0) return diff;
      return String(a.project.name || "").localeCompare(String(b.project.name || ""), undefined, {
        sensitivity: "base",
      });
    });

    return { groups, ungrouped };
  }

  return {
    get state() { return _state; },
    on: _on,
    load,
    list: () => _state.projects.slice(),
    activeProject,
    activeId: () => _state.activeId,
    setActive,
    findByPath,
    isCollapsed,
    setCollapsed,
    toggleCollapsed,
    isExpandedMore,
    setExpandedMore,
    toggleExpandedMore,
    sessionPreviewLimit: SESSION_PREVIEW_LIMIT,
    openPath,
    openWithPicker,
    rename,
    remove,
    groupSessions,
    normalizePath: _normalizePath,
  };
})();

window.ProjectsStore = ProjectsStore;
if (window.Clacky) Clacky.ProjectsStore = ProjectsStore;
