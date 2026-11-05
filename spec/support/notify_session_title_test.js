"use strict";

// Regression harness for the desktop notification title.
//
// The toast used to say "Task complete" with no hint of which session had
// finished, which is useless when several background tasks are running. The
// title now names the session; the body stays generic so no prompt text leaks
// onto a shared screen.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(
  path.resolve(__dirname, "../../lib/clacky/web/components/notify.js"),
  "utf8"
);

const notifications = [];
class FakeNotification {
  constructor(title, options) {
    this.title = title;
    this.options = options;
    this.closed = false;
    notifications.push(this);
  }
  close() { this.closed = true; }
}
FakeNotification.permission = "granted";

const store = { "clacky-notify-sound": "on" };

const sandbox = {
  console,
  Clacky: {},
  Notification: FakeNotification,
  localStorage: {
    getItem: key => (key in store ? store[key] : null),
    setItem: (key, value) => { store[key] = String(value); },
  },
  document: {
    readyState: "complete",
    hidden: true,
    hasFocus: () => false,
    getElementById: () => null,
    querySelector: () => null,
    addEventListener: () => {},
  },
  Audio: class {
    constructor() { this.muted = false; this.currentTime = 0; }
    play() { return { then: () => this, catch: () => this }; }
    pause() {}
  },
  // The real i18n.js is exercised by RSpec copy checks; here the stub only
  // proves which key is chosen and which name is interpolated.
  I18n: {
    t: (key, vars = {}) => (vars.name ? `${key}:${vars.name}` : key),
  },
  Sessions: { activeId: "currently-open", find: () => null },
  setTimeout: () => 0,
};
sandbox.window = { Notification: FakeNotification };

vm.createContext(sandbox);
vm.runInContext(source, sandbox);

const Notify = sandbox.Clacky.Notify;

function finish(sid, awaiting, sessions, sessionName) {
  notifications.length = 0;
  sandbox.Sessions = sessions;
  Notify.onTaskFinished(sid, awaiting, sessionName);
  assert.equal(notifications.length, 1, "expected exactly one notification");
  return notifications[0];
}

// 1. Task complete, session known: the title names the session.
let n = finish("s1", false, {
  activeId: "currently-open",
  find: id => (id === "s1" ? { id, name: "修复登录页跳转" } : null),
});
assert.equal(n.title, "notify.desktop.titleWithName:修复登录页跳转");
assert.equal(n.options.body, "notify.desktop.body");

// 2. Awaiting reply uses the awaiting title and keeps the session name.
n = finish("s1", true, {
  activeId: "currently-open",
  find: id => (id === "s1" ? { id, name: "修复登录页跳转" } : null),
});
assert.equal(n.title, "notify.desktop.awaiting.titleWithName:修复登录页跳转");
assert.equal(n.options.body, "notify.desktop.awaiting.body");

// 3. Unknown session (e.g. a background session not loaded in this tab):
//    fall back to the generic title instead of an empty name.
n = finish("ghost", false, { activeId: "currently-open", find: () => null });
assert.equal(n.title, "notify.desktop.title");

// 4. Blank name behaves like an unknown session.
n = finish("s2", false, { activeId: "currently-open", find: () => ({ name: "   " }) });
assert.equal(n.title, "notify.desktop.title");

// 5. Long names are clipped to 40 code points, ellipsis included.
const longName = "很长很长的一个会话名字".repeat(6);
n = finish("s3", false, {
  activeId: "currently-open",
  find: () => ({ name: longName }),
});
const label = n.title.split(":").pop();
assert.equal(Array.from(label).length, 40);
assert.ok(label.endsWith("…"));
assert.ok(longName.startsWith(Array.from(label).slice(0, -1).join("")));

// 6. A cron run can land outside the loaded sidebar pages, so the name now
//    travels with the event. It must win over an empty local lookup.
n = finish("cron", false, { activeId: "currently-open", find: () => null }, "▶ 早报 09:00");
assert.equal(n.title, "notify.desktop.titleWithName:▶ 早报 09:00");

// 7. A whitespace-only name from the server counts as no name.
n = finish("cron", false, { activeId: "currently-open", find: () => null }, "   ");
assert.equal(n.title, "notify.desktop.title");

console.log("notify session title: ok");
