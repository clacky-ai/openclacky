"use strict";

// Regression harness for file-link handoff and Files viewer boundaries.
//
// The real store.js / code-editor.js / view.js run against a DOM stub, so the
// assertions cover both network calls and viewer side effects.

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
  const ui = { asideOpens: 0, filesTabClicks: 0 };
  const filesTab = new Element("button");
  filesTab.click = () => { ui.filesTabClicks += 1; };

  const document = {
    createElement: tag => new Element(tag),
    createDocumentFragment: () => new Element("fragment"),
    getElementById: id => nodes[id] || (nodes[id] = new Element()),
    addEventListener() {},
    querySelector: selector => selector === '.aside-tab[data-tab="files"]' ? filesTab : null,
    querySelectorAll: () => [],
    body: new Element("body"),
  };

  const context = {
    console, Date, Map, Set, Math, JSON, Promise, URL, URLSearchParams, Blob,
    setTimeout, clearTimeout, requestAnimationFrame: fn => setTimeout(fn, 0),
    CSS: { escape: s => String(s) },
    navigator: { platform: "MacIntel", clipboard: { writeText: async () => {} } },
    document,
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    I18n: { t: key => key, lang: () => "en" },
    Modal: { toast: (...args) => toasts.push(args) },
    Clacky: {
      Aside: { open: () => { ui.asideOpens += 1; } },
      ext: { emit() {}, ui: { mountBuiltin() {} } },
    },
    fetch: async (url, options) => {
      fetches.push({ url: String(url), options });
      if (String(url).includes("/files")) {
        return { ok: true, status: 200, json: async () => ({ root: "/wd", entries: [] }) };
      }
      const body = options && options.body ? JSON.parse(options.body) : {};
      if (opts.failOpen && body.action === "open") {
        return { ok: false, status: 500, json: async () => ({ error: "no handler" }) };
      }
      return {
        ok: true,
        status: 200,
        json: async () => ({ ok: true }),
        text: async () => opts.fileText || "hello",
        blob: async () => new Blob(["image"]),
      };
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

  return { WorkspaceView, Workspace, container, fetches, toasts, ui };
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
  {
    const { WorkspaceView } = boot();
    ["report.docx", "sheet.xlsx", "deck.pptx", "clip.mp4", "song.mp3", "bundle.zip", "poster.psd"]
      .forEach(name => assert.equal(WorkspaceView.autoOpenWithSystem(name), true, `${name} goes to the OS`));
    ["setup.exe", "installer.dmg", "lib.jar", "run.sh", "build.command", "lib.dylib", "mod.wasm"]
      .forEach(name => assert.equal(WorkspaceView.autoOpenWithSystem(name), false, `${name} stays manual`));
  }

  for (const name of ["report.docx", "sheet.xlsx", "deck.pptx", "clip.mp4"]) {
    const w = boot();
    assert.equal(await w.WorkspaceView.openLinkedFile(`/wd/${name}`), true);

    const opens = systemOpens(w);
    assert.equal(opens.length, 1, `${name} launches the default application once`);
    assert.equal(JSON.parse(opens[0].options.body).path, `/wd/${name}`);
    assert.equal(w.ui.asideOpens, 0, `${name} does not open the aside`);
    assert.equal(w.ui.filesTabClicks, 0, `${name} does not select Files`);
    assert.equal(subhintOf(w), null, `${name} does not create a fallback tab`);
  }

  {
    const w = boot({ failOpen: true });
    assert.equal(await w.WorkspaceView.openLinkedFile("/wd/report.docx"), true);
    await settle();

    assert.equal(systemOpens(w).length, 1, "the handoff is attempted once");
    assert.equal(w.toasts.length, 1, "the failure surfaces as a toast");
    assert.match(w.toasts[0][0], /workspace\.openWithFailed/);
    assert.equal(w.ui.asideOpens, 1, "the failure opens the aside fallback");
    assert.equal(w.ui.filesTabClicks, 1, "the failure selects Files");
    assert.equal(subhintOf(w), "workspace.fallbackSubHint");
  }

  for (const name of ["setup.exe", "installer.dmg", "run.sh", "build.command"]) {
    const w = boot();
    assert.equal(await w.WorkspaceView.openLinkedFile(`/wd/${name}`), true);
    await settle();

    assert.equal(systemOpens(w).length, 0, `${name} is not launched`);
    assert.equal(w.ui.asideOpens, 1, `${name} opens the safe fallback`);
    assert.equal(subhintOf(w), "workspace.fallbackSubHint");
  }

  for (const name of ["notes.md", "image.png", "paper.pdf", "data.csv"]) {
    const w = boot();
    assert.equal(await w.WorkspaceView.openLinkedFile(`/wd/${name}`), true);
    await settle();

    assert.equal(systemOpens(w).length, 0, `${name} stays in the viewer`);
    assert.equal(w.ui.asideOpens, 1, `${name} opens the aside preview`);
    assert.equal(w.ui.filesTabClicks, 1, `${name} selects Files`);
    assert.equal(subhintOf(w), null, `${name} does not create a fallback`);
  }

  {
    const w = boot({ fileText: "private\u0000payload" });
    assert.equal(await w.WorkspaceView.openLinkedFile("/wd/private.unknown"), true);
    await settle();

    assert.equal(systemOpens(w).length, 0, "unknown binary content is not launched");
    assert.equal(subhintOf(w), "workspace.fallbackSubHint");
  }

  {
    const w = boot();
    assert.equal(w.WorkspaceView.openFile("/wd/report.docx"), true);
    await settle();

    assert.equal(systemOpens(w).length, 0, "the Files viewer never launches an external app");
    assert.equal(w.ui.asideOpens, 1);
    assert.equal(w.ui.filesTabClicks, 1);
    assert.equal(subhintOf(w), "workspace.fallbackSubHint");
  }
}

tests().then(
  () => console.log("workspace_binary_handoff_test: ok"),
  err => { console.error(err); process.exit(1); }
);
