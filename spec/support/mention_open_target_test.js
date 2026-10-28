"use strict";

// MentionAC.open(mode, input) must target the composer it is opened for: the
// + menu opens references from a button, before any keystroke re-pointed _cfg.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class El {
  constructor() { this.style = {}; this.children = []; this.handlers = {}; this.className = ""; }
  addEventListener(type, fn) { this.handlers[type] = fn; }
  appendChild(c) { this.children.push(c); return c; }
  setAttribute() {}
  contains() { return false; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  set innerHTML(v) { this.children = []; }
}

const nodes = { "chat-in": new El(), "chat-menu": new El(), "ns-in": new El(), "ns-menu": new El() };
const context = vm.createContext({
  console, Promise, URLSearchParams,
  Clacky: {},
  document: {
    getElementById: id => nodes[id] || null,
    createElement: () => new El(),
    createElementNS: () => new El(),
    createTextNode: () => new El(),
    addEventListener() {}, removeEventListener() {},
  },
  fetch: async () => ({ ok: true, json: async () => ({ entries: [], sessions: [] }) }),
});
vm.runInContext(fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/components/mentions.js"), "utf8"), context);
const MentionAC = context.Clacky.MentionAC;

nodes["chat-menu"].style.display = "none";
nodes["ns-menu"].style.display = "none";
MentionAC.attach({ input: "chat-in", menu: "chat-menu" });
MentionAC.attach({ input: "ns-in", menu: "ns-menu" });

MentionAC.open("files", "chat-in");
assert.equal(nodes["chat-menu"].style.display, "", "opens on the requested composer");
assert.equal(nodes["ns-menu"].style.display, "none", "the last attached composer stays closed");
MentionAC.hide();

MentionAC.open("chats", "ns-in");
assert.equal(nodes["ns-menu"].style.display, "");
assert.equal(nodes["chat-menu"].style.display, "none");

MentionAC.hide();

// Back from the top level of a submenu returns to whoever opened it (the + menu).
let backs = 0;
MentionAC.open("files", "chat-in", () => { backs += 1; });
nodes["chat-in"].handlers.keydown({ key: "Backspace", preventDefault() {}, stopImmediatePropagation() {} });
assert.equal(backs, 1, "Back calls the opener");
assert.equal(MentionAC.visible, false, "the mention menu closes before handing back");

// Typed @ menus keep their own root as the Back target.
MentionAC.open("chats", "chat-in");
nodes["chat-in"].handlers.keydown({ key: "Backspace", preventDefault() {}, stopImmediatePropagation() {} });
assert.equal(backs, 1);
assert.equal(MentionAC.visible, true, "without an opener Back stays in the mention menu");

console.log("ok - mention open target");
