// ── Extensions · view — rendering, DOM wiring for the extension marketplace ─
//
// The view owns everything DOM: the tab strip, search bar, sort control, the
// two-column row lists, loading/empty states and the detail panel. It reads
// data only through ExtensionsStore.state and reacts to store events via
// Extensions.on(...). It never fetches directly — it calls store actions.
//
// The list is a two-column grid of compact rows (icon · name · one-line
// description · action). Rows are grouped by publisher: official (builtin),
// user (marketplace), or brand (a branded install's private catalog). The
// action slot is a "+" for anything not switched on yet (install, or enable for
// a disabled official extension), a "…" menu for installed ones, and a spinner
// while an install/enable round-trip is in flight.
//
// Depends on: ExtensionsStore (store.js), I18n/Router, global $ / escapeHtml.
// ───────────────────────────────────────────────────────────────────────────

const ExtensionsView = (() => {
  let _domWired    = false;
  let _searchTimer = null;
  let _index       = {};   // extId => extension object currently rendered
  let _menuEl      = null; // shared floating "…" row menu (see _toggleMenu)
  let _menuBtn     = null; // row button the open menu is anchored to
  let _menuExt     = null; // extension the open menu acts on

  const MORE_SVG = '<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><circle cx="5" cy="12" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="19" cy="12" r="1.7"/></svg>';

  function _renderLoading() {
    const container = $("extensions-list");
    if (!container) return;
    container.innerHTML = `
      <div class="extensions-group">
        <div class="extensions-rows">${Array.from({ length: 4 }).map(() => `
          <div class="extension-row extension-row-skeleton">
            <span class="skel" style="height:2.25rem;width:2.25rem;border-radius:10px;flex-shrink:0"></span>
            <div class="extension-row-text">
              <span class="skel skel-title"></span>
              <span class="skel skel-subtitle"></span>
            </div>
          </div>`).join("")}</div>
      </div>`;
  }

  function _renderEmpty() {
    const container = $("extensions-list");
    if (!container) return;
    const key = ExtensionsStore.state.query ? "extensions.noResults" : "extensions.empty";
    container.innerHTML = `<div class="extensions-empty">${escapeHtml(I18n.t(key))}</div>`;
  }

  // Group the active tab's data into sections. The all tab shows the two
  // publishers side by side, the brand tab swaps the public catalog for the
  // brand-private one, and the installed tab uses the same two headings, split
  // by the layer each extension actually lives in. A disabled extension is not
  // "installed" as far as the user is concerned: it leaves this tab and is
  // switched back on from the all tab's official group, which lists every
  // builtin extension.
  function _groups(st) {
    if (st.tab === "installed") {
      const live = st.installed.filter((e) => e.disabled !== true);
      return [
        { title: I18n.t("extensions.group.official"), items: live.filter((e) => e.layer === "builtin") },
        { title: I18n.t("extensions.group.user"),     items: live.filter((e) => e.layer !== "builtin") },
      ];
    }
    if (st.tab === "brand") {
      return [
        { title: I18n.t("extensions.group.official"), items: st.official },
        { title: I18n.t("extensions.group.brand"),    items: st.catalog },
      ];
    }
    return [
      { title: I18n.t("extensions.group.official"), items: st.official },
      { title: I18n.t("extensions.group.user"),     items: st.catalog },
    ];
  }

  function _renderList() {
    _closeMenu();
    const container = $("extensions-list");
    if (!container) return;

    const st = ExtensionsStore.state;
    if (st.loading) { _renderLoading(); return; }

    const groups = _groups(st).filter((g) => g.items.length > 0);
    if (groups.length === 0) { _renderEmpty(); return; }

    container.innerHTML = "";
    groups.forEach((g) => container.appendChild(_renderGroup(g)));
    _renderLoadMore(container, st);
    _applyWarning(st.error);
  }

  function _renderGroup(group) {
    const wrap = document.createElement("div");
    wrap.className = "extensions-group";
    if (group.title) {
      const title = document.createElement("div");
      title.className = "extensions-group-title";
      title.textContent = group.title;
      wrap.appendChild(title);
    }
    const grid = document.createElement("div");
    grid.className = "extensions-rows";
    group.items.forEach((ext) => grid.appendChild(_renderRow(ext)));
    wrap.appendChild(grid);
    return wrap;
  }

  function _renderRow(ext) {
    const st = ExtensionsStore.state;
    const id = ext.id != null ? String(ext.id) : (ext.name || "");
    _index[id] = ext;

    const currentLang = I18n.lang();
    const name = (currentLang === "zh" && ext.display_name_zh) ? ext.display_name_zh : (ext.display_name || ext.name);
    const description = (currentLang === "zh" && ext.description_zh)
      ? ext.description_zh
      : (ext.description || "");
    const unlistedHtml = (ext.unlisted && ext.installed)
      ? `<span class="extension-unlisted">${escapeHtml(I18n.t("extensions.unlisted"))}</span>` : "";

    const row = document.createElement("div");
    row.className = "extension-row";
    row.dataset.extId     = id;
    row.dataset.extOrigin = ext.origin || "";
    row.innerHTML = `
      <span class="extension-row-icon">${_iconHtml(ext)}</span>
      <div class="extension-row-text">
        <div class="extension-row-name">
          <span class="extension-name">${escapeHtml(name)}</span>
          ${unlistedHtml}
        </div>
        ${description ? `<div class="extension-row-desc">${escapeHtml(description)}</div>` : ""}
      </div>
      <div class="extension-row-action">${_rowAction(ext, id, st)}</div>`;

    // Official (builtin) rows have no marketplace detail to open; anything the
    // marketplace knows about gets a clickable row that drills into details.
    if (ext.layer !== "builtin") row.classList.add("extension-row-clickable");

    return row;
  }

  // Whether the extensions panel is the view the user is looking at.
  function _panelVisible() {
    const panel = $("extensions-panel");
    return !!(panel && panel.offsetParent !== null);
  }

  // Repaint one row's action slot — progress ticks arrive once a second and
  // shouldn't cost a full list re-render (or drop the row under the pointer).
  function _updateRowJob(id) {
    const container = $("extensions-list");
    if (!container) return;
    const key = String(id).replace(/"/g, '\\"');
    const row = container.querySelector(`.extension-row[data-ext-id="${key}"]`);
    const slot = row && row.querySelector(".extension-row-action");
    const ext = _index[String(id)];
    if (!slot || !ext) return;
    if (_menuBtn && _menuBtn.getAttribute("data-ext-more") === String(id)) _closeMenu();
    slot.innerHTML = _rowAction(ext, String(id), ExtensionsStore.state);
  }

  function _iconHtml(ext) {
    if (ext.icon_url) {
      return `<img class="extension-row-img" src="${escapeHtml(ext.icon_url)}" alt="" loading="lazy" />`;
    }
    if (ext.emoji) return `<span class="extension-emoji">${escapeHtml(ext.emoji)}</span>`;
    return _defaultIcon(ext.name || ext.display_name);
  }

  // The right-hand slot of a row: progress while a job runs, a "…" menu for
  // anything already on disk, otherwise "+" (install / enable).
  function _rowAction(ext, id, st) {
    const job = st.jobFor(id);
    if (job && job.stage !== "error") {
      return `<span class="ext-row-busy"><span class="ext-spinner"></span>${escapeHtml(_actionLabel(job))}</span>`;
    }

    const failedHtml = (job && job.stage === "error")
      ? `<span class="ext-row-error">${escapeHtml(I18n.t("extensions.action.installFailed"))}</span>` : "";

    if (ext.installed) {
      // A builtin extension that is switched off reads as "not on yet", so it
      // keeps the same "+" (enable) affordance as anything waiting to be
      // installed rather than the "…" menu.
      if (ext.layer === "builtin" && ext.disabled === true) {
        return `${failedHtml}<button type="button" class="ext-row-add" data-ext-row-enable="${escapeHtml(id)}" title="${escapeHtml(I18n.t("extensions.action.enable"))}">${_plusSvg()}</button>`;
      }
      return `${failedHtml}${_rowMore(id)}`;
    }

    return `${failedHtml}<button type="button" class="ext-row-add" data-ext-row-install="${escapeHtml(id)}" title="${escapeHtml(I18n.t("extensions.action.install"))}">${_plusSvg()}</button>`;
  }

  function _rowMore(id) {
    return `<button type="button" class="ext-row-more" data-ext-more="${escapeHtml(id)}"
      title="${escapeHtml(I18n.t("extensions.action.more"))}" aria-haspopup="menu" aria-expanded="false">${MORE_SVG}</button>`;
  }

  function _plusSvg() {
    return '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M12 5.5v13M5.5 12h13" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>';
  }

  // ── Row "…" menu ──────────────────────────────────────────────────────────
  // One menu is shared by every row: rows repaint in place on each progress
  // tick, so a menu nested inside a row would be torn down mid-interaction.
  //
  // Official (builtin) extensions have no marketplace detail of their own — the
  // store resolves their slug against an unrelated marketplace entry — and
  // can't be removed. They only reach the menu once they're switched on, where
  // the one action left is switching them back off.
  function _menuItemsFor(ext) {
    if (ext.layer === "builtin") return ["disable"];
    return ext.removable === false ? ["manage"] : ["manage", "uninstall"];
  }

  const MENU_ICONS = {
    manage: '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="8" cy="8" r="6.2" stroke="currentColor" stroke-width="1.3"/><path d="M8 7.3v3.3" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="5.1" r="0.9" fill="currentColor"/></svg>',
    uninstall: '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M3.1 4.6h9.8" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/><path d="M6.3 4.6V3.4c0-.5.4-.9.9-.9h1.6c.5 0 .9.4.9.9v1.2" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/><path d="M4.6 4.6l.6 8c.05.7.63 1.25 1.33 1.25h2.94c.7 0 1.28-.55 1.33-1.25l.6-8" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
    disable: '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="8" cy="8" r="6.1" stroke="currentColor" stroke-width="1.3"/><path d="M4.3 11.7L11.7 4.3" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
  };

  function _ensureMenu() {
    if (_menuEl) return _menuEl;
    _menuEl = document.createElement("div");
    _menuEl.className = "ext-row-menu";
    _menuEl.setAttribute("role", "menu");
    _menuEl.hidden = true;
    _menuEl.addEventListener("click", _onMenuClick);
    document.body.appendChild(_menuEl);
    return _menuEl;
  }

  // Local operations (uninstall) address an extension by the directory it was
  // installed under. On a catalog row `id` is the store's own row id, whose
  // uninstall round-trip would answer "Not installed".
  function _slugOf(ext, id) {
    return String((ext && (ext.slug || ext.name)) || id);
  }

  function _menuHtml(ext, id) {
    const keys = {
      manage:    "extensions.action.manage",
      uninstall: "extensions.action.remove",
      enable:    "extensions.action.enable",
      disable:   "extensions.action.disable",
    };
    const slug = _slugOf(ext, id);
    return _menuItemsFor(ext).map((kind) => {
      const danger = kind === "uninstall" ? " ext-row-menu-danger" : "";
      return `<button type="button" role="menuitem" class="ext-row-menu-item${danger}" data-ext-menu-item="${kind}" data-ext-menu-id="${escapeHtml(id)}" data-ext-menu-slug="${escapeHtml(slug)}">${MENU_ICONS[kind]}<span>${escapeHtml(I18n.t(keys[kind]))}</span></button>`;
    }).join("");
  }

  function _toggleMenu(btn, ext, id) {
    if (_menuBtn === btn && _menuEl && !_menuEl.hidden) { _closeMenu(); return; }

    const el = _ensureMenu();
    _menuBtn = btn;
    _menuExt = ext;
    el.innerHTML = _menuHtml(ext, id);
    el.hidden = false;
    btn.setAttribute("aria-expanded", "true");

    const rect = btn.getBoundingClientRect();
    const w    = el.offsetWidth;
    const h    = el.offsetHeight;
    let left = Math.min(rect.right - w, window.innerWidth - w - 8);
    let top  = rect.bottom + 4;
    if (top + h > window.innerHeight - 8) top = rect.top - h - 4;
    el.style.left = Math.max(8, left) + "px";
    el.style.top  = Math.max(8, top) + "px";
  }

  function _closeMenu() {
    if (!_menuEl || _menuEl.hidden) return;
    _menuEl.hidden = true;
    if (_menuBtn) _menuBtn.setAttribute("aria-expanded", "false");
    _menuBtn = null;
    _menuExt = null;
  }

  function _onMenuClick(e) {
    const item = e.target.closest("[data-ext-menu-item]");
    if (!item) return;
    const kind = item.getAttribute("data-ext-menu-item");
    const id   = item.getAttribute("data-ext-menu-id");
    const slug = item.getAttribute("data-ext-menu-slug") || id;
    const ext  = _menuExt;
    _closeMenu();

    if (kind === "manage")         _openDetail(id, ext && ext.origin);
    else if (kind === "uninstall") _confirmUninstall(slug);
    else if (kind === "disable")   Extensions.setEnabled(id, false);
  }

  // The menu floats outside the row, so dismissing it needs document-level
  // listeners rather than the list's own delegated handler.
  function _wireMenuDismiss() {
    document.addEventListener("click", (e) => {
      if (!_menuEl || _menuEl.hidden) return;
      if (!e.target.closest(".ext-row-more") && !e.target.closest(".ext-row-menu")) _closeMenu();
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") _closeMenu();
    });
    window.addEventListener("resize", _closeMenu);
    window.addEventListener("scroll", _closeMenu, true);
  }

  async function _confirmUninstall(id) {
    const { ok, checked } = await Modal.confirmWithCheckbox(
      I18n.t("extensions.action.removeConfirm"),
      I18n.t("extensions.action.removePurgeData")
    );
    if (!ok) return;
    const res = await Extensions.uninstall(id, checked);
    if (res && res.ok === false) {
      Modal.toast(I18n.t("extensions.removeFailed") + ": " + (res.error || ""), "error");
    }
  }

  function _renderLoadMore(container, st) {
    if (st.tab !== "all" || !st.hasMore) return;

    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "extensions-load-more";
    btn.textContent = st.loadingMore ? I18n.t("extensions.loadingMore") : I18n.t("extensions.loadMore");
    btn.disabled = st.loadingMore;
    btn.addEventListener("click", () => Extensions.loadMoreUser());
    container.appendChild(btn);
  }

  function _renderLoadingMore() {
    const container = $("extensions-list");
    const btn = container && container.querySelector(".extensions-load-more");
    if (btn) {
      btn.disabled = true;
      btn.textContent = I18n.t("extensions.loadingMore");
    }
  }

  function _applyWarning(warning) {
    const banner = $("extensions-warning");
    if (!banner) return;
    if (warning) {
      banner.textContent   = warning;
      banner.style.display = "";
    } else {
      banner.style.display = "none";
    }
  }

  function _formatUnits(units) {
    if (!units || typeof units !== "object") return "";
    const parts = [];
    Object.keys(units).forEach((type) => {
      const n = parseInt(units[type], 10);
      if (!n) return;
      const key = "extensions.unit." + type + (n > 1 ? "s" : "");
      const label = I18n.t(key);
      const word = (label && label !== key) ? label : type;
      parts.push(`${n} ${word}`);
    });
    return parts.join(" · ");
  }

  function _defaultIcon(name) {
    const letter = (name || "?")[0].toUpperCase();
    const colors = [
      ["#6366f1","#818cf8"], ["#8b5cf6","#a78bfa"], ["#ec4899","#f472b6"],
      ["#f59e0b","#fbbf24"], ["#10b981","#34d399"], ["#3b82f6","#60a5fa"],
      ["#ef4444","#f87171"], ["#14b8a6","#2dd4bf"],
    ];
    const idx = (name || "").charCodeAt(0) % colors.length;
    const [c1, c2] = colors[idx];
    const gid = `eg-${idx}-${Math.random().toString(36).slice(2,7)}`;
    return `<span class="extension-emoji"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" class="extension-default-icon"><defs><linearGradient id="${gid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="${c1}"/><stop offset="100%" stop-color="${c2}"/></linearGradient></defs><rect width="32" height="32" rx="8" fill="url(#${gid})"/><text x="16" y="22" text-anchor="middle" font-family="system-ui,sans-serif" font-size="16" font-weight="700" fill="white">${letter}</text></svg></span>`;
  }

  // Returns a human-readable label for a given row/detail job state.
  function _actionLabel(job) {
    if (!job) return I18n.t("extensions.action.install");
    switch (job.stage) {
      case "downloading": {
        // Suppress "0%" — it's shown for a very brief instant right after the
        // download starts (or never, for fast installs) and just looks like a stall.
        const pct = (job.progress != null && job.progress > 0) ? ` ${job.progress}%` : "...";
        return I18n.t("extensions.action.downloading") + pct;
      }
      case "extracting": return I18n.t("extensions.action.extracting") + "...";
      case "verifying":  return I18n.t("extensions.action.verifying") + "...";
      case "enabling":   return I18n.t("extensions.action.enabling") + "...";
      case "disabling":  return I18n.t("extensions.action.disabling") + "...";
      default:           return I18n.t("extensions.action.installing");
    }
  }

  // Label for the detail panel's install/update button.
  function _installJobLabel(job) {
    return _actionLabel(job);
  }

  function _renderDetail() {
    const panel = $("extensions-detail");
    const body  = $("extensions-body");
    if (!panel) return;

    const st = ExtensionsStore.state;
    const open = st.detail || st.detailLoading || st.detailError;

    if (!open) {
      panel.style.display = "none";
      panel.innerHTML = "";
      if (body) body.style.display = "";
      return;
    }

    if (body) body.style.display = "none";
    panel.style.display = "";

    if (st.detailLoading) {
      panel.innerHTML = _detailShell(`
        <div class="extension-detail-loading">
          <span class="skel skel-title"></span>
          <span class="skel skel-subtitle"></span>
        </div>`);
      _wireDetail();
      return;
    }

    if (st.detailError) {
      console.warn("[Extensions] detail error, navigating back:", st.detailError);
      _backToList();
      return;
    }

    panel.innerHTML = _detailShell(_detailContent(st.detail));
    _wireDetail();

    // If an install/update job is in-progress, update the button text to reflect current stage.
    // Note: both the "install" and "update" buttons drive the same job/poll flow, so we must
    // look for whichever one is actually present in the freshly-rendered DOM.
    const job = st.installJob;
    const actionBtn = document.querySelector("[data-ext-install], [data-ext-update]");
    if (job && job.stage !== "error") {
      if (actionBtn) {
        actionBtn.disabled = true;
        actionBtn.textContent = _installJobLabel(job);
      }
    }

    // If the last install/update attempt failed, show an inline error banner
    if (st.installError) {
      if (actionBtn) {
        actionBtn.disabled = false;
        // Insert error message right after the button if not already there
        let errEl = panel.querySelector(".extension-install-error");
        if (!errEl) {
          errEl = document.createElement("p");
          errEl.className = "extension-install-error";
          actionBtn.insertAdjacentElement("afterend", errEl);
        }
        errEl.textContent = st.installError;
      }
    }
  }

  function _detailShell(inner) {
    return `
      <div class="extension-detail-head">
        <button type="button" class="extension-detail-back" id="extension-detail-back">
          <svg width="14" height="14" viewBox="0 0 14 14" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M9 2L4 7L9 12" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"/></svg>
          ${escapeHtml(I18n.t("extensions.detail.back"))}
        </button>
      </div>
      ${inner}`;
  }

  function _wireDetail() {
    const back = $("extension-detail-back");
    if (back) back.addEventListener("click", () => _backToList());

    const toggle = document.querySelector("[data-ext-toggle]");
    if (toggle) {
      toggle.addEventListener("click", () => {
        const id = toggle.getAttribute("data-ext-toggle");
        const currentlyDisabled = toggle.getAttribute("data-ext-enabled") === "1";
        Extensions.setEnabled(id, currentlyDisabled);
      });
    }

    const remove = document.querySelector("[data-ext-remove]");
    if (remove) {
      remove.addEventListener("click", () => _confirmUninstall(remove.getAttribute("data-ext-remove")));
    }

    const installBtn = document.querySelector("[data-ext-install]");
    if (installBtn) {
      installBtn.addEventListener("click", async () => {
        const id = installBtn.getAttribute("data-ext-install");
        const ext = ExtensionsStore.state.detail;
        if (ext && !ext.verified && !(typeof Brand !== "undefined" && Brand.branded)) {
          const confirmed = await Modal.confirm(I18n.t("extensions.unverifiedInstallWarning"));
          if (!confirmed) return;
        }
        installBtn.disabled = true;
        installBtn.textContent = _installJobLabel({ stage: "downloading", progress: null });
        Extensions.install(id);
      });
    }

    const updateBtn = document.querySelector("[data-ext-update]");
    if (updateBtn) {
      updateBtn.addEventListener("click", () => {
        const id = updateBtn.getAttribute("data-ext-update");
        updateBtn.disabled = true;
        updateBtn.textContent = _installJobLabel({ stage: "downloading", progress: null });
        Extensions.update(id);
      });
    }
  }

  function _backToList() {
    const router = window.Clacky && window.Clacky.Router;
    if (router) router.navigate("extensions");
    else Extensions.closeDetail();
  }

  function _detailContent(ext) {
    const currentLang = I18n.lang();
    const name = (currentLang === "zh" && ext.display_name_zh) ? ext.display_name_zh : (ext.display_name || ext.name);
    const description = (currentLang === "zh" && ext.description_zh)
      ? ext.description_zh
      : ext.description || "";
    const detailEmojiHtml = ext.emoji
      ? `<span class="extension-emoji extension-emoji-lg">${escapeHtml(ext.emoji)}</span>`
      : _defaultIcon(ext.name, "extension-emoji-lg");

    const canUpdate = ext.installed && ext.installed_version && ext.version && ext.installed_version !== ext.version;
    const versionHtml = ext.version
      ? `<span class="extension-version">v${escapeHtml(String(ext.version))}</span>` : "";
    const installedLabel = canUpdate && ext.installed_version
      ? `${I18n.t("extensions.installed")} v${escapeHtml(String(ext.installed_version))}`
      : I18n.t("extensions.installed");
    const installedHtml = ext.installed
      ? `<span class="extension-installed">${installedLabel}</span>` : "";
    const unlistedHtml = ext.unlisted
      ? `<span class="extension-unlisted">${escapeHtml(I18n.t("extensions.unlisted"))}</span>` : "";
    const verifiedHtml = ext.verified
      ? `<span class="extension-verified">${escapeHtml(I18n.t("extensions.verified"))}</span>` : "";
    const unverifiedBannerHtml = (!ext.verified && !ext.installed && !(typeof Brand !== "undefined" && Brand.branded))
      ? `<div class="extension-unverified-banner"><svg class="extension-unverified-icon" width="14" height="14" viewBox="0 0 14 14" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="7" cy="7" r="6.25" stroke="currentColor" stroke-width="1.2"/><path d="M7 4V7.5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/><circle cx="7" cy="10" r="0.7" fill="currentColor"/></svg>${escapeHtml(I18n.t("extensions.unverifiedBanner"))}</div>` : "";
    const unitsText = _formatUnits(ext.units);
    const unitsHtml = unitsText
      ? `<span class="extension-units">${escapeHtml(unitsText)}</span>` : "";
    const homepageHtml = ext.homepage
      ? `<a class="extension-homepage" href="${escapeHtml(ext.homepage)}" target="_blank" rel="noopener noreferrer">${I18n.t("extensions.homepage")}</a>`
      : "";
    const authorHtml = ext.author
      ? `<span class="extension-author">${escapeHtml(I18n.t("extensions.by"))}${escapeHtml(ext.author)}</span>` : "";
    const installsHtml = ext.download_count > 0
      ? `<span class="extension-installs">${escapeHtml(String(ext.download_count))} ${escapeHtml(I18n.t("extensions.installs"))}</span>` : "";

    return `
      <div class="extension-detail-hero">
        ${detailEmojiHtml}
        <div class="extension-detail-heading">
          <div class="extension-title">
            <span class="extension-name extension-name-lg">${escapeHtml(name)}</span>
            ${versionHtml}
            ${installedHtml}
            ${unlistedHtml}
            ${verifiedHtml}
            ${unitsHtml}
            ${authorHtml}
            ${installsHtml}
          </div>
          ${description ? `<div class="extension-desc extension-desc-detail">${escapeHtml(description)}</div>` : ""}
          ${homepageHtml ? `<div class="extension-meta">${homepageHtml}</div>` : ""}
          ${unverifiedBannerHtml}
          ${_renderActions(ext)}
        </div>
      </div>
      ${_renderReadme(ext.readme)}
      ${_renderVersions(ext.versions)}`;
  }

  // Renders Markdown readme content. Uses marked.js if available, falls back to plain text.
  function _renderReadme(readme) {
    if (!readme || !readme.trim()) return "";
    const html = typeof marked !== "undefined"
      ? marked.parse(readme, { breaks: true, gfm: true })
      : `<pre style="white-space:pre-wrap">${escapeHtml(readme)}</pre>`;
    return `
      <div class="extension-detail-block extension-readme">
        <h3 class="extension-detail-block-title">${escapeHtml(I18n.t("extensions.detail.readme"))}</h3>
        <div class="extension-readme-body">${html}</div>
      </div>`;
  }

  // Manage buttons for a locally installed extension: enable/disable toggle
  // (always available when installed) plus remove (installed layer only).
  function _renderActions(ext) {
    const id = ext.id != null ? String(ext.id) : (ext.name || ext.slug || "");
    if (!ext.installed) {
      // Show install button for both marketplace and brand-private (origin=self) extensions,
      // as long as a download_url is available.
      if (ext.download_url) {
        return `
      <div class="extension-detail-actions">
        <button type="button" class="extension-action extension-action-install" data-ext-install="${escapeHtml(id)}">${escapeHtml(I18n.t("extensions.action.install"))}</button>
      </div>`;
      }
      return "";
    }
    const slug = ext.slug || id;
    const toggleKey = ext.disabled ? "extensions.action.enable" : "extensions.action.disable";
    const toggleCls = ext.disabled ? "extension-action-enable" : "extension-action-disable";
    const disabledBadge = ext.disabled
      ? `<span class="extension-disabled">${escapeHtml(I18n.t("extensions.disabled"))}</span>` : "";
    const removeBtn = ext.removable
      ? `<button type="button" class="extension-action extension-action-remove" data-ext-remove="${escapeHtml(slug)}">${escapeHtml(I18n.t("extensions.action.remove"))}</button>`
      : "";
    const canUpdate = ext.installed_version && ext.version && ext.installed_version !== ext.version && ext.download_url;
    const updateBtn = canUpdate
      ? `<button type="button" class="extension-action extension-action-update" data-ext-update="${escapeHtml(id)}">${escapeHtml(I18n.t("extensions.action.update"))}</button>`
      : "";
    return `
      <div class="extension-detail-actions">
        ${disabledBadge}
        ${updateBtn}
        <button type="button" class="extension-action ${toggleCls}" data-ext-toggle="${escapeHtml(slug)}" data-ext-enabled="${ext.disabled ? "1" : "0"}">${escapeHtml(I18n.t(toggleKey))}</button>
        ${removeBtn}
      </div>`;
  }

  function _sectionHeading(type) {
    const key = "extensions.section." + type;
    const label = I18n.t(key);
    return (label && label !== key) ? label : type;
  }

  function _renderContributes(contributes) {
    if (!contributes || typeof contributes !== "object") return "";
    const currentLang = I18n.lang();
    const sections = [];

    Object.keys(contributes).forEach((type) => {
      const items = contributes[type];
      if (!Array.isArray(items) || items.length === 0) return;
      const singular = type.replace(/s$/, "");
      const heading = _sectionHeading(type);
      const rows = items.map((it) => {
        const isStr = typeof it === "string";
        const title = isStr ? it
          : ((currentLang === "zh" && it.title_zh) ? it.title_zh
            : (it.title || it.name || it.id || singular));
        const desc = isStr ? ""
          : ((currentLang === "zh" && it.description_zh) ? it.description_zh
            : (it.description || ""));
        return `
          <li class="extension-contrib-item">
            <span class="extension-contrib-title">${escapeHtml(String(title))}</span>
            ${desc ? `<span class="extension-contrib-desc">${escapeHtml(String(desc))}</span>` : ""}
          </li>`;
      }).join("");
      sections.push(`
        <div class="extension-detail-section">
          <h4 class="extension-detail-section-title">${escapeHtml(heading)}</h4>
          <ul class="extension-contrib-list">${rows}</ul>
        </div>`);
    });

    if (sections.length === 0) return "";
    return `
      <div class="extension-detail-block">
        <h3 class="extension-detail-block-title">${escapeHtml(I18n.t("extensions.detail.contributes"))}</h3>
        ${sections.join("")}
      </div>`;
  }

  function _renderVersions(versions) {
    if (!Array.isArray(versions) || versions.length === 0) return "";
    const rows = versions.map((v) => {
      const date = v.published_at ? String(v.published_at).slice(0, 10) : "";
      return `
        <li class="extension-version-item">
          <div class="extension-version-row">
            <span class="extension-version">v${escapeHtml(String(v.version || ""))}</span>
            ${date ? `<span class="extension-version-separator">-</span><span class="extension-version-date">${escapeHtml(date)}</span>` : ""}
          </div>
          ${v.release_notes ? `<div class="extension-version-notes">${typeof marked !== "undefined" ? marked.parse(String(v.release_notes).replace(/^#{1,3}[^\n]*\n?/, ""), { breaks: true, gfm: true }) : escapeHtml(String(v.release_notes))}</div>` : ""}
        </li>`;
    }).join("");
    return `
      <div class="extension-detail-block">
        <h3 class="extension-detail-block-title">${escapeHtml(I18n.t("extensions.detail.versions"))}</h3>
        <ul class="extension-version-list">${rows}</ul>
      </div>`;
  }

  // Show/hide the brand tab based on brand status from the store. A branded
  // install browses the brand-private catalog instead of the public one.
  function _brandTabVisibility(branded) {
    const brandTab = $("tab-extensions-brand");
    const allTab   = $("tab-extensions-all");
    if (brandTab) brandTab.style.display = branded ? "" : "none";
    if (allTab)   allTab.style.display   = branded ? "none" : "";
  }

  async function _applyBrandTab() {
    try {
      const data = await Extensions.fetchBrandStatus();
      _brandTabVisibility(!!data.branded);
    } catch (_e) {
      // On error, keep tabs as-is.
    }
  }

  function _setActiveTab(tab) {
    const btn = document.querySelector(`.extensions-filter-tab[data-filter="${tab}"]`);
    if (!btn || btn.style.display === "none") {
      const visible = Array.from(document.querySelectorAll(".extensions-filter-tab"))
        .find((b) => b.style.display !== "none");
      tab = visible ? visible.dataset.filter : "all";
    }
    document.querySelectorAll(".extensions-filter-tab").forEach((b) => {
      b.classList.toggle("extensions-filter-tab-active", b.dataset.filter === tab);
    });
    const sortEl = $("extensions-sort");
    if (sortEl) sortEl.style.display = (tab === "installed") ? "none" : "";
    Extensions.setTab(tab);
  }

  function _openDetail(extId, extOrigin) {
    const router = window.Clacky && window.Clacky.Router;
    const isBrand = extOrigin === "self" || ExtensionsStore.state.tab === "brand";
    const source  = isBrand ? "brand" : null;
    if (router) router.navigate("extensions", { detailId: extId, source });
    else Extensions.loadDetail(extId, source);
  }

  function _wireDom() {
    if (_domWired) return;

    const input = $("extensions-search-input");
    if (input) {
      input.placeholder = I18n.t("extensions.searchPlaceholder");
      input.addEventListener("input", () => {
        clearTimeout(_searchTimer);
        _searchTimer = setTimeout(() => Extensions.setQuery(input.value), 300);
      });
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); clearTimeout(_searchTimer); Extensions.setQuery(input.value); }
      });
    }

    const sortWrap = $("extensions-sort");
    if (sortWrap && window.CustomSelect) {
      const sortDropdown = sortWrap.querySelector(".custom-select-dropdown");
      if (!sortDropdown.__customSelect) {
        window.CustomSelect.init({
          trigger: sortWrap.querySelector(".custom-select-trigger"),
          dropdown: sortDropdown,
          onSelect: (value) => Extensions.setSort(value)
        });
      }
      sortDropdown.__customSelect.setValue(ExtensionsStore.state.sort);
    }

    document.querySelectorAll(".extensions-filter-tab").forEach((btn) => {
      btn.addEventListener("click", () => _setActiveTab(btn.dataset.filter));
    });

    // Subscribe to brand status changes to show/hide the brand tab.
    if (window.Skills && Skills.on) {
      Skills.on("brandStatus:changed", (p) => _brandTabVisibility(!!p.branded));
    }

    const list = $("extensions-list");
    if (list) {
      list.addEventListener("click", (e) => {
        const install = e.target.closest("[data-ext-row-install]");
        if (install) {
          const id = install.dataset.extRowInstall;
          Extensions.install(id, _index[id]);
          return;
        }
        const enable = e.target.closest("[data-ext-row-enable]");
        if (enable) {
          Extensions.setEnabled(enable.dataset.extRowEnable, true);
          return;
        }
        const more = e.target.closest("[data-ext-more]");
        if (more) {
          const id  = more.dataset.extMore;
          const ext = _index[id];
          if (ext) _toggleMenu(more, ext, id);
          return;
        }
        if (e.target.closest("a")) return;
        const row = e.target.closest(".extension-row-clickable");
        if (row && row.dataset.extId) _openDetail(row.dataset.extId, row.dataset.extOrigin);
      });
    }

    _wireMenuDismiss();

    const importBtn  = $("btn-import-extension");
    const importFile = $("extension-import-file");
    if (importBtn && importFile) {
      importBtn.addEventListener("click", () => importFile.click());
      importFile.addEventListener("change", async () => {
        const file = importFile.files[0];
        importFile.value = "";
        if (!file) return;
        if (!/\.zip$/i.test(file.name)) {
          alert(I18n.t("extensions.import.notZip"));
          return;
        }
        const label = importBtn.querySelector("span");
        importBtn.disabled = true;
        if (label) label.textContent = I18n.t("extensions.action.installing");
        const result = await Extensions.importZip(file);
        if (!result.ok) alert(result.error || I18n.t("extensions.import.failed"));
        // Success reloads the page inside importZip's poll loop; these resets
        // only matter on the failure path above.
        importBtn.disabled = false;
        if (label) label.textContent = I18n.t("extensions.btn.import");
      });
    }

    document.addEventListener("langchange", () => {
      if (input) input.placeholder = I18n.t("extensions.searchPlaceholder");
      _renderList();
      _renderDetail();
    });

    _domWired = true;
  }

  function _subscribe() {
    Extensions.on("extensions:loading", _renderLoading);
    Extensions.on("extensions:loadingMore", _renderLoadingMore);
    Extensions.on("extensions:changed", _renderList);
    Extensions.on("extensions:job", (p) => {
      if (!p || !p.id) return;
      if (p.stage === "done") {
        // A finished install has no row state to paint — reload so the new
        // extension shows up everywhere. Skip when the panel is off screen: the
        // store re-reads on the next onPanelShow.
        if (_panelVisible()) location.reload();
        return;
      }
      _updateRowJob(p.id);
    });
    Extensions.on("extensions:error",   _renderList);
    Extensions.on("extensions:detail",  _renderDetail);
  }

  const viewApi = {
    async onPanelShow(opts) {
      _wireDom();
      await _applyBrandTab();
      if (window.Skills && Skills.refreshBrandStatus) Skills.refreshBrandStatus();

      const detailId = opts && opts.detailId;
      if (detailId) {
        const sortEl = $("extensions-sort");
        if (sortEl) sortEl.style.display = "";
        Extensions.load();
        Extensions.loadDetail(detailId, opts && opts.source);
        return;
      }

      Extensions.closeDetail();
      let restored = null;
      try { restored = sessionStorage.getItem(EXT_TAB_KEY); } catch (_) {}
      _setActiveTab(restored || "all");
    },
  };

  return { init: _subscribe, api: viewApi };
})();

Object.assign(Extensions, ExtensionsView.api);
ExtensionsView.init();
