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
      const sel  = $("onboard-provider-select");
      _providers.forEach(p => {
        const opt = document.createElement("option");
        opt.value       = p.id;
        opt.textContent = p.name;
        sel.appendChild(opt);
      });
    } catch (_) { /* ignore */ }
  }

  function _bindKeyPhase() {
    // Provider quick-fill
    $("onboard-provider-select").addEventListener("change", e => {
      const preset = _providers.find(p => p.id === e.target.value);
      if (!preset) return;
      $("onboard-model").value    = preset.default_model || "";
      $("onboard-base-url").value = preset.base_url      || "";
    });

    // Toggle key visibility
    $("onboard-toggle-key").addEventListener("click", () => {
      const inp = $("onboard-api-key");
      inp.type = inp.type === "password" ? "text" : "password";
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
      Sessions.select(session.id);
      WS.send({ type: "message", session_id: session.id, content: "/onboard" });
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
