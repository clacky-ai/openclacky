// mcp.js — MCP servers panel (read-only, Agent-First).
//
// This page lists MCP servers configured in ~/.clacky/mcp.json (or project-level
// override). Configuration itself stays in the JSON file — same format as
// Claude Desktop and Cursor — so existing configs work as-is.
//
// Per-server "Show tools" probes the server briefly to fetch its tool catalog.
// Nothing here keeps a process running; agent runs do their own lazy spawn.

const Mcp = (() => {

  let _data = null;
  const _expanded = new Set();
  const _toolsCache = new Map();

  async function onPanelShow() {
    await _load();
  }

  async function _load() {
    const list = $("mcp-list");
    const status = $("mcp-status");
    if (!list) return;
    list.innerHTML = `<div class="channel-loading">${I18n.t("mcp.loading")}</div>`;
    if (status) status.innerHTML = "";

    try {
      const res = await fetch("/api/mcp");
      const data = await res.json();
      _data = data;
      _render();
    } catch (e) {
      list.innerHTML = `<div class="channel-error">${I18n.t("mcp.loadError", { msg: _esc(e.message) })}</div>`;
    }
  }

  function _render() {
    const list = $("mcp-list");
    const status = $("mcp-status");
    if (!list || !_data) return;

    if (status) {
      const pathLabel = _data.config_exists
        ? _esc(_data.config_path)
        : `${_esc(_data.config_path)} <em>${I18n.t("mcp.config.missing")}</em>`;
      status.innerHTML = `
        <div class="mcp-cta">
          <div class="mcp-cta-text">
            <h3>${I18n.t("mcp.cta.title")}</h3>
            <p>${I18n.t("mcp.cta.body")}</p>
          </div>
          <button class="btn-mcp-cta" id="btn-mcp-cta">
            <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>
            </svg>
            ${I18n.t("mcp.cta.button")}
          </button>
        </div>
        <div class="mcp-config-line">
          <div class="mcp-config-text">
            <span class="mcp-config-label">${I18n.t("mcp.config.path")}</span>
            <code>${pathLabel}</code>
          </div>
          <button class="btn-mcp-refresh" id="btn-mcp-refresh" title="${_esc(I18n.t("mcp.btn.refresh"))}">
            <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M21 2v6h-6"/><path d="M3 12a9 9 0 0 1 15-6.7L21 8"/>
              <path d="M3 22v-6h6"/><path d="M21 12a9 9 0 0 1-15 6.7L3 16"/>
            </svg>
          </button>
        </div>
      `;
      $("btn-mcp-refresh")?.addEventListener("click", () => {
        _toolsCache.clear();
        _expanded.clear();
        _load();
      });
      $("btn-mcp-cta")?.addEventListener("click", () => _askClackyAdd());
    }

    list.innerHTML = "";

    if (!_data.configured || !_data.servers || _data.servers.length === 0) {
      list.innerHTML = `
        <div class="mcp-empty">
          <h3>${I18n.t("mcp.empty.title")}</h3>
          <p>${I18n.t("mcp.empty.body")}</p>
          <button class="btn-mcp-cta btn-mcp-cta-large" id="btn-mcp-empty-cta">
            ${I18n.t("mcp.cta.button")}
          </button>
        </div>
      `;
      $("btn-mcp-empty-cta")?.addEventListener("click", () => _askClackyAdd());
      return;
    }

    _data.servers.forEach(server => {
      list.appendChild(_renderCard(server));
    });
  }

  function _renderCard(server) {
    const card = document.createElement("div");
    card.className = "channel-card mcp-card";
    if (server.disabled) card.classList.add("mcp-card-disabled");
    card.id = `mcp-card-${_esc(server.name)}`;

    const isHttp = server.type === "http" || server.type === "streamable-http";
    const cmdLine = isHttp
      ? (server.url || "")
      : [server.command, ...(server.args || [])].filter(Boolean).join(" ");
    const cmdLabel = isHttp ? I18n.t("mcp.url") : I18n.t("mcp.command");
    const isExpanded = _expanded.has(server.name);
    const toggleAria = server.disabled
      ? I18n.t("mcp.toggle.off")
      : I18n.t("mcp.toggle.on");

    card.innerHTML = `
      <div class="channel-card-header">
        <div class="channel-card-identity">
          <span class="channel-logo mcp-logo" aria-hidden="true">
            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <rect x="3" y="4" width="18" height="6" rx="1"/>
              <rect x="3" y="14" width="18" height="6" rx="1"/>
              <path d="M8 7h.01M8 17h.01"/>
            </svg>
          </span>
          <div>
            <div class="channel-card-name">${_esc(server.name)}</div>
            <div class="channel-card-desc">${_esc(server.description || "")}</div>
          </div>
        </div>
        <div class="channel-card-status">
          <label class="toggle-switch" title="${_esc(toggleAria)}">
            <input type="checkbox"
                   id="toggle-mcp-${_esc(server.name)}"
                   ${!server.disabled ? "checked" : ""}
                   aria-label="${_esc(toggleAria)}">
            <span class="toggle-slider"></span>
          </label>
        </div>
      </div>

      <div class="channel-card-body">
        ${cmdLine ? `
          <div class="mcp-cmd-block">
            <div class="mcp-cmd-label">${cmdLabel}</div>
            <code class="mcp-cmd">${_esc(cmdLine)}</code>
          </div>
        ` : ""}
        <div class="mcp-tools-region" id="mcp-tools-${_esc(server.name)}" style="display:${isExpanded ? "block" : "none"}"></div>
      </div>

      <div class="channel-card-footer">
        <div class="channel-card-actions">
          <button class="btn-mcp-probe" id="btn-mcp-probe-${_esc(server.name)}" ${server.disabled ? "disabled" : ""}>
            <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <circle cx="11" cy="11" r="8"/>
              <line x1="21" y1="21" x2="16.65" y2="16.65"/>
            </svg>
            ${isExpanded ? I18n.t("mcp.btn.hide") : I18n.t("mcp.btn.probe")}
          </button>
          <button class="btn-mcp-remove" id="btn-mcp-remove-${_esc(server.name)}">
            <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="3 6 5 6 21 6"/>
              <path d="M19 6l-2 14a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2L5 6"/>
              <path d="M10 11v6M14 11v6"/>
            </svg>
            ${I18n.t("mcp.btn.remove")}
          </button>
        </div>
      </div>
    `;

    card.querySelector(`#btn-mcp-probe-${CSS.escape(server.name)}`)
      ?.addEventListener("click", () => {
        if (server.disabled) return;
        _toggleProbe(server.name);
      });
    card.querySelector(`#btn-mcp-remove-${CSS.escape(server.name)}`)
      ?.addEventListener("click", () => _remove(server.name));
    card.querySelector(`#toggle-mcp-${CSS.escape(server.name)}`)
      ?.addEventListener("change", (ev) => _toggle(server.name, ev.target.checked));

    if (isExpanded && !server.disabled) _renderTools(server.name);

    return card;
  }

  async function _toggleProbe(name) {
    if (_expanded.has(name)) {
      _expanded.delete(name);
    } else {
      _expanded.add(name);
    }
    _render();
    if (_expanded.has(name)) await _renderTools(name);
  }

  async function _renderTools(name) {
    const region = document.getElementById(`mcp-tools-${name}`);
    if (!region) return;

    if (_toolsCache.has(name)) {
      region.innerHTML = _toolsHtml(_toolsCache.get(name));
      return;
    }

    region.innerHTML = `<div class="mcp-tools-loading">${I18n.t("mcp.toolsLoading")}</div>`;

    try {
      const res = await fetch(`/api/mcp/${encodeURIComponent(name)}/probe`, { method: "POST" });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        region.innerHTML = `<div class="mcp-tools-error">${I18n.t("mcp.toolsLoadError", { msg: _esc(data.error || "unknown") })}</div>`;
        return;
      }
      _toolsCache.set(name, data.tools || []);
      region.innerHTML = _toolsHtml(data.tools || []);
    } catch (e) {
      region.innerHTML = `<div class="mcp-tools-error">${I18n.t("mcp.toolsLoadError", { msg: _esc(e.message) })}</div>`;
    }
  }

  function _toolsHtml(tools) {
    if (!tools || tools.length === 0) {
      return `<div class="mcp-tools-empty">${I18n.t("mcp.toolsNone")}</div>`;
    }
    const items = tools.map(t => `
      <li class="mcp-tool-item">
        <code class="mcp-tool-name">${_esc(t.name)}</code>
        ${t.description ? `<span class="mcp-tool-desc">${_esc(t.description)}</span>` : ""}
      </li>
    `).join("");
    return `
      <div class="mcp-tools-header">${I18n.t("mcp.toolsHeader")} (${tools.length})</div>
      <ul class="mcp-tool-list">${items}</ul>
    `;
  }

  function _askClackyAdd() {
    _sendToAgent("/mcp-manager add", "MCP Setup");
  }

  function _askClackyFix(name) {
    _sendToAgent(`/mcp-manager reconfigure ${name}`, `MCP Fix — ${name}`);
  }

  async function _sendToAgent(command, sessionName) {
    try {
      const maxN = Sessions.all.reduce((max, s) => {
        const m = s.name.match(/^Session (\d+)$/);
        return m ? Math.max(max, parseInt(m[1], 10)) : max;
      }, 0);
      const name = sessionName || ("Session " + (maxN + 1));

      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name, source: "mcp" }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "failed to create session");
      const session = data.session;
      if (!session) throw new Error("no session returned");

      Sessions.add(session);
      Sessions.renderList();
      Sessions.setPendingMessage(session.id, command);
      Sessions.select(session.id);
    } catch (e) {
      alert("Error: " + e.message);
    }
  }

  async function _toggle(name, enabled) {
    try {
      const res = await fetch(`/api/mcp/${encodeURIComponent(name)}/enabled`, {
        method:  "PATCH",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ enabled }),
      });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        alert(I18n.t("mcp.toggle.error", { msg: data.error || `HTTP ${res.status}` }));
        return;
      }
      if (!enabled) {
        _toolsCache.delete(name);
        _expanded.delete(name);
      }
      await _load();
    } catch (e) {
      alert(I18n.t("mcp.toggle.error", { msg: e.message }));
    }
  }

  async function _remove(name) {
    const msg = I18n.t("mcp.remove.confirm", { name });
    if (!window.confirm(msg)) return;

    try {
      const res = await fetch(`/api/mcp/${encodeURIComponent(name)}`, { method: "DELETE" });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        alert(I18n.t("mcp.remove.error", { msg: data.error || `HTTP ${res.status}` }));
        return;
      }
      _toolsCache.delete(name);
      _expanded.delete(name);
      await _load();
    } catch (e) {
      alert(I18n.t("mcp.remove.error", { msg: e.message }));
    }
  }

  function _esc(str) {
    return String(str || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  return {
    onPanelShow,
    init() {},
  };
})();
