// ── quote-select.js — Quote-on-selection ────────────────────────────────────
//
// Drag-select text inside any user or assistant message bubble; a floating
// "Quote" pill appears above the selection. Clicking it appends the selected
// text to the composer as a markdown blockquote with a provenance line:
//
//   > [Assistant · #3]
//   > selected text…
//
// Pure frontend: the quote is plain text in the composer and rides the
// existing WS message pipeline unchanged (no backend/protocol changes).
//
// Event bindings are delegation-style on document, so they survive history
// lazy-loading and streaming DOM rebuilds. The button itself is a single
// recycled element, created lazily and hidden when any selection dies.

const QuoteSelect = (() => {
  let _btn = null;     // floating quote button (lazily created, recycled)
  let _snap = null;    // selection snapshot captured when the button appears
  let _pending = null; // mouseup validation timer

  // ── DOM helpers ──────────────────────────────────────────────────────────
  // Nearest message root: .msg-user-wrap (user) or .msg-assistant. Returns
  // null when the node is outside any quotable message (e.g. composer, modal).
  function _msgRoot(node) {
    if (!node || node.nodeType === Node.DOCUMENT_NODE) return null;
    const el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
    if (!el) return null;
    return el.closest(".msg-user-wrap, .msg-assistant");
  }

  // Message role + 1-based chat index, counted among quoted messages only
  // (user / assistant), so index stays consistent with rendered history.
  function _msgMeta(root) {
    const items = root.parentElement.querySelectorAll(
      ":scope > .msg-user-wrap, :scope > .msg-assistant"
    );
    return {
      role:  root.classList.contains("msg-user-wrap") ? "user" : "assistant",
      index: Array.prototype.indexOf.call(items, root) + 1,
    };
  }

  // ── Text cleaning ────────────────────────────────────────────────────────
  // Normalize raw selection text into quote lines: strip leading/trailing
  // blank lines, collapse consecutive blanks inside, keep each line's
  // trailing whitespace trimmed.
  function _cleanLines(raw) {
    const lines = String(raw || "").replace(/\r\n/g, "\n").split("\n");
    while (lines.length && !lines[0].trim()) lines.shift();
    while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
    const out = [];
    for (const line of lines) {
      if (!line.trim()) {
        if (!out.length || out[out.length - 1] !== "") out.push("");
      } else {
        out.push(line.replace(/\s+$/, ""));
      }
    }
    return out;
  }

  // Build the markdown blockquote inserted into the composer (方案 B).
  function _buildBlock(snap) {
    const roleWord = snap.role === "user"
      ? I18n.t("chat.quote.roleUser")
      : I18n.t("chat.quote.roleAssistant");
    const sig = I18n.t("chat.quote.sig", { role: roleWord, index: snap.index });
    const body = _cleanLines(snap.text).map(line => {
      if (!line) return ">";                 // keep paragraph gaps inside the quote
      return line.startsWith(">") ? line : "> " + line;
    });
    if (!body.length) return "";
    return "> [" + sig + "]\n" + body.join("\n");
  }

  // ── Button lifecycle ─────────────────────────────────────────────────────
  function _createBtn() {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "quote-select-btn";
    btn.disabled = false;
    btn.innerHTML =
      `<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 6H3"/><path d="M21 12H8"/><path d="M21 18H8"/><path d="M3 12v6"/></svg>` +
      `<span>${escapeHtml(I18n.t("chat.quote.btn"))}</span>`;
    // Keep the textarea focus / selection alive: a bare mousedown on a button
    // collapses the selection before click fires.
    btn.addEventListener("mousedown", e => e.preventDefault());
    btn.addEventListener("click", _onQuoteClick);
    document.body.appendChild(btn);
    return btn;
  }

  function _show(rect) {
    if (!_btn) _btn = _createBtn();
    const btnRect = _btn.getBoundingClientRect();
    let top = rect.top - btnRect.height - 10;   // 10px above the selection
    if (top < 8) top = rect.bottom + 10;        // flip below when clipped at top
    _btn.style.top = top + "px";
    // Horizontal center of the selection; CSS translateX(-50%) finishes it.
    _btn.style.left = (rect.left + rect.width / 2) + "px";
    _btn.classList.add("visible");
  }

  function _hide() {
    if (_pending) { clearTimeout(_pending); _pending = null; }
    if (_btn) _btn.classList.remove("visible");
    _snap = null;
  }

  // ── Quote action ─────────────────────────────────────────────────────────
  function _onQuoteClick(e) {
    e.preventDefault();
    e.stopPropagation();
    if (!_snap) return _hide();
    const block = _buildBlock(_snap);
    _hide();
    if (block) _insert(block);
  }

  // Append the blockquote to the composer: keep any existing draft and
  // mention chips (we append — never overwrite), ensure a blank line separates
  // it, leave the caret on a fresh line after the quote.
  // Composer is a contenteditable div since v1.5.13 (Clacky.Composer); the
  // textarea branch is a fallback for older builds / custom templates.
  // Append plain text to the composer's end, after any existing content and
  // mention chips (chips are contenteditable=false nodes — appending at the
  // very end naturally preserves them). Newlines become <br>. Works without a
  // focused caret, so it is deterministic in headless environments where
  // execCommand / focus-based insertion silently no-ops.
  function _appendToComposer(el, str) {
    const range = document.createRange();
    range.selectNodeContents(el);
    range.collapse(false);
    const frag = document.createDocumentFragment();
    String(str).split("\n").forEach((line, i) => {
      if (i > 0) frag.appendChild(document.createElement("br"));
      if (line !== "") frag.appendChild(document.createTextNode(line));
    });
    range.insertNode(frag);
  }

  function _insert(block) {
    const el = document.getElementById("user-input");
    if (!el) return;
    const api = (typeof Clacky !== "undefined" && Clacky.Composer) || null;

    if (api) {
      const cur = api.text(el);
      let prefix = "";
      if (cur.length > 0 && !cur.endsWith("\n\n")) {
        prefix = cur.endsWith("\n") ? "\n" : "\n\n";
      }
      _appendToComposer(el, prefix + block + "\n");
      api.focusEnd(el);
      el.dispatchEvent(new Event("input", { bubbles: true }));
      return;
    }

    if (el.tagName === "TEXTAREA") {
      let v = el.value || "";
      if (v.length > 0 && !v.endsWith("\n\n")) {
        v += v.endsWith("\n") ? "\n" : "\n\n";
      }
      v += block + "\n";
      el.value = v;
      el.focus();
      el.setSelectionRange(v.length, v.length);
    }
  }

  // ── Selection validation ─────────────────────────────────────────────────
  // Runs 60ms after mouseup/touchend so the browser has finished updating the
  // selection (dbl-click word selection, drag end, etc.).
  function _onMouseUp() {
    if (_pending) clearTimeout(_pending);
    _pending = setTimeout(_validate, 60);
  }

  function _validate() {
    _pending = null;
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount < 1) return _hide();
    const range = sel.getRangeAt(0);
    const r1 = _msgRoot(range.startContainer);
    const r2 = _msgRoot(range.endContainer);
    if (!r1 || r1 !== r2) return _hide();          // cross-message selection: no unique provenance
    const messages = document.getElementById("messages");
    if (!messages || !messages.contains(r1)) return _hide();

    const text = sel.toString().trim();
    if (!text) return _hide();

    _snap = Object.assign({ text }, _msgMeta(r1), { rect: range.getBoundingClientRect() });
    _show(_snap.rect);
  }

  function _onDocMouseDown(e) {
    if (_btn && e.target !== _btn && !_btn.contains(e.target)) _hide();
  }

  // ── Init ─────────────────────────────────────────────────────────────────
  function init() {
    document.addEventListener("mouseup", _onMouseUp);
    document.addEventListener("touchend", _onMouseUp);
    document.addEventListener("mousedown", _onDocMouseDown);
    document.addEventListener("scroll", _hide, true); // any scroll collides with the anchor
    document.addEventListener("keydown", e => { if (e.key === "Escape") _hide(); });
    window.addEventListener("resize", _hide);

    // Streaming rewrites message DOM wholesale; a detached selection cannot
    // anchor the button anymore, so hide whenever the message list mutates.
    const messages = document.getElementById("messages");
    if (messages && typeof MutationObserver !== "undefined") {
      new MutationObserver(() => { if (_snap) _hide(); }).observe(messages, {
        childList: true,
        subtree: true,
      });
    }
  }

  return { init };
})();