"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = name => fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web", name), "utf8");
function extract(text, signature, indent = "  ") {
  const start = text.indexOf(signature);
  assert.ok(start >= 0);
  return text.slice(start, text.indexOf(`\n${indent}}\n`, start) + indent.length + 3);
}
const sessions = source("sessions.js");
const dispatcher = source("ws-dispatcher.js");
const live = [];
const container = {
  children: [],
  appendChild(el) { this.children.push(el); },
  querySelector() { return null; },
  insertBefore() {},
};
const escapeHtml = value => String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll('"', "&quot;");
const ctx = vm.createContext({
  window: {},
  document: { createElement: () => ({}), createDocumentFragment: () => container },
  Sessions: { appendMsg: (...args) => live.push(args), _sessionProgress: {} },
  I18n: { t: key => key },
  escapeHtml,
  _collapseToolGroup() {},
});
vm.runInContext(extract(dispatcher, "function _errorActionBtn(", ""), ctx);
vm.runInContext(extract(dispatcher, "function renderErrorEvent(", ""), ctx);
vm.runInContext(extract(dispatcher, "function _buildRawDetail(", ""), ctx);
vm.runInContext("window.renderErrorEvent = renderErrorEvent", ctx);
vm.runInContext(extract(sessions, "function _renderHistoryEvent("), ctx);
const history = { group: {}, lastItem: {} };
ctx._renderHistoryEvent({ type: "error", message: "<failed>", raw_message: "<upstream>" }, container, history);
ctx._renderHistoryEvent({ type: "error", message: "credit", code: "insufficient_credit", top_up_url: "https://example.com" }, container, history);
assert.equal(live.length, 0, "history must not use the live append path");
assert.equal(container.children.length, 2, "multiple historical errors stay visible");
assert.match(container.children[0].innerHTML, /&lt;failed>/);
assert.match(container.children[0].innerHTML, /&lt;upstream>/);
assert.doesNotMatch(container.children[1].innerHTML, /https:\/\/example.com|error-action-btn|retry-btn/);
assert.match(container.children[1].innerHTML, /error.insufficient_credit.history/);
assert.equal(history.group, null);

// Only the latest unresolved error uses the live card with actions.
const rendered = [];
Object.assign(ctx, {
  _activeId: "s", _historyState: {}, _renderedCreatedAt: {},
  _sessions: [{ id: "s", status: "error", error: "latest" }],
  RenderTarget: { outer: () => container },
  URLSearchParams, AbortController,
  _renderHistoryEvent(ev) { rendered.push(ev); }, _refreshFeedbackStatus() {}, _flushPendingStdout() {}, _refreshEditButtons() {},
  _showNewMessageBanner() {}, _hideNewMessageBanner() {}, _updateEmptyHint() {},
  fetch: async () => ({ ok: true, json: async () => ctx.response }),
});
ctx.Sessions.find = id => ctx._sessions.find(s => s.id === id);
vm.runInContext(extract(sessions, "async function _fetchHistory("), ctx);
(async () => {
  ctx.response = { has_more: true, events: [{ type: "history_user_message", created_at: 1 }, { type: "error", message: "latest" }] };
  assert.equal(await ctx._fetchHistory("s"), true);
  assert.equal(live.length, 1);
  assert.equal(rendered.filter(ev => ev.type === "error").length, 0, "current error must not appear twice");
  ctx.response.events.push({ type: "history_user_message", created_at: 2 });
  ctx._renderedCreatedAt = {};
  rendered.length = 0;
  assert.equal(await ctx._fetchHistory("s"), true);
  assert.equal(live.length, 2, "legacy current error still has an actionable card");
  assert.equal(rendered.filter(ev => ev.type === "error").length, 1, "earlier errors remain historical");
  ctx._sessions[0].status = "idle";
  ctx._renderedCreatedAt = {};
  assert.equal(await ctx._fetchHistory("s"), true);
  assert.equal(live.length, 2, "idle sessions must not offer error actions");
  ctx._sessions[0].status = "error";
  ctx.response.has_after = true;
  ctx._renderedCreatedAt = {};
  rendered.length = 0;
  assert.equal(await ctx._fetchHistory("s"), true);
  assert.equal(live.length, 2, "historical windows must not offer error actions");
  assert.equal(rendered.filter(ev => ev.type === "error").length, 1);

  const credit = { textContent: "top up now" };
  const action = { removed: false, remove() { this.removed = true; } };
  const classes = new Set();
  const oldError = {
    classList: { add: name => classes.add(name) },
    querySelectorAll: () => [action], querySelector: () => credit,
  };
  container.querySelectorAll = () => [oldError];
  const start = sessions.indexOf("    archiveErrors() {");
  const end = sessions.indexOf("\n    },", start) + "\n    },".length;
  ctx.Sessions.archiveErrors = vm.runInContext(`({${sessions.slice(start, end)}}).archiveErrors`, ctx);
  ctx.Sessions.archiveErrors();
  assert.ok(classes.has("msg-history-error"));
  assert.ok(action.removed, "continuing must remove the old actions");
  assert.equal(credit.textContent, "error.insufficient_credit.history");
  console.log("Session error history checks passed");
})().catch(error => { console.error(error); process.exitCode = 1; });
