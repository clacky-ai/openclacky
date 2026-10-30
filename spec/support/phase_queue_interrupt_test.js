"use strict";

// Regression harness for C-5804: sending a message while a subagent phase is
// running must not mark that phase "(interrupted)" on its own. Whether the
// task is actually interrupted is decided by the backend (queue vs interrupt),
// so only a real `interrupted` event may finalize the card as incomplete.
//
// The real sessions.js + ws-dispatcher.js run against a minimal DOM stub.

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
    this.parentNode = null;
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
  // Phase summaries are built from flat <span class="..">text</span> markup;
  // materialize those spans so status updates can be observed.
  set innerHTML(v) {
    this._innerHTML = v;
    this.children = [];
    for (const m of String(v).matchAll(/<span class="([^"]+)">([^<]*)<\/span>/g)) {
      const span = new Element("span");
      span.className = m[1];
      span.textContent = m[2];
      this.appendChild(span);
    }
  }
  get innerHTML() { return this._innerHTML; }
  setAttribute(k, v) { this.attrs[k] = v; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener() {}
  removeEventListener() {}
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  append(...kids) { kids.forEach(k => this.appendChild(k)); }
  prepend(child) { this.children.unshift(child); child.parentNode = this; return child; }
  remove() {
    if (!this.parentNode) return;
    this.parentNode.children = this.parentNode.children.filter(c => c !== this);
    this.parentNode = null;
  }
  replaceChildren(...kids) { this.children = []; this.append(...kids); }
  insertBefore(child) { return this.prepend(child); }
  _all(cls, out = []) {
    this.children.forEach(c => {
      if (c.classes && c.classes.has(cls)) out.push(c);
      if (c._all) c._all(cls, out);
    });
    return out;
  }
  querySelector(sel) { return sel.startsWith(".") ? (this._all(sel.slice(1))[0] || null) : null; }
  querySelectorAll(sel) { return sel.startsWith(".") ? this._all(sel.slice(1)) : []; }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  contains() { return false; }
  closest() { return null; }
  focus() {}
}

const SID = "s1";

function boot() {
  const nodes = {};
  const unrefTimeout = (fn, ms, ...args) => {
    const timer = setTimeout(fn, ms, ...args);
    if (timer.unref) timer.unref();
    return timer;
  };
  const document = {
    createElement: tag => new Element(tag),
    createDocumentFragment: () => new Element("fragment"),
    createTextNode: text => ({ nodeType: 3, textContent: text }),
    getElementById: id => nodes[id] || (nodes[id] = new Element()),
    addEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => [],
    body: new Element(),
  };

  const sent = [];
  const context = {
    console, Date, Map, Set, Math, JSON, Promise, URLSearchParams,
    setTimeout: unrefTimeout,
    clearTimeout,
    document,
    fetch: async () => ({ ok: false, json: async () => ({}) }),
    I18n: { t: key => key, lang: () => "en" },
    WS: {
      ready: true,
      onEvent: fn => { context.__dispatcher = fn; },
      setSubscribedSession() {},
      send: msg => sent.push(msg),
    },
    Clacky: {},
    $: id => document.getElementById(id),
    escapeHtml: s => String(s === undefined || s === null ? "" : s),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    Router: autoStub(),
    Projects: autoStub(),
    Tasks: autoStub(),
    Skills: autoStub(),
    SkillAC: autoStub({ renderUserMessageHtml: s => s }),
    Composer: autoStub({ text: () => "follow-up", chips: () => [] }),
    IME: autoStub({ track: () => ({ isComposing: () => false, dispose() {} }) }),
    alert() {},
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);

  vm.runInContext(fs.readFileSync(sourcePath("utils.js"), "utf8"), context);
  vm.runInContext(fs.readFileSync(sourcePath("sessions.js"), "utf8"), context);
  vm.runInContext(fs.readFileSync(sourcePath("ws-dispatcher.js"), "utf8"), context);

  const Sessions = vm.runInContext("Clacky.Sessions", context);
  Sessions.setAll([{ id: SID, name: SID, status: "running", source: "manual",
                     created_at: "2026-09-01T00:00:00+08:00", updated_at: "2026-09-01T00:00:00+08:00" }]);
  Sessions._setActiveId(SID);
  const messages = document.getElementById("messages");
  const dispatch = context.__dispatcher;
  dispatch({ type: "phase_start", session_id: SID, phase_id: "p1", kind: "subagent", label: "worker" });
  const card = messages.children.find(c => c.classes.has("msg-phase"));
  assert.ok(card, "phase card is rendered");
  return { Sessions, messages, dispatch, card, sent };
}

const statusOf = card => card.querySelector(".msg-phase-status").textContent;
const userBubbles = messages => messages.children.filter(c => c.classes.has("msg-user-wrap"));

async function tests() {
  // 1. The reported bug: a message sent while the subagent runs gets queued by
  //    the backend. The card must stay open and running.
  {
    const { Sessions, messages, dispatch, card, sent } = boot();
    await Sessions.sendMessage();

    assert.equal(sent.filter(m => m.type === "message").length, 1, "message goes over the wire");
    assert.equal(statusOf(card), "…", "sending alone does not mark the phase interrupted");
    assert.equal(card.open, true, "running phase card stays expanded");
    assert.equal(userBubbles(messages).length, 1, "optimistic bubble renders in the outer stream");

    dispatch({ type: "input_enqueued", session_id: SID, created_at: 1 });
    assert.equal(userBubbles(messages).length, 0, "queued message retracts the optimistic bubble");
    assert.equal(statusOf(card), "…", "queueing keeps the phase running");
  }

  // 2. When the backend really interrupts, the card is still finalized.
  {
    const { Sessions, dispatch, card } = boot();
    await Sessions.sendMessage();
    dispatch({ type: "interrupted", session_id: SID, reason: "replacement" });

    assert.equal(statusOf(card), " (interrupted)", "a real interrupt marks the phase incomplete");
    assert.equal(card.open, false, "interrupted phase card collapses");
  }
}

tests().then(
  () => console.log("phase_queue_interrupt_test: ok"),
  err => { console.error(err); process.exit(1); }
);
