"use strict";

// Regression harness for "add to chat" in the Files tab (C-5804 follow-up).
//
// Right-clicking a file in the tree must offer adding it to the conversation.
// Clicking it stages the file in the composer as an attachment — carrying the
// absolute path, not an /api/upload copy — and focuses the message input, so
// the user can type and send right away.
//
// The real view.js and sessions.js run against a DOM stub; only I/O is faked.

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

const TREE = {
  "": [
    { name: "src", path: "src", type: "dir" },
    { name: "report.docx", path: "report.docx", type: "file", size: 1200 },
    { name: "cover.png", path: "cover.png", type: "file", size: 2048 },
  ],
};

function boot() {
  const fetches = [];
  const dragged = [];
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

  const sent = [];
  const context = {
    console, Date, Map, Set, Math, JSON, Promise, URL, URLSearchParams,
    setTimeout: (fn, ms, ...args) => {
      const timer = setTimeout(fn, ms, ...args);
      if (timer.unref) timer.unref();
      return timer;
    },
    clearTimeout,
    requestAnimationFrame: fn => setTimeout(fn, 0),
    CSS: { escape: s => String(s) },
    navigator: { platform: "MacIntel", clipboard: { writeText: async () => {} } },
    document,
    fetch: async (url) => {
      fetches.push({ url: String(url) });
      if (String(url).includes("/files")) {
        const rel = new URL(String(url), "http://localhost").searchParams.get("path") || "";
        return { ok: true, status: 200, json: async () => ({ root: "/wd", entries: TREE[rel] || [] }) };
      }
      return { ok: true, status: 200, json: async () => ({ ok: true }) };
    },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    I18n: { t: key => key, lang: () => "en" },
    Modal: { toast() {} },
    Clacky: { ext: { emit() {}, ui: { mountBuiltin() {} } } },
    WS: { ready: true, onEvent() {}, setSubscribedSession() {}, send: msg => sent.push(msg) },
    $: id => document.getElementById(id),
    escapeHtml: s => String(s === undefined || s === null ? "" : s),
    Router: autoStub(),
    Projects: autoStub(),
    Tasks: autoStub(),
    Skills: autoStub(),
    SkillAC: autoStub({ renderUserMessageHtml: s => s }),
    Composer: autoStub({
      text: () => "follow-up",
      chips: () => [],
      clear() {},
      focus() {},
      beginWorkspaceFileDrag(dataTransfer, file) {
        dragged.push(file);
        dataTransfer.effectAllowed = "copy";
        return true;
      },
    }),
    IME: autoStub({ track: () => ({ isComposing: () => false, dispose() {} }) }),
    alert() {},
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);

  ["utils.js", "sessions.js", "ws-dispatcher.js", "features/workspace/store.js", "components/code-editor.js", "features/workspace/view.js"]
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
  const opened = [];
  WorkspaceView.openFile = filePath => { opened.push(filePath); return true; };

  return {
    Sessions,
    WorkspaceView,
    document,
    container,
    fetches,
    sent,
    dragged,
    opened,
    input: document.getElementById("user-input"),
    tree: container.querySelector(".wt-tree"),
  };
}

const settle = async (times = 3) => {
  for (let i = 0; i < times; i++) await new Promise(resolve => setTimeout(resolve, 0));
};

// Payloads are built inside the vm realm; re-create them here so deep
// comparisons do not trip over a foreign Object.prototype.
const plain = value => JSON.parse(JSON.stringify(value));

const row = (w, relPath) => w.tree.querySelector(`.wt-row[data-path="${relPath}"]`);

const previewStrip = w => w.document.getElementById("image-preview-strip");

const stripIconHtml = w => previewStrip(w).querySelector(".pdf-preview-icon").innerHTML;

// Open the row's context menu and return it, as the DOM would after a real
// right-click (clientX/Y only position the menu).
function openMenu(w, entry) {
  row(w, entry).handlers.contextmenu({ preventDefault() {}, clientX: 10, clientY: 10 });
  return w.document.body.querySelector(".wt-context-menu");
}

async function clickMenu(w, menu, action, entry) {
  const item = menu.querySelector(`[data-action="${action}"]`);
  assert.ok(item, `the ${action} item is in the menu for ${entry}`);
  await menu.handlers.click({ target: item });
}

async function tests() {
  // 1. A file can be staged into the composer and travels with the message as
  //    an absolute path — no upload round-trip.
  {
    const w = boot();
    await settle();

    const menu = openMenu(w, "report.docx");
    await clickMenu(w, menu, "addtochat", "report.docx");

    assert.equal(w.input.focusCount, 1, "the message input is focused");

    assert.equal(stripIconHtml(w), w.WorkspaceView.fileIcon("report.docx"), "the chip reuses the file-tree icon");

    previewStrip(w).querySelector(".pdf-preview-open").click();
    assert.deepEqual(w.opened, ["/wd/report.docx"], "the pending card opens in the Files viewer");

    await w.Sessions.sendMessage();

    const msg = w.sent.find(m => m.type === "message");
    assert.deepEqual(plain(msg.files), [{ name: "report.docx", path: "/wd/report.docx", mime_type: "" }],
      "the staged file goes out with the message, by absolute path");
    assert.equal(w.fetches.filter(f => /upload|file-action|download/.test(f.url)).length, 0,
      "nothing is uploaded or copied");
  }

  // 2. Dragging a file exposes the same absolute path-backed attachment data
  //    as the context-menu action; folders remain ordinary tree controls.
  {
    const w = boot();
    await settle();

    const fileRow = row(w, "report.docx");
    const dirRow = row(w, "src");
    assert.equal(fileRow.draggable, true, "files are draggable");
    assert.notEqual(dirRow.draggable, true, "directories are not draggable attachments");

    const dataTransfer = { effectAllowed: "none" };
    fileRow.handlers.dragstart({ dataTransfer, preventDefault() { assert.fail("valid file drag was cancelled"); } });
    assert.equal(dataTransfer.effectAllowed, "copy");
    assert.deepEqual(plain(w.dragged), [{
      type: "file",
      name: "report.docx",
      path: "/wd/report.docx",
      size: 1200,
    }]);
  }

  // 3. Images need a MIME type: without one the model never sees the picture.
  {
    const w = boot();
    await settle();

    await clickMenu(w, openMenu(w, "cover.png"), "addtochat", "cover.png");

    // Workspace images look and behave like image attachments while retaining
    // their original path in the outgoing payload.
    const thumbnail = previewStrip(w).querySelector(".img-preview-thumb");
    assert.ok(thumbnail, "a workspace image renders as a thumbnail");
    assert.equal(thumbnail.src, "/api/local-image?path=%2Fwd%2Fcover.png");

    await w.Sessions.sendMessage();

    const msg = w.sent.find(m => m.type === "message");
    assert.deepEqual(plain(msg.files), [{ name: "cover.png", path: "/wd/cover.png", mime_type: "image/png" }],
      "the image keeps its type so the vision pipeline picks it up");
  }

  // 4. Only files: a folder has nothing to attach.
  {
    const w = boot();
    await settle();

    const menu = openMenu(w, "src");
    assert.equal(menu.querySelector('[data-action="addtochat"]'), null, "folders have no add-to-chat item");
    assert.ok(menu.querySelector('[data-action="reveal"]'), "the rest of the menu is untouched");
  }
}

tests().then(
  () => console.log("workspace_add_to_chat_test: ok"),
  err => { console.error(err); process.exit(1); }
);
