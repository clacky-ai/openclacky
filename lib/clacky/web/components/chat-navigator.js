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

  let nav, track, popup, popupList;
  let messages, chatMain;
  let items = [];          // [{ el, bar, popupItem, type, preview }]
  let activeIdx = -1;
  let mo, ro;
  let rebuildTimer = null;
  let scrollTimer = null;
  let hideTimer = null;
  let hoveredIdx = -1;

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
    const els = Array.from(messages.querySelectorAll(NAV_SELECTOR));
    items = els.map((el) => ({
      el,
      preview: _previewFor(el),
    }));

    // Hide navigator when content fits without scrolling
    const scrollable = messages.scrollHeight > messages.clientHeight + 40;
    nav.style.display = scrollable && items.length > 1 ? "" : "none";
    if (!scrollable || items.length <= 1) return;

    // Build bars
    track.innerHTML = "";
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
    let idx = 0;
    for (let i = 0; i < items.length; i++) {
      if (!items[i].el || !items[i].el.isConnected) {
        _scheduleRebuild();
        return;
      }
      const top = items[i].el.getBoundingClientRect().top;
      if (top <= threshold) idx = i;
      else break;
    }
    if (idx !== activeIdx) {
      activeIdx = idx;
      items.forEach((item, i) => {
        item.bar.classList.toggle("active", i === idx);
      });
    }
  }

  function _onScroll() {
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(_updateActive, 80);
  }

  // ── Popup interaction ───────────────────────────────────────────────────

  function _onBarHover(idx) {
    clearTimeout(hideTimer);
    _showPopup(idx);
  }

  function _onItemHover(idx) {
    clearTimeout(hideTimer);
    hoveredIdx = idx;
    items.forEach((item, i) => {
      item.bar.classList.toggle("hovered", i === idx);
    });
  }

  function _showPopup(idx) {
    if (!popup || !items.length) return;
    hoveredIdx = idx;
    popup.style.display = "flex";

    items.forEach((item, i) => {
      item.popupItem.classList.toggle("highlighted", i === idx);
      item.bar.classList.toggle("hovered", i === idx);
    });

    // Position popup vertically centered on the hovered bar
    const bar = items[idx].bar;
    const navRect = nav.getBoundingClientRect();
    const barRect = bar.getBoundingClientRect();
    const barCenter = barRect.top + barRect.height / 2 - navRect.top;
    popup.style.top = "";
    popup.style.bottom = "";
    const popupHeight = popup.offsetHeight;
    let top = barCenter - popupHeight / 2;
    top = Math.max(48, Math.min(top, navRect.height - popupHeight));
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
    messages.scrollTop += offset - 12;
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
    nav.addEventListener("mouseleave", _hidePopup);

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
