// Shared helpers for the model config UI flows.
// Used by both the onboarding wizard and the settings model modal.
window.ModelTester = (function () {
  // Test a model connection.
  // Returns one of:
  //   { ok: true,  base_url, message }                 — connected, no rewrite
  //   { ok: true,  base_url, message, rewrote: true }  — connected, base_url auto-corrected (/v1 appended)
  //   { ok: false, message }                           — failed (server-reported or network)
  async function testConnection({ model, base_url, api_key, anthropic_format, index } = {}) {
    const body = { model, base_url, api_key };
    if (typeof index === "number") body.index = index;
    if (anthropic_format) body.anthropic_format = true;

    let data;
    try {
      const res = await fetch("/api/config/test", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify(body)
      });
      data = await res.json();
    } catch (e) {
      return { ok: false, message: e.message };
    }

    if (!data.ok) return { ok: false, message: data.message || "" };

    if (data.effective_base_url && data.effective_base_url !== base_url) {
      return { ok: true, base_url: data.effective_base_url, message: data.message || "", rewrote: true };
    }
    return { ok: true, base_url, message: data.message || "" };
  }

  // Persist a model config (create or update).
  // existingId === null/undefined → POST /api/config/models (create).
  // existingId === string         → PATCH /api/config/models/:id (update).
  // Returns { ok: bool, error? }.
  async function saveModel(payload, { existingId } = {}) {
    const url = existingId
      ? `/api/config/models/${encodeURIComponent(existingId)}`
      : "/api/config/models";
    const method = existingId ? "PATCH" : "POST";

    try {
      const res  = await fetch(url, {
        method,
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify(payload)
      });
      const data = await res.json();
      return data.ok ? { ok: true } : { ok: false, error: data.error || "" };
    } catch (e) {
      return { ok: false, error: e.message };
    }
  }

  return { testConnection, saveModel };
})();
