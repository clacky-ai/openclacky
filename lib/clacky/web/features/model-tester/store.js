// ── RuntimeProvider + ModelTester · store — provider network helpers ──────
//
// Network helpers shared by the onboarding wizard and the settings model modal:
// test a model connection and persist a model config. No own panel, no state to
// hold — it mirrors test/save outcomes onto the extension bus so extensions can
// observe model-config changes.
//
// RuntimeProvider owns the metadata-driven runtime contract. ModelTester keeps
// the existing API-model test/save facade and adds a runtime health probe.
//
// Depends on: I18n, Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────

window.RuntimeProvider = (function () {
  const PENDING_STATES = ["starting", "authenticating", "pending"];
  const ERROR_STATES = ["error", "failed", "unavailable"];
  // The Codex ACP authentication request is allowed to wait for five minutes.
  // Keep the browser observing slightly longer so a valid slow login is not
  // reported as a local timeout while the backend is still authenticating.
  const AUTH_POLL_ATTEMPTS = 305;

  function isRuntimeProvider(provider) {
    return !!provider && (provider.auth_mode === "runtime" || !!provider.runtime_id);
  }

  function runtimeUrl(provider, action) {
    if (!isRuntimeProvider(provider) || !provider.extension_id) return null;
    return `/api/ext/${encodeURIComponent(provider.extension_id)}/${action}`;
  }

  async function runtimeRequest(provider, action, { method = "GET" } = {}) {
    const url = runtimeUrl(provider, action);
    if (!url) {
      return { ok: false, status: "unavailable", message: I18n.t("runtime.provider.status.unavailable") };
    }

    try {
      const res = await fetch(url, { method });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        return {
          ...data,
          ok: false,
          status: data.status || "error",
          message: data.message || data.error || `HTTP ${res.status}`,
        };
      }
      return { ...data, ok: data.ok !== false };
    } catch (error) {
      return { ok: false, status: "error", message: error.message };
    }
  }

  function status(provider) {
    return runtimeRequest(provider, "status");
  }

  function connect(provider) {
    return runtimeRequest(provider, "connect", { method: "POST" });
  }

  function authenticate(provider) {
    return runtimeRequest(provider, "authenticate", { method: "POST" });
  }

  async function discover(provider) {
    const data = await runtimeRequest(provider, "discover", { method: "POST" });
    const models = Array.from(new Set(
      (Array.isArray(data.models) ? data.models : [])
        .map(model => String(model || "").trim())
        .filter(Boolean)
    ));
    const advertisedDefault = String(data.default_model || "").trim();
    return {
      ...data,
      models,
      default_model: models.includes(advertisedDefault) ? advertisedDefault : (models[0] || ""),
    };
  }

  function statusView(data) {
    if (!data) return { state: "checking", connected: false, terminal: false, message: "" };

    const status = String(data.status || "").toLowerCase();
    if (data.authenticated === true || status === "connected" || status === "authenticated") {
      return { state: "connected", connected: true, terminal: true, message: data.message || "" };
    }
    if (status === "idle") {
      return { state: "idle", connected: false, terminal: true, message: data.message || "" };
    }
    if (PENDING_STATES.includes(status)) {
      return { state: "starting", connected: false, terminal: false, message: data.message || "" };
    }
    if (data.available === false || data.ok === false || ERROR_STATES.includes(status)) {
      return { state: "unavailable", connected: false, terminal: true, message: data.message || data.error || "" };
    }
    if (data.authenticated === false) {
      return { state: "notConnected", connected: false, terminal: true, message: data.message || "" };
    }
    return { state: "notConnected", connected: false, terminal: false, message: data.message || "" };
  }

  async function pollStatus(provider, { maxAttempts = 60, intervalMs = 1000, onUpdate, shouldContinue } = {}) {
    let last = null;
    const cancelled = () => typeof shouldContinue === "function" && !shouldContinue();
    const cancelledResult = () => ({
      ...(last || {}),
      cancelled: true,
      view: statusView(last),
    });

    for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
      if (cancelled()) return cancelledResult();
      last = await status(provider);
      if (cancelled()) return cancelledResult();
      const view = statusView(last);
      if (typeof onUpdate === "function") onUpdate(last, view);
      if (view.terminal) return { ...last, view };
      if (attempt + 1 < maxAttempts && intervalMs > 0) {
        await new Promise(resolve => setTimeout(resolve, intervalMs));
      }
    }
    return {
      ...(last || {}),
      ok: false,
      status: "timeout",
      timed_out: true,
      view: { state: "timeout", connected: false, terminal: true, message: "" },
    };
  }

  function displayModel(model, provider) {
    if (!model) return (provider && provider.display_model) || "";
    return model.model || model.display_model || (provider && provider.display_model) || model.id || "";
  }

  return {
    AUTH_POLL_ATTEMPTS,
    isRuntimeProvider,
    status,
    connect,
    authenticate,
    discover,
    pollStatus,
    statusView,
    displayModel,
  };
})();

const RuntimeProvider = window.RuntimeProvider;

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

  async function testRuntime({ provider_id, index, id } = {}) {
    const body = { provider_id };
    if (typeof id === "string" && id) body.id = id;
    if (typeof index === "number") body.index = index;

    try {
      const res = await fetch("/api/config/test", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await res.json().catch(() => ({}));
      const view = RuntimeProvider.statusView({ ...data, ok: res.ok && data.ok !== false });
      const message = data.message || I18n.t(`runtime.provider.status.${view.state}`);
      const result = { ok: res.ok && data.ok === true, message, status: data.status };
      _emit("modeltester:tested", { provider_id, ok: result.ok });
      return result;
    } catch (error) {
      return { ok: false, message: error.message };
    }
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
      const result = data.ok ? { ...data, ok: true } : { ok: false, error: data.error || "" };
      _emit("modeltester:saved", { existingId: existingId || null, ok: result.ok });
      return result;
    } catch (e) {
      return { ok: false, error: e.message };
    }
  }

  return { testConnection, testRuntime, saveModel };
})();

const ModelTester = window.ModelTester;
