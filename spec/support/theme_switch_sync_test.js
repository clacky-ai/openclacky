"use strict";

// Switching themes must repaint every region in the same frame: per-element
// transitions are frozen while data-theme flips, and the page cross-fades as one.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/theme.js"), "utf8");

function boot({ viewTransition, reduceMotion = false }) {
  const classes = new Set();
  const log = [];
  const frames = [];
  const listeners = [];
  const root = {
    attrs: {},
    classList: {
      add: c => { classes.add(c); log.push(`add:${c}`); },
      remove: c => { classes.delete(c); log.push(`remove:${c}`); },
    },
    setAttribute(k, v) { this.attrs[k] = v; log.push(`attr:${v}:${classes.has("theme-switching")}`); },
    getAttribute(k) { return this.attrs[k]; },
    get offsetWidth() { log.push("reflow"); return 0; },
  };
  const document = { documentElement: root, querySelectorAll: () => [] };
  if (viewTransition) document.startViewTransition = cb => { log.push("view-transition"); cb(); };
  const store = {};
  const ctx = vm.createContext({
    document,
    localStorage: { getItem: k => store[k] || null, setItem: (k, v) => { store[k] = v; }, removeItem: k => { delete store[k]; } },
    window: {
      matchMedia: q => ({
        matches: q.includes("reduced-motion") ? reduceMotion : false,
        addEventListener: (_e, fn) => listeners.push(fn),
      }),
      dispatchEvent() {},
    },
    CustomEvent: function CustomEvent() {},
    requestAnimationFrame: fn => frames.push(fn),
  });
  ctx.window.document = document;
  vm.runInContext(source + "\nthis.Theme = Theme;", ctx);
  log.length = 0;
  return { Theme: ctx.Theme, log, frames, classes, listeners };
}

{
  const w = boot({ viewTransition: false });
  w.Theme.apply("dark");
  assert.deepEqual(w.log, ["add:theme-switching", "attr:dark:true", "reflow"], "data-theme flips while transitions are frozen");
  assert.ok(w.classes.has("theme-switching"));
  w.frames.forEach(fn => fn());
  assert.ok(!w.classes.has("theme-switching"), "transitions come back on the next frame");
}

{
  const w = boot({ viewTransition: true });
  w.Theme.apply("dark");
  assert.equal(w.log[0], "view-transition", "the whole page cross-fades as one");
  assert.ok(w.log.includes("attr:dark:true"));
}

{
  const w = boot({ viewTransition: true, reduceMotion: true });
  w.Theme.apply("dark");
  assert.ok(!w.log.includes("view-transition"), "reduced motion skips the cross-fade");
  assert.ok(w.log.includes("attr:dark:true"));
}

{
  const w = boot({ viewTransition: false });
  w.listeners.forEach(fn => fn());
  assert.ok(w.log.includes("add:theme-switching"), "following the OS theme is synced too");
}

console.log("Theme switch sync checks passed");
