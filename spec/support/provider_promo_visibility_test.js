"use strict";

// The OpenClacky AI Keys promo shows up in two places: the model-edit modal
// (provider hint) and the Secondary Models section (media banner). Each surface
// carries its own dismiss button and its own localStorage flag, so closing one
// never silences the other.
//
// This harness pins:
//   * the modal hint truth table (_shouldShowPromo), including "editing a
//     third-party model shows nothing" — the bug that started this;
//   * that the two dismissals are stored under separate keys and only affect
//     their own surface;
//   * that both surfaces render their own close button.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/settings.js"), "utf8");

const start = source.indexOf("const AI_KEYS_PROMO_DISMISSED_KEY");
const end = source.indexOf("function _syncPromoHint(");
assert.ok(start !== -1 && end > start, "settings.js: promo helpers not found");

function load(localStorage) {
  const context = vm.createContext({ localStorage });
  vm.runInContext(source.slice(start, end), context);
  return {
    shouldShow: vm.runInContext("_shouldShowPromo", context),
    bannerDismissed: vm.runInContext("_aiKeysPromoDismissed", context),
    modalDismissed: vm.runInContext("_modelModalPromoDismissed", context),
  };
}

function storageWith(banner, modal) {
  const data = new Map();
  if (banner) data.set("clacky-ai-keys-promo-dismissed", banner);
  if (modal) data.set("clacky-model-modal-promo-dismissed", modal);
  return {
    getItem: key => (data.has(key) ? data.get(key) : null),
    setItem: (key, value) => data.set(key, String(value)),
  };
}

{
  const promo = load(storageWith(null, null));
  assert.equal(promo.shouldShow(null, false), true, "add flow: nothing picked yet shows the promo");
  assert.equal(promo.shouldShow("openclacky", false), true, "picking OpenClacky keeps the promo");
  assert.equal(promo.shouldShow("deepseek", false), false, "editing a DeepSeek model hides the promo");
  assert.equal(promo.shouldShow("openai", false), false, "editing an OpenAI model hides the promo");
  assert.equal(promo.shouldShow(null, true), false, "an unresolved custom provider hides the promo");
  assert.equal(promo.shouldShow("openclacky", true), false, "custom is custom even if the id resolves");
}

{
  // Closing the banner is a banner-only opt-out.
  const promo = load(storageWith("1", null));
  assert.equal(promo.bannerDismissed(), true, "the banner flag reads back");
  assert.equal(promo.modalDismissed(), false, "the banner flag is not the modal flag");
  assert.equal(promo.shouldShow(null, false), true, "the banner dismissal leaves the modal hint alone");
  assert.equal(promo.shouldShow("openclacky", false), true, "banner dismissal does not beat an OpenClacky selection");
}

{
  // Closing the hint inside the model editor is a hint-only opt-out.
  const promo = load(storageWith(null, "1"));
  assert.equal(promo.modalDismissed(), true, "the modal flag reads back");
  assert.equal(promo.bannerDismissed(), false, "the modal flag is not the banner flag");
  assert.equal(promo.shouldShow(null, false), false, "a dismissed hint stays gone in the add flow");
  assert.equal(promo.shouldShow("openclacky", false), false, "a dismissed hint stays gone for OpenClacky");
}

{
  // Storage can be unavailable (private mode, disabled cookies). The ad must
  // still render rather than throwing into the settings init path.
  const promo = load({
    getItem() { throw new Error("denied"); },
    setItem() { throw new Error("denied"); },
  });
  assert.equal(promo.bannerDismissed(), false);
  assert.equal(promo.modalDismissed(), false);
  assert.equal(promo.shouldShow(null, false), true);
}

const mediaBody = source.slice(source.indexOf("function _updateMediaPromo("), source.indexOf("function _renderMediaRows("));
const hintBody = source.slice(source.indexOf("function _shouldShowPromo("), source.indexOf("function _syncPromoHint("));

assert.ok(/_aiKeysPromoDismissed\(\)/.test(mediaBody), "_updateMediaPromo must honour its own dismissal");
assert.ok(!/_modelModalPromoDismissed\(\)/.test(mediaBody), "_updateMediaPromo must ignore the modal dismissal");
// The media banner is the same campaign as the model-modal hint, so white-label
// builds show it too rather than treating Brand.branded as an extra gate.
assert.ok(!/Brand\.branded/.test(mediaBody), "_updateMediaPromo must not hide the banner in white-label builds");

assert.ok(/_modelModalPromoDismissed\(\)/.test(hintBody), "_shouldShowPromo must honour the modal dismissal");
assert.ok(!/_aiKeysPromoDismissed\(\)/.test(hintBody), "_shouldShowPromo must ignore the banner dismissal");

const dismissBody = source.slice(source.indexOf("function _dismissModelModalPromo("), source.indexOf("function _shouldShowPromo("));
assert.ok(/MODEL_MODAL_PROMO_DISMISSED_KEY/.test(dismissBody), "the hint's close button must write its own key");

const showBody = source.slice(source.indexOf("function _showPromoHint("), source.indexOf("function _bindCardEvents("));
assert.ok(/class="promo-close"/.test(showBody), "the model-modal promo must render its own dismiss button");
assert.ok(/_dismissModelModalPromo/.test(showBody), "the model-modal promo close button must be wired");

assert.ok(
  /getElementById\("media-promo-close"\)/.test(source),
  "the media banner close button must be wired"
);
