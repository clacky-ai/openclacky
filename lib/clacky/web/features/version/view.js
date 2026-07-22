// ── Version · view — badge, upgrade popover, hover lifecycle ──────────────
//
// Renders the sidebar version badge and the fixed upgrade popover, driven
// entirely from VersionStore snapshots. All hover/click/popover lifecycle and
// DOM lives here; lifecycle transitions and network go through store actions.
//
// Badge states: up-to-date / has-update / is-upgrading / needs-restart /
// upgrade-done. Popover morphs as the store emits version:changed with reason.
//
// Depends on: VersionStore, I18n.
// ───────────────────────────────────────────────────────────────────────────

const VersionView = (() => {
  let _popoverOpen = false;
  let _hoverTimer  = null;
  let _autoReloaded = false;

  const $  = id => document.getElementById(id);
  const el = (tag, attrs = {}, ...children) => {
    const e = document.createElement(tag);
    Object.entries(attrs).forEach(([k, v]) => {
      if (k === "className") e.className = v;
      else if (k === "innerHTML") e.innerHTML = v;
      else e.setAttribute(k, v);
    });
    children.forEach(c => c && e.appendChild(typeof c === "string" ? document.createTextNode(c) : c));
    return e;
  };

  function S() { return Version.snapshot(); }

  // ── Badge render ───────────────────────────────────────────────────────
  function _renderBadge() {
    const s             = S();
    const badge         = $("version-badge");
    const text          = $("version-text");
    const dot           = $("version-update-dot");
    const restartDot    = $("version-restart-dot");
    const check         = $("version-done-check");
    const spinner       = $("version-spinner");
    if (!badge || !text) return;

    text.textContent = s.current ? `v${s.current}` : "";

    if (dot)        dot.style.display        = "none";
    if (restartDot) restartDot.style.display = "none";
    if (check)      check.style.display      = "none";
    if (spinner)    spinner.style.display    = "none";
    badge.className = "version-badge";

    if (s.upgrading) {
      badge.classList.add("is-upgrading");
      badge.title = I18n.t("upgrade.tooltip.upgrading");
      if (spinner) spinner.style.display = "inline-block";
    } else if (s.needsRestart) {
      badge.classList.add("needs-restart");
      badge.title = I18n.t("upgrade.tooltip.needs_restart");
      if (restartDot) restartDot.style.display = "inline-block";
    } else if (s.upgradeDone) {
      badge.classList.add("upgrade-done");
      badge.title = I18n.t("upgrade.tooltip.done");
      if (check) check.style.display = "inline-block";
    } else if (s.needsUpdate) {
      badge.classList.add("has-update");
      badge.title = I18n.t("upgrade.tooltip.new", { latest: s.latest });
      if (dot) dot.style.display = "inline-block";
    } else {
      badge.title = I18n.t("upgrade.tooltip.ok", { current: s.current });
    }

    badge.style.display = "flex";
  }

  // ── Popover ──────────────────────────────────────────────────────────
  function _getOrCreatePopover() {
    let pop = $("version-upgrade-popover");
    if (pop) return pop;
    pop = el("div", { id: "version-upgrade-popover", className: "vup" });
    document.body.appendChild(pop);
    return pop;
  }

  function _positionPopover() {
    const badge = $("version-badge");
    const pop   = $("version-upgrade-popover");
    if (!badge || !pop) return;
    const rect = badge.getBoundingClientRect();
    pop.style.left   = rect.left + "px";
    pop.style.bottom = (window.innerHeight - rect.top + 8) + "px";
    pop.style.top    = "auto";
  }

  function _renderPopoverFor(pop) {
    const s = S();
    pop.innerHTML = "";
    if (s.restartFailed)      _renderRestartFailedState(pop, s);
    else if (s.reconnecting)  _renderReconnectState(pop);
    else if (s.upgrading)     _renderProgressState(pop, s);
    else if (s.needsRestart)  _renderDoneState(pop);
    else if (s.upgradeDone)   _renderDoneState(pop);
    else if (s.needsUpdate)   _renderConfirmState(pop, s);
    else                      _renderUpToDateState(pop, s);
  }

  function _openPopover() {
    if (_popoverOpen) { _positionPopover(); return; }
    _popoverOpen = true;
    const pop = _getOrCreatePopover();
    _renderPopoverFor(pop);
    pop.style.display = "block";
    _positionPopover();
    requestAnimationFrame(() => pop.classList.add("vup--visible"));
  }

  function _closePopover() {
    const s = S();
    if (s.upgrading || s.reconnecting) return;
    const pop = $("version-upgrade-popover");
    if (!pop) return;
    pop.classList.remove("vup--visible");
    setTimeout(() => {
      pop.style.display = "none";
      _popoverOpen = false;
    }, 180);
  }

  // ── Popover states ─────────────────────────────────────────────────────

  function _renderUpToDateState(pop, s) {
    pop.innerHTML = `
      <p class="vup-up-to-date">
        <span class="vup-check-icon">✓</span>
        ${I18n.t("upgrade.tooltip.ok", { current: s.current })}
      </p>
    `;
    setTimeout(() => { if (_popoverOpen) _closePopover(); }, 2000);
  }

  function _renderConfirmState(pop, s) {
    pop.innerHTML = `
      <p class="vup-desc">${I18n.t("upgrade.desc")}</p>
      <p class="vup-versions">v${s.current} <span class="vup-arrow">→</span> v${s.latest}</p>
      <div class="vup-actions">
        <button id="vup-btn-upgrade" class="vup-btn-primary">${I18n.t("upgrade.btn.upgrade")}</button>
        <button id="vup-btn-cancel"  class="vup-btn-cancel">${I18n.t("upgrade.btn.cancel")}</button>
      </div>
    `;
    $("vup-btn-upgrade").addEventListener("click", () => Version.startUpgrade());
    $("vup-btn-cancel").addEventListener("click", _closePopover);
  }

  function _renderProgressState(pop, s) {
    pop.innerHTML = `
      <div class="vup-progress-header">
        <span class="vup-installing-dot"></span>
        <span class="vup-installing-label">${I18n.t("upgrade.installing")}</span>
      </div>
      <pre id="vup-log" class="vup-log"></pre>
    `;
    const logEl = $("vup-log");
    if (logEl && s.logLines.length) {
      logEl.textContent = s.logLines.join("\n");
      logEl.scrollTop = logEl.scrollHeight;
    }
  }

  function _renderDoneState(pop) {
    pop.innerHTML = `
      <div class="vup-done-header">
        <span class="vup-done-icon">✓</span>
        <span>${I18n.t("upgrade.done")}</span>
      </div>
      <button id="vup-btn-restart" class="vup-btn-restart">${I18n.t("upgrade.btn.restart")}</button>
    `;
    $("vup-btn-restart").addEventListener("click", () => Version.startRestart());
  }

  function _renderReconnectState(pop) {
    pop.innerHTML = `
      <div class="vup-reconnect">
        <div class="vup-reconnect-spinner"></div>
        <p class="vup-reconnect-msg">${I18n.t("upgrade.reconnecting")}</p>
      </div>
    `;
  }

  function _renderRestartFailedState(pop, s) {
    const safeCmd = String(s.cliCommand).replace(/[&<>"']/g, c => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
    const cmd = `<code class="vup-cmd">${safeCmd} server</code>`;
    pop.innerHTML = `
      <div class="vup-restart-failed">
        <p class="vup-restart-failed-title">⚠ ${I18n.t("upgrade.restart.timeout.title")}</p>
        <p class="vup-restart-failed-desc">${I18n.t("upgrade.restart.timeout.desc")}</p>
        <ul class="vup-restart-failed-options">
          <li>${I18n.t("upgrade.restart.timeout.tray")}</li>
          <li>${I18n.t("upgrade.restart.timeout.cli", { cmd })}</li>
        </ul>
        <div class="vup-actions">
          <button id="vup-btn-retry" class="vup-btn-primary">${I18n.t("upgrade.restart.timeout.retry")}</button>
        </div>
      </div>
    `;
    const retry = $("vup-btn-retry");
    if (retry) retry.addEventListener("click", () => Version.retryReconnect());
  }

  // ── Store event reaction ─────────────────────────────────────────────
  function _onChanged(s) {
    _renderBadge();

    const reason = s.reason;

    if (reason === "log") {
      const logEl = $("vup-log");
      if (logEl) {
        logEl.textContent += (logEl.textContent ? "\n" : "") + (s.line || "");
        logEl.scrollTop = logEl.scrollHeight;
      }
      return;
    }

    if (reason === "restart-start") {
      const pop = _getOrCreatePopover();
      _renderReconnectState(pop);
      if (!_popoverOpen) {
        _popoverOpen = true;
        pop.style.display = "block";
        _positionPopover();
        requestAnimationFrame(() => pop.classList.add("vup--visible"));
      }
      return;
    }

    if (reason === "reconnected") {
      _closePopover();
      if (!_autoReloaded) {
        _autoReloaded = true;
        // Delay reload to ensure the server is fully ready after restart.
        // /api/version responding OK does not guarantee the full server stack
        // (static assets, routes) is ready; a short extra wait avoids a blank
        // page caused by the browser hitting a not-yet-ready server.
        setTimeout(() => window.location.reload(), 3000);
      }
      return;
    }

    const pop = $("version-upgrade-popover");
    if (!pop || !_popoverOpen) return;

    if (reason === "upgrade-complete") {
      if (s.success) _renderDoneState(pop);
      else pop.innerHTML = `<p class="vup-error">${I18n.t("upgrade.failed")}</p>`;
      return;
    }
    if (reason === "upgrade-start")   { _renderProgressState(pop, s); return; }
    if (reason === "restart-failed")  { _renderRestartFailedState(pop, s); return; }
    if (reason === "retry-reconnect") { _renderReconnectState(pop); return; }
  }

  // ── Init ───────────────────────────────────────────────────────────────
  function init() {
    const badge = $("version-badge");
    if (badge) {
      badge.addEventListener("click", e => {
        e.stopPropagation();
        if (S().reconnecting) { if (!_popoverOpen) _openPopover(); return; }
      });

      badge.addEventListener("mouseenter", () => {
        if (!S().current) return;
        clearTimeout(_hoverTimer);
        _openPopover();
      });

      badge.addEventListener("mouseleave", () => {
        _hoverTimer = setTimeout(() => {
          const pop = $("version-upgrade-popover");
          if (pop && pop.matches(":hover")) return;
          _closePopover();
        }, 200);
      });
    }

    document.addEventListener("mouseover", e => {
      const pop = $("version-upgrade-popover");
      if (pop && e.target.closest("#version-upgrade-popover")) {
        clearTimeout(_hoverTimer);
      }
    });
    document.addEventListener("mouseout", e => {
      const pop = $("version-upgrade-popover");
      if (!pop) return;
      if (e.target.closest("#version-upgrade-popover") && !e.relatedTarget?.closest("#version-upgrade-popover") && !e.relatedTarget?.closest("#version-badge")) {
        _hoverTimer = setTimeout(() => _closePopover(), 200);
      }
    });

    document.addEventListener("click", e => {
      if (!e.target.closest("#version-badge") && !e.target.closest("#version-upgrade-popover")) {
        const s = S();
        if (_popoverOpen && !s.upgrading && !s.reconnecting) _closePopover();
      }
    });

    window.addEventListener("resize", () => {
      if (_popoverOpen) _positionPopover();
    });

    Version.bootWs();
    Version.checkVersion();
  }

  function _boot() {
    Version.on("version:changed", _onChanged);
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", init);
    } else {
      init();
    }
  }

  return { init: _boot };
})();

VersionView.init();
