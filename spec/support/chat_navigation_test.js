"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class Element {
  constructor() {
    this.style = { setProperty(name, value) { this[name] = value; } };
    this.dataset = {};
    this.attrs = {};
    this.children = [];
    this.handlers = {};
    this.clientHeight = 360;
    this.clientWidth = this.offsetWidth = 500;
    this.offsetHeight = 110;
    this.scrollHeight = 1000;
    this.scrollTop = 0;
    this.isConnected = true;
    this.hidden = false;
    this.classes = new Set();
    this.classList = { toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name) };
  }
  setAttribute(key, value) { this.attrs[key] = value; }
  removeAttribute(key) { delete this.attrs[key]; }
  addEventListener(key, fn) { this.handlers[key] = fn; }
  appendChild(child) { child.parentNode = this; this.children.push(...(child.fragment ? child.children : [child])); }
  remove() { if (this.parentNode) this.parentNode.children = this.parentNode.children.filter(child => child !== this); }
  replaceChildren(...children) { this.children = []; children.forEach(child => this.appendChild(child)); }
  insertBefore(child) { this.children.unshift(...(child.fragment ? child.children : [child])); }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  getBoundingClientRect() { return { top: 40, bottom: 400, height: 360, left: 0, right: 500, width: 500 }; }
  get firstChild() { return this.children[0]; }
}

const document = {
  createElement: () => new Element(),
  createDocumentFragment: () => Object.assign(new Element(), { fragment: true }),
  getElementById: () => null,
};
const sourcePath = name => path.resolve(__dirname, "../../lib/clacky/web", name);

function loadMarkdownPreview(context) {
  vm.runInContext(fs.readFileSync(sourcePath("vendor/marked/marked.min.js"), "utf8"), context);
  const app = fs.readFileSync(sourcePath("app.js"), "utf8");
  vm.runInContext(app.slice(app.indexOf("function escapeHtml("), app.indexOf("// ── Router")), context);
  vm.runInContext(fs.readFileSync(sourcePath("utils.js"), "utf8"), context);
}

function markdownPreviewTests() {
  const context = vm.createContext({});
  loadMarkdownPreview(context);
  const render = vm.runInContext("MarkdownPreview.render", context);
  assert.equal(render("查完了，**通用分组**，`GROUPED_SOURCES`，*完成*。"),
    "查完了，<strong>通用分组</strong>，<code>GROUPED_SOURCES</code>，<em>完成</em>。");
  assert.equal(render("# Heading\n\n- **First**\n- Second\n\n> Quote"),
    "Heading <strong>First</strong> Second Quote");
  assert.equal(render("```html\n<img src=x onerror=alert(1)>\n```"),
    "<code>&lt;img src=x onerror=alert(1)&gt;</code>");
  assert.equal(render("`List<T>` & text"), "<code>List&lt;T&gt;</code> &amp; text");
  assert.equal(render("[**Link**](javascript:alert(1)) ![image](https://example.com/image.png)"), "<strong>Link</strong>");
  assert.equal(render("<script>alert(1)</script>\n\nSafe <img src=x onerror=alert(1)>"), "Safe");
  assert.equal(render("| Name | Value |\n| --- | --- |\n| **Key** | `value` |"),
    "Name Value <strong>Key</strong> <code>value</code>");
  assert.equal(render("- [x] Done\n- [ ] Pending"), "Done Pending");
  assert.equal(render("```js\nconst value = 1;"), "<code>const value = 1;</code>", "accepts a truncated code fence");
  assert.equal(render(""), "");
  assert.match(context.marked.parse("# Heading"), /<h1>/, "preview renderer does not change global marked defaults");
  context.marked = { ...context.marked, parse: () => { throw new Error("malformed Markdown"); } };
  assert.equal(render("<broken>"), "&lt;broken&gt;");
  context.marked = undefined;
  assert.equal(render("<fallback>"), "&lt;fallback&gt;");
}

async function navigatorTests() {
  const nodes = Object.fromEntries(["nav", "track", "canvas", "popup", "userPreview", "answerPreview", "messages", "chatMain"].map(key => [key, new Element()]));
  const context = vm.createContext({
    window: {}, document, console, URLSearchParams, AbortController,
    setTimeout, clearTimeout, I18n: { t: key => key },
    Sessions: { activeId: "test", jumpToHistory: async () => true, isHistoricalWindow: () => false },
    getComputedStyle: () => ({ width: "40px", getPropertyValue: () => "12px" }),
    ...nodes,
  });
  loadMarkdownPreview(context);
  vm.runInContext("const originalRender = MarkdownPreview.render; let renderCalls = 0; MarkdownPreview.render = text => { renderCalls++; return originalRender(text); };", context);
  let source = fs.readFileSync(sourcePath("components/chat-navigator.js"), "utf8");
  source = source.replace("window.ChatNavigator = {", `window.testing = {
    configure(data, nodes, cached = true) {
      items = data; ({nav, track, canvas, popup, userPreview, answerPreview, messages, chatMain} = nodes);
      sessionId = 'test'; hoveredIdx = -1; pointerY = null;
      _cancelPreview(); clearTimeout(hideTimer); loading = failed = jumping = false;
      previews.clear(); if (cached) data.forEach(item => previews.set(item.id, item));
    },
    _hover, _hide, _nearest, _tickY, _renderTicks, _renderPreview, _jump, _loadIndex, _syncBounds, _cancelPreview,
    state() { return {items, activeIdx, hoveredIdx, loading, failed, previewFailure, cacheSize: previews.size}; },
    requestPreviewNow() { clearTimeout(previewTimer); previewDue = true; return _loadPreview(); },
    setLoading(value) { loading = value; },
  }; window.ChatNavigator = {`);
  vm.runInContext(source, context);
  const api = context.window.testing;
  const entries = Array.from({ length: 1000 }, (_, i) => ({ id: JSON.stringify(["live", i, "v1"]), user: `Question ${i}`, assistant: `Answer ${i}` }));
  api.configure(entries, nodes);
  api._renderTicks();
  assert.ok(nodes.canvas.children.length < 50, "virtualizes thousands of ticks");

  nodes.messages.querySelectorAll = () => entries.slice(0, 2).map((item, i) => ({
    querySelector: () => ({ dataset: { roundId: item.id } }),
    getBoundingClientRect: () => ({ top: i === 0 ? -100 : 100 }),
  }));
  nodes.messages.scrollTop = nodes.messages.scrollHeight - nodes.messages.clientHeight;
  context.window.ChatNavigator.syncMessages();
  assert.equal(api.state().activeIdx, 1, "at the latest bottom, selects the last loaded turn even below the top threshold");
  context.Sessions.isHistoricalWindow = () => true;
  context.window.ChatNavigator.syncMessages();
  assert.equal(api.state().activeIdx, 0, "the bottom of a historical page keeps position-based highlighting");
  context.Sessions.isHistoricalWindow = () => false;
  nodes.messages.scrollTop -= 20;
  context.window.ChatNavigator.syncMessages();
  assert.equal(api.state().activeIdx, 0, "near the bottom is not the same as reaching it");
  nodes.messages.scrollTop = nodes.messages.scrollHeight - nodes.messages.clientHeight - 0.5;
  context.window.ChatNavigator.syncMessages();
  assert.equal(api.state().activeIdx, 1, "fractional scroll rounding does not prevent bottom detection");
  delete nodes.messages.querySelectorAll;
  nodes.messages.scrollTop = 0;
  context.window.ChatNavigator.syncMessages();

  const tickPositions = entries.map((_, i) => api._tickY(i));
  const canvasHeight = nodes.canvas.style.height;
  api._hover(86); // exactly between two baseline ticks, rather than on a tick
  assert.ok(api.state().hoveredIdx >= 0, "gaps select nearest tick");
  assert.deepEqual(entries.map((_, i) => api._tickY(i)), tickPositions, "hover does not move any tick vertically");
  assert.equal(nodes.canvas.style.height, canvasHeight, "hover does not change the track content height");
  assert.equal(nodes.popup.hidden, false);
  const index = api.state().hoveredIdx;
  assert.equal(nodes.userPreview.innerHTML, `Question ${index}`);
  assert.equal(nodes.answerPreview.innerHTML, `Answer ${index}`);
  const renderCalls = vm.runInContext("renderCalls", context);
  api._renderPreview();
  assert.equal(vm.runInContext("renderCalls", context), renderCalls, "unchanged preview is not parsed again");
  entries[index].assistant = "**Updated** `answer`";
  api._renderPreview();
  assert.equal(nodes.answerPreview.innerHTML, "<strong>Updated</strong> <code>answer</code>", "new reply updates the cached preview");
  assert.ok(nodes.canvas.children.find(tick => tick.id === `chat-nav-tick-${index}`).classes.has("hovered"));
  const css = fs.readFileSync(sourcePath("app.css"), "utf8");
  const hoveredStyle = css.match(/\.chat-nav-bar\.hovered\s*\{([^}]+)\}/)[1];
  assert.match(hoveredStyle, /background:\s*var\(--color-accent-primary\)/);
  assert.match(hoveredStyle, /opacity:\s*1;/);
  assert.equal(nodes.canvas.children.find(tick => tick.id === `chat-nav-tick-${index}`).style.width, "30px");
  assert.equal(nodes.canvas.children.find(tick => tick.id === `chat-nav-tick-${index + 1}`).style.width, "24px",
    "neighbors still expand horizontally");
  assert.equal(api._tickY(index + 1) - api._tickY(index), 12, "neighbors keep their original spacing");
  const neighborY = api._tickY(index + 1);
  api._hover(neighborY);
  api._hover(neighborY);
  assert.equal(api.state().hoveredIdx, index + 1, "selection stays stable at visual center");
  api._hover(1);
  assert.equal(nodes.popup.style.top, "0px", "preview stays below toolbar");
  api._hover(359);
  assert.ok(parseFloat(nodes.popup.style.top) + nodes.popup.offsetHeight <= 360, "preview stays above composer");
  let target;
  context.Sessions.jumpToHistory = async id => { target = id; return true; };
  await api._jump();
  assert.equal(target, entries[api.state().hoveredIdx].id, "unloaded target uses source locator");

  api.configure(entries, nodes);
  nodes.track.scrollTop = parseFloat(canvasHeight) - nodes.track.clientHeight;
  api._renderTicks();
  const bottomScroll = nodes.track.scrollTop;
  for (const y of [1, 180, 359]) {
    api._hover(y);
    assert.deepEqual(entries.map((_, i) => api._tickY(i)), tickPositions, "hover near the bottom keeps all tick positions fixed");
    assert.equal(nodes.canvas.style.height, canvasHeight);
    assert.equal(nodes.track.scrollTop, bottomScroll, "hover does not shift the navigation scroll position");
    assert.equal(api._nearest(api._tickY(api.state().hoveredIdx) - bottomScroll), api.state().hoveredIdx,
      "scrolled ticks remain selectable at their visible centers");
  }
  api._hide();
  await new Promise(resolve => setTimeout(resolve, 180));
  assert.equal(nodes.popup.hidden, true);
  assert.deepEqual(entries.map((_, i) => api._tickY(i)), tickPositions, "leaving hover keeps tick positions fixed");
  assert.equal(nodes.track.scrollTop, bottomScroll);
  nodes.track.scrollTop = 0;
  assert.equal(api._nearest(-100), 0);
  assert.equal(api._nearest(100000), entries.length - 1);

  api.configure([], nodes);
  api.setLoading(true);
  api._hover(50);
  assert.equal(nodes.popup.attrs["aria-busy"], "true");
  assert.ok(nodes.popup.classes.has("loading"), "loading renders a skeleton");
  assert.equal(nodes.userPreview.innerHTML, "");
  assert.equal(nodes.answerPreview.innerHTML, "");

  api.configure(entries, nodes, false);
  api._syncBounds();
  assert.equal(nodes.nav.style.right, "12px", "overlay scrollbar retains its own hit area");
  assert.equal(nodes.chatMain.style["--chat-nav-overlay-space"], "12px", "content leaves room for the overlay scrollbar");
  assert.ok(nodes.chatMain.classes.has("has-chat-navigator"), "visible navigation reserves content space");
  nodes.messages.clientWidth = 480;
  api._syncBounds();
  assert.equal(nodes.nav.style.right, "20px", "classic scrollbar uses its actual width");
  assert.equal(nodes.chatMain.style["--chat-nav-overlay-space"], "0px", "classic scrollbar width is not counted twice");
  nodes.messages.clientWidth = 500;
  assert.match(css, /\.has-chat-navigator > \.chat-messages-scroll\s*\{\s*padding-right:\s*calc\(var\(--chat-nav-width\)/,
    "message content and navigation share the same width variable");
  assert.match(css, /\.chat-navigator\s*\{[^}]*width:\s*var\(--chat-nav-width\)/);
  api.configure(entries.slice(0, 1), nodes);
  api._renderTicks();
  assert.ok(!nodes.chatMain.classes.has("has-chat-navigator"), "hidden navigation restores normal content spacing");
  api.configure(entries, nodes, false);

  const opener = new Element();
  opener.parentElement = nodes.chatMain;
  let openerHidden = false;
  const openerStyle = { top: "8px", height: "32px" };
  opener.getBoundingClientRect = () => openerHidden ? { top: 0, bottom: 0, height: 0 } : { top: 48, bottom: 80, height: 32 };
  context.document = { ...document, getElementById: id => id === "btn-aside-open" ? opener : null };
  const defaultComputedStyle = context.getComputedStyle;
  context.getComputedStyle = element => element === opener ? openerStyle : defaultComputedStyle(element);
  api._syncBounds();
  const closedAsideBounds = { top: nodes.nav.style.top, height: nodes.nav.style.height };
  assert.equal(closedAsideBounds.top, "52px", "navigation leaves space below the aside opener");
  openerHidden = true;
  api._syncBounds();
  assert.deepEqual({ top: nodes.nav.style.top, height: nodes.nav.style.height }, closedAsideBounds,
    "opening the aside keeps the same navigation range even though the opener has no layout box");
  openerStyle.top = "10px";
  openerStyle.height = "40px";
  api._syncBounds();
  assert.equal(nodes.nav.style.top, "62px", "reserved space follows the opener's CSS dimensions even when hidden");
  nodes.messages.getBoundingClientRect = () => ({ top: 140, bottom: 350, height: 210, left: 0, right: 500, width: 500 });
  api._syncBounds();
  assert.equal(nodes.nav.style.top, "112px", "a taller session banner still limits the navigation's top edge");
  assert.equal(nodes.nav.style.height, "182px", "navigation still follows the message viewport's bottom edge");
  delete nodes.messages.getBoundingClientRect;
  context.document = document;
  context.getComputedStyle = defaultComputedStyle;
  api._syncBounds();

  const requests = [];
  let resolvePreview;
  context.fetch = url => { requests.push(url); return new Promise(resolve => { resolvePreview = resolve; }); };
  api._hover(86);
  const firstPreviewId = entries[api.state().hoveredIdx].id;
  assert.equal(requests.length, 0, "moving the mouse does not immediately issue a request");
  assert.equal(nodes.popup.attrs["aria-busy"], "true", "uncached preview displays a skeleton");
  const pendingPreview = api.requestPreviewNow();
  assert.equal(requests.length, 1);
  api._hover(150);
  api._hover(250);
  const latestPreviewId = entries[api.state().hoveredIdx].id;
  await api.requestPreviewNow();
  assert.equal(requests.length, 1, "rapid movement does not create concurrent preview requests");
  resolvePreview({ ok: true, json: async () => ({ id: firstPreviewId, user: "Old", assistant: "Old answer" }) });
  await pendingPreview;
  assert.equal(requests.length, 2, "only the latest waiting target is fetched");
  assert.equal(new URL(requests[1], "http://localhost").searchParams.get("preview"), latestPreviewId);
  assert.equal(nodes.answerPreview.innerHTML, "", "a late response does not replace the hovered preview");
  resolvePreview({ ok: true, json: async () => ({ id: latestPreviewId, user: "Latest", assistant: "**Final** answer" }) });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(nodes.answerPreview.innerHTML, "<strong>Final</strong> answer");
  assert.equal(nodes.popup.attrs["aria-busy"], "false");
  api._hover(86);
  await api.requestPreviewNow();
  assert.equal(requests.length, 2, "revisiting a cached tick does not fetch again");

  api.configure(entries, nodes, false);
  context.fetch = async () => { throw new Error("offline"); };
  api._hover(86);
  await api.requestPreviewNow();
  assert.equal(api.state().previewFailure, entries[api.state().hoveredIdx].id);
  assert.equal(nodes.popup.attrs["aria-busy"], "false", "failure does not leave a permanent skeleton");

  context.fetch = async url => ({ ok: true, json: async () => ({ id: new URL(url, "http://localhost").searchParams.get("preview"), user: "Question", assistant: "Answer" }) });
  for (let i = 0; i < 90; i++) {
    nodes.track.scrollTop = i * 12;
    api._hover(100);
    await api.requestPreviewNow();
  }
  assert.equal(api.state().cacheSize, 80, "preview cache has a fixed upper bound");
  api._cancelPreview();

  api.configure([], nodes, false);
  nodes.track.scrollTop = 0;
  let indexRequests = 0;
  context.fetch = async () => {
    indexRequests++;
    return { ok: true, json: async () => ({ total: 5000, sources: [{ key: "archive", version: "v1", count: 5000, volatile: false }] }) };
  };
  await api._loadIndex();
  assert.equal(indexRequests, 1, "startup fetches only the compact manifest, not all previews");
  assert.equal(api.state().items.length, 5000, "all ticks are available from source counts");
  assert.ok(nodes.canvas.children.length < 50);

  api._hover(86);
  let resolveStalePreview;
  context.fetch = () => new Promise(resolve => { resolveStalePreview = resolve; });
  const stalePreview = api.requestPreviewNow();
  context.fetch = async () => ({ ok: true, json: async () => ({ total: 0, sources: [] }) });
  context.window.ChatNavigator.setSession("test");
  resolveStalePreview({ ok: true, json: async () => ({ user: "Stale", assistant: "Stale" }) });
  await stalePreview;
  assert.equal(api.state().cacheSize, 0, "a switched session cannot inherit an old preview response");

  // An old request resolves after switching sessions; it must not overwrite the new index.
  let resolveOld;
  context.fetch = () => new Promise(resolve => { resolveOld = resolve; });
  api.configure([], nodes);
  const old = api._loadIndex();
  context.Sessions.activeId = "new-session";
  context.fetch = async () => ({ ok: true, json: async () => ({ total: 0, sources: [] }) });
  context.window.ChatNavigator.setSession("new-session");
  resolveOld({ ok: true, json: async () => ({ total: 1000, sources: [{ key: "live", version: "v1", count: 1000 }] }) });
  await old;
  await Promise.resolve();
  assert.equal(api.state().items.length, 0, "ignores stale session index response");
}

async function historyTests() {
  const messages = new Element();
  const source = fs.readFileSync(sourcePath("sessions.js"), "utf8");
  const fetchFunction = source.slice(source.indexOf("  async function _fetchHistory("), source.indexOf("  // ── Private helpers", source.indexOf("  async function _fetchHistory(")));
  const state = {};
  const context = vm.createContext({
    document, URLSearchParams, AbortController, console,
    _historyState: state, _renderedCreatedAt: {}, _activeId: "a", _sessions: [], _userScrolledUp: false,
    RenderTarget: { outer: () => messages }, window: {}, I18n: { t: key => key }, escapeHtml: text => text,
    _collapseToolGroup() {}, _refreshEditButtons() {}, _updateEmptyHint() {}, _flushPendingStdout() {},
    _showNewMessageBanner() {}, _hideNewMessageBanner() {},
    _renderHistoryEvent(ev, fragment) { fragment.appendChild(ev); },
    Sessions: { _sessionProgress: {}, collapseToolGroup() {}, appendMsg() {} },
  });
  vm.runInContext(fetchFunction, context);
  const event = id => ({ type: "history_user_message", round_id: id, created_at: 10, content: id, editable: false });
  const response = (events, extra = {}) => ({ ok: true, json: async () => ({ events, has_more: true, has_after: false, ...extra }) });
  context.fetch = async () => response([event("chunk-one"), event("chunk-two")]);
  await context._fetchHistory("a");
  assert.equal(messages.children.length, 2, "identical synthetic timestamps do not deduplicate different archived turns");

  messages.scrollTop = 70;
  context.fetch = async () => response([event("chunk-three")], { has_after: true, after_cursor: "chunk-three" });
  await context._fetchHistory("a", null, false, { after: "chunk-two" });
  assert.equal(messages.scrollTop, 70, "appending a newer page does not jump to the bottom");
  assert.equal(state.a.hasAfter, true);

  context.fetch = async () => response([event("target")], { has_after: true });
  await context._fetchHistory("a", null, false, { around: "target", replace: true });
  assert.equal(messages.children.length, 1, "direct navigation replaces rather than accumulating all intermediate history");
  assert.equal(messages.children[0].content, "target");
  assert.equal(messages.scrollTop, 0);

  let resolveOld;
  context.fetch = () => new Promise(resolve => { resolveOld = resolve; });
  const old = context._fetchHistory("a", null, false, { around: "stale", replace: true });
  context.fetch = async () => response([event("latest")]);
  await context._fetchHistory("a", null, false, { replace: true });
  resolveOld(response([event("stale")]));
  await old;
  assert.equal(messages.children[0].content, "latest", "late history requests cannot overwrite the selected window");
  assert.equal(state.a.hasAfter, false);

  context.fetch = async () => { throw new Error("network unavailable"); };
  await context._fetchHistory("a", null, false, { around: "missing", replace: true });
  assert.equal(messages.children[0].content, "latest", "failed jump preserves existing conversation");
  assert.equal(state.a.hasAfter, false, "failed jump restores latest-window state");
  assert.equal(state.a.loading, false);

  let requests = 0;
  context.fetch = async () => {
    requests++;
    if (requests === 1) state.a.liveRevision = 1;
    return response([event(requests === 1 ? "snapshot" : "caught-up")]);
  };
  await context._fetchHistory("a", null, false, { replace: true });
  assert.equal(requests, 2, "reconciles live output received while returning to latest");
  assert.equal(messages.children[0].content, "caught-up");

  const refreshStart = source.indexOf("  function _refreshEditButtons(");
  const refreshFunction = source.slice(refreshStart, source.indexOf("  function _extractUserBubbleText", refreshStart));
  vm.runInContext(refreshFunction, context);
  const buttons = [new Element(), new Element()];
  const container = { querySelectorAll: selector => selector === ".msg-edit-btn" ? buttons : [] };
  context.Sessions.find = () => ({ status: "idle" });
  context.Sessions.isHistoricalWindow = () => true;
  context._refreshEditButtons(container);
  assert.ok(buttons.every(button => button.style.display === "none"), "old windows expose no editable user message");
  context.Sessions.isHistoricalWindow = () => false;
  context._refreshEditButtons(container);
  assert.equal(buttons[0].style.display, "none");
  assert.equal(buttons[1].style.display, "", "only the last user message is editable at latest");
  context._refreshEditButtons(container, "running");
  assert.ok(buttons.every(button => button.style.display === "none"));
}

(async () => {
  markdownPreviewTests();
  await navigatorTests();
  await historyTests();
  console.log("Navigation geometry, virtual rendering, preview, request races and history pagination passed");
})().catch(error => { console.error(error); process.exitCode = 1; });
