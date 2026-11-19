// ── Profile · store — Soul/User/memories data + curate/delete network ─────
//
// Owns the profile data (soul / user identity files, memories list) and the
// network calls: load profile, load memories, fetch one memory, delete a
// memory, and open agent-led curate sessions. It never renders.
//
// Emits store events the view reacts to; mirrors them to the extension bus via
// Clacky.ext.emit.
//
// `Profile` stays the single public facade.
//
// Depends on: Sessions, I18n, Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────

const ProfileStore = (() => {
  let _data = { user: null, soul: null, memories: [] };

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

  const state = {
    get user()     { return _data.user; },
    get soul()     { return _data.soul; },
    get memories() { return _data.memories; },
  };

  async function _loadProfile() {
    try {
      const res  = await fetch("/api/profile");
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "Load failed");
      _data.user = data.user;
      _data.soul = data.soul;
    } catch (e) {
      console.error("[Profile] load profile failed", e);
      _data.user = null;
      _data.soul = null;
    }
  }

  async function _loadMemories() {
    try {
      const res  = await fetch("/api/memories");
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "Load failed");
      _data.memories = data.memories || [];
    } catch (e) {
      console.error("[Profile] load memories failed", e);
      _data.memories = [];
    }
  }

  async function _openCurateSession(name, command) {
    await Sessions.startWith(command, { name, source: "setup" });
  }

  const Profile = {
    on: _on,
    state,

    async loadAll() {
      await Promise.all([_loadProfile(), _loadMemories()]);
      _emit("profile:changed");
    },

    /** Fetch one memory's raw content. Returns { ok, content, error }. */
    async fetchMemory(filename) {
      try {
        const res  = await fetch("/api/memories/" + encodeURIComponent(filename));
        const data = await res.json();
        if (!data.ok) throw new Error(data.error || "Load failed");
        return { ok: true, content: data.content || "" };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    /** Delete a memory (trash semantics). Returns { ok, error }. */
    async deleteMemory(filename) {
      try {
        const res  = await fetch("/api/memories/" + encodeURIComponent(filename), { method: "DELETE" });
        const data = await res.json().catch(() => ({}));
        if (!res.ok || !data.ok) throw new Error(data.error || `HTTP ${res.status}`);
        _data.memories = _data.memories.filter(x => x.filename !== filename);
        _emit("profile:memoriesChanged");
        return { ok: true };
      } catch (e) {
        console.error("[Profile] delete memory failed", e);
        return { ok: false, error: e.message };
      }
    },

    /** Open an /onboard scope:<soul|user> curate session. */
    async curateProfile(scope) {
      const lang = (I18n && I18n.lang) ? I18n.lang() : "en";
      const sessionName = (I18n && I18n.t)
        ? I18n.t(scope === "soul" ? "profile.curateName.soul" : "profile.curateName.user")
        : scope;
      await _openCurateSession(sessionName, `/onboard scope:${scope} lang:${lang}`);
    },

    /** Update SOUL.md or USER.md content. Returns { ok, error }. */
    async updateProfile(kind, content) {
      const res = await fetch("/api/profile", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ kind, content })
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "Save failed");
      await Profile.loadAll();
    },

    /** Update a memory file's content. Returns { ok, error }. */
    async updateMemory(filename, content) {
      try {
        const res = await fetch("/api/memories/" + encodeURIComponent(filename), {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ content })
        });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || "Save failed");
        await _loadMemories();
        _emit("profile:memoriesChanged");
        return { ok: true };
      } catch (e) {
        console.error("[Profile] update memory failed", e);
        return { ok: false, error: e.message };
      }
    },

    /** Open an /onboard path:<abs> curate session for a memory. */
    async curateMemory(m) {
      const absPath = m.path || ("~/.clacky/memories/" + m.filename);
      const base    = (I18n && I18n.t) ? I18n.t("memories.curateName") : "Curate";
      const name    = base + " · " + (m.topic || m.filename);
      await _openCurateSession(name, `/onboard path:${absPath}`);
    },
  };

  return Profile;
})();

const Profile = ProfileStore;
