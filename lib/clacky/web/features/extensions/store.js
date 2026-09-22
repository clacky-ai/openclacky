// ── Extensions · store — data, state, network for the extension marketplace ─
//
// The store is the single source of truth for the extension catalog. It owns
// state, talks to the local server (which proxies the platform's public
// /api/v1/extensions endpoint), and emits events so the view re-renders. It
// NEVER touches the DOM directly.
//
// Two lists, grouped by who published them:
//   official  — builtin extensions that ship with the gem
//   catalog   — the public marketplace, or a brand's private catalog
//
// The panel has two visible tabs over those lists:
//   all       — official + catalog, i.e. everything the user could add
//   installed — official (builtin) + everything already on disk
// A brand-licensed install hides the marketplace tab and shows a "brand" one
// instead: the same official group, with the catalog coming from the brand.
//
// Two event channels (same convention as the skills store):
//   1. Internal bus (Extensions.on / _emit) — always live; the core view
//      subscribes here so the panel keeps rendering under ?pure=true.
//   2. Clacky.ext.emit(...) — extension bus; silenced in pure mode.
//
// Depends on: I18n, global $ / escapeHtml helpers, Clacky.ext (core/ext.js)
// ───────────────────────────────────────────────────────────────────────────

const EXT_TAB_KEY  = "clacky-ext-tab";
const EXT_SORT_KEY = "clacky-ext-sort";

const ExtensionsStore = (() => {
  // ── State (single source of truth) ─────────────────────────────────────
  let _tab        = "all";   // "all" | "installed" | "brand"
  let _official   = [];      // builtin extensions, unfiltered
  let _catalog    = [];      // marketplace (or brand-private) extensions
  let _installed  = [];      // everything on disk: builtin + installed layers
  let _query      = "";      // current search text
  let _sort       = (function() { try { return localStorage.getItem(EXT_SORT_KEY) || "downloads"; } catch (_) { return "downloads"; } })();
  const PAGE_SIZE = 20;      // requested page size, sent to the platform as per_page
  let _page       = 1;       // current marketplace page (1-based)
  let _hasMore    = false;   // whether the marketplace has another page
  let _loading    = false;
  let _loadingMore = false;
  let _error      = null;    // soft warning when the store is unreachable
  let _detail     = null;    // currently opened extension detail, or null
  let _detailLoading = false;
  let _detailError   = null;
  let _jobs       = {};      // extId => { stage, progress, error } while a row action runs
  let _installError = null;  // error message from the last failed install attempt

  function _matches(ext, query) {
    if (!query) return true;
    const needle = query.toLowerCase();
    return [ext.name, ext.display_name, ext.display_name_zh, ext.description, ext.description_zh]
      .some((f) => f && String(f).toLowerCase().includes(needle));
  }

  function _jobFor(id) {
    return _jobs[String(id)] || null;
  }

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
    get tab()        { return _tab; },
    get official()   { return _official.filter((e) => _matches(e, _query)); },
    // The brand catalog has no server-side search, so the query is applied here
    // too; on the marketplace tab the server already did the filtering.
    get catalog()    { return _catalog.filter((e) => _matches(e, _query)); },
    get installed()  { return _installed.filter((e) => _matches(e, _query)); },
    get query()      { return _query; },
    get sort()       { return _sort; },
    get loading()    { return _loading; },
    get loadingMore(){ return _loadingMore; },
    get hasMore()    { return _hasMore; },
    get error()      { return _error; },
    get detail()        { return _detail; },
    get detailLoading() { return _detailLoading; },
    get detailError()   { return _detailError; },
    get installJob()    { return _detail ? _jobFor(_detail.id) : null; },
    get installError()  { return _installError; },
    jobFor(id)          { return _jobFor(id); },
  };

  const Extensions = {
    on: _on,
    state,

    /** Fetch the data for the active tab. */
    async load() {
      if (_tab === "installed") return Extensions.loadInstalled();
      if (_tab === "brand")     return Extensions.loadBrand();
      return Extensions.loadAll();
    },

    /** Tab "all": the builtin list plus the first page of the marketplace. */
    async loadAll() {
      _loading = true;
      _error   = null;
      _emit("extensions:loading");
      try {
        const [official, market] = await Promise.all([_fetchOfficial(), _fetchMarketPage(1)]);
        _official = official;
        _catalog  = market.extensions;
        _page     = 1;
        _hasMore  = _computeHasMore(market.meta, market.extensions);
        _error    = market.warning || null;
      } catch (e) {
        console.error("[Extensions] loadAll failed", e);
        _official = [];
        _catalog  = [];
        _error    = I18n.t("extensions.loadFailed");
      } finally {
        _loading = false;
        _emit("extensions:changed", { reset: true });
      }
    },

    /** Append the next marketplace page to the user group. */
    async loadMoreUser() {
      if (_loading || _loadingMore || !_hasMore) return;
      _loadingMore = true;
      _emit("extensions:loadingMore");
      try {
        const next = await _fetchMarketPage(_page + 1);
        _catalog = _catalog.concat(next.extensions);
        _page    = _page + 1;
        _hasMore = _computeHasMore(next.meta, next.extensions);
        _error   = next.warning || null;
      } catch (e) {
        console.error("[Extensions] loadMoreUser failed", e);
      } finally {
        _loadingMore = false;
        _emit("extensions:changed", { reset: false });
      }
    },

    /** Tab "installed": everything on disk, both layers, no paging. */
    async loadInstalled() {
      _loading = true;
      _error   = null;
      _emit("extensions:loading");
      try {
        const res  = await fetch("/api/store/extensions/installed");
        const data = await res.json();
        _installed = data.extensions || [];
      } catch (e) {
        console.error("[Extensions] loadInstalled failed", e);
        _installed = [];
        _error     = I18n.t("extensions.loadFailed");
      } finally {
        _loading = false;
        _emit("extensions:changed", { reset: true });
      }
    },

    /** Tab "brand": the official group plus the brand-private catalog. */
    async loadBrand() {
      _loading = true;
      _error   = null;
      _emit("extensions:loading");
      try {
        const params = new URLSearchParams();
        if (_sort) params.set("sort", _sort);
        const qs = params.toString();
        const [official, brand] = await Promise.all([
          _fetchOfficial(),
          fetch("/api/store/extensions/brand" + (qs ? "?" + qs : "")).then((r) => r.json()),
        ]);
        _official = official;
        _catalog  = brand.extensions || [];
        _hasMore  = false;
        _error    = brand.warning || null;
      } catch (e) {
        console.error("[Extensions] loadBrand failed", e);
        _official = [];
        _catalog  = [];
        _error    = I18n.t("extensions.loadFailed");
      } finally {
        _loading = false;
        _emit("extensions:changed", { reset: true });
      }
    },

    /** Switch tabs; the tab survives panel navigation via sessionStorage. */
    async setTab(tab) {
      _tab = tab || "all";
      try { sessionStorage.setItem(EXT_TAB_KEY, _tab); } catch (_) {}
      return Extensions.load();
    },

    /** Set the search text and reload. */
    setQuery(query) {
      _query = (query || "").trim();
      return Extensions.load();
    },

    /** Set the sort order and reload. */
    setSort(sort) {
      _sort = sort || "downloads";
      try { localStorage.setItem(EXT_SORT_KEY, _sort); } catch (_) {}
      return Extensions.load();
    },

    /** Open the detail view for one extension (fetches contributes + versions). */
    async loadDetail(id, source) {
      if (!id) return;
      _detail        = null;
      _detailLoading = true;
      _detailError   = null;
      // Reopening this detail (back button, switching panels and returning) must
      // not resurrect a stale failure or progress snapshot from a previous visit.
      delete _jobs[String(id)];
      _installError  = null;
      _emit("extensions:detail");
      try {
        const isBrand = source === "brand" || _tab === "brand";
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
      _installError  = null;
      _emit("extensions:detail");
    },

    /** Enable/disable an extension, then refresh the panel. */
    async setEnabled(id, enabled) {
      if (!id) return;
      id = String(id);
      _jobs[id] = { stage: enabled ? "enabling" : "disabling" };
      _emit("extensions:job", { id });
      const path = enabled ? "/api/store/extension/enable" : "/api/store/extension/disable";
      try {
        const res = await fetch(path, {
          method:  "POST",
          headers: { "Content-Type": "application/json" },
          body:    JSON.stringify({ id }),
        });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || "toggle failed");
        delete _jobs[id];
        location.reload();
      } catch (e) {
        console.error("[Extensions] setEnabled failed", e);
        delete _jobs[id];
        _installError = e.message;
        _emit("extensions:job", { id });
        _emit("extensions:detail");
      }
    },

    /**
     * Install a marketplace extension by fetching its download_url then posting
     * to the local server. `extHint` lets a list row skip the extra detail
     * round-trip — it already has the extension object it rendered.
     */
    async install(id, extHint) {
      if (!id) return;
      id = String(id);
      _installError = null;
      _jobs[id] = { stage: "downloading", progress: null };
      _emit("extensions:job", { id });
      try {
        // Prefer a hint from the caller, then the open detail (avoids a second
        // round-trip and correctly handles brand-private extensions whose detail
        // was fetched with &source=brand). The catalog projection drops
        // download_url, so a hint without one is useless — fall back to detail.
        let ext = (extHint && String(extHint.id) === id && extHint.download_url) ? extHint : null;
        if (!ext && _detail && String(_detail.id) === id && _detail.download_url) ext = _detail;
        if (!ext) {
          const source     = _tab === "brand" ? "&source=brand" : "";
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

        await _pollInstallStatus(data.job_id, id);
      } catch (e) {
        console.error("[Extensions] install failed", e);
        _jobs[id]     = { stage: "error", error: e.message };
        _installError = e.message;
        _emit("extensions:job", { id });
        _emit("extensions:detail");
      }
    },

    /** Import a locally selected .zip package via multipart upload. */
    async importZip(file) {
      _installError = null;
      const id = "__import__"; // job bookkeeping only; no row renders this id
      _jobs[id] = { stage: "downloading", progress: null };
      try {
        const form = new FormData();
        form.append("file", file);
        const res = await fetch("/api/store/extension/import", { method: "POST", body: form });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || "import failed");

        // done path reloads the page inside _pollInstallStatus, so the
        // returned object only matters on failure.
        await _pollInstallStatus(data.job_id, id);
        return { ok: true };
      } catch (e) {
        console.error("[Extensions] import failed", e);
        delete _jobs[id];
        _installError = e.message;
        _emit("extensions:detail");
        return { ok: false, error: e.message };
      }
    },

    /** Update an installed extension to the latest marketplace version. */
    async update(id) {
      return Extensions.install(id);
    },

    /** Remove an installed extension, then return to the list. */
    async uninstall(id, purgeData = false) {
      if (!id) return { ok: false, error: "Missing id" };
      try {
        const res = await fetch("/api/store/extension", {
          method:  "DELETE",
          headers: { "Content-Type": "application/json" },
          body:    JSON.stringify({ id, purge_data: purgeData }),
        });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || "uninstall failed");
        location.reload();
        return { ok: true };
      } catch (e) {
        console.error("[Extensions] uninstall failed", e);
        // Hand the failure to the caller. Setting `_detailError` here swapped
        // the panel to the detail view and bounced straight back, which read
        // as "nothing happened" instead of as an error.
        return { ok: false, error: e.message };
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

  // ── Network helpers ─────────────────────────────────────────────────────
  async function _fetchOfficial() {
    const res  = await fetch("/api/store/extensions/system");
    const data = await res.json();
    return data.extensions || [];
  }

  async function _fetchMarketPage(page) {
    const params = new URLSearchParams();
    if (_query) params.set("q", _query);
    if (_sort)  params.set("sort", _sort);
    if (page > 1) params.set("page", String(page));
    params.set("per_page", String(PAGE_SIZE));
    const qs   = params.toString();
    const res  = await fetch("/api/store/extensions" + (qs ? "?" + qs : ""));
    const data = await res.json();
    return {
      extensions: data.extensions || [],
      meta:       data.meta,
      warning:    data.warning || null,
    };
  }

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

  // Poll /api/store/extension/install/status until done, keeping _jobs[extId]
  // current so whatever renders that id shows live progress.
  const POLL_MAX_DURATION_MS = 30 * 60 * 1000; // give up after 30 minutes total

  async function _pollInstallStatus(jobId, extId) {
    const INTERVAL = 1000;
    const startedAt = Date.now();
    let first = true;
    while (true) {
      // Check immediately on the first iteration — the job already exists
      // server-side by the time we get here, so there's no reason to sit on the
      // initial "downloading" placeholder for a full INTERVAL before
      // fetching real progress. Subsequent iterations still wait normally.
      if (first) {
        first = false;
      } else {
        await new Promise(r => setTimeout(r, INTERVAL));
      }

      if (Date.now() - startedAt > POLL_MAX_DURATION_MS) {
        delete _jobs[extId];
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
        delete _jobs[extId];
        throw new Error(data.error || "install failed");
      }

      _jobs[extId] = { stage: data.stage, progress: data.progress };
      _emit("extensions:job", { id: extId });

      if (data.stage === "done") {
        delete _jobs[extId];
        // The view owns the DOM: it decides whether a finished install should
        // reload now (panel on screen) or wait until the panel opens again.
        _emit("extensions:job", { id: extId, stage: "done" });
        return;
      }
      if (data.stage === "error") {
        delete _jobs[extId];
        throw new Error(data.error || "install failed");
      }
    }
  }

  return Extensions;
})();

const Extensions = ExtensionsStore;
Clacky.Extensions = Extensions;
