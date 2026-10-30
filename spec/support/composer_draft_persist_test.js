"use strict";

// Regression harness for composer draft persistence. Loads the real
// components/draft-store.js against an in-memory IndexedDB fake so a "reload"
// is just booting the module again over the same backing store.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const src = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/components/draft-store.js"), "utf8");
const DAY = 24 * 60 * 60 * 1000;

function fakeIndexedDB(disk, { broken = false } = {}) {
  const later = fn => setImmediate(fn);
  const request = (run) => {
    const req = {};
    later(() => { req.result = run(); req.onsuccess && req.onsuccess(); });
    return req;
  };
  const store = {
    getAll: () => request(() => Array.from(disk.values()).map(r => structuredClone(r))),
    put: row => request(() => disk.set(row.id, structuredClone(row))),
    delete: id => request(() => disk.delete(id)),
  };
  const db = { transaction: () => ({ objectStore: () => store }), createObjectStore() {} };
  return {
    open() {
      const req = {};
      later(() => {
        if (broken) { req.onerror && req.onerror(); return; }
        req.result = db;
        req.onupgradeneeded && req.onupgradeneeded();
        req.onsuccess && req.onsuccess();
      });
      return req;
    },
  };
}

function boot(disk, opts) {
  const listeners = {};
  const ctx = {
    Clacky: {},
    indexedDB: fakeIndexedDB(disk, opts),
    window: { addEventListener: (k, fn) => { listeners[k] = fn; } },
    setTimeout, clearTimeout, Promise, Date, Map, Array,
  };
  vm.createContext(ctx);
  vm.runInContext(src + "\nthis.DraftStore = DraftStore;", ctx);
  return { store: ctx.DraftStore, pagehide: () => listeners.pagehide() };
}

const tick = (ms = 5) => new Promise(r => setTimeout(r, ms));
const DRAFT = {
  text: "hello",
  images: [{ dataUrl: "data:image/png;base64,AAAA", name: "IMG_002.png", mimeType: "image/png", seq: 2 }],
  files: [{ name: "a.pdf", path: "/tmp/a.pdf", mime_type: "application/pdf" }],
  quotes: [{ role: "assistant", index: 3, text: "quoted" }],
};

(async () => {
  {
    const disk = new Map();
    const a = boot(disk);
    await a.store.ready;
    a.store.set("s1", DRAFT);
    assert.deepEqual(a.store.get("s1"), DRAFT, "reads are served from memory immediately");
    assert.equal(disk.size, 0, "writes are debounced");
    await tick(350);
    const b = boot(disk);
    await b.store.ready;
    assert.deepEqual(JSON.parse(JSON.stringify(b.store.get("s1"))), DRAFT, "text, images, files and quotes survive a reload");
  }

  {
    const disk = new Map();
    const a = boot(disk);
    await a.store.ready;
    a.store.set("s1", { text: "one" });
    a.store.set("s1", { text: "two" });
    a.pagehide();
    await tick();
    assert.equal(disk.get("s1").draft.text, "two", "pagehide flushes the latest debounced draft");
  }

  {
    const disk = new Map();
    const a = boot(disk);
    await a.store.ready;
    a.store.set("s1", DRAFT);
    await tick(350);
    a.store.delete("s1");
    assert.equal(a.store.get("s1"), undefined);
    await tick();
    assert.equal(disk.has("s1"), false, "delete also removes the disk copy");
  }

  {
    const disk = new Map();
    const a = boot(disk);
    await a.store.ready;
    a.store.set("s1", { text: "pending" });
    a.store.delete("s1");
    await tick(350);
    assert.equal(disk.has("s1"), false, "delete cancels a pending debounced write");
  }

  {
    const disk = new Map([
      ["old", { id: "old", draft: { text: "stale" }, ts: Date.now() - 8 * DAY }],
      ["new", { id: "new", draft: { text: "fresh" }, ts: Date.now() - 1 * DAY }],
    ]);
    const a = boot(disk);
    await a.store.ready;
    await tick();
    assert.equal(a.store.get("old"), undefined, "drafts older than 7 days are dropped");
    assert.equal(disk.has("old"), false, "and purged from disk");
    assert.equal(a.store.get("new").text, "fresh");
  }

  {
    const disk = new Map([["s1", { id: "s1", draft: { text: "disk" }, ts: Date.now() }]]);
    const a = boot(disk);
    a.store.set("s1", { text: "typed before load finished" });
    await a.store.ready;
    assert.equal(a.store.get("s1").text, "typed before load finished", "load never clobbers a newer in-memory draft");
  }

  {
    const a = boot(new Map(), { broken: true });
    await a.store.ready;
    a.store.set("s1", { text: "memory only" });
    await tick(350);
    assert.equal(a.store.get("s1").text, "memory only", "without IndexedDB drafts still work in memory");
  }

  console.log("composer draft persist: ok");
})().catch((e) => { console.error(e); process.exit(1); });
