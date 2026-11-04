(function () {
  // Extension-owned dictionary, following the advisor panel convention.
  const DICT = {
  "en": {
    "created": "Created: ",
    "paused": "Paused",
    "queued": "Waiting to start",
    "running": "Your secretary is working on this",
    "waiting_reply": "Waiting for a reply",
    "waiting_user": "Your decision is needed",
    "completed": "Completed",
    "failed": "Something needs attention; review with your secretary",
    "cancelled": "Cancelled",
    "error": "Progress is temporarily unavailable",
    "draft": "About “{title}”, I would like to add:",
    "activeCount": "In progress: {count}",
    "waitingCount": "Awaiting replies: {count}",
    "needsCount": "Needs your attention: {count}",
    "pausedCount": "Paused: {count}",
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
    "history": "Open execution history",
    "technical": "Execution details",
    "plans": "Recurring plans",
    "nextRun": "Next run: ",
    "scheduled": "Scheduled",
    "daily": "Daily at {time}",
    "weekdays": "Weekdays at {time}",
    "planDraft": "I would like to change the plan “{title}”: ",
    "title": "Work"
  },
  "zh": {
    "created": "创建于：",
    "paused": "已暂停",
    "queued": "等待开始处理",
    "running": "秘书正在处理",
    "waiting_reply": "等待对方回复",
    "waiting_user": "需要你的决定",
    "completed": "已完成",
    "failed": "遇到问题，需要和秘书一起处理",
    "cancelled": "已取消",
    "error": "暂时无法读取工作进展",
    "draft": "关于「{title}」，我想补充：",
    "activeCount": "正在推进 {count} 件事",
    "waitingCount": "等待 {count} 个回复",
    "needsCount": "{count} 件需要你关注",
    "pausedCount": "{count} 件已暂停",
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
    "history": "查看执行记录",
    "technical": "执行详情",
    "plans": "定时安排",
    "nextRun": "下次执行：",
    "scheduled": "已安排",
    "daily": "每天 {time}",
    "weekdays": "工作日 {time}",
    "planDraft": "我想调整「{title}」这个定时安排：",
    "title": "工作事项"
  }
};
  const locale = () => typeof I18n !== "undefined" && I18n.lang ? I18n.lang() : "en";
  const t = (key, vars = {}) => {
    const text = (DICT[locale()] || DICT.en)[key] || DICT.en[key] || key;
    return text.replace(/\{(\w+)\}/g, (_, name) => vars[name] ?? "");
  };
  const attention = card => ['waiting_user', 'failed'].includes(card.status);
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
    if (['waiting_user', 'waiting_reply'].includes(card.status) && text.length <= 100 &&
        !/[\n\r`#]|https?:\/\//.test(text) && text) return text;
    return t(card.status);
  }
  function dateText(value) {
    if (!value) return '';
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? '' : date.toLocaleString(locale());
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
      .secretary-work-card { padding:10px 0; border-bottom:1px solid var(--color-border-primary); }
      .secretary-work-card:last-child { border-bottom:0; }
      .secretary-work summary { cursor:pointer; }
      .secretary-work summary:focus-visible, .secretary-work button:focus-visible { outline:2px solid var(--color-text-secondary); outline-offset:3px; }
      .secretary-work-main > summary { list-style:none; position:relative; padding-right:18px; }
      .secretary-work-main > summary::-webkit-details-marker { display:none; }
      .secretary-work-main > summary::after { content:'›'; position:absolute; right:0; top:0; color:var(--color-text-tertiary); }
      .secretary-work-main[open] > summary::after { transform:rotate(90deg); }
      .secretary-work-title { display:block; font-weight:500; overflow-wrap:anywhere; }
      .secretary-work-brief { display:block; margin-top:3px; color:var(--color-text-secondary); overflow-wrap:anywhere; }
      .secretary-work-content { white-space:pre-wrap; overflow-wrap:anywhere; margin:10px 0; }
      .secretary-work-meta { display:flex; flex-wrap:wrap; gap:2px 10px; margin-top:3px; }
      .secretary-work-actions { margin-top:10px; display:flex; align-items:center; gap:14px; }
      .secretary-work-actions a { font-size:12px; color:var(--color-text-secondary); text-decoration:none; }
      .secretary-work-actions a:hover { text-decoration:underline; }
      .secretary-work-details { margin-top:10px; color:var(--color-text-secondary); font-size:12px; }
      .secretary-work-details > summary { list-style:none; }
      .secretary-work-details > summary::-webkit-details-marker { display:none; }
      .secretary-work-details > summary::after { content:" +"; }
      .secretary-work-details[open] > summary::after { content:" −"; }
      .secretary-work button { cursor:pointer; border:1px solid var(--color-border-primary); border-radius:var(--radius-sm, 6px); background:var(--color-bg-secondary); color:inherit; padding:4px 10px; font:inherit; }
      .secretary-work-nested { margin-top:10px; font-size:12px; }
      .secretary-work-status { color:var(--color-text-secondary); font-size:12px; padding:5px 0; }
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
      const row = el('article', null, 'secretary-work-card');
      row.append(el('strong', card.title, 'secretary-work-title'));
      const meta = el('div', null, 'secretary-work-meta secretary-work-muted');
      meta.append(el('span', brief(card)));
      const created = dateText(card.created_at);
      if (created) {
        const time = el('time', t('created') + created);
        time.dateTime = card.created_at;
        meta.append(time);
      }
      row.append(meta);
      const check = dateText(card.waiting?.check_at);
      if (card.status === 'waiting_reply' && check) row.append(el('small', t('check') + check, 'secretary-work-muted'));
      const actions = el('div', null, 'secretary-work-actions');
      actions.append(button(t('discuss'), () => discuss(card, ctx.sessionId)));
      const link = el('a', t('history'));
      link.href = '#session/' + encodeURIComponent(card.session_id);
      actions.append(link);
      row.append(actions);
      if (card.instruction || card.constraints || card.updates?.length) {
        const details = disclosure('work:' + card.id, el('summary', t('requirements')), 'secretary-work-details');
        if (card.instruction) details.append(el('div', card.instruction, 'secretary-work-content'));
        if (card.constraints) details.append(el('div', t('constraints') + card.constraints, 'secretary-work-content'));
        (card.updates || []).forEach(update => details.append(el('div', update.text, 'secretary-work-content')));
        row.append(details);
      }
      return row;
    }
    function render() {
      body.replaceChildren();
      const cards = store.cards;
      const needs = cards.filter(attention);
      const running = cards.filter(card => ['queued', 'running'].includes(card.status));
      const waiting = cards.filter(card => card.status === 'waiting_reply');
      const paused = cards.filter(card => card.status === 'paused');
      if (ctx.setBadge) ctx.setBadge(needs.length || null);
      if (store.error) body.append(el('div', t('error'), 'secretary-work-error'));
      if (compact) {
        const parts = [];
        if (needs.length) parts.push(t('needsCount', { count: needs.length }));
        if (running.length) parts.push(t('activeCount', { count: running.length }));
        if (waiting.length) parts.push(t('waitingCount', { count: waiting.length }));
        if (!parts.length && paused.length) parts.push(t('pausedCount', { count: paused.length }));
        root.hidden = !parts.length && !store.error;
        if (parts.length) body.append(el('div', parts.join(' · '), 'secretary-work-status'));
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
