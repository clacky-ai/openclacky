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
    return _workingDir.replace(/\/+$/, "") + "/" + relPath;
  }

  const state = {
    get sessionId()  { return _sessionId; },
    get workingDir() { return _workingDir; },
    hasSession()     { return _sessionId != null; },
  };

  const Workspace = {
    on: _on,
    state,

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
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();
      return data.entries || [];
    },

    async revealFile(entry) {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: _absPath(entry.path), action: "reveal" })
      });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    },

    async displayPath(entry) {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: _absPath(entry.path), action: "display-path" })
      });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();
      return data.path;
    },

    async fetchFileBlob(entry) {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: _absPath(entry.path), action: "download" })
      });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      return resp.blob();
    },

    async fetchFileText(entry) {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: _absPath(entry.path), action: "download" })
      });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      return resp.text();
    },
  };

  return Workspace;
})();

const Workspace = WorkspaceStore;
Clacky.Workspace = Workspace;
Clacky.WorkspaceStore = WorkspaceStore;
