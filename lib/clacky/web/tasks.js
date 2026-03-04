// ── Tasks — task/schedule state, rendering, CRUD ──────────────────────────
//
// Responsibilities:
//   - Single source of truth for tasks + schedules data
//   - Render the tasks section in the sidebar
//   - Show task-detail panel
//   - CRUD: load, run, delete, edit
//
// Depends on: WS (ws.js), Sessions (sessions.js), global $ / escapeHtml
// ─────────────────────────────────────────────────────────────────────────

const Tasks = (() => {
  // ── Private state ──────────────────────────────────────────────────────
  let _tasks     = [];   // [{ name, schedules: Schedule[] }]
  let _schedules = [];   // [{ name, task, cron, enabled }]
  let _activeName = null;

  // ── Private helpers ────────────────────────────────────────────────────

  /** Merge schedule info into task objects. Pure function. */
  function _attachSchedules(tasks, schedules) {
    return tasks.map(t => ({
      ...t,
      schedules: schedules.filter(s => s.task === t.name)
    }));
  }

  // ── Public API ─────────────────────────────────────────────────────────
  return {
    get active() { return _activeName; },

    // ── Data ─────────────────────────────────────────────────────────────

    /** Fetch tasks + schedules from server; re-render sidebar. */
    async load() {
      try {
        const [tr, sr] = await Promise.all([
          fetch("/api/tasks"),
          fetch("/api/schedules")
        ]);
        const td = await tr.json();
        const sd = await sr.json();
        _schedules = sd.schedules || [];
        _tasks     = _attachSchedules(td.tasks || [], _schedules);
        Tasks.renderSection();
      } catch (e) {
        console.error("[Tasks] load failed", e);
      }
    },

    // ── Sidebar rendering ─────────────────────────────────────────────────

    renderSection() {
      const section   = $("tasks-section");
      const container = $("task-list-items");
      container.innerHTML = "";
      section.style.display = "";   // always visible

      if (_tasks.length === 0) {
        container.innerHTML =
          '<div class="task-empty-hint">No tasks yet.<br>Ask the Agent to create one!</div>';
        return;
      }

      _tasks.forEach(t => {
        const isActive   = t.name === _activeName;
        const cronLabel  = t.schedules.length > 0
          ? `<span class="task-cron">${escapeHtml(t.schedules[0].cron)}</span>`
          : "";

        const el = document.createElement("div");
        el.className = "task-item" + (isActive ? " active" : "");
        el.dataset.name = t.name;
        el.innerHTML = `
          <div class="task-row">
            <span class="task-icon">⏰</span>
            <div class="task-info">
              <span class="task-name">${escapeHtml(t.name)}</span>
              ${cronLabel}
            </div>
            <div class="task-actions">
              <button class="task-btn-run" title="Run now">▶</button>
              <button class="task-btn-del" title="Delete">✕</button>
            </div>
          </div>`;

        // Event delegation via named handlers — no stale closures
        el.querySelector(".task-row").addEventListener("click", e => {
          if (e.target.closest("button")) return;
          Tasks.select(t.name);
        });
        el.querySelector(".task-btn-run").addEventListener("click", e => {
          e.stopPropagation();
          Tasks.run(t.name);
        });
        el.querySelector(".task-btn-del").addEventListener("click", e => {
          e.stopPropagation();
          Tasks.delete(t.name);
        });

        container.appendChild(el);
      });
    },

    // ── Detail panel ──────────────────────────────────────────────────────

    /** Select a task: show the detail panel (uses cached data, no extra fetch). */
    select(name) {
      const task = _tasks.find(t => t.name === name);
      if (!task) return;

      _activeName = name;
      Tasks.renderSection();   // update sidebar active state

      // Deselect any active session (but don't destroy its message cache)
      Sessions._activeId = null;   // internal update without triggering deselect()
      WS.setSubscribedSession(null);
      Sessions.renderList();

      // Show task detail panel
      $("welcome").style.display           = "none";
      $("chat-panel").style.display        = "none";
      $("task-detail-panel").style.display = "flex";

      $("task-detail-title").textContent = "⏰ " + name;
      $("task-detail-prompt").textContent = task.content || "";

      // Schedule badges
      const schedEl = $("task-schedule-info");
      if (task.schedules.length > 0) {
        schedEl.innerHTML = task.schedules.map(s =>
          `<span class="sched-badge">⏰ ${escapeHtml(s.cron)}</span>`
        ).join(" ");
      } else {
        schedEl.innerHTML = '<span class="sched-badge sched-manual">Manual only</span>';
      }
    },

    deselect() {
      _activeName = null;
      Tasks.renderSection();
    },

    // ── CRUD ─────────────────────────────────────────────────────────────

    async run(name) {
      const res  = await fetch("/api/tasks/run", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name })
      });
      const data = await res.json();
      if (!res.ok) { alert("Error: " + (data.error || "unknown")); return; }

      if (data.session_id) {
        await Tasks.load();                          // refresh task list
        Sessions._waitAndSelect(data.session_id);    // navigate to new session
      }
    },

    async delete(name) {
      if (!confirm(`Delete task "${name}"?`)) return;
      const res = await fetch(`/api/tasks/${encodeURIComponent(name)}`, { method: "DELETE" });
      if (!res.ok) { alert("Error deleting task."); return; }
      if (_activeName === name) Sessions.deselect();
      _activeName = null;
      await Tasks.load();
    },

    openEditModal(name) {
      const task = _tasks.find(t => t.name === name);
      if (!task) return;
      $("task-edit-name").value    = name;
      $("task-edit-content").value = task.content || "";
      $("task-edit-overlay").style.display = "flex";
      $("task-edit-content").focus();
    },

    closeEditModal() {
      $("task-edit-overlay").style.display = "none";
    },

    async saveEdit() {
      const name    = $("task-edit-name").value;
      const content = $("task-edit-content").value;

      const res = await fetch("/api/tasks", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name, content })
      });
      const data = await res.json();
      if (!res.ok) { alert("Error: " + (data.error || "unknown")); return; }

      Tasks.closeEditModal();
      await Tasks.load();
      Tasks.select(name);
    },
  };
})();
