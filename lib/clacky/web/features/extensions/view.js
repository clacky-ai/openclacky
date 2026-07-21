// ── Extensions · view — rendering, DOM wiring for the extension marketplace ─
//
// The view owns everything DOM: the search bar, sort control, extension cards,
// loading/empty states. It reads data only through ExtensionsStore.state and
// reacts to store events via Extensions.on(...). It never fetches directly — it
// calls store actions.
//
// The panel is read-only: extensions are delivered inside license-gated brand
// packages, so there is no install button here, only a "how to get" hint.
//
// Depends on: ExtensionsStore (store.js), I18n/Router, global $ / escapeHtml.
// ───────────────────────────────────────────────────────────────────────────

const ExtensionsView = (() => {
  let _domWired    = false;
  let _searchTimer = null;

  function _renderLoading() {
    const container = $("extensions-list");
    if (!container) return;
    container.innerHTML = Array.from({ length: 4 }).map(() => `
      <div class="extension-card">
        <div class="extension-card-main">
          <span class="skel" style="height:2rem;width:2rem;border-radius:8px;flex-shrink:0"></span>
          <div class="extension-info" style="display:flex;flex-direction:column;gap:0.375rem">
            <span class="skel skel-title"></span>
            <span class="skel skel-subtitle"></span>
          </div>
        </div>
      </div>`).join("");
  }

  function _renderEmpty() {
    const container = $("extensions-list");
    if (!container) return;
    const key = ExtensionsStore.state.query ? "extensions.noResults" : "extensions.empty";
    container.innerHTML = `<div class="extensions-empty">${escapeHtml(I18n.t(key))}</div>`;
  }

  function _renderList() {
    const container = $("extensions-list");
    if (!container) return;

    if (ExtensionsStore.state.loading) { _renderLoading(); return; }

    const list = ExtensionsStore.state.extensions;
    if (!list || list.length === 0) { _renderEmpty(); return; }

    container.innerHTML = "";
    list.forEach(ext => container.appendChild(_renderCard(ext)));

    _applyWarning(ExtensionsStore.state.error);
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

  function _defaultIcon(name, extraClass) {
    const letter = (name || "?")[0].toUpperCase();
    const colors = [
      ["#6366f1","#818cf8"], ["#8b5cf6","#a78bfa"], ["#ec4899","#f472b6"],
      ["#f59e0b","#fbbf24"], ["#10b981","#34d399"], ["#3b82f6","#60a5fa"],
      ["#ef4444","#f87171"], ["#14b8a6","#2dd4bf"],
    ];
    const idx = (name || "").charCodeAt(0) % colors.length;
    const [c1, c2] = colors[idx];
    const gid = `eg-${idx}-${Math.random().toString(36).slice(2,7)}`;
    const cls = extraClass ? `extension-emoji ${extraClass}` : "extension-emoji";
    return `<span class="${cls}"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" class="extension-default-icon"><defs><linearGradient id="${gid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="${c1}"/><stop offset="100%" stop-color="${c2}"/></linearGradient></defs><rect width="32" height="32" rx="8" fill="url(#${gid})"/><text x="16" y="22" text-anchor="middle" font-family="system-ui,sans-serif" font-size="16" font-weight="700" fill="white">${letter}</text></svg></span>`;
  }

  function _renderCard(ext) {
    const currentLang = I18n.lang();
    const name = (currentLang === "zh" && ext.display_name_zh) ? ext.display_name_zh : (ext.display_name || ext.name);
    const description = (currentLang === "zh" && ext.description_zh)
      ? ext.description_zh
      : ext.description || "";
    const emojiHtml = ext.emoji ? `<span class="extension-emoji">${escapeHtml(ext.emoji)}</span>` : _defaultIcon(ext.name);

    const versionHtml = ext.version
      ? `<span class="extension-version">v${escapeHtml(String(ext.version))}</span>` : "";
    const canUpdate = ext.installed_version && ext.version && ext.installed_version !== ext.version;
    const installedHtml = ext.installed
      ? `<span class="extension-installed">${escapeHtml(I18n.t("extensions.installed"))}</span>` : "";
    const updatableHtml = canUpdate
      ? `<span class="extension-updatable">${escapeHtml(I18n.t("extensions.updatable"))}</span>` : "";
    const unlistedHtml = (ext.unlisted && ext.installed)
      ? `<span class="extension-unlisted">${escapeHtml(I18n.t("extensions.unlisted"))}</span>` : "";
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

    const card = document.createElement("div");
    card.className = "extension-card extension-card-clickable";
    card.dataset.extId = ext.id != null ? String(ext.id) : (ext.name || "");
    card.innerHTML = `
      <div class="extension-card-main">
        ${emojiHtml}
        <div class="extension-info">
          <div class="extension-title">
            <span class="extension-name">${escapeHtml(name)}</span>
            ${versionHtml}
            ${installedHtml}
            ${updatableHtml}
            ${unlistedHtml}
            ${unitsHtml}
            ${authorHtml}
            ${installsHtml}
          </div>
          ${description ? `<div class="extension-desc">${escapeHtml(description)}</div>` : ""}
          ${homepageHtml ? `<div class="extension-meta">${homepageHtml}</div>` : ""}
        </div>
      </div>`;
    return card;
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
      remove.addEventListener("click", async () => {
        const id = remove.getAttribute("data-ext-remove");
        const { ok, checked } = await Modal.confirmWithCheckbox(
          I18n.t("extensions.action.removeConfirm"),
          I18n.t("extensions.action.removePurgeData")
        );
        if (ok) Extensions.uninstall(id, checked);
      });
    }

    const installBtn = document.querySelector("[data-ext-install]");
    if (installBtn) {
      installBtn.addEventListener("click", () => {
        const id = installBtn.getAttribute("data-ext-install");
        installBtn.disabled = true;
        installBtn.textContent = I18n.t("extensions.action.installing");
        Extensions.install(id);
      });
    }

    const updateBtn = document.querySelector("[data-ext-update]");
    if (updateBtn) {
      updateBtn.addEventListener("click", () => {
        const id = updateBtn.getAttribute("data-ext-update");
        updateBtn.disabled = true;
        updateBtn.textContent = I18n.t("extensions.action.updating");
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
    const emoji = ext.emoji || "🧩";
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
            ${unitsHtml}
            ${authorHtml}
            ${installsHtml}
          </div>
          ${description ? `<div class="extension-desc extension-desc-detail">${escapeHtml(description)}</div>` : ""}
          ${homepageHtml ? `<div class="extension-meta">${homepageHtml}</div>` : ""}
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
    const slug = ext.name || ext.slug || id;
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

    const sortSelect = $("extensions-sort");
    if (sortSelect) {
      sortSelect.value = ExtensionsStore.state.sort;
      sortSelect.addEventListener("change", () => Extensions.setSort(sortSelect.value));
    }

    document.querySelectorAll(".extensions-filter-tab").forEach(btn => {
      btn.addEventListener("click", () => {
        document.querySelectorAll(".extensions-filter-tab").forEach(b => b.classList.remove("extensions-filter-tab-active"));
        btn.classList.add("extensions-filter-tab-active");
        Extensions.setFilterInstalled(btn.dataset.filter === "installed");
      });
    });

    const list = $("extensions-list");
    if (list) {
      list.addEventListener("click", (e) => {
        if (e.target.closest("a")) return;
        const card = e.target.closest(".extension-card-clickable");
        if (card && card.dataset.extId) {
          const router = window.Clacky && window.Clacky.Router;
          if (router) router.navigate("extensions", { detailId: card.dataset.extId });
          else Extensions.loadDetail(card.dataset.extId);
        }
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
    Extensions.on("extensions:changed", _renderList);
    Extensions.on("extensions:error",   _renderList);
    Extensions.on("extensions:detail",  _renderDetail);
  }

  const viewApi = {
    onPanelShow(opts) {
      _wireDom();
      const detailId = opts && opts.detailId;
      if (detailId) {
        Extensions.load();
        Extensions.loadDetail(detailId);
      } else {
        Extensions.closeDetail();
        Extensions.load();
      }
    },
  };

  return { init: _subscribe, api: viewApi };
})();

Object.assign(Extensions, ExtensionsView.api);
ExtensionsView.init();
