(function () {
  // Extension-owned dictionary, following the advisor panel convention.
  const DICT = {
  "en": {
    "created": "Created: ",
    "paused": "Paused",
    "queued": "Waiting to start",
    "running": "Your secretary is working on this",
    "waiting_event": "Waiting for an event or checkpoint",
    "needs_input": "Needs input from your secretary",
    "completed": "Completed",
    "failed": "Something needs attention; review with your secretary",
    "cancelled": "Cancelled",
    "error": "Progress is temporarily unavailable",
    "draft": "About “{title}”, I would like to add:",
    "activeCount": "Working in background: {count}",
    "waitingCount": "Waiting for events: {count}",
    "needsCount": "Needs input: {count}",
    "pausedCount": "Paused: {count}",
    "done": "Work is up to date",
    "empty": "Nothing to follow up on yet. Tell your secretary what you need.",
    "needsSection": "Your decisions",
    "failedSection": "Needs attention",
    "runningSection": "In progress",
    "waitingSection": "Waiting",
    "pausedSection": "Paused",
    "completedSection": "Recently completed",
    "cancelledSection": "Cancelled",
    "moreCompleted": "Earlier completed work ({count})",
    "requirements": "Details",
    "constraints": "Constraints: ",
    "check": "Check again: ",
    "confirm": "Reply",
    "review": "Discuss",
    "discuss": "Discuss with secretary",
    "history": "Execution history",
    "technical": "Execution details",
    "plans": "Recurring plans",
    "nextRun": "Next run: ",
    "scheduled": "Scheduled",
    "daily": "Daily at {time}",
    "weekdays": "Weekdays at {time}",
    "planDraft": "I would like to change the plan “{title}”: ",
    "badge_needs_input": "Needs reply",
    "badge_failed": "Needs attention",
    "badge_running": "In progress",
    "badge_queued": "Queued",
    "badge_waiting_event": "Waiting",
    "badge_completed": "Completed",
    "badge_paused": "Paused",
    "badge_cancelled": "Cancelled",
    "title": "Work"
  },
  "zh": {
    "created": "创建于：",
    "paused": "已暂停",
    "queued": "等待开始处理",
    "running": "秘书正在处理",
    "waiting_event": "等待外部事件或定时检查",
    "needs_input": "等待秘书协助",
    "completed": "已完成",
    "failed": "遇到问题，需要和秘书一起处理",
    "cancelled": "已取消",
    "error": "暂时无法读取工作进展",
    "draft": "关于「{title}」，我想补充：",
    "activeCount": "后台处理中 · {count} 件事",
    "waitingCount": "{count} 件等待事件或定时检查",
    "needsCount": "{count} 件需要协助",
    "pausedCount": "有 {count} 件事项已暂停",
    "done": "工作已告一段落",
    "empty": "暂时没有需要跟进的事，可以直接告诉秘书你的安排。",
    "needsSection": "需要你决定",
    "failedSection": "需要处理",
    "runningSection": "正在推进",
    "waitingSection": "等待中",
    "pausedSection": "已暂停",
    "completedSection": "最近完成",
    "cancelledSection": "已取消",
    "moreCompleted": "更早完成的事项（{count}）",
    "requirements": "事项详情",
    "constraints": "约束：",
    "check": "再次检查：",
    "confirm": "去回复",
    "review": "去讨论",
    "discuss": "与秘书讨论",
    "history": "执行记录",
    "technical": "执行详情",
    "plans": "定时安排",
    "nextRun": "下次执行：",
    "scheduled": "已安排",
    "daily": "每天 {time}",
    "weekdays": "工作日 {time}",
    "planDraft": "我想调整「{title}」这个定时安排：",
    "badge_needs_input": "待协助",
    "badge_failed": "需处理",
    "badge_running": "处理中",
    "badge_queued": "排队中",
    "badge_waiting_event": "等待中",
    "badge_completed": "已完成",
    "badge_paused": "已暂停",
    "badge_cancelled": "已取消",
    "title": "工作事项"
  }
};
  const locale = () => typeof I18n !== "undefined" && I18n.lang ? I18n.lang() : "en";
  const t = (key, vars = {}) => {
    const text = (DICT[locale()] || DICT.en)[key] || DICT.en[key] || key;
    return text.replace(/\{(\w+)\}/g, (_, name) => vars[name] ?? "");
  };
  const attention = card => ['needs_input', 'failed'].includes(card.status);
  // tone picks the colour tokens in styles(); loud marks the states that ask the user to act.
  const ring = extra => ['circle', Object.assign({ cx: 7, cy: 7, r: 6, fill: 'none', stroke: 'currentColor', 'stroke-width': 1.5 }, extra)];
  const line = (d, width, extra) => ['path', Object.assign({ d, fill: 'none', stroke: 'currentColor', 'stroke-width': width || 1.5, 'stroke-linecap': 'round' }, extra)];
  const STATUS_BADGE = {
    needs_input: { tone: 'warn', loud: true, icon: [ring(), line('M7 3.8v3.9'), ['circle', { cx: 7, cy: 10, r: 0.9, fill: 'currentColor' }]] },
    failed: { tone: 'err', loud: true, icon: [ring(), line('M4.8 4.8l4.4 4.4M9.2 4.8l-4.4 4.4')] },
    running: { tone: 'live', icon: [ring({ 'stroke-opacity': 0.3 }), line('M7 1a6 6 0 0 1 6 6', 1.5, { class: 'secretary-work-spin' })] },
    queued: { tone: 'mute', icon: [ring({ 'stroke-dasharray': '2.5 2' })] },
    waiting_event: { tone: 'info', icon: [ring(), line('M7 4v3.2l2 1.2', 1.4)] },
    completed: { tone: 'ok', icon: [['circle', { cx: 7, cy: 7, r: 6.5, fill: 'currentColor' }], line('M4.4 7.2l1.9 1.9 3.4-3.6', 1.5, { stroke: 'var(--color-bg-secondary)', 'stroke-linejoin': 'round' })] },
    paused: { tone: 'mute', icon: [ring(), line('M5.4 4.8v4.4M8.6 4.8v4.4')] },
    cancelled: { tone: 'mute', icon: [ring(), line('M4.5 7h5')] }
  };
  const CHEVRON = [line('M2.5 3.8L5 6.3l2.5-2.5', 1.4, { 'stroke-linejoin': 'round' })];
  const svg = (size, viewBox, shapes, cls) => {
    const NS = 'http://www.w3.org/2000/svg';
    const node = document.createElementNS(NS, 'svg');
    node.setAttribute('viewBox', viewBox);
    node.setAttribute('width', size);
    node.setAttribute('height', size);
    node.setAttribute('aria-hidden', 'true');
    if (cls) node.setAttribute('class', cls);
    shapes.forEach(([tag, attrs]) => {
      const child = document.createElementNS(NS, tag);
      Object.keys(attrs).forEach(key => child.setAttribute(key, attrs[key]));
      node.append(child);
    });
    return node;
  };
  const el = (tag, text, cls) => {
    const node = document.createElement(tag);
    if (text) node.textContent = text;
    if (cls) node.className = cls;
    return node;
  };

  // Per-session data source shared by the aside and composer slots. Events only
  // invalidate it; mount/reconnect fetch the persisted authoritative snapshot.
  const stores = new Map();
  function acquire(sessionId) {
    let store = stores.get(sessionId);
    if (!store) {
      store = { cards: [], schedules: [], error: '', listeners: new Set(), refs: 0, loading: false, dirty: false, disposed: false };
      store.refresh = async () => {
        if (store.disposed) return;
        if (store.loading) { store.dirty = true; return; }
        store.loading = true;
        try {
          const response = await fetch('/api/ext/secretary/work?session_id=' + encodeURIComponent(sessionId));
          const data = await response.json();
          if (!response.ok) throw new Error('Unable to load work');
          if (store.disposed) return;
          store.cards = data.work || [];
          store.schedules = data.schedules || [];
          store.error = '';
        } catch (error) {
          if (!store.disposed) store.error = true;
        } finally {
          store.loading = false;
          if (!store.disposed) store.listeners.forEach(listener => listener());
          if (store.dirty && !store.disposed) { store.dirty = false; store.refresh(); }
        }
      };
      stores.set(sessionId, store);
      store.refresh();
    }
    store.refs++;
    return store;
  }
  function release(sessionId, store, render) {
    store.listeners.delete(render);
    if (--store.refs === 0) { store.disposed = true; stores.delete(sessionId); }
  }
  function refreshSession(event) {
    stores.get(event.sessionId || event.session_id)?.refresh();
  }
  Clacky.ext.subscribe('ext.work.changed', refreshSession);
  Clacky.ext.subscribe('session:subscribed', refreshSession);

  // Existing Composer API supplies a normal conversation draft and reference.
  // Never mutate work or send a message from the panel, and preserve user drafts.
  function discuss(card, ownerId) {
    if (Clacky.ext.context.sessionId !== ownerId) return;
    const input = document.getElementById('user-input');
    const composer = Clacky.Composer;
    if (!input || !composer) return;
    if (!composer.hasContent(input)) composer.setText(input, t('draft', { title: card.title }));
    if (!composer.chips(input).some(chip => chip.type === 'session' && chip.session_id === card.session_id)) {
      composer.insertChip(input, { type: 'session', name: card.title, sessionId: card.session_id });
    }
    composer.focusEnd(input);
  }
  // Prefer the worker's user-facing sentence. Legacy short questions remain
  // readable; long reports stay in the worker conversation instead of being cut off.
  function brief(card) {
    const concise = String(card.display_summary || '').trim();
    if (concise && concise.length <= 100) return concise;
    const text = String(card.progress || '').trim();
    if (text && text.length <= 100 && !/[\n\r`#]|https?:\/\//.test(text)) return text;
    return '';
  }
  function dateText(value) {
    if (!value) return '';
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? '' : date.toLocaleString(locale());
  }
  function shortDate(value) {
    if (!value) return '';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return '';
    const pad = number => String(number).padStart(2, '0');
    return pad(date.getMonth() + 1) + '-' + pad(date.getDate()) + ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes());
  }
  function cadence(plan) {
    const fields = String(plan.cron || '').trim().split(/\s+/);
    if (fields.length === 5 && /^\d+$/.test(fields[0]) && /^\d+$/.test(fields[1]) &&
        Number(fields[0]) < 60 && Number(fields[1]) < 24 && fields[2] === '*' && fields[3] === '*') {
      const time = fields[1].padStart(2, '0') + ':' + fields[0].padStart(2, '0');
      if (fields[4] === '*') return t('daily', { time });
      if (fields[4] === '1-5') return t('weekdays', { time });
    }
    const next = dateText(plan.next_run);
    return next ? t('nextRun') + next : t('scheduled');
  }
  function styles() {
    return el('style', `
      .secretary-work { color:var(--color-text-primary); font-size:13px; line-height:1.55; }
      .secretary-work-aside { padding:18px 16px; overflow:auto; height:100%; box-sizing:border-box; }
      .secretary-work-muted { color:var(--color-text-secondary); font-size:12px; }
      .secretary-work-group { margin-bottom:24px; }
      .secretary-work-heading { margin:0 0 8px; font-size:12px; font-weight:600; color:var(--color-text-secondary); }
      .secretary-work-card { padding:12px 14px; margin-bottom:8px; background:var(--color-bg-card); border:1px solid var(--color-border-primary); border-radius:10px; transition:border-color var(--transition-fast, 120ms ease); }
      .secretary-work-card:hover { border-color:var(--color-border-strong); }
      .secretary-work summary { cursor:pointer; }
      .secretary-work summary:focus-visible, .secretary-work button:focus-visible { outline:2px solid var(--color-text-secondary); outline-offset:3px; }
      .secretary-work-main > summary { list-style:none; position:relative; padding-right:18px; }
      .secretary-work-main > summary::-webkit-details-marker { display:none; }
      .secretary-work-main > summary::after { content:'›'; position:absolute; right:0; top:0; color:var(--color-text-tertiary); }
      .secretary-work-main[open] > summary::after { transform:rotate(90deg); }
      .secretary-work-head { display:flex; align-items:flex-start; gap:8px; }
      .secretary-work-icon { flex:none; margin-top:3px; color:var(--tone); }
      .secretary-work-title { display:block; flex:1; min-width:0; font-weight:500; overflow-wrap:anywhere; }
      .secretary-work-label { flex:none; font-size:11px; line-height:18px; color:var(--tone-fg); white-space:nowrap; }
      .secretary-work-label.is-loud { padding:0 7px; border-radius:var(--radius-pill, 999px); background:var(--tone-bg); border:1px solid var(--tone-bd); }
      .tone-warn { --tone:var(--color-warning); --tone-fg:var(--color-warning-text); --tone-bg:var(--color-warning-bg); --tone-bd:var(--color-warning-border); }
      .tone-err { --tone:var(--color-error); --tone-fg:var(--color-error); --tone-bg:var(--color-error-bg); --tone-bd:var(--color-error-border); }
      .tone-ok { --tone:var(--color-success); --tone-fg:var(--color-success); }
      .tone-live { --tone:var(--live); --tone-fg:var(--live); }
      .tone-info { --tone:var(--color-info); --tone-fg:var(--color-info); }
      .tone-mute { --tone:var(--color-text-tertiary); --tone-fg:var(--color-text-tertiary); }
      .is-cancelled .secretary-work-title { color:var(--color-text-tertiary); text-decoration:line-through; text-decoration-color:var(--color-border-strong); }
      .is-cancelled .secretary-work-brief { color:var(--color-text-tertiary); }
      .secretary-work-spin { animation:secretary-work-spin 1.2s linear infinite; transform-origin:50% 50%; }
      @keyframes secretary-work-spin { to { transform:rotate(360deg); } }
      .secretary-work-brief { display:block; margin:3px 0 0 22px; font-size:12px; color:var(--color-text-secondary); overflow-wrap:anywhere; }
      .secretary-work-check { display:block; margin:3px 0 0 22px; }
      .secretary-work-content { white-space:pre-wrap; overflow-wrap:anywhere; margin:10px 0; }
      .secretary-work-footer { display:flex; flex-wrap:wrap; align-items:center; justify-content:space-between; gap:6px 12px; margin:10px 0 0; color:var(--color-text-tertiary); }
      .secretary-work-actions { display:flex; align-items:center; gap:10px; margin-left:auto; white-space:nowrap; }
      .secretary-work-footer a { color:var(--color-text-secondary); text-decoration:none; }
      .secretary-work-footer a:hover { text-decoration:underline; }
      .secretary-work-details { margin:8px 0 0 22px; color:var(--color-text-secondary); font-size:12px; }
      .secretary-work-details > summary { list-style:none; display:inline-flex; align-items:center; gap:4px; color:var(--color-text-tertiary); border-radius:var(--radius-xs, 4px); }
      .secretary-work-details > summary::-webkit-details-marker { display:none; }
      .secretary-work-details > summary:hover { color:var(--color-text-secondary); }
      .secretary-work-chevron { transition:transform var(--transition-fast, 120ms ease); }
      .secretary-work-details[open] .secretary-work-chevron { transform:rotate(180deg); }
      .secretary-work button { cursor:pointer; border:1px solid var(--color-border-primary); border-radius:var(--radius-sm, 6px); background:transparent; color:var(--color-text-primary); padding:3px 10px; font:inherit; }
      .secretary-work button:hover { background:var(--color-bg-hover); border-color:var(--color-border-strong); }
      .secretary-work-nested { margin-top:10px; font-size:12px; }
      .secretary-work-status { display:flex; flex-wrap:wrap; gap:8px; align-items:center; padding:6px 0; }
      .secretary-work-status-title { color:var(--color-text-secondary); }
      .secretary-work-error { color:var(--color-error); margin-bottom:12px; }
    `);
  }
  function mountRuntime(ctx, compact) {
    const store = acquire(ctx.sessionId);
    const expanded = new Set();
    const root = el('div', null, 'secretary-work' + (compact ? '' : ' secretary-work-aside'));
    const body = el('div');
    root.append(styles(), body);
    function disclosure(key, summary, cls) {
      const details = el('details', null, cls);
      details.open = expanded.has(key);
      details.ontoggle = () => { if (details.open) expanded.add(key); else expanded.delete(key); };
      details.append(summary);
      return details;
    }
    function button(label, action) {
      const node = el('button', label);
      node.type = 'button';
      node.onclick = action;
      return node;
    }
    function workRow(card) {
      const row = el('article', null, 'secretary-work-card is-' + card.status);
      const badge = STATUS_BADGE[card.status] || STATUS_BADGE.queued;
      const head = el('div', null, 'secretary-work-head tone-' + badge.tone);
      head.append(svg(14, '0 0 14 14', badge.icon, 'secretary-work-icon'), el('strong', card.title, 'secretary-work-title'),
        el('span', t('badge_' + card.status), 'secretary-work-label' + (badge.loud ? ' is-loud' : '')));
      row.append(head);
      const summary = brief(card);
      if (summary) row.append(el('div', summary, 'secretary-work-brief'));
      const check = dateText(card.waiting?.check_at);
      if (card.status === 'waiting_event' && check) row.append(el('small', t('check') + check, 'secretary-work-muted secretary-work-check'));
      const footer = el('div', null, 'secretary-work-footer secretary-work-muted');
      const created = shortDate(card.created_at);
      if (created) {
        const time = el('time', created);
        time.dateTime = card.created_at;
        time.title = t('created') + dateText(card.created_at);
        footer.append(time);
      }
      const link = el('a', t('history'));
      link.href = '#session/' + encodeURIComponent(card.session_id);
      const actions = el('div', null, 'secretary-work-actions');
      actions.append(link, button(t('discuss'), () => discuss(card, ctx.sessionId)));
      footer.append(actions);
      if (card.instruction || card.constraints || card.updates?.length) {
        const toggle = el('summary', t('requirements'));
        toggle.append(svg(10, '0 0 10 10', CHEVRON, 'secretary-work-chevron'));
        const details = disclosure('work:' + card.id, toggle, 'secretary-work-details');
        if (card.instruction) details.append(el('div', card.instruction, 'secretary-work-content'));
        if (card.constraints) details.append(el('div', t('constraints') + card.constraints, 'secretary-work-content'));
        (card.updates || []).forEach(update => details.append(el('div', update.text, 'secretary-work-content')));
        row.append(details);
      }
      row.append(footer);
      return row;
    }
    function render() {
      body.replaceChildren();
      const cards = store.cards;
      const active = cards.filter(card => !['completed', 'cancelled'].includes(card.status));
      const needs = cards.filter(attention);
      const running = cards.filter(card => ['queued', 'running'].includes(card.status));
      const waiting = cards.filter(card => card.status === 'waiting_event');
      const paused = cards.filter(card => card.status === 'paused');
      if (ctx.setBadge) ctx.setBadge(needs.length || null);
      if (store.error) body.append(el('div', t('error'), 'secretary-work-error'));
      if (compact) {
        root.hidden = !cards.length && !store.error;
        if (!cards.length) return;
        const running = cards.filter(card => ['queued', 'running'].includes(card.status));
        const waiting = cards.filter(card => card.status === 'waiting_event');
        const parts = [];
        if (running.length) parts.push(t('activeCount', { count: running.length }));
        if (waiting.length) parts.push(t('waitingCount', { count: waiting.length }));
        if (needs.length) parts.push(t('needsCount', { count: needs.length }));
        if (!parts.length) parts.push(active.length ? t('pausedCount', { count: active.length }) : t('done'));
        const row = el('div', null, 'secretary-work-status');
        row.append(el('span', parts.join(' · '), 'secretary-work-status-title'));
        const focus = needs.length ? needs : active;
        focus.slice(0, 3).forEach(card => {
          const button = el('button', card.title);
          button.type = 'button';
          button.onclick = () => discuss(card, ctx.sessionId);
          row.append(button);
        });
        body.append(row);
        return;
      }
      // A stable chronological list: status changes never move a work item.
      [...cards].sort((a, b) => (Date.parse(b.created_at) || 0) - (Date.parse(a.created_at) || 0))
        .forEach(card => body.append(workRow(card)));
      if (store.schedules.length) {
        const plans = el('section', null, 'secretary-work-group');
        plans.append(el('h3', t('plans'), 'secretary-work-heading'));
        store.schedules.forEach(plan => {
          const title = plan.target?.title || plan.name;
          const summary = el('summary');
          summary.append(el('strong', title, 'secretary-work-title'), el('span',
            cadence(plan) + (plan.enabled === false ? ' · ' + t('paused') : ''), 'secretary-work-brief'));
          const details = disclosure('plan:' + plan.name, summary, 'secretary-work-main');
          const next = dateText(plan.next_run);
          if (plan.enabled !== false && next) details.append(el('p', t('nextRun') + next, 'secretary-work-muted'));
          if (plan.content) details.append(el('div', plan.content, 'secretary-work-content'));
          details.append(button(t('discuss'), () => {
            if (Clacky.ext.context.sessionId !== ctx.sessionId) return;
            const input = document.getElementById('user-input');
            if (!input || !Clacky.Composer) return;
            if (!Clacky.Composer.hasContent(input)) Clacky.Composer.setText(input, t('planDraft', { title }));
            Clacky.Composer.focusEnd(input);
          }));
          const row = el('article', null, 'secretary-work-card');
          row.append(details);
          plans.append(row);
        });
        body.append(plans);
      }
      if (!cards.length && !store.schedules.length && !store.error) body.append(el('p', t('empty'), 'secretary-work-muted'));
    }
    store.listeners.add(render);
    render();
    return { root, dispose() { release(ctx.sessionId, store, render); } };
  }
  document.addEventListener('langchange', () => {
    stores.forEach(store => store.listeners.forEach(render => render()));
    if (typeof Clacky.ext.refreshSlots === 'function') Clacky.ext.refreshSlots();
  });
  Clacky.ext.ui.mount('session.aside', {
    create(ctx) { return mountRuntime(ctx, false); },
    render(container, ctx, runtime) { container.appendChild(runtime.root); }
  }, { order: 20, tab: { id: 'secretary-work', label: () => t('title') } });
  Clacky.ext.ui.mount('session.composer', {
    create(ctx) { return mountRuntime(ctx, true); },
    render(container, ctx, runtime) { container.appendChild(runtime.root); }
  }, { order: 100 });
})();
