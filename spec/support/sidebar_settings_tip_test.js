"use strict";

// Regression harness for the first-run hint above the sidebar Settings entry.
//
// The hint must survive a reload only until it is dismissed, and dismissing it
// (via the × or by opening Settings) has to win over the delayed reveal — a
// user who clicks early must not see it pop back a second later.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = path.resolve(__dirname, "../../lib/clacky/web/components/sidebar.js");

class Element {
  constructor(id) {
    this.id = id;
    this.style = {};
    this.listeners = {};
  }
  addEventListener(type, fn) {
    (this.listeners[type] || (this.listeners[type] = [])).push(fn);
  }
  fire(type, event = {}) {
    (this.listeners[type] || []).forEach(fn => fn(event));
  }
}

function boot({ dismissed = false } = {}) {
  const nodes = {};
  const storage = new Map();
  if (dismissed) storage.set("clacky-settings-tip-dismissed", "1");
  const timers = [];

  const document = {
    getElementById: id => nodes[id] || (nodes[id] = new Element(id)),
    querySelectorAll: () => [],
  };
  // Mirror the inline `style="display:none"` the markup ships with.
  document.getElementById("settings-tip").style.display = "none";

  const context = vm.createContext({
    console,
    document,
    localStorage: {
      getItem: key => (storage.has(key) ? storage.get(key) : null),
      setItem: (key, value) => storage.set(key, value),
    },
    setTimeout: fn => { timers.push(fn); return timers.length; },
    Router: { current: "welcome", navigate() {} },
  });

  vm.runInContext(fs.readFileSync(sourcePath, "utf8"), context, { filename: sourcePath });
  // Top-level `const` in a vm script lives in the global lexical scope, not on
  // the context object, so read it back by evaluating the identifier.
  const Sidebar = vm.runInContext("Sidebar", context);
  Sidebar.init();

  return {
    tip: document.getElementById("settings-tip"),
    close: document.getElementById("settings-tip-close"),
    button: document.getElementById("btn-settings"),
    storage,
    reveal() { timers.splice(0).forEach(fn => fn()); },
  };
}

const tests = [
  ["reveals the hint when it was never dismissed", () => {
    const app = boot();
    assert.equal(app.tip.style.display, "none", "hidden until the delay elapses");
    app.reveal();
    assert.equal(app.tip.style.display, "flex");
  }],

  ["close button hides the hint and remembers it", () => {
    const app = boot();
    app.reveal();
    app.close.fire("click", { stopPropagation() {} });
    assert.equal(app.tip.style.display, "none");
    assert.equal(app.storage.get("clacky-settings-tip-dismissed"), "1");
  }],

  ["close click does not bubble into the Settings button", () => {
    const app = boot();
    app.reveal();
    let stopped = false;
    app.close.fire("click", { stopPropagation() { stopped = true; } });
    assert.equal(stopped, true);
  }],

  ["opening Settings retires the hint", () => {
    const app = boot();
    app.reveal();
    app.button.fire("click");
    assert.equal(app.tip.style.display, "none");
    assert.equal(app.storage.get("clacky-settings-tip-dismissed"), "1");
  }],

  ["a dismissal before the delay is not undone by the reveal", () => {
    const app = boot();
    app.close.fire("click", { stopPropagation() {} });
    app.reveal();
    assert.equal(app.tip.style.display, "none");
  }],

  ["a dismissed hint never appears again", () => {
    const app = boot({ dismissed: true });
    app.reveal();
    assert.equal(app.tip.style.display, "none", "dismissed hint stays hidden");
  }],
];

try {
  tests.forEach(([name, run]) => {
    run();
    console.log(`  ok — ${name}`);
  });
  console.log("sidebar settings tip: ok");
} catch (err) {
  console.error(err);
  process.exit(1);
}
