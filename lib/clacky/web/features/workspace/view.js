// ── Workspace · view — Files tab (download artifacts) ─────────────────────
//
// Renders the working-directory file tree as the "Files" tab in the session
// aside. The tab is product-positioned as "see what the AI produced and
// download it": clicking a file downloads it; directories expand lazily;
// right-click reveals in the OS file manager (desktop only).
//
// Registered as a host-owned (built-in) tab via Clacky.ext.ui.mountBuiltin so
// it shows for every session regardless of agent profile. All I/O goes through
// WorkspaceStore.
//
// Depends on: WorkspaceStore, Clacky.ext, I18n, Modal.
// ───────────────────────────────────────────────────────────────────────────
"use strict";

const WorkspaceView = (() => {
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

  function renderEntries(entries) {
    const frag = document.createDocumentFragment();
    if (!entries.length) {
      const empty = document.createElement("div");
      empty.className = "wt-empty";
      empty.textContent = t("workspace.empty");
      frag.appendChild(empty);
      return frag;
    }
    for (const entry of entries) frag.appendChild(buildNode(entry));
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
      row.addEventListener("click", () => openFile(entry));
    }

    row.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      showContextMenu(e, entry);
    });

    return node;
  }

  function showContextMenu(e, entry) {
    closeContextMenu();

    const iconFolder   = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>';
    const iconDownload = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="M7.5 11l4.5 4.5 4.5-4.5"/><path d="M5 20h14"/></svg>';
    const iconCopy     = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>';
    const iconRelPath  = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/><path d="M12 19l3-3"/></svg>';

    const downloadItem = entry.type === "file" ? `
      <div class="session-actions-menu-item" data-action="download">
        <span class="session-actions-menu-icon">${iconDownload}</span>
        <span class="session-actions-menu-label">${t("workspace.download")}</span>
      </div>` : "";

    const menu = document.createElement("div");
    menu.className = "wt-context-menu session-context-menu";
    menu.innerHTML = `
      <div class="session-actions-menu-item" data-action="reveal">
        <span class="session-actions-menu-icon">${iconFolder}</span>
        <span class="session-actions-menu-label">${t("workspace.revealInFinder")}</span>
      </div>
      <div class="session-actions-menu-item" data-action="copypath">
        <span class="session-actions-menu-icon">${iconCopy}</span>
        <span class="session-actions-menu-label">${t("workspace.copyPath")}</span>
      </div>
      <div class="session-actions-menu-item" data-action="copyrelpath">
        <span class="session-actions-menu-icon">${iconRelPath}</span>
        <span class="session-actions-menu-label">${t("workspace.copyRelPath")}</span>
      </div>
      ${downloadItem}
    `;

    document.body.appendChild(menu);
    menu.addEventListener("contextmenu", (ev) => ev.preventDefault());
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
      if (item.dataset.action === "reveal")    await revealFile(entry);
      if (item.dataset.action === "download")  await downloadFile(entry);
      if (item.dataset.action === "copypath")    copyPath(entry);
      if (item.dataset.action === "copyrelpath") copyRelPath(entry);
    });

    setTimeout(() => {
      document.addEventListener("click", closeContextMenu, { once: true });
    }, 0);
  }

  function closeContextMenu() {
    const existing = document.querySelector(".wt-context-menu");
    if (existing) existing.remove();
  }

  async function copyPath(entry) {
    const fallback = Workspace.state.workingDir.replace(/\/+$/, "") + "/" + entry.path.replace(/^\/+/, "");
    let target = fallback;
    try {
      target = await Workspace.displayPath(entry);
    } catch (err) {
      target = fallback;
    }
    navigator.clipboard.writeText(target).then(() => {
      Modal.toast(target, "info");
    });
  }

  function copyRelPath(entry) {
    navigator.clipboard.writeText(entry.path).then(() => {
      Modal.toast(entry.path, "info");
    });
  }

  async function revealFile(entry) {
    try {
      await Workspace.revealFile(entry);
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
      const entries = await Workspace.fetchEntries(entry.path);
      children.innerHTML = "";
      children.appendChild(renderEntries(entries));
      children.dataset.loaded = "1";
    } catch (err) {
      console.error("workspace load failed:", err);
      children.innerHTML = `<div class="wt-error">${t("workspace.error")}</div>`;
    }
  }

  async function openFile(entry) {
    const kind = CodeEditor.fileKind(entry.name);
    if (kind === "binary") {
      Modal.toast(t("workspace.previewUnsupported"), "info");
      return;
    }
    if (kind === "image") {
      try {
        const blob = await Workspace.fetchFileBlob(entry);
        const url = URL.createObjectURL(blob);
        CodeEditor.open({ filename: entry.name, title: entry.name, kind: "image", imageUrl: url, onClose: () => URL.revokeObjectURL(url) });
      } catch (err) {
        console.error("preview failed:", err);
        Modal.toast(t("workspace.previewFailed"), "error");
      }
      return;
    }
    try {
      const text = await Workspace.fetchFileText(entry);
      CodeEditor.open({ filename: entry.name, title: entry.name, content: text, readOnly: true });
    } catch (err) {
      console.error("preview failed:", err);
      Modal.toast(t("workspace.previewFailed"), "error");
    }
  }

  async function downloadFile(entry) {
    try {
      const blob = await Workspace.fetchFileBlob(entry);
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

  async function loadRoot(tree) {
    if (!tree || !Workspace.state.hasSession()) return;
    tree.innerHTML = `<div class="wt-loading">${t("workspace.loading")}</div>`;
    try {
      const entries = await Workspace.fetchEntries("");
      tree.innerHTML = "";
      tree.appendChild(renderEntries(entries));
    } catch (err) {
      console.error("workspace load failed:", err);
      tree.innerHTML = `<div class="wt-error">${t("workspace.error")}</div>`;
    }
  }

  // Build the Files tab body for the current session.
  function renderFilesTab(_ctx) {
    const wrap = document.createElement("div");
    wrap.className = "wt-panel";

    const bar = document.createElement("div");
    bar.className = "wt-bar";
    const hint = document.createElement("span");
    hint.className = "wt-bar-hint";
    hint.textContent = t("workspace.contextMenuHint");
    const refresh = document.createElement("button");
    refresh.type = "button";
    refresh.className = "wt-bar-btn";
    refresh.textContent = t("workspace.refresh");
    bar.appendChild(hint);
    bar.appendChild(refresh);

    const tree = document.createElement("div");
    tree.className = "wt-tree";
    tree.setAttribute("role", "tree");

    refresh.addEventListener("click", () => loadRoot(tree));

    wrap.appendChild(bar);
    wrap.appendChild(tree);
    loadRoot(tree);
    return wrap;
  }

  return { renderFilesTab };
})();

// Files is a built-in tab: visible for every session, after the agent-scoped
// panels (git/time-machine use orders 10/20).
if (window.Clacky && Clacky.ext) {
  Clacky.ext.ui.mountBuiltin("session.aside", (ctx) => WorkspaceView.renderFilesTab(ctx), {
    order: 40,
    tab: { id: "files", label: () => (typeof I18n !== "undefined" ? I18n.t("workspace.title") : "Files") },
  });
}

// Keep the store's session context in sync (sessions.js still calls
// Workspace.onSession on every session switch). Rendering is driven by the
// slot re-render, so this only updates state.
Workspace.onSession = (session) => { Workspace.setSession(session); };
