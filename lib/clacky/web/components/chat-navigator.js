// ── Chat Navigator — lightweight round index, independent of loaded DOM ──
"use strict";

(() => {
  const STEP = 32;
  const PADDING = 20;
  const PREVIEW_DELAY = 120;
  // Navigation IDs include source versions and are URL encoded in a GET query.
  // Keep each batch below WEBrick's request-target limit, then drain visible
  // rows serially through _renderTicks() after every response.
  const PREVIEW_BATCH_SIZE = 8;
  const PREVIEW_CACHE_SIZE = 80;
  const BOTTOM_TOLERANCE = 1;
  let nav, track, canvas, popup, answerPreview, messages, chatMain;
  let sessionId = null;
  let items = [];
  let loaded = [];
  let activeIdx = -1;
  let hoveredIdx = -1;
  let expanded = false;
  let hoveringMessage = false;
  let loading = false;
  let failed = false;
  let jumping = false;
  let controller;
  let generation = 0;
  let refreshTimer, syncTimer, hideTimer, scrollFrame;
  let pointerY = null;
  let previewTimer, previewRequest, previewQueueKey;
  const previewFailures = new Set();
  const previews = new Map();
  const renderedTicks = new Map();
  const previewText = new WeakMap();

  function _contentSpan() {
    return Math.max(0, (items.length - 1) * STEP);
  }

  function _baseOffset() {
    return Math.max(PADDING, (track.clientHeight - _contentSpan()) / 2);
  }

  function _tickY(index) {
    return _baseOffset() + index * STEP;
  }

  function _nearest(y) {
    if (!items.length) return -1;
    const index = Math.round((y + track.scrollTop - _baseOffset()) / STEP);
    return Math.max(0, Math.min(items.length - 1, index));
  }

  function _visibleBounds() {
    const first = Math.max(0, Math.floor((track.scrollTop - _baseOffset()) / STEP) - 2);
    const last = Math.min(items.length, first + Math.ceil(track.clientHeight / STEP) + 5);
    return { first, last };
  }

  function _intersectsViewport(index) {
    const y = _tickY(index) - track.scrollTop;
    return y + STEP / 2 > 0 && y - STEP / 2 < track.clientHeight;
  }

  function _visiblePreviewIds(first, last) {
    return items.slice(first, last)
      .map((item, offset) => ({ id: item.id, index: first + offset }))
      .filter(item => _intersectsViewport(item.index))
      .map(item => item.id);
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
    const expandedWidth = parseFloat(getComputedStyle(chatMain).getPropertyValue("--chat-nav-expanded-width")) || 368;
    popup.style.maxWidth = `${Math.max(0, rect.width - scrollbarSpace - expandedWidth - 12)}px`;
    _renderTicks();
  }

  function _renderTicks() {
    if (!track) return;
    const visible = items.length > 1 || loading || failed;
    nav.style.display = visible ? "" : "none";
    chatMain.classList.toggle("has-chat-navigator", visible);
    const contentHeight = _contentSpan() + PADDING * 2;
    canvas.style.height = `${Math.max(track.clientHeight, contentHeight)}px`;
    const compact = items.length > 0 && contentHeight <= track.clientHeight;
    const frameTop = compact ? Math.max(0, _baseOffset() - STEP / 2 - 8) : 0;
    const frameHeight = compact ? Math.min(track.clientHeight - frameTop, items.length * STEP + 16) : track.clientHeight;
    nav.style.setProperty("--chat-nav-frame-top", `${frameTop}px`);
    nav.style.setProperty("--chat-nav-frame-height", `${frameHeight}px`);
    // Only visible rows and a small buffer get DOM nodes.
    const { first, last } = _visibleBounds();
    for (const [index, tick] of renderedTicks) {
      if (index < first || index >= last) { tick.remove(); renderedTicks.delete(index); }
    }
    for (let i = first; i < last; i++) {
      let tick = renderedTicks.get(i);
      if (!tick) {
        tick = document.createElement("div");
        tick.className = "chat-nav-row";
        const user = document.createElement("span");
        user.className = "chat-nav-user";
        const bar = document.createElement("span");
        bar.className = "chat-nav-bar";
        tick.appendChild(user);
        tick.appendChild(bar);
        tick.id = `chat-nav-tick-${i}`;
        tick.setAttribute("role", "option");
        renderedTicks.set(i, tick);
        canvas.appendChild(tick);
      }
      const preview = previews.get(items[i].id);
      const previewFailed = previewFailures.has(items[i].id);
      tick.classList.toggle("active", i === activeIdx);
      tick.classList.toggle("hovered", i === hoveredIdx);
      tick.classList.toggle("loading", expanded && !preview && !previewFailed);
      tick.classList.toggle("failed", previewFailed);
      tick.style.top = `${_tickY(i)}px`;
      tick.setAttribute("aria-selected", String(i === hoveredIdx));
      tick.setAttribute("aria-label", preview?.user || I18n.t("chat.nav.round", { number: i + 1 }));
      if (expanded) {
        const user = preview
          ? preview.user || I18n.t("chat.nav.empty")
          : previewFailed ? I18n.t("chat.nav.retry") : "";
        _setPreview(tick.querySelector(".chat-nav-user"), user);
      }
    }
    if (hoveredIdx >= first && hoveredIdx < last) {
      track.setAttribute("aria-activedescendant", `chat-nav-tick-${hoveredIdx}`);
    }
    else track.removeAttribute("aria-activedescendant");
    _renderPreview();
    if (expanded && !loading && !failed) _queueVisiblePreviews(first, last);
  }

  function _setPreview(element, text) {
    if (previewText.get(element) === text) return;
    element.innerHTML = MarkdownPreview.render(text);
    previewText.set(element, text);
  }

  function _renderPreview() {
    if (!popup) return;
    if (!expanded || !hoveringMessage || hoveredIdx < 0) {
      popup.hidden = true;
      return;
    }
    popup.hidden = false;
    const item = items[hoveredIdx];
    const preview = item && previews.get(item.id);
    const previewFailed = item && previewFailures.has(item.id);
    const skeleton = !failed && !previewFailed && (jumping || (item ? !preview : loading));
    popup.classList.toggle("loading", skeleton);
    popup.setAttribute("aria-busy", String(skeleton));
    _setPreview(answerPreview, skeleton ? "" : failed || previewFailed ? I18n.t("chat.nav.retry") : preview?.assistant || I18n.t("chat.nav.noReply"));
    const center = item ? _tickY(hoveredIdx) - track.scrollTop : pointerY || 0;
    popup.style.top = `${Math.max(0, Math.min(center - popup.offsetHeight / 2, nav.clientHeight - popup.offsetHeight))}px`;
  }

  function _queueVisiblePreviews(first, last) {
    if (!expanded || previewRequest) return;
    const ids = _visiblePreviewIds(first, last)
      .filter(id => !previews.has(id) && !previewFailures.has(id))
      .slice(0, PREVIEW_BATCH_SIZE);
    const key = ids.join("\n");
    if (!ids.length) {
      clearTimeout(previewTimer);
      previewQueueKey = null;
      return;
    }
    if (previewQueueKey === key) return;

    clearTimeout(previewTimer);
    previewQueueKey = key;
    previewTimer = setTimeout(() => {
      previewQueueKey = null;
      _loadVisiblePreviews(ids);
    }, PREVIEW_DELAY);
  }

  async function _loadVisiblePreviews(ids) {
    ids = ids.filter(id => !previews.has(id));
    if (previewRequest || !ids.length) return;
    const request = { ids, generation, controller: new AbortController() };
    previewRequest = request;
    try {
      const params = new URLSearchParams({ previews: JSON.stringify(request.ids) });
      const res = await fetch(`/api/sessions/${sessionId}/messages?${params}`, { signal: request.controller.signal });
      if (res.status === 409 && request.generation === generation) refresh();
      if (!res.ok) throw new Error(`Previews: ${res.status}`);
      const data = await res.json();
      if (request.generation !== generation) return;
      for (const preview of data.previews || []) {
        previews.delete(preview.id);
        previews.set(preview.id, preview);
        previewFailures.delete(preview.id);
        while (previews.size > PREVIEW_CACHE_SIZE) previews.delete(previews.keys().next().value);
      }
    } catch (error) {
      if (error.name !== "AbortError" && request.generation === generation) {
        request.ids.forEach(id => previewFailures.add(id));
      }
    } finally {
      if (previewRequest === request) {
        previewRequest = null;
        _renderTicks();
      }
    }
  }

  function _cancelPreview() {
    clearTimeout(previewTimer);
    previewRequest?.controller.abort();
    previewRequest = null;
    previewQueueKey = null;
    previewFailures.clear();
  }

  function _expand() {
    clearTimeout(hideTimer);
    if (expanded) return;
    expanded = true;
    nav.classList.add("expanded");
    _renderTicks();
  }

  function _hover(y, showAnswer = false) {
    pointerY = y;
    clearTimeout(hideTimer);
    hoveredIdx = _nearest(y);
    hoveringMessage = showAnswer;
    _renderTicks();
  }

  function _hide() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      hoveredIdx = -1;
      pointerY = null;
      hoveringMessage = false;
      expanded = false;
      nav.classList.remove("expanded");
      popup.hidden = true;
      _cancelPreview();
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
    const id = sessionId;
    const element = loaded.find(entry => entry.index === hoveredIdx)?.el;
    if (element?.isConnected) {
      messages.scrollTop += element.getBoundingClientRect().top - messages.getBoundingClientRect().top - 12;
      return;
    }
    jumping = true;
    _renderPreview();
    const success = await Sessions.jumpToHistory(item.id);
    if (id !== sessionId) return;
    jumping = false;
    if (!success) {
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
    hoveringMessage = expanded = jumping = failed = false;
    nav?.classList.remove("expanded");
    if (popup) popup.hidden = true;
    _loadIndex();
  }

  function init() {
    messages = document.getElementById("messages");
    chatMain = document.getElementById("chat-main");
    if (!messages || !chatMain) return;
    nav = document.createElement("div");
    nav.className = "chat-navigator";
    nav.innerHTML = '<div class="chat-nav-frame" aria-hidden="true"></div>' +
      '<div class="chat-nav-viewport"><div class="chat-nav-track" tabindex="0" role="listbox"><div class="chat-nav-canvas"></div></div></div>' +
      '<div class="chat-nav-popup" hidden><span class="chat-nav-answer"></span></div>';
    chatMain.appendChild(nav);
    track = nav.querySelector(".chat-nav-track");
    canvas = nav.querySelector(".chat-nav-canvas");
    popup = nav.querySelector(".chat-nav-popup");
    answerPreview = nav.querySelector(".chat-nav-answer");
    track.setAttribute("aria-label", I18n.t("chat.nav.title"));
    track.addEventListener("pointerenter", event => {
      _expand();
      _hover(event.clientY - track.getBoundingClientRect().top, false);
    });
    track.addEventListener("pointermove", event => {
      const overMessage = !!event.target.closest?.(".chat-nav-user");
      _hover(event.clientY - track.getBoundingClientRect().top, overMessage);
    });
    track.addEventListener("click", _jump);
    track.addEventListener("wheel", event => {
      event.preventDefault();
      event.stopPropagation();
      const delta = event.deltaY * (event.deltaMode === 1 ? STEP : event.deltaMode === 2 ? track.clientHeight : 1);
      track.scrollTop += delta;
      const overMessage = !!event.target.closest?.(".chat-nav-user");
      _hover(event.clientY - track.getBoundingClientRect().top, overMessage);
    }, { passive: false });
    track.addEventListener("scroll", _renderTicks, { passive: true });
    track.addEventListener("keydown", event => {
      _expand();
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
