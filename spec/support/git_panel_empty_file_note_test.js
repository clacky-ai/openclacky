"use strict";

// A file with no hunks is either empty (created/deleted) or only changed its
// mode/name; the note must tell those apart instead of always saying "no change".

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

const lazyCalls = [];
const ctx = vm.createContext({
  state: { records: new Map(), budget: 0 },
  t: key => key,
  el: (_tag, attrs) => ({ note: attrs.text }),
  renderLazy: (_section, file) => lazyCalls.push(file.path),
});
for (const sig of ["function classify(", "function parseHunks(", "function renderFileBody("]) {
  vm.runInContext(extract(sig), ctx);
}

function noteFor(file, record = {}) {
  const children = [];
  const lines = { replaceChildren() {}, classList: { remove() {} }, appendChild: c => children.push(c) };
  ctx.state.records = new Map([[file.path, record]]);
  ctx.renderFileBody({ querySelector: () => lines }, file);
  return children.map(c => c.note);
}

const head = (path, extra) => `diff --git a/${path} b/${path}\n${extra}\n`;

assert.deepEqual(noteFor({ path: "e.txt", untracked: true,
  diff: head("e.txt", "new file mode 100644\nindex 0000000..e69de29") }), ["changes.diff.emptyNew"], "untracked empty file");
assert.deepEqual(noteFor({ path: "e.txt", x: "A", y: ".",
  diff: head("e.txt", "new file mode 100644\nindex 0000000..e69de29") }), ["changes.diff.emptyNew"], "staged empty file");
assert.deepEqual(noteFor({ path: "e.txt", x: "D", y: ".",
  diff: head("e.txt", "deleted file mode 100644\nindex e69de29..0000000") }), ["changes.diff.emptyNew"], "deleted empty file");
assert.deepEqual(noteFor({ path: "run.sh", x: ".", y: "M",
  diff: head("run.sh", "old mode 100644\nnew mode 100755") }), ["changes.diff.same"], "mode-only change");
assert.deepEqual(noteFor({ path: "e.txt", x: "A", y: ".", diff: "" }), ["changes.diff.emptyNew"], "empty diff on an added file");
assert.deepEqual(noteFor({ path: "m.rb", x: ".", y: "M", diff: "" }), ["changes.diff.same"], "empty diff on a modified file");

assert.deepEqual(noteFor({ path: "big.rb", x: ".", y: "M", diff: "" }, { lazyPending: true }), []);
assert.deepEqual(lazyCalls, ["big.rb"], "a pending lazy file still shows the load-on-click placeholder");

console.log("Git panel empty file note checks passed");
