// ── Composer — contenteditable composer abstraction ─────────────────────
// Wraps the message composer (now a <div contenteditable> instead of a
// <textarea>) so the rest of the app reads/writes plain text and manages
// mention chips through one API, hiding the DOM / caret / paste differences.
//
// Chips are <span class="mention-chip" contenteditable="false"> elements
// carrying a data-mention-type (file | directory | session) plus payload
// attributes. They are atomic: the caret skips them, Backspace/Delete removes
// them whole, and text() excludes them from the plain-text value.
//
// Depends on: nothing (pure DOM + Selection API). Loaded after app.js ($ helper).
// ─────────────────────────────────────────────────────────────────────────
"use strict";

const Composer = (() => {
  const CHIP_CLASS = "mention-chip";
  const ELEMENT_NODE = 1;
  const TEXT_NODE = 3;

  // Lucide-style 24×24 stroke paths for the chip type icons (matches the
  // inline SVGs used across the UI).
  const CHIP_ICONS = {
    file:      ["M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z", "M14 2v4a2 2 0 0 0 2 2h4"],
    directory: "M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z",
    session:   "M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z",
  };

  function _chipIcon(type) {
    const paths = CHIP_ICONS[type];
    if (!paths) return null;
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("width", "13");
    svg.setAttribute("height", "13");
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
    const wrap = document.createElement("span");
    wrap.className = "mention-chip-icon";
    wrap.appendChild(svg);
    return wrap;
  }

  function _isChip(node) {
    return !!node && node.nodeType === ELEMENT_NODE && node.classList && node.classList.contains(CHIP_CLASS);
  }

  // Plain text of the composer, excluding chips. Newlines are reconstructed
  // from <br> and block elements; zero-width / non-breaking spaces normalized.
  function text(el) {
    let out = "";
    const walk = (node) => {
      for (const n of Array.from(node.childNodes)) {
        if (n.nodeType === TEXT_NODE) {
          out += n.nodeValue;
          continue;
        }
        if (n.nodeType !== ELEMENT_NODE) continue;
        if (_isChip(n)) continue;
        switch (n.tagName) {
          case "BR":
            out += "\n";
            break;
          case "DIV":
          case "P":
          case "LI":
            if (out && !out.endsWith("\n")) out += "\n";
            walk(n);
            if (!out.endsWith("\n")) out += "\n";
            break;
          default:
            walk(n);
        }
      }
    };
    walk(el);
    return out.replace(/\u200B/g, "").replace(/\u00A0/g, " ");
  }

  // Replace composer contents with plain text (newlines → <br>), caret at end.
  function setText(el, value) {
    el.innerHTML = "";
    const v = String(value == null ? "" : value);
    if (v !== "") {
      v.split("\n").forEach((line, i) => {
        if (i > 0) el.appendChild(document.createElement("br"));
        el.appendChild(document.createTextNode(line));
      });
    }
    focusEnd(el);
  }

  function clear(el) {
    el.innerHTML = "";
  }

  function focus(el) {
    el.focus();
  }

  // Move the caret to the very end of the composer and focus it.
  function focusEnd(el) {
    el.focus();
    const range = document.createRange();
    range.selectNodeContents(el);
    range.collapse(false);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  // True when the composer holds any text or chip (for send-button state).
  function hasContent(el) {
    return text(el).trim().length > 0 || el.querySelector("." + CHIP_CLASS) != null;
  }

  // Extract mention chips as plain data objects, in document order.
  // file/directory → { type, name, path }; session → { type, name, session_id }.
  function chips(el) {
    return Array.from(el.querySelectorAll("." + CHIP_CLASS)).map((c) => {
      const type = c.dataset.mentionType || "";
      const out = { type: type, name: c.dataset.name || "" };
      if (type === "session") {
        out.session_id = c.dataset.sessionId || "";
      } else {
        out.path = c.dataset.path || "";
      }
      return out;
    });
  }

  function _emitInput(el) {
    el.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function _buildChip(chip) {
    const span = document.createElement("span");
    span.className = CHIP_CLASS;
    span.contentEditable = "false";
    span.dataset.mentionType = chip.type || "";
    span.dataset.name = chip.name || "";
    if (chip.type === "session") {
      span.dataset.sessionId = chip.sessionId || "";
    } else {
      span.dataset.path = chip.path || "";
    }

    const icon = _chipIcon(chip.type);
    if (icon) span.appendChild(icon);

    const label = document.createElement("span");
    label.className = "mention-chip-label";
    label.textContent = chip.name || "";

    span.appendChild(label);
    return span;
  }

  // Insert a chip at the current caret, followed by a space; caret after it.
  function insertChip(el, chip) {
    const sel = window.getSelection();
    const range = (sel && sel.rangeCount && el.contains(sel.anchorNode))
      ? sel.getRangeAt(0)
      : (() => { const r = document.createRange(); r.selectNodeContents(el); r.collapse(false); return r; })();
    range.collapse(false);

    const chipEl = _buildChip(chip);
    const space = document.createTextNode(" ");
    range.insertNode(chipEl);
    chipEl.parentNode.insertBefore(space, chipEl.nextSibling);

    // A leading zero-width guard keeps the caret from sitting on the bare
    // block boundary before an atomic chip, where browsers insert a <br>/<div>
    // on input/delete and push the chip onto its own line.
    const prev = chipEl.previousSibling;
    if (!prev || prev.nodeType !== TEXT_NODE) {
      chipEl.parentNode.insertBefore(document.createTextNode("\u200B"), chipEl);
    }

    const after = document.createRange();
    after.setStartAfter(space);
    after.collapse(true);
    sel.removeAllRanges();
    sel.addRange(after);
    el.focus();
    _emitInput(el);
  }

  // Remove a chip DOM node and its surrounding zero-width guards + separator whitespace.
  function removeChip(chipEl) {
    const prev = chipEl.previousSibling;
    if (prev && prev.nodeType === TEXT_NODE && /^\u200B+$/.test(prev.nodeValue)) {
      prev.remove();
    }
    const next = chipEl.nextSibling;
    if (next && next.nodeType === TEXT_NODE && /^[\s\u00A0\u200B]*$/.test(next.nodeValue)) {
      next.remove();
    }
    chipEl.remove();
  }

  // Backspace/Delete at a chip boundary removes the chip atomically.
  function _handleKeydown(el, e) {
    if (e.key !== "Backspace" && e.key !== "Delete") return false;
    const sel = window.getSelection();
    if (!sel || !sel.rangeCount || !sel.isCollapsed) return false;
    const range = sel.getRangeAt(0);
    const container = range.startContainer;
    const offset = range.startOffset;

    let target = null;
    if (e.key === "Backspace") {
      if (container.nodeType === TEXT_NODE) {
        if (offset === 0) target = container.previousSibling;
      } else if (container === el) {
        target = container.childNodes[offset - 1];
      }
    } else {
      if (container.nodeType === TEXT_NODE) {
        if (offset === container.nodeValue.length) target = container.nextSibling;
      } else if (container === el) {
        target = container.childNodes[offset];
      }
    }

    if (_isChip(target)) {
      e.preventDefault();
      removeChip(target);
      _emitInput(el);
      return true;
    }
    return false;
  }

  // Plain-text paste. File pastes are left untouched so the caller's own
  // paste handler (which stages attachments) owns those events.
  function _handlePaste(el, e) {
    const items = Array.from(e.clipboardData && e.clipboardData.items ? e.clipboardData.items : []);
    if (items.some((it) => it.kind === "file")) return;
    const plain = e.clipboardData.getData("text/plain");
    if (plain) {
      e.preventDefault();
      document.execCommand("insertText", false, plain);
    }
  }

  // Shift+Enter inserts a line break (Enter-to-send is owned by SkillAC).
  function _handleEnter(el, e) {
    if (e.key === "Enter" && e.shiftKey && !e.isComposing) {
      e.preventDefault();
      document.execCommand("insertLineBreak");
    }
  }

  function setPlaceholder(el, value) {
    el.setAttribute("data-placeholder", value || "");
  }

  // Wire up chip deletion, plain-text paste, and Shift+Enter for one composer.
  function init(el) {
    if (!el || el.dataset.composerInit) return;
    el.dataset.composerInit = "1";
    el.addEventListener("keydown", (e) => {
      if (_handleKeydown(el, e)) return;
      _handleEnter(el, e);
    });
    el.addEventListener("paste", (e) => _handlePaste(el, e));
    // Browsers leave a stray <br> after deleting all text, which breaks the
    // :empty::before placeholder. Clear it so the placeholder shows again.
    el.addEventListener("input", () => {
      if (text(el).trim() === "" && !el.querySelector("." + CHIP_CLASS) && el.innerHTML !== "") {
        el.innerHTML = "";
      }
    });
  }

  return {
    text, setText, clear, focus, focusEnd, hasContent,
    chips, insertChip, removeChip, setPlaceholder, init,
  };
})();

Clacky.Composer = Composer;
