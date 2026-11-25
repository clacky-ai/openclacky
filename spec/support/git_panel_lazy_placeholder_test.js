"use strict";

// The load-on-click placeholder appears for two different reasons (the payload
// budget ran out on the server, or the render budget ran out in the browser),
// and neither of them means "this file changed a lot". The copy must stay
// neutral, and the static variant must not pretend to be clickable.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "../..");
const view = fs.readFileSync(path.join(root, "lib/clacky/default_extensions/git/panels/git/view.js"), "utf8");
const i18n = fs.readFileSync(path.join(root, "lib/clacky/web/i18n.js"), "utf8");

function extract(signature) {
  const start = view.indexOf(signature);
  assert.ok(start >= 0, `missing ${signature}`);
  return view.slice(start, view.indexOf("\n  }\n", start) + 4);
}

const source = extract("function renderLazy(");

const zh = {};
const zhPattern = /"changes\.diff\.(lazy|skipped)":\s*"([^"]*)"/g;
let hit;
while ((hit = zhPattern.exec(i18n))) {
  if (/\p{Script=Han}/u.test(hit[2])) zh[hit[1]] = hit[2];
}
assert.ok(zh.lazy && zh.skipped, "both keys must exist in the Chinese dictionary");

// The literal fallbacks in view.js are shown whenever I18n is unavailable, so
// they must not drift away from the dictionary.
assert.ok(source.includes(`"${zh.lazy}"`), "lazy fallback must match the Chinese dictionary");
assert.ok(source.includes(`"${zh.skipped}"`), "skipped fallback must match the Chinese dictionary");

const built = [];
const ctx = vm.createContext({
  state: { scope: "worktree", records: new Map() },
  t: (key, fallback) => fallback || key,
  el: (tag, attrs) => {
    const node = { tag: tag, attrs: attrs, clicks: 0 };
    node.addEventListener = () => { node.clicks += 1; };
    built.push(node);
    return node;
  },
  loadFileDiff: () => {},
});
vm.runInContext(source, ctx);

function placeholderFor(scope, file, record) {
  built.length = 0;
  ctx.state.scope = scope;
  ctx.state.records = new Map([[file.path, record]]);
  ctx.renderLazy({ querySelector: () => ({ appendChild() {} }) }, file);
  assert.equal(built.length, 1, "exactly one placeholder");
  return built[0];
}

const lazy = placeholderFor("worktree", { path: "a.txt" }, { lazyPending: true });
assert.equal(lazy.attrs.text, zh.lazy, "a loadable placeholder uses the neutral copy");
assert.equal(lazy.attrs.class, "cg-lazy", "a loadable placeholder has no static marker");
assert.equal(lazy.clicks, 1, "a loadable placeholder is clickable");
assert.ok(!/过大|较大|too large|Large/i.test(zh.lazy), "the copy must not claim the file changed a lot");

const staticBox = placeholderFor("lastTurn", { path: "b.txt" }, { lazyPending: true, raw: "" });
assert.equal(staticBox.attrs.text, zh.skipped, "a placeholder without a reload channel says so");
assert.equal(staticBox.attrs.class, "cg-lazy is-static", "it must not look clickable");
assert.equal(staticBox.clicks, 0, "it must not bind a click handler");

const reloadable = placeholderFor("lastTurn", { path: "c.txt" }, { lazyPending: true, raw: "@@ -1 +1 @@" });
assert.equal(reloadable.attrs.text, zh.lazy, "a last-turn file with its patch in memory stays loadable");
assert.equal(reloadable.clicks, 1, "and stays clickable");

console.log("Git panel lazy placeholder checks passed");
