"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class Style {
  constructor() { this.transition = ""; this.values = {}; }
  setProperty(name, value) { this.values[name] = value; }
  removeProperty(name) { delete this.values[name]; }
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

  const storage = options.storage || new Map([
    ["clacky.aside.open", options.open === false ? "0" : "1"],
    ["clacky.aside.fullscreen", "0"],
  ]);
  const documentListeners = {};
  const observers = [];
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
    MutationObserver: class MutationObserver {
      constructor(callback) { this.callback = callback; observers.push(this); }
      observe() {}
    },
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

  // A probe starts bound to a real session: width is stored per session, so
  // the __default__ bucket the welcome page uses is not what these exercise.
  if (options.session !== false) context.Clacky.Aside.onSession(options.session || "s1");

  const fire = (type, event) => (documentListeners[type] || []).forEach(fn => fn(event));
  const drag = (type, clientX) => ({
    clientX,
    preventDefault() {},
  });
  const onHandle = (type, clientX) => (nodes["session-aside-resize"].listeners[type] || [])
    .forEach(fn => fn(drag(type, clientX)));
  return {
    nodes, storage, fire, onHandle, context, observers,
    triggerMutation: () => observers.forEach(observer => observer.callback()),
    fullscreen: () => nodes["chat-panel"].classes.has("aside-fullscreen"),
    width: () => parseInt(nodes["session-aside"].style.values["--session-aside-width"] || "256", 10),
  };
}

// Dragging the divider past the chat column's floor hands the workspace to the
// aside — through fullscreen, so the button and Esc share the same exit.
{
  const ui = boot();
  assert.equal(ui.fullscreen(), false);

  ui.onHandle("mousedown", 1000);
  ui.fire("mousemove", { clientX: 544 });
  assert.equal(ui.width(), 712);
  assert.equal(ui.fullscreen(), false, "488px of chat is still a split");

  ui.fire("mousemove", { clientX: 200 });
  assert.equal(ui.width(), 900, "the split drops back to the largest legal width");
  assert.equal(ui.fullscreen(), true, "chat below 300px takes the fullscreen state");

  ui.fire("mouseup", { clientX: 200 });
  assert.equal(ui.storage.get("clacky.aside.width.s1"), "900");

  // Leaving fullscreen lands on a readable split instead of bouncing back in.
  ui.context.Clacky.Aside.fullscreen(false);
  assert.equal(ui.fullscreen(), false);
  assert.equal(ui.width(), 899, "the chat column keeps its 300px floor");

  // The divider is back in hand and can widen the chat again.
  ui.onHandle("mousedown", 899);
  ui.fire("mousemove", { clientX: 998 });
  assert.equal(ui.width(), 800);
  assert.equal(ui.fullscreen(), false, "800px leaves 400px for the chat");
}

// Leaving fullscreen must survive a reload: the drag-written width is already
// inside the floor, so init must not bounce back into fullscreen.
{
  const ui = boot();
  ui.onHandle("mousedown", 1000);
  ui.fire("mousemove", { clientX: 200 });
  ui.fire("mouseup", { clientX: 200 });
  assert.equal(ui.storage.get("clacky.aside.fullscreen"), "1");
  assert.equal(ui.storage.get("clacky.aside.width.s1"), "900");

  ui.context.Clacky.Aside.fullscreen(false);
  assert.equal(ui.storage.get("clacky.aside.fullscreen"), "0");
  assert.equal(ui.storage.get("clacky.aside.width.s1"), "899",
    "the width the user sees on exit is the one that gets persisted");

  const reloaded = boot({ storage: ui.storage });
  assert.equal(reloaded.width(), 899);
  assert.equal(reloaded.fullscreen(), false, "a reload stays out of fullscreen");
}

// A width the user chose comes back exactly as dragged: a reload is not a
// layout pass that gets to re-clamp a split that already fits.
{
  const ui = boot();
  ui.onHandle("mousedown", 1000);
  ui.fire("mousemove", { clientX: 556 });
  ui.fire("mouseup", { clientX: 556 });
  assert.equal(ui.storage.get("clacky.aside.width.s1"), "700");

  const reloaded = boot({ storage: ui.storage });
  assert.equal(reloaded.width(), 700);
  assert.equal(reloaded.fullscreen(), false);
}

// A width that no longer fits never leaves the chat column under the floor: the
// aside hands the workspace over, exactly as the divider does.
{
  const ui = boot({ storage: new Map([
    ["clacky.aside.open", "1"],
    ["clacky.aside.width.s1", "950"],
    ["clacky.aside.fullscreen", "0"],
  ]) });
  assert.equal(ui.width(), 900, "the split drops back to the largest legal width");
  assert.equal(ui.fullscreen(), true);
}

// A collapsed aside (or an agent with no aside panels) must never be turned
// into a full-width column by the split rule.
{
  const closed = boot({ open: false });
  closed.onHandle("mousedown", 1000);
  closed.fire("mousemove", { clientX: 200 });
  assert.equal(closed.fullscreen(), false);

  const empty = boot({ emptySlot: true });
  empty.onHandle("mousedown", 1000);
  empty.fire("mousemove", { clientX: 200 });
  assert.equal(empty.fullscreen(), false);
}

// Fullscreen survives a reload: the panels render a frame after init, so the
// slot is briefly empty and must hide the mode without forgetting it.
{
  const ui = boot({
    storage: new Map([
      ["clacky.aside.open", "1"],
      ["clacky.aside.width.s1", "900"],
      ["clacky.aside.fullscreen", "1"],
    ]),
    emptySlot: true,
  });
  assert.equal(ui.fullscreen(), false, "no panels, no fullscreen column");
  assert.equal(ui.storage.get("clacky.aside.fullscreen"), "1", "the preference is kept");

  ui.nodes["ext-slot-session-aside"].appendChild(new Element("panel"));
  ui.triggerMutation();
  assert.equal(ui.fullscreen(), true, "the mode comes back with the panels");
}

// Reloading a fullscreen session: app.js binds the welcome state and then the
// session, which used to read as a session switch and drop fullscreen.
{
  const ui = boot({
    session: false,
    storage: new Map([
      ["clacky.aside.open", "1"],
      ["clacky.aside.width.s1", "900"],
      ["clacky.aside.fullscreen", "1"],
    ]),
  });
  assert.equal(ui.fullscreen(), true, "init restores fullscreen");

  ui.context.Clacky.Aside.onSession(null);
  ui.context.Clacky.Aside.onSession("s1");
  assert.equal(ui.fullscreen(), true, "binding the session keeps fullscreen");
  assert.equal(ui.storage.get("clacky.aside.fullscreen"), "1");

  ui.context.Clacky.Aside.onSession("s2");
  assert.equal(ui.fullscreen(), false, "a real session switch leaves fullscreen");
  assert.equal(ui.storage.get("clacky.aside.fullscreen"), "0");
}

// Narrow layouts render the aside as a fixed drawer, and a panel narrower
// than the floor itself must not lose its chat column.
{
  const narrow = boot({ narrow: true });
  narrow.onHandle("mousedown", 1000);
  narrow.fire("mousemove", { clientX: 200 });
  assert.equal(narrow.fullscreen(), false);

  const small = boot({ panelWidth: 280 });
  small.onHandle("mousedown", 1000);
  small.fire("mousemove", { clientX: 200 });
  assert.equal(small.fullscreen(), false);
}

console.log("chat column collapse tests passed");

// Width is remembered per session: the room opened for a diff stays with that
// conversation instead of following the user into the next one.
{
  const ui = boot();
  ui.context.Clacky.Aside.onSession("sA");
  ui.onHandle("mousedown", 1000);
  ui.fire("mousemove", { clientX: 556 });
  ui.fire("mouseup", { clientX: 556 });
  assert.equal(ui.width(), 700);
  assert.equal(ui.storage.get("clacky.aside.width.sA"), "700");

  ui.context.Clacky.Aside.onSession("sB");
  assert.equal(ui.width(), 256,
    "a session that was never dragged starts at the default, not at sA's width");

  ui.onHandle("mousedown", 1000);
  ui.fire("mousemove", { clientX: 756 });
  ui.fire("mouseup", { clientX: 756 });
  assert.equal(ui.width(), 500);
  assert.equal(ui.storage.get("clacky.aside.width.sB"), "500");
  assert.equal(ui.storage.get("clacky.aside.width.sA"), "700",
    "and dragging sB leaves sA untouched");

  ui.context.Clacky.Aside.onSession("sA");
  assert.equal(ui.width(), 700, "coming back restores the width this session was left at");
}

// A switch leaves fullscreen behind, but it must not re-clamp the width that
// fullscreen was painting over — that number belongs to the session leaving.
{
  const ui = boot();
  ui.context.Clacky.Aside.onSession("sA");
  ui.onHandle("mousedown", 1000);
  ui.fire("mousemove", { clientX: 200 });
  ui.fire("mouseup", { clientX: 200 });
  assert.equal(ui.fullscreen(), true);
  assert.equal(ui.storage.get("clacky.aside.width.sA"), "900");

  ui.context.Clacky.Aside.onSession("sB");
  assert.equal(ui.fullscreen(), false, "a switch leaves fullscreen behind");
  assert.equal(ui.width(), 256,
    "the incoming session starts at the default instead of inheriting a width it never chose");
  assert.equal(ui.storage.get("clacky.aside.width.sA"), "900",
    "the hidden width is still the width that session owns");
  assert.equal(ui.storage.get("clacky.aside.width.sB"), undefined,
    "and the switch does not write a record the user never asked for");
}
