// ── Tasks — task/schedule state, rendering, CRUD ──────────────────────────
//
// Responsibilities:
//   - Single source of truth for tasks + schedules data
//   - Render the "Scheduled Tasks" entry in the sidebar
//   - Show/render the task list table in the main panel
//   - CRUD: load, run, editInSession (creates new session), delete
//
// Panel switching is delegated to Router — Tasks only manages data + rendering.
//
// Depends on: WS (ws.js), Sessions (sessions.js), Router (app.js),
//             global $ / escapeHtml helpers
// ─────────────────────────────────────────────────────────────────────────

const Tasks = (() => {
  // ── Private state ──────────────────────────────────────────────────────
  let _tasks = [];   // [{ name, content, cron, enabled, scheduled }]

  // ── Private helpers ────────────────────────────────────────────────────

  function _humanCron(cron) {
    if (!cron) return cron;
    const parts = cron.trim().split(/\s+/);
    if (parts.length !== 5) return cron;
    const [min, hour, dom, month, dow] = parts;

    const isAny = v => v === "*";
    const isNum = v => /^\d+$/.test(v);
    const pad   = n => String(n).padStart(2, "0");

    const lang = (typeof I18n !== "undefined" && I18n.lang()) || "zh";
    const isZh = lang === "zh";

    const dowNames = isZh
      ? ["周日","周一","周二","周三","周四","周五","周六"]
      : ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];

    const monthNames = isZh
      ? ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"]
      : ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

    const timeStr = (isNum(hour) && isNum(min))
      ? `${pad(hour)}:${pad(min)}`
      : null;

    // Every N minutes
    if (min.startsWith("*/") && isAny(hour) && isAny(dom) && isAny(month) && isAny(dow)) {
      const n = min.slice(2);
      return isZh ? `每 ${n} 分钟` : `Every ${n} min`;
    }
    // Every N hours
    if ((isAny(min) || isNum(min)) && hour.startsWith("*/") && isAny(dom) && isAny(month) && isAny(dow)) {
      const n = hour.slice(2);
      return isZh ? `每 ${n} 小时` : `Every ${n} hr`;
    }
    // Every minute
    if (isAny(min) && isAny(hour) && isAny(dom) && isAny(month) && isAny(dow)) {
      return isZh ? "每分钟" : "Every minute";
    }
    // Every hour at :MM
    if (isNum(min) && isAny(hour) && isAny(dom) && isAny(month) && isAny(dow)) {
      return isZh ? `每小时 :${pad(min)}` : `Hourly at :${pad(min)}`;
    }
    // Specific day-of-week
    if (timeStr && isAny(dom) && isAny(month) && isNum(dow)) {
      const d = dowNames[parseInt(dow, 10)] || dow;
      return isZh ? `每${d} ${timeStr}` : `${d} ${timeStr}`;
    }
    // Weekdays (1-5)
    if (timeStr && isAny(dom) && isAny(month) && dow === "1-5") {
      return isZh ? `工作日 ${timeStr}` : `Weekdays ${timeStr}`;
    }
    // Weekends (0,6 or 6,0)
    if (timeStr && isAny(dom) && isAny(month) && (dow === "0,6" || dow === "6,0")) {
      return isZh ? `周末 ${timeStr}` : `Weekends ${timeStr}`;
    }
    // Every day at HH:MM
    if (timeStr && isAny(dom) && isAny(month) && isAny(dow)) {
      return isZh ? `每天 ${timeStr}` : `Daily ${timeStr}`;
    }
    // Specific day of month
    if (timeStr && isNum(dom) && isAny(month) && isAny(dow)) {
      return isZh ? `每月 ${dom} 日 ${timeStr}` : `Monthly day ${dom} ${timeStr}`;
    }
    // Specific month + day
    if (timeStr && isNum(dom) && isNum(month) && isAny(dow)) {
      const m = monthNames[parseInt(month, 10) - 1] || month;
      return isZh ? `${m}${dom}日 ${timeStr}` : `${m} ${dom} ${timeStr}`;
    }

    return cron;
  }

  /** Render a single task row in the main panel table. */
  function _renderTaskRow(t) {
    const row = document.createElement("div");
    row.className = "task-card";
    row.dataset.name = t.name;

    const isPaused = t.scheduled && t.enabled === false;
    row.classList.toggle("task-card-paused", isPaused);

    const schedLabel = t.scheduled
      ? `<span class="task-card-cron" title="${escapeHtml(t.cron)}">${escapeHtml(_humanCron(t.cron))}</span>`
      : `<span class="task-card-cron task-card-cron-manual">${I18n.t("tasks.manual")}</span>`;

    const pausedBadge = isPaused
      ? `<span class="task-card-badge task-card-badge-paused">${I18n.t("tasks.paused")}</span>`
      : "";

    const content = t.content || "";
    const isTruncated = content.trim().length > 0;
    const previewText = escapeHtml(content.replace(/\s+/g, " ").trim()) || escapeHtml(I18n.t("tasks.empty"));

    const toggleBtnHtml = t.scheduled ? (isPaused
      ? `<button class="task-action-btn task-btn-toggle task-btn-resume">
           <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
             <polygon points="6 3 20 12 6 21 6 3"/>
           </svg>
           <span>${I18n.t("tasks.btn.resume")}</span>
         </button>`
      : `<button class="task-action-btn task-btn-toggle task-btn-pause">
           <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
             <rect x="6" y="4" width="4" height="16" rx="1"/>
             <rect x="14" y="4" width="4" height="16" rx="1"/>
           </svg>
           <span>${I18n.t("tasks.btn.pause")}</span>
         </button>`
    ) : "";

    row.innerHTML = `
      <div class="task-card-main">
        <div class="task-card-icon">
          <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="10"/>
            <polyline points="12 6 12 12 16 14"/>
          </svg>
        </div>
        <div class="task-card-info">
          <div class="task-card-title-row">
            <span class="task-card-name">${escapeHtml(t.name)}</span>
            ${pausedBadge}
            ${schedLabel}
          </div>
          <div class="task-card-preview${isTruncated ? " task-card-preview-expandable" : ""}">${previewText}</div>
        </div>
        <div class="task-card-actions">
          <button class="task-run-btn task-btn-run" title="${I18n.t("tasks.btn.run")}">
            <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <polygon points="6 3 20 12 6 21 6 3"/>
            </svg>
            <span>${I18n.t("tasks.btn.run")}</span>
          </button>
          ${toggleBtnHtml}
          <button class="task-action-btn task-btn-edit">
            <svg xmlns="http://www.w3.org/2000/svg" width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"/>
              <path d="m15 5 4 4"/>
            </svg>
            <span>${I18n.t("tasks.btn.edit")}</span>
          </button>
          <button class="task-action-btn task-btn-del">
            <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <path d="M3 6h18"/><path d="M19 6l-1 14H6L5 6"/><path d="M8 6V4h8v2"/>
            </svg>
            <span>${I18n.t("tasks.btn.delete")}</span>
          </button>
        </div>
      </div>
      ${isTruncated ? `<div class="task-card-detail" hidden><pre class="task-card-detail-content">${escapeHtml(content)}</pre></div>` : ""}`;

    row.querySelector(".task-btn-run").addEventListener("click", e => {
      e.stopPropagation();
      Tasks.run(t.name);
    });

    if (isTruncated) {
      const previewEl = row.querySelector(".task-card-preview");
      const detailEl  = row.querySelector(".task-card-detail");
      previewEl.addEventListener("click", e => {
        e.stopPropagation();
        const expanded = !detailEl.hidden;
        detailEl.hidden = expanded;
        row.classList.toggle("task-card-expanded", !expanded);
      });
    }
    const toggleBtn = row.querySelector(".task-btn-toggle");
    if (toggleBtn) {
      toggleBtn.addEventListener("click", e => {
        e.stopPropagation();
        Tasks.toggleEnabled(t.name, isPaused);  // isPaused=true means we want to enable
      });
    }
    row.querySelector(".task-btn-edit").addEventListener("click", e => {
      e.stopPropagation();
      Tasks.editInSession(t.name);
    });
    row.querySelector(".task-btn-del").addEventListener("click", e => {
      e.stopPropagation();
      Tasks.delete(t.name);
    });

    return row;
  }

  // ── Public API ─────────────────────────────────────────────────────────
  return {

    // ── Data ─────────────────────────────────────────────────────────────

    /** Fetch cron tasks from server; re-render sidebar + panel if open. */
    async load() {
      try {
        const res  = await fetch("/api/cron-tasks");
        const data = await res.json();
        _tasks = data.cron_tasks || [];
        Tasks.renderSection();
        if (Router.current === "tasks") Tasks.renderTable();
      } catch (e) {
        console.error("[Tasks] load failed", e);
      }
    },

    // ── Router interface ──────────────────────────────────────────────────

    /** Called by Router when the tasks panel becomes active. */
    onPanelShow() {
      Tasks.load();
      const btn = $("btn-create-task");
      if (btn) btn.onclick = () => Tasks.createInSession();
    },

    // ── Sidebar rendering ─────────────────────────────────────────────────

    renderSection() {
      // Sidebar item is static in HTML — just update the label text.
      const labelEl = $("tasks-sidebar-label");
      if (!labelEl) return;
      labelEl.textContent = I18n.t("sidebar.tasks");
    },

    // ── Main panel table ──────────────────────────────────────────────────

    /** Render all tasks as rows in the main panel table. */
    renderTable() {
      const table = $("task-list-table");
      table.innerHTML = "";

      if (_tasks.length === 0) {
        const empty = document.createElement("div");
        empty.className = "task-table-empty";
        empty.innerHTML = `
          <p>${I18n.t("tasks.noScheduled")}</p>
          <button class="task-create-btn" id="btn-create-task-empty">
            <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon-sm">
              <path d="M5 12h14"/>
              <path d="M12 5v14"/>
            </svg> ${I18n.t("tasks.btn.createTask")}
          </button>`;
        table.appendChild(empty);
        const btn = table.querySelector("#btn-create-task-empty");
        if (btn) btn.addEventListener("click", () => Tasks.createInSession());
        return;
      }

      _tasks.forEach(t => table.appendChild(_renderTaskRow(t)));
    },

    // ── CRUD ─────────────────────────────────────────────────────────────

    async run(name) {
      const res = await fetch(`/api/cron-tasks/${encodeURIComponent(name)}/run`, {
        method: "POST"
      });
      const data = await res.json();
      if (!res.ok) { alert(I18n.t("tasks.runError") + (data.error || "unknown")); return; }

      if (data.session) {
        await Tasks.load();
        Sessions.add(data.session);
        Sessions.renderList();
        Sessions.setPendingRunTask(data.session.id);
        Sessions.select(data.session.id);
      }
    },

    /** Toggle a scheduled task's enabled flag. `wasPaused` is the current
     *  paused-state before the click; if true, we resume (enabled: true).
     *  Optimistic: we update local state first, then reload on success. */
    async toggleEnabled(name, wasPaused) {
      const nextEnabled = wasPaused; // paused → resume(true); running → pause(false)
      const res = await fetch(`/api/cron-tasks/${encodeURIComponent(name)}`, {
        method:  "PATCH",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ enabled: nextEnabled })
      });
      if (!res.ok) {
        let msg = "";
        try { msg = (await res.json()).error || ""; } catch (_) {}
        alert(I18n.t("tasks.toggleError") + (msg ? " " + msg : ""));
        return;
      }
      await Tasks.load();
    },

    /** Create a new task by opening a new session and sending /create-task. */
    async createInSession() {
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
      if (!res.ok) { alert(I18n.t("tasks.sessionError") + (data.error || "unknown")); return; }

      const session = data.session;
      if (!session) return;

      // If WS is not yet connected (e.g. called during onboarding), boot the UI
      // first so WS connects, then use setPendingMessage so the command is sent
      // once the socket is ready. This mirrors Onboard._startSoulSession().
      if (!WS.ready) {
        WS.connect();
        Skills.load();
      }

      Sessions.add(session);
      Sessions.renderList();
      Sessions.setPendingMessage(session.id, "/cron-task-creator");
      Sessions.select(session.id);
    },

    /** Edit a task by creating a new session and auto-sending the edit command. */
    async editInSession(name) {
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
      if (!res.ok) { alert("Error creating session: " + (data.error || "unknown")); return; }

      const session = data.session;
      if (!session) return;

      if (!WS.ready) {
        WS.connect();
        Skills.load();
      }

      Sessions.add(session);
      Sessions.renderList();
      Sessions.setPendingMessage(session.id, `/cron-task-creator I'm editing ${name} task`);
      Sessions.select(session.id);
    },

    async delete(name) {
      if (!confirm(I18n.t("tasks.confirmDelete", { name }))) return;
      const res = await fetch(`/api/cron-tasks/${encodeURIComponent(name)}`, { method: "DELETE" });
      if (!res.ok) { alert(I18n.t("tasks.deleteError")); return; }

      await Tasks.load();
    },
  };
})();
