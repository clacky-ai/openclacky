"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = path.resolve(__dirname, "../../lib/clacky/web/sessions.js");
const source = fs.readFileSync(sourcePath, "utf8");
const start = source.indexOf("// ── Session Info Bar Model Switcher");
const finish = source.indexOf("// ── Session Info Bar Working Directory Switcher", start);

assert.notEqual(start, -1, "model switcher source marker must exist");
assert.notEqual(finish, -1, "working-directory switcher source marker must exist");

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

function response({ ok = true, status = 200, body = {} } = {}) {
  return { ok, status, json: async () => body };
}

function createHarness({ sessionId = "session-a", modelId = "card-a", runtimeId = "" } = {}) {
  let activeId = sessionId;
  let modelDisabled = false;
  let fetchImpl = async () => response();
  const handlers = [];
  const populated = [];
  const alerts = [];
  const dropdown = {
    style: { display: "none" },
    innerHTML: "",
    getBoundingClientRect: () => ({ left: 0, right: 240, top: 0, width: 240, height: 200 }),
  };
  const modelEl = {
    isConnected: true,
    dataset: {
      sessionId,
      modelId,
      runtimeId,
      subModelOptions: "[]",
      subModel: "",
      cardModel: "Codex default",
    },
    classList: { contains: name => name === "sib-model-disabled" && modelDisabled },
    getBoundingClientRect: () => ({ left: 40, top: 300, width: 120 }),
    closest(selector) { return selector === "#sib-model" ? this : null; },
  };
  const outside = { closest: () => null };
  const sessions = {};
  Object.defineProperty(sessions, "activeId", { get: () => activeId });

  const context = vm.createContext({
    console: { log() {}, error() {} },
    document: {
      addEventListener(type, handler) { if (type === "click") handlers.push(handler); },
      getElementById() { return null; },
    },
    window: { innerWidth: 1200, innerHeight: 800 },
    Sessions: sessions,
    ModelPicker: {
      async populate(_container, options) { populated.push(options); },
      closeSubmodelPanel() {},
    },
    RuntimeProvider: {
      displayModel(model) { return model.display_model || model.model || ""; },
    },
    I18n: {
      t(key, vars = {}) {
        let value = `T:${key}`;
        Object.entries(vars).forEach(([name, replacement]) => {
          value += `:${name}=${replacement}`;
        });
        return value;
      },
    },
    Router: { navigate() {} },
    encodeURIComponent,
    setTimeout,
    alert(message) { alerts.push(message); },
    $(id) { return id === "sib-model-dropdown" ? dropdown : null; },
    fetch(...args) { return fetchImpl(...args); },
  });

  vm.runInContext(source.slice(start, finish), context);

  return {
    alerts,
    dropdown,
    modelEl,
    outside,
    populated,
    setActive(id) { activeId = id; },
    setModelDisabled(disabled) { modelDisabled = disabled; },
    setFetch(implementation) { fetchImpl = implementation; },
    async click(target) {
      const event = { target, stopPropagation() {} };
      await Promise.all(handlers.map(handler => handler(event)));
    },
  };
}

async function closeRace() {
  const harness = createHarness();
  const pending = deferred();
  harness.setFetch(() => pending.promise);

  const opening = harness.click(harness.modelEl);
  await Promise.resolve();
  await harness.click(harness.outside);
  pending.resolve(response({ body: { models: [{ id: "card-a", model: "api-a" }] } }));
  await opening;

  assert.notEqual(harness.dropdown.style.display, "block", "a closed picker must stay closed");
  assert.equal(harness.populated.length, 0, "a closed picker must discard its pending response");
}

async function sessionRace() {
  const harness = createHarness();
  const pending = deferred();
  harness.setFetch(() => pending.promise);

  const opening = harness.click(harness.modelEl);
  await Promise.resolve();
  harness.setActive("session-b");
  pending.resolve(response({ body: { models: [{ id: "card-a", model: "api-a" }] } }));
  await opening;

  assert.notEqual(harness.dropdown.style.display, "block", "an inactive session cannot reopen the picker");
  assert.equal(harness.populated.length, 0, "an inactive session cannot render into the shared picker");
}

async function disabledAnchorRace() {
  const harness = createHarness();
  const pending = deferred();
  harness.setFetch(() => pending.promise);

  const opening = harness.click(harness.modelEl);
  await Promise.resolve();
  harness.setModelDisabled(true);
  pending.resolve(response({ body: { models: [{ id: "card-a", model: "api-a" }] } }));
  await opening;

  assert.notEqual(harness.dropdown.style.display, "block", "a picker cannot open after its anchor becomes disabled");
}

async function restoredRuntime() {
  const restoredId = "restored-runtime:codex:codex";
  const harness = createHarness({ modelId: restoredId, runtimeId: "codex" });
  let requestCount = 0;
  const apiCard = { id: "api-card", model: "api-model" };
  const sessionModel = {
    id: restoredId,
    provider_id: "codex",
    runtime_id: "codex",
    display_model: "Codex default",
    model: "gpt-5.6-sol",
    card_model: "Codex default",
    sub_model: "gpt-5.6-sol",
    sub_model_options: ["gpt-5.6-sol", "gpt-5.6-terra"],
  };
  harness.setFetch(async () => {
    requestCount += 1;
    return response({
      body: { models: [apiCard], session_model: sessionModel, media_capabilities: {} },
    });
  });

  await harness.click(harness.modelEl);

  assert.equal(harness.populated.length, 1);
  const options = harness.populated[0];
  assert.equal(options.currentId, restoredId);
  assert.ok(options.models.some(model => model.id === restoredId), "the restored card is rendered session-locally");
  assert.equal(options.isSelectable(apiCard), false, "runtime identity blocks API cards even without a global runtime card");
  assert.equal(JSON.stringify(options.subInfo.options), JSON.stringify(sessionModel.sub_model_options));
  await options.onSelect(sessionModel);
  assert.equal(requestCount, 1, "selecting the already-active restored card is a local no-op");
}

async function httpError() {
  const harness = createHarness();
  harness.setFetch(async () => response({
    ok: false,
    status: 503,
    body: { error: "backend unavailable", models: [{ id: "card-a", model: "api-a" }] },
  }));

  await harness.click(harness.modelEl);

  assert.equal(harness.populated.length, 0, "an unsuccessful response cannot populate model choices");
  assert.match(harness.dropdown.innerHTML, /T:sib\.model\.loadError/, "the error state is localized");
}

const scenarios = {
  "close-race": closeRace,
  "session-race": sessionRace,
  "disabled-anchor-race": disabledAnchorRace,
  "restored-runtime": restoredRuntime,
  "http-error": httpError,
};

const scenario = process.argv[2];
if (!scenarios[scenario]) {
  console.error(`Unknown scenario: ${scenario || "(missing)"}`);
  process.exitCode = 2;
} else {
  scenarios[scenario]().catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
}
