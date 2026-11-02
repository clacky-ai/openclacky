// Cross-browser IME composition guard for Enter-to-submit inputs.
//
// Problem: pressing Enter to confirm an IME composition (e.g. selecting a
// Chinese candidate) must NOT trigger submit. Different browsers signal this
// differently:
//   - Chrome / Firefox / Edge: e.isComposing === true on the confirming Enter
//   - Older browsers: e.keyCode === 229
//   - Safari: fires compositionend ~5ms BEFORE keydown, so isComposing is
//     already false. We need a recent compositionend timestamp to suppress.
//
// Reference: https://bugs.webkit.org/show_bug.cgi?id=165004
//
// Usage:
//   IME.bindEnter(inputEl, () => submit());
//
// Or low-level for handlers that already own a keydown listener:
//   const ime = IME.track(inputEl);
//   inputEl.addEventListener("keydown", e => {
//     if (e.key === "Enter" && !ime.isComposing(e)) submit();
//   });
const IME = (() => {
  const SAFARI_GUARD_MS = 20;

  function track(inputEl) {
    let lastCompositionEnd = -Infinity;
    const onEnd = () => { lastCompositionEnd = Date.now(); };
    inputEl.addEventListener("compositionend", onEnd);

    return {
      isComposing(e) {
        if (e.isComposing || e.keyCode === 229) return true;
        return Date.now() - lastCompositionEnd <= SAFARI_GUARD_MS;
      },
      dispose() {
        inputEl.removeEventListener("compositionend", onEnd);
      }
    };
  }

  function bindEnter(inputEl, handler, options = {}) {
    const ime = track(inputEl);
    const onKey = (e) => {
      if (e.key !== "Enter") return;
      if (options.allowShift !== true && e.shiftKey) return;
      if (ime.isComposing(e)) return;
      e.preventDefault();
      handler(e);
    };
    inputEl.addEventListener("keydown", onKey);
    return () => {
      inputEl.removeEventListener("keydown", onKey);
      ime.dispose();
    };
  }

  return { track, bindEnter };
})();

// Compact, non-interactive Markdown for short previews. Only inline formatting
// is emitted; raw HTML and images cannot introduce active content.
const MarkdownPreview = (() => {
  function render(text) {
    if (!text) return "";
    if (typeof marked === "undefined") return escapeHtml(text);

    const renderer = new marked.Renderer();
    renderer.html = renderer.image = renderer.checkbox = () => "";
    renderer.hr = renderer.br = () => " ";
    renderer.link = function({ tokens }) { return this.parser.parseInline(tokens); };
    renderer.paragraph = renderer.heading = function({ tokens }) {
      return this.parser.parseInline(tokens) + " ";
    };
    renderer.blockquote = renderer.listitem = function({ tokens }) {
      return this.parser.parse(tokens).trim() + " ";
    };
    renderer.list = function({ items }) {
      return items.map(item => this.listitem(item)).join("");
    };
    renderer.table = function({ header, rows }) {
      return [header, ...rows].map(row => row.map(cell => this.parser.parseInline(cell.tokens)).join(" ")).join(" ") + " ";
    };
    renderer.code = function({ text }) { return `<code>${escapeHtml(text)}</code> `; };
    try {
      return marked.parse(text, { gfm: true, breaks: false, renderer }).trim();
    } catch (_) {
      return escapeHtml(text);
    }
  }

  return { render };
})();

// Gradient tile with the label's first character; `seed` keeps the colour
// stable when the label is localized.
function letterIcon(label, seed) {
  const text = label || "?";
  const letter = text[0].toUpperCase();
  const cjk = /[\u3400-\u9fff]/.test(letter);
  const fontSize = cjk ? 14 : 16;
  const fontWeight = cjk ? 500 : 700;
  const colors = [
    ["#6366f1","#818cf8"], ["#8b5cf6","#a78bfa"], ["#ec4899","#f472b6"],
    ["#f59e0b","#fbbf24"], ["#10b981","#34d399"], ["#3b82f6","#60a5fa"],
    ["#ef4444","#f87171"], ["#14b8a6","#2dd4bf"],
  ];
  const idx = (seed || text).charCodeAt(0) % colors.length;
  const [c1, c2] = colors[idx];
  const gid = `eg-${idx}-${Math.random().toString(36).slice(2,7)}`;
  const safe = letter.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return `<span class="extension-emoji"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" class="extension-default-icon"><defs><linearGradient id="${gid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="${c1}"/><stop offset="100%" stop-color="${c2}"/></linearGradient></defs><rect width="32" height="32" rx="8" fill="url(#${gid})"/><text x="16" y="22" text-anchor="middle" font-family="system-ui,sans-serif" font-size="${fontSize}" font-weight="${fontWeight}" fill="white">${safe}</text></svg></span>`;
}

const Tooltip = (() => {
  const GAP = 8;
  let el = null;
  let _hideTimer = null;

  function _el() {
    if (!el) el = document.getElementById("tooltip");
    return el;
  }

  function show(anchor) {
    const tip = _el();
    if (!tip) return;
    clearTimeout(_hideTimer);

    const text = anchor.getAttribute("data-tooltip");
    if (!text) return;
    if (anchor.hasAttribute("data-tooltip-overflow") && anchor.scrollWidth <= anchor.clientWidth) return;

    const pos = anchor.getAttribute("data-tooltip-pos") || "top";
    tip.textContent = text;
    tip.setAttribute("data-pos", pos);
    tip.style.display = "block";
    // Measure from the left edge: leaving the previous anchor's `left` in place
    // shrinks the available width, so a tip next to the right edge wraps early.
    tip.style.left = "0px";
    tip.style.top = "0px";

    const r = anchor.getBoundingClientRect();
    const tw = tip.offsetWidth;
    const th = tip.offsetHeight;

    let top, left;
    if (pos === "bottom") {
      top  = r.bottom + GAP;
      left = r.left + r.width / 2 - tw / 2;
    } else if (pos === "left") {
      top  = r.top + r.height / 2 - th / 2;
      left = r.left - tw - GAP;
    } else if (pos === "right") {
      top  = r.top + r.height / 2 - th / 2;
      left = r.right + GAP;
    } else {
      top  = r.top - th - GAP;
      left = r.left + r.width / 2 - tw / 2;
    }

    left = Math.max(6, Math.min(left, window.innerWidth  - tw - 6));
    top  = Math.max(6, Math.min(top,  window.innerHeight - th - 6));

    tip.style.left = `${left}px`;
    tip.style.top  = `${top}px`;
    requestAnimationFrame(() => tip.classList.add("visible"));
  }

  function hide() {
    const tip = _el();
    if (!tip) return;
    tip.classList.remove("visible");
    _hideTimer = setTimeout(() => { tip.style.display = "none"; }, 120);
  }

  // Anchor that was clicked; stays silent until the pointer leaves it so the
  // tip does not cover the menu or popover the click just opened.
  let _suppressed = null;

  function init() {
    document.addEventListener("mouseover", (e) => {
      const anchor = e.target.closest("[data-tooltip]");
      if (anchor && anchor !== _suppressed) show(anchor);
    });
    document.addEventListener("mouseout", (e) => {
      const anchor = e.target.closest("[data-tooltip]");
      if (!anchor) return;
      if (anchor.contains(e.relatedTarget)) return;
      if (anchor === _suppressed) _suppressed = null;
      hide();
    });
    document.addEventListener("pointerdown", (e) => {
      const anchor = e.target.closest && e.target.closest("[data-tooltip]");
      _suppressed = anchor || null;
      hide();
    }, true);
  }

  return { init, show, hide };
})();

// "Open with" submenu attached to a row of any context menu.
//
// The file tree and the Git panel both list files, so both offer this entry.
// The hover timing, the edge-flip maths and the app-icon rows live here once
// instead of being reimplemented per panel.
//
//   OpenWith.mount(rowEl, { path: "app/models/user.rb" }, { menu: menuEl });
//
// The row keeps its caller-provided icon and label; mount() adds the chevron
// and the submenu. Apps come from the backend (macOS scan, cached per process)
// so a file type with no registered handler shows a hint rather than an empty
// popup.
const OpenWith = (() => {
  const HIDE_DELAY = 200;
  const CHEVRON = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18l6-6-6-6"/></svg>';

  let active = null; // { row, submenu, timer }
  let cache = new Map(); // entry path => Promise<{ apps, defaultApp }>

  function tr(key, fallback) {
    if (typeof I18n === "undefined") return fallback;
    const value = I18n.t(key);
    return value && value !== key ? value : fallback;
  }

  function make(tag, cls) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    return node;
  }

  function absEntry(entry) {
    const workspace = window.Clacky && Clacky.Workspace;
    const path = workspace && workspace.absPath ? workspace.absPath(entry.path) : entry.path;
    return { path: path, name: entry.name || String(entry.path).split("/").pop() };
  }

  function fetchApps(entry) {
    const workspace = window.Clacky && Clacky.Workspace;
    if (!workspace || typeof workspace.fetchOpenWithApps !== "function") {
      return Promise.resolve({ apps: [], defaultApp: null });
    }
    const target = absEntry(entry);
    if (!cache.has(target.path)) {
      cache.set(target.path, Promise.all([
        workspace.fetchOpenWithApps(target),
        workspace.fetchDefaultApp(target)
      ]).then(([apps, defaultApp]) => ({ apps: apps || [], defaultApp: defaultApp || null }))
        .catch(() => ({ apps: [], defaultApp: null })));
    }
    return cache.get(target.path);
  }

  function dismissMenu(row) {
    const menu = row.closest(".session-context-menu");
    if (menu && menu.parentNode) menu.remove();
    close();
  }

  function pick(row, entry, appPath) {
    const workspace = window.Clacky && Clacky.Workspace;
    dismissMenu(row);
    if (!workspace || typeof workspace.openWithApp !== "function") return;
    workspace.openWithApp(absEntry(entry), appPath).catch((err) => {
      if (typeof Modal === "undefined") return;
      const reason = err && err.message ? ": " + err.message : "";
      Modal.toast(tr("workspace.openWithFailed", "Could not open the file") + reason, "error");
    });
  }

  // Menu rows for every app that claims this file type. Both the submenu and
  // the viewer's "Open with" button render from here, so an app list looks the
  // same wherever it appears. `base` picks the menu-item class family.
  function appRows(entry, onPick, opts) {
    const base = (opts && opts.base) || "session-actions-submenu";
    return fetchApps(entry).then((data) => data.apps.map((app) => {
      const isDefault = !!(data.defaultApp && data.defaultApp.path === app.path);
      const item = make("div", base + "-item" + (isDefault ? " is-default" : ""));
      if (isDefault) item.title = tr("workspace.openDefault", "Open with default app");
      const icon = make("span", base + "-icon menu-app-icon");
      const img = document.createElement("img");
      img.alt = "";
      img.src = "/api/app-icon?path=" + encodeURIComponent(app.path);
      img.addEventListener("error", () => { img.remove(); });
      icon.appendChild(img);
      const label = make("span", base + "-label");
      label.textContent = app.name;
      item.appendChild(icon);
      item.appendChild(label);
      item.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        onPick(app);
      });
      return item;
    }));
  }

  function place(row, submenu) {
    const host = row.closest(".session-context-menu") || row.parentElement || document.body;
    const rowRect = row.getBoundingClientRect();
    const hostRect = host.getBoundingClientRect();
    submenu.style.position = "fixed";
    submenu.style.display = "block";
    const subRect = submenu.getBoundingClientRect();
    let left = hostRect.right;
    if (left + subRect.width > window.innerWidth - 8) {
      left = Math.max(8, hostRect.left - subRect.width);
    }
    let top = rowRect.top;
    if (top + subRect.height > window.innerHeight - 8) {
      top = Math.max(8, window.innerHeight - subRect.height - 8);
    }
    submenu.style.left = left + "px";
    submenu.style.top = top + "px";
  }

  function hideNow() {
    if (!active) return;
    clearTimeout(active.timer);
    active.submenu.style.display = "none";
    active.row.classList.remove("active");
  }

  function hideSoon() {
    if (!active) return;
    clearTimeout(active.timer);
    active.timer = setTimeout(hideNow, HIDE_DELAY);
  }

  function close() {
    if (!active) return;
    clearTimeout(active.timer);
    if (active.submenu.parentNode) active.submenu.remove();
    active.row.classList.remove("active");
    active = null;
  }

  function mount(row, entry, opts) {
    const host = (opts && opts.menu) || row.closest(".session-context-menu") || document.body;
    const submenu = make("div", "session-actions-submenu");
    submenu.style.display = "none";
    host.appendChild(submenu);

    row.classList.add("session-actions-menu-item--has-submenu");
    if (!row.querySelector(".session-actions-menu-arrow")) {
      const arrow = make("span", "session-actions-menu-arrow");
      arrow.innerHTML = CHEVRON;
      row.appendChild(arrow);
    }

    let rendered = false;
    const load = () => appRows(entry, (app) => pick(row, entry, app.path)).then((rows) => {
      if (!submenu.parentNode) return;
      submenu.replaceChildren();
      if (rows.length) {
        rows.forEach((node) => submenu.appendChild(node));
      } else {
        const hint = make("div", "session-actions-submenu-hint");
        hint.textContent = tr("workspace.openWithEmpty", "No app can open this file");
        submenu.appendChild(hint);
      }
      rendered = true;
      if (submenu.style.display === "block") place(row, submenu);
    });
    const loaded = load();

    const open = () => {
      if (active && active.row !== row) close();
      if (!active) active = { row: row, submenu: submenu, timer: null };
      clearTimeout(active.timer);
      row.classList.add("active");
      submenu.style.display = "block";
      place(row, submenu);
      if (!rendered) loaded.then(() => { if (submenu.style.display === "block") place(row, submenu); });
    };

    row.addEventListener("mouseenter", open);
    row.addEventListener("mouseleave", hideSoon);
    submenu.addEventListener("mouseenter", () => { if (active) clearTimeout(active.timer); });
    submenu.addEventListener("mouseleave", hideSoon);

    // A click on the row expands the submenu instead of closing the whole menu,
    // which is what makes the entry usable without a pointer.
    row.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (submenu.style.display === "block") hideNow(); else open();
    });

    // Sliding onto a sibling row folds this one away, so two submenus are
    // never open at once.
    host.addEventListener("mouseover", (e) => {
      if (!active || active.row !== row) return;
      const sibling = e.target.closest && e.target.closest(".session-actions-menu-item");
      if (sibling && sibling !== row) hideNow();
    });

    return { open: open, close: close };
  }

  return { mount: mount, appRows: appRows, close: close };
})();
