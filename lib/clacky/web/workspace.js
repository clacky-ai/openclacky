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
      const children = document.createElement("div");
      children.className = "wt-children";
      children.style.display = "none";
      node.appendChild(children);
      row.addEventListener("click", () => toggleDir(entry, caret, children));
    } else {
      row.addEventListener("click", () => downloadFile(entry));
    }

    row.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      showContextMenu(e, entry);
    });

    return node;
  }

  function showContextMenu(e, entry) {
    closeContextMenu();

    const iconFolder = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>';

    const menu = document.createElement("div");
    menu.className = "wt-context-menu session-context-menu";
    menu.innerHTML = `
      <div class="session-actions-menu-item" data-action="reveal">
        <span class="session-actions-menu-icon">${iconFolder}</span>
        <span class="session-actions-menu-label">${t("workspace.revealInFinder")}</span>
      </div>
    `;

    document.body.appendChild(menu);
    menu.addEventListener("contextmenu", (e) => e.preventDefault());
    menu.style.position = "fixed";
    menu.style.top = e.clientY + "px";
    menu.style.left = e.clientX + "px";
    requestAnimationFrame(() => {
      const r = menu.getBoundingClientRect();
      if (r.right > window.innerWidth)   menu.style.left = (window.innerWidth - r.width - 8) + "px";
      if (r.bottom > window.innerHeight) menu.style.top  = (window.innerHeight - r.height - 8) + "px";
    });

    menu.addEventListener("click", async (ev) => {
      const item = ev.target.closest(".session-actions-menu-item");
      if (!item) return;
      closeContextMenu();
      if (item.dataset.action === "reveal") await revealFile(entry);
    });

    setTimeout(() => {
      document.addEventListener("click", closeContextMenu, { once: true });
    }, 0);
  }

  function closeContextMenu() {
    const existing = document.querySelector(".wt-context-menu");
    if (existing) existing.remove();
  }

  async function revealFile(entry) {
    const fullPath = _workingDir.replace(/\/+$/, "") + "/" + entry.path;
    try {
      const resp = await fetch("/api/file-action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: fullPath, action: "reveal" })
      });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    } catch (err) {
      console.error("reveal failed:", err);
      if (typeof Modal !== "undefined") Modal.toast(t("workspace.revealFailed"), "error");
    }
  }

  async function toggleDir(entry, caret, children) {
    const isOpen = caret.classList.contains("open");
    if (isOpen) {
      caret.classList.remove("open");
      children.style.display = "none";
      return;
    }
    caret.classList.add("open");
    children.style.display = "";
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

  async function loadRoot() {
    const tree = $("workspace-tree");
    if (!tree || !_sessionId) return;
    tree.innerHTML = `<div class="wt-loading">${t("workspace.loading")}</div>`;
    try {
      const entries = await fetchEntries("");
      tree.innerHTML = "";
      tree.appendChild(renderEntries(entries));
    } catch (err) {
      console.error("workspace load failed:", err);
      tree.innerHTML = `<div class="wt-error">${t("workspace.error")}</div>`;
    }
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
    // On a real session switch (from one session to another) we always collapse
    // the panel: the file list is only ever loaded when the user explicitly
    // expands it (which triggers a single refresh via setOpen), so the list is
    // never shown stale across sessions. The first attach (no previous session)
    // is not a switch and keeps the restored open state.
    onSession(session) {
      const newId  = session ? session.id : null;
      const newDir = session ? session.working_dir : null;
      const hadSession = _sessionId != null;
      const changed = newId !== _sessionId || newDir !== _workingDir;
      _sessionId  = newId;
      _workingDir = newDir;
      if (changed && hadSession && _open) setOpen(false);
      applyOpenState();
      // First attach with the panel restored open: load once.
      if (!hadSession && _open && _sessionId) loadRoot();
    }
  };
})();

(function _initWorkspaceResize() {
  const panel  = document.getElementById("workspace-panel");
  const handle = document.getElementById("workspace-resize-handle");
  if (!panel || !handle) return;

  const MIN_W = 160;
  const MAX_W = 600;

  const saved = localStorage.getItem("workspace-width");
  if (saved) {
    const w = parseFloat(saved);
    if (w >= MIN_W && w <= MAX_W) panel.style.setProperty("--workspace-width", w + "px");
  }

  let startX = 0;
  let startW = 0;

  handle.addEventListener("mousedown", (e) => {
    e.preventDefault();
    startX = e.clientX;
    startW = parseFloat(getComputedStyle(panel).getPropertyValue("--workspace-width"));
    handle.classList.add("active");
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
  });

  document.addEventListener("mousemove", (e) => {
    if (!handle.classList.contains("active")) return;
    const dx = startX - e.clientX;
    const newW = Math.min(MAX_W, Math.max(MIN_W, startW + dx));
    panel.style.setProperty("--workspace-width", newW + "px");
  });

  document.addEventListener("mouseup", () => {
    if (!handle.classList.contains("active")) return;
    handle.classList.remove("active");
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
    localStorage.setItem("workspace-width", parseFloat(getComputedStyle(panel).getPropertyValue("--workspace-width")));
  });
})();

document.addEventListener("DOMContentLoaded", () => Workspace.init());
window.Workspace = Workspace;
