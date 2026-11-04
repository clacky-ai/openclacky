"use strict";

// Regression harness for reloading workspace file viewer tabs after AI edits.
//
// 1. Reopening a file whose tab is already open must refetch it from disk
//    instead of showing the stale tab content.
// 2. Completing an agent task (workspace:taskCompleted) must refresh open tabs
//    so users do not have to close and reopen the tab to see AI changes.
// 3. A tab with unsaved user edits (dirty) must never be overwritten.
// 4. CodeEditor.setContent() must update the doc without firing onChange
//    (otherwise a silent refresh would mark the tab dirty).

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = name => path.resolve(__dirname, "../../lib/clacky/web", name);
const read = name => fs.readFileSync(sourcePath(name), "utf8");

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
      add: (...names) => { names.forEach(n => this.classes.add(n)); this._syncClassName(); },
      remove: (...names) => { names.forEach(n => this.classes.delete(n)); this._syncClassName(); },
      toggle: (n, on) => { (on ? this.classes.add(n) : this.classes.delete(n)); this._syncClassName(); },
      contains: n => this.classes.has(n),
    };
  }
  _syncClassName() { this._className = Array.from(this.classes).join(" "); }
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
  insertBefore(child, ref) {
    const idx = ref ? this.children.indexOf(ref) : -1;
    if (idx >= 0) {
      this.children.splice(idx, 0, child);
      child.parentNode = this;
    } else {
      this.appendChild(child);
    }
    return child;
  }
  remove() {
    if (!this.parentNode) return;
    this.parentNode.children = this.parentNode.children.filter(c => c !== this);
    this.parentNode = null;
  }
  replaceChildren(...kids) { this.children = kids; kids.forEach(k => { k.parentNode = this; }); }
  querySelector(sel) { return descendants(this).find(el => matches(el, sel)) || null; }
  querySelectorAll(sel) { return descendants(this).filter(el => matches(el, sel)); }
  closest() { return null; }
  scrollIntoView() {}
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 200, height: 200 }; }
  click() { const fn = this.handlers.click; if (fn) fn({ preventDefault() {}, stopPropagation() {}, target: this }); }
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

function makeDocument() {
  const nodes = {};
  const body = new Element("body");
  return {
    documentElement: new Element("html"),
    body,
    createElement: tag => new Element(tag),
    createDocumentFragment: () => new Element("fragment"),
    getElementById: id => nodes[id] || (nodes[id] = new Element()),
    querySelector: sel => descendants(body).find(el => matches(el, sel)) || null,
    querySelectorAll: sel => descendants(body).filter(el => matches(el, sel)),
    addEventListener() {},
    removeEventListener() {},
  };
}

// The viewer only needs the CodeEditor facade. Stubbing it keeps this harness
// focused on view.js: `setContent` calls are recorded so assertions can check
// the new disk content actually reached the editor.
function stubCodeEditor() {
  const calls = { setContent: [], onChange: null };
  return {
    calls,
    fileKind: () => "text",
    detectLanguage: () => "text",
    looksBinary: () => false,
    renderMarkdown: text => `<p>${text}</p>`,
    renderTable: () => ({ table: new Element("table"), truncated: false, rows: 0 }),
    createInline(container, opts) {
      let content = opts.content || "";
      if (opts.onChange) calls.onChange = opts.onChange;
      return {
        view: {
          state: { doc: { toString: () => content, length: content.length } },
          dispatch() {},
          focus() {},
          requestMeasure() {},
        },
        getContent: () => content,
        setContent(text) {
          content = String(text);
          calls.setContent.push(content);
        },
        destroy() {},
      };
    },
  };
}

function boot(initialFiles = {}) {
  const files = Object.assign({}, initialFiles);
  const fetches = [];
  const previewOpens = [];
  const document = makeDocument();
  const CodeEditor = stubCodeEditor();

  const context = {
    console, Date, Map, Set, Math, JSON, Promise, URL, URLSearchParams,
    setTimeout, clearTimeout, requestAnimationFrame: fn => setTimeout(fn, 0),
    CSS: { escape: s => String(s) },
    document,
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    I18n: { t: key => key, lang: () => "en" },
    Modal: { toast: () => {} },
    Clacky: {
      ext: { emit() {}, ui: { mountBuiltin() {} } },
      Preview: { open(rel) { previewOpens.push(rel); return true; } },
    },
    CodeEditor,
    fetch: async (url, options) => {
      fetches.push({ url: String(url), options });
      if (String(url).includes("/files")) {
        const entries = Object.keys(files).map(name => ({
          name, path: name, type: "file", size: files[name].length
        }));
        return { ok: true, status: 200, json: async () => ({ root: "/wd", entries }) };
      }
      const body = options && options.body ? JSON.parse(options.body) : {};
      if (body.action === "download") {
        const filePath = body.path.replace(/^\/wd\//, "");
        return { ok: true, status: 200, text: async () => files[filePath] || "" };
      }
      return { ok: true, status: 200, json: async () => ({ ok: true }) };
    },
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);

  ["features/workspace/store.js", "features/workspace/view.js"].forEach(file => {
    vm.runInContext(read(file), context);
  });

  const WorkspaceView = vm.runInContext("Clacky.WorkspaceView", context);
  const Workspace = vm.runInContext("Clacky.Workspace", context);
  Workspace.setSession({ id: "s1", working_dir: "/wd" });

  const container = new Element("div");
  document.body.appendChild(container);
  WorkspaceView.mount(container, {});

  return {
    WorkspaceView,
    Workspace,
    CodeEditor,
    container,
    files,
    fetches,
    previewOpens,
    updateDiskFile: (name, content) => { files[name] = content; },
    downloads: target => fetches.filter(f => {
      if (!f.options || !f.options.body) return false;
      const body = JSON.parse(f.options.body);
      return body.action === "download" && body.path === target;
    }),
  };
}

const settle = () => new Promise(r => setTimeout(r, 20));

async function testReopenRefetchesModifiedFile() {
  const env = boot({ "hello.rb": 'puts "old code"' });

  env.WorkspaceView.openFile("/wd/hello.rb");
  await settle();
  assert.equal(env.CodeEditor.calls.setContent.length, 0, "first open builds the editor from fetched text");

  env.updateDiskFile("hello.rb", 'puts "ai updated code"');
  env.WorkspaceView.openFile("/wd/hello.rb");
  await settle();

  assert.equal(env.downloads("/wd/hello.rb").length, 2, "reopening should refetch the file from disk");
  assert.deepEqual(
    env.CodeEditor.calls.setContent,
    ['puts "ai updated code"'],
    "the open editor receives the new disk content"
  );
}

async function testTaskCompletedRefreshesOpenTabs() {
  const env = boot({ "app.py": "def foo(): pass" });
  env.WorkspaceView.openFile("/wd/app.py");
  await settle();

  env.updateDiskFile("app.py", "def foo(): return 42");
  env.Workspace.notifyTaskCompleted("s1");
  await settle();

  assert.equal(env.downloads("/wd/app.py").length, 2, "task completion should refetch the open tab");
  assert.deepEqual(env.CodeEditor.calls.setContent, ["def foo(): return 42"]);
}

async function testDirtyTabIsNotOverwritten() {
  const env = boot({ "notes.md": "# old" });
  env.WorkspaceView.openFile("/wd/notes.md");
  await settle();

  // The user is typing: this is exactly what the editor onChange callback does.
  assert.equal(typeof env.CodeEditor.calls.onChange, "function", "editor should wire onChange");
  env.CodeEditor.calls.onChange("# unsaved");

  env.updateDiskFile("notes.md", "# from ai");
  const before = env.downloads("/wd/notes.md").length;
  env.Workspace.notifyTaskCompleted("s1");
  await settle();

  assert.equal(env.downloads("/wd/notes.md").length, before, "dirty tabs must not be refetched");
  assert.equal(env.CodeEditor.calls.setContent.length, 0, "dirty tabs must keep the user's text");
}

// CodeEditor.setContent() must not surface as a user edit.
function testSetContentIsSilent() {
  const listeners = [];
  const CM = {
    EditorView: class {
      static updateListener = { of: cb => ({ __updateListener: cb }) };
      static lineWrapping = {};
      constructor({ state }) {
        this.state = state;
        this._listeners = (state.extensions || []).filter(e => e && e.__updateListener);
      }
      dispatch({ changes }) {
        if (!changes) return;
        this.state.doc = {
          toString: () => changes.insert,
          length: changes.insert.length,
        };
        this._listeners.forEach(ext => ext.__updateListener({ docChanged: true, state: this.state }));
      }
      destroy() {}
    },
    EditorState: {
      create: ({ doc, extensions }) => ({
        doc: { toString: () => String(doc), length: String(doc).length },
        extensions: extensions || [],
      }),
      readOnly: { of: () => ({}) },
    },
    keymap: { of: () => ({}) },
    defaultKeymap: [], historyKeymap: [], searchKeymap: [], foldKeymap: [],
    indentWithTab: {}, defaultHighlightStyle: {},
  };
  const context = {
    console, Date, Map, Set, Math, JSON, String, Promise,
    setTimeout, clearTimeout,
    document: makeDocument(),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    I18n: { t: k => k, lang: () => "en" },
    CM: new Proxy(CM, { get: (t, p) => (p in t ? t[p] : () => ({})) }),
    hljs: undefined,
  };
  context.window = context;
  vm.createContext(context);
  vm.runInContext(read("components/code-editor.js"), context);
  const CodeEditor = vm.runInContext("CodeEditor", context);

  const editor = CodeEditor.createInline(new Element("div"), {
    content: "old",
    onChange: () => listeners.push("change"),
  });
  editor.setContent("new");
  assert.equal(editor.getContent(), "new");
  assert.deepEqual(listeners, [], "silent setContent must not fire onChange");

  // Same content is a no-op.
  editor.setContent("new");
  assert.equal(editor.getContent(), "new");
}

async function main() {
  await testReopenRefetchesModifiedFile();
  await testTaskCompletedRefreshesOpenTabs();
  await testDirtyTabIsNotOverwritten();
  await testClosingLastTabRevealsTree();
  testHtmlLinkKeepsOriginalPath();
  testSetContentIsSilent();
  console.log("All workspace file reload tests passed!");
}

// Clicking a file:// link in chat must hand the preview panel the original
// absolute path. The panel maps it onto /preview/f, which keeps the address
// bar showing the file's real location instead of the session-relative
// /preview/s form.
function testHtmlLinkKeepsOriginalPath() {
  const env = boot({});
  env.WorkspaceView.openFile("/wd/moxia-landing/index.html");
  assert.deepEqual(
    env.previewOpens,
    ["file:///wd/moxia-landing/index.html"],
    "HTML links keep their file:// path"
  );
}

// Closing the last file tab must bring the tree back: with the strip empty it
// is the only content in the panel, and the toggle button that hid it lives in
// the (now hidden) viewer.
async function testClosingLastTabRevealsTree() {
  const env = boot({ "notes.md": "# hi" });
  await settle();

  const root = env.container.querySelector(".wv-root");
  const toggle = env.container.querySelector(".wv-toggle-tree");
  assert.ok(root, "root rendered");
  assert.ok(toggle, "tree toggle rendered");

  env.WorkspaceView.openFile("/wd/notes.md");
  await settle();
  assert.ok(!root.classList.contains("tree-hidden"), "tree starts visible");

  toggle.click();
  assert.ok(root.classList.contains("tree-hidden"), "toggle hides the tree");

  env.container.querySelector(".wv-tab-close").click();
  await settle();

  assert.ok(!root.classList.contains("tree-hidden"), "closing the last tab reveals the tree");
  assert.ok(!root.classList.contains("has-open-files"), "no tabs left");
  assert.ok(toggle.classList.contains("active"), "toggle reflects the visible tree");

  toggle.click();
  assert.ok(!root.classList.contains("tree-hidden"), "an empty strip never hides the tree");
}

main().catch(err => {
  console.error("Test failed:", err);
  process.exit(1);
});
