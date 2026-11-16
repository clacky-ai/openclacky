"use strict";

// Regression harness (C-5857): the reporter injected into every preview HTML
// page patches pushState/replaceState. A root-absolute URL ("/virtual/abs")
// resolves against the frame origin and drops the prefix the page was served
// under (/preview/p/<port> or /preview/s/<session>), so the frame asked the
// host origin for its own assets and the reporter announced a URL the panel's
// relFromUrl could not map back. The patched calls must re-attach the prefix.
//
// The reporter lives inside PREVIEW_NAV_REPORT in lib/clacky/server/preview.rb;
// the Ruby spec extracts the <script> body and passes it here as argv[2].

const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const scriptPath = process.argv[2];
if (!scriptPath) throw new Error("usage: node preview_nav_prefix_test.js <reporter.js>");
const source = fs.readFileSync(scriptPath, "utf8");

function boot(pageUrl) {
  const start = new URL(pageUrl);
  const location = {
    href: start.href,
    origin: start.origin,
    pathname: start.pathname,
    search: start.search,
    hash: start.hash,
  };
  const reports = [];

  // Mirrors the browser: the resolved URL must keep the document origin, and
  // an empty/omitted url leaves the current entry alone.
  const apply = url => {
    if (url === null || url === undefined || url === "") return;
    const u = new URL(String(url), location.href);
    if (u.origin !== location.origin) throw new DOMException("cross origin", "SecurityError");
    location.href = u.href;
    location.origin = u.origin;
    location.pathname = u.pathname;
    location.search = u.search;
    location.hash = u.hash;
  };

  const history = {
    pushState(state, title, url) { apply(url); },
    replaceState(state, title, url) { apply(url); },
  };

  const context = {
    URL, String, Number, console, history, location,
    parent: { postMessage: msg => reports.push(msg) },
    document: { addEventListener() {} },
    addEventListener() {},
    setInterval: () => 0,
  };
  context.window = context;
  vm.createContext(context);
  vm.runInContext(source, context, { filename: "preview-nav-report.js" });

  return {
    location,
    history,
    reports,
    lastReport: () => (reports.length ? reports[reports.length - 1].href : null),
    href: () => location.href,
  };
}

const paths = href => {
  const u = new URL(href);
  return u.pathname + u.search + u.hash;
};

// ── Dev-server proxy: /preview/p/<port> ──────────────────────────────────
{
  const env = boot("http://preview.localhost:7070/preview/p/8899/index.html");

  assert.equal(env.lastReport(), "http://preview.localhost:7070/preview/p/8899/index.html",
    "the reporter announces the page it was served");

  env.history.pushState({}, "", "/virtual/abs?x=1#frag");
  assert.equal(paths(env.href()), "/preview/p/8899/virtual/abs?x=1#frag",
    "pushState keeps the proxy prefix, query and fragment");
  assert.equal(env.lastReport(), env.href(), "the new URL is announced to the panel");

  env.history.replaceState({}, "", "/other/page");
  assert.equal(paths(env.href()), "/preview/p/8899/other/page",
    "replaceState keeps the proxy prefix");

  env.history.pushState({}, "", "/preview/p/8899/already/there");
  assert.equal(paths(env.href()), "/preview/p/8899/already/there",
    "an already-prefixed URL is never prefixed twice");

  env.history.pushState({}, "", "../user/1");
  assert.equal(paths(env.href()), "/preview/p/8899/user/1",
    "a relative URL keeps the browser's own resolution");

  env.history.pushState({}, "", "http://preview.localhost:7070/deep/link");
  assert.equal(paths(env.href()), "/preview/p/8899/deep/link",
    "a same-origin absolute URL is folded back into the prefix");

  const before = env.href();
  env.history.pushState({ count: 1 }, "", undefined);
  assert.equal(env.href(), before, "an omitted url leaves the entry untouched");

  let crossOrigin = null;
  try {
    env.history.pushState({}, "", "http://example.com/x");
  } catch (e) {
    crossOrigin = e.name;
  }
  assert.equal(crossOrigin, "SecurityError", "a cross-origin URL is left for the browser to reject");
  assert.equal(env.href(), before, "the rejected call changed nothing");
}

// ── Workspace files: /preview/s/<session> ────────────────────────────────
{
  const env = boot("http://preview.localhost:7070/preview/s/encSession/index.html");

  env.history.pushState({}, "", "/virtual/abs");
  assert.equal(paths(env.href()), "/preview/s/encSession/virtual/abs",
    "workspace previews keep their session prefix too");

  env.history.replaceState({}, "", "/from?q=1");
  assert.equal(paths(env.href()), "/preview/s/encSession/from?q=1",
    "replaceState on the workspace route keeps prefix and query");
}

// ── Outside the preview proxy: no prefix, no rewriting ───────────────────
{
  const env = boot("http://localhost:7070/elsewhere/page.html");

  env.history.pushState({}, "", "/virtual/abs");
  assert.equal(paths(env.href()), "/virtual/abs",
    "a page served outside the proxy keeps root-absolute URLs untouched");

  env.history.pushState({}, "", "/preview/p/8899/x");
  assert.equal(paths(env.href()), "/preview/p/8899/x",
    "an explicit preview path still passes through");
}

console.log("preview nav prefix: ok");
