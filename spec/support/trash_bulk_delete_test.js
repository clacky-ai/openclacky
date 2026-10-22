"use strict";

// Regression harness for the recycle bin's "clear all" / "clear older than 7
// days" buttons. The type and project filters live in the browser, so the
// confirmation count and the request must describe the same visible sessions.
//
// The real store.js + view.js run against a minimal DOM stub; fetch and the
// confirm dialog are recorded so the assertions cover what the user agrees to
// and what actually goes over the wire.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const read = name => fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/features/trash", name), "utf8");

class Element {
  constructor() {
    this.dataset = {};
    this.style = {};
    this.handlers = {};
    this.children = [];
    this.disabled = false;
    this.innerHTML = "";
    this.textContent = "";
    this.className = "";
    this.classList = { add() {}, remove() {}, toggle() {}, contains: () => false };
    this._queried = {};
  }
  addEventListener(name, fn) { this.handlers[name] = fn; }
  appendChild(child) { this.children.push(child); return child; }
  querySelector(sel) { return (this._queried[sel] ||= new Element()); }
  querySelectorAll() { return []; }
}

const daysAgo = n => new Date(Date.now() - n * 86400000).toISOString();

const SESSIONS = [
  { session_id: "A", name: "A", source: "manual", project_id: "p1", deleted_at: daysAgo(10) },
  { session_id: "B", name: "B", source: "manual", project_id: "p1", deleted_at: daysAgo(0) },
  { session_id: "C", name: "C", source: "cron",   project_id: "p2", deleted_at: daysAgo(10) },
  { session_id: "D", name: "D",                    project_id: null, deleted_at: daysAgo(0) },
];

function boot() {
  const elements = {};
  const confirms = [];
  const posts = [];
  let trash = SESSIONS.map(s => ({ ...s }));

  const document = {
    getElementById: id => (elements[id] ||= new Element()),
    createElement: () => new Element(),
    querySelectorAll: () => [],
  };

  const fetch = async (url, opts = {}) => {
    if (url === "/api/trash/sessions") {
      return { ok: true, json: async () => ({ ok: true, sessions: trash, count: trash.length, total_size: 0 }) };
    }
    if (url === "/api/trash/sessions/delete" && opts.method === "POST") {
      const ids = JSON.parse(opts.body).session_ids;
      posts.push(ids);
      trash = trash.filter(s => !ids.includes(s.session_id));
      return { ok: true, json: async () => ({ ok: true, deleted_count: ids.length }) };
    }
    throw new Error(`unexpected request: ${opts.method || "GET"} ${url}`);
  };

  const sandbox = {
    document, fetch, console,
    I18n: { t: (key, vars) => (vars && vars.count !== undefined ? `${key}|${vars.count}` : key) },
    Modal: { confirm: async msg => { confirms.push(msg); return true; }, toast() {} },
  };
  sandbox.window = sandbox;
  const ctx = vm.createContext(sandbox);
  vm.runInContext(read("store.js"), ctx);
  vm.runInContext(read("view.js"), ctx);

  return {
    Trash: vm.runInContext("Trash", ctx),
    el: id => document.getElementById(id),
    confirms, posts,
    remaining: () => trash.map(s => s.session_id),
  };
}

async function open() {
  const h = boot();
  h.Trash.onPanelShow();
  await new Promise(resolve => setImmediate(resolve));
  return h;
}

const click = (h, id) => h.el(id).handlers.click();

async function main() {
  {
    const h = await open();
    h.Trash.setFilterProject("p1");
    await click(h, "btn-trash-empty-all");
    assert.deepEqual(h.confirms, ["trash.confirmEmptySessionAll|2"], "confirmation counts the visible sessions");
    assert.deepEqual(h.posts, [["A", "B"]], "only the visible sessions are sent");
    assert.deepEqual(h.remaining(), ["C", "D"], "sessions outside the filter survive");
  }

  {
    const h = await open();
    h.Trash.setFilterProject("p1");
    await click(h, "btn-trash-empty-old");
    assert.deepEqual(h.confirms, ["trash.confirmEmptySessionOld|1"]);
    assert.deepEqual(h.posts, [["A"]], "old + visible only");
    assert.deepEqual(h.remaining(), ["B", "C", "D"]);
  }

  {
    const h = await open();
    h.Trash.setFilterSource("cron");
    await click(h, "btn-trash-empty-all");
    assert.deepEqual(h.posts, [["C"]], "the type filter narrows the scope too");
  }

  {
    const h = await open();
    await click(h, "btn-trash-empty-all");
    assert.deepEqual(h.posts, [["A", "B", "C", "D"]], "no filter still clears everything");
    assert.deepEqual(h.remaining(), []);
  }

  {
    const h = await open();
    h.Trash.setFilterProject("p2");
    h.Trash.setFilterSource("manual");
    await click(h, "btn-trash-empty-all");
    assert.deepEqual(h.posts, [], "nothing visible, nothing sent");
    assert.equal(h.confirms.length, 0, "no confirmation for an empty selection");
  }
}

main().catch(err => { console.error(err); process.exit(1); });
