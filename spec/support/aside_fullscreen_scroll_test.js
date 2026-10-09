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
    this.style = new Style();
    this.children = [];
    this.parentNode = null;
    this.listeners = {};
    this.classes = new Set();
    this.clientHeight = 400;
    this.scrollHeight = 1000;
    this._scrollTop = 0;
    this.rect = { top: 0, bottom: 400, left: 0, right: 800, width: 800, height: 400 };
    this.classList = {
      add: name => this.classes.add(name),
      remove: name => this.classes.delete(name),
      contains: name => this.classes.has(name),
      toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name),
    };
  }
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  replaceChildren(...children) {
    this.children.forEach(child => { child.parentNode = null; });
    this.children = [];
    children.forEach(child => this.appendChild(child));
  }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  contains(target) {
    if (target === this) return true;
    return this.children.some(child => child === target || child.contains(target));
  }
  get firstElementChild() { return this.children[0] || null; }
  get childElementCount() { return this.children.length; }
  getBoundingClientRect() { return this.rect; }
  get scrollTop() { return this._scrollTop; }
  set scrollTop(value) {
    const max = Math.max(0, this.scrollHeight - this.clientHeight);
    this._scrollTop = Math.max(0, Math.min(max, value));
  }
}

function boot() {
  const ids = [
    "chat-panel", "session-aside", "session-aside-resize",
    "btn-aside-collapse", "btn-aside-open", "btn-aside-fullscreen",
    "workspace-overlay", "ext-slot-session-aside", "messages",
  ];
  const nodes = Object.fromEntries(ids.map(id => [id, new Element(id)]));
  nodes["ext-slot-session-aside"].appendChild(new Element("panel"));
  nodes["session-aside"].style.transition = "width 0.2s ease";
  nodes.messages.rect = { top: 100, bottom: 500, left: 0, right: 800, width: 800, height: 400 };

  const storage = new Map([
    ["clacky.aside.open", "1"],
    ["clacky.aside.fullscreen", "0"],
  ]);
  const document = {
    readyState: "complete",
    documentElement: new Element("html"),
    body: { style: {} },
    getElementById: id => nodes[id] || null,
    addEventListener() {},
  };
  const context = {
    console, Map, Math, Number,
    document,
    innerWidth: 1200,
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
    Clacky: { I18n: { t: key => key } },
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(
    path.resolve(__dirname, "../../lib/clacky/web/core/aside.js"),
    "utf8"
  ), context);
  return { context, nodes };
}

// A message being read in the middle of history remains at the same viewport
// offset after the chat column is restored at its final width.
{
  const { context, nodes } = boot();
  const messages = nodes.messages;
  messages.scrollTop = 420;
  const anchor = new Element("anchor");
  const initialScrollTop = messages.scrollTop;
  let layoutTop = 80;
  anchor.getBoundingClientRect = () => {
    const top = layoutTop - (messages.scrollTop - initialScrollTop);
    return { top, bottom: top + 140, left: 0, right: 800, width: 800, height: 140 };
  };
  messages.appendChild(anchor);
  Object.defineProperty(nodes["session-aside"], "offsetWidth", {
    get() { layoutTop = 145; return 256; },
  });

  context.Clacky.Aside.fullscreen(true);
  context.Clacky.Aside.fullscreen(false);

  assert.equal(messages.scrollTop, 485, "restores the visible message anchor after reflow");
  assert.equal(anchor.getBoundingClientRect().top, 80, "keeps the anchor at its original viewport offset");
  assert.equal(nodes["session-aside"].style.transition, "width 0.2s ease", "restores the authored transition");
}

// Bottom readers remain pinned to the newest content, including output that
// arrived while the preview occupied the full workspace.
{
  const { context, nodes } = boot();
  const messages = nodes.messages;
  messages.scrollTop = 600;
  messages.appendChild(new Element("message"));

  context.Clacky.Aside.fullscreen(true);
  messages.scrollHeight = 1300;
  context.Clacky.Aside.fullscreen(false);

  assert.equal(messages.scrollTop, 900, "keeps the conversation pinned to the bottom");
}

// Replacing the conversation while fullscreen invalidates the old marker; an
// anchor from the previous session must never move the new session.
{
  const { context, nodes } = boot();
  const messages = nodes.messages;
  messages.scrollTop = 320;
  const oldMessage = new Element("old-message");
  oldMessage.rect = { top: 80, bottom: 220, left: 0, right: 800, width: 800, height: 140 };
  messages.appendChild(oldMessage);

  context.Clacky.Aside.fullscreen(true);
  const newMessage = new Element("new-message");
  newMessage.rect = { top: 100, bottom: 240, left: 0, right: 800, width: 800, height: 140 };
  messages.replaceChildren(newMessage);
  messages.scrollTop = 180;
  context.Clacky.Aside.fullscreen(false);

  assert.equal(messages.scrollTop, 180, "ignores a stale anchor after a session switch");
}

console.log("aside fullscreen scroll tests passed");
