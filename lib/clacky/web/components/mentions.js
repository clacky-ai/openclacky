// ── MentionAC — @ mention autocomplete for file/directory/session references ─
// Cursor-style inline menu above the composer. Two top-level kinds:
//   - Files & Folders → directory drill-down (pick a file or a whole directory)
//   - Past Chats     → session list (pick a conversation to reference)
// Selection removes the typed "@" and inserts a chip via Composer.insertChip;
// send-time extraction is handled by the caller (sessions.js / new-session view).
//
// Multi-composer: attach() wires a second composer (new-session page) exactly
// like SkillAC.attach(). The caller supplies element ids and data resolvers.
//
// IMPORTANT ordering: attach() must run BEFORE Composer.init() and SkillAC so
// its keydown consumes @ / menu navigation first (it uses stopImmediatePropagation
// to keep Enter from being treated as "send").
//
// Depends on: Composer, global $ / I18n (optional). Loaded after ext.js.
// ─────────────────────────────────────────────────────────────────────────
"use strict";

const MentionAC = (() => {
  let _cfg = null;
  let _visible = false;
  let _mode = "root"; // "root" | "files" | "chats"
  let _items = [];
  let _activeIndex = -1;
  let _relPath = "";  // relative path under working dir (files mode)
  let _atNode = null; // DOM node holding the "@" while the menu is open
  let _keyboardNav = false; // suppress mouse hover while navigating with arrows
  let _mouseBound = false;
  let _chatsCursor = null; // `before` cursor for Past Chats pagination
  let _chatsHasMore = false;
  let _chatsLoading = false;
  let _chatsReq = 0;      // request token to ignore stale fetches

  const _menuEl  = () => (_cfg ? document.getElementById(_cfg.menu) : null);
  const _inputEl = () => (_cfg ? document.getElementById(_cfg.input) : null);

  function _label(zh, en) {
    return (typeof I18n !== "undefined" && I18n.lang && I18n.lang() === "zh") ? zh : en;
  }

  // ── data ───────────────────────────────────────────────────────────────

  // List one directory level. Chat sessions use the session-scoped endpoint
  // (relative paths); the new-session page uses /api/dirs (absolute paths).
  async function _fetchFiles() {
    const sid = _cfg.getSessionId ? _cfg.getSessionId() : null;
    const wd  = ((_cfg.getWorkingDir ? _cfg.getWorkingDir() : "") || "").replace(/\/+$/, "");
    if (sid) {
      const url = `/api/sessions/${encodeURIComponent(sid)}/files?path=${encodeURIComponent(_relPath || "")}`;
      const res = await fetch(url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      return (data.entries || []).map((e) => ({
        name: e.name, type: e.type, size: e.size,
        absPath: wd + "/" + (e.path || "").replace(/^\/+|\/+$/g, ""),
      }));
    }
    const url = `/api/dirs?path=${encodeURIComponent(wd + "/" + (_relPath || ""))}&files=true`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    return (data.entries || []).map((e) => ({
      name: e.name, type: e.type, size: e.size, absPath: e.path,
    }));
  }

  async function _fetchSessions(before) {
    // Cron/scheduled-task sessions are noise here — exclude them from references.
    const params = new URLSearchParams({ limit: "20", exclude_type: "cron" });
    if (before) params.set("before", before);
    const url = `/api/sessions?${params}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json(); // { sessions, has_more }
  }

  // ── render helpers ─────────────────────────────────────────────────────

  function _el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  // Lucide-style icons (24×24 stroke), matching the inline SVGs used across
  // the rest of the UI (feather/lucide stroke="currentColor" 2px round caps).
  const ICONS = {
    folder:       "M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z",
    file:         ["M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z", "M14 2v4a2 2 0 0 0 2 2h4"],
    message:      "M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z",
    chevronRight: "m9 18 6-6-6-6",
    chevronLeft:  "m15 18-6-6 6-6",
  };

  function _svg(paths, size) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("width", size || 16);
    svg.setAttribute("height", size || 16);
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "2");
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("aria-hidden", "true");
    (Array.isArray(paths) ? paths : [paths]).forEach((d) => {
      const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
      p.setAttribute("d", d);
      svg.appendChild(p);
    });
    return svg;
  }

  // HTML-string variant of _svg for innerHTML-rendered badges (message bubbles).
  function svgHtml(paths, size) {
    const sz = size || 16;
    const ds = (Array.isArray(paths) ? paths : [paths]).map((d) => `<path d="${d}"/>`).join("");
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${sz}" height="${sz}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ds}</svg>`;
  }

  function _ico(className, iconPaths) {
    const span = _el("span", className, "");
    span.appendChild(_svg(iconPaths, 16));
    return span;
  }

  function _header(menu, backLabel, title) {
    const bar = _el("div", "mention-header");
    if (backLabel) {
      const back = _el("button", "mention-back", "");
      back.type = "button";
      back.appendChild(_svg(ICONS.chevronLeft, 16));
      back.appendChild(_el("span", "mention-back-label", backLabel));
      back.addEventListener("mousedown", (e) => e.preventDefault());
      back.addEventListener("click", () => _goBack());
      bar.appendChild(back);
    }
    bar.appendChild(_el("span", "mention-title", title));
    menu.appendChild(bar);
  }

  // Scroll an item into the menu's own list container (never the page).
  // Uses offsetTop (relative to the .mention-list, which is position:relative)
  // so it is immune to page scroll and viewport coordinates.
  function _scrollTo(node) {
    const list = node.closest(".mention-list");
    if (!list) return;
    const top = node.offsetTop;
    const bottom = top + node.offsetHeight;
    const viewTop = list.scrollTop;
    const viewBottom = list.scrollTop + list.clientHeight;
    if (top < viewTop) list.scrollTop = top;
    else if (bottom > viewBottom) list.scrollTop = bottom - list.clientHeight;
  }

  function _setActive(idx) {
    _activeIndex = idx;
    const menu = _menuEl();
    if (!menu) return;
    menu.querySelectorAll(".mention-item").forEach((n, i) => {
      n.classList.toggle("active", i === idx);
      if (i === idx) _scrollTo(n);
    });
    // Past Chats: the trailing "load more" button is also keyboard-reachable.
    const more = menu.querySelector(".mention-load-more");
    if (more) {
      const isActive = _mode === "chats" && idx === _items.length;
      more.classList.toggle("active", isActive);
      if (isActive) _scrollTo(more);
    }
  }

  // Mouse hover sets the active item only when the user isn't navigating with
  // the arrow keys (list scrolling can fire spurious mouseenter events).
  function _hover(idx) {
    if (!_keyboardNav) _setActive(idx);
  }

  function _renderRoot() {
    const menu = _menuEl();
    menu.innerHTML = "";
    _items = [{ kind: "files" }, { kind: "chats" }];

    const files = _el("div", "mention-item", "");
    files.appendChild(_ico("mention-ico", ICONS.folder));
    files.appendChild(_el("span", "mention-name", _label("文件和文件夹", "Files & Folders")));
    files.addEventListener("mousedown", (e) => e.preventDefault());
    files.addEventListener("mouseenter", () => _hover(0));
    files.addEventListener("click", () => _enter("files"));
    menu.appendChild(files);

    const chats = _el("div", "mention-item", "");
    chats.appendChild(_ico("mention-ico", ICONS.message));
    chats.appendChild(_el("span", "mention-name", _label("历史会话", "Past Chats")));
    chats.addEventListener("mousedown", (e) => e.preventDefault());
    chats.addEventListener("mouseenter", () => _hover(1));
    chats.addEventListener("click", () => _enter("chats"));
    menu.appendChild(chats);

    _setActive(0);
  }

  function _renderFiles() {
    const menu = _menuEl();
    menu.innerHTML = "";
    _header(menu, _label("返回", "Back"), _relPath || _label("工作目录", "Workspace"));
    const listWrap = _el("div", "mention-list", "");
    menu.appendChild(listWrap);

    _fetchFiles().then((entries) => {
      if (_mode !== "files") return; // user navigated away mid-fetch
      _items = entries;
      if (entries.length === 0) {
        listWrap.appendChild(_el("div", "mention-empty", _label("空目录", "Empty directory")));
        _activeIndex = -1;
        return;
      }
      entries.forEach((entry, idx) => {
        const isDir = entry.type === "dir";
        const item = _el("div", "mention-item", "");

        const main = _el("span", "mention-item-main", "");
        main.appendChild(_ico("mention-ico", isDir ? ICONS.folder : ICONS.file));
        main.appendChild(_el("span", "mention-name", entry.name));
        if (!isDir && entry.size != null) {
          main.appendChild(_el("span", "mention-size", _fmtSize(entry.size)));
        }
        main.addEventListener("mousedown", (e) => e.preventDefault());
        main.addEventListener("click", () => _pickEntry(entry, isDir));
        item.appendChild(main);

        if (isDir) {
          const chevron = _ico("mention-chevron", ICONS.chevronRight);
          chevron.addEventListener("mousedown", (e) => e.preventDefault());
          chevron.addEventListener("click", () => _drillInto(entry));
          item.appendChild(chevron);
        }
        item.addEventListener("mouseenter", () => _hover(idx));
        listWrap.appendChild(item);
      });
      _setActive(0);
    }).catch((err) => {
      if (_mode !== "files") return;
      listWrap.appendChild(_el("div", "mention-empty", String(err.message || err)));
      _activeIndex = -1;
    });
  }

  function _renderChats() {
    const menu = _menuEl();
    menu.innerHTML = "";
    _header(menu, _label("返回", "Back"), _label("历史会话", "Past Chats"));
    const listWrap = _el("div", "mention-list", "");
    menu.appendChild(listWrap);
    _chatsCursor = null;
    _chatsHasMore = false;
    _items = [];
    _chatsLoading = false;
    _loadChats(listWrap, true);
  }

  function _renderChatItems(listWrap, resetActive) {
    listWrap.innerHTML = "";
    if (_items.length === 0) {
      listWrap.appendChild(_el("div", "mention-empty", _label("无会话", "No chats")));
      _activeIndex = -1;
      return;
    }
    _items.forEach((s, idx) => {
      const item = _el("div", "mention-item", "");
      item.appendChild(_ico("mention-ico", ICONS.message));
      item.appendChild(_el("span", "mention-name", s.name));
      item.addEventListener("mousedown", (e) => e.preventDefault());
      item.addEventListener("mouseenter", () => _hover(idx));
      item.addEventListener("click", () => _pickSession(s));
      listWrap.appendChild(item);
    });
    if (_chatsHasMore) {
      const more = _el("button", "mention-load-more", _label("加载更多", "Load more"));
      more.type = "button";
      more.addEventListener("mousedown", (e) => e.preventDefault());
      more.addEventListener("click", () => _loadChats(listWrap, false));
      listWrap.appendChild(more);
    }
    _setActive(resetActive ? 0 : Math.max(_activeIndex, 0));
  }

  async function _loadChats(listWrap, reset) {
    if (_chatsLoading) return;
    _chatsLoading = true;
    const req = ++_chatsReq;
    if (reset) {
      listWrap.innerHTML = "";
      listWrap.appendChild(_el("div", "mention-empty", _label("加载中…", "Loading…")));
    } else {
      const more = listWrap.querySelector(".mention-load-more");
      if (more) { more.textContent = _label("加载中…", "Loading…"); more.disabled = true; }
    }
    try {
      const data = await _fetchSessions(_chatsCursor);
      if (_mode !== "chats" || req !== _chatsReq) return;
      const sessions = data.sessions || [];
      _chatsHasMore = !!data.has_more;
      _items = _items.concat(sessions.map((s) => ({ kind: "session", id: s.id, name: s.name || s.id })));
      if (sessions.length) {
        // Cursor must come from a non-pinned session: pinned sessions sit at
        // the top regardless of age, so an old pinned row would otherwise push
        // the cursor too far back and leave the next page empty.
        const oldest = sessions.reduce((min, s) => {
          if (s.pinned) return min;
          const t = s.updated_at || s.created_at;
          if (!t) return min;
          return (!min || t < min) ? t : min;
        }, null);
        if (oldest) _chatsCursor = oldest;
      }
      _renderChatItems(listWrap, reset);
    } catch (err) {
      if (_mode !== "chats" || req !== _chatsReq) return;
      listWrap.innerHTML = "";
      listWrap.appendChild(_el("div", "mention-empty", String(err.message || err)));
      _activeIndex = -1;
    } finally {
      if (req === _chatsReq) _chatsLoading = false;
    }
  }

  function _fmtSize(bytes) {
    if (bytes == null || isNaN(bytes)) return "";
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
    return (bytes / (1024 * 1024)).toFixed(1) + " MB";
  }

  // ── actions ────────────────────────────────────────────────────────────

  function _enter(mode) {
    _mode = mode;
    _relPath = "";
    _activeIndex = -1;
    if (mode === "files") _renderFiles();
    else if (mode === "chats") _renderChats();
  }

  function _goBack() {
    if (_mode === "files") {
      if (_relPath) {
        _relPath = _relPath.includes("/") ? _relPath.slice(0, _relPath.lastIndexOf("/")) : "";
        _renderFiles();
      } else {
        _mode = "root";
        _renderRoot();
      }
    } else {
      _mode = "root";
      _renderRoot();
    }
  }

  function _drillInto(entry) {
    _relPath = _relPath ? _relPath + "/" + entry.name : entry.name;
    _activeIndex = -1;
    _renderFiles();
  }

  function _pickEntry(entry, isDir) {
    _insert({ type: isDir ? "directory" : "file", name: entry.name, path: entry.absPath });
  }

  function _pickSession(s) {
    _insert({ type: "session", name: s.name, sessionId: s.id });
  }

  function _insert(chip) {
    const el = _inputEl();
    if (!el) return;
    _clearAtMarker();
    hide();
    if (_cfg.onChip) _cfg.onChip(chip);
    else Composer.insertChip(el, chip);
  }

  // Insert a literal "@" (as a tracked marker) at the caret and open the menu
  // right after it. While the menu is open the "@" is visible in the composer;
  // picking an item removes it (see _clearAtMarker).
  function _insertAtMarker() {
    const el = _inputEl();
    if (!el) return;
    const sel = window.getSelection();
    if (!sel || !sel.rangeCount) return;
    const range = sel.getRangeAt(0);
    range.deleteContents();
    const marker = document.createElement("span");
    marker.className = "mention-at-marker";
    marker.textContent = "@";
    range.insertNode(marker);
    const after = document.createRange();
    after.setStartAfter(marker);
    after.collapse(true);
    sel.removeAllRanges();
    sel.addRange(after);
    _atNode = marker;
    el.dispatchEvent(new Event("input", { bubbles: true }));
  }

  // Promote an "@" already committed by the browser into the tracked marker.
  // Windows IMEs may suppress the printable keydown (or expose it as Process),
  // so the input/composition events are the only reliable character boundary.
  function _adoptCommittedAtMarker() {
    const el = _inputEl();
    const sel = window.getSelection();
    if (!el || !sel || !sel.rangeCount || !sel.isCollapsed) return false;

    const caret = sel.getRangeAt(0);
    if (!el.contains(caret.startContainer)) return false;

    let node = caret.startContainer;
    let offset = caret.startOffset;
    if (node.nodeType !== 3) {
      if (node.nodeType !== 1 || offset === 0) return false;
      node = node.childNodes[offset - 1];
      while (node && node.lastChild) node = node.lastChild;
      if (!node || node.nodeType !== 3) return false;
      offset = node.nodeValue.length;
    }
    if (offset === 0 || node.nodeValue[offset - 1] !== "@") return false;

    const at = document.createRange();
    at.setStart(node, offset - 1);
    at.setEnd(node, offset);
    at.deleteContents();

    const marker = document.createElement("span");
    marker.className = "mention-at-marker";
    marker.textContent = "@";
    at.insertNode(marker);

    const after = document.createRange();
    after.setStartAfter(marker);
    after.collapse(true);
    sel.removeAllRanges();
    sel.addRange(after);
    _atNode = marker;
    return true;
  }

  // Cancel path: turn the tracked "@" marker back into plain text so the user
  // keeps the character they typed.
  function _unwrapAtMarker() {
    if (!_atNode) return;
    const el = _inputEl();
    if (el && el.contains(_atNode)) {
      const text = document.createTextNode("@");
      _atNode.parentNode.replaceChild(text, _atNode);
      const sel = window.getSelection();
      const r = document.createRange();
      r.setStartAfter(text);
      r.collapse(true);
      sel.removeAllRanges();
      sel.addRange(r);
    }
    _atNode = null;
  }

  // Selection path: remove the "@" (and any filter text typed after it) before
  // the chip is inserted, leaving the caret where the "@" was.
  function _clearAtMarker() {
    const el = _inputEl();
    if (!_atNode || !el || !el.contains(_atNode)) { _atNode = null; return; }
    const sel = window.getSelection();
    const tail = document.createRange();
    tail.setStartAfter(_atNode);
    if (sel && sel.rangeCount) {
      const caret = sel.getRangeAt(0);
      tail.setEnd(caret.endContainer, caret.endOffset);
    } else {
      tail.collapse(true);
    }
    tail.deleteContents();
    const before = document.createRange();
    before.setStartBefore(_atNode);
    before.collapse(true);
    _atNode.remove();
    _atNode = null;
    sel.removeAllRanges();
    sel.addRange(before);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  }

  // ── keyboard ───────────────────────────────────────────────────────────

  function _handleKey(e) {
    if (!_visible) return false;
    // Past Chats appends a trailing "load more" button after the last item.
    const lastIdx = _items.length + ((_mode === "chats" && _chatsHasMore) ? 1 : 0) - 1;
    if (e.key === "ArrowDown") { e.preventDefault(); _keyboardNav = true; _setActive(Math.min(_activeIndex + 1, lastIdx)); return true; }
    if (e.key === "ArrowUp")   { e.preventDefault(); _keyboardNav = true; _setActive(Math.max(_activeIndex - 1, 0)); return true; }
    if (e.key === "Escape")    { e.preventDefault(); hide(); return true; }
    if (e.key === "Backspace" && _mode !== "root") { e.preventDefault(); _goBack(); return true; }
    if (e.key === "Enter" || e.key === "Tab") {
      e.preventDefault();
      if (_mode === "root") {
        if (_activeIndex === 0) _enter("files");
        else if (_activeIndex === 1) _enter("chats");
        return true;
      }
      if (_mode === "chats" && _chatsHasMore && _activeIndex === _items.length) {
        const menu = _menuEl();
        const listWrap = menu ? menu.querySelector(".mention-list") : null;
        if (listWrap) _loadChats(listWrap, false);
        return true;
      }
      const item = _items[_activeIndex];
      if (!item) return true;
      if (_mode === "files") {
        if (item.type === "dir") _drillInto(item);
        else _pickEntry(item, false);
      } else if (_mode === "chats") {
        _pickSession(item);
      }
      return true;
    }
    return false;
  }

  // ── show / hide ────────────────────────────────────────────────────────

  function _createOverlay() {
    _removeOverlay();
    const overlay = document.createElement("div");
    overlay.id = "mention-overlay";
    overlay.style.cssText = "position: fixed; inset: 0; z-index: 998; background: transparent;";
    overlay.addEventListener("click", hide);
    document.body.appendChild(overlay);
  }

  function _removeOverlay() {
    const overlay = document.getElementById("mention-overlay");
    if (overlay) overlay.remove();
  }

  function open(mode) {
    _mode = mode || "root";
    _relPath = "";
    _activeIndex = -1;
    const menu = _menuEl();
    if (menu) menu.style.display = "";
    if (_mode === "root") _renderRoot();
    else if (_mode === "files") _renderFiles();
    else if (_mode === "chats") _renderChats();
    _visible = true;
    _createOverlay();
  }

  function hide() {
    _visible = false;
    _mode = "root";
    _items = [];
    _activeIndex = -1;
    _relPath = "";
    const menu = _menuEl();
    if (menu) menu.style.display = "none";
    _unwrapAtMarker();
    _removeOverlay();
  }

  function _toggle() {
    if (_visible) hide();
    else open("root");
  }

  // ── attach ─────────────────────────────────────────────────────────────

  function attach(cfg) {
    const el = document.getElementById(cfg.input);
    if (!el) return;
    _cfg = cfg;

    // Reset keyboard-nav mode on the next real mouse movement so hover takes
    // over again (bound once globally; attach runs for two composers).
    if (!_mouseBound) {
      _mouseBound = true;
      document.addEventListener("mousemove", () => { _keyboardNav = false; });
    }

    // @ inserts the literal character into the composer (as a tracked marker)
    // and opens the menu; picking an item removes it. Menu navigation keys are
    // consumed here and stopImmediatePropagation keeps Composer/SkillAC from
    // double-handling. `_cfg = cfg` re-points the shared context to this
    // composer on every event so the chat + new-session composers can coexist
    // (same pattern as SkillAC).
    el.addEventListener("keydown", (e) => {
      _cfg = cfg;
      if (e.key === "@" && !e.isComposing && !e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault();
        e.stopImmediatePropagation();
        if (_visible) hide();
        else { _insertAtMarker(); open("root"); }
        return;
      }
      if (_visible && _handleKey(e)) {
        e.stopImmediatePropagation();
        return;
      }
      // Any other printable character typed while the menu is open closes it:
      // the "@" stays as plain text and the character is inserted normally.
      if (_visible && e.key.length === 1 && !e.isComposing && !e.ctrlKey && !e.metaKey && !e.altKey) {
        hide();
      }
    });

    // Keydown is not reliable while a Windows IME is active. Once the browser
    // commits a literal "@", adopt it into the existing marker state machine.
    // Composing input waits for compositionend so we never rewrite active IME
    // text; non-composing input can be handled immediately.
    el.addEventListener("input", (e) => {
      _cfg = cfg;
      if (!_visible && !e.isComposing && e.data === "@" && _adoptCommittedAtMarker()) {
        open("root");
        return;
      }
      if (_visible && _atNode && !el.contains(_atNode)) {
        _atNode = null;
        hide();
      }
    });

    el.addEventListener("compositionend", (e) => {
      _cfg = cfg;
      if (!_visible && e.data === "@" && _adoptCommittedAtMarker()) open("root");
    });

    // Optional @ button removed — @ is opened via the keyboard only.

    return {
      open, hide, toggle: _toggle,
      get visible() { return _visible; },
    };
  }

  return {
    attach,
    open,
    hide,
    toggle: _toggle,
    svgHtml,
    icons: ICONS,
    get visible() { return _visible; },
  };
})();

Clacky.MentionAC = MentionAC;
