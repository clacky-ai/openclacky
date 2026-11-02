"use strict";

// Regression harness for the "open with" submenu in the file tree.
//
// Right-clicking a file must offer a submenu of the applications the backend
// reports for that extension, with the OS default handler called out. Picking
// one opens the file through /api/file-action. Folders get no such entry, and
// a file type with no registered app shows a hint instead of an empty popup.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = name => path.resolve(__dirname, "../../lib/clacky/web", name);

const autoStub = (extra = {}) => new Proxy(extra, {
  get: (target, key) => (key in target ? target[key] : () => {}),
});

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
    this.style = {};
    this.dataset = {};
    this.attrs = {};
    this.children = [];
    this.parentNode = null;
    this.handlers = {};
    this.classes = new Set();
    this._className = "";
    this._innerHTML = "";
    this.textContent = "";
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
  // The tree menu is built from flat <div class="menu-item" data-action="..">
  // markup wrapping icon/label spans; materialize both so a click can land.
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
  replaceChildren(...kids) {
    this.children = [];
    kids.forEach(k => { k.parentNode = this; this.children.push(k); });
  }
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
  getBoundingClientRect() { return { top: 20, bottom: 40, left: 40, right: 200, width: 160, height: 20 }; }
  contains() { return false; }
  scrollIntoView() {}
  focus() {}
  click() { if (this.handlers.click) this.handlers.click({ preventDefault() {}, stopPropagation() {} }); }
}

const TREE = {
  "": [
    { name: "src", path: "src", type: "dir" },
    { name: "report.docx", path: "report.docx", type: "file", size: 1200 },
    { name: "unknown.xyz", path: "unknown.xyz", type: "file", size: 10 },
  ],
};

const APPS = {
  "report.docx": [
    { name: "Pages", path: "/System/Applications/Pages.app" },
    { name: "TextEdit", path: "/System/Applications/TextEdit.app" },
  ],
};

function boot() {
  const nodes = {};
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

  const actions = [];
  const desktop = {
    "report.docx": { name: "Pages", path: "/System/Applications/Pages.app" },
  };

  const json = data => ({ ok: true, status: 200, json: async () => data });

  const context = {
    console, Date, Map, Set, Math, JSON, Promise, URL, URLSearchParams,
    setTimeout: (fn, ms, ...args) => {
      const timer = setTimeout(fn, ms, ...args);
      if (timer.unref) timer.unref();
      return timer;
    },
    clearTimeout,
    requestAnimationFrame: fn => setTimeout(fn, 0),
    innerWidth: 1280,
    innerHeight: 800,
    CSS: { escape: s => String(s) },
    navigator: { platform: "MacIntel", clipboard: { writeText: async () => {} } },
    document,
    fetch: async (url, opts) => {
      const target = new URL(String(url), "http://localhost");
      if (target.pathname === "/api/file/apps") {
        const file = path.basename(target.searchParams.get("path") || "");
        return json({ ok: true, apps: APPS[file] || [] });
      }
      if (target.pathname === "/api/file/default-app") {
        const file = path.basename(target.searchParams.get("path") || "");
        return json({ ok: true, app: desktop[file] || null });
      }
      if (target.pathname === "/api/file-action") {
        actions.push(JSON.parse(opts.body));
        return json({ ok: true });
      }
      if (target.pathname.endsWith("/files")) {
        const rel = target.searchParams.get("path") || "";
        return json({ root: "/wd", entries: TREE[rel] || [] });
      }
      return json({ ok: true });
    },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    I18n: { t: key => key, lang: () => "en" },
    Modal: { toast() {} },
    Clacky: { ext: { emit() {}, ui: { mountBuiltin() {} } } },
    WS: { ready: true, onEvent() {}, setSubscribedSession() {}, send() {} },
    $: id => document.getElementById(id),
    escapeHtml: s => String(s === undefined || s === null ? "" : s),
    Router: autoStub(),
    Projects: autoStub(),
    Tasks: autoStub(),
    Skills: autoStub(),
    SkillAC: autoStub({ renderUserMessageHtml: s => s }),
    Composer: autoStub({ text: () => "", chips: () => [], focus() {} }),
    IME: autoStub({ track: () => ({ isComposing: () => false, dispose() {} }) }),
    alert() {},
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);

  ["utils.js", "sessions.js", "ws-dispatcher.js", "features/workspace/store.js", "features/workspace/view.js"]
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

  return { WorkspaceView, document, container, actions, tree: container.querySelector(".wt-tree") };
}

const settle = async (times = 4) => {
  for (let i = 0; i < times; i++) await new Promise(resolve => setTimeout(resolve, 0));
};

const row = (w, relPath) => w.tree.querySelector(`.wt-row[data-path="${relPath}"]`);

function openMenu(w, relPath) {
  row(w, relPath).handlers.contextmenu({ preventDefault() {}, clientX: 10, clientY: 10 });
  return w.document.body.querySelector(".wt-context-menu");
}

function hover(el) {
  el.handlers.mouseenter({ preventDefault() {}, stopPropagation() {} });
}

async function tests() {
  // 1. Hovering the entry lists the apps for the file type, with the OS default
  //    handler marked, and picking one opens it through the backend.
  {
    const w = boot();
    await settle();

    const menu = openMenu(w, "report.docx");
    const entry = menu.querySelector('[data-action="openwith"]');
    assert.ok(entry, "a file offers 打开方式");
    assert.ok(entry.classList.contains("session-actions-menu-item--has-submenu"),
      "the row is marked as a submenu parent");
    assert.ok(entry.querySelector(".session-actions-menu-arrow"), "the row carries a chevron");

    hover(entry);
    await settle();

    const submenu = menu.querySelector(".session-actions-submenu");
    assert.equal(submenu.style.display, "block", "hover unfolds the submenu");

    const labels = submenu.querySelectorAll(".session-actions-submenu-label").map(n => n.textContent);
    assert.deepEqual(labels, ["Pages", "TextEdit"], "every app the backend reports is listed");

    const first = submenu.querySelectorAll(".session-actions-submenu-item")[0];
    assert.ok(first.className.includes("is-default"), "the default app is called out");
    assert.ok(first.querySelector("img"), "apps show their real icon");

    first.handlers.click({ preventDefault() {}, stopPropagation() {} });
    await settle();

    assert.deepEqual(w.actions, [{
      path: "/wd/report.docx",
      action: "open_with",
      app: "/System/Applications/Pages.app",
    }], "the chosen app is asked to open the absolute path");
    assert.equal(w.document.body.querySelector(".wt-context-menu"), null,
      "picking an app closes the whole menu");
  }

  // 2. Sliding onto a sibling row folds the submenu away, so two of them are
  //    never open at once.
  {
    const w = boot();
    await settle();

    const menu = openMenu(w, "report.docx");
    const entry = menu.querySelector('[data-action="openwith"]');
    hover(entry);
    await settle();
    const submenu = menu.querySelector(".session-actions-submenu");
    assert.equal(submenu.style.display, "block");

    menu.handlers.mouseover({ target: menu.querySelector('[data-action="reveal"]') });
    assert.equal(submenu.style.display, "none", "a sibling row folds the submenu away");
  }

  // 3. A file type no app claims shows a hint instead of an empty popup.
  {
    const w = boot();
    await settle();

    const menu = openMenu(w, "unknown.xyz");
    hover(menu.querySelector('[data-action="openwith"]'));
    await settle();

    const hint = menu.querySelector(".session-actions-submenu-hint");
    assert.ok(hint, "an unclaimed file type still explains itself");
    assert.equal(hint.textContent, "No app can open this file");
  }

  // 4. Folders have nothing to open in an app.
  {
    const w = boot();
    await settle();

    const menu = openMenu(w, "src");
    assert.equal(menu.querySelector('[data-action="openwith"]'), null, "folders have no 打开方式 entry");
    assert.ok(menu.querySelector('[data-action="reveal"]'), "the rest of the menu is untouched");
  }
}

tests().then(
  () => console.log("open_with_menu_test: ok"),
  err => { console.error(err); process.exit(1); }
);
