// ── Archive · store — archived chats + their network calls ────────────────
//
// Owns the archived-session list (a paged read of GET /api/sessions?archived=1)
// plus every mutation: archive, unarchive, delete (soft, lands in the recycle
// bin), and bulk delete-all. It never renders.
//
// Emits mirror to the extension bus via Clacky.ext.emit.
//
// Depends on: Sessions, Projects, Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────

const ArchiveStore = (() => {
  const PAGE_SIZE = 50;  // server caps `limit` at 50

  let _items   = [];
  let _hasMore = false;
  let _cursor  = null;      // server-issued sort key of the last loaded row
  let _loading = false;
  let _archivedTotal = 0;   // whole archive, not just the loaded page

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

  async function _patchArchived(sessionId, archived) {
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ archived }),
    });
    const data = await res.json();
    if (!res.ok || !data.ok) return { ok: false, error: data.error || res.statusText };
    return { ok: true, archived_at: data.archived_at || null };
  }

  function _removeLocal(sessionId) {
    const before = _items.length;
    _items = _items.filter(s => (s.id || s.session_id) !== sessionId);
    if (_items.length < before && _archivedTotal > 0) _archivedTotal--;
  }

  const Archive = {
    on: _on,

    state: {
      get items()   { return _items; },
      get hasMore() { return _hasMore; },
      get loading() { return _loading; },
      get count()   { return _items.length; },
      // Server-side size of the archive. `count` above is only what has been
      // paged in, so anything that talks about "all archived chats" (the
      // summary line, the delete-all confirmation) has to use this instead.
      get archivedTotal() { return _archivedTotal; },
    },

    /** Load the first page (reset = true) or append the next one. */
    async load(opts = {}) {
      if (_loading) return;
      _loading = true;
      _emit("archive:loading", { append: opts.reset === false });

      try {
        const params = new URLSearchParams({ archived: "1", limit: String(PAGE_SIZE) });
        if (!opts.reset && _cursor) {
          params.set("before", _cursor.before);
          params.set("before_id", _cursor.before_id);
        }

        const res  = await fetch(`/api/sessions?${params.toString()}`);
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || "Load failed");

        const rows = data.sessions || [];
        _items   = opts.reset === false ? _items.concat(rows) : rows;
        _hasMore = !!data.has_more;
        _cursor  = data.next_cursor || (opts.reset === false ? _cursor : null);
        if (typeof data.archived_count === "number") _archivedTotal = data.archived_count;
        _emit("archive:changed");
      } catch (e) {
        console.error("[Archive] load failed", e);
        _emit("archive:error", { message: e.message });
      } finally {
        _loading = false;
      }
    },

    /** Archive a live session: it drops out of the sidebar and every list. */
    async archiveSession(session) {
      const id = session && (session.id || session.session_id);
      if (!id) return { ok: false, error: "missing session id" };
      try {
        const res = await _patchArchived(id, true);
        if (!res.ok) return res;
        _archivedTotal++;
        if (typeof Sessions !== "undefined") {
          Sessions.remove(id);
          Sessions.renderList();
        }
        if (typeof Projects !== "undefined") Projects.renderSection();
        return { ok: true };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    /** Bring an archived chat back into the sidebar. */
    async unarchive(session) {
      const id = session && (session.id || session.session_id);
      if (!id) return { ok: false, error: "missing session id" };
      try {
        const res = await _patchArchived(id, false);
        if (!res.ok) return res;
        _removeLocal(id);
        _emit("archive:changed");
        if (typeof Sessions !== "undefined") {
          const row = await fetch(`/api/sessions/${encodeURIComponent(id)}`)
            .then(r => (r.ok ? r.json() : null)).catch(() => null);
          if (row && row.session) Sessions.add(row.session);
          Sessions.renderList();
        }
        if (typeof Projects !== "undefined") Projects.renderSection();
        return { ok: true };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    /** Delete one archived chat — soft delete, so it lands in the recycle bin. */
    async remove(session) {
      const id = session && (session.id || session.session_id);
      if (!id) return { ok: false, error: "missing session id" };
      try {
        const res  = await fetch(`/api/sessions/${encodeURIComponent(id)}`, { method: "DELETE" });
        const data = await res.json();
        if (!res.ok || !data.ok) return { ok: false, error: data.error || res.statusText };
        _removeLocal(id);
        _emit("archive:changed");
        return { ok: true };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    /**
     * Delete archived chats (soft delete, same as remove).
     * `sessions` is the visible selection when search or filters narrow the
     * page; null means the whole archive, which is paged, so only the server
     * can enumerate it. Either way the caller words its confirmation with the
     * number this call takes out.
     */
    async deleteMany(sessions) {
      const ids  = sessions ? sessions.map(s => s.id || s.session_id) : null;
      const opts = { method: "POST" };
      if (ids) {
        opts.headers = { "Content-Type": "application/json" };
        opts.body    = JSON.stringify({ session_ids: ids });
      }
      try {
        const res  = await fetch("/api/archive/sessions/delete", opts);
        const data = await res.json();
        if (!res.ok || !data.ok) return { ok: false, error: data.error || res.statusText };
        const deleted = data.deleted_count || 0;
        if (ids) {
          _items         = _items.filter(s => !ids.includes(s.id || s.session_id));
          _archivedTotal = Math.max(0, _archivedTotal - deleted);
        } else {
          _items         = [];
          _hasMore       = false;
          _cursor        = null;
          _archivedTotal = 0;
        }
        _emit("archive:changed");
        return { ok: true, deleted_count: deleted };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },
  };

  return Archive;
})();

const Archive = ArchiveStore;
