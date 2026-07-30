// ── Trash · store — recycle-bin data (files + sessions) + network ──────────
//
// Owns the file-trash and session-trash lists/totals plus every network call:
// load, restore, delete, and bulk empty (by age / all / orphans). Mutates local
// state optimistically and emits change events. It never renders.
//
// The orphan heuristic lives here (state classification, not presentation).
// Emits mirror to the extension bus via Clacky.ext.emit.
//
// `Trash` stays the single public facade.
//
// Depends on: Sessions, Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────

const TrashStore = (() => {
  const SOURCES = Object.freeze({ ALL: "all", CRON: "cron", MANUAL: "manual" });

  let _files          = [];
  let _totals         = { count: 0, size: 0 };
  let _sessions       = [];
  let _sessionTotals  = { count: 0, size: 0 };
  let _filterSource   = SOURCES.ALL;
  let _filterProjectId = null;  // null = all projects
  let _loading        = false;

  const _listeners = {};

  function _on(event, handler) {
    (_listeners[event] ||= []).push(handler);
    return () => {
      const list = _listeners[event];
      const i = list ? list.indexOf(handler) : -1;
      if (i >= 0) list.splice(i, 1);
    };
  }

  function _emit(event, payload) {
    (_listeners[event] || []).forEach((h) => h(payload));
    if (window.Clacky && Clacky.ext) Clacky.ext.emit(event, payload);
  }

  function _isOrphanRoot(root) {
    root = root || "";
    return /^\/(?:var\/folders|tmp|private\/var\/folders)\b/.test(root) ||
           /\/d\d{8}-\d+-[a-z0-9]+(?:\/|$)/.test(root);
  }

  const state = {
    get files()         { return _files; },
    get totals()        { return _totals; },
    get sessions()      {
      let list = _sessions;
      if (_filterSource !== SOURCES.ALL) {
        list = _filterSource === SOURCES.CRON
          ? list.filter(s => s.source === SOURCES.CRON)
          : list.filter(s => s.source !== SOURCES.CRON);
      }
      if (_filterProjectId !== null) {
        list = list.filter(s => String(s.project_id ?? "") === _filterProjectId);
      }
      return list;
    },
    get sessionTotals() {
      const filtered = state.sessions;
      return { count: filtered.length, size: filtered.reduce((sum, s) => sum + (s.file_size || 0), 0) };
    },
    get filterSource()     { return _filterSource; },
    get filterProjectId()  { return _filterProjectId; },
    orphanCount() { return _files.filter(f => _isOrphanRoot(f.project_root)).length; },
    isOrphan(file) { return _isOrphanRoot(file.project_root); },
  };

  const Trash = {
    on: _on,
    state,
    SOURCES,

    setFilterSource(source) {
      if (source === _filterSource) return;
      _filterSource = source;
      _emit("trash:sessionsChanged");
    },

    setFilterProject(projectId) {
      // projectId: string/number ID or null/empty (= all)
      const normalized = (projectId != null && projectId !== "") ? String(projectId) : null;
      if (normalized === _filterProjectId) return;
      _filterProjectId = normalized;
      _emit("trash:sessionsChanged");
    },

    async loadFiles() {
      if (_loading) return;
      _loading = true;
      _emit("trash:filesLoading");
      try {
        const res  = await fetch("/api/trash");
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || "Load failed");
        _files  = data.files  || [];
        _totals = { count: data.total_count || 0, size: data.total_size || 0 };
        _emit("trash:filesChanged");
      } catch (e) {
        console.error("[Trash] load files failed", e);
        _emit("trash:filesError", { message: e.message });
      } finally {
        _loading = false;
      }
    },

    async loadSessions() {
      if (_loading) return;
      _loading = true;
      _emit("trash:sessionsLoading");
      try {
        const res  = await fetch("/api/trash/sessions");
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || "Load failed");
        _sessions      = data.sessions || [];
        _sessionTotals = { count: data.count || 0, size: data.total_size || 0 };
        _emit("trash:sessionsChanged");
      } catch (e) {
        console.error("[Trash] load sessions failed", e);
        _emit("trash:sessionsError", { message: e.message });
      } finally {
        _loading = false;
      }
    },

    async restoreFile(file) {
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
        if (!res.ok || !data.ok) return { ok: false, error: data.error || res.statusText };
        _removeFileLocal(file);
        _emit("trash:filesChanged");
        return { ok: true };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    async deleteFile(file) {
      const url = "/api/trash?" + new URLSearchParams({
        project: file.project_root,
        file:    file.original_path
      }).toString();
      try {
        const res  = await fetch(url, { method: "DELETE" });
        const data = await res.json();
        if (!res.ok || !data.ok) return { ok: false, error: data.error || res.statusText };
        _removeFileLocal(file);
        _emit("trash:filesChanged");
        return { ok: true };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    async restoreSession(session) {
      try {
        const res = await fetch("/api/trash/sessions/restore", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ session_id: session.session_id })
        });
        const data = await res.json();
        if (!res.ok || !data.ok) return { ok: false, error: data.error || res.statusText };
        _removeSessionLocal(session);
        _emit("trash:sessionsChanged");
        const restored = data.session;
        if (restored && typeof Sessions !== "undefined") {
          Sessions.add(restored);
          Sessions.renderList();
          if (typeof Projects !== "undefined") Projects.renderSection();
        }
        return { ok: true, session: restored };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    async deleteSession(session) {
      try {
        const res  = await fetch(`/api/trash/sessions/${encodeURIComponent(session.session_id)}`, { method: "DELETE" });
        const data = await res.json();
        if (!res.ok || !data.ok) return { ok: false, error: data.error || res.statusText };
        _removeSessionLocal(session);
        _emit("trash:sessionsChanged");
        return { ok: true };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    countMatching(items, daysOld) {
      if (!Array.isArray(items)) return 0;
      if (!daysOld || daysOld <= 0) return items.length;
      const cutoff = Date.now() - daysOld * 86400000;
      return items.filter(it => {
        const t = Date.parse(it.deleted_at || "");
        return !isNaN(t) && t < cutoff;
      }).length;
    },

    async emptyFilesBulk(daysOld) {
      const url = "/api/trash?" + new URLSearchParams({ days_old: String(daysOld) }).toString();
      try {
        const res  = await fetch(url, { method: "DELETE" });
        const data = await res.json();
        if (!res.ok || !data.ok) return { ok: false, error: data.error || res.statusText };
        await Trash.loadFiles();
        return { ok: true, deleted_count: data.deleted_count || 0, freed_size: data.freed_size || 0 };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    async emptySessionsBulk(daysOld) {
      const url = "/api/trash/sessions?" + new URLSearchParams({ days_old: String(daysOld) }).toString();
      try {
        const res  = await fetch(url, { method: "DELETE" });
        const data = await res.json();
        if (!res.ok || !data.ok) return { ok: false, error: data.error || res.statusText };
        await Trash.loadSessions();
        return { ok: true, deleted_count: data.deleted_count || 0 };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    orphans() {
      return _files.filter(f => _isOrphanRoot(f.project_root));
    },

    async deleteOneFileRaw(file) {
      const url = "/api/trash?" + new URLSearchParams({
        project: file.project_root,
        file:    file.original_path
      }).toString();
      try {
        const r = await fetch(url, { method: "DELETE" });
        const d = await r.json();
        return { ok: r.ok && !!d.ok, freed_size: d.freed_size || 0 };
      } catch (_e) {
        return { ok: false, freed_size: 0 };
      }
    },
  };

  function _removeFileLocal(file) {
    _files = _files.filter(f =>
      !(f.project_root === file.project_root && f.original_path === file.original_path));
    _totals = {
      count: Math.max(0, _totals.count - 1),
      size:  Math.max(0, _totals.size - (file.file_size || 0))
    };
  }

  function _removeSessionLocal(session) {
    _sessions = _sessions.filter(s => s.session_id !== session.session_id);
  }

  return Trash;
})();

const Trash = TrashStore;
