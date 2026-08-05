// ── Skills · store — data, state, network, business actions ────────────────
//
// The store is the single source of truth for skills data. It owns state,
// talks to the server, and runs business actions (toggle/delete/install/open
// a session). It NEVER touches rendering DOM directly — when data changes it
// emits an event and lets the view re-render.
//
// Two event channels, on purpose:
//   1. Internal bus (Store.on / _emit) — ALWAYS live. The core view layer
//      subscribes here. This must keep working in pure mode, otherwise the
//      official panel would stop rendering.
//   2. Clacky.ext.emit(...) — the extension bus. Fired alongside the internal
//      bus so user/AI extensions can observe core data changes. It is a no-op
//      under ?pure=true by design (extensions are silenced, core is not).
//
// `Skills` stays the single public facade so existing callers (app.js,
// settings.js, tasks.js, ws-dispatcher.js, brand.js, creator.js, onboard.js)
// keep working unchanged. View functions are reached through SkillsView, which
// the store calls only via events — never by importing view internals.
//
// Depends on: WS (ws.js), Sessions (sessions.js), Router (app.js),
//             Modal/I18n, global $ / escapeHtml helpers, Clacky.ext (core/ext.js)
// ───────────────────────────────────────────────────────────────────────────

const SkillsStore = (() => {
  // ── State (single source of truth) ─────────────────────────────────────
  let _skills          = [];          // [{ name, description, source, enabled }]
  let _brandSkills     = [];          // skills from cloud license API
  let _activeTab       = "my-skills"; // "my-skills" | "brand-skills"
  let _brandActivated  = false;       // whether a license is currently active
  let _freeMode        = false;       // brand-skills tab is showing free-mode skills
  let _paidSkillsCount = 0;           // premium (encrypted) skills locked behind activation
  let _showSystemSkills = localStorage.getItem(SKILL_AC_SHOW_SYSTEM_KEY) === "true";

  // ── Internal event bus ──────────────────────────────────────────────────
  // Always live (unlike Clacky.ext, which is silenced under ?pure=true). The
  // core view layer subscribes here so the official panel keeps rendering even
  // in pure mode.
  const _listeners = {};              // event => [handler]

  function _on(event, handler) {
    (_listeners[event] ||= []).push(handler);
    return () => {
      const list = _listeners[event];
      const i = list ? list.indexOf(handler) : -1;
      if (i >= 0) list.splice(i, 1);
    };
  }

  // Notify the core view (internal bus) and mirror to the extension bus so
  // extensions can observe core data changes. Extension delivery is silenced
  // in pure mode by Clacky.ext itself.
  function _emit(event, payload) {
    (_listeners[event] || []).forEach((h) => h(payload));
    if (window.Clacky && Clacky.ext) Clacky.ext.emit(event, payload);
  }

  // ── Read-only accessors used by the view ────────────────────────────────
  const state = {
    get skills()           { return _skills; },
    get brandSkills()      { return _brandSkills; },
    get activeTab()        { return _activeTab; },
    get brandActivated()   { return _brandActivated; },
    get freeMode()         { return _freeMode; },
    get paidSkillsCount()  { return _paidSkillsCount; },
    get showSystemSkills() { return _showSystemSkills; },
  };

  // ── Helpers shared by business actions ───────────────────────────────────

  // Resolve the next "Session N" name and create a session, then hand off to
  // Sessions. Used by every "open a session and run a command" action.
  async function _openSessionWith(message) {
    if (!WS.ready) { WS.connect(); Skills.load(); }
    try {
      return await Sessions.startWith(message, { source: "manual" });
    } catch (e) {
      alert(I18n.t("tasks.sessionError") + (e.message || "unknown"));
      return null;
    }
  }

  /** Return a user-friendly message for install/update errors. */
  function _friendlyInstallError(rawError) {
    if (!rawError) return I18n.t("skills.brand.unknownError");
    const lower = rawError.toLowerCase();
    if (lower.includes("timeout") || lower.includes("network error") ||
        lower.includes("execution expired") || lower.includes("failed to open")) {
      return I18n.t("skills.brand.networkRetry");
    }
    return I18n.t("skills.brand.installFailed") + rawError;
  }

  // ── Public facade (kept identical for existing callers) ──────────────────
  const Skills = {

    // ── Store wiring (used by the view layer only) ─────────────────────────
    on: _on,
    state,

    // ── Data ───────────────────────────────────────────────────────────────

    /** Return current skills list (read-only snapshot). */
    get all() { return _skills.slice(); },

    /** Fetch skills from server; emit so the view re-renders. */
    async load() {
      try {
        const res  = await fetch("/api/skills");
        const data = await res.json();
        _skills = data.skills || [];
        _emit("skills:changed", { skills: _skills });
      } catch (e) {
        console.error("[Skills] load failed", e);
      }
    },

    /** Fetch brand skills from server; emit so the view re-renders. */
    async loadBrandSkills() {
      _emit("brandSkills:loading");
      try {
        const res  = await fetch("/api/brand/skills");
        const data = await res.json();

        if (!res.ok || !data.ok) {
          _emit("brandSkills:error", { error: data.error || I18n.t("skills.brand.loadFailed") });
          return;
        }

        _brandSkills     = data.skills || [];
        _freeMode        = !!data.free_mode;
        _paidSkillsCount = Number(data.paid_skills_count) || 0;

        _emit("brandSkills:changed", {
          brandSkills: _brandSkills,
          freeMode: _freeMode,
          paidSkillsCount: _paidSkillsCount,
          warning: data.warning,
          warningCode: data.warning_code,
        });
      } catch (e) {
        console.error("[Skills] brand skills load failed", e);
        _emit("brandSkills:error", { network: true });
      }
    },

    /** Refresh brand license status; emit so the view can toggle the tab. */
    async refreshBrandStatus() {
      try {
        const res  = await fetch("/api/brand/status");
        const data = await res.json();
        const prevActivated = _brandActivated;
        _brandActivated = data.branded && !data.needs_activation;
        _emit("brandStatus:changed", {
          branded: data.branded,
          activated: _brandActivated,
          activatedChanged: prevActivated !== _brandActivated,
        });
      } catch (_e) {
        // On network error, keep whatever is currently shown.
      }
    },

    // ── State setters driven by the view ─────────────────────────────────────

    /** Switch the active tab; emit so the view updates tab UI. */
    setActiveTab(tab) {
      _activeTab = tab;
      _emit("tab:changed", { tab });
      if (tab === "brand-skills") Skills.loadBrandSkills();
    },

    /** Toggle visibility of system skills; emit so the view re-renders. */
    setShowSystemSkills(show) {
      _showSystemSkills = !!show;
      localStorage.setItem(SKILL_AC_SHOW_SYSTEM_KEY, _showSystemSkills ? "true" : "false");
      _emit("skills:changed", { skills: _skills });
    },

    // ── Actions ──────────────────────────────────────────────────────────────

    /** Toggle enable/disable for a skill, then reload. */
    async toggle(name, enabled) {
      try {
        const res = await fetch(`/api/skills/${encodeURIComponent(name)}/toggle`, {
          method:  "PATCH",
          headers: { "Content-Type": "application/json" },
          body:    JSON.stringify({ enabled })
        });
        const data = await res.json();
        if (!res.ok) { alert(I18n.t("skills.toggleError") + (data.error || "unknown")); return; }
        await Skills.load();
      } catch (e) {
        console.error("[Skills] toggle failed", e);
      }
    },

    /** Delete a custom skill by name. Confirms, then reloads. */
    async delete(name) {
      if (!confirm(I18n.t("skills.deleteConfirm", { name }))) return;
      try {
        const res = await fetch(`/api/skills/${encodeURIComponent(name)}`, { method: "DELETE" });
        const data = await res.json();
        if (!res.ok) { alert(data.error || I18n.t("skills.deleteError")); return; }
        Modal.toast(I18n.t("skills.deleted", { name }), "success");
        await Skills.load();
      } catch (e) {
        console.error("[Skills] delete failed", e);
      }
    },

    /** Install or update a brand skill. Resolves to a result the view renders. */
    async installBrandSkill(name) {
      try {
        const res  = await fetch(`/api/brand/skills/${encodeURIComponent(name)}/install`, { method: "POST" });
        const data = await res.json();
        if (!res.ok || !data.ok) {
          return { ok: false, message: _friendlyInstallError(data.error) };
        }
        const skill = _brandSkills.find(s => s.name === name);
        if (skill) { skill.installed_version = data.version; skill.needs_update = false; }
        _emit("brandSkills:changed", { brandSkills: _brandSkills, freeMode: _freeMode, paidSkillsCount: _paidSkillsCount });
        await Skills.load();
        return { ok: true };
      } catch (e) {
        return { ok: false, message: I18n.t("skills.brand.networkRetry") };
      }
    },

    /** Delete an installed brand skill. */
    async deleteBrandSkill(name) {
      if (!confirm(I18n.t("skills.deleteConfirm", { name }))) return;
      try {
        const res  = await fetch(`/api/brand/skills/${encodeURIComponent(name)}`, { method: "DELETE" });
        const data = await res.json();
        if (!res.ok || !data.ok) { alert(data.error || I18n.t("skills.deleteError")); return; }
        const skill = _brandSkills.find(s => s.name === name);
        if (skill) skill.installed_version = null;
        _emit("brandSkills:changed", { brandSkills: _brandSkills, freeMode: _freeMode, paidSkillsCount: _paidSkillsCount });
        await Skills.load();
        Modal.toast(I18n.t("skills.deleted", { name }), "success");
      } catch (e) {
        console.error("[Skills] brand skill delete failed", e);
      }
    },

    /** Open a session and run a brand skill by sending "/{name}". */
    useInstalledSkill(name) {
      return _openSessionWith("/" + name);
    },

    /** Create a new custom skill via a session running /skill-creator. */
    createInSession(message) {
      return _openSessionWith(message || "/skill-creator");
    },

    /** Fetch a custom skill's SKILL.md content. Returns { ok, content, path, error }. */
    async fetchSkillContent(name) {
      try {
        const res  = await fetch(`/api/skills/${encodeURIComponent(name)}/content`);
        const data = await res.json();
        if (!data.ok) throw new Error(data.error || "Load failed");
        return { ok: true, content: data.content || "", path: data.path };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    /** Update a custom skill's SKILL.md content. Returns { ok, error }. */
    async updateSkillContent(name, content) {
      try {
        const res  = await fetch(`/api/skills/${encodeURIComponent(name)}/content`, {
          method:  "PUT",
          headers: { "Content-Type": "application/json" },
          body:    JSON.stringify({ content })
        });
        const data = await res.json();
        if (!res.ok || !data.ok) throw new Error(data.error || "Save failed");
        await Skills.load();
        return { ok: true };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    /** Import a skill: validate url/path, open a session, run /skill-add. */
    async importSkill(url) {
      const trimmed = (url || "").trim();
      if (!trimmed) return { ok: false, reason: "empty" };
      const isUrl       = /^https?:\/\//i.test(trimmed);
      const isLocalPath = trimmed.startsWith("/") || trimmed.startsWith("~");
      if (!isUrl && !isLocalPath) return { ok: false, reason: "invalid" };
      try {
        await _openSessionWith(`/skill-add ${trimmed}`);
        return { ok: true };
      } catch (e) {
        console.error("[Skills] import failed", e);
        return { ok: false, reason: "network" };
      }
    },

    // ── Cross-feature state resets (called by settings.js) ───────────────────

    resetBrandState() {
      _brandSkills    = [];
      _brandActivated = false;
      _activeTab      = "my-skills";
      _emit("brandStatus:changed", { branded: false, activated: false, activatedChanged: true });
      _emit("tab:changed", { tab: "my-skills", reason: "unbind" });
    },
  };

  return Skills;
})();

// Expose the facade under its historical global name.
const Skills = SkillsStore;
Clacky.Skills = Skills;
