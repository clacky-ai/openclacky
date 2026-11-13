"use strict";

// Regression harness (C-5867): the folded-group entry (Extensions / Scheduled
// Tasks) must repaint its status dot when a session inside it finishes. Those
// background rows live in `_extraSessions`, which the sidebar list signature
// used to ignore — the signature matched, the list was kept, and the entry
// kept a stale running dot forever.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const read = name => fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web", name), "utf8");

const autoStub = (extra = {}) => new Proxy(extra, {
  get: (target, key) => (key in target ? target[key] : () => {}),
});

class Element {
  constructor(tag = "div") {
    this.tagName = tag;
    this.style = { setProperty() {} };
    this.dataset = {};
    this.children = [];
    this.handlers = {};
    this.classList = { add() {}, remove() {}, toggle() {}, contains: () => false };
    this.innerHTML = "";
    this.textContent = "";
    this.className = "";
    this.value = "";
    this._queried = {};
  }
  setAttribute() {}
  removeAttribute() {}
  addEventListener(k, fn) { this.handlers[k] = fn; }
  removeEventListener() {}
  appendChild(child) { this.children.push(child); return child; }
  append() {}
  prepend() {}
  remove() {}
  replaceChildren() {}
  insertBefore(child) { return child; }
  querySelector(sel) { return (this._queried[sel] ||= new Element()); }
  querySelectorAll() { return []; }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  contains() { return false; }
  closest() { return null; }
  focus() {}
}

function boot() {
  const elements = {};
  const document = {
    readyState: "complete",
    createElement: tag => new Element(tag),
    createDocumentFragment: () => new Element("fragment"),
    getElementById: id => (elements[id] ||= new Element()),
    addEventListener() {},
    removeEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => [],
    body: new Element(),
    documentElement: new Element(),
  };

  // A rebuild starts with `innerHTML = ""`; mirror that by clearing the stubbed
  // children so `renders()` counts real repaints. A signature short-circuit
  // must leave the DOM untouched.
  const listEl = document.getElementById("session-list");
  let html = "";
  let renders = 0;
  Object.defineProperty(listEl, "innerHTML", {
    get: () => html,
    set: value => {
      html = value;
      listEl.children.length = 0;
      renders += 1;
    },
  });

  const unrefTimeout = (fn, ms, ...args) => {
    const timer = setTimeout(fn, ms, ...args);
    if (timer.unref) timer.unref();
    return timer;
  };

  const context = {
    console, Date, Map, Set, Math, JSON, Promise, URLSearchParams,
    setTimeout: unrefTimeout,
    clearTimeout,
    setInterval: () => 0,
    clearInterval() {},
    document,
    location: { hash: "" },
    fetch: async () => ({ ok: true, json: async () => ({}) }),
    I18n: { t: (key, vars) => (vars ? `${key}|${JSON.stringify(vars)}` : key), lang: () => "en", applyAll() {} },
    Modal: autoStub({ confirm: async () => true, toast() {} }),
    WS: autoStub(),
    Clacky: {},
    $: id => document.getElementById(id),
    escapeHtml: s => String(s === undefined || s === null ? "" : s),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    Router: { current: "welcome", navigate() {} },
    NewSessionStore: { state: {}, updateAdvanced() {} },
    Projects: autoStub({ all: () => [], renderSection() {}, getIconSvg: () => "" }),
    Tasks: autoStub(),
    Skills: autoStub(),
    Composer: autoStub({ text: () => "", chips: () => [] }),
    IME: autoStub({ track: () => ({ isComposing: () => false, dispose() {} }) }),
    CustomSelect: { init() {} },
    alert() {},
  };
  context.window = context;
  context.globalThis = context;
  const elementStub = () => new Proxy({}, { get: () => () => new Element() });
  for (const name of ["RenderTarget", "QuoteSelect"]) context[name] = elementStub();
  context.MutationObserver = class { observe() {} disconnect() {} };
  context.ResizeObserver = context.MutationObserver;
  context.IntersectionObserver = context.MutationObserver;
  context.addEventListener = () => {};
  vm.createContext(context);

  for (const file of ["utils.js", "sessions.js"]) {
    vm.runInContext(read(file), context, { filename: file });
  }

  const get = name => vm.runInContext(name, context);
  return {
    Sessions: get("Sessions"),
    renders: () => renders,
    listChildren: () => listEl.children,
  };
}

const groupEntry = (h, source) => h.listChildren().find(el => String(el.className).includes(`group-item--${source}`));

// Status of the dot the entry renders: "running" | "awaiting_feedback" | "done" | null.
const dotOf = (h, source) => {
  const el = groupEntry(h, source);
  if (!el) return "missing";
  const m = String(el.innerHTML).match(/dot-([a-z_]+)/);
  return m ? m[1] : null;
};

function main() {
  const h = boot();
  const S = h.Sessions;
  S.setAll([], false,
    { cron: { count: 0, latest_updated_at: null }, ext: { count: 0, latest_updated_at: null } });

  // 1) A background ext session lights the entry …
  S.patch("E1", { status: "running", source: "ext", name: "E1" });
  S.renderList();
  assert.equal(dotOf(h, "ext"), "running", "a running background session lights the group entry");

  // … and the dot clears once it finishes. Regression: the signature ignored
  // `_extraSessions`, so nothing repainted and the dot stayed green.
  S.patch("E1", { status: "idle" });
  S.renderList();
  assert.equal(dotOf(h, "ext"), null, "the dot clears when every session in the group finished");

  // 2) An unchanged list still short-circuits — the dot must not cost a repaint.
  const steady = h.renders();
  S.renderList();
  assert.equal(h.renders(), steady, "an unchanged list keeps the existing DOM");

  // 3) Most urgent status wins inside the group.
  S.patch("E2", { status: "awaiting_feedback", source: "ext", name: "E2" });
  S.patch("E3", { status: "running", source: "ext", name: "E3" });
  S.renderList();
  assert.equal(dotOf(h, "ext"), "running", "running outranks awaiting_feedback");
  S.patch("E3", { status: "idle" });
  S.renderList();
  assert.equal(dotOf(h, "ext"), "awaiting_feedback", "a blocked session keeps the amber dot");
  S.patch("E2", { status: "idle" });
  S.renderList();
  assert.equal(dotOf(h, "ext"), null, "idle sessions render no dot");

  // 4) The transient done ring shows up and clears through the same signature.
  S.markDone("E1");
  S.renderList();
  assert.equal(dotOf(h, "ext"), "done", "a session finished elsewhere rings the entry");
  S.clearDone("E1");
  S.renderList();
  assert.equal(dotOf(h, "ext"), null, "opening the session clears the ring");

  // 5) A grouped session assigned to a project renders in the project section.
  S.patch("PE", { status: "running", source: "ext", project_id: "p1", name: "PE" });
  S.renderList();
  assert.equal(dotOf(h, "ext"), null, "project-assigned sessions never light the group entry");

  // 6) Grouped sessions that made it into the loaded page behave the same.
  S.add({ id: "E4", name: "E4", status: "running", source: "ext" });
  S.renderList();
  assert.equal(dotOf(h, "ext"), "running", "a loaded grouped session lights the entry");
  S.patch("E4", { status: "idle" });
  S.renderList();
  assert.equal(dotOf(h, "ext"), null, "and clears it once it finishes");

  // 7) Groups with no sessions render no entry at all.
  assert.equal(dotOf(h, "cron"), "missing", "an empty group has no entry");

  console.log("folded group status dot: ok");
}

main();
