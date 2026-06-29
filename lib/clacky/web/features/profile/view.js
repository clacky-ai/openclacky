// ── Profile · view — markdown render, tabs, memory cards, DOM wiring ───────
//
// Owns the safe Markdown renderer, identity/memory rendering, tab switching,
// and all DOM wiring. Reads through ProfileStore.state; load/curate/delete go
// through store actions. Confirm dialogs and alerts (UI concerns) live here.
//
// Augments the `Profile` facade with onPanelShow.
//
// Depends on: ProfileStore, I18n.
// ───────────────────────────────────────────────────────────────────────────

const ProfileView = (() => {
  let _wired   = false;
  let _activeTab = "soul";

  function $(id) { return document.getElementById(id); }

  function _t(key, args) {
    return (I18n && I18n.t) ? I18n.t(key, args) : key;
  }

  // ── Minimal safe Markdown renderer ──────────────────────────────────────
  // HTML-escapes first, so raw Markdown can never inject script/style/events.

  function _escapeHtml(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function _renderInline(text) {
    return text
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/(^|[^*])\*([^*\s][^*]*?)\*(?!\*)/g, "$1<em>$2</em>");
  }

  function _renderMarkdown(raw) {
    if (!raw || !raw.trim()) return "";
    const escaped = _escapeHtml(raw);
    const lines = escaped.split(/\r?\n/);

    const out = [];
    let listType = null;
    let paraBuf  = [];

    function flushPara() {
      if (paraBuf.length === 0) return;
      out.push("<p>" + _renderInline(paraBuf.join("<br>")) + "</p>");
      paraBuf = [];
    }
    function openList(type) {
      if (listType !== type) {
        closeList();
        out.push("<" + type + ">");
        listType = type;
      }
    }
    function closeList() {
      if (listType) { out.push("</" + listType + ">"); listType = null; }
    }

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      if (trimmed === "") { flushPara(); closeList(); continue; }

      let m;
      if ((m = trimmed.match(/^(#{1,3})\s+(.+)$/))) {
        flushPara(); closeList();
        const level = m[1].length;
        out.push(`<h${level}>` + _renderInline(m[2]) + `</h${level}>`);
        continue;
      }
      if ((m = trimmed.match(/^[-*]\s+(.+)$/))) {
        flushPara(); openList("ul");
        out.push("<li>" + _renderInline(m[1]) + "</li>");
        continue;
      }
      if ((m = trimmed.match(/^\d+\.\s+(.+)$/))) {
        flushPara(); openList("ol");
        out.push("<li>" + _renderInline(m[1]) + "</li>");
        continue;
      }
      if (listType) closeList();
      paraBuf.push(trimmed);
    }
    flushPara(); closeList();
    return out.join("\n");
  }

  function _stripFrontmatter(content) {
    if (!content || !content.startsWith("---")) return content || "";
    const m = content.match(/^---\s*\n[\s\S]*?\n---\s*\n?/);
    return m ? content.slice(m[0].length) : content;
  }

  function _humanBytes(n) {
    if (!n || n < 0) return "0 B";
    const units = ["B", "KB", "MB"];
    let i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n.toFixed(0) : n.toFixed(2)) + " " + units[i];
  }

  // ── Rendering ────────────────────────────────────────────────────────────

  function _renderIdentitySection(kind) {
    const file    = ProfileStore.state[kind];
    const wrap    = $(`profile-${kind}-body`);
    const status  = $(`profile-${kind}-status`);
    const pathEl  = $(`profile-${kind}-path`);
    if (!wrap) return;

    if (!file) {
      wrap.innerHTML = `<div class="profile-empty">${_t("profile.loadFail")}</div>`;
      if (status) { status.textContent = ""; status.className = "profile-status"; }
      if (pathEl) pathEl.textContent = "";
      return;
    }

    wrap.innerHTML = _renderMarkdown(file.content || "")
      || `<div class="profile-empty">${_t("profile.emptyContent")}</div>`;
    if (pathEl) pathEl.textContent = file.path || "";
    if (status) {
      status.textContent = file.is_default
        ? _t("profile.statusDefault")
        : _t("profile.statusCustom");
      status.className = "profile-status "
        + (file.is_default ? "profile-status-default" : "profile-status-custom");
    }
  }

  function _renderMemories() {
    const list    = $("memories-list");
    const summary = $("memories-summary");
    if (!list) return;

    const memories = ProfileStore.state.memories;
    if (summary) {
      summary.textContent = memories.length
        ? _t("memories.summary", { count: memories.length })
        : _t("memories.emptyHint");
    }

    if (memories.length === 0) {
      list.innerHTML = `<div class="profile-empty">${_t("memories.empty")}</div>`;
      return;
    }

    const openSet = new Set(
      [...list.querySelectorAll(".memory-card")]
        .filter(c => c.querySelector(".memory-card-body")?.style.display !== "none")
        .map(c => c.dataset.filename)
    );

    list.innerHTML = "";
    memories.forEach(m => list.appendChild(_buildMemoryCard(m, openSet.has(m.filename))));
  }

  function _buildMemoryCard(m, expanded = false) {
    const card = document.createElement("div");
    card.className = "memory-card";
    card.dataset.filename = m.filename;

    const topic   = m.topic || m.filename;
    const desc    = m.description || "";
    const updated = m.updated_at || "";
    const size    = _humanBytes(m.size || 0);

    const head = document.createElement("div");
    head.className = "memory-card-head";
    head.innerHTML = `
      <div class="memory-card-info">
        <div class="memory-card-title" title="${_escapeHtml(m.filename)}">${_escapeHtml(topic)}</div>
        ${desc ? `<div class="memory-card-desc">${_escapeHtml(desc)}</div>` : ""}
        <div class="memory-card-meta">
          <span class="memory-filename">${_escapeHtml(m.filename)}</span>
          <span>${_escapeHtml(updated)}</span>
          <span>${size}</span>
        </div>
      </div>
      <div class="memory-card-actions">
        <button class="btn-memory-curate" title="${_t("memories.curateTitle")}">
          <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M15 4V2"/><path d="M15 16v-2"/><path d="M8 9h2"/><path d="M20 9h2"/>
            <path d="M17.8 11.8 19 13"/><path d="M15 9h.01"/><path d="M17.8 6.2 19 5"/>
            <path d="m3 21 9-9"/><path d="M12.2 6.2 11 5"/>
          </svg>
          <span>${_t("memories.curate")}</span>
        </button>
        <button class="btn-memory-edit" title="${_t("memories.edit")}">
          <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M12 20h9"/>
            <path d="M16.5 3.5a2.121 2.121 0 1 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/>
          </svg>
          <span>${_t("memories.edit")}</span>
        </button>
        <button class="btn-memory-delete" title="${_t("memories.deleteTitle")}">
          <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="3 6 5 6 21 6"/>
            <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>
            <path d="M10 11v6"/><path d="M14 11v6"/>
            <path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/>
          </svg>
          <span>${_t("memories.delete")}</span>
        </button>
        <button class="btn-memory-expand" title="${_t("memories.expandTitle")}" aria-expanded="false">
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="6 9 12 15 18 9"/>
          </svg>
        </button>
      </div>`;
    card.appendChild(head);

    const body = document.createElement("div");
    body.className = "memory-card-body";
    body.style.display = "none";
    card.appendChild(body);

    head.querySelector(".btn-memory-edit")
      .addEventListener("click", (e) => { e.stopPropagation(); _editMemory(m); });

    head.querySelector(".btn-memory-curate")
      .addEventListener("click", (e) => { e.stopPropagation(); _curateMemory(m); });

    head.querySelector(".btn-memory-delete")
      .addEventListener("click", (e) => { e.stopPropagation(); _deleteMemory(m); });

    const expandBtn = head.querySelector(".btn-memory-expand");
    function toggle() {
      const open = body.style.display !== "none";
      if (open) {
        body.style.display = "none";
        expandBtn.setAttribute("aria-expanded", "false");
        expandBtn.classList.remove("expanded");
      } else {
        if (!body.dataset.loaded) {
          body.innerHTML = `<div class="memory-card-loading">${_t("memories.loading")}</div>`;
          Profile.fetchMemory(m.filename).then(res => {
            if (!res.ok) {
              body.innerHTML = `<div class="profile-empty">${_escapeHtml(res.error)}</div>`;
              return;
            }
            const stripped = _stripFrontmatter(res.content);
            body.innerHTML = _renderMarkdown(stripped)
              || `<div class="profile-empty">${_t("profile.emptyContent")}</div>`;
            body.dataset.loaded = "1";
          });
        }
        body.style.display = "";
        expandBtn.setAttribute("aria-expanded", "true");
        expandBtn.classList.add("expanded");
      }
    }
    expandBtn.addEventListener("click", (e) => { e.stopPropagation(); toggle(); });
    head.querySelector(".memory-card-info").addEventListener("click", toggle);

    if (expanded) toggle();

    return card;
  }

  // ── Tabs ─────────────────────────────────────────────────────────────────

  function _switchTab(tab) {
    if (!tab || tab === _activeTab) return;
    _activeTab = tab;

    document.querySelectorAll(".profile-tab").forEach(el => {
      const isActive = el.dataset.tab === tab;
      el.classList.toggle("active", isActive);
      el.setAttribute("aria-selected", isActive ? "true" : "false");
    });

    ["soul", "user", "memories"].forEach(name => {
      const pane = $(`profile-pane-${name}`);
      if (!pane) return;
      const isActive = name === tab;
      pane.classList.toggle("active", isActive);
      pane.style.display = isActive ? "" : "none";
    });
  }

  // ── Actions (UI side, delegating to store) ───────────────────────────────

  async function _curateProfile(scope) {
    const btn = $(`btn-profile-curate-${scope}`);
    if (btn) btn.disabled = true;
    try {
      await Profile.curateProfile(scope);
    } catch (e) {
      console.error("[Profile] curate profile failed", e);
      alert(_t("profile.curateFail") + ": " + e.message);
      if (btn) btn.disabled = false;
    }
  }

  async function _editMemory(m) {
    const res = await Profile.fetchMemory(m.filename);
    if (!res.ok) { alert(_t("memories.curateFail") + ": " + res.error); return; }

    CodeEditor.open({
      content: res.content,
      title: m.topic || m.filename,
      language: "markdown",
      onSave: async (newContent) => {
        const r = await Profile.updateMemory(m.filename, newContent);
        if (!r.ok) throw new Error(r.error);
        Modal.toast(_t("profile.savedOk"), "success");
      }
    });
  }

  async function _curateMemory(m) {
    try {
      await Profile.curateMemory(m);
    } catch (e) {
      console.error("[Profile] curate memory failed", e);
      alert(_t("memories.curateFail") + ": " + e.message);
    }
  }

  async function _deleteMemory(m) {
    const label = m.topic || m.filename;
    if (!confirm(_t("memories.confirmDelete", { name: label }))) return;
    const res = await Profile.deleteMemory(m.filename);
    if (!res.ok) alert(_t("memories.deleteFail") + ": " + res.error);
  }

  function _editProfile(kind) {
    const file = ProfileStore.state[kind];
    if (!file) return;

    const title = kind === "soul" ? _t("profile.whoIAm") : _t("profile.whoYouAre");

    CodeEditor.open({
      content: file.content || "",
      title,
      language: "markdown",
      onSave: async (newContent) => {
        await Profile.updateProfile(kind, newContent);
        Modal.toast(_t("profile.savedOk"), "success");
      }
    });
  }

  // ── Wiring ───────────────────────────────────────────────────────────

  function _wire() {
    if (_wired) return;
    _wired = true;

    document.querySelectorAll(".profile-tab").forEach(el => {
      el.addEventListener("click", () => _switchTab(el.dataset.tab));
    });

    const soulBtn = $("btn-profile-curate-soul");
    if (soulBtn) soulBtn.addEventListener("click", () => _curateProfile("soul"));
    const userBtn = $("btn-profile-curate-user");
    if (userBtn) userBtn.addEventListener("click", () => _curateProfile("user"));

    // Per-tab direct edit buttons
    const editSoulBtn = $("btn-profile-edit-soul");
    if (editSoulBtn) editSoulBtn.addEventListener("click", () => _editProfile("soul"));
    const editUserBtn = $("btn-profile-edit-user");
    if (editUserBtn) editUserBtn.addEventListener("click", () => _editProfile("user"));

    // Memories list reload
    const refreshMemBtn = $("btn-memories-refresh-list");
    if (refreshMemBtn) refreshMemBtn.addEventListener("click", () => Profile.loadAll());
  }

  function _renderAll() {
    _renderIdentitySection("soul");
    _renderIdentitySection("user");
    _renderMemories();
  }

  function _subscribe() {
    Profile.on("profile:changed", _renderAll);
    Profile.on("profile:memoriesChanged", _renderMemories);
  }

  const viewApi = {
    onPanelShow() {
      _wire();
      ["soul", "user"].forEach(s => {
        const b = $(`btn-profile-curate-${s}`);
        if (b) b.disabled = false;
      });
      Profile.loadAll();
    }
  };

  return { init: _subscribe, api: viewApi };
})();

Object.assign(Profile, ProfileView.api);
ProfileView.init();
