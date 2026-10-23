/**
 * ImageZoom — shared zoom and pan behavior for image viewers.
 *
 * The image keeps its natural dimensions and is transformed around the centre
 * of the viewport, so 100% always means one image pixel per screen pixel.
 */
;(function(window) {
  "use strict";

  const DEFAULT_MIN_SCALE = 0.1;
  const DEFAULT_MAX_SCALE = 8;
  const DEFAULT_STEP = 1.25;

  function create(options) {
    const viewport = options.viewport;
    const image = options.image;
    const minScale = options.minScale || DEFAULT_MIN_SCALE;
    const maxScale = options.maxScale || DEFAULT_MAX_SCALE;
    const step = options.step || DEFAULT_STEP;
    const fitPadding = options.fitPadding || 1;
    const onChange = options.onChange || function() {};

    let scale = 1;
    let fit = 1;
    let x = 0;
    let y = 0;
    let drag = null;

    function fitScale() {
      const vw = viewport.clientWidth;
      const vh = viewport.clientHeight;
      if (!vw || !vh) return 1;
      const nw = image.naturalWidth || vw;
      const nh = image.naturalHeight || vh;
      return Math.min(1, vw * fitPadding / nw, vh * fitPadding / nh);
    }

    function pan(offsetX, offsetY) {
      const maxX = Math.max(0, (image.naturalWidth * scale - viewport.clientWidth) / 2);
      const maxY = Math.max(0, (image.naturalHeight * scale - viewport.clientHeight) / 2);
      x = Math.max(-maxX, Math.min(maxX, offsetX));
      y = Math.max(-maxY, Math.min(maxY, offsetY));
    }

    function state() {
      return {
        scale,
        fit,
        atFit: Math.abs(scale - fit) < 1e-6,
        canZoomIn: scale < maxScale - 1e-6,
        canZoomOut: scale > minScale + 1e-6,
      };
    }

    function render() {
      pan(x, y);
      image.style.transform = "translate(" + x + "px, " + y + "px) scale(" + scale + ")";
      onChange(state());
    }

    // Zoom around a point relative to the viewport centre, so the image pixel
    // beneath the pointer stays in place rather than drifting toward a corner.
    function zoomAt(target, px, py) {
      const next = Math.max(minScale, Math.min(maxScale, target));
      if (next === scale) return;
      const k = next / scale;
      x = px - k * (px - x);
      y = py - k * (py - y);
      scale = next;
      render();
    }

    function anchorOf(ev) {
      const rect = viewport.getBoundingClientRect();
      return [
        ev.clientX - (rect.left + rect.width / 2),
        ev.clientY - (rect.top + rect.height / 2),
      ];
    }

    function reset() {
      fit = fitScale();
      scale = fit;
      x = 0;
      y = 0;
      render();
    }

    function zoomIn() { zoomAt(scale * step, 0, 0); }
    function zoomOut() { zoomAt(scale / step, 0, 0); }

    function onWheel(ev) {
      ev.preventDefault();
      const anchor = anchorOf(ev);
      zoomAt(scale * Math.exp(-ev.deltaY * 0.002), anchor[0], anchor[1]);
    }

    function onDoubleClick(ev) {
      ev.preventDefault();
      if (state().atFit) {
        const anchor = anchorOf(ev);
        zoomAt(fit < 1 ? 1 : fit * 2, anchor[0], anchor[1]);
      } else {
        reset();
      }
    }

    function onPointerDown(ev) {
      if (ev.button || (options.panOnImageOnly && ev.target !== image)) return;
      drag = { id: ev.pointerId, x: ev.clientX, y: ev.clientY };
      viewport.classList.add("is-panning");
      viewport.setPointerCapture(ev.pointerId);
      ev.preventDefault();
    }

    function onPointerMove(ev) {
      if (!drag || ev.pointerId !== drag.id) return;
      pan(x + ev.clientX - drag.x, y + ev.clientY - drag.y);
      drag.x = ev.clientX;
      drag.y = ev.clientY;
      image.style.transform = "translate(" + x + "px, " + y + "px) scale(" + scale + ")";
    }

    function endDrag(ev) {
      if (!drag || ev.pointerId !== drag.id) return;
      drag = null;
      viewport.classList.remove("is-panning");
    }

    viewport.addEventListener("wheel", onWheel, { passive: false });
    viewport.addEventListener("dblclick", onDoubleClick);
    viewport.addEventListener("pointerdown", onPointerDown);
    viewport.addEventListener("pointermove", onPointerMove);
    viewport.addEventListener("pointerup", endDrag);
    viewport.addEventListener("pointercancel", endDrag);
    image.addEventListener("load", reset);

    if (image.complete) reset();
    else render();

    // Refit only while the image is still fitted. A deliberate user zoom must
    // survive a viewport resize or a tab becoming visible.
    const observer = typeof ResizeObserver === "function"
      ? new ResizeObserver(function() { if (state().atFit) reset(); })
      : null;
    if (observer) observer.observe(viewport);

    function destroy() {
      if (observer) observer.disconnect();
      drag = null;
      viewport.classList.remove("is-panning");
      viewport.removeEventListener("wheel", onWheel);
      viewport.removeEventListener("dblclick", onDoubleClick);
      viewport.removeEventListener("pointerdown", onPointerDown);
      viewport.removeEventListener("pointermove", onPointerMove);
      viewport.removeEventListener("pointerup", endDrag);
      viewport.removeEventListener("pointercancel", endDrag);
      image.removeEventListener("load", reset);
    }

    return { zoomIn, zoomOut, reset, destroy, state };
  }

  window.ImageZoom = { create };
})(window);
