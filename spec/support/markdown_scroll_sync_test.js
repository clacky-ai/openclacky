"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class Scroller {
  constructor(scrollHeight, clientHeight) {
    this.scrollHeight = scrollHeight;
    this.clientHeight = clientHeight;
    this._scrollTop = 0;
    this.writes = 0;
    this.listeners = {};
  }
  get scrollTop() { return this._scrollTop; }
  set scrollTop(value) {
    const max = Math.max(0, this.scrollHeight - this.clientHeight);
    const next = Math.min(Math.max(0, value), max);
    if (next === this._scrollTop) return;
    this._scrollTop = next;
    this.writes += 1;
    this.fire("scroll");
  }
  get ratio() {
    const max = this.scrollHeight - this.clientHeight;
    return max > 0 ? this._scrollTop / max : 0;
  }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  removeEventListener(type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter(f => f !== fn);
  }
  fire(type) {
    (this.listeners[type] || []).slice().forEach(fn => fn({ type, target: this }));
  }
}

const sandbox = { window: {}, console };
sandbox.window.window = sandbox.window;
vm.createContext(sandbox);

const source = fs.readFileSync(
  path.join(__dirname, "../../lib/clacky/web/components/code-editor.js"),
  "utf8"
);
vm.runInContext(source, sandbox);

const { linkScrollSync } = sandbox.window.CodeEditor;
assert.equal(typeof linkScrollSync, "function", "CodeEditor.linkScrollSync should be exported");

// Editor pane is 3x taller than the preview pane; both should land on the same ratio.
const editor = new Scroller(3000, 600);
const preview = new Scroller(1000, 400);
linkScrollSync(editor, preview);

editor.scrollTop = 1200;
assert.equal(editor.ratio, 0.5);
assert.equal(preview.ratio, 0.5, "preview should follow the editor");
assert.equal(preview.writes, 1, "the follower should not bounce back to the editor");
assert.equal(editor.writes, 1, "editor should not be written to by its own scroll");

preview.scrollTop = 100;
assert.equal(preview.ratio, 1 / 6);
assert.equal(editor.ratio, 1 / 6, "editor should follow the preview");
assert.equal(editor.writes, 2);
assert.equal(preview.writes, 2);

// A pane that cannot scroll (hidden or shorter than the viewport) must not
// hijack the other side.
const hidden = new Scroller(200, 400);
const visible = new Scroller(2000, 400);
linkScrollSync(hidden, visible);
visible.scrollTop = 800;
assert.equal(hidden.scrollTop, 0, "hidden pane scrollTop stays put");

// syncFrom aligns after a re-render / when the split view becomes visible.
const left = new Scroller(2000, 400);
const right = new Scroller(1200, 400);
right.scrollTop = 400;
const link = linkScrollSync(left, right);
assert.equal(left.scrollTop, 0, "linking alone should not move either pane");
link.syncFrom(right);
assert.equal(left.ratio, 0.5, "syncFrom should push the source ratio to the other pane");

link.destroy();
right.scrollTop = 0;
assert.equal(left.ratio, 0.5, "destroy stops the sync");

console.log("markdown scroll sync ok");
