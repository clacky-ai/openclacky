// ── Official panel: live preview ──────────────────────────────────────────
//
// "预览 / Preview": a mini browser view of workspace HTML files (served by
// GET /preview/s/<session>/<rel>) and of any http(s) URL — dev servers, local
// hosts — loaded straight into the sandboxed iframe. The toolbar mirrors a
// browser chrome: back / forward / reload on the left, a centred address bar,
// open-external on the right. Clicking an HTML file or a localhost URL in the
// chat stream calls Clacky.Preview.open(), which opens the aside, activates
// this tab and (re)loads the page.
//
// Proxied pages (workspace files and dev servers) are served from
// `preview.localhost` instead of the host origin: same server, different
// origin. That keeps them unable to read the host's cookies, localStorage or
// DOM while still giving them a real (non-opaque) origin — an opaque origin
// turns every <script type="module"> into a CORS request that fails, and makes
// localStorage/sessionStorage/cookie throw SecurityError, so any framework
// (Rails+Stimulus, Turbo, React) would render but never become interactive.
// Third-party URLs are loaded directly and only get allow-same-origin when
// they are cross-origin. Because the sandbox hides load errors, the panel HEADs
// the URL first and shows a friendly 404 card instead of a blank frame.
// ───────────────────────────────────────────────────────────────────────────

(() => {
  if (!window.Clacky || !Clacky.ext) return;

  const PREVIEW_ASIDE_WIDTH = 620;
  // Chrome resolves every *.localhost name to loopback, so the preview proxy
  // is reachable under a second origin without a second listener.
  const ISOLATED_PREVIEW_HOST = "preview.localhost";
  const SANDBOX = "allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-modals";
  const ZOOM_MIN = 50;
  const ZOOM_MAX = 200;
  const ZOOM_STEP = 10;

  const ICON_GLOBE = '<svg viewBox="0 0 24 24" width="40" height="40" fill="none" stroke="currentColor" stroke-width="1.2"><circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18"/></svg>';
  const ICON_BACK = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12H5"/><path d="M12 19l-7-7 7-7"/></svg>';
  const ICON_FORWARD = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14"/><path d="M12 5l7 7-7 7"/></svg>';
  const ICON_RELOAD = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36L21 8"/><path d="M21 3v5h-5"/></svg>';
  const ICON_GO = '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14"/><path d="M12 5l7 7-7 7"/></svg>';
  const ICON_EXTERNAL = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><path d="M15 3h6v6"/><path d="M10 14L21 3"/></svg>';
  const ICON_MORE = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><circle cx="12" cy="5" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="12" cy="19" r="1.7"/></svg>';
  const ICON_ZOOM_RESET = '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 3-6.7"/><path d="M3 4v5h5"/></svg>';

  const t = (k, fallback) => {
    const v = (typeof I18n !== "undefined") ? I18n.t(k) : null;
    return (v && v !== k) ? v : fallback;
  };

  function el(tag, attrs, ...kids) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (k === "class") node.className = v;
        else if (k === "text") node.textContent = v;
        else if (k.startsWith("on") && typeof v === "function") node.addEventListener(k.slice(2), v);
        else node.setAttribute(k, v);
      }
    }
    kids.forEach((c) => node.appendChild(typeof c === "string" ? document.createTextNode(c) : c));
    return node;
  }

  if (!document.getElementById("preview-panel-style")) {
    const style = document.createElement("style");
    style.id = "preview-panel-style";
    style.textContent = `
      .preview-root { display: flex; flex-direction: column; flex: 1; min-height: 0; }
      .preview-bar { flex: none; position: relative; z-index: 10; display: flex; align-items: center; gap: 2px; padding: 7px 8px; border-bottom: 1px solid var(--color-border-secondary); }
      .preview-nav-btn { flex: none; display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; border: none; border-radius: 50%; background: transparent; color: var(--color-text-secondary); cursor: pointer; transition: background var(--transition-fast), color var(--transition-fast); }
      .preview-nav-btn:hover:not(:disabled) { background: var(--color-bg-hover); color: var(--color-text-primary); }
      .preview-nav-btn:disabled { opacity: .3; cursor: default; }
      .preview-address-wrap { flex: 1; min-width: 0; position: relative; display: flex; align-items: center; margin: 0 6px; }
      .preview-address { width: 100%; height: 30px; padding: 0 30px 0 16px; border: 1px solid transparent; border-radius: var(--radius-pill); background: var(--color-bg-primary); color: var(--color-text-primary); font-size: 12px; font-family: ui-monospace, monospace; text-align: center; transition: background var(--transition-fast), box-shadow var(--transition-fast), border-color var(--transition-fast); }
      .preview-address::placeholder { color: var(--color-text-tertiary); font-family: -apple-system, sans-serif; }
      .preview-address:hover:not(:focus) { background: var(--color-bg-hover); }
      .preview-address:focus { outline: none; background: var(--color-bg-secondary); border-color: var(--color-border-strong); box-shadow: var(--shadow-sm); }
      .preview-go { position: absolute; right: 6px; display: inline-flex; align-items: center; justify-content: center; width: 20px; height: 20px; padding: 0; border: none; border-radius: 50%; background: transparent; color: var(--color-text-tertiary); cursor: pointer; }
      .preview-go:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
      .preview-icon-btn { flex: none; display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; border: none; border-radius: 50%; background: transparent; color: var(--color-text-secondary); cursor: pointer; transition: background var(--transition-fast), color var(--transition-fast); }
      .preview-icon-btn:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
      .preview-menu { position: absolute; top: calc(100% - 2px); right: 10px; z-index: 20; width: 236px; padding: 5px; background: var(--color-bg-secondary); border: 1px solid var(--color-border-primary); border-radius: var(--radius-md); box-shadow: var(--shadow-lg); }
      .preview-menu[hidden] { display: none; }
      .preview-menu-label { flex: 1; }
      .preview-menu-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 3px 6px 3px 10px; font-size: 12.5px; color: var(--color-text-primary); }
      .preview-zoom { display: flex; align-items: center; gap: 1px; padding: 1px; border-radius: var(--radius-pill); background: var(--color-bg-hover); }
      .preview-zoom-btn { display: inline-flex; align-items: center; justify-content: center; width: 22px; height: 22px; padding: 0; border: none; border-radius: 50%; background: transparent; color: var(--color-text-secondary); font-size: 13px; line-height: 1; cursor: pointer; }
      .preview-zoom-btn:hover:not(:disabled) { background: var(--color-bg-secondary); color: var(--color-text-primary); }
      .preview-zoom-btn:disabled { opacity: .35; cursor: default; }
      .preview-zoom-value { min-width: 46px; height: 22px; padding: 0 4px; border: none; border-radius: var(--radius-pill); background: transparent; color: var(--color-text-primary); font-size: 11.5px; font-variant-numeric: tabular-nums; cursor: pointer; }
      .preview-zoom-value:hover { background: var(--color-bg-secondary); }
      .preview-frame-wrap { flex: 1; min-height: 0; overflow: auto; }
      .preview-frame { display: block; width: 100%; height: 100%; border: none; background: #fff; }
      .preview-empty, .preview-notfound { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; padding: 24px; text-align: center; }
      .preview-empty-icon { color: var(--color-text-tertiary); opacity: .5; margin-bottom: 4px; }
      .preview-empty-title { font-size: 15px; font-weight: 600; color: var(--color-text-primary); }
      .preview-empty-sub { font-size: 12px; color: var(--color-text-tertiary); max-width: 240px; line-height: 1.5; }
      .preview-notfound-title { font-size: 13px; color: var(--color-text-secondary); }
      .preview-retry { margin-top: 4px; padding: 6px 14px; border: 1px solid var(--color-border-primary); border-radius: var(--radius-md); background: transparent; color: var(--color-text-primary); font-size: 12px; cursor: pointer; }
      .preview-retry:hover { background: var(--color-bg-hover); }
    `;
    document.head.appendChild(style);
  }

  // ── Panel state ────────────────────────────────────────────────────────
  // The tab body is re-rendered on every session switch; these refs live at
  // module level so the eager onAttach subscription can route an event into
  // a not-yet-rendered body via `pending`.
  let els = null;               // live DOM refs while the tab body is rendered
  let activeSessionId = null;
  let currentRel = null;
  let backStack = [];           // rels reachable via back, oldest → newest
  let forwardStack = [];        // rels reachable via forward, newest → oldest
  let pending = null;           // { sid, rel } arrived before that body rendered
  let releaseAsideWidth = null; // set while the aside is widened for the preview
  let zoom = 100;               // preview zoom, in percent; survives tab re-renders

  function isExternal(rel) {
    return /^https?:\/\//i.test(rel);
  }

  // /Users/... (bare absolute path) or file:///Users/... — a local file
  // addressed by absolute path, served via /preview/f/ instead of the
  // workspace route.
  function isFile(rel) {
    return /^file:\/\//i.test(rel) || /^\//.test(rel);
  }

  function filePath(rel) {
    if (/^file:\/\//i.test(rel)) {
      try {
        let p = new URL(rel).pathname;
        try { p = decodeURIComponent(p); } catch (_e) { /* keep encoded */ }
        return p;
      } catch (_e) {
        return rel.replace(/^file:\/\//i, "");
      }
    }
    return rel;
  }

  // True when the URL is served from the host origin through the preview
  // proxy (workspace files /preview/s/ or dev servers /preview/p/). These
  // pages must stay sandboxed without allow-same-origin so AI-generated
  // content can never touch the host's cookies / localStorage / DOM.
  function isProxied(url) {
    return url.startsWith("/preview/s/") || url.startsWith("/preview/p/") || url.startsWith("/preview/f/");
  }

  // A localhost / 127.0.0.1 dev server is opened through the host's proxy
  // (/preview/p/<port>/<path>) so pages that set X-Frame-Options still render
  // in the sandboxed iframe. Everything else loads straight into the iframe.
  function proxyUrlFor(rel) {
    try {
      const u = new URL(rel);
      const host = u.hostname.toLowerCase();
      if (host !== "localhost" && host !== "127.0.0.1") return null;
      const port = u.port || "80";
      return `/preview/p/${port}${u.pathname}${u.search}`;
    } catch (_e) {
      return null;
    }
  }

  function buildUrl(sid, rel) {
    if (isExternal(rel)) return proxyUrlFor(rel) || rel;
    if (isFile(rel)) {
      const enc = filePath(rel).split("/").map(encodeURIComponent).join("/");
      return "/preview/f" + enc;
    }
    const enc = rel.split("/").map(encodeURIComponent).join("/");
    return `/preview/s/${encodeURIComponent(sid)}/${enc}`;
  }

  // The address bar shows workspace files as their full /preview/s/ URL so
  // the user can see where the file lives; dev-server rels already carry
  // their own http(s) URL.
  function displayUrl(rel) {
    if (isExternal(rel) || isFile(rel)) return rel;
    return location.origin + buildUrl(activeSessionId, rel);
  }

  function cleanRel(input) {
    const s = String(input || "").trim().replace(/\\/g, "/");
    return /^\//.test(s) ? s : s.replace(/^\.\//, "");
  }

  // The preview needs horizontal room, so the aside is widened while a page is
  // shown. Same contract as the changes panel: borrowed space, given back on
  // close, never persisted over the user's own width.
  function ensureAsideWidth() {
    if (releaseAsideWidth || !window.Clacky || !Clacky.Aside) return;
    releaseAsideWidth = Clacky.Aside.requestWidth(PREVIEW_ASIDE_WIDTH);
  }

  function restoreAsideWidth() {
    if (!releaseAsideWidth) return;
    const release = releaseAsideWidth;
    releaseAsideWidth = null;
    release();
  }

  function showOverlay(which) {
    if (!els) return;
    els.empty.style.display       = which === "empty"       ? "flex" : "none";
    els.notFound.style.display    = which === "notFound"    ? "flex" : "none";
    els.unreachable.style.display = which === "unreachable" ? "flex" : "none";
    els.frame.style.display       = which ? "none" : "block";
  }

  function syncAddress(rel) {
    if (!els) return;
    if (document.activeElement === els.address) return;
    els.address.value = rel ? displayUrl(rel) : "";
  }

  function updateNavButtons() {
    if (!els) return;
    els.backBtn.disabled = backStack.length === 0;
    els.forwardBtn.disabled = forwardStack.length === 0;
  }

  // Follows in-frame navigation. The frame is cross-origin to the host page,
  // so contentWindow.location is unreadable and the src property does not
  // follow internal navigations. Instead the server injects a reporter into
  // every preview HTML page that announces its URL whenever it changes, so
  // link clicks and SPA/Turbo transitions keep the address bar and the
  // back/forward stacks in sync with what is actually on screen.
  function relFromUrl(url) {
    try {
      const u = new URL(url, location.href);

      const file = u.pathname.match(/^\/preview\/f(\/.*)$/);
      if (file) return file[1].split("/").map(decodeURIComponent).join("/");

      const dev = u.pathname.match(/^\/preview\/p\/(\d+)(\/.*)?$/);
      if (dev) return `http://${devHostFor(dev[1])}:${dev[1]}${dev[2] || "/"}${u.search}`;

      const ws = u.pathname.match(/^\/preview\/s\/([^/]+)\/(.*)$/);
      if (!ws || !ws[2]) return null;
      if (activeSessionId && ws[1] !== encodeURIComponent(activeSessionId)) return null;
      return ws[2].split("/").map(decodeURIComponent).join("/");
    } catch (_e) { return null; }
  }

  // A dev server is reachable as either localhost or 127.0.0.1; keep whichever
  // the address bar was already showing so the URL doesn't flip on every click.
  function devHostFor(port) {
    try {
      const u = new URL(currentRel);
      if (u.port === String(port) && u.hostname) return u.hostname;
    } catch (_e) { /* currentRel is a workspace path */ }
    return "localhost";
  }

  if (!window.__clackyPreviewNav) {
    window.__clackyPreviewNav = true;
    window.addEventListener("message", (e) => {
      const data = e.data;
      if (!data || data.__clackyPreview !== 1) return;
      if (els && els.iframe && e.source !== els.iframe.contentWindow) return;
      const rel = relFromUrl(data.href);
      if (!rel || rel === currentRel) return;
      if (currentRel) backStack.push(currentRel);
      forwardStack = [];
      currentRel = rel;
      syncAddress(rel);
      updateNavButtons();
    });
  }

  // A brand-new element is the only reload primitive that works uniformly:
  // re-assigning an identical src is a no-op, and contentWindow is sealed by
  // the sandbox.
  function freshFrame(url, isolated) {
    const src = isolated ? isolateOrigin(url) : url;
    const f = el("iframe", {
      class: "preview-frame",
      sandbox: sandboxFor(src),
      referrerpolicy: "no-referrer",
      title: t("preview.tab", "预览"),
    });
    els.frame.replaceChildren(f);
    els.iframe = f;
    applyZoom();
    f.src = src;
  }

  // Swaps the loopback host for `preview.localhost`, keeping port and path so
  // the same server answers. Non-loopback hosts (a remote clacky UI) have no
  // second name to use and are left alone.
  function isolateOrigin(url) {
    try {
      const u = new URL(url, location.href);
      if (!isLoopbackHost(location.hostname) || !isLoopbackHost(u.hostname)) return url;
      if (u.hostname === ISOLATED_PREVIEW_HOST) return u.href;
      u.hostname = ISOLATED_PREVIEW_HOST;
      return u.href;
    } catch (_e) { return url; }
  }

  function isLoopbackHost(host) {
    return host === "127.0.0.1" || host === "localhost" || host === "::1" || host === "[::1]";
  }

  // allow-same-origin is only withheld when the frame would share the host's
  // origin, which is the one case where it would escape the sandbox.
  function sandboxFor(url) {
    try {
      return new URL(url, location.href).origin === location.origin ? SANDBOX : (SANDBOX + " allow-same-origin");
    } catch (_e) { return SANDBOX; }
  }

  // CSS zoom on an iframe keeps the element box at its laid-out size while
  // shrinking the layout viewport inside it, so the page reflows at
  // (width / scale) and is then drawn scaled — exactly what browser page zoom
  // does. The box must stay at 100% or the frame detaches from the panel edge.
  function applyZoom() {
    if (!els) return;
    if (els.iframe) els.iframe.style.zoom = String(zoom / 100);
    if (els.zoomValue) els.zoomValue.textContent = zoom + "%";
    if (els.zoomOutBtn) els.zoomOutBtn.disabled = zoom <= ZOOM_MIN;
    if (els.zoomInBtn) els.zoomInBtn.disabled = zoom >= ZOOM_MAX;
    if (els.zoomResetBtn) els.zoomResetBtn.disabled = zoom === 100;
  }

  function stepZoom(delta) {
    const next = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, zoom + delta));
    if (next === zoom) return;
    zoom = next;
    applyZoom();
  }

  function resetZoom() {
    if (zoom === 100) return;
    zoom = 100;
    applyZoom();
  }

  async function openRel(sid, rel, record) {
    rel = cleanRel(rel);
    if (!rel || !sid) return;

    if (record) {
      if (currentRel && currentRel !== rel) backStack.push(currentRel);
      forwardStack = [];
    }
    currentRel = rel;
    if (els && activeSessionId === sid) {
      syncAddress(rel);
      updateNavButtons();
    } else {
      pending = { sid: sid, rel: rel };
      return;
    }

    const url = buildUrl(sid, rel);
    let frameUrl = url;
    // Proxied URLs (workspace files and dev servers) are same-origin, so they
    // can be HEAD-probed. A non-200 from the proxy means the dev server is
    // down — show a friendly "unreachable" card instead of the raw text in
    // the frame. Truly cross-origin URLs skip the probe (CORS blocks HEAD).
    if (isProxied(url)) {
      try {
        const res = await fetch(url, { method: "HEAD" });
        if (res.status !== 200) {
          if (currentRel === rel) {
            showOverlay(url.startsWith("/preview/p/") ? "unreachable" : "notFound");
          }
          return;
        }
        // The proxy reports whether the upstream allows framing on its own.
        // Vite-style dev servers send no X-Frame-Options, and their modules
        // import by absolute path (/node_modules/.vite/deps/...), which the
        // proxy cannot rewrite — for those, load the dev server directly so
        // the ESM graph (and HMR websockets) resolves against the right origin.
        if (url.startsWith("/preview/p/") && res.headers.get("X-Clacky-Upstream-Frameable") === "1") {
          frameUrl = rel;
        }
      } catch (_e) { /* offline/race — try the iframe anyway */ }
    }
    if (currentRel !== rel || !els) return;
    showOverlay(null);
    syncAddress(rel);
    ensureAsideWidth();
    // Proxy URLs move to the isolated preview origin; direct third-party URLs
    // stay as-is and are already cross-origin.
    freshFrame(frameUrl, isProxied(frameUrl));
  }

  function goBack() {
    const rel = backStack.pop();
    if (!rel || !activeSessionId) return;
    if (currentRel) forwardStack.push(currentRel);
    openRel(activeSessionId, rel, false);
  }

  function goForward() {
    const rel = forwardStack.pop();
    if (!rel || !activeSessionId) return;
    if (currentRel) backStack.push(currentRel);
    openRel(activeSessionId, rel, false);
  }

  function reloadCurrent() {
    if (activeSessionId && currentRel) openRel(activeSessionId, currentRel, false);
  }

  function openExternal() {
    if (!activeSessionId || !currentRel) return;
    // External URLs open as-is: the proxy strips X-Frame-Options only to
    // satisfy the iframe, a fresh tab needs no such workaround. Bare
    // absolute paths get a file:// prefix for the new tab.
    let url;
    if (isExternal(currentRel)) {
      url = currentRel;
    } else if (isFile(currentRel)) {
      url = /^file:\/\//i.test(currentRel) ? currentRel : "file://" + currentRel;
    } else {
      url = buildUrl(activeSessionId, currentRel);
    }
    window.open(url, "_blank", "noopener");
  }

  // ── More menu ──────────────────────────────────────────────────────────
  // Menu state is read from the DOM rather than the module-level `els` ref:
  // when the aside re-renders (session switch, layout restore) the old `els`
  // points at detached nodes and a click on the fresh toolbar would silently
  // toggle a menu nobody can see.
  function closeMenu() {
    document.querySelectorAll(".preview-menu:not([hidden])").forEach((menu) => {
      menu.hidden = true;
      const btn = menu.parentElement && menu.parentElement.querySelector('[aria-haspopup="true"]');
      if (btn) btn.setAttribute("aria-expanded", "false");
    });
  }

  function toggleMenu(menu, btn) {
    if (!menu) return;
    menu.hidden = !menu.hidden;
    if (btn) btn.setAttribute("aria-expanded", String(!menu.hidden));
  }

  if (!window.__clackyPreviewMenuDismiss) {
    window.__clackyPreviewMenuDismiss = true;
    document.addEventListener("mousedown", (e) => {
      if (!document.querySelector(".preview-menu:not([hidden])")) return;
      if (e.target.closest(".preview-menu") || e.target.closest('[aria-haspopup="true"]')) return;
      closeMenu();
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") closeMenu();
    });
    // Clicking into the preview frame moves focus to the iframe's document,
    // which the host never sees; the window blur is the only signal available.
    window.addEventListener("blur", () => closeMenu());
  }

  Clacky.ext.ui.mount("session.aside", (container, ctx) => {
    if (!ctx || !ctx.sessionId) return;

    const address = el("input", {
      class: "preview-address", type: "text",
      placeholder: t("preview.address", "输入本地文件路径或 localhost 地址"),
      "aria-label": t("preview.address", "输入本地文件路径或 localhost 地址"),
      spellcheck: "false",
    });
    const submitAddress = () => {
      // The bar shows a full URL; map /preview/s/<sid>/<rel> back to the rel
      // the rest of the panel navigates by, and leave everything else as-is.
      openRel(ctx.sessionId, relFromUrl(address.value) || address.value, true);
      address.blur();
    };
    address.addEventListener("keydown", (e) => {
      if (e.key === "Enter") submitAddress();
    });
    address.addEventListener("focus", () => address.select());

    const goBtn = el("button", {
      class: "preview-go", type: "button",
      title: t("preview.go", "前往"), onclick: submitAddress,
    });
    goBtn.innerHTML = ICON_GO;
    const addressWrap = el("div", { class: "preview-address-wrap" }, address, goBtn);

    const backBtn = el("button", {
      class: "preview-nav-btn", type: "button",
      title: t("preview.back", "后退"), onclick: goBack,
    });
    backBtn.innerHTML = ICON_BACK;

    const forwardBtn = el("button", {
      class: "preview-nav-btn", type: "button",
      title: t("preview.forward", "前进"), onclick: goForward,
    });
    forwardBtn.innerHTML = ICON_FORWARD;

    const reloadBtn = el("button", {
      class: "preview-nav-btn", type: "button",
      title: t("preview.reload", "刷新"), onclick: reloadCurrent,
    });
    reloadBtn.innerHTML = ICON_RELOAD;

    const extBtn = el("button", {
      class: "preview-icon-btn", type: "button",
      title: t("preview.openExternal", "在新标签页打开"), onclick: openExternal,
    });
    extBtn.innerHTML = ICON_EXTERNAL;

    const moreBtn = el("button", {
      class: "preview-icon-btn", type: "button",
      title: t("preview.more", "更多"), "aria-haspopup": "true", "aria-expanded": "false",
      onclick: (e) => { e.stopPropagation(); toggleMenu(menu, moreBtn); },
    });
    moreBtn.innerHTML = ICON_MORE;

    const zoomOutBtn = el("button", {
      class: "preview-zoom-btn", type: "button",
      title: t("preview.zoom.out", "缩小"), text: "−",
      onclick: () => stepZoom(-ZOOM_STEP),
    });
    const zoomValue = el("button", {
      class: "preview-zoom-value", type: "button",
      title: t("preview.zoom.reset", "重置为 100%"), text: zoom + "%",
      onclick: resetZoom,
    });
    const zoomInBtn = el("button", {
      class: "preview-zoom-btn", type: "button",
      title: t("preview.zoom.in", "放大"), text: "+",
      onclick: () => stepZoom(ZOOM_STEP),
    });
    const zoomResetBtn = el("button", {
      class: "preview-zoom-btn", type: "button",
      title: t("preview.zoom.reset", "重置为 100%"),
      onclick: resetZoom,
    });
    zoomResetBtn.innerHTML = ICON_ZOOM_RESET;
    const zoomRow = el("div", { class: "preview-menu-row" },
      el("span", { class: "preview-menu-label", text: t("preview.zoom", "缩放") }),
      el("div", { class: "preview-zoom" }, zoomOutBtn, zoomValue, zoomInBtn),
      zoomResetBtn);

    const menu = el("div", { class: "preview-menu" },
      zoomRow);
    menu.hidden = true;

    const bar = el("div", { class: "preview-bar" },
      backBtn, forwardBtn, reloadBtn, addressWrap, extBtn, moreBtn, menu);
    const frame = el("div", { class: "preview-frame-wrap" });

    const notFound = el("div", { class: "preview-notfound" },
      el("div", { class: "preview-notfound-title", text: t("preview.notFound", "文件不存在") }),
      el("button", { class: "preview-retry", type: "button",
        text: t("preview.reload", "刷新"), onclick: reloadCurrent }));

    const unreachable = el("div", { class: "preview-notfound" },
      el("div", { class: "preview-notfound-title", text: t("preview.unreachable", "无法连接到开发服务器") }),
      el("button", { class: "preview-retry", type: "button",
        text: t("preview.reload", "刷新"), onclick: reloadCurrent }));

    const emptyIcon = el("div", { class: "preview-empty-icon" });
    emptyIcon.innerHTML = ICON_GLOBE;
    const empty = el("div", { class: "preview-empty" },
      emptyIcon,
      el("div", { class: "preview-empty-title", text: t("preview.empty.title", "开始浏览") }),
      el("div", { class: "preview-empty-sub",
        text: t("preview.empty.sub", "输入本地文件路径或 localhost 地址以打开页面") }));

    const root = el("div", { class: "preview-root", "data-panel": "preview" },
      bar, frame, notFound, unreachable, empty);
    container.appendChild(root);

    els = {
      frame: frame, iframe: null,
      empty: empty, notFound: notFound, unreachable: unreachable,
      address: address,
      backBtn: backBtn, forwardBtn: forwardBtn,
      moreBtn: moreBtn, menu: menu,
      zoomValue: zoomValue, zoomOutBtn: zoomOutBtn, zoomInBtn: zoomInBtn, zoomResetBtn: zoomResetBtn,
    };
    activeSessionId = ctx.sessionId;
    syncAddress(currentRel);
    updateNavButtons();
    applyZoom();

    if (pending && pending.sid === ctx.sessionId) {
      const rel = pending.rel;
      pending = null;
      openRel(ctx.sessionId, rel, false);
    } else if (currentRel) {
      openRel(ctx.sessionId, currentRel, false);
    } else {
      showOverlay("empty");
    }
  }, {
    order: 50,
    tab: {
      id: "preview",
      label: () => t("preview.tab", "预览"),
      // Eager onAttach: runs before the tab is ever opened by hand, and only
      // handles session-switch cleanup — restoring the borrowed aside width
      // and resetting the preview state for the next session.
      onAttach(ctx) {
        if (!ctx || !ctx.sessionId) return;
        const sid = ctx.sessionId;
        return () => {
          restoreAsideWidth();
          // A same-session re-render keeps the preview state; only a real
          // session switch starts the next workspace from a clean slate.
          const switchedAway = !(Clacky.ext.context && Clacky.ext.context.sessionId === sid);
          if (switchedAway) {
            currentRel = null;
            backStack = [];
            forwardStack = [];
            if (pending && pending.sid === sid) pending = null;
          }
          if (activeSessionId === sid) {
            els = null;
            activeSessionId = null;
          }
        };
      },
    },
  });

  // Programmatic entry point used by the host (the workspace viewer and the
  // chat link interceptor): open a workspace-relative HTML path or an http(s)
  // URL. Returns false when there is no active session.
  if (window.Clacky) {
    Clacky.Preview = {
      open(rel) {
        const sid = Clacky.ext.context && Clacky.ext.context.sessionId;
        if (!sid || !rel) return false;
        openRel(sid, rel, true);
        if (window.Clacky && Clacky.Aside) Clacky.Aside.open();
        Clacky.ext.activateTab("session.aside", "preview");
        return true;
      },
    };
  }
})();
