/* global CM */
/**
 * CodeEditor — a reusable wrapper around CodeMirror 6.
 *
 * Usage:
 *   CodeEditor.open({
 *     content: '# Hello',
 *     language: 'markdown',
 *     title: 'SKILL.md',
 *     readOnly: false,
 *     onSave: async (content) => { ... }
 *   });
 */
;(function(window) {
  "use strict";

  const LANG_MAP = {
    markdown: () => CM.markdown({ base: CM.markdownLanguage }),
    md:       () => CM.markdown({ base: CM.markdownLanguage }),
  };

  const IMAGE_EXTS  = new Set(["png","jpg","jpeg","gif","bmp","webp","svg","ico","tiff","tif","avif"]);
  const BINARY_EXTS = new Set(["zip","gz","7z","tar","dmg","pdf","xls","xlsx","doc","docx","exe","rar","ttf","mov","mp4","mp3","db","db3","sqlite","sqlite3","dat","wasm","bin","so","dylib","dll"]);

  function _fileKind(filename) {
    if (!filename) return "text";
    const ext = filename.split(".").pop().toLowerCase();
    if (IMAGE_EXTS.has(ext))  return "image";
    if (BINARY_EXTS.has(ext)) return "binary";
    return "text";
  }

  function _detectLanguage(filename) {
    if (!filename) return "markdown";
    const ext = filename.split(".").pop().toLowerCase();
    const map = { md: "markdown", markdown: "markdown" };
    return map[ext] || "markdown";
  }

  function _isDark() {
    return document.documentElement.getAttribute("data-theme") === "dark";
  }

  function _buildExtensions(opts) {
    const extensions = [
      CM.lineNumbers(),
      CM.highlightActiveLineGutter(),
      CM.highlightSpecialChars(),
      CM.history(),
      CM.drawSelection(),
      CM.dropCursor(),
      CM.indentOnInput(),
      CM.bracketMatching(),
      CM.rectangularSelection(),
      CM.crosshairCursor(),
      CM.highlightActiveLine(),
      CM.highlightSelectionMatches(),
      CM.keymap.of([
        ...CM.defaultKeymap,
        ...CM.historyKeymap,
        ...CM.searchKeymap,
        ...CM.foldKeymap,
        CM.indentWithTab,
      ]),
      CM.search(),
      CM.foldGutter(),
      CM.syntaxHighlighting(CM.defaultHighlightStyle, { fallback: true }),
      CM.EditorView.lineWrapping,
    ];

    if (_isDark()) {
      extensions.push(CM.oneDark);
    }

    const langFn = LANG_MAP[opts.language || "markdown"];
    if (langFn) extensions.push(langFn());

    if (opts.readOnly) {
      extensions.push(CM.EditorState.readOnly.of(true));
    }

    if (opts.onSave) {
      extensions.push(CM.keymap.of([{
        key: "Mod-s",
        run: () => { opts.onSave(opts._getContent()); return true; }
      }]));
    }

    return extensions;
  }

  function open(opts) {
    const {
      content = "",
      title = "Editor",
      readOnly = false,
      onSave = null,
      onClose = null,
      imageUrl = null,
    } = opts;

    const kind = opts.kind || (opts.filename ? _fileKind(opts.filename) : "text");
    const language = opts.language || _detectLanguage(opts.filename);

    let overlay = document.getElementById("code-editor-overlay");
    if (overlay) overlay.remove();

    overlay = document.createElement("div");
    overlay.id = "code-editor-overlay";
    overlay.className = "modal-overlay";

    const cancelLabel = I18n.t("modal.cancel");
    const closeLabel = I18n.t("modal.close");
    const saveLabel = I18n.t("modal.save");

    const isReadOnlyOrImage = readOnly || kind === "image";
    const footerActions = isReadOnlyOrImage
      ? `<button class="btn btn-secondary code-editor-cancel">${closeLabel}</button>`
      : `<button class="btn btn-secondary code-editor-cancel">${cancelLabel}</button><button class="btn btn-primary code-editor-save">${saveLabel}</button>`;

    overlay.innerHTML = `
      <div class="code-editor-modal${kind === "image" ? " code-editor-modal--image" : ""}">
        <div class="code-editor-header">
          <h3 class="code-editor-title"></h3>
          <button class="code-editor-close" title="${closeLabel}">&times;</button>
        </div>
        <div class="code-editor-body"></div>
        <div class="code-editor-footer">
          <span class="code-editor-status"></span>
          <div class="code-editor-actions">${footerActions}</div>
        </div>
      </div>`;

    document.body.appendChild(overlay);
    overlay.querySelector(".code-editor-title").textContent = title;

    const body    = overlay.querySelector(".code-editor-body");
    const status  = overlay.querySelector(".code-editor-status");
    const closeBtn  = overlay.querySelector(".code-editor-close");
    const cancelBtn = overlay.querySelector(".code-editor-cancel");
    const saveBtn   = overlay.querySelector(".code-editor-save");

    function close() {
      overlay.remove();
      if (onClose) onClose();
    }

    closeBtn.addEventListener("click", close);
    if (cancelBtn) cancelBtn.addEventListener("click", close);
    overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });

    if (kind === "image") {
      body.classList.add("code-editor-body--image");
      const img = document.createElement("img");
      img.className = "code-editor-img-preview";
      img.alt = title;
      img.src = imageUrl || "";
      body.appendChild(img);
      return { close };
    }

    const editorOpts = { language, readOnly, onSave: null, _getContent: null };
    const getContent = () => view.state.doc.toString();
    editorOpts._getContent = getContent;
    editorOpts.onSave = onSave ? () => doSave() : null;

    const view = new CM.EditorView({
      state: CM.EditorState.create({
        doc: content,
        extensions: _buildExtensions(editorOpts),
      }),
      parent: body,
    });

    async function doSave() {
      if (!onSave) return;
      if (saveBtn) {
        saveBtn.disabled = true;
        saveBtn.textContent = I18n.t("modal.saving");
      }
      status.textContent = "";
      status.className = "code-editor-status";
      try {
        await onSave(getContent());
        if (saveBtn) {
          saveBtn.textContent = I18n.t("modal.saved");
          saveBtn.classList.add("code-editor-save--saved");
        }
        setTimeout(close, 1000);
      } catch (e) {
        status.textContent = e.message || "Save failed";
        status.className = "code-editor-status code-editor-status-error";
        if (saveBtn) {
          saveBtn.disabled = false;
          saveBtn.textContent = I18n.t("modal.save");
        }
      }
    }

    if (saveBtn) saveBtn.addEventListener("click", doSave);
    setTimeout(() => view.focus(), 50);

    return { view, close, getContent };
  }

  window.CodeEditor = { open, fileKind: _fileKind };
})(window);
