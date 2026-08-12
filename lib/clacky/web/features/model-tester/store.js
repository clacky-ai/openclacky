// ── ModelTester · store — model connection test + save (shared helper) ────
//
// Network helpers shared by the onboarding wizard and the settings model modal:
// test a model connection and persist a model config. No own panel, no state to
// hold — it mirrors test/save outcomes onto the extension bus so extensions can
// observe model-config changes.
//
// `ModelTester` stays the single public facade.
//
// Depends on: I18n, Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────

window.ModelTester = (function () {
  function _emit(event, payload) {
    if (window.Clacky && Clacky.ext) Clacky.ext.emit(event, payload);
  }

  async function testConnection({ model, base_url, api_key, api_protocol, anthropic_format, index, id } = {}) {
    const body = { model, base_url, api_key };
    if (typeof id === "string" && id) body.id = id;
    if (typeof index === "number") body.index = index;
    if (api_protocol) body.api_protocol = api_protocol;
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

    let result;
    if (!data.ok) {
      const msg  = data.message || "";
      const code = data.error_code || "";
      result = code === "insufficient_credit"
        ? { ok: false, message: I18n.t("error.insufficient_credit"), error_code: code }
        : { ok: false, message: msg, error_code: code };
    } else if (data.effective_base_url && data.effective_base_url !== base_url) {
      result = { ok: true, base_url: data.effective_base_url, message: data.message || "", rewrote: true };
    } else {
      result = { ok: true, base_url, message: data.message || "" };
    }

    _emit("modeltester:tested", { model, ok: result.ok });
    return result;
  }

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
      const result = data.ok ? { ok: true } : { ok: false, error: data.error || "" };
      _emit("modeltester:saved", { existingId: existingId || null, ok: result.ok });
      return result;
    } catch (e) {
      return { ok: false, error: e.message };
    }
  }

  return { testConnection, saveModel };
})();

const ModelTester = window.ModelTester;
