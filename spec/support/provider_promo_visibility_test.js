"use strict";

// The OpenClacky AI Keys promo shows up in two places: the model-edit modal
// (provider hint) and the Secondary Models section (media banner). Both are the
// same campaign, so a single dismissal must silence both, permanently.
//
// This harness pins:
//   * the visibility truth table (_shouldShowPromo), including "editing a
//     third-party model shows nothing" — the bug that started this;
//   * that a dismissal is persisted and respected on the next read;
//   * that both banners route their decision through the shared helpers.

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
    dismissed: vm.runInContext("_aiKeysPromoDismissed", context),
  };
}

function storageWith(initial) {
  const data = new Map(initial ? [["clacky-ai-keys-promo-dismissed", initial]] : []);
  return {
    getItem: key => (data.has(key) ? data.get(key) : null),
    setItem: (key, value) => data.set(key, String(value)),
  };
}

{
  const promo = load(storageWith(null));
  assert.equal(promo.shouldShow(null, false), true, "add flow: nothing picked yet shows the promo");
  assert.equal(promo.shouldShow("openclacky", false), true, "picking OpenClacky keeps the promo");
  assert.equal(promo.shouldShow("deepseek", false), false, "editing a DeepSeek model hides the promo");
  assert.equal(promo.shouldShow("openai", false), false, "editing an OpenAI model hides the promo");
  assert.equal(promo.shouldShow(null, true), false, "an unresolved custom provider hides the promo");
  assert.equal(promo.shouldShow("openclacky", true), false, "custom is custom even if the id resolves");
}

{
  const promo = load(storageWith("1"));
  assert.equal(promo.dismissed(), true, "the stored flag reads back");
  assert.equal(promo.shouldShow(null, false), false, "a dismissed promo never comes back, even in the add flow");
  assert.equal(promo.shouldShow("openclacky", false), false, "dismissal beats an OpenClacky selection");
}

{
  // Storage can be unavailable (private mode, disabled cookies). The ad must
  // still render rather than throwing into the settings init path.
  const promo = load({
    getItem() { throw new Error("denied"); },
    setItem() { throw new Error("denied"); },
  });
  assert.equal(promo.dismissed(), false);
  assert.equal(promo.shouldShow(null, false), true);
}

// Both surfaces must consult _aiKeysPromoDismissed, otherwise one of them keeps
// nagging after the other is closed.
assert.ok(
  /_aiKeysPromoDismissed\(\)/.test(
    source.slice(source.indexOf("function _updateMediaPromo("), source.indexOf("function _renderMediaRows("))
  ),
  "_updateMediaPromo must honour the dismissal"
);
assert.ok(
  source.slice(source.indexOf("function _shouldShowPromo(")).includes("_aiKeysPromoDismissed()"),
  "_shouldShowPromo must honour the dismissal"
);
assert.ok(
  !/_promoCloseButton\(\)/.test(
    source.slice(source.indexOf("function _showPromoHint("), source.indexOf("function _bindCardEvents("))
  ),
  "the model-modal promo must not render a dismiss button"
);
assert.ok(
  /getElementById\("media-promo-close"\)/.test(source),
  "the media banner close button must be wired"
);
