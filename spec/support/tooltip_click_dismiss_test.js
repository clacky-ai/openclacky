"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../../lib/clacky/web/utils.js"), "utf8");
const start = source.indexOf("const Tooltip = (() => {");
const end = source.indexOf("})();", start) + "})();".length;
assert.ok(start >= 0, "Tooltip module not found in utils.js");

class Node {
  constructor(attrs = {}) {
    this.attributes = { ...attrs };
    this.parent = null;
    this.children = [];
  }
  append(child) { child.parent = this; this.children.push(child); return child; }
  getAttribute(name) { return name in this.attributes ? this.attributes[name] : null; }
  hasAttribute(name) { return name in this.attributes; }
  closest(selector) {
    const attr = selector.slice(1, -1);
    for (let n = this; n; n = n.parent) if (n.hasAttribute && n.hasAttribute(attr)) return n;
    return null;
  }
  contains(other) {
    for (let n = other; n; n = n.parent) if (n === this) return true;
    return false;
  }
  getBoundingClientRect() { return { top: 100, bottom: 120, left: 10, right: 60, width: 50, height: 20 }; }
}

const tip = {
  style: {},
  textContent: "",
  offsetWidth: 80,
  offsetHeight: 20,
  classes: new Set(),
  setAttribute() {},
};
tip.classList = { add: c => tip.classes.add(c), remove: c => tip.classes.delete(c) };

const listeners = {};
const document = {
  getElementById: id => (id === "tooltip" ? tip : null),
  addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn); },
};

const sandbox = {
  document,
  window: { innerWidth: 1000, innerHeight: 800 },
  requestAnimationFrame: fn => fn(),
  setTimeout: fn => { fn(); return 0; },
  clearTimeout: () => {},
};
vm.createContext(sandbox);
vm.runInContext(`${source.slice(start, end)}\nthis.Tooltip = Tooltip;`, sandbox);
sandbox.Tooltip.init();

const fire = (type, target, relatedTarget = null) =>
  (listeners[type] || []).forEach(fn => fn({ target, relatedTarget }));
const visible = () => tip.classes.has("visible");

const body = new Node();
const pill = body.append(new Node({ "data-tooltip": "Click to switch model" }));
const icon = pill.append(new Node());
const label = pill.append(new Node());
const other = body.append(new Node({ "data-tooltip": "Other" }));

fire("mouseover", icon);
assert.equal(visible(), true, "hover shows the tooltip");

fire("pointerdown", icon);
assert.equal(visible(), false, "pressing the anchor hides the tooltip");

fire("mouseout", icon, label);
fire("mouseover", label);
assert.equal(visible(), false, "moving between children of a clicked anchor keeps it hidden");

fire("mouseout", label, body);
fire("mouseover", pill);
assert.equal(visible(), true, "the tooltip returns after the pointer leaves and re-enters");

fire("pointerdown", icon);
fire("mouseout", icon, other);
fire("mouseover", other);
assert.equal(visible(), true, "other anchors are not suppressed by an earlier click");

fire("pointerdown", body);
assert.equal(visible(), false, "pressing anywhere hides the tooltip");

console.log("tooltip click dismiss ok");
