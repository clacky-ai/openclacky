"use strict";

// Regression harness for HintTip — the dismissible first-run hint bubble.
//
// The hint must appear once, survive a dismissal, and never be undone by the
// delayed reveal. It also has to stay hidden while its anchor has no box
// (e.g. the session bar is closed), otherwise it would point at nothing.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = path.resolve(__dirname, "../../lib/clacky/web/components/hint-tip.js");

class ClassList {
  constructor() { this.values = new Set(); }
  toggle(name, force) {
    if (force === undefined ? !this.values.has(name) : force) this.values.add(name);
    else this.values.delete(name);
  }
  contains(name) { return this.values.has(name); }
}

class Element {
  constructor(tag) {
    this.tagName = tag;
    this.style = {
      values: {},
      setProperty: (key, value) => { this.style.values[key] = value; },
      getPropertyValue: key => this.style.values[key] || "",
    };
    this.classList = new ClassList();
    this.listeners = {};
    this.children = [];
    this.attributes = {};
    this.textContent = "";
    this.innerHTML = "";
    this.removed = false;
    this.rect = { top: 0, bottom: 40, left: 0, width: 240, height: 40 };
  }
  set className(value) { this._class = value; }
  get className() { return this._class; }
  setAttribute(key, value) { this.attributes[key] = value; }
  getAttribute(key) { return this.attributes[key]; }
  addEventListener(type, fn) {
    (this.listeners[type] || (this.listeners[type] = [])).push(fn);
  }
  fire(type, event = {}) {
    (this.listeners[type] || []).forEach(fn => fn(event));
  }
  appendChild(child) { this.children.push(child); return child; }
  querySelector(selector) {
    return selector === ".hint-tip-close" ? this.children[1] : null;
  }
  getBoundingClientRect() { return this.rect; }
  remove() { this.removed = true; }
}

function boot({ dismissed = false, anchorRect = null } = {}) {
  const storage = new Map();
  if (dismissed) storage.set("clacky-model-tip-dismissed", "1");
  const timers = [];

  const anchor = new Element("span");
  anchor.rect = anchorRect || { top: 700, bottom: 720, left: 100, width: 200, height: 20 };

  const body = new Element("body");
  const created = [];

  const document = {
    getElementById: id => (id === "sib-model" ? anchor : null),
    createElement: tag => { const el = new Element(tag); created.push(el); return el; },
    body,
    addEventListener() {},
    removeEventListener() {},
  };

  const context = vm.createContext({
    console,
    document,
    window: {
      innerWidth: 1200,
      innerHeight: 800,
      addEventListener() {},
      removeEventListener() {},
    },
    localStorage: {
      getItem: key => (storage.has(key) ? storage.get(key) : null),
      setItem: (key, value) => storage.set(key, value),
    },
    setTimeout: fn => { timers.push(fn); return timers.length; },
    clearTimeout() {},
    I18n: { t: key => `t:${key}` },
  });

  vm.runInContext(fs.readFileSync(sourcePath, "utf8"), context, { filename: sourcePath });
  const HintTip = vm.runInContext("HintTip", context);

  const mount = extra => HintTip.attach(Object.assign({
    anchor: "sib-model",
    i18nKey: "sib.model.tip",
    storageKey: "clacky-model-tip-dismissed",
    delay: 1200,
  }, extra));

  return {
    anchor,
    body,
    storage,
    created,
    mount,
    reveal() { timers.splice(0).forEach(fn => fn()); },
  };
}

const tests = [
  ["reveals the hint once the delay has elapsed", () => {
    const app = boot();
    const tip = app.mount();
    assert.equal(app.body.children.length, 1, "portalled to body");
    assert.equal(tip === null, false);
    assert.equal(app.created[0].style.display, "none", "hidden until the delay");
    app.reveal();
    assert.equal(app.created[0].style.display, "flex");
  }],

  ["places the bubble above the anchor, with the tail centred on it", () => {
    const app = boot();
    app.mount();
    app.reveal();
    const tip = app.created[0];
    const top = parseFloat(tip.style.top);
    const bottom = top + tip.getBoundingClientRect().height;
    assert.ok(bottom <= 700, `bubble sits above the anchor (bottom=${bottom})`);
    assert.equal(tip.style.getPropertyValue("--hint-tip-arrow-left"), "120px");
    assert.equal(tip.classList.contains("hint-tip--above"), true);
  }],

  ["arrowAlign start parks the tail near the leading corner", () => {
    const app = boot();
    app.mount({ arrowAlign: "start" });
    app.reveal();
    const tip = app.created[0];
    assert.equal(tip.style.getPropertyValue("--hint-tip-arrow-left"), "12px");
  }],

  ["align start pins the bubble to the anchor's leading edge", () => {
    const app = boot();
    app.mount({ align: "start" });
    app.reveal();
    assert.equal(app.created[0].style.left, "108px");
  }],

  ["stays invisible while the anchor has no box", () => {
    const app = boot({ anchorRect: { top: 0, bottom: 0, left: 0, width: 0, height: 0 } });
    app.mount();
    app.reveal();
    assert.equal(app.created[0].style.visibility, "hidden");
  }],

  ["close button removes the hint and remembers the dismissal", () => {
    const app = boot();
    app.mount();
    app.reveal();
    const tip = app.created[0];
    tip.querySelector(".hint-tip-close").fire("click", { stopPropagation() {} });
    assert.equal(tip.removed, true);
    assert.equal(app.storage.get("clacky-model-tip-dismissed"), "1");
  }],

  ["acting on the anchor retires the hint", () => {
    const app = boot();
    app.mount();
    app.reveal();
    app.anchor.fire("click");
    assert.equal(app.created[0].removed, true);
    assert.equal(app.storage.get("clacky-model-tip-dismissed"), "1");
  }],

  ["a dismissal before the delay is not undone by the reveal", () => {
    const app = boot();
    app.mount();
    app.created[0].querySelector(".hint-tip-close").fire("click", { stopPropagation() {} });
    app.reveal();
    assert.equal(app.created[0].style.display, "none");
  }],

  ["an already dismissed hint is never attached", () => {
    const app = boot({ dismissed: true });
    assert.equal(app.mount(), null);
    assert.equal(app.body.children.length, 0);
  }],
];

try {
  tests.forEach(([name, run]) => {
    run();
    console.log(`  ok — ${name}`);
  });
  console.log("hint tip: ok");
} catch (err) {
  console.error(err);
  process.exit(1);
}
