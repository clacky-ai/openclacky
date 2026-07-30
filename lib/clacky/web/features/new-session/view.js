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
        badge.textContent = "EXT";
        card.appendChild(badge);
      } else if (a.source === "user") {
        const badge = document.createElement("span");
        badge.className = "agent-card-badge agent-card-badge--custom";
        badge.textContent = "custom";
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
    _renderAgentPanels();
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

  function _renderAgentPanels() {
    const box = $("new-session-agent-panels");
    if (!box) return;
    const agent = NewSessionStore.currentAgent();
    const ext = window.Clacky && Clacky.ext;
    const contrib = (agent && ext && typeof ext.contributionsForAgent === "function")
      ? ext.contributionsForAgent(agent.id)
      : null;
    const panels = (contrib && contrib.panels) || [];
    const skills = (contrib && contrib.skills) || [];
    if (!panels.length && !skills.length) {
      box.style.display = "none";
      box.replaceChildren();
      return;
    }
    const zh = _isZh();
    const label = document.createElement("span");
    label.className = "ns-panels-label";
    label.textContent = zh ? "此助手额外提供" : "This agent adds";
    box.replaceChildren(label);
    panels.forEach((p) => box.appendChild(_contribChip((zh && p.title_zh) ? p.title_zh : p.title, "panel")));
    skills.forEach((s) => box.appendChild(_contribChip((zh && s.title_zh) ? s.title_zh : s.title, "skill")));
    box.style.display = "flex";
  }

  function _contribChip(text, kind) {
    const chip = document.createElement("span");
    chip.className = `ns-panel-chip ns-panel-chip--${kind}`;
    chip.textContent = text;
    return chip;
  }

  function _updatePlaceholder() {
    const input = $("new-session-input");
    if (!input) return;
    input.placeholder = I18n.t("chat.input.placeholder");
  }

  async function _populateModels() {
    if (_modelsLoaded) return;
    const select = $("new-session-model");
    if (!select) return;
    const models = await NewSessionStore.loadModels();

    select.innerHTML = "";
    if (models.length === 0) {
      const opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "No models configured";
      select.appendChild(opt);
      _modelsLoaded = true;
      return;
    }

    models.forEach((m) => {
      const opt = document.createElement("option");
      opt.value = m.id || "";
      const typeBadge = m.type === "default" ? "[default] " : "";
      opt.textContent = `${typeBadge}${m.model} (${m.api_key_masked})`;
      if (m.type === "default") {
        opt.selected = true;
        NewSessionStore.updateAdvanced({ modelId: opt.value });
      }
      select.appendChild(opt);
    });
    _modelsLoaded = true;
  }

  async function _prefillDefaultDir() {
    const dirInput = $("new-session-directory");
    if (!dirInput || dirInput.value) return;
    const active = window.ProjectsStore && ProjectsStore.activeProject();
    if (active && active.path) {
      dirInput.value = active.path;
      NewSessionStore.updateAdvanced({ workingDir: active.path });
      return;
    }
    const home = await NewSessionStore.loadDefaultDirectory();
    if (home && !dirInput.value) {
      dirInput.value = home;
      NewSessionStore.updateAdvanced({ workingDir: home });
    }
  }

  function _updateInitProjectVisibility() {
    const field = $("new-session-init-project-field");
    if (!field) return;
    const agent = NewSessionStore.currentAgent();
    field.style.display = agent && agent.id === "coding" ? "block" : "none";
  }

  function _updateSendButton() {
    const btn = $("new-session-send");
    const input = $("new-session-input");
    if (!btn || !input) return;
    const hasText = input.value.trim().length > 0;
    const hasFiles = _pendingImages.length > 0 || _pendingFiles.length > 0;
    btn.disabled = (!hasText && !hasFiles) || NewSessionStore.state.creating;
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
  const MAX_FILE_BYTES       = 32 * 1024 * 1024;
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
      alert(I18n.t("chat.file.tooLarge", { name: file.name, max: "32 MB" }));
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

  async function _submit() {
    const input = $("new-session-input");
    if (!input) return;
    const content = input.value.trim();
    const hasFiles = _pendingImages.length > 0 || _pendingFiles.length > 0;
    if (!content && !hasFiles) return;

    const initCheckbox = $("new-session-init-project");
    const initProject = initCheckbox && initCheckbox.checked;

    const btn = $("new-session-send");
    if (btn) btn.disabled = true;

    const session = await NewSessionStore.createSession({
      existingSessions: (Sessions && Sessions.all) || [],
    });
    if (!session) {
      _updateSendButton();
      return;
    }

    const files = hasFiles ? _buildPendingFiles() : null;
    const display = hasFiles ? _buildBubbleHtml(content) : null;

    Sessions.add(session);
    Sessions.setPendingMessage(session.id, content, display, files);
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
      _updateInitProjectVisibility();
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

    const toggle = $("new-session-toggle-advanced");
    const advanced = $("new-session-advanced");
    if (toggle && advanced) {
      toggle.addEventListener("click", async () => {
        const open = advanced.hidden;
        advanced.hidden = !open;
        toggle.classList.toggle("is-open", open);
        if (open) {
          await _populateModels();
          await _prefillDefaultDir();
          requestAnimationFrame(() =>
            advanced.scrollIntoView({ behavior: "smooth", block: "end" })
          );
        }
        NewSessionStore.toggleAdvanced(open);
      });
    }

    const nameInput = $("new-session-name");
    if (nameInput) {
      nameInput.addEventListener("input", (e) =>
        NewSessionStore.updateAdvanced({ name: e.target.value })
      );
    }

    const modelSelect = $("new-session-model");
    if (modelSelect) {
      modelSelect.addEventListener("change", (e) =>
        NewSessionStore.updateAdvanced({ modelId: e.target.value })
      );
    }

    const dirInput = $("new-session-directory");
    if (dirInput) {
      dirInput.addEventListener("input", (e) =>
        NewSessionStore.updateAdvanced({ workingDir: e.target.value })
      );
    }

    const browseBtn = $("new-session-browse-btn");
    if (browseBtn && dirInput) {
      browseBtn.addEventListener("click", async () => {
        const start = dirInput.value.trim();
        const picked = await window.openDirectoryPicker(start, null);
        if (picked) {
          dirInput.value = picked;
          NewSessionStore.updateAdvanced({ workingDir: picked });
        }
      });
    }

    const initCheckbox = $("new-session-init-project");
    if (initCheckbox) {
      initCheckbox.addEventListener("change", (e) =>
        NewSessionStore.updateAdvanced({ initProject: e.target.checked })
      );
    }
  }

  async function onPanelShow() {
    _bindOnce();
    if (NewSessionStore.state.agents.length === 0) {
      await NewSessionStore.loadAgents();
    } else {
      _renderAgents();
    }
    _updateInitProjectVisibility();
    _updateSendButton();
    const input = $("new-session-input");
    if (input) input.focus();
  }

  return { onPanelShow };
})();

window.NewSessionView = NewSessionView;
