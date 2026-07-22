// ── NewSession · store — agent list + selection + advanced options ────────
//
// Owns the state for the "new session" landing page: the list of agents
// fetched from /api/agents, the current selection (persisted in localStorage),
// and the advanced-options form values (name / model / working dir / init).
// It never renders — NewSessionView owns the DOM.
//
// Also handles session creation: POST /api/sessions with the current selection
// and returns the created session summary. Sending the first message is the
// caller's job (via Sessions.setPendingMessage + Sessions.select).
//
// Depends on: Clacky.ext (for cross-module event emit).
// ───────────────────────────────────────────────────────────────────────────

const NewSessionStore = (() => {
  const LS_AGENT_KEY = "openclacky.newSession.lastAgent";

  const _state = {
    agents: [],
    selectedAgentId: null,
    advanced: {
      name: "",
      modelId: "",
      workingDir: "",
      initProject: false,
    },
    advancedOpen: false,
    creating: false,
  };

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

  async function loadAgents() {
    try {
      const res = await fetch("/api/agents");
      if (!res.ok) return;
      const data = await res.json();
      _state.agents = (data && data.agents) || [];

      // Restore last-used agent from localStorage; fall back to the first
      // available one (typically "general").
      const remembered = localStorage.getItem(LS_AGENT_KEY);
      const found = _state.agents.find((a) => a.id === remembered);
      _state.selectedAgentId = found
        ? found.id
        : (_state.agents[0] && _state.agents[0].id) || "general";

      _emit("newSession:agents-loaded", { agents: _state.agents });
      _emit("newSession:selection-changed", { agentId: _state.selectedAgentId });
    } catch (e) {
      console.error("Failed to load agents:", e);
    }
  }

  function selectAgent(agentId) {
    if (!agentId || agentId === _state.selectedAgentId) return;
    const found = _state.agents.find((a) => a.id === agentId);
    if (!found) return;
    _state.selectedAgentId = agentId;
    localStorage.setItem(LS_AGENT_KEY, agentId);
    _emit("newSession:selection-changed", { agentId });
  }

  function currentAgent() {
    return _state.agents.find((a) => a.id === _state.selectedAgentId) || null;
  }

  function toggleAdvanced(open) {
    _state.advancedOpen = open === undefined ? !_state.advancedOpen : !!open;
    _emit("newSession:advanced-toggled", { open: _state.advancedOpen });
  }

  function updateAdvanced(patch) {
    Object.assign(_state.advanced, patch);
    _emit("newSession:advanced-changed", { advanced: _state.advanced });
  }

  async function loadModels() {
    try {
      const res = await fetch("/api/config");
      if (!res.ok) return [];
      const data = await res.json();
      return (data && data.models) || [];
    } catch (e) {
      console.error("Failed to load models:", e);
      return [];
    }
  }

  async function loadDefaultDirectory() {
    try {
      const res = await fetch("/api/dirs");
      if (!res.ok) return "";
      const data = await res.json();
      const home = data && data.home;
      if (!home) return "";
      return home.replace(/\/+$/, "") + "/clacky_workspace";
    } catch (e) {
      return "";
    }
  }

  function _autoName(existingSessions) {
    const maxN = (existingSessions || []).reduce((max, s) => {
      const m = s.name && s.name.match(/^Session (\d+)$/);
      return m ? Math.max(max, parseInt(m[1], 10)) : max;
    }, 0);
    return "Session " + (maxN + 1);
  }

  async function createSession({ existingSessions, useDefaults = false } = {}) {
    if (_state.creating) return null;
    _state.creating = true;
    _emit("newSession:creating", { creating: true });

    try {
      // useDefaults=true: quick-create from sidebar — use the default agent and
      // skip advanced options (model / dir) so the session always starts clean.
      const agentId = useDefaults ? "general" : (_state.selectedAgentId || "general");
      const adv = _state.advanced;
      const name = adv.name.trim() || _autoName(existingSessions);

      const payload = { name, agent_profile: agentId, source: "manual" };
      if (!useDefaults) {
        if (adv.workingDir.trim()) payload.working_dir = adv.workingDir.trim();
        if (adv.modelId) payload.model_id = adv.modelId;
      }

      const res = await fetch("/api/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const data = await res.json();

      if (!res.ok) {
        const msg = data.error || "unknown error";
        const friendly = res.status === 409
          ? I18n.t("sessions.dirNotEmpty")
          : I18n.t("sessions.createError") + msg;
        alert(friendly);
        return null;
      }

      return data.session || null;
    } catch (e) {
      alert(I18n.t("sessions.createError") + e.message);
      return null;
    } finally {
      _state.creating = false;
      _emit("newSession:creating", { creating: false });
    }
  }

  function reset() {
    _state.advanced.name = "";
    _state.advanced.initProject = false;
    _emit("newSession:reset", {});
  }

  async function fetchSkillsForAgent(agentId) {
    try {
      const res = await fetch(`/api/agents/${encodeURIComponent(agentId)}/skills`);
      if (!res.ok) return [];
      const data = await res.json();
      return data.skills || [];
    } catch (e) {
      console.error("Failed to load skills:", e);
      return [];
    }
  }

  return {
    get state() { return _state; },
    on: _on,
    loadAgents,
    selectAgent,
    currentAgent,
    toggleAdvanced,
    updateAdvanced,
    loadModels,
    loadDefaultDirectory,
    createSession,
    fetchSkillsForAgent,
    reset,
  };
})();

window.NewSessionStore = NewSessionStore;
