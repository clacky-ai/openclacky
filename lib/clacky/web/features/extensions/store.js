// ── Extensions · store — data, state, network for the extension marketplace ─
//
// The store is the single source of truth for the public extension catalog. It
// owns state, talks to the local server (which proxies the platform's public
// /api/v1/extensions endpoint), and emits events so the view re-renders. It
// NEVER touches the DOM directly.
//
// Extension archives are NOT downloadable from here — extensions ship inside
// license-gated brand packages (path B distribution). This panel is a
// read-only browse/search catalog of metadata only.
//
// Two event channels (same convention as the skills store):
//   1. Internal bus (Extensions.on / _emit) — always live; the core view
//      subscribes here so the panel keeps rendering under ?pure=true.
//   2. Clacky.ext.emit(...) — extension bus; silenced in pure mode.
//
// Depends on: I18n, global $ / escapeHtml helpers, Clacky.ext (core/ext.js)
// ───────────────────────────────────────────────────────────────────────────

const EXT_TAB_KEY      = "clacky-ext-tab";
const EXT_SORT_KEY     = "clacky-ext-sort";
const EXT_INSTALLED_KEY = "clacky-ext-installed-filter";

const ExtensionsStore = (() => {
  // ── State (single source of truth) ─────────────────────────────────────
  let _extensions      = [];        // [{ id, name, name_zh, description, ..., units }]
  let _allExtensions   = [];        // unfiltered result from server
  let _query           = "";        // current search text
  let _sort            = (function() { try { return localStorage.getItem(EXT_SORT_KEY) || "downloads"; } catch (_) { return "downloads"; } })();
  let _filterInstalled = false;     // when true, show only installed extensions
  let _filterBrand     = false;     // when true, show only brand-private extensions
  let _filterSystem    = false;      // when true, show system (builtin) extensions
  let _filterMarket    = true;     // when true, show marketplace extensions
  let _onlyInstalled   = (function() { try { return localStorage.getItem(EXT_INSTALLED_KEY) === "installed"; } catch (_) { return false; } })();
  const PAGE_SIZE   = 20;        // requested page size, sent to the platform as per_page
  let _page         = 1;         // current marketplace page (1-based)
  let _hasMore      = false;     // whether the marketplace has another page
  let _loading    = false;
  let _loadingMore = false;
  let _error      = null;      // soft warning when the store is unreachable
  let _detail     = null;      // currently opened extension detail, or null
  let _detailLoading = false;
  let _detailError   = null;
  let _installJob    = null;   // { stage, progress } while install is running, null otherwise
  let _installError  = null;   // error message from a failed install attempt
  let _pollToken     = 0;      // bumped by closeDetail() to abandon an in-flight poll loop

  // ── Internal event bus ──────────────────────────────────────────────────
  const _listeners = {};       // event => [handler]

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

  // ── Read-only accessors used by the view ────────────────────────────────
  const state = {
    get extensions() { return _extensions; },
    get query()      { return _query; },
    get sort()       { return _sort; },
    get filterInstalled() { return _filterInstalled; },
    get filterBrand()     { return _filterBrand; },
    get filterSystem()    { return _filterSystem; },
    get filterMarket()    { return _filterMarket; },
    get onlyInstalled()   { return _onlyInstalled; },
    get loading()    { return _loading; },
    get loadingMore(){ return _loadingMore; },
    get hasMore()    { return _hasMore; },
    get error()      { return _error; },
    get detail()        { return _detail; },
    get detailLoading() { return _detailLoading; },
    get detailError()   { return _detailError; },
    get installJob()    { return _installJob; },
    get installError()  { return _installError; },
  };

  const Extensions = {
    on: _on,
    state,

    /** Fetch the catalog from the server for the current query + sort. */
    async load() {
      if (_filterSystem) return Extensions.loadSystemExtensions();
      if (_filterInstalled) return;
      if (_filterBrand) return Extensions.loadBrandExtensions();
      return Extensions.loadMarketExtensions();
    },

    /** Load builtin system extensions from /api/store/extensions/system. */
    async loadSystemExtensions() {
      _loading = true;
      _error   = null;
      _emit("extensions:loading");
      try {
        const res  = await fetch("/api/store/extensions/system");
        const data = await res.json();
        const all  = data.extensions || [];
        _extensions = _query
          ? all.filter(e => [e.name, e.display_name, e.display_name_zh, e.description].some(
              f => f && f.toLowerCase().includes(_query.toLowerCase())))
          : all;
        _error   = null;
        _loading = false;
        _emit("extensions:changed", { extensions: _extensions, warning: _error });
      } catch (e) {
        console.error("[Extensions] loadSystemExtensions failed", e);
        _extensions = [];
        _error      = I18n.t("extensions.loadFailed");
        _loading    = false;
        _emit("extensions:error", { network: true });
      } finally {
        _loading = false;
      }
    },

    /** Load marketplace extensions (all, not filtered by installed) — first page. */
    async loadMarketExtensions() {
      _page = 1;
      return Extensions._loadMarketPage(true);
    },

    /** Load the next marketplace page and append it to the current list. */
    async loadMoreMarketExtensions() {
      if (_loading || _loadingMore || !_hasMore) return;
      return Extensions._loadMarketPage(false);
    },

    async _loadMarketPage(reset) {
      const page = reset ? 1 : _page + 1;
      if (reset) {
        _loading = true;
        _error   = null;
        _emit("extensions:loading");
      } else {
        _loadingMore = true;
        _emit("extensions:loadingMore");
      }
      try {
        const params = new URLSearchParams();
        if (_query) params.set("q", _query);
        if (_sort)  params.set("sort", _sort);
        if (page > 1) params.set("page", String(page));
        params.set("per_page", String(PAGE_SIZE));
        const qs   = params.toString();
        const res  = await fetch("/api/store/extensions" + (qs ? "?" + qs : ""));
        const data = await res.json();
        const incoming = data.extensions || [];
        _error = data.warning || null;

        if (reset) {
          _allExtensions = incoming;
          _extensions = _onlyInstalled ? incoming.filter(e => e.installed) : incoming;
        } else {
          _allExtensions = _allExtensions.concat(incoming);
          const incomingFiltered = _onlyInstalled ? incoming.filter(e => e.installed) : incoming;
          _extensions = _extensions.concat(incomingFiltered);
        }

        _page    = page;
        _hasMore = _computeHasMore(data.meta, incoming);
      } catch (e) {
        console.error("[Extensions] loadMarketExtensions failed", e);
        if (reset) {
          _extensions = [];
          _error      = I18n.t("extensions.loadFailed");
        }
      } finally {
        _loading     = false;
        _loadingMore = false;
        _emit("extensions:changed", { extensions: _extensions, warning: _error, reset: reset });
      }
    },

    /** Set the search text and reload. */
    setQuery(query) {
      _query = (query || "").trim();
      if (_filterSystem) return Extensions.loadSystemExtensions();
      if (_filterBrand) return Extensions.loadBrandExtensions();
      return Extensions.loadMarketExtensions();
    },

    /** Set the sort order and reload. */
    setSort(sort) {
      _sort = sort || "downloads";
      try { localStorage.setItem(EXT_SORT_KEY, _sort); } catch (_) {}
      if (_filterSystem) return Extensions.loadSystemExtensions();
      if (_filterBrand) return Extensions.loadBrandExtensions();
      return Extensions.loadMarketExtensions();
    },

    /** Toggle the global "only installed" overlay and reload the current tab. */
    async setOnlyInstalled(only) {
      _onlyInstalled = !!only;
      try { localStorage.setItem(EXT_INSTALLED_KEY, _onlyInstalled ? "installed" : "all"); } catch (_) {}
      if (_filterSystem) return Extensions.loadSystemExtensions();
      if (_filterBrand) return Extensions.loadBrandExtensions();
      _extensions = _onlyInstalled ? _allExtensions.filter(e => e.installed) : _allExtensions;
      _emit("extensions:changed", { extensions: _extensions, warning: _error, reset: true });
    },

    /** Switch to the system (builtin) extensions tab. */
    async setFilterSystem() {
      _filterSystem    = true;
      _filterMarket    = false;
      _filterInstalled = false;
      _filterBrand     = false;
      return Extensions.loadSystemExtensions();
    },

    /** Switch to the marketplace extensions tab. */
    async setFilterMarket() {
      _filterMarket    = true;
      _filterSystem    = false;
      _filterInstalled = false;
      _filterBrand     = false;
      return Extensions.loadMarketExtensions();
    },

    /** Toggle the "installed only" filter — fetches from local store when enabled. */
    async setFilterInstalled(onlyInstalled) {
      _filterInstalled = !!onlyInstalled;
      _filterBrand     = false;
      _filterSystem    = false;
      _filterMarket    = !onlyInstalled;
      if (_filterInstalled) {
        _loading = true;
        _emit("extensions:loading");
        try {
          const res  = await fetch("/api/store/extensions/installed");
          const data = await res.json();
          const all  = data.extensions || [];
          _extensions = _query
            ? all.filter(e => [e.name, e.name_zh, e.description].some(
                f => f && f.toLowerCase().includes(_query.toLowerCase())))
            : all;
        } catch (e) {
          console.error("[Extensions] load installed failed", e);
          _extensions = [];
        } finally {
          _loading = false;
        }
        _emit("extensions:changed", { extensions: _extensions, warning: _error });
      } else {
        return Extensions.load();
      }
    },

    /** Toggle the "brand only" filter — fetches brand-private extensions. */
    async setFilterBrand(onlyBrand) {
      _filterBrand     = !!onlyBrand;
      _filterInstalled = false;
      _filterSystem    = false;
      _filterMarket    = !onlyBrand;
      if (_filterBrand) {
        return Extensions.loadBrandExtensions();
      } else {
        return Extensions.loadMarketExtensions();
      }
    },

    /** Fetch brand-private extensions from /api/store/extensions/brand. */
    async loadBrandExtensions() {
      _loading = true;
      _error   = null;
      _emit("extensions:loading");
      try {
        const res  = await fetch("/api/store/extensions/brand");
        const data = await res.json();
        const all  = data.extensions || [];
        const matched = _query
          ? all.filter(e => [e.name, e.name_zh, e.description].some(
              f => f && f.toLowerCase().includes(_query.toLowerCase())))
          : all;
        _extensions = _onlyInstalled ? matched.filter(e => e.installed) : matched;
        _error      = data.warning || null;
        _loading    = false;
        _emit("extensions:changed", { extensions: _extensions, warning: _error });
      } catch (e) {
        console.error("[Extensions] loadBrandExtensions failed", e);
        _extensions = [];
        _error      = I18n.t("extensions.loadFailed");
        _loading    = false;
        _emit("extensions:error", { network: true });
      } finally {
        _loading = false;
      }
    },

    /** Open the detail view for one extension (fetches contributes + versions). */
    async loadDetail(id, source) {
      if (!id) return;
      _detail        = null;
      _detailLoading = true;
      _detailError   = null;
      // Reopening/refreshing this detail (back button, switching panels and
      // returning, etc.) must not resurrect a stale install/update job
      // snapshot from a previous visit — bump the token so any poll loop
      // still running for that old visit becomes a no-op, and clear the
      // snapshot itself so the button starts from a clean slate.
      _pollToken += 1;
      _installJob   = null;
      _installError = null;
      _emit("extensions:detail");
      try {
        const isBrand = source === "brand" || _filterBrand;
        const url  = isBrand
          ? "/api/store/extension?id=" + encodeURIComponent(id) + "&source=brand"
          : "/api/store/extension?id=" + encodeURIComponent(id);
        const res  = await fetch(url);
        const data = await res.json();
        if (res.ok && data.ok && data.extension) {
          _detail      = data.extension;
          _detailError = null;
        } else {
          _detail      = null;
          _detailError = data.error || I18n.t("extensions.loadFailed");
        }
      } catch (e) {
        console.error("[Extensions] loadDetail failed", e);
        _detail      = null;
        _detailError = I18n.t("extensions.loadFailed");
      } finally {
        _detailLoading = false;
        _emit("extensions:detail");
      }
    },

    /** Fetch /api/brand/status and return { branded: bool }. */
    async fetchBrandStatus() {
      try {
        const res  = await fetch("/api/brand/status");
        const data = await res.json();
        return data;
      } catch (_e) {
        return { branded: false };
      }
    },

    /** Close the detail view. */
    closeDetail() {
      _detail        = null;
      _detailLoading = false;
      _detailError   = null;
      // Abandon any install/update poll still running for this detail — bumping
      // the token makes the next loop iteration in _pollInstallStatus a no-op,
      // so we stop hammering the status endpoint once nobody is watching.
      // Also clear the job/error snapshot itself: since nothing will update it
      // anymore, leaving a stale value around would make the button look frozen
      // (e.g. stuck on "downloading 22%") the next time this extension's detail
      // is reopened.
      _pollToken += 1;
      _installJob   = null;
      _installError = null;
      _emit("extensions:detail");
    },

    /** Disable/enable an installed extension, then refresh the open detail. */
    async setEnabled(id, enabled) {
      if (!id) return;
      const path = enabled ? "/api/store/extension/enable" : "/api/store/extension/disable";
      try {
        const res = await fetch(path, {
          method:  "POST",
          headers: { "Content-Type": "application/json" },
          body:    JSON.stringify({ id }),
        });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || "toggle failed");
        const activeTab = _filterSystem ? "system" : _filterBrand ? "brand" : _filterInstalled ? "installed" : "market";
        try { sessionStorage.setItem(EXT_TAB_KEY, activeTab); } catch (_) {}
        location.reload();
      } catch (e) {
        console.error("[Extensions] setEnabled failed", e);
        _detailError = e.message;
        _emit("extensions:detail");
      }
    },

    /** Install a marketplace extension by fetching its download_url then posting to the local server. */
    async install(id) {
      if (!id) return;
      _installError = null;
      // Capture the current token so that if the user closes the detail panel
      // mid-install, both the poll loop and this catch block notice and stop
      // touching state for a view nobody is looking at anymore.
      const token = _pollToken;
      try {
        // Prefer the already-loaded detail (avoids a second round-trip and correctly
        // handles brand-private extensions whose detail was fetched with &source=brand).
        let ext;
        if (_detail && String(_detail.id) === String(id)) {
          ext = _detail;
        } else {
          const source     = _filterBrand ? "&source=brand" : "";
          const detailRes  = await fetch("/api/store/extension?id=" + encodeURIComponent(id) + source);
          const detailData = await detailRes.json();
          if (!detailRes.ok || !detailData.ok) throw new Error(detailData.error || "fetch detail failed");
          ext = detailData.extension;
        }
        const download_url = ext.download_url;
        if (!download_url) throw new Error("No download URL available");

        // Start async install — server returns job_id immediately
        const res = await fetch("/api/store/extension/install", {
          method:  "POST",
          headers: { "Content-Type": "application/json" },
          body:    JSON.stringify({ download_url, name: ext.name }),
        });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || "install failed");

        // Poll for progress until done.
        const jobId = data.job_id;
        await _pollInstallStatus(jobId, token);
      } catch (e) {
        console.error("[Extensions] install failed", e);
        if (token !== _pollToken) return; // panel was closed — nothing to update
        _installJob   = null;
        _installError = e.message;
        _emit("extensions:detail");
      }
    },

    /** Update an installed extension to the latest marketplace version. */
    async update(id) {
      return Extensions.install(id);
    },

    /** Remove an installed extension, then return to the list. */
    async uninstall(id, purgeData = false) {
      if (!id) return;
      try {
        const res = await fetch("/api/store/extension", {
          method:  "DELETE",
          headers: { "Content-Type": "application/json" },
          body:    JSON.stringify({ id, purge_data: purgeData }),
        });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || "uninstall failed");
        location.reload();
      } catch (e) {
        console.error("[Extensions] uninstall failed", e);
        _detailError = e.message;
        _emit("extensions:detail");
      }
    },

    /** Create a new extension via ext-studio and return the session_id. */
    async createNew(idea) {
      const res = await fetch("/api/ext/ext-studio/develop", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ idea: idea || null }),
      });
      return res.json();
    },

  };

  // Whether another marketplace page exists. Prefers the platform's pagination
  // meta; falls back to "a full page came back" for older platform builds that
  // don't return meta yet.
  function _computeHasMore(meta, incoming) {
    if (meta && meta.total_pages != null) {
      const current = meta.current_page != null ? Number(meta.current_page) : _page;
      return current < Number(meta.total_pages);
    }
    return (incoming || []).length >= PAGE_SIZE;
  }

  // Poll /api/store/extension/install/status until done, updating _installJob each tick.
  // `token` is the _pollToken snapshot taken when the poll started; if the
  // user closes the detail panel, closeDetail() bumps _pollToken and this
  // loop notices on its next tick and quietly stops (no more state writes,
  // no more network requests).
  const POLL_MAX_DURATION_MS = 30 * 60 * 1000; // give up after 30 minutes total

  async function _pollInstallStatus(jobId, token) {
    const INTERVAL = 1000;
    const startedAt = Date.now();
    let first = true;
    while (true) {
      // Check immediately on the first iteration — the job already exists
      // server-side by the time we get here, so there's no reason to sit on
      // the initial "downloading" placeholder for a full INTERVAL before
      // fetching real progress. Subsequent iterations still wait normally.
      if (first) {
        first = false;
      } else {
        await new Promise(r => setTimeout(r, INTERVAL));
      }

      // Panel closed mid-poll — abandon silently, nothing left to update.
      if (token !== _pollToken) return;

      if (Date.now() - startedAt > POLL_MAX_DURATION_MS) {
        throw new Error(I18n.t("extensions.action.installTimeout"));
      }

      let data;
      try {
        const r = await fetch("/api/store/extension/install/status?job_id=" + encodeURIComponent(jobId));
        data = await r.json();
      } catch (e) {
        // network hiccup — keep polling
        continue;
      }
      if (!data.ok) {
        throw new Error(data.error || "install failed");
      }
      if (token !== _pollToken) return; // closed while the fetch was in flight

      _installJob = { stage: data.stage, progress: data.progress };
      _emit("extensions:detail");

      if (data.stage === "done") {
        _installJob = null;
        location.reload();
        return;
      }
      if (data.stage === "error") {
        _installJob = null;
        throw new Error(data.error || "install failed");
      }
    }
  }

  return Extensions;
})();

const Extensions = ExtensionsStore;
Clacky.Extensions = Extensions;
