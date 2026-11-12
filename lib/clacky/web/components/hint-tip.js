// ── HintTip — dismissible one-shot hint anchored to an element ───────────────
// A tooltip vanishes on mouse-out; guidance has to stay on screen until the
// user reads it or closes it. The tip is portalled to <body> and positioned
// with `position: fixed`, so no ancestor's overflow or stacking context can
// clip it. Dismissal is remembered per storageKey: each hint teaches once.

const HintTip = (() => {
  const GAP = 10;         // space between the bubble tail and the anchor
  const EDGE = 8;         // minimum distance from the viewport edge
  const ARROW_INSET = 12; // keep the tail clear of the rounded corners
  const MAX_WIDTH = 480; // wide enough for one line of CJK copy on a widened sidebar

  function attach(opts) {
    const anchor = _resolve(opts.anchor);
    if (!anchor || _seen(opts.storageKey)) return null;

    const tip = _build(opts);
    document.body.appendChild(tip);

    const arrowAnchor = _resolve(opts.arrowAnchor) || anchor;
    let dismissed = false;
    let timer = null;
    let observer = null;

    function dismiss() {
      if (dismissed) return;
      dismissed = true;
      if (timer) { clearTimeout(timer); timer = null; }
      if (observer) { observer.disconnect(); observer = null; }
      tip.remove();
      window.removeEventListener("resize", update);
      window.removeEventListener("scroll", update, true);
      document.removeEventListener("transitionend", update);
      _remember(opts.storageKey);
    }

    function update() {
      if (dismissed) return;
      const rect = anchor.getBoundingClientRect();
      const onScreen = rect.width > 0 && rect.height > 0 &&
        rect.bottom > 0 && rect.top < window.innerHeight;
      // The anchor can be hidden (session closed, sidebar slid away) while the
      // tip is still on its delay — keep it invisible until the anchor returns.
      tip.style.visibility = onScreen ? "" : "hidden";
      if (!onScreen) return;
      _place(tip, rect, arrowAnchor.getBoundingClientRect(), opts.maxWidth, opts.arrowAlign, opts.align);
    }

    tip.querySelector(".hint-tip-close").addEventListener("click", e => {
      e.stopPropagation();
      dismiss();
    });
    // Acting on the hint is as good as closing it.
    (_resolve(opts.dismissOn) || anchor).addEventListener("click", dismiss);

    if (typeof IntersectionObserver === "function") {
      observer = new IntersectionObserver(update);
      observer.observe(anchor);
    }
    window.addEventListener("resize", update);
    window.addEventListener("scroll", update, true);
    // Sidebar collapse animates with a transform, which fires no resize event.
    document.addEventListener("transitionend", update);

    const show = () => {
      timer = null;
      if (dismissed) return;
      tip.style.display = "flex";
      update();
    };
    if (opts.delay) {
      timer = setTimeout(show, opts.delay);
    } else {
      show();
    }

    return { dismiss: dismiss };
  }

  function _place(tip, rect, arrowRect, maxWidth, arrowAlign, align) {
    const limit = typeof maxWidth === "function" ? maxWidth() : maxWidth;
    tip.style.maxWidth = Math.round(
      Math.min(limit || MAX_WIDTH, MAX_WIDTH, window.innerWidth - EDGE * 2)
    ) + "px";

    const bubble = tip.getBoundingClientRect();
    const spaceAbove = rect.top - GAP - EDGE;
    const spaceBelow = window.innerHeight - rect.bottom - GAP - EDGE;
    // Prefer above (the anchor is usually at the bottom of the screen), but
    // never render somewhere the bubble does not fit.
    const above = spaceAbove >= bubble.height || spaceAbove >= spaceBelow;

    let top = above ? rect.top - GAP - bubble.height : rect.bottom + GAP;
    top = Math.max(EDGE, Math.min(top, window.innerHeight - EDGE - bubble.height));

    // "start" pins the bubble to the anchor's leading edge, like a caption
    // sitting in the corner of the region it describes; otherwise centre it.
    let left = align === "start"
      ? rect.left + EDGE
      : rect.left + rect.width / 2 - bubble.width / 2;
    left = Math.max(EDGE, Math.min(left, window.innerWidth - EDGE - bubble.width));

    const arrowCenter = arrowRect.left + arrowRect.width / 2;
    // "start" parks the tail near the bubble's leading corner, which reads as
    // pointing at a whole row (Settings) rather than at one icon.
    const arrowLeft = arrowAlign === "start"
      ? ARROW_INSET
      : Math.max(
        ARROW_INSET,
        Math.min(arrowCenter - left, bubble.width - ARROW_INSET)
      );

    tip.style.top = Math.round(top) + "px";
    tip.style.left = Math.round(left) + "px";
    tip.style.setProperty("--hint-tip-arrow-left", Math.round(arrowLeft) + "px");
    tip.classList.toggle("hint-tip--above", above);
    tip.classList.toggle("hint-tip--below", !above);
  }

  function _build(opts) {
    const tip = document.createElement("div");
    tip.className = "hint-tip";
    tip.setAttribute("role", "note");
    tip.style.display = "none";

    const text = document.createElement("span");
    text.className = "hint-tip-text";
    if (opts.i18nKey) {
      text.setAttribute("data-i18n", opts.i18nKey);
      text.textContent = typeof I18n !== "undefined" ? I18n.t(opts.i18nKey) : (opts.text || "");
    } else {
      text.textContent = opts.text || "";
    }
    tip.appendChild(text);

    const close = document.createElement("button");
    close.type = "button";
    close.className = "hint-tip-close";
    close.setAttribute("data-i18n-title", "modal.close");
    close.title = typeof I18n !== "undefined" ? I18n.t("modal.close") : "Close";
    close.innerHTML = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 6 6 18"/><path d="m6 6 12 12"/></svg>';
    tip.appendChild(close);

    return tip;
  }

  function _resolve(target) {
    if (!target) return null;
    return typeof target === "string" ? document.getElementById(target) : target;
  }

  function _seen(key) {
    if (!key) return false;
    try {
      return localStorage.getItem(key) === "1";
    } catch (err) {
      // Storage blocked: showing the hint again beats never showing it.
      return false;
    }
  }

  function _remember(key) {
    if (!key) return;
    try {
      localStorage.setItem(key, "1");
    } catch (err) {
      // Non-fatal: the hint simply reappears next reload.
    }
  }

  return { attach: attach };
})();
