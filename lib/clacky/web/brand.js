// brand.js — White-label branding support
//
// Responsibilities:
//   1. On boot, fetch GET /api/brand/status
//      - If needs_activation → show brand activation panel (like onboard)
//      - If branded + warning → show a dismissible warning bar
//      - If not branded → no-op (standard OpenClacky experience)
//   2. Fetch GET /api/brand and apply brand_name to all branded DOM elements
//
// Load order: must be loaded after onboard.js and before app.js

const Brand = (() => {

  // ── Public API ─────────────────────────────────────────────────────────────

  // Whether the server was started with --brand-test (set during check()).
  let _testMode = false;

  // Check brand status. Returns true if activation is needed
  // (caller should defer normal UI boot until activation is done or skipped).
  async function check() {
    try {
      const res  = await fetch("/api/brand/status");
      const data = await res.json();

      _testMode = !!data.test_mode;

      if (!data.branded) return false;

      // Brand name is already baked into the HTML by the server at request time,
      // so no DOM update is needed here on boot.

      if (data.needs_activation) {
        _showActivationPanel(data.brand_name);
        return true;
      }

      if (data.warning) _showWarning(data.warning);

      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  function _showActivationPanel(brandName) {
    if (brandName) {
      const title = $("brand-title");
      const sub   = $("brand-subtitle");
      if (title) title.textContent = "Activate " + brandName;
      if (sub)   sub.textContent   = "Enter your license key to get started.";
    }
    Router.navigate("brand");
    _bindActivationPanel();
  }

  function _bindActivationPanel() {
    $("brand-btn-activate").addEventListener("click", _doActivate);
    $("brand-license-key").addEventListener("keydown", e => {
      if (e.key === "Enter") _doActivate();
    });
    $("brand-btn-skip").addEventListener("click", _skipActivation);
  }

  async function _doActivate() {
    const btn = $("brand-btn-activate");
    const key = $("brand-license-key").value.trim();

    if (!key) {
      _setResult(false, "Please enter your license key.");
      return;
    }

    // In brand-test mode accept any non-empty key so developers can test without a real license.
    if (!_testMode && !/^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{8}){4}$/.test(key)) {
      _setResult(false, "Invalid format. Expected: XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX");
      return;
    }

    btn.disabled    = true;
    btn.textContent = "Activating...";
    _setResult(null, "");

    try {
      const res  = await fetch("/api/brand/activate", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ license_key: key })
      });
      const data = await res.json();

      if (data.ok) {
        _setResult(true, "License activated successfully!");
        if (data.brand_name) _applyBrandName(data.brand_name);
        setTimeout(_bootUI, 800);
      } else {
        _setResult(false, data.error || "Activation failed. Please try again.");
        btn.disabled    = false;
        btn.textContent = "Activate";
      }
    } catch (e) {
      _setResult(false, "Network error: " + e.message);
      btn.disabled    = false;
      btn.textContent = "Activate";
    }
  }

  function _skipActivation() {
    _bootUI();
  }

  function _setResult(ok, msg) {
    const el = $("brand-activate-result");
    if (!el) return;
    if (ok === null) { el.textContent = ""; el.className = "onboard-test-result"; return; }
    el.textContent = ok ? msg : msg;
    el.className   = "onboard-test-result " + (ok ? "result-ok" : "result-fail");
  }

  // Replace all branded text nodes in the DOM.
  function _applyBrandName(name) {
    const nodes = {
      "page-title":    name,
      "sidebar-logo":  name,
      "onboard-title": "Welcome to " + name,
      "welcome-title": "Welcome to " + name
    };
    Object.entries(nodes).forEach(([id, text]) => {
      const el = $(id);
      if (el) el.textContent = text;
    });
  }

  // Show a dismissible warning bar above the main content.
  function _showWarning(message) {
    const existing = document.getElementById("brand-warning-bar");
    if (existing) return;

    const bar = document.createElement("div");
    bar.id        = "brand-warning-bar";
    bar.className = "brand-warning-bar";
    bar.innerHTML = `<span>${escapeHtml(message)}</span>
                     <button onclick="this.parentElement.remove()">&#x2715;</button>`;
    document.getElementById("main").prepend(bar);
  }

  // Boot the normal UI (mirrors Onboard._bootUI).
  function _bootUI() {
    WS.connect();
    Tasks.load();
    Skills.load();
  }

  return { check, applyBrandName: _applyBrandName };
})();
