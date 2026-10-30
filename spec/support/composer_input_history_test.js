"use strict";

// Regression harness for ArrowUp/Down recall of sent messages in the composer.
// Loads the real components/composer.js against a minimal contenteditable stub.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class Node {
  constructor(tag, value) {
    this.tagName = tag;
    this.nodeType = tag ? 1 : 3;
    this.nodeValue = value;
    this.childNodes = [];
    this.dataset = {};
    this.handlers = {};
    this.classList = { contains: () => false };
  }
  set innerHTML(v) { if (v === "") this.childNodes = []; }
  get innerHTML() { return this.childNodes.length ? "x" : ""; }
  appendChild(n) { this.childNodes.push(n); return n; }
  addEventListener(k, fn) { this.handlers[k] = fn; }
  querySelector(sel) { return sel === ".mention-chip" ? this.chip || null : null; }
  setAttribute() {}
  focus() {}
}

const document = {
  createElement: tag => new Node(tag.toUpperCase()),
  createTextNode: text => new Node(null, text),
  createRange: () => ({ selectNodeContents() {}, collapse() {} }),
};
const ctx = {
  document,
  window: { getSelection: () => ({ removeAllRanges() {}, addRange() {} }) },
  Clacky: {},
  Event: class { constructor(type) { this.type = type; } },
};
vm.createContext(ctx);
const src = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/components/composer.js"), "utf8");
vm.runInContext(src + "\nthis.Composer = Composer;", ctx);
const { Composer } = ctx;

let history = ["first", "second\nline", "third"];
function setup(opts = { getHistory: () => history }) {
  const el = new Node("DIV");
  Composer.init(el, opts);
  const press = (key, extra = {}) => {
    const e = { key, prevented: false, preventDefault() { this.prevented = true; }, ...extra };
    el.handlers.keydown(e);
    return e.prevented;
  };
  return { el, press, value: () => Composer.text(el) };
}

{
  const { press, value } = setup();
  assert.equal(press("ArrowUp"), true);
  assert.equal(value(), "third", "empty box + ArrowUp recalls the newest message");
  press("ArrowUp");
  assert.equal(value(), "second\nline", "multi-line messages keep their line breaks");
  press("ArrowUp");
  assert.equal(value(), "first");
  press("ArrowUp");
  assert.equal(value(), "first", "stops at the oldest message");
  press("ArrowDown");
  press("ArrowDown");
  assert.equal(value(), "third");
  assert.equal(press("ArrowDown"), true);
  assert.equal(value(), "", "stepping past the newest clears the box");
  assert.equal(press("ArrowDown"), false, "ArrowDown on an empty box is left alone");
}

{
  const { el, press, value } = setup();
  Composer.setText(el, "draft");
  assert.equal(press("ArrowUp"), false, "a box with content keeps native caret movement");
  assert.equal(value(), "draft");
  el.innerHTML = "";
  el.chip = new Node("SPAN");
  assert.equal(press("ArrowUp"), false, "a chip counts as content");
}

{
  const { el, press, value } = setup();
  press("ArrowUp");
  el.appendChild(document.createTextNode("!"));
  assert.equal(press("ArrowUp"), false, "editing a recalled entry leaves recall mode");
  assert.equal(value(), "third!");
}

{
  const { press, value } = setup();
  assert.equal(press("ArrowUp", { isComposing: true }), false, "IME candidate navigation is left alone");
  for (const mod of ["shiftKey", "altKey", "metaKey", "ctrlKey"]) {
    assert.equal(press("ArrowUp", { [mod]: true }), false, `${mod} + ArrowUp is left alone`);
  }
  assert.equal(value(), "");
}

{
  const { el, press, value } = setup();
  press("ArrowUp");
  press("ArrowUp");
  Composer.setText(el, "");
  press("ArrowUp");
  assert.equal(value(), "third", "setText (e.g. session switch) restarts recall from the newest");
  press("ArrowUp");
  Composer.clear(el);
  press("ArrowUp");
  assert.equal(value(), "third", "clear (e.g. after send) restarts recall from the newest");
}

{
  const { press, value } = setup({});
  assert.equal(press("ArrowUp"), false, "no getHistory → no recall");
  history = [];
  const empty = setup();
  assert.equal(empty.press("ArrowUp"), false, "empty history → no recall");
  assert.equal(value(), "");
}

console.log("composer input history: ok");
