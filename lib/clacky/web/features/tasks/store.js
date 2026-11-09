// ── Tasks · store — schedule data, CRUD, business actions ──────────────────
//
// Single source of truth for cron tasks. Owns state, talks to the server, runs
// CRUD + "open a session and run a command" actions. Never touches render DOM —
// it emits events and lets the view react.
//
// Internal bus (Store.on / _emit) is always live; Clacky.ext.emit mirrors to
// the extension bus (silenced under ?pure=true).
//
// `Tasks` stays the single public facade so existing callers keep working.
//
// Depends on: WS, Sessions, Skills, Router, I18n, Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────

const TasksStore = (() => {
  let _tasks = [];   // [{ name, content, cron, enabled, scheduled, last_run }]
  let _runs  = [];   // [{ id, task, session_id, trigger, status, started_at, finished_at, error }]

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
    get tasks() { return _tasks; },
    get runs()  { return _runs; },
  };

  // Create a session and queue a command. Shared by run/create/edit actions.
  async function _openSessionWith(message, onSession) {
    const maxN = Sessions.all.reduce((max, s) => {
      const m = s.name.match(/^Session (\d+)$/);
      return m ? Math.max(max, parseInt(m[1], 10)) : max;
    }, 0);
    const res = await fetch("/api/sessions", {
      method:  "POST",
      headers: { "Content-Type": "application/json" },
      body:    JSON.stringify({ name: "Session " + (maxN + 1), source: "manual" })
    });
    const data = await res.json();
    if (!res.ok) { Modal.toast(I18n.t("tasks.sessionError") + (data.error || "unknown"), "error"); return null; }

    const session = data.session;
    if (!session) return null;

    if (!WS.ready) { WS.connect(); Skills.load(); }

    Sessions.add(session);
    Sessions.renderList();
    if (onSession) onSession(session);
    else Sessions.setPendingMessage(session.id, message);
    Sessions.select(session.id);
    return session;
  }

  const Tasks = {
    on: _on,
    state,

    /** Fetch cron tasks; emit so the view re-renders. */
    async load() {
      try {
        const res  = await fetch("/api/cron-tasks");
        const data = await res.json();
        _tasks = data.cron_tasks || [];
        _emit("tasks:changed", { tasks: _tasks });
      } catch (e) {
        console.error("[Tasks] load failed", e);
      }
    },

    async loadRuns() {
      try {
        const res  = await fetch("/api/cron-runs");
        const data = await res.json();
        _runs = data.runs || [];
        _emit("tasks:runs-changed", { runs: _runs });
      } catch (e) {
        console.error("[Tasks] loadRuns failed", e);
      }
    },

    /** Run a task now; on success reload and hand the session to Sessions. */
    async run(name) {
      const res  = await fetch(`/api/cron-tasks/${encodeURIComponent(name)}/run`, { method: "POST" });
      const data = await res.json();
      if (!res.ok) { Modal.toast(I18n.t("tasks.runError") + (data.error || "unknown"), "error"); return; }

      if (data.session) {
        await Tasks.load();
        Sessions.add(data.session);
        Sessions.renderList();
        Sessions.setPendingRunTask(data.session.id);
        Sessions.select(data.session.id);
      }
    },

    /** Toggle a scheduled task's enabled flag. `wasPaused` is the pre-click
     *  paused state; true means we resume (enabled: true). */
    async toggleEnabled(name, wasPaused) {
      const nextEnabled = wasPaused;
      const res = await fetch(`/api/cron-tasks/${encodeURIComponent(name)}`, {
        method:  "PATCH",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ enabled: nextEnabled })
      });
      if (!res.ok) {
        let msg = "";
        try { msg = (await res.json()).error || ""; } catch (_) {}
        Modal.toast(I18n.t("tasks.toggleError") + (msg ? " " + msg : ""), "error");
        return;
      }
      await Tasks.load();
    },

    /** Create a new task via a session running /cron-task-creator.
     *  `prompt` lets a starter example describe the plan up front. */
    createInSession(prompt) {
      const command = String(prompt || "").trim();
      return _openSessionWith(command ? `/cron-task-creator ${command}` : "/cron-task-creator");
    },

    /** Edit a task via a session that auto-sends the edit command. */
    editInSession(name) {
      return _openSessionWith(`/cron-task-creator I'm editing ${name} task`);
    },

    async delete(name) {
      const confirmed = await Modal.confirm(I18n.t("tasks.confirmDelete", { name }));
      if (!confirmed) return;
      const res = await fetch(`/api/cron-tasks/${encodeURIComponent(name)}`, { method: "DELETE" });
      if (!res.ok) { Modal.toast(I18n.t("tasks.deleteError"), "error"); return; }
      await Tasks.load();
    },

    async deleteRun(id) {
      const confirmed = await Modal.confirm(I18n.t("tasks.run.confirmDelete"));
      if (!confirmed) return;
      const res = await fetch(`/api/cron-runs/${encodeURIComponent(id)}`, { method: "DELETE" });
      if (!res.ok) { Modal.toast(I18n.t("tasks.run.deleteError"), "error"); return; }
      await Promise.all([Tasks.loadRuns(), Tasks.load()]);
    },
  };

  return Tasks;
})();

const Tasks = TasksStore;
