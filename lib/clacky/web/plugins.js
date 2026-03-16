// ── plugins.js — Plugin system loader ────────────────────────────────────
//
// Fetches installed plugins from GET /api/plugins on boot, then:
//   1. Dynamically injects sidebar entries into #plugins-section
//   2. Dynamically injects panel containers into #main
//   3. Loads each plugin's plugin.js via a <script> tag (sandboxed)
//
// Plugin panel IDs follow the convention: plugin-panel-{id}
// Plugin sidebar item IDs: plugin-sidebar-{id}
//
// Plugins communicate with the host app via the PluginBridge API
// exposed on window.PluginBridge.
// ─────────────────────────────────────────────────────────────────────────

const Plugins = (() => {
  // Installed plugin descriptors returned by /api/plugins
  let _plugins = [];

  // ── i18n helper ───────────────────────────────────────────────────────
  //
  // Resolve a plugin field that may be either:
  //   - a plain string:  "Coding Agent"
  //   - an i18n object:  { en: "Coding Agent", zh: "编程助手" }
  //
  // Falls back to "en", then to the raw value, then to the fallback arg.
  //
  // Usage: _t(plugin.name)  or  _t(plugin.sidebar_divider, "")
  // ─────────────────────────────────────────────────────────────────────
  function _t(field, fallback = "") {
    if (!field) return fallback;
    if (typeof field === "string") return field;
    if (typeof field === "object") {
      const lang = (typeof I18n !== "undefined") ? I18n.lang() : "en";
      return field[lang] ?? field["en"] ?? fallback;
    }
    return fallback;
  }

  // ── PluginBridge ──────────────────────────────────────────────────────
  //
  // Public API exposed to plugin scripts so they can interact with the host
  // app without touching internals directly.
  //
  // Available inside plugin.js as: PluginBridge.navigate(...)
  //                                PluginBridge.onNavigate(...)
  //                                PluginBridge.getActiveSession()
  // ─────────────────────────────────────────────────────────────────────
  const PluginBridge = {
    /**
     * Navigate to a plugin panel.
     * @param {string} pluginId - The plugin id (e.g. "coding-agent")
     */
    navigate(pluginId) {
      // Delegate to the main Router (defined in app.js, loaded after plugins.js)
      if (typeof Router !== "undefined") {
        Router.navigate("plugin", { id: pluginId });
      }
    },

    /**
     * Register a callback that fires whenever the active view changes.
     * @param {Function} fn - Called with (view, params)
     */
    onNavigate(fn) {
      _navListeners.push(fn);
    },

    /**
     * Returns the currently active session object, or null.
     */
    getActiveSession() {
      if (typeof Sessions !== "undefined") {
        return Sessions.find(Sessions.activeId) || null;
      }
      return null;
    },

    /**
     * Make an authenticated fetch to the local server API.
     * @param {string} path - e.g. "/api/sessions"
     * @param {object} opts - fetch options
     */
    async fetch(path, opts = {}) {
      const res = await fetch(path, {
        headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
        ...opts,
      });
      return res;
    },

    /**
     * Show a simple info message in the current panel (uses Sessions.appendInfo if available).
     * @param {string} message
     */
    info(message) {
      if (typeof Sessions !== "undefined") {
        Sessions.appendInfo(message);
      }
    },

    /**
     * Register a callback that fires once when the given plugin's panel.html is fully injected
     * into the DOM. If the panel is already ready, the callback fires on the next microtask.
     * Use this instead of reading panel DOM elements inside onNavigate(), because panel.html
     * is loaded asynchronously and may not be present when onNavigate fires.
     *
     * @param {string} pluginId - e.g. "coding-agent"
     * @param {Function} fn - called with no arguments when panel DOM is ready
     */
    onPanelReady(pluginId, fn) {
      const panelId = `plugin-panel-${pluginId}`;
      const panel = document.getElementById(panelId);
      // If panel element already has children, html has already been injected
      if (panel && panel.children.length > 0) {
        Promise.resolve().then(fn);
        return;
      }
      if (!_panelReadyListeners[pluginId]) {
        _panelReadyListeners[pluginId] = [];
      }
      _panelReadyListeners[pluginId].push(fn);
    },
  };

  // Navigation change listeners registered by plugins
  const _navListeners = [];

  // Panel-ready listeners: called once when a plugin's panel.html is fully injected into DOM.
  // Map of pluginId → [callback, ...]
  const _panelReadyListeners = {};

  // Called by Router._apply() after each view change (wired up in app.js)
  function _notifyNavListeners(view, params) {
    _navListeners.forEach(fn => {
      try { fn(view, params); } catch (e) { console.error("[Plugins] onNavigate error:", e); }
    });
  }

  // ── Sidebar injection ─────────────────────────────────────────────────

  // Ensure the #plugins-section container exists in the sidebar.
  // It is created once and appended to #sidebar-list.
  function _ensurePluginsSection() {
    if (document.getElementById("plugins-section")) return;

    const section = document.createElement("div");
    section.id = "plugins-section";

    const list = document.getElementById("sidebar-list");
    if (list) list.appendChild(section);
  }

  // Inject a sidebar entry for one plugin.
  function _injectSidebarEntry(plugin) {
    _ensurePluginsSection();

    const section = document.getElementById("plugins-section");
    if (!section) return;

    // Check if already injected (idempotent)
    if (document.getElementById(`plugin-sidebar-${plugin.id}`)) return;

    // If the plugin declares a sidebar_divider, inject it before the entry.
    const dividerText = _t(plugin.sidebar_divider);
    if (dividerText) {
      const divider = document.createElement("div");
      divider.className = "sidebar-divider";
      // Store plugin id so we can re-translate on language change
      divider.dataset.pluginDivider = plugin.id;
      divider.innerHTML = `<span>${dividerText}</span>`;
      section.appendChild(divider);
    }

    // If the plugin has a custom sidebar.html, fetch and inject it.
    // Otherwise render a default entry.
    if (plugin.has_sidebar_html) {
      fetch(`/api/plugins/${plugin.id}/assets/sidebar.html`)
        .then(r => r.text())
        .then(html => {
          const wrapper = document.createElement("div");
          wrapper.id        = `plugin-sidebar-${plugin.id}`;
          wrapper.className = "plugin-sidebar-entry";
          wrapper.innerHTML = html;

          // Wire up click → navigate to plugin panel
          wrapper.addEventListener("click", () => {
            if (typeof Router !== "undefined") {
              Router.navigate("plugin", { id: plugin.id });
            }
          });

          section.appendChild(wrapper);
          // Notify plugin scripts that sidebar is ready
          document.dispatchEvent(new CustomEvent(`plugin:sidebar-ready:${plugin.id}`));
        })
        .catch(e => console.error(`[Plugins] Failed to load sidebar.html for ${plugin.id}:`, e));
    } else {
      // Default sidebar entry — use _t() to resolve i18n name
      const wrapper = document.createElement("div");
      wrapper.id        = `plugin-sidebar-${plugin.id}`;
      wrapper.className = "task-item task-item-summary plugin-sidebar-entry";
      wrapper.innerHTML = `
        <div class="task-row">
          <span class="task-icon">${plugin.icon || "🧩"}</span>
          <div class="task-info">
            <span class="task-name">${_t(plugin.name, plugin.id)}</span>
          </div>
        </div>
      `;
      wrapper.addEventListener("click", () => {
        if (typeof Router !== "undefined") {
          Router.navigate("plugin", { id: plugin.id });
        }
      });
      section.appendChild(wrapper);
    }
  }

  // ── Panel injection ───────────────────────────────────────────────────

  // Inject a panel container for one plugin into #main.
  function _injectPanel(plugin) {
    const panelId = `plugin-panel-${plugin.id}`;
    if (document.getElementById(panelId)) return;

    const main = document.getElementById("main");
    if (!main) return;

    const panel = document.createElement("div");
    panel.id            = panelId;
    panel.className     = "plugin-panel";
    panel.style.display = "none";

    if (plugin.has_panel_html) {
      fetch(`/api/plugins/${plugin.id}/assets/panel.html`)
        .then(r => r.text())
        .then(html => {
          panel.innerHTML = html;
          // Notify any listeners waiting for this plugin's panel to be ready
          const pluginId = plugin.id;
          if (_panelReadyListeners[pluginId]) {
            _panelReadyListeners[pluginId].forEach(fn => {
              try { fn(); } catch (e) { console.error(`[Plugins] onPanelReady error for ${pluginId}:`, e); }
            });
            delete _panelReadyListeners[pluginId];
          }
        })
        .catch(e => console.error(`[Plugins] Failed to load panel.html for ${plugin.id}:`, e));
    } else {
      // Default empty panel placeholder — use _t() to resolve i18n fields
      panel.innerHTML = `
        <div class="plugin-panel-placeholder">
          <span>${plugin.icon || "🧩"}</span>
          <h2>${_t(plugin.name, plugin.id)}</h2>
          <p>${_t(plugin.description)}</p>
        </div>
      `;
    }

    main.appendChild(panel);
  }

  // ── Plugin JS loader ──────────────────────────────────────────────────

  // Dynamically load a plugin's plugin.js.
  // The script runs in the page context and can access window.PluginBridge.
  function _loadPluginScript(plugin) {
    if (!plugin.has_plugin_js) return;

    const script = document.createElement("script");
    script.src   = `/api/plugins/${plugin.id}/assets/plugin.js`;
    script.async = true;
    script.onerror = () => console.error(`[Plugins] Failed to load plugin.js for ${plugin.id}`);
    document.head.appendChild(script);
  }

  // ── Language change — re-translate sidebar dividers ───────────────────
  //
  // Sidebar divider text is rendered once on load. When the user switches
  // language in Settings, we re-translate all dividers via data-plugin-divider.

  document.addEventListener("i18n:langchange", () => {
    document.querySelectorAll("[data-plugin-divider]").forEach(divider => {
      const pluginId = divider.dataset.pluginDivider;
      const plugin   = _plugins.find(p => p.id === pluginId);
      if (!plugin) return;
      const text = _t(plugin.sidebar_divider);
      if (text) {
        const span = divider.querySelector("span");
        if (span) span.textContent = text;
      }
    });
  });

  // ── Boot ──────────────────────────────────────────────────────────────

  // Fetch plugin list from server and bootstrap all plugins.
  async function init() {
    try {
      const res  = await fetch("/api/plugins");
      const data = await res.json();
      _plugins   = data.plugins || [];

      if (_plugins.length === 0) return;  // No plugins installed — nothing to do

      // Expose PluginBridge globally so plugin scripts can access it
      window.PluginBridge = PluginBridge;

      _plugins.forEach(plugin => {
        if (plugin.sidebar !== false) {
          _injectSidebarEntry(plugin);
        }
        _injectPanel(plugin);
        _loadPluginScript(plugin);
      });
    } catch (e) {
      console.error("[Plugins] Failed to initialize plugins:", e);
    }
  }

  // ── Public API ────────────────────────────────────────────────────────

  return {
    init,

    /** All loaded plugin descriptors. */
    get all() { return _plugins; },

    /** Find a plugin by id. */
    find: id => _plugins.find(p => p.id === id) || null,

    /**
     * Get the panel DOM element for a plugin.
     * @param {string} id - Plugin id
     */
    getPanel: id => document.getElementById(`plugin-panel-${id}`),

    /**
     * Get the sidebar DOM element for a plugin.
     * @param {string} id - Plugin id
     */
    getSidebarItem: id => document.getElementById(`plugin-sidebar-${id}`),

    /**
     * Called by Router after each view change to notify plugins.
     * Wired up in app.js.
     */
    notifyNavListeners: _notifyNavListeners,

    /** Expose PluginBridge for external use */
    Bridge: PluginBridge,
  };
})();
