"use strict";

// Regression harness for the first-paint reveal of #app.
//
// The first session_list can arrive before DOMContentLoaded, because the
// extension scripts load after app.js. Modules restore their persisted layout
// (aside collapsed / width, project list) in their DOMContentLoaded init, so
// revealing earlier showed the default layout and then animated to the saved
// one (the right aside popped open and slid shut on refresh). These tests pin
// that the reveal waits for the DOM, and that it still runs exactly once.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const appSource = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/app.js"), "utf8");

function sliceBetween(source, startMarker, endMarker, label) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker);
  assert.ok(start !== -1, `${label}: start marker not found (${startMarker})`);
  assert.ok(end > start, `${label}: end marker not found (${endMarker})`);
  return source.slice(start, end);
}

const revealBlock = sliceBetween(
  appSource,
  "function _revealApp()",
  "// Core: apply a view change.",
  "app.js reveal block"
);

function makeEnv(readyState) {
  const listeners = {};
  const rootClasses = new Set(["booting"]);
  const frames = [];
  const env = {
    applyAllCalls: 0,
    appEl: { style: { visibility: "hidden" } },
    listeners,
    rootClasses,
    flushFrames() {
      while (frames.length) frames.shift()();
    },
    fireDomReady() {
      env.document.readyState = "interactive";
      const list = listeners.DOMContentLoaded || [];
      listeners.DOMContentLoaded = [];
      list.forEach(({ fn }) => fn());
    },
  };
  env.document = {
    readyState,
    getElementById: id => (id === "app" ? env.appEl : null),
    addEventListener(type, fn, opts) {
      (listeners[type] = listeners[type] || []).push({ fn, opts });
    },
    documentElement: { classList: { remove: c => rootClasses.delete(c) } },
  };
  const context = vm.createContext({
    document: env.document,
    I18n: { applyAll: () => { env.applyAllCalls += 1; } },
    requestAnimationFrame: fn => frames.push(fn),
  });
  vm.runInContext(revealBlock, context);
  env.reveal = vm.runInContext("_revealApp", context);
  return env;
}

// ── DOM still loading: reveal is deferred to DOMContentLoaded ─────────────
{
  const env = makeEnv("loading");
  env.reveal();
  assert.equal(env.appEl.style.visibility, "hidden", "must not reveal before DOMContentLoaded");
  assert.equal(env.applyAllCalls, 0, "i18n waits for the reveal too");
  assert.equal(env.listeners.DOMContentLoaded.length, 1);
  assert.equal(env.listeners.DOMContentLoaded[0].opts.once, true);

  // A second navigation before the DOM is ready (e.g. session → welcome
  // fallback) still reveals only once.
  env.reveal();
  env.fireDomReady();
  assert.equal(env.appEl.style.visibility, "", "revealed once the DOM is ready");
  assert.equal(env.applyAllCalls, 1, "applyAll runs exactly once");
  assert.ok(env.rootClasses.has("booting"), "booting stays until frames commit");
  env.flushFrames();
  assert.ok(!env.rootClasses.has("booting"), "booting removed after two frames");
}

// ── DOM already parsed: reveal immediately ───────────────────────────────
for (const state of ["interactive", "complete"]) {
  const env = makeEnv(state);
  env.reveal();
  assert.equal(env.appEl.style.visibility, "", `reveals immediately when readyState=${state}`);
  assert.equal((env.listeners.DOMContentLoaded || []).length, 0);
  env.flushFrames();
  assert.ok(!env.rootClasses.has("booting"));
}

// ── Later navigations are no-ops ──────────────────────────────────────────
{
  const env = makeEnv("complete");
  env.reveal();
  env.flushFrames();
  env.rootClasses.add("booting");  // sentinel: a repeat reveal must not touch it
  env.reveal();
  env.flushFrames();
  assert.equal(env.applyAllCalls, 1, "already-visible #app is left alone");
  assert.ok(env.rootClasses.has("booting"));
}

// ── _apply goes through _revealApp ────────────────────────────────────────
const applyBlock = sliceBetween(appSource, "async function _apply(", "// ── Activate target panel", "app.js _apply head");
assert.ok(applyBlock.includes("_revealApp();"), "_apply must reveal via _revealApp");
assert.ok(!applyBlock.includes('style.visibility = ""'), "_apply must not reveal #app inline");
