// The message input used at the bottom of the main chat panel and of the
// side chat panel. One implementation, so both inputs cannot drift apart.
//
// The component owns the parts that are identical in both places:
//   - DOM: card frame, attachment strip, attach/slash/send/stop buttons
//   - attachments: client-side image compression, POST /api/upload for other
//     files, preview strip rendering, drag-drop and paste staging
//   - Enter-to-send and the ArrowUp/Down history recall
//
// The caller owns everything that depends on what a message means: the WS
// payload, drafts, the slash menu (SkillAC) and the @ mention menu. Both call
// sites drive Enter through SkillAC, so they pass `enterToSend: false` and
// call `composer.submit()` from SkillAC's onSend.

const ChatComposer = (() => {
  let _seq = 0;

  const MAX_IMAGE_SIZE       = 5 * 1024 * 1024;   // reject before compression
  const MAX_IMAGE_BYTES_SEND = 512 * 1024;        // target after compression
  const MAX_IMAGE_LONG_EDGE  = 1920;
  const MAX_FILE_BYTES       = 300 * 1024 * 1024;

  const ACCEPTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];
  const IMAGE_MIME_BY_EXT = {
    png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg",
    gif: "image/gif", webp: "image/webp",
  };
  // Must match what /api/local-image serves, or path-backed thumbnails break.
  const IMAGE_FILE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "gif", "webp", "svg"]);

  const ICON_ATTACH =
    `<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66L9.41 17.41a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>`;
  const ICON_SLASH =
    `<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M16 3l-8 18"/></svg>`;
  const ICON_SEND =
    `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"></line><polyline points="12 5 19 12 12 19"></polyline></svg>`;
  const ICON_STOP =
    `<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><rect x="5" y="5" width="14" height="14" rx="2.5"></rect></svg>`;

  const _ext = (name) => String(name || "").split(".").pop().toLowerCase();

  function _isImageAttachment(name) {
    return IMAGE_FILE_EXTENSIONS.has(_ext(name));
  }

  function _attachmentImageUrl(filePath) {
    if (!filePath) return "";
    const path = window.Clacky?.Workspace?.absPath
      ? Clacky.Workspace.absPath(filePath)
      : filePath;
    return `/api/local-image?path=${encodeURIComponent(path)}`;
  }

  function _typeLabel(name) {
    const lower = String(name || "").toLowerCase();
    if (lower.endsWith(".tar.gz")) return "TAR.GZ";
    return (String(name || "").split(".").pop() || "file").toUpperCase();
  }

  // PNG keeps its alpha; everything else becomes JPEG at falling quality.
  // GIF loses animation, which is fine — only the first frame reaches the model.
  function _compressImage(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(new Error("Failed to read image"));
      reader.onload = (e) => {
        const img = new Image();
        img.onerror = () => reject(new Error("Failed to decode image"));
        img.onload = () => {
          let { width, height } = img;
          if (width > MAX_IMAGE_LONG_EDGE || height > MAX_IMAGE_LONG_EDGE) {
            const ratio = Math.min(MAX_IMAGE_LONG_EDGE / width, MAX_IMAGE_LONG_EDGE / height);
            width = Math.round(width * ratio);
            height = Math.round(height * ratio);
          }

          const canvas = document.createElement("canvas");
          canvas.width = width;
          canvas.height = height;
          const ctx = canvas.getContext("2d");
          ctx.drawImage(img, 0, 0, width, height);

          if (file.type === "image/png") {
            let dataUrl = canvas.toDataURL("image/png");
            let scale = 0.9;
            while (dataUrl.length * 0.75 > MAX_IMAGE_BYTES_SEND && scale > 0.3) {
              const sw = Math.round(width * scale);
              const sh = Math.round(height * scale);
              canvas.width = sw;
              canvas.height = sh;
              ctx.drawImage(img, 0, 0, sw, sh);
              dataUrl = canvas.toDataURL("image/png");
              scale -= 0.1;
            }
            resolve(dataUrl);
            return;
          }

          let quality = 0.85;
          let dataUrl = canvas.toDataURL("image/jpeg", quality);
          while (dataUrl.length * 0.75 > MAX_IMAGE_BYTES_SEND && quality > 0.2) {
            quality -= 0.1;
            dataUrl = canvas.toDataURL("image/jpeg", quality);
          }
          resolve(dataUrl);
        };
        img.src = e.target.result;
      };
      reader.readAsDataURL(file);
    });
  }

  function _button(id, className, tooltipKey, icon) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.id = id;
    btn.className = className;
    btn.setAttribute("data-i18n-tooltip", tooltipKey);
    btn.setAttribute("data-tooltip-pos", "top");
    btn.innerHTML = icon;
    return btn;
  }

  function create(options = {}) {
    const ns = options.ids || {};
    const uid = ++_seq;
    const idOf = (key) => ns[key] || `cc-${key}-${uid}`;

    const mount = typeof options.mount === "string"
      ? document.getElementById(options.mount)
      : options.mount;
    if (!mount) throw new Error("ChatComposer: mount node not found");

    // ── DOM ────────────────────────────────────────────────────────────────
    const card = document.createElement("div");
    card.id = idOf("card");
    card.className = "composer-card";

    const strip = document.createElement("div");
    strip.id = idOf("strip");
    strip.className = "composer-strip";
    strip.hidden = true;

    const bar = document.createElement("div");
    bar.id = idOf("bar");
    bar.className = "composer-bar";

    const fileInput = document.createElement("input");
    fileInput.type = "file";
    fileInput.id = idOf("file");
    fileInput.accept = "*/*";
    fileInput.multiple = true;
    fileInput.style.display = "none";

    const attachBtn = _button(idOf("attach"), "composer-attach", "tooltip.attach", ICON_ATTACH);
    const slashBtn = _button(idOf("slash"), "composer-slash", "tooltip.slash", ICON_SLASH);

    const input = document.createElement("div");
    input.id = idOf("input");
    input.className = "composer-input";
    input.contentEditable = "true";
    input.setAttribute("role", "textbox");
    input.setAttribute("aria-multiline", "true");

    const sendBtn = document.createElement("button");
    sendBtn.type = "button";
    sendBtn.id = idOf("send");
    sendBtn.className = "composer-send";
    sendBtn.title = "Send message";
    sendBtn.setAttribute("data-i18n-title", "chat.btn.sendTitle");
    sendBtn.innerHTML = ICON_SEND;

    const stopBtn = document.createElement("button");
    stopBtn.type = "button";
    stopBtn.id = idOf("stop");
    stopBtn.className = "composer-stop";
    stopBtn.title = "Stop";
    stopBtn.setAttribute("data-i18n-title", "chat.btn.stopTitle");
    stopBtn.innerHTML = ICON_STOP;
    stopBtn.hidden = true;

    bar.appendChild(fileInput);
    bar.appendChild(attachBtn);
    if (options.slash !== false) bar.appendChild(slashBtn);
    bar.appendChild(input);
    if (options.behavior) bar.appendChild(options.behavior);
    bar.appendChild(sendBtn);
    bar.appendChild(stopBtn);

    card.appendChild(strip);
    card.appendChild(bar);
    mount.appendChild(card);

    // A caller-supplied menu lives outside the bar in the page markup; moving
    // it in keeps its absolute positioning relative to the composer.
    const behaviorMenu = options.behaviorMenu
      ? (typeof options.behaviorMenu === "string"
          ? document.getElementById(options.behaviorMenu)
          : options.behaviorMenu)
      : null;
    if (behaviorMenu) bar.appendChild(behaviorMenu);

    if (typeof I18n !== "undefined" && I18n.applyAll) I18n.applyAll();
    if (options.placeholder != null) setPlaceholder(options.placeholder);

    // ── State ──────────────────────────────────────────────────────────────
    let images = [];
    let files = [];
    let imageSeq = 0;

    // ── Attachments ────────────────────────────────────────────────────────
    function _addImageFile(file) {
      if (!ACCEPTED_IMAGE_TYPES.includes(file.type)) {
        alert(I18n.t("chat.file.unsupportedType", { type: file.type }));
        return;
      }
      if (file.size > MAX_IMAGE_SIZE) {
        alert(I18n.t("chat.file.imageTooLarge", { name: file.name, max: "5 MB" }));
        return;
      }
      const seq = ++imageSeq;
      const ext = _ext(file.name) || "png";
      _compressImage(file)
        .then((dataUrl) => {
          images.push({
            dataUrl,
            name: `IMG_${String(seq).padStart(3, "0")}.${ext}`,
            mimeType: file.type === "image/png" ? "image/png" : "image/jpeg",
            seq,
          });
          renderStrip();
          input.focus();
        })
        .catch((err) => alert(I18n.t("chat.file.processFailed", { msg: err.message })));
    }

    function _addGenericFile(file) {
      if (file.size > MAX_FILE_BYTES) {
        alert(I18n.t("chat.file.tooLarge", { name: file.name, max: "300 MB" }));
        return;
      }
      // Only the server-side path comes back — no base64 copy held in memory.
      const formData = new FormData();
      formData.append("file", file);
      fetch("/api/upload", { method: "POST", body: formData })
        .then((r) => r.json())
        .then((data) => {
          if (!data.ok) { alert(I18n.t("chat.file.uploadFailed", { msg: data.error })); return; }
          files.push({ name: data.name, path: data.path, mime_type: file.type });
          renderStrip();
          setTimeout(() => input.focus(), 100);
        })
        .catch((err) => alert(`Upload error: ${err.message}`));
    }

    function addFiles(list) {
      Array.from(list || []).forEach((file) => {
        if (ACCEPTED_IMAGE_TYPES.includes(file.type)) _addImageFile(file);
        else _addGenericFile(file);
      });
    }

    // A file the caller only knows by path (Files tab, dragged tree entry).
    function addPathFile(entry) {
      const filePath = entry && entry.path;
      if (!filePath) return false;
      const name = entry.name || filePath.split(/[\\/]/).pop();
      if (entry.size > MAX_FILE_BYTES) {
        alert(I18n.t("chat.file.tooLarge", { name, max: "300 MB" }));
        return false;
      }
      files.push({ name, path: filePath, mime_type: IMAGE_MIME_BY_EXT[_ext(name)] || "" });
      renderStrip();
      input.focus();
      return true;
    }

    function _imagePreview(item, onRemove) {
      const node = document.createElement("div");
      node.className = "img-preview-item";
      node.title = item.name;

      const thumb = document.createElement("img");
      thumb.className = "img-preview-thumb";
      thumb.src = item.dataUrl || _attachmentImageUrl(item.path);
      thumb.alt = item.name;

      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "img-preview-remove";
      remove.textContent = "✕";
      remove.title = I18n.t("tooltip.remove");
      remove.addEventListener("click", onRemove);

      node.appendChild(thumb);
      node.appendChild(remove);
      return node;
    }

    function _filePreview(file, onRemove) {
      const item = document.createElement("div");
      item.className = "pdf-preview-item pdf-preview-item--clickable";
      item.title = file.name;

      const open = document.createElement("button");
      open.type = "button";
      open.className = "pdf-preview-open";
      open.addEventListener("click", () => {
        if (file.path && window.Clacky.WorkspaceView) Clacky.WorkspaceView.openFile(file.path);
      });

      const icon = document.createElement("div");
      icon.className = "pdf-preview-icon";
      icon.innerHTML = Clacky.WorkspaceView.fileIcon(file.name || "");

      const info = document.createElement("div");
      info.className = "pdf-preview-info";
      const name = document.createElement("div");
      name.className = "pdf-preview-name";
      name.textContent = file.name;
      const type = document.createElement("div");
      type.className = "pdf-preview-type";
      type.textContent = _typeLabel(file.name);
      info.appendChild(name);
      info.appendChild(type);

      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "pdf-preview-remove";
      remove.textContent = "✕";
      remove.title = I18n.t("tooltip.remove");
      remove.addEventListener("click", onRemove);

      open.appendChild(icon);
      open.appendChild(info);
      item.appendChild(open);
      item.appendChild(remove);
      return item;
    }

    function renderStrip() {
      if (images.length === 0 && files.length === 0) {
        strip.hidden = true;
        strip.replaceChildren();
        return;
      }
      strip.hidden = false;
      const frag = document.createDocumentFragment();
      images.forEach((img, idx) => {
        frag.appendChild(_imagePreview(img, () => { images.splice(idx, 1); renderStrip(); }));
      });
      files.forEach((file, idx) => {
        const remove = () => { files.splice(idx, 1); renderStrip(); };
        frag.appendChild(
          _isImageAttachment(file.name)
            ? _imagePreview({ name: file.name, path: file.path }, remove)
            : _filePreview(file, remove)
        );
      });
      strip.replaceChildren(frag);
    }

    function getAttachments() {
      const sorted = images.slice().sort((a, b) => a.seq - b.seq);
      return [
        ...sorted.map((img) => ({
          name: img.name,
          mime_type: img.mimeType || "image/jpeg",
          data_url: img.dataUrl,
        })),
        ...files.map((f) => ({
          name: f.name,
          path: f.path,
          mime_type: f.mime_type || IMAGE_MIME_BY_EXT[_ext(f.name)] || "",
        })),
      ];
    }

    function setAttachments(list) {
      images = [];
      files = [];
      imageSeq = 0;
      (list || []).forEach((item) => {
        if (item.data_url) {
          images.push({
            dataUrl: item.data_url,
            name: item.name || "image",
            mimeType: item.mime_type || "image/jpeg",
            seq: ++imageSeq,
          });
        } else if (item.path) {
          files.push({ name: item.name || item.path, path: item.path, mime_type: item.mime_type || "" });
        }
      });
      renderStrip();
    }

    function clearAttachments() {
      images = [];
      files = [];
      imageSeq = 0;
      renderStrip();
    }

    // ── Actions ────────────────────────────────────────────────────────────
    function getValue() {
      return Composer.text(input);
    }

    function setValue(value) {
      Composer.setText(input, value || "");
    }

    function clear() {
      Composer.clear(input);
    }

    function setPlaceholder(value) {
      const text = typeof value === "function" ? value() : value;
      Composer.setPlaceholder(input, text || "");
    }

    function setRunning(running) {
      stopBtn.hidden = !running;
      sendBtn.hidden = !!running;
    }

    function submit() {
      const text = Composer.text(input).trim();
      const attachments = getAttachments();
      // Quote chips live in the input but not in its text, so a caller that
      // stages them says so explicitly.
      const extra = typeof options.hasExtra === "function" && !!options.hasExtra(input);
      if (!text && attachments.length === 0 && !extra) return false;
      if (typeof options.onSend !== "function") return false;
      options.onSend({ text, files: attachments });
      clear();
      clearAttachments();
      return true;
    }

    // ── Wiring ─────────────────────────────────────────────────────────────
    attachBtn.addEventListener("click", () => fileInput.click());
    fileInput.addEventListener("change", () => {
      addFiles(fileInput.files);
      fileInput.value = "";
    });
    sendBtn.addEventListener("click", () => submit());
    stopBtn.addEventListener("click", () => {
      if (typeof options.onStop === "function") options.onStop();
    });
    input.addEventListener("input", () => {
      if (typeof options.onInput === "function") options.onInput(Composer.text(input));
    });
    input.addEventListener("paste", (e) => {
      const items = Array.from(e.clipboardData?.items || []).filter((it) => it.kind === "file");
      if (items.length === 0) return;
      e.preventDefault();
      items.forEach((it) => {
        const file = it.getAsFile && it.getAsFile();
        if (file) addFiles([file]);
      });
    });

    if (typeof Composer !== "undefined") {
      Composer.init(input, {
        getHistory: typeof options.getHistory === "function" ? options.getHistory : undefined,
      });
      Composer.bindDropZone({
        zone: options.dropZone || card,
        input,
        onFiles: addFiles,
        onWorkspaceFile: (entry) => {
          if (typeof options.onWorkspaceFile === "function") options.onWorkspaceFile(entry, addPathFile);
        },
      });
    }

    // Both call sites route Enter through SkillAC, which also needs to win the
    // key while its menu is open — so it owns the binding there.
    if (options.enterToSend !== false) {
      IME.bindEnter(input, () => submit());
    }

    function focus() { input.focus(); }

    function destroy() {
      card.remove();
    }

    return {
      el: card, card, bar, strip, input, send: sendBtn, stop: stopBtn,
      attach: attachBtn, slash: slashBtn, fileInput,
      submit, focus, clear, getValue, setValue, setPlaceholder, setRunning,
      addFiles, addPathFile,
      getAttachments, setAttachments, clearAttachments, renderStrip,
      destroy,
    };
  }

  return { create };
})();

Clacky.ChatComposer = ChatComposer;
