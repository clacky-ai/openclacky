"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sessions = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/sessions.js"), "utf8");
const start = sessions.indexOf("function _renderHistoryEvent(");
assert.ok(start >= 0);
const renderSource = sessions.slice(start, sessions.indexOf("\n  }\n", start) + 4);

function makeItem(name) {
  const status = { className: "tool-item-status running", textContent: "…" };
  const stdout = { textContent: "", innerHTML: "", style: {} };
  const item = {
    dataset: { toolName: name },
    querySelector(sel) {
      if (sel === ".tool-item-status") return status;
      if (sel === ".tool-item-stdout") return stdout;
      return null;
    },
    status,
    stdout,
  };
  status.closest = () => item;
  return item;
}

function makeGroup() {
  const items = [];
  return {
    items,
    querySelector(sel) {
      if (sel !== ".tool-item-status.running") return null;
      const hit = items.find(i => i.status.className.includes("running"));
      return hit ? hit.status : null;
    },
  };
}

const ctx = vm.createContext({
  _makeToolGroup: makeGroup,
  _addToolCallToGroup(group, name) { const item = makeItem(name); group.items.push(item); return item; },
  _renderEditWriteDiff() {},
  _ansiToHtml: s => s,
  _collapseToolGroup() {},
});
vm.runInContext(renderSource, ctx);

const container = { appendChild() {} };
const history = { group: null, lastItem: null };
ctx._renderHistoryEvent({ type: "tool_call", name: "terminal", args: {} }, container, history);
ctx._renderHistoryEvent({ type: "tool_call", name: "browser", args: {} }, container, history);
ctx._renderHistoryEvent({ type: "tool_result", result: "terminal out" }, container, history);
ctx._renderHistoryEvent({ type: "tool_result", result: "browser out" }, container, history);

const [terminal, browser] = history.group.items;
assert.equal(terminal.status.textContent, "✓", "earlier call in a batch must be completed");
assert.equal(browser.status.textContent, "✓");
assert.equal(terminal.stdout.innerHTML, "terminal out", "first result belongs to the first call");
assert.equal(browser.stdout.innerHTML, "browser out", "second result belongs to the second call");

// A call whose result never arrived (interrupted) keeps its running state.
const pending = { group: null, lastItem: null };
ctx._renderHistoryEvent({ type: "tool_call", name: "edit", args: {} }, container, pending);
ctx._renderHistoryEvent({ type: "tool_call", name: "write", args: {} }, container, pending);
ctx._renderHistoryEvent({ type: "tool_result", result: "edit out" }, container, pending);
assert.equal(pending.group.items[0].stdout.innerHTML, "edit out");
assert.equal(pending.group.items[1].status.textContent, "…");
