// ── ModelTester · store — model connection test + save (shared helper) ────
//
// Network helpers shared by the onboarding wizard and the settings model modal:
// test a model connection, persist a model config, and list the models an
// endpoint advertises. No own panel, no state to hold — it mirrors test/save
// outcomes onto the extension bus so extensions can observe model-config changes.
//
// `ModelTester` stays the single public facade.
//
// Depends on: I18n, Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────

window.ModelTester = (function () {
  function _emit(event, payload) {
    if (window.Clacky && Clacky.ext) Clacky.ext.emit(event, payload);
  }

  async function testConnection({ model, base_url, api_key, anthropic_format, api_format, index, id } = {}) {
    const body = { model, base_url, api_key };
    if (typeof id === "string" && id) body.id = id;
    if (typeof index === "number") body.index = index;
    if (anthropic_format) body.anthropic_format = true;
    if (api_format) body.api_format = api_format;

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

  // Ask the server to query `<base_url>/models` for the ids the endpoint
  // advertises. The key travels in the POST body (never the URL) because it
  // is used for this one request only; a masked key is resolved server-side
  // from the stored config via `id`/`index`, same as testConnection.
  async function listModels({ base_url, api_key, api_format, index, id } = {}) {
    const body = { base_url, api_key };
    if (typeof id === "string" && id) body.id = id;
    if (typeof index === "number") body.index = index;
    if (api_format) body.api_format = api_format;

    let data;
    let status = 0;
    try {
      const res = await fetch("/api/config/models/list", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify(body)
      });
      status = res.status;
      data = await res.json();
    } catch (e) {
      return { ok: false, message: e.message };
    }

    // Validation failures (400/422) carry `error` instead of `message`;
    // never render an empty reason tail.
    if (!data.ok) return { ok: false, message: data.message || data.error || ("HTTP " + status) };

    const models = Array.isArray(data.models) ? data.models : [];
    _emit("modeltester:listed", { base_url, count: models.length });
    return { ok: true, models, message: data.message || "" };
  }

  return { testConnection, saveModel, listModels };
})();

const ModelTester = window.ModelTester;
