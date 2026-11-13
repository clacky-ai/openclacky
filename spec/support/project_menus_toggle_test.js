"use strict";

// Regression harness for the project-area "···" menus toggle.
//
// Both menus dismiss via a capture-phase document mousedown, which runs before
// the button's click. Clicking the owning "···" again must close the menu
// instead of dismiss-on-mousedown followed by reopen-on-click.
//
// The real projects.js runs against a minimal DOM stub.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/projects.js"), "utf8");

class Element {
  constructor(tag = "div", id = "") {
    this.tagName = tag;
    this.id = id;
    this.style = { setProperty() {} };
    this.dataset = {};
    this.children = [];
    this.parentNode = null;
    this.listeners = {};
    this.classes = new Set();
    this._className = "";
    this._innerHTML = "";
    this.textContent = "";
    this.title = "";
    this.classList = {
      add: n => this.classes.add(n),
      remove: n => this.classes.delete(n),
      toggle: (n, on) => ((on === undefined ? !this.classes.has(n) : on) ? this.classes.add(n) : this.classes.delete(n)),
      contains: n => this.classes.has(n),
    };
  }
  set className(v) { this._className = v; this.classes = new Set(v.split(/\s+/).filter(Boolean)); }
  get className() { return this._className; }
  set innerHTML(v) {
    this._innerHTML = v;
    if (v === "") { this.children.forEach(c => { c.parentNode = null; }); this.children = []; }
  }
  get innerHTML() { return this._innerHTML; }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
  removeEventListener(type, fn) { this.listeners[type] = (this.listeners[type] || []).filter(f => f !== fn); }
  appendChild(child) { child.remove(); this.children.push(child); child.parentNode = this; return child; }
  append(...kids) { kids.forEach(k => this.appendChild(k)); }
  remove() {
    if (!this.parentNode) return;
    this.parentNode.children = this.parentNode.children.filter(c => c !== this);
    this.parentNode = null;
  }
  matches(sel) { return sel.startsWith("#") ? this.id === sel.slice(1) : this.classes.has(sel.slice(1)); }
  closest(sel) {
    for (let el = this; el; el = el.parentNode) if (el.matches && el.matches(sel)) return el;
    return null;
  }
  contains(other) {
    for (let el = other; el; el = el.parentNode) if (el === this) return true;
    return false;
  }
  descendants() { return this.children.flatMap(c => [c, ...c.descendants()]); }
  querySelector(sel) { return this.descendants().find(el => el.matches(sel)) || null; }
  querySelectorAll(sel) { return this.descendants().filter(el => el.matches(sel)); }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }; }
  get nextElementSibling() {
    if (!this.parentNode) return null;
    const siblings = this.parentNode.children;
    return siblings[siblings.indexOf(this) + 1] || null;
  }
}

function boot() {
  const body = new Element("body");
  const sectionHeader = new Element("div", "projects-section-header");
  const btnOrganize = new Element("button", "btn-projects-organize");
  const organizeIcon = new Element("svg");
  const projectList = new Element("div", "project-list");
  btnOrganize.appendChild(organizeIcon);
  sectionHeader.appendChild(btnOrganize);
  body.append(sectionHeader, projectList);

  const captureMousedown = [];
  const document = {
    readyState: "complete",
    body,
    createElement: tag => new Element(tag),
    getElementById: id => body.descendants().find(el => el.id === id) || null,
    querySelector: sel => body.querySelector(sel),
    querySelectorAll: sel => body.querySelectorAll(sel),
    addEventListener(type, fn, capture) { if (type === "mousedown" && capture) captureMousedown.push(fn); },
    removeEventListener(type, fn, capture) {
      if (type !== "mousedown" || !capture) return;
      const i = captureMousedown.indexOf(fn);
      if (i >= 0) captureMousedown.splice(i, 1);
    },
  };

  const store = {};
  const context = {
    console,
    document,
    window: { innerWidth: 1280, innerHeight: 800 },
    localStorage: { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } },
    Sessions: { all: [], renderSessionItem() {}, renderList() {}, patch() {}, removeByProjectId() {}, _setupHorizontalTextOverflow() {} },
    I18n: { t: (_key, fallback) => fallback, applyAll() {} },
    NewSessionStore: { state: {}, updateAdvanced() {} },
    Router: { navigate() {} },
    fetch: async () => ({ ok: true, json: async () => ({}) }),
  };
  vm.createContext(context);
  vm.runInContext(`${source}\nthis.Projects = Projects;`, context, { filename: "projects.js" });

  // A real click: capture-phase mousedown on document, then click bubbling from the target.
  const click = target => {
    captureMousedown.slice().forEach(fn => fn({ target }));
    press(target);
  };
  // Keyboard activation (Enter/Space) fires click without a preceding mousedown.
  const press = target => {
    let stopped = false;
    const event = { target, stopPropagation: () => { stopped = true; } };
    for (let el = target; el && !stopped; el = el.parentNode) (el.listeners.click || []).forEach(fn => fn(event));
  };

  const Projects = context.Projects;
  Projects.setAll([{ id: "p-a", name: "A" }, { id: "p-b", name: "B" }]);
  Projects.renderSection();

  const headerOf = id => projectList.descendants().find(el => el.dataset.projectId === id);
  const actionsIconOf = id => {
    const btn = headerOf(id).children.find(el => el.className === "project-actions-btn");
    return btn.children[0] || btn.appendChild(new Element("svg"));
  };
  const newSessionBtnOf = id => headerOf(id).children.find(el => el.classes.has("project-new-session-btn"));

  return { Projects, body, sectionHeader, organizeIcon, click, press, actionsIconOf, newSessionBtnOf };
}

const organizeMenus = env => env.body.querySelectorAll(".project-organize-menu");
const projectMenus = env => env.body.querySelectorAll(".project-actions-menu");
const openProjectId = env => projectMenus(env).map(m => m.dataset.projectId);

{
  const env = boot();
  env.click(env.organizeIcon);
  assert.equal(organizeMenus(env).length, 1, "first click opens the organize menu");
  env.click(env.organizeIcon);
  assert.equal(organizeMenus(env).length, 0, "second click on the organize button closes it");
  env.click(env.organizeIcon);
  assert.equal(organizeMenus(env).length, 1, "third click reopens the organize menu");
  env.click(env.sectionHeader);
  assert.equal(organizeMenus(env).length, 0, "clicking outside closes the organize menu");
}

{
  const env = boot();
  env.click(env.actionsIconOf("p-a"));
  assert.deepEqual(openProjectId(env), ["p-a"], "first click opens project A's menu");
  env.click(env.actionsIconOf("p-a"));
  assert.deepEqual(openProjectId(env), [], "second click on A's button closes its menu");
  env.click(env.actionsIconOf("p-a"));
  assert.deepEqual(openProjectId(env), ["p-a"], "third click reopens A's menu");

  env.click(env.actionsIconOf("p-b"));
  assert.deepEqual(openProjectId(env), ["p-b"], "clicking B's button switches to B's menu");

  env.click(env.newSessionBtnOf("p-b"));
  assert.deepEqual(openProjectId(env), [], "the neighbouring new-session button counts as outside");

  env.click(env.actionsIconOf("p-a"));
  env.click(env.sectionHeader);
  assert.deepEqual(openProjectId(env), [], "clicking outside closes the project menu");
}

{
  const env = boot();
  env.click(env.actionsIconOf("p-a"));
  env.Projects.renderSection();
  env.click(env.actionsIconOf("p-a"));
  assert.deepEqual(openProjectId(env), [], "the re-rendered button of the same project still closes its menu");
}

{
  const env = boot();
  env.press(env.actionsIconOf("p-a"));
  env.press(env.actionsIconOf("p-b"));
  assert.deepEqual(openProjectId(env), ["p-b"], "keyboard activation on B switches from A's menu to B's");
  env.press(env.actionsIconOf("p-b"));
  assert.deepEqual(openProjectId(env), [], "keyboard activation on B again closes its menu");
}

console.log("project menus toggle: ok");
