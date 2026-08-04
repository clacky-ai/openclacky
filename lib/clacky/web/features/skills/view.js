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
    const activeTab = SkillsStore.state.activeTab;

    if (activeTab === "my-skills") {
      const list = $("skills-list");
      if (!list) return;
      list.querySelectorAll(".skill-card").forEach(card => {
        card.style.display = (!q || card.textContent.toLowerCase().includes(q)) ? "" : "none";
      });
      let noResult = list.querySelector(".skills-search-empty");
      const anyVisible = [...list.querySelectorAll(".skill-card")].some(c => c.style.display !== "none");
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
    } else {
      const list = $("brand-skills-list");
      if (!list) return;
      list.querySelectorAll(".brand-skill-card").forEach(card => {
        card.style.display = (!q || card.textContent.toLowerCase().includes(q)) ? "" : "none";
      });
      let noResult = list.querySelector(".skills-search-empty");
      const anyVisible = [...list.querySelectorAll(".brand-skill-card")].some(c => c.style.display !== "none");
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

  // ── My Skills rendering ──────────────────────────────────────────────────

  function _renderMySkills() {
    const container = $("skills-list");
    if (!container) { console.error("[Skills] skills-list not found!"); return; }
    container.innerHTML = "";

    const skills = SkillsStore.state.skills;
    const visible = SkillsStore.state.showSystemSkills
      ? skills
      : skills.filter(s => s.always_show || s.source !== "default");

    if (visible.length === 0) {
      container.appendChild(_renderEmptyState());
      return;
    }

    const sorted = [
      ...visible.filter(s => s.source === "default"),
      ...visible.filter(s => s.source !== "default")
    ];
    sorted.forEach((skill, i) => {
      try {
        container.appendChild(_renderSkillCard(skill));
      } catch (e) {
        console.error("[Skills] _renderSkillCard failed for skill", i, skill.name, e);
      }
    });
    _applySearch();
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

  function _renderSkillCard(skill) {
    const card = document.createElement("div");
    card.className = "skill-card" + (skill.invalid ? " skill-card-invalid" : "");

    const isSystem   = skill.source === "default" || skill.source === "brand";
    const badgeClass = isSystem ? "skill-badge skill-badge-system" : "skill-badge skill-badge-custom";
    const badgeLabel = isSystem ? I18n.t("skills.badge.system") : I18n.t("skills.badge.custom");

    let warnIconHtml = "";
    let errorNoticeHtml = "";
    if (skill.invalid) {
      const reason = skill.invalid_reason || I18n.t("skills.invalid.reason");
      errorNoticeHtml = `<div class="skill-notice skill-notice-error">⚠ ${escapeHtml(reason)}</div>`;
    } else if (skill.warnings && skill.warnings.length > 0) {
      const reason    = skill.warnings.join("\n");
      const tooltip   = I18n.t("skills.warning.tooltip", { reason });
      warnIconHtml = `<span class="skill-warn-icon" data-tooltip="${escapeHtml(tooltip)}">⚠</span>`;
    }

    const toggleDisabled = isSystem || skill.invalid;
    const toggleTitle    = isSystem      ? I18n.t("skills.systemDisabledTip")
                         : skill.invalid  ? I18n.t("skills.invalid.toggleTip")
                         : skill.enabled   ? I18n.t("skills.toggle.disableDesc")
                         : I18n.t("skills.toggle.enableDesc");

    const currentLang = I18n.lang();
    const description = (currentLang === "zh" && skill.description_zh)
                        ? skill.description_zh
                        : skill.description || "";

    const useButtonHtml = skill.invalid
      ? ""
      : `<button class="btn-skill-use" data-name="${escapeHtml(skill.name)}">${I18n.t("skills.btn.use")}</button>`;

    const deleteButtonHtml = isSystem
      ? ""
      : `<button class="btn-skill-delete" data-name="${escapeHtml(skill.name)}" title="${I18n.t("skills.btn.delete")}">
           <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
             <polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/>
           </svg>
         </button>`;

    const editButtonHtml = isSystem
      ? ""
      : `<button class="btn-skill-edit" data-name="${escapeHtml(skill.name)}" title="${I18n.t("skills.btn.edit")}">
           <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
             <path d="M12 20h9"/>
             <path d="M16.5 3.5a2.121 2.121 0 1 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/>
           </svg>
         </button>`;

    card.innerHTML = `
      <div class="skill-card-main">
        <div class="skill-card-info">
          <div class="skill-card-title">
            ${warnIconHtml}
            <span class="skill-name">${escapeHtml((currentLang === "zh" && skill.name_zh) ? skill.name_zh : skill.name)}</span>
            <span class="${badgeClass}">${badgeLabel}</span>
            ${skill.invalid ? `<span class="skill-badge skill-badge-invalid">${I18n.t("skills.badge.invalid")}</span>` : ""}
          </div>
          <div class="skill-card-desc" data-tooltip="${escapeHtml(description)}" data-tooltip-pos="top" data-tooltip-overflow>${escapeHtml(description)}</div>
        </div>
        <div class="skill-card-actions">
          <label class="skill-toggle ${toggleDisabled ? "skill-toggle-disabled" : ""}" data-tooltip="${escapeHtml(toggleTitle)}">
            <input type="checkbox" class="skill-toggle-input" ${skill.enabled ? "checked" : ""} ${toggleDisabled ? "disabled" : ""}>
            <span class="skill-toggle-track"></span>
          </label>
          ${useButtonHtml}
          ${editButtonHtml}
          ${deleteButtonHtml}
        </div>
      </div>
      ${errorNoticeHtml}`;

    if (!isSystem) {
      const checkbox = card.querySelector(".skill-toggle-input");
      checkbox.addEventListener("change", () => Skills.toggle(skill.name, checkbox.checked));
    }

    const toggleLabel = card.querySelector(".skill-toggle");
    if (toggleLabel) {
      toggleLabel.addEventListener("mouseenter", () => {
        const scroller = toggleLabel.closest(".skills-tab-content");
        if (!scroller) return;
        const toggleTop   = toggleLabel.getBoundingClientRect().top;
        const scrollerTop = scroller.getBoundingClientRect().top;
        if (toggleTop - scrollerTop < 80) {
          toggleLabel.setAttribute("data-tooltip-pos", "bottom");
        }
      });
    }

    const useBtn = card.querySelector(".btn-skill-use");
    if (useBtn) useBtn.addEventListener("click", () => Skills.useInstalledSkill(skill.name));

    const editBtn = card.querySelector(".btn-skill-edit");
    if (editBtn) editBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      _editSkill(skill);
    });

    const deleteBtn = card.querySelector(".btn-skill-delete");
    if (deleteBtn) deleteBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      Skills.delete(skill.name);
    });

    return card;
  }

  // ── Brand Skills rendering ───────────────────────────────────────────────

  function _renderBrandLoading() {
    const container = $("brand-skills-list");
    if (!container) return;
    container.innerHTML = Array.from({ length: 4 }).map(() => `
      <div class="brand-skill-card">
        <div class="brand-skill-card-main">
          <div class="brand-skill-info">
            <div class="brand-skill-title">
              <span class="skel skel-title"></span>
              <span class="skel" style="height:1rem;width:3.5rem;border-radius:4px;"></span>
            </div>
            <span class="skel skel-subtitle"></span>
          </div>
          <div class="brand-skill-actions">
            <span class="skel" style="height:1.75rem;width:4.5rem;border-radius:6px;"></span>
          </div>
        </div>
      </div>`).join("");
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
    container.innerHTML = "";

    const brandSkills     = SkillsStore.state.brandSkills;
    const freeMode        = SkillsStore.state.freeMode;
    const paidSkillsCount = SkillsStore.state.paidSkillsCount;

    if (brandSkills.length === 0 && !(freeMode && paidSkillsCount > 0)) {
      container.innerHTML = `<div class="brand-skills-empty">${I18n.t("skills.brand.empty")}</div>`;
      return;
    }

    brandSkills.forEach(skill => container.appendChild(_renderBrandSkillCard(skill)));

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

  function _renderBrandSkillCard(skill) {
    const name             = skill.name;
    const installedVersion = skill.installed_version;
    const latestVersion    = (skill.latest_version || {}).version || skill.version;
    const needsUpdate      = skill.needs_update;

    let statusHtml = "";
    if (!installedVersion) {
      const versionBadge = latestVersion
        ? `<span class="brand-skill-version latest">v${escapeHtml(latestVersion)}</span>` : "";
      statusHtml = `${versionBadge}<button class="btn-brand-install" data-name="${escapeHtml(name)}">${I18n.t("skills.brand.btn.install")}</button>`;
    } else if (needsUpdate) {
      statusHtml = `
        <span class="brand-skill-version installed">v${escapeHtml(installedVersion)}</span>
        <span class="brand-skill-update-arrow">→</span>
        <span class="brand-skill-version latest">v${escapeHtml(latestVersion)}</span>
        <button class="btn-brand-update" data-name="${escapeHtml(name)}">${I18n.t("skills.brand.btn.update")}</button>`;
    } else {
      const displayVersion = installedVersion || latestVersion;
      statusHtml = `
        <span class="brand-skill-version installed">v${escapeHtml(displayVersion)} ✓</span>
        <button class="btn-brand-use" data-name="${escapeHtml(name)}">${I18n.t("skills.brand.btn.use")}</button>
        <button class="btn-skill-delete btn-brand-delete" data-name="${escapeHtml(name)}" title="${I18n.t("skills.btn.delete")}">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/>
          </svg>
        </button>`;
    }

    const badge = skill.is_free
      ? `<span class="brand-skill-badge-free" title="${I18n.t("skills.brand.freeTip")}">✨ ${I18n.t("skills.brand.free")}</span>`
      : `<span class="brand-skill-badge-private" title="${I18n.t("skills.brand.privateTip")}">🔒 ${I18n.t("skills.brand.private")}</span>`;

    const currentLang = I18n.lang();
    const description = (currentLang === "zh" && skill.description_zh)
                        ? skill.description_zh
                        : skill.description || "";

    const card = document.createElement("div");
    card.className = "brand-skill-card";
    card.innerHTML = `
      <div class="brand-skill-card-main">
        <div class="brand-skill-info">
          <div class="brand-skill-title">
            <span class="brand-skill-name">${escapeHtml((currentLang === "zh" && skill.name_zh) ? skill.name_zh : name)}</span>
            ${badge}
          </div>
          <div class="brand-skill-desc">${escapeHtml(description)}</div>
        </div>
        <div class="brand-skill-actions">${statusHtml}</div>
      </div>`;

    const installBtn = card.querySelector(".btn-brand-install");
    const updateBtn  = card.querySelector(".btn-brand-update");
    const useBtn     = card.querySelector(".btn-brand-use");
    const deleteBtn  = card.querySelector(".btn-brand-delete");
    if (installBtn) installBtn.addEventListener("click", () => _runBrandInstall(name, installBtn));
    if (updateBtn)  updateBtn.addEventListener("click",  () => _runBrandInstall(name, updateBtn));
    if (useBtn)     useBtn.addEventListener("click",     () => Skills.useInstalledSkill(name));
    if (deleteBtn)  deleteBtn.addEventListener("click",  (e) => { e.stopPropagation(); Skills.deleteBrandSkill(name); });

    return card;
  }

  async function _runBrandInstall(name, btn) {
    const originalText = btn.textContent;
    btn.disabled    = true;
    btn.textContent = I18n.t("skills.brand.btn.installing");
    const result = await Skills.installBrandSkill(name);
    if (!result || !result.ok) {
      _showBrandInstallError(btn, (result && result.message) || I18n.t("skills.brand.unknownError"));
      btn.disabled    = false;
      btn.textContent = originalText;
    }
    // On success the store emits brandSkills:changed → the tab re-renders,
    // replacing this button.
  }

  function _showBrandInstallError(btn, message) {
    const existing = btn.parentElement.querySelector(".brand-install-error");
    if (existing) existing.remove();
    const tip = document.createElement("div");
    tip.className   = "brand-install-error";
    tip.textContent = message;
    btn.parentElement.appendChild(tip);
    setTimeout(() => tip.remove(), 5000);
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
    });

    _domWired = true;
  }

  // ── Store subscriptions ──────────────────────────────────────────────────

  function _subscribe() {
    Skills.on("skills:changed", () => {
      Skills.renderSection();
      if (Router.current === "skills") {
        try { _renderMySkills(); } catch (e) { console.error("[Skills] _renderMySkills failed", e); }
      }
    });

    Skills.on("brandSkills:loading", _renderBrandLoading);
    Skills.on("brandSkills:error",   _renderBrandError);
    Skills.on("brandSkills:changed", (p) => {
      if (p) _applyBrandWarning(p.warning, p.warningCode);
      _renderBrandSkills();
    });

    Skills.on("tab:changed", (p) => { _applyTab(p.tab); _applySearch(); });

    Skills.on("brandStatus:changed", (p) => {
      const brandTab = $("tab-brand-skills");
      if (brandTab) brandTab.style.display = p.branded ? "" : "none";
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

    onPanelShow() {
      _wireDom();
      _renderMySkills();
      Skills.renderSection();
      _applyTab(SkillsStore.state.activeTab);
      if (SkillsStore.state.activeTab === "brand-skills") Skills.loadBrandSkills();
      Skills.refreshBrandStatus();
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
              else { input.value = ""; alert(data.error || "Upload failed"); }
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
    if (!res.ok) { alert(I18n.t("skills.editFail") + ": " + res.error); return; }

    CodeEditor.open({
      content: res.content,
      title: skill.name,
      language: "markdown",
      onSave: async (newContent) => {
        const r = await Skills.updateSkillContent(skill.name, newContent);
        if (!r.ok) throw new Error(r.error);
      }
    });
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
    alert(I18n.lang() === "zh" ? "导入技能时网络错误。" : "Network error while importing skill.");
  }

  return { init: _subscribe, api: viewApi, _doImportFromBar };
})();

// Augment the Skills facade with view-owned UI methods, then wire subscriptions.
Object.assign(Skills, SkillsView.api);
Skills._doImportFromBar = SkillsView._doImportFromBar;
SkillsView.init();
