"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(
  path.resolve(__dirname, "../../lib/clacky/web/utils.js"),
  "utf8"
);

// Every portalled dropdown caps itself at 17.5rem in app.css.
const CSS_MAX_HEIGHT = 280;

function load(viewportHeight) {
  const context = vm.createContext({
    window: {
      innerHeight: viewportHeight,
      getComputedStyle: (el) => ({ maxHeight: el.computedMaxHeight || "none" }),
    },
  });
  vm.runInContext(source, context);
  return vm.runInContext("FloatingDropdown", context);
}

function dropdown(scrollHeight) {
  return { style: {}, scrollHeight, computedMaxHeight: CSS_MAX_HEIGHT + "px" };
}

function anchor(top, bottom) {
  return {
    getBoundingClientRect: () => ({ top, bottom, height: bottom - top, left: 20, width: 300 }),
  };
}

function assertInsideViewport(dd, viewportHeight) {
  const top = dd.style.top === "auto" ? null : parseFloat(dd.style.top);
  const bottom = dd.style.bottom === "auto" ? null : viewportHeight - parseFloat(dd.style.bottom);
  const height = parseFloat(dd.style.maxHeight);

  assert.ok(top !== null || bottom !== null, "panel is anchored");
  const panelTop = top !== null ? top : bottom - height;
  const panelBottom = top !== null ? top + height : bottom;
  assert.ok(panelTop >= 0, `panel top ${panelTop} stays on screen`);
  assert.ok(panelBottom <= viewportHeight, `panel bottom ${panelBottom} stays on screen`);
}

// A short list with plenty of room keeps opening downwards, untouched.
{
  const dd = dropdown(140);
  load(827).place(dd, anchor(300, 340));

  assert.equal(dd.style.position, "fixed");
  assert.equal(dd.style.top, "344px");
  assert.equal(dd.style.bottom, "auto");
  assert.equal(dd.style.maxHeight, "140px");
}

// A long list near the bottom is capped to the room left below the field so
// the options stay reachable instead of running past the viewport edge.
{
  const dd = dropdown(27 * 32);
  load(827).place(dd, anchor(527, 559));

  assert.equal(dd.style.top, "563px");
  assert.equal(dd.style.bottom, "auto");
  assert.ok(parseFloat(dd.style.maxHeight) > 200, "still shows a browsable list");
  assertInsideViewport(dd, 827);
}

// When the field sits too low for a browsable list, the panel opens upwards.
{
  const dd = dropdown(27 * 32);
  load(827).place(dd, anchor(700, 732));

  assert.equal(dd.style.top, "auto");
  assert.equal(dd.style.bottom, (827 - 700 + 4) + "px");
  assert.equal(dd.style.maxHeight, CSS_MAX_HEIGHT + "px");
  assertInsideViewport(dd, 827);
}

// A viewport too short for the flapped panel still clamps to the room above.
{
  const dd = dropdown(27 * 32);
  load(400).place(dd, anchor(320, 352));

  assert.equal(dd.style.top, "auto");
  assert.equal(dd.style.maxHeight, CSS_MAX_HEIGHT + "px");
  assertInsideViewport(dd, 400);
}

// Closing a dropdown hands the element back to its original container, so the
// positioning styles must not linger.
{
  const dd = dropdown(200);
  const panel = load(827);
  panel.place(dd, anchor(300, 340));
  panel.reset(dd);

  ["position", "top", "bottom", "left", "right", "width", "minWidth", "maxHeight", "zIndex"]
    .forEach((key) => assert.equal(dd.style[key], "", `${key} is cleared`));
}

console.log("floating dropdown positioning: ok");
