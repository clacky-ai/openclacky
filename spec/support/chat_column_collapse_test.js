"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class Style {
  constructor() { this.transition = ""; this.values = {}; }
  setProperty(name, value) { this.values[name] = value; }
}

class Element {
  constructor(id = "") {
    this.id = id;
    this.title = "";
    this.attributes = {};
    this.style = new Style();
    this.children = [];
    this.parentNode = null;
    this.listeners = {};
    this.classes = new Set();
    this.rectWidth = 0;
    this.classList = {
      add: name => this.classes.add(name),
      remove: name => this.classes.delete(name),
      contains: name => this.classes.has(name),
      toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name),
    };
  }
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  removeAttribute(name) { delete this.attributes[name]; }
  get firstElementChild() { return this.children[0] || null; }
  get childElementCount() { return this.children.length; }
  getBoundingClientRect() {
    return { top: 0, bottom: 0, left: 0, right: this.rectWidth, width: this.rectWidth, height: 0 };
  }
  get scrollTop() { return 0; }
  set scrollTop(_value) {}
}

const LABELS = { "aside.collapse": "Collapse panel", "aside.expand": "Open panel" };

function boot(options = {}) {
  const ids = [
    "chat-panel", "session-aside", "session-aside-resize",
    "btn-aside-collapse", "btn-aside-open", "btn-aside-fullscreen",
    "workspace-overlay", "ext-slot-session-aside", "messages",
  ];
  const nodes = Object.fromEntries(ids.map(id => [id, new Element(id)]));
  nodes["ext-slot-session-aside"].appendChild(new Element("panel"));
  if (options.emptySlot) nodes["ext-slot-session-aside"].children = [];
  nodes["chat-panel"].rectWidth = options.panelWidth ?? 1200;

  const storage = new Map([
    ["clacky.aside.open", options.open === false ? "0" : "1"],
    ["clacky.aside.fullscreen", "0"],
  ]);
  const documentListeners = {};
  const document = {
    readyState: "complete",
    documentElement: new Element("html"),
    body: { style: {} },
    getElementById: id => nodes[id] || null,
    addEventListener(type, fn) { (documentListeners[type] ||= []).push(fn); },
  };
  const context = {
    console, Map, Math, Number,
    document,
    innerWidth: options.innerWidth ?? 1200,
    navigator: { platform: "MacIntel" },
    localStorage: {
      getItem: key => storage.has(key) ? storage.get(key) : null,
      setItem: (key, value) => storage.set(key, String(value)),
    },
    matchMedia: () => ({ matches: !!options.narrow }),
    getComputedStyle: element => ({
      fontSize: "16px",
      getPropertyValue: name => element.style.values[name] ||
        (name === "--session-aside-width" ? "256px" : ""),
    }),
    MutationObserver: class MutationObserver { observe() {} },
    requestAnimationFrame: fn => { fn(); return 1; },
    addEventListener() {},
    Clacky: { I18n: { t: key => LABELS[key] || key } },
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(
    path.resolve(__dirname, "../../lib/clacky/web/core/aside.js"),
    "utf8"
  ), context);

  const fire = (type, event) => (documentListeners[type] || []).forEach(fn => fn(event));
  const drag = (type, clientX) => ({
    clientX,
    preventDefault() {},
  });
  const onHandle = (type, clientX) => (nodes["session-aside-resize"].listeners[type] || [])
    .forEach(fn => fn(drag(type, clientX)));
  return {
    nodes, storage, fire, onHandle,
    collapsed: () => nodes["chat-panel"].classes.has("chat-collapsed"),
    width: () => parseInt(nodes["session-aside"].style.values["--session-aside-width"], 10),
  };
}

// Dragging the divider past the chat column's floor hands the workspace to
// the aside instead of squeezing the conversation into a strip.
{
  const ui = boot();
  assert.equal(ui.collapsed(), false);

  ui.onHandle("mousedown", 1000);
  ui.fire("mousemove", { clientX: 544 });
  assert.equal(ui.width(), 712);
  assert.equal(ui.collapsed(), false, "488px of chat is still a split");

  ui.fire("mousemove", { clientX: 200 });
  assert.equal(ui.width(), 960);
  assert.equal(ui.collapsed(), true, "chat below 300px collapses");

  // Pulling back past the threshold restores the split immediately.
  ui.fire("mouseup", { clientX: 200 });
  ui.onHandle("mousedown", 0);
  ui.fire("mousemove", { clientX: 40 });
  assert.equal(ui.width(), 920);
  assert.equal(ui.collapsed(), true, "920px still leaves under 300px");

  ui.fire("mousemove", { clientX: 260 });
  assert.equal(ui.width(), 700);
  assert.equal(ui.collapsed(), false, "500px of chat restores the split");
}

// A collapsed aside (or an agent with no aside panels) must never be turned
// into a full-width column by the collapse class.
{
  const closed = boot({ open: false });
  closed.onHandle("mousedown", 1000);
  closed.fire("mousemove", { clientX: 200 });
  assert.equal(closed.collapsed(), false);

  const empty = boot({ emptySlot: true });
  empty.onHandle("mousedown", 1000);
  empty.fire("mousemove", { clientX: 200 });
  assert.equal(empty.collapsed(), false);
}

// Narrow layouts render the aside as a fixed drawer, and a panel narrower
// than the floor itself must not lose its chat column.
{
  const narrow = boot({ narrow: true });
  narrow.onHandle("mousedown", 1000);
  narrow.fire("mousemove", { clientX: 200 });
  assert.equal(narrow.collapsed(), false);

  const small = boot({ panelWidth: 280 });
  small.onHandle("mousedown", 1000);
  small.fire("mousemove", { clientX: 200 });
  assert.equal(small.collapsed(), false);
}

console.log("chat column collapse tests passed");
