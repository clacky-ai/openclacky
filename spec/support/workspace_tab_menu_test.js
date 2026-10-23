"use strict";

// Regression harness for the workspace viewer's tab context menu and image
// zoom.
//
// Right-clicking an open file tab used to do nothing — the only way to close a
// file was the small × on the tab, and files could only reach the composer /
// be revealed on disk from the tree. The menu now offers the file actions the
// tree already had (add to chat, reveal, copy path, copy relative path,
// download) plus closing this tab or every tab at once.
//
// Pictures used to be locked to "fit and nothing else". Their pane now scales
// and pans, so the same stub drives the buttons, the wheel, the double click
// and a drag.
//
// The real view.js runs against a DOM stub; only I/O is faked.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = name => path.resolve(__dirname, "../../lib/clacky/web", name);

const autoStub = (extra = {}) => new Proxy(extra, {
  get: (target, key) => (key in target ? target[key] : () => {}),
});

// The image pane hands the fetched bytes to an object URL. Node's global URL
// parses but has no such pair, so the context gets a subclass that does.
class URLWithObjectUrls extends URL {
  static createObjectURL() { return "blob:stub"; }
  static revokeObjectURL() {}
}

function parseSelector(selector) {
  const attrs = [];
  const rest = selector.replace(/\[([\w-]+)="([^"]*)"\]/g, (_m, key, value) => {
    attrs.push([key, value]);
    return "";
  });
  const classes = rest.split(".").slice(1).map(s => s.trim()).filter(Boolean);
  const tag = rest.startsWith(".") ? null : (rest.split(".")[0].trim() || null);
  return { tag, classes, attrs };
}

function matches(el, selector) {
  const sel = parseSelector(selector);
  if (sel.tag && el.tagName !== sel.tag) return false;
  const classes = (el.className || "").split(/\s+/).filter(Boolean);
  if (!sel.classes.every(c => classes.includes(c))) return false;
  return sel.attrs.every(([key, value]) => {
    if (key.startsWith("data-")) {
      const prop = key.slice(5).replace(/-([a-z])/g, (_m, ch) => ch.toUpperCase());
      return el.dataset[prop] === value;
    }
    return el.attrs[key] === value;
  });
}

function descendants(root) {
  const out = [];
  for (const child of root.children || []) out.push(child, ...descendants(child));
  return out;
}

class Element {
  constructor(tag = "div") {
    this.tagName = tag;
    this.style = { setProperty() {} };
    this.dataset = {};
    this.attrs = {};
    this.children = [];
    this.parentNode = null;
    this.handlers = {};
    this.classes = new Set();
    this._className = "";
    this._innerHTML = "";
    this.textContent = "";
    this.focusCount = 0;
    // Layout metrics the zoom pane measures. They stay 0 until a test sets
    // them, which reads as "no viewport and no picture" — the same thing the
    // pane sees before the bytes arrive.
    this.clientWidth = 0;
    this.clientHeight = 0;
    this.offsetWidth = 0;
    this.offsetHeight = 0;
    this.naturalWidth = 0;
    this.naturalHeight = 0;
    this.complete = false;
    this.setPointerCapture = () => {};
    this.releasePointerCapture = () => {};
    this.classList = {
      add: n => this.classes.add(n),
      remove: n => this.classes.delete(n),
      toggle: (n, on) => (on ? this.classes.add(n) : this.classes.delete(n)),
      contains: n => this.classes.has(n),
    };
  }
  set className(v) { this._className = v; this.classes = new Set(v.split(/\s+/).filter(Boolean)); }
  get className() { return this._className; }
  get parentElement() { return this.parentNode; }
  // Menus are built from flat <div class="menu-item" data-action=".."> markup
  // wrapping icon/label spans; materialize both so a click can be dispatched.
  set innerHTML(v) {
    this._innerHTML = v;
    this.children = [];
    for (const item of String(v).matchAll(/<div class="([^"]*)"([^>]*)>([\s\S]*?)<\/div>/g)) {
      const div = new Element("div");
      div.className = item[1];
      const action = item[2].match(/data-action="([^"]*)"/);
      if (action) div.dataset.action = action[1];
      for (const span of item[3].matchAll(/<span class="([^"]*)">([^<]*)<\/span>/g)) {
        const child = new Element("span");
        child.className = span[1];
        child.textContent = span[2];
        div.appendChild(child);
      }
      this.appendChild(div);
    }
  }
  get innerHTML() { return this._innerHTML; }
  setAttribute(k, v) { this.attrs[k] = v; }
  getAttribute(k) { return this.attrs[k]; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(kind, fn) { this.handlers[kind] = fn; }
  removeEventListener() {}
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  append(...kids) { kids.forEach(k => this.appendChild(k)); }
  prepend(child) { this.children.unshift(child); child.parentNode = this; return child; }
  insertBefore(child) { return this.prepend(child); }
  replaceChildren(...kids) { this.children = kids; }
  remove() {
    if (!this.parentNode) return;
    this.parentNode.children = this.parentNode.children.filter(c => c !== this);
    this.parentNode = null;
  }
  querySelector(selector) { return descendants(this).find(el => matches(el, selector)) || null; }
  querySelectorAll(selector) { return descendants(this).filter(el => matches(el, selector)); }
  closest(selector) {
    let node = this;
    while (node) {
      if (matches(node, selector)) return node;
      node = node.parentNode;
    }
    return null;
  }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  contains() { return false; }
  scrollIntoView() {}
  focus() { this.focusCount += 1; }
  click() { if (this.handlers.click) this.handlers.click({ preventDefault() {}, stopPropagation() {} }); }
}

// Opening any of these files lands on the "hand it to the OS" pane, so no
// CodeMirror instance is needed to have real tabs on screen.
const TREE = {
  "": [
    { name: "report.docx", path: "report.docx", type: "file", size: 1200 },
    { name: "sheet.xlsx",  path: "sheet.xlsx",  type: "file", size: 900 },
    { name: "deck.pptx",   path: "deck.pptx",   type: "file", size: 4000 },
    { name: "memo.docx",   path: "memo.docx",   type: "file", size: 700 },
    // PDFs render as an iframe with no editor, which makes them the cheapest
    // file the viewer can reopen from a saved record.
    { name: "notes.pdf",   path: "notes.pdf",   type: "file", size: 5000 },
    { name: "guide.pdf",   path: "guide.pdf",   type: "file", size: 800 },
    // Pictures take the zoom pane, which is the only pane that measures its
    // container instead of just filling it.
    { name: "photo.png",   path: "photo.png",   type: "file", size: 200000 },
  ],
};

function boot(opts = {}) {
  const fetches = [];
  const confirms = [];
  const toasts = [];
  const nodes = {};
  const storage = opts.storage instanceof Map
    ? opts.storage
    : new Map(Object.entries(opts.storage || {}));
  const document = {
    createElement: tag => new Element(tag),
    createDocumentFragment: () => new Element("fragment"),
    createTextNode: text => ({ nodeType: 3, textContent: text }),
    getElementById: id => nodes[id] || (nodes[id] = new Element()),
    querySelector: sel => descendants(document.body).find(el => matches(el, sel)) || null,
    querySelectorAll: sel => descendants(document.body).filter(el => matches(el, sel)),
    addEventListener() {},
    body: new Element("body"),
  };

  const sent = [];
  const observers = [];
  // Restoring a deleted file logs the failure on purpose (silence is for the
  // user, not the console), so the harness keeps that line out of its output.
  const console = Object.assign({}, global.console, {
    error: (...args) => {
      if (String(args[0]).includes("preview failed")) return;
      global.console.error(...args);
    },
  });
  const context = {
    console, Date, Map, Set, Math, JSON, Promise, URL: URLWithObjectUrls, URLSearchParams,
    setTimeout: (fn, ms, ...args) => {
      const timer = setTimeout(fn, ms, ...args);
      if (timer.unref) timer.unref();
      return timer;
    },
    clearTimeout,
    requestAnimationFrame: fn => setTimeout(fn, 0),
    // The zoom pane watches its own box. Each observer is kept so a test can
    // report a new size the way the browser would.
    ResizeObserver: class {
      constructor(cb) { this.cb = cb; this.targets = []; observers.push(this); }
      observe(el) { this.targets.push(el); }
      disconnect() { this.disconnected = true; }
    },
    CSS: { escape: s => String(s) },
    navigator: { platform: "MacIntel", clipboard: { writeText: async () => {} } },
    document,
    fetch: async (url, options) => {
      fetches.push({ url: String(url), options });
      if (String(url).includes("/files")) {
        const rel = new URL(String(url), "http://localhost").searchParams.get("path") || "";
        return { ok: true, status: 200, json: async () => ({ root: "/wd", entries: TREE[rel] || [] }) };
      }
      // Any path with "missing" in it stands for a file that was deleted
      // between the reload and the restore.
      if (options && String(options.body || "").includes("missing")) {
        return { ok: false, status: 404, json: async () => ({ error: "file not found" }) };
      }
      return { ok: true, status: 200, json: async () => ({ ok: true }), blob: async () => ({}) };
    },
    localStorage: {
      getItem: key => (storage.has(key) ? storage.get(key) : null),
      setItem: (key, value) => { storage.set(key, String(value)); },
      removeItem: key => { storage.delete(key); },
    },
    I18n: { t: key => key, lang: () => "en" },
    Modal: {
      toast: (msg, kind) => { toasts.push({ msg, kind }); },
      confirm: async (msg) => { confirms.push(msg); return true; },
    },
    Clacky: { ext: { emit() {}, ui: { mountBuiltin() {} } } },
    WS: { ready: true, onEvent() {}, setSubscribedSession() {}, send: msg => sent.push(msg) },
    $: id => document.getElementById(id),
    escapeHtml: s => String(s === undefined || s === null ? "" : s),
    Router: autoStub(),
    Projects: autoStub(),
    Tasks: autoStub(),
    Skills: autoStub(),
    SkillAC: autoStub({ renderUserMessageHtml: s => s }),
    Composer: autoStub({ text: () => "follow-up", chips: () => [], clear() {}, focus() {} }),
    IME: autoStub({ track: () => ({ isComposing: () => false, dispose() {} }) }),
    alert() {},
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);

  ["utils.js", "sessions.js", "ws-dispatcher.js", "features/workspace/store.js", "components/code-editor.js", "components/image-zoom.js", "features/workspace/view.js"]
    .forEach(file => vm.runInContext(fs.readFileSync(sourcePath(file), "utf8"), context));

  const Sessions = vm.runInContext("Clacky.Sessions", context);
  Sessions.setAll([{ id: "s1", name: "s1", status: "idle", source: "manual",
                     created_at: "2026-09-01T00:00:00+08:00", updated_at: "2026-09-01T00:00:00+08:00" }]);
  Sessions._setActiveId("s1");

  const Workspace = vm.runInContext("Clacky.Workspace", context);
  const WorkspaceView = vm.runInContext("Clacky.WorkspaceView", context);
  Workspace.setSession({ id: "s1", working_dir: "/wd" });

  const container = new Element("div");
  WorkspaceView.mount(container, {});

  return {
    Sessions, document, container, fetches, confirms, sent, observers, storage, toasts,
    input: document.getElementById("user-input"),
    tree: container.querySelector(".wt-tree"),
  };
}

const settle = async (times = 6) => {
  for (let i = 0; i < times; i++) await new Promise(resolve => setTimeout(resolve, 0));
};

const plain = value => JSON.parse(JSON.stringify(value));

const row = (w, relPath) => w.tree.querySelector(`.wt-row[data-path="${relPath}"]`);

const tabButtons = w => w.container.querySelectorAll(".wv-tab");
const tabLabels = w => tabButtons(w).map(b => b.querySelector(".wv-tab-label").textContent);
const activeTabLabel = w => {
  const active = tabButtons(w).find(b => b.classList.contains("active"));
  return active ? active.querySelector(".wv-tab-label").textContent : null;
};

async function openFile(w, relPath) {
  row(w, relPath).handlers.click({ preventDefault() {}, stopPropagation() {} });
  await settle();
}

// The stub has no layout engine, so a test that needs the zoom pane measured
// writes the numbers the browser would have reported — 1600×1200 of picture
// inside an 800×600 pane — and replays the load event that follows the bytes.
async function openImage(w) {
  await openFile(w, "photo.png");
  const viewport = w.container.querySelector(".wv-zoom");
  const img = viewport.querySelector("img");
  viewport.clientWidth = 800;
  viewport.clientHeight = 600;
  img.naturalWidth = 1600;
  img.naturalHeight = 1200;
  img.handlers.load();
  return {
    viewport,
    img,
    ...zoomButtons(w),
  };
}

function zoomButtons(w) {
  const bar = w.container.querySelector(".wv-zoom-bar");
  return { bar, out: bar.children[0], level: bar.children[1], in: bar.children[2], fit: bar.children[3] };
}

// Right-click a tab the way the DOM would: clientX/Y only position the menu.
function openTabMenu(w, index) {
  tabButtons(w)[index].handlers.contextmenu({ preventDefault() {}, clientX: 10, clientY: 10 });
  return w.document.body.querySelector(".wt-context-menu");
}

async function clickTabMenu(w, menu, action, label) {
  const item = menuItem(menu, action);
  assert.ok(item, `the ${action} item is in the tab menu for ${label}`);
  await menu.handlers.click({ target: item });
  await settle();
}

function menuItem(menu, action) {
  return menu.children.filter(i => i.dataset.action === action)[0];
}

const GREYED_OUT = "session-actions-menu-item--disabled";

const TABS_KEY = "clacky.workspace.openTabs";
const savedRecord = (w, sessionId = "s1") => JSON.parse(w.storage.get(TABS_KEY) || "{}")[sessionId];
const withSaved = (tabs, active) => ({
  [TABS_KEY]: JSON.stringify({ s1: { tabs, active, ts: 1 } }),
});

async function tests() {
  // 1. The menu offers closing plus every file action the tree has, in that
  //    order, so the tab is a full stand-in for the row it came from.
  {
    const w = boot();
    await settle();
    await openFile(w, "report.docx");

    const menu = openTabMenu(w, 0);
    assert.ok(menu, "right-clicking a tab opens a menu");
    const actions = menu.children.filter(i => i.dataset.action).map(i => i.dataset.action);
    assert.deepEqual(actions,
      ["closetab", "closeothers", "closeright", "closealltabs",
       "addtochat", "reveal", "copypath", "copyrelpath", "download"],
      "the menu lists closing first, then the file actions");
    assert.ok(menu.querySelector(".wv-menu-separator"), "closing is separated from the file actions");
  }

  // 2. Closing acts on the tab that was right-clicked, not on whichever tab is
  //    active — the menu is the only way to reach a background tab.
  {
    const w = boot();
    await settle();
    await openFile(w, "report.docx");
    await openFile(w, "sheet.xlsx");
    await openFile(w, "deck.pptx");

    assert.deepEqual(tabLabels(w), ["report.docx", "sheet.xlsx", "deck.pptx"], "three files are open");
    assert.equal(activeTabLabel(w), "deck.pptx", "the last one opened is the active tab");

    await clickTabMenu(w, openTabMenu(w, 0), "closetab", "report.docx");

    assert.deepEqual(tabLabels(w), ["sheet.xlsx", "deck.pptx"], "the right-clicked tab is the one that closes");
    assert.equal(activeTabLabel(w), "deck.pptx", "closing a background tab does not steal the active one");
  }

  // 3. "Close others" keeps the right-clicked tab — and makes it the active
  //    one, since whatever was active may just have gone.
  {
    const w = boot();
    await settle();
    await openFile(w, "report.docx");
    await openFile(w, "sheet.xlsx");
    await openFile(w, "deck.pptx");

    await clickTabMenu(w, openTabMenu(w, 1), "closeothers", "sheet.xlsx");

    assert.deepEqual(tabLabels(w), ["sheet.xlsx"], "only the right-clicked tab survives");
    assert.equal(activeTabLabel(w), "sheet.xlsx", "and it becomes the active tab");
  }

  // 4. "Close to the right" drops everything after the right-clicked tab and
  //    leaves the tabs before it alone. On the last tab there is nothing to
  //    close, so the entry is greyed out instead of closing the tab itself.
  {
    const w = boot();
    await settle();
    await openFile(w, "report.docx");
    await openFile(w, "sheet.xlsx");
    await openFile(w, "deck.pptx");
    await openFile(w, "memo.docx");

    const enabledMenu = openTabMenu(w, 1);
    assert.ok(!menuItem(enabledMenu, "closeright").classList.contains(GREYED_OUT),
      "\"Close to the Right\" is enabled while tabs follow");
    await clickTabMenu(w, enabledMenu, "closeright", "sheet.xlsx");

    assert.deepEqual(tabLabels(w), ["report.docx", "sheet.xlsx"], "only the tabs to the right close");
    assert.equal(activeTabLabel(w), "sheet.xlsx", "the active tab went with them, so the last survivor takes over");

    const lastMenu = openTabMenu(w, 1);
    assert.ok(menuItem(lastMenu, "closeright").classList.contains(GREYED_OUT),
      "\"Close to the Right\" is greyed out on the last tab");

    await clickTabMenu(w, lastMenu, "closeright", "sheet.xlsx");
    assert.deepEqual(tabLabels(w), ["report.docx", "sheet.xlsx"], "clicking the greyed-out entry does nothing");
  }

  // 5. "Close all" empties the tab strip in one go.
  {
    const w = boot();
    await settle();
    await openFile(w, "report.docx");
    await openFile(w, "sheet.xlsx");
    await openFile(w, "deck.pptx");

    await clickTabMenu(w, openTabMenu(w, 1), "closealltabs", "sheet.xlsx");

    assert.deepEqual(tabLabels(w), [], "every tab is closed");
    assert.equal(w.confirms.length, 0, "nothing was unsaved, so nothing was asked");
  }

  // 6. The file actions travel with the tab's own entry, by absolute path.
  {
    const w = boot();
    await settle();
    await openFile(w, "report.docx");
    await openFile(w, "sheet.xlsx");

    await clickTabMenu(w, openTabMenu(w, 0), "addtochat", "report.docx");

    assert.equal(w.input.focusCount, 1, "the message input is focused");

    await w.Sessions.sendMessage();

    const msg = w.sent.find(m => m.type === "message");
    assert.deepEqual(plain(msg.files), [{ name: "report.docx", path: "/wd/report.docx", mime_type: "" }],
      "the right-clicked tab's file is staged, not the active tab's");
  }

  // 7. Reveal and download work from the tab too, on the right-clicked tab.
  {
    const w = boot();
    await settle();
    await openFile(w, "report.docx");
    await openFile(w, "sheet.xlsx");

    const before = w.fetches.length;
    await clickTabMenu(w, openTabMenu(w, 0), "reveal", "report.docx");

    const actions = w.fetches.slice(before)
      .filter(f => f.options && f.url.includes("/api/file-action"))
      .map(f => JSON.parse(f.options.body));
    assert.deepEqual(actions, [{ path: "/wd/report.docx", action: "reveal" }],
      "reveal targets the right-clicked tab's file");
  }

  // 8. Only one tab menu exists at a time: re-opening closes the previous one
  //    rather than stacking menus in the body.
  {
    const w = boot();
    await settle();
    await openFile(w, "report.docx");
    await openFile(w, "sheet.xlsx");

    openTabMenu(w, 0);
    openTabMenu(w, 1);

    assert.equal(w.document.body.querySelectorAll(".wt-context-menu").length, 1, "menus do not stack");
  }

  // 9. Open files are remembered per session so a reload can bring them back —
  //    but a binary tab stays out of the record: its only effect is launching
  //    an external application, which a reload must not do on its own.
  {
    const w = boot();
    await settle();
    await openFile(w, "notes.pdf");
    await openFile(w, "report.docx");

    const rec = savedRecord(w);
    assert.deepEqual(rec.tabs, ["notes.pdf"], "the previewable tab is remembered, the binary one is not");
    assert.equal(rec.active, "notes.pdf", "the active tab is remembered by path");
  }

  // 10. A reload rebuilds the strip from that record, including which file was
  //     in front — the remembered active path wins over "last opened".
  {
    const w = boot({ storage: withSaved(["notes.pdf", "guide.pdf"], "notes.pdf") });
    await settle();

    assert.deepEqual(tabLabels(w), ["notes.pdf", "guide.pdf"], "both files reopen after a reload");
    assert.equal(activeTabLabel(w), "notes.pdf", "the remembered active tab is the one in front");
  }

  // 11. A file that disappeared while the page was closed is skipped without a
  //     message, and the record is rewritten so later reloads stop asking.
  //     (A markdown path is used because text files are the ones that read
  //     from disk before they can fail; PDFs render without asking.)
  {
    const w = boot({ storage: withSaved(["missing.md", "notes.pdf"], "notes.pdf") });
    await settle();

    assert.deepEqual(tabLabels(w), ["notes.pdf"], "the surviving file still opens");
    assert.equal(w.toasts.length, 0, "a file that is gone is not worth a toast");
    assert.deepEqual(savedRecord(w).tabs, ["notes.pdf"], "the record drops the path that failed");
  }

  // 12. Closing every tab forgets the session, so the next reload starts empty
  //     instead of resurrecting files the user just dismissed.
  {
    const w = boot();
    await settle();
    await openFile(w, "notes.pdf");
    assert.ok(savedRecord(w), "opening a file records it");

    await clickTabMenu(w, openTabMenu(w, 0), "closealltabs", "notes.pdf");

    assert.equal(savedRecord(w), undefined, "the session is forgotten once its last tab closes");
  }

  // 13. End to end: what one page load leaves in storage is exactly what the
  //     next load reads back.
  {
    const first = boot();
    await settle();
    await openFile(first, "notes.pdf");
    await openFile(first, "guide.pdf");
    await clickTabMenu(first, openTabMenu(first, 0), "closetab", "notes.pdf");

    const reloaded = boot({ storage: first.storage });
    await settle();

    assert.deepEqual(tabLabels(reloaded), ["guide.pdf"], "the reload lands on what was left open");
    assert.equal(activeTabLabel(reloaded), "guide.pdf", "and on the tab that was in front");
  }

  // 14. A picture opens fitted: 1600×1200 in an 800×600 pane reads 50%, because
  //     the number is a real pixel ratio rather than a share of the pane.
  {
    const w = boot();
    await settle();
    const { img, level } = await openImage(w);

    assert.equal(level.textContent, "50%", "an oversized picture opens fitted to the pane");
    assert.equal(img.style.transform, "translate(0px, 0px) scale(0.5)", "the fitted scale is applied to the image");
  }

  // 15. The buttons step the zoom a quarter at a time, in both directions, and
  //     "fit" brings the whole picture back.
  {
    const w = boot();
    await settle();
    const { img } = await openImage(w);
    const b = zoomButtons(w);

    b.in.click();
    assert.equal(b.level.textContent, "63%", "+ steps up by a quarter");
    b.out.click();
    b.out.click();
    assert.equal(b.level.textContent, "40%", "− steps down, past the fit if asked");
    b.fit.click();
    assert.equal(b.level.textContent, "50%", "fit puts the whole picture back on screen");
    assert.equal(img.style.transform, "translate(0px, 0px) scale(0.5)", "and recentres it");
  }

  // 16. The wheel, a drag and a double click drive the same scale, and a drag
  //     stops at the edge of the picture instead of losing it off-screen.
  {
    const w = boot();
    await settle();
    const { viewport, img, level } = await openImage(w);
    const act = (kind, ev) => viewport.handlers[kind](Object.assign({ preventDefault() {} }, ev));

    act("wheel", { deltaY: -100, clientX: 0, clientY: 0 });
    assert.equal(level.textContent, "61%", "one wheel notch zooms in by about a quarter");

    zoomButtons(w).fit.click();  // back to a round 50%, so the pan has an exact expectation
    act("pointerdown", { button: 0, pointerId: 1, clientX: 0, clientY: 0 });
    act("pointermove", { pointerId: 1, clientX: 500, clientY: 400 });
    act("pointerup", { pointerId: 1 });
    assert.equal(img.style.transform, "translate(0px, 0px) scale(0.5)",
      "a picture that is exactly the size of the pane has nowhere to be dragged");

    zoomButtons(w).in.click();
    act("pointerdown", { button: 0, pointerId: 1, clientX: 0, clientY: 0 });
    act("pointermove", { pointerId: 1, clientX: 500, clientY: 400 });
    act("pointerup", { pointerId: 1 });
    assert.equal(img.style.transform, "translate(100px, 75px) scale(0.625)",
      "once it overflows, a drag pans to the edge of the picture and stops there");

    act("dblclick", { clientX: 0, clientY: 0 });
    assert.equal(level.textContent, "50%", "a double click returns a zoomed picture to the fit");
    act("dblclick", { clientX: 0, clientY: 0 });
    assert.equal(level.textContent, "100%", "and doubles it when the picture is already fitted");
  }

  // 17. A pane that changes size refits the picture — the aside can be dragged,
  //     and a tab opened in the background only learns its real size once it is
  //     shown — but a zoom the user asked for is left where they put it.
  {
    const w = boot();
    await settle();
    const { viewport, level } = await openImage(w);
    assert.equal(level.textContent, "50%", "the picture opens fitted");

    const resize = (width, height) => {
      viewport.clientWidth = width;
      viewport.clientHeight = height;
      w.observers.forEach(o => o.cb());
    };

    resize(400, 300);
    assert.equal(level.textContent, "25%", "a smaller pane fits the picture smaller");

    zoomButtons(w).in.click();
    assert.equal(level.textContent, "31%", "the user zooms in");
    resize(800, 600);
    assert.equal(level.textContent, "31%", "a resize after that leaves the zoom alone");

    await clickTabMenu(w, openTabMenu(w, 0), "closetab", "photo.png");
    assert.ok(w.observers.every(o => o.disconnected), "closing the tab stops watching the box");
  }
}

tests().then(
  () => console.log("workspace_tab_menu_test: ok"),
  err => { console.error(err); process.exit(1); }
);
