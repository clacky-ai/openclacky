"use strict";

// Regression harness for composer text drafts surviving a page reload. The real
// sessions.js boots against a shared localStorage fake; a "reload" is simply
// booting it again over the same storage.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = name => path.resolve(__dirname, "../../lib/clacky/web", name);
const autoStub = (extra = {}) => new Proxy(extra, {
  get: (target, key) => (key in target ? target[key] : () => {}),
});

class Element {
  constructor() {
    this.style = { setProperty() {} };
    this.dataset = {};
    this.children = [];
    this.innerHTML = "";
    this.textContent = "";
    this.classList = { add() {}, remove() {}, toggle() {}, contains: () => false };
  }
  setAttribute() {}
  removeAttribute() {}
  addEventListener() {}
  appendChild(child) { this.children.push(child); return child; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  closest() { return null; }
  focus() {}
}

function fakeStorage(data = {}) {
  return {
    data,
    getItem: k => (k in data ? data[k] : null),
    setItem: (k, v) => { data[k] = String(v); },
    removeItem: k => { delete data[k]; },
  };
}

function boot(storage) {
  const nodes = {};
  const document = {
    createElement: () => new Element(),
    createDocumentFragment: () => new Element(),
    getElementById: id => nodes[id] || (nodes[id] = new Element()),
    addEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => [],
    body: new Element(),
  };
  const composer = { value: "" };
  const context = {
    console, Date, Map, Set, Math, JSON, Promise, Object, URLSearchParams,
    setTimeout: (fn, ms) => { const t = setTimeout(fn, ms); if (t.unref) t.unref(); return t; },
    clearTimeout,
    document,
    localStorage: storage,
    fetch: async () => ({ ok: false, json: async () => ({}) }),
    I18n: { t: key => key, lang: () => "en" },
    WS: { onEvent() {}, setSubscribedSession() {}, send() {} },
    Clacky: {},
    $: id => document.getElementById(id),
    escapeHtml: s => String(s == null ? "" : s),
    Router: autoStub(),
    Projects: autoStub(),
    Tasks: autoStub(),
    Skills: autoStub(),
    Composer: autoStub({
      text: () => composer.value,
      setText: (_el, v) => { composer.value = v; },
      chips: () => [],
    }),
    IME: autoStub({ track: () => ({ isComposing: () => false, dispose() {} }) }),
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(sourcePath("utils.js"), "utf8"), context);
  vm.runInContext(fs.readFileSync(sourcePath("sessions.js"), "utf8"), context);
  return { Sessions: vm.runInContext("Clacky.Sessions", context), composer };
}

// 1. Text typed into a session is still there after a reload.
{
  const storage = fakeStorage();
  const a = boot(storage);
  a.Sessions._setActiveId("s1");
  a.composer.value = "  a long prompt I do not want to retype  ";
  a.Sessions._cacheActiveAndDeselect();

  const b = boot(storage);
  b.Sessions._setActiveId("s1");
  assert.equal(b.composer.value, "a long prompt I do not want to retype");
  b.Sessions._setActiveId("s2");
  assert.equal(b.composer.value, "", "drafts stay per session");
}

// 2. An emptied composer and a deleted session leave nothing behind.
{
  const storage = fakeStorage();
  const a = boot(storage);
  a.Sessions.setDraft("s1", "keep");
  a.Sessions.setDraft("s2", "drop");
  a.Sessions.setDraft("s1", "   ");
  a.Sessions.remove("s2");
  assert.deepEqual(JSON.parse(storage.data.clacky_composer_drafts), {});
}

// 3. Corrupt or unavailable storage never breaks boot.
{
  const a = boot(fakeStorage({ clacky_composer_drafts: "{not json" }));
  a.Sessions._setActiveId("s1");
  assert.equal(a.composer.value, "");

  const full = fakeStorage();
  full.setItem = () => { throw new Error("QuotaExceededError"); };
  const b = boot(full);
  b.Sessions.setDraft("s1", "still in memory");
  b.Sessions._setActiveId("s1");
  assert.equal(b.composer.value, "still in memory");
}

console.log("composer_draft_persist_test: ok");
