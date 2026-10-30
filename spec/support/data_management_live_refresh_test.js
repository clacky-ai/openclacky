"use strict";

// Regression harness: while the Archived sessions / Recycle bin page is open,
// archiving or deleting from the sidebar (or a project menu) must refresh that
// page's list. Nothing is fetched when the page is not the one on screen.
//
// The real sessions.js, projects.js and the archive/trash modules share one
// sandbox with a minimal DOM stub; fetch is recorded so the assertions cover
// both the requests made and what the pages end up listing.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const read = name => fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web", name), "utf8");

const autoStub = (extra = {}) => new Proxy(extra, {
  get: (target, key) => (key in target ? target[key] : () => {}),
});

class Element {
  constructor(tag = "div") {
    this.tagName = tag;
    this.style = { setProperty() {} };
    this.dataset = {};
    this.children = [];
    this.handlers = {};
    this.classList = { add() {}, remove() {}, toggle() {}, contains: () => false };
    this.innerHTML = "";
    this.textContent = "";
    this.className = "";
    this.value = "";
    this._queried = {};
  }
  setAttribute() {}
  removeAttribute() {}
  addEventListener(k, fn) { this.handlers[k] = fn; }
  removeEventListener() {}
  appendChild(child) { this.children.push(child); return child; }
  append() {}
  prepend() {}
  remove() {}
  replaceChildren() {}
  insertBefore(child) { return child; }
  querySelector(sel) { return (this._queried[sel] ||= new Element()); }
  querySelectorAll() { return []; }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  contains() { return false; }
  closest() { return null; }
  focus() {}
}

const row = (id, extra = {}) => ({ id, name: id, status: "idle", source: "manual", project_id: "p1", ...extra });

function boot() {
  const elements = {};
  const requests = [];
  const live = [row("L1"), row("L2")];
  const archived = [row("OLD", { archived_at: "2026-01-01T00:00:00Z" })];
  const trashed = [];

  const document = {
    readyState: "complete",
    createElement: tag => new Element(tag),
    createDocumentFragment: () => new Element("fragment"),
    getElementById: id => (elements[id] ||= new Element()),
    addEventListener() {},
    removeEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => [],
    body: new Element(),
    documentElement: new Element(),
  };

  const take = (list, id) => {
    const i = list.findIndex(s => s.id === id);
    return i < 0 ? null : list.splice(i, 1)[0];
  };
  const json = body => ({ ok: true, json: async () => body });

  const fetch = async (url, opts = {}) => {
    const method = opts.method || "GET";
    requests.push(`${method} ${url}`);

    let m;
    if (method === "GET" && url.startsWith("/api/sessions?")) {
      return json({ sessions: archived.map(s => ({ ...s })), has_more: false, next_cursor: null, archived_count: archived.length });
    }
    if (method === "GET" && url === "/api/trash/sessions") {
      return json({ ok: true, sessions: trashed.map(s => ({ ...s, session_id: s.id })), count: trashed.length, total_size: 0 });
    }
    if (method === "PATCH" && (m = url.match(/^\/api\/sessions\/([^/]+)$/))) {
      const s = take(live, m[1]);
      if (s) archived.push({ ...s, archived_at: "2026-02-01T00:00:00Z" });
      return json({ ok: true, archived_at: "2026-02-01T00:00:00Z" });
    }
    if (method === "DELETE" && (m = url.match(/^\/api\/sessions\/([^/]+)$/))) {
      const s = take(live, m[1]);
      if (s) trashed.push(s);
      return json({ ok: true });
    }
    if (method === "POST" && url === "/api/projects/p1/sessions/archive") {
      const moved = live.splice(0, live.length);
      moved.forEach(s => archived.push({ ...s, archived_at: "2026-02-01T00:00:00Z" }));
      return json({ ok: true, archived: moved.length });
    }
    if (method === "DELETE" && (url === "/api/projects/p1/sessions" || url === "/api/projects/p1")) {
      trashed.push(...live.splice(0, live.length), ...archived.splice(0, archived.length));
      return json({ ok: true });
    }
    throw new Error(`unexpected request: ${method} ${url}`);
  };

  const unrefTimeout = (fn, ms, ...args) => {
    const timer = setTimeout(fn, ms, ...args);
    if (timer.unref) timer.unref();
    return timer;
  };

  const router = { current: "welcome", navigate() {} };
  const context = {
    console, Date, Map, Set, Math, JSON, Promise, URLSearchParams,
    setTimeout: unrefTimeout,
    clearTimeout,
    setInterval: () => 0,
    clearInterval() {},
    document,
    location: { hash: "" },
    fetch,
    I18n: { t: key => key, lang: () => "en", applyAll() {} },
    Modal: { confirm: async () => true, toast() {} },
    WS: autoStub(),
    Clacky: {},
    $: id => document.getElementById(id),
    escapeHtml: s => String(s === undefined || s === null ? "" : s),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    Router: router,
    NewSessionStore: { state: {}, updateAdvanced() {} },
    Tasks: autoStub(),
    Skills: autoStub(),
    Composer: autoStub({ text: () => "", chips: () => [] }),
    IME: autoStub({ track: () => ({ isComposing: () => false, dispose() {} }) }),
    CustomSelect: { init() {} },
    alert() {},
  };
  context.window = context;
  context.globalThis = context;
  const elementStub = () => new Proxy({}, { get: () => () => new Element() });
  for (const name of ["RenderTarget", "QuoteSelect"]) context[name] = elementStub();
  context.MutationObserver = class { observe() {} disconnect() {} };
  context.ResizeObserver = context.MutationObserver;
  context.IntersectionObserver = context.MutationObserver;
  context.addEventListener = () => {};
  vm.createContext(context);

  for (const file of [
    "utils.js", "sessions.js", "projects.js",
    "features/trash/store.js", "features/trash/view.js",
    "features/archive/store.js", "features/archive/view.js",
  ]) {
    vm.runInContext(read(file), context, { filename: file });
  }

  const get = name => vm.runInContext(name, context);
  const Sessions = get("Sessions");
  const Projects = get("Projects");
  Projects.setAll([{ id: "p1", name: "P1" }]);
  live.forEach(s => Sessions.add({ ...s }));

  // Open a page the way the router does: record the view, then run its onPanelShow.
  const open = async view => {
    router.current = view;
    if (view === "archive") get("Archive").onPanelShow();
    if (view === "trash") get("Trash").onPanelShow();
    await tick();
    requests.length = 0;
  };

  return {
    Sessions, Projects, Archive: get("Archive"), Trash: get("Trash"),
    router, requests, open,
    archivedIds: () => Array.from(get("Archive").state.items, s => s.id),
    trashedIds: () => Array.from(get("Trash").state.sessions, s => s.session_id),
  };
}

const tick = () => new Promise(resolve => setImmediate(resolve));
const archiveLoads = h => h.requests.filter(r => r.startsWith("GET /api/sessions?"));
const trashLoads = h => h.requests.filter(r => r === "GET /api/trash/sessions");

async function main() {
  // Archiving from the sidebar while the archive page is open.
  {
    const h = boot();
    await h.open("archive");
    assert.deepEqual(h.archivedIds(), ["OLD"]);

    const res = await h.Archive.archiveSession(row("L1"));
    await tick();

    assert.equal(res.ok, true);
    assert.equal(archiveLoads(h).length, 1, "archive list is reloaded");
    assert.deepEqual(h.archivedIds(), ["OLD", "L1"], "the archived chat shows up without a manual refresh");
    assert.equal(h.Archive.state.archivedTotal, 2, "the count follows the server");
  }

  // Deleting from the sidebar while the recycle bin is open.
  {
    const h = boot();
    await h.open("trash");
    assert.deepEqual(h.trashedIds(), []);

    await h.Sessions.deleteSession("L1");
    await tick();

    assert.equal(trashLoads(h).length, 1, "trash list is reloaded");
    assert.deepEqual(h.trashedIds(), ["L1"], "the deleted chat shows up without a manual refresh");
  }

  // Archiving every session of a project while the archive page is open.
  {
    const h = boot();
    await h.open("archive");

    await h.Projects.promptArchiveSessions("p1");
    await tick();

    assert.equal(archiveLoads(h).length, 1);
    assert.deepEqual(h.archivedIds(), ["OLD", "L1", "L2"]);
  }

  // Clearing a project's sessions, or deleting the project, soft-deletes live
  // and archived chats alike: both pages can be affected.
  for (const act of [p => p.promptDeleteSessions("p1"), p => p.remove("p1")]) {
    {
      const h = boot();
      await h.open("trash");
      await act(h.Projects);
      await tick();
      assert.equal(trashLoads(h).length, 1, "trash list is reloaded");
      assert.deepEqual(h.trashedIds(), ["L1", "L2", "OLD"]);
    }
    {
      const h = boot();
      await h.open("archive");
      await act(h.Projects);
      await tick();
      assert.equal(archiveLoads(h).length, 1, "archive list is reloaded");
      assert.deepEqual(h.archivedIds(), [], "archived chats removed with the project disappear");
    }
  }

  // Any other page: nothing is fetched, the next visit loads fresh anyway.
  for (const view of ["session", "welcome", "tasks", "backup"]) {
    const h = boot();
    await h.open(view);

    await h.Archive.archiveSession(row("L1"));
    await h.Sessions.deleteSession("L2");
    await h.Projects.promptArchiveSessions("p1");
    await h.Projects.promptDeleteSessions("p1");
    await tick();

    assert.deepEqual(archiveLoads(h), [], `no archive reload while on ${view}`);
    assert.deepEqual(trashLoads(h), [], `no trash reload while on ${view}`);
  }

  // Archive page open: deleting a session does not touch the recycle bin list,
  // and vice versa.
  {
    const h = boot();
    await h.open("archive");
    await h.Sessions.deleteSession("L1");
    await tick();
    assert.deepEqual(trashLoads(h), [], "trash is not loaded while the archive page is on screen");
  }
  {
    const h = boot();
    await h.open("trash");
    await h.Archive.archiveSession(row("L1"));
    await tick();
    assert.deepEqual(archiveLoads(h), [], "archive is not loaded while the recycle bin is on screen");
  }
}

main().then(
  () => console.log("data_management_live_refresh_test: ok"),
  err => { console.error(err); process.exit(1); },
);
