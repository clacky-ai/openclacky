// ── Brand · store — white-label status flags + brand info cache + network ──
//
// Owns the brand status flags (test mode / user-licensed / branded), the cached
// /api/brand response, and the brand network calls (status, info, activate).
// It never renders.
//
// check() / refresh() fetch status and emit events; the view reacts to drive
// banners, logo, badges. Emits mirror to the extension bus via Clacky.ext.emit.
//
// `Brand` stays the single public facade.
//
// Depends on: Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────

const BrandStore = (() => {
  let _testMode     = false;
  let _userLicensed = false;
  let _branded      = false;

  let _brandInfoCache    = null;
  let _brandInfoFetching = null;

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

  // Fetch /api/brand once and cache. Returns a Promise<info>.
  function _fetchBrandInfo() {
    if (_brandInfoCache) return Promise.resolve(_brandInfoCache);
    if (_brandInfoFetching) return _brandInfoFetching;
    _brandInfoFetching = fetch("/api/brand")
      .then(r => r.json())
      .then(info => { _brandInfoCache = info; _brandInfoFetching = null; return info; })
      .catch(err => { _brandInfoFetching = null; throw err; });
    return _brandInfoFetching;
  }

  const Brand = {
    on: _on,
    get testMode()     { return _testMode; },
    get userLicensed() { return _userLicensed; },
    get branded()      { return _branded; },

    fetchInfo: _fetchBrandInfo,

    clearBrandCache() {
      _brandInfoCache    = null;
      _brandInfoFetching = null;
    },

    // Check brand status and emit an event for the view to act on.
    // Always resolves false (boot is no longer deferred on activation).
    async check() {
      try {
        const res  = await fetch("/api/brand/status");
        const data = await res.json();
        _testMode     = !!data.test_mode;
        _userLicensed = !!data.user_licensed;
        _branded      = !!data.branded;
        _emit("brand:status", data);
      } catch (_) {
        _emit("brand:status", null);
      }
      return false;
    },

    // Re-fetch status and notify views without driving the main boot sequence.
    async refresh() {
      try {
        const res  = await fetch("/api/brand/status");
        const data = await res.json();
        _testMode     = !!data.test_mode;
        _userLicensed = !!data.user_licensed;
        _branded      = !!data.branded;
        _emit("brand:status", data);
        return data;
      } catch (_) {
        _emit("brand:status", null);
        return null;
      }
    },

    fetchSkillsBanner() {
      return fetch("/api/brand/skills").then(r => r.json());
    },

    async activate(key) {
      const res  = await fetch("/api/brand/activate", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ license_key: key })
      });
      return res.json();
    },
  };

  return Brand;
})();

const Brand = BrandStore;
