// ── Billing · store — usage data, currency settings, network ──────────────
//
// Owns billing state (summary / daily / sessions / model list / current period
// & model filter), currency conversion utilities (localStorage-backed), the
// data fetch, and clear-data actions (retained for API use). It never renders.
//
// Currency utilities are pure and read by both the view and other modules, so
// they live with the data layer. Emits store events the view reacts to; mirrors
// them to the extension bus via Clacky.ext.emit.
//
// `Billing` stays the single public facade.
//
// Depends on: Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────

const BillingStore = (() => {
  let _summary = null;
  let _daily = [];
  let _sessions = [];
  let _allModels = [];
  let _currentPeriod = "day";
  let _currentModel = "all";

  const CURRENCY_STORAGE_KEY = "clacky-currency";
  const EXCHANGE_RATE_STORAGE_KEY = "clacky-exchange-rate";
  const DEFAULT_USD_TO_CNY_RATE = 6.7944;

  const _listeners = {};

  function _on(event, handler) {
    (_listeners[event] ||= []).push(handler);
    return () => {
      const list = _listeners[event];
      const i = list ? list.indexOf(handler) : -1;
      if (i >= 0) list.splice(i, 1);
    };
  }

  function _emit(event, payload) {
    (_listeners[event] || []).forEach((h) => h(payload));
    if (window.Clacky && Clacky.ext) Clacky.ext.emit(event, payload);
  }

  function _getCurrency() {
    try { return localStorage.getItem(CURRENCY_STORAGE_KEY) || "USD"; } catch (_) { return "USD"; }
  }

  function _getExchangeRate() {
    try {
      const rate = localStorage.getItem(EXCHANGE_RATE_STORAGE_KEY);
      if (rate) {
        const parsed = parseFloat(rate);
        if (!isNaN(parsed) && parsed > 0) return parsed;
      }
    } catch (_) {}
    return DEFAULT_USD_TO_CNY_RATE;
  }

  function _setExchangeRate(rate) {
    try {
      if (rate && !isNaN(rate) && rate > 0) {
        localStorage.setItem(EXCHANGE_RATE_STORAGE_KEY, rate.toString());
        document.dispatchEvent(new CustomEvent("currencychange"));
      }
    } catch (_) {}
  }

  function _convertCost(usdCost) {
    if (_getCurrency() === "CNY") return usdCost * _getExchangeRate();
    return usdCost;
  }

  function _getCurrencySymbol() {
    return _getCurrency() === "CNY" ? "¥" : "$";
  }

  const state = {
    get summary()       { return _summary; },
    get daily()         { return _daily; },
    get sessions()      { return _sessions; },
    get allModels()     { return _allModels; },
    get currentPeriod() { return _currentPeriod; },
    get currentModel()  { return _currentModel; },
  };

  const Billing = {
    on: _on,
    state,

    getCurrency:        _getCurrency,
    getExchangeRate:    _getExchangeRate,
    setExchangeRate:    _setExchangeRate,
    convertCost:        _convertCost,
    getCurrencySymbol:  _getCurrencySymbol,

    /** Entry point: load usage data. */
    open() {
      return Billing.load();
    },

    /** Re-emit a changed event so the view re-renders (e.g. on currency change). */
    refreshView() {
      if (_summary) _emit("billing:changed");
    },

    setPeriod(period) { _currentPeriod = period; _emit("billing:changed"); return Billing.load(); },
    setModel(model)   { _currentModel = model;   _emit("billing:changed"); return Billing.load(); },

    async load() {
      const isFirstLoad = !_summary;
      _emit("billing:loading", { isFirstLoad });

      try {
        const modelParam = (_currentModel && _currentModel !== "all") ? `&model=${encodeURIComponent(_currentModel)}` : "";
        const [summaryRes, dailyRes] = await Promise.all([
          fetch(`/api/billing/summary?period=${_currentPeriod}${modelParam}`),
          fetch(`/api/billing/daily?days=30${modelParam}`)
        ]);

        _summary = await summaryRes.json();
        const dailyData = await dailyRes.json();
        _daily = dailyData.days || [];

        if (!_currentModel || _currentModel === "all") {
          _allModels = _summary.by_model ? Object.keys(_summary.by_model) : [];
        }

        _emit("billing:changed");
      } catch (e) {
        _emit("billing:error", { message: e.message });
      }
    },

    /** Fetch summary for a single period (used by scorecard background fill). */
    async fetchSummary(period) {
      const modelParam = (_currentModel && _currentModel !== "all") ? `&model=${encodeURIComponent(_currentModel)}` : "";
      const r = await fetch(`/api/billing/summary?period=${period}${modelParam}`);
      return r.json();
    },

    async clearData(scope) {
      try {
        const res = await fetch(`/api/billing/clear?scope=${scope}`, { method: "DELETE" });
        const data = await res.json();
        if (res.ok) {
          await Billing.load();
        } else {
          _emit("billing:actionError", { message: data.error || "Failed to clear data" });
        }
      } catch (e) {
        _emit("billing:actionError", { message: `Error clearing data: ${e.message}` });
      }
    },
  };

  return Billing;
})();

const Billing = BillingStore;
