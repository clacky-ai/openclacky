// ── Workspace · view - Files tab (tree + inline tabbed viewer) ─────────────
//
// Renders the working-directory file tree plus an inline file viewer in the
// "Files" tab of the session aside. Clicking a file opens it in the viewer
// right of the tree as a tab: files can be switched / closed, text files are
// editable with Cmd+S save, images preview inline and markdown has an
// edit/preview toggle. Right-click on the tree still reveals / copies paths /
// downloads.
//
// Registered as a host-owned (built-in) tab via Clacky.ext.ui.mountBuiltin so
// it shows for every session regardless of agent profile. All I/O goes through
// WorkspaceStore.
//
// Depends on: WorkspaceStore, Clacky.ext, I18n, Modal, CodeEditor.
// ───────────────────────────────────────────────────────────────────────────
"use strict";

const WorkspaceView = (() => {
  const t = (key) => (typeof I18n !== "undefined" ? I18n.t(key) : key);

  const ICON_FOLDER = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>';
  const ICON_FOLDER_OPEN = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/></svg>';
  const ICON_FILE   = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>';
  const ICON_CARET  = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg>';
  const ICON_COPY    = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>';
  const ICON_DOWNLOAD= '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="M7.5 11l4.5 4.5 4.5-4.5"/><path d="M5 20h14"/></svg>';
  const ICON_SAVE    = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><polyline points="17 21 17 13 7 13 7 21"/><polyline points="7 3 7 8 15 8"/></svg>';
  const ICON_EYE     = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>';
  const ICON_CLOSE   = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M18 6L6 18M6 6l12 12"/></svg>';

  function el(tag, cls) {
    const d = document.createElement(tag);
    if (cls) d.className = cls;
    return d;
  }

  function formatSize(bytes) {
    if (bytes == null) return "";
    if (bytes < 1024) return `${bytes} B`;
    const units = ["KB", "MB", "GB", "TB"];
    let n = bytes / 1024, i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return `${n < 10 ? n.toFixed(1) : Math.round(n)} ${units[i]}`;
  }

  // ── File-type icons (VS Code Seti-style colored SVGs) ────────────────────

  const ICON_FONT = 'font-family="ui-sans-serif, system-ui, -apple-system, \'Segoe UI\', sans-serif"';

  function svgWrap(inner) {
    return '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">' + inner + '</svg>';
  }

  function boxIcon(label, bg, fg, fontSize) {
    const size = fontSize || (label.length >= 2 ? 6.5 : 8);
    return svgWrap(
      `<rect x="1" y="2" width="14" height="12" rx="2.2" fill="${bg}"/>` +
      `<text x="8" y="11.3" text-anchor="middle" ${ICON_FONT} font-size="${size}" font-weight="800" fill="${fg || "#fff"}">${label}</text>`
    );
  }

  function glyphIcon(glyph, color, fontSize) {
    return svgWrap(
      `<text x="8" y="12.3" text-anchor="middle" ${ICON_FONT} font-size="${fontSize}" font-weight="800" fill="${color}">${glyph}</text>`
    );
  }

  const ICON_REACT = svgWrap(
    '<g fill="none" stroke="#61dafb" stroke-width="1">' +
    '<ellipse cx="8" cy="8" rx="6.5" ry="2.7"/>' +
    '<ellipse cx="8" cy="8" rx="6.5" ry="2.7" transform="rotate(60 8 8)"/>' +
    '<ellipse cx="8" cy="8" rx="6.5" ry="2.7" transform="rotate(120 8 8)"/>' +
    '<circle cx="8" cy="8" r="1.5" fill="#61dafb" stroke="none"/></g>'
  );

  const ICON_GIT = svgWrap(
    '<g fill="#e87d3e"><circle cx="5" cy="3.6" r="1.7"/><circle cx="11.5" cy="3.6" r="1.7"/><circle cx="5" cy="12.4" r="1.7"/></g>' +
    '<path d="M5 5.6v5" fill="none" stroke="#e87d3e" stroke-width="1.2"/>' +
    '<path d="M11.5 5.6c0 3-6.5 2-6.5 5" fill="none" stroke="#e87d3e" stroke-width="1.2"/>'
  );

  const ICON_RUBY = svgWrap('<path fill="#cc342d" d="M3.2 3h9.6l2.7 3.8L8 14.2.5 6.8z"/>');

  const ICON_LOCK = svgWrap(
    '<rect x="3" y="7" width="10" height="7" rx="1.5" fill="#8a8d94"/>' +
    '<path d="M5.5 7V5.2a2.5 2.5 0 0 1 5 0V7" fill="none" stroke="#8a8d94" stroke-width="1.5"/>'
  );

  const ICON_ZAP = svgWrap('<path fill="#fbc02d" d="M9.5 1.5L3 9h4l-1.5 5.5L13 7H8.5z"/>');

  const ICON_WAVE = svgWrap(
    '<g fill="none" stroke="#38bdf8" stroke-width="1.7" stroke-linecap="round">' +
    '<path d="M1.5 6.5q2.5-3 5 0t5 0t3-1.5"/>' +
    '<path d="M1.5 11q2.5-3 5 0t5 0t3-1.5"/></g>'
  );

  const ICON_DB = svgWrap(
    '<path d="M2.5 4v8.2c0 1.3 2.5 2.3 5.5 2.3s5.5-1 5.5-2.3V4" fill="#e38c00"/>' +
    '<ellipse cx="8" cy="4" rx="5.5" ry="2.3" fill="#f0a830"/>'
  );

  const ICON_MD = svgWrap(
    '<rect x="1" y="2" width="14" height="12" rx="2.2" fill="#519aba"/>' +
    `<text x="8" y="11.3" text-anchor="middle" ${ICON_FONT} font-size="6" font-weight="800" fill="#fff">M↓</text>`
  );

  const ICON_NPM = svgWrap(
    '<rect x="1" y="2" width="14" height="12" rx="2.2" fill="#cb3837"/>' +
    `<text x="8" y="11.5" text-anchor="middle" ${ICON_FONT} font-size="8.5" font-weight="800" fill="#fff">n</text>`
  );

  function imgIcon(color) {
    return svgWrap(
      `<circle cx="5.5" cy="5" r="1.7" fill="${color}" opacity="0.75"/>` +
      `<path d="M2.5 13l3.5-4.5L9 12l2-2.5L13.5 13z" fill="${color}"/>`
    );
  }

  function tableIcon(color) {
    return svgWrap(
      `<g fill="none" stroke="${color}" stroke-width="1.3">` +
      '<rect x="2" y="3" width="12" height="10" rx="1.2"/>' +
      '<path d="M2 6.7h12M2 10.3h12M7.3 3v10"/></g>'
    );
  }

  const ICON_DOC = svgWrap(
    '<path fill="#90a4ae" d="M3.5 1.5h6.2L13 4.8v9.2a1 1 0 0 1-1 1H3.5a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1z"/>' +
    '<path fill="#c3ccd4" d="M9.7 1.5v3.3H13z"/>'
  );

  function extOf(name) {
    const n = name.toLowerCase();
    if (n.startsWith(".git")) return "gitfile";
    if (n === ".env" || n.startsWith(".env.")) return "dotenv";
    const i = n.lastIndexOf(".");
    return i > 0 ? n.slice(i + 1) : "";
  }

  const EXT_ICON_MAP = {
    ts: boxIcon("TS", "#3178c6"), mts: boxIcon("TS", "#3178c6"), cts: boxIcon("TS", "#3178c6"),
    tsx: ICON_REACT, jsx: ICON_REACT,
    js: boxIcon("JS", "#f1e05a", "#20240a"), mjs: boxIcon("JS", "#f1e05a", "#20240a"), cjs: boxIcon("JS", "#f1e05a", "#20240a"),
    json: glyphIcon("{}", "#cbcb41", 9), jsonc: glyphIcon("{}", "#cbcb41", 9),
    rb: ICON_RUBY, rake: ICON_RUBY, erb: ICON_RUBY, gemspec: ICON_RUBY,
    py: boxIcon("PY", "#3572a5"),
    go: boxIcon("GO", "#00add8"),
    rs: boxIcon("RS", "#dea584"),
    java: boxIcon("J", "#b07219"), kt: boxIcon("K", "#a97bff"), kts: boxIcon("K", "#a97bff"),
    swift: boxIcon("SW", "#f05138"),
    c: boxIcon("C", "#283593"), h: boxIcon("H", "#55606a"),
    cpp: boxIcon("C+", "#f34b7d"), hpp: boxIcon("C+", "#f34b7d"), cc: boxIcon("C+", "#f34b7d"), hh: boxIcon("C+", "#f34b7d"),
    css: glyphIcon("#", "#519aba", 12), less: glyphIcon("#", "#519aba", 12),
    scss: glyphIcon("#", "#c6538c", 12), sass: glyphIcon("#", "#c6538c", 12),
    html: glyphIcon("<>", "#e44d26", 8.5), htm: glyphIcon("<>", "#e44d26", 8.5),
    vue: boxIcon("V", "#41b883"), svelte: boxIcon("S", "#ff3e00"),
    md: ICON_MD, mdx: ICON_MD, markdown: ICON_MD,
    yml: glyphIcon("Y", "#a074c4", 12), yaml: glyphIcon("Y", "#a074c4", 12),
    toml: boxIcon("T", "#9c4221"), ini: boxIcon("I", "#9c4221"), conf: boxIcon("C", "#9c4221"), config: boxIcon("C", "#9c4221"),
    sh: glyphIcon("$", "#89e051", 12), bash: glyphIcon("$", "#89e051", 12), zsh: glyphIcon("$", "#89e051", 12), fish: glyphIcon("$", "#89e051", 12),
    svg: imgIcon("#ffb13b"),
    png: imgIcon("#a074c4"), jpg: imgIcon("#a074c4"), jpeg: imgIcon("#a074c4"),
    gif: imgIcon("#a074c4"), webp: imgIcon("#a074c4"), ico: imgIcon("#a074c4"), bmp: imgIcon("#a074c4"),
    pdf: boxIcon("P", "#e04b4b"),
    zip: boxIcon("Z", "#dba15d"), tar: boxIcon("Z", "#dba15d"), gz: boxIcon("Z", "#dba15d"),
    "7z": boxIcon("Z", "#dba15d"), rar: boxIcon("Z", "#dba15d"), dmg: boxIcon("Z", "#dba15d"), iso: boxIcon("Z", "#dba15d"),
    lock: ICON_LOCK,
    sql: ICON_DB,
    csv: tableIcon("#89e051"), tsv: tableIcon("#89e051"),
    ttf: glyphIcon("A", "#d4157f", 12), otf: glyphIcon("A", "#d4157f", 12),
    woff: glyphIcon("A", "#d4157f", 12), woff2: glyphIcon("A", "#d4157f", 12),
    gitfile: ICON_GIT,
    dotenv: boxIcon("E", "#ecd53f", "#3a3000"),
  };

  function fileIconSvg(name) {
    const n = name.toLowerCase();
    if (n === "package.json" || n === "package-lock.json" || n === "npm-shrinkwrap.json") return ICON_NPM;
    if (n.startsWith("vite.config")) return ICON_ZAP;
    if (n.startsWith("tailwind.config")) return ICON_WAVE;
    if (n.startsWith("postcss.config")) return boxIcon("P", "#dd3a0a");
    if (n.startsWith("eslint.config")) return boxIcon("E", "#4b32c3");
    if (n.startsWith("webpack.config")) return boxIcon("W", "#1c78c0");
    if (n.startsWith("next.config")) return boxIcon("N", "#111827");
    if (n === "dockerfile" || n.startsWith("dockerfile.")) return boxIcon("D", "#0db7ed");
    if (n === "gemfile" || n === "rustfile") return ICON_RUBY;
    if (n === "makefile" || n.startsWith("makefile.")) return boxIcon("M", "#6d8086");
    if (n.startsWith("license") || n.startsWith("licence") || n.startsWith("copying")) return ICON_DOC;
    return EXT_ICON_MAP[extOf(name)] || ICON_DOC;
  }


  // ── File tree ───────────────────────────────────────────────────────────

  const treeState = { activePath: null, treeEl: null, indexPromise: null };

  function highlightActiveRow() {
    const tree = treeState.treeEl;
    if (!tree) return;
    tree.querySelectorAll(".wt-row.active").forEach((r) => r.classList.remove("active"));
    if (!treeState.activePath) return;
    const row = tree.querySelector(`.wt-row[data-path="${CSS.escape(treeState.activePath)}"]`);
    if (row) {
      row.classList.add("active");
      row.scrollIntoView({ block: "nearest" });
    }
  }

  function setActiveFilePath(path) {
    treeState.activePath = path;
    highlightActiveRow();
  }

  let lastGuidedRow = null;

  function updateIndentGuides(row) {
    const tree = treeState.treeEl;
    if (!tree) return;
    if (row === lastGuidedRow) return;
    lastGuidedRow = row;
    tree.querySelectorAll(".wt-children.guide-on").forEach((c) => c.classList.remove("guide-on"));
    if (!row) return;
    let p = row.parentElement;
    while (p && p !== tree) {
      if (p.classList.contains("wt-children")) p.classList.add("guide-on");
      p = p.parentElement;
    }
  }

  function renderEntries(entries, openFile) {
    const frag = document.createDocumentFragment();
    if (!entries.length) {
      const empty = document.createElement("div");
      empty.className = "wt-empty";
      empty.textContent = t("workspace.empty");
      frag.appendChild(empty);
      return frag;
    }
    for (const entry of entries) frag.appendChild(buildNode(entry, openFile));
    return frag;
  }

  function buildNode(entry, openFile) {
    const node = document.createElement("div");
    node.className = "wt-node";
    node.dataset.type = entry.type;

    const row = document.createElement("div");
    row.className = "wt-row";
    row.title = entry.name;
    row.dataset.path = entry.path;

    const caret = document.createElement("span");
    caret.className = "wt-caret" + (entry.type === "dir" ? "" : " leaf");
    if (entry.type === "dir") caret.innerHTML = ICON_CARET;

    const icon = document.createElement("span");
    icon.className = "wt-icon";
    if (entry.type === "dir") {
      icon.innerHTML = ICON_FOLDER;
    } else {
      icon.innerHTML = fileIconSvg(entry.name);
    }

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
      row.addEventListener("click", () => toggleDir(entry, caret, children, icon, openFile));
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

    const iconRelPath  = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/><path d="M12 19l3-3"/></svg>';

    const downloadItem = entry.type === "file" ? `
      <div class="session-actions-menu-item" data-action="download">
        <span class="session-actions-menu-icon">${ICON_DOWNLOAD}</span>
        <span class="session-actions-menu-label">${t("workspace.download")}</span>
      </div>` : "";

    const menu = document.createElement("div");
    menu.className = "wt-context-menu session-context-menu";
    menu.innerHTML = `
      <div class="session-actions-menu-item" data-action="reveal">
        <span class="session-actions-menu-icon">${ICON_FOLDER}</span>
        <span class="session-actions-menu-label">${t("workspace.revealInFinder")}</span>
      </div>
      <div class="session-actions-menu-item" data-action="copypath">
        <span class="session-actions-menu-icon">${ICON_COPY}</span>
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

  async function toggleDir(entry, caret, children, iconEl, openFile) {
    const isOpen = caret.classList.contains("open");
    if (isOpen) {
      caret.classList.remove("open");
      children.style.display = "none";
      if (iconEl) iconEl.innerHTML = ICON_FOLDER;
      return;
    }
    caret.classList.add("open");
    children.style.display = "";
    if (iconEl) iconEl.innerHTML = ICON_FOLDER_OPEN;
    if (children.dataset.loaded === "1") return;

    children.innerHTML = `<div class="wt-loading">${t("workspace.loading")}</div>`;
    try {
      const entries = await Workspace.fetchEntries(entry.path);
      children.innerHTML = "";
      children.appendChild(renderEntries(entries, openFile));
      children.dataset.loaded = "1";
      highlightActiveRow();
    } catch (err) {
      console.error("workspace load failed:", err);
      children.innerHTML = `<div class="wt-error">${t("workspace.error")}</div>`;
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

  async function loadRoot(tree, openFile) {
    if (!tree || !Workspace.state.hasSession()) return;
    tree.innerHTML = `<div class="wt-loading">${t("workspace.loading")}</div>`;
    try {
      const entries = await Workspace.fetchEntries("");
      tree.innerHTML = "";
      tree.appendChild(renderEntries(entries, openFile));
    } catch (err) {
      console.error("workspace load failed:", err);
      tree.innerHTML = `<div class="wt-error">${t("workspace.error")}</div>`;
    }
  }

  // ── Inline tabbed viewer ────────────────────────────────────────────────

  // The tree + viewer split needs horizontal room; widen the aside once when
  // the first file is opened (still user-resizable afterwards).
  function ensureAsideWidth() {
    const aside = document.getElementById("session-aside");
    if (!aside) return;
    let w = 0;
    try {
      w = parseFloat(getComputedStyle(aside).getPropertyValue("--session-aside-width")) || 0;
    } catch (_e) { w = 0; }
    const target = 620;
    if (w < target) {
      aside.style.setProperty("--session-aside-width", target + "px");
      try { localStorage.setItem("clacky.aside.width", String(target)); } catch (_e) { /* non-fatal */ }
    }
  }

  function createViewer(onTabsChanged) {
    const tabs = [];
    let activeId = null;
    const notify = () => { if (onTabsChanged) onTabsChanged({ count: tabs.length, activeId }); };

    const root = el("div", "wv-viewer");

    const tabbar = el("div", "wv-tabbar");
    const tabsEl = el("div", "wv-tabs");
    tabsEl.setAttribute("role", "tablist");
    const actionsEl = el("div", "wv-actions");

    const content = el("div", "wv-content");

    function actionBtn(icon, title, cls) {
      const btn = el("button", "wv-action" + (cls ? " " + cls : ""));
      btn.type = "button";
      btn.title = title;
      btn.innerHTML = icon;
      return btn;
    }

    const previewBtn  = actionBtn(ICON_EYE, t("workspace.preview"));
    const copyBtn     = actionBtn(ICON_COPY, t("workspace.copyContent"));
    const downloadBtn = actionBtn(ICON_DOWNLOAD, t("workspace.download"));
    const saveBtn     = actionBtn(ICON_SAVE, t("modal.save"));
    actionsEl.appendChild(previewBtn);
    actionsEl.appendChild(copyBtn);
    actionsEl.appendChild(downloadBtn);
    actionsEl.appendChild(saveBtn);

    tabbar.appendChild(tabsEl);
    tabbar.appendChild(actionsEl);

    root.appendChild(tabbar);
    root.appendChild(content);

    const activeTab = () => tabs.find((x) => x.id === activeId) || null;

    function rebuildTabbar() {
      tabsEl.replaceChildren();
      tabs.forEach((tab) => {
        const btn = el("button", "wv-tab" + (tab.id === activeId ? " active" : ""));
        btn.type = "button";
        btn.title = tab.entry.path;
        btn.setAttribute("role", "tab");

        const label = el("span", "wv-tab-label");
        label.textContent = tab.entry.name;

        const dot = el("span", "wv-tab-dot");
        dot.style.display = tab.dirty ? "" : "none";

        const close = el("span", "wv-tab-close");
        close.innerHTML = ICON_CLOSE;
        close.title = t("workspace.closeTab");

        btn.appendChild(label);
        btn.appendChild(dot);
        btn.appendChild(close);

        btn.addEventListener("click", (e) => {
          if (e.target.closest(".wv-tab-close")) return;
          activate(tab.id);
        });
        close.addEventListener("click", (e) => {
          e.stopPropagation();
          closeTab(tab.id);
        });
        btn.addEventListener("auxclick", (e) => {
          if (e.button === 1) closeTab(tab.id);
        });

        tabsEl.appendChild(btn);
      });
    }

    function updateActions() {
      const tab = activeTab();
      previewBtn.style.display  = tab && tab.kind === "text" && tab.isMd ? "" : "none";
      copyBtn.style.display     = tab && tab.kind === "text" ? "" : "none";
      saveBtn.style.display     = tab && tab.kind === "text" ? "" : "none";
      downloadBtn.style.display = tab ? "" : "none";
      previewBtn.classList.toggle("active", !!(tab && tab.previewMode));
      saveBtn.classList.toggle("dirty", !!(tab && tab.dirty));
    }

    function activate(id) {
      activeId = id;
      tabs.forEach((tab) => tab.el.classList.toggle("active", tab.id === id));
      rebuildTabbar();
      updateActions();
      notify();
      const tab = activeTab();
      if (tab && tab.editor) {
        setTimeout(() => {
          tab.editor.view.focus();
          tab.editor.view.requestMeasure();
        }, 0);
      }
    }

    async function closeTab(id) {
      const idx = tabs.findIndex((x) => x.id === id);
      if (idx < 0) return;
      const tab = tabs[idx];
      if (tab.dirty) {
        const ok = await Modal.confirm(t("workspace.dirtyCloseConfirm"));
        if (!ok) return;
      }
      if (tab.editor) tab.editor.destroy();
      if (tab.imageUrl) URL.revokeObjectURL(tab.imageUrl);
      tab.el.remove();
      tabs.splice(idx, 1);
      if (activeId === id) {
        const next = tabs[Math.min(idx, tabs.length - 1)];
        activate(next ? next.id : null);
      } else {
        rebuildTabbar();
      }
      notify();
    }

    function syncDirty(tab) {
      rebuildTabbar();
      updateActions();
    }

    async function doSave(tab) {
      if (!tab.editor) return;
      try {
        await Workspace.saveFileText(tab.entry, tab.editor.getContent());
        tab.dirty = false;
        syncDirty(tab);
        Modal.toast(t("workspace.saved"), "info");
      } catch (err) {
        console.error("save failed:", err);
        Modal.toast(t("workspace.saveFailed"), "error");
      }
    }

    function togglePreview(tab) {
      tab.previewMode = !tab.previewMode;
      tab.el.dataset.mode = tab.previewMode ? "preview" : "edit";
      if (tab.previewMode && tab.editor) {
        tab.previewEl.innerHTML = CodeEditor.renderMarkdown(tab.editor.getContent());
      }
      updateActions();
    }

    function buildTextTab(entry, text) {
      const pane = el("div", "wv-pane wv-pane--text");
      pane.dataset.mode = "edit";

      const lang = CodeEditor.detectLanguage(entry.name);
      const isMd = lang === "markdown";

      const code = el("div", "wv-code");
      pane.appendChild(code);

      const tab = {
        id: entry.path,
        entry,
        kind: "text",
        el: pane,
        dirty: false,
        isMd,
        previewMode: false,
        previewEl: null,
        editor: null,
        imageUrl: null,
      };

      if (isMd) {
        const preview = el("div", "wv-md-preview code-editor-markdown-preview");
        pane.appendChild(preview);
        tab.previewEl = preview;
      }

      tab.editor = CodeEditor.createInline(code, {
        content: text,
        language: lang,
        onChange: () => {
          if (!tab.dirty) {
            tab.dirty = true;
            syncDirty(tab);
          }
        },
        onSave: () => doSave(tab),
      });

      return tab;
    }

    function buildImageTab(entry, url) {
      const pane = el("div", "wv-pane wv-pane--image");
      const img = document.createElement("img");
      img.alt = entry.name;
      img.src = url;
      pane.appendChild(img);
      return {
        id: entry.path,
        entry,
        kind: "image",
        el: pane,
        dirty: false,
        isMd: false,
        previewMode: false,
        previewEl: null,
        editor: null,
        imageUrl: url,
      };
    }

    async function openTab(entry) {
      ensureAsideWidth();
      const existing = tabs.find((x) => x.id === entry.path);
      if (existing) {
        activate(existing.id);
        return;
      }
      const kind = CodeEditor.fileKind(entry.name);
      if (kind === "binary") {
        Modal.toast(t("workspace.previewUnsupported"), "info");
        return;
      }
      let tab = null;
      try {
        if (kind === "image") {
          const blob = await Workspace.fetchFileBlob(entry);
          tab = buildImageTab(entry, URL.createObjectURL(blob));
        } else {
          const text = await Workspace.fetchFileText(entry);
          tab = buildTextTab(entry, text);
        }
      } catch (err) {
        console.error("preview failed:", err);
        Modal.toast(t("workspace.previewFailed"), "error");
        return;
      }
      tabs.push(tab);
      content.appendChild(tab.el);
      activate(tab.id);
      notify();
    }

    previewBtn.addEventListener("click", () => {
      const tab = activeTab();
      if (tab && tab.isMd) togglePreview(tab);
    });
    copyBtn.addEventListener("click", async () => {
      const tab = activeTab();
      if (!tab || !tab.editor) return;
      try {
        await navigator.clipboard.writeText(tab.editor.getContent());
        Modal.toast(t("workspace.copied"), "info");
      } catch (err) {
        Modal.toast(t("workspace.copyFailed"), "error");
      }
    });
    downloadBtn.addEventListener("click", () => {
      const tab = activeTab();
      if (tab) downloadFile(tab.entry);
    });
    saveBtn.addEventListener("click", () => {
      const tab = activeTab();
      if (tab) doSave(tab);
    });

    function destroy() {
      tabs.forEach((tab) => {
        if (tab.editor) tab.editor.destroy();
        if (tab.imageUrl) URL.revokeObjectURL(tab.imageUrl);
      });
      tabs.length = 0;
      activeId = null;
    }

    return { root, openTab, destroy };
  }

  // Build the Files tab body for the current session: file tree on the left,
  // tabbed viewer on the right. Mutates `container` and returns a destroy()
  // that frees CodeMirror instances and blob URLs when the tab is re-rendered
  // or the session switches.
  function mount(container, _ctx) {
    const root = el("div", "wv-root");

    const treePane = el("div", "wv-tree-pane");

    const bar = el("div", "wt-bar");

    const searchWrap = el("div", "wt-search");
    const searchIcon = el("span", "wt-search-icon");
    searchIcon.innerHTML = '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>';
    const searchInput = el("input", "wt-search-input");
    searchInput.type = "text";
    searchInput.placeholder = t("workspace.search");
    searchInput.setAttribute("aria-label", t("workspace.search"));
    const searchClear = el("button", "wt-search-clear");
    searchClear.type = "button";
    searchClear.title = t("workspace.closeTab");
    searchClear.innerHTML = ICON_CLOSE;
    searchWrap.appendChild(searchIcon);
    searchWrap.appendChild(searchInput);
    searchWrap.appendChild(searchClear);

    const refresh = el("button", "wt-bar-btn");
    refresh.type = "button";
    refresh.title = t("workspace.refresh");
    refresh.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><polyline points="21 3 21 9 15 9"/></svg>';
    bar.appendChild(searchWrap);
    bar.appendChild(refresh);

    const tree = el("div", "wt-tree");
    tree.setAttribute("role", "tree");
    treeState.treeEl = tree;

    const searchList = el("div", "wt-search-list");
    searchList.style.display = "none";

    tree.addEventListener("mouseover", (e) => {
      const row = e.target.closest(".wt-row");
      if (row) updateIndentGuides(row);
    });
    tree.addEventListener("mouseleave", () => updateIndentGuides(null));

    const viewer = createViewer(({ count, activeId }) => {
      root.classList.toggle("has-open-files", count > 0);
      setActiveFilePath(activeId);
    });

    // ── File search ─────────────────────────────────────────────────────

    // node_modules/.git hold thousands of vendored files nobody searches for.
    const SKIP_DIRS = { node_modules: true, ".git": true };

    async function buildIndex() {
      if (treeState.indexPromise) return treeState.indexPromise;
      treeState.indexPromise = (async () => {
        const files = [];
        const walk = async (dirPath) => {
          let entries;
          try { entries = await Workspace.fetchEntries(dirPath); } catch (_e) { return; }
          await Promise.all(entries.map(async (entry) => {
            if (entry.type === "dir") {
              if (!SKIP_DIRS[entry.name]) await walk(entry.path);
            } else {
              files.push(entry);
            }
          }));
        };
        await walk("");
        return files;
      })();
      return treeState.indexPromise;
    }

    function escapeHtml(s) {
      return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
    }

    function highlightMatch(text, q) {
      const idx = text.toLowerCase().indexOf(q.toLowerCase());
      if (idx < 0) return escapeHtml(text);
      return escapeHtml(text.slice(0, idx)) +
        '<mark class="wt-mark">' + escapeHtml(text.slice(idx, idx + q.length)) + "</mark>" +
        escapeHtml(text.slice(idx + q.length));
    }

    function showTree() {
      tree.style.display = "";
      searchList.style.display = "none";
      searchList.replaceChildren();
      searchClear.style.display = "none";
    }

    function renderSearchResults(files, q) {
      tree.style.display = "none";
      searchList.style.display = "";
      searchList.replaceChildren();
      if (!files.length) {
        const no = el("div", "wt-empty");
        no.textContent = t("workspace.noResults");
        searchList.appendChild(no);
        return;
      }
      const frag = document.createDocumentFragment();
      for (const f of files) {
        const row = el("div", "wt-row wt-search-row");
        row.title = f.path;
        const icon = el("span", "wt-icon");
        icon.innerHTML = fileIconSvg(f.name);
        const name = el("span", "wt-name");
        name.innerHTML = highlightMatch(f.name, q);
        const dir = el("span", "wt-search-dir");
        dir.textContent = f.path.includes("/") ? f.path.slice(0, f.path.lastIndexOf("/")) : "";
        row.appendChild(icon);
        row.appendChild(name);
        row.appendChild(dir);
        row.addEventListener("click", () => viewer.openTab(f));
        frag.appendChild(row);
      }
      searchList.appendChild(frag);
    }

    async function runSearch(q) {
      searchClear.style.display = q ? "inline-flex" : "none";
      if (!q) { showTree(); return; }
      const files = await buildIndex();
      if (searchInput.value.trim() !== q) return;
      const ql = q.toLowerCase();
      const scored = [];
      for (const f of files) {
        const nameL = f.name.toLowerCase();
        const pathL = f.path.toLowerCase();
        let score;
        if (nameL.startsWith(ql)) score = 0;
        else if (nameL.includes(ql)) score = 1;
        else if (pathL.includes(ql)) score = 2;
        else continue;
        scored.push({ f, score, depth: f.path.split("/").length });
      }
      scored.sort((a, b) => a.score - b.score || a.depth - b.depth || a.f.path.localeCompare(b.f.path));
      renderSearchResults(scored.map((s) => s.f).slice(0, 200), q);
    }

    let searchTimer = null;
    searchInput.addEventListener("input", () => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => { runSearch(searchInput.value.trim()); }, 200);
    });
    searchInput.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && searchInput.value) {
        searchInput.value = "";
        showTree();
      }
    });
    searchClear.addEventListener("click", () => {
      searchInput.value = "";
      searchInput.focus();
      showTree();
    });

    refresh.addEventListener("click", () => {
      treeState.indexPromise = null;
      searchInput.value = "";
      showTree();
      loadRoot(tree, viewer.openTab);
    });

    treePane.appendChild(bar);
    treePane.appendChild(tree);
    treePane.appendChild(searchList);

    root.appendChild(treePane);
    root.appendChild(viewer.root);
    container.appendChild(root);

    loadRoot(tree, viewer.openTab);
    return {
      destroy() {
        clearTimeout(searchTimer);
        treeState.treeEl = null;
        treeState.activePath = null;
        treeState.indexPromise = null;
        lastGuidedRow = null;
        viewer.destroy();
      },
    };
  }

  return { mount };
})();

// Files is a built-in tab: visible for every session, after ext-studio
// publish (20) and before git (30) / time-machine (40).
if (window.Clacky && Clacky.ext) {
  Clacky.ext.ui.mountBuiltin("session.aside", (container, ctx) => {
    const viewer = WorkspaceView.mount(container, ctx);
    return () => viewer.destroy();
  }, {
    order: 25,
    tab: { id: "files", label: () => (typeof I18n !== "undefined" ? I18n.t("workspace.title") : "Files") },
  });
}

// Keep the store's session context in sync (sessions.js still calls
// Workspace.onSession on every session switch). Rendering is driven by the
// slot re-render, so this only updates state.
Workspace.onSession = (session) => { Workspace.setSession(session); };
