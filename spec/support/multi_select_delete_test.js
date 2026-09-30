"use strict";

// Harness for bulk-deleting sessions from the sidebar.
//
// The sidebar has one row renderer shared by the main list, the folded group
// sub-views, the project section and the search overlay. Selection mode is
// therefore module state scoped by DOM ancestry (`#sidebar-list`) rather than a
// per-call-site flag — these assertions pin that scoping down, plus the delete
// fan-out and the partial-failure path.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = name => path.resolve(__dirname, "../../lib/clacky/web", name);

const autoStub = (extra = {}) => new Proxy(extra, {
  get: (target, key) => (key in target ? target[key] : () => {}),
});

class Element {
  constructor(tag = "div") {
    this.tagName = tag;
    this.style = { setProperty() {} };
    this.dataset = {};
    this.attrs = {};
    this.children = [];
    this.handlers = {};
    this.classes = new Set();
    this._className = "";
    this._innerHTML = "";
    this.textContent = "";
    this.disabled = false;
    this.hidden = false;
    this.parentNode = null;
    this.classList = {
      add: n => this.classes.add(n),
      remove: n => this.classes.delete(n),
      toggle: (n, on) => (on ? this.classes.add(n) : this.classes.delete(n)),
      contains: n => this.classes.has(n),
    };
  }
  set className(v) { this._className = v; this.classes = new Set(v.split(/\s+/).filter(Boolean)); }
  get className() { return this._className; }
  set innerHTML(v) { this._innerHTML = v; if (v === "") this.children = []; }
  get innerHTML() { return this._innerHTML; }
  setAttribute(k, v) { this.attrs[k] = v; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(k, fn) { this.handlers[k] = fn; }
  removeEventListener() {}
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  append(...kids) { kids.forEach(k => this.appendChild(k)); }
  prepend(child) { this.children.unshift(child); child.parentNode = this; return child; }
  remove() {
    if (!this.parentNode) return;
    const idx = this.parentNode.children.indexOf(this);
    if (idx !== -1) this.parentNode.children.splice(idx, 1);
    this.parentNode = null;
  }
  replaceChildren(...kids) { this.children = kids; }
  insertBefore(child) { this.children.unshift(child); child.parentNode = this; return child; }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  focus() {}

  descendants() {
    const out = [];
    this.children.forEach(c => { out.push(c); out.push(...c.descendants()); });
    return out;
  }

  // Supports only the selector shapes sessions.js actually uses here:
  // "#id", ".cls", "[data-attr]" and whitespace-joined combinations.
  matches(selector) {
    return selector.trim().split(/\s+/).every(part => {
      const tokens = part.match(/(^[a-z]+)|(\.[A-Za-z0-9_-]+)|(#[A-Za-z0-9_-]+)|(\[[^\]]+\])/g) || [];
      return tokens.every(token => {
        if (token.startsWith(".")) return this.classes.has(token.slice(1));
        if (token.startsWith("#")) return this.attrs.id === token.slice(1);
        if (token.startsWith("[")) {
          const name = token.slice(1, -1).split("=")[0];
          const key = name.replace(/^data-/, "").replace(/-([a-z])/g, (_, c) => c.toUpperCase());
          return name.startsWith("data-") ? key in this.dataset : name in this.attrs;
        }
        return this.tagName === token;
      });
    });
  }

  querySelectorAll(selector) {
    // Descendant combinators are checked against the *last* compound only;
    // ancestry is then verified via closest() on the ancestor part.
    const parts = selector.trim().split(/\s+(?![^[]*\])/);
    const leaf = parts[parts.length - 1];
    const ancestor = parts.slice(0, -1).join(" ");
    return this.descendants().filter(node => {
      if (!node.matches(leaf)) return false;
      if (!ancestor) return true;
      return node.parentNode ? Boolean(node.parentNode.closest(ancestor)) : false;
    });
  }

  querySelector(selector) {
    const hit = this.querySelectorAll(selector)[0];
    if (hit) return hit;
    // innerHTML is stored verbatim, never parsed. Hand back a detached stub for
    // markup that only exists as a string (e.g. a row's own ⋯ button) so the
    // code under test can attach handlers to it.
    const attr = selector.match(/^\[([\w-]+)="([^"]*)"\]$/);
    if (attr) return this._innerHTML.includes(`${attr[1]}="${attr[2]}"`) ? new Element() : null;
    const bare = selector.replace(/^[.#]/, "");
    return this._innerHTML.includes(bare) ? new Element() : null;
  }

  closest(selector) {
    let node = this;
    while (node) {
      if (node.matches && node.matches(selector)) return node;
      node = node.parentNode;
    }
    return null;
  }

  contains(other) { return other === this || this.descendants().includes(other); }
}

function boot({ fetchImpl } = {}) {
  const nodes = {};
  const unrefTimeout = (fn, ms, ...args) => {
    const timer = setTimeout(fn, ms, ...args);
    if (timer.unref) timer.unref();
    return timer;
  };

  const make = id => {
    const el = new Element();
    el.attrs.id = id;
    return el;
  };

  const document = {
    createElement: tag => new Element(tag),
    createDocumentFragment: () => new Element("fragment"),
    getElementById: id => nodes[id] || (nodes[id] = make(id)),
    addEventListener() {},
    body: new Element(),
    querySelector(sel) { return document.body.querySelector(sel); },
    querySelectorAll(sel) { return document.body.querySelectorAll(sel); },
  };

  const requests = [];
  const context = {
    console, Date, Map, Set, Math, JSON, Promise, Array, Object, URLSearchParams,
    encodeURIComponent,
    setTimeout: unrefTimeout,
    clearTimeout,
    requestAnimationFrame: fn => unrefTimeout(fn, 0),
    document,
    fetch: async (url, opts) => {
      requests.push({ url, method: opts && opts.method });
      return fetchImpl ? fetchImpl(url, opts) : { ok: true, json: async () => ({}) };
    },
    I18n: { t: (key, vars) => (vars ? `${key}:${JSON.stringify(vars)}` : key), lang: () => "en" },
    WS: { onEvent() {}, setSubscribedSession() {}, send() {} },
    Clacky: {},
    $: id => document.getElementById(id),
    escapeHtml: s => String(s === undefined || s === null ? "" : s),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    Router: autoStub(),
    Projects: autoStub(),
    Tasks: autoStub(),
    Skills: autoStub(),
    Modal: autoStub({ confirm: async () => true, toast: () => {} }),
    Composer: autoStub({ text: () => "", chips: () => [] }),
    IME: autoStub({ track: () => ({ isComposing: () => false, dispose() {} }) }),
    innerWidth: 1024,
    alert() {},
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);

  vm.runInContext(fs.readFileSync(sourcePath("utils.js"), "utf8"), context);
  vm.runInContext(fs.readFileSync(sourcePath("sessions.js"), "utf8"), context);

  const Sessions = vm.runInContext("Clacky.Sessions", context);

  // Mirror index.html: #session-list lives inside #sidebar-list, and the
  // select bar is a sibling of the list (not inside it).
  const sidebarList = document.getElementById("sidebar-list");
  const list = document.getElementById("session-list");
  sidebarList.appendChild(list);
  document.body.appendChild(sidebarList);

  const bar = document.getElementById("session-select-bar");
  const count = new Element("span");
  count.dataset.selectCount = "";
  const delBtn = new Element("button");
  delBtn.dataset.selectDelete = "";
  delBtn.disabled = true;
  const delLabel = new Element("span");
  delLabel.dataset.selectDeleteLabel = "";
  delBtn.appendChild(delLabel);
  bar.appendChild(count);
  bar.appendChild(delBtn);
  bar.hidden = true;
  document.body.appendChild(bar);

  return { Sessions, context, document, sidebarList, list, bar, count, delBtn, delLabel, requests };
}

const row = (id, extra = {}) => Object.assign({
  id, name: id, status: "idle", source: "manual",
  created_at: "2026-08-01T00:00:00+08:00",
  updated_at: "2026-08-01T00:00:00+08:00",
}, extra);

const click = el => el.onclick({ target: el, closest: () => null, preventDefault() {} });

const tick = () => new Promise(resolve => setImmediate(resolve));

// Arrays cross the vm realm boundary, so deepEqual against a plain literal
// fails on prototype identity alone. Normalise before comparing.
const ids = value => JSON.parse(JSON.stringify(Array.from(value)));

async function tests() {
  // 1. Entering selection mode goes through the header "···" menu: opening
  //    the menu alone must not select anything, only its labelled item does.
  //    Nothing is pre-ticked: the entry is list-level, so no row gets
  //    special treatment.
  {
    const { Sessions, document, sidebarList, bar, list } = boot();
    Sessions.setAll([row("a"), row("b"), row("c")]);
    Sessions.renderList();

    assert.equal(sidebarList.classes.has("selecting"), false);
    assert.equal(bar.hidden, true, "bar is hidden until selection mode starts");

    Sessions._showListMenu(document.getElementById("btn-sessions-menu"));

    const menus = document.body.children.filter(el => el.classes.has("session-actions-menu"));
    assert.equal(menus.length, 1, "the header menu opens as a floating layer");
    const html = menus[0]._innerHTML;
    assert.match(html, /session-actions-menu-item session-actions-menu-item--danger session-actions-menu-item--danger-follow" data-action="selectMultiple"/,
      "the item is the row-menu danger variant, separator stripped");
    assert.match(html, /M3 6h18/, "the item carries the shared trash icon");
    assert.match(html, /session-actions-menu-label">sessions\.actions\.selectMultiple</,
      "the item is labelled so a mis-tap needs two clicks, not one");
    assert.equal(sidebarList.classes.has("selecting"), false,
      "opening the menu alone must not start selection");

    Sessions.enterSelectMode();

    assert.equal(sidebarList.classes.has("selecting"), true,
      "the sidebar carries the scope class that reveals checkboxes");
    assert.equal(bar.hidden, false, "the select bar becomes visible");
    assert.deepEqual(ids(Sessions.selectedIds()), [], "nothing starts ticked");

    const marked = list.children.filter(el => el.classes.has("selected")).map(el => el.dataset.sessionId);
    assert.deepEqual(marked, [], "no row is visually ticked");
  }

  // 2. The checkbox markup ships with every row so entering selection mode
  //    never needs a re-render (which would reset the sidebar scroll).
  {
    const { Sessions, list } = boot();
    Sessions.setAll([row("a")]);
    Sessions.renderList();
    assert.match(list.children[0].innerHTML, /class="session-select"/,
      "rows always contain the checkbox wrapper");
    assert.match(list.children[0].innerHTML, /session-select-box/,
      "rows always contain the checkbox markup");
  }

  // 3. Clicking a row in selection mode toggles the tick instead of opening
  //    the session — and does so synchronously, not after the dblclick timer.
  {
    const { Sessions, list } = boot();
    let opened = null;
    Sessions.setAll([row("a"), row("b")]);
    Sessions.renderList();
    Sessions.enterSelectMode();

    const original = Sessions.select;
    Sessions.select = id => { opened = id; };

    click(list.children[0]);
    assert.deepEqual(ids(Sessions.selectedIds()), ["a"], "click ticks the row immediately");
    assert.equal(opened, null, "the session is not opened while selecting");
    assert.equal(list.children[0].classes.has("selected"), true);

    click(list.children[0]);
    assert.deepEqual(ids(Sessions.selectedIds()), [], "clicking again unticks");
    assert.equal(list.children[0].classes.has("selected"), false);

    Sessions.select = original;
  }

  // 4. The counter tracks the tick count and the delete button is inert at zero.
  {
    const { Sessions, list, count, delBtn, delLabel } = boot();
    // 3 rows paged in, but the server says there are 140 sessions in total.
    Sessions.setAll([row("a"), row("b"), row("c")], false, {}, 140);
    Sessions.renderList();
    Sessions.enterSelectMode();

    assert.equal(delBtn.disabled, true, "nothing selected → delete is disabled");
    assert.match(count.textContent, /"n":0/);
    // The denominator must be the server's total, never the number of rows
    // that happen to be paged into the sidebar.
    assert.match(count.textContent, /"total":140/, "counter reports the server total");

    click(list.children[0]);
    click(list.children[1]);

    assert.equal(delBtn.disabled, false);
    assert.match(count.textContent, /"n":2/);
    assert.match(delLabel.textContent, /"n":2/, "the button label carries the count");

    // Deleting a row must decrement the total, or the denominator goes stale.
    Sessions.remove("a");
    Sessions._renderSelectBar();
    assert.match(count.textContent, /"total":139/, "total drops as sessions go away");
  }

  // 5. Deleting fans out one DELETE per ticked session and drops them locally.
  {
    const { Sessions, list, requests } = boot();
    Sessions.setAll([row("a"), row("b"), row("c")]);
    Sessions.renderList();
    Sessions.enterSelectMode();
    click(list.children[0]);
    click(list.children[2]);

    await Sessions.deleteSelected();
    await tick();

    const deletes = requests.filter(r => r.method === "DELETE").map(r => r.url).sort();
    assert.deepEqual(deletes, ["/api/sessions/a", "/api/sessions/c"],
      "exactly the ticked sessions are deleted");
    assert.deepEqual(ids(Sessions.all.map(s => s.id)), ["b"], "deleted rows leave the local list");
    assert.equal(Sessions.selectMode, false, "selection mode ends after a successful delete");
  }

  // 6. A partial failure still removes what succeeded, and reports the rest.
  {
    const failing = new Set(["b"]);
    const { Sessions, list } = boot({
      fetchImpl: async url => {
        const id = url.split("/").pop();
        return failing.has(id)
          ? { ok: false, status: 500, json: async () => ({ error: "boom" }) }
          : { ok: true, json: async () => ({}) };
      },
    });
    Sessions.setAll([row("a"), row("b")]);
    Sessions.renderList();
    Sessions.enterSelectMode();
    click(list.children[0]);
    click(list.children[1]);

    await Sessions.deleteSelected();
    await tick();

    assert.deepEqual(ids(Sessions.all.map(s => s.id)), ["b"],
      "the session that failed to delete stays in the list");
  }

  // 7. A 404 means the session is already gone server-side — converge instead
  //    of reporting a failure the user can do nothing about.
  {
    const { Sessions, list } = boot({
      fetchImpl: async () => ({ ok: false, status: 404, json: async () => ({}) }),
    });
    Sessions.setAll([row("a")]);
    Sessions.renderList();
    Sessions.enterSelectMode();
    click(list.children[0]);

    await Sessions.deleteSelected();
    await tick();

    assert.deepEqual(ids(Sessions.all.map(s => s.id)), [], "a 404 row is removed locally");
  }

  // 8. Leaving selection mode restores normal row behaviour.
  {
    const { Sessions, list, sidebarList, bar } = boot();
    let opened = null;
    Sessions.setAll([row("a")]);
    Sessions.renderList();
    Sessions.enterSelectMode();
    click(list.children[0]);
    Sessions.exitSelectMode();

    assert.equal(sidebarList.classes.has("selecting"), false);
    assert.equal(bar.hidden, true, "the bar hides again");
    assert.deepEqual(ids(Sessions.selectedIds()), [], "ticks are dropped on exit");
    assert.equal(list.children[0].classes.has("selected"), false,
      "the row's tick styling is cleared");

    Sessions.select = id => { opened = id; };
    click(list.children[0]);
    await tick();
    assert.equal(opened, null, "single click is still debounced, not instant");
    await new Promise(resolve => waitReal(resolve, 250));
    assert.equal(opened, "a", "after exiting, clicking a row opens the session again");
  }

  // 9. Rows rendered into the search overlay live outside #sidebar-list, so
  //    they must keep opening sessions even while selection mode is active.
  {
    const { Sessions, document, list } = boot();
    Sessions.setAll([row("a")]);
    Sessions.renderList();
    Sessions.enterSelectMode();

    const overlay = document.getElementById("session-search-overlay");
    document.body.appendChild(overlay);
    Sessions.renderSessionItem(overlay, row("a"));
    const overlayRow = overlay.children[0];

    let opened = null;
    Sessions.select = id => { opened = id; };
    click(overlayRow);

    assert.deepEqual(ids(Sessions.selectedIds()), [],
      "clicking a search-overlay row does not tick anything");
    await new Promise(resolve => waitReal(resolve, 250));
    assert.equal(opened, "a", "the search-overlay row still opens the session");
    assert.equal(list.children[0].classes.has("selected"), false);
  }

  // 10. Deleting the open session sends the user back to the welcome screen.
  {
    const { Sessions, context, list } = boot();
    const navigated = [];
    context.Router.navigate = target => navigated.push(target);
    Sessions.setAll([row("a"), row("b")]);
    Sessions._setActiveId("a");
    Sessions.renderList();
    Sessions.enterSelectMode();
    click(list.children[0]);

    await Sessions.deleteSelected();
    await tick();

    assert.deepEqual(navigated, ["welcome"],
      "removing the active session navigates away from the dead route");
  }

  // 11. A row deleted elsewhere (WS broadcast) must leave the tick set, or the
  //     counter would include a session that no longer exists.
  {
    const { Sessions, list } = boot();
    Sessions.setAll([row("a"), row("b")]);
    Sessions.renderList();
    Sessions.enterSelectMode();
    click(list.children[0]);
    click(list.children[1]);
    assert.equal(ids(Sessions.selectedIds()).length, 2);

    Sessions.remove("a");
    assert.deepEqual(ids(Sessions.selectedIds()), ["b"],
      "an externally removed session drops out of the selection");
  }
}

// The dblclick debounce is real time, and this one must keep the event loop
// alive — unref'ing it would let node exit before the assertion runs.
const waitReal = (fn, ms) => setTimeout(fn, ms);

tests().then(
  () => { console.log("multi-select delete: all assertions passed"); },
  err => { console.error(err); process.exit(1); }
);
