"use strict";

// Streaming replies used to append raw text nodes, so users watched markdown
// source until the final assistant_message replaced the preview. The preview
// must now be painted through the markdown renderer.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/sessions.js"), "utf8");

function slice(from, to) {
  const start = source.indexOf(from);
  assert.ok(start >= 0, `missing ${from}`);
  const end = source.indexOf(to, start);
  assert.ok(end >= 0, `missing end of ${from}`);
  return source.slice(start, end + to.length);
}

const timers = [];
const host = { appendChild() {} };
const Sessions = { _assistantStreams: new Map(), _sessionProgress: {} };
const ctx = vm.createContext({
  Sessions,
  RenderTarget: { current: () => host },
  document: {
    createElement: () => ({
      className: "",
      dataset: {},
      innerHTML: "",
      isConnected: true,
      removed: false,
      remove() { this.removed = true; },
    }),
  },
  setTimeout: (fn) => { timers.push(fn); return timers.length; },
  clearTimeout: (id) => { timers[id - 1] = null; },
  Date: { now: () => 0 },
  _renderMarkdown: (text) => `<md>${text}</md>`,
  _scrollToBottomIfNeeded() {},
});

vm.runInContext(
  slice("function _paintAssistantStream(", "\n  }\n") + "\n" +
  "Sessions.appendAssistantDelta = function " +
    slice("appendAssistantDelta(ev) {", "\n    },").replace(/,\s*$/, "") + ";\n" +
  "Sessions.clearAssistantStreams = function " +
    slice("clearAssistantStreams(ev = null) {", "\n    },").replace(/,\s*$/, "") + ";\n",
  ctx
);

Sessions.appendAssistantDelta({ session_id: "s1", message_id: "m1", seq: 1, delta: "## 标题\n" });
Sessions.appendAssistantDelta({ session_id: "s1", message_id: "m1", seq: 2, delta: "**加粗**" });

const el = Sessions._assistantStreams.get("s1:m1").el;
assert.equal(el.innerHTML, "", "nothing paints before the deferred frame");
assert.equal(el.className, "msg msg-assistant msg-streaming");
assert.equal(timers.length, 1, "deltas within one frame share a single paint");

timers[0]();
assert.equal(el.innerHTML, "<md>## 标题\n**加粗**</md>", "the whole preview is rendered as markdown");
assert.equal(el.dataset.raw, "## 标题\n**加粗**", "raw markdown stays available for copy");

Sessions.appendAssistantDelta({ session_id: "s1", message_id: "m1", seq: 2, delta: "stale" });
assert.equal(Sessions._assistantStreams.get("s1:m1").content, "## 标题\n**加粗**", "duplicate seq is ignored");

Sessions.clearAssistantStreams({ session_id: "s1", message_id: "m1" });
assert.equal(el.removed, true, "the preview element is removed once the final message arrives");
assert.equal(Sessions._assistantStreams.size, 0);
