"use strict";

// Behavioural harness for the side chat panel (default_extensions/side-chat
// view.js) running against the real chat composer component:
//
//   - a quote picked in the main conversation only marks the branch for a
//     refresh; the branch is replaced when the user actually sends, so an
//     abandoned quote leaves the panel's conversation untouched;
//   - the composer swaps send for stop while the branch works.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const VIEW = path.join(
  __dirname,
  "../../lib/clacky/default_extensions/side-chat/panels/side-chat/view.js"
);
const COMPOSER = path.join(__dirname, "../../lib/clacky/web/components/chat-composer.js");

class Element {
  constructor(tag = "div") {
    this.tagName = tag.toUpperCase();
    this.className = "";
    this.textContent = "";
    this.innerHTML = "";
    this.children = [];
    this.hidden = false;
    this.style = {};
    this.dataset = {};
    this.attributes = {};
    this.listeners = {};
    this.scrollHeight = 0;
    this.scrollTop = 0;
    this.clientHeight = 100;
    this.isConnected = true;
    this.classList = {
      add: () => {},
      remove: () => {},
      toggle: () => {},
      contains: () => false,
    };
    this._id = null;
  }
  set id(value) { this._id = value; }
  get id() { return this._id; }
  setAttribute(name, value) { this.attributes[name] = value; }
  getAttribute(name) { return this.attributes[name]; }
  removeAttribute(name) { delete this.attributes[name]; }
  appendChild(node) { this.children.push(node); return node; }
  replaceChildren(...nodes) { this.children = nodes; }
  remove() { this.isConnected = false; }
  addEventListener(type, handler) { (this.listeners[type] = this.listeners[type] || []).push(handler); }
  click() { (this.listeners.click || []).forEach((handler) => handler({})); }
  getBoundingClientRect() { return { top: 0, left: 0, width: 300, height: 300 }; }
  closest() { return null; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  focus() {}
}

function makeDocument() {
  const head = new Element("head");
  const byId = new Map();
  return {
    head: head,
    body: new Element("body"),
    createElement: (tag) => new Element(tag),
    createDocumentFragment: () => new Element("fragment"),
    getElementById: (id) => byId.get(id) || null,
    querySelector: () => null,
    _byId: byId,
  };
}

function load() {
  const document = makeDocument();
  const frames = [];
  const listeners = [];
  const opens = []; // unresolved /open requests
  const staged = [];
  const intervals = [];
  const toolCalls = [];
  const rafs = [];
  const observers = [];

  class ResizeObserverStub {
    constructor(cb) { this.cb = cb; this.targets = []; this.disconnected = false; observers.push(this); }
    observe(target) { this.targets.push(target); }
    disconnect() { this.disconnected = true; }
    trigger() { this.cb([]); }
  }
  const stubs = { activateTab: true };

  const context = {
    console: console,
    Promise: Promise,
    Date: Date,
    Math: Math,
    JSON: JSON,
    Object: Object,
    Array: Array,
    Map: Map,
    Set: Set,
    setTimeout: (fn) => setTimeout(fn, 0),
    clearTimeout: (id) => clearTimeout(id),
    // The elapsed counter is faked: the assertion drives one tick by hand
    // instead of waiting a real second for it.
    setInterval: (fn, ms) => { intervals.push({ fn: fn, ms: ms, cleared: false }); return intervals.length; },
    clearInterval: (id) => { if (intervals[id - 1]) intervals[id - 1].cleared = true; },
    requestAnimationFrame: (fn) => { rafs.push(fn); setTimeout(fn, 0); },
    ResizeObserver: ResizeObserverStub,
    document: document,
    fetch: (url, options) =>
      new Promise((resolve) => {
        opens.push({ url: url, body: JSON.parse(options.body), resolve: resolve });
      }),
    escapeHtml: (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])),
    // The composer's text lives on the element so setValue/clear round-trip.
    Composer: {
      init: () => {},
      bindDropZone: () => {},
      text: (node) => node._text || "",
      setText: (node, value) => { node._text = value; },
      clear: (node) => { node._text = ""; },
      setPlaceholder: () => {},
    },
    IME: { bindEnter: () => {} },
    I18n: { t: (key) => key, applyAll: () => {} },
    QuoteSelect: {
      stage: (snap, input) => staged.push({ snap: snap, input: input }),
      list: () => [],
      toReferences: () => [],
    },
    Clacky: null,
  };
  context.window = context;

  context.Clacky = {
    ext: {
      context: { sessionId: "session-1" },
      ui: { mount: (slot, panel) => { context.__panel = panel; } },
      activateTab: () => stubs.activateTab,
    },
    Aside: { open: () => {} },
    Sessions: {
      renderMarkdown: (text) => text,
      renderReferenceBadge: () => "",
      // The panel must build tool rows with the main conversation's own
      // helpers; these record what it asked for. The rendering itself lives in
      // sessions.js and is verified in the browser.
      toolView: {
        makeGroup: () => {
          const group = new Element("div");
          group.className = "tool-group expanded";
          toolCalls.push({ op: "makeGroup", group: group });
          return group;
        },
        addCall: (group, name, args, summary) => {
          const item = new Element("div");
          item.className = "tool-item";
          group.appendChild(item);
          toolCalls.push({ op: "addCall", item: item, name: name, args: args, summary: summary });
          return item;
        },
        complete: (item, result, opts) => toolCalls.push({ op: "complete", item: item, result: result, opts: opts }),
        collapse: (group) => toolCalls.push({ op: "collapse", group: group }),
        toggleDetails: (item) => toolCalls.push({ op: "toggleDetails", item: item }),
        isPromoted: (ui) => ui && ui.type === "web_search",
        promoteResult: (container, ui) => {
          const card = new Element("div");
          card.className = "search-card";
          container.appendChild(card);
          toolCalls.push({ op: "promoteResult", card: card, ui: ui });
        },
      },
    },
    WS: {
      send: (frame) => frames.push(frame),
      onEvent: (cb) => listeners.push(cb),
    },
  };

  vm.createContext(context);
  // Real component: the send/stop swap asserted below is its own code, not a
  // stand-in for it.
  vm.runInContext(fs.readFileSync(COMPOSER, "utf8"), context, { filename: COMPOSER });
  vm.runInContext(fs.readFileSync(VIEW, "utf8"), context, { filename: VIEW });

  const rt = context.__panel.create({ sessionId: "session-1" });
  const container = new Element("div");
  context.__panel.render(container, { sessionId: "session-1" }, rt);

  return {
    context,
    rt,
    frames,
    opens,
    staged,
    stubs,
    container,
    composer: () => rt.el.composer,
    emit: (event) => listeners.forEach((cb) => cb(event)),
    respond: (index, data) => {
      opens[index].resolve({ ok: true, status: 200, json: async () => data });
    },
    tick: () => new Promise((resolve) => setTimeout(resolve, 5)),
    listeners,
    rafs,
    intervals,
    toolCalls,
    observers,
    scrollBody: (top, height) => {
      const body = rt.el.body;
      body.scrollHeight = height;
      body.clientHeight = height === 0 ? 0 : 100;
      body.scrollTop = top;
      (body.listeners.scroll || []).forEach((fn) => fn());
    },
    // The calls from the most recent render of a tool run (starts at its group).
    lastToolRun: () => {
      let start = 0;
      toolCalls.forEach((call, i) => { if (call.op === "makeGroup") start = i; });
      return toolCalls.slice(start);
    },
    sends: () => frames.filter((f) => f.type === "ext.side_chat.send"),
    type: (text) => {
      rt.el.composer.setValue(text);
      rt.el.composer.send.click();
    },
  };
}

(async () => {
  const h = load();

  // ── The panel starts idle: send visible, stop hidden ──────────────────────
  assert.equal(h.composer().send.hidden, false, "the panel opens with a send button");
  assert.equal(h.composer().stop.hidden, true, "and no stop button");
  assert.equal(h.opens.length, 0, "render must not fork on its own");

  // ── First message: no branch yet, so /open + a queued send ─────────────────
  h.type("first question");
  assert.equal(h.opens.length, 1, "the first send opens the branch");
  assert.equal(h.opens[0].body.fresh, false, "nothing to replace on the first send");
  h.respond(0, { chat_id: "chat-1" });
  await h.tick();
  assert.equal(h.sends().length, 1, "the queued message is delivered after the branch exists");
  assert.equal(h.sends()[0].chat_id, "chat-1");
  assert.equal(h.composer().stop.hidden, true, "sending alone does not paint a running turn");

  // The attach answered before the send can land after it; the turn-start
  // frame is what the panel trusts, so the snapshot must not leave it idle.
  h.emit({ type: "ext.side_chat.attached", chat_id: "chat-1", running: false });
  assert.equal(h.composer().stop.hidden, true, "a stale snapshot keeps the send button");
  h.emit({ type: "ext.side_chat.busy", chat_id: "chat-1" });
  assert.equal(h.composer().send.hidden, true, "the turn-start frame swaps send for stop");
  assert.equal(h.composer().stop.hidden, false);

  h.emit({ type: "ext.side_chat.user", chat_id: "chat-1", text: "first question" });
  assert.equal(h.rt.entries.length, 1, "the user bubble is in the panel");

  // ── The thinking line, same as the main conversation ──────────────────────
  h.emit({ type: "ext.side_chat.event", chat_id: "chat-1", event: {
    type: "progress", phase: "active", message: "思考中", progress_type: "thinking",
    started_at: Date.now() - 2000, metadata: {},
  } });
  await h.tick();
  assert.equal(h.rt.progress && h.rt.progress.text, "思考中", "the progress frame is kept");
  assert.ok(h.rt.progressEl, "and rendered as a progress line");
  assert.equal(h.intervals.length, 1, "the elapsed counter ticks");
  h.intervals[0].fn();
  assert.equal(h.rt.progressEl.textContent, "思考中… (2s)", "the line counts seconds");

  h.emit({ type: "ext.side_chat.event", chat_id: "chat-1", event: { type: "progress", phase: "done", message: "思考中" } });
  await h.tick();
  assert.equal(h.rt.progress, null, "the done frame clears the line");
  assert.equal(h.intervals[0].cleared, true, "and stops the counter");

  h.emit({ type: "ext.side_chat.event", chat_id: "chat-1", event: { type: "assistant_message", content: "answer" } });
  assert.equal(h.rt.entries.length, 2, "and so is the answer");
  assert.equal(h.composer().stop.hidden, false, "stop stays through the whole turn");

  // ── Stop interrupts the branch ────────────────────────────────────────────
  h.composer().stop.click();
  assert.equal(h.frames.filter((f) => f.type === "ext.side_chat.interrupt").length, 1,
    "clicking stop interrupts the branch");
  h.emit({ type: "ext.side_chat.turn", chat_id: "chat-1" });
  assert.equal(h.composer().send.hidden, false, "send comes back when the turn ends");
  assert.equal(h.composer().stop.hidden, true, "and stop goes away");

  // ── A quote clicked and then abandoned keeps the conversation ──────────────
  await new Promise((resolve) => {
    h.context.Clacky.SideChat.ask({ role: "assistant", index: 3, text: "quoted passage" });
    setTimeout(resolve, 20);
  });
  assert.equal(h.opens.length, 1, "clicking a quote must not re-fork on its own");
  assert.equal(h.rt.entries.length, 2, "the conversation stays on screen");
  assert.equal(h.staged.length, 1, "the quote still lands in the composer as a chip");

  // ── Second quote out of the main thread: the send replaces the branch ──────
  h.type("second question");
  assert.equal(h.opens.length, 2, "sending after a quote re-forks");
  assert.equal(h.opens[1].body.fresh, true, "and asks for a fresh branch");
  assert.equal(h.sends().length, 1, "nothing is sent before the new branch answers");

  // A second send inside the fork window joins the queue instead of hitting
  // the branch that is being replaced.
  h.composer().setValue("third question");
  h.composer().send.click();

  assert.equal(h.sends().length, 1, "no send while the fork is in flight");
  assert.equal(h.opens.length, 2, "and no second fork is requested");

  h.respond(1, { chat_id: "chat-2" });
  await h.tick();
  assert.equal(h.rt.chatId, "chat-2", "the panel switched to the new branch");
  assert.equal(h.rt.entries.length, 0, "the old conversation is gone once the new branch is live");
  assert.equal(h.sends().length, 3, "both queued messages are delivered");
  assert.deepEqual(h.sends().slice(1).map((f) => [f.chat_id, f.text]), [
    ["chat-2", "second question"],
    ["chat-2", "third question"],
  ]);

  // ── A quote picked while the branch is still empty needs no re-fork ────────
  h.emit({ type: "ext.side_chat.user", chat_id: "chat-2", text: "second question" });
  h.emit({ type: "ext.side_chat.event", chat_id: "chat-2", event: { type: "assistant_message", content: "answer two" } });
  await new Promise((resolve) => {
    h.context.Clacky.SideChat.ask({ role: "user", index: 9, text: "another passage" });
    setTimeout(resolve, 20);
  });
  assert.equal(h.rt.entries.length, 2, "the question is still on screen after the quote click");
  h.type("fourth question");
  assert.equal(h.opens.length, 3, "the next send replaces the branch again");
  assert.equal(h.opens[2].body.fresh, true);
  h.respond(2, { chat_id: "chat-3" });
  await h.tick();
  assert.equal(h.sends()[h.sends().length - 1].text, "fourth question");
  assert.equal(h.sends()[h.sends().length - 1].chat_id, "chat-3");

  // ── Tool runs ride the main conversation's own rows ───────────────────────
  h.toolCalls.length = 0;
  const toolEvent = (chatId, event) => h.emit({ type: "ext.side_chat.event", chat_id: chatId, event: event });

  toolEvent("chat-3", { type: "tool_call", name: "glob", args: { pattern: "*", dir: "/tmp" }, summary: 'glob("*" in /tmp)' });
  await h.tick();
  let run = h.lastToolRun();
  assert.deepEqual(run.map((c) => c.op), ["makeGroup", "addCall"], "a tool call opens one group and one row");
  assert.equal(run[1].name, "glob");
  assert.deepEqual(run[1].args, { pattern: "*", dir: "/tmp" },
    "args reach the row so its details pane has something to open");
  assert.equal(run[1].summary, 'glob("*" in /tmp)');

  toolEvent("chat-3", { type: "tool_result", result: "3 files" });
  await h.tick();
  run = h.lastToolRun();
  assert.ok(run.some((c) => c.op === "complete" && c.result === "3 files"),
    "the result fills the row's stdout and the row's tick");

  toolEvent("chat-3", { type: "tool_call", name: "read", args: { path: "a.rb" }, summary: "Read(a.rb)" });
  await h.tick();
  run = h.lastToolRun();
  assert.equal(run.filter((c) => c.op === "makeGroup").length, 1,
    "a run of consecutive calls shares one group, not one group per call");
  assert.equal(run.filter((c) => c.op === "addCall").length, 2);
  assert.ok(!run.some((c) => c.op === "collapse"),
    "a running call keeps the group expanded");

  toolEvent("chat-3", { type: "tool_result", result: "file body" });
  await h.tick();
  run = h.lastToolRun();
  assert.ok(run.some((c) => c.op === "collapse"),
    "once the run is over it collapses to the ⚙ N tool(s) used header");

  // ── Search hits become a card below the run, as in the main conversation ──
  h.toolCalls.length = 0;
  toolEvent("chat-3", { type: "tool_call", name: "web_search", args: { query: "ruby" }, summary: "Search(ruby)" });
  await h.tick();
  const ui = { type: "web_search", results: [{ title: "Ruby", url: "https://ruby-lang.org" }] };
  toolEvent("chat-3", { type: "tool_result", result: "{\"results\":[]}", ui: ui });
  await h.tick();
  run = h.lastToolRun();
  const searchRow = run.find((c) => c.op === "addCall" && c.name === "web_search");
  const completed = run.find((c) => c.op === "complete" && c.item === searchRow.item);
  assert.equal(completed.opts && completed.opts.ui, ui,
    "the ui payload rides along so the row stays free of raw JSON");
  const promo = run.find((c) => c.op === "promoteResult");
  assert.ok(promo, "a promoted result appends its own card");
  assert.equal(promo.ui, ui);
  assert.ok(!run[0].group.children.includes(promo.card),
    "the card sits outside the tool group, below it");

  // ── The view follows the tail, and survives being rendered while hidden ───
  const panelBody = h.rt.el.body;
  h.scrollBody(900, 1000);
  toolEvent("chat-3", { type: "assistant_message", content: "next answer" });
  await h.tick();
  assert.equal(panelBody.scrollTop, 1000, "a new answer keeps the view on the tail");

  h.scrollBody(0, 1000);
  toolEvent("chat-3", { type: "assistant_message", content: "answer while reading" });
  await h.tick();
  assert.equal(panelBody.scrollTop, 0, "a user reading history is not dragged down");

  h.emit({ type: "ext.side_chat.user", chat_id: "chat-3", text: "my next question" });
  await h.tick();
  assert.equal(panelBody.scrollTop, 1000, "asking a question pulls the view back to the tail");

  // The host mounts a tab body hidden and adds .active after render() returns,
  // so a scrollTop written during that pass lands on a body with no height.
  h.scrollBody(0, 0);
  toolEvent("chat-3", { type: "assistant_message", content: "answer while hidden" });
  await h.tick();
  assert.equal(h.rt.pinBottom, true, "the pin survives a body that has no height yet");
  assert.equal(panelBody.scrollTop, 0, "writing scrollTop on a hidden body is a no-op");
  panelBody.scrollHeight = 1000;
  panelBody.clientHeight = 100;
  if (h.observers[0]) h.observers[0].trigger();
  assert.equal(panelBody.scrollTop, 1000, "and lands on the tail once the tab is shown");
  assert.equal(h.observers.length, 1, "render watches the body for its first layout");

  // ── A quote click lands on the spot, not on a later frame ──────────────────
  // activateTab paints the panel synchronously, so there is nothing to wait for;
  // a frame scheduled here could only re-ask a question already answered.
  h.rafs.length = 0;
  h.context.Clacky.SideChat.ask({ role: "assistant", index: 11, text: "one last passage" });
  assert.equal(h.rafs.length, 0, "opening the panel for a quote schedules no animation frame");
  assert.equal(h.rt.pendingQuotes.length, 0, "and the chip is staged in the same turn");

  // ── The panel binds one socket handler, however often it is reopened ───────
  assert.equal(h.listeners.length, 1, "one handler for the whole extension");
  h.rt.dispose();
  const reopened = h.context.__panel.create({ sessionId: "session-1" });
  h.context.__panel.render(new Element("div"), { sessionId: "session-1" }, reopened);
  assert.equal(h.listeners.length, 1, "reopening the panel does not stack a second handler");

  console.log("side chat deferred fork: ok");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
