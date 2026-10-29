"use strict";

// Branch state for the /#new context bar: the work tree's branch belongs to
// the project, not the session, so the store caches it per project, drops
// responses for a project the user already switched away from, and merges
// checkout results back into the same shape.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const storePath = path.resolve(__dirname, "../../lib/clacky/web/features/new-session/store.js");

function boot({ projects = {}, checkoutResult = null } = {}) {
  const calls = [];
  const emitted = [];

  const context = {
    console, JSON, Promise, Math, Object, String, Number, Array, Date, Boolean,
    setTimeout: (fn, ms, ...args) => {
      const timer = setTimeout(fn, ms, ...args);
      if (timer.unref) timer.unref();
      return timer;
    },
    clearTimeout,
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    fetch: async () => ({ ok: false, json: async () => ({}) }),
    Projects: {
      gitInfo: async (id, dir) => {
        calls.push({ kind: "gitInfo", id, dir: dir || "" });
        const entry = projects[`${id}\u0000${dir || ""}`] || projects[String(id)];
        if (!entry) throw new Error("git info failed");
        if (typeof entry.then === "function") return entry;
        return entry;
      },
      checkoutBranch: async (id, opts) => {
        calls.push({ kind: "checkout", id, opts });
        return checkoutResult;
      },
    },
    Clacky: { ext: { emit: (name) => emitted.push(name) } },
  };
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(storePath, "utf8"), context);

  return { Store: context.NewSessionStore, calls, emitted };
}

async function tests() {
  // 1. A repo project yields repo/branch/branches, and the second read is cached.
  {
    const { Store, calls } = boot({
      projects: {
        p1: { repo: true, branch: "main", branches: [{ name: "main", current: true }, { name: "dev", current: false }] },
      },
    });

    const git = await Store.loadGitInfo("p1");
    assert.equal(git.repo, true);
    assert.equal(git.branch, "main");
    assert.equal(git.loaded, true);
    assert.deepEqual(Array.from(git.branches, (b) => b.name), ["main", "dev"]);
    assert.equal(calls.length, 1);

    await Store.loadGitInfo("p1");
    assert.equal(calls.length, 1, "second read must not refetch");

    await Store.loadGitInfo("p1", { force: true });
    assert.equal(calls.length, 2, "force refetches");
  }

  // 2. A failure or non-repo project collapses to repo:false instead of throwing.
  {
    const { Store } = boot({ projects: {} });
    const git = await Store.loadGitInfo("p2");
    assert.equal(git.repo, false);
    assert.equal(git.loaded, true);
    assert.equal(git.loading, false);
    assert.equal(git.branch, "");
    assert.equal(git.branches.length, 0);
  }

  // 3. Clearing the project nulls the state once, not on every render.
  {
    const { Store, emitted } = boot({
      projects: { p1: { repo: true, branch: "main", branches: [] } },
    });
    await Store.loadGitInfo("p1");
    const before = emitted.length;

    await Store.loadGitInfo(null);
    const afterFirstClear = emitted.length;
    assert.equal(Store.state.git.projectId, null);
    assert.equal(Store.state.git.repo, false);
    assert.equal(afterFirstClear, before + 1);

    await Store.loadGitInfo(null);
    assert.equal(emitted.length, afterFirstClear, "repeat clear stays quiet");
  }

  // 4. A slow response for a project the user already left must not win.
  {
    let releaseSlow;
    const slow = new Promise((resolve) => { releaseSlow = resolve; });
    const { Store } = boot({
      projects: {
        p1: slow,
        p2: { repo: true, branch: "dev", branches: [{ name: "dev", current: true }] },
      },
    });

    const first = Store.loadGitInfo("p1");
    await Store.loadGitInfo("p2");
    releaseSlow({ repo: true, branch: "main", branches: [{ name: "main", current: true }] });
    await first;

    assert.equal(Store.state.git.projectId, "p2");
    assert.equal(Store.state.git.branch, "dev");
  }

  // 5. A checkout response updates the cached branch and list in place.
  {
    const { Store } = boot({
      projects: { p1: { repo: true, branch: "main", branches: [{ name: "main", current: true }] } },
    });
    await Store.loadGitInfo("p1");

    Store.applyGitState({
      branch: "feature/x",
      branches: [{ name: "main", current: false }, { name: "feature/x", current: true }],
    });

    assert.equal(Store.state.git.projectId, "p1");
    assert.equal(Store.state.git.branch, "feature/x");
    assert.equal(Store.state.git.repo, true);
    assert.deepEqual(Array.from(Store.state.git.branches, (b) => b.name), ["main", "feature/x"]);
  }

  // 6. A different working dir on the same project refetches: it may be a
  //    different repo with a different branch entirely.
  {
    const { Store, calls } = boot({
      projects: {
        "p1\u0000": { repo: true, branch: "main", branches: [{ name: "main", current: true }] },
        "p1\u0000/tmp/other": { repo: true, branch: "dev", branches: [{ name: "dev", current: true }] },
      },
    });

    const first = await Store.loadGitInfo("p1");
    assert.equal(first.branch, "main");
    assert.equal(calls[0].dir, "", "no dir means the project's own working dir");

    const second = await Store.loadGitInfo("p1", { dir: "/tmp/other" });
    assert.equal(second.branch, "dev");
    assert.equal(second.dir, "/tmp/other");
    assert.equal(calls.length, 2, "a new dir must refetch");
    assert.equal(calls[1].dir, "/tmp/other");

    await Store.loadGitInfo("p1", { dir: "/tmp/other" });
    assert.equal(calls.length, 2, "same dir stays cached");

    await Store.loadGitInfo("p1");
    assert.equal(calls.length, 3, "going back to the project dir refetches too");
    assert.equal(Store.state.git.branch, "main");
  }

  console.log("new_session_branch_state_test: ok");
}

tests().catch((err) => {
  console.error(err);
  process.exit(1);
});
