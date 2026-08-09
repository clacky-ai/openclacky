// ── Chat Navigator - vertical minimap on the right edge of the chat ────────
//
// Shows one bar per user message. Hovering a bar opens a scrollable popup
// listing every user message preview; clicking a bar or popup item scrolls
// the chat to that message.
//
// The navigator element is absolutely positioned inside #chat-main and its
// vertical bounds are synced to #messages via ResizeObserver so it never
// overlaps the composer / info bar below.
//
// Depends on: global $ helper (app.js), I18n.
// ───────────────────────────────────────────────────────────────────────────
"use strict";

(() => {
  const $ = (id) => document.getElementById(id);

  const NAV_SELECTOR = ".msg-user-wrap";
  const MAGNIFY_RADIUS = 64;
  const MAX_MAGNIFY    = 1.35;

  let nav, track, indicator, popup, popupList;
  let messages, chatMain;
  let items = [];          // [{ el, bar, popupItem, type, preview }]
  let activeIdx = -1;
  let mo, ro;
  let rebuildTimer = null;
  let scrollFrame = null;
  let showTimer = null;
  let hideTimer = null;
  let hoveredIdx = -1;
  let indicatorOffsetTop = 0;

  // ── Preview text extraction ────────────────────────────────────────────

  function _previewFor(el) {
    const bubble = el.querySelector(".msg-user");
    if (!bubble) return "";
    const clone = bubble.cloneNode(true);
    clone
      .querySelectorAll("img, .msg-pdf-badge, .msg-user-action-bar, .msg-time")
      .forEach((e) => e.remove());
    const text = clone.textContent.trim();
    return text || (I18n.t("chat.nav.empty") || "(empty)");
  }

  // ── Position sync ───────────────────────────────────────────────────────

  function _syncBounds() {
    if (!nav || !messages || !chatMain) return;
    const msgRect = messages.getBoundingClientRect();
    const mainRect = chatMain.getBoundingClientRect();
    nav.style.top = msgRect.top - mainRect.top + "px";
    nav.style.height = msgRect.height + "px";
  }

  // ── Rebuild bars + popup list ───────────────────────────────────────────

  function _scheduleRebuild() {
    clearTimeout(rebuildTimer);
    rebuildTimer = setTimeout(_rebuild, 120);
  }

  function _rebuild() {
    if (!messages || !track) return;
    clearTimeout(showTimer);
    _resetMagnification();
    const els = Array.from(messages.querySelectorAll(NAV_SELECTOR));
    items = els.map((el) => ({
      el,
      preview: _previewFor(el),
    }));

    // Hide navigator when content fits without scrolling
    const scrollable = messages.scrollHeight > messages.clientHeight + 40;
    nav.style.display = scrollable && items.length > 1 ? "" : "none";
    if (!scrollable || items.length <= 1) return;

    // Build bars. The floating indicator moves between these fixed message
    // landmarks as the chat scrolls, so progress reads continuously instead
    // of jumping from one active bar to the next.
    track.innerHTML = '<div class="chat-nav-indicator" aria-hidden="true"></div>';
    indicator = track.querySelector(".chat-nav-indicator");
    items.forEach((item, i) => {
      const bar = document.createElement("div");
      bar.className = "chat-nav-bar";
      bar.dataset.idx = String(i);
      bar.title = item.preview.slice(0, 120);
      bar.addEventListener("mouseenter", () => _onBarHover(i));
      bar.addEventListener("click", () => _scrollToIdx(i));
      track.appendChild(bar);
      item.bar = bar;
    });

    // Build popup list (lazy: build once per rebuild)
    popupList.innerHTML = "";
    items.forEach((item, i) => {
      const li = document.createElement("div");
      li.className = "chat-nav-popup-item";
      li.dataset.idx = String(i);
      li.innerHTML =
        `<span class="chat-nav-popup-item-text">${escapeHtml(item.preview)}</span>`;
      li.addEventListener("mouseenter", () => _onItemHover(i));
      li.addEventListener("click", () => _scrollToIdx(i));
      popupList.appendChild(li);
      item.popupItem = li;
    });

    activeIdx = -1;
    _updateActive();
  }

  // ── Active bar tracking ─────────────────────────────────────────────────

  function _updateActive() {
    if (!items.length) return;
    const threshold = messages.getBoundingClientRect().top + 30;
    let idx = Math.max(0, Math.min(activeIdx, items.length - 1));

    const itemTop = (i) => items[i].el.getBoundingClientRect().top;
    for (let i = 0; i < items.length; i++) {
      if (!items[i].el || !items[i].el.isConnected || !items[i].bar) {
        _scheduleRebuild();
        return;
      }
    }

    // Start at the previous index and only walk as far as this frame moved.
    // This keeps scroll tracking cheap while still handling large scrollbar
    // jumps in either direction.
    while (idx + 1 < items.length && itemTop(idx + 1) <= threshold) idx++;
    while (idx > 0 && itemTop(idx) > threshold) idx--;

    if (idx !== activeIdx) {
      activeIdx = idx;
      items.forEach((item, i) => {
        item.bar.classList.toggle("active", i === idx);
      });
    }

    // Interpolate between the current and next message landmarks. The active
    // class remains useful for context, while the indicator provides the
    // smooth, exact motion users expect from a progress control.
    if (indicator && items[idx].bar) {
      const currentTop = itemTop(idx);
      let indicatorTop = items[idx].bar.offsetTop;
      if (idx + 1 < items.length && items[idx + 1].bar) {
        const nextTop = itemTop(idx + 1);
        const distance = nextTop - currentTop;
        const fraction = distance > 0
          ? Math.max(0, Math.min(1, (threshold - currentTop) / distance))
          : 0;
        const currentBarTop = items[idx].bar.offsetTop;
        const nextBarTop = items[idx + 1].bar.offsetTop;
        indicatorTop = currentBarTop + (nextBarTop - currentBarTop) * fraction;
      }
      indicatorOffsetTop = indicatorTop;
      indicator.style.transform = `translate3d(0, ${indicatorTop}px, 0)`;
      indicator.classList.add("is-visible");
    }
  }

  function _onScroll() {
    if (scrollFrame !== null) return;
    scrollFrame = requestAnimationFrame(() => {
      scrollFrame = null;
      _updateActive();
    });
  }

  // ── Popup interaction ───────────────────────────────────────────────────

  // Return horizontal stretch on a cosine arc: longest at the pointer, then
  // progressively shorter with a soft tangent at both edges. This creates the
  // lens/zoom-ring silhouette without a visible step where magnification ends.
  function _magnificationAt(distance) {
    const normalized = Math.min(Math.abs(distance) / MAGNIFY_RADIUS, 1);
    const influence = (Math.cos(normalized * Math.PI) + 1) / 2;
    return 1 + MAX_MAGNIFY * influence;
  }

  function _applyMagnification(clientY) {
    if (!track || !items.length) return;
    const trackRect = track.getBoundingClientRect();
    track.classList.add("is-magnified");

    items.forEach((item) => {
      if (!item.bar) return;
      const center = trackRect.top + item.bar.offsetTop + item.bar.offsetHeight / 2;
      const scaleX = _magnificationAt(clientY - center);
      const influence = (scaleX - 1) / MAX_MAGNIFY;
      item.bar.style.setProperty("--chat-nav-scale-x", scaleX.toFixed(3));
      item.bar.style.setProperty("--chat-nav-scale-y", (1 + influence * 0.12).toFixed(3));
      item.bar.style.setProperty("--chat-nav-opacity", (0.52 + influence * 0.22).toFixed(3));
    });

    if (indicator) {
      const center = trackRect.top + indicatorOffsetTop + indicator.offsetHeight / 2;
      indicator.style.setProperty(
        "--chat-nav-indicator-scale",
        _magnificationAt(clientY - center).toFixed(3)
      );
    }
  }

  function _magnifyAroundIndex(idx) {
    const bar = items[idx] && items[idx].bar;
    if (!bar || !track) return;
    const trackRect = track.getBoundingClientRect();
    _applyMagnification(trackRect.top + bar.offsetTop + bar.offsetHeight / 2);
  }

  function _resetMagnification() {
    if (track) track.classList.remove("is-magnified");
    items.forEach((item) => {
      if (!item.bar) return;
      item.bar.style.removeProperty("--chat-nav-scale-x");
      item.bar.style.removeProperty("--chat-nav-scale-y");
      item.bar.style.removeProperty("--chat-nav-opacity");
    });
    if (indicator) indicator.style.removeProperty("--chat-nav-indicator-scale");
  }

  function _onBarHover(idx) {
    clearTimeout(hideTimer);
    clearTimeout(showTimer);
    _magnifyAroundIndex(idx);
    if (popup && popup.style.display !== "none") {
      _showPopup(idx);
    } else {
      showTimer = setTimeout(() => _showPopup(idx), 260);
    }
  }

  function _onItemHover(idx) {
    clearTimeout(hideTimer);
    hoveredIdx = idx;
    _magnifyAroundIndex(idx);
    items.forEach((item, i) => {
      item.bar.classList.toggle("hovered", i === idx);
    });
  }

  function _showPopup(idx) {
    if (!popup || !items[idx] || !items[idx].bar) return;
    hoveredIdx = idx;
    popup.style.display = "flex";

    items.forEach((item, i) => {
      item.popupItem.classList.toggle("highlighted", i === idx);
      item.bar.classList.toggle("hovered", i === idx);
    });

    // Position popup vertically centered on the hovered bar
    const bar = items[idx].bar;
    const navRect = nav.getBoundingClientRect();
    const trackRect = track.getBoundingClientRect();
    const barCenter = trackRect.top + bar.offsetTop + bar.offsetHeight / 2 - navRect.top;
    popup.style.top = "";
    popup.style.bottom = "";
    const popupHeight = popup.offsetHeight;
    let top = barCenter - popupHeight / 2;
    top = Math.max(0, Math.min(top, navRect.height - popupHeight));
    popup.style.top = top + "px";

    const target = items[idx].popupItem;
    if (target) {
      const listRect = popupList.getBoundingClientRect();
      const itemRect = target.getBoundingClientRect();
      const offset =
        itemRect.top - listRect.top - (listRect.height - itemRect.height) / 2;
      popupList.scrollTop += offset;
    }
  }

  function _hidePopup() {
    clearTimeout(showTimer);
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (!popup) return;
      popup.style.display = "none";
      hoveredIdx = -1;
      items.forEach((item) => {
        item.bar.classList.remove("hovered");
        item.popupItem.classList.remove("highlighted");
      });
    }, 200);
  }

  // ── Scroll to message ───────────────────────────────────────────────────

  function _scrollToIdx(idx) {
    if (!items[idx] || !items[idx].el) return;
    const el = items[idx].el;
    const msgRect = messages.getBoundingClientRect();
    const elRect = el.getBoundingClientRect();
    const offset = elRect.top - msgRect.top;
    const reduceMotion = window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    messages.scrollTo({
      top: messages.scrollTop + offset - 12,
      behavior: reduceMotion ? "auto" : "smooth",
    });
    _hidePopup();
  }

  // ── Init ────────────────────────────────────────────────────────────────

  function init() {
    messages = $("messages");
    chatMain = $("chat-main");
    if (!messages || !chatMain) return;

    nav = document.createElement("div");
    nav.className = "chat-navigator";
    nav.style.display = "none";
    nav.innerHTML =
      '<div class="chat-nav-track"></div>' +
      '<div class="chat-nav-popup" style="display:none">' +
      '<div class="chat-nav-popup-header">' +
      '<span class="chat-nav-popup-title"></span>' +
      "</div>" +
      '<div class="chat-nav-popup-list"></div>' +
      "</div>";
    chatMain.appendChild(nav);
    track = nav.querySelector(".chat-nav-track");
    popup = nav.querySelector(".chat-nav-popup");
    popupList = nav.querySelector(".chat-nav-popup-list");

    const titleEl = nav.querySelector(".chat-nav-popup-title");
    if (titleEl) titleEl.textContent = I18n.t("chat.nav.title") || "Messages";

    // Hover open / leave close
    nav.addEventListener("mouseenter", () => clearTimeout(hideTimer));
    nav.addEventListener("mouseleave", () => {
      _resetMagnification();
      _hidePopup();
    });
    track.addEventListener("pointermove", (event) => {
      if (!event.pointerType || event.pointerType === "mouse" || event.pointerType === "pen") {
        _applyMagnification(event.clientY);
      }
    });

    // Observe message children changes (add / remove / clear)
    mo = new MutationObserver(() => _scheduleRebuild());
    mo.observe(messages, { childList: true });

    // Sync navigator bounds when layout changes
    ro = new ResizeObserver(() => {
      _syncBounds();
      _scheduleRebuild();
    });
    ro.observe(chatMain);
    ro.observe(messages);

    // Track scroll position for active bar
    messages.addEventListener("scroll", _onScroll, { passive: true });

    // Re-render title on language change
    document.addEventListener("langchange", () => {
      const t = nav.querySelector(".chat-nav-popup-title");
      if (t) t.textContent = I18n.t("chat.nav.title") || "Messages";
    });

    _syncBounds();
    _scheduleRebuild();
  }

  window.ChatNavigator = { init };
})();
