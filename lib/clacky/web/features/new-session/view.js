// ── NewSession · view — landing page for #new ─────────────────────────────
//
// Renders the "start a new session" page: agent card grid, first-message
// composer, and the collapsible advanced-options section (name / model /
// working dir / init-project). Reads state from NewSessionStore and delegates
// I/O to it. On send, creates a session then hands off to Sessions.select()
// with a pending first message so the existing chat pipeline handles delivery.
//
// Depends on: NewSessionStore, Sessions, I18n, Router.
// ───────────────────────────────────────────────────────────────────────────

const NewSessionView = (() => {
  const $ = (id) => document.getElementById(id);

  let _initialized = false;
  let _modelsLoaded = false;

  function _isZh() {
    return I18n.lang && I18n.lang().startsWith("zh");
  }

  function _agentLabel(a) {
    if (_isZh() && a.title_zh) return a.title_zh;
    return a.title || a.id;
  }

  function _agentDesc(a) {
    if (_isZh() && a.description_zh) return a.description_zh;
    return a.description || "";
  }

  const LS_SEEN_AGENTS_KEY = "openclacky.newSession.seenAgents";

  function _seenAgents() {
    try {
      const raw = localStorage.getItem(LS_SEEN_AGENTS_KEY);
      return raw ? JSON.parse(raw) : [];
    } catch (e) {
      return [];
    }
  }

  function _markAgentSeen(id) {
    if (!id) return;
    const seen = _seenAgents();
    if (seen.includes(id)) return;
    seen.push(id);
    try { localStorage.setItem(LS_SEEN_AGENTS_KEY, JSON.stringify(seen)); } catch (e) { /* ignore */ }
  }

  // Builtin agents (general/coding/ext-studio) ship with the app and are not
  // "extensions" from the user's point of view — no EXT badge, never NEW.
  function _isBuiltin(a) {
    return a.layer === "builtin";
  }

  function _isNewAgent(a) {
    if (_isBuiltin(a) || a.source === "user") return false;
    return !_seenAgents().includes(a.id);
  }

  function _renderAgents() {
    const container = $("new-session-agents");
    if (!container) return;
    const agents = NewSessionStore.state.agents;
    const selected = NewSessionStore.state.selectedAgentId;

    container.innerHTML = "";
    agents.forEach((a) => {
      const card = document.createElement("button");
      card.type = "button";
      card.className = "agent-card" + (a.id === selected ? " agent-card--selected" : "");
      card.dataset.agentId = a.id;

      const header = document.createElement("div");
      header.className = "agent-card-header";

      const avatar = document.createElement("div");
      avatar.className = "agent-card-avatar";
      if (a.avatar) {
        const img = document.createElement("img");
        img.src = a.avatar;
        img.alt = "";
        img.loading = "lazy";
        avatar.appendChild(img);
      } else {
        avatar.classList.add("agent-card-avatar--fallback");
        avatar.textContent = (_agentLabel(a) || "?").trim().charAt(0).toUpperCase();
      }
      header.appendChild(avatar);

      const title = document.createElement("div");
      title.className = "agent-card-title";
      title.textContent = _agentLabel(a);
      if (_isNewAgent(a)) {
        const isNew = document.createElement("span");
        isNew.className = "agent-card-new";
        isNew.textContent = "NEW";
        title.appendChild(isNew);
      }
      header.appendChild(title);
      card.appendChild(header);

      const descText = _agentDesc(a);
      if (descText) {
        const desc = document.createElement("div");
        desc.className = "agent-card-desc";
        desc.textContent = descText;
        card.appendChild(desc);
      }

      const author = (a.author || "").trim();
      if (author && !_isBuiltin(a)) {
        const by = document.createElement("div");
        by.className = "agent-card-author";
        by.textContent = _isZh() ? `作者 ${author}` : `by ${author}`;
        card.appendChild(by);
      }

      if (!_isBuiltin(a) && a.source === "extension") {
        const badge = document.createElement("span");
        badge.className = "agent-card-badge";
        badge.textContent = _isZh() ? "扩展" : "EXT";
        card.appendChild(badge);
      } else if (a.source === "user") {
        const badge = document.createElement("span");
        badge.className = "agent-card-badge agent-card-badge--custom";
        badge.textContent = _isZh() ? "自定义" : "Custom";
        card.appendChild(badge);
      }

      card.addEventListener("click", () => {
        _markAgentSeen(a.id);
        NewSessionStore.selectAgent(a.id);
        _renderAgents();
      });
      container.appendChild(card);
    });

    _updatePlaceholder();
    _renderStarterPrompts();
  }

  // ── Starter prompts ────────────────────────────────────────────────────
  // Hardcoded UI hints per agent id. These are purely presentational and
  // help users discover what to ask without needing to think from scratch.
  const STARTER_PROMPTS = {
    "ext-developer": [
      {
        en: "Help me build a Xiaohongshu content publishing extension, with a custom panel in the right sidebar",
        zh: "帮我开发一个小红书内容发布管理扩展，在会话右侧边栏添加一个自定义面板",
      },
      {
        en: "I want to build a GitHub PR review assistant extension that auto-analyzes code changes, with an entry in the bottom-left sidebar",
        zh: "我想做一个 GitHub PR 审查助手扩展，自动分析代码变更，入口放在左底部侧边栏",
      },
      {
        en: "Help me build a Pomodoro + task tracking extension with a left sidebar entry and custom Agent",
        zh: "帮我开发一个番茄钟 + 任务追踪扩展，带左侧边栏访问入口和自定义 Agent",
      },
    ],
  };

  function _renderStarterPrompts() {
    const container = $("new-session-starter-prompts");
    if (!container) return;
    const agent = NewSessionStore.currentAgent();
    const prompts = agent && STARTER_PROMPTS[agent.id];
    if (!prompts || !prompts.length) {
      container.style.display = "none";
      container.replaceChildren();
      return;
    }

    const zh = _isZh();
    container.replaceChildren();

    const label = document.createElement("div");
    label.className = "ns-starter-label";
    label.textContent = I18n.t("sessions.new.tryAsking");
    container.appendChild(label);

    const list = document.createElement("div");
    list.className = "ns-starter-list";
    prompts.forEach((p) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "ns-starter-item";
      const text = zh ? p.zh : p.en;
      btn.textContent = "\u201c" + text + "\u201d";
      btn.addEventListener("click", () => {
        const input = $("new-session-input");
        if (!input) return;
        input.value = zh ? p.zh : p.en;
        input.focus();
        _updateSendButton();
      });
      list.appendChild(btn);
    });
    container.appendChild(list);
    container.style.display = "block";
  }

  function _updatePlaceholder() {
    const input = $("new-session-input");
    if (!input) return;
    input.placeholder = I18n.t("chat.input.placeholder");
  }

  async function _populateModels() {
    if (_modelsLoaded) return;
    const models = await NewSessionStore.loadModels();
    _modelsLoaded = true;

    // Set default modelId in store if not already set
    if (!NewSessionStore.state.advanced.modelId) {
      const def = models.find((m) => m.type === "default") || models[0];
      if (def) NewSessionStore.updateAdvanced({ modelId: def.id || "" });
    }
    _renderContextBar();
  }

  async function _prefillDefaultDir() {
    if (NewSessionStore.state.advanced.workingDir) return;  // already set
    // When a project is selected (possibly restored from localStorage by
    // loadAgents), prefer its working directory over the global default so
    // the new session lands in the project's folder — same behavior as
    // picking the project explicitly from the context bar popover.
    const project = typeof Projects !== "undefined" && Projects.find
      ? Projects.find(NewSessionStore.state.advanced.projectId)
      : null;
    if (project && project.working_dir) {
      NewSessionStore.updateAdvanced({ workingDir: project.working_dir });
      _renderContextBar();
      return;
    }
    const home = await NewSessionStore.loadDefaultDirectory();
    if (home) {
      NewSessionStore.updateAdvanced({ workingDir: home });
      _renderContextBar();
    }
  }

  function _updateSendButton() {
    const btn = $("new-session-send");
    const input = $("new-session-input");
    if (!btn || !input) return;
    const hasText = input.value.trim().length > 0;
    const hasFiles = _pendingImages.length > 0 || _pendingFiles.length > 0;
    const initProject = NewSessionStore.state.advanced.initProject === true;
    btn.disabled = (!hasText && !hasFiles && !initProject) || NewSessionStore.state.creating;
  }

  // ── Attachments (image compression + generic file upload) ───────────────
  // A trimmed mirror of the chat composer's pipeline (sessions.js). New-session
  // has no live session, so attachments are staged here and handed to the chat
  // pipeline as a pending message once the session is created & subscribed.
  const _pendingImages = [];
  const _pendingFiles  = [];
  let   _imageSeq      = 0;
  const MAX_IMAGE_SIZE       = 5 * 1024 * 1024;
  const MAX_IMAGE_BYTES_SEND = 512 * 1024;
  const MAX_IMAGE_LONG_EDGE  = 1920;
  const MAX_FILE_BYTES       = 300 * 1024 * 1024;
  const ACCEPTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];

  function _docTypeIcon(mimeType, filename) {
    const lower = (filename || "").toLowerCase();
    if (mimeType === "application/pdf" || lower.endsWith(".pdf")) return "📄";
    if (mimeType === "application/zip" || lower.endsWith(".zip")) return "🗜️";
    if (lower.endsWith(".tar") || lower.endsWith(".gz") || lower.endsWith(".tgz") ||
        lower.endsWith(".tar.gz") || lower.endsWith(".rar") || lower.endsWith(".7z")) return "🗜️";
    if ((mimeType && mimeType.includes("wordprocessingml")) || lower.endsWith(".doc") || lower.endsWith(".docx")) return "📝";
    if ((mimeType && mimeType.includes("spreadsheetml")) || lower.endsWith(".xls") || lower.endsWith(".xlsx")) return "📊";
    if ((mimeType && mimeType.includes("presentationml")) || lower.endsWith(".ppt") || lower.endsWith(".pptx")) return "📋";
    if (mimeType === "text/csv" || lower.endsWith(".csv")) return "📊";
    if (lower.endsWith(".md") || lower.endsWith(".markdown")) return "📝";
    return "📎";
  }

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
            width  = Math.round(width * ratio);
            height = Math.round(height * ratio);
          }
          const canvas = document.createElement("canvas");
          canvas.width = width;
          canvas.height = height;
          const ctx = canvas.getContext("2d");
          ctx.drawImage(img, 0, 0, width, height);
          const isPNG = file.type === "image/png";
          if (isPNG) {
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
          } else {
            let quality = 0.85;
            let dataUrl = canvas.toDataURL("image/jpeg", quality);
            while (dataUrl.length * 0.75 > MAX_IMAGE_BYTES_SEND && quality > 0.2) {
              quality -= 0.1;
              dataUrl = canvas.toDataURL("image/jpeg", quality);
            }
            resolve(dataUrl);
          }
        };
        img.src = e.target.result;
      };
      reader.readAsDataURL(file);
    });
  }

  function _addImageFile(file) {
    if (file.size > MAX_IMAGE_SIZE) {
      alert(I18n.t("chat.file.imageTooLarge", { name: file.name, max: "5 MB" }));
      return;
    }
    const seq = ++_imageSeq;
    const ext = (file.name.split(".").pop() || "png").toLowerCase();
    const displayName = `IMG_${String(seq).padStart(3, "0")}.${ext}`;
    _compressImage(file)
      .then((dataUrl) => {
        _pendingImages.push({ dataUrl, name: displayName, mimeType: file.type === "image/png" ? "image/png" : "image/jpeg", seq });
        _renderAttachmentPreviews();
      })
      .catch((err) => alert(I18n.t("chat.file.processFailed", { msg: err.message })));
  }

  function _addGenericFile(file) {
    if (file.size > MAX_FILE_BYTES) {
      alert(I18n.t("chat.file.tooLarge", { name: file.name, max: "300 MB" }));
      return;
    }
    const formData = new FormData();
    formData.append("file", file);
    fetch("/api/upload", { method: "POST", body: formData })
      .then((r) => r.json())
      .then((data) => {
        if (!data.ok) { alert(I18n.t("chat.file.uploadFailed", { msg: data.error })); return; }
        _pendingFiles.push({ name: data.name, path: data.path, mime_type: file.type });
        _renderAttachmentPreviews();
      })
      .catch((err) => alert(`Upload error: ${err.message}`));
  }

  function _addAttachmentFile(file) {
    if (file && ACCEPTED_IMAGE_TYPES.includes(file.type)) _addImageFile(file);
    else _addGenericFile(file);
  }

  function _renderAttachmentPreviews() {
    const strip = $("ns-image-preview-strip");
    if (!strip) return;
    strip.innerHTML = "";
    const hasContent = _pendingImages.length > 0 || _pendingFiles.length > 0;
    strip.style.display = hasContent ? "flex" : "none";
    _updateSendButton();
    if (!hasContent) return;

    _pendingImages.forEach((img, idx) => {
      const item = document.createElement("div");
      item.className = "img-preview-item";
      item.title = img.name;
      const thumbnail = document.createElement("img");
      thumbnail.src = img.dataUrl;
      thumbnail.alt = img.name;
      const removeBtn = document.createElement("button");
      removeBtn.className = "img-preview-remove";
      removeBtn.textContent = "✕";
      removeBtn.title = "Remove";
      removeBtn.addEventListener("click", () => { _pendingImages.splice(idx, 1); _renderAttachmentPreviews(); });
      item.appendChild(thumbnail);
      item.appendChild(removeBtn);
      strip.appendChild(item);
    });

    _pendingFiles.forEach((f, idx) => {
      const item = document.createElement("div");
      item.className = "pdf-preview-item";
      item.title = f.name;
      const icon = document.createElement("div");
      icon.className = "pdf-preview-icon";
      icon.textContent = _docTypeIcon(f.mime_type, f.name);
      const info = document.createElement("div");
      info.className = "pdf-preview-info";
      const name = document.createElement("div");
      name.className = "pdf-preview-name";
      name.textContent = f.name;
      const typeLabel = document.createElement("div");
      typeLabel.className = "pdf-preview-type";
      typeLabel.textContent = (f.name.split(".").pop() || "file").toUpperCase();
      info.appendChild(name);
      info.appendChild(typeLabel);
      const removeBtn = document.createElement("button");
      removeBtn.className = "pdf-preview-remove";
      removeBtn.textContent = "✕";
      removeBtn.title = "Remove";
      removeBtn.addEventListener("click", () => { _pendingFiles.splice(idx, 1); _renderAttachmentPreviews(); });
      item.appendChild(icon);
      item.appendChild(info);
      item.appendChild(removeBtn);
      strip.appendChild(item);
    });
  }

  function _buildPendingFiles() {
    _pendingImages.sort((a, b) => a.seq - b.seq);
    return [
      ..._pendingImages.map((img) => ({ name: img.name, mime_type: img.mimeType || "image/jpeg", data_url: img.dataUrl })),
      ..._pendingFiles.map((f) => ({ name: f.name, path: f.path, mime_type: f.mime_type })),
    ];
  }

  function _buildBubbleHtml(content) {
    let html = content ? escapeHtml(content) : "";
    if (_pendingImages.length > 0) {
      const thumbs = _pendingImages
        .map((img) => `<img src="${img.dataUrl}" alt="${escapeHtml(img.name)}" class="msg-image-thumb">`)
        .join("");
      html = thumbs + (html ? "<br>" + html : "");
    }
    if (_pendingFiles.length > 0) {
      const badges = _pendingFiles.map((f) => {
        const icon = _docTypeIcon(f.mime_type, f.name);
        const ext  = (f.name.split(".").pop() || "file").toUpperCase();
        return `<span class="msg-pdf-badge"><span class="msg-pdf-badge-icon">${icon}</span>` +
          `<span class="msg-pdf-badge-info"><span class="msg-pdf-badge-name">${escapeHtml(f.name)}</span>` +
          `<span class="msg-pdf-badge-type">${escapeHtml(ext)}</span></span></span>`;
      }).join(" ");
      html = badges + (html ? "<br>" + html : "");
    }
    return html;
  }


  // ── Context bar (chips above the input) ──────────────────────────────────
  // Shows: Agent · Model · Working Dir · Session Name (optional)
  // Each chip opens a lightweight popover when clicked.

  let _ctxPopoverDismiss = null;

  function _dismissCtxPopover() {
    if (_ctxPopoverDismiss) { _ctxPopoverDismiss(); _ctxPopoverDismiss = null; }
  }

  function _makeChip(iconSvg, label, onClick) {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = "ns-ctx-chip";

    if (iconSvg) {
      const icon = document.createElement("span");
      icon.className = "ns-ctx-chip-icon";
      icon.innerHTML = iconSvg;
      chip.appendChild(icon);
    }

    const text = document.createElement("span");
    text.className = "ns-ctx-chip-label";
    text.textContent = label;
    chip.appendChild(text);

    chip.addEventListener("click", (e) => { e.stopPropagation(); onClick(chip); });
    return chip;
  }

  function _showCtxPopover(anchor, buildFn) {
    _dismissCtxPopover();

    const pop = document.createElement("div");
    pop.className = "ns-ctx-popover";
    buildFn(pop);

    const rect = anchor.getBoundingClientRect();
    pop.style.position = "fixed";
    pop.style.left = `${rect.left}px`;
    pop.style.top  = `${rect.bottom + 6}px`;
    document.body.appendChild(pop);

    // Flip up if overflows viewport bottom
    const popRect = pop.getBoundingClientRect();
    if (popRect.bottom > window.innerHeight - 8) {
      pop.style.top = `${rect.top - popRect.height - 6}px`;
    }

    const dismiss = (e) => {
      if (!pop.contains(e.target) && e.target !== anchor) {
        pop.remove();
        document.removeEventListener("mousedown", dismiss, true);
        _ctxPopoverDismiss = null;
      }
    };
    document.addEventListener("mousedown", dismiss, true);
    _ctxPopoverDismiss = () => {
      pop.remove();
      document.removeEventListener("mousedown", dismiss, true);
    };
    return pop;
  }

  // ── Session name chip — custom modal dialog ──
  // ── Session name chip — modal dialog (reuses standard modal classes) ──
  function _openNamePopover(_anchor) {
    const zh = _isZh();
    const current = NewSessionStore.state.advanced.name || "";

    return new Promise((resolve) => {
      const overlay = document.createElement("div");
      overlay.className = "modal-overlay";
      overlay.innerHTML = `
        <div class="modal-box sm">
          <div class="modal-header">
            <h3 class="modal-title">${zh ? "会话名称" : "Session Name"}</h3>
          </div>
          <div class="modal-body">
            <div class="modal-field">
              <label class="modal-label">
                <span>${zh ? "名称" : "Name"}</span>
              </label>
              <input type="text" class="modal-input ns-name-modal-input"
                     placeholder="${zh ? "留空自动生成" : "Leave empty to auto-generate"}"
                     autocomplete="off" spellcheck="false"
                     value="${_escHtml(current)}">
            </div>
          </div>
          <div class="modal-footer">
            <button type="button" class="btn-secondary ns-name-modal-cancel">${zh ? "取消" : "Cancel"}</button>
            <button type="button" class="btn-primary ns-name-modal-confirm">${zh ? "确定" : "OK"}</button>
          </div>
        </div>`;
      document.body.appendChild(overlay);

      const input   = overlay.querySelector(".ns-name-modal-input");
      const cancel  = overlay.querySelector(".ns-name-modal-cancel");
      const confirm = overlay.querySelector(".ns-name-modal-confirm");

      setTimeout(() => { input.focus(); input.select(); }, 50);

      const cleanup = (save) => {
        overlay.remove();
        if (save) {
          NewSessionStore.updateAdvanced({ name: input.value.trim() });
          _renderContextBar();
        }
        resolve(save ? input.value.trim() : null);
      };

      confirm.addEventListener("click", () => cleanup(true));
      cancel.addEventListener("click",  () => cleanup(false));
      overlay.addEventListener("click", (e) => { if (e.target === overlay) cleanup(false); });
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter")  cleanup(true);
        if (e.key === "Escape") cleanup(false);
      });
    });
  }

  // ── Project chip popover — list projects for selection ──
  function _openProjectPopover(anchor) {
    _showCtxPopover(anchor, (pop) => {
      const zh = _isZh();
      const projects = (typeof Projects !== "undefined" && Projects.all) ? Projects.all() : [];
      const currentId = NewSessionStore.state.advanced.projectId;

      if (!projects.length) {
        const empty = document.createElement("div");
        empty.className = "ns-ctx-popover-empty";
        empty.textContent = zh ? "暂无项目" : "No projects";
        pop.appendChild(empty);
      } else {
        projects.forEach((proj) => {
          const item = document.createElement("button");
          item.type = "button";
          item.className = "ns-ctx-popover-item" + (proj.id === currentId ? " active" : "");
          const folderIcon = `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="flex-shrink:0"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>`;
          item.innerHTML = folderIcon + `<span style="margin-left:6px">${_escHtml(proj.name)}</span>`;
          item.style.display = "flex";
          item.style.alignItems = "center";
          item.addEventListener("click", () => {
            const dir = proj.working_dir || NewSessionStore.state.defaultDir || "";
            NewSessionStore.updateAdvanced({ projectId: proj.id, workingDir: dir });
            _dismissCtxPopover();
            _renderContextBar();
          });
          pop.appendChild(item);
        });
      }

      // Separator + "No project" clear option
      if (projects.length) {
        const sep = document.createElement("div");
        sep.style.cssText = "height:1px;background:var(--color-border-primary);margin:4px 8px";
        pop.appendChild(sep);
      }
      const clearItem = document.createElement("button");
      clearItem.type = "button";
      clearItem.className = "ns-ctx-popover-item" + (!currentId ? " active" : "");
      clearItem.textContent = zh ? "不选项目" : "No project";
      clearItem.addEventListener("click", () => {
        const defaultDir = NewSessionStore.state.defaultDir || "";
        NewSessionStore.updateAdvanced({ projectId: null, workingDir: defaultDir });
        _dismissCtxPopover();
        _renderContextBar();
      });
      pop.appendChild(clearItem);
    });
  }

  function _escHtml(str) {
    return String(str || "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  // ── Model chip popover ──
  function _openModelPopover(anchor) {
    _showCtxPopover(anchor, (pop) => {
      const models = NewSessionStore.state.models || [];
      const currentId = NewSessionStore.state.advanced.modelId;

      if (!models.length) {
        const empty = document.createElement("div");
        empty.className = "ns-ctx-popover-empty";
        empty.textContent = I18n.t("sessions.modal.model");
        pop.appendChild(empty);
        return;
      }
      models.forEach((m) => {
        const isDefault = m.type === "default";
        const modelName = m.model || m.id || "";

        const item = document.createElement("button");
        item.type = "button";
        item.className = "ns-ctx-popover-item sib-model-option" + ((m.id || "") === currentId ? " active" : "");
        item.style.cssText = "display:flex;align-items:center;justify-content:space-between;gap:0.5rem;";

        const nameSpan = document.createElement("span");
        nameSpan.textContent = modelName;
        item.appendChild(nameSpan);

        if (isDefault) {
          const badge = document.createElement("span");
          badge.className = "model-badge default";
          badge.textContent = "default";
          item.appendChild(badge);
        }

        item.addEventListener("click", () => {
          NewSessionStore.updateAdvanced({ modelId: m.id || "" });
          _dismissCtxPopover();
          _renderContextBar();
        });
        pop.appendChild(item);
      });
    });
  }

  // ── Working dir chip popover ──
  async function _openDirPopover(_anchor) {
    const start = NewSessionStore.state.advanced.workingDir || "";
    const picked = await window.openDirectoryPicker(start, null);
    if (picked) {
      NewSessionStore.updateAdvanced({ workingDir: picked });
      _renderContextBar();
    }
  }

  // ── Init project chip (coding agent only) — toggle directly ──
  function _toggleInitProject(chip) {
    const newVal = !NewSessionStore.state.advanced.initProject;
    NewSessionStore.updateAdvanced({ initProject: newVal });
    chip.classList.toggle("ns-ctx-chip--active", newVal);
    _updateSendButton();
  }

  // ── Render context bar ──
  function _renderContextBar() {
    const bar = $("ns-context-bar");
    if (!bar) return;
    bar.innerHTML = "";

    const zh = _isZh();
    const agent = NewSessionStore.currentAgent();
    const adv   = NewSessionStore.state.advanced;

    // Project chip
    const projectId = adv.projectId;
    const project = projectId && typeof Projects !== "undefined" && Projects.find
      ? Projects.find(projectId)
      : null;
    const projectLabel = project
      ? project.name
      : (zh ? "选择项目" : "Project");
    const projectIcon = `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>`;
    const projectChip = _makeChip(projectIcon, projectLabel, _openProjectPopover);
    if (!projectId) projectChip.classList.add("ns-ctx-chip--muted");
    bar.appendChild(projectChip);

    // Session name chip (2nd position)
    const nameVal = adv.name || "";
    const nameLabel = nameVal || (zh ? "会话名称" : "Name");
    const nameIcon = `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/></svg>`;
    const nameChip = _makeChip(nameIcon, nameLabel, _openNamePopover);
    if (!nameVal) nameChip.classList.add("ns-ctx-chip--muted");
    bar.appendChild(nameChip);

    // Model chip — show selected model name from store (strip prefix/suffix for brevity)
    let modelLabel = zh ? "模型" : "Model";
    const modelId = adv.modelId;
    if (modelId) {
      const models = NewSessionStore.state.models || [];
      const found = models.find((m) => (m.id || "") === modelId);
      if (found) {
        const raw = found.model || found.id || modelId;
        modelLabel = raw.length > 28 ? raw.slice(0, 26) + "…" : raw;
      }
    }
    const modelIcon = `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z"/><path d="M20 3v4"/><path d="M22 5h-4"/><path d="M4 17v2"/><path d="M5 18H3"/></svg>`;
    bar.appendChild(_makeChip(modelIcon, modelLabel, _openModelPopover));

    // Working dir chip
    const dirVal = adv.workingDir || "";
    const dirShort = dirVal
      ? dirVal.replace(/^.*[\/]([^\/]+[\/][^\/]*)$/, "$1").replace(/^.*[\/]/, "").slice(-32)
      : (zh ? "工作目录" : "Directory");
    const dirIcon = `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>`;
    const dirChip = _makeChip(dirIcon, dirShort || (zh ? "工作目录" : "Directory"), _openDirPopover);
    if (!dirVal) dirChip.classList.add("ns-ctx-chip--muted");
    bar.appendChild(dirChip);

    // Init project chip — only for coding agent
    if (agent && agent.id === "coding") {
      const active = NewSessionStore.state.advanced.initProject === true;
      const initLabel = zh ? "初始化项目" : "Init project";
      const initIcon = `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>`;
      const initChip = _makeChip(initIcon, initLabel, _toggleInitProject);
      if (active) initChip.classList.add("ns-ctx-chip--active");
      bar.appendChild(initChip);
    }
  }

  async function _submit() {
    const input = $("new-session-input");
    if (!input) return;
    const content = input.value.trim();
    const hasFiles = _pendingImages.length > 0 || _pendingFiles.length > 0;
    const initProject = NewSessionStore.state.advanced.initProject === true;
    // Allow empty input when initProject is checked — /new will be auto-sent.
    if (!content && !hasFiles && !initProject) return;

    const btn = $("new-session-send");
    if (btn) btn.disabled = true;

    const session = await NewSessionStore.createSession({
      existingSessions: (Sessions && Sessions.all) || [],
    });
    if (!session) {
      _updateSendButton();
      return;
    }

    // When initProject is selected, send /new as the first message so the
    // coding agent triggers the new-project skill. If the user also typed
    // something, append it as the project description.
    const finalContent = initProject
      ? (content ? `/new\n${content}` : "/new")
      : content;
    const files = hasFiles ? _buildPendingFiles() : null;
    const display = hasFiles ? _buildBubbleHtml(finalContent) : null;

    Sessions.add(session);
    Sessions.setPendingMessage(session.id, finalContent, display, files);
    input.value = "";
    _pendingImages.length = 0;
    _pendingFiles.length = 0;
    _imageSeq = 0;
    _renderAttachmentPreviews();
    NewSessionStore.reset();

    // Hand off to the normal chat pipeline: this switches the panel, wires
    // up WS subscription, and the pending message is sent once subscribed
    // (see ws-dispatcher.js "subscribed" branch).
    Sessions.select(session.id);
  }

  function _bindOnce() {
    if (_initialized) return;
    _initialized = true;

    NewSessionStore.on("newSession:agents-loaded", _renderAgents);
    NewSessionStore.on("newSession:selection-changed", () => {
      _renderAgents();
      _renderContextBar();
    });
    NewSessionStore.on("newSession:creating", _updateSendButton);

    const input = $("new-session-input");
    if (input) {
      input.addEventListener("input", _updateSendButton);
      // Enter-to-send + slash-command navigation are owned by SkillAC.attach().
    }

    // Slash-command skill autocomplete for this composer (mirrors chat).
    if (typeof SkillAC !== "undefined" && input) {
      SkillAC.attach({
        input:     "new-session-input",
        dropdown:  "ns-skill-autocomplete",
        list:      "ns-skill-autocomplete-list",
        slashBtn:  "ns-btn-slash",
        systemChk: "ns-chk-ac-show-system-skills",
        fetchSkills: async () => {
          const agent = NewSessionStore.currentAgent();
          if (!agent) return [];
          return NewSessionStore.fetchSkillsForAgent(agent.id);
        },
        onSend: _submit,
      });
    }

    // Attachments: attach button → file picker, drag-drop, paste.
    const fileInput = $("ns-file-input");
    const attachBtn = $("ns-btn-attach");
    if (attachBtn && fileInput) {
      attachBtn.addEventListener("click", () => fileInput.click());
      fileInput.addEventListener("change", (e) => {
        Array.from(e.target.files).forEach(_addAttachmentFile);
        e.target.value = "";
      });
    }
    if (input) {
      input.addEventListener("paste", (e) => {
        const items = (e.clipboardData && e.clipboardData.items) || [];
        let handled = false;
        for (const it of items) {
          if (it.kind === "file") {
            const file = it.getAsFile();
            if (file) { _addAttachmentFile(file); handled = true; }
          }
        }
        if (handled) e.preventDefault();
      });
    }
    const composer = document.querySelector("#welcome .new-session-composer");
    if (composer) {
      composer.addEventListener("dragover", (e) => { e.preventDefault(); });
      composer.addEventListener("drop", (e) => {
        e.preventDefault();
        Array.from(e.dataTransfer.files || []).forEach(_addAttachmentFile);
      });
    }

    const sendBtn = $("new-session-send");
    if (sendBtn) sendBtn.addEventListener("click", _submit);

    // Context bar: load models eagerly, then render chips. The working-dir
    // prefill happens in onPanelShow() instead, so it runs after loadAgents()
    // restores the remembered project from localStorage.
    _populateModels().then(() => _renderContextBar());
  }

  async function onPanelShow() {
    _bindOnce();
    await NewSessionStore.loadAgents();
    // Must run after loadAgents(): that call restores the remembered
    // projectId from localStorage, which decides whether the working dir is
    // prefilled from the project or from the global default.
    await _prefillDefaultDir();
    _renderContextBar();
    _updateSendButton();
    const input = $("new-session-input");
    if (input) input.focus();
  }

  return { onPanelShow };
})();

window.NewSessionView = NewSessionView;
