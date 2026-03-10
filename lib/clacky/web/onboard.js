// onboard.js — First-run onboarding flow
//
// Phase 1 (key_setup):  User picks a provider, enters API key, tests & saves.
// Phase 2 (soul_setup): Open a dedicated session and invoke the /onboard skill,
//                       which uses interactive cards to collect preferences and
//                       write SOUL.md + USER.md.
//
// Pattern: same as Tasks.createInSession() — create session → select (subscribe)
//          → send slash command. No custom pending state needed.

const Onboard = (() => {
  let _providers = [];
  let _phase = null;  // "key_setup" | "soul_setup"

  // ── Public API ──────────────────────────────────────────────────────────────

  // Check onboard status and show panel if needed.
  // Returns true if onboard is needed (caller should NOT boot normal UI yet).
  async function check() {
    try {
      const res  = await fetch("/api/onboard/status");
      const data = await res.json();
      if (!data.needs_onboard) return false;

      _phase = data.phase;
      await _show(_phase);
      return true;
    } catch (e) {
      // If the status check fails, proceed with normal boot
      return false;
    }
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  async function _show(phase) {
    // Show onboard panel, hide everything else
    Router.navigate("onboard");

    // Render the empty session list placeholder immediately (WS is not connected yet
    // during onboarding, so renderList() would never be called otherwise).
    Sessions.renderList();

    if (phase === "key_setup") {
      _showPhase("key");
      await _loadProviders();
      _bindKeyPhase();
    } else {
      // soul_setup: key already configured, jump straight to phase 2
      _showPhase("soul");
      _bindSoulPhase();
    }
  }

  function _showPhase(which) {
    $("onboard-phase-key").style.display  = which === "key"  ? "" : "none";
    $("onboard-phase-soul").style.display = which === "soul" ? "" : "none";
    $("step-dot-1").className = "onboard-step" + (which === "key"  ? " active" : " done");
    $("step-dot-2").className = "onboard-step" + (which === "soul" ? " active" : "");
  }

  // ── Phase 1: Key setup ──────────────────────────────────────────────────────

  async function _loadProviders() {
    try {
      const res  = await fetch("/api/providers");
      const data = await res.json();
      _providers = data.providers || [];
      
      const dropdown = $("onboard-provider-dropdown");
      _providers.forEach(p => {
        const option = document.createElement("div");
        option.className = "custom-select-option";
        option.dataset.value = p.id;
        option.textContent = p.name;
        dropdown.appendChild(option);
      });
      
      // Bind custom dropdown events
      _bindCustomDropdown();
    } catch (_) { /* ignore */ }
  }

  function _bindCustomDropdown() {
    const wrapper = $("onboard-provider-wrapper");
    const trigger = wrapper.querySelector(".custom-select-trigger");
    const dropdown = wrapper.querySelector(".custom-select-dropdown");
    const valueSpan = trigger.querySelector(".custom-select-value");
    const options = dropdown.querySelectorAll(".custom-select-option");

    // Toggle dropdown
    trigger.addEventListener("click", (e) => {
      e.stopPropagation();
      const isOpen = dropdown.classList.contains("open");
      if (isOpen) {
        dropdown.classList.remove("open");
        trigger.classList.remove("open");
      } else {
        dropdown.classList.add("open");
        trigger.classList.add("open");
      }
    });

    // Select option
    options.forEach(option => {
      option.addEventListener("click", (e) => {
        e.stopPropagation();
        const value = option.dataset.value;
        const text = option.textContent;
        
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
        if (value) {
          const preset = _providers.find(p => p.id === value);
          if (preset) {
            $("onboard-model").value    = preset.default_model || "";
            $("onboard-base-url").value = preset.base_url      || "";
          }
        }
      });
    });

    // Close dropdown when clicking outside
    document.addEventListener("click", () => {
      dropdown.classList.remove("open");
      trigger.classList.remove("open");
    });
  }

  function _bindKeyPhase() {
    // Toggle key visibility with icon change
    const toggleKeyBtn = $("onboard-toggle-key");
    const apiKeyInput = $("onboard-api-key");
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

    // Test & Continue
    $("onboard-btn-test").addEventListener("click", _testAndSave);
  }

  async function _testAndSave() {
    const btn     = $("onboard-btn-test");
    const model   = $("onboard-model").value.trim();
    const baseUrl = $("onboard-base-url").value.trim();
    const apiKey  = $("onboard-api-key").value.trim();

    if (!model || !baseUrl || !apiKey) {
      _setTestResult(false, "Please fill in Model, Base URL and API Key.");
      return;
    }

    btn.disabled    = true;
    btn.textContent = "Testing…";
    _setTestResult(null, "");

    // Step 1: test connection
    try {
      const testRes  = await fetch("/api/config/test", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ model, base_url: baseUrl, api_key: apiKey, index: 0 })
      });
      const testData = await testRes.json();
      if (!testData.ok) {
        _setTestResult(false, testData.message || "Connection failed.");
        btn.disabled    = false;
        btn.textContent = "Test & Continue →";
        return;
      }
    } catch (e) {
      _setTestResult(false, e.message);
      btn.disabled    = false;
      btn.textContent = "Test & Continue →";
      return;
    }

    // Step 2: save config
    btn.textContent = "Saving…";
    try {
      const saveRes  = await fetch("/api/config", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({
          models: [{ type: "default", model, base_url: baseUrl, api_key: apiKey, anthropic_format: false }]
        })
      });
      const saveData = await saveRes.json();
      if (!saveData.ok) {
        _setTestResult(false, saveData.error || "Save failed.");
        btn.disabled    = false;
        btn.textContent = "Test & Continue →";
        return;
      }
    } catch (e) {
      _setTestResult(false, e.message);
      btn.disabled    = false;
      btn.textContent = "Test & Continue →";
      return;
    }

    // Step 3: advance to phase 2
    _setTestResult(true, "Connected!");
    setTimeout(() => {
      _showPhase("soul");
      _bindSoulPhase();
    }, 600);
  }

  function _setTestResult(ok, msg) {
    const el = $("onboard-test-result");
    if (ok === null) { el.textContent = ""; el.className = "onboard-test-result"; return; }
    el.textContent = ok ? "✓ " + msg : "✗ " + msg;
    el.className   = "onboard-test-result " + (ok ? "result-ok" : "result-fail");
  }

  // ── Phase 2: Soul setup ──────────────────────────────────────────────────────

  function _bindSoulPhase() {
    $("onboard-btn-start-soul").addEventListener("click", _startSoulSession);
    $("onboard-btn-skip").addEventListener("click",       _skipSoul);
  }

  // Start the onboard skill in a dedicated session.
  // Pattern: identical to Tasks.createInSession() — create session → boot UI
  // → select session (triggers WS subscribe) → send /onboard slash command.
  async function _startSoulSession() {
    const btn = $("onboard-btn-start-soul");
    btn.disabled    = true;
    btn.textContent = "Starting…";

    try {
      // Ensure config is persisted, then create the onboard session
      await _complete();
      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name: "✨ Onboard" })
      });
      const data = await res.json();
      const session = data.session;
      if (!session) throw new Error("No session returned");

      // Boot WS + UI first so Sessions/Router are available
      _bootUI();

      // Select the session (triggers WS subscribe) then fire the skill command
      Sessions.add(session);
      Sessions.renderList();
      Sessions.setPendingMessage(session.id, "/onboard");
      Sessions.select(session.id);
    } catch (e) {
      btn.disabled    = false;
      btn.textContent = "Let's go →";
    }
  }

  async function _skipSoul() {
    // Write a default SOUL.md so onboard isn't re-triggered, then boot normally
    await _complete();
    await _ensureSoulFile();
    _bootUI();
  }

  // POST /api/onboard/complete — persists config, creates default session if missing.
  async function _complete() {
    try {
      const res = await fetch("/api/onboard/complete", { method: "POST" });
      return await res.json();
    } catch (_) { return null; }
  }

  // POST /api/onboard/skip-soul — writes a minimal default SOUL.md.
  async function _ensureSoulFile() {
    try {
      await fetch("/api/onboard/skip-soul", { method: "POST" });
    } catch (_) { /* ignore */ }
  }

  // Boot the normal UI (WS + sessions sidebar + tasks + skills).
  function _bootUI() {
    WS.connect();
    Tasks.load();
    Skills.load();
  }

  return { check, startSoulSession: _startSoulSession };
})();
