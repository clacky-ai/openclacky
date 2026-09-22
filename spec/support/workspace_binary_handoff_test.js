"use strict";

// Regression harness for the workspace viewer's binary handoff.
//
// Clicking a .docx link used to open a pane that reads "this file type can't be
// previewed here" and leave the user to find and press Open themselves. The
// viewer now hands such files to the OS default application on that first
// click, except for formats the system would run or mount rather than display.
//
// The real store.js / code-editor.js / view.js run against a DOM stub, so the
// assertions read the fetch calls a click actually produced.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = name => path.resolve(__dirname, "../../lib/clacky/web", name);

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
  set innerHTML(v) { this._innerHTML = v; if (v === "") this.children = []; }
  get innerHTML() { return this._innerHTML; }
  setAttribute(k, v) { this.attrs[k] = v; }
  getAttribute(k) { return this.attrs[k]; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(k, fn) { this.handlers[k] = fn; }
  removeEventListener() {}
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  append(...kids) { kids.forEach(k => this.appendChild(k)); }
  prepend(child) { this.children.unshift(child); return child; }
  insertBefore(child) { this.children.unshift(child); return child; }
  replaceChildren(...kids) { this.children = kids; }
  remove() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  contains() { return false; }
  closest() { return null; }
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

// `failOpen` makes the "open with the OS" call answer 500 the way a machine
// without a handler for the extension would.
function boot(opts = {}) {
  const fetches = [];
  const toasts = [];
  const nodes = {};

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
    Modal: { toast: (...args) => toasts.push(args) },
    Clacky: { ext: { emit() {}, ui: { mountBuiltin() {} } } },
    fetch: async (url, options) => {
      fetches.push({ url: String(url), options });
      if (String(url).includes("/files")) {
        return { ok: true, status: 200, json: async () => ({ root: "/wd", entries: [] }) };
      }
      const body = options && options.body ? JSON.parse(options.body) : {};
      if (opts.failOpen && body.action === "open") {
        return { ok: false, status: 500, json: async () => ({ error: "no handler" }) };
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

  return { WorkspaceView, Workspace, container, fetches, toasts };
}

const settle = () => new Promise(resolve => setTimeout(resolve, 0));

const systemOpens = w => w.fetches.filter(f => {
  if (!f.options || f.options.method !== "POST" || !f.url.includes("/api/file-action")) return false;
  return JSON.parse(f.options.body).action === "open";
});

const subhintOf = w => {
  const node = findByClass(w.container, "wv-fallback-subhint");
  return node ? node.textContent : null;
};

async function tests() {
  // 1. Policy: formats with no in-browser renderer go to the OS; anything the
  //    system would run or mount instead keeps the manual page.
  {
    const { WorkspaceView } = boot();
    ["report.docx", "sheet.xlsx", "deck.pptx", "clip.mp4", "song.mp3", "bundle.zip", "poster.psd"]
      .forEach(name => assert.equal(WorkspaceView.autoOpenWithSystem(name), true, `${name} goes to the OS`));
    ["setup.exe", "installer.dmg", "lib.jar", "run.sh", "build.command", "lib.dylib", "mod.wasm"]
      .forEach(name => assert.equal(WorkspaceView.autoOpenWithSystem(name), false, `${name} stays manual`));
  }

  // 2. The reported flow: one click on a .docx launches the default app, and
  //    the pane says so instead of asking for a second click.
  {
    const w = boot();
    w.WorkspaceView.openFile("/wd/report.docx");
    await settle();

    const opens = systemOpens(w);
    assert.equal(opens.length, 1, "the click launched the default application once");
    assert.equal(JSON.parse(opens[0].options.body).path, "/wd/report.docx", "the clicked path is handed over");
    assert.equal(subhintOf(w), "workspace.openedInSystem", "the pane reports the handoff");
  }

  // 3. Executable formats are never launched by a link click.
  {
    const w = boot();
    w.WorkspaceView.openFile("/wd/lib.jar");
    await settle();

    assert.equal(systemOpens(w).length, 0, "no program is started");
    assert.equal(subhintOf(w), "workspace.fallbackSubHint", "the manual page still explains itself");
  }

  // 4. Re-opening a fallback file hands it to the OS again: the pane has no
  //    content of its own to re-select, and the document was probably closed in
  //    the meantime.
  {
    const w = boot();
    w.WorkspaceView.openFile("/wd/report.docx");
    await settle();
    w.WorkspaceView.openFile("/wd/report.docx");
    await settle();

    assert.equal(systemOpens(w).length, 2, "the application is launched again");
    assert.equal(subhintOf(w), "workspace.openedInSystem", "the pane still reports the handoff");
  }

  // 5. A fallback the OS must not launch by itself stays put when re-opened:
  //    nothing is loaded and no program starts.
  {
    const w = boot();
    w.WorkspaceView.openFile("/wd/lib.jar");
    await settle();
    const loaded = w.fetches.length;
    w.WorkspaceView.openFile("/wd/lib.jar");
    await settle();

    assert.equal(w.fetches.length, loaded, "no second load");
    assert.equal(systemOpens(w).length, 0, "no program is started");
  }

  // 6. A machine with no handler for the format keeps the manual fallback.
  {
    const w = boot({ failOpen: true });
    w.WorkspaceView.openFile("/wd/report.docx");
    await settle();

    assert.equal(systemOpens(w).length, 1, "the handoff was attempted");
    assert.equal(w.toasts.length, 1, "the failure surfaces as a toast");
    assert.match(w.toasts[0][0], /workspace\.openWithFailed/);
    assert.equal(subhintOf(w), "workspace.fallbackSubHint", "the pane does not claim it opened");
  }
}

tests().then(
  () => console.log("workspace_binary_handoff_test: ok"),
  err => { console.error(err); process.exit(1); }
);
