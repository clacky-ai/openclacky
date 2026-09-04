// ── Workspace · store — session context + file-tree network ───────────────
//
// Owns the active session id / working dir and the network calls: list one
// directory level, reveal a file in Finder, download a file. It never renders.
//
// `Workspace` stays the single public facade.
//
// Depends on: Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────
"use strict";

const WorkspaceStore = (() => {
  let _sessionId  = null;
  let _workingDir = null;

  const _defaultAppCache = {};
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

  function _absPath(relPath) {
    // Absolute input (POSIX or Windows drive letter) is used as-is so
    // file:// links from chat can point outside the working directory.
    if (/^([A-Za-z]:[\\/]|\/)/.test(relPath)) return relPath;
    return (_workingDir || "").replace(/\/+$/, "") + "/" + relPath;
  }

  // Throw with the backend's error message when available so toasts show the
  // real cause ("file not found", "unsupported OS", …) instead of "HTTP 404".
  async function _respError(resp) {
    let detail = `HTTP ${resp.status}`;
    try {
      const data = await resp.json();
      if (data && data.error) detail = data.error;
    } catch (_e) { /* non-JSON body */ }
    throw new Error(detail);
  }

  const state = {
    get sessionId()  { return _sessionId; },
    get workingDir() { return _workingDir; },
    hasSession()     { return _sessionId != null; },
  };

  const Workspace = {
    on: _on,
    state,

    /** Resolve an entry-relative (or absolute) path to an absolute path. */
    absPath(relPath) { return _absPath(relPath); },

    /** Update active session context. Returns { changed, hadSession }. */
    setSession(session) {
      const newId      = session ? session.id : null;
      const newDir     = session ? session.working_dir : null;
      const hadSession = _sessionId != null;
      const changed    = newId !== _sessionId || newDir !== _workingDir;
      _sessionId  = newId;
      _workingDir = newDir;
      if (changed) _emit("workspace:sessionChanged", { sessionId: newId });
      return { changed, hadSession };
    },

    async fetchEntries(relPath) {
      const url  = `/api/sessions/${encodeURIComponent(_sessionId)}/files?path=${encodeURIComponent(relPath || "")}`;
      const resp = await fetch(url);
      if (!resp.ok) await _respError(resp);
      const data = await resp.json();
      // The root the server actually listed is the authoritative base for
      // the relative entry paths it returns — keeps _absPath in sync with
      // what the tree shows even if a session-context update lands stale.
      if (data.root) _workingDir = data.root;
      return data.entries || [];
    },

    async revealFile(entry) {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: _absPath(entry.path), action: "reveal" })
      });
      if (!resp.ok) await _respError(resp);
    },

    /** Installed applications that can open this file (macOS; [] elsewhere). */
    async fetchOpenWithApps(entry) {
      const resp = await fetch("/api/file/apps?path=" + encodeURIComponent(_absPath(entry.path)));
      if (!resp.ok) return [];
      const data = await resp.json();
      return data.apps || [];
    },

    /** Default application the OS would use to open this file; null if none.
     *  Cached per extension so tab switches don't refetch. */
    async fetchDefaultApp(entry) {
      const ext = (entry.path.match(/\.([^./\\]+)$/) || [])[1];
      if (!ext) return null;
      const key = ext.toLowerCase();
      if (Object.prototype.hasOwnProperty.call(_defaultAppCache, key)) {
        return _defaultAppCache[key];
      }
      const resp = await fetch("/api/file/default-app?path=" + encodeURIComponent(_absPath(entry.path)));
      const data = resp.ok ? await resp.json() : null;
      const app = data && data.ok ? data.app || null : null;
      _defaultAppCache[key] = app;
      return app;
    },

    /** Open the file with one of the apps returned by fetchOpenWithApps. */
    async openWithApp(entry, app) {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: _absPath(entry.path), action: "open_with", app })
      });
      if (!resp.ok) await _respError(resp);
    },

    /** Open the file with the OS default application. */
    async openWithDefault(entry) {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: _absPath(entry.path), action: "open" })
      });
      if (!resp.ok) await _respError(resp);
    },

    async displayPath(entry) {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: _absPath(entry.path), action: "display-path" })
      });
      if (!resp.ok) await _respError(resp);
      const data = await resp.json();
      return data.path;
    },

    async fetchFileBlob(entry) {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: _absPath(entry.path), action: "download" })
      });
      if (!resp.ok) await _respError(resp);
      return resp.blob();
    },

    async fetchFileText(entry) {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: _absPath(entry.path), action: "download" })
      });
      if (!resp.ok) await _respError(resp);
      return resp.text();
    },

    async saveFileText(entry, content) {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: _absPath(entry.path), action: "save", content })
      });
      if (!resp.ok) await _respError(resp);
      _emit("workspace:fileSaved", { sessionId: _sessionId, path: entry.path, name: entry.name });
    },
  };

  return Workspace;
})();

const Workspace = WorkspaceStore;
Clacky.Workspace = Workspace;
Clacky.WorkspaceStore = WorkspaceStore;
