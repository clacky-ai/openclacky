// ── Tasks · view — rendering, DOM event wiring ─────────────────────────────
//
// Owns everything that touches the DOM: the task table, sidebar label, panel
// wiring. Reads data through TasksStore.state and reacts to store events via
// Tasks.on(...). Calls store actions; never fetches data itself.
//
// Augments the `Tasks` facade with the UI methods other modules invoke
// (onPanelShow / renderSection / renderTable).
//
// Depends on: TasksStore, I18n/Router, global $ / escapeHtml helpers.
// ───────────────────────────────────────────────────────────────────────────

const TasksView = (() => {

  function _humanCron(cron) {
    if (!cron) return cron;
    const parts = cron.trim().split(/\s+/);
    if (parts.length !== 5) return cron;
    let [min, hour, dom, month, dow] = parts;

    // normalize */1 → *
    if (min === "*/1")   min   = "*";
    if (hour === "*/1")  hour  = "*";
    if (dom === "*/1")   dom   = "*";
    if (month === "*/1") month = "*";
    if (dow === "*/1")   dow   = "*";

    const isAny = v => v === "*";
    const isInt = v => /^\d+$/.test(v);
    const pad   = n => String(n).padStart(2, "0");

    const lang = (typeof I18n !== "undefined" && I18n.lang()) || "zh";
    const isZh = lang === "zh";

    const DOW_ZH = ["周日","周一","周二","周三","周四","周五","周六"];
    const DOW_EN = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
    const MON_ZH = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"];
    const MON_EN = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

    // dow → label, e.g. "1-5"→"工作日", "1,3,5"→"周一、周三、周五", "1"→"每周一"
    function dowLabel(d) {
      if (isAny(d)) return null;
      if (d === "1-5") return isZh ? "工作日" : "Weekdays";
      if (d === "0,6" || d === "6,0") return isZh ? "周末" : "Weekends";
      if (isInt(d)) {
        const name = (isZh ? DOW_ZH : DOW_EN)[parseInt(d, 10)] || d;
        return isZh ? `每${name}` : name;
      }
      if (/^[\d,]+$/.test(d)) {
        const names = d.split(",").map(n => (isZh ? DOW_ZH : DOW_EN)[parseInt(n, 10)] || n);
        return isZh ? names.join("、") : names.join("/");
      }
      return d;
    }

    // build HH:MM string; supports single hour or comma-list like "10,14"
    function timeStr() {
      if (!isInt(min)) return null;
      if (isInt(hour)) return `${pad(hour)}:${pad(min)}`;
      if (/^[\d,]+$/.test(hour))
        return hour.split(",").map(h => `${pad(h)}:${pad(min)}`).join(isZh ? "、" : "/");
      return null;
    }

    // ── every-N-minutes ───────────────────────────────────────────────────
    if (min.startsWith("*/") && isAny(hour) && isAny(dom) && isAny(month) && isAny(dow)) {
      const n = min.slice(2);
      return isZh ? `每 ${n} 分钟` : `Every ${n} min`;
    }
    // ── every-N-hours ─────────────────────────────────────────────────────
    if (isAny(dom) && isAny(month) && isAny(dow)) {
      if (isAny(min) && hour.startsWith("*/")) {
        return isZh ? `每 ${hour.slice(2)} 小时` : `Every ${hour.slice(2)} hr`;
      }
      if (isInt(min) && hour.startsWith("*/")) {
        return isZh ? `每 ${hour.slice(2)} 小时` : `Every ${hour.slice(2)} hr`;
      }
    }
    // ── every-N-hours on specific days  e.g. 0 */3 * * 1-5 ────────────
    if (isAny(dom) && isAny(month) && !isAny(dow) && hour.startsWith("*/")) {
      const dl = dowLabel(dow);
      const ev = isZh ? `每 ${hour.slice(2)} 小时` : `Every ${hour.slice(2)} hr`;
      if (dl) return `${dl} ${ev}`;
    }
    // ── every minute ──────────────────────────────────────────────────────
    if (isAny(min) && isAny(hour) && isAny(dom) && isAny(month) && isAny(dow)) {
      return isZh ? "每分钟" : "Every minute";
    }
    // ── hourly at :MM ─────────────────────────────────────────────────────
    if (isInt(min) && isAny(hour) && isAny(dom) && isAny(month) && isAny(dow)) {
      return isZh ? `每小时 :${pad(min)}` : `Hourly at :${pad(min)}`;
    }
    // ── hourly at :MM on specific days  e.g. 30 * * * 1-5 ─────────────
    if (isInt(min) && isAny(hour) && isAny(dom) && isAny(month) && !isAny(dow)) {
      const dl = dowLabel(dow);
      const tm = isZh ? `每小时 :${pad(min)}` : `Hourly at :${pad(min)}`;
      if (dl) return `${dl} ${tm}`;
    }

    // ── every-N-min within hour range on certain days  e.g. */1 9-14 * * 1-5
    if (min.startsWith("*/") && /^\d+-\d+$/.test(hour) && isAny(dom) && isAny(month)) {
      const n   = min.slice(2);
      const dl  = dowLabel(dow);
      const hr  = isZh ? `${hour}时` : `${hour}h`;
      const ev  = isZh ? `每 ${n} 分钟` : `Every ${n} min`;
      return dl ? `${dl} ${hr} ${ev}` : `${hr} ${ev}`;
    }
    // ── every minute within hour range  e.g. * 9-14 * * 1-5
    if (isAny(min) && /^\d+-\d+$/.test(hour) && isAny(dom) && isAny(month)) {
      const dl = dowLabel(dow);
      const hr = isZh ? `${hour}时` : `${hour}h`;
      const ev = isZh ? "每分钟" : "Every minute";
      return dl ? `${dl} ${hr} ${ev}` : `${hr} ${ev}`;
    }

    const ts  = timeStr();
    const dl  = dowLabel(dow);

    // ── fixed time, variable days ─────────────────────────────────────────
    if (ts && isAny(dom) && isAny(month)) {
      if (dl) return `${dl} ${ts}`;
      return isZh ? `每天 ${ts}` : `Daily ${ts}`;
    }
    // ── fixed time, fixed day-of-month ────────────────────────────────────
    if (ts && isInt(dom) && isAny(month) && isAny(dow)) {
      return isZh ? `每月 ${dom} 日 ${ts}` : `Monthly day ${dom} ${ts}`;
    }
    // ── fixed time, fixed date ────────────────────────────────────────────
    if (ts && isInt(dom) && isInt(month) && isAny(dow)) {
      const m = (isZh ? MON_ZH : MON_EN)[parseInt(month, 10) - 1] || month;
      return isZh ? `${m}${dom}日 ${ts}` : `${m} ${dom} ${ts}`;
    }

    return cron;
  }

  const ICONS = {
    play:   '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7.5 4.2a1 1 0 0 1 1.53-.85l10.3 7.8a1 1 0 0 1 0 1.7l-10.3 7.8a1 1 0 0 1-1.53-.85Z"/></svg>',
    more:   '<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="19" cy="12" r="1.6"/></svg>',
    edit:   '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>',
    pause:  '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><line x1="10" y1="9" x2="10" y2="15"/><line x1="14" y1="9" x2="14" y2="15"/></svg>',
    resume: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><polygon points="10 8.5 16 12 10 15.5 10 8.5"/></svg>',
    history:'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l3 2"/></svg>',
    del:    '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M19 6l-1 14H6L5 6"/><path d="M8 6V4h8v2"/></svg>',
  };

  let _tab       = "tasks";
  let _query     = "";
  let _filter    = "all";   // all | active | paused
  let _runsTask  = null;   // narrow the run list to one task (from a row's menu)
  let _menuEl    = null;
  let _menuBtn   = null;

  function _matches(text) {
    return String(text || "").toLowerCase().includes(_query);
  }

  function _pad(n) { return String(n).padStart(2, "0"); }

  function _formatTime(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (isNaN(d)) return "";
    return `${_pad(d.getMonth() + 1)}/${_pad(d.getDate())} ${_pad(d.getHours())}:${_pad(d.getMinutes())}`;
  }

  function _nextRunLabel(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (isNaN(d)) return "";
    const mins = Math.round((d - new Date()) / 60000);
    if (mins <= 0) return I18n.t("tasks.next.soon");
    if (mins < 60) return I18n.t("tasks.next.minutes", { n: mins });
    const hours = Math.round(mins / 60);
    if (hours < 24) return I18n.t("tasks.next.hours", { n: hours });
    return I18n.t("tasks.next.days", { n: Math.round(hours / 24) });
  }

  function _plainPreview(md) {
    return (md || "")
      .replace(/```[\s\S]*?```/g, " ")
      .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/^[ \t]{0,3}#{1,6}[ \t]*/gm, "")
      .replace(/^[ \t]{0,3}>[ \t]?/gm, "")
      .replace(/^[ \t]{0,3}([-*+]|\d+\.)[ \t]+/gm, "")
      .replace(/[*_`~]+/g, "")
      .replace(/\s+/g, " ")
      .trim();
  }

  function _formatDuration(startIso, endIso) {
    if (!startIso || !endIso) return "";
    const secs = Math.max(0, Math.round((new Date(endIso) - new Date(startIso)) / 1000));
    if (secs < 60) return `${secs}s`;
    const m = Math.floor(secs / 60), s = secs % 60;
    if (m < 60) return s ? `${m}m ${s}s` : `${m}m`;
    return `${Math.floor(m / 60)}h ${m % 60}m`;
  }

  function _dayLabel(iso) {
    const d = new Date(iso);
    const today = new Date(); today.setHours(0, 0, 0, 0);
    const day = new Date(d); day.setHours(0, 0, 0, 0);
    const diff = Math.round((today - day) / 86400000);
    if (diff === 0) return I18n.t("tasks.day.today");
    if (diff === 1) return I18n.t("tasks.day.yesterday");
    return `${d.getFullYear()}-${_pad(d.getMonth() + 1)}-${_pad(d.getDate())}`;
  }

  function _statusHtml(status) {
    const s = status || "running";
    return `<span class="task-run-status task-run-status-${escapeHtml(s)}">${escapeHtml(I18n.t("tasks.run.status." + s))}</span>`;
  }

  // Task prompts are agent-written, so raw HTML is shown as text and only safe links are kept.
  function _markdownHtml(text) {
    if (typeof marked === "undefined") return `<pre style="white-space:pre-wrap">${escapeHtml(text)}</pre>`;
    const renderer = new marked.Renderer();
    renderer.html = ({ text: raw }) => escapeHtml(raw);
    const baseLink = renderer.link.bind(renderer);
    renderer.link = function(token) {
      if (!/^(https?:|mailto:)/i.test(token.href || "")) return this.parser.parseInline(token.tokens);
      return baseLink(token).replace(/^<a /, '<a target="_blank" rel="noopener noreferrer" ');
    };
    try {
      return marked.parse(text, { breaks: true, gfm: true, renderer });
    } catch (_) {
      return `<pre style="white-space:pre-wrap">${escapeHtml(text)}</pre>`;
    }
  }

  // Full prompt lives in a modal: a grid cell is too narrow to read a long task body.
  function _openDetail(t) {
    const isPaused = t.scheduled && t.enabled === false;
    const sched = t.scheduled ? _humanCron(t.cron) : I18n.t("tasks.manual");
    const next  = isPaused ? I18n.t("tasks.section.paused")
                : t.scheduled ? _nextRunLabel(t.next_run)
                : "";
    const meta  = [sched, next].filter(Boolean).join(" · ");

    const overlay = document.createElement("div");
    overlay.className = "modal-overlay";
    overlay.innerHTML = `
      <div class="modal-box lg task-detail-modal" role="dialog" aria-modal="true" aria-labelledby="task-detail-title">
        <div class="modal-header">
          <h3 class="modal-title" id="task-detail-title">${escapeHtml(t.name)}</h3>
          <button type="button" class="modal-close-btn" aria-label="${escapeHtml(I18n.t("modal.close"))}"></button>
        </div>
        <div class="modal-body">
          ${meta ? `<p class="form-hint">${escapeHtml(meta)}</p>` : ""}
          <div class="extension-readme-body">${_markdownHtml(t.content)}</div>
        </div>
      </div>`;
    document.body.appendChild(overlay);

    const close = () => {
      document.removeEventListener("keydown", onKey);
      overlay.remove();
    };
    const onKey = e => { if (e.key === "Escape") close(); };
    document.addEventListener("keydown", onKey);
    overlay.addEventListener("click", e => { if (e.target === overlay) close(); });
    overlay.querySelector(".modal-close-btn").addEventListener("click", close);
  }

  function _renderTaskCard(t) {
    const isPaused = t.scheduled && t.enabled === false;
    const card = document.createElement("article");
    card.className = "task-card";
    card.dataset.name = t.name;
    card.classList.toggle("is-paused", isPaused);
    card.classList.toggle("is-manual", !t.scheduled);

    const content = _plainPreview(t.content);
    const sched   = t.scheduled ? _humanCron(t.cron) : I18n.t("tasks.manual");
    const next    = isPaused ? I18n.t("tasks.section.paused")
                  : t.scheduled ? _nextRunLabel(t.next_run)
                  : "";
    const nextAt  = t.next_run ? new Date(t.next_run) : null;
    const nextTip = nextAt && !isNaN(nextAt) ? nextAt.toLocaleString() : "";

    card.innerHTML = `
      <div class="task-card-head">
        <h3 class="task-card-title" title="${escapeHtml(t.name)}">${escapeHtml(t.name)}</h3>
        <div class="task-card-actions">
          <div class="task-card-tools">
            <button type="button" class="task-card-tool task-btn-run" data-tooltip="${escapeHtml(I18n.t("tasks.btn.run"))}" data-i18n-tooltip="tasks.btn.run" aria-label="${escapeHtml(I18n.t("tasks.btn.run"))}">${ICONS.play}</button>
            <button type="button" class="task-card-tool task-btn-edit" data-tooltip="${escapeHtml(I18n.t("tasks.btn.edit"))}" data-i18n-tooltip="tasks.btn.edit" aria-label="${escapeHtml(I18n.t("tasks.btn.edit"))}">${ICONS.edit}</button>
            <button type="button" class="task-card-tool ext-row-more task-btn-more" aria-haspopup="menu" aria-expanded="false" title="${escapeHtml(I18n.t("tasks.btn.more"))}" aria-label="${escapeHtml(I18n.t("tasks.btn.more"))}">${ICONS.more}</button>
          </div>
          ${t.scheduled ? `<label class="toggle-switch task-card-toggle" title="${escapeHtml(I18n.t(isPaused ? "tasks.btn.resume" : "tasks.btn.pause"))}">
            <input type="checkbox"${isPaused ? "" : " checked"} />
            <span class="toggle-slider"></span>
          </label>` : ""}
        </div>
      </div>
      <p class="task-card-desc">${escapeHtml(content) || escapeHtml(I18n.t("tasks.empty"))}</p>
      <div class="task-card-foot">
        <span class="task-card-sched">
          <svg class="task-card-clock" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 15.5 14"/></svg>
          <span class="task-card-sched-text" title="${escapeHtml(t.cron || sched)}">${escapeHtml(sched)}</span>
        </span>
        ${next ? `<span class="task-card-next"${nextTip ? ` title="${escapeHtml(nextTip)}"` : ""}>${escapeHtml(next)}</span>` : ""}
      </div>`;

    const toggle = card.querySelector(".task-card-toggle input");
    if (toggle) {
      toggle.addEventListener("change", e => {
        e.stopPropagation();
        Tasks.toggleEnabled(t.name, isPaused);
      });
      toggle.addEventListener("click", e => e.stopPropagation());
    }
    card.querySelector(".task-btn-run").addEventListener("click", e => {
      e.stopPropagation();
      Tasks.run(t.name);
    });
    card.querySelector(".task-btn-edit").addEventListener("click", e => {
      e.stopPropagation();
      Tasks.editInSession(t.name);
    });
    card.querySelector(".task-btn-more").addEventListener("click", e => {
      e.stopPropagation();
      _toggleMenu(e.currentTarget, t, isPaused);
    });

    if (t.content) {
      card.addEventListener("click", e => {
        if (e.target.closest("button, label, a")) return;
        _openDetail(t);
      });
    }
    return card;
  }

  function _menuItems(t, isPaused) {
    const items = [["edit", "tasks.btn.edit"]];
    if (t.scheduled) items.push(isPaused ? ["resume", "tasks.btn.resume"] : ["pause", "tasks.btn.pause"]);
    items.push(["history", "tasks.btn.history"]);
    items.push(["del", "tasks.btn.delete"]);
    return items;
  }

  function _ensureMenu() {
    if (_menuEl) return _menuEl;
    _menuEl = document.createElement("div");
    _menuEl.className = "ext-row-menu cron-row-menu";
    _menuEl.setAttribute("role", "menu");
    _menuEl.hidden = true;
    document.body.appendChild(_menuEl);
    document.addEventListener("click", e => {
      if (!_menuEl.hidden && !e.target.closest(".cron-row-menu") && !e.target.closest(".task-btn-more")) _closeMenu();
    });
    document.addEventListener("keydown", e => { if (e.key === "Escape") _closeMenu(); });
    window.addEventListener("resize", _closeMenu);
    window.addEventListener("scroll", _closeMenu, true);
    return _menuEl;
  }

  function _toggleMenu(btn, t, isPaused) {
    if (_menuBtn === btn && _menuEl && !_menuEl.hidden) { _closeMenu(); return; }
    _closeMenu();

    const el = _ensureMenu();
    el.innerHTML = _menuItems(t, isPaused).map(([kind, key]) => {
      const danger = kind === "del" ? " ext-row-menu-danger" : "";
      return `<button type="button" role="menuitem" class="ext-row-menu-item${danger}" data-kind="${kind}">${ICONS[kind]}<span>${escapeHtml(I18n.t(key))}</span></button>`;
    }).join("");
    el.onclick = e => {
      const item = e.target.closest("[data-kind]");
      if (!item) return;
      _closeMenu();
      const kind = item.dataset.kind;
      if (kind === "edit")                            Tasks.editInSession(t.name);
      else if (kind === "pause" || kind === "resume") Tasks.toggleEnabled(t.name, isPaused);
      else if (kind === "history")                    _showRuns(t.name);
      else if (kind === "del")                        Tasks.delete(t.name);
    };

    el.hidden = false;
    _menuBtn = btn;
    btn.setAttribute("aria-expanded", "true");
    const card = btn.closest(".task-card");
    if (card) card.classList.add("is-menu-open");

    const rect = btn.getBoundingClientRect();
    const w = el.offsetWidth, h = el.offsetHeight;
    let top = rect.bottom + 4;
    if (top + h > window.innerHeight - 8) top = rect.top - h - 4;
    el.style.left = Math.max(8, Math.min(rect.right - w, window.innerWidth - w - 8)) + "px";
    el.style.top  = Math.max(8, top) + "px";
  }

  function _closeMenu() {
    if (!_menuEl || _menuEl.hidden) return;
    _menuEl.hidden = true;
    if (_menuBtn) {
      _menuBtn.setAttribute("aria-expanded", "false");
      const card = _menuBtn.closest(".task-card");
      if (card) card.classList.remove("is-menu-open");
    }
    _menuBtn = null;
  }

  function _sectionHeader(text) {
    const h = document.createElement("div");
    h.className = "task-section-label";
    h.textContent = text;
    return h;
  }

  function _emptyState(text) {
    const el = document.createElement("div");
    el.className = "task-table-empty";
    el.innerHTML = `<p>${escapeHtml(text)}</p>`;
    return el;
  }

  function _renderFilterBar(matched) {
    const isPaused = t => t.scheduled && t.enabled === false;
    const counts = {
      all:    matched.length,
      active: matched.filter(t => !isPaused(t)).length,
      paused: matched.filter(isPaused).length,
    };
    const bar = document.createElement("div");
    bar.className = "segmented-control";
    bar.setAttribute("role", "tablist");
    bar.innerHTML = ["all", "active", "paused"].map(kind => `
      <button type="button" role="tab" class="segmented-control__btn${_filter === kind ? " active" : ""}"
              data-filter="${kind}" aria-selected="${_filter === kind}">
        ${escapeHtml(I18n.t("tasks.filter." + kind))}<span class="segmented-control__count">(${counts[kind]})</span>
      </button>`).join("");
    bar.querySelectorAll("[data-filter]").forEach(btn => {
      btn.addEventListener("click", () => {
        _filter = btn.dataset.filter;
        _renderTable();
      });
    });
    return bar;
  }

  function _renderTable() {
    const table = $("task-list-table");
    if (!table) return;
    table.innerHTML = "";

    const all = TasksStore.state.tasks;
    if (all.length === 0) {
      const empty = _emptyState(I18n.t("tasks.noScheduled"));
      empty.insertAdjacentHTML("beforeend", `
        <button class="task-create-btn" id="btn-create-task-empty">
          <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon-sm">
            <path d="M5 12h14"/>
            <path d="M12 5v14"/>
          </svg> ${escapeHtml(I18n.t("tasks.btn.createTask"))}
        </button>`);
      table.appendChild(empty);
      empty.querySelector("#btn-create-task-empty").addEventListener("click", () => Tasks.createInSession());
      return;
    }

    const matched = _query ? all.filter(t => _matches(t.name) || _matches(t.content)) : all;
    table.appendChild(_renderFilterBar(matched));

    if (matched.length === 0) {
      table.appendChild(_emptyState(I18n.t("tasks.search.empty")));
      return;
    }

    const isPaused = t => t.scheduled && t.enabled === false;
    const shown = _filter === "active" ? matched.filter(t => !isPaused(t))
                : _filter === "paused" ? matched.filter(isPaused)
                : matched;
    if (shown.length === 0) {
      table.appendChild(_emptyState(I18n.t(_filter === "active" ? "tasks.section.activeEmpty" : "tasks.section.pausedEmpty")));
      return;
    }

    const grid = document.createElement("div");
    grid.className = "task-card-grid";
    shown.forEach(t => grid.appendChild(_renderTaskCard(t)));
    table.appendChild(grid);
  }

  function _renderRunRow(r) {
    const row = document.createElement("div");
    row.className = "cron-row task-run-row";
    const duration = _formatDuration(r.started_at, r.finished_at);
    const trigger  = I18n.t(r.trigger === "manual" ? "tasks.run.trigger.manual" : "tasks.run.trigger.schedule");
    row.innerHTML = `
      <div class="cron-row-main">
        ${_statusHtml(r.status)}
        <span class="cron-row-name">${escapeHtml(r.task)}</span>
        <span class="task-run-trigger">${escapeHtml(trigger)}</span>
        ${r.error ? `<span class="task-run-error" title="${escapeHtml(r.error)}">${escapeHtml(r.error)}</span>` : ""}
        <span class="cron-row-spacer"></span>
        <div class="cron-row-end">
          <div class="cron-row-meta">
            <span class="task-run-time">${escapeHtml(_formatTime(r.started_at))}</span>
            <span class="task-run-duration">${escapeHtml(duration)}</span>
          </div>
          <div class="cron-row-actions">
            <button type="button" class="cron-row-btn task-run-btn-del" title="${escapeHtml(I18n.t("tasks.btn.delete"))}" aria-label="${escapeHtml(I18n.t("tasks.btn.delete"))}">${ICONS.del}</button>
          </div>
        </div>
      </div>`;
    row.querySelector(".task-run-btn-del").addEventListener("click", (e) => {
      e.stopPropagation();
      TasksStore.deleteRun(r.id);
    });
    if (r.session_id) {
      row.classList.add("task-run-row-link");
      row.title = I18n.t("tasks.run.open");
      row.addEventListener("click", () => Router.navigate("session", { id: r.session_id }));
    }
    return row;
  }

  function _renderRuns() {
    const table = $("task-runs-table");
    if (!table) return;
    table.innerHTML = "";

    if (_runsTask) {
      const chip = document.createElement("div");
      chip.className = "task-runs-filter";
      chip.innerHTML = `<span>${escapeHtml(I18n.t("tasks.run.filtered", { name: _runsTask }))}</span><button type="button" class="task-runs-filter-clear">${escapeHtml(I18n.t("tasks.run.showAll"))}</button>`;
      chip.querySelector("button").addEventListener("click", () => { _runsTask = null; _renderRuns(); });
      table.appendChild(chip);
    }

    let runs = TasksStore.state.runs;
    if (_runsTask) runs = runs.filter(r => r.task === _runsTask);
    if (_query)    runs = runs.filter(r => _matches(r.task) || _matches(r.error));

    if (runs.length === 0) {
      const none = TasksStore.state.runs.length === 0 ? "tasks.run.none" : "tasks.search.empty";
      table.appendChild(_emptyState(I18n.t(none)));
      return;
    }

    let lastDay = null;
    runs.forEach(r => {
      const day = _dayLabel(r.started_at);
      if (day !== lastDay) {
        table.appendChild(_sectionHeader(day));
        lastDay = day;
      }
      table.appendChild(_renderRunRow(r));
    });
  }

  function _setTab(tab) {
    _tab = tab;
    document.querySelectorAll("#tasks-tabs .tasks-tab").forEach(b => {
      b.classList.toggle("active", b.dataset.tab === tab);
    });
    const list = $("task-list-table"), runs = $("task-runs-table");
    if (list) list.style.display = tab === "tasks" ? "" : "none";
    if (runs) runs.style.display = tab === "runs" ? "" : "none";
    if (tab === "runs") {
      _renderRuns();
      Tasks.loadRuns();
    } else {
      _renderTable();
    }
  }

  function _showRuns(taskName) {
    _runsTask = taskName;
    _setTab("runs");
  }

  function _wireControls() {
    document.querySelectorAll("#tasks-tabs .tasks-tab").forEach(b => {
      b.onclick = () => _setTab(b.dataset.tab);
    });
    const input = $("tasks-search-input");
    if (input) {
      input.oninput = () => {
        _query = input.value.trim().toLowerCase();
        if (_tab === "runs") _renderRuns();
        else _renderTable();
      };
    }
  }

  function _renderSection() {
    const labelEl = $("tasks-sidebar-label");
    if (!labelEl) return;
    labelEl.textContent = I18n.t("sidebar.tasks");
  }

  function _subscribe() {
    Tasks.on("tasks:changed", () => {
      _renderSection();
      if (Router.current !== "tasks") return;
      _renderTable();
      if (_tab === "runs") Tasks.loadRuns();
    });
    Tasks.on("tasks:runs-changed", () => {
      if (Router.current === "tasks" && _tab === "runs") _renderRuns();
    });
  }

  const viewApi = {
    renderSection: _renderSection,
    renderTable: _renderTable,

    onPanelShow() {
      Tasks.load();
      _wireControls();
      _setTab(_tab);
      const btn = $("btn-create-task");
      if (btn) btn.onclick = () => Tasks.createInSession();
    },
  };

  return { init: _subscribe, api: viewApi };
})();

Object.assign(Tasks, TasksView.api);
TasksView.init();
