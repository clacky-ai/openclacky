"use strict";

// Custom endpoints pre-fill "cannot recognize images" from the model name,
// using what the presets declare; the user's own click always wins.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/settings.js"), "utf8");

function extract(name) {
  const start = source.indexOf(`  function ${name}(`);
  assert.ok(start >= 0, `${name} not found`);
  const end = source.indexOf("\n  }\n", start);
  return source.slice(start, end + 4);
}

function boot({ custom = true, touched = false, checked = false } = {}) {
  const fields = {
    "model-modal-model": { value: "" },
    "model-modal-no-vision": { checked },
  };
  const ctx = vm.createContext({
    document: { getElementById: id => fields[id] },
    _providers: [
      { id: "zai", model_capabilities: { "glm-5.3": { vision: false }, "glm-5.3-flash": { vision: true }, "glm-5v-turbo": { vision: true } } },
      { id: "ds", model_capabilities: { "deepseek-v4-pro": { vision: false } } },
      { id: "ark", model_capabilities: { "GLM-5.3": { vision: false }, "mixed": { vision: true } } },
      { id: "other", model_capabilities: { "mixed": { vision: false }, "plain": {} } },
    ],
    _modalProviderIsCustom: custom,
    _noVisionTouched: touched,
  });
  vm.runInContext(["_syncNoVisionFromModel", "_modelKey", "_knownVision"].map(extract).join("\n"), ctx);
  const type = v => { fields["model-modal-model"].value = v; vm.runInContext("_syncNoVisionFromModel()", ctx); };
  return { type, box: fields["model-modal-no-vision"] };
}

// 1. Text-only model is ticked, regardless of case, separators or relay prefix/suffix.
for (const name of ["glm-5.3", "GLM_5.3", " z-ai/glm-5.3 ", "wsp-deepseek-v4-pro", "deepseek-v4-pro-0528", "[relay]deepseek-v4-pro"]) {
  const w = boot();
  w.type(name);
  assert.equal(w.box.checked, true, name);
}

// 2. Switching to a vision model unticks it again.
{
  const w = boot();
  w.type("glm-5.3");
  w.type("glm-5v-turbo");
  assert.equal(w.box.checked, false);
}

// 2b. The longest known segment wins over a shorter one it contains.
{
  const w = boot();
  w.type("relay-glm-5.3-flash");
  assert.equal(w.box.checked, false);
}

// 3. Unknown, partial-segment, capability-less and conflicting names leave the box alone.
for (const name of ["glm-5.30", "xglm-5.3", "plain", "mixed", ""]) {
  const w = boot({ checked: true });
  w.type(name);
  assert.equal(w.box.checked, true, name);
}

// 4. Once the user clicked the box, typing never overrides it.
{
  const w = boot({ touched: true });
  w.type("glm-5.3");
  assert.equal(w.box.checked, false);
}

// 5. Preset providers are never touched.
{
  const w = boot({ custom: false });
  w.type("glm-5.3");
  assert.equal(w.box.checked, false);
}

// 6. Each modal open resets the "user touched" flag; listeners wire both paths.
assert.match(extract("_openModal"), /_noVisionTouched = false;/);
assert.match(source, /modelInput\.addEventListener\("change", _syncNoVisionFromModel\)/);
assert.match(source, /noVisionField\.addEventListener\("pointerdown", \(\) => \{ _noVisionTouched = true; \}\)/);
assert.match(source, /modelInput\.value = opt\.dataset\.value;\n\s+_syncNoVisionFromModel\(\);/);
assert.match(source, /"model-modal-no-vision"\)\.addEventListener\("change", \(\) => \{\n\s+_noVisionTouched = true;/);

console.log("model_vision_autodetect_test: ok");
