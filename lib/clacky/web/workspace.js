// Workspace panel — lazy file tree for the active session's working directory.
// Lists one directory level at a time via GET /api/sessions/:id/files,
// expands/collapses folders in place, and downloads files on click via
// POST /api/file-action.
"use strict";

const Workspace = (() => {
  const STORAGE_KEY = "clacky.workspace.open";

  let _sessionId   = null;
  let _workingDir  = null;
  let _open        = false;
  let _refreshTimer = null;          // debounce timer for hot-reload refresh
  const REFRESH_DEBOUNCE_MS = 600;

  const $ = (id) => document.getElementById(id);
  const t = (key) => (typeof I18n !== "undefined" ? I18n.t(key) : key);

  const ICON_FOLDER = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>';
  const ICON_FILE   = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>';
  const ICON_CARET  = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg>';

  function formatSize(bytes) {
    if (bytes == null) return "";
    if (bytes < 1024) return `${bytes} B`;
    const units = ["KB", "MB", "GB", "TB"];
    let n = bytes / 1024, i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return `${n < 10 ? n.toFixed(1) : Math.round(n)} ${units[i]}`;
  }

  async function fetchEntries(relPath) {
    const url = `/api/sessions/${encodeURIComponent(_sessionId)}/files?path=${encodeURIComponent(relPath || "")}`;
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const data = await resp.json();
    return data.entries || [];
  }

  function renderEntries(entries) {
    const frag = document.createDocumentFragment();
    if (!entries.length) {
      const empty = document.createElement("div");
      empty.className = "wt-empty";
      empty.textContent = t("workspace.empty");
      frag.appendChild(empty);
      return frag;
    }
    for (const entry of entries) {
      frag.appendChild(buildNode(entry));
    }
    return frag;
  }

  function buildNode(entry) {
    const node = document.createElement("div");
    node.className = "wt-node";

    const row = document.createElement("div");
    row.className = "wt-row";
    row.title = entry.name;

    const caret = document.createElement("span");
    caret.className = "wt-caret" + (entry.type === "dir" ? "" : " leaf");
    if (entry.type === "dir") caret.innerHTML = ICON_CARET;

    const icon = document.createElement("span");
    icon.className = "wt-icon";
    icon.innerHTML = entry.type === "dir" ? ICON_FOLDER : ICON_FILE;

    const name = document.createElement("span");
    name.className = "wt-name";
    name.textContent = entry.name;

    row.appendChild(caret);
    row.appendChild(icon);
    row.appendChild(name);

    if (entry.type === "file") {
      const size = document.createElement("span");
      size.className = "wt-size";
      size.textContent = formatSize(entry.size);
      row.appendChild(size);
    }

    node.appendChild(row);

    if (entry.type === "dir") {
      node.dataset.dirPath = entry.path;
      const children = document.createElement("div");
      children.className = "wt-children";
      children.style.display = "none";
      node.appendChild(children);
      row.addEventListener("click", () => toggleDir(entry, caret, children, node));
    } else {
      row.addEventListener("click", () => downloadFile(entry));
    }

    return node;
  }

  async function toggleDir(entry, caret, children, node) {
    const isOpen = caret.classList.contains("open");
    if (isOpen) {
      caret.classList.remove("open");
      children.style.display = "none";
      if (node) delete node.dataset.expanded;
      return;
    }
    caret.classList.add("open");
    children.style.display = "";
    if (node) node.dataset.expanded = "1";
    if (children.dataset.loaded === "1") return;

    children.innerHTML = `<div class="wt-loading">${t("workspace.loading")}</div>`;
    try {
      const entries = await fetchEntries(entry.path);
      children.innerHTML = "";
      children.appendChild(renderEntries(entries));
      children.dataset.loaded = "1";
    } catch (err) {
      console.error("workspace load failed:", err);
      children.innerHTML = `<div class="wt-error">${t("workspace.error")}</div>`;
    }
  }

  async function downloadFile(entry) {
    const fullPath = _workingDir.replace(/\/+$/, "") + "/" + entry.path;
    try {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: fullPath, action: "download" })
      });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const blob = await resp.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = entry.name;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } catch (err) {
      console.error("download failed:", err);
      if (typeof Modal !== "undefined") Modal.toast(t("workspace.downloadFailed"), "error");
    }
  }

  // Collect the relative paths of all currently-expanded directories,
  // so a hot-reload refresh can restore the same expand state.
  function collectExpandedPaths() {
    const tree = $("workspace-tree");
    if (!tree) return [];
    return Array.from(tree.querySelectorAll('.wt-node[data-expanded="1"]'))
      .map((n) => n.dataset.dirPath)
      .filter((p) => p != null);
  }

  // Expand a directory node programmatically (no user click), loading its
  // children if not already loaded. Returns once children are in the DOM.
  async function expandNode(node) {
    if (!node || node.dataset.dirPath == null) return;
    const caret    = node.querySelector(":scope > .wt-row > .wt-caret");
    const children = node.querySelector(":scope > .wt-children");
    if (!caret || !children) return;
    caret.classList.add("open");
    children.style.display = "";
    node.dataset.expanded = "1";
    if (children.dataset.loaded === "1") return;
    children.innerHTML = `<div class="wt-loading">${t("workspace.loading")}</div>`;
    try {
      const entries = await fetchEntries(node.dataset.dirPath);
      children.innerHTML = "";
      children.appendChild(renderEntries(entries));
      children.dataset.loaded = "1";
    } catch (err) {
      console.error("workspace load failed:", err);
      children.innerHTML = `<div class="wt-error">${t("workspace.error")}</div>`;
    }
  }

  // Re-expand the given relative paths, shallowest first, so parents are
  // loaded before their children. Paths that no longer exist are skipped.
  async function restoreExpandedPaths(paths) {
    if (!paths || !paths.length) return;
    const tree = $("workspace-tree");
    if (!tree) return;
    const ordered = paths.slice().sort((a, b) => a.split("/").length - b.split("/").length);
    for (const p of ordered) {
      const node = tree.querySelector(`.wt-node[data-dir-path="${CSS.escape(p)}"]`);
      if (node) await expandNode(node);
    }
  }

  async function loadRoot({ preserveExpanded = false } = {}) {
    const tree = $("workspace-tree");
    if (!tree || !_sessionId) return;
    const expanded = preserveExpanded ? collectExpandedPaths() : [];
    // Silent refresh keeps the current tree visible; only the initial / manual
    // load shows the loading placeholder to avoid a flicker on every reload.
    if (!preserveExpanded) {
      tree.innerHTML = `<div class="wt-loading">${t("workspace.loading")}</div>`;
    }
    try {
      const entries = await fetchEntries("");
      tree.innerHTML = "";
      tree.appendChild(renderEntries(entries));
      if (expanded.length) await restoreExpandedPaths(expanded);
    } catch (err) {
      console.error("workspace load failed:", err);
      tree.innerHTML = `<div class="wt-error">${t("workspace.error")}</div>`;
    }
  }

  // Debounced hot-reload entry point. Called on WS tool_result / complete
  // events. No-ops when the panel is closed or there is no session, so it
  // costs nothing when not visible.
  function refreshIfOpen() {
    if (!_open || !_sessionId) return;
    if (_refreshTimer) clearTimeout(_refreshTimer);
    _refreshTimer = setTimeout(() => {
      _refreshTimer = null;
      loadRoot({ preserveExpanded: true });
    }, REFRESH_DEBOUNCE_MS);
  }

  function applyOpenState() {
    const panel = $("workspace-panel");
    const opener = $("btn-workspace-open");
    if (!panel) return;
    const hasSession = !!_sessionId;
    panel.classList.toggle("collapsed", !(_open && hasSession));
    if (opener) opener.style.display = (!_open && hasSession) ? "" : "none";
  }

  function setOpen(open) {
    _open = open;
    try { localStorage.setItem(STORAGE_KEY, open ? "1" : "0"); } catch (_) {}
    applyOpenState();
    if (open) loadRoot();
  }

  return {
    init() {
      try { _open = localStorage.getItem(STORAGE_KEY) === "1"; } catch (_) { _open = false; }

      const close   = $("btn-workspace-close");
      const opener   = $("btn-workspace-open");
      const refresh  = $("btn-workspace-refresh");
      if (close)   close.addEventListener("click", () => setOpen(false));
      if (opener)  opener.addEventListener("click", () => setOpen(true));
      if (refresh) refresh.addEventListener("click", () => loadRoot());

      applyOpenState();
    },

    // Called from Sessions.updateInfoBar whenever the active session changes.
    onSession(session) {
      const newId  = session ? session.id : null;
      const newDir = session ? session.working_dir : null;
      const changed = newId !== _sessionId || newDir !== _workingDir;
      _sessionId  = newId;
      _workingDir = newDir;
      applyOpenState();
      if (changed && _open && _sessionId) loadRoot();
    },

    // Called from ws-dispatcher on file-mutating WS events (tool_result /
    // complete). Debounced; no-ops when the panel is closed.
    refreshIfOpen,
  };
})();

document.addEventListener("DOMContentLoaded", () => Workspace.init());
window.Workspace = Workspace;
