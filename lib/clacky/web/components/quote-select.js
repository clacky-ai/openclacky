// ── quote-select.js — Quote-on-selection ────────────────────────────────────
//
// Drag-select text inside any user or assistant message bubble; a floating
// "Quote" pill appears above the selection. Clicking it drops the selection
// into the composer as an atomic quote chip:
//
//   [❝ the selected text…] ▏what the user types next
//
// The chip reuses the mention-chip mechanics in composer.js: it is
// contenteditable=false, the caret skips over it, Backspace removes it whole,
// and Composer.text() leaves it out of the plain-text value. The composer DOM
// is the single source of truth — nothing is mirrored in JS state, so editing
// the composer by hand can never desync the staged quotes.
//
// QuoteSelect.toReferences() walks those chips at send time and turns them into
// reference objects. They travel the same `references` channel as @mention
// chips, so the sent bubble — and every replay of it — renders them with the
// same badge (see sessions.js _renderMentionBadge), and http_server.rb inlines
// the excerpt into the model's context. The excerpt never reaches the message
// body, so it can't be shown twice.
//
// Event bindings are delegation-style on document, so they survive history
// lazy-loading and streaming DOM rebuilds. The floating button itself is a
// single recycled element, created lazily and kept alive from its captured
// snapshot until an explicit user or navigation action dismisses it.

const QuoteSelect = (() => {
  const INPUT_ID = "user-input";
  const CHIP_CLASS = "quote-chip";

  // Lucide "message-square-text" — the comment glyph. Reads clearly at 13px and
  // stays distinct from the plain speech bubble the mention chips use.
  const ICON_QUOTE =
    '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>' +
    '<path d="M13 8H7"/><path d="M17 12H7"/>';

  let _btn = null;     // floating quote button (lazily created, recycled)
  let _snap = null;    // selection snapshot captured when the button appears
  let _pending = null; // mouseup validation timer
  let _scrollFrame = null; // coalesce scroll-driven anchor updates

  // ── DOM helpers ──────────────────────────────────────────────────────────
  // Nearest message root: .msg-user-wrap (user) or .msg-assistant. Returns
  // null when the node is outside any quotable message (e.g. composer, modal).
  function _msgRoot(node) {
    if (!node || node.nodeType === Node.DOCUMENT_NODE) return null;
    const el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
    if (!el) return null;
    return el.closest(".msg-user-wrap, .msg-assistant");
  }

  // Message role + 1-based chat index, counted among quotable messages only
  // (user / assistant), so the index stays consistent with rendered history.
  function _msgMeta(root) {
    const items = root.parentElement.querySelectorAll(
      ":scope > .msg-user-wrap, :scope > .msg-assistant"
    );
    return {
      role:  root.classList.contains("msg-user-wrap") ? "user" : "assistant",
      index: Array.prototype.indexOf.call(items, root) + 1,
    };
  }

  function _roleWord(role) {
    return role === "user"
      ? I18n.t("chat.quote.roleUser")
      : I18n.t("chat.quote.roleAssistant");
  }

  function _signature(quote) {
    return I18n.t("chat.quote.sig", {
      role: _roleWord(quote.role),
      index: quote.index,
    });
  }

  function _icon(paths, size) {
    return '<svg xmlns="http://www.w3.org/2000/svg" width="' + size + '" height="' + size +
      '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + paths + "</svg>";
  }

  function _input() {
    return document.getElementById(INPUT_ID);
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

  function _cleanText(raw) {
    return _cleanLines(raw).join("\n");
  }

  // ── Serialization ────────────────────────────────────────────────────────
  // Read the staged quotes straight off the composer — document order, which is
  // the order the user arranged them in.
  function list() {
    const el = _input();
    if (!el) return [];
    return Array.prototype.map.call(el.querySelectorAll("." + CHIP_CLASS), function (chip) {
      return {
        role:  chip.dataset.quoteRole || "user",
        index: Number(chip.dataset.quoteIndex) || 0,
        text:  chip.dataset.quoteText || "",
      };
    });
  }

  // Whole staged list → reference objects for the outgoing payload. The excerpt
  // is the point of the reference, so it rides along verbatim; `label` is the
  // provenance line ("Assistant · #82") the badge tooltip shows.
  function toReferences() {
    return list().map(function (quote) {
      return { type: "quote", label: _signature(quote), text: _cleanText(quote.text) };
    }).filter(function (ref) { return ref.text; });
  }

  // Shared with sessions.js, which draws the same glyph on the sent bubble.
  function icon(size) {
    return _icon(ICON_QUOTE, size || 13);
  }

  // ── Composer chip ────────────────────────────────────────────────────────
  function _buildChip(quote) {
    const chip = document.createElement("span");
    chip.className = "mention-chip quote-chip";
    chip.contentEditable = "false";
    chip.dataset.quoteRole = quote.role;
    chip.dataset.quoteIndex = String(quote.index);
    chip.dataset.quoteText = quote.text;
    chip.title = _signature(quote) + "\n" + quote.text;
    chip.innerHTML = _icon(ICON_QUOTE, 13);

    const label = document.createElement("span");
    label.className = "mention-chip-label";
    // Flatten onto one line: the chip is a single-line affordance, the markdown
    // keeps the real line breaks.
    label.textContent = quote.text.replace(/\s*\n\s*/g, " ");
    chip.appendChild(label);

    return chip;
  }

  // Drop a chip in at the caret (end of composer when the caret is elsewhere)
  // and leave the caret after it, ready for typing.
  function _insert(chip) {
    const el = _input();
    if (!el) return;
    const sel = window.getSelection();
    const range = (sel && sel.rangeCount && el.contains(sel.anchorNode))
      ? sel.getRangeAt(0)
      : (function () {
          const r = document.createRange();
          r.selectNodeContents(el);
          r.collapse(false);
          return r;
        })();
    range.collapse(false);

    const space = document.createTextNode(" ");
    range.insertNode(chip);
    chip.parentNode.insertBefore(space, chip.nextSibling);

    // Without a text anchor before it the browser wraps an atomic chip onto its
    // own line; composer.js keeps re-seeding these guards on every input.
    const before = chip.previousSibling;
    if (!before || before.nodeType === Node.TEXT_NODE && before.nodeValue === "") {
      chip.parentNode.insertBefore(document.createTextNode("\u200B"), chip);
    }

    const after = document.createRange();
    after.setStartAfter(space);
    after.collapse(true);
    sel.removeAllRanges();
    sel.addRange(after);
    el.focus();
    el.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function stage(snap) {
    const text = _cleanText(snap.text);
    if (!text) return;
    _insert(_buildChip({ role: snap.role, index: snap.index, text: text }));
  }

  // Replay saved quotes into the composer (session draft switching).
  function restore(items) {
    clear();
    (items || []).forEach(function (item) {
      if (item && item.text) {
        _insert(_buildChip({
          role:  item.role || "user",
          index: Number(item.index) || 0,
          text:  String(item.text),
        }));
      }
    });
  }

  function clear() {
    const el = _input();
    if (!el) return;
    Array.prototype.forEach.call(el.querySelectorAll("." + CHIP_CLASS), function (chip) {
      if (typeof Composer !== "undefined" && Composer.removeChip) Composer.removeChip(chip);
      else chip.remove();
    });
    // Removing the chips can leave their zero-width anchors behind, which would
    // keep the :empty placeholder from coming back.
    if (el.innerHTML !== "" && el.textContent.replace(/[\u200B\s]/g, "") === "") {
      el.innerHTML = "";
    }
  }

  function count() {
    return list().length;
  }

  // ── Button lifecycle ─────────────────────────────────────────────────────
  function _createBtn() {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "quote-select-btn";
    btn.disabled = false;
    btn.innerHTML =
      `<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">${ICON_QUOTE}</svg>` +
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
    // The button is a single recycled element — when it was first created it
    // baked in the language of that moment. Sync the label with the current
    // language on every show so switching en/zh mid-session stays consistent.
    // (textContent assignment, no escaping needed.)
    const labelQ = _btn.querySelector("span");
    if (labelQ) labelQ.textContent = I18n.t("chat.quote.btn");
    // The button is display:none until visible — measuring its rect while
    // hidden returns 0×0, which would misplace it by its own height. Make it
    // visible first, then measure and position (all synchronous, no flicker).
    _btn.classList.add("visible");
    const btnRect = _btn.getBoundingClientRect();
    let top = rect.top - btnRect.height - 10;   // 10px above the selection
    if (top < 8) top = rect.bottom + 10;        // flip below when clipped at top
    _btn.style.top = top + "px";
    // Horizontal center of the selection; CSS translateX(-50%) finishes it.
    _btn.style.left = (rect.left + rect.width / 2) + "px";
  }

  function _hide() {
    if (_pending) { clearTimeout(_pending); _pending = null; }
    if (_scrollFrame) { cancelAnimationFrame(_scrollFrame); _scrollFrame = null; }
    if (_btn) _btn.classList.remove("visible");
    _snap = null;
  }

  // Public lifecycle hook for callers that replace the conversation wholesale
  // (session switches and history-window jumps). Ordinary live updates must not
  // call this: _snap is deliberately independent from the browser's selection
  // once validation has captured the selected text and its provenance.
  function dismiss() {
    _hide();
  }

  function hasActiveSelection() {
    return !!_snap;
  }

  // Browser scroll anchoring and the live-session renderer may adjust the
  // message pane even when the user did not intentionally leave the quote.
  // Keep the floating action attached to the captured Range while it remains
  // visible; only discard it once its source has actually left the viewport.
  function _syncAnchor() {
    if (!_snap || !_snap.range || !_snap.root) return;
    const messages = document.getElementById("messages");
    if (!messages || !messages.contains(_snap.root)) return _hide();

    const rect = _snap.range.getBoundingClientRect();
    const bounds = messages.getBoundingClientRect();
    const hasArea = rect && (rect.width > 0 || rect.height > 0);
    const visible = hasArea && rect.bottom > bounds.top && rect.top < bounds.bottom &&
      rect.right > bounds.left && rect.left < bounds.right;
    if (!visible) return _hide();

    _snap.rect = rect;
    _show(rect);
  }

  function _onScroll() {
    if (!_snap || _scrollFrame) return;
    _scrollFrame = requestAnimationFrame(() => {
      _scrollFrame = null;
      _syncAnchor();
    });
  }

  // ── Quote action ─────────────────────────────────────────────────────────
  function _onQuoteClick(e) {
    e.preventDefault();
    e.stopPropagation();
    if (!_snap) return _hide();
    const snap = _snap;
    _hide();
    stage(snap);
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

    _snap = Object.assign({ text }, _msgMeta(r1), {
      rect: range.getBoundingClientRect(),
      range: range.cloneRange(),
      root: r1,
    });
    _show(_snap.rect);
  }

  function _onDocMouseDown(e) {
    if (_btn && e.target !== _btn && !_btn.contains(e.target)) _hide();
  }

  // ── Init ─────────────────────────────────────────────────────────────────
  let _inited = false; // guard against double init (listener stacking)
  function init() {
    if (_inited) return;
    _inited = true;
    document.addEventListener("mouseup", _onMouseUp);
    document.addEventListener("touchend", _onMouseUp);
    document.addEventListener("mousedown", _onDocMouseDown);
    document.addEventListener("scroll", _onScroll, true);
    document.addEventListener("keydown", e => { if (e.key === "Escape") _hide(); });
    window.addEventListener("resize", _hide);
  }

  return {
    init, dismiss, hasActiveSelection, stage, list, restore, clear, count, toReferences, icon,
  };
})();
