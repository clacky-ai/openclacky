// onboard.js — First-run setup flow
//
// Two distinct phases, now cleanly separated:
//
//   key_setup  → Show the full-screen setup-panel (language + provider).
//                Hard block: nothing works without a connected provider.
//                On success, automatically launches the /onboard session.
//
//   soul_setup → API key is already configured, SOUL.md is missing.
//                Automatically creates an /onboard session and boots the UI —
//                no blocking panel shown, user lands directly in the session.
//
// The old onboard-panel (with phase-lang / phase-key / phase-soul) is gone.
// setup-panel handles the mandatory first-run setup.
// /onboard skill handles the optional personalisation inside a chat session.

const Onboard = (() => {
  let _providers   = [];
  let _selectedProviderId = null;
  let _selectedLang = I18n.lang();  // language chosen during setup
  let _branded      = false;        // true when running under a brand license
  let _runtimeStatusRequest = 0;
  let _setupRuntimeModels = [];
  let _setupRuntimeStatusData = null;
  let _providerOperationRequest = 0;
  let _providerOperationInFlight = false;
  let _setupProviderSelect = null;

  // ── Public API ──────────────────────────────────────────────────────────────

  async function check() {
    try {
      const res  = await fetch("/api/onboard/status");
      const data = await res.json();
      if (!data.needs_onboard) return { needsOnboard: false, phase: null };

      const phase = data.phase;
      _branded = !!data.branded;

      if (phase === "key_setup") {
        // Mandatory: show full-screen setup panel, block boot.
        _showSetup();
        return { needsOnboard: true, phase };
      }

      if (phase === "soul_setup") {
        // Skip any blocking panel — just auto-launch the /onboard session.
        // If the user already has an onboard session in progress (hash has a
        // session id), restore it instead of creating a duplicate.
        if (window.location.hash.includes("session/")) {
          return { needsOnboard: false, phase: null };
        }
        await _launchOnboardSession();
        return { needsOnboard: true, phase };
      }

      return { needsOnboard: false, phase: null };
    } catch (_) {
      return { needsOnboard: false, phase: null };
    }
  }

  // ── Setup panel (key_setup) ─────────────────────────────────────────────────

  function _showSetup() {
    document.body.classList.add("setup-mode");
    Router.navigate("setup");
    Sessions.renderList();

    _selectedLang = I18n.lang();
    _bindLangStep();
  }

  // Step 1 — language selection
  function _bindLangStep() {
    const btnEn   = $("setup-btn-lang-en");
    const btnZh   = $("setup-btn-lang-zh");
    const btnNext = $("setup-btn-lang-next");

    _updateLangBtns(_selectedLang);

    btnEn.addEventListener("click", () => {
      _selectedLang = "en";
      I18n.setLang("en");
      _updateLangBtns("en");
    });

    btnZh.addEventListener("click", () => {
      _selectedLang = "zh";
      I18n.setLang("zh");
      _updateLangBtns("zh");
    });

    btnNext.addEventListener("click", async () => {
      _showSetupStep("key");
      await _loadProviders();
      _bindKeyStep();
      // Nudge: focus the provider trigger so the user knows step 1 is "pick
      // a provider". `tabindex="0"` on the trigger makes it focusable; the
      // .open class is NOT toggled, so the dropdown stays closed — we just
      // get the accent-color border via `.custom-select-trigger:focus`.
      const trigger = $("setup-provider-wrapper")?.querySelector(".custom-select-trigger");
      if (trigger) trigger.focus({ preventScroll: true });
    });
  }

  function _updateLangBtns(lang) {
    const btnEn   = $("setup-btn-lang-en");
    const btnZh   = $("setup-btn-lang-zh");
    const btnNext = $("setup-btn-lang-next");
    if (!btnEn || !btnZh) return;
    btnEn.classList.toggle("active", lang === "en");
    btnZh.classList.toggle("active", lang === "zh");
    if (btnNext) btnNext.textContent = lang === "zh" ? "继续 →" : "Continue →";
  }

  function _showSetupStep(step) {
    $("setup-phase-lang").style.display = step === "lang" ? "" : "none";
    $("setup-phase-key").style.display  = step === "key"  ? "" : "none";
    $("setup-dot-1").className = "setup-step" + (step === "lang" ? " active" : " done");
    $("setup-dot-2").className = "setup-step" + (step === "key"  ? " active" : "");
    if (step === "key") {
      if (_branded) {
        // Brand mode: skip the OpenClacky AI Keys card, go straight to manual config
        $("setup-device-block").style.display   = "none";
        $("setup-manual-toggle").style.display  = "none";
        $("setup-manual-section").style.display = "";
      } else {
        $("setup-device-block").style.display   = "";
        $("setup-manual-toggle").style.display  = "";
        $("setup-manual-section").style.display = "none";
      }
    }
  }

  // Step 2 — provider setup
  // Guard: providers are loaded only once; dropdown is bound only once.
  let _providersLoaded = false;
  let _dropdownBound   = false;

  async function _loadProviders() {
    // Fetch providers only once; on Back→Next, re-render from cache.
    if (!_providersLoaded) {
      try {
        const res  = await fetch("/api/providers");
        const data = await res.json();
        _providers = data.providers || [];
        _providersLoaded = true;
      } catch (_) { /* ignore */ }
    }

    // Always re-render options (dropdown is cleared on each visit to Step 2)
    _renderProviderOptions();
    // Bind event listeners only once (delegation-based, safe to skip on re-entry)
    _bindCustomDropdown();
  }

  function _renderProviderOptions() {
    const dropdown = $("setup-provider-dropdown");
    // Clear any previously rendered options before re-rendering
    dropdown.innerHTML = "";

    // Insert placeholder option first
    const placeholder = document.createElement("div");
    placeholder.className    = "custom-select-option";
    placeholder.dataset.value = "";
    placeholder.dataset.i18n  = "onboard.key.provider.placeholder";
    placeholder.textContent   = I18n.t("onboard.key.provider.placeholder");
    dropdown.appendChild(placeholder);

    _providers.forEach(p => {
      // Prefer i18n key (localised); fall back to shipped English `name`.
      const translated  = p.name_key ? I18n.t(p.name_key) : null;
      const displayName = (translated && translated !== p.name_key) ? translated : p.name;

      const opt = document.createElement("div");
      opt.className     = "custom-select-option";
      opt.dataset.value = p.id;
      opt.dataset.label = displayName;
      if (p.id === "openclacky") {
        const nameSpan = document.createElement("span");
        nameSpan.textContent = displayName;
        opt.innerHTML = nameSpan.outerHTML + ` <span class="provider-badge-recommended">${I18n.t("provider.recommended")}</span>`;
      } else {
        opt.textContent = displayName;
      }
      dropdown.appendChild(opt);
    });

    // Always append "Custom" as the last option
    const custom = document.createElement("div");
    custom.className     = "custom-select-option";
    custom.dataset.value = "__custom__";
    custom.dataset.i18n  = "onboard.provider.custom";
    custom.textContent   = I18n.t("onboard.provider.custom");
    dropdown.appendChild(custom);
  }

  // ── Populate model dropdown options for the onboard combobox ──────────────

  function _updateSetupModelDropdown(models) {
    const dd = $("setup-model-dropdown");
    if (!dd) return;
    dd.innerHTML = "";
    if (!models || models.length === 0) return;
    models.forEach(m => {
      const opt = document.createElement("div");
      opt.className   = "model-dropdown-option";
      opt.dataset.value = m;
      opt.textContent   = m;
      opt.addEventListener("click", (e) => {
        e.stopPropagation();
        $("setup-model").value = m;
        dd.style.display = "none";
        if (RuntimeProvider.isRuntimeProvider(_selectedSetupProvider())) {
          _renderSetupRuntimeStatus(_setupRuntimeStatusData);
        }
      });
      dd.appendChild(opt);
    });
  }

  // ── Populate Base URL dropdown options from preset.endpoint_variants ──────
  // Mirrors settings.js _renderBaseUrlDropdown but for the single-shot
  // onboarding combobox. Called whenever the provider changes so the dropdown
  // reflects the currently selected preset (empty for Custom / presets with
  // no variants — button stays inert in that case).
  function _updateSetupBaseUrlDropdown(preset) {
    const dd = $("setup-base-url-dropdown");
    if (!dd) return;
    dd.innerHTML = "";

    const variants = preset && Array.isArray(preset.endpoint_variants)
      ? preset.endpoint_variants
      : [];

    if (variants.length === 0) {
      // Leave dd empty; the dropdown-btn still toggles but shows a no-variant
      // hint to signal "this provider has only one endpoint".
      const empty = document.createElement("div");
      empty.className   = "model-dropdown-empty";
      empty.textContent = I18n.t("settings.models.baseurl.noVariants");
      dd.appendChild(empty);
      return;
    }

    variants.forEach(v => {
      // Prefer i18n key (localised per UI language); fall back to literal
      // `label` (shipped English copy) then base_url for safety.
      const translated = v.label_key ? I18n.t(v.label_key) : null;
      const labelText  = (translated && translated !== v.label_key) ? translated : (v.label || v.base_url);

      const opt = document.createElement("div");
      opt.className     = "model-dropdown-option base-url-dropdown-option";
      opt.dataset.value = v.base_url;

      const lbl = document.createElement("div");
      lbl.className   = "base-url-dropdown-label";
      lbl.textContent = labelText;

      const url = document.createElement("div");
      url.className   = "base-url-dropdown-url";
      url.textContent = v.base_url;

      opt.appendChild(lbl);
      opt.appendChild(url);

      opt.addEventListener("click", (e) => {
        e.stopPropagation();
        $("setup-base-url").value = v.base_url;
        dd.style.display = "none";
      });
      dd.appendChild(opt);
    });
  }

  function _selectedSetupProvider() {
    if (!_selectedProviderId || _selectedProviderId === "__custom__") return null;
    return _providers.find(p => p.id === _selectedProviderId) || null;
  }

  function _clearSetupApiFields() {
    $("setup-model").value = "";
    $("setup-base-url").value = "";
    $("setup-api-key").value = "";
    _updateSetupModelDropdown([]);
    _updateSetupBaseUrlDropdown(null);
  }

  function _runtimeStatusText(view, data) {
    const translated = I18n.t(`runtime.provider.status.${view.state}`);
    const message = data && (data.message || data.error);
    return message && message !== translated ? `${translated} — ${message}` : translated;
  }

  function _renderSetupRuntimeStatus(data, suppliedView) {
    _setupRuntimeStatusData = data;
    const view = suppliedView || RuntimeProvider.statusView(data);
    const status = $("setup-runtime-status");
    const login = $("setup-runtime-login");
    const recheck = $("setup-runtime-recheck");
    const continueBtn = $("setup-btn-test");
    if (status) {
      status.textContent = _runtimeStatusText(view, data);
      status.className = `runtime-provider-status is-${view.state}`;
    }
    if (login) {
      const canAuthenticate = !data || data.can_authenticate !== false;
      login.style.display = !view.connected && canAuthenticate && !["checking", "starting"].includes(view.state)
        ? ""
        : "none";
      login.disabled = _providerOperationInFlight || view.state === "starting";
    }
    if (recheck) recheck.disabled = _providerOperationInFlight || ["checking", "starting"].includes(view.state);
    if (continueBtn && RuntimeProvider.isRuntimeProvider(_selectedSetupProvider())) {
      const selectedModel = $("setup-model")?.value.trim() || "";
      continueBtn.disabled = _providerOperationInFlight || !view.connected ||
        !_setupRuntimeModels.includes(selectedModel);
      continueBtn.textContent = I18n.t("runtime.provider.continue");
    }
    return view;
  }

  function _applySetupRuntimeDiscovery(data) {
    _setupRuntimeModels = Array.isArray(data.models) ? data.models : [];
    const input = $("setup-model");
    const current = input.value.trim();
    if (!_setupRuntimeModels.includes(current)) {
      input.value = data.default_model || _setupRuntimeModels[0] || "";
    }
    input.readOnly = true;
    _updateSetupModelDropdown(_setupRuntimeModels);
    _renderSetupRuntimeStatus(data);
  }

  async function _refreshSetupRuntimeStatus(provider = _selectedSetupProvider()) {
    if (!RuntimeProvider.isRuntimeProvider(provider)) return null;
    const request = ++_runtimeStatusRequest;
    const isCurrent = () => {
      const selected = _selectedSetupProvider();
      return request === _runtimeStatusRequest &&
        selected?.id === provider.id &&
        selected?.runtime_id === provider.runtime_id &&
        selected?.extension_id === provider.extension_id;
    };
    _renderSetupRuntimeStatus(null);
    let data = await RuntimeProvider.connect(provider);
    if (!isCurrent()) return data;
    let view = _renderSetupRuntimeStatus(data);
    if (!view.connected && !view.terminal) {
      data = await RuntimeProvider.pollStatus(provider, {
        maxAttempts: 60,
        intervalMs: 1000,
        shouldContinue: isCurrent,
        onUpdate: (nextData, nextView) => {
          if (isCurrent()) _renderSetupRuntimeStatus(nextData, nextView);
        },
      });
      if (!isCurrent()) return data;
      view = data.view || _renderSetupRuntimeStatus(data);
    }
    if (!view.connected) return data;

    const discovery = await RuntimeProvider.discover(provider);
    if (isCurrent()) _applySetupRuntimeDiscovery(discovery);
    return discovery;
  }

  async function _authenticateSetupRuntime() {
    const provider = _selectedSetupProvider();
    if (!RuntimeProvider.isRuntimeProvider(provider)) return;

    const request = ++_runtimeStatusRequest;
    const isCurrent = () => {
      const selected = _selectedSetupProvider();
      return request === _runtimeStatusRequest &&
        selected?.id === provider.id &&
        selected?.runtime_id === provider.runtime_id &&
        selected?.extension_id === provider.extension_id;
    };
    _renderSetupRuntimeStatus({ status: "starting" });
    const started = await RuntimeProvider.authenticate(provider);
    if (!isCurrent()) return;
    if (!started.ok) {
      _renderSetupRuntimeStatus(started);
      return;
    }

    const result = await RuntimeProvider.pollStatus(provider, {
      maxAttempts: RuntimeProvider.AUTH_POLL_ATTEMPTS,
      intervalMs: 1000,
      shouldContinue: isCurrent,
      onUpdate: (data, view) => {
        if (isCurrent()) {
          _renderSetupRuntimeStatus(data, view);
        }
      },
    });
    if (isCurrent()) {
      _renderSetupRuntimeStatus(result, result.view);
      const view = result.view || RuntimeProvider.statusView(result);
      if (view.connected) {
        const discovery = await RuntimeProvider.discover(provider);
        if (isCurrent()) _applySetupRuntimeDiscovery(discovery);
      }
    }
  }

  function _syncSetupProviderMode(provider) {
    const runtime = RuntimeProvider.isRuntimeProvider(provider);
    const apiFields = $("setup-api-fields");
    const runtimePanel = $("setup-runtime-panel");
    const continueBtn = $("setup-btn-test");
    if (apiFields) apiFields.style.display = runtime ? "none" : "";
    if (runtimePanel) runtimePanel.style.display = runtime ? "" : "none";
    if (continueBtn) {
      continueBtn.disabled = runtime;
      continueBtn.textContent = I18n.t(runtime ? "runtime.provider.continue" : "onboard.key.btn.test");
    }
    if (runtime) {
      _setupRuntimeModels = [];
      _setupRuntimeStatusData = null;
      const input = $("setup-model");
      input.readOnly = true;
      _refreshSetupRuntimeStatus(provider);
    } else {
      _runtimeStatusRequest += 1;
      _setupRuntimeModels = [];
      _setupRuntimeStatusData = null;
      const input = $("setup-model");
      if (input) input.readOnly = false;
    }
  }

  function _setSetupProviderBusy(busy) {
    _providerOperationInFlight = busy;
    const setup = $("setup-manual-section");
    if (setup) {
      setup.setAttribute("aria-busy", busy ? "true" : "false");
      setup.querySelectorAll("input, button, select, textarea").forEach(control => {
        if (busy) {
          if (!control.hasAttribute("data-provider-operation-disabled")) {
            control.dataset.providerOperationDisabled = control.disabled ? "true" : "false";
          }
          control.disabled = true;
        } else if (control.hasAttribute("data-provider-operation-disabled")) {
          control.disabled = control.dataset.providerOperationDisabled === "true";
          delete control.dataset.providerOperationDisabled;
        }
      });
    }

    const trigger = $("setup-provider-wrapper")?.querySelector(".custom-select-trigger");
    const dropdown = $("setup-provider-dropdown");
    if (trigger) {
      trigger.setAttribute("aria-disabled", busy ? "true" : "false");
      trigger.style.pointerEvents = busy ? "none" : "";
      if (busy) {
        if (!trigger.hasAttribute("data-provider-operation-tabindex")) {
          trigger.dataset.providerOperationTabindex = trigger.getAttribute("tabindex") || "";
        }
        trigger.setAttribute("tabindex", "-1");
        trigger.blur();
      } else if (trigger.hasAttribute("data-provider-operation-tabindex")) {
        const previous = trigger.dataset.providerOperationTabindex;
        if (previous) trigger.setAttribute("tabindex", previous);
        else trigger.removeAttribute("tabindex");
        delete trigger.dataset.providerOperationTabindex;
      }
    }
    if (dropdown) dropdown.style.pointerEvents = busy ? "none" : "";
    if (busy) {
      if (_setupProviderSelect) _setupProviderSelect.close();
      const modelDropdown = $("setup-model-dropdown");
      const baseUrlDropdown = $("setup-base-url-dropdown");
      if (modelDropdown) modelDropdown.style.display = "none";
      if (baseUrlDropdown) baseUrlDropdown.style.display = "none";
    }
  }

  function _selectSetupProvider(value) {
    if (_providerOperationInFlight) {
      if (_setupProviderSelect) _setupProviderSelect.setValue(_selectedProviderId || "");
      return;
    }

    const previousProviderId = _selectedProviderId || "";
    const previousWasRuntime = RuntimeProvider.isRuntimeProvider(_selectedSetupProvider());
    _selectedProviderId = value || null;
    const provider = _selectedSetupProvider();
    const nextIsRuntime = RuntimeProvider.isRuntimeProvider(provider);
    const providerChanged = previousProviderId !== (_selectedProviderId || "");
    const getApiKeyLink = $("setup-get-apikey-link");

    _providerOperationRequest += 1;
    _setResult(null, "");
    if (providerChanged || previousWasRuntime !== nextIsRuntime) _clearSetupApiFields();

    if (value === "__custom__") {
      _clearSetupApiFields();
      if (getApiKeyLink) getApiKeyLink.style.display = "none";
    } else if (provider && !nextIsRuntime) {
      $("setup-model").value = provider.default_model || "";
      $("setup-base-url").value = provider.base_url || "";
      _updateSetupModelDropdown(provider.models || []);
      _updateSetupBaseUrlDropdown(provider);
      if (getApiKeyLink && provider.website_url) {
        getApiKeyLink.href = provider.website_url;
        getApiKeyLink.style.display = "";
      } else if (getApiKeyLink) {
        getApiKeyLink.style.display = "none";
      }
    } else {
      _updateSetupModelDropdown([]);
      _updateSetupBaseUrlDropdown(null);
      if (getApiKeyLink) getApiKeyLink.style.display = "none";
    }

    _syncSetupProviderMode(provider);
  }

  function _bindCustomDropdown() {
    if (_dropdownBound) return; // listeners already attached
    _dropdownBound = true;

    const wrapper = $("setup-provider-wrapper");
    _setupProviderSelect = CustomSelect.init({
      trigger: wrapper.querySelector(".custom-select-trigger"),
      dropdown: wrapper.querySelector(".custom-select-dropdown"),
      onSelect: _selectSetupProvider
    });
  }

  // Guard: key-step listeners are attached only once
  let _keyStepBound = false;

  function _bindKeyStep() {
    if (_keyStepBound) return;
    _keyStepBound = true;

    // Toggle key visibility
    const toggleBtn  = $("setup-toggle-key");
    const keyInput   = $("setup-api-key");
    const eyeIcon    = toggleBtn.querySelector("svg");

    toggleBtn.addEventListener("click", () => {
      const isPassword = keyInput.type === "password";
      keyInput.type = isPassword ? "text" : "password";
      eyeIcon.innerHTML = isPassword
        ? `<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"></path>`
        : `<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"></path>`;
    });

    // ── Model combobox dropdown ───────────────────────────────────────────────
    const modelDropdownBtn = $("setup-model-dropdown-btn");
    const modelDropdown    = $("setup-model-dropdown");
    const modelInput       = $("setup-model");

    modelDropdownBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = modelDropdown.style.display === "block";
      // Close sibling dropdown to avoid overlap.
      $("setup-base-url-dropdown").style.display = "none";
      modelDropdown.style.display = isOpen ? "none" : "block";
    });

    // ── Base URL combobox dropdown ────────────────────────────────────────────
    // Shows preset.endpoint_variants (e.g. GLM mainland vs Z.ai international).
    // Rendering is driven by the currently selected provider — see the
    // provider custom-select handler above, which calls
    // _updateSetupBaseUrlDropdown(preset) on every switch.
    const baseUrlDropdownBtn = $("setup-base-url-dropdown-btn");
    const baseUrlDropdown    = $("setup-base-url-dropdown");

    baseUrlDropdownBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = baseUrlDropdown.style.display === "block";
      // Close sibling dropdown (model combobox) to avoid overlap.
      modelDropdown.style.display = "none";
      baseUrlDropdown.style.display = isOpen ? "none" : "block";
    });

    document.addEventListener("click", () => {
      modelDropdown.style.display   = "none";
      baseUrlDropdown.style.display = "none";
    });

    $("setup-btn-test").addEventListener("click", _testAndSave);
    $("setup-runtime-login").addEventListener("click", _authenticateSetupRuntime);
    $("setup-runtime-recheck").addEventListener("click", () => _refreshSetupRuntimeStatus());

    $("setup-manual-toggle").addEventListener("click", () => {
      $("setup-device-block").style.display  = "none";
      $("setup-manual-toggle").style.display = "none";
      $("setup-manual-section").style.display = "";
    });

    $("setup-btn-back").addEventListener("click", () => {
      if (!_branded && $("setup-manual-section").style.display !== "none") {
        // Non-brand: collapse manual section back to device card
        $("setup-device-block").style.display  = "";
        $("setup-manual-toggle").style.display = "";
        $("setup-manual-section").style.display = "none";
      } else {
        _showSetupStep("lang");
      }
    });

    _bindDeviceStep();
  }

  // ── Device-authorization login (primary onboarding path) ──────────────────
  let _devicePolling = false;

  function _bindDeviceStep() {
    const btn = $("setup-btn-device-login");
    if (btn) btn.addEventListener("click", _startDeviceLogin);

    const cancel = $("setup-device-cancel");
    if (cancel) cancel.addEventListener("click", () => {
      _devicePolling = false;
      _showDevicePending(false);
    });

    const continueBtn = $("setup-btn-device-continue");
    if (continueBtn) continueBtn.addEventListener("click", () => {
      _launchOnboardSession();
    });
  }

  function _showDevicePending(on) {
    const pending = $("setup-device-pending");
    const card    = $("setup-device-card");
    if (pending) pending.style.display = on ? "" : "none";
    if (card)    card.style.display    = on ? "none" : "";
  }

  function _showDeviceSuccess(model) {
    const pending = $("setup-device-pending");
    const card    = $("setup-device-card");
    const success = $("setup-device-success");
    const modelEl = $("setup-device-success-model");
    if (pending) pending.style.display = "none";
    if (card)    card.style.display    = "none";
    if (success) success.style.display = "";
    if (modelEl && model) modelEl.textContent = model;
  }

  function _setDeviceError(msg) {
    const el = $("setup-device-error");
    if (!el) return;
    el.textContent = msg ? "✗ " + msg : "";
    el.className   = "setup-test-result" + (msg ? " result-fail" : "");
  }

  async function _startDeviceLogin() {
    const zh = _selectedLang === "zh";
    _setDeviceError("");

    const w = window.open("about:blank", "_blank");

    let data;
    try {
      const res = await fetch("/api/onboard/device/start", { method: "POST" });
      data = await res.json();
    } catch (_) {
      data = null;
    }

    if (!data || !data.ok) {
      if (w && !w.closed) w.close();
      _setDeviceError((data && data.error) || (zh ? "无法发起登录，请稍后重试。" : "Could not start login. Please try again."));
      return;
    }

    const url = data.verification_uri_complete || data.verification_uri;
    const codeEl = $("setup-device-usercode");
    if (codeEl) codeEl.textContent = data.user_code || "—";
    const link = $("setup-device-link");
    if (link && url) link.href = url;

    _showDevicePending(true);
    if (w && !w.closed) {
      w.location.href = url;
    } else {
      window.open(url, "_blank");
    }

    _devicePolling = true;
    _pollDevice(data.device_code, (data.interval || 5) * 1000);
  }

  async function _pollDevice(deviceCode, intervalMs) {
    const zh = _selectedLang === "zh";

    while (_devicePolling) {
      await new Promise(r => setTimeout(r, intervalMs));
      if (!_devicePolling) return;

      let data;
      try {
        const res = await fetch("/api/onboard/device/poll", {
          method:  "POST",
          headers: { "Content-Type": "application/json" },
          body:    JSON.stringify({ device_code: deviceCode })
        });
        data = await res.json();
      } catch (_) {
        continue; // transient network error — keep polling
      }

      if (data.status === "approved") {
        _devicePolling = false;
        _showDeviceSuccess(data.default_model);
        return;
      }
      if (data.status === "pending") continue;

      // denied / expired / consumed / error
      _devicePolling = false;
      _showDevicePending(false);
      const msg = data.status === "denied"
        ? (zh ? "授权已被拒绝。" : "Authorization was denied.")
        : (zh ? "授权已过期，请重新登录。" : "Authorization expired. Please try again.");
      _setDeviceError(data.error || msg);
      return;
    }
  }

  async function _testAndSave() {
    const provider = _selectedSetupProvider();
    if (RuntimeProvider.isRuntimeProvider(provider)) {
      await _saveRuntimeProvider(provider);
      return;
    }

    const btn     = $("setup-btn-test");
    const model   = $("setup-model").value.trim();
    const baseUrl = $("setup-base-url").value.trim();
    const apiKey  = $("setup-api-key").value.trim();
    const zh      = _selectedLang === "zh";

    if (!model || !baseUrl || !apiKey) {
      _setResult(false, zh ? "请填写模型、Base URL 和 API Key。" : "Please fill in Model, Base URL and API Key.");
      return;
    }

    const operation = ++_providerOperationRequest;
    const providerId = _selectedProviderId;
    _setSetupProviderBusy(true);
    btn.disabled    = true;
    btn.textContent = I18n.t("onboard.key.testing");
    _setResult(null, "");

    // Step 1: test connection
    const testResult = await ModelTester.testConnection({
      model, base_url: baseUrl, api_key: apiKey, index: 0
    });
    if (operation !== _providerOperationRequest || providerId !== _selectedProviderId) return;

    if (!testResult.ok) {
      _setSetupProviderBusy(false);
      _setResult(false, testResult.message || (zh ? "连接失败。" : "Connection failed."));
      btn.disabled    = false;
      btn.textContent = I18n.t("onboard.key.btn.test");
      return;
    }

    let effectiveBaseUrl = testResult.base_url;
    if (testResult.rewrote) {
      const baseInput = document.getElementById("setup-base-url");
      if (baseInput) baseInput.value = effectiveBaseUrl;
    }

    // Step 2: save config
    btn.textContent = I18n.t("onboard.key.saving");
    const saveResult = await ModelTester.saveModel({
      type: "default",
      provider_id: _selectedProviderId === "__custom__" ? "custom" : _selectedProviderId,
      model,
      base_url: effectiveBaseUrl,
      api_key: apiKey
    });
    if (operation !== _providerOperationRequest || providerId !== _selectedProviderId) return;
    if (!saveResult.ok) {
      _setSetupProviderBusy(false);
      _setResult(false, saveResult.error || (zh ? "保存失败。" : "Save failed."));
      btn.disabled    = false;
      btn.textContent = I18n.t("onboard.key.btn.test");
      return;
    }

    // Success — show brief feedback then auto-launch /onboard session
    _setResult(true, zh ? "连接成功！" : "Connected!");
    setTimeout(() => {
      if (operation === _providerOperationRequest && providerId === _selectedProviderId) {
        _launchOnboardSession();
      }
    }, 600);
  }

  async function _saveRuntimeProvider(provider) {
    const operation = ++_providerOperationRequest;
    const providerId = provider.id;
    const btn = $("setup-btn-test");
    _setSetupProviderBusy(true);
    btn.disabled = true;
    _setResult(null, "");

    const selectedModel = $("setup-model").value.trim();
    const status = await RuntimeProvider.discover(provider);
    if (operation !== _providerOperationRequest || providerId !== _selectedProviderId) return;
    const view = _renderSetupRuntimeStatus(status);
    if (!view.connected || !status.models.includes(selectedModel)) {
      _setSetupProviderBusy(false);
      btn.disabled = true;
      return;
    }

    btn.textContent = I18n.t("onboard.key.saving");
    const saveResult = await ModelTester.saveModel({
      provider_id: provider.id,
      display_model: selectedModel,
      type: "default",
    });
    if (operation !== _providerOperationRequest || providerId !== _selectedProviderId) return;
    if (!saveResult.ok) {
      _setSetupProviderBusy(false);
      _setResult(false, saveResult.error || I18n.t("settings.models.saveFailed"));
      btn.disabled = false;
      btn.textContent = I18n.t("runtime.provider.continue");
      return;
    }

    _setResult(true, I18n.t("runtime.provider.status.connected"));
    setTimeout(() => {
      if (operation === _providerOperationRequest && providerId === _selectedProviderId) {
        _launchOnboardSession({ personalize: false, modelId: saveResult.id });
      }
    }, 600);
  }

  function _setResult(ok, msg) {
    const el = $("setup-test-result");
    if (!el) return;
    if (ok === null) { el.textContent = ""; el.className = "setup-test-result"; return; }
    el.textContent = ok ? "✓ " + msg : "✗ " + msg;
    el.className   = "setup-test-result " + (ok ? "result-ok" : "result-fail");
  }

  // ── /onboard session launcher ───────────────────────────────────────────────

  async function _createSetupSession(modelId) {
    const body = { name: "Onboard", source: "setup" };
    if (modelId) body.model_id = modelId;
    const res = await fetch("/api/sessions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok || !data.session) throw new Error(data.error || "failed to create session");
    return data.session;
  }

  // Create a dedicated session and send the /onboard slash command.
  // Called after provider setup succeeds AND on soul_setup phase (auto, no panel shown).
  async function _launchOnboardSession({ personalize = true, modelId = null } = {}) {
    try {
      const completed = await _complete();
      if (personalize) {
        await Sessions.startWith(`/onboard lang:${_selectedLang}`, { name: "Onboard", source: "setup" });
      } else {
        let session = completed && completed.session;
        if (!modelId || !session || session.model_id !== modelId) {
          session = await _createSetupSession(modelId);
        }
        Sessions.add(session);
        Sessions.renderList();
        Sessions.select(session.id);
      }
      _bootUI();
    } catch (_) {
      // Fallback: just boot normally if session creation fails
      _bootUI();
    }
  }

  // POST /api/onboard/complete — finalizes setup and creates a default session if missing.
  async function _complete() {
    try {
      const res = await fetch("/api/onboard/complete", { method: "POST" });
      return await res.json();
    } catch (_) { return null; }
  }

  // Boot the normal UI (WS + sessions sidebar + tasks + skills).
  function _bootUI() {
    _setSetupProviderBusy(false);
    document.body.classList.remove("setup-mode");
    SkillAC.init();
    WS.connect();
    Tasks.load();
    Skills.load();
  }

  return { check, startSoulSession: _launchOnboardSession };
})();
