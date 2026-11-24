"use strict";

// Behavioural harness for the aside tab strip (core/ext.js): nothing opens by
// default, the "+" picker groups tools vs extensions, tabs close, the open set
// is remembered per session, and a panel scoped to one agent is still reachable
// from another agent's picker.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class Element {
  constructor(tag = "div") {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parentNode = null;
    this.attributes = {};
    this._classes = new Set();
    this.listeners = {};
    this._text = "";
    this._html = "";
    this.scrollWidth = 0;
    this.clientWidth = 0;
    this.scrollLeft = 0;
    const self = this;
    this._style = {};
    this.style = {
      setProperty: (name, value) => { self._style[name] = String(value); },
      getPropertyValue: (name) => self._style[name] ?? "",
      removeProperty: (name) => { delete self._style[name]; },
    };
    this.classList = {
      add: (name) => self._classes.add(name),
      remove: (name) => self._classes.delete(name),
      contains: (name) => self._classes.has(name),
      toggle: (name, on) => (on ? self._classes.add(name) : self._classes.delete(name)),
    };
  }
  get className() { return Array.from(this._classes).join(" "); }
  set className(value) {
    this._classes = new Set(String(value).split(/\s+/).filter(Boolean));
  }
  get childElementCount() { return this.children.length; }
  get childNodes() { return this.children; }
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  replaceChildren(...nodes) {
    this.children.forEach((c) => { c.parentNode = null; });
    this.children = [];
    nodes.forEach((n) => this.appendChild(n));
  }
  remove() {
    if (!this.parentNode) return;
    this.parentNode.children = this.parentNode.children.filter((c) => c !== this);
    this.parentNode = null;
  }
  contains(node) {
    if (node === this) return true;
    return this.children.some((c) => c.contains(node));
  }
  getBoundingClientRect() {
    return this.rect || { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 };
  }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  removeEventListener(type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn);
  }
  fire(type, event = {}) {
    (this.listeners[type] || []).forEach((fn) => fn(event));
    return event;
  }
  get textContent() { return this._text; }
  set textContent(value) { this._text = String(value); }
  get innerHTML() { return this._html; }
  set innerHTML(value) { this._html = String(value); }
  querySelector(selector) {
    const cls = selector.startsWith(".") ? selector.slice(1) : null;
    const walk = (node) => {
      for (const child of node.children) {
        if (cls && child._classes.has(cls)) return child;
        const found = walk(child);
        if (found) return found;
      }
      return null;
    };
    return walk(this);
  }
}

function findAll(root, predicate, out = []) {
  root.children.forEach((child) => {
    if (predicate(child)) out.push(child);
    findAll(child, predicate, out);
  });
  return out;
}

const byClass = (root, cls) => findAll(root, (el) => el._classes.has(cls));
const byAttr = (root, name) => findAll(root, (el) => name in el.attributes);

function boot() {
  const storage = new Map();
  const container = new Element("div");
  container.setAttribute("data-slot", "session.aside");

  const documentListeners = {};
  const document = {
    readyState: "complete",
    body: new Element("body"),
    documentElement: new Element("html"),
    head: new Element("head"),
    createElement: (tag) => new Element(tag),
    querySelectorAll: (selector) => (selector === "[data-slot]" ? [container] : []),
    addEventListener(type, fn) { (documentListeners[type] ||= []).push(fn); },
    removeEventListener(type, fn) {
      documentListeners[type] = (documentListeners[type] || []).filter((f) => f !== fn);
    },
  };

  const context = {
    console,
    document,
    location: { search: "" },
    localStorage: {
      getItem: (k) => (storage.has(k) ? storage.get(k) : null),
      setItem: (k, v) => storage.set(k, String(v)),
      removeItem: (k) => storage.delete(k),
      get length() { return storage.size; },
      key: (i) => Array.from(storage.keys())[i] ?? null,
    },
    getComputedStyle: () => ({ paddingRight: "108px" }),
    requestAnimationFrame: (fn) => { fn(); return 1; },
    ResizeObserver: class { observe() {} disconnect() {} },
    MutationObserver: class { observe() {} disconnect() {} },
    URLSearchParams,
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init && init.detail; } },
    dispatchEvent() {},
    addEventListener() {},
    I18n: {
      t: (key) => ({
        "aside.newTab": "新标签页",
        "aside.closeTab": "关闭标签页",
        "aside.group.official": "官方工具",
        "aside.group.mine": "我的工具",
        "aside.allOpen": "所有面板都已打开",
      }[key] || key),
    },
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);
  vm.runInContext(
    fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/core/ext.js"), "utf8"),
    context
  );
  // The host column module is not loaded in this harness; the strip only calls
  // into it when the picker was the last page left.
  const asideCloseCalls = { count: 0 };
  context.Clacky.Aside = { close: () => { asideCloseCalls.count += 1; } };
  // The host exposes i18n as Clacky.I18n (not window.I18n); mirror that here.
  context.Clacky.I18n = context.I18n;
  return { ext: context.Clacky.ext, container, storage, document, asideCloseCalls };
}

function mountPanel(ext, { extId, layer, tabId, label, order, agents }) {
  ext._extBegin(extId, agents || null, null, layer);
  ext.ui.mount("session.aside", () => {
    const node = new Element("div");
    node.textContent = label;
    return node;
  }, { order: order || 100, tab: { id: tabId, label: () => label } });
  ext._extEnd();
}

function mountBuiltin(ext, tabId, label, order) {
  ext.ui.mountBuiltin("session.aside", () => null, {
    order: order || 25,
    tab: { id: tabId, label: () => label },
  });
}

function panels(ext, container = null) {
  return { ext, container };
}

function setup() {
  const env = boot();
  mountBuiltin(env.ext, "files", "文件", 25);
  mountPanel(env.ext, { extId: "ext/git/changes", layer: "builtin", tabId: "changes", label: "Git 管理", order: 30 });
  mountPanel(env.ext, { extId: "ext/time_machine/tm", layer: "builtin", tabId: "tm", label: "时光机", order: 40 });
  mountPanel(env.ext, { extId: "ext/clock/clock", layer: "installed", tabId: "clock", label: "时钟", order: 60 });
  env.ext.registerPanelAgents({ "git/changes": ["coding"] });
  return env;
}

const tabIds = (env) => byAttr(env.container, "data-tab").map((el) => el.attributes["data-tab"]);
const activeTab = (env) => byAttr(env.container, "data-tab").filter((el) => el._classes.has("active")).map((el) => el.attributes["data-tab"]);
const cardIds = (env) => byAttr(env.container, "data-panel-id").map((el) => el.attributes["data-panel-id"]);
const groupTitles = (env) => byClass(env.container, "aside-newtab-title").map((el) => el.textContent);

// 1. A fresh session opens nothing: the strip holds only the "+" page.
{
  const env = setup();
  env.ext.setContext({ agentProfile: "general", sessionId: "s1" });
  assert.deepEqual(tabIds(env), ["__new__"], "no panel opens by default");
  assert.deepEqual(activeTab(env), ["__new__"]);
  assert.deepEqual(cardIds(env).sort(), ["changes", "clock", "files", "tm"]);
  assert.deepEqual(groupTitles(env), ["官方工具", "我的工具"],
    "grouped by source, the same word the extensions page uses");
  const groupedCards = byClass(env.container, "aside-newtab-group")
    .map((g) => byAttr(g, "data-panel-id").map((el) => el.attributes["data-panel-id"]));
  assert.deepEqual(groupedCards, [["files", "changes", "tm"], ["clock"]],
    "host and built-in panels are official, installed ones are mine");
  assert.equal(byClass(env.container, "aside-tab-close").length, 1,
    "the picker tab closes like any other tab");
  const pickerIcon = byClass(env.container, "aside-tabs")[0].children[0];
  assert.equal(byClass(pickerIcon, "aside-tab-icon").length, 1, "the picker tab carries its own icon");
  const cardOf = (id) => byAttr(env.container, "data-panel-id")
    .find((el) => el.attributes["data-panel-id"] === id);
  const iconOf = (id) => byClass(cardOf(id), "aside-newtab-icon")[0].innerHTML;
  const glyphs = ["files", "changes", "tm"].map(iconOf);
  assert.equal(new Set(glyphs).size, glyphs.length, "each tool gets its own glyph");
  assert.equal(byClass(cardOf("clock"), "aside-newtab-icon").length, 0,
    "an extension without its own icon stays label-only instead of sharing a placeholder");
  const opener = byClass(env.container, "aside-tab-add")[0];
  assert.ok(!opener._classes.has("is-current"),
    "the + opener keeps full contrast while the picker is the active page");
  assert.equal(opener.attributes["data-tooltip"], "新标签页", "the + opener explains itself");
  assert.equal(opener.attributes["data-tooltip-pos"], "bottom",
    "the tooltip drops below the strip instead of over the header");
  opener.fire("click");
  assert.ok(opener._classes.has("is-nudging"),
    "hitting it on the picker nudges instead of silently repainting");
  assert.deepEqual(activeTab(env), ["__new__"], "and it stays on the picker");
}

// 2. A panel scoped to another agent is still offered and can be opened.
{
  const env = setup();
  env.ext.setContext({ agentProfile: "general", sessionId: "s2" });
  assert.ok(cardIds(env).includes("changes"), "general can open the coding-only panel");
  const card = byAttr(env.container, "data-panel-id").find((el) => el.attributes["data-panel-id"] === "changes");
  card.fire("click");
  assert.deepEqual(tabIds(env), ["changes"], "the picker tab gives way to the panel");
  assert.deepEqual(activeTab(env), ["changes"]);
  const strip = byClass(env.container, "aside-tabs")[0];
  const frame = byClass(env.container, "aside-tabs-frame")[0];
  const opener = byClass(env.container, "aside-tab-add")[0];
  assert.equal(strip.children.indexOf(opener), -1, "the + opener sits outside the scrolling strip");
  assert.equal(frame.children[frame.children.length - 1], opener,
    "it stays docked at the right end of the bar however many tabs are open");
  assert.equal(byClass(env.container, "aside-panel").some((el) => el.attributes["data-panel"] === "changes"), true);
}

// 3. Closing a tab disposes it and falls back to the "+" page.
{
  const env = setup();
  env.ext.setContext({ agentProfile: "general", sessionId: "s3" });
  byAttr(env.container, "data-panel-id").find((el) => el.attributes["data-panel-id"] === "tm").fire("click");
  assert.deepEqual(tabIds(env), ["tm"]);

  const closeBtn = byClass(env.container, "aside-tab-close")
    .find((el) => el.parentNode.attributes["data-tab"] === "tm");
  closeBtn.fire("click", { stopPropagation() {} });
  assert.deepEqual(tabIds(env), ["__new__"], "closing the last panel lands on the picker");
  assert.equal(byClass(env.container, "aside-panel").some((el) => el.attributes["data-panel"] === "tm"), false,
    "the closed panel body is destroyed");
}

// 4. The open set is remembered per session, not globally.
{
  const env = setup();
  env.ext.setContext({ agentProfile: "general", sessionId: "a" });
  byAttr(env.container, "data-panel-id").find((el) => el.attributes["data-panel-id"] === "clock").fire("click");
  assert.deepEqual(tabIds(env), ["clock"]);

  env.ext.setContext({ agentProfile: "general", sessionId: "b" });
  assert.deepEqual(tabIds(env), ["__new__"], "another session starts empty");

  env.ext.setContext({ agentProfile: "general", sessionId: "a" });
  assert.deepEqual(tabIds(env), ["clock"], "switching back restores the tab");
  assert.deepEqual(activeTab(env), ["clock"]);

  const stored = JSON.parse(env.storage.get("clacky.aside.tabs.a"));
  assert.deepEqual(stored.open, ["clock"]);
  assert.equal(env.storage.has("clacky.aside.tabs.b"), false,
    "a session the user never touched keeps no record");
}

// 5. activateTab opens a closed panel (preview does this when you click a file).
{
  const env = setup();
  env.ext.setContext({ agentProfile: "general", sessionId: "s5" });
  assert.equal(env.ext.activateTab("session.aside", "changes"), true);
  assert.deepEqual(activeTab(env), ["changes"]);
  assert.equal(env.ext.activateTab("session.aside", "nope"), false);
}

// 6. An agent-restricted extension stays out of other agents' pickers.
{
  const env = boot();
  mountPanel(env.ext, { extId: "agent/designer/webui/panel", layer: null, tabId: "canvas", label: "画布", agents: ["designer"] });
  env.ext.setContext({ agentProfile: "general", sessionId: "g" });
  assert.deepEqual(cardIds(env), [], "designer-only panel is not offered to general");
  env.ext.setContext({ agentProfile: "designer", sessionId: "d" });
  assert.deepEqual(cardIds(env), ["canvas"]);
}

// 7. Every panel already open → the picker says so instead of going blank.
{
  const env = boot();
  mountBuiltin(env.ext, "files", "文件", 25);
  env.ext.setContext({ agentProfile: "general", sessionId: "s7" });
  byAttr(env.container, "data-panel-id").find((el) => el.attributes["data-panel-id"] === "files").fire("click");
  env.ext.activateTab("session.aside", "__new__");
  assert.deepEqual(cardIds(env), []);
  assert.deepEqual(byClass(env.container, "aside-newtab-empty").map((el) => el.textContent), ["所有面板都已打开"]);
}

// 8. Deleting a session drops its tab record.
{
  const env = setup();
  env.ext.setContext({ agentProfile: "general", sessionId: "dead" });
  byAttr(env.container, "data-panel-id").find((el) => el.attributes["data-panel-id"] === "tm").fire("click");
  env.ext.notifySessionRemoved("dead");
  assert.equal(env.storage.has("clacky.aside.tabs.dead"), false);
}

// 9. The strip publishes how many tabs are open: the CSS divides the free
//    width by that count, so a short label still gets a real target.
{
  const env = setup();
  env.ext.setContext({ agentProfile: "general", sessionId: "s9" });
  const frame = byClass(env.container, "aside-tabs-frame")[0];
  assert.equal(frame.style.getPropertyValue("--aside-tab-count"), "1");
  env.ext.activateTab("session.aside", "files");
  env.ext.activateTab("session.aside", "tm");
  assert.equal(frame.style.getPropertyValue("--aside-tab-count"), "2");
  env.ext.activateTab("session.aside", "__new__");
  assert.equal(frame.style.getPropertyValue("--aside-tab-count"), "3");
}

// 10. A newly opened panel appends on the right instead of being re-sorted
//     into the declared order (files 25 < tm 40 < clock 60).
{
  const env = setup();
  env.ext.setContext({ agentProfile: "general", sessionId: "s10" });
  env.ext.activateTab("session.aside", "tm");
  env.ext.activateTab("session.aside", "clock");
  env.ext.activateTab("session.aside", "files");
  assert.deepEqual(tabIds(env), ["tm", "clock", "files"]);
}

// 11. The picker becomes a tab once the user asks for it: it stays while they
//     move between existing tabs, and retires as soon as they pick a panel.
{
  const env = setup();
  env.ext.setContext({ agentProfile: "general", sessionId: "s11" });
  const cardOf = (id) => byAttr(env.container, "data-panel-id")
    .find((el) => el.attributes["data-panel-id"] === id);

  cardOf("files").fire("click");
  assert.deepEqual(tabIds(env), ["files"],
    "opening a panel from the strip's only page leaves no picker tab behind");

  byClass(env.container, "aside-tab-add")[0].fire("click");
  assert.deepEqual(tabIds(env), ["files", "__new__"], "the + opener opens the picker as a tab");
  assert.deepEqual(activeTab(env), ["__new__"]);

  cardOf("changes").fire("click");
  assert.deepEqual(tabIds(env), ["files", "changes"],
    "picking a panel from the picker page retires the picker tab");
  assert.deepEqual(activeTab(env), ["changes"], "and the picked panel takes the view");

  env.ext.setContext({ agentProfile: "general", sessionId: "s11" });
  assert.deepEqual(tabIds(env), ["files", "changes"], "the retired picker tab does not come back");

  byClass(env.container, "aside-tab-add")[0].fire("click");
  assert.deepEqual(tabIds(env), ["files", "changes", "__new__"], "the + opener can bring it back");

  byClass(env.container, "aside-tab").find((el) => el.attributes["data-tab"] === "files").fire("click");
  assert.deepEqual(tabIds(env), ["files", "changes", "__new__"],
    "switching to an already open tab keeps the picker tab");
  assert.deepEqual(activeTab(env), ["files"]);

  byClass(env.container, "aside-tab").find((el) => el.attributes["data-tab"] === "__new__").fire("click");
  assert.deepEqual(activeTab(env), ["__new__"], "clicking it comes back to the picker");

  const pickerClose = byClass(env.container, "aside-tab-close")
    .find((el) => el.parentNode.attributes["data-tab"] === "__new__");
  assert.ok(pickerClose, "the picker tab is closable once another tab exists");
  pickerClose.fire("click", { stopPropagation() {} });
  assert.deepEqual(tabIds(env), ["files", "changes"], "closing it leaves the panels alone");
  assert.deepEqual(activeTab(env), ["changes"], "and hands the view to the neighbour");
  assert.equal(env.asideCloseCalls.count, 0,
    "the column stays open while other pages are still in the strip");
}

// 12. The picker on its own is the last page: closing it closes the column.
{
  const env = setup();
  env.ext.setContext({ agentProfile: "general", sessionId: "s12" });
  const pickerClose = byClass(env.container, "aside-tab-close")
    .find((el) => el.parentNode.attributes["data-tab"] === "__new__");
  assert.ok(pickerClose, "the picker tab carries its own close control");
  pickerClose.fire("click", { stopPropagation() {} });
  assert.equal(env.asideCloseCalls.count, 1,
    "closing the only page collapses the side panel instead of leaving an empty strip");
  assert.deepEqual(JSON.parse(env.storage.get("clacky.aside.tabs.s12")).open, [],
    "and the session remembers that nothing is open");

  // Reopening must rebuild the picker page once. The old body used to stay in
  // the DOM, so the second open painted a duplicate copy of every card group.
  env.ext.activateTab("session.aside", "__new__");
  assert.equal(byClass(env.container, "aside-newtab").length, 1,
    "reopening the picker leaves a single page body behind");
  assert.deepEqual(groupTitles(env), ["官方工具", "我的工具"],
    "and each group comes back once");
}

// 13. The last real panel behaves like the picker: once its × empties the
//     strip, the column goes away instead of leaving the picker behind. The
//     user closed a tab to get rid of the panel, not to be handed a menu.
{
  const env = setup();
  env.ext.setContext({ agentProfile: "general", sessionId: "s13" });
  const cardOf = (id) => byAttr(env.container, "data-panel-id")
    .find((el) => el.attributes["data-panel-id"] === id);

  cardOf("files").fire("click");
  assert.deepEqual(tabIds(env), ["files"]);

  const filesClose = byClass(env.container, "aside-tab-close")
    .find((el) => el.parentNode.attributes["data-tab"] === "files");
  assert.ok(filesClose, "a real panel tab carries its own close control");
  filesClose.fire("click", { stopPropagation() {} });

  assert.equal(env.asideCloseCalls.count, 1,
    "closing the last real panel collapses the side panel");
  assert.deepEqual(JSON.parse(env.storage.get("clacky.aside.tabs.s13")).open, [],
    "and the session remembers that nothing is open");

  // Reopening starts on the picker, since there is no panel to restore.
  env.ext.activateTab("session.aside", "__new__");
  assert.equal(byClass(env.container, "aside-newtab").length, 1,
    "reopening after that shows a single picker page");
}

console.log("aside tabs tests passed");