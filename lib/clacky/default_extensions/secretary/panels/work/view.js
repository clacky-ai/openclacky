(function () {
  // Extension-owned dictionary, following the advisor panel convention.
  const DICT = {
  "en": {
    "paused": "Paused",
    "queued": "Queued",
    "running": "In progress",
    "waiting_reply": "Waiting for reply",
    "waiting_user": "Your decision needed",
    "completed": "Completed",
    "failed": "Needs attention",
    "cancelled": "Cancelled",
    "error": "Unable to load work progress",
    "draft": "About “{title}”, I would like to add:",
    "activeCount": "In progress: {count}",
    "waitingCount": "Awaiting replies: {count}",
    "needsCount": "Decisions needed: {count}",
    "pausedCount": "Paused: {count}",
    "done": "Work is up to date",
    "help": "Work progress appears here. Tell your secretary about updates, replies, pauses or cancellations.",
    "empty": "No work yet. Ask your secretary to delegate a task.",
    "details": "Requirements and updates",
    "constraints": "Constraints: ",
    "none": "None provided",
    "check": "Next check: ",
    "confirm": "Confirm with secretary",
    "discuss": "Discuss with secretary",
    "history": "View execution history",
    "title": "Work"
  },
  "zh": {
    "paused": "已暂停",
    "queued": "待执行",
    "running": "执行中",
    "waiting_reply": "等待回复",
    "waiting_user": "等你决定",
    "completed": "已完成",
    "failed": "需要处理",
    "cancelled": "已取消",
    "error": "暂时无法读取工作进展",
    "draft": "关于「{title}」，我想补充：",
    "activeCount": "正在推进 {count} 件事",
    "waitingCount": "等待 {count} 个回复",
    "needsCount": "{count} 件需要你确认",
    "pausedCount": "有 {count} 件事项已暂停",
    "done": "工作已告一段落",
    "help": "这里展示工作进展。补充要求、转交回复、暂停或取消，都可以直接告诉秘书。",
    "empty": "暂无工作，可以让秘书先委派一件事。",
    "details": "任务要求与修改记录",
    "constraints": "约束：",
    "none": "未补充",
    "check": "下次检查：",
    "confirm": "和秘书确认",
    "discuss": "与秘书讨论",
    "history": "查看执行记录",
    "title": "工作事项"
  }
};
  const locale = () => typeof I18n !== "undefined" && I18n.lang ? I18n.lang() : "en";
  const t = (key, vars = {}) => {
    const text = (DICT[locale()] || DICT.en)[key] || DICT.en[key] || key;
    return text.replace(/\{(\w+)\}/g, (_, name) => vars[name] ?? "");
  };
  const terminal = card => ['completed', 'cancelled'].includes(card.status);
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
      store = { cards: [], error: '', listeners: new Set(), refs: 0, loading: false, dirty: false, disposed: false };
      store.refresh = async () => {
        if (store.disposed) return;
        if (store.loading) { store.dirty = true; return; }
        store.loading = true;
        try {
          const response = await fetch('/api/ext/secretary/work?session_id=' + encodeURIComponent(sessionId));
          const data = await response.json();
          if (!response.ok) throw new Error(data.error || t('error'));
          if (store.disposed) return;
          store.cards = data.work || [];
          store.error = '';
        } catch (error) {
          if (!store.disposed) store.error = error.message;
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
  function styles() {
    return el('style', `
      .secretary-work { color:var(--color-text-primary); font-size:13px; line-height:1.6; }
      .secretary-work-aside { padding:16px; overflow:auto; height:100%; box-sizing:border-box; }
      .secretary-work-muted { color:var(--color-text-secondary); font-size:12px; }
      .secretary-work-card { border:1px solid var(--color-border); border-radius:var(--radius-md, 10px); padding:12px; margin:12px 0; }
      .secretary-work-content { white-space:pre-wrap; overflow-wrap:anywhere; }
      .secretary-work-actions { display:flex; gap:12px; align-items:center; margin-top:10px; }
      .secretary-work button { cursor:pointer; border:1px solid var(--color-border); border-radius:var(--radius-sm, 6px); background:var(--color-bg-secondary); color:inherit; padding:4px 10px; }
      .secretary-work-status { display:flex; flex-wrap:wrap; gap:8px; align-items:center; padding:6px 0; }
      .secretary-work-status-title { color:var(--color-text-secondary); }
      .secretary-work-error { color:var(--color-error); }
    `);
  }
  function mountRuntime(ctx, compact) {
    const store = acquire(ctx.sessionId);
    const root = el('div', null, 'secretary-work' + (compact ? '' : ' secretary-work-aside'));
    const body = el('div');
    root.append(styles(), body);
    function render() {
      body.replaceChildren();
      const cards = store.cards;
      const active = cards.filter(card => !terminal(card));
      const needs = cards.filter(attention);
      if (ctx.setBadge) ctx.setBadge(needs.length || active.length || null);
      if (store.error) body.append(el('div', store.error, 'secretary-work-error'));
      if (compact) {
        root.hidden = !cards.length && !store.error;
        if (!cards.length) return;
        const running = cards.filter(card => ['queued', 'running'].includes(card.status));
        const waiting = cards.filter(card => card.status === 'waiting_reply');
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
      body.append(el('p', t('help'), 'secretary-work-muted'));
      if (!cards.length) body.append(el('p', t('empty')));
      cards.forEach(card => {
        const section = el('section', null, 'secretary-work-card');
        section.append(el('strong', card.title), el('div', t(card.status), 'secretary-work-muted'));
        section.append(el('div', card.progress, 'secretary-work-content'));
        const details = el('details');
        details.append(el('summary', t('details')));
        details.append(el('div', card.instruction + '\n\n' + t('constraints') + (card.constraints || t('none')) + '\n' + (card.updates || []).map(update => update.text).join('\n'), 'secretary-work-content'));
        section.append(details);
        if (card.waiting?.check_at) section.append(el('small', t('check') + new Date(card.waiting.check_at).toLocaleString(locale())));
        const actions = el('div', null, 'secretary-work-actions');
        const discussButton = el('button', attention(card) ? t('confirm') : t('discuss'));
        discussButton.type = 'button';
        discussButton.onclick = () => discuss(card, ctx.sessionId);
        const link = el('a', t('history'));
        link.href = '#session/' + encodeURIComponent(card.session_id);
        actions.append(discussButton, link);
        section.append(actions);
        body.append(section);
      });
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
