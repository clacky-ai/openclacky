// ── Skills · view — rendering, slots, DOM event wiring ─────────────────────
//
// The view owns everything that touches the DOM: rendering skill cards,
// switching tabs, wiring panel listeners, the import bar. It reads data only
// through SkillsStore.state and reacts to store events via SkillsStore.on(...).
// It never fetches or mutates core data directly — it calls store actions.
//
// Several entry points (onPanelShow / renderSection / toggleImportBar /
// openBrandSkillsTab) are still invoked on the `Skills` global by other modules
// (app.js, settings.js, SkillAC). The view augments the same `Skills` facade
// with these UI methods so existing callers keep working unchanged.
//
// Depends on: SkillsStore (store.js), I18n/Modal/Router/Brand, Sessions,
//             global $ / escapeHtml helpers.
// ───────────────────────────────────────────────────────────────────────────

const SkillsView = (() => {
  let _domWired = false;
  let _searchQuery = "";

  // ── Search filtering ─────────────────────────────────────────────────────

  function _applySearch() {
    const q = _searchQuery.trim().toLowerCase();
    const list = $(SkillsStore.state.activeTab === "my-skills" ? "skills-list" : "brand-skills-list");
    if (!list) return;

    const tiles = [...list.querySelectorAll(".skill-tile")];
    tiles.forEach(tile => {
      tile.style.display = (!q || tile.textContent.toLowerCase().includes(q)) ? "" : "none";
    });
    list.querySelectorAll(".extensions-group").forEach(group => {
      const shown = [...group.querySelectorAll(".skill-tile")].some(t => t.style.display !== "none");
      group.style.display = shown ? "" : "none";
    });

    let noResult = list.querySelector(".skills-search-empty");
    const anyVisible = tiles.some(t => t.style.display !== "none");
    if (q && !anyVisible) {
      if (!noResult) {
        noResult = document.createElement("div");
        noResult.className = "skills-search-empty";
        noResult.textContent = I18n.t("skills.search.empty");
        list.appendChild(noResult);
      }
    } else {
      noResult && noResult.remove();
    }
  }

  function _wireSearch() {
    const input = $("skills-search-input");
    if (!input) return;
    input.placeholder = I18n.t("skills.search.placeholder");
    input.addEventListener("input", () => {
      _searchQuery = input.value;
      _applySearch();
    });
  }

  // ── Shared tile pieces ───────────────────────────────────────────────────

  const ICONS = {
    more:   '<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><circle cx="5" cy="12" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="19" cy="12" r="1.7"/></svg>',
    check:  '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M3.5 8.3l3 3 6-6.3" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    chat:   '<svg width="18" height="18" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M10 2.75c4.1 0 7.25 2.9 7.25 6.6s-3.15 6.6-7.25 6.6c-.9 0-1.76-.14-2.56-.4L4 17.1l.84-3.1C3.52 12.8 2.75 11.15 2.75 9.35c0-3.7 3.15-6.6 7.25-6.6z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/><path d="M7.3 7.6v1.6M12.7 7.6v1.6" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
    plus:   '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M12 5.5v13M5.5 12h13" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>',
    update: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M8 12.5V3.8M4.3 7.3L8 3.6l3.7 3.7" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    edit:   '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M9.9 3.4l2.7 2.7M2.8 13.2l.6-3 7.3-7.3a1.3 1.3 0 011.9 0l.8.8a1.3 1.3 0 010 1.9L6.1 12.9l-3.3.3z" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    delete: '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M3.1 4.6h9.8" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/><path d="M6.3 4.6V3.4c0-.5.4-.9.9-.9h1.6c.5 0 .9.4.9.9v1.2" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/><path d="M4.6 4.6l.6 8c.05.7.63 1.25 1.33 1.25h2.94c.7 0 1.28-.55 1.33-1.25l.6-8" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
    on:     '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="8" cy="8" r="6.1" stroke="currentColor" stroke-width="1.3"/><path d="M5.4 8.2l1.8 1.8 3.4-3.6" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    off:    '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="8" cy="8" r="6.1" stroke="currentColor" stroke-width="1.3"/><path d="M4.3 11.7L11.7 4.3" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
  };

  function _localized(skill) {
    const zh = I18n.lang() === "zh";
    return {
      name:        (zh && skill.name_zh) ? skill.name_zh : skill.name,
      description: (zh && skill.description_zh) ? skill.description_zh : (skill.description || ""),
    };
  }

  // `state` is the right-most button; `menu` lists the "…" entries.
  // Inner controls must not open the detail view. Their own click handlers run
  // first and may replace their children before the event bubbles up here (the
  // install button swaps itself for a spinner), which detaches e.target from
  // the tree and makes closest("button") miss. composedPath() is fixed when the
  // event is dispatched, so it survives that.
  function _clickedOnControl(e) {
    return e.composedPath().some((el) => el.tagName === "BUTTON" || el.tagName === "A");
  }

  function _tile({ skill, metaHtml, descHtml, stateHtml, menu, muted }) {
    const { name } = _localized(skill);
    const tile = document.createElement("div");
    tile.className = "skill-tile" + (muted ? " skill-tile-muted" : "");
    tile.innerHTML = `
      <div class="skill-tile-head">
        <div class="skill-tile-title">
          <span class="skill-tile-name">${escapeHtml(name)}</span>
          ${metaHtml || ""}
        </div>
        <div class="skill-tile-actions">
          ${menu && menu.length ? `<button type="button" class="ext-row-more" title="${escapeHtml(I18n.t("extensions.action.more"))}" aria-haspopup="menu" aria-expanded="false">${ICONS.more}</button>` : ""}
          ${stateHtml || ""}
        </div>
      </div>
      ${descHtml}`;

    const moreBtn = tile.querySelector(".ext-row-more");
    if (moreBtn) moreBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      _toggleMenu(moreBtn, menu);
    });
    return tile;
  }

  function _descHtml(text) {
    return `<div class="skill-tile-desc">${escapeHtml(text)}</div>`;
  }

  // ✓ at rest, chat bubble while the tile is hovered — clicking starts a session.
  function _useStateHtml() {
    return `<button type="button" class="ext-row-more skill-tile-use" data-tooltip="${escapeHtml(I18n.t("skills.btn.use"))}">
      <span class="skill-tile-use-done">${ICONS.check}</span><span class="skill-tile-use-go">${ICONS.chat}</span>
    </button>`;
  }

  function _grid(tiles) {
    const grid = document.createElement("div");
    grid.className = "skill-grid";
    tiles.forEach(t => grid.appendChild(t));
    return grid;
  }

  function _group(title, tiles) {
    const wrap = document.createElement("div");
    wrap.className = "extensions-group";
    const head = document.createElement("div");
    head.className = "extensions-group-title";
    head.textContent = title;
    wrap.appendChild(head);
    wrap.appendChild(_grid(tiles));
    return wrap;
  }

  // ── Row "…" menu (one floating menu shared by every tile) ────────────────

  let _menuEl    = null;
  let _menuBtn   = null;
  let _menuItems = [];

  function _ensureMenu() {
    if (_menuEl) return _menuEl;
    _menuEl = document.createElement("div");
    _menuEl.className = "ext-row-menu";
    _menuEl.setAttribute("role", "menu");
    _menuEl.hidden = true;
    _menuEl.addEventListener("click", (e) => {
      const item = e.target.closest("[data-skill-menu]");
      if (!item) return;
      const entry = _menuItems[Number(item.getAttribute("data-skill-menu"))];
      _closeMenu();
      if (entry) entry.run();
    });
    document.body.appendChild(_menuEl);

    document.addEventListener("click", (e) => {
      if (_menuEl.hidden) return;
      if (!e.target.closest(".ext-row-more") && !e.target.closest(".ext-row-menu")) _closeMenu();
    });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") _closeMenu(); });
    window.addEventListener("resize", _closeMenu);
    window.addEventListener("scroll", _closeMenu, true);
    return _menuEl;
  }

  function _toggleMenu(btn, items) {
    if (_menuBtn === btn && _menuEl && !_menuEl.hidden) { _closeMenu(); return; }

    const el = _ensureMenu();
    _closeMenu();
    _menuBtn   = btn;
    _menuItems = items;
    el.innerHTML = items.map((it, i) =>
      `<button type="button" role="menuitem" class="ext-row-menu-item${it.danger ? " ext-row-menu-danger" : ""}" data-skill-menu="${i}">${ICONS[it.icon]}<span>${escapeHtml(it.label)}</span></button>`
    ).join("");
    el.hidden = false;
    btn.setAttribute("aria-expanded", "true");

    const rect = btn.getBoundingClientRect();
    const w    = el.offsetWidth;
    const h    = el.offsetHeight;
    const left = Math.min(rect.right - w, window.innerWidth - w - 8);
    let top    = rect.bottom + 4;
    if (top + h > window.innerHeight - 8) top = rect.top - h - 4;
    el.style.left = Math.max(8, left) + "px";
    el.style.top  = Math.max(8, top) + "px";
  }

  function _closeMenu() {
    if (!_menuEl || _menuEl.hidden) return;
    _menuEl.hidden = true;
    if (_menuBtn) _menuBtn.setAttribute("aria-expanded", "false");
    _menuBtn   = null;
    _menuItems = [];
  }

  // ── My Skills rendering ──────────────────────────────────────────────────

  function _renderMySkills() {
    const container = $("skills-list");
    if (!container) { console.error("[Skills] skills-list not found!"); return; }
    _closeMenu();
    container.innerHTML = "";

    const skills = SkillsStore.state.skills;
    const visible = SkillsStore.state.showSystemSkills
      ? skills
      : skills.filter(s => !_isSystem(s));

    if (visible.length === 0) {
      container.appendChild(_renderEmptyState());
      return;
    }

    const groups = [
      { title: I18n.t("skills.badge.system"), items: visible.filter(_isSystem) },
      { title: I18n.t("skills.badge.custom"), items: visible.filter(s => !_isSystem(s)) },
    ];
    groups.forEach((group) => {
      if (group.items.length === 0) return;
      const tiles = [];
      group.items.forEach((skill) => {
        try {
          tiles.push(_renderSkillTile(skill));
        } catch (e) {
          console.error("[Skills] _renderSkillTile failed for skill", skill.name, e);
        }
      });
      container.appendChild(_group(group.title, tiles));
    });
    _applySearch();
  }

  function _isSystem(skill) {
    return skill.source === "default" || skill.source === "brand";
  }

  function _renderEmptyState() {
    const emptyWrapper = document.createElement("div");
    emptyWrapper.className = "skills-empty";

    const emptyTextEl = document.createElement("div");
    emptyTextEl.className   = "skills-empty-text";
    emptyTextEl.textContent = I18n.t("skills.empty");

    const createBtn = document.createElement("div");
    createBtn.className = "skills-empty-create-btn";
    createBtn.innerHTML = `
      <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M12 2a10 10 0 1 0 10 10A10 10 0 0 0 12 2z"/><path d="M12 8v8"/><path d="M8 12h8"/>
      </svg>
      <span>${escapeHtml(I18n.t("skills.empty.createBtn"))}</span>
      <svg class="skills-empty-create-arrow" xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M5 12h14"/><path d="M12 5l7 7-7 7"/>
      </svg>`;
    createBtn.addEventListener("click", () => Skills.createInSession("/skill-creator"));

    emptyWrapper.appendChild(emptyTextEl);
    emptyWrapper.appendChild(createBtn);
    return emptyWrapper;
  }

  // Enabled → ✓ (hover: use). Disabled → "+" to switch back on.
  // System skills are always on and can't be edited, so they get no "…".
  function _renderSkillTile(skill) {
    const isSystem = _isSystem(skill);
    const { description } = _localized(skill);

    let metaHtml = "";
    if (skill.invalid) {
      metaHtml = `<span class="skill-badge skill-badge-invalid">${I18n.t("skills.badge.invalid")}</span>`;
    } else if (skill.warnings && skill.warnings.length > 0) {
      const tooltip = I18n.t("skills.warning.tooltip", { reason: skill.warnings.join("\n") });
      metaHtml = `<span class="skill-warn-icon" data-tooltip="${escapeHtml(tooltip)}">⚠</span>`;
    }

    const descHtml = skill.invalid
      ? `<div class="skill-tile-desc skill-tile-error">${escapeHtml(skill.invalid_reason || I18n.t("skills.invalid.reason"))}</div>`
      : _descHtml(description);

    let stateHtml = "";
    if (skill.invalid) {
      stateHtml = "";
    } else if (skill.enabled || isSystem) {
      stateHtml = _useStateHtml();
    } else {
      stateHtml = `<button type="button" class="ext-row-add skill-tile-enable" data-tooltip="${escapeHtml(I18n.t("skills.toggle.enableDesc"))}">${ICONS.plus}</button>`;
    }

    const menu = [];
    if (!isSystem) {
      if (!skill.invalid) {
        menu.push(skill.enabled
          ? { icon: "off", label: I18n.t("extensions.action.disable"), run: () => Skills.toggle(skill.name, false) }
          : { icon: "on",  label: I18n.t("extensions.action.enable"),  run: () => Skills.toggle(skill.name, true) });
      }
      menu.push({ icon: "edit",   label: I18n.t("skills.btn.edit"),   run: () => _editSkill(skill) });
      menu.push({ icon: "delete", label: I18n.t("skills.btn.delete"), run: () => Skills.delete(skill.name), danger: true });
    }

    const tile = _tile({
      skill, metaHtml, descHtml, stateHtml, menu,
      muted: skill.invalid || (!isSystem && !skill.enabled),
    });

    const useBtn = tile.querySelector(".skill-tile-use");
    if (useBtn) useBtn.addEventListener("click", () => Skills.useInstalledSkill(skill.name));
    const enableBtn = tile.querySelector(".skill-tile-enable");
    if (enableBtn) enableBtn.addEventListener("click", () => Skills.toggle(skill.name, true));

    tile.classList.add("skill-tile-clickable");
    tile.addEventListener("click", (e) => {
      if (_clickedOnControl(e)) return;
      _openDetail(skill.name);
    });

    return tile;
  }

  // ── Brand Skills rendering ───────────────────────────────────────────────

  function _renderBrandLoading() {
    const container = $("brand-skills-list");
    if (!container) return;
    container.innerHTML = `<div class="skill-grid">${Array.from({ length: 4 }).map(() => `
      <div class="skill-tile">
        <div class="skill-tile-head">
          <span class="skel skel-title"></span>
        </div>
        <span class="skel skel-subtitle"></span>
      </div>`).join("")}</div>`;
  }

  function _renderBrandError(payload) {
    const container = $("brand-skills-list");
    if (!container) return;
    const msg = payload.network
      ? "Network error \u2014 please try again."
      : escapeHtml(payload.error || I18n.t("skills.brand.loadFailed"));
    container.innerHTML = `<div class="brand-skills-error">${msg}</div>`;
  }

  function _applyBrandWarning(warning, warningCode) {
    const warningBanner = $("brand-skills-warning");
    if (!warningBanner) return;
    const warningText = warningCode ? I18n.t("skills.brand.warning." + warningCode) : warning;
    if (warningText) {
      warningBanner.textContent = warningText;
      if (warningCode) warningBanner.setAttribute("data-i18n", "skills.brand.warning." + warningCode);
      else warningBanner.removeAttribute("data-i18n");
      warningBanner.style.display = "";
    } else {
      warningBanner.style.display = "none";
      warningBanner.removeAttribute("data-i18n");
    }
  }

  function _renderBrandSkills() {
    const container = $("brand-skills-list");
    if (!container) return;
    _closeMenu();
    container.innerHTML = "";

    const brandSkills     = SkillsStore.state.brandSkills;
    const freeMode        = SkillsStore.state.freeMode;
    const paidSkillsCount = SkillsStore.state.paidSkillsCount;

    if (brandSkills.length === 0 && !(freeMode && paidSkillsCount > 0)) {
      container.innerHTML = `<div class="brand-skills-empty">${I18n.t("skills.brand.empty")}</div>`;
      return;
    }

    if (brandSkills.length > 0) container.appendChild(_grid(brandSkills.map(_renderBrandSkillTile)));

    if (freeMode && paidSkillsCount > 0) {
      container.appendChild(_renderPaidHint(paidSkillsCount));
    }
    _applySearch();
  }

  function _renderPaidHint(paidSkillsCount) {
    const hint = document.createElement("div");
    hint.className = "brand-skills-paid-hint";

    const msgEl = document.createElement("div");
    msgEl.className = "brand-skills-paid-hint-msg";
    msgEl.textContent = I18n.t("skills.brand.paidHint", { n: paidSkillsCount });
    msgEl.setAttribute("data-i18n", "skills.brand.paidHint");
    msgEl.setAttribute("data-i18n-vars", `n=${paidSkillsCount}`);

    const btn = document.createElement("button");
    btn.className   = "brand-skills-activate-btn";
    btn.textContent = I18n.t("skills.brand.activateBtn");
    btn.setAttribute("data-i18n", "skills.brand.activateBtn");
    btn.addEventListener("click", () => {
      if (typeof Brand !== "undefined" && Brand.goToLicenseInput) Brand.goToLicenseInput();
      else window.Clacky.Router.navigate("settings");
    });

    hint.appendChild(msgEl);
    hint.appendChild(btn);
    return hint;
  }

  // Not installed → "+" (install). Outdated → ↑ (update). Installed → ✓ (hover: use).
  function _renderBrandSkillTile(skill) {
    const name             = skill.name;
    const installedVersion = skill.installed_version;
    const latestVersion    = (skill.latest_version || {}).version || skill.version;
    const needsUpdate      = skill.needs_update;
    const shownVersion     = installedVersion || latestVersion;

    const tag = skill.is_free
      ? `<span class="skill-tile-tag" data-tooltip="${escapeHtml(I18n.t("skills.brand.freeTip"))}">${I18n.t("skills.brand.free")}</span>`
      : `<span class="skill-tile-tag" data-tooltip="${escapeHtml(I18n.t("skills.brand.privateTip"))}">${I18n.t("skills.brand.private")}</span>`;
    const metaHtml = `${shownVersion ? `<span class="skill-tile-version">v${escapeHtml(shownVersion)}</span>` : ""}${tag}`;

    let stateHtml;
    if (!installedVersion) {
      stateHtml = `<button type="button" class="ext-row-add skill-tile-install" data-tooltip="${escapeHtml(I18n.t("skills.brand.btn.install"))}">${ICONS.plus}</button>`;
    } else if (needsUpdate) {
      const tip = `${I18n.t("skills.brand.btn.update")} v${installedVersion} → v${latestVersion}`;
      stateHtml = `<button type="button" class="ext-row-add skill-tile-install skill-tile-update" data-tooltip="${escapeHtml(tip)}">${ICONS.update}</button>`;
    } else {
      stateHtml = _useStateHtml();
    }

    const menu = installedVersion
      ? [{ icon: "delete", label: I18n.t("skills.btn.delete"), run: () => Skills.deleteBrandSkill(name), danger: true }]
      : [];

    const tile = _tile({ skill, metaHtml, descHtml: _descHtml(_localized(skill).description), stateHtml, menu });

    const installBtn = tile.querySelector(".skill-tile-install");
    if (installBtn) installBtn.addEventListener("click", () => _runBrandInstall(name, installBtn));
    const useBtn = tile.querySelector(".skill-tile-use");
    if (useBtn) useBtn.addEventListener("click", () => Skills.useInstalledSkill(name));

    tile.classList.add("skill-tile-clickable");
    tile.addEventListener("click", (e) => {
      if (_clickedOnControl(e)) return;
      _openDetail(name, true);
    });

    return tile;
  }

  async function _runBrandInstall(name, btn) {
    const original = btn.innerHTML;
    btn.disabled  = true;
    btn.innerHTML = '<span class="ext-spinner"></span>';
    const result = await Skills.installBrandSkill(name);
    if (!result || !result.ok) {
      _showBrandInstallError(btn, (result && result.message) || I18n.t("skills.brand.unknownError"));
      btn.disabled  = false;
      btn.innerHTML = original;
    }
    // On success the store emits brandSkills:changed → the tab re-renders,
    // replacing this button.
  }

  function _showBrandInstallError(btn, message) {
    const tile = btn.closest(".skill-tile, .skill-detail-hero");
    const existing = tile.querySelector(".brand-install-error");
    if (existing) existing.remove();
    const tip = document.createElement("div");
    tip.className   = "brand-install-error";
    tip.textContent = message;
    tile.appendChild(tip);
    setTimeout(() => tip.remove(), 5000);
  }

  // ── Skill detail ─────────────────────────────────────────────────────────

  let _detailName  = null;
  let _detailBrand = false;
  let _detailMode  = "preview";   // "preview" | "source"
  let _detailToken = 0;

  const DETAIL_ICONS = {
    back:    '<svg width="14" height="14" viewBox="0 0 14 14" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M9 2L4 7L9 12" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    preview: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>',
    source:  '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg"><path d="M9 7l-5 5 5 5M15 7l5 5-5 5"/></svg>',
  };

  function _openDetail(name, brand = false) {
    const router = window.Clacky && window.Clacky.Router;
    if (router) router.navigate("skills", { detailName: name, brand });
    else _showDetail(name, brand);
  }

  function _backToList() {
    const router = window.Clacky && window.Clacky.Router;
    if (router) router.navigate("skills");
    else _showDetail(null);
  }

  function _showDetail(name, brand = false) {
    _closeMenu();
    const body  = $("skills-body");
    const panel = $("skills-detail");
    if (!panel) return;
    if (name !== _detailName || brand !== _detailBrand) _detailMode = "preview";
    _detailName  = name;
    _detailBrand = !!(name && brand);
    if (!name) {
      panel.style.display = "none";
      panel.innerHTML = "";
      if (body) body.style.display = "";
      return;
    }
    if (body) body.style.display = "none";
    panel.style.display = "";
    // Back from a brand detail should land on the brand tab; switching also loads the list.
    if (_detailBrand && SkillsStore.state.activeTab !== "brand-skills") Skills.setActiveTab("brand-skills");
    _renderDetail();
  }

  async function _renderDetail() {
    const panel = $("skills-detail");
    if (!panel || !_detailName) return;
    if (_detailBrand) return _renderBrandDetail(panel);
    if (!SkillsStore.state.loaded) {
      panel.innerHTML = _detailShell(_detailSkeleton());
      _wireDetailBack();
      return;
    }
    const skill = SkillsStore.state.skills.find(s => s.name === _detailName);
    if (!skill) { _backToList(); return; }

    const token = ++_detailToken;
    const res = await Skills.fetchSkillContent(skill.name);
    if (token !== _detailToken || _detailName !== skill.name) return;

    panel.innerHTML = _detailShell(_detailContent(skill, res.ok ? res : null));
    _wireDetail(skill, res.ok ? res : null);
  }

  function _detailSkeleton() {
    return `<div class="extension-detail-loading"><span class="skel skel-title"></span><span class="skel skel-subtitle"></span></div>`;
  }

  async function _renderBrandDetail(panel) {
    const state = SkillsStore.state;
    const skill = state.brandSkills.find(s => s.name === _detailName);
    if (!skill) {
      if (state.brandLoaded) { _backToList(); return; }
      panel.innerHTML = _detailShell(_detailSkeleton());
      _wireDetailBack();
      return;
    }

    const token = ++_detailToken;
    const res = skill.installed_version ? await Skills.fetchSkillContent(skill.name) : null;
    if (token !== _detailToken || _detailName !== skill.name || !_detailBrand) return;

    const doc = res && res.ok ? res : null;
    panel.innerHTML = _detailShell(_brandDetailContent(skill, doc));
    _wireBrandDetail(skill, doc);
  }

  function _brandDetailMenu(skill) {
    if (!skill.installed_version) return [];
    return [{ icon: "delete", label: I18n.t("skills.btn.delete"), run: () => Skills.deleteBrandSkill(skill.name), danger: true }];
  }

  function _brandDetailContent(skill, res) {
    const { name, description } = _localized(skill);
    const installed = skill.installed_version;
    const latest    = skill.latest_version || {};
    const latestVer = latest.version || skill.version;

    let actionHtml;
    if (!installed) {
      actionHtml = `<button type="button" class="btn-primary skill-detail-try" id="skill-detail-install">${escapeHtml(I18n.t("skills.brand.btn.install"))}</button>`;
    } else if (skill.needs_update) {
      actionHtml = `<button type="button" class="btn-primary skill-detail-try" id="skill-detail-install">${escapeHtml(`${I18n.t("skills.brand.btn.update")} v${latestVer}`)}</button>`;
    } else {
      actionHtml = `<button type="button" class="btn-secondary skill-detail-try" id="skill-detail-try">${escapeHtml(I18n.t("skills.detail.try"))}</button>`;
    }
    const moreHtml = _brandDetailMenu(skill).length
      ? `<button type="button" class="ext-row-more" id="skill-detail-more" title="${escapeHtml(I18n.t("extensions.action.more"))}" aria-haspopup="menu" aria-expanded="false">${ICONS.more}</button>` : "";

    const shownVer = installed || latestVer;
    const tag = I18n.t(skill.is_free ? "skills.brand.free" : "skills.brand.private");
    const metaHtml = `<div class="skill-detail-sub">${shownVer ? `<span class="skill-tile-version">v${escapeHtml(shownVer)}</span>` : ""}<span class="skill-tile-tag">${escapeHtml(tag)}</span></div>`;

    const notes = latest.release_notes ? `
      <div class="skill-detail-notes">
        <div class="skill-detail-notes-title">${escapeHtml(I18n.t("skills.detail.releaseNotes"))}${latestVer ? ` · v${escapeHtml(latestVer)}` : ""}</div>
        <div class="extension-readme-body">${_markdownHtml(String(latest.release_notes))}</div>
      </div>` : "";

    let docHtml;
    if (res) docHtml = _detailDoc(res);
    else docHtml = `<div class="skill-detail-hint">${escapeHtml(I18n.t(installed ? "skills.detail.encrypted" : "skills.detail.notInstalled"))}</div>`;

    return `
      <div class="skill-detail-hero">
        <div class="skill-detail-title-row">
          <h2 class="skill-detail-title">${escapeHtml(name)}</h2>
          <div class="skill-detail-actions">${actionHtml}${moreHtml}</div>
        </div>
        ${metaHtml}
        ${description ? `<p class="skill-detail-desc">${escapeHtml(description)}</p>` : ""}
      </div>
      ${notes}
      ${docHtml}`;
  }

  function _wireBrandDetail(skill, res) {
    _wireDetailBack();

    const installBtn = $("skill-detail-install");
    if (installBtn) installBtn.addEventListener("click", () => _runBrandInstall(skill.name, installBtn));

    const tryBtn = $("skill-detail-try");
    if (tryBtn) tryBtn.addEventListener("click", () => Skills.useInstalledSkill(skill.name));

    const more = $("skill-detail-more");
    if (more) more.addEventListener("click", (e) => {
      e.stopPropagation();
      _toggleMenu(more, _brandDetailMenu(skill));
    });

    if (res) _wireDocModes(res);
  }

  function _detailShell(inner) {
    return `
      <div class="extension-detail-head">
        <button type="button" class="extension-detail-back" id="skill-detail-back">
          ${DETAIL_ICONS.back}${escapeHtml(I18n.t("skills.detail.back"))}
        </button>
      </div>
      ${inner}`;
  }

  function _detailMenu(skill) {
    if (_isSystem(skill)) return [];
    return [
      { icon: "edit",   label: I18n.t("skills.btn.edit"),   run: () => _editSkill(skill) },
      { icon: "delete", label: I18n.t("skills.btn.delete"), run: () => Skills.delete(skill.name), danger: true },
    ];
  }

  function _detailContent(skill, res) {
    const { name, description } = _localized(skill);
    const isSystem = _isSystem(skill);
    const canToggle = !isSystem && !skill.invalid;

    const toggleHtml = canToggle ? `
      <label class="toggle-switch skill-detail-toggle" data-tooltip="${escapeHtml(I18n.t(skill.enabled ? "extensions.action.disable" : "extensions.action.enable"))}">
        <input type="checkbox" id="skill-detail-enabled" ${skill.enabled ? "checked" : ""}>
        <span class="toggle-slider"></span>
      </label>` : "";
    const tryHtml = (skill.invalid || (!isSystem && !skill.enabled)) ? ""
      : `<button type="button" class="btn-secondary skill-detail-try" id="skill-detail-try">${escapeHtml(I18n.t("skills.detail.try"))}</button>`;
    const moreHtml = _detailMenu(skill).length
      ? `<button type="button" class="ext-row-more" id="skill-detail-more" title="${escapeHtml(I18n.t("extensions.action.more"))}" aria-haspopup="menu" aria-expanded="false">${ICONS.more}</button>` : "";
    const invalidHtml = skill.invalid
      ? `<div class="skill-detail-error">${escapeHtml(skill.invalid_reason || I18n.t("skills.invalid.reason"))}</div>` : "";

    return `
      <div class="skill-detail-hero">
        <div class="skill-detail-title-row">
          <h2 class="skill-detail-title">${escapeHtml(name)}</h2>
          <div class="skill-detail-actions">${tryHtml}${toggleHtml}${moreHtml}</div>
        </div>
        ${description ? `<p class="skill-detail-desc">${escapeHtml(description)}</p>` : ""}
        ${invalidHtml}
      </div>
      ${res ? _detailDoc(res) : ""}`;
  }

  function _detailDoc(res) {
    const modeBtn = (mode) => `
      <button type="button" class="ext-row-more skill-detail-mode${_detailMode === mode ? " active" : ""}" data-skill-mode="${mode}" data-tooltip="${escapeHtml(I18n.t("skills.detail." + mode))}">${DETAIL_ICONS[mode]}</button>`;
    const inner = _detailMode === "source"
      ? `<pre class="skill-detail-source">${escapeHtml(res.content || "")}</pre>`
      : `${_frontmatterHtml(res.frontmatter)}<div class="extension-readme-body skill-detail-body">${_markdownHtml((res.fields && res.fields.body) || "")}</div>`;
    return `
      <div class="skill-detail-doc">
        <div class="skill-detail-doc-bar">${modeBtn("preview")}${modeBtn("source")}</div>
        ${inner}
      </div>`;
  }

  function _frontmatterHtml(fm) {
    const keys = Object.keys(fm || {});
    if (keys.length === 0) return "";
    const fmt = (v) => {
      if (v === null || v === undefined) return "";
      if (Array.isArray(v)) return v.map(x => (typeof x === "object" ? JSON.stringify(x) : String(x))).join(", ");
      if (typeof v === "object") return JSON.stringify(v);
      return String(v);
    };
    return `<dl class="skill-detail-meta">${keys.map(k =>
      `<dt>${escapeHtml(k)}</dt><dd>${escapeHtml(fmt(fm[k]))}</dd>`).join("")}</dl>`;
  }

  // Skill bodies come from imported zips, so raw HTML in them is shown as text.
  function _markdownHtml(text) {
    if (!text.trim()) return "";
    if (typeof marked === "undefined") return `<pre style="white-space:pre-wrap">${escapeHtml(text)}</pre>`;
    const renderer = new marked.Renderer();
    renderer.html = ({ text: raw }) => escapeHtml(raw);
    const baseLink = renderer.link.bind(renderer);
    renderer.link = function(token) {
      if (!/^(https?:|mailto:|#|\/|\.)/i.test(token.href || "")) return this.parser.parseInline(token.tokens);
      return baseLink(token).replace(/^<a /, '<a target="_blank" rel="noopener noreferrer" ');
    };
    try {
      return marked.parse(text, { breaks: true, gfm: true, renderer });
    } catch (_) {
      return `<pre style="white-space:pre-wrap">${escapeHtml(text)}</pre>`;
    }
  }

  function _wireDetailBack() {
    const back = $("skill-detail-back");
    if (back) back.addEventListener("click", _backToList);
  }

  function _wireDetail(skill, res) {
    _wireDetailBack();

    const tryBtn = $("skill-detail-try");
    if (tryBtn) tryBtn.addEventListener("click", () => Skills.useInstalledSkill(skill.name));

    const chk = $("skill-detail-enabled");
    if (chk) chk.addEventListener("change", () => Skills.toggle(skill.name, chk.checked));

    const more = $("skill-detail-more");
    if (more) more.addEventListener("click", (e) => {
      e.stopPropagation();
      _toggleMenu(more, _detailMenu(skill));
    });

    _wireDocModes(res);
  }

  function _wireDocModes(res) {
    document.querySelectorAll("#skills-detail [data-skill-mode]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const mode = btn.getAttribute("data-skill-mode");
        if (mode === _detailMode || !res) return;
        _detailMode = mode;
        const doc = document.querySelector("#skills-detail .skill-detail-doc");
        if (doc) doc.outerHTML = _detailDoc(res);
        _wireDocModes(res);
      });
    });
  }

  // ── Tab switching (pure DOM) ─────────────────────────────────────────────

  function _applyTab(tab) {
    document.querySelectorAll(".skills-tab").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.tab === tab);
    });
    const tabMy    = $("skills-tab-my");
    const tabBrand = $("skills-tab-brand");
    if (tabMy)    tabMy.style.display    = tab === "my-skills"    ? "" : "none";
    if (tabBrand) tabBrand.style.display = tab === "brand-skills" ? "" : "none";

    const showSystemLabel = $("label-show-system");
    const refreshBtn      = $("btn-refresh-brand-skills");
    if (showSystemLabel) showSystemLabel.style.display = tab === "my-skills"    ? "" : "none";
    if (refreshBtn)      refreshBtn.style.display      = tab === "brand-skills" ? "" : "none";

    _syncTabStrip();
  }

  // A lone tab has nothing to switch to, so drop the tab affordance entirely.
  function _syncTabStrip() {
    const bar = $("skills-tabs");
    if (!bar) return;
    const visible = Array.from(bar.querySelectorAll(".skills-tab"))
      .filter(btn => btn.style.display !== "none");
    bar.classList.toggle("is-single-tab", visible.length <= 1);
  }

  // ── One-time DOM wiring ──────────────────────────────────────────────────

  function _wireDom() {
    if (_domWired) return;

    _wireSearch();

    document.querySelectorAll(".skills-tab").forEach(btn => {
      btn.addEventListener("click", () => Skills.setActiveTab(btn.dataset.tab));
    });

    const refreshBtn = $("btn-refresh-brand-skills");
    if (refreshBtn) {
      refreshBtn.addEventListener("click", async () => {
        const icon = refreshBtn.querySelector("svg");
        if (icon) icon.classList.add("spinning");
        refreshBtn.disabled = true;
        await Skills.loadBrandSkills();
        if (icon) icon.classList.remove("spinning");
        refreshBtn.disabled = false;
      });
    }

    const chkSystem = $("chk-show-system-skills");
    if (chkSystem) {
      chkSystem.checked = SkillsStore.state.showSystemSkills;
      chkSystem.addEventListener("change", () => Skills.setShowSystemSkills(chkSystem.checked));
    }

    document.addEventListener("langchange", () => {
      _renderMySkills();
      _renderBrandSkills();
      if (_detailName) _renderDetail();
    });

    _domWired = true;
  }

  // ── Store subscriptions ──────────────────────────────────────────────────

  function _subscribe() {
    Skills.on("skills:changed", () => {
      Skills.renderSection();
      if (Router.current === "skills") {
        try { _renderMySkills(); } catch (e) { console.error("[Skills] _renderMySkills failed", e); }
        if (_detailName) _renderDetail();
      }
    });

    Skills.on("brandSkills:loading", _renderBrandLoading);
    Skills.on("brandSkills:error", (p) => {
      _renderBrandError(p);
      if (_detailBrand) _renderDetail();
    });
    Skills.on("brandSkills:changed", (p) => {
      if (p) _applyBrandWarning(p.warning, p.warningCode);
      _renderBrandSkills();
      if (_detailBrand) _renderDetail();
    });

    Skills.on("tab:changed", (p) => { _applyTab(p.tab); _applySearch(); });

    Skills.on("brandStatus:changed", (p) => {
      const brandTab = $("tab-brand-skills");
      if (brandTab) brandTab.style.display = p.branded ? "" : "none";
      _syncTabStrip();
      if (p.activatedChanged && Router.current === "skills") _renderMySkills();
    });
  }

  // ── UI facade methods (called externally on the Skills global) ───────────

  const viewApi = {
    renderSection() {
      const labelEl = $("skills-sidebar-label");
      if (!labelEl) return;
      labelEl.textContent = I18n.t("sidebar.skills");
    },

    onPanelShow(opts = {}) {
      _wireDom();
      _renderMySkills();
      Skills.renderSection();
      _applyTab(SkillsStore.state.activeTab);
      if (SkillsStore.state.activeTab === "brand-skills") Skills.loadBrandSkills();
      Skills.refreshBrandStatus();
      _showDetail(opts.detailName || null, !!opts.brand);
    },

    openBrandSkillsTab() {
      Skills.onPanelShow();
      Skills.setActiveTab("brand-skills");
    },

    toggleImportBar() {
      Skills.setActiveTab("my-skills");

      const bar        = $("skill-import-bar");
      const input      = $("skill-import-input");
      const confirmBtn = $("btn-skill-import-confirm");
      const cancelBtn  = $("btn-skill-import-cancel");
      if (!bar) return;

      const isOpen = bar.style.display !== "none";
      if (isOpen) {
        bar.style.display = "none";
        if (input) input.value = "";
        return;
      }

      bar.style.display = "";
      if (input) {
        input.focus();
        input.placeholder = I18n.t("skills.import.placeholder");
      }

      if (!bar.dataset.wired) {
        bar.dataset.wired = "1";
        confirmBtn.addEventListener("click", () => _doImportFromBar());
        input.addEventListener("keydown", (e) => {
          if (e.key === "Enter") { e.preventDefault(); _doImportFromBar(); }
        });
        cancelBtn.addEventListener("click", () => {
          bar.style.display = "none";
          input.value = "";
        });

        const browseBtn = $("btn-skill-import-browse");
        const fileInput = $("skill-import-file");
        if (browseBtn && fileInput) {
          browseBtn.addEventListener("click", () => fileInput.click());
          fileInput.addEventListener("change", async () => {
            const file = fileInput.files[0];
            if (!file) return;
            input.value = file.name;
            input.placeholder = "";
            browseBtn.disabled = true;
            browseBtn.style.opacity = "0.5";
            try {
              const form = new FormData();
              form.append("file", file);
              const res  = await fetch("/api/upload", { method: "POST", body: form });
              const data = await res.json();
              if (res.ok && data.path) input.value = data.path;
              else { input.value = ""; Modal.toast(data.error || "Upload failed", "error"); }
            } catch (e) {
              input.value = "";
              console.error("[Skills] upload error", e);
            } finally {
              browseBtn.disabled = false;
              browseBtn.style.opacity = "";
              fileInput.value = "";
            }
          });
        }
      }
    },

    resetAfterUnbind() {
      SkillsStore.resetBrandState();
      const panel = $("skills-panel");
      if (panel && panel.style.display !== "none") _applyTab("my-skills");
    },
  };

  async function _editSkill(skill) {
    const res = await Skills.fetchSkillContent(skill.name);
    if (!res.ok) { Modal.toast(I18n.t("skills.editFail") + ": " + res.error, "error"); return; }
    _openSkillFormEditor(skill, res);
  }

  function _openSkillFormEditor(skill, res) {
    const f = res.fields || {};

    let overlay = document.getElementById("skill-editor-overlay");
    if (overlay) overlay.remove();

    overlay = document.createElement("div");
    overlay.id = "skill-editor-overlay";
    overlay.className = "modal-overlay";

    const cancelLabel = I18n.t("modal.cancel");
    const saveLabel   = I18n.t("modal.save");

    overlay.innerHTML = `
      <div class="modal-box skill-editor-box">
        <div class="modal-header">
          <h3 class="modal-title"></h3>
          <button class="modal-close-btn" title="${cancelLabel}"></button>
        </div>
        <div class="modal-body">
          <div class="modal-field">
            <label class="modal-label" for="se-name">${I18n.t("skills.edit.name")}</label>
            <input type="text" id="se-name" class="modal-input skill-editor-name">
            <span class="form-hint">${I18n.t("skills.edit.nameHint")}</span>
          </div>
          <div class="modal-field">
            <label class="modal-label" for="se-name-zh">${I18n.t("skills.edit.nameZh")}</label>
            <input type="text" id="se-name-zh" class="modal-input skill-editor-name-zh">
          </div>
          <div class="modal-field">
            <label class="modal-label" for="se-desc">${I18n.t("skills.edit.description")}</label>
            <textarea id="se-desc" class="modal-input skill-editor-description" rows="2"></textarea>
          </div>
          <div class="modal-field">
            <label class="modal-label" for="se-desc-zh">${I18n.t("skills.edit.descriptionZh")}</label>
            <textarea id="se-desc-zh" class="modal-input skill-editor-description-zh" rows="2"></textarea>
          </div>
          <div class="modal-field">
            <label class="modal-label" for="se-body">${I18n.t("skills.edit.body")}</label>
            <textarea id="se-body" class="modal-input skill-editor-body-input" rows="10"></textarea>
          </div>
        </div>
        <div class="modal-footer">
          <span class="skill-editor-status"></span>
          <button class="btn-secondary skill-editor-cancel">${cancelLabel}</button>
          <button class="btn-secondary skill-editor-markdown">${I18n.t("skills.edit.editMarkdown")}</button>
          <button class="btn-primary skill-editor-save">${saveLabel}</button>
        </div>
      </div>`;

    document.body.appendChild(overlay);
    overlay.querySelector(".modal-title").textContent = I18n.t("skills.edit.title") + ": " + skill.name;

    const nameInput   = overlay.querySelector(".skill-editor-name");
    const nameZhInput = overlay.querySelector(".skill-editor-name-zh");
    const descInput   = overlay.querySelector(".skill-editor-description");
    const descZhInput = overlay.querySelector(".skill-editor-description-zh");
    const bodyInput   = overlay.querySelector(".skill-editor-body-input");
    const status      = overlay.querySelector(".skill-editor-status");
    const closeBtn    = overlay.querySelector(".modal-close-btn");
    const cancelBtn   = overlay.querySelector(".skill-editor-cancel");
    const markdownBtn = overlay.querySelector(".skill-editor-markdown");
    const saveBtn     = overlay.querySelector(".skill-editor-save");

    nameInput.value   = f.name || skill.name || "";
    nameZhInput.value = f.name_zh || "";
    descInput.value   = f.description || "";
    descZhInput.value = f.description_zh || "";
    bodyInput.value   = f.body || "";

    // Auto-grow textareas so the modal body is the only scroll container.
    [descInput, descZhInput, bodyInput].forEach((ta) => {
      const autoResize = () => {
        ta.style.height = "auto";
        ta.style.height = ta.scrollHeight + "px";
      };
      ta.addEventListener("input", autoResize);
      autoResize();
    });

    function close() {
      overlay.remove();
    }

    closeBtn.addEventListener("click", close);
    cancelBtn.addEventListener("click", close);

    markdownBtn.addEventListener("click", () => {
      close();
      CodeEditor.open({
        content: res.content,
        title: skill.name,
        language: "markdown",
        onSave: async (newContent) => {
          const r = await Skills.updateSkillContent(skill.name, newContent);
          if (!r.ok) throw new Error(r.error);
        }
      });
    });

    saveBtn.addEventListener("click", async () => {
      const name = nameInput.value.trim();
      if (!name) {
        nameInput.classList.add("input-error");
        nameInput.focus();
        return;
      }

      const fields = {
        name:           name,
        name_zh:        nameZhInput.value.trim(),
        description:    descInput.value.trim(),
        description_zh: descZhInput.value.trim(),
        body:           bodyInput.value
      };

      saveBtn.disabled = true;
      status.textContent = I18n.t("modal.saving");
      status.className = "skill-editor-status";
      const r = await Skills.updateSkillFields(skill.name, fields);
      if (r.ok) { close(); return; }

      status.textContent = I18n.t("skills.edit.saveFail") + (r.error ? ": " + r.error : "");
      status.className = "skill-editor-status skill-editor-status-error";
      saveBtn.disabled = false;
    });

    setTimeout(() => nameInput.focus(), 50);
  }

  async function _doImportFromBar() {
    const input = $("skill-import-input");
    const bar   = $("skill-import-bar");
    const url   = (input ? input.value : "").trim();

    const result = await Skills.importSkill(url);
    if (result.ok) {
      if (bar) bar.style.display = "none";
      if (input) input.value = "";
      return;
    }
    if (result.reason === "empty") {
      input && input.focus();
      return;
    }
    if (result.reason === "invalid") {
      input.classList.add("skill-import-input-error");
      setTimeout(() => input.classList.remove("skill-import-input-error"), 1200);
      input.focus();
      return;
    }
    Modal.toast(I18n.lang() === "zh" ? "导入技能时网络错误。" : "Network error while importing skill.", "error");
  }

  return { init: _subscribe, api: viewApi, _doImportFromBar };
})();

// Augment the Skills facade with view-owned UI methods, then wire subscriptions.
Object.assign(Skills, SkillsView.api);
Skills._doImportFromBar = SkillsView._doImportFromBar;
SkillsView.init();
