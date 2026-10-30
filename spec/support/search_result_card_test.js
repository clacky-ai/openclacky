"use strict";

// Regression harness for promoting web_search results into their own card.
//
// The structured result used to be injected into the tool-item's stdout, which
// _completeToolItem hides the moment the tool finishes — so the card was only
// visible for the second or two the search was running. The card now renders as
// a standalone element in the message stream, and the tool group is closed so
// later tool calls stay below it chronologically.
//
// The real sessions.js runs against a minimal DOM stub; assertions cover the
// user-visible outcome: what lands in the message stream and in which order.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = name => path.resolve(__dirname, "../../lib/clacky/web", name);

const autoStub = (extra = {}) => new Proxy(extra, {
  get: (target, key) => (key in target ? target[key] : () => {}),
});

class Element {
  constructor(tag = "div") {
    this.tagName = tag;
    this.style = { setProperty() {} };
    this.dataset = {};
    this.attrs = {};
    this.children = [];
    this.handlers = {};
    this.classes = new Set();
    this._className = "";
    this._innerHTML = "";
    this.textContent = "";
    this.classList = {
      add: n => this.classes.add(n),
      remove: n => this.classes.delete(n),
      toggle: (n, on) => {
        if (on === undefined) {
          if (this.classes.has(n)) { this.classes.delete(n); return false; }
          this.classes.add(n); return true;
        }
        return on ? (this.classes.add(n), true) : (this.classes.delete(n), false);
      },
      contains: n => this.classes.has(n),
    };
  }
  set className(v) { this._className = v; this.classes = new Set(v.split(/\s+/).filter(Boolean)); }
  get className() { return this._className; }
  set innerHTML(v) { this._innerHTML = v; if (v === "") this.children = []; }
  get innerHTML() { return this._innerHTML; }
  setAttribute(k, v) { this.attrs[k] = v; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(k, fn) { this.handlers[k] = fn; }
  removeEventListener() {}
  appendChild(child) {
    if (child.tagName === "fragment") {
      child.children.forEach(k => this.appendChild(k));
      child.children = [];
      return child;
    }
    this.children.push(child);
    child.parentNode = this;
    return child;
  }
  append(...kids) { kids.forEach(k => this.appendChild(k)); }
  prepend(child) { this.children.unshift(child); return child; }
  remove() {}
  replaceChildren(...kids) { this.children = kids; }
  insertBefore(child) { this.children.unshift(child); return child; }
  // Elements built from an innerHTML template are not parsed by this stub, so
  // a queried-but-missing child is memoised per selector. That keeps writes the
  // code under test performs (e.g. filling .tool-item-stdout) observable.
  querySelector(sel) {
    const found = this._find(sel);
    if (found) return found;
    if (!this._stubs) this._stubs = {};
    if (!this._stubs[sel]) {
      const stub = new Element();
      stub.className = sel.split(",")[0].trim().split(/\s+/).pop().replace(/^\./, "");
      this._stubs[sel] = stub;
    }
    return this._stubs[sel];
  }
  querySelectorAll(sel) { return this._findAll(sel); }
  _matches(sel) {
    return sel.split(",").some(part => part.trim().split(/\s+/).every(token =>
      token.split(".").filter(Boolean).every(cls => this.classes.has(cls))));
  }
  _descendants() {
    return this.children.concat(Object.values(this._stubs || {}));
  }
  _find(sel) {
    for (const child of this._descendants()) {
      if (child._matches && child._matches(sel)) return child;
      const deep = child._find && child._find(sel);
      if (deep) return deep;
    }
    return null;
  }
  _findAll(sel) {
    const out = [];
    for (const child of this.children) {
      if (child._matches && child._matches(sel)) out.push(child);
      if (child._findAll) out.push(...child._findAll(sel));
    }
    return out;
  }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  contains() { return false; }
  closest(sel) {
    let node = this;
    while (node) {
      if (node._matches && node._matches(sel)) return node;
      node = node.parentNode;
    }
    return null;
  }
  focus() {}
}

function boot() {
  const nodes = {};
  const unrefTimeout = (fn, ms, ...args) => {
    const timer = setTimeout(fn, ms, ...args);
    if (timer.unref) timer.unref();
    return timer;
  };
  const document = {
    createElement: tag => new Element(tag),
    createDocumentFragment: () => new Element("fragment"),
    getElementById: id => nodes[id] || (nodes[id] = new Element()),
    addEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => [],
    body: new Element(),
  };

  const context = {
    console, Date, Map, Set, Math, JSON, Promise, URL, URLSearchParams,
    setTimeout: unrefTimeout,
    clearTimeout,
    document,
    fetch: async () => ({
      ok: true,
      status: 200,
      json: async () => ({ events: context.__historyEvents || [], has_more: false, has_after: false }),
    }),
    AbortController: class { constructor() { this.signal = {}; } abort() {} },
    WS: { onEvent() {}, setSubscribedSession() {}, send() {} },
    Clacky: {},
    $: id => document.getElementById(id),
    escapeHtml: s => String(s === undefined || s === null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    navigator: { language: "en-US" },
    Router: autoStub(),
    Projects: autoStub(),
    Tasks: autoStub(),
    Skills: autoStub(),
    Composer: autoStub({ text: () => "", chips: () => [] }),
    IME: autoStub({ track: () => ({ isComposing: () => false, dispose() {} }) }),
    alert() {},
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);

  const messages = document.getElementById("messages");
  context.RenderTarget = { current: () => messages, outer: () => messages };

  // The real i18n dictionary is loaded so the assertions also prove the copy
  // keys exist instead of matching placeholder text.
  vm.runInContext(fs.readFileSync(sourcePath("i18n.js"), "utf8"), context);
  vm.runInContext(fs.readFileSync(sourcePath("utils.js"), "utf8"), context);
  vm.runInContext(fs.readFileSync(sourcePath("sessions.js"), "utf8"), context);

  const Sessions = vm.runInContext("Clacky.Sessions", context);
  return { Sessions, messages, context };
}

const PAYLOAD = {
  type: "web_search",
  query: "OpenClacky release notes",
  count: 5,
  provider: "parallel",
  results: [
    { title: "One",   url: "https://www.example.com/a", snippet: "first" },
    { title: "Two",   url: "https://example.org/b",     snippet: "second" },
    { title: "Three", url: "https://example.net/c",     snippet: "third" },
    { title: "Four",  url: "https://example.io/d",      snippet: "fourth" },
    { title: "Five",  url: "https://example.dev/e",     snippet: "fifth" },
  ],
};

const cardsIn = messages => messages.children.filter(c => c.classes.has("search-card"));

async function tests() {
  // 1. Live search: the card is a sibling of the tool group, not stdout content.
  {
    const { Sessions, messages } = boot();
    Sessions.appendToolCall("web_search", { query: PAYLOAD.query }, null);
    Sessions.appendToolResult(JSON.stringify(PAYLOAD), PAYLOAD);

    const cards = cardsIn(messages);
    assert.equal(cards.length, 1, "one standalone card is appended to the stream");
    assert.match(cards[0].innerHTML, /search-card-title/, "results are rendered in the card");
    assert.match(cards[0].innerHTML, /Searched/, "the head says this was a search");
    assert.match(cards[0].innerHTML, /\u201cOpenClacky release notes\u201d/, "the query is quoted, not styled as a tool name");
    assert.match(cards[0].innerHTML, /class="search-card-count">5 results</, "the head counts the results");
    assert.match(cards[0].innerHTML, /class="search-card-provider">parallel</, "the provider is credited in the footer");
    assert.match(cards[0].innerHTML, /search-card-icon">\s*<svg[^>]*><circle cx="11" cy="11" r="8"\/><path d="m21 21-4\.3-4\.3"\/>/,
      "the head icon is a magnifier, not a globe");

    const group = messages.children.find(c => c.classes.has("tool-group"));
    const stdout = group.querySelector(".tool-item-stdout");
    assert.equal(stdout.innerHTML, "", "raw JSON never lands in the tool stdout");
  }

  // 2. Hostname is shown instead of the full URL, with the www. prefix dropped.
  {
    const { Sessions, messages } = boot();
    Sessions.appendToolCall("web_search", { query: PAYLOAD.query }, null);
    Sessions.appendToolResult(JSON.stringify(PAYLOAD), PAYLOAD);

    const html = cardsIn(messages)[0].innerHTML;
    assert.match(html, /class="search-card-host">example\.com</, "www. is stripped from the host");
    assert.ok(!html.includes(">https://www.example.com/a<"), "the full URL is not printed as text");
    assert.match(html, /class="search-card-row">.*?search-card-title.*?search-card-host/,
      "title and host share a row so the host trails the title");
    assert.match(html, /<\/span>\s*<span class="search-card-snippet">/,
      "the snippet sits outside that row, on its own line");
  }

  // 3. Long result lists start collapsed behind a toggle.
  {
    const { Sessions, messages } = boot();
    Sessions.appendToolCall("web_search", { query: PAYLOAD.query }, null);
    Sessions.appendToolResult(JSON.stringify(PAYLOAD), PAYLOAD);

    const card = cardsIn(messages)[0];
    assert.ok(card.classes.has("is-collapsed"), "more results than the preview → collapsed");
    assert.match(card.innerHTML, /class="search-card-more"/, "a toggle button is rendered");
    assert.match(card.innerHTML, /Show all 5 results/, "the toggle spells out the total");
    assert.match(card.innerHTML, /data-total="5"/, "the toggle knows the total");
  }

  // 4. A short list needs no toggle and must not be collapsed.
  {
    const { Sessions, messages } = boot();
    const short = Object.assign({}, PAYLOAD, { count: 2, results: PAYLOAD.results.slice(0, 2) });
    Sessions.appendToolCall("web_search", { query: short.query }, null);
    Sessions.appendToolResult(JSON.stringify(short), short);

    const card = cardsIn(messages)[0];
    assert.ok(!card.classes.has("is-collapsed"), "short list stays fully visible");
    assert.ok(!card.innerHTML.includes("search-card-more"), "no toggle button");
    assert.match(card.innerHTML, /class="search-card-provider">parallel</, "the provider is still credited");
  }

  // 5. A failed search renders the error inside the same card, with no result rows.
  {
    const { Sessions, messages } = boot();
    const failed = { type: "web_search", query: "anything", error: "provider returned 401" };
    Sessions.appendToolCall("web_search", { query: failed.query }, null);
    Sessions.appendToolResult(JSON.stringify(failed), failed);

    const card = cardsIn(messages)[0];
    assert.match(card.innerHTML, /search-card-error/, "the error is shown in the card");
    assert.match(card.innerHTML, /provider returned 401/);
    assert.ok(!card.innerHTML.includes("search-card-item"), "no result rows");
    assert.ok(!card.innerHTML.includes("search-card-count"), "no result count on failure");
  }

  // 6. Other tools are untouched: their output still renders in the tool stdout.
  {
    const { Sessions, messages } = boot();
    Sessions.appendToolCall("terminal", { command: "ls" }, null);
    Sessions.appendToolResult("a.txt\nb.txt", null);

    assert.equal(cardsIn(messages).length, 0, "no card for non-search tools");
    const group = messages.children.find(c => c.classes.has("tool-group"));
    assert.match(group.querySelector(".tool-item-stdout").innerHTML, /a\.txt/);
  }

  // 7. A tool call after a search opens a fresh group, so the card keeps its
  //    chronological place instead of being pushed below later tool items.
  {
    const { Sessions, messages } = boot();
    Sessions.appendToolCall("web_search", { query: PAYLOAD.query }, null);
    Sessions.appendToolResult(JSON.stringify(PAYLOAD), PAYLOAD);
    Sessions.appendToolCall("read", { path: "README.md" }, null);

    const order = messages.children.map(c =>
      c.classes.has("search-card") ? "card" : c.classes.has("tool-group") ? "group" : "other");
    assert.deepEqual(order, ["group", "card", "group"],
      "the follow-up tool call lands in a new group below the card");
  }

  // 8. History replay produces the same standalone card as the live path.
  {
    const { Sessions, messages, context } = boot();
    context.__historyEvents = [
      { type: "tool_call", name: "web_search", args: { query: PAYLOAD.query } },
      { type: "tool_result", result: JSON.stringify(PAYLOAD), ui: PAYLOAD },
    ];
    Sessions._setActiveId("sess-1");
    await Sessions.loadHistory("sess-1");

    const cards = cardsIn(messages);
    assert.equal(cards.length, 1, "replayed search renders one standalone card");
    assert.match(cards[0].innerHTML, /search-card-title/);
    const group = messages.children.find(c => c.classes.has("tool-group"));
    assert.equal(group.querySelector(".tool-item-stdout").innerHTML, "",
      "replay keeps the raw JSON out of the tool stdout");
  }

  // 9. The tool group is collapsed once the card takes over, so a multi-tool
  //    group does not stay expanded above its own results.
  {
    const { Sessions, messages } = boot();
    Sessions.appendToolCall("read", { path: "README.md" }, null);
    Sessions.appendToolResult("# readme", null);
    Sessions.appendToolCall("web_search", { query: PAYLOAD.query }, null);
    Sessions.appendToolResult(JSON.stringify(PAYLOAD), PAYLOAD);

    const group = messages.children.find(c => c.classes.has("tool-group"));
    assert.ok(!group.classes.has("expanded"), "the group collapses when the card is promoted");
  }

  // 10. Clicking the toggle expands the card and flips the button copy.
  //     The stub does not parse innerHTML, so the button is synthesised and
  //     parented to the card the way the real markup nests it.
  {
    const { Sessions, messages } = boot();
    Sessions.appendToolCall("web_search", { query: PAYLOAD.query }, null);
    Sessions.appendToolResult(JSON.stringify(PAYLOAD), PAYLOAD);

    const card = cardsIn(messages)[0];
    const foot = new Element("div");
    foot.className = "search-card-foot";
    const btn = new Element("button");
    btn.className = "search-card-more";
    btn.dataset.total = "5";
    foot.appendChild(btn);
    card.appendChild(foot);

    const onClick = messages.handlers.click;
    assert.ok(onClick, "a click delegate is installed on the message stream");

    onClick({ target: btn, preventDefault() {}, stopPropagation() {} });
    assert.ok(!card.classes.has("is-collapsed"), "the card expands on click");
    assert.equal(btn.textContent, "Show less ▴", "the button offers to collapse again");

    onClick({ target: btn, preventDefault() {}, stopPropagation() {} });
    assert.ok(card.classes.has("is-collapsed"), "clicking again collapses the card");
    assert.match(btn.textContent, /Show all 5 results/, "the button offers the full list again");
  }
}

tests().then(() => console.log("search_result_card_test: ok"));
