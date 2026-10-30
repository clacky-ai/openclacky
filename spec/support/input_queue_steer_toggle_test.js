"use strict";

// Regression harness for the guidance toggle on queued messages.
//
// Clicking "guide" (→) converts a queued message into guidance for the running
// task. That used to be a one-way door: the button was disabled as soon as
// delivery became "steer", so a mis-click could only be undone by deleting the
// message and re-sending it — which pushes it to the back of the queue and
// shuffles the order the user intended.
//
// The real ws-dispatcher.js renders the queue panel against a DOM stub, so the
// assertions cover what the user actually sees and what the click puts on the
// wire.

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
    this.classes = new Set();
    this._className = "";
    this.textContent = "";
    this.innerHTML = "";
    this.hidden = false;
    this.disabled = false;
    this.classList = {
      add: n => this.classes.add(n),
      remove: n => this.classes.delete(n),
      toggle: (n, on) => (on ? this.classes.add(n) : this.classes.delete(n)),
      contains: n => this.classes.has(n),
    };
  }
  set className(v) { this._className = v; this.classes = new Set(v.split(/\s+/).filter(Boolean)); }
  get className() { return this._className; }
  setAttribute(k, v) { this.attrs[k] = v; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(k, fn) { this.handlers[k] = fn; }
  removeEventListener() {}
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  append(...kids) { kids.forEach(k => this.appendChild(k)); }
  prepend(child) { this.children.unshift(child); return child; }
  remove() {}
  replaceChildren(...kids) { this.children = kids; }
  replaceWith() {}
  insertBefore(child) { this.children.unshift(child); return child; }
  querySelector() { return new Element(); }
  querySelectorAll() { return []; }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  contains() { return false; }
  closest() { return null; }
  focus() {}
}

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
    Composer: autoStub({ text: () => "", chips: () => [] }),
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
  Sessions._setActiveId("s");
  const panel = document.getElementById("input-queue");
  // WS payloads are built inside the vm realm, so their prototype differs from
  // the host's: compare them as plain data rather than by identity.
  const wire = () => JSON.parse(JSON.stringify(sent));
  return { panel, wire, dispatch: context.__dispatcher };
}

// actions.append(edit, guide, sendNow, remove) — the toggle is the 2nd action.
const guideButton = (panel, index = 0) => panel.children[index].children[1].children[1];
const statusOf = (panel, index = 0) => panel.children[index].children[0].children[0].textContent;

const entry = (extra = {}) => Object.assign({
  id: "p1", content: "test", delivery: "queue", steer_target: 7, options: {},
}, extra);

const render = (dispatch, entries) =>
  dispatch({ type: "input_queue", session_id: "s", entries: entries });

function tests() {
  // 1. The reported bug: an entry already accepted as guidance must still offer
  //    a way back, and the click must ask the backend to undo the conversion.
  {
    const { panel, wire, dispatch } = boot();
    render(dispatch, [entry({ delivery: "steer" })]);
    const guide = guideButton(panel);

    assert.equal(guide.disabled, false, "guidance can be cancelled");
    assert.equal(guide.attrs["aria-label"], "chat.input.cancelSteerMode");
    assert.equal(guide.title, "chat.input.cancelSteerDescription");
    assert.equal(statusOf(panel), "chat.input.guidancePending");

    guide.handlers.click ? guide.handlers.click() : guide.onclick();
    assert.deepEqual(wire(), [{ type: "unsteer_pending_input", session_id: "s", id: "p1" }],
      "cancelling does not delete or re-send the message");
  }

  // 2. A plain queued entry keeps the forward conversion, carrying the task id
  //    so a stale client cannot steer a successor task.
  {
    const { panel, wire, dispatch } = boot();
    render(dispatch, [entry()]);
    const guide = guideButton(panel);

    assert.equal(guide.disabled, false);
    assert.equal(guide.attrs["aria-label"], "chat.input.steerMode");
    assert.equal(guide.title, "chat.input.steerDescription");

    guide.onclick();
    assert.deepEqual(wire(), [{ type: "steer_pending_input", session_id: "s", id: "p1", task_id: 7 }]);
  }

  // 3. Starting guidance stays gated: no open window, or a slash command that
  //    keeps run-level dispatch.
  {
    const { panel, dispatch } = boot();
    render(dispatch, [entry({ steer_target: null }), entry({ id: "p2", content: "/commit" })]);

    assert.equal(guideButton(panel, 0).disabled, true, "closed window blocks new guidance");
    assert.equal(guideButton(panel, 0).title, "chat.input.guidanceClosed");
    assert.equal(guideButton(panel, 1).disabled, true, "slash commands are never steered");
  }

  // 4. Cancelling must stay reachable once the task stopped accepting guidance:
  //    that is exactly when being stuck in the steer state hurts most.
  {
    const { panel, wire, dispatch } = boot();
    render(dispatch, [entry({ delivery: "steer", steer_target: null })]);
    const guide = guideButton(panel);

    assert.equal(guide.disabled, false, "a closed window still allows withdrawal");
    guide.onclick();
    assert.deepEqual(wire(), [{ type: "unsteer_pending_input", session_id: "s", id: "p1" }]);
  }

  // 5. Each row toggles independently, and the queue order is untouched.
  {
    const { panel, wire, dispatch } = boot();
    render(dispatch, [
      entry({ id: "a" }),
      entry({ id: "b", delivery: "steer" }),
      entry({ id: "c" }),
    ]);

    assert.equal(panel.children.length, 3);
    assert.equal(guideButton(panel, 1).attrs["aria-label"], "chat.input.cancelSteerMode");
    assert.equal(guideButton(panel, 0).attrs["aria-label"], "chat.input.steerMode");
    assert.equal(guideButton(panel, 2).attrs["aria-label"], "chat.input.steerMode");

    guideButton(panel, 1).onclick();
    assert.deepEqual(wire(), [{ type: "unsteer_pending_input", session_id: "s", id: "b" }]);
  }

  // 6. The optimistic disable still applies, so a double click cannot send the
  //    same withdrawal twice before the fresh snapshot arrives.
  {
    const { panel, wire, dispatch } = boot();
    render(dispatch, [entry({ delivery: "steer" })]);
    const guide = guideButton(panel);

    guide.onclick();
    assert.equal(guide.disabled, true, "button is disabled until the snapshot returns");
    assert.equal(wire().length, 1);
  }
}

tests();
console.log("input_queue_steer_toggle_test: ok");
