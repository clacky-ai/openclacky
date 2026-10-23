"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class Element {
  constructor(tag = "div") {
    this.tagName = tag.toUpperCase();
    this.nodeType = 1;
    this.childNodes = [];
    this.dataset = {};
    this.attrs = {};
    this.parentNode = null;
    this.className = "";
    this.inputEvents = 0;
    this.listeners = {};
    this.classList = {
      add: name => {
        const names = new Set(this.className.split(/\s+/).filter(Boolean));
        names.add(name);
        this.className = Array.from(names).join(" ");
      },
      remove: name => {
        this.className = this.className.split(/\s+/).filter(value => value && value !== name).join(" ");
      },
      contains: name => this.className.split(/\s+/).includes(name),
    };
  }
  appendChild(child) {
    this.childNodes.push(child);
    child.parentNode = this;
    return child;
  }
  insertBefore(child, next) {
    const index = next ? this.childNodes.indexOf(next) : this.childNodes.length;
    this.childNodes.splice(index < 0 ? this.childNodes.length : index, 0, child);
    child.parentNode = this;
    return child;
  }
  contains(node) {
    if (node === this) return true;
    return this.childNodes.some(child => child === node || (child.contains && child.contains(node)));
  }
  addEventListener(type, callback) {
    (this.listeners[type] ||= []).push(callback);
  }
  setAttribute(name, value) { this.attrs[name] = String(value); }
  dispatchEvent(event) {
    if (event.type === "input") this.inputEvents += 1;
    (this.listeners[event.type] || []).forEach(callback => callback(event));
  }
  focus() { this.focused = true; }
  get previousSibling() {
    if (!this.parentNode) return null;
    const index = this.parentNode.childNodes.indexOf(this);
    return index > 0 ? this.parentNode.childNodes[index - 1] : null;
  }
  get nextSibling() {
    if (!this.parentNode) return null;
    const index = this.parentNode.childNodes.indexOf(this);
    return this.parentNode.childNodes[index + 1] || null;
  }
}

class TextNode {
  constructor(value) {
    this.nodeType = 3;
    this.nodeValue = value;
    this.parentNode = null;
  }
  get previousSibling() {
    if (!this.parentNode) return null;
    const index = this.parentNode.childNodes.indexOf(this);
    return index > 0 ? this.parentNode.childNodes[index - 1] : null;
  }
  get nextSibling() {
    if (!this.parentNode) return null;
    const index = this.parentNode.childNodes.indexOf(this);
    return this.parentNode.childNodes[index + 1] || null;
  }
}

class Range {
  selectNodeContents(node) { this.startContainer = node; this.startOffset = node.childNodes.length; }
  collapse() {}
  setStart(node, offset) { this.startContainer = node; this.startOffset = offset; }
  setStartAfter(node) {
    this.startContainer = node.parentNode;
    this.startOffset = node.parentNode.childNodes.indexOf(node) + 1;
  }
  insertNode(node) {
    const next = this.startContainer.childNodes[this.startOffset] || null;
    this.startContainer.insertBefore(node, next);
  }
}

const selection = {
  rangeCount: 0,
  anchorNode: null,
  removeAllRanges() {},
  addRange(range) { this.rangeCount = 1; this.anchorNode = range.startContainer; },
};
const document = {
  body: null,
  createElement: tag => new Element(tag),
  createElementNS: (_ns, tag) => new Element(tag),
  createTextNode: text => new TextNode(text),
  createRange: () => new Range(),
};

const context = {
  console,
  JSON,
  setTimeout,
  clearTimeout,
  Event: class Event { constructor(type) { this.type = type; } },
  document,
  Clacky: {},
};
context.window = context;
context.getSelection = () => selection;
context.globalThis = context;
vm.createContext(context);

const source = fs.readFileSync(
  path.resolve(__dirname, "../../lib/clacky/web/components/composer.js"),
  "utf8"
);
vm.runInContext(source, context);

const Composer = context.Clacky.Composer;

function transfer(initial = {}, files = []) {
  const values = new Map(Object.entries(initial));
  return {
    effectAllowed: "none",
    dropEffect: "none",
    files,
    get types() {
      const types = Array.from(values.keys());
      if (files.length > 0) types.push("Files");
      return types;
    },
    setData(type, value) { values.set(type, value); },
    getData(type) { return values.get(type) || ""; },
    value(type) { return values.get(type); },
  };
}

const dt = transfer();
assert.equal(Composer.beginReferenceDrag(dt, {
  type: "session",
  name: "Investigate timeout",
  sessionId: "session-123",
}), true);
assert.equal(dt.effectAllowed, "copyMove");
assert.equal(dt.value("text/plain"), "@Investigate timeout");
assert.deepEqual(
  JSON.parse(JSON.stringify(Composer.readDraggedChip(dt))),
  { type: "session", name: "Investigate timeout", sessionId: "session-123" }
);

const wirePayload = transfer({
  "application/x-openclacky-reference": JSON.stringify({
    type: "session",
    name: "Wire format",
    session_id: "session-wire",
  }),
});
assert.deepEqual(
  JSON.parse(JSON.stringify(Composer.readDraggedChip(wirePayload))),
  { type: "session", name: "Wire format", sessionId: "session-wire" }
);

assert.equal(Composer.readDraggedChip(transfer({
  "application/x-openclacky-reference": "not json",
})), null);
assert.equal(Composer.readDraggedChip(transfer({
  "application/x-openclacky-reference": JSON.stringify({ type: "file", path: "/tmp/a" }),
})), null);
assert.equal(Composer.readDraggedChip(transfer({
  "application/x-openclacky-reference": JSON.stringify({ type: "session", name: "Missing id" }),
})), null);
assert.equal(Composer.acceptsSessionDrag(dt), true, "session drags are identified separately");
assert.equal(
  Composer.acceptsSessionDrag(transfer({}, [{ name: "report.pdf" }])),
  false,
  "file drags are not mistaken for session drags"
);

const workspaceFileTransfer = transfer();
assert.equal(Composer.beginWorkspaceFileDrag(workspaceFileTransfer, {
  type: "file",
  name: "report.pdf",
  path: "/workspace/report.pdf",
  size: 2048,
}), true);
assert.equal(workspaceFileTransfer.effectAllowed, "copy");
assert.equal(workspaceFileTransfer.value("text/plain"), "report.pdf");
assert.deepEqual(
  JSON.parse(JSON.stringify(Composer.readDraggedWorkspaceFile(workspaceFileTransfer))),
  { type: "file", name: "report.pdf", path: "/workspace/report.pdf", size: 2048 }
);
assert.equal(Composer.acceptsWorkspaceFileDrag(workspaceFileTransfer), true);
assert.equal(Composer.beginWorkspaceFileDrag(transfer(), {
  type: "directory",
  name: "src",
  path: "/workspace/src",
}), false, "directories are not exposed as file attachments");
assert.equal(Composer.readDraggedWorkspaceFile(transfer({
  "application/x-openclacky-workspace-file": "not json",
})), null, "invalid workspace drag data is ignored");

const input = new Element("div");
assert.equal(Composer.insertDroppedChip(input, dt, 10, 10), true);
const insertedChip = input.childNodes.find(node => node.classList && node.classList.contains("mention-chip"));
assert.ok(insertedChip, "drop inserts a mention chip");
assert.equal(insertedChip.dataset.mentionType, "session");
assert.equal(insertedChip.dataset.sessionId, "session-123");
assert.equal(insertedChip.dataset.name, "Investigate timeout");
assert.equal(input.inputEvents, 1, "drop notifies the composer input pipeline");
assert.equal(input.focused, true, "drop restores focus to the composer");

assert.equal(Composer.acceptsDrop(dt), true, "internal references are accepted");
assert.equal(Composer.acceptsDrop(workspaceFileTransfer), true, "workspace files are accepted");
assert.equal(Composer.acceptsDrop(transfer({}, [{ name: "report.pdf" }])), true, "files are accepted");
assert.equal(Composer.acceptsDrop(transfer({ "text/plain": "plain text" })), false, "plain text is ignored");

const zone = new Element("section");
const zoneInput = new Element("div");
const uploaded = [];
const stagedWorkspaceFiles = [];
Composer.bindDropZone({
  zone,
  input: zoneInput,
  onFiles: files => uploaded.push(...files),
  onWorkspaceFile: file => stagedWorkspaceFiles.push(file),
});

let prevented = false;
zone.dispatchEvent({
  type: "dragover",
  dataTransfer: dt,
  preventDefault() { prevented = true; },
});
assert.equal(prevented, true, "supported drags opt into browser drop handling");
assert.equal(dt.dropEffect, "copy");
assert.equal(zone.classList.contains("drag-over"), true, "the full zone is highlighted");

zone.dispatchEvent({
  type: "drop",
  dataTransfer: dt,
  clientX: 100,
  clientY: 100,
  preventDefault() {},
});
assert.equal(zone.classList.contains("drag-over"), false, "drop feedback is cleared");
assert.ok(
  zoneInput.childNodes.some(node => node.classList && node.classList.contains("mention-chip")),
  "dropping a reference anywhere in the zone inserts it into the composer"
);

const file = { name: "report.pdf" };
const fileTransfer = transfer({}, [file]);
zone.dispatchEvent({
  type: "drop",
  dataTransfer: fileTransfer,
  clientX: 100,
  clientY: 100,
  preventDefault() {},
});
assert.deepEqual(uploaded, [file], "dropping files anywhere in the zone uses the attachment callback");

zone.dispatchEvent({
  type: "dragover",
  dataTransfer: workspaceFileTransfer,
  preventDefault() {},
});
zone.dispatchEvent({
  type: "drop",
  dataTransfer: workspaceFileTransfer,
  clientX: 100,
  clientY: 100,
  preventDefault() {},
});
assert.deepEqual(
  JSON.parse(JSON.stringify(stagedWorkspaceFiles)),
  [{ type: "file", name: "report.pdf", path: "/workspace/report.pdf", size: 2048 }],
  "dropping a workspace file uses the path-backed attachment callback"
);

const uploadOnlyZone = new Element("section");
let uploadOnlyPrevented = false;
Composer.bindDropZone({
  zone: uploadOnlyZone,
  input: new Element("div"),
  onFiles() {},
});
uploadOnlyZone.dispatchEvent({
  type: "dragover",
  dataTransfer: workspaceFileTransfer,
  preventDefault() { uploadOnlyPrevented = true; },
});
assert.equal(uploadOnlyPrevented, false, "views without a workspace callback ignore workspace drags");
assert.equal(uploadOnlyZone.classList.contains("drag-over"), false);
