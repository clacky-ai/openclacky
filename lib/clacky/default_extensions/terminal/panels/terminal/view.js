// ── Official panel: terminal ──────────────────────────────────────────────
//
// A real shell in the session's working directory, rendered by xterm.js inside
// the session aside. The shell itself lives in the openclacky process (see
// api/runtime.rb); this file owns only the view.
//
// Two things drive the shape of this code:
//   - The aside re-renders the active tab's body on every activation, so the
//     xterm instance is created once per session and its element is re-parented
//     into the fresh container. Re-creating it would lose the scrollback.
//   - Output arrives as base64 bytes (PTY reads split multi-byte UTF-8), so it
//     is decoded into a Uint8Array instead of being written as a JS string.
// ───────────────────────────────────────────────────────────────────────────

(() => {
  if (!window.Clacky || !Clacky.ext) return;

  const API_BASE = "/api/ext/terminal";
  const ASSET_BASE = "/ext_ui/terminal/vendor/";
  const WS_PREFIX = "ext.terminal.";
  const TAB_SLOT = "session.aside";
  const TAB_ID = "terminal";

  const t = (key, fallback, params) => {
    const value = (typeof I18n !== "undefined") ? I18n.t(key, params) : null;
    return (value && value !== key) ? value : fallback;
  };

  let assetsPromise = null;

  function loadAssets() {
    if (assetsPromise) return assetsPromise;
    assetsPromise = new Promise((resolve, reject) => {
      if (!document.getElementById("terminal-ext-style")) {
        const link = document.createElement("link");
        link.id = "terminal-ext-style";
        link.rel = "stylesheet";
        link.href = ASSET_BASE + "xterm.css";
        document.head.appendChild(link);
      }
      const files = ["xterm.js", "addon-fit.js"];
      const next = (index) => {
        if (index >= files.length) { resolve(); return; }
        const script = document.createElement("script");
        script.src = ASSET_BASE + files[index];
        script.onload = () => next(index + 1);
        script.onerror = () => reject(new Error("failed to load " + script.src));
        document.head.appendChild(script);
      };
      next(0);
    });
    return assetsPromise;
  }

  function b64ToBytes(b64) {
    const binary = atob(b64 || "");
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  function send(rt, frame) {
    if (!rt || rt.disposed || !rt.termId) return;
    if (!window.Clacky || !Clacky.WS) return;
    Clacky.WS.send(Object.assign({ term_id: rt.termId }, frame));
  }

  function styles() {
    if (document.getElementById("terminal-ext-css")) return;
    const style = document.createElement("style");
    style.id = "terminal-ext-css";
    style.textContent = `
      .term-host { flex: 1 1 auto; min-height: 0; padding: 0.5rem 0.375rem 0.375rem 0.625rem; background: transparent; }
      .term-host .xterm { height: 100%; }
      .term-host .xterm-viewport { background: transparent !important; }
      .term-host .xterm-viewport::-webkit-scrollbar { width: 0.5rem; }
      .term-host .xterm-viewport::-webkit-scrollbar-thumb { background: var(--color-border-strong, rgba(0,0,0,.18)); border-radius: 0.25rem; }
      .term-note { flex: 1 1 auto; display: flex; flex-direction: column; align-items: center; justify-content: center;
                   gap: 0.625rem; padding: 1.5rem; text-align: center; font-size: 0.78rem;
                   color: var(--color-text-secondary, #4b5563); }
      .term-note-detail { font-size: 0.72rem; color: var(--color-text-tertiary, #9ca3af);
                          font-family: var(--font-mono, monospace); word-break: break-all; }
      .term-btn-primary { border: 1px solid var(--color-border-strong, rgba(0,0,0,.14)); background: transparent;
                          color: inherit; border-radius: 0.375rem; padding: 0.25rem 0.75rem; font-size: 0.75rem; cursor: pointer; }
      .term-btn-primary:hover { background: var(--color-bg-hover, rgba(0,0,0,.05)); }
    `;
    document.head.appendChild(style);
  }

  function build(rt) {
    if (rt.disposed) return;
    const css = getComputedStyle(document.documentElement);
    const cssVar = (name, fallback) => (css.getPropertyValue(name) || "").trim() || fallback;
    const Terminal = window.Terminal;
    const FitAddon = window.FitAddon && window.FitAddon.FitAddon;
    if (!Terminal || !FitAddon) return;

    const term = new Terminal({
      fontFamily: cssVar("--font-mono", "ui-monospace, Menlo, monospace"),
      fontSize: 12.5,
      lineHeight: 1.3,
      letterSpacing: 0,
      cursorBlink: true,
      scrollback: 5000,
      macOptionIsMeta: true,
      theme: {
        background: "rgba(0,0,0,0)",
        foreground: cssVar("--color-text-primary", "#1f2328"),
        cursor: cssVar("--color-text-primary", "#1f2328"),
        selectionBackground: cssVar("--color-accent-soft", "rgba(79,70,229,.28)"),
      },
      allowTransparency: true,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.onData((data) => send(rt, { type: "ext.terminal.input", data }));
    rt.term = term;
    rt.fit = fit;
  }

  function fitNow(rt) {
    if (!rt.term || !rt.fit) return;
    const host = rt.host;
    if (!host || !host.isConnected || host.clientWidth < 8 || host.clientHeight < 8) return;
    try { rt.fit.fit(); } catch (_e) { /* container not measurable yet */ }
  }

  // ResizeObserver fires continuously while the user drags the aside divider;
  // one resize frame per animation frame is plenty for both xterm and the PTY.
  function scheduleSync(rt) {
    if (rt.syncFrame) return;
    rt.syncFrame = requestAnimationFrame(() => {
      rt.syncFrame = null;
      if (rt.disposed) return;
      fitNow(rt);
      if (rt.term) send(rt, { type: "ext.terminal.resize", cols: rt.term.cols, rows: rt.term.rows });
    });
  }

  function watchSize(rt) {
    if (rt.ro || !rt.host) return;
    rt.ro = new ResizeObserver(() => scheduleSync(rt));
    rt.ro.observe(rt.host);
  }

  function showNote(rt, title, detail, withRetry) {
    if (!rt.container) return;
    hideNote(rt);
    const note = document.createElement("div");
    note.className = "term-note";
    const line = document.createElement("div");
    line.textContent = title;
    note.appendChild(line);
    if (detail) {
      const small = document.createElement("div");
      small.className = "term-note-detail";
      small.textContent = detail;
      note.appendChild(small);
    }
    if (withRetry) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "term-btn-primary";
      button.textContent = t("terminal.retry", "重试");
      button.addEventListener("click", () => startShell(rt));
      note.appendChild(button);
    }
    rt.container.appendChild(note);
    rt.note = note;
    if (rt.host) rt.host.style.display = "none";
  }

  function hideNote(rt) {
    if (rt.note && rt.note.parentNode) rt.note.parentNode.removeChild(rt.note);
    rt.note = null;
    if (rt.host) rt.host.style.display = "";
  }

  // The shell is the panel: once it exits (or the server no longer knows it,
  // which happens if openclacky restarts) the tab has nothing to show, so it
  // closes itself exactly like the × on the tab would.
  function retire(rt) {
    send(rt, { type: "ext.terminal.close" });
    rt.termId = null;
    if (rt.term) rt.term.reset();
    const ext = window.Clacky && Clacky.ext;
    // A background session's runtime must not close the tab the user is
    // looking at; the tab id is shared, the panel state is per session.
    if (!ext || !ext.context || ext.context.sessionId !== rt.sessionId) return;
    if (ext.closeTab) ext.closeTab(TAB_SLOT, TAB_ID);
  }

  async function startShell(rt) {
    if (rt.disposed || !rt.term || rt.booting) return;
    if (rt.termId) return;
    hideNote(rt);
    rt.booting = true;
    fitNow(rt);
    try {
      const response = await fetch(API_BASE + "/open", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          session_id: rt.sessionId,
          cols: rt.term.cols || 80,
          rows: rt.term.rows || 24,
        }),
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        const title = (response.status === 403)
          ? t("terminal.localOnly", "终端只能在从本机打开应用时使用。")
          : (payload.error || ("HTTP " + response.status));
        showNote(rt, title, null, response.status !== 403 && response.status !== 501);
        return;
      }
      rt.termId = payload.term_id;
      send(rt, { type: "ext.terminal.attach" });
      rt.term.focus();
    } catch (error) {
      showNote(rt, t("terminal.openFailed", "无法启动终端"), String(error && error.message || error), true);
    } finally {
      rt.booting = false;
    }
  }

  function onServerEvent(rt, event) {
    if (!event || rt.disposed) return;

    if (event.type === "_ws_connected") {
      if (rt.termId) send(rt, { type: "ext.terminal.attach" });
      return;
    }
    if (typeof event.type !== "string" || !event.type.startsWith(WS_PREFIX)) return;
    if (event.term_id !== rt.termId || !rt.term) return;

    switch (event.type) {
      case "ext.terminal.ready":
        if (event.status && event.status !== "running") { retire(rt); break; }
        if (event.replay) {
          rt.term.reset();
          rt.term.write(b64ToBytes(event.replay));
        }
        fitNow(rt);
        break;
      case "ext.terminal.output":
        rt.term.write(b64ToBytes(event.data));
        break;
      case "ext.terminal.exit":
      case "ext.terminal.gone":
        retire(rt);
        break;
      default:
        break;
    }
  }

  function create(ctx) {
    styles();
    const rt = {
      sessionId: ctx && ctx.sessionId,
      termId: null,
      term: null,
      fit: null,
      host: null,
      container: null,
      ro: null,
      note: null,
      disposed: false,
      booting: false,
      syncFrame: null,
      ready: null,
    };

    if (window.Clacky && Clacky.WS) {
      Clacky.WS.onEvent((event) => onServerEvent(rt, event));
    }
    rt.ready = loadAssets().then(() => build(rt)).catch((error) => {
      rt.loadError = error;
    });

    rt.dispose = () => {
      if (rt.disposed) return;
      rt.disposed = true;
      if (rt.syncFrame) cancelAnimationFrame(rt.syncFrame);
      if (rt.ro) { rt.ro.disconnect(); rt.ro = null; }
      if (rt.termId) {
        if (window.Clacky && Clacky.WS) {
          Clacky.WS.send({ type: "ext.terminal.close", term_id: rt.termId });
        }
        rt.termId = null;
      }
      if (rt.term) { rt.term.dispose(); rt.term = null; }
    };

    return rt;
  }

  function render(container, ctx, rt) {
    if (!rt) return undefined;
    rt.container = container;

    const host = document.createElement("div");
    host.className = "term-host";
    container.appendChild(host);

    rt.host = host;

    const activate = () => {
      if (rt.disposed || !rt.term) return;
      if (!rt.host || !rt.host.isConnected) return;
      if (!rt.term.element) {
        rt.term.open(host);
      } else if (rt.term.element.parentNode !== host) {
        host.appendChild(rt.term.element);
      }
      watchSize(rt);
      fitNow(rt);
      rt.term.focus();
      // Switching tabs detaches the pane; re-attaching replays whatever the
      // shell printed meanwhile, so the view is not frozen on return.
      if (!rt.termId) startShell(rt);
      else send(rt, { type: "ext.terminal.attach" });
    };

    if (rt.loadError) {
      showNote(rt, t("terminal.loadFailed", "终端组件加载失败"), String(rt.loadError.message || rt.loadError), false);
    } else if (rt.ready) {
      rt.ready.then(activate);
    }

    return () => {
      if (rt.ro) { rt.ro.disconnect(); rt.ro = null; }
      // The shell keeps running while the page lives; the server reaps it after
      // an hour without a client, or earlier when a new terminal needs the slot.
      send(rt, { type: "ext.terminal.detach" });
      rt.host = null;
      rt.container = null;
      rt.note = null;
    };
  }

  Clacky.ext.ui.mount(TAB_SLOT, { create, render }, {
    order: 35,
    tab: {
      id: TAB_ID,
      label: () => t("terminal.tab", "终端"),
      icon: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="5 8 10 12 5 16"/><line x1="12" y1="16.5" x2="19" y2="16.5"/></svg>',
    },
  });
})();
