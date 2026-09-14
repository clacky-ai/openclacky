"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class FakeElement {
  constructor() {
    this.attrs = {};
    this.children = [];
    this.dataset = {};
    this.handlers = {};
    this.hidden = false;
    this.style = {};
    this.value = "";
    this.classes = new Set();
    this.classList = {
      add: name => this.classes.add(name),
      remove: name => this.classes.delete(name),
      toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name),
      contains: name => this.classes.has(name),
    };
  }

  set className(value) {
    this._className = value;
    this.classes = new Set(String(value).split(/\s+/).filter(Boolean));
  }

  get className() { return this._className || ""; }

  set innerHTML(value) {
    this._innerHTML = value;
    if (value === "") this.children = [];
  }

  get innerHTML() { return this._innerHTML || ""; }

  addEventListener(type, handler) {
    (this.handlers[type] ||= []).push(handler);
  }

  emit(type, event = {}) {
    const enriched = Object.assign({
      preventDefault() {},
      stopPropagation() {},
      target: this,
    }, event);
    return (this.handlers[type] || []).map(handler => handler(enriched));
  }

  appendChild(child) {
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  remove() {
    if (!this.parentNode) return;
    this.parentNode.children = this.parentNode.children.filter(child => child !== this);
    this.parentNode = null;
  }

  querySelector(selector) {
    if (!selector.startsWith(".")) return null;
    const className = selector.slice(1);
    for (const child of this.children) {
      if (child.classes && child.classes.has(className)) return child;
      const nested = child.querySelector && child.querySelector(selector);
      if (nested) return nested;
    }
    return null;
  }

  querySelectorAll() { return []; }
  setAttribute(name, value) { this.attrs[name] = String(value); }
  removeAttribute(name) { delete this.attrs[name]; }
  focus() {}
}

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

function tick() {
  return new Promise(resolve => setImmediate(resolve));
}

function sourcePath(name) {
  return path.resolve(__dirname, "../../lib/clacky/web", name);
}

function newSessionContext() {
  const input = new FakeElement();
  const send = new FakeElement();
  const elements = {
    "new-session-input": input,
    "new-session-send": send,
  };
  const state = {
    agents: [],
    selectedAgentId: null,
    models: [],
    advanced: {
      name: "",
      modelId: "",
      workingDir: "/tmp/project",
      initProject: false,
      projectId: null,
    },
    creating: false,
  };
  const requests = [];
  const store = {
    state,
    on() {},
    currentAgent() { return null; },
    loadAgentName: async () => "",
    loadAgents: async () => {},
    loadDefaultDirectory: async () => "",
    loadModels(options = {}) {
      const pending = deferred();
      const request = {
        options,
        promise: pending.promise,
        resolve(models) {
          if (options.commit !== false) state.models = models;
          pending.resolve(models);
        },
      };
      requests.push(request);
      return request.promise;
    },
    setModels(models) { state.models = models; },
    updateAdvanced(patch) { Object.assign(state.advanced, patch); },
  };
  const document = {
    addEventListener() {},
    getElementById: id => elements[id] || null,
    querySelector: () => null,
  };
  const composer = {
    init() {},
    hasContent: el => el.value.trim() !== "",
    text: el => el.value,
    chips: () => [],
    setPlaceholder() {},
  };
  const window = {};
  const context = vm.createContext({
    window,
    document,
    console,
    setTimeout,
    clearTimeout,
    setImmediate,
    NewSessionStore: store,
    Composer: composer,
    I18n: { lang: () => "en", t: key => key },
    RuntimeProvider: { displayModel: model => model.display_model || model.model || model.id },
    ModelPicker: { populate() {} },
    alert() {},
  });
  vm.runInContext(fs.readFileSync(sourcePath("features/new-session/view.js"), "utf8"), context);
  return { view: window.NewSessionView, state, requests, send };
}

async function modelRefreshTests() {
  const { view, state, requests, send } = newSessionContext();

  const firstShow = view.onPanelShow();
  await tick();
  assert.equal(requests.length, 1, "first display loads models");
  requests[0].resolve([{ id: "api-old", model: "old", type: "default" }]);
  await firstShow;
  assert.equal(state.models[0].id, "api-old");

  const secondShow = view.onPanelShow();
  await tick();
  assert.equal(requests.length, 2, "each later display refreshes models");
  requests[1].resolve([{ id: "runtime-new", display_model: "Codex", runtime_id: "codex", type: "default" }]);
  await secondShow;
  assert.equal(state.models[0].id, "runtime-new", "refreshed models replace the prior snapshot");

  const staleShow = view.onPanelShow();
  await tick();
  const currentShow = view.onPanelShow();
  await tick();
  assert.equal(requests.length, 4, "a newer display owns a separate refresh generation");

  requests[3].resolve([{ id: "fresh", model: "fresh", type: "default" }]);
  await currentShow;
  requests[2].resolve([{ id: "stale", model: "stale", type: "default" }]);
  await staleShow;
  assert.equal(state.models[0].id, "fresh", "an older response cannot overwrite the current generation");

  const dedupedShow = view.onPanelShow();
  await tick();
  assert.equal(requests.length, 5);
  const submitPromise = send.emit("click")[0];
  await tick();
  assert.equal(requests.length, 5, "submit shares the active display's model request");
  assert.equal(requests[4].options.commit, false, "the view commits only generation-current results");
  requests[4].resolve([{ id: "deduped", model: "deduped", type: "default" }]);
  await Promise.all([dedupedShow, submitPromise]);
}

function skillContext() {
  const ids = {
    input: new FakeElement(),
    dropdown: new FakeElement(),
    list: new FakeElement(),
    slash: new FakeElement(),
  };
  const body = new FakeElement();
  const document = {
    body,
    createElement: () => new FakeElement(),
    createTextNode: value => ({ nodeType: 3, textContent: String(value) }),
    getElementById(id) {
      if (ids[id]) return ids[id];
      const findById = node => {
        if (node.id === id) return node;
        for (const child of node.children || []) {
          const found = findById(child);
          if (found) return found;
        }
        return null;
      };
      return findById(body);
    },
  };
  const storage = new Map();
  const composer = {
    text: el => el.value,
    setText(el, value) { el.value = String(value); },
  };
  const window = {};
  const context = vm.createContext({
    window,
    document,
    console,
    localStorage: {
      getItem: key => storage.has(key) ? storage.get(key) : null,
      setItem: (key, value) => storage.set(key, value),
    },
    Composer: composer,
    IME: { track: () => ({ isComposing: () => false }) },
    I18n: { lang: () => "en", t: key => key },
    Sessions: { activeId: null, find: () => null, sendMessage() {} },
    Clacky: {},
    escapeHtml: value => String(value),
    $: id => document.getElementById(id),
  });
  vm.runInContext(fs.readFileSync(sourcePath("skills.js"), "utf8"), context);
  return { api: context.Clacky.SkillAC, ids };
}

async function insertedSkillCommandTests() {
  const { api, ids } = skillContext();
  api.attach({
    input: "input",
    dropdown: "dropdown",
    list: "list",
    slashBtn: "slash",
    systemChk: "missing-checkbox",
    isEnabled: () => true,
    fetchSkills: async () => [{ name: "slides", description: "Build slides", source_type: "default", always_show: true }],
    onSend() {},
  });

  ids.slash.emit("click");
  await tick();
  assert.equal(ids.list.children.length, 1, "skill picker renders its selectable skill");
  ids.list.children[0].emit("mousedown");
  assert.equal(ids.input.value, "/slides ", "selecting a skill inserts its command");
  assert.equal(typeof api.stripInsertedCommand, "function", "SkillAC exposes a guarded strip operation");

  ids.input.value = "/slides Build the quarterly deck";
  assert.equal(api.stripInsertedCommand(ids.input), true);
  assert.equal(ids.input.value, "Build the quarterly deck", "stripping keeps the user's description");

  ids.input.value = "/slides Keep this literal";
  assert.equal(api.stripInsertedCommand(ids.input), false, "manually entered slash text is not stripped");
  assert.equal(ids.input.value, "/slides Keep this literal");
}

(async () => {
  await modelRefreshTests();
  await insertedSkillCommandTests();
})().catch(error => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
