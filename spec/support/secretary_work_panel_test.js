const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.style = {}; this.value = ''; this.open = false; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
}
(async () => {
  const mounts = {}, handlers = {}, requests = [], badges = [];
  let lang = 'zh', schedules = [], extras = [], failedFetch = false;
  const input = { text: '', chips: [] };
  const card = { id: 'work_1', session_id: 'worker_1', title: '<script>unsafe</script>', status: 'waiting_user',
    created_at: '2026-11-04T01:30:00Z', revision: 2, progress: '张三周五有空，是否安排晚上七点？', instruction: '约饭的详细原始要求', constraints: '不预订', updates: [] };
  const context = {
    I18n: { lang: () => lang },
    document: { addEventListener: (name, fn) => { handlers[name] = fn; }, createElement: tag => new Element(tag), getElementById: id => id === 'user-input' ? input : null },
    Clacky: {
      ext: { context: { sessionId: 'owner' }, ui: { mount: (slot, definition) => { mounts[slot] = definition; } },
        subscribe: (event, fn) => { handlers[event] = fn; } },
      Composer: {
        hasContent: el => !!el.text || el.chips.length > 0,
        setText: (el, text) => { el.text = text; }, chips: el => el.chips,
        insertChip: (el, chip) => el.chips.push({ type: chip.type, session_id: chip.sessionId }),
        focusEnd: el => { el.focused = true; }
      }
    },
    fetch: async (url, opts) => {
      requests.push({ url, opts });
      if (failedFetch) throw new Error('raw backend traceback');
      return { ok: true, json: async () => ({ work: JSON.parse(JSON.stringify([card, ...extras])), schedules }) };
    }, encodeURIComponent, JSON, Date
  };
  vm.runInNewContext(fs.readFileSync('lib/clacky/default_extensions/secretary/panels/work/view.js', 'utf8'), context);
  const aside = mounts['session.aside'].create({ sessionId: 'owner', setBadge: n => badges.push(n) });
  const banner = mounts['session.composer'].create({ sessionId: 'owner' });
  const flush = () => new Promise(resolve => setImmediate(resolve));
  const walk = node => [node, ...node.children.flatMap(walk)];
  const visible = node => node.hidden ? [] : [node, ...(node.tag === 'details' && !node.open ? node.children.filter(n => n.tag === 'summary') : node.children).flatMap(visible)];
  const refresh = async () => { handlers['ext.work.changed']({ sessionId: 'owner' }); await flush(); };
  const has = (nodes, text) => nodes.some(n => n.textContent?.includes(text));
  await flush();
  assert.equal(requests.length, 1, 'slots share a snapshot');
  assert(has(visible(aside.root), '<script>unsafe</script>'));
  assert(!walk(aside.root).some(n => n.innerHTML || n.tag === 'textarea'));
  assert(has(visible(aside.root), card.progress));
  const createdTime = visible(aside.root).find(n => n.tag === 'time');
  assert.equal(createdTime.dateTime, card.created_at);
  assert(createdTime.textContent.startsWith('创建于：'));
  assert(!has(visible(aside.root), card.instruction));
  assert(visible(aside.root).some(n => n.tag === 'a'), 'history is directly accessible');
  assert(has(visible(banner.root), '1 件需要你关注'));
  assert(!walk(banner.root).some(n => n.tag === 'button'), 'composer has only the summary');
  assert.equal(badges.at(-1), 1);
  visible(aside.root).find(n => n.textContent === '与秘书讨论').onclick();
  assert(input.text.includes('我想补充'));
  assert.equal(input.chips[0].session_id, 'worker_1');
  assert(input.focused);
  input.text = '保留正在输入的内容';
  visible(aside.root).find(n => n.textContent === '与秘书讨论').onclick();
  assert.equal(input.text, '保留正在输入的内容');
  assert.equal(input.chips.length, 1);
  assert.equal(requests.length, 1, 'reply neither sends nor mutates');

  let details = walk(aside.root).find(n => n.tag === 'details' && n.className === 'secretary-work-details');
  details.open = true; details.ontoggle();
  await refresh();
  details = walk(aside.root).find(n => n.tag === 'details' && n.className === 'secretary-work-details');
  assert(details.open, 'refresh retains expanded work');
  assert(has(visible(aside.root), card.instruction), 'one disclosure shows requirements');
  assert(!walk(details).some(n => n.tag === 'details' && n !== details), 'no nested disclosure');
  details.open = false; details.ontoggle();

  card.created_at = '2026-10-01T00:00:00Z';
  card.status = 'running'; card.progress = 'INTERNAL FULL REPORT\n' + 'details '.repeat(80);
  extras = [
    { id: 'wait', session_id: 'w2', title: '供应商报价', status: 'waiting_reply', progress: '等待供应商回复', waiting: { check_at: '2026-11-06T07:00:00Z' } },
    { id: 'need', session_id: 'w3', title: '需要决定', status: 'waiting_user', progress: '是否选周五？' },
    ...Array.from({ length: 7 }, (_, i) => ({ id: 'done' + i, session_id: 'd' + i, title: '完成事项' + i, status: 'completed', progress: '完整结果', created_at: '2026-11-0' + (i + 1) }))
  ];
  await refresh();
  const preview = visible(aside.root).find(n => n.className === 'secretary-work-preview' && n.textContent.startsWith('INTERNAL'));
  assert(preview.textContent.length <= 141, 'output preview is bounded');
  assert(!has(walk(aside.root), card.progress), 'full output does not flood the panel');
  const titles = visible(aside.root).filter(n => n.tag === 'strong').map(n => n.textContent);
  assert.equal(titles[0], '完成事项6', 'newest created item first regardless of status');
  assert.equal(titles[6], '完成事项0');
  assert.equal(visible(aside.root).filter(n => n.textContent === '与秘书讨论').length, 10, 'every work has a visible discussion action');
  assert(has(visible(aside.root), '再次检查：'));
  delete extras[0].waiting;
  await refresh();
  assert(!has(visible(aside.root), '再次检查：'), 'do not promise a check without a deadline');

  card.status = 'waiting_reply'; card.progress = '等待张三回复'; extras = [];
  handlers['session:subscribed']({ sessionId: 'owner' }); await flush();
  assert(has(visible(banner.root), '等待 1 个回复'));
  assert.equal(badges.at(-1), null, 'waiting alone does not request user attention');
  lang = 'en'; handlers.langchange();
  assert(has(visible(banner.root), 'Awaiting replies: 1'));

  schedules = [{ name: 'secretary_1', target: { title: 'Morning report' }, enabled: true, cron: '0 9 * * *',
    content: 'Detailed report scope', next_run: '2026-11-05T01:00:00Z' }];
  await refresh();
  assert(has(visible(aside.root), 'Daily at 09:00'));
  assert(!has(visible(aside.root), '0 9 * * *'));
  assert(!has(visible(aside.root), 'Detailed report scope'));
  const plan = walk(aside.root).find(n => n.tag === 'details' && has(walk(n.children[0]), 'Morning report'));
  plan.open = true; plan.ontoggle();
  input.text = ''; input.chips = [];
  visible(plan).find(n => n.tag === 'button').onclick();
  assert(input.text.includes('I would like to change the plan'));
  assert.equal(input.chips.length, 0);
  input.text = 'Keep my draft'; visible(plan).find(n => n.tag === 'button').onclick();
  assert.equal(input.text, 'Keep my draft');
  context.Clacky.ext.context.sessionId = 'other'; input.text = '';
  visible(plan).find(n => n.tag === 'button').onclick(); assert.equal(input.text, '');
  context.Clacky.ext.context.sessionId = 'owner';

  lang = 'fr'; handlers.langchange();
  assert(has(visible(aside.root), 'Recurring plans'), 'unknown languages fall back to English');
  card.status = 'completed'; await refresh();
  assert(banner.root.hidden, 'completed work does not occupy the composer');
  failedFetch = true; await refresh();
  assert(has(visible(aside.root), 'Progress is temporarily unavailable'));
  assert(!has(walk(aside.root), 'raw backend traceback'));
  const count = requests.length;
  handlers['ext.work.changed']({ sessionId: 'other' });
  assert.equal(requests.length, count);
  aside.dispose(); banner.dispose();
  handlers['ext.work.changed']({ sessionId: 'owner' });
  assert.equal(requests.length, count);
  assert(requests.every(r => !r.opts), 'panel is read-only');
  console.log('Chronological ordering, bounded previews, disclosures, language, references, refresh and lifecycle passed.');
})().catch(error => { console.error(error); process.exitCode = 1; });
