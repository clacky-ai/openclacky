"use strict";

// Regression harness: the sidebar quick "New session" button must ignore the
// /#new draft (name included) and leave that draft intact for the user.
//
// The real sessions.js + new-session/store.js run against a minimal DOM stub;
// the assertions inspect the POST /api/sessions payload and the store state.

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
    this.classList = { add() {}, remove() {}, toggle() {}, contains: () => false };
    this.innerHTML = "";
    this.textContent = "";
    this.value = "";
  }
  setAttribute(k, v) { this.attrs[k] = v; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(k, fn) { (this.handlers[k] ||= []).push(fn); }
  removeEventListener() {}
  appendChild(child) { this.children.push(child); return child; }
  append() {}
  prepend() {}
  remove() {}
  replaceChildren() {}
  insertBefore(child) { return child; }
  querySelector() { return new Element(); }
  querySelectorAll() { return []; }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  contains() { return false; }
  closest() { return null; }
  focus() {}
}

function boot() {
  const nodes = {};
  const posted = [];
  const unrefTimeout = (fn, ms, ...args) => {
    const timer = setTimeout(fn, ms, ...args);
    if (timer.unref) timer.unref();
    return timer;
  };
  const document = {
    createElement: tag => new Element(tag),
    createDocumentFragment: () => new Element("fragment"),
    getElementById: id => nodes[id] || (nodes[id] = new Element()),
    addEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => [],
    body: new Element(),
    documentElement: new Element(),
  };

  let seq = 0;
  const context = {
    console, Date, Map, Set, Math, JSON, Promise, URLSearchParams,
    setTimeout: unrefTimeout,
    clearTimeout,
    setInterval: () => 0,
    clearInterval() {},
    document,
    location: { hash: "" },
    fetch: async (url, opts = {}) => {
      if (url === "/api/sessions" && opts.method === "POST") {
        const body = JSON.parse(opts.body);
        posted.push(body);
        seq += 1;
        return { ok: true, json: async () => ({ session: { id: `s${seq}`, name: body.name, status: "idle", source: "manual" } }) };
      }
      return { ok: false, json: async () => ({}) };
    },
    I18n: { t: key => key, lang: () => "en" },
    WS: autoStub(),
    Clacky: {},
    $: id => document.getElementById(id),
    escapeHtml: s => String(s === undefined || s === null ? "" : s),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    Router: autoStub(),
    Projects: autoStub(),
    Tasks: autoStub(),
    Skills: autoStub(),
    Composer: autoStub({ text: () => "", chips: () => [] }),
    IME: autoStub({ track: () => ({ isComposing: () => false, dispose() {} }) }),
    alert() {},
  };
  context.window = context;
  context.globalThis = context;
  // init() touches many sibling modules; they resolve to stubs returning inert
  // elements since only the quick-create wiring matters here.
  const elementStub = () => new Proxy({}, { get: () => () => new Element() });
  for (const name of ["RenderTarget", "QuoteSelect"]) context[name] = elementStub();
  context.MutationObserver = class { observe() {} disconnect() {} };
  context.ResizeObserver = context.MutationObserver;
  context.IntersectionObserver = context.MutationObserver;
  context.addEventListener = () => {};
  vm.createContext(context);

  vm.runInContext(fs.readFileSync(sourcePath("utils.js"), "utf8"), context);
  vm.runInContext(fs.readFileSync(sourcePath("sessions.js"), "utf8"), context);
  vm.runInContext(fs.readFileSync(sourcePath("features/new-session/store.js"), "utf8"), context);

  const Sessions = vm.runInContext("Clacky.Sessions", context);
  const Store = vm.runInContext("NewSessionStore", context);
  Sessions.init();

  const quickButton = document.getElementById("btn-new-session-inline");
  const clickQuickNew = () => Promise.all((quickButton.handlers.click || []).map(fn => fn()));
  return { Store, posted, clickQuickNew, location: context.location };
}

async function tests() {
  // 1. A name typed on /#new and left unsubmitted must not leak into the quick-created session.
  {
    const { Store, posted, clickQuickNew, location } = boot();
    Store.updateAdvanced({ name: "test" });

    await clickQuickNew();

    assert.equal(posted.length, 1);
    assert.equal(posted[0].name, "Session 1");
    assert.equal(location.hash, "session/s1");
  }

  // 2. The /#new draft survives a quick create, so returning to /#new still shows it.
  {
    const { Store, clickQuickNew } = boot();
    Store.updateAdvanced({ name: "test" });

    await clickQuickNew();

    assert.equal(Store.state.advanced.name, "test");
  }

  // 3. Submitting from /#new still uses the typed name.
  {
    const { Store, posted } = boot();
    Store.updateAdvanced({ name: "test" });

    await Store.createSession({ existingSessions: [] });

    assert.equal(posted[0].name, "test");
  }
}

tests().then(
  () => console.log("new_session_quick_create_test: ok"),
  err => { console.error(err); process.exit(1); },
);
