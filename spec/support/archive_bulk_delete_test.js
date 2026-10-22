"use strict";

// Regression harness for the archive page's "delete all" button. Search and the
// project / type filters live in the browser and the list is paged, so a
// narrowed view must send exactly the visible ids, while an un-narrowed view
// sends no ids and lets the server take the whole archive.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const read = name => fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/features/archive", name), "utf8");

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
    this.value = "";
    this.classList = { add() {}, remove() {}, toggle() {}, contains: () => false };
    this._queried = {};
  }
  addEventListener(name, fn) { this.handlers[name] = fn; }
  appendChild(child) { this.children.push(child); return child; }
  append(...kids) { kids.forEach(k => this.children.push(k)); }
  querySelector(sel) { return (this._queried[sel] ||= new Element()); }
  querySelectorAll() { return []; }
}

// Page one of a two-page archive; E is on the unloaded second page.
const LOADED = [
  { id: "A", name: "alpha", source: "manual",  project_id: "p1" },
  { id: "B", name: "beta",  source: "cron",    project_id: "p1" },
  { id: "C", name: "gamma", source: "manual",  project_id: "p2" },
  { id: "D", name: "delta", source: "channel", project_id: null },
];
const TOTAL = 5;

function boot() {
  const elements = {};
  const confirms = [];
  const toasts = [];
  const posts = [];
  const selects = {};

  const document = {
    getElementById: id => (elements[id] ||= new Element()),
    createElement: () => new Element(),
    querySelectorAll: () => [],
  };

  const fetch = async (url, opts = {}) => {
    if (url.startsWith("/api/sessions?")) {
      return { ok: true, json: async () => ({
        sessions: LOADED.map(s => ({ ...s })), has_more: true,
        next_cursor: { before: "t", before_id: "D" }, archived_count: TOTAL,
      }) };
    }
    if (url === "/api/archive/sessions/delete" && opts.method === "POST") {
      const ids = opts.body ? JSON.parse(opts.body).session_ids : null;
      posts.push(ids);
      return { ok: true, json: async () => ({ ok: true, deleted_count: ids ? ids.length : TOTAL }) };
    }
    throw new Error(`unexpected request: ${opts.method || "GET"} ${url}`);
  };

  const sandbox = {
    document, fetch, console, setTimeout, clearTimeout, URLSearchParams,
    I18n: { t: (key, vars) => (vars && vars.count !== undefined ? `${key}|${vars.count}` : key) },
    Modal: { confirm: async msg => { confirms.push(msg); return true; }, toast: msg => toasts.push(msg) },
    Projects: { all: () => [{ id: "p1", name: "P1" }, { id: "p2", name: "P2" }] },
    CustomSelect: {
      init: ({ dropdown, onSelect }) => {
        dropdown.__customSelect = { setValue() {} };
        selects[dropdown === elements["archive-filter-type"].querySelector(".custom-select-dropdown") ? "type" : "project"] = onSelect;
      },
    },
  };
  sandbox.window = sandbox;
  const ctx = vm.createContext(sandbox);
  vm.runInContext(read("store.js"), ctx);
  vm.runInContext(read("view.js"), ctx);

  return {
    Archive: vm.runInContext("Archive", ctx),
    el: id => document.getElementById(id),
    selects, confirms, toasts, posts,
  };
}

const tick = () => new Promise(resolve => setImmediate(resolve));

async function open() {
  const h = boot();
  h.Archive.onPanelShow();
  await tick();
  return h;
}

async function search(h, text) {
  const input = h.el("archive-search");
  input.value = text;
  input.handlers.input();
  await new Promise(resolve => setTimeout(resolve, 200));
}

const deleteAll = h => h.el("btn-archive-delete-all").handlers.click();
const ids = h => Array.from(h.Archive.state.items, s => s.id);

async function main() {
  {
    const h = await open();
    h.selects.project("p1");
    await deleteAll(h);
    assert.deepEqual(h.confirms, ["archive.confirmDeleteAll|2"], "confirmation counts the visible chats");
    assert.deepEqual(h.posts, [["A", "B"]], "only the visible chats are sent");
    assert.deepEqual(ids(h), ["C", "D"], "chats outside the filter stay listed");
    assert.equal(h.Archive.state.archivedTotal, 3, "total drops by what was deleted");
    assert.equal(h.Archive.state.hasMore, true, "later pages are still reachable");
  }

  {
    const h = await open();
    h.selects.type("cron");
    await deleteAll(h);
    assert.deepEqual(h.posts, [["B"]], "the type filter narrows the scope too");
  }

  {
    const h = await open();
    await search(h, "gam");
    await deleteAll(h);
    assert.deepEqual(h.posts, [["C"]], "search narrows the scope too");
  }

  {
    const h = await open();
    await deleteAll(h);
    assert.deepEqual(h.confirms, [`archive.confirmDeleteAll|${TOTAL}`], "un-narrowed counts the whole archive");
    assert.deepEqual(h.posts, [null], "un-narrowed sends no ids, so unloaded pages go too");
    assert.deepEqual(ids(h), []);
    assert.equal(h.Archive.state.archivedTotal, 0);
  }

  {
    const h = await open();
    h.selects.project("p2");
    h.selects.type("cron");
    assert.equal(h.el("btn-archive-delete-all").disabled, true, "button is disabled when nothing is visible");
    await deleteAll(h);
    assert.deepEqual(h.posts, [], "nothing visible, nothing sent");
    assert.equal(h.confirms.length, 0, "no confirmation for an empty selection");
    assert.deepEqual(h.toasts, ["archive.noMatch"]);
  }
}

main().catch(err => { console.error(err); process.exit(1); });
