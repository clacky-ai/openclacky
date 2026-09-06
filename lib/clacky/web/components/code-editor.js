/* global CM, marked */
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
    python:   () => CM.python(),
    javascript: () => CM.javascript(),
    jsx:      () => CM.jsx(),
    typescript: () => CM.typescript(),
    tsx:      () => CM.tsx(),
    html:     () => CM.html(),
    css:      () => CM.css(),
    json:     () => CM.json(),
    sql:      () => CM.sql(),
    xml:      () => CM.xml(),
    rust:     () => CM.rust(),
    java:     () => CM.java(),
    cpp:      () => CM.cpp(),
    php:      () => CM.php(),
    ruby:     () => CM.ruby(),
    go:       () => CM.go(),
    shell:    () => CM.shell(),
    yaml:     () => CM.yaml(),
    toml:     () => CM.toml(),
    dockerfile: () => CM.dockerfile(),
  };

  // Extension → language id. Keyed by lowercase extension (no leading dot).
  const EXT_LANG = {
    md: "markdown", markdown: "markdown", mdx: "markdown",
    py: "python", pyw: "python",
    js: "javascript", mjs: "javascript", cjs: "javascript",
    jsx: "jsx",
    ts: "typescript", mts: "typescript", cts: "typescript",
    tsx: "tsx",
    html: "html", htm: "html",
    css: "css",
    json: "json", jsonc: "json",
    sql: "sql",
    xml: "xml", svg: "xml", xsd: "xml", xsl: "xml", plist: "xml",
    rs: "rust",
    java: "java",
    c: "cpp", h: "cpp", cpp: "cpp", cc: "cpp", cxx: "cpp", hpp: "cpp", hxx: "cpp", hh: "cpp",
    php: "php", php3: "php", php4: "php", php5: "php", phtml: "php",
    rb: "ruby", rbw: "ruby", gemspec: "ruby", rake: "ruby", ru: "ruby",
    go: "go",
    sh: "shell", bash: "shell", zsh: "shell", ksh: "shell",
    yaml: "yaml", yml: "yaml",
    toml: "toml",
    vue: "html", svelte: "html",
  };

  // Whole filename (no extension) → language id.
  const FILENAME_LANG = {
    dockerfile: "dockerfile",
    gemfile: "ruby", rakefile: "ruby", vagrantfile: "ruby", guardfile: "ruby",
    podfile: "ruby", berksfile: "ruby", brewfile: "ruby",
  };

  const IMAGE_EXTS  = new Set(["png","jpg","jpeg","gif","bmp","webp","svg","ico","tiff","tif","avif"]);
  const PDF_EXTS    = new Set(["pdf"]);
  const BINARY_EXTS = new Set([
    // archives
    "zip","gz","7z","tar","dmg","rar","tgz","iso","jar","war",
    // office docs (previewed via the "open with app" fallback instead)
    "xls","xlsx","doc","docx","ppt","pptx","pot","pps","ppsx","dot",
    "odt","ods","odp","wps","et","dps","key","numbers","pages",
    // media
    "mov","mp4","mp3","avi","mkv","wmv","weba","flac","wav","m4a","aac","aiff",
    // fonts
    "ttf","otf","woff","woff2","eot",
    // system / misc
    "exe","msi","db","db3","sqlite","sqlite3","dat","wasm","bin","so","dylib","dll",
    "class","pyc","psd","ai","eps","indd","sketch","fig",
  ]);

  function _fileKind(filename) {
    if (!filename) return "text";
    const ext = filename.split(".").pop().toLowerCase();
    if (IMAGE_EXTS.has(ext))  return "image";
    if (PDF_EXTS.has(ext))   return "pdf";
    if (BINARY_EXTS.has(ext)) return "binary";
    return "text";
  }

  function _detectLanguage(filename) {
    if (!filename) return null;
    const base = filename.split(/[\\/]/).pop().toLowerCase();
    if (FILENAME_LANG[base]) return FILENAME_LANG[base];
    const dot = base.lastIndexOf(".");
    if (dot < 0) return null;
    return EXT_LANG[base.slice(dot + 1)] || null;
  }

  function _isDark() {
    return document.documentElement.getAttribute("data-theme") === "dark";
  }

  function _isMarkdown(language) {
    return language === "markdown" || language === "md";
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

    const langFn = opts.language ? LANG_MAP[opts.language] : null;
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

    if (opts.onChange) {
      extensions.push(CM.EditorView.updateListener.of((update) => {
        if (update.docChanged) opts.onChange(update.state.doc.toString());
      }));
    }

    return extensions;
  }

  function _renderMarkdownHtml(text) {
    if (typeof marked !== "undefined") {
      try {
        return marked.parse(text, { breaks: true, gfm: true });
      } catch (_) { /* fall through */ }
    }
    return `<pre>${text.replace(/</g, "&lt;")}</pre>`;
  }

  // Inline (non-modal) editor: mount a CodeMirror instance into `container`
  // without any modal chrome. Used by the workspace file viewer.
  // Returns { view, getContent, destroy }.
  function createInline(container, opts = {}) {
    const getContent = () => view.state.doc.toString();
    const editorOpts = {
      language: opts.language,
      readOnly: !!opts.readOnly,
      onSave: opts.onSave ? () => opts.onSave(getContent()) : null,
      onChange: opts.onChange || null,
      _getContent: () => getContent(),
    };
    const view = new CM.EditorView({
      state: CM.EditorState.create({
        doc: opts.content || "",
        extensions: _buildExtensions(editorOpts),
      }),
      parent: container,
    });
    return {
      view,
      getContent,
      destroy: () => { try { view.destroy(); } catch (_e) { /* already gone */ } },
    };
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
    const isMd = _isMarkdown(language) && kind !== "image";

    let overlay = document.getElementById("code-editor-overlay");
    if (overlay) overlay.remove();

    overlay = document.createElement("div");
    overlay.id = "code-editor-overlay";
    overlay.className = "modal-overlay";

    const cancelLabel = I18n.t("modal.cancel");
    const closeLabel  = I18n.t("modal.close");
    const saveLabel   = I18n.t("modal.save");

    const isReadOnlyOrImage = readOnly || kind === "image";
    const footerActions = isReadOnlyOrImage
      ? `<button class="btn btn-secondary code-editor-cancel">${closeLabel}</button>`
      : `<button class="btn btn-secondary code-editor-cancel">${cancelLabel}</button><button class="btn btn-primary code-editor-save">${saveLabel}</button>`;

    overlay.innerHTML = `
      <div class="code-editor-modal${kind === "image" ? " code-editor-modal--image" : ""}${isMd ? " code-editor-modal--md" : ""}">
        <div class="code-editor-header">
          <h3 class="code-editor-title"></h3>
          <button class="code-editor-close" title="${closeLabel}">&times;</button>
        </div>
        <div class="code-editor-body${isMd ? " code-editor-body--split" : ""}">
          ${isMd ? `<div class="code-editor-split-left"></div><div class="code-editor-split-divider"></div><div class="code-editor-split-right"><div class="code-editor-markdown-preview"></div></div>` : ""}
        </div>
        <div class="code-editor-footer">
          <span class="code-editor-status"></span>
          <div class="code-editor-actions">${footerActions}</div>
        </div>
      </div>`;

    document.body.appendChild(overlay);
    overlay.querySelector(".code-editor-title").textContent = title;

    const body      = overlay.querySelector(".code-editor-body");
    const status    = overlay.querySelector(".code-editor-status");
    const closeBtn  = overlay.querySelector(".code-editor-close");
    const cancelBtn = overlay.querySelector(".code-editor-cancel");
    const saveBtn   = overlay.querySelector(".code-editor-save");

    function close() {
      overlay.remove();
      if (onClose) onClose();
    }

    closeBtn.addEventListener("click", close);
    if (cancelBtn) cancelBtn.addEventListener("click", close);

    if (kind === "image") {
      body.classList.add("code-editor-body--image");
      const img = document.createElement("img");
      img.className = "code-editor-img-preview";
      img.alt = title;
      img.src = imageUrl || "";
      body.appendChild(img);
      return { close };
    }

    // Editor mount target: left pane for markdown split, body itself otherwise
    const editorParent = isMd ? overlay.querySelector(".code-editor-split-left") : body;
    const previewPane  = isMd ? overlay.querySelector(".code-editor-markdown-preview") : null;

    function updatePreview(text) {
      if (previewPane) previewPane.innerHTML = _renderMarkdownHtml(text);
    }

    const editorOpts = {
      language: language || "markdown",
      readOnly,
      onSave: null,
      _getContent: null,
      onChange: isMd ? updatePreview : null,
    };
    const getContent = () => view.state.doc.toString();
    editorOpts._getContent = getContent;
    editorOpts.onSave = onSave ? () => doSave() : null;

    const view = new CM.EditorView({
      state: CM.EditorState.create({
        doc: content,
        extensions: _buildExtensions(editorOpts),
      }),
      parent: editorParent,
    });

    // Render initial preview
    if (isMd) updatePreview(content);

    async function doSave() {
      if (!onSave) return;
      if (saveBtn) saveBtn.disabled = true;
      status.textContent = I18n.t("modal.saving");
      status.className = "code-editor-status";
      try {
        await onSave(getContent());
        close();
      } catch (e) {
        status.textContent = e.message || "Save failed";
        status.className = "code-editor-status code-editor-status-error";
        if (saveBtn) saveBtn.disabled = false;
      }
    }

    if (saveBtn) saveBtn.addEventListener("click", doSave);
    setTimeout(() => view.focus(), 50);

    return { view, close, getContent };
  }

  window.CodeEditor = {
    open,
    createInline,
    fileKind: _fileKind,
    detectLanguage: _detectLanguage,
    renderMarkdown: _renderMarkdownHtml,
  };
})(window);
