"use strict";

// Regression harness: opening the scheduled-tasks page must not throw.
//
// Router._apply stamps the sidebar highlight after the view renders, so any
// exception escaping onPanelShow() silently leaves the page with no active
// menu item. Booting the view is enough to catch it: state is read on the very
// first call, before any DOM is touched.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const view = fs.readFileSync(
  path.resolve(__dirname, "../../lib/clacky/web/features/tasks/view.js"),
  "utf8"
);

const errors = [];
const sandbox = {
  console,
  window: {},
  $: () => null,
  escapeHtml: s => String(s == null ? "" : s),
  I18n: { t: k => k, lang: () => "zh" },
  Router: { current: "tasks" },
  TasksStore: { state: { tasks: [] } },
  Tasks: {
    on() {},
    load() {},
    loadRuns() {},
  },
  document: {
    querySelectorAll: () => [],
    getElementById: () => null,
    createElement: () => ({ style: {}, classList: { add() {}, remove() {} }, appendChild() {} }),
    addEventListener() {},
  },
};

sandbox.globalThis = sandbox;
vm.createContext(sandbox);

try {
  vm.runInContext(view, sandbox, { filename: "features/tasks/view.js" });
} catch (err) {
  errors.push(`load: ${err.message}`);
}

try {
  sandbox.Tasks.onPanelShow();
} catch (err) {
  errors.push(`onPanelShow: ${err.message}`);
}

assert.deepEqual(errors, [], `tasks view failed to boot:\n${errors.join("\n")}`);
console.log("tasks view booted without errors");
