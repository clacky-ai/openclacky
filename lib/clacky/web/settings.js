// settings.js — Settings panel logic
// Handles reading, editing, saving, testing AI model configurations.

const Settings = (() => {
  // Local copy of models loaded from server
  let _models = [];
  // Provider presets loaded from server
  let _providers = [];

  // ── Public API ──────────────────────────────────────────────────────────────

  function open() {
    _load();
    _loadBrand();
  }

  // ── Data Loading ────────────────────────────────────────────────────────────

  async function _load() {
    const container = document.getElementById("model-cards");
    container.innerHTML = `<div class="settings-loading">Loading…</div>`;
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
      container.innerHTML = `<div class="settings-error">Failed to load config: ${e.message}</div>`;
    }
  }

  // ── Rendering ───────────────────────────────────────────────────────────────

  function _renderCards() {
    const container = document.getElementById("model-cards");
    container.innerHTML = "";

    if (_models.length === 0) {
      container.innerHTML = `<div class="settings-empty">No models configured. Click "+ Add Model" to add one.</div>`;
      return;
    }

    _models.forEach((m, i) => _renderCard(container, m, i));
  }

  function _renderCard(container, model, index) {
    const isDefault = model.type === "default";
    const isLite    = model.type === "lite";

    const card = document.createElement("div");
    card.className = "model-card";
    card.dataset.index = index;

    // Build provider options
    const providerOptions = _providers.map(p =>
      `<option value="${p.id}">${p.name}</option>`
    ).join("");

    card.innerHTML = `
      <div class="model-card-header">
        <div class="model-card-badges">
          ${isDefault ? `<span class="badge badge-default">Default</span>` : ""}
          ${isLite    ? `<span class="badge badge-lite">Lite</span>` : ""}
          ${!isDefault && !isLite ? `<span class="badge badge-secondary">Model ${index + 1}</span>` : ""}
        </div>
        <div class="model-card-actions">
          ${_models.length > 1
            ? `<button class="btn-model-remove" data-index="${index}" title="Remove this model">✕</button>`
            : ""}
        </div>
      </div>

      <div class="model-fields">
        <label class="model-field">
          <span class="field-label">Quick Setup</span>
          <select class="field-select provider-select" data-index="${index}">
            <option value="">— Choose provider —</option>
            ${providerOptions}
            <option value="custom">Custom</option>
          </select>
        </label>
        <label class="model-field">
          <span class="field-label">Model</span>
          <input type="text" class="field-input" data-key="model" data-index="${index}"
            placeholder="e.g. claude-sonnet-4-5" value="${_esc(model.model)}">
        </label>
        <label class="model-field">
          <span class="field-label">Base URL</span>
          <input type="text" class="field-input" data-key="base_url" data-index="${index}"
            placeholder="https://api.anthropic.com" value="${_esc(model.base_url)}">
        </label>
        <label class="model-field">
          <span class="field-label">API Key</span>
          <div class="field-input-row">
            <input type="password" class="field-input api-key-input" data-key="api_key" data-index="${index}"
              placeholder="sk-…" value="${_esc(model.api_key_masked)}">
            <button class="btn-toggle-key" data-index="${index}" title="Show/hide key">👁</button>
          </div>
        </label>
      </div>

      <div class="model-card-footer">
        <span class="model-test-result" data-index="${index}"></span>
        <button class="btn-save-model btn-primary" data-index="${index}">Save</button>
      </div>
    `;

    container.appendChild(card);
    _bindCardEvents(card, index);
  }

  function _bindCardEvents(card, index) {
    // Provider preset dropdown — auto-fill model & base_url
    card.querySelector(".provider-select").addEventListener("change", (e) => {
      const pid = e.target.value;
      if (!pid || pid === "custom") return;
      const preset = _providers.find(p => p.id === pid);
      if (!preset) return;

      const modelInput   = card.querySelector(`[data-key="model"]`);
      const baseUrlInput = card.querySelector(`[data-key="base_url"]`);
      if (modelInput)   modelInput.value   = preset.default_model || "";
      if (baseUrlInput) baseUrlInput.value = preset.base_url       || "";
    });

    // Toggle API key visibility
    card.querySelector(".btn-toggle-key").addEventListener("click", () => {
      const input = card.querySelector(".api-key-input");
      input.type = input.type === "password" ? "text" : "password";
    });

    // Save: auto-test first, then save if passed
    card.querySelector(".btn-save-model").addEventListener("click", () => _saveModel(index));

    // Remove model
    const removeBtn = card.querySelector(".btn-model-remove");
    if (removeBtn) {
      removeBtn.addEventListener("click", () => _removeModel(index));
    }
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
      anthropic_format: false,
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
    saveBtn.textContent = "Testing…";
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
        saveBtn.textContent = "Save";
        saveBtn.disabled = false;
        return;
      }
    } catch (e) {
      _showTestResult(index, false, e.message);
      saveBtn.textContent = "Save";
      saveBtn.disabled = false;
      return;
    }

    // Step 2: test passed — now save
    saveBtn.textContent = "Saving…";

    // Merge into _models
    _models[index] = { ..._models[index], ...updated };

    try {
      const res = await fetch("/api/config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ models: _models })
      });
      const data = await res.json();
      if (data.ok) {
        saveBtn.textContent = "Saved ✓";
        setTimeout(() => { saveBtn.textContent = "Save"; saveBtn.disabled = false; }, 1500);
        // Reload to get fresh masked keys
        setTimeout(_load, 1600);
      } else {
        saveBtn.textContent = "Save";
        saveBtn.disabled = false;
        _showTestResult(index, false, data.error || "Save failed");
      }
    } catch (e) {
      saveBtn.textContent = "Save";
      saveBtn.disabled = false;
      _showTestResult(index, false, e.message);
    }
  }

  function _showTestResult(index, ok, message) {
    const el = document.querySelector(`.model-test-result[data-index="${index}"]`);
    if (!el) return;
    if (ok === null) { el.textContent = ""; el.className = "model-test-result"; return; }
    el.textContent = ok ? `✓ ${message || "Connected"}` : `✗ ${message || "Failed"}`;
    el.className   = `model-test-result ${ok ? "result-ok" : "result-fail"}`;
  }

  // ── Add / Remove model ───────────────────────────────────────────────────────

  function _addModel() {
    _models.push({
      index:            _models.length,
      model:            "",
      base_url:         "",
      api_key_masked:   "",
      anthropic_format: false,
      type:             null
    });
    _renderCards();
    // Scroll to the new card
    const cards = document.querySelectorAll(".model-card");
    if (cards.length) cards[cards.length - 1].scrollIntoView({ behavior: "smooth" });
  }

  async function _removeModel(index) {
    if (_models.length <= 1) return;
    if (!confirm(`Remove model "${_models[index]?.model || index + 1}"?`)) return;

    _models.splice(index, 1);

    try {
      await fetch("/api/config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ models: _models })
      });
    } catch (_) { /* ignore */ }

    // Reload fresh state
    _load();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function _esc(str) {
    return (str || "").replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
  }

  // ── Rerun onboard ────────────────────────────────────────────────────────────

  async function _rerunOnboard() {
    const btn = document.getElementById("btn-rerun-onboard");
    btn.disabled    = true;
    btn.textContent = "Starting…";

    try {
      // Close settings panel and navigate to chat, then start the onboard session.
      // Onboard.startSoulSession() creates a new session, selects it, and sends /onboard.
      Router.navigate("chat");
      await Onboard.startSoulSession();
    } catch (e) {
      btn.disabled    = false;
      btn.textContent = "✨ Re-run Onboard";
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

      document.getElementById("brand-status-name").textContent = data.brand_name || "—";

      const badge = document.getElementById("brand-status-badge");
      if (data.warning) {
        badge.textContent  = "Warning";
        badge.className    = "brand-status-value badge-expired";
      } else {
        badge.textContent  = "Active";
        badge.className    = "brand-status-value badge-active";
      }

      // Fetch full brand info for expiry date
      fetch("/api/brand").then(r => r.json()).then(info => {
        const expiresEl = document.getElementById("brand-status-expires");
        if (info.license_expires_at) {
          expiresEl.textContent = new Date(info.license_expires_at).toLocaleDateString();
        } else {
          expiresEl.textContent = "—";
        }
      }).catch(() => {
        document.getElementById("brand-status-expires").textContent = "—";
      });

    } else {
      // Not activated (or needs activation) — show form, hide status card
      statusCard.style.display   = "none";
      activateForm.style.display = "";

      // Pre-fill brand name in input placeholder if we know it
      if (data.brand_name) {
        const desc = activateForm.querySelector(".brand-activate-desc");
        if (desc) desc.textContent =
          `Enter your ${data.brand_name} license key to activate branded mode.`;
      }
    }
  }

  async function _activateLicense() {
    const input  = document.getElementById("settings-license-key");
    const btn    = document.getElementById("btn-settings-activate");
    const result = document.getElementById("settings-activate-result");
    const key    = input.value.trim();

    if (!key) {
      _showBrandResult(false, "Please enter a license key.");
      return;
    }

    // In brand-test mode skip strict key format validation so developers can use any test key.
    if (!_brandTestMode && !/^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{8}){4}$/.test(key)) {
      _showBrandResult(false, "Invalid format. Expected: XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX");
      return;
    }

    btn.disabled    = true;
    btn.textContent = "Activating…";
    _showBrandResult(null, "");

    try {
      const res  = await fetch("/api/brand/activate", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ license_key: key })
      });
      const data = await res.json();

      if (data.ok) {
        _showBrandResult(true, `License activated! Brand: ${data.brand_name || "configured"}`);
        // Apply brand name across the entire UI immediately
        if (data.brand_name) Brand.applyBrandName(data.brand_name);
        // Reload brand status card after short delay
        setTimeout(_loadBrand, 800);
      } else {
        _showBrandResult(false, data.error || "Activation failed. Please try again.");
      }
    } catch (e) {
      _showBrandResult(false, "Network error: " + e.message);
    } finally {
      btn.disabled    = false;
      btn.textContent = "Activate";
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

  function init() {
    document.getElementById("btn-add-model").addEventListener("click", _addModel);
    document.getElementById("btn-rerun-onboard").addEventListener("click", _rerunOnboard);

    document.getElementById("btn-settings-activate").addEventListener("click", _activateLicense);
    document.getElementById("settings-license-key").addEventListener("keydown", e => {
      if (e.key === "Enter") _activateLicense();
    });
    document.getElementById("btn-rebind-license").addEventListener("click", () => {
      // Show the form again so user can enter a new key
      document.getElementById("brand-status-card").style.display   = "none";
      document.getElementById("brand-activate-form").style.display = "";
      document.getElementById("settings-license-key").value = "";
      document.getElementById("settings-license-key").focus();
    });
  }

  return { open, init, loadBrand: _loadBrand };
})();
