// ── Chat Navigator — lightweight round index, independent of loaded DOM ──
"use strict";

(() => {
  const STEP = 12;
  const PADDING = 20;
  const LENS_RADIUS = 3;
  const PREVIEW_DELAY = 120;
  const PREVIEW_CACHE_SIZE = 80;
  const BOTTOM_TOLERANCE = 1;
  let nav, track, canvas, popup, userPreview, answerPreview, messages, chatMain;
  let sessionId = null;
  let items = [];
  let loaded = [];
  let activeIdx = -1;
  let hoveredIdx = -1;
  let loading = false;
  let failed = false;
  let jumping = false;
  let controller;
  let generation = 0;
  let refreshTimer, syncTimer, hideTimer, scrollFrame;
  let pointerY = null;
  let previewTimer, previewRequest, previewTarget;
  let previewDue = false;
  let previewFailure = null;
  const previews = new Map();
  const renderedTicks = new Map();
  const previewText = new WeakMap();

  function _baseOffset() {
    return Math.max(PADDING, (track.clientHeight - items.length * STEP) / 2);
  }

  function _tickY(index) {
    return _baseOffset() + index * STEP;
  }

  function _nearest(y) {
    if (!items.length) return -1;
    const index = Math.round((y + track.scrollTop - _baseOffset()) / STEP);
    return Math.max(0, Math.min(items.length - 1, index));
  }

  function _syncBounds() {
    const rect = messages.getBoundingClientRect();
    const main = chatMain.getBoundingClientRect();
    const opener = document.getElementById("btn-aside-open");
    const openerStyle = opener && getComputedStyle(opener);
    // Reserve the opener's CSS geometry even when the expanded aside hides it.
    const openerBottom = opener
      ? opener.parentElement.getBoundingClientRect().top + parseFloat(openerStyle.top) + parseFloat(openerStyle.height)
      : rect.top;
    const top = Math.max(rect.top, openerBottom) + 12;
    const scrollbarWidth = messages.offsetWidth - messages.clientWidth;
    const scrollbarSpace = Math.max(scrollbarWidth,
      parseFloat(getComputedStyle(nav).getPropertyValue("--chat-nav-scrollbar-space")) || 12);
    // Classic scrollbars already consume layout width; reserve only the overlay remainder.
    chatMain.style.setProperty("--chat-nav-overlay-space", `${scrollbarSpace - scrollbarWidth}px`);
    nav.style.right = `${main.right - rect.right + scrollbarSpace}px`;
    nav.style.top = `${top - main.top}px`;
    nav.style.height = `${Math.max(0, rect.bottom - top - 16)}px`;
    popup.style.maxWidth = `${Math.max(0, rect.width - scrollbarSpace - parseFloat(getComputedStyle(nav).width) - 12)}px`;
    _renderTicks();
  }

  function _renderTicks() {
    if (!track) return;
    const visible = items.length > 1 || loading || failed;
    nav.style.display = visible ? "" : "none";
    chatMain.classList.toggle("has-chat-navigator", visible);
    canvas.style.height = `${Math.max(track.clientHeight, items.length * STEP + PADDING * 2)}px`;
    // Only visible ticks and a small buffer get DOM nodes.
    const first = Math.max(0, Math.floor((track.scrollTop - _baseOffset()) / STEP) - LENS_RADIUS - 2);
    const last = Math.min(items.length, first + Math.ceil(track.clientHeight / STEP) + LENS_RADIUS * 2 + 5);
    for (const [index, tick] of renderedTicks) {
      if (index < first || index >= last) { tick.remove(); renderedTicks.delete(index); }
    }
    for (let i = first; i < last; i++) {
      let tick = renderedTicks.get(i);
      if (!tick) {
        tick = document.createElement("div");
        tick.className = "chat-nav-bar";
        tick.id = `chat-nav-tick-${i}`;
        tick.setAttribute("role", "option");
        renderedTicks.set(i, tick);
        canvas.appendChild(tick);
      }
      const distance = hoveredIdx < 0 ? Infinity : Math.abs(i - hoveredIdx);
      tick.classList.toggle("active", i === activeIdx);
      tick.classList.toggle("hovered", i === hoveredIdx);
      tick.classList.toggle("nearby", distance > 0 && distance <= LENS_RADIUS);
      tick.style.top = `${_tickY(i)}px`;
      tick.style.width = `${distance <= LENS_RADIUS ? 30 - distance * 6 : 9}px`;
      tick.setAttribute("aria-selected", String(i === hoveredIdx));
      tick.setAttribute("aria-label", previews.get(items[i].id)?.user || I18n.t("chat.nav.round", { number: i + 1 }));
    }
    if (hoveredIdx >= first && hoveredIdx < last) track.setAttribute("aria-activedescendant", `chat-nav-tick-${hoveredIdx}`);
    else track.removeAttribute("aria-activedescendant");
    _renderPreview();
  }

  function _setPreview(element, text) {
    if (previewText.get(element) === text) return;
    element.innerHTML = MarkdownPreview.render(text);
    previewText.set(element, text);
  }

  function _renderPreview() {
    if (!popup || (hoveredIdx < 0 && pointerY === null)) return;
    popup.hidden = false;
    const item = items[hoveredIdx];
    const preview = item && previews.get(item.id);
    const previewFailed = item && previewFailure === item.id;
    const skeleton = !failed && !previewFailed && (jumping || (item ? !preview : loading));
    popup.classList.toggle("loading", skeleton);
    popup.setAttribute("aria-busy", String(skeleton));
    _setPreview(userPreview, skeleton ? "" : preview?.user || I18n.t(failed || previewFailed ? "chat.nav.retry" : "chat.nav.empty"));
    _setPreview(answerPreview, skeleton ? "" : failed || previewFailed ? I18n.t("chat.nav.retry") : preview?.assistant || I18n.t("chat.nav.noReply"));
    const center = item ? _tickY(hoveredIdx) - track.scrollTop : pointerY || 0;
    popup.style.top = `${Math.max(0, Math.min(center - popup.offsetHeight / 2, nav.clientHeight - popup.offsetHeight))}px`;
    if (!loading && !failed) _queuePreview(item);
  }

  function _queuePreview(item) {
    if (previewTarget === item?.id) return;
    clearTimeout(previewTimer);
    previewTarget = item?.id;
    previewDue = false;
    previewFailure = null;
    if (!item) return;
    if (previews.has(item.id)) {
      const cached = previews.get(item.id);
      previews.delete(item.id);
      previews.set(item.id, cached);
      return;
    }
    previewTimer = setTimeout(() => { previewDue = true; _loadPreview(); }, PREVIEW_DELAY);
  }

  async function _loadPreview() {
    if (!previewDue || previewRequest || !previewTarget || previews.has(previewTarget)) return;
    previewDue = false;
    const request = { id: previewTarget, generation, controller: new AbortController() };
    previewRequest = request;
    try {
      const params = new URLSearchParams({ preview: request.id });
      const res = await fetch(`/api/sessions/${sessionId}/messages?${params}`, { signal: request.controller.signal });
      if (res.status === 409 && request.generation === generation) refresh();
      if (!res.ok) throw new Error(`Preview: ${res.status}`);
      const data = await res.json();
      if (request.generation !== generation) return;
      previews.delete(request.id);
      previews.set(request.id, data);
      while (previews.size > PREVIEW_CACHE_SIZE) previews.delete(previews.keys().next().value);
    } catch (error) {
      if (error.name !== "AbortError" && request.generation === generation) previewFailure = request.id;
    } finally {
      if (previewRequest === request) {
        previewRequest = null;
        _renderTicks();
        // At most one request runs at a time; moving across many ticks retains
        // only the latest target, not a queue of every crossed message.
        _loadPreview();
      }
    }
  }

  function _cancelPreview() {
    clearTimeout(previewTimer);
    previewRequest?.controller.abort();
    previewRequest = null;
    previewTarget = null;
    previewDue = false;
    previewFailure = null;
  }

  function _hover(y) {
    pointerY = y;
    clearTimeout(hideTimer);
    hoveredIdx = _nearest(y);
    _renderTicks();
  }

  function _hide() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      hoveredIdx = -1;
      pointerY = null;
      clearTimeout(previewTimer);
      previewTarget = null;
      previewDue = false;
      popup.hidden = true;
      _renderTicks();
    }, 160);
  }

  function _reveal(index) {
    if (index < 0) return;
    const y = _tickY(index);
    if (y < track.scrollTop + PADDING || y > track.scrollTop + track.clientHeight - PADDING) {
      track.scrollTop = Math.max(0, y - track.clientHeight / 2);
    }
  }

  function _updateActive() {
    if (!loaded.length) return;
    const threshold = messages.getBoundingClientRect().top + 30;
    let found = loaded[0].index;
    for (const entry of loaded) {
      if (entry.el.getBoundingClientRect().top > threshold) break;
      found = entry.index;
    }
    const atBottom = messages.scrollHeight - messages.scrollTop - messages.clientHeight <= BOTTOM_TOLERANCE;
    if (atBottom && !Sessions.isHistoricalWindow()) found = loaded[loaded.length - 1].index;
    activeIdx = found;
    if (pointerY === null) _reveal(activeIdx);
    _renderTicks();
  }

  function syncMessages() {
    if (!messages || sessionId !== Sessions.activeId) return;
    const byId = new Map(items.map((item, index) => [item.id, index]));
    const liveByTime = new Map();
    items.forEach((item, index) => {
      if (!item.archived && item.created_at) liveByTime.set(String(item.created_at), index);
    });
    loaded = [];
    messages.querySelectorAll(".msg-user-wrap").forEach(el => {
      const bubble = el.querySelector(".msg-user");
      let index = byId.get(bubble?.dataset.roundId);
      // Only optimistic live bubbles need a timestamp fallback. Archived
      // targets always use source locators, never synthetic timestamps.
      if (index === undefined && bubble?.dataset.editable !== "false") index = liveByTime.get(bubble?.dataset.createdAt);
      if (index !== undefined) loaded.push({ index, el });
    });
    _updateActive();
  }

  async function _jump() {
    if (failed) { refresh(); return; }
    const item = items[hoveredIdx];
    if (!item || jumping) return;
    if (previewFailure === item.id) {
      previewTarget = null;
      _queuePreview(item);
      _renderPreview();
      return;
    }
    const id = sessionId;
    const element = loaded.find(entry => entry.index === hoveredIdx)?.el;
    if (element?.isConnected) {
      messages.scrollTop += element.getBoundingClientRect().top - messages.getBoundingClientRect().top - 12;
      _hide();
      return;
    }
    jumping = true;
    _renderPreview();
    const success = await Sessions.jumpToHistory(item.id);
    if (id !== sessionId) return;
    jumping = false;
    if (success) _hide();
    else {
      failed = true;
      _renderPreview();
      _setPreview(answerPreview, I18n.t("chat.history_load_failed"));
    }
  }

  async function _loadIndex() {
    if (!sessionId || !nav) return;
    controller?.abort();
    controller = new AbortController();
    const signal = controller.signal;
    const requestGeneration = ++generation;
    _cancelPreview();
    const id = sessionId;
    loading = true;
    failed = false;
    _renderTicks();
    try {
      const res = await fetch(`/api/sessions/${id}/messages?navigation=1`, { signal });
      if (!res.ok) throw new Error(`Navigation: ${res.status}`);
      const data = await res.json();
      if (requestGeneration !== generation || sessionId !== Sessions.activeId) return;
      const anchorId = items[hoveredIdx]?.id;
      const firstVisibleId = items[Math.max(0, Math.floor((track.scrollTop - _baseOffset()) / STEP))]?.id;
      const sources = new Map(data.sources.map(source => [source.key, source]));
      for (const key of previews.keys()) {
        const [source, , version] = JSON.parse(key);
        if (!sources.has(source) || sources.get(source).version !== version || sources.get(source).volatile) previews.delete(key);
      }
      items = data.sources.flatMap(source => Array.from({ length: source.count }, (_, offset) => {
        const identity = source.identities?.[offset] || null;
        return { id: JSON.stringify([source.key, offset, source.version, identity]),
          archived: !source.identities, created_at: identity?.[0] };
      }));
      hoveredIdx = anchorId ? items.findIndex(item => item.id === anchorId) : -1;
      _renderTicks();
      if (pointerY !== null && firstVisibleId) {
        const first = items.findIndex(item => item.id === firstVisibleId);
        if (first >= 0) track.scrollTop = Math.max(0, _baseOffset() + first * STEP);
      }
      syncMessages();
    } catch (error) {
      if (error.name !== "AbortError" && requestGeneration === generation) failed = true;
    } finally {
      if (requestGeneration === generation) {
        loading = false;
        if (pointerY !== null && hoveredIdx < 0) hoveredIdx = _nearest(pointerY);
        _renderTicks();
      }
    }
  }

  function refresh() {
    if (!sessionId) return;
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(_loadIndex, 350);
  }

  function setSession(id) {
    controller?.abort();
    clearTimeout(refreshTimer);
    clearTimeout(hideTimer);
    generation++;
    sessionId = id;
    items = [];
    loaded = [];
    previews.clear();
    _cancelPreview();
    activeIdx = hoveredIdx = -1;
    pointerY = null;
    jumping = failed = false;
    if (popup) popup.hidden = true;
    _loadIndex();
  }

  function init() {
    messages = document.getElementById("messages");
    chatMain = document.getElementById("chat-main");
    if (!messages || !chatMain) return;
    nav = document.createElement("div");
    nav.className = "chat-navigator";
    nav.innerHTML = '<div class="chat-nav-track" tabindex="0" role="listbox"><div class="chat-nav-canvas"></div></div>' +
      '<button type="button" class="chat-nav-popup" hidden><span class="chat-nav-user"></span><span class="chat-nav-answer"></span></button>';
    chatMain.appendChild(nav);
    track = nav.querySelector(".chat-nav-track");
    canvas = nav.querySelector(".chat-nav-canvas");
    popup = nav.querySelector(".chat-nav-popup");
    userPreview = nav.querySelector(".chat-nav-user");
    answerPreview = nav.querySelector(".chat-nav-answer");
    track.setAttribute("aria-label", I18n.t("chat.nav.title"));
    track.addEventListener("pointermove", event => _hover(event.clientY - track.getBoundingClientRect().top));
    track.addEventListener("click", _jump);
    track.addEventListener("wheel", event => {
      event.preventDefault();
      event.stopPropagation();
      const delta = event.deltaY * (event.deltaMode === 1 ? STEP : event.deltaMode === 2 ? track.clientHeight : 1);
      track.scrollTop += delta;
      _hover(event.clientY - track.getBoundingClientRect().top);
    }, { passive: false });
    track.addEventListener("scroll", _renderTicks, { passive: true });
    track.addEventListener("keydown", event => {
      let index = hoveredIdx >= 0 ? hoveredIdx : Math.max(activeIdx, 0);
      if (event.key === "ArrowUp") index--;
      else if (event.key === "ArrowDown") index++;
      else if (event.key === "Home") index = 0;
      else if (event.key === "End") index = items.length - 1;
      else if (event.key === "Enter" || event.key === " ") { event.preventDefault(); _jump(); return; }
      else if (event.key === "Escape") { _hide(); return; }
      else return;
      event.preventDefault();
      hoveredIdx = Math.max(0, Math.min(items.length - 1, index));
      _reveal(hoveredIdx);
      _renderTicks();
    });
    popup.addEventListener("click", _jump);
    nav.addEventListener("pointerenter", () => clearTimeout(hideTimer));
    nav.addEventListener("pointerleave", _hide);
    nav.addEventListener("focusout", event => { if (!nav.contains(event.relatedTarget)) _hide(); });
    new MutationObserver(() => {
      clearTimeout(syncTimer);
      syncTimer = setTimeout(syncMessages, 100);
    }).observe(messages, { childList: true });
    const observer = new ResizeObserver(_syncBounds);
    observer.observe(messages);
    observer.observe(chatMain);
    messages.addEventListener("scroll", () => {
      cancelAnimationFrame(scrollFrame);
      scrollFrame = requestAnimationFrame(_updateActive);
    }, { passive: true });
    document.addEventListener("langchange", () => {
      track.setAttribute("aria-label", I18n.t("chat.nav.title"));
      _renderPreview();
    });
    _syncBounds();
    if (Sessions.activeId) setSession(Sessions.activeId);
  }

  window.ChatNavigator = { init, setSession, refresh, syncMessages };
})();
