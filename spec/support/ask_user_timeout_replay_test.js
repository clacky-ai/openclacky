"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sessions = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/sessions.js"), "utf8");
function extract(signature) {
  const start = sessions.indexOf(signature);
  assert.ok(start >= 0, signature);
  return sessions.slice(start, sessions.indexOf("\n  }\n", start) + 4);
}

const rendered = [];
const container = { appendChild() {}, insertBefore() {}, querySelector() { return null; }, firstChild: null };
const ctx = vm.createContext({
  _activeId: "s", _historyState: {}, _renderedCreatedAt: {}, _unseenSummary: null,
  _sessions: [{ id: "s", status: "idle" }],
  Sessions: { _sessionProgress: {}, appendMsg(_k, msg) { throw new Error(msg); } },
  window: {}, I18n: { t: k => k }, escapeHtml: s => s, _userScrolledUp: false, _collapseToolGroup() {},
  RenderTarget: { outer: () => container },
  document: { createDocumentFragment: () => container, createElement: () => ({}) },
  URLSearchParams, AbortController,
  _renderHistoryEvent(ev) { if (ev.type === "request_feedback") rendered.push(ev._answered); },
  _refreshFeedbackStatus() {}, _flushPendingStdout() {}, _refreshEditButtons() {},
  _showNewMessageBanner() {}, _hideNewMessageBanner() {}, _updateEmptyHint() {},
  fetch: async () => ({ ok: true, json: async () => ctx.response }),
});
vm.runInContext(extract("async function _fetchHistory("), ctx);

async function answeredStates(events, extra = {}) {
  ctx._renderedCreatedAt = {};
  ctx._historyState = {};
  rendered.length = 0;
  ctx.response = Object.assign({ events }, extra);
  assert.equal(await ctx._fetchHistory("s"), true);
  return rendered.slice();
}

const user = text => ({ type: "history_user_message", content: text, created_at: Math.random() });
const ask = () => ({ type: "request_feedback", question: "color?", options: ["red", "blue"] });

(async () => {
  // Auto-approve timeout: the agent replied on its own, so the card must stay closed after reload.
  assert.deepEqual(
    await answeredStates([user("go"), ask(), { type: "token_usage" }, { type: "tool_result" },
                          { type: "assistant_message", content: "defaulting to blue" }]),
    ["chat.feedback_timeout"]
  );

  // A user reply closes the card as submitted.
  assert.deepEqual(await answeredStates([user("go"), ask(), { type: "token_usage" }, user("blue")]),
                   ["chat.feedback_answered"]);

  // The last pending question remains interactive.
  assert.deepEqual(await answeredStates([user("go"), ask(), { type: "token_usage" }]), [null]);

  // A window that is not the newest page never offers a live card.
  assert.deepEqual(await answeredStates([user("go"), ask()], { has_after: true }), ["chat.feedback_answered"]);

  // Consecutive questions: the earlier one was superseded by the agent, the latest is still open.
  assert.deepEqual(await answeredStates([user("go"), ask(), { type: "tool_result" }, { type: "tool_call" }, ask()]),
                   ["chat.feedback_timeout", null]);
})().catch(err => { console.error(err); process.exit(1); });
