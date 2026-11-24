"use strict";

// A branch comparison can list hundreds of files. The line budget caps how
// much diff text ships, but every file also builds a section with a sticky
// header - mounting all of them at once is what made the sidebar drag janky.
// Sections mount in batches, the next batch arrives on scroll, a tree click on
// a file that is not mounted yet mounts up to it first, and sections far from
// the viewport park their rows so a drag only lays out what is on screen.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const view = fs.readFileSync(
  path.resolve(__dirname, "../../lib/clacky/default_extensions/git/panels/git/view.js"), "utf8");

function extract(signature) {
  const start = view.indexOf(signature);
  assert.ok(start >= 0, `missing ${signature}`);
  return view.slice(start, view.indexOf("\n  }\n", start) + 4);
}

const ROW_PX = 40;
const PANE_PX = 400;

// A section keeps one height until it is parked, at which point the height it
// had is frozen into the inline style. Both the scroll box and every following
// offset are derived from that, so a wrong freeze shows up as drift.
function makeSection(file, rowPx) {
  const classes = new Set();
  const section = {
    tagName: "section",
    dataset: { path: file.path },
    style: { height: "" },
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name),
      contains: (name) => classes.has(name),
      toggle: (name, on) => { if (on) classes.add(name); else classes.delete(name); },
    },
    querySelector: () => null,
    offsetHeight: rowPx,
    getBoundingClientRect() { return { height: rowPx }; },
    isParked: () => classes.has("is-parked"),
  };
  return section;
}

const heightOf = (section) => (section.style.height
  ? parseFloat(section.style.height)
  : section.offsetHeight);

function makeStream(rowPx = ROW_PX) {
  const children = [];
  const stream = {
    children,
    rowPx,
    clientHeight: PANE_PX,
    scrollState: 0,
    get scrollHeight() { return children.reduce((sum, c) => sum + heightOf(c), 0); },
    get scrollTop() {
      return Math.min(this.scrollState, Math.max(0, this.scrollHeight - this.clientHeight));
    },
    set scrollTop(v) { this.scrollState = v; },
    appendChild(node) {
      const rows = node.children || [node];
      rows.forEach((row) => children.push(row));
    },
    replaceChildren() { children.length = 0; this.scrollState = 0; },
    querySelector(selector) {
      const match = /data-path="(.*)"/.exec(selector);
      if (!match) return null;
      return children.find((c) => c.dataset.path === match[1]) || null;
    },
    querySelectorAll(selector) {
      if (selector === "section.cg-file") return children.slice();
      if (selector === "section.cg-file.is-parked") return children.filter((c) => c.isParked());
      return [];
    },
  };
  return stream;
}

function sectionTop(stream, section) {
  let top = 0;
  for (const child of stream.children) {
    if (child === section) return top;
    top += heightOf(child);
  }
  return top;
}

function installSections(stream) {
  // The view reads `section.offsetTop`; wire it to the stream's live heights.
  const build = (file) => {
    const section = makeSection(file, stream.rowPx || ROW_PX);
    Object.defineProperty(section, "offsetTop", { get: () => sectionTop(stream, section) });
    return section;
  };
  return build;
}

const state = {
  els: { stream: null },
  files: [],
  records: new Map(),
  mounted: 0,
  budget: 0,
  note: null,
  scope: "branch",
  wrap: false,
  parkTimer: null,
  spanTimer: null,
};

const ctx = vm.createContext({
  state,
  CSS: { escape: (s) => s },
  document: { createDocumentFragment: () => ({ children: [], appendChild(c) { this.children.push(c); } }) },
  t: (key) => key,
  el: (_tag, attrs) => ({ note: attrs.text }),
  buildFileSection: null,
  updateActiveRow: () => {},
  setFileCollapsed: () => {},
  highlightTreeRow: () => {},
  loadFileDiff: () => {},
  scheduleSpan: () => {},
  EMPTY_BY_SCOPE: { branch: () => "empty" },
  NOTE_BY_SCOPE: {},
  setTimeout: (fn) => { fn(); return 1; },
  clearTimeout: () => {},
});

for (const line of ["const VIEW_BUDGET_LINES = ", "const VIEW_BATCH_FILES = ", "const BATCH_AHEAD_PX = ", "const PARK_AHEAD_PX = "]) {
  const start = view.indexOf(line);
  assert.ok(start >= 0, `missing ${line}`);
  vm.runInContext(view.slice(start, view.indexOf("\n", start) + 1), ctx);
}
for (const sig of ["function renderStream(", "function mountNextBatch(", "function fillViewport(", "function focusFile(",
  "function parkSection(", "function unparkSection(", "function unparkAllSections(",
  "function parkFarSections(", "function schedulePark("]) {
  vm.runInContext(extract(sig), ctx);
}

const BATCH = vm.runInContext("VIEW_BATCH_FILES", ctx);
const PARK_AHEAD = vm.runInContext("PARK_AHEAD_PX", ctx);

const makeFiles = (n) => Array.from({ length: n }, (_v, i) => ({ path: `f${String(i).padStart(3, "0")}.rb`, diff: "" }));

function useStream(rowPx, height) {
  const stream = makeStream(rowPx);
  if (height) stream.clientHeight = height;
  state.els.stream = stream;
  ctx.buildFileSection = installSections(stream);
  return stream;
}

const stream = useStream();

state.files = makeFiles(200);
ctx.renderStream();

assert.equal(stream.children.length, BATCH, "first paint mounts exactly one batch");
assert.equal(state.mounted, BATCH);
assert.ok(stream.children.length < state.files.length, "the whole list must not be mounted");
assert.equal(state.records.size, BATCH, "only mounted files own a record");

// Park pass: everything beyond the viewport buffer drops its rows, and the
// scroll box keeps the total height it had.
const totalBefore = stream.scrollHeight;
const parkedCount = stream.children.filter((c) => c.isParked()).length;
assert.ok(parkedCount > 0, "far sections park their rows");
assert.ok(parkedCount < stream.children.length, "the visible sections stay in layout");
assert.equal(stream.scrollHeight, totalBefore, "parking must not resize the scroll box");

const nearTop = stream.children[0];
assert.equal(nearTop.isParked(), false, "the first section is on screen");
assert.equal(nearTop.style.height, "", "an awake section owns its own height");

const far = stream.children[stream.children.length - 1];
assert.equal(far.isParked(), true, "the last mounted section is far below the fold");
assert.equal(far.style.height, `${ROW_PX}px`, "the parked section remembers the height it had");
assert.equal(stream.children.reduce((sum, c) => sum + heightOf(c), 0), totalBefore,
  "frozen heights keep every offset where it was");

stream.scrollTop = stream.scrollHeight;
ctx.fillViewport();
assert.equal(state.mounted, BATCH * 2, "scrolling to the end mounts the next batch");
assert.equal(stream.children.length, BATCH * 2);

// The sections that scrolled into view wake up on the same pass.
const scrolledIn = stream.children[BATCH * 2 - 1];
assert.equal(scrolledIn.isParked(), false, "the section under the new viewport is awake");

const totalAfterMount = stream.scrollHeight;
ctx.parkFarSections();
const refrozen = stream.children[0];
assert.equal(refrozen.isParked(), true, "scrolling away parks the sections left behind");
assert.equal(stream.scrollHeight, totalAfterMount, "the scroll box still measures the same");

stream.scrollTop = 0;
ctx.parkFarSections();
assert.equal(stream.children[0].isParked(), false, "scrolling back wakes the top section");
assert.equal(stream.children[0].style.height, "", "its inline height is cleared");

// Wrapping rewraps at every width, so a frozen height would go stale: turning
// it on hands everything back to layout and later passes leave it alone.
state.wrap = true;
ctx.unparkAllSections();
stream.scrollTop = stream.scrollHeight;
ctx.parkFarSections();
assert.equal(stream.children.filter((c) => c.isParked()).length, 0,
  "wrapping mode never parks");
state.wrap = false;

// Far past the mounted rows: mounting up to the target is what keeps the tree
// click from silently doing nothing.
state.files = makeFiles(200);
ctx.renderStream();
const target = "f150.rb";
ctx.focusFile(target);
assert.ok(state.mounted > 150, `mounted ${state.mounted} rows, expected past 150`);
assert.equal(state.mounted, 180, "mounting stops at the batch holding the target");
assert.equal(state.activePath, target);
assert.ok(stream.scrollTop > 0, "the pane scrolled to the target");

// A short list is mounted in one go and stays there.
state.files = makeFiles(5);
ctx.renderStream();
assert.equal(stream.children.length, 5);
assert.equal(state.mounted, 5);
assert.equal(stream.children.filter((c) => c.isParked()).length, 0,
  "a list that fits the pane parks nothing");

// Empty scope: one note, no sections, no leftover mount counter.
state.files = [];
state.note = null;
ctx.renderStream();
assert.equal(stream.children.length, 1, "only the empty note");
assert.equal(stream.children[0].note, "empty");
assert.equal(state.mounted, 0);

// Placeholders are one line tall, so a batch may not fill the pane. The view
// has to keep mounting instead of waiting for a scroll that cannot happen.
const short = useStream(10, 1200);
state.files = makeFiles(200);
ctx.renderStream();
assert.ok(short.children.length > BATCH, "short rows top the pane up");
assert.ok(short.scrollHeight > short.clientHeight, "the stream overflows, so scrolling can continue");

// Uneven sections: freezing the measured height has to keep the offsets the
// scroll bar was computed from, or clicking a tree row lands on the wrong file.
const uneven = makeStream();
uneven.clientHeight = PANE_PX;
state.els.stream = uneven;
ctx.buildFileSection = (file) => {
  const section = makeSection(file, 10 + (Number(file.path.slice(1, 4)) % 7) * 25);
  Object.defineProperty(section, "offsetTop", { get: () => sectionTop(uneven, section) });
  return section;
};
state.files = makeFiles(120);
ctx.renderStream();
const unevenBefore = uneven.children.map((c) => sectionTop(uneven, c));
ctx.parkFarSections();
const unevenAfter = uneven.children.map((c) => sectionTop(uneven, c));
assert.deepEqual(unevenAfter, unevenBefore, "parking keeps every section at its own offset");

assert.ok(PARK_AHEAD >= PANE_PX, "the buffer must cover more than one viewport");

console.log("git panel stream batch: ok");
