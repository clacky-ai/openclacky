"use strict";

// Regression harness for reloading the file tree while the user is watching it.
//
// The tree reloads every time the agent finishes a task (it may have created or
// edited files). Rebuilding it used to blank the panel down to a "loading"
// placeholder and collapse every folder the user had unfolded, which reads as
// the whole right column flickering. A reload must instead keep the listing on
// screen until the fresh one arrives and re-open the folders that were open.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = name => path.resolve(__dirname, "../../lib/clacky/web", name);

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
  for (const child of root.children || []) {
    out.push(child, ...descendants(child));
  }
  return out;
}

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
    this.value = "";
    this.classList = {
      add: n => this.classes.add(n),
      remove: n => this.classes.delete(n),
      toggle: (n, on) => (on ? this.classes.add(n) : this.classes.delete(n)),
      contains: n => this.classes.has(n),
    };
  }
  set className(v) { this._className = v; this.classes = new Set(v.split(/\s+/).filter(Boolean)); }
  get className() { return this._className; }
  get parentElement() { return this.parentNode || null; }
  get firstChild() { return this.children[0] || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const kids = this.parentNode.children;
    return kids[kids.indexOf(this) + 1] || null;
  }
  // Only the flat <div class="…">text</div> placeholders the view writes through
  // innerHTML matter here; icons (svg) are irrelevant to these tests.
  set innerHTML(v) {
    this._innerHTML = v;
    this.children = [];
    const re = /<div class="([^"]*)">([\s\S]*?)<\/div>/g;
    let m;
    while ((m = re.exec(v))) {
      const child = new Element("div");
      child.className = m[1];
      child.textContent = m[2];
      this.appendChild(child);
    }
  }
  get innerHTML() { return this._innerHTML; }
  setAttribute(k, v) { this.attrs[k] = v; }
  getAttribute(k) { return this.attrs[k]; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(k, fn) { this.handlers[k] = fn; }
  removeEventListener() {}
  appendChild(child) {
    // A DocumentFragment inserts its children, it does not become a child.
    if (child.tagName === "fragment") {
      child.children.slice().forEach(kid => this.appendChild(kid));
      child.children = [];
      return child;
    }
    this.children.push(child);
    child.parentNode = this;
    return child;
  }
  append(...kids) { kids.forEach(k => this.appendChild(k)); }
  prepend(child) {
    if (child.tagName === "fragment") {
      child.children.slice().reverse().forEach(kid => this.prepend(kid));
      child.children = [];
      return child;
    }
    this.children.unshift(child);
    child.parentNode = this;
    return child;
  }
  insertBefore(child, ref) {
    const kids = this.children;
    const move = node => {
      const from = kids.indexOf(node);
      if (from !== -1) kids.splice(from, 1);
    };
    const insert = node => {
      const at = ref ? kids.indexOf(ref) : -1;
      kids.splice(at === -1 ? kids.length : at, 0, node);
      node.parentNode = this;
    };
    if (child.tagName === "fragment") {
      child.children.slice().forEach(kid => { move(kid); insert(kid); });
      child.children = [];
      return child;
    }
    move(child);
    insert(child);
    return child;
  }
  replaceChildren(...kids) {
    this.children.forEach(kid => { kid.parentNode = null; });
    this.children = [];
    kids.forEach(kid => this.appendChild(kid));
  }
  remove() {
    if (!this.parentNode) return;
    const kids = this.parentNode.children;
    const i = kids.indexOf(this);
    if (i !== -1) kids.splice(i, 1);
    this.parentNode = null;
  }
  querySelector(selector) { return descendants(this).find(el => matches(el, selector)) || null; }
  querySelectorAll(selector) { return descendants(this).filter(el => matches(el, selector)); }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  contains() { return false; }
  closest() { return null; }
  scrollIntoView() {}
  focus() {}
  click() { const fn = this.handlers.click; if (fn) fn({ preventDefault() {}, stopPropagation() {} }); }
}

function findByClass(root, cls) {
  if ((root.className || "").split(/\s+/).includes(cls)) return root;
  for (const child of root.children || []) {
    const hit = findByClass(child, cls);
    if (hit) return hit;
  }
  return null;
}

const ROOT_ENTRIES = () => [
  { name: "backend", path: "backend", type: "dir" },
  { name: "index.html", path: "index.html", type: "file", size: 12 },
];

function boot(opts = {}) {
  const fetches = [];
  const toasts = [];
  const control = { fail: false };
  const nodes = {};
  const tree = opts.tree || {
    "": ROOT_ENTRIES(),
    "backend": [
      { name: "app.rb", path: "backend/app.rb", type: "file", size: 40 },
    ],
  };

  const document = {
    createElement: tag => new Element(tag),
    createDocumentFragment: () => new Element("fragment"),
    getElementById: id => nodes[id] || (nodes[id] = new Element()),
    addEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => [],
    body: new Element("body"),
  };

  const context = {
    console, Date, Map, Set, Math, JSON, Promise, URL, URLSearchParams,
    setTimeout, clearTimeout, requestAnimationFrame: fn => setTimeout(fn, 0),
    CSS: { escape: s => String(s) },
    navigator: { platform: "MacIntel", clipboard: { writeText: async () => {} } },
    document,
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    I18n: { t: key => key, lang: () => "en" },
    Modal: { toast: (message, type) => toasts.push([message, type]) },
    Clacky: { ext: { emit() {}, ui: { mountBuiltin() {} } } },
    fetch: async (url) => {
      fetches.push({ url: String(url) });
      if (String(url).includes("/files")) {
        if (control.fail) return { ok: false, status: 500, json: async () => ({ error: "boom" }) };
        if (opts.treeDelay) await new Promise(r => setTimeout(r, opts.treeDelay));
        const rel = new URL(String(url), "http://localhost").searchParams.get("path") || "";
        return { ok: true, status: 200, json: async () => ({ root: "/wd", entries: tree[rel] || [] }) };
      }
      return { ok: true, status: 200, json: async () => ({ ok: true }) };
    },
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);

  ["features/workspace/store.js", "components/code-editor.js", "features/workspace/view.js"]
    .forEach(file => vm.runInContext(fs.readFileSync(sourcePath(file), "utf8"), context));

  const WorkspaceView = vm.runInContext("Clacky.WorkspaceView", context);
  const Workspace = vm.runInContext("Clacky.Workspace", context);
  Workspace.setSession({ id: "s1", working_dir: "/wd" });

  const container = new Element("div");
  WorkspaceView.mount(container, {});

  return { WorkspaceView, Workspace, container, fetches, toasts, tree, control };
}

const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function settle(times = 4) {
  for (let i = 0; i < times; i++) await wait(0);
}

const treeEl = w => findByClass(w.container, "wt-tree");
const rowFor = (w, relPath) => treeEl(w).querySelector(`.wt-row[data-path="${relPath}"]`);
const buttonFor = (w, title) => descendants(w.container).find(el => el.tagName === "button" && el.title === title) || null;
const dirLoads = (w, rel) => w.fetches.filter(f => {
  if (!f.url.includes("/files")) return false;
  return new URL(f.url, "http://localhost").searchParams.get("path") === rel;
});

async function tests() {
  // 1. A reload keeps the listing on screen instead of blanking to "loading".
  {
    const w = boot({ treeDelay: 15 });
    await wait(60);
    await settle();
    rowFor(w, "backend").click();
    await wait(60);
    await settle();
    assert.ok(rowFor(w, "backend/app.rb"), "the folder's contents are rendered");

    w.Workspace.notifyTaskCompleted("s1");
    await wait(5); // inside the reload fetch window
    assert.ok(rowFor(w, "index.html"), "the previous listing stays visible while reloading");
    assert.equal(findByClass(treeEl(w), "wt-loading"), null,
      "no loading placeholder replaces the tree");

    await wait(80);
    await settle();
    assert.ok(rowFor(w, "index.html"), "the fresh listing is in place");
  }

  // 2. Folders the user had opened are re-opened after the reload.
  {
    const w = boot();
    await settle();
    rowFor(w, "backend").click();
    await settle();
    assert.ok(rowFor(w, "backend/app.rb"), "the folder is expanded");

    w.Workspace.notifyTaskCompleted("s1");
    await settle();
    await settle();

    const caret = rowFor(w, "backend").querySelector(".wt-caret");
    assert.ok(caret.classList.contains("open"), "the expanded folder is open again");
    assert.ok(rowFor(w, "backend/app.rb"), "its contents are back");
    assert.equal(dirLoads(w, "backend").length, 2, "its contents were re-fetched once");
  }

  // 3. Files the agent added while the tree was open show up on reload.
  {
    const w = boot();
    await settle();
    rowFor(w, "backend").click();
    await settle();

    w.tree[""] = ROOT_ENTRIES().concat([{ name: "new.md", path: "new.md", type: "file", size: 3 }]);
    w.Workspace.notifyTaskCompleted("s1");
    await settle();
    await settle();

    assert.ok(rowFor(w, "new.md"), "the new root file is listed");
    assert.ok(rowFor(w, "backend/app.rb"), "and the open folder is still expanded");
  }

  // 4. A folder the agent deleted drops out without breaking the reload.
  {
    const w = boot();
    await settle();
    rowFor(w, "backend").click();
    await settle();

    w.tree[""] = [{ name: "index.html", path: "index.html", type: "file", size: 12 }];
    w.Workspace.notifyTaskCompleted("s1");
    await settle();
    await settle();

    assert.equal(rowFor(w, "backend"), null, "the deleted folder is gone");
    assert.ok(rowFor(w, "index.html"), "the rest of the listing survives");
  }

  // 5. Another session starts collapsed: expansions do not leak across folders.
  {
    const w = boot();
    await settle();
    rowFor(w, "backend").click();
    await settle();
    assert.ok(rowFor(w, "backend/app.rb"), "the folder is expanded");

    w.Workspace.setSession({ id: "s2", working_dir: "/wd2" });
    await settle();
    await settle();

    const caret = rowFor(w, "backend").querySelector(".wt-caret");
    assert.equal(caret.classList.contains("open"), false, "the next session starts collapsed");
    assert.equal(treeEl(w).querySelector(".wt-children").children.length, 0,
      "no stale children are restored");
  }
  // 6. Surviving rows are the same DOM nodes after a reload: the tree is
  //    reconciled in place, never torn down and rebuilt (which is what made the
  //    column blank out, collapse and jump).
  {
    const w = boot({ treeDelay: 15 });
    await wait(60);
    await settle();
    rowFor(w, "backend").click();
    await wait(60);
    await settle();

    const backendNode = rowFor(w, "backend").parentElement;
    const indexNode = rowFor(w, "index.html").parentElement;
    const childrenEl = findByClass(treeEl(w), "wt-children");
    assert.ok(childrenEl.children.length > 0, "the folder has contents before the reload");

    w.Workspace.notifyTaskCompleted("s1");
    await wait(5); // inside the reload fetch window
    assert.equal(rowFor(w, "index.html").parentElement, indexNode,
      "the listing is untouched while the reload is in flight");
    assert.ok(childrenEl.children.length > 0, "the open folder keeps its rows while loading");

    await wait(80);
    await settle();
    assert.equal(rowFor(w, "backend").parentElement, backendNode, "the folder node was reused");
    assert.equal(rowFor(w, "index.html").parentElement, indexNode, "the file node was reused");
    assert.equal(findByClass(treeEl(w), "wt-children"), childrenEl,
      "the folder's child list element is the same");
  }

  // 7. The first listing replaces the placeholder instead of leaving it behind.
  {
    const w = boot({ treeDelay: 15 });
    assert.ok(findByClass(treeEl(w), "wt-loading"), "the placeholder shows while the first listing loads");
    await wait(60);
    await settle();
    assert.equal(findByClass(treeEl(w), "wt-loading"), null, "no placeholder survives the first listing");

    w.Workspace.setSession({ id: "s2", working_dir: "/wd2" });
    await wait(60);
    await settle();
    assert.equal(findByClass(treeEl(w), "wt-loading"), null, "no placeholder survives a session switch");

    const kids = treeEl(w).children.map(node => node.className);
    assert.equal(kids.filter(c => c === "wt-loading" || c === "wt-error").length, 0,
      "the tree holds nothing but rows");
  }

  // 8. The refresh button answers the click: the listing usually looks the same
  //    afterwards, so the toast is the only feedback there is.
  {
    const w = boot();
    await settle();
    const btn = buttonFor(w, "workspace.refresh");
    assert.ok(btn, "the refresh button is rendered");

    w.toasts.length = 0;
    btn.click();
    await settle();
    assert.deepEqual(w.toasts, [["workspace.refreshed", "success"]], "a refresh that worked says so");

    w.toasts.length = 0;
    rowFor(w, "backend").click();
    await settle();
    w.tree["backend"] = [];
    btn.click();
    await settle();
    assert.deepEqual(w.toasts, [["workspace.refreshed", "success"]], "and so does one that changes the tree");
  }

  // 9. A failed refresh keeps the listing and reports the failure.
  {
    const w = boot();
    await settle();
    assert.ok(rowFor(w, "index.html"), "the tree loaded once");

    w.control.fail = true;
    w.toasts.length = 0;
    buttonFor(w, "workspace.refresh").click();
    await settle();
    assert.deepEqual(w.toasts, [["workspace.refreshFailed", "error"]], "a failed refresh says so");
    assert.ok(rowFor(w, "index.html"), "the listing that was already there survives");
    assert.equal(findByClass(treeEl(w), "wt-error"), null, "and no error row replaces it");
  }
}

tests().then(
  () => console.log("workspace_tree_reload_test: ok"),
  err => { console.error(err); process.exit(1); }
);
