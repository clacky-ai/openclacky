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
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  get scrollTop() { return 0; }
  set scrollTop(_value) {}
}

const LABELS = { "aside.collapse": "Collapse panel", "aside.expand": "Open panel" };

function boot(platform = "MacIntel") {
  const ids = [
    "chat-panel", "session-aside", "session-aside-resize",
    "btn-aside-collapse", "btn-aside-open", "btn-aside-fullscreen",
    "workspace-overlay", "ext-slot-session-aside", "messages",
  ];
  const nodes = Object.fromEntries(ids.map(id => [id, new Element(id)]));
  nodes["ext-slot-session-aside"].appendChild(new Element("panel"));

  const storage = new Map([
    ["clacky.aside.open", "1"],
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
    innerWidth: 1200,
    navigator: { platform },
    localStorage: {
      getItem: key => storage.has(key) ? storage.get(key) : null,
      setItem: (key, value) => storage.set(key, String(value)),
    },
    matchMedia: () => ({ matches: false }),
    getComputedStyle: element => ({
      fontSize: "16px",
      getPropertyValue: name => element.style.values[name] || (name === "--session-aside-width" ? "256px" : ""),
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
  return { context, nodes, storage, fire };
}

const shortcutEvent = (overrides = {}) => ({
  key: "l",
  code: "KeyL",
  metaKey: true,
  ctrlKey: false,
  altKey: false,
  shiftKey: false,
  prevented: false,
  preventDefault() { this.prevented = true; },
  ...overrides,
});

// Both chrome buttons advertise the shortcut in their tooltip, on mac and off.
{
  const mac = boot("MacIntel");
  assert.equal(mac.nodes["btn-aside-collapse"].attributes["data-tooltip"], "Collapse panel (⌘L)");
  assert.equal(mac.nodes["btn-aside-open"].attributes["data-tooltip"], "Open panel (⌘L)");

  const pc = boot("Win32");
  assert.equal(pc.nodes["btn-aside-collapse"].attributes["data-tooltip"], "Collapse panel (Ctrl+L)");
  assert.equal(pc.nodes["btn-aside-open"].attributes["data-tooltip"], "Open panel (Ctrl+L)");
}

// ⌘L toggles the column both ways and swallows the keystroke only when it acts.
{
  const { nodes, storage, fire } = boot();
  const close = shortcutEvent();
  fire("keydown", close);
  assert.equal(storage.get("clacky.aside.open"), "0", "closes an open panel");
  assert.equal(nodes["session-aside"].classes.has("collapsed"), true);
  assert.equal(close.prevented, true);

  fire("keydown", shortcutEvent({ key: "L", code: "KeyL", shiftKey: false }));
  assert.equal(storage.get("clacky.aside.open"), "1", "opens a collapsed panel");

  fire("keydown", shortcutEvent({ metaKey: false, ctrlKey: true }));
  assert.equal(storage.get("clacky.aside.open"), "0", "Ctrl+L works off mac");
}

// Where the browser keeps ⌘L for the address bar, ⌘\ still reaches the page.
{
  const { storage, fire } = boot();
  const event = shortcutEvent({ key: "\\", code: "Backslash" });
  fire("keydown", event);
  assert.equal(storage.get("clacky.aside.open"), "0", "backslash fallback toggles too");
  assert.equal(event.prevented, true);
}

// Unrelated strokes stay untouched: a bare "l" while typing, other keys, and
// Alt/Shift combos.
{
  const { storage, fire } = boot();
  const plain = shortcutEvent({ metaKey: false });
  fire("keydown", plain);
  assert.equal(storage.get("clacky.aside.open"), "1", "a bare l never toggles");
  assert.equal(plain.prevented, false);

  const otherKey = shortcutEvent({ key: "k", code: "KeyK" });
  fire("keydown", otherKey);
  assert.equal(storage.get("clacky.aside.open"), "1");

  const alt = shortcutEvent({ altKey: true });
  fire("keydown", alt);
  assert.equal(storage.get("clacky.aside.open"), "1");
  assert.equal(alt.prevented, false);
}

// No panels in the slot means no column to toggle.
{
  const { nodes, storage, fire } = boot();
  nodes["ext-slot-session-aside"].children = [];
  const event = shortcutEvent();
  fire("keydown", event);
  assert.equal(storage.get("clacky.aside.open"), "1");
  assert.equal(event.prevented, false);
}

console.log("aside shortcut tests passed");
