"use strict";

// Regression harness for the preview address bar dropping URL fragments.
// A page that jumps to #sec reports its full href, but the panel converted it
// into a fragment-free rel — identical to currentRel — so the address bar,
// the back/forward stacks and refresh all lost the anchor. The pure helpers
// are lifted out of the panel source and exercised in a vm sandbox: parsing
// must keep the fragment, building must keep it out of the percent-encoded
// path half, and the two directions must round-trip.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(
  path.resolve(__dirname, "../../lib/clacky/default_extensions/preview/panels/preview/view.js"),
  "utf8"
);

function sliceBetween(src, startMarker, endMarker, label) {
  const start = src.indexOf(startMarker);
  const end = src.indexOf(endMarker);
  assert.ok(start !== -1, `${label}: start marker not found`);
  assert.ok(end > start, `${label}: end marker not found`);
  return src.slice(start, end);
}

const builders = sliceBetween(
  source,
  "  function isExternal(rel) {",
  "  // The preview needs horizontal room",
  "url builders"
);
const parser = sliceBetween(
  source,
  "  function relFromUrl(url) {",
  "  // A dev server is reachable as either localhost or 127.0.0.1",
  "relFromUrl"
);

const context = vm.createContext({
  URL,
  location: { href: "http://127.0.0.1:7070/", origin: "http://127.0.0.1:7070" },
});
vm.runInContext('var activeSessionId = "abc123"; var currentRel = null;', context);
vm.runInContext(builders, context);
vm.runInContext('function devHostFor(port) { return "localhost"; }', context);
vm.runInContext(parser, context);

const relFromUrl = vm.runInContext("relFromUrl", context);
const buildUrl = vm.runInContext("buildUrl", context);
const displayUrl = vm.runInContext("displayUrl", context);

// ── Parsing keeps the fragment ────────────────────────────────────────────
assert.equal(
  relFromUrl("http://preview.localhost:7070/preview/p/9000/sec#sec"),
  "http://localhost:9000/sec#sec"
);
assert.equal(
  relFromUrl("http://preview.localhost:7070/preview/p/9000/#sec"),
  "http://localhost:9000/#sec",
  "a bare fragment on the dev-server root"
);
assert.equal(
  relFromUrl("http://preview.localhost:7070/preview/p/9000/list?page=2#row-7"),
  "http://localhost:9000/list?page=2#row-7",
  "query and fragment both survive"
);
assert.equal(
  relFromUrl("http://preview.localhost:7070/preview/s/abc123/index.html#sec"),
  "index.html#sec"
);
assert.equal(
  relFromUrl("http://preview.localhost:7070/preview/s/abc123/docs/a%20b.html#sec"),
  "docs/a b.html#sec",
  "encoded path segments decode, the fragment stays raw"
);
assert.equal(
  relFromUrl("http://preview.localhost:7070/preview/f/Users/x/a.html#sec"),
  "/Users/x/a.html#sec"
);
assert.equal(
  relFromUrl("http://preview.localhost:7070/preview/s/abc123/#sec"),
  null,
  "a fragment without a file is not a rel"
);
assert.equal(
  relFromUrl("http://preview.localhost:7070/preview/s/other/index.html#sec"),
  null,
  "a file from another session is not a rel"
);

// ── Building keeps the fragment out of the encoded path half ──────────────
assert.equal(buildUrl("abc123", "index.html#sec"), "/preview/s/abc123/index.html#sec");
assert.equal(
  buildUrl("abc123", "docs/说明.html#章节"),
  "/preview/s/abc123/docs/%E8%AF%B4%E6%98%8E.html#章节",
  "non-ASCII path encodes, hash text does not"
);
assert.equal(buildUrl("abc123", "/Users/x/a.html#sec"), "/preview/f/Users/x/a.html#sec");
assert.equal(buildUrl("abc123", "file:///Users/x/a.html#sec"), "/preview/f/Users/x/a.html#sec");
assert.equal(buildUrl("abc123", "http://localhost:9000/x?q=1#sec"), "/preview/p/9000/x?q=1#sec");
assert.equal(
  buildUrl("abc123", "http://example.com/x#sec"),
  "http://example.com/x#sec",
  "non-loopback URLs load as-is"
);

// ── Round trip: parse(build(rel)) === rel ─────────────────────────────────
const origin = "http://127.0.0.1:7070";
[
  "index.html#sec",
  "docs/a b.html#sec",
  "/Users/x/a.html#sec",
  "http://localhost:9000/x?q=1#sec",
].forEach((rel) => {
  assert.equal(relFromUrl(origin + buildUrl("abc123", rel)), rel, `round trip: ${rel}`);
});

// ── Address bar display ───────────────────────────────────────────────────
assert.equal(
  displayUrl("index.html#sec"),
  "http://127.0.0.1:7070/preview/s/abc123/index.html#sec"
);
assert.equal(displayUrl("http://localhost:9000/x#sec"), "http://localhost:9000/x#sec");

// ── No fragment: unchanged behaviour ──────────────────────────────────────
assert.equal(relFromUrl("http://preview.localhost:7070/preview/p/9000/"), "http://localhost:9000/");
assert.equal(buildUrl("abc123", "index.html"), "/preview/s/abc123/index.html");
assert.equal(displayUrl("index.html"), "http://127.0.0.1:7070/preview/s/abc123/index.html");
assert.equal(relFromUrl("https://example.com/x"), null);

console.log("preview rel/hash harness: all assertions passed");
