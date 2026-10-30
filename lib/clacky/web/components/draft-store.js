// ── DraftStore — per-session composer drafts that survive a reload ──────
//
// The in-memory Map is the working copy (sync reads on every session switch);
// IndexedDB is its on-disk mirror, read back once at boot via `ready`. When
// IndexedDB is unavailable (private mode, blocked storage) drafts stay
// memory-only, which is the pre-persistence behaviour.
// ─────────────────────────────────────────────────────────────────────────
"use strict";

const DraftStore = (() => {
  const DB_NAME     = "clacky-drafts";
  const STORE       = "drafts";
  const MAX_AGE_MS  = 7 * 24 * 60 * 60 * 1000;
  const WRITE_DELAY = 300;

  const _drafts  = new Map();  // { [session_id]: draft }
  const _pending = new Map();  // { [session_id]: debounce timer }
  let   _db      = null;

  function _open() {
    return new Promise((resolve) => {
      let req;
      try {
        req = indexedDB.open(DB_NAME, 1);
      } catch (_e) {
        resolve(null);
        return;
      }
      req.onupgradeneeded = () => req.result.createObjectStore(STORE, { keyPath: "id" });
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(null);
    });
  }

  function _tx(fn) {
    if (!_db) return;
    try {
      fn(_db.transaction(STORE, "readwrite").objectStore(STORE));
    } catch (_e) { /* quota or closed connection: keep the in-memory copy */ }
  }

  async function _load() {
    _db = await _open();
    if (!_db) return;
    const rows = await new Promise((resolve) => {
      try {
        const req = _db.transaction(STORE, "readonly").objectStore(STORE).getAll();
        req.onsuccess = () => resolve(req.result || []);
        req.onerror = () => resolve([]);
      } catch (_e) {
        resolve([]);
      }
    });
    const cutoff = Date.now() - MAX_AGE_MS;
    rows.forEach((row) => {
      if (row.ts < cutoff) _tx((store) => store.delete(row.id));
      // A draft written before the read finished is newer than the disk copy.
      else if (!_drafts.has(row.id)) _drafts.set(row.id, row.draft);
    });
  }

  function _write(id) {
    clearTimeout(_pending.get(id));
    _pending.delete(id);
    const draft = _drafts.get(id);
    _tx((store) => (draft ? store.put({ id, draft, ts: Date.now() }) : store.delete(id)));
  }

  function get(id) {
    return _drafts.get(id);
  }

  function set(id, draft) {
    if (!id) return;
    _drafts.set(id, draft);
    clearTimeout(_pending.get(id));
    _pending.set(id, setTimeout(() => _write(id), WRITE_DELAY));
  }

  function remove(id) {
    if (!id) return;
    _drafts.delete(id);
    _write(id);
  }

  // Write every debounced draft now (page is going away).
  function flush() {
    Array.from(_pending.keys()).forEach(_write);
  }

  const ready = _load();
  window.addEventListener("pagehide", flush);

  return { ready, get, set, delete: remove, flush };
})();

Clacky.DraftStore = DraftStore;
