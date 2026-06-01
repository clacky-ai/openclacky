// settings.js — Settings panel logic
// Handles reading, editing, saving, testing AI model configurations.

const Settings = (() => {
  // Local copy of models loaded from server
  let _models = [];
  // Provider presets loaded from server
  let _providers = [];
  // Provider id selected in the model edit modal (null when "Custom" or unset).
  // Used to opt the request into anthropic_format=true when the user picks
  // the Anthropic provider; other providers leave the flag unset and let the
  // backend's runtime inference decide.
  let _modalSelectedProviderId = null;

  // ── Public API ──────────────────────────────────────────────────────────────

  function open() {
    _load();
    _loadMedia();
    _loadBrand();
    _loadBrowserStatus();
    _applyAboutTabVisibility();
  }

  // ── Data Loading ────────────────────────────────────────────────────────────

  async function _load() {
    const container = document.getElementById("model-cards");
    container.innerHTML = `<div class="settings-loading">${I18n.t("settings.models.loading")}</div>`;
    try {
      // Load config and providers in parallel
      const [configRes, providerRes] = await Promise.all([
        fetch("/api/config"),
        fetch("/api/providers")
      ]);
      const configData   = await configRes.json();
      const providerData = await providerRes.json();
      _models    = configData.models   || [];
      _providers = providerData.providers || [];
      _renderCards();
    } catch (e) {
      container.innerHTML = `<div class="settings-error">${I18n.t("settings.models.error", { msg: e.message })}</div>`;
    }
  }

  // ── Rendering ───────────────────────────────────────────────────────────────

  function _renderCards() {
    const container = document.getElementById("model-cards");
    container.innerHTML = "";

    if (_models.length === 0) {
      container.innerHTML = `<div class="settings-empty">${I18n.t("settings.models.empty")}</div>`;
      return;
    }

    _models.forEach((m, i) => _renderCard(container, m, i));
  }

  function _getProviderName(model) {
    const p = _findProviderByBaseUrl(model.base_url);
    return p ? p.name : I18n.t("settings.models.provider.custom");
  }

  function _findProviderByBaseUrl(baseUrl) {
    if (!baseUrl) return null;
    const url = String(baseUrl).trim().replace(/\/+$/, "");
    return _providers.find(p => {
      const candidates = [p.base_url].concat(
        Array.isArray(p.endpoint_variants) ? p.endpoint_variants.map(v => v.base_url) : []
      ).filter(Boolean);
      return candidates.some(c => {
        const norm = String(c).replace(/\/+$/, "");
        return url === norm || url.startsWith(norm + "/");
      });
    }) || null;
  }

  function _renderCard(container, model, index) {
    const isDefault = model.type === "default";
    const isLite    = model.type === "lite";
    const provider  = _findProviderByBaseUrl(model.base_url);
    const providerName = provider ? provider.name : I18n.t("settings.models.provider.custom");
    const websiteUrl   = provider && provider.website_url;
    const displayName = model.model || I18n.t("settings.models.unnamed");

    const card = document.createElement("div");
    card.className = "model-card-grid" + (isDefault ? " model-card-grid-default" : "");
    card.dataset.index = index;

    card.innerHTML = `
      <div class="model-card-grid-info">
        <div class="model-card-grid-name-row">
          <span class="model-card-grid-name">${_esc(displayName)}</span>
          ${isDefault ? `<span class="badge badge-default">${I18n.t("settings.models.badge.default")}</span>` : ""}
          ${isLite ? `<span class="badge badge-lite">${I18n.t("settings.models.badge.lite")}</span>` : ""}
        </div>
        <div class="model-card-grid-provider">${_esc(providerName)}</div>
        ${model.api_key_masked ? `<div class="model-card-grid-model">${_esc(model.api_key_masked)}</div>` : ""}
        <div class="model-card-grid-status">
          <span class="model-test-result" data-index="${index}"></span>
        </div>
      </div>
      <div class="model-card-grid-actions">
        ${!isDefault ? `<button class="btn-card-grid-action btn-card-grid-action-primary" data-index="${index}" data-action="default">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z"/></svg>
          <span>${I18n.t("settings.models.btn.setDefault")}</span>
        </button>` : ""}
        <div class="model-card-grid-toolbar">
          <button class="btn-card-grid-action" data-index="${index}" data-action="test">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>
            <span>${I18n.t("settings.models.btn.test")}</span>
          </button>
          <button class="btn-card-grid-action" data-index="${index}" data-action="edit">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>
            <span>${I18n.t("settings.models.btn.edit")}</span>
          </button>
          ${_models.length > 1 ? `<button class="btn-card-grid-action btn-card-grid-action-danger" data-index="${index}" data-action="delete">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>
            <span>${I18n.t("settings.models.btn.delete")}</span>
          </button>` : ""}
        </div>
      </div>
      ${websiteUrl ? `<div class="model-card-grid-footer">
        <a class="model-card-grid-link" href="${_esc(websiteUrl)}" target="_blank" rel="noopener noreferrer">
          ${I18n.t("settings.models.link.topUp")}
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 17L17 7"/><path d="M8 7h9v9"/></svg>
        </a>
      </div>` : ""}
    `;

    container.appendChild(card);
    _bindCompactCardEvents(card, index);
  }

  function _bindCompactCardEvents(card, index) {
    card.querySelectorAll("[data-action]").forEach(btn => {
      btn.addEventListener("click", () => {
        const action = btn.dataset.action;
        switch (action) {
          case "edit":    _openModal(index); break;
          case "test":    _testModel(index); break;
          case "delete":  _removeModel(index); break;
          case "default": _setAsDefault(index); break;
        }
      });
    });
  }

  // ── Modal Functions ────────────────────────────────────────────────────────

  function _openModal(index = -1) {
    const modal = document.getElementById("model-edit-modal");
    const titleEl = document.getElementById("model-modal-title");
    const indexInput = document.getElementById("model-modal-index");

    indexInput.value = index;

    // Populate provider dropdown
    _populateModalProviderDropdown();

    if (index >= 0 && _models[index]) {
      // Edit mode
      const model = _models[index];
      titleEl.textContent = I18n.t("settings.models.modal.edit");
      document.getElementById("model-modal-model").value = model.model || "";
      document.getElementById("model-modal-baseurl").value = model.base_url || "";
      document.getElementById("model-modal-apikey").value = model.api_key_masked || "";
      document.getElementById("model-modal-default-field").style.display = "";
      document.getElementById("model-modal-set-default").checked = (model.type === "default");

      // Set provider dropdown value
      const matched = _findProviderByBaseUrl(model.base_url);
      // Preserve an explicit anthropic_format=true even if base_url is custom:
      // the user may have configured a self-hosted Anthropic-compatible proxy.
      _modalSelectedProviderId = matched ? matched.id : (model.anthropic_format ? "anthropic" : null);
      const providerName = matched ? matched.name : I18n.t("settings.models.provider.custom");
      const providerValue = document.getElementById("model-modal-provider-value");
      providerValue.textContent = providerName;
      providerValue.classList.remove("placeholder");
    } else {
      // Add mode
      titleEl.textContent = I18n.t("settings.models.modal.add");
      document.getElementById("model-modal-model").value = "";
      document.getElementById("model-modal-baseurl").value = "";
      document.getElementById("model-modal-apikey").value = "";
      document.getElementById("model-modal-default-field").style.display = "";
      // Default to checked for new models — most users want their first/new
      // model to take over as the default.
      document.getElementById("model-modal-set-default").checked = true;

      // Reset provider dropdown
      _modalSelectedProviderId = null;
      const providerValue = document.getElementById("model-modal-provider-value");
      providerValue.textContent = I18n.t("settings.models.placeholder.provider");
      providerValue.classList.add("placeholder");
    }

    // Reset save button
    const saveBtn = document.getElementById("model-modal-save");
    saveBtn.textContent = I18n.t("settings.models.btn.save");
    saveBtn.disabled = false;

    // Clear test result
    document.getElementById("model-modal-test-result").textContent = "";
    document.getElementById("model-modal-test-result").className = "model-test-result";

    // Show promo hint by default for new models
    const promoHint = document.getElementById("model-modal-promo-hint");
    _showPromoHint(promoHint);

    modal.style.display = "";
    document.body.style.overflow = "hidden";
    document.getElementById("model-modal-provider-trigger").focus();
  }

  function _closeModal() {
    const modal = document.getElementById("model-edit-modal");
    modal.style.display = "none";
    document.body.style.overflow = "";
  }

  function _populateModalProviderDropdown() {
    const dropdown = document.getElementById("model-modal-provider-dropdown");
    dropdown.innerHTML = `
      <div class="custom-select-option" data-value="">${I18n.t("settings.models.placeholder.provider")}</div>
      ${_providers.map(p => `<div class="custom-select-option" data-value="${p.id}" data-label="${_esc(p.name)}">${_esc(p.name)}${p.id === "openclacky" ? ` <span class="provider-badge-recommended">${I18n.t("provider.recommended")}</span>` : ""}</div>`).join("")}
      <div class="custom-select-option" data-value="custom">${I18n.t("settings.models.custom")}</div>
    `;

    // Bind click events for options
    dropdown.querySelectorAll(".custom-select-option").forEach(option => {
      option.addEventListener("click", (e) => {
        e.stopPropagation();
        const value = option.dataset.value;
        const text = option.dataset.label || option.textContent.trim();

        // Track the picked provider so test/save can flag anthropic_format=true
        // when the user explicitly picks Anthropic. Empty / "custom" → null.
        _modalSelectedProviderId = (value && value !== "custom") ? value : null;

        const providerValue = document.getElementById("model-modal-provider-value");
        providerValue.textContent = text;
        providerValue.classList.toggle("placeholder", !value);

        dropdown.classList.remove("open");
        document.getElementById("model-modal-provider-trigger").classList.remove("open");

        // Show/hide promo hint
        const promoHint = document.getElementById("model-modal-promo-hint");
        if (value === "openclacky" || !value) {
          _showPromoHint(promoHint);
        } else {
          promoHint.classList.remove("visible");
        }

        // Auto-fill if provider selected
        if (value && value !== "custom") {
          const preset = _providers.find(p => p.id === value);
          if (preset) {
            document.getElementById("model-modal-model").value = preset.default_model || "";
            document.getElementById("model-modal-baseurl").value = preset.base_url || "";

            const apikeyLink = document.getElementById("model-modal-apikey-link");
            if (preset.website_url) {
              apikeyLink.href = preset.website_url;
              apikeyLink.style.display = "";
            } else {
              apikeyLink.style.display = "none";
            }

            // Update model dropdown with provider's models
            setTimeout(() => _updateModalModelDropdown(), 0);
          }
        }
      });
    });
  }

  async function _testModel(index) {
    const model = _models[index];
    if (!model) return;

    const testBtn = document.querySelector(`.btn-test-model[data-index="${index}"]`);
    if (testBtn) testBtn.disabled = true;

    _showTestResult(index, null, "");

    try {
      const result = await ModelTester.testConnection({
        model:    model.model,
        base_url: model.base_url,
        api_key:  model.api_key_masked,
        index,
        anthropic_format: model.anthropic_format
      });
      _showTestResult(index, result.ok, result.message);
    } finally {
      if (testBtn) testBtn.disabled = false;
    }
  }

  async function _saveModalModel() {
    const saveBtn = document.getElementById("model-modal-save");
    const index = parseInt(document.getElementById("model-modal-index").value, 10);

    const model = document.getElementById("model-modal-model").value.trim();
    let base_url = document.getElementById("model-modal-baseurl").value.trim();
    const api_key = document.getElementById("model-modal-apikey").value.trim();

    saveBtn.disabled = true;

    // Anthropic protocol is opted in only when the user picks the Anthropic
    // provider in the modal. Other providers leave the flag absent so the
    // backend's runtime inference (provider preset + model api overrides)
    // decides — preserving e.g. OpenRouter's per-model anthropic-messages
    // routing for Claude sub-models.
    const anthropic_format = _modalSelectedProviderId === "anthropic";

    // Step 1: Test first
    saveBtn.textContent = I18n.t("settings.models.btn.testing");
    _showModalTestResult(null, "");

    const result = await ModelTester.testConnection({
      model, base_url, api_key, index, anthropic_format
    });

    if (result.rewrote) {
      base_url = result.base_url;
      const baseInput = document.getElementById("model-modal-baseurl");
      if (baseInput) baseInput.value = base_url;
    }

    _showModalTestResult(result.ok, result.message);

    if (!result.ok) {
      saveBtn.textContent = I18n.t("settings.models.btn.save");
      saveBtn.disabled = false;
      return;
    }

    // Step 2: Save
    saveBtn.textContent = I18n.t("settings.models.btn.saving");

    const isNew = index < 0;
    const existing = isNew ? {} : (_models[index] || {});
    const hasId = !!existing.id;

    const payload = { model, base_url, anthropic_format };
    const setDefault = document.getElementById("model-modal-set-default").checked;
    payload.type = setDefault ? "default" : null;
    if (setDefault) {
      _models.forEach((m, i) => {
        if (i !== index && m.type === "default") m.type = null;
      });
    }

    if (api_key && !api_key.includes("****")) {
      payload.api_key = api_key;
    }

    if (!hasId && !payload.api_key) {
      saveBtn.textContent = I18n.t("settings.models.btn.save");
      saveBtn.disabled = false;
      _showModalTestResult(false, I18n.t("settings.models.placeholder.apikey"));
      return;
    }

    const saveResult = await ModelTester.saveModel(payload, { existingId: hasId ? existing.id : null });

    if (saveResult.ok) {
      saveBtn.textContent = I18n.t("settings.models.btn.saved");
      setTimeout(() => {
        _closeModal();
        _load();
        _loadMedia();
      }, 800);
    } else {
      saveBtn.textContent = I18n.t("settings.models.btn.save");
      saveBtn.disabled = false;
      _showModalTestResult(false, saveResult.error || I18n.t("settings.models.saveFailed"));
    }
  }

  function _showModalTestResult(ok, message) {
    const el = document.getElementById("model-modal-test-result");
    if (!el) return;
    if (ok === null) { el.textContent = I18n.t("settings.models.btn.testing"); el.className = "model-test-result result-testing"; return; }
    el.textContent = ok ? `✓ ${message || I18n.t("settings.models.connected")}` : `✗ ${I18n.t("settings.models.testFail")}: ${message || I18n.t("settings.models.failed")}`;
    el.className = `model-test-result ${ok ? "result-ok" : "result-fail"}`;
  }

  function _initModal() {
    // Close button
    document.getElementById("model-modal-close").addEventListener("click", _closeModal);
    document.getElementById("model-modal-cancel").addEventListener("click", _closeModal);

    // Save button
    document.getElementById("model-modal-save").addEventListener("click", _saveModalModel);

    // Click overlay to close
    document.getElementById("model-edit-modal").addEventListener("click", (e) => {
      if (e.target.id === "model-edit-modal") _closeModal();
    });

    // ESC to close
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && document.getElementById("model-edit-modal").style.display !== "none") {
        _closeModal();
      }
    });

    // Provider dropdown toggle
    const providerTrigger = document.getElementById("model-modal-provider-trigger");
    const providerDropdown = document.getElementById("model-modal-provider-dropdown");
    providerTrigger.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = providerDropdown.classList.contains("open");
      document.querySelectorAll(".custom-select-dropdown.open").forEach(d => {
        d.classList.remove("open");
      });
      if (!isOpen) {
        providerDropdown.classList.add("open");
        providerTrigger.classList.add("open");
      } else {
        providerDropdown.classList.remove("open");
        providerTrigger.classList.remove("open");
      }
    });

    // Close dropdowns on outside click
    document.addEventListener("click", () => {
      providerDropdown.classList.remove("open");
      providerTrigger.classList.remove("open");
    });

    // Toggle API key visibility
    document.getElementById("model-modal-toggle-key").addEventListener("click", () => {
      const input = document.getElementById("model-modal-apikey");
      input.type = input.type === "password" ? "text" : "password";
    });

    // Model dropdown functionality
    const modelDropdownBtn = document.getElementById("model-modal-model-dropdown-btn");
    const modelDropdown = document.getElementById("model-modal-model-dropdown");
    const modelInput = document.getElementById("model-modal-model");

    modelDropdownBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = modelDropdown.style.display === "block";
      document.querySelectorAll(".model-name-dropdown, .base-url-dropdown").forEach(d => {
        d.style.display = "none";
      });
      if (!isOpen) {
        _updateModalModelDropdown();
        modelDropdown.style.display = "block";
      }
    });

    // Base URL dropdown functionality
    const baseUrlDropdownBtn = document.getElementById("model-modal-baseurl-dropdown-btn");
    const baseUrlDropdown = document.getElementById("model-modal-baseurl-dropdown");
    const baseUrlInput = document.getElementById("model-modal-baseurl");

    baseUrlDropdownBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = baseUrlDropdown.style.display === "block";
      document.querySelectorAll(".model-name-dropdown, .base-url-dropdown").forEach(d => {
        d.style.display = "none";
      });
      if (!isOpen) {
        _updateModalBaseUrlDropdown();
        baseUrlDropdown.style.display = "block";
      }
    });

    // Update model dropdown when base_url changes
    baseUrlInput.addEventListener("blur", () => {
      _updateModalModelDropdown();
    });

    // Close all modal dropdowns on document click
    document.addEventListener("click", () => {
      modelDropdown.style.display = "none";
      baseUrlDropdown.style.display = "none";
    });
  }

  function _getModalCurrentProvider() {
    const baseUrlInput = document.getElementById("model-modal-baseurl");
    const url = (baseUrlInput?.value || "").trim().replace(/\/+$/, "");
    if (!url) return null;
    return _providers.find(p => {
      const candidates = [p.base_url].concat(
        Array.isArray(p.endpoint_variants) ? p.endpoint_variants.map(v => v.base_url) : []
      ).filter(Boolean);
      return candidates.some(c => {
        const norm = String(c).replace(/\/+$/, "");
        return url === norm || url.startsWith(norm + "/");
      });
    }) || null;
  }

  function _updateModalModelDropdown() {
    const modelDropdown = document.getElementById("model-modal-model-dropdown");
    const modelInput = document.getElementById("model-modal-model");
    const provider = _getModalCurrentProvider();
    const models = provider?.models || [];

    if (models.length === 0) {
      modelDropdown.innerHTML = `<div class="model-dropdown-empty">${I18n.t("settings.models.noModels") || "No preset models available"}</div>`;
      return;
    }

    modelDropdown.innerHTML = models.map(m =>
      `<div class="model-dropdown-option" data-value="${_esc(m)}">${_esc(m)}</div>`
    ).join("");

    modelDropdown.querySelectorAll(".model-dropdown-option").forEach(opt => {
      opt.addEventListener("click", (e) => {
        e.stopPropagation();
        modelInput.value = opt.dataset.value;
        modelDropdown.style.display = "none";
      });
    });
  }

  function _updateModalBaseUrlDropdown() {
    const baseUrlDropdown = document.getElementById("model-modal-baseurl-dropdown");
    const baseUrlInput = document.getElementById("model-modal-baseurl");
    const provider = _getModalCurrentProvider();
    const variants = provider && Array.isArray(provider.endpoint_variants) ? provider.endpoint_variants : [];

    if (variants.length === 0) {
      baseUrlDropdown.innerHTML = `<div class="model-dropdown-empty">${I18n.t("settings.models.baseurl.noVariants")}</div>`;
      return;
    }

    baseUrlDropdown.innerHTML = variants.map(v => {
      const translated = v.label_key ? I18n.t(v.label_key) : null;
      const labelText = (translated && translated !== v.label_key) ? translated : (v.label || v.base_url);
      const label = _esc(labelText);
      const url = _esc(v.base_url);
      return `
        <div class="model-dropdown-option base-url-dropdown-option" data-value="${url}">
          <div class="base-url-dropdown-label">${label}</div>
          <div class="base-url-dropdown-url">${url}</div>
        </div>`;
    }).join("");

    baseUrlDropdown.querySelectorAll(".base-url-dropdown-option").forEach(opt => {
      opt.addEventListener("click", (e) => {
        e.stopPropagation();
        baseUrlInput.value = opt.dataset.value;
        baseUrlDropdown.style.display = "none";
        _updateModalModelDropdown();
      });
    });
  }

  function _showPromoHint(promoHint) {
    const items = [
      I18n.t("provider.promo.openclacky.1"),
      I18n.t("provider.promo.openclacky.2"),
      I18n.t("provider.promo.openclacky.3"),
    ];
    const title = `<div class="promo-title">${I18n.t("provider.promo.openclacky.title")}</div>`;
    const body = items.map(s => `<div class="promo-item"><span class="promo-icon">✦</span>${s}</div>`).join("");
    promoHint.innerHTML = `<div class="promo-inner">${title}${body}</div>`;
    promoHint.classList.add("visible");
  }

  function _bindCardEvents(card, index) {
    // Custom dropdown interactions
    const customSelectWrapper = card.querySelector(".custom-select-wrapper");
    const trigger = customSelectWrapper.querySelector(".custom-select-trigger");
    const dropdown = customSelectWrapper.querySelector(".custom-select-dropdown");
    const valueSpan = trigger.querySelector(".custom-select-value");
    const options = dropdown.querySelectorAll(".custom-select-option");

    // Initialize promo hint: only show for new cards (no existing model config)
    const quickSetupField = card.querySelector(".quick-setup-field");
    const isNewCard = quickSetupField && quickSetupField.style.display !== "none";
    const initialPromoHint = card.querySelector(`.provider-promo-hint[data-index="${index}"]`);
    const initialSelected = dropdown.querySelector(".custom-select-option.selected");
    const initialValue = initialSelected ? initialSelected.dataset.value : "";
    if (isNewCard && initialPromoHint && (!initialValue || initialValue === "openclacky")) {
      _showPromoHint(initialPromoHint);
    }

    // Toggle dropdown
    trigger.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = dropdown.classList.contains("open");
      // Close all other dropdowns
      document.querySelectorAll(".custom-select-dropdown.open").forEach(d => {
        d.classList.remove("open");
        d.previousElementSibling.classList.remove("open");
      });
      if (!isOpen) {
        dropdown.classList.add("open");
        trigger.classList.add("open");
      }
    });

    // Select option
    options.forEach(option => {
      option.addEventListener("click", (e) => {
        e.stopPropagation();
        const value = option.dataset.value;
        const text = option.dataset.label || option.textContent;
        
        // Update UI
        valueSpan.textContent = text;
        if (value) {
          valueSpan.classList.remove("placeholder");
        } else {
          valueSpan.classList.add("placeholder");
        }
        
        // Update selected state
        options.forEach(opt => opt.classList.remove("selected"));
        option.classList.add("selected");
        
        // Close dropdown
        dropdown.classList.remove("open");
        trigger.classList.remove("open");
        
        // Auto-fill model & base_url if a provider preset was selected
        const getApiKeyLink = card.querySelector(`.get-apikey-link[data-index="${index}"]`);
        const promoHint = card.querySelector(`.provider-promo-hint[data-index="${index}"]`);
        if (value && value !== "custom") {
          const preset = _providers.find(p => p.id === value);
          if (preset) {
            const modelInput   = card.querySelector(`[data-key="model"]`);
            const baseUrlInput = card.querySelector(`[data-key="base_url"]`);
            if (modelInput)   modelInput.value   = preset.default_model || "";
            if (baseUrlInput) baseUrlInput.value = preset.base_url       || "";
            // Show "how to get" link if provider has a website_url
            if (getApiKeyLink && preset.website_url) {
              getApiKeyLink.href = preset.website_url;
              getApiKeyLink.style.display = "";
            } else if (getApiKeyLink) {
              getApiKeyLink.style.display = "none";
            }
          }
          // Show promo hint for openclacky, hide for others
          if (promoHint) {
            if (value === "openclacky") {
              _showPromoHint(promoHint);
            } else {
              promoHint.classList.remove("visible");
            }
          }
        } else {
          if (getApiKeyLink) getApiKeyLink.style.display = "none";
          // Show promo hint when no provider selected (default state)
          if (promoHint) _showPromoHint(promoHint);
        }
      });
    });

    // Close dropdown when clicking outside
    document.addEventListener("click", () => {
      dropdown.classList.remove("open");
      trigger.classList.remove("open");
    });

    // Toggle API key visibility
    const toggleKeyBtn = card.querySelector(".btn-toggle-key");
    const apiKeyInput = card.querySelector(".api-key-input");
    const eyeIcon = toggleKeyBtn.querySelector("svg");
    
    toggleKeyBtn.addEventListener("click", () => {
      const isPassword = apiKeyInput.type === "password";
      apiKeyInput.type = isPassword ? "text" : "password";
      
      // Update icon
      if (isPassword) {
        // Show eye-off icon
        eyeIcon.innerHTML = `
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"></path>
        `;
      } else {
        // Show eye icon
        eyeIcon.innerHTML = `
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path>
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"></path>
        `;
      }
    });

    // Save: auto-test first, then save if passed
    card.querySelector(".btn-save-model").addEventListener("click", () => _saveModel(index));

    // Remove model
    const removeBtn = card.querySelector(".btn-model-remove");
    if (removeBtn) {
      removeBtn.addEventListener("click", () => _removeModel(index));
    }

    // Set as default model
    const setDefaultBtn = card.querySelector(".btn-set-default");
    if (setDefaultBtn) {
      setDefaultBtn.addEventListener("click", () => _setAsDefault(index));
    }

    // Model name combobox: dropdown button + model list
    const modelCombobox = card.querySelector(".model-name-combobox");
    const modelInput = modelCombobox.querySelector(".model-name-input");
    const modelDropdownBtn = modelCombobox.querySelector(".model-name-dropdown-btn");
    const modelDropdown = modelCombobox.querySelector(".model-name-dropdown");

    // Build model list from current base_url's provider
    const _updateModelDropdown = () => {
      const baseUrlInput = card.querySelector(`[data-key="base_url"]`);
      const baseUrl = baseUrlInput ? baseUrlInput.value.trim().replace(/\/+$/, "") : "";

      // Find provider by matching base_url against BOTH the canonical
      // preset.base_url AND every endpoint_variants[].base_url — otherwise
      // picking e.g. GLM's Coding-Plan variant would wipe the model list
      // because only the canonical URL would match.
      const provider = _providers.find(p => {
        const candidates = [p.base_url].concat(
          Array.isArray(p.endpoint_variants) ? p.endpoint_variants.map(v => v.base_url) : []
        ).filter(Boolean);
        return candidates.some(c => {
          const norm = String(c).replace(/\/+$/, "");
          return baseUrl === norm || baseUrl.startsWith(norm + "/");
        });
      });
      const models = provider?.models || [];

      if (models.length === 0) {
        modelDropdown.innerHTML = '<div class="model-dropdown-empty">No preset models available</div>';
        return;
      }

      // Render model options
      modelDropdown.innerHTML = models.map(m => 
        `<div class="model-dropdown-option" data-value="${_esc(m)}">${_esc(m)}</div>`
      ).join("");

      // Bind click events
      modelDropdown.querySelectorAll(".model-dropdown-option").forEach(opt => {
        opt.addEventListener("click", (e) => {
          e.stopPropagation();
          const value = opt.dataset.value;
          if (modelInput) modelInput.value = value;
          modelDropdown.style.display = "none";
        });
      });
    };

    // Toggle dropdown
    modelDropdownBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = modelDropdown.style.display === "block";
      
      // Close all other model dropdowns
      document.querySelectorAll(".model-name-dropdown").forEach(d => {
        d.style.display = "none";
      });

      if (!isOpen) {
        _updateModelDropdown();
        modelDropdown.style.display = "block";
      }
    });

    // Close dropdown when clicking outside
    document.addEventListener("click", () => {
      modelDropdown.style.display = "none";
    });

    // Re-populate model list when base_url changes
    const baseUrlInput = card.querySelector(`[data-key="base_url"]`);
    if (baseUrlInput) {
      baseUrlInput.addEventListener("blur", () => {
        _updateModelDropdown();
      });
    }

    // Base URL combobox: dropdown button + endpoint_variants list.
    //
    // Rationale: some providers (GLM on Zhipu/Z.ai, MiniMax on .com/.io) run
    // multiple regional / billing-plan endpoints under a single identity.
    // Listing every variant lets the user pick the right one instead of
    // hand-editing the URL, while still allowing free-form input for
    // unknown / self-hosted proxies. Mirrors the model-name combobox.
    //
    // Data source: the endpoint_variants[] field on each provider preset,
    // resolved by matching the currently-entered base_url against every
    // preset's {base_url + endpoint_variants[].base_url}. When no variants
    // are declared for the matched provider (single-endpoint providers like
    // Anthropic, OpenClacky), the dropdown shows an "empty" hint.
    const baseUrlCombobox   = card.querySelector(".base-url-combobox");
    const baseUrlDropdownBtn = baseUrlCombobox.querySelector(".base-url-dropdown-btn");
    const baseUrlDropdown   = baseUrlCombobox.querySelector(".base-url-dropdown");

    // Resolve the "active" provider preset from the current form values:
    // 1. If the Quick Setup select points at a known provider, use that
    //    (even before the base_url input is typed into).
    // 2. Otherwise fall back to matching the current base_url against all
    //    preset base_url + endpoint_variants. Unknown URLs → null.
    const _currentProvider = () => {
      const selected = card.querySelector(".custom-select-option.selected");
      const selectedId = selected?.dataset.value;
      if (selectedId && selectedId !== "custom") {
        const byId = _providers.find(p => p.id === selectedId);
        if (byId) return byId;
      }
      const url = (baseUrlInput?.value || "").trim().replace(/\/+$/, "");
      if (!url) return null;
      return _providers.find(p => {
        const candidates = [p.base_url].concat(
          Array.isArray(p.endpoint_variants) ? p.endpoint_variants.map(v => v.base_url) : []
        ).filter(Boolean);
        return candidates.some(c => {
          const norm = String(c).replace(/\/+$/, "");
          return url === norm || url.startsWith(norm + "/");
        });
      }) || null;
    };

    const _renderBaseUrlDropdown = () => {
      const provider = _currentProvider();
      const variants = provider && Array.isArray(provider.endpoint_variants)
        ? provider.endpoint_variants
        : [];

      if (variants.length === 0) {
        baseUrlDropdown.innerHTML =
          `<div class="model-dropdown-empty">${I18n.t("settings.models.baseurl.noVariants")}</div>`;
        return;
      }

      baseUrlDropdown.innerHTML = variants.map(v => {
        // Prefer i18n key (localised per UI language); fall back to literal
        // `label` (shipped English copy) and finally to base_url for safety.
        // Pattern: _translateVariant(v) -> "大陆 · 按量付费" in zh, "Mainland · Pay-as-you-go" in en.
        const translated = v.label_key ? I18n.t(v.label_key) : null;
        // I18n.t typically returns the key itself when missing — treat that as a miss.
        const labelText = (translated && translated !== v.label_key) ? translated : (v.label || v.base_url);
        const label = _esc(labelText);
        const url   = _esc(v.base_url);
        return `
          <div class="model-dropdown-option base-url-dropdown-option" data-value="${url}">
            <div class="base-url-dropdown-label">${label}</div>
            <div class="base-url-dropdown-url">${url}</div>
          </div>`;
      }).join("");

      baseUrlDropdown.querySelectorAll(".base-url-dropdown-option").forEach(opt => {
        opt.addEventListener("click", (e) => {
          e.stopPropagation();
          if (baseUrlInput) {
            baseUrlInput.value = opt.dataset.value;
            // Trigger model-list refresh since base_url just changed.
            _updateModelDropdown();
          }
          baseUrlDropdown.style.display = "none";
        });
      });
    };

    baseUrlDropdownBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = baseUrlDropdown.style.display === "block";
      // Close sibling dropdowns (model-name + other base-url) to avoid overlap.
      document.querySelectorAll(".model-name-dropdown, .base-url-dropdown").forEach(d => {
        d.style.display = "none";
      });
      if (!isOpen) {
        _renderBaseUrlDropdown();
        baseUrlDropdown.style.display = "block";
      }
    });

    // Close dropdown when clicking outside
    document.addEventListener("click", () => {
      baseUrlDropdown.style.display = "none";
    });
  }

  // ── Read form values from a card ────────────────────────────────────────────

  function _readCard(index) {
    const card = document.querySelector(`.model-card[data-index="${index}"]`);
    if (!card) return null;
    return {
      index,
      model:            card.querySelector(`[data-key="model"]`).value.trim(),
      base_url:         card.querySelector(`[data-key="base_url"]`).value.trim(),
      api_key:          card.querySelector(`[data-key="api_key"]`).value.trim(),
      // The inline card form has no provider picker — preserve whatever the
      // model was saved with. The modal flow is the only place where the
      // user can flip this flag.
      anthropic_format: !!_models[index]?.anthropic_format,
      type:             _models[index]?.type ?? null
    };
  }

  // ── Save ─────────────────────────────────────────────────────────────────────

  async function _saveModel(index) {
    const saveBtn = document.querySelector(`.btn-save-model[data-index="${index}"]`);
    const updated = _readCard(index);
    if (!updated) return;

    saveBtn.disabled = true;

    // Step 1: auto-test first
    saveBtn.textContent = I18n.t("settings.models.btn.testing");
    _showTestResult(index, null, "");

    try {
      const testRes = await fetch("/api/config/test", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...updated, index })
      });
      const testData = await testRes.json();
      _showTestResult(index, testData.ok, testData.message);

      if (!testData.ok) {
        // Test failed — stop, let user fix
        saveBtn.textContent = I18n.t("settings.models.btn.save");
        saveBtn.disabled = false;
        return;
      }
    } catch (e) {
      _showTestResult(index, false, e.message);
      saveBtn.textContent = I18n.t("settings.models.btn.save");
      saveBtn.disabled = false;
      return;
    }

    // Step 2: test passed — now save via single-item endpoint.
    //
    // Contract (see http_server.rb):
    //   - Row has an id already → PATCH /api/config/models/:id
    //   - No id yet (locally-added row) → POST /api/config/models to
    //     create, then capture the server-assigned id.
    // We NEVER send "the whole list" — each save touches exactly one row,
    // so no bug in this function can ever affect another model's api_key.
    saveBtn.textContent = I18n.t("settings.models.btn.saving");

    const existing = _models[index] || {};
    const hasId    = !!existing.id;

    // For PATCH: only send api_key if the user actually typed something
    // non-masked. The masked display value ("sk-ab12****...5678") must
    // never be sent as api_key — the server treats it as "no change"
    // defensively, but the cleanest path is simply to omit it.
    const payload = {
      model:            updated.model,
      base_url:         updated.base_url,
      anthropic_format: updated.anthropic_format,
      type:             updated.type
    };
    if (updated.api_key && !updated.api_key.includes("****")) {
      payload.api_key = updated.api_key;
    }

    try {
      let res, data;
      if (hasId) {
        res  = await fetch(`/api/config/models/${encodeURIComponent(existing.id)}`, {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload)
        });
        data = await res.json();
      } else {
        // Creation requires a non-empty api_key — surface a friendly
        // error rather than a server 422.
        if (!payload.api_key) {
          saveBtn.textContent = I18n.t("settings.models.btn.save");
          saveBtn.disabled    = false;
          _showTestResult(index, false, I18n.t("settings.models.placeholder.apikey"));
          return;
        }
        res  = await fetch(`/api/config/models`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload)
        });
        data = await res.json();
        if (data.ok && data.id) {
          // Record the assigned id so subsequent saves become PATCH.
          _models[index].id = data.id;
        }
      }

      if (data.ok) {
        saveBtn.textContent = I18n.t("settings.models.btn.saved");
        setTimeout(() => { saveBtn.textContent = I18n.t("settings.models.btn.save"); saveBtn.disabled = false; }, 1500);
        // Reload to get fresh masked keys
        setTimeout(_load, 1600);
      } else {
        saveBtn.textContent = I18n.t("settings.models.btn.save");
        saveBtn.disabled = false;
        _showTestResult(index, false, data.error || I18n.t("settings.models.saveFailed"));
      }
    } catch (e) {
      saveBtn.textContent = I18n.t("settings.models.btn.save");
      saveBtn.disabled = false;
      _showTestResult(index, false, e.message);
    }
  }

  function _showTestResult(index, ok, message) {
    const el = document.querySelector(`.model-test-result[data-index="${index}"]`);
    if (!el) return;
    if (ok === null) { el.textContent = I18n.t("settings.models.btn.testing"); el.className = "model-test-result result-testing"; return; }
    el.textContent = ok ? `✓ ${message || I18n.t("settings.models.connected")}` : `✗ ${I18n.t("settings.models.testFail")}: ${message || I18n.t("settings.models.failed")}`;
    el.className   = `model-test-result ${ok ? "result-ok" : "result-fail"}`;
  }

  // ── Set as Default Model ───────────────────────────────────────────────────

  async function _setAsDefault(index) {
    const btn = document.querySelector(`.btn-card-grid-action[data-index="${index}"][data-action="default"]`);
    const target = _models[index];
    if (!target || !target.id) {
      alert(I18n.t("settings.models.setDefaultFailed"));
      return;
    }

    if (btn) {
      btn.disabled = true;
      const span = btn.querySelector("span");
      if (span) span.textContent = I18n.t("settings.models.btn.setting");
    }

    try {
      const res = await fetch(`/api/config/models/${encodeURIComponent(target.id)}/default`, {
        method: "POST"
      });
      const data = await res.json();

      if (data.ok) {
        if (btn) {
          const span = btn.querySelector("span");
          if (span) span.textContent = I18n.t("settings.models.btn.done");
        }
        setTimeout(() => { _load(); _loadMedia(); }, 800);
      } else {
        if (btn) {
          btn.disabled = false;
          const span = btn.querySelector("span");
          if (span) span.textContent = I18n.t("settings.models.btn.setDefault");
        }
        alert(data.error || I18n.t("settings.models.setDefaultFailed"));
      }
    } catch (e) {
      if (btn) {
        btn.disabled = false;
        const span = btn.querySelector("span");
        if (span) span.textContent = I18n.t("settings.models.btn.setDefault");
      }
      alert(I18n.t("settings.models.errorPrefix") + e.message);
    }
  }

  // ── Add / Remove model ───────────────────────────────────────────────────────

  function _addModel() {
    // Open modal in add mode (index = -1)
    _openModal(-1);
  }

  async function _removeModel(index) {
    if (_models.length <= 1) return;
    const modelName = _models[index]?.model || String(index + 1);
    const confirmed = await Modal.confirm(I18n.t("settings.models.confirmRemove", { model: modelName }));
    if (!confirmed) return;

    const target = _models[index];

    // Unsaved local card → just drop it from the local list, no server call.
    if (!target || !target.id) {
      _models.splice(index, 1);
      _renderCards();
      return;
    }

    try {
      const res = await fetch(`/api/config/models/${encodeURIComponent(target.id)}`, {
        method: "DELETE"
      });
      // Whatever the server says, reload to reflect the true state.
      // (On error, _load will re-show the model.)
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        alert(data.error || I18n.t("settings.models.setDefaultFailed"));
      }
    } catch (_) { /* ignore */ }

    // Reload fresh state
    _load();
    _loadMedia();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function _esc(str) {
    return (str || "").replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
  }

  // ── Rerun onboard ────────────────────────────────────────────────────────────

  async function _rerunOnboard() {
    const btn = document.getElementById("btn-rerun-onboard");
    btn.disabled    = true;
    btn.textContent = I18n.t("settings.personalize.btn.starting");

    try {
      // Close settings panel and navigate to chat, then start the onboard session.
      // Onboard.startSoulSession() creates a new session, selects it, and sends /onboard.
      Router.navigate("chat");
      await Onboard.startSoulSession();
    } catch (e) {
      btn.disabled    = false;
      btn.textContent = I18n.t("settings.personalize.btn.rerun");
    }
  }

  // ── Browser Setup ─────────────────────────────────────────────────────────────

  async function _loadBrowserStatus() {
    try {
      const res  = await fetch("/api/browser/status");
      const data = await res.json();
      const desc        = document.getElementById("browser-status-desc");
      const btn         = document.getElementById("btn-browser-setup");
      const toggleWrap  = document.getElementById("browser-toggle-wrap");
      const toggleInput = document.getElementById("browser-toggle-input");

      // File doesn't exist → not set up yet
      if (data.enabled === undefined || data.enabled === null) {
        desc.textContent = I18n.t("settings.browser.desc");
        btn.textContent  = I18n.t("settings.browser.btn");
        toggleWrap.style.display = "none";
        return;
      }

      // Configured — show toggle + reconfigure button
      const version = data.chrome_version ? ` (Chrome v${data.chrome_version})` : "";
      desc.textContent     = I18n.t(data.enabled ? "settings.browser.configured" : "settings.browser.disabled") + version;
      btn.textContent      = I18n.t("settings.browser.btn.reconfigure");
      toggleWrap.style.display = "inline-block";
      toggleInput.checked  = data.enabled;

      // Only bind once
      if (!toggleInput.dataset.bound) {
        toggleInput.dataset.bound = "1";
        toggleInput.addEventListener("change", _toggleBrowser);
      }
    } catch (_) { /* non-critical */ }
  }

  async function _toggleBrowser() {
    const toggleInput = document.getElementById("browser-toggle-input");
    toggleInput.disabled = true;
    try {
      const res  = await fetch("/api/browser/toggle", { method: "POST" });
      const data = await res.json();
      if (!data.ok) throw new Error(data.error || "toggle failed");
      await _loadBrowserStatus();
    } catch (_) {
      // Revert on failure
      toggleInput.checked  = !toggleInput.checked;
    } finally {
      toggleInput.disabled = false;
    }
  }

  async function _setupBrowser() {
    const btn = document.getElementById("btn-browser-setup");
    btn.disabled    = true;
    btn.textContent = I18n.t("settings.browser.btn.starting");
    try {
      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name: "🌐 Browser Setup", source: "setup" })
      });
      const data    = await res.json();
      const session = data.session;
      if (!session) throw new Error("No session returned");
      Sessions.add(session);
      Sessions.renderList();
      Sessions.setPendingMessage(session.id, "/browser-setup");
      Sessions.select(session.id);
    } catch (e) {
      btn.disabled    = false;
      btn.textContent = I18n.t("settings.browser.btn");
    }
  }

  // ── Brand & License ───────────────────────────────────────────────────────────

  // Whether the server was started with --brand-test (relaxed key validation).
  let _brandTestMode = false;

  // Load and render the current brand/license status in Settings.
  async function _loadBrand() {
    try {
      const res  = await fetch("/api/brand/status");
      const data = await res.json();
      _brandTestMode = !!data.test_mode;
      _renderBrandStatus(data);
    } catch (_) {
      // If the API is unreachable just leave both areas hidden — non-critical.
    }
  }

  function _renderBrandStatus(data) {
    const statusCard   = document.getElementById("brand-status-card");
    const activateForm = document.getElementById("brand-activate-form");

    if (data.branded && !data.needs_activation) {
      // Already activated — show status card, hide form
      statusCard.style.display   = "";
      activateForm.style.display = "none";

      document.getElementById("brand-status-name").textContent = data.product_name || "—";

      const badge = document.getElementById("brand-status-badge");
      if (data.warning) {
        // Distinguish between expired (red) and expiring-soon (yellow)
        const isExpired = data.warning && data.warning.toLowerCase().includes("expired");
        badge.textContent = isExpired ? I18n.t("settings.brand.badge.expired") : I18n.t("settings.brand.badge.warning");
        badge.className   = "brand-status-value " + (isExpired ? "badge-expired" : "badge-expiring");
      } else {
        badge.textContent  = I18n.t("settings.brand.badge.active");
        badge.className    = "brand-status-value badge-active";
      }

      // Fetch full brand info for expiry date and support QR code
      fetch("/api/brand").then(r => r.json()).then(info => {
        const expiresEl = document.getElementById("brand-status-expires");
        if (info.license_expires_at) {
          expiresEl.textContent = new Date(info.license_expires_at).toLocaleDateString();
        } else {
          expiresEl.textContent = "—";
        }

        // Show homepage link if available
        const homepageRow  = document.getElementById("brand-status-homepage-row");
        const homepageLink = document.getElementById("brand-status-homepage");
        if (info.homepage_url && homepageRow && homepageLink) {
          homepageLink.href        = info.homepage_url;
          homepageLink.textContent = info.homepage_url;
          homepageRow.style.display = "";
        } else if (homepageRow) {
          homepageRow.style.display = "none";
        }

        // Show support contact if available
        const contactWrap = document.getElementById("brand-support-contact");
        const contactLink = document.getElementById("brand-support-contact-link");
        if (info.support_contact && contactWrap && contactLink) {
          const contact = info.support_contact;
          contactLink.textContent = contact;
          // Auto-detect mailto / http link
          if (contact.startsWith("http://") || contact.startsWith("https://")) {
            contactLink.href = contact;
          } else if (contact.includes("@")) {
            contactLink.href = "mailto:" + contact;
          } else {
            contactLink.href = "#";
            contactLink.style.cursor = "default";
          }
          contactWrap.style.display = "";
        } else if (contactWrap) {
          contactWrap.style.display = "none";
        }

        // Show support QR code if available
        const qrContainer = document.getElementById("brand-support-qr");
        const qrImg       = document.getElementById("brand-support-qr-img");
        if (info.support_qr_url && qrContainer && qrImg) {
          qrImg.src                 = info.support_qr_url;
          qrContainer.style.display = "";
          _initQrLightbox(info.support_qr_url, info.support_qr_label || null);
        } else if (qrContainer) {
          qrContainer.style.display = "none";
        }
      }).catch(() => {
        document.getElementById("brand-status-expires").textContent = "—";
      });

    } else {
      // Not activated (or needs activation) — show form, hide status card
      statusCard.style.display   = "none";
      activateForm.style.display = "";

      // Pre-fill brand name in input placeholder if we know it
      if (data.product_name) {
        const desc = activateForm.querySelector(".brand-activate-desc");
        if (desc) desc.textContent =
          I18n.t("settings.brand.descNamed", { name: data.product_name });
      }

      // Show "Get a serial number" link only when the brand vendor has
      // published a homepage_url (read from /api/brand). No homepage → no link.
      if (typeof Brand.applyGetSerialLink === "function") Brand.applyGetSerialLink();
    }
  }

  /** Return a user-friendly error message for license activation failures. */
  function _friendlyActivateError(rawError) {
    if (!rawError) return I18n.t("settings.brand.activationFailed");
    const lower = rawError.toLowerCase();
    if (lower.includes("timeout") || lower.includes("network error") ||
        lower.includes("execution expired") || lower.includes("failed to open")) {
      return I18n.t("settings.brand.networkRetry");
    }
    return rawError;
  }

  async function _activateLicense() {
    const input  = document.getElementById("settings-license-key");
    const btn    = document.getElementById("btn-settings-activate");
    const result = document.getElementById("settings-activate-result");
    const key    = input.value.trim();

    if (!key) {
      _showBrandResult(false, I18n.t("settings.brand.enterKey"));
      return;
    }

    // In brand-test mode skip strict key format validation so developers can use any test key.
    if (!_brandTestMode && !/^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{8}){4}$/.test(key)) {
      _showBrandResult(false, I18n.t("settings.brand.invalidFormat"));
      return;
    }

    btn.disabled    = true;
    btn.textContent = I18n.t("settings.brand.btn.activating");
    _showBrandResult(null, "");

    try {
      const res  = await fetch("/api/brand/activate", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ license_key: key })
      });
      const data = await res.json();

      if (data.ok) {
        _showBrandResult(true, I18n.t("settings.brand.activated", { name: data.product_name || "configured" }));
        // Apply brand name and logo across the entire UI immediately
        if (data.product_name) Brand.applyBrandName(data.product_name);
        Brand.clearBrandCache();
        Brand.applyHeaderLogo();
        // Refresh brand status flags (user_licensed may have flipped from false
        // to true if this is a creator-tier license) and repaint dependent UI:
        //   - Creator sidebar entry (hidden for brand consumers, shown otherwise)
        //   - Header owner badge (shown only for creator licenses)
        // Without this refresh the user would need to reload the page to see
        // the Creator Hub appear in the sidebar after activation.
        Brand.refresh().then(() => {
          if (typeof Creator !== "undefined" && Creator.updateSidebarVisibility) {
            Creator.updateSidebarVisibility();
          }
          if (typeof Brand.applyOwnerBadge === "function") Brand.applyOwnerBadge();
        });
        // Remove the activation banner immediately after successful activation
        const banner = document.getElementById("brand-activation-banner");
        if (banner) banner.remove();
        // Reload brand status card after short delay
        setTimeout(_loadBrand, 800);
        // Auto-navigate to brand skills tab after a brief moment so user sees the success message first
        setTimeout(() => {
          Router.navigate("skills");
          if (typeof Skills !== "undefined") Skills.openBrandSkillsTab();
        }, 1500);
      } else {
        _showBrandResult(false, _friendlyActivateError(data.error));
      }
    } catch (e) {
      // Fetch itself threw (network down, timeout, etc.) — always show retry message
      _showBrandResult(false, I18n.t("settings.brand.networkRetry"));
    } finally {
      btn.disabled    = false;
      btn.textContent = I18n.t("settings.brand.btn.activate");
    }
  }

  function _showBrandResult(ok, message) {
    const el = document.getElementById("settings-activate-result");
    if (!el) return;
    if (ok === null) { el.textContent = ""; el.className = "model-test-result"; return; }
    el.textContent = message;
    el.className   = "model-test-result " + (ok ? "result-ok" : "result-fail");
  }

  // ── Init ──────────────────────────────────────────────────────────────────────

  function _initTabs() {
    const tabs = document.querySelectorAll("#settings-tabs .settings-tab");
    const contents = document.querySelectorAll("#settings-body .settings-tab-content");

    tabs.forEach(tab => {
      tab.addEventListener("click", () => {
        const targetTab = tab.dataset.tab;

        // Update tab buttons
        tabs.forEach(t => t.classList.toggle("active", t.dataset.tab === targetTab));

        // Update tab content panels
        contents.forEach(c => {
          const isActive = c.dataset.tabContent === targetTab;
          c.classList.toggle("active", isActive);
          c.style.display = isActive ? "" : "none";
        });
      });
    });
  }

  function _applyAboutTabVisibility() {
    const branded  = typeof Brand !== "undefined" && Brand.branded;
    const tabBtn   = document.querySelector('#settings-tabs .settings-tab[data-tab="about"]');
    const tabPanel = document.querySelector('#settings-body .settings-tab-content[data-tab-content="about"]');
    if (!tabBtn || !tabPanel) return;

    if (branded) {
      tabBtn.style.display = "none";
      if (tabBtn.classList.contains("active")) {
        tabBtn.classList.remove("active");
        tabPanel.classList.remove("active");
        tabPanel.style.display = "none";
        const fallback = document.querySelector('#settings-tabs .settings-tab[data-tab="models"]');
        const fallbackPanel = document.querySelector('#settings-body .settings-tab-content[data-tab-content="models"]');
        if (fallback) fallback.classList.add("active");
        if (fallbackPanel) {
          fallbackPanel.classList.add("active");
          fallbackPanel.style.display = "";
        }
      }
    } else {
      tabBtn.style.display = "";
    }
  }

  function _initLangBtns() {
    // Highlight the active language button on open
    document.querySelectorAll("#language-section .settings-lang-btn").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.lang === I18n.lang());
      btn.addEventListener("click", () => {
        I18n.setLang(btn.dataset.lang);
        document.querySelectorAll("#language-section .settings-lang-btn").forEach(b =>
          b.classList.toggle("active", b.dataset.lang === I18n.lang())
        );
      });
    });
  }

  // ── Advanced Settings ────────────────────────────────────────────────────────

  async function _loadAdvancedSettings() {
    try {
      const res = await fetch("/api/config/settings");
      const data = await res.json();
      if (data.ok) {
        const comp = document.getElementById("settings-compression-toggle");
        const cache = document.getElementById("settings-prompt-caching-toggle");
        const mem = document.getElementById("settings-memory-update-toggle");
        if (comp) comp.checked = data.enable_compression !== false;
        if (cache) cache.checked = data.enable_prompt_caching !== false;
        if (mem) mem.checked = data.memory_update_enabled !== false;
      }
    } catch (e) {
      console.error("Failed to load advanced settings:", e);
    }
  }

  async function _saveAdvancedSetting(key, value) {
    try {
      await fetch("/api/config/settings", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ [key]: value })
      });
    } catch (e) {
      console.error("Failed to save setting:", e);
    }
  }

  function _initAdvancedSettings() {
    _loadAdvancedSettings();
    document.getElementById("settings-compression-toggle")?.addEventListener("change", (e) => {
      _saveAdvancedSetting("enable_compression", e.target.checked);
    });
    document.getElementById("settings-prompt-caching-toggle")?.addEventListener("change", (e) => {
      _saveAdvancedSetting("enable_prompt_caching", e.target.checked);
    });
    document.getElementById("settings-memory-update-toggle")?.addEventListener("change", (e) => {
      _saveAdvancedSetting("memory_update_enabled", e.target.checked);
    });
  }

  // ── About Tab ───────────────────────────────────────────────────────────────

  async function _loadAboutInfo() {
    try {
      const res = await fetch("/api/version");
      const data = await res.json();
      if (data.current) {
        const el = document.getElementById("about-version");
        if (el) el.textContent = `v${data.current}`;
      }
    } catch (e) {
      console.error("Failed to load version info:", e);
    }
  }


  // ── Media generation (Settings → Models tab, below the model cards) ───
  // Per-kind tri-state: off / auto (derive from default) / custom (user-set).
  // Backend API:
  //   GET   /api/config/media                 → { media: { image: {...}, ... }, default_provider: {...} }
  //   PATCH /api/config/media/:kind           → body { source: "off"|"auto"|"custom", model?, base_url?, api_key?, anthropic_format? }
  // The state object per kind:
  //   { source, configured, model, base_url, api_key_masked, provider, available }

  const MEDIA_KINDS = ["image", "video", "audio"];
  let _mediaState = null;
  let _mediaDefaults = null;
  const _mediaCustomDraft = {};

  async function _loadMedia() {
    const container = document.getElementById("media-rows");
    if (!container) return;
    container.innerHTML = `<div class="settings-loading">${I18n.t("settings.media.loading")}</div>`;
    try {
      const res = await fetch("/api/config/media");
      const data = await res.json();
      _mediaState = data.media || {};
      _mediaDefaults = data.default_provider || {};
      _renderMediaRows();
    } catch (e) {
      container.innerHTML = `<div class="settings-error">${I18n.t("settings.media.error", { msg: e.message })}</div>`;
    }
  }

  function _renderMediaRows() {
    const container = document.getElementById("media-rows");
    if (!container) return;
    container.innerHTML = "";
    MEDIA_KINDS.forEach(kind => {
      container.appendChild(_renderMediaRow(kind));
    });
  }

  function _renderMediaRow(kind) {
    const state = (_mediaState && _mediaState[kind]) || { source: "off", available: [] };
    const def   = (_mediaDefaults && _mediaDefaults[kind]) || { available: [] };
    const autoAvailable = !!(def && def.model);
    const isCustomEditing = state.source === "custom" && (!state.configured || _mediaCustomDraft[kind]);

    const row = document.createElement("div");
    row.className = "media-row";
    if (isCustomEditing || (state.source === "auto" && state.configured) || (state.source === "custom" && state.configured)) {
      row.classList.add("is-expanded");
    }
    row.dataset.kind = kind;

    // Compact head: title · segmented · status
    const head = document.createElement("div");
    head.className = "media-row-head";

    const title = document.createElement("span");
    title.className = "media-row-title";
    title.textContent = I18n.t(`settings.media.kind.${kind}`);
    head.appendChild(title);

    const seg = document.createElement("div");
    seg.className = "media-row-segmented";
    ["off", "auto", "custom"].forEach(src => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.dataset.source = src;
      btn.textContent = I18n.t(`settings.media.source.${src}`);
      if (state.source === src) btn.classList.add("is-active");
      if (src === "auto" && !autoAvailable) {
        btn.disabled = true;
        btn.title = I18n.t("settings.media.auto.disabledTitle");
      } else {
        btn.addEventListener("click", () => _onMediaSourceClick(kind, src));
      }
      seg.appendChild(btn);
    });
    head.appendChild(seg);

    const status = document.createElement("span");
    status.className = "media-row-status";
    status.textContent = _mediaStatusText(kind, state, def);
    head.appendChild(status);

    row.appendChild(head);

    const detail = _renderMediaDetail(kind, state, def);
    if (detail) row.appendChild(detail);

    return row;
  }

  function _mediaStatusText(kind, state, def) {
    if (state.source === "off") return "";
    if (state.source === "auto") {
      if (state.configured && state.model) return state.model;
      return "";
    }
    if (state.source === "custom" && state.configured && !_mediaCustomDraft[kind]) {
      return state.model || "";
    }
    return "";
  }

  function _renderMediaDetail(kind, state, def) {
    if (state.source === "off") return null;

    if (state.source === "auto") {
      if (state.configured && state.model) {
        const wrap = document.createElement("div");
        wrap.className = "media-row-detail";
        wrap.innerHTML = `
          <div class="media-kv">
            <span class="media-kv-key">${I18n.t("settings.media.field.provider")}</span>
            <span class="media-kv-val">${_esc(state.provider || "—")}</span>
            <span class="media-kv-key">${I18n.t("settings.media.field.model")}</span>
            <span class="media-kv-val">${_esc(state.model)}</span>
          </div>
          <div class="media-row-hint">${I18n.t("settings.media.auto.followsDefault")}</div>
        `;
        return wrap;
      }
      const wrap = document.createElement("div");
      wrap.className = "media-row-detail is-warning";
      const hasDefault = def && def.provider;
      wrap.innerHTML = `<div>${hasDefault ? I18n.t("settings.media.auto.unsupported") : I18n.t("settings.media.auto.noDefaultModel")}</div>`;
      return wrap;
    }

    // custom
    if (state.configured && !_mediaCustomDraft[kind]) {
      const wrap = document.createElement("div");
      wrap.className = "media-row-detail";
      wrap.innerHTML = `
        <div class="media-kv">
          <span class="media-kv-key">${I18n.t("settings.media.field.model")}</span>
          <span class="media-kv-val">${_esc(state.model || "—")}</span>
          <span class="media-kv-key">${I18n.t("settings.media.field.baseUrl")}</span>
          <span class="media-kv-val">${_esc(state.base_url || "—")}</span>
          <span class="media-kv-key">${I18n.t("settings.media.field.apiKey")}</span>
          <span class="media-kv-val">${_esc(state.api_key_masked || "—")}</span>
        </div>
      `;
      const actions = document.createElement("div");
      actions.className = "media-row-actions";
      const editBtn = document.createElement("button");
      editBtn.type = "button";
      editBtn.className = "media-row-btn";
      editBtn.textContent = I18n.t("settings.media.action.edit");
      editBtn.addEventListener("click", () => {
        _mediaCustomDraft[kind] = {
          model:    state.model || "",
          base_url: state.base_url || "",
          api_key:  ""
        };
        _renderMediaRows();
      });
      actions.appendChild(editBtn);
      wrap.appendChild(actions);
      return wrap;
    }

    // edit form
    const draft = _mediaCustomDraft[kind] || { model: "", base_url: "", api_key: "" };
    const wrap = document.createElement("div");
    wrap.className = "media-row-detail";
    const form = document.createElement("div");
    form.className = "media-custom-form";
    form.innerHTML = `
      <label>${I18n.t("settings.media.field.model")}</label>
      <input type="text" data-field="model" value="${_esc(draft.model)}" placeholder="gpt-image-1">
      <label>${I18n.t("settings.media.field.baseUrl")}</label>
      <input type="text" data-field="base_url" value="${_esc(draft.base_url)}" placeholder="https://api.openai.com/v1">
      <label>${I18n.t("settings.media.field.apiKey")}</label>
      <input type="password" data-field="api_key" value="${_esc(draft.api_key)}" placeholder="${I18n.t("settings.media.apiKey.placeholder")}">
      <div class="media-form-actions">
        <button type="button" class="media-row-btn" data-act="cancel">${I18n.t("settings.media.action.cancel")}</button>
        <button type="button" class="media-row-btn is-primary" data-act="save">${I18n.t("settings.media.action.save")}</button>
      </div>
    `;
    form.querySelectorAll("input").forEach(inp => {
      inp.addEventListener("input", () => {
        _mediaCustomDraft[kind] = _mediaCustomDraft[kind] || {};
        _mediaCustomDraft[kind][inp.dataset.field] = inp.value;
      });
    });
    form.querySelector('[data-act="cancel"]').addEventListener("click", () => {
      delete _mediaCustomDraft[kind];
      // If there's no saved custom, fall back to whatever the saved source is (or off)
      if (!state.configured) {
        const fallback = (_mediaDefaults && _mediaDefaults[kind] && _mediaDefaults[kind].model) ? "auto" : "off";
        _mediaState[kind] = { ..._mediaState[kind], source: fallback };
      }
      _renderMediaRows();
    });
    form.querySelector('[data-act="save"]').addEventListener("click", async () => {
      const d = _mediaCustomDraft[kind] || {};
      try {
        await _saveMediaConfig(kind, {
          source:   "custom",
          model:    (d.model || "").trim(),
          base_url: (d.base_url || "").trim(),
          api_key:  d.api_key || ""
        });
        delete _mediaCustomDraft[kind];
        await _loadMedia();
      } catch (e) {
        alert(e.message);
      }
    });
    wrap.appendChild(form);
    return wrap;
  }

  async function _onMediaSourceClick(kind, source) {
    const cur = (_mediaState && _mediaState[kind]) || {};
    if (cur.source === source && source !== "custom") return;

    if (source === "custom") {
      if (cur.source !== "custom" && !_mediaCustomDraft[kind]) {
        _mediaCustomDraft[kind] = {
          model:    cur.model || "",
          base_url: cur.base_url || "",
          api_key:  ""
        };
      }
      _mediaState[kind] = { ...cur, source: "custom" };
      _renderMediaRows();
      return;
    }

    try {
      await _saveMediaConfig(kind, { source });
      delete _mediaCustomDraft[kind];
      await _loadMedia();
    } catch (e) {
      alert(e.message);
    }
  }

  async function _saveMediaConfig(kind, body) {
    const res = await fetch(`/api/config/media/${kind}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body)
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.error) {
      throw new Error(data.error || `HTTP ${res.status}`);
    }
    return data;
  }


  function init() {
    _initTabs();
    _initModal();
    _initAdvancedSettings();
    _loadAboutInfo();
    document.getElementById("btn-add-model").addEventListener("click", _addModel);
    document.getElementById("btn-rerun-onboard").addEventListener("click", _rerunOnboard);
    document.getElementById("btn-browser-setup").addEventListener("click", _setupBrowser);

    document.getElementById("btn-settings-activate").addEventListener("click", _activateLicense);
    document.getElementById("settings-license-key").addEventListener("keydown", e => {
      if (e.key === "Enter") _activateLicense();
    });

    // "Get a Serial Number" → opens the brand vendor's homepage in a new tab.
    // URL comes from /api/brand `homepage_url`, stashed on the button's dataset
    // by Brand.applyGetSerialLink(). If no homepage is configured the whole
    // row stays hidden, so this listener is effectively unreachable in that
    // case; the guard is purely defensive.
    document.getElementById("btn-get-serial")?.addEventListener("click", (e) => {
      const url = e.currentTarget.dataset.homepageUrl;
      if (url) window.open(url, "_blank", "noopener,noreferrer");
    });
    document.getElementById("btn-rebind-license").addEventListener("click", async () => {
      const confirmed = await Modal.confirm(I18n.t("settings.brand.confirmRebind"));
      if (!confirmed) return;
      // Show the form again so user can enter a new key
      document.getElementById("brand-status-card").style.display   = "none";
      document.getElementById("brand-activate-form").style.display = "";
      document.getElementById("settings-license-key").value = "";
      document.getElementById("settings-license-key").focus();
    });

    document.getElementById("btn-unbind-license").addEventListener("click", async () => {
      const confirmed = await Modal.confirm(I18n.t("settings.brand.confirmUnbind"));
      if (!confirmed) return;

      try {
        const res = await fetch("/api/brand/license", { method: "DELETE" });
        const data = await res.json();

        if (data.ok) {
          // Clear brand name and logo from header
          Brand.applyBrandName("OpenClacky");
          Brand.clearBrandCache();
          Brand.applyHeaderLogo();
          // Reset Skills panel state (hide Brand Skills tab, switch to My Skills)
          if (typeof Skills !== "undefined" && Skills.resetAfterUnbind) {
            Skills.resetAfterUnbind();
          }
          // Refresh brand flags so the sidebar creator entry and owner badge
          // reflect the now-unbound state without a page reload.
          Brand.refresh().then(() => {
            if (typeof Creator !== "undefined" && Creator.updateSidebarVisibility) {
              Creator.updateSidebarVisibility();
            }
            if (typeof Brand.applyOwnerBadge === "function") Brand.applyOwnerBadge();
          });
          // Hide status card, show activation form
          document.getElementById("brand-status-card").style.display   = "none";
          document.getElementById("brand-activate-form").style.display = "";
          document.getElementById("settings-license-key").value = "";
          _showBrandResult(true, I18n.t("settings.brand.unbindSuccess"));
          // Reload brand status after a brief delay
          setTimeout(_loadBrand, 800);
        } else {
          _showBrandResult(false, data.error || I18n.t("settings.brand.unbindFailed"));
        }
      } catch (e) {
        _showBrandResult(false, I18n.t("settings.brand.networkRetry"));
      }
    });

    _initLangBtns();
    _initFontBtns();
    _initCurrencyBtns();

    // Re-render model cards when language changes (dynamic HTML, not data-i18n)
    document.addEventListener("langchange", () => {
      _renderCards();
      _renderMediaRows();
    });
  }

  // ── Currency ──────────────────────────────────────────────────────────
  const CURRENCY_STORAGE_KEY = "clacky-currency";
  const EXCHANGE_RATE_STORAGE_KEY = "clacky-exchange-rate";
  const CURRENCY_DEFAULT     = "USD";
  const DEFAULT_EXCHANGE_RATE = 6.7944;

  function _applyCurrency(currency) {
    try { localStorage.setItem(CURRENCY_STORAGE_KEY, currency); } catch (_) {}
    // Update active state on all currency buttons
    document.querySelectorAll("#currency-section .settings-lang-btn").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.currency === currency);
    });
    // Show/hide exchange rate input based on currency
    const exchangeRateSection = document.getElementById("exchange-rate-section");
    if (exchangeRateSection) {
      exchangeRateSection.style.display = currency === "CNY" ? "block" : "none";
    }
    // Dispatch event for billing panel to update
    document.dispatchEvent(new CustomEvent("currencychange", { detail: { currency } }));
  }

  function _getExchangeRate() {
    try {
      const rate = localStorage.getItem(EXCHANGE_RATE_STORAGE_KEY);
      if (rate) {
        const parsed = parseFloat(rate);
        if (!isNaN(parsed) && parsed > 0) return parsed;
      }
    } catch (_) {}
    return DEFAULT_EXCHANGE_RATE;
  }

  function _setExchangeRate(rate) {
    try {
      if (rate && !isNaN(rate) && rate > 0) {
        localStorage.setItem(EXCHANGE_RATE_STORAGE_KEY, rate.toString());
        document.dispatchEvent(new CustomEvent("currencychange"));
      }
    } catch (_) {}
  }

  function _initCurrencyBtns() {
    // Apply saved preference (or default) on page load
    let saved = null;
    try { saved = localStorage.getItem(CURRENCY_STORAGE_KEY); } catch (_) {}
    const current = saved || CURRENCY_DEFAULT;

    // Wire up button clicks
    document.querySelectorAll("#currency-section .settings-lang-btn").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.currency === current);
      btn.addEventListener("click", () => {
        _applyCurrency(btn.dataset.currency);
      });
    });

    // Initialize exchange rate input
    const exchangeRateInput = document.getElementById("settings-exchange-rate");
    const exchangeRateSection = document.getElementById("exchange-rate-section");
    if (exchangeRateInput && exchangeRateSection) {
      // Set initial value
      exchangeRateInput.value = _getExchangeRate();
      // Show/hide based on current currency
      exchangeRateSection.style.display = current === "CNY" ? "block" : "none";
      // Handle input changes
      exchangeRateInput.addEventListener("change", () => {
        const rate = parseFloat(exchangeRateInput.value);
        if (!isNaN(rate) && rate > 0) {
          _setExchangeRate(rate);
        } else {
          exchangeRateInput.value = _getExchangeRate();
        }
      });
    }
  }

  // ── Font Size ──────────────────────────────────────────────────────────
  const FONT_STORAGE_KEY = "clacky-font-size";
  const FONT_DEFAULT     = "medium";

  function _applyFontSize(size) {
    document.documentElement.setAttribute("data-font-size", size);
    try { localStorage.setItem(FONT_STORAGE_KEY, size); } catch (_) {}
    // Update active state on all font-size buttons (if settings panel is open)
    document.querySelectorAll("#font-size-section .settings-lang-btn").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.font === size);
    });
  }

  function _initFontBtns() {
    // Apply saved preference (or default) on page load
    let saved = null;
    try { saved = localStorage.getItem(FONT_STORAGE_KEY); } catch (_) {}
    _applyFontSize(saved || FONT_DEFAULT);

    // Wire up button clicks
    document.querySelectorAll("#font-size-section .settings-lang-btn").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.font === (saved || FONT_DEFAULT));
      btn.addEventListener("click", () => {
        _applyFontSize(btn.dataset.font);
      });
    });
  }

  // ── QR Code Lightbox ───────────────────────────────────────────────────
  // Sets up click-to-enlarge behaviour for the support QR code.
  // Safe to call multiple times — idempotent via a data attribute guard.
  function _initQrLightbox(qrUrl, label) {
    const btn      = document.getElementById("brand-support-qr-btn");
    const lightbox = document.getElementById("qr-lightbox");
    const backdrop = document.getElementById("qr-lightbox-backdrop");
    const closeBtn = document.getElementById("qr-lightbox-close");
    const lbImg    = document.getElementById("qr-lightbox-img");
    const lbLabel  = document.getElementById("qr-lightbox-label");

    if (!btn || !lightbox) return;
    // Avoid double-binding
    if (btn.dataset.lightboxBound) return;
    btn.dataset.lightboxBound = "1";

    function openLightbox() {
      lbImg.src = qrUrl;
      if (lbLabel && label) lbLabel.textContent = label;
      lightbox.style.display = "";
      document.body.style.overflow = "hidden";
      closeBtn && closeBtn.focus();
    }

    function closeLightbox() {
      lightbox.style.display = "none";
      document.body.style.overflow = "";
      btn.focus();
    }

    btn.addEventListener("click", openLightbox);
    closeBtn  && closeBtn.addEventListener("click", closeLightbox);
    backdrop  && backdrop.addEventListener("click", closeLightbox);

    // Close on Escape key
    document.addEventListener("keydown", e => {
      if (e.key === "Escape" && lightbox.style.display !== "none") closeLightbox();
    });
  }

  return { open, init, loadBrand: _loadBrand };
})();
