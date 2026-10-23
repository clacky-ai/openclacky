"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class Target {
  constructor() {
    this.handlers = {};
    this.style = {};
    this.classes = new Set();
    this.classList = {
      add: name => this.classes.add(name),
      remove: name => this.classes.delete(name),
    };
  }

  addEventListener(kind, handler) {
    (this.handlers[kind] ||= new Set()).add(handler);
  }

  removeEventListener(kind, handler) {
    if (this.handlers[kind]) this.handlers[kind].delete(handler);
  }

  emit(kind, event = {}) {
    for (const handler of this.handlers[kind] || []) handler(event);
  }
}

const observers = [];
const context = {
  console,
  Math,
  ResizeObserver: class {
    constructor(callback) { this.callback = callback; observers.push(this); }
    observe(target) { this.target = target; }
    disconnect() { this.disconnected = true; }
  },
};
context.window = context;
vm.createContext(context);
vm.runInContext(
  fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/components/image-zoom.js"), "utf8"),
  context
);

const viewport = new Target();
viewport.clientWidth = 800;
viewport.clientHeight = 600;
viewport.getBoundingClientRect = () => ({ left: 0, top: 0, width: 800, height: 600 });
viewport.setPointerCapture = id => { viewport.captured = id; };

const image = new Target();
image.naturalWidth = 1600;
image.naturalHeight = 1200;
image.complete = true;

const changes = [];
const zoom = context.ImageZoom.create({
  viewport,
  image,
  panOnImageOnly: true,
  onChange: state => changes.push(state),
});

assert.equal(changes.at(-1).scale, 0.5, "an oversized image opens fitted");
assert.equal(image.style.transform, "translate(0px, 0px) scale(0.5)");

viewport.emit("wheel", {
  deltaY: -100,
  clientX: 400,
  clientY: 300,
  preventDefault() {},
});
assert.equal(Math.round(changes.at(-1).scale * 100), 61, "the wheel zooms around the pointer");

zoom.reset();
viewport.emit("pointerdown", {
  button: 0,
  pointerId: 1,
  clientX: 0,
  clientY: 0,
  target: viewport,
  preventDefault() {},
});
assert.equal(viewport.captured, undefined, "the lightbox backdrop does not begin a drag");

zoom.zoomIn();
viewport.emit("pointerdown", {
  button: 0,
  pointerId: 2,
  clientX: 0,
  clientY: 0,
  target: image,
  preventDefault() {},
});
viewport.emit("pointermove", { pointerId: 2, clientX: 500, clientY: 400 });
viewport.emit("pointerup", { pointerId: 2 });
assert.equal(image.style.transform, "translate(100px, 75px) scale(0.625)",
  "dragging stops at the image edge");
assert.equal(viewport.classes.has("is-panning"), false, "ending a drag restores the cursor state");

zoom.reset();
viewport.clientWidth = 400;
viewport.clientHeight = 300;
observers[0].callback();
assert.equal(changes.at(-1).scale, 0.25, "a fitted image follows viewport size changes");

zoom.zoomIn();
viewport.clientWidth = 800;
viewport.clientHeight = 600;
observers[0].callback();
assert.equal(changes.at(-1).scale, 0.3125, "a deliberate user zoom survives a resize");

zoom.destroy();
assert.equal(observers[0].disconnected, true, "destroy stops observing the viewport");
assert.equal(viewport.handlers.wheel.size, 0, "destroy removes interaction listeners");
assert.equal(image.handlers.load.size, 0, "destroy removes the image load listener");

console.log("image_zoom_test: ok");
