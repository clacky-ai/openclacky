// ── Clacky.ext — WebUI extension registry ─────────────────────────────────
//
// The single, controlled entry point through which extensions declared
// in an ext.yml container hook into the WebUI.
//
// Three capabilities (the whole contract an extension author must learn):
//   Clacky.ext.api.register(name, fn)        — register a data source
//   Clacky.ext.subscribe(event, handler)     — listen to store events (read-only)
//   Clacky.ext.ui.mount(slot, spec, opts)    — inject UI into a named slot
//
//   `spec` is either a render function or { create?, render }. The render
//   signature is always `render(container, ctx, runtime)`:
//     - `container` is a host-owned DOM element — append your UI into it,
//       or return a DOM node / HTML string and the host appends it for you.
//     - returning a function registers it as a teardown callback.
//     - returning null is treated as an error (almost always a wrong
//       signature, e.g. `(ctx) => ...`), surfaced as a crashed placeholder.
//   On per-session slots (session.aside/banner/composer), providing
//   `create(ctx)` gives you one runtime per sessionId, isolated across
//   sessions and disposed only when the session leaves the sidebar.
//
// Safety guarantees enforced here (the "constitution"):
//   - Every extension callback is wrapped in try/catch. A throwing extension is
//     contained: its slot degrades to a placeholder marked
//     data-ext-status="crashed"; it never takes down the host or sibling slots.
//   - In pure mode (?pure=true), the registry becomes a no-op: register/
//     subscribe/mount do nothing, so no extension code can affect the page.
//   - Extensions reach the host ONLY through this object. The enable/disable
//     and safe-mode controls live in the host frame, never inside an extension.
//
// Depends on: nothing (loads right after utils.js).
// ───────────────────────────────────────────────────────────────────────────

window.Clacky = window.Clacky || {};

Clacky.ext = (() => {
  // Pure mode: detect ?pure=true once. When on, all registration is a no-op
  // and the host must not inject any extension scripts (handled server-side).
  // This is the ultimate escape hatch back to a clean official UI.
  const PURE = (() => {
    try {
      return new URLSearchParams(window.location.search).get("pure") === "true";
    } catch (_e) {
      return false;
    }
  })();

  const _dataSources = {};            // name => fn
  const _subscribers = {};            // event => [handler]
  const _slotRenderers = {};          // slot => [{ fn, extId, agents, panel, order, tab }]
  const _slotTabActivators = {};      // tabbed slot => activate(tabId) from the latest render
  const _workspaces = {};             // id => { id, title, render, extId }
  let   _currentExtId = null;         // set while an extension file is loading

  // Slots that render as a tabbed container instead of a vertical stack: each
  // renderer becomes one tab (chrome drawn by the host), and only the active
  // tab's body is shown. Renderers in these slots must carry opts.tab.
  const TABBED_SLOTS = { "session.aside": true };

  // Slots that follow the current session's agent scope. A mount into any
  // of these, made from inside a panel file, is confined to that panel's
  // agents (via _currentPanel). Every other slot — sidebar, header, main
  // workspace, the settings panel — is treated as global chrome: mounts
  // there always show, regardless of which panel file happened to be
  // loading. This is what separates "session UI" from "app chrome" and it
  // is the ONLY place that distinction lives.
  const SESSION_SCOPED_SLOTS = {
    "session.banner": true,
    "session.composer": true,
    "session.aside": true,
  };

  // Named slots the host renders. Extensions mounting into any other name
  // will silently do nothing — we warn once per bad name to catch typos
  // like "sidebar-nav.top" or "session.aisde" during development.
  const KNOWN_SLOTS = {
    "header.left": true,
    "header.right": true,
    "sidebar.nav.top": true,
    "sidebar.nav": true,
    "sidebar.nav.bottom": true,
    "sidebar.footer": true,
    "main.workspace": true,
    "session.banner": true,
    "session.composer": true,
    "session.aside": true,
    "settings.tabs": true,
    "settings.body": true,
  };
  const _warnedUnknownSlots = {};

  // Per-extension/panel agent scoping declared at load time:
  //   _extAgents[extId]  = ["coding", ...]   (from <script data-agent=...>, may be multiple)
  //   _panelAgents[panel] = ["coding", ...]  (agents whose profile.yml references the panel)
  // Resolved by the host before the extension scripts run (see loader markers).
  const _extAgents = {};
  const _extLayers = {};              // extId => "builtin" | "installed" | "local"
  const _panelAgents = {};
  const _agentContributions = {};     // agent id => { panels:[{id,title,title_zh}], skills:[...] }
  let   _currentPanel = null;         // set while an official panel file is loading

  // Current session context, kept in sync by the host on every session switch.
  // Slots are (re)rendered against this so an extension/panel only appears for
  // the agent profiles it was scoped to.
  const context = { agentProfile: null };

  // Wrap any extension-provided callback so a throw is contained, logged, and
  // attributed to the extension that registered it.
  function _guard(fn, label, extId) {
    return (...args) => {
      try {
        return fn(...args);
      } catch (err) {
        console.error(`[Clacky.ext] extension "${extId || "?"}" failed in ${label}:`, err);
        return undefined;
      }
    };
  }

  // Warn once per unknown slot so a typo is loud but the log stays finite.
  function _warnUnknownSlot(slot, label) {
    if (KNOWN_SLOTS[slot] || _warnedUnknownSlots[slot]) return;
    _warnedUnknownSlots[slot] = true;
    const known = Object.keys(KNOWN_SLOTS).join(", ");
    console.warn(
      `[Clacky.ext] unknown slot ${JSON.stringify(slot)} in ${label}. ` +
      `Nothing will render. Known slots: ${known}`
    );
  }

  // Slots whose renderer represents "the current session's copy" of some UI
  // (a tabbed panel body, a session banner, a session-composer button). Mounts
  // to these slots may declare `create(ctx)` and get one runtime per session,
  // isolated from every other session and torn down only when the session
  // itself leaves the sidebar.
  const PER_SESSION_SLOTS = {
    "session.aside": true,
    "session.banner": true,
    "session.composer": true,
  };

  // sessionId => Map<mountKey, runtime>. Populated lazily on first render.
  const _sessionRuntimes = new Map();
  // sessionId => Map<mountKey, teardownFn|null>. Cleared before every rerender.
  const _viewTeardowns = new Map();

  // Deterministic key for a renderer within a session: same slot + extId + tab
  // id always resolves to the same runtime for a given session.
  function _mountKey(slot, entry) {
    const tabId = entry.tab && entry.tab.id ? entry.tab.id : "_";
    return `${slot}::${entry.extId || "?"}::${tabId}`;
  }

  // Normalize a mount registration. Accepts either a plain function (render
  // only) or an object { create?, render }. Anything else is rejected with a
  // console warning to catch typos early.
  function _register(slot, spec, opts, extId, extra) {
    let create = null;
    let render;
    if (typeof spec === "function") {
      render = spec;
    } else if (spec && typeof spec === "object" && typeof spec.render === "function") {
      render = spec.render;
      if (typeof spec.create === "function") create = spec.create;
    } else {
      console.warn(
        `[Clacky.ext] ui.mount(${JSON.stringify(slot)}) needs a render function ` +
        `or { create?, render } object. Got: ${typeof spec}`
      );
      return;
    }

    const isBuiltin = !!(extra && extra.builtin);
    const explicit  = opts && Array.isArray(opts.agents) ? opts.agents : null;
    const panel     = (!isBuiltin && SESSION_SCOPED_SLOTS[slot]) ? _currentPanel : null;
    const scoped    = isBuiltin ? null : (explicit || _extAgents[extId] || null);
    const order     = opts && Number.isFinite(opts.order) ? opts.order : 100;
    const tab       = (opts && opts.tab) || null;
    const workspace = (opts && typeof opts.workspace === "string") ? opts.workspace : null;

    const label = `ui.mount(${slot})`;
    (_slotRenderers[slot] ||= []).push({
      render:  _guard(render, label, extId),
      create:  create ? _guard(create, `${label}#create`, extId) : null,
      extId,
      layer:   isBuiltin ? "host" : (_extLayers[extId] || null),
      agents:  scoped,
      panel,
      order,
      tab,
      workspace,
    });
  }


  // extension's <script src> and _extEnd right after. In pure mode these are
  // no-ops (and the host does not emit extension scripts at all).
  //
  // `agents` scopes a single-agent extension (from user agents/<name>/webui/):
  // a list of agent profile names it should appear for. `panel` marks a panel
  // whose agent scope is resolved separately via registerPanelAgents. Either
  // may be omitted for a global extension.
  function _extBegin(extId, agents, panel, layer) {
    if (PURE) return;
    _currentExtId = extId;
    if (Array.isArray(agents) && agents.length) _extAgents[extId] = agents;
    if (panel) _currentPanel = panel;
    if (layer) _extLayers[extId] = String(layer);
  }

  function _extEnd() {
    _currentExtId = null;
    _currentPanel = null;
  }

  // Record which agent profiles reference an official panel (host computes this
  // from each agent's profile.yml `panels:` declaration). Called once at load.
  function registerPanelAgents(map) {
    if (PURE || !map) return;
    Object.assign(_panelAgents, map);
  }

  function registerAgentContributions(map) {
    if (PURE || !map) return;
    Object.assign(_agentContributions, map);
  }

  const api = {
    // Register a named data source. Host/extensions can later resolve it.
    register(name, fn) {
      if (PURE || typeof fn !== "function") return;
      _dataSources[name] = _guard(fn, `api.register(${name})`, _currentExtId);
    },
    // Resolve a registered data source by name; undefined if absent.
    resolve(name) {
      return _dataSources[name];
    },
  };

  // Subscribe to a store event. Read-only: handlers can observe, never mutate
  // core logic. Returns an unsubscribe function.
  function subscribe(event, handler) {
    if (PURE || typeof handler !== "function") return () => {};
    const wrapped = _guard(handler, `subscribe(${event})`, _currentExtId);
    (_subscribers[event] ||= []).push(wrapped);
    return () => {
      const list = _subscribers[event];
      if (!list) return;
      const i = list.indexOf(wrapped);
      if (i >= 0) list.splice(i, 1);
    };
  }

  // Emit a store event to all subscribers. Called by store-layer code (host),
  // never by extensions. A throwing subscriber is already guarded above.
  function emit(event, payload) {
    const list = _subscribers[event];
    if (!list) return;
    list.forEach((h) => h(payload));
  }

  const ui = {
    // Register a renderer for a named slot. renderFn(ctx) -> Node | string | null.
    //
    // Scope rules (automatic — you never spell them out):
    //   • Mounts to session/settings slots inherit the current panel's agent
    //     scope, so a `session.aside` tab written next to a designer panel
    //     only shows when the user is on the designer agent.
    //   • Mounts to every other slot (sidebar.*, header.*, main.workspace)
    //     are global app chrome — they show regardless of panel/agent.
    //
    // opts.agents — restrict to these agent profile names, overriding the
    //   defaults above. Rarely needed.
    // Mount UI into a named slot. `spec` is either:
    //   • a function (ctx) => Node|string|null       — plain render, no state
    //   • an object { create?, render }              — render + optional
    //     per-session runtime bound to `create`
    //
    // If the slot is per-session (session.aside etc.) AND `create` is present,
    // the host allocates one runtime per sessionId — `create(ctx)` runs the
    // first time this session shows the tab, `render(container, ctx, runtime)`
    // runs every time the tab becomes visible with a fresh empty container,
    // and `runtime.dispose()` runs when the session leaves the sidebar. State
    // set up in `create` (media recorders, timers, subscriptions, buffers) is
    // therefore isolated per session and survives tab teardown.
    //
    // For non-per-session slots or specs without `create`, the mount is a
    // pure global renderer — one call per (re)render.
    //
    // opts.tab   — { id, label, badge? } required for tabbed slots.
    // opts.order — vertical sort weight (lower first). Default 100.
    // opts.workspace — id of a registerWorkspace() workspace this mount opens;
    //   the host stamps it on the mount so the Router highlights this item
    //   while that workspace is active. Use on sidebar.nav.* items.
    // opts.agents — override the automatic agent scope.
    mount(slot, spec, opts) {
      if (PURE || spec == null) return;
      _warnUnknownSlot(slot, `ui.mount(${_currentExtId || "?"})`);
      _register(slot, spec, opts, _currentExtId);
    },

    // Host-owned mount: identical to `mount` but bypasses PURE so official
    // built-in tabs keep working in safe mode, and defaults to no agent scope.
    mountBuiltin(slot, spec, opts) {
      if (spec == null) return;
      _warnUnknownSlot(slot, "ui.mountBuiltin");
      _register(slot, spec, opts, "host", { builtin: true });
    },

    // Register a full-page workspace under this extension. When opened it
    // takes over the main content area (host hides its own panels first) and
    // gets its own URL hash `#ext/<id>` so back/forward + reload work.
    //
    //   Clacky.ext.ui.registerWorkspace("my-console", {
    //     title: "My Console",
    //     render(container) { container.textContent = "hello"; },
    //   });
    //
    // A workspace is opened with `Clacky.ext.ui.openWorkspace(id)` — typically
    // wired to a `sidebar.nav` menu item mounted from the same extension.
    // render(container, ctx) is called every time the workspace is shown; the
    // container is cleared beforehand so the render function can be dumb.
    registerWorkspace(id, def) {
      if (PURE || !id || !def || typeof def.render !== "function") return;
      _workspaces[id] = {
        id,
        title: def.title || id,
        render: _guard(def.render, `ui.registerWorkspace(${id})`, _currentExtId),
        extId: _currentExtId,
      };
    },

    // Open a registered workspace. Emits a `clacky:ext:navigate` event that
    // the host router listens for; ext.js has no compile-time dependency on
    // the router. No-op if the id was never registered.
    openWorkspace(id) {
      if (PURE || !_workspaces[id]) return;
      document.dispatchEvent(new CustomEvent("clacky:ext:navigate", {
        detail: { view: "ext-workspace", params: { id } },
      }));
    },
  };

  // Return the per-session runtime for a mount, allocating it via `create` on
  // first use. Global mounts (or per-session slots without `create`) return
  // null — the render function is expected to work stateless.
  function _getRuntime(slot, entry, ctx) {
    if (!entry.create) return null;
    if (!PER_SESSION_SLOTS[slot]) return null;
    const sessionId = ctx && ctx.sessionId;
    if (!sessionId) return null;

    let bySession = _sessionRuntimes.get(sessionId);
    if (!bySession) {
      bySession = new Map();
      _sessionRuntimes.set(sessionId, bySession);
    }
    const key = _mountKey(slot, entry);
    let runtime = bySession.get(key);
    if (!runtime) {
      runtime = entry.create(ctx);
      if (runtime === undefined) return null;  // create threw (guarded)
      bySession.set(key, runtime || {});
    }
    return runtime;
  }

  // Run any view-level teardown collected on the previous render pass for the
  // current session, so old event listeners / RAF loops don't leak when a tab
  // is re-rendered or the session switches away.
  function _runViewTeardowns(sessionId) {
    if (!sessionId) return;
    const map = _viewTeardowns.get(sessionId);
    if (!map) return;
    map.forEach((fn) => { if (typeof fn === "function") { try { fn(); } catch (_e) {} } });
    map.clear();
  }

  function _rememberViewTeardown(sessionId, key, teardown) {
    if (!sessionId || typeof teardown !== "function") return;
    let map = _viewTeardowns.get(sessionId);
    if (!map) { map = new Map(); _viewTeardowns.set(sessionId, map); }
    map.set(key, teardown);
  }

  // Run and forget a single teardown by key. Used when a tab re-renders within
  // the same session (e.g. an eager onAttach re-running) so its previous
  // subscriptions are released before a new one is registered.
  function _runViewTeardown(sessionId, key) {
    if (!sessionId) return;
    const map = _viewTeardowns.get(sessionId);
    if (!map) return;
    const fn = map.get(key);
    if (typeof fn !== "function") return;
    map.delete(key);
    try { fn(); } catch (_e) { /* already guarded by caller */ }
  }

  // Invoke a renderer's render function. Handles the (container, ctx, runtime)
  // signature used everywhere; if the render returns a function it is stored
  // as the view teardown, run before the next render or on session exit.
  function _invokeRender(slot, entry, container, ctx) {
    const runtime = _getRuntime(slot, entry, ctx);
    let node, teardown, crashed = false, reason = null;
    try {
      const out = entry.render(container, ctx, runtime);
      if (out === undefined || out === null) {
        // undefined → container mutated in-place; null → renderer opted out of
        // this context (e.g. `if (!ctx.sessionId) return null` on the new-session
        // page). Both render nothing; neither is an error.
      } else if (typeof out === "function") {
        teardown = out;
      } else {
        node = out;
      }
    } catch (err) {
      reason = String((err && err.stack) || err);
      console.error(`[Clacky.ext] extension "${entry.extId || "?"}" threw in render for slot ${JSON.stringify(slot)}:`, err);
      crashed = true;
    }
    if (crashed) return { crashed: true, reason, extId: entry.extId };
    if (ctx && ctx.sessionId && teardown) {
      _rememberViewTeardown(ctx.sessionId, _mountKey(slot, entry), teardown);
    }
    return { node };
  }

  // Build a styled, self-contained crashed-panel placeholder: a short headline
  // plus a collapsible <details> exposing the actual reason and a nudge to the
  // console. Never throws; the reason is rendered as plain text.
  function _crashedPlaceholder(extId, reason) {
    _injectCrashStyle();
    const box = document.createElement("div");
    box.className = "ext-slot-crashed";
    box.setAttribute("data-ext-status", "crashed");

    const head = document.createElement("div");
    head.className = "ext-crashed-head";
    const icon = document.createElement("span");
    icon.className = "ext-crashed-icon";
    icon.textContent = "!";
    const title = document.createElement("span");
    title.className = "ext-crashed-title";
    title.textContent = extId ? `扩展「${extId}」渲染失败` : "扩展渲染失败";
    head.appendChild(icon);
    head.appendChild(title);
    box.appendChild(head);

    const hint = document.createElement("div");
    hint.className = "ext-crashed-hint";
    hint.textContent = "面板未能加载。展开下方详情，或打开浏览器控制台 (console) 查看完整错误。";
    box.appendChild(hint);

    if (reason) {
      const details = document.createElement("details");
      details.className = "ext-crashed-details";
      const summary = document.createElement("summary");
      summary.textContent = "错误详情";
      const pre = document.createElement("pre");
      pre.className = "ext-crashed-reason";
      pre.textContent = reason;
      details.appendChild(summary);
      details.appendChild(pre);
      box.appendChild(details);
    }
    return box;
  }

  let _crashStyleInjected = false;
  function _injectCrashStyle() {
    if (_crashStyleInjected) return;
    _crashStyleInjected = true;
    const style = document.createElement("style");
    style.id = "ext-crashed-style";
    style.textContent = `
      .ext-slot-crashed {
        margin: 12px;
        padding: 14px 16px;
        border: 1px solid var(--color-error-border, #fecaca);
        background: var(--color-error-bg, #fef2f2);
        border-radius: var(--radius-md, 8px);
        color: var(--color-text-secondary, #56585e);
        font-size: 13px;
        line-height: 1.5;
      }
      .ext-crashed-head { display: flex; align-items: center; gap: 8px; }
      .ext-crashed-icon {
        display: inline-flex; align-items: center; justify-content: center;
        width: 18px; height: 18px; flex: none;
        border-radius: 50%;
        background: var(--color-error, #ef4444);
        color: #fff; font-size: 12px; font-weight: 700; line-height: 1;
      }
      .ext-crashed-title { font-weight: 600; color: var(--color-text-primary, #1a1b1e); }
      .ext-crashed-hint { margin-top: 6px; color: var(--color-text-tertiary, #8a8d94); }
      .ext-crashed-details { margin-top: 10px; }
      .ext-crashed-details > summary {
        cursor: pointer; user-select: none;
        color: var(--color-error, #ef4444); font-weight: 500;
      }
      .ext-crashed-reason {
        margin: 8px 0 0;
        padding: 10px;
        max-height: 220px; overflow: auto;
        background: var(--color-bg-primary, #fbfbfa);
        border: 1px solid var(--color-border-primary, #e8e8e4);
        border-radius: var(--radius-sm, 6px);
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 12px; line-height: 1.45;
        white-space: pre-wrap; word-break: break-word;
        color: var(--color-text-secondary, #56585e);
      }
    `;
    (document.head || document.documentElement).appendChild(style);
  }


  // null agents AND null panel => global (always visible). Otherwise the
  // current profile must be in the renderer's agent list, or in the set of
  // agents that reference its panel.
  function _visibleFor(entry, profile) {
    if (!entry.agents && !entry.panel) return true;
    if (entry.agents && entry.agents.includes(profile)) return true;
    if (entry.panel && (_panelAgents[entry.panel] || []).includes(profile)) return true;
    return false;
  }

  // What a third-party agent's extension contributes (panels + skills), from
  // ext.yml — so the new-session page can advertise it before a session exists.
  // Returns { panels:[{id,title,title_zh}], skills:[...] } or null for built-ins.
  function contributionsForAgent(agentId) {
    return (agentId && _agentContributions[agentId]) || null;
  }

  // Render every extension registered for `slot` into `container`, scoped to the
  // current agent profile. Called by the host's view layer wherever it exposes a
  // slot, and re-called on session switch (the container is cleared first so a
  // previous agent's panels don't linger). Each renderer is isolated: if one
  // throws (guarded -> returns undefined) or yields nothing, a degraded
  // placeholder marked data-ext-status="crashed" is shown for it, and sibling
  // renderers / the rest of the page are unaffected.
  function renderSlot(slot, container, ctx) {
    if (!container) return;
    if (TABBED_SLOTS[slot]) {
      renderTabbedSlot(slot, container, ctx);
      return;
    }
    container.replaceChildren();  // clear stale render from a previous agent
    const renderers = _slotRenderers[slot];
    if (!renderers || renderers.length === 0) return;

    const profile = (ctx && ctx.agentProfile) || context.agentProfile;
    const renderCtx = Object.assign({}, context, ctx || {});
    // Lower order renders first; sort is stable so equal orders keep
    // registration order. slice() avoids mutating the registry.
    const ordered = renderers.slice().sort((a, b) => a.order - b.order);
    ordered.forEach((entry) => {
      if (!_visibleFor(entry, profile)) return;
      const wrap = document.createElement("div");
      if (entry.extId) wrap.setAttribute("data-ext-id", entry.extId);
      // Nav mounts that open a workspace declare it via opts.workspace; the
      // host stamps it so the Router alone owns the active highlight.
      if (entry.workspace) wrap.setAttribute("data-ext-workspace", entry.workspace);
      const { node, crashed, reason, extId } = _invokeRender(slot, entry, wrap, renderCtx);
      if (crashed) {
        wrap.appendChild(_crashedPlaceholder(extId || entry.extId, reason));
        container.appendChild(wrap);
        return;
      }
      if (node != null) {
        if (typeof node === "string") wrap.innerHTML = node;
        else wrap.appendChild(node);
      }
      // If render mutated `wrap` in-place (returned nothing) or produced a
      // node, either way we only append when there's something to show.
      if (wrap.childNodes.length > 0 || (node != null && typeof node === "string")) {
        container.appendChild(wrap);
      }
    });
  }

  // ── Aside tab strip ────────────────────────────────────────────────────────
  // Which panels a session shows is the user's call, not the agent profile's.
  // Nothing opens by default: a fresh session lands on the "+" picker (tools
  // and extensions, two groups), and the open set is remembered per session so
  // a session reopens the way the user left it.
  const ASIDE_TAB_STORE_PREFIX = "clacky.aside.tabs.";  // + sessionId → { open, active, t }
  const ASIDE_NEW_TAB_ID = "__new__";
  const ASIDE_TAB_STORE_MAX = 200;          // sessions kept in localStorage

  const ASIDE_PLUS_ICON =
    '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" ' +
    'stroke-width="1.5" stroke-linecap="round" aria-hidden="true">' +
    '<path d="M8 3.2v9.6M3.2 8h9.6"/></svg>';
  const ASIDE_CLOSE_ICON =
    '<svg viewBox="0 0 16 16" width="10" height="10" fill="none" stroke="currentColor" ' +
    'stroke-width="1.6" stroke-linecap="round" aria-hidden="true">' +
    '<path d="M4 4l8 8M12 4l-8 8"/></svg>';
  // Lucide outlines on a 24 grid, so a column of cards reads as one icon set
  // instead of a stack of identical boxes. Keyed by tab id; panels may also
  // ship their own glyph through `tab.icon` (an SVG string), which wins.
  const ASIDE_GLYPHS = {
    // The picker tab means "open a panel", so it gets a framed plus: a bare
    // one is already the strip's own opener right next to it.
    [ASIDE_NEW_TAB_ID]: '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M8 12h8"/><path d="M12 8v8"/>',
    files: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
    changes: '<rect x="3" y="3" width="18" height="18" rx="3"/><path d="M12 7.5v4M10 9.5h4M10 16.5h4"/>',
    tm: '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l4 2"/>',
    preview: '<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>',
    terminal: '<rect x="3" y="3" width="18" height="18" rx="3"/><path d="m8 9.5 2.5 2.5L8 14.5"/><path d="M13 15h4"/>',
    meeting: '<path d="m16 13 5.22 3.06a.5.5 0 0 0 .78-.43V8.37a.5.5 0 0 0-.78-.43L16 11"/><rect x="2" y="6" width="14" height="12" rx="2"/>',
    advisor: '<path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1.3.5 2.6 1.5 3.5.8.8 1.3 1.5 1.5 2.5"/><path d="M9 18h6"/><path d="M10 22h4"/>',
    // Same clipboard as the extension's own logo, minus the two dots on the
    // lines: at 15px they melt into the border and the whole glyph reads as
    // dirt rather than a checklist.
    "secretary-work": '<rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M12 11h4"/><path d="M12 16h4"/>',
    "ext-develop": '<path d="M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73Z"/><path d="M12 22V12"/><path d="m3.3 7 7.7 4.4a2 2 0 0 0 2 0L20.7 7"/>',
    knowledge: '<path d="M12 7v14"/><path d="M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z"/>',
    "computer-use": '<path d="M14 4.1 12 6"/><path d="m5.1 8-2.9-.8"/><path d="m6 12-1.9 2"/><path d="M7.2 2.2 8 5.1"/><path d="M9.04 9.69a.5.5 0 0 1 .65-.65l11 4.5a.5.5 0 0 1-.07.95l-4.35 1.04a1 1 0 0 0-.74.74l-1.04 4.35a.5.5 0 0 1-.95.07z"/>'
  };
  function _asideGlyph(panelId) {
    return ASIDE_GLYPHS[String(panelId || "").split("/").pop()] || null;
  }

  // One wrapper so every glyph shares size and stroke weight. Empty string
  // when the panel has no glyph of its own: one shared placeholder on every
  // extension read as clutter, so those entries render label-only.
  function _asideGlyphSvg(panelId, size) {
    const glyph = _asideGlyph(panelId);
    if (!glyph) return "";
    const px = size || 15;
    return '<svg viewBox="0 0 24 24" width="' + px + '" height="' + px + '" fill="none" ' +
      'stroke="currentColor" stroke-width="1.7" stroke-linecap="round" ' +
      'stroke-linejoin="round" aria-hidden="true">' + glyph + "</svg>";
  }

  // Panel-supplied SVG wins; otherwise the built-in glyph for its id.
  function _asideIconFor(entry, size) {
    const custom = entry && entry.tab && entry.tab.icon;
    if (typeof custom === "string" && custom.trim()) return custom;
    return _asideGlyphSvg(entry && entry.tab && entry.tab.id, size);
  }

  // Panels this agent may open at all. An extension written for one agent
  // (explicit `agents: [...]`) stays confined to it; everything else is the
  // user's to open, whatever agent they happen to be on.
  function _usableFor(entry, profile) {
    if (!entry.agents || entry.agents.length === 0) return true;
    return !!profile && entry.agents.includes(profile);
  }

  function _asideTabSessionKey(sessionId) {
    return sessionId != null && sessionId !== "" ? String(sessionId) : "__default__";
  }

  function _asideTabsGet(sessionKey) {
    try {
      const raw = window.localStorage.getItem(ASIDE_TAB_STORE_PREFIX + sessionKey);
      const v = raw ? JSON.parse(raw) : null;
      if (!v || !Array.isArray(v.open)) return null;
      return {
        open: v.open.filter((id) => typeof id === "string"),
        active: typeof v.active === "string" ? v.active : null,
      };
    } catch (_e) {
      // A corrupt record just means an empty tab strip — rebuilt on next edit.
      return null;
    }
  }

  // The cap still matters even with one key per session: sessions deleted while
  // the page was closed leave their record behind, so drop the oldest.
  function _asideTabsPrune() {
    try {
      const entries = [];
      for (let i = 0; i < window.localStorage.length; i++) {
        const key = window.localStorage.key(i);
        if (!key || key.indexOf(ASIDE_TAB_STORE_PREFIX) !== 0) continue;
        let t = 0;
        try { t = JSON.parse(window.localStorage.getItem(key) || "{}").t || 0; } catch (_e) { t = 0; }
        entries.push({ key: key, t: t });
      }
      if (entries.length <= ASIDE_TAB_STORE_MAX) return;
      entries.sort((a, b) => a.t - b.t);
      entries.slice(0, entries.length - ASIDE_TAB_STORE_MAX)
        .forEach((e) => window.localStorage.removeItem(e.key));
    } catch (_e) {
      // Quota / private mode: nothing to prune.
    }
  }

  function _asideTabsSet(sessionKey, value) {
    try {
      window.localStorage.setItem(
        ASIDE_TAB_STORE_PREFIX + sessionKey,
        JSON.stringify({ open: value.open.slice(), active: value.active, t: Date.now() })
      );
    } catch (_e) {
      // Quota / private mode: the strip still works for this page.
    }
    _asideTabsPrune();
  }

  function _asideTabsForget(sessionId) {
    if (sessionId == null || sessionId === "") return;
    try {
      window.localStorage.removeItem(ASIDE_TAB_STORE_PREFIX + _asideTabSessionKey(sessionId));
    } catch (_e) { /* ignore */ }
  }

  // Render a tabbed slot: a tab bar across the top, one body shown at a time.
  //
  // Nothing is open until the user opens it. The profile only decides which
  // panels are *reachable* (an extension restricted to one agent stays there);
  // everything else lives behind the "+" picker, which is itself a tab — so
  // closing a tab and adding one read as the same gesture. A tab's body is
  // rendered on first activation and destroyed on close, which releases its
  // subscriptions and keeps a closed panel from fetching anything. The open
  // set is persisted per session.
  function renderTabbedSlot(slot, container, ctx) {
    // Invalidate any activator captured by a previous render of this slot;
    // if this pass finds no renderers it must stay invalid.
    _slotTabActivators[slot] = null;
    const previousTabFrame = container.querySelector(".aside-tabs-frame");
    if (previousTabFrame) {
      if (previousTabFrame._overflowCleanup) previousTabFrame._overflowCleanup();
      if (previousTabFrame._langCleanup) previousTabFrame._langCleanup();
    }
    container.replaceChildren();
    const profile = (ctx && ctx.agentProfile) || context.agentProfile;
    const renderCtx = Object.assign({}, context, ctx || {});

    const usable = (_slotRenderers[slot] || [])
      .slice()
      .sort((a, b) => a.order - b.order)
      .filter((e) => e.tab && _usableFor(e, profile));

    if (usable.length === 0) return; // empty slot → host CSS collapses it

    const sessionKey = _asideTabSessionKey(renderCtx.sessionId);
    const byId = new Map(usable.map((e) => [e.tab.id, e]));
    const saved = _asideTabsGet(sessionKey);

    const state = {
      open: saved ? saved.open.filter((id) => id === ASIDE_NEW_TAB_ID || byId.has(id)) : [],
      active: null,
    };
    if (state.open.length === 0) {
      state.active = ASIDE_NEW_TAB_ID;
    } else if (saved.active === ASIDE_NEW_TAB_ID) {
      state.active = ASIDE_NEW_TAB_ID;
    } else if (saved.active && state.open.includes(saved.active)) {
      state.active = saved.active;
    } else {
      state.active = state.open[0];
    }

    const tabFrame = document.createElement("div");
    tabFrame.className = "aside-tabs-frame";
    const tabBar = document.createElement("div");
    tabBar.className = "aside-tabs";
    tabFrame.appendChild(tabBar);
    const bodies = document.createElement("div");
    bodies.className = "aside-bodies";
    container.appendChild(tabFrame);
    container.appendChild(bodies);

    // Parked outside the scrolling strip: however many tabs are open, the way
    // to add another one never scrolls out of reach.
    const addBtn = document.createElement("button");
    addBtn.type = "button";
    addBtn.className = "aside-tab-add";
    addBtn.innerHTML = ASIDE_PLUS_ICON;
    addBtn.setAttribute("aria-label", _asideText("aside.newTab", "New tab"));
    addBtn.setAttribute("data-tooltip", _asideText("aside.newTab", "New tab"));
    addBtn.setAttribute("data-tooltip-pos", "bottom");
    addBtn.addEventListener("click", () => {
      // Already on the picker: the opener has nowhere to go, so acknowledge
      // the click instead of repainting an identical page.
      if (state.active === ASIDE_NEW_TAB_ID) {
        if (newTabBody) newTabBody.scrollTop = 0;
        addBtn.classList.remove("is-nudging");
        void addBtn.offsetWidth;
        addBtn.classList.add("is-nudging");
        return;
      }
      activate(ASIDE_NEW_TAB_ID);
    });
    addBtn.addEventListener("animationend", () => addBtn.classList.remove("is-nudging"));
    tabFrame.appendChild(addBtn);

    // Strip labels come from the dictionary, so a language switch has to
    // repaint them instead of leaving the previous language behind.
    const refreshStripText = () => {
      const label = _asideText("aside.newTab", "New tab");
      addBtn.setAttribute("aria-label", label);
      addBtn.setAttribute("data-tooltip", label);
      paint();
    };
    document.addEventListener("langchange", refreshStripText);
    tabFrame._langCleanup = () => document.removeEventListener("langchange", refreshStripText);

    const tabBtns = {};        // id => tab button (rebuilt on every paint)
    const tabBadges = {};      // id => last badge value, so paints keep it
    const bodyEls = {};        // id => body element (survives paints until closed)
    const rendered = {};       // id => true once the panel body has run render
    const attached = {};       // id => true once tab.onAttach has run
    let newTabBody = null;

    function labelOf(entry) {
      const raw = entry.tab.label;
      const label = typeof raw === "function" ? raw() : raw;
      return label || entry.tab.id;
    }

    function persist() {
      _asideTabsSet(sessionKey, { open: state.open, active: state.active });
    }

    function tabCtx(id) {
      return Object.assign({}, renderCtx, {
        setBadge: (n) => {
          tabBadges[id] = n;
          _setTabBadge(tabBtns[id], n);
        },
      });
    }

    function ensureBody(id) {
      let body = bodyEls[id];
      if (body) return body;
      body = document.createElement("div");
      body.className = "aside-panel";
      body.setAttribute("data-panel", id);
      bodies.appendChild(body);
      bodyEls[id] = body;
      return body;
    }

    function attachPanel(id) {
      if (attached[id]) return;
      attached[id] = true;
      const entry = byId.get(id);
      if (!entry || typeof entry.tab.onAttach !== "function") return;
      const attachKey = _mountKey(slot, entry) + "::attach";
      let teardown;
      try {
        teardown = entry.tab.onAttach(tabCtx(id));
      } catch (err) {
        console.error(`[Clacky.ext] onAttach for tab "${id}" threw:`, err);
        teardown = null;
      }
      if (typeof teardown === "function" && renderCtx.sessionId) {
        _rememberViewTeardown(renderCtx.sessionId, attachKey, teardown);
      }
    }

    function renderBody(id) {
      if (rendered[id]) return;
      rendered[id] = true;
      attachPanel(id);
      const body = ensureBody(id);
      const entry = byId.get(id);
      const { node, crashed, reason, extId } = _invokeRender(slot, entry, body, tabCtx(id));
      if (crashed) {
        body.appendChild(_crashedPlaceholder(extId || entry.extId, reason));
      } else if (node != null) {
        if (typeof node === "string") body.innerHTML = node;
        else body.appendChild(node);
      }
    }

    function disposePanel(id) {
      const entry = byId.get(id);
      if (entry) {
        const key = _mountKey(slot, entry);
        _runViewTeardown(renderCtx.sessionId, key + "::attach");
        _runViewTeardown(renderCtx.sessionId, key);
      }
      if (bodyEls[id]) {
        bodyEls[id].remove();
        delete bodyEls[id];
      }
      // The picker body is kept in its own handle and never lands in bodyEls,
      // so it needs both the node and the handle cleared: leaving the node
      // behind makes the next open paint a second copy next to the old one.
      if (id === ASIDE_NEW_TAB_ID) {
        if (newTabBody) newTabBody.remove();
        newTabBody = null;
      }
      delete rendered[id];
      delete attached[id];
      delete tabBadges[id];
    }

    function ensureNewTabBody() {
      if (newTabBody) return newTabBody;
      newTabBody = document.createElement("div");
      newTabBody.className = "aside-panel aside-newtab";
      newTabBody.setAttribute("data-panel", ASIDE_NEW_TAB_ID);
      bodies.appendChild(newTabBody);
      return newTabBody;
    }

    function cardFor(entry) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "aside-newtab-card";
      btn.setAttribute("data-panel-id", entry.tab.id);

      const text = document.createElement("span");
      text.className = "aside-newtab-text";

      const name = document.createElement("span");
      name.className = "aside-newtab-name";
      name.textContent = labelOf(entry);
      text.appendChild(name);

      const desc = entry.tab && entry.tab.description;
      if (desc) {
        const sub = document.createElement("span");
        sub.className = "aside-newtab-desc";
        sub.textContent = desc;
        text.appendChild(sub);
      }

      const iconHtml = _asideIconFor(entry);
      if (iconHtml) {
        const icon = document.createElement("span");
        icon.className = "aside-newtab-icon";
        icon.innerHTML = iconHtml;
        btn.appendChild(icon);
      }
      btn.appendChild(text);
      btn.addEventListener("click", () => activate(entry.tab.id, true));
      return btn;
    }

    function group(titleKey, fallback, entries) {
      if (entries.length === 0) return null;
      const section = document.createElement("div");
      section.className = "aside-newtab-group";
      const heading = document.createElement("div");
      heading.className = "aside-newtab-title";
      heading.textContent = _asideText(titleKey, fallback);
      section.appendChild(heading);
      const grid = document.createElement("div");
      grid.className = "aside-newtab-grid";
      entries.forEach((entry) => grid.appendChild(cardFor(entry)));
      section.appendChild(grid);
      return section;
    }

    function renderNewTabPage() {
      const body = ensureNewTabBody();
      body.replaceChildren();

      const closed = usable.filter((e) => !state.open.includes(e.tab.id));
      if (closed.length === 0) {
        const empty = document.createElement("div");
        empty.className = "aside-newtab-empty";
        empty.textContent = _asideText("aside.allOpen", "All panels are already open");
        body.appendChild(empty);
        return;
      }
      // Split by where the panel comes from: host + official extensions ship
      // with the product, the rest are installed from the market or written
      // locally. Grouping by function would have to guess what a panel "is".
      const official = closed.filter((e) => e.layer === "host" || e.layer === "builtin");
      const mine = closed.filter((e) => e.layer !== "host" && e.layer !== "builtin");
      [group("aside.group.official", "Official", official),
       group("aside.group.mine", "Mine", mine)].forEach((section) => {
        if (section) body.appendChild(section);
      });
    }

    // `fromPicker` marks a pick made on the picker page: the picker has done
    // its job, so it retires instead of lingering as a tab to close by hand.
    function activate(id, fromPicker) {
      if (id !== ASIDE_NEW_TAB_ID && !byId.has(id)) return false;
      if (fromPicker) {
        const pickerIndex = state.open.indexOf(ASIDE_NEW_TAB_ID);
        if (pickerIndex >= 0) state.open.splice(pickerIndex, 1);
      }
      // Appends, so a newly opened panel always lands right of the others
      // instead of being re-sorted into the extension's declared order. The
      // picker is opened the same way: once the user asks for it, it is a tab
      // that stays put while they look at their panels.
      if (!state.open.includes(id)) state.open.push(id);
      state.active = id;
      persist();
      paint();
      return true;
    }
    _slotTabActivators[slot] = activate;

    function closePanel(id) {
      const index = state.open.indexOf(id);
      // The picker is the visible page while `open` is still empty, so a
      // missing index does not mean there is nothing to close.
      if (index < 0 && id !== ASIDE_NEW_TAB_ID) return;
      if (index >= 0) state.open.splice(index, 1);
      disposePanel(id);
      if (state.active === id) {
        state.active = state.open.length
          ? state.open[Math.min(Math.max(index, 0), state.open.length - 1)]
          : ASIDE_NEW_TAB_ID;
      }
      persist();
      paint();
      // An emptied strip has nothing to show, so the column collapses instead
      // of silently falling back to the picker. That covers the picker itself
      // as well as the last real panel: reopening the panel brings the picker
      // back, which is where a fresh column starts anyway.
      if (state.open.length === 0 && window.Clacky && Clacky.Aside) {
        Clacky.Aside.close();
      }
    }

    function tabButton(id, label, entry) {
      const btn = document.createElement("button");
      btn.className = "aside-tab";
      btn.type = "button";
      btn.setAttribute("data-tab", id);
      btn.classList.toggle("active", state.active === id);

      const iconHtml = id === ASIDE_NEW_TAB_ID
        ? _asideGlyphSvg(ASIDE_NEW_TAB_ID, 14)
        : _asideIconFor(entry, 14);
      if (iconHtml) {
        const icon = document.createElement("span");
        icon.className = "aside-tab-icon";
        icon.innerHTML = iconHtml;
        btn.appendChild(icon);
      }

      const text = document.createElement("span");
      text.className = "aside-tab-label";
      text.textContent = label;
      btn.appendChild(text);

      if (entry && entry.tab.badge != null) _setTabBadge(btn, entry.tab.badge);
      if (tabBadges[id] != null) _setTabBadge(btn, tabBadges[id]);

      // Every tab can be closed by hand, the picker included. Emptying the
      // strip this way collapses the whole column, which is the gesture the
      // user expects from that ×.
      const close = document.createElement("span");
      close.className = "aside-tab-close";
      close.setAttribute("role", "button");
      close.setAttribute("aria-label", _asideText("aside.closeTab", "Close tab"));
      close.title = _asideText("aside.closeTab", "Close tab");
      close.innerHTML = ASIDE_CLOSE_ICON;
      close.addEventListener("click", (event) => {
        event.stopPropagation();
        closePanel(id);
      });
      btn.appendChild(close);

      btn.addEventListener("click", () => activate(id));
      tabBtns[id] = btn;
      tabBar.appendChild(btn);
    }

    function paint() {
      Object.keys(tabBtns).forEach((k) => delete tabBtns[k]);
      tabBar.replaceChildren();
      state.open.forEach((id) => {
        if (id === ASIDE_NEW_TAB_ID) tabButton(id, _asideText("aside.newTab", "New tab"), null);
        else tabButton(id, labelOf(byId.get(id)), byId.get(id));
      });
      if (state.active === ASIDE_NEW_TAB_ID && !state.open.includes(ASIDE_NEW_TAB_ID)) {
        tabButton(ASIDE_NEW_TAB_ID, _asideText("aside.newTab", "New tab"), null);
      }

      Object.keys(bodyEls).forEach((id) => {
        bodyEls[id].classList.toggle("active", state.active === id);
      });

      if (state.active === ASIDE_NEW_TAB_ID) {
        if (newTabBody) newTabBody.classList.remove("active");
        renderNewTabPage();
        newTabBody.scrollTop = 0;
        newTabBody.classList.add("active");
      } else {
        if (newTabBody) newTabBody.classList.remove("active");
        renderBody(state.active);
        ensureBody(state.active).classList.add("active");
      }

      revealActiveTab();
      // Feeds the CSS width formula: every tab shares the strip's free width.
      tabFrame.style.setProperty("--aside-tab-count", String(tabBar.childElementCount));

      const maxScroll = Math.max(0, tabBar.scrollWidth - tabBar.clientWidth);
      tabFrame.classList.toggle("can-scroll-left", tabBar.scrollLeft > 1);
      tabFrame.classList.toggle("can-scroll-right", tabBar.scrollLeft < maxScroll - 1);
    }

    // A freshly opened tab can land outside the strip; nudge the scroll so the
    // active item stays readable instead of hiding under the "+" opener.
    function revealActiveTab() {
      const btn = tabBtns[state.active];
      if (!btn) return;
      const reserve = parseFloat(getComputedStyle(tabBar).paddingRight) || 0;
      const barRect = tabBar.getBoundingClientRect();
      const btnRect = btn.getBoundingClientRect();
      const visibleRight = barRect.right - reserve;
      if (btnRect.right > visibleRight) {
        tabBar.scrollLeft += btnRect.right - visibleRight;
      } else if (btnRect.left < barRect.left) {
        tabBar.scrollLeft -= barRect.left - btnRect.left;
      }
    }

    const syncOverflowCues = () => {
      const maxScroll = Math.max(0, tabBar.scrollWidth - tabBar.clientWidth);
      tabFrame.classList.toggle("can-scroll-left", tabBar.scrollLeft > 1);
      tabFrame.classList.toggle("can-scroll-right", tabBar.scrollLeft < maxScroll - 1);
    };
    // A label too long for its pill is clipped rather than ellipsised, so it
    // needs a soft edge: flag the ones actually cut and let CSS fade them out.
    const syncClippedLabels = () => {
      Object.keys(tabBtns).forEach((id) => {
        const label = tabBtns[id].querySelector(".aside-tab-label");
        if (label) tabBtns[id].classList.toggle("is-clipped", label.scrollWidth > label.clientWidth + 1);
      });
    };
    const scrollTabsWithWheel = (event) => {
      // Preserve native horizontal trackpad gestures. A predominantly vertical
      // wheel gesture is translated only while the strip can move that way.
      if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
      const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? tabBar.clientWidth : 1;
      const delta = event.deltaY * unit;
      const maxScroll = Math.max(0, tabBar.scrollWidth - tabBar.clientWidth);
      const nextScroll = Math.max(0, Math.min(maxScroll, tabBar.scrollLeft + delta));
      if (Math.abs(nextScroll - tabBar.scrollLeft) < 1) return;
      event.preventDefault();
      tabBar.scrollLeft = nextScroll;
    };
    const onStripResize = () => {
      syncOverflowCues();
      syncClippedLabels();
    };
    tabBar.addEventListener("scroll", syncOverflowCues, { passive: true });
    tabBar.addEventListener("wheel", scrollTabsWithWheel, { passive: false });
    const resizeObserver = window.ResizeObserver ? new ResizeObserver(onStripResize) : null;
    const mutationObserver = window.MutationObserver ? new MutationObserver(onStripResize) : null;
    if (resizeObserver) resizeObserver.observe(tabBar);
    if (mutationObserver) mutationObserver.observe(tabBar, { childList: true, subtree: true, characterData: true });
    if (!resizeObserver) window.addEventListener("resize", onStripResize);
    tabFrame._overflowCleanup = () => {
      tabBar.removeEventListener("scroll", syncOverflowCues);
      tabBar.removeEventListener("wheel", scrollTabsWithWheel);
      if (resizeObserver) resizeObserver.disconnect();
      else window.removeEventListener("resize", onStripResize);
      if (mutationObserver) mutationObserver.disconnect();
    };

    paint();
    requestAnimationFrame(onStripResize);
  }

  // Translate a tab-strip string, falling back when i18n isn't loaded yet.
  // I18n hangs off Clacky, not window: reading window.I18n would silently pin
  // every strip label to English.
  function _asideText(key, fallback) {
    const i18n = window.Clacky && window.Clacky.I18n;
    if (!i18n || typeof i18n.t !== "function") return fallback;
    const value = i18n.t(key);
    return value && value !== key ? value : fallback;
  }

  // Set or clear a tab's badge pill. n == null/0 removes it.
  function _setTabBadge(btn, n) {
    if (!btn) return;
    let badge = btn.querySelector(".aside-tab-badge");
    if (n == null || n === 0 || n === "") {
      if (badge) badge.remove();
      return;
    }
    if (!badge) {
      badge = document.createElement("span");
      badge.className = "aside-tab-badge";
      btn.appendChild(badge);
    }
    badge.textContent = String(n);
  }

  // List slot names that currently have at least one renderer (host/debug use).
  function slots() {
    return Object.keys(_slotRenderers).filter((s) => _slotRenderers[s].length > 0);
  }

  // Programmatically activate a tab in a tabbed slot (e.g. switch the session
  // aside to the preview tab when the user clicks an HTML file or a localhost
  // link in chat). Returns true when the slot is rendered and the tab exists.
  function activateTab(slot, tabId) {
    const activate = _slotTabActivators[slot];
    return activate ? !!activate(tabId) : false;
  }

  // Update the current session context (host calls this on every session
  // switch) and re-render all slots so panels match the new agent profile.
  // Runs the previous session's view-level teardowns first (event listeners /
  // RAF loops attached to now-dead DOM), but leaves per-session runtimes
  // alive — the meeting recorder for session A keeps running while you're
  // looking at B, and its captions are still there when you switch back.
  function setContext(next) {
    const prevSessionId = context.sessionId;
    Object.assign(context, next || {});
    if (prevSessionId && prevSessionId !== context.sessionId) {
      _runViewTeardowns(prevSessionId);
    }
    refreshSlots();
  }

  // Called by the host when a session leaves the sidebar for good (deleted,
  // archived, or the page is unloading). Runs every runtime's `dispose()` for
  // that session so timers, media recorders, and network handles are released.
  function notifySessionRemoved(sessionId) {
    if (!sessionId) return;
    _runViewTeardowns(sessionId);
    _viewTeardowns.delete(sessionId);
    _asideTabsForget(sessionId);
    const bySession = _sessionRuntimes.get(sessionId);
    if (!bySession) return;
    bySession.forEach((runtime) => {
      if (runtime && typeof runtime.dispose === "function") {
        try { runtime.dispose(); } catch (err) {
          console.error("[Clacky.ext] runtime.dispose failed:", err);
        }
      }
    });
    _sessionRuntimes.delete(sessionId);
  }

  // Re-render every named slot present in the DOM against the current context.
  // Idempotent: each slot's container is cleared before re-rendering.
  // main.workspace is skipped: the Router owns it (registerWorkspace render),
  // and clearing it here blanked any open workspace on language switch.
  function refreshSlots() {
    if (PURE) return;
    document.querySelectorAll("[data-slot]").forEach((el) => {
      const slot = el.getAttribute("data-slot");
      if (slot === "main.workspace") return;
      renderSlot(slot, el);
    });
  }

  return {
    get pure() { return PURE; },
    context,
    setContext,
    notifySessionRemoved,
    refreshSlots,
    registerPanelAgents,
    registerAgentContributions,
    contributionsForAgent,
    api,
    ui,
    subscribe,
    emit,
    renderSlot,
    slots,
    activateTab,
    // Host-only: look up a registered workspace by id. Returns
    // { id, title, render, extId } or undefined. Used by the Router when
    // handling the `ext-workspace` view — extensions never call this.
    _getWorkspace(id) { return _workspaces[id]; },
    _extBegin,  // used by the loader; not part of the public extension API
    _extEnd,    // used by the loader; not part of the public extension API
  };
})();
