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

  let _agentName        = "";
  let _agentNamePromise = null;

  function _isZh() {
    return I18n.lang && I18n.lang().startsWith("zh");
  }

  function _loadAgentName() {
    if (_agentName) return Promise.resolve(_agentName);
    if (_agentNamePromise) return _agentNamePromise;
    _agentNamePromise = NewSessionStore.loadAgentName()
      .then(name => {
        _agentName = name || "";
        return _agentName;
      })
      .finally(() => { _agentNamePromise = null; });
    return _agentNamePromise;
  }

  function _renderTitle() {
    const el = document.querySelector(".new-session-title");
    if (!el) return;
    el.textContent = _agentName
      ? I18n.t("sessions.new.title.named", { name: _agentName })
      : I18n.t("sessions.new.title");
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

  const BUILTIN_AGENT_ICONS = {
    general: '<path d="M9.94 15.5A2 2 0 0 0 8.5 14.06l-6.14-1.58a.5.5 0 0 1 0-.96L8.5 9.94A2 2 0 0 0 9.94 8.5l1.58-6.14a.5.5 0 0 1 .96 0l1.58 6.14a2 2 0 0 0 1.44 1.44l6.14 1.58a.5.5 0 0 1 0 .96l-6.14 1.58a2 2 0 0 0-1.44 1.44l-1.58 6.14a.5.5 0 0 1-.96 0z"/><path d="M20 3v4"/><path d="M22 5h-4"/>',
    coding: '<path d="m18 16 4-4-4-4"/><path d="m6 8-4 4 4 4"/><path d="m14.5 4-5 16"/>',
    "ext-developer": '<path d="M15.39 4.39a1 1 0 0 0 1.68-.47 2.5 2.5 0 1 1 3.01 3.01 1 1 0 0 0-.47 1.68l1.68 1.68a2.41 2.41 0 0 1 0 3.42l-1.68 1.68a1 1 0 0 1-1.68-.47 2.5 2.5 0 1 0-3.01 3.01 1 1 0 0 1 .47 1.68l-1.68 1.68a2.41 2.41 0 0 1-3.42 0l-1.68-1.68a1 1 0 0 0-1.68.47 2.5 2.5 0 1 1-3.01-3.01 1 1 0 0 0 .47-1.68l-1.68-1.68a2.41 2.41 0 0 1 0-3.42L4.39 8.61a1 1 0 0 1 1.68.47 2.5 2.5 0 1 0 3.01-3.01 1 1 0 0 1-.47-1.68l1.68-1.68a2.41 2.41 0 0 1 3.42 0z"/>',
  };

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
      const builtinIcon = _isBuiltin(a) && BUILTIN_AGENT_ICONS[a.id];
      if (builtinIcon) {
        avatar.classList.add("agent-card-avatar--icon", `agent-card-avatar--${a.id}`);
        avatar.innerHTML = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">${builtinIcon}</svg>`;
      } else if (a.avatar) {
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
        Composer.setText(input, zh ? p.zh : p.en);
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
    Composer.setPlaceholder(input, I18n.t("chat.input.placeholder"));
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
    const hasContent = Composer.hasContent(input);
    const hasFiles = _pendingImages.length > 0 || _pendingFiles.length > 0;
    const initProject = NewSessionStore.state.advanced.initProject === true;
    btn.disabled = (!hasContent && !hasFiles && !initProject) || NewSessionStore.state.creating;
  }

  // ── External deep link (#new?prompt=…&agent=…) ──────────────────────────
  // Router hands the parsed link over on every welcome render. The prompt only
  // lands in the composer for the user to read — nothing here sends on its own
  // — and the notice stays until the box is cleared or the message is sent.
  let _deepLinkNotice = null;   // { kind: "normal" | "long" | "tooLong", count, max }

  function _renderDeepLinkNotice() {
    const el = $("ns-deeplink-notice");
    if (!el) return;
    if (!_deepLinkNotice) {
      el.textContent = "";
      el.style.display = "none";
      return;
    }
    const n = _deepLinkNotice;
    const key = n.kind === "tooLong" ? "newSession.deepLink.tooLong"
      : n.kind === "long" ? "newSession.deepLink.long"
      : "newSession.deepLink.fromLink";
    el.textContent = I18n.t(key, { count: n.count, max: n.max });
    el.style.display = "block";
  }

  function _applyDeepLinkPrompt(params) {
    const deep = params && params.deepLink;
    if (!deep) return;
    if (deep.tooLong) {
      // Dropped rather than truncated: a half-visible prompt invites a blind
      // Enter, which is the one thing a deep link must never cause.
      _deepLinkNotice = { kind: "tooLong", count: 0, max: deep.max };
    } else if (deep.prompt) {
      const input = $("new-session-input");
      if (!input) return;
      Composer.setText(input, deep.prompt);
      _deepLinkNotice = {
        kind: deep.long ? "long" : "normal",
        count: deep.prompt.length,
        max: deep.max,
      };
      _updateSendButton();
    }
    _renderDeepLinkNotice();
  }

  // Must run after loadAgents(): an unknown agent id is ignored and the
  // remembered default stays selected, so a bad link still opens a usable page.
  function _applyDeepLinkAgent(params) {
    const deep = params && params.deepLink;
    if (deep && deep.agent) NewSessionStore.selectAgent(deep.agent, { persist: false });
  }

  // The notice clears as soon as the composer is empty again. The "too long"
  // variant has nothing to clear, so it survives until the next navigation.
  function _syncDeepLinkNotice() {
    if (_deepLinkNotice && _deepLinkNotice.kind !== "tooLong") {
      const input = $("new-session-input");
      if (!input || !Composer.hasContent(input)) _deepLinkNotice = null;
    }
    _renderDeepLinkNotice();
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
      thumbnail.className = "img-preview-thumb";
      thumbnail.src = img.dataUrl;
      thumbnail.alt = img.name;
      const removeBtn = document.createElement("button");
      removeBtn.className = "img-preview-remove";
      removeBtn.textContent = "✕";
      removeBtn.title = I18n.t("tooltip.remove");
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
      icon.innerHTML = Clacky.WorkspaceView.fileIcon(f.name);
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
      removeBtn.title = I18n.t("tooltip.remove");
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

  function _buildBubbleHtml(content, mentionChips = []) {
    let html = content ? escapeHtml(content) : "";
    if (mentionChips.length > 0) {
      const badges = mentionChips.map((ch) => {
        const path = ch.type === "session"
          ? MentionAC.icons.message
          : (ch.type === "directory" ? MentionAC.icons.folder : MentionAC.icons.file);
        return `<span class="msg-mention-badge"><span class="msg-mention-badge-icon">${MentionAC.svgHtml(path, 13)}</span>` +
          `<span class="msg-mention-badge-name">${escapeHtml(ch.name)}</span></span>`;
      }).join(" ");
      html = badges + (html ? "<br>" + html : "");
    }
    if (_pendingImages.length > 0) {
      const thumbs = _pendingImages
        .map((img) => `<img src="${img.dataUrl}" alt="${escapeHtml(img.name)}" class="msg-image-thumb">`)
        .join("");
      html = thumbs + (html ? "<br>" + html : "");
    }
    if (_pendingFiles.length > 0) {
      const badges = _pendingFiles.map((f) => {
        const icon = Clacky.WorkspaceView.fileIcon(f.name);
        const ext  = (f.name.split(".").pop() || "file").toUpperCase();
        const tag = f.path ? "button" : "span";
        const attrs = f.path
          ? ` type="button" class="msg-pdf-badge msg-file-open" data-file-path="${encodeURIComponent(f.path)}"`
          : ` class="msg-pdf-badge"`;
        return `<${tag}${attrs}><span class="msg-pdf-badge-icon">${icon}</span>` +
          `<span class="msg-pdf-badge-info"><span class="msg-pdf-badge-name">${escapeHtml(f.name)}</span>` +
          `<span class="msg-pdf-badge-type">${escapeHtml(ext)}</span></span></${tag}>`;
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

    if (iconSvg instanceof Node) {
      chip.appendChild(iconSvg);
    } else if (iconSvg) {
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
    // Keep the popover inside the viewport when the anchor sits near the right
    // edge (narrow windows), instead of letting it run off-screen.
    if (popRect.right > window.innerWidth - 8) {
      pop.style.left = `${Math.max(8, window.innerWidth - popRect.width - 8)}px`;
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

      // "Create new project" action
      const actionSep = document.createElement("div");
      actionSep.style.cssText = "height:1px;background:var(--color-border-primary);margin:4px 8px";
      pop.appendChild(actionSep);
      const createItem = document.createElement("button");
      createItem.type = "button";
      createItem.className = "ns-ctx-popover-item";
      createItem.style.cssText = "display:flex;align-items:center;gap:6px";
      const plusIcon = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="flex-shrink:0"><path d="M12 5v14M5 12h14"/></svg>';
      createItem.innerHTML = plusIcon + `<span>${zh ? "新建项目" : "New project"}</span>`;
      createItem.addEventListener("click", async () => {
        _dismissCtxPopover();
        const project = await Projects.promptCreate();
        if (project) {
          const dir = project.working_dir || NewSessionStore.state.defaultDir || "";
          NewSessionStore.updateAdvanced({ projectId: project.id, workingDir: dir });
          _renderContextBar();
        }
      });
      pop.appendChild(createItem);
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

      ModelPicker.populate(pop, {
        models,
        currentId,
        onSelect: (m) => {
          NewSessionStore.updateAdvanced({ modelId: m.id || "" });
          _dismissCtxPopover();
          _renderContextBar();
        },
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

  // ── Branch chip popover — search, switch, create ──
  // Branches live in the project's work tree, not in the session, so switching
  // here really runs `git checkout` on the shared directory. Local branches
  // switch directly; remote ones become a tracking branch of the same name.
  function _openBranchPopover(anchor) {
    const zh = _isZh();
    const projectId = NewSessionStore.state.advanced.projectId;
    if (!projectId) return;

    let busy = false;

    _showCtxPopover(anchor, (pop) => {
      pop.classList.add("ns-branch-pop");

      const header = document.createElement("div");
      header.className = "ns-branch-search";
      header.innerHTML =
        '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
        'stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>';
      const input = document.createElement("input");
      input.type = "text";
      input.className = "ns-branch-search-input";
      input.placeholder = zh ? "搜索分支" : "Search branches";
      input.autocomplete = "off";
      input.spellcheck = false;
      header.appendChild(input);
      pop.appendChild(header);

      const list = document.createElement("div");
      list.className = "ns-branch-list";
      pop.appendChild(list);

      const foot = document.createElement("div");
      foot.className = "ns-branch-foot";
      pop.appendChild(foot);

      const _showError = (msg) => {
        Clacky.Modal.toast(msg, "error");
      };

      const _checkout = async (branch, opts = {}) => {
        if (busy) return;
        busy = true;
        list.classList.add("is-busy");
        try {
          const data = await Projects.checkoutBranch(projectId, {
            branch,
            dir: NewSessionStore.state.advanced.workingDir || "",
            ...opts,
          });
          NewSessionStore.applyGitState(data);
          _dismissCtxPopover();
        } catch (e) {
          busy = false;
          list.classList.remove("is-busy");
          _showError(_branchErrorText(e.message, zh, branch));
        }
      };

      const _branchItem = (b, label, onClick) => {
        const item = document.createElement("button");
        item.type = "button";
        item.className = "ns-ctx-popover-item ns-branch-item" + (b.current ? " active" : "");
        const icon =
          '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
          'stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="6" r="2.5"/><circle cx="6" cy="18" r="2.5"/>' +
          '<circle cx="18" cy="8" r="2.5"/><path d="M6 8.5v7"/><path d="M18 10.5c0 3-2.5 4.5-6 5"/></svg>';
        const check = b.current
          ? '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" ' +
            'stroke-linecap="round" stroke-linejoin="round"><path d="m20 6-11 11-5-5"/></svg>'
          : "";
        item.innerHTML =
          `<span class="ns-branch-item-icon">${icon}</span>` +
          `<span class="ns-branch-item-label">${_escHtml(label)}</span>` +
          `<span class="ns-branch-item-check">${check}</span>`;
        item.title = label;
        item.addEventListener("click", onClick);
        return item;
      };

      const _localName = (ref) => ref.replace(/^[^/]+\//, "");

      const renderList = () => {
        const q = input.value.trim().toLowerCase();
        const branches = NewSessionStore.state.git.branches || [];
        const local  = branches.filter(b => !b.remote && b.name.toLowerCase().includes(q));
        const remote = branches.filter(b =>  b.remote && b.name.toLowerCase().includes(q));
        const currentRef = NewSessionStore.state.git.branch;
        const localNames = new Set(branches.filter(b => !b.remote).map(b => b.name));

        list.innerHTML = "";
        list.scrollTop = 0;

        if (!local.length && !remote.length) {
          const empty = document.createElement("div");
          empty.className = "ns-ctx-popover-empty";
          empty.textContent = q
            ? (zh ? "没有匹配的分支" : "No matching branches")
            : (zh ? "暂无分支" : "No branches");
          list.appendChild(empty);
          return;
        }

        const addGroup = (title, items, toItem) => {
          if (!items.length) return;
          const label = document.createElement("div");
          label.className = "ns-branch-group";
          label.textContent = title;
          list.appendChild(label);
          items.forEach(b => list.appendChild(toItem(b)));
        };

        addGroup(zh ? "分支" : "Branches", local, (b) => {
          const isCurrent = b.name === currentRef || b.current;
          return _branchItem({ current: isCurrent }, b.name, () => {
            if (isCurrent) { _dismissCtxPopover(); return; }
            _checkout(b.name);
          });
        });

        addGroup(zh ? "远程" : "Remote", remote, (b) => {
          // A remote ref is not a thing HEAD can point at, so picking one
          // materialises a local branch of the same name (or reuses it).
          const short = _localName(b.name);
          const existsLocally = localNames.has(short);
          const item = _branchItem({ current: false }, b.name, () => {
            if (existsLocally) _checkout(short);
            else _checkout(short, { create: true, from: b.name });
          });
          item.classList.add("is-remote");
          return item;
        });
      };

      // Naming a new branch needs room for the prefix rule and validation
      // messages, so it opens in a modal instead of an inline field here.
      const createBtn = document.createElement("button");
      createBtn.type = "button";
      createBtn.className = "ns-ctx-popover-item ns-branch-create";
      createBtn.innerHTML =
        '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
        'stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12h14"/></svg>' +
        `<span>${zh ? "创建并检出分支…" : "Create and check out…"}</span>`;
      createBtn.addEventListener("click", () => {
        _dismissCtxPopover();
        _openCreateBranchModal();
      });
      foot.appendChild(createBtn);

      input.addEventListener("input", renderList);
      input.addEventListener("keydown", (e) => {
        if (e.key === "Escape") { e.preventDefault(); _dismissCtxPopover(); }
      });

      renderList();
      setTimeout(() => input.focus(), 30);
    });
  }

  // ── Create-branch modal ──
  // Mirrors `git check-ref-format --branch` locally so most mistakes are caught
  // before the round trip; git's own message is shown for anything missed.
  function _branchNameError(name, zh) {
    if (!name) return zh ? "请输入分支名称。" : "Please enter a branch name.";
    if (name.endsWith("/")) return zh ? '分支名不能以"/"结尾。' : 'Branch name cannot end with "/".';
    if (name.startsWith("/")) return zh ? '分支名不能以"/"开头。' : 'Branch name cannot start with "/".';
    if (name.startsWith("-")) return zh ? '分支名不能以"-"开头。' : 'Branch name cannot start with "-".';
    if (name.indexOf("//") !== -1) return zh ? '分支名不能包含"//"。' : 'Branch name cannot contain "//".';
    if (name.indexOf("..") !== -1) return zh ? '分支名不能包含".."。' : 'Branch name cannot contain "..".';
    if (name.endsWith(".")) return zh ? '分支名不能以"."结尾。' : 'Branch name cannot end with "."';
    if (name.endsWith(".lock")) return zh ? '分支名不能以".lock"结尾。' : 'Branch name cannot end with ".lock".';
    if (/[\s~^:?*\[\\\x00-\x1f\x7f]/.test(name)) {
      return zh
        ? "分支名不能包含空格或 ~ ^ : ? * [ \\ 等字符。"
        : "Branch name cannot contain spaces or characters like ~ ^ : ? * [ \\.";
    }
    return "";
  }

  // git reports checkout failures on stderr in English and with a file list that
  // would swamp the popover, so the common cases are rewritten for the active
  // language; anything unrecognised is passed through untouched.
  function _branchErrorText(raw, zh, branch, verb = "切换分支") {
    const msg = String(raw || "").trim();
    if (!zh) return msg || "Failed";
    if (!msg) return `${verb}失败。`;

    if (/would be overwritten by checkout|would be overwritten by merge/i.test(msg)) {
      const files = msg
        .slice(msg.indexOf(":") + 1)
        .split("\n")
        .map(line => line.trim())
        .filter(line => line && !/^(Please|error:|hint:|Aborting)/i.test(line));
      if (!files.length) return "本地有未提交的修改，切换分支会被覆盖。请先提交或暂存后再试。";
      const shown = files.slice(0, 5);
      const more  = files.length > shown.length ? `\n…（共 ${files.length} 个文件）` : "";
      return `本地有未提交的修改，切换分支会被覆盖：\n${shown.join("\n")}${more}\n请先提交或暂存后再试。`;
    }
    if (/untracked working tree files would be overwritten/i.test(msg)) {
      return "本地有未跟踪的文件会被覆盖，请先移走或提交后再试。";
    }
    if (/a branch named '.+' already exists/i.test(msg)) {
      const found = msg.match(/a branch named '(.+)' already exists/i);
      return `分支 ${found ? found[1] : branch || ""} 已存在。`;
    }
    if (/not a valid branch name/i.test(msg)) return "分支名不合法。";
    if (/couldn't find remote ref/i.test(msg)) return "远程分支不存在。";
    if (/did not match any file\(s\) known to git|pathspec .+ did not match/i.test(msg)) {
      return "找不到该分支。";
    }
    if (/not a git repository/i.test(msg)) return "该目录不是 Git 仓库。";
    if (/you need to resolve your current index first/i.test(msg)) {
      return "当前有未解决的合并冲突，请先处理后再切换分支。";
    }
    return `${verb}失败：${msg}`;
  }

  function _openCreateBranchModal() {
    const zh = _isZh();
    const projectId = NewSessionStore.state.advanced.projectId;
    if (!projectId) return;

    let prefix = "";
    let busy = false;

    const overlay = document.createElement("div");
    overlay.className = "modal-overlay";
    overlay.innerHTML =
      '<div class="modal-box sm ns-branch-modal" role="dialog" aria-modal="true">' +
        '<div class="modal-header">' +
          `<h3 class="modal-title">${zh ? "创建并检出分支" : "Create and check out branch"}</h3>` +
          '<button type="button" class="modal-close-btn ns-branch-modal-close" aria-label="Close"></button>' +
        "</div>" +
        '<div class="modal-body">' +
          '<div class="modal-field">' +
            '<div class="ns-branch-field-head">' +
              `<span class="modal-label">${zh ? "分支名称" : "Branch name"}</span>` +
              `<button type="button" class="ns-branch-prefix-btn">${zh ? "设置前缀" : "Set prefix"}</button>` +
            "</div>" +
            '<div class="ns-branch-name-row">' +
              '<span class="ns-branch-prefix-chip" hidden></span>' +
              '<input type="text" class="ns-branch-name-input" autocomplete="off" spellcheck="false"' +
              ` aria-label="${zh ? "分支名称" : "Branch name"}"` +
              ` placeholder="${zh ? "例如 feature/login" : "e.g. feature/login"}">` +
            "</div>" +
            '<div class="ns-branch-modal-error" hidden></div>' +
          "</div>" +
        "</div>" +
        '<div class="modal-footer">' +
          `<button type="button" class="btn-secondary ns-branch-modal-cancel">${zh ? "关闭" : "Close"}</button>` +
          `<button type="button" class="btn-primary ns-branch-modal-submit">${zh ? "创建并检出" : "Create and check out"}</button>` +
        "</div>" +
      "</div>";
    document.body.appendChild(overlay);

    const input = overlay.querySelector(".ns-branch-name-input");
    const prefixChip = overlay.querySelector(".ns-branch-prefix-chip");
    const prefixBtn = overlay.querySelector(".ns-branch-prefix-btn");
    const nameRow = overlay.querySelector(".ns-branch-name-row");
    const errorEl = overlay.querySelector(".ns-branch-modal-error");
    const submitBtn = overlay.querySelector(".ns-branch-modal-submit");
    const cancelBtn = overlay.querySelector(".ns-branch-modal-cancel");
    const closeBtn = overlay.querySelector(".ns-branch-modal-close");

    const fullName = () => (prefix + input.value.trim()).trim();

    const setError = (msg) => {
      errorEl.textContent = msg;
      errorEl.hidden = !msg;
      nameRow.classList.toggle("is-invalid", !!msg);
    };

    const sync = () => {
      const name = input.value.trim();
      prefixChip.hidden = !prefix;
      prefixChip.textContent = prefix;
      prefixBtn.textContent = prefix
        ? (zh ? "取消前缀" : "Clear prefix")
        : (zh ? "设置前缀" : "Set prefix");
      prefixBtn.disabled = busy || (!prefix && !name);
      submitBtn.disabled = busy || !name;
      setError(name ? _branchNameError(fullName(), zh) : "");
    };

    const close = () => {
      unbindEnter();
      document.removeEventListener("keydown", onKeydown);
      overlay.remove();
    };

    const onKeydown = (e) => {
      if (e.key === "Escape") { e.preventDefault(); close(); }
    };

    const submit = async () => {
      if (busy) return;
      const branch = fullName();
      const err = _branchNameError(branch, zh);
      if (err) { setError(err); input.focus(); return; }

      busy = true;
      const label = submitBtn.textContent;
      submitBtn.textContent = zh ? "创建中…" : "Creating…";
      sync();
      try {
        const data = await Projects.checkoutBranch(projectId, {
          branch,
          create: true,
          dir: NewSessionStore.state.advanced.workingDir || "",
        });
        NewSessionStore.applyGitState(data);
        close();
      } catch (e) {
        busy = false;
        submitBtn.textContent = label;
        sync();
        setError(_branchErrorText(e.message, zh, branch, "创建分支"));
      }
    };

    prefixBtn.addEventListener("click", () => {
      const name = input.value.trim();
      if (prefix) {
        input.value = prefix + name;
        prefix = "";
      } else {
        if (!name) return;
        const cut = name.lastIndexOf("/");
        if (cut > 0) {
          prefix = name.slice(0, cut + 1);
          input.value = name.slice(cut + 1);
        } else {
          prefix = name + "/";
          input.value = "";
        }
      }
      input.focus();
      sync();
    });

    input.addEventListener("input", sync);
    overlay.addEventListener("mousedown", (e) => { if (e.target === overlay) close(); });
    submitBtn.addEventListener("click", submit);
    cancelBtn.addEventListener("click", close);
    closeBtn.addEventListener("click", close);
    document.addEventListener("keydown", onKeydown);
    const unbindEnter = IME.bindEnter(input, submit);

    sync();
    setTimeout(() => input.focus(), 50);
  }

  // ── Render context bar ──
  // Chips are created once and updated in place. Rebuilding the row on every
  // store event made it flash during a project switch: the branch chip dropped
  // out until git info arrived, which shoved the model and init chips sideways,
  // and the row was repainted two or three times per switch.
  const CTX_CHIP_ORDER = ["name", "project", "dir", "branch", "model", "init"];

  const _ctxSvg = (body) =>
    `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;

  const CTX_ICONS = {
    name: _ctxSvg(`<path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/>`),
    project: _ctxSvg(`<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>`),
    dir: _ctxSvg(`<rect width="18" height="18" x="3" y="3" rx="2"/><path d="m7 11 2-2-2-2"/><path d="M11 13h4"/>`),
    branch: _ctxSvg(`<circle cx="6" cy="6" r="2.5"/><circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="8" r="2.5"/><path d="M6 8.5v7"/><path d="M18 10.5c0 3-2.5 4.5-6 5"/>`),
    model: _ctxSvg(`<path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"/><path d="m3.3 7 8.7 5 8.7-5"/><path d="M12 22V12"/>`),
    init: _ctxSvg(`<polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>`),
  };

  let _ctxChips = null;

  function _setChipLabel(chip, label) {
    const text = chip.querySelector(".ns-ctx-chip-label");
    if (text && text.textContent !== label) text.textContent = label;
  }

  function _setChipIcon(chip, icon, cacheKey) {
    if (!icon) return;
    if (cacheKey && chip.dataset.iconKey === cacheKey) return;
    const slot = chip.querySelector(".ns-ctx-chip-icon");
    if (slot) {
      if (icon instanceof Node) {
        slot.innerHTML = "";
        slot.appendChild(icon);
        slot.classList.add("ns-ctx-chip-icon--badge");
      } else if (slot.innerHTML !== icon) {
        slot.innerHTML = icon;
        slot.classList.remove("ns-ctx-chip-icon--badge");
      }
    }
    if (cacheKey) chip.dataset.iconKey = cacheKey;
  }

  function _ensureCtxChips(bar) {
    if (_ctxChips && _ctxChips.name.parentElement === bar) return _ctxChips;
    bar.innerHTML = "";
    _ctxChips = {};
    CTX_CHIP_ORDER.forEach((role) => {
      const onClick = {
        name: _openNamePopover,
        project: _openProjectPopover,
        dir: _openDirPopover,
        branch: _openBranchPopover,
        model: _openModelPopover,
        init: _toggleInitProject,
      }[role];
      const chip = _makeChip(CTX_ICONS[role], "", onClick);
      chip.dataset.ctxRole = role;
      _ctxChips[role] = chip;
      bar.appendChild(chip);
    });
    _ctxChips.branch.id = "ns-chip-branch";
    return _ctxChips;
  }

  function _renderContextBar() {
    const bar = $("ns-context-bar");
    if (!bar) return;
    const chips = _ensureCtxChips(bar);

    const zh = _isZh();
    const agent = NewSessionStore.currentAgent();
    const adv   = NewSessionStore.state.advanced;

    // Session name chip — leads the bar: naming the session is the first thing
    // people do here, and every other chip is a setting they rarely touch.
    const nameVal = adv.name || "";
    _setChipLabel(chips.name, nameVal || (zh ? "会话名称" : "Name"));
    chips.name.classList.toggle("ns-ctx-chip--muted", !nameVal);

    // Project chip
    const projectId = adv.projectId;
    const project = projectId && typeof Projects !== "undefined" && Projects.find
      ? Projects.find(projectId)
      : null;
    _setChipLabel(chips.project, project ? project.name : (zh ? "选择项目" : "Project"));
    chips.project.classList.toggle("ns-ctx-chip--muted", !projectId);

    // Working dir chip — a terminal, not a folder: the folder glyph is already
    // the project chip's, and two folders in a row read as the same thing.
    const dirVal = adv.workingDir || "";
    const dirShort = dirVal
      ? dirVal.replace(/^.*[\/]([^\/]+[\/][^\/]*)$/, "$1").replace(/^.*[\/]/, "").slice(-32)
      : "";
    _setChipLabel(chips.dir, dirShort || (zh ? "工作目录" : "Directory"));
    chips.dir.classList.toggle("ns-ctx-chip--muted", !dirVal);

    // Branch chip — coding agent on a git-backed project. The work tree's
    // branch is shared state, and the session's working dir can point at a
    // different repo than the project's, so the key is project + dir.
    const showBranch = !!(agent && agent.id === "coding" && projectId);
    const git = NewSessionStore.state.git || {};
    const gitKey = showBranch ? NewSessionStore.gitKey(projectId, dirVal) : "";
    const gitKnown = showBranch && git.loaded && git.key === gitKey;

    if (showBranch && !gitKnown && !git.loading) {
      NewSessionStore.loadGitInfo(projectId, { dir: dirVal });
    }

    // Only a confirmed non-repo hides the chip; while loading it stays in place
    // so the chips after it don't shift.
    chips.branch.hidden = !showBranch || (gitKnown && !git.repo);
    if (showBranch) {
      // Keep the previous branch name while a switch is in flight — swapping in
      // a placeholder and then the real name reads as two separate flickers.
      const branchLabel = gitKnown
        ? (git.branch || (zh ? "分支" : "Branch"))
        : (chips.branch.querySelector(".ns-ctx-chip-label").textContent || (zh ? "分支" : "Branch"));
      _setChipLabel(chips.branch, branchLabel);
      chips.branch.classList.toggle("ns-ctx-chip--muted", !gitKnown || !git.branch);
      chips.branch.title = gitKnown
        ? (zh ? "切换或创建分支" : "Switch or create a branch")
        : (zh ? "正在读取分支…" : "Loading branch…");
    }

    // Model chip — show selected model name from store (strip prefix/suffix for brevity)
    let modelLabel = zh ? "模型" : "Model";
    let modelRaw = "";
    const modelId = adv.modelId;
    if (modelId) {
      const models = NewSessionStore.state.models || [];
      const found = models.find((m) => (m.id || "") === modelId);
      if (found) {
        modelRaw = found.model || found.id || modelId;
        modelLabel = modelRaw.length > 28 ? modelRaw.slice(0, 26) + "…" : modelRaw;
      }
    }
    _setChipLabel(chips.model, modelLabel);
    _setChipIcon(
      chips.model,
      modelRaw && typeof ModelPicker !== "undefined" ? ModelPicker.vendorBadge(modelRaw) : CTX_ICONS.model,
      modelRaw || "default"
    );

    // Init project chip — only for coding agent
    const showInit = !!(agent && agent.id === "coding");
    chips.init.hidden = !showInit;
    if (showInit) {
      _setChipLabel(chips.init, zh ? "初始化项目" : "Init project");
      chips.init.classList.toggle("ns-ctx-chip--active", adv.initProject === true);
    }
  }

  async function _submit() {
    const input = $("new-session-input");
    if (!input) return;
    const content = Composer.text(input).trim();
    const mentionChips = Composer.chips(input);
    const hasFiles = _pendingImages.length > 0 || _pendingFiles.length > 0;
    const initProject = NewSessionStore.state.advanced.initProject === true;
    // Allow empty input when initProject is checked — /new will be auto-sent.
    if (!content && mentionChips.length === 0 && !hasFiles && !initProject) return;

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

    // Mention chips: file/directory references ride the files payload (agent.run
    // lists directory contents), session references ride references.
    const fileDirChips = mentionChips.filter(c => c.type === "file" || c.type === "directory");
    const references = mentionChips.map(c => {
      const ref = { type: c.type, name: c.name };
      if (c.type === "session") ref.session_id = c.session_id;
      else ref.path = c.path;
      return ref;
    });

    const files = (hasFiles || fileDirChips.length > 0)
      ? _buildPendingFiles().concat(fileDirChips.map(c => ({ name: c.name, path: c.path, reference: true })))
      : null;
    const display = (hasFiles || mentionChips.length > 0)
      ? _buildBubbleHtml(finalContent, mentionChips)
      : null;

    Sessions.add(session);
    if (session.project_id && typeof Projects !== "undefined" && Projects.expand) {
      Projects.expand(session.project_id);
    }
    Sessions.setPendingMessage(session.id, finalContent, display, files, references);
    Composer.clear(input);
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

    document.addEventListener("langchange", _renderTitle);

    NewSessionStore.on("newSession:agents-loaded", _renderAgents);
    NewSessionStore.on("newSession:selection-changed", () => {
      _renderAgents();
      _renderContextBar();
    });
    NewSessionStore.on("newSession:creating", _updateSendButton);
    NewSessionStore.on("newSession:git-changed", _renderContextBar);

    const input = $("new-session-input");
    if (input) {
      input.addEventListener("input", () => {
        _updateSendButton();
        _syncDeepLinkNotice();
      });
      // Enter-to-send + slash-command navigation are owned by SkillAC.attach().
    }

    // @ mention autocomplete — register before Composer/SkillAC so its keydown
    // stopImmediatePropagation wins over chip deletion / Enter-send.
    if (input && typeof MentionAC !== "undefined") {
      MentionAC.attach({
        input:         "new-session-input",
        menu:          "ns-mention-autocomplete",
        getWorkingDir: () => NewSessionStore.state.advanced.workingDir || "",
      });
    }
    // contenteditable composer: chip deletion, plain-text paste, Shift+Enter.
    if (input) Composer.init(input);

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
    Composer.bindDropZone({
      zone: $("welcome"),
      input,
      onFiles: files => files.forEach(_addAttachmentFile),
    });

    const sendBtn = $("new-session-send");
    if (sendBtn) sendBtn.addEventListener("click", _submit);

    // Context bar: load models eagerly, then render chips. The working-dir
    // prefill happens in onPanelShow() instead, so it runs after loadAgents()
    // restores the remembered project from localStorage.
    _populateModels().then(() => _renderContextBar());
  }

  async function onPanelShow(params) {
    _bindOnce();
    _syncDeepLinkNotice();
    _applyDeepLinkPrompt(params);
    _loadAgentName().then(_renderTitle);
    await NewSessionStore.loadAgents();
    _applyDeepLinkAgent(params);
    // Must run after loadAgents(): that call restores the remembered
    // projectId from localStorage, which decides whether the working dir is
    // prefilled from the project or from the global default.
    await _prefillDefaultDir();
    // Another session may have switched the work tree's branch while this page
    // was hidden, so the cached value is refreshed on every show.
    await NewSessionStore.loadGitInfo(NewSessionStore.state.advanced.projectId, {
      dir: NewSessionStore.state.advanced.workingDir || "",
      force: true,
    });
    _renderContextBar();
    _updateSendButton();
    const input = $("new-session-input");
    if (input) input.focus();
  }

  return { onPanelShow };
})();

window.NewSessionView = NewSessionView;
