"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = name => fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web", name), "utf8");
function extract(text, signature, indent = "  ") {
  const start = text.indexOf(signature);
  assert.ok(start >= 0, `missing ${signature}`);
  return text.slice(start, text.indexOf(`\n${indent}}\n`, start) + indent.length + 3);
}
function method(text, name) {
  const start = text.indexOf(`    ${name}(`);
  assert.ok(start >= 0, `missing ${name}`);
  const end = text.indexOf("\n    },", start) + "\n    },".length;
  return text.slice(start, end);
}

const sessions = source("sessions.js");
const dispatcher = source("ws-dispatcher.js");
const infos = [];
const ctx = vm.createContext({
  _recentlyDone: new Map(), _activeId: null, _unseenSummary: null, DONE_DOT_TTL: 1000,
  setTimeout: () => 1, clearTimeout() {},
  I18n: { t: (key, vars) => `${key}:${JSON.stringify(vars || {})}` },
  Sessions: { appendMsg: (...a) => { throw new Error("history failed: " + a.join()); }, renderList() {}, appendInfo: (text, sub) => infos.push([text, sub]) },
});
for (const name of ["markDone", "markDoneSummary", "clearDone", "appendCompleteSummary"]) {
  ctx.Sessions[name] = vm.runInContext(`({${method(sessions, name)}}).${name}`, ctx);
}
const ev = { iterations: 3, cost: 0.25, cost_source: "api", duration: 2,
  cache_stats: { total_requests: 4, cache_hit_requests: 2, cache_read_input_tokens: 1500 } };

// Live `complete` and the deferred replay share one renderer.
assert.match(dispatcher, /case "complete":[\s\S]*?Sessions\.appendCompleteSummary\(ev\);/);
assert.match(dispatcher, /case "task_finished":[\s\S]*?Sessions\.markDoneSummary\(ev\.session_id, ev\.complete\)/);
ctx.Sessions.appendCompleteSummary(ev);
assert.match(infos[0][0], /^✓ chat\.done:\{"n":3,"cost":"\$0\.2500"\}chat\.done\.duration:\{"duration":"2\.0"\}$/);
assert.match(infos[0][1], /chat\.done\.cache:.*"rate":"50\.0".*"tokens":"1\.5k"/);
infos.length = 0;

// The summary rides on the done dot and is handed out exactly once.
ctx.Sessions.markDoneSummary("a", ev);
assert.equal(ctx.Sessions.clearDone("a"), null, "no dot, nothing to keep");
ctx.Sessions.markDone("a");
ctx.Sessions.markDoneSummary("a", ev);
assert.equal(ctx.Sessions.clearDone("a"), ev);
assert.equal(ctx.Sessions.clearDone("a"), null, "seen summaries are gone");
ctx._activeId = "b";
ctx.Sessions.markDone("b");
ctx.Sessions.markDoneSummary("b", ev);
assert.equal(ctx._recentlyDone.has("b"), false, "the open session keeps the live summary only");
ctx._activeId = null;
ctx.Sessions.markDone("c");
ctx.Sessions.markDoneSummary("c", ev);
ctx.Sessions.markDone("c");
assert.equal(ctx.Sessions.clearDone("c"), null, "a new turn drops the stale summary");

// Opening the session appends the unseen summary after its history.
ctx.Sessions.markDone("s");
ctx.Sessions.markDoneSummary("s", ev);
const setActive = method(sessions, "_setActiveId");
const head = setActive.slice(0, setActive.indexOf("\n", setActive.indexOf("_unseenSummary =")) + 1);
vm.runInContext(`(function ${head.trim().replace(/^_setActiveId/, "")} })`, ctx)("s");
assert.equal(ctx._unseenSummary.id, "s");
assert.equal(ctx._unseenSummary.ev, ev);

const container = { appendChild() {}, querySelector() { return null; }, insertBefore() {}, firstChild: null };
Object.assign(ctx, {
  _activeId: "s", _historyState: {}, _renderedCreatedAt: {}, _sessions: [{ id: "s", status: "idle" }],
  _userScrolledUp: false,
  RenderTarget: { outer: () => container },
  document: { createDocumentFragment: () => ({}), createElement: () => ({}) },
  window: {}, URLSearchParams, AbortController,
  escapeHtml: String, _renderHistoryEvent() {}, _refreshFeedbackStatus() {}, _flushPendingStdout() {}, _refreshEditButtons() {},
  _showNewMessageBanner() {}, _hideNewMessageBanner() {}, _updateEmptyHint() {},
  fetch: async () => ({ ok: true, json: async () => ({ has_more: false, events: [] }) }),
});
ctx.Sessions._sessionProgress = {};
vm.runInContext(extract(sessions, "async function _fetchHistory("), ctx);
(async () => {
  assert.equal(await ctx._fetchHistory("s"), true);
  assert.equal(infos.length, 1, "unseen summary shown on first open");
  assert.equal(ctx._unseenSummary, null);
  assert.equal(await ctx._fetchHistory("s"), true);
  assert.equal(infos.length, 1, "shown only once");
  console.log("Unread task summary checks passed");
})().catch(error => { console.error(error); process.exitCode = 1; });
