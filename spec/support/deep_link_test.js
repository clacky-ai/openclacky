"use strict";

// Regression harness for external deep links (#new?prompt=…&agent=…).
//
// The shape follows claude-cli://open and claude://code/new: an outside page
// may hand a task to a fresh session, but the text only lands in the composer
// for the user to read — the link never sends anything. These tests pin the
// parsing rules and the two structural guards that keep it that way:
//   * the query is split off before path matching, so "#session/<id>?prompt=x"
//     resolves to the id, not to "x"-flavoured garbage ("<id>?prompt=x");
//   * an over-long prompt is dropped rather than truncated, because a
//     half-visible prompt is what invites a blind Enter.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = name => path.resolve(__dirname, "../../lib/clacky/web", name);

const appSource = fs.readFileSync(sourcePath("app.js"), "utf8");
const viewSource = fs.readFileSync(sourcePath("features/new-session/view.js"), "utf8");

function sliceBetween(source, startMarker, endMarker, label) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker);
  assert.ok(start !== -1, `${label}: start marker not found (${startMarker})`);
  assert.ok(end > start, `${label}: end marker not found (${endMarker})`);
  return source.slice(start, end);
}

const deepLinkBlock = sliceBetween(
  appSource,
  "const DEEP_LINK_MAX_PROMPT",
  "// Sidebar items managed by Router",
  "app.js deep-link block"
);

const context = vm.createContext({ URLSearchParams });
vm.runInContext(deepLinkBlock, context);
const parseHash = vm.runInContext("_parseHash", context);

// ── Existing routes keep working ──────────────────────────────────────────
assert.equal(Object.keys(parseHash("#new").params).length, 0, "a bare #new carries no params");
assert.equal(parseHash("#session/abc").params.id, "abc");
assert.equal(parseHash("#session/abc").view, "session");
assert.equal(parseHash("#extensions").view, "extensions");
assert.equal(parseHash("").view, "welcome", "an empty hash still lands on welcome");

// ── Prompt: decoded, multi-line, aliased ──────────────────────────────────
{
  const text = "fix the failing test\nin ~/repo";
  const r = parseHash("#new?prompt=" + encodeURIComponent(text));
  assert.equal(r.view, "welcome");
  assert.equal(r.params.deepLink.prompt, text, "URL-encoded newlines survive");
  assert.equal(r.params.deepLink.long, false);
  assert.equal(r.params.deepLink.tooLong, false);
}
{
  // claude:// and claude-cli:// both accept q; supporting it keeps links from
  // those tools working if they are ever pointed at the WebUI.
  const r = parseHash("#new?q=hello");
  assert.equal(r.params.deepLink.prompt, "hello");
}
{
  const odd = "#tag & stuff?";
  const r = parseHash("#new?prompt=" + encodeURIComponent(odd));
  assert.equal(r.params.deepLink.prompt, odd, "characters that look like URL syntax survive");
}

{
  // Third-party pages routinely form-encode (spaces as +). Both spellings must
  // resolve to the same prompt.
  const r = parseHash("#new?prompt=Review+the+last+commit");
  assert.equal(r.params.deepLink.prompt, "Review the last commit");
}

// ── Long prompts: flagged, then dropped ───────────────────────────────────
{
  const r = parseHash("#new?prompt=" + encodeURIComponent("a".repeat(1500)));
  assert.equal(r.params.deepLink.prompt.length, 1500, "a long prompt is still prefilled");
  assert.equal(r.params.deepLink.long, true, "but the notice carries a character count");
}
{
  const r = parseHash("#new?prompt=" + encodeURIComponent("c".repeat(5000)));
  assert.equal(r.params.deepLink.tooLong, false, "exactly at the limit is accepted");
}
{
  const r = parseHash("#new?prompt=" + encodeURIComponent("b".repeat(5001)));
  assert.equal(r.params.deepLink.prompt, "", "over the limit is dropped, never truncated");
  assert.equal(r.params.deepLink.tooLong, true);
  assert.equal(r.params.deepLink.max, 5000, "the notice needs the limit to explain itself");
}

// ── Agent: passed through, resolved later ─────────────────────────────────
{
  const r = parseHash("#new?agent=coding");
  assert.equal(r.params.deepLink.agent, "coding");
  assert.equal(r.params.deepLink.prompt, "", "an agent-only link fills nothing in");
}

// ── Nothing to do → no notice ─────────────────────────────────────────────
assert.equal(parseHash("#new").params.deepLink, undefined, "a plain #new must not show the notice");
assert.equal(parseHash("#new?foo=bar").params.deepLink, undefined);
assert.equal(parseHash("#new?prompt=").params.deepLink, undefined, "an empty prompt is not a link");

// ── The query must not leak into a path param (regression) ────────────────
{
  const r = parseHash("#session/abc?prompt=x");
  assert.equal(r.params.id, "abc", "the id must not swallow the query");
}

// ── Session deep links: an existing session can be handed a prompt too ────
{
  const r = parseHash("#session/abc?prompt=" + encodeURIComponent("look at this"));
  assert.equal(r.view, "session");
  assert.equal(r.params.id, "abc");
  assert.equal(r.params.deepLink.prompt, "look at this");
}
{
  const r = parseHash("#session/abc");
  assert.equal(r.params.deepLink, undefined, "opening a session by link is not a deep link");
}
{
  const r = parseHash("#session/abc?agent=coding");
  assert.equal(r.params.id, "abc");
  assert.equal(r.params.deepLink.agent, "coding", "session links honour the same agent param");
}
{
  const r = parseHash("#session/abc?prompt=" + encodeURIComponent("d".repeat(5001)));
  assert.equal(r.params.deepLink.prompt, "", "the same length gate applies to sessions");
  assert.equal(r.params.deepLink.tooLong, true);
}
{
  const r = parseHash("#extensions/ext1?source=foo");
  assert.equal(r.params.detailId, "ext1");
  assert.equal(r.params.source, "foo", "extension links keep resolving their source");
}
{
  const r = parseHash("#new?prompt=a?b");
  assert.equal(r.params.deepLink.prompt, "a?b", "a stray ? belongs to the prompt");
}

// ── Structural guards ─────────────────────────────────────────────────────
assert.equal(/\bfetch\s*\(/.test(deepLinkBlock), false,
  "parsing a deep link must not perform I/O");
assert.equal(/Sessions\./.test(deepLinkBlock), false,
  "parsing a deep link must not touch session state");

{
  const viewBlock = sliceBetween(
    viewSource,
    "function _applyDeepLinkPrompt",
    "const _pendingImages",
    "view.js deep-link block"
  );
  assert.equal(/_submit\s*\(/.test(viewBlock), false,
    "prefilling must never submit: the user presses Enter, not the link");
  assert.equal(/Sessions\.(select|sendMessage|add)\s*\(/.test(viewBlock), false,
    "prefilling must never start a session");
}

// ── View behaviour: prefilled, announced, never sent ──────────────────────
//
// The functions under test are the ones that touch the composer, so they run
// against stubs: what matters here is the contract (fill + warn, cancel on an
// emptied box, preselect without persisting), not the DOM itself.
function loadViewDeepLink() {
  const block = sliceBetween(
    viewSource,
    "let _deepLinkNotice = null;",
    "const _pendingImages",
    "view.js deep-link runtime"
  );

  const els = { "new-session-input": {}, "ns-deeplink-notice": { style: {} } };
  const calls = { setText: [], selectAgent: [], sendButton: 0 };
  const context = vm.createContext({
    $: (id) => els[id] || null,
    I18n: { t: (key, vars) => `${key}|${JSON.stringify(vars || {})}` },
    Composer: {
      setText: (el, value) => { calls.setText.push(value); el.__text = value; },
      hasContent: (el) => Boolean(el && el.__text),
    },
    NewSessionStore: {
      selectAgent: (id, opts) => { calls.selectAgent.push([id, opts]); },
    },
    _updateSendButton: () => { calls.sendButton++; },
  });
  vm.runInContext(
    block + "\nglobalThis.__deepLinkApi = { _applyDeepLinkPrompt, _applyDeepLinkAgent, _syncDeepLinkNotice };",
    context
  );
  return { els, calls, api: vm.runInContext("__deepLinkApi", context) };
}

{
  const { els, calls, api } = loadViewDeepLink();
  api._applyDeepLinkPrompt({ deepLink: { prompt: "hello", long: false, max: 5000 } });

  assert.equal(calls.setText.length, 1, "the prompt is written into the composer");
  assert.equal(calls.setText[0], "hello");
  assert.equal(calls.sendButton, 1, "the send button is refreshed so the text is sendable");
  assert.equal(els["ns-deeplink-notice"].style.display, "block", "the notice is shown");
  assert.ok(
    els["ns-deeplink-notice"].textContent.startsWith("newSession.deepLink.fromLink"),
    "a short prompt gets the plain notice"
  );

  // Clearing the box must take the notice with it.
  els["new-session-input"].__text = "";
  api._syncDeepLinkNotice();
  assert.equal(els["ns-deeplink-notice"].style.display, "none", "an emptied composer clears the notice");
  assert.equal(els["ns-deeplink-notice"].textContent, "");
}

{
  const { els, api } = loadViewDeepLink();
  api._applyDeepLinkPrompt({ deepLink: { prompt: "a".repeat(1500), long: true, max: 5000 } });
  const text = els["ns-deeplink-notice"].textContent;
  assert.ok(text.startsWith("newSession.deepLink.long"), "a long prompt gets the emphatic notice");
  assert.ok(text.includes("1500"), "and it says how long the prompt is");
}

{
  const { els, calls, api } = loadViewDeepLink();
  api._applyDeepLinkPrompt({ deepLink: { prompt: "", tooLong: true, max: 5000 } });

  assert.equal(calls.setText.length, 0, "an over-long prompt is not written into the composer at all");
  assert.equal(els["new-session-input"].__text, undefined);
  assert.ok(
    els["ns-deeplink-notice"].textContent.startsWith("newSession.deepLink.tooLong"),
    "the user is told why nothing appeared"
  );
  assert.equal(els["ns-deeplink-notice"].style.display, "block");

  // Nothing to clear means the notice must not vanish on the next input event.
  api._syncDeepLinkNotice();
  assert.equal(els["ns-deeplink-notice"].style.display, "block", "the too-long notice survives");
}

{
  const { calls, api } = loadViewDeepLink();
  api._applyDeepLinkAgent({ deepLink: { agent: "coding" } });
  assert.equal(calls.selectAgent.length, 1);
  assert.equal(calls.selectAgent[0][0], "coding");
  assert.equal(calls.selectAgent[0][1].persist, false,
    "a link from someone else's page must not become the remembered agent");

  api._applyDeepLinkAgent({});
  api._applyDeepLinkAgent(undefined);
  assert.equal(calls.selectAgent.length, 1, "a plain visit never touches the selection");
}

// ── Chat-view notice: prefilled, announced, never sent ────────────────────
//
// The welcome view renders its own notice; a link that targets an existing session
// gets the same contract from app.js. The composer there belongs to sessions.js, so
// the clearing side rides a document-level listener instead of reaching inside.
function loadChatNotice() {
  const block = sliceBetween(
    appSource,
    "// ── Chat-view deep link notice",
    "// Hide all panels.",
    "app.js chat deep-link notice block"
  );

  const listeners = [];
  const els = { "chat-deeplink-notice": { style: {} } };
  const context = vm.createContext({
    $: (id) => els[id] || null,
    I18n: { t: (key, vars) => `${key}|${JSON.stringify(vars || {})}` },
    Composer: { hasContent: (el) => Boolean(el && el.__text) },
    document: {
      addEventListener: (type, fn, capture) => listeners.push({ type, fn, capture }),
    },
  });
  vm.runInContext(
    block + "\nglobalThis.__chatApi = { _applyChatDeepLinkNotice, _renderChatDeepLinkNotice };",
    context
  );
  return { els, listeners, api: vm.runInContext("__chatApi", context) };
}

{
  const { els, listeners, api } = loadChatNotice();
  assert.equal(listeners.length, 1, "the clearing listener is registered exactly once");
  assert.equal(listeners[0].type, "input");
  assert.equal(listeners[0].capture, true, "capture phase keeps sessions.js untouched");

  api._applyChatDeepLinkNotice({ prompt: "hello", long: false, max: 5000 });
  assert.equal(els["chat-deeplink-notice"].style.display, "block", "the notice is shown");
  assert.ok(
    els["chat-deeplink-notice"].textContent.startsWith("newSession.deepLink.fromLink"),
    "a short prompt gets the plain notice"
  );

  // Clearing the box takes the notice with it.
  listeners[0].fn({ target: { id: "user-input", __text: "" } });
  assert.equal(els["chat-deeplink-notice"].style.display, "none", "an emptied composer clears the notice");

  // Typing somewhere else must not.
  api._applyChatDeepLinkNotice({ prompt: "hello", long: false, max: 5000 });
  listeners[0].fn({ target: { id: "some-other-input", __text: "" } });
  assert.equal(els["chat-deeplink-notice"].style.display, "block", "other inputs are ignored");

  // Navigating away must.
  api._applyChatDeepLinkNotice(null);
  assert.equal(els["chat-deeplink-notice"].style.display, "none");
  assert.equal(els["chat-deeplink-notice"].textContent, "");
}

{
  const { els, api } = loadChatNotice();
  api._applyChatDeepLinkNotice({ prompt: "", tooLong: true, max: 5000 });
  assert.ok(
    els["chat-deeplink-notice"].textContent.startsWith("newSession.deepLink.tooLong"),
    "an over-long prompt is explained, not filled in"
  );
  assert.equal(els["chat-deeplink-notice"].style.display, "block");
}

{
  const { els, api } = loadChatNotice();
  api._applyChatDeepLinkNotice({ prompt: "e".repeat(1500), long: true, max: 5000 });
  const text = els["chat-deeplink-notice"].textContent;
  assert.ok(text.startsWith("newSession.deepLink.long"), "a long prompt gets the emphatic notice");
  assert.ok(text.includes("1500"), "and it says how long the prompt is");
}

{
  const block = sliceBetween(
    appSource,
    "// ── Chat-view deep link notice",
    "// Hide all panels.",
    "app.js chat deep-link notice block"
  );
  assert.equal(/\bfetch\s*\(/.test(block), false, "showing a notice must not perform I/O");
  assert.equal(/Sessions\.(select|sendMessage|add|setDraft)\s*\(/.test(block), false,
    "showing a notice must not drive session state");
}

// ── Contract: the fragment the desktop app emits must land here unchanged ──
//
// open-clacky-installer turns a clacky:// URL into "new?prompt=<rfc3986>&agent=<id>&t=<ms>"
// (see deeplink.rs). The nonce is what keeps a repeated click firing hashchange, so it
// has to stay harmless to this parser.
{
  const r = parseHash("#new?prompt=%E4%BD%A0%E5%A5%BD&agent=coding&t=1758600000000");
  assert.equal(r.view, "welcome");
  assert.equal(r.params.deepLink.prompt, "你好", "the app's percent-encoding decodes here");
  assert.equal(r.params.deepLink.agent, "coding");
}
{
  const r = parseHash("#session/abc?prompt=hi&t=1758600000000");
  assert.equal(r.params.id, "abc");
  assert.equal(r.params.deepLink.prompt, "hi", "the nonce is ignored, the prompt is not");
}

console.log("deep link tests passed");
