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
  const REFERENCE_DRAG_TYPE = "application/x-openclacky-reference";
  const WORKSPACE_FILE_DRAG_TYPE = "application/x-openclacky-workspace-file";
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

  // ArrowUp/Down recall position per composer: { index, filled }.
  const _recall = new WeakMap();

  // Replace composer contents with plain text (newlines → <br>), caret at end.
  function setText(el, value) {
    _recall.delete(el);
    _fill(el, value);
  }

  function _fill(el, value) {
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
    _recall.delete(el);
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
  // Quote chips ride on the same chip mechanics (atomic, skipped by text()) but
  // are not mentions — quote-select.js reads them off the DOM itself.
  function chips(el) {
    return Array.from(el.querySelectorAll("." + CHIP_CLASS + ":not(.quote-chip)")).map((c) => {
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

  function _rangeAtEnd(el) {
    const range = document.createRange();
    range.selectNodeContents(el);
    range.collapse(false);
    return range;
  }

  // Resolve the browser's caret position at a pointer coordinate. Chromium
  // exposes caretRangeFromPoint while Firefox uses caretPositionFromPoint.
  // Only accept positions inside this composer; dropping on its surrounding
  // card deliberately falls back to the end instead of mutating another node.
  function _rangeFromPoint(el, x, y) {
    let range = null;
    if (document.caretPositionFromPoint) {
      const pos = document.caretPositionFromPoint(x, y);
      if (pos && el.contains(pos.offsetNode)) {
        range = document.createRange();
        range.setStart(pos.offsetNode, pos.offset);
        range.collapse(true);
      }
    } else if (document.caretRangeFromPoint) {
      const candidate = document.caretRangeFromPoint(x, y);
      if (candidate && el.contains(candidate.startContainer)) range = candidate;
    }
    return range;
  }

  function _insertChipAtRange(el, chip, range) {
    const sel = window.getSelection();
    range = range || _rangeAtEnd(el);
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

  // Insert a chip at the current caret, followed by a space; caret after it.
  function insertChip(el, chip) {
    const sel = window.getSelection();
    const range = (sel && sel.rangeCount && el.contains(sel.anchorNode))
      ? sel.getRangeAt(0)
      : _rangeAtEnd(el);
    _insertChipAtRange(el, chip, range);
  }

  function _normalizeDraggedChip(value) {
    if (!value || typeof value !== "object" || value.type !== "session") return null;
    const sessionId = String(value.sessionId || value.session_id || "").trim();
    if (!sessionId || sessionId.length > 512) return null;
    const rawName = String(value.name || sessionId).trim();
    const name = (rawName || sessionId).slice(0, 512);
    return { type: "session", name, sessionId };
  }

  // Start an internal reference drag. The custom MIME payload is authoritative;
  // text/plain is only a harmless fallback when dropped outside OpenClacky.
  function beginReferenceDrag(dataTransfer, chip) {
    const normalized = _normalizeDraggedChip(chip);
    if (!dataTransfer || !normalized) return false;

    // The composer treats this as a copy, while sidebar project targets may
    // interpret the same session drag as a move between organization buckets.
    dataTransfer.effectAllowed = "copyMove";
    dataTransfer.setData(REFERENCE_DRAG_TYPE, JSON.stringify(normalized));
    dataTransfer.setData("text/plain", "@" + normalized.name);

    if (dataTransfer.setDragImage && document.body) {
      const preview = _buildChip(normalized);
      preview.classList.add("reference-drag-preview");
      preview.setAttribute("aria-hidden", "true");
      document.body.appendChild(preview);
      dataTransfer.setDragImage(preview, 18, 18);
      setTimeout(() => preview.remove(), 0);
    }
    return true;
  }

  function readDraggedChip(dataTransfer) {
    if (!dataTransfer) return null;
    let raw = "";
    try {
      raw = dataTransfer.getData(REFERENCE_DRAG_TYPE) || "";
    } catch (_) {
      return null;
    }
    if (!raw || raw.length > 4096) return null;
    try {
      return _normalizeDraggedChip(JSON.parse(raw));
    } catch (_) {
      return null;
    }
  }

  function acceptsSessionDrag(dataTransfer) {
    if (!dataTransfer || !dataTransfer.types) return false;
    const types = Array.from(dataTransfer.types);
    return types.includes(REFERENCE_DRAG_TYPE);
  }

  function _normalizeDraggedWorkspaceFile(value) {
    if (!value || typeof value !== "object" || value.type !== "file") return null;
    const path = String(value.path || "").trim();
    if (!path || path.length > 32768) return null;
    const rawName = String(value.name || path.split(/[\\/]/).pop() || "").trim();
    if (!rawName) return null;
    const size = value.size == null ? NaN : Number(value.size);
    return {
      type: "file",
      name: rawName.slice(0, 512),
      path,
      size: Number.isFinite(size) && size >= 0 ? size : null,
    };
  }

  // Start a drag from the Files tree without turning the workspace entry into
  // a browser File. The path-backed attachment keeps using the same staging
  // path as the Files tab's "Add to chat" action.
  function beginWorkspaceFileDrag(dataTransfer, file) {
    const normalized = _normalizeDraggedWorkspaceFile(file);
    if (!dataTransfer || !normalized) return false;
    dataTransfer.effectAllowed = "copy";
    dataTransfer.setData(WORKSPACE_FILE_DRAG_TYPE, JSON.stringify(normalized));
    dataTransfer.setData("text/plain", normalized.name);
    return true;
  }

  function readDraggedWorkspaceFile(dataTransfer) {
    if (!dataTransfer) return null;
    let raw = "";
    try {
      raw = dataTransfer.getData(WORKSPACE_FILE_DRAG_TYPE) || "";
    } catch (_) {
      return null;
    }
    if (!raw || raw.length > 65536) return null;
    try {
      return _normalizeDraggedWorkspaceFile(JSON.parse(raw));
    } catch (_) {
      return null;
    }
  }

  function acceptsWorkspaceFileDrag(dataTransfer) {
    if (!dataTransfer || !dataTransfer.types) return false;
    return Array.from(dataTransfer.types).includes(WORKSPACE_FILE_DRAG_TYPE);
  }

  function _acceptsDrop(dataTransfer, allowWorkspaceFile) {
    if (!dataTransfer || !dataTransfer.types) return false;
    const types = Array.from(dataTransfer.types);
    return acceptsSessionDrag(dataTransfer) || types.includes("Files") ||
      (allowWorkspaceFile && acceptsWorkspaceFileDrag(dataTransfer));
  }

  function acceptsDrop(dataTransfer) {
    return _acceptsDrop(dataTransfer, true);
  }

  // Insert a valid dropped reference at the pointer position. Returns false
  // for files and unrelated drags so the caller can keep its existing upload
  // path unchanged.
  function insertDroppedChip(el, dataTransfer, x, y) {
    const chip = readDraggedChip(dataTransfer);
    if (!el || !chip) return false;
    _insertChipAtRange(el, chip, _rangeFromPoint(el, x, y) || _rangeAtEnd(el));
    return true;
  }

  // Make a whole page/panel act as the drop target for its composer. Session
  // references are inserted into the contenteditable; files are handed back
  // to the owning view so its existing attachment pipeline remains in charge.
  function bindDropZone({ zone, input, onFiles, onWorkspaceFile }) {
    if (!zone || !input) return;

    const acceptsBoundDrop = (dataTransfer) =>
      _acceptsDrop(dataTransfer, typeof onWorkspaceFile === "function");

    zone.addEventListener("dragover", (event) => {
      if (!acceptsBoundDrop(event.dataTransfer)) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
      zone.classList.add("drag-over");
    });
    zone.addEventListener("dragleave", (event) => {
      if (!zone.contains(event.relatedTarget)) zone.classList.remove("drag-over");
    });
    zone.addEventListener("drop", (event) => {
      if (!acceptsBoundDrop(event.dataTransfer)) return;
      event.preventDefault();
      zone.classList.remove("drag-over");
      if (insertDroppedChip(input, event.dataTransfer, event.clientX, event.clientY)) return;

      const workspaceFile = readDraggedWorkspaceFile(event.dataTransfer);
      if (workspaceFile && typeof onWorkspaceFile === "function") {
        onWorkspaceFile(workspaceFile);
        return;
      }

      const files = Array.from(event.dataTransfer.files || []);
      if (files.length > 0 && typeof onFiles === "function") onFiles(files);
    });
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

  // Re-establish a text anchor before each chip. Editing can delete the
  // leading zero-width guard (when the caret sits inside it), after which the
  // browser drops a <br>/<div> line anchor before the chip and wraps it onto
  // its own line. Runs on every input event.
  function _ensureChipGuards(el) {
    for (const chip of Array.from(el.querySelectorAll("." + CHIP_CLASS))) {
      let prev = chip.previousSibling;
      // A stray <br> that has no visible text before it is the browser's line
      // anchor, not a user Shift+Enter break — drop it so the chip rejoins the
      // current line.
      if (prev && prev.nodeType === ELEMENT_NODE && prev.tagName === "BR") {
        const beforeBr = prev.previousSibling;
        const noTextBefore = !beforeBr ||
          (beforeBr.nodeType === TEXT_NODE && /^[\u200B]*$/.test(beforeBr.nodeValue));
        if (noTextBefore) prev.remove();
      }
      const before = chip.previousSibling;
      if (!before || before.nodeType !== TEXT_NODE || before.nodeValue === "") {
        chip.parentNode.insertBefore(document.createTextNode("\u200B"), chip);
      }
    }
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

  // Shell-style recall: only from an empty box, or while the box still holds
  // the last recalled entry untouched. Past the newest entry clears the box.
  function _handleHistory(el, e, getHistory) {
    if (!getHistory || (e.key !== "ArrowUp" && e.key !== "ArrowDown")) return false;
    if (e.isComposing || e.shiftKey || e.altKey || e.metaKey || e.ctrlKey) return false;
    let state = _recall.get(el);
    if (state && (text(el) !== state.filled || el.querySelector("." + CHIP_CLASS))) {
      _recall.delete(el);
      state = null;
    }
    if (!state && (hasContent(el) || e.key === "ArrowDown")) return false;
    const history = getHistory();
    if (!history.length) return false;
    e.preventDefault();
    const index = Math.max(0, (state ? state.index : history.length) + (e.key === "ArrowUp" ? -1 : 1));
    if (index >= history.length) {
      clear(el);
      return true;
    }
    _fill(el, history[index]);
    _recall.set(el, { index, filled: text(el) });
    return true;
  }

  // Wire up chip deletion, plain-text paste, Shift+Enter, and optional
  // ArrowUp/Down recall of opts.getHistory() (oldest → newest) for one composer.
  function init(el, opts = {}) {
    if (!el || el.dataset.composerInit) return;
    el.dataset.composerInit = "1";
    el.addEventListener("keydown", (e) => {
      if (_handleKeydown(el, e)) return;
      if (_handleHistory(el, e, opts.getHistory)) return;
      _handleEnter(el, e);
    });
    el.addEventListener("paste", (e) => _handlePaste(el, e));
    // Browsers leave a stray <br> after deleting all text, which breaks the
    // :empty::before placeholder. Clear it so the placeholder shows again.
    el.addEventListener("input", () => {
      _ensureChipGuards(el);
      if (text(el).trim() === "" && !el.querySelector("." + CHIP_CLASS) && el.innerHTML !== "") {
        el.innerHTML = "";
      }
    });
  }

  return {
    text, setText, clear, focus, focusEnd, hasContent,
    chips, insertChip, insertDroppedChip, beginReferenceDrag, readDraggedChip,
    acceptsSessionDrag, beginWorkspaceFileDrag, readDraggedWorkspaceFile,
    acceptsWorkspaceFileDrag,
    acceptsDrop, bindDropZone,
    removeChip, setPlaceholder, init,
  };
})();

Clacky.Composer = Composer;
