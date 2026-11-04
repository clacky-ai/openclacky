const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.style = {}; this.value = ''; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
}
(async () => {
  const mounts = {}, handlers = {}, requests = [], badges = [];
  let lang = 'zh';
  const input = { text: '', chips: [] };
  const card = { id: 'work_1', session_id: 'worker_1', title: '<script>unsafe</script>', status: 'waiting_user',
    revision: 2, progress: '张三只有周五有空', instruction: '约饭', constraints: '不预订', updates: [] };
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
      return { ok: true, json: async () => ({ work: [JSON.parse(JSON.stringify(card))] }) };
    }, encodeURIComponent, JSON, Date
  };
  vm.runInNewContext(fs.readFileSync('lib/clacky/default_extensions/secretary/panels/work/view.js', 'utf8'), context);
  const aside = mounts['session.aside'].create({ sessionId: 'owner', setBadge: n => badges.push(n) });
  const banner = mounts['session.composer'].create({ sessionId: 'owner' });
  const flush = () => new Promise(resolve => setImmediate(resolve));
  const walk = node => [node, ...node.children.flatMap(walk)];
  await flush();
  assert.equal(requests.length, 1, 'slots share a per-session snapshot');
  let nodes = walk(aside.root);
  assert(nodes.some(n => n.tag === 'strong' && n.textContent === '<script>unsafe</script>'));
  assert(!nodes.some(n => n.innerHTML || n.tag === 'textarea'));
  assert(nodes.some(n => n.tag === 'a' && n.href === '#session/worker_1'));
  assert(walk(banner.root).some(n => n.textContent?.includes('1 件需要你确认')));
  assert.equal(badges.at(-1), 1);
  nodes.find(n => n.textContent === '和秘书确认').onclick();
  assert(input.text.includes('我想补充'));
  assert.equal(input.chips[0].session_id, 'worker_1');
  assert(input.focused);
  input.text = '保留正在输入的内容';
  nodes.find(n => n.textContent === '和秘书确认').onclick();
  assert.equal(input.text, '保留正在输入的内容');
  assert.equal(input.chips.length, 1, 'do not duplicate references');
  assert.equal(requests.length, 1, 'discussion must not mutate work or send automatically');
  card.status = 'running';
  handlers['ext.work.changed']({ sessionId: 'owner' });
  await flush();
  assert(walk(banner.root).some(n => n.textContent?.includes('正在推进 1 件事')));
  card.status = 'waiting_reply';
  handlers['session:subscribed']({ sessionId: 'owner' });
  await flush();
  assert(walk(banner.root).some(n => n.textContent?.includes('等待 1 个回复')));
  lang = 'en';
  handlers.langchange();
  assert(walk(banner.root).some(n => n.textContent?.includes('Awaiting replies: 1')));
  assert(walk(aside.root).some(n => n.textContent === 'Discuss with secretary'));
  input.text = ''; input.chips = [];
  walk(aside.root).find(n => n.textContent === 'Discuss with secretary').onclick();
  assert(input.text.includes('I would like to add:'));
  lang = 'fr'; handlers.langchange();
  assert(walk(aside.root).some(n => n.textContent === 'View execution history'), 'unknown locales fall back to English');
  const count = requests.length;
  handlers['ext.work.changed']({ sessionId: 'other' });
  assert.equal(requests.length, count, 'events must be scoped to their session');
  aside.dispose(); banner.dispose();
  handlers['ext.work.changed']({ sessionId: 'owner' });
  assert.equal(requests.length, count, 'disposed sessions must stop fetching');
  assert(requests.every(r => !r.opts), 'panel API is read-only');
  console.log('Secretary slots, events, badges, conversation references and disposal passed.');
})().catch(error => { console.error(error); process.exitCode = 1; });
