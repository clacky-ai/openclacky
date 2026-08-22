// ── SkillAC — slash-command autocomplete + composer bindings ──────────────
// NOTE: The Skills data/render module moved to features/skills/{store,view}.js.
// Only the composer-side autocomplete lives here.

// ─────────────────────────────────────────────────────────────────────────
// SkillAC — slash-command skill autocomplete dropdown + composer bindings
//
// Handles the "/xxx" slash-command autocomplete UI above the message input,
// plus all composer keyboard/composition/input DOM bindings that depend on it
// (Enter to send, / button, IME composition guard).
//
// Moved verbatim from app.js; structural changes only:
//   - `_lastCompositionEndTime` moved into the IIFE closure (was module-level)
//   - The bare DOM bindings (btn-slash, user-input keydown/input/compositionend,
//     btn-create-skill, btn-import-skill) are wrapped in a private
//     `_initDOMBindings()` function called at the end of `init()`.
//
// Depends on: Sessions (sendMessage), Skills (createInSession, toggleImportBar),
//             I18n, global $ helper.
// ─────────────────────────────────────────────────────────────────────────
const SKILL_AC_SHOW_SYSTEM_KEY = "skill-ac-show-system";
const SKILL_AC_MRU_KEY         = "skill-ac-mru";

const SkillAC = (() => {
  let _initialized    = false;
  let _visible        = false;
  let _activeIndex    = -1;
  let _items          = [];  // filtered [{ name, description, encrypted, source }]
  let _currentSession = null; // track active session id for live fetch
  let _skillsSnapshot = null; // cached user-invocable skills for slash highlight (null = not loaded)

  // Load from localStorage, default to false (hide system skills)
  let _showSystemSkills = localStorage.getItem(SKILL_AC_SHOW_SYSTEM_KEY) === "true";

  function _mruLoad() {
    try { return JSON.parse(localStorage.getItem(SKILL_AC_MRU_KEY) || "{}"); } catch { return {}; }
  }
  function _mruTouch(name) {
    const mru = _mruLoad();
    mru[name] = Date.now();
    try { localStorage.setItem(SKILL_AC_MRU_KEY, JSON.stringify(mru)); } catch {}
  }

  let _ime = null;  // IME tracker for #user-input, set up in _initDOMBindings

  // The active DOM/behavior config. Defaults to the chat composer; `attach()`
  // can swap in a different set of element ids (e.g. the new-session page).
  // `fetchSkills` returns the skill list; `onSend` fires on bare Enter.
  const _chatCfg = {
    input:     "user-input",
    dropdown:  "skill-autocomplete",
    list:      "skill-autocomplete-list",
    slashBtn:  "btn-slash",
    systemChk: "chk-ac-show-system-skills",
    fetchSkills: null,   // null → use session-scoped default fetch
    onSend:      () => Sessions.sendMessage(),
  };
  let _cfg = _chatCfg;

  const _inputEl    = () => $(_cfg.input);
  const _dropdownEl = () => $(_cfg.dropdown);
  const _listEl     = () => $(_cfg.list);
  const _slashBtnEl = () => $(_cfg.slashBtn);

  /** Called whenever the active session changes — drop the cached skill list and
   *  refetch in the background so slash highlighting works against current data. */
  function _loadForSession(sessionId) {
    _currentSession = sessionId || null;
    _skillsSnapshot = null;
    if (_currentSession) {
      _fetchSkills().then(skills => { _skillsSnapshot = skills; }).catch(() => {});
    }
  }

  /** Fetch live skill list from server for the current session. */
  async function _fetchSkills() {
    if (_cfg.fetchSkills) {
      try {
        return (await _cfg.fetchSkills()) || [];
      } catch (e) {
        console.error("[SkillAC] custom fetchSkills failed", e);
        return [];
      }
    }
    if (!_currentSession) return [];
    try {
      const res  = await fetch(`/api/sessions/${_currentSession}/skills`);
      const data = await res.json();
      return data.skills || [];
    } catch (e) {
      console.error("[SkillAC] fetchSkills failed", e);
      return [];
    }
  }

  /** Return the /xxx prefix if the entire input is a slash command, else null. */
  function _getSlashQuery(value) {
    // Full-width slash / dunhao are already replaced in the input event handler,
    // but guard here too in case value is passed programmatically.
    let trimmed = value.replace(/^[／、]/, "/");

    // Only activate when the whole input starts with / (no leading space)
    if (!trimmed.startsWith("/")) return null;
    // Only single-word slash token — no spaces allowed after /
    if (/^\/\S*$/.test(trimmed)) return trimmed.slice(1).toLowerCase();
    return null;
  }

  /**
   * Score how well a skill matches the query string.
   * Only matches against name and name_zh — description is intentionally excluded.
   * All matches are contiguous substring matches (no fuzzy/subsequence).
   * Returns 0 if no match (should be filtered out).
   *
   * Scoring tiers:
   *   100 — name or name_zh exact match
   *    80 — name or name_zh starts-with
   *    60 — name or name_zh contains
   *     0 — no match
   */
  function _scoreMatch(skill, query) {
    if (!query) return 50; // empty query → show all with neutral score

    const q    = query.toLowerCase();
    const name = (skill.name || "").toLowerCase();
    const zh   = (skill.name_zh || "").toLowerCase();

    // Exact match
    if (name === q || zh === q) return 100;

    // Prefix match
    if (name.startsWith(q) || zh.startsWith(q)) return 80;

    // Contains match (contiguous substring)
    if (name.includes(q) || zh.includes(q)) return 60;

    return 0;
  }

  /**
   * Wrap the matching substring in <mark> for highlighting.
   * Returns an array of DOM nodes (text + mark nodes).
   */
  function _highlight(text, query) {
    if (!query) return [document.createTextNode(text)];
    const idx = text.toLowerCase().indexOf(query.toLowerCase());
    if (idx === -1) return [document.createTextNode(text)];

    const nodes = [];
    if (idx > 0) nodes.push(document.createTextNode(text.slice(0, idx)));
    const mark = document.createElement("span");
    mark.className = "skill-ac-highlight";
    mark.textContent = text.slice(idx, idx + query.length);
    nodes.push(mark);
    if (idx + query.length < text.length) {
      nodes.push(document.createTextNode(text.slice(idx + query.length)));
    }
    return nodes;
  }

  /**
   * Exact-match check: is `name` (a skill identifier) present in the cached
   * session skill snapshot? Mirrors the backend's user_invocable + agent-profile
   * filtering (the snapshot comes from /api/sessions/:id/skills, which applies
   * exactly those rules).
   */
  function _isValidCommand(name) {
    if (!name || !_skillsSnapshot) return false;
    return _skillsSnapshot.some(s => s.name === name);
  }

  /**
   * Look up the skill backing a slash command, preferring the backend's
   * authoritative identifier when one is provided (history replay / live WS).
   */
  function _findSkill(name, skillCommand) {
    if (!_skillsSnapshot) return null;
    const key = skillCommand || name;
    return _skillsSnapshot.find(s => s.name === key) || null;
  }

  /**
   * Localized label for a slash command, resolved from the cached snapshot.
   * Chinese UI prefers the skill's name_zh — same convention as the
   * autocomplete dropdown and the skills panel. Only used as a fallback when
   * the backend didn't ship a skill_command_display (optimistic renders).
   */
  function _localizedLabel(name, skillCommand) {
    const skill = _findSkill(name, skillCommand);
    if (skill && I18n.lang() === "zh" && skill.name_zh) return skill.name_zh;
    return name;
  }

  /**
   * Render a user message's text with its leading slash command highlighted.
   *
   * `skillCommand` is the authoritative skill identifier from the backend
   * (history replay / live WS event); `skillCommandDisplay` is its localized
   * display name, already resolved by the backend against the client language
   * (zh → name_zh, anything else → the identifier). When absent — optimistic
   * render before the server echoes the message back — falls back to the
   * cached snapshot, which is the same exact-match semantics as
   * parse_skill_command.
   *
   * Returns an HTML string; the caller assigns it to innerHTML.
   */
  function _renderUserMessageHtml(content, skillCommand, skillCommandDisplay) {
    const text = String(content || "");
    let result = "";
    
    // Check for slash command at the start
    const m = text.match(/^\/(\S+)/);
    if (m) {
      const token = m[0];  // "/pptx"
      const name  = m[1];  // "pptx"
      const valid = skillCommand ? name === skillCommand : _isValidCommand(name);
      if (valid) {
        const display = skillCommandDisplay || _localizedLabel(name, skillCommand);
        result += `<span class="msg-slash-cmd">${escapeHtml("/" + display)}</span>`;
        // Continue processing the rest of the text for @mentions
        const rest = text.slice(token.length);
        result += _renderFileMentions(rest);
        return result;
      }
    }
    
    // No valid slash command — just render file mentions
    return _renderFileMentions(text);
  }
  
  /** Render @filename mentions with styled tags. */
  function _renderFileMentions(text) {
    // Escape the WHOLE text first — the bubble must never execute user HTML,
    // and non-mention characters like "<" must survive verbatim.
    // (escapeHtml leaves quotes intact, so the quoted-path branch still works;
    // the matched slice is already escaped, so no double-escape here.)
    return escapeHtml(text).replace(/@("(?:[^"\\]|\\.)*"|[^\s@]+)/g, (match, filename) => {
      const cleanName = filename.startsWith('"') && filename.endsWith('"')
        ? filename.slice(1, -1)
        : filename;
      return `<span class="file-mention-tag">@${cleanName}</span>`;
    });
  }

  async function _render(query) {
    const all = await _fetchSkills();
    // Keep the highlight snapshot in sync: the dropdown is the most frequent
    // fetch point, so piggybacking here keeps it fresh after skill installs.
    _skillsSnapshot = all;

    // Score and filter
    let scored = all
      .map(s => ({ skill: s, score: _scoreMatch(s, query) }))
      .filter(({ score }) => score > 0);

    if (!_showSystemSkills) {
      scored = scored.filter(({ skill }) => skill.always_show || skill.source_type !== "default");
    }

    // Sort: score descending; same score → MRU timestamp descending; no MRU → alphabetical
    const mru = _mruLoad();
    scored.sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      const ta = mru[a.skill.name] || 0;
      const tb = mru[b.skill.name] || 0;
      if (ta !== tb) return tb - ta;
      return a.skill.name.localeCompare(b.skill.name);
    });

    _items = scored.map(({ skill }) => skill);

    const countEl = _dropdownEl().querySelector(".skill-ac-count");
    if (countEl) countEl.textContent = " (" + _items.length + ")";

    const list = _listEl();
    list.innerHTML = "";

    if (_items.length === 0) {
      // Show empty state instead of hiding the dropdown
      const emptyEl = document.createElement("div");
      emptyEl.className = "skill-ac-empty";
      emptyEl.textContent = I18n.t("skills.ac.empty");
      list.appendChild(emptyEl);
      _dropdownEl().style.display = "";
      _visible = true;
      _createOverlay();
      return;
    }

    _items.forEach((skill, idx) => {
      const item = document.createElement("div");
      item.className = "skill-ac-item" + (idx === _activeIndex ? " active" : "");
      item.setAttribute("role", "option");
      item.setAttribute("data-idx", idx);

      const nameEl = document.createElement("span");
      nameEl.className = "skill-ac-name";

      const currentLangForName = I18n.lang();
      const showZhFirst = currentLangForName === "zh" && skill.name_zh;

      if (showZhFirst) {
        // Chinese UI: /中文名 first (with slash), then english id (no slash) after
        const zhEl = document.createElement("span");
        zhEl.className = "skill-ac-name-zh";
        zhEl.appendChild(document.createTextNode("/"));
        _highlight(skill.name_zh, query).forEach(function(n) { zhEl.appendChild(n); });
        nameEl.appendChild(zhEl);

        const nameTextEl = document.createElement("span");
        nameTextEl.className = "skill-ac-name-id";
        _highlight(skill.name, query).forEach(function(n) { nameTextEl.appendChild(n); });
        nameEl.appendChild(nameTextEl);
      } else {
        // English UI (or no zh name): show /id only, no zh name
        const nameTextEl = document.createElement("span");
        nameTextEl.appendChild(document.createTextNode("/"));
        _highlight(skill.name, query).forEach(function(n) { nameTextEl.appendChild(n); });
        nameEl.appendChild(nameTextEl);
      }

      // meta: encrypted badge + source type label (subtle)
      const metaEl = document.createElement("span");
      metaEl.className = "skill-ac-meta";
      if (skill.encrypted) {
        const encBadge = document.createElement("span");
        encBadge.className = "skill-ac-enc";
        encBadge.textContent = "🔒";
        metaEl.appendChild(encBadge);
      }
      const sourceKey = {
        "default":        "skills.src.builtIn",
        "global_clacky":  "skills.src.user",
        "global_claude":  "skills.src.user",
        "project_clacky": "skills.src.project",
        "project_claude": "skills.src.project",
        "brand":          "skills.src.brand",
      }[skill.source_type];
      if (sourceKey) {
        const srcEl = document.createElement("span");
        srcEl.className = "skill-ac-src";
        srcEl.textContent = I18n.t(sourceKey);
        metaEl.appendChild(srcEl);
      }

      const descEl = document.createElement("span");
      descEl.className = "skill-ac-desc";
      // Choose description based on current language
      const description = (currentLangForName === "zh" && skill.description_zh)
                          ? skill.description_zh
                          : skill.description || "";
      descEl.textContent = description;

      item.appendChild(nameEl);
      item.appendChild(metaEl);
      item.appendChild(descEl);

      item.addEventListener("mousedown", e => {
        // mousedown fires before blur — prevent input losing focus
        e.preventDefault();
        _select(idx);
      });

      list.appendChild(item);
    });

    _dropdownEl().style.display = "";
    _visible = true;
    _createOverlay();
  }

  function _hide() {
    _dropdownEl().style.display = "none";
    _visible     = false;
    _activeIndex = -1;
    _items       = [];
    _slashBtnEl()?.classList.remove("active");
    _removeOverlay();
  }

  function _createOverlay() {
    // Remove existing overlay if any
    _removeOverlay();

    const overlay = document.createElement("div");
    overlay.id = "skill-ac-overlay";
    overlay.style.cssText = "position: fixed; top: 0; left: 0; right: 0; bottom: 0; z-index: 999; background: transparent;";

    // Click overlay to close dropdown
    overlay.addEventListener("click", () => {
      _hide();
    });

    document.body.appendChild(overlay);
  }

  function _removeOverlay() {
    const overlay = document.getElementById("skill-ac-overlay");
    if (overlay) overlay.remove();
  }

  function _select(idx) {
    const skill = _items[idx];
    if (!skill) return;
    _mruTouch(skill.name);
    const input  = _inputEl();
    input.value  = "/" + skill.name + " ";
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, 200) + "px";
    _hide();
    input.focus();
    // Route the change through a real `input` event: the composer textarea
    // paints transparent glyphs (the visible text comes from FileAC's
    // highlight layer), and that layer only re-renders on input events.
    // Without the dispatch the inserted "/skill " occupies space but stays
    // invisible until the user's next keystroke. Same pattern as
    // FileAC._selectItem. (`_getSlashQuery("/name ")` returns null because
    // of the trailing space, so this cannot re-open the dropdown.)
    input.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function _moveActive(delta) {
    if (!_visible || _items.length === 0) return;
    _activeIndex = (_activeIndex + delta + _items.length) % _items.length;
    // Re-render to apply active class
    const list  = _listEl();
    list.querySelectorAll(".skill-ac-item").forEach((el, i) => {
      el.classList.toggle("active", i === _activeIndex);
      if (i === _activeIndex) el.scrollIntoView({ block: "nearest" });
    });
  }

  /** Open the dropdown showing all skills, used by the / button. */
  async function _openAll() {
    _activeIndex = 0;  // Default to first item
    await _render("");
    _inputEl().focus();
  }

  /** Toggle the dropdown (open if hidden, close if visible). */
  async function _toggle() {
    if (_visible) {
      _hide();
    } else {
      await _openAll();
    }
  }

  // ── DOM bindings: composer keyboard/composition/input + slash button + ────
  // ── skill-panel create/import buttons. Called once from init().           ──
  function _initDOMBindings(cfg) {
    // / button: set input to "/" and open skill autocomplete.
    // mousedown + preventDefault prevents the textarea from losing focus
    // (which would trigger the blur→hide timer and immediately close
    //  the dropdown we're about to open).
    $(cfg.slashBtn).addEventListener("mousedown", e => {
      e.preventDefault();  // keep focus on the input
    });
    $(cfg.slashBtn).addEventListener("click", () => {
      _cfg = cfg;
      const input = $(cfg.input);
      if (input.value === "" || input.value === "/") {
        input.value = "/";
        input.style.height = "auto";
        input.style.height = Math.min(input.scrollHeight, 200) + "px";
        // Keep FileAC's highlight layer in sync — the textarea glyphs are
        // transparent, so without this the "/" sits invisible until the next
        // keystroke. Deliberately NOT dispatching an input event here: the
        // _toggle() below already opens the dropdown, and a dispatched event
        // would race it with a second _render()/fetch.
        if (Clacky.FileAC && typeof Clacky.FileAC.sync === "function") Clacky.FileAC.sync();
      }
      _toggle();  // Toggle dropdown instead of always opening
      if (_visible) {
        $(cfg.slashBtn).classList.add("active");
      }
      input.focus();
    });

    // IME composition tracker: shared by main keydown + AC _handleKey.
    const ime = IME.track($(cfg.input));

    // Main composer keydown: SkillAC consumes nav keys first, then Enter → send.
    $(cfg.input).addEventListener("keydown", e => {
      _cfg = cfg;
      _ime = ime;
      // Let skill autocomplete consume arrow/enter/escape first
      if (_handleKey(e)) return;

      if (e.key === "Enter" && !e.shiftKey && !ime.isComposing(e)) {
        e.preventDefault();
        cfg.onSend();
      }
    });

    // Composer input: auto-grow textarea, normalize full-width slash, drive AC.
    $(cfg.input).addEventListener("input", () => {
      _cfg = cfg;
      const el = $(cfg.input);
      el.style.height = "auto";
      el.style.height = Math.min(el.scrollHeight, 200) + "px";

      // Replace full-width slash ／ or Chinese dunhao 、 with ASCII / in-place
      if (/^[／、]/.test(el.value)) {
        const pos = el.selectionStart;
        el.value = el.value.replace(/^[／、]/, "/");
        el.setSelectionRange(pos, pos);
      }

      // Trigger skill autocomplete
      _update(el.value);
    });

    const chk = $(cfg.systemChk);
    if (chk) {
      chk.checked = _showSystemSkills;
      chk.addEventListener("change", async () => {
        _cfg = cfg;
        _showSystemSkills = chk.checked;
        localStorage.setItem(SKILL_AC_SHOW_SYSTEM_KEY, _showSystemSkills ? "true" : "false");
        if (_visible) {
          const query = _getSlashQuery($(cfg.input).value);
          if (query !== null) await _render(query);
        }
      });
    }

    // Skills panel action buttons only exist in the chat composer.
    if (cfg === _chatCfg) {
      $("btn-create-skill").addEventListener("click", () => Skills.createInSession());
      $("btn-import-skill").addEventListener("click", () => Skills.toggleImportBar());
    }
  }

  // Update handler — driven from the input event above. Exposed on the
  // public API for programmatic use too.
  function _update(value) {
    const query = _getSlashQuery(value);
    if (query === null) { _hide(); return; }
    _activeIndex = 0;  // Always highlight the first match
    _render(query);  // async, fire-and-forget
  }

  // Keyboard handler for the dropdown. Returns true if the event was consumed.
  function _handleKey(e) {
    if (!_visible) return false;
    if (e.key === "ArrowDown") { e.preventDefault(); _moveActive(1);  return true; }
    if (e.key === "ArrowUp")   { e.preventDefault(); _moveActive(-1); return true; }
    if (e.key === "Escape")    { e.preventDefault(); _hide();         return true; }
    if (e.key === "Tab") {
      // Tab: select active item if one is highlighted, otherwise select first item
      e.preventDefault();
      const targetIdx = _activeIndex >= 0 ? _activeIndex : 0;
      _select(targetIdx);
      return true;
    }
    if (e.key === "Enter" && !_ime.isComposing(e)) {
      if (_activeIndex >= 0) {
        e.preventDefault();
        _select(_activeIndex);
        return true;
      }
      // No item highlighted — select first item if available
      if (_items.length > 0) {
        e.preventDefault();
        _select(0);
        return true;
      }
      // No items — let Enter fall through to sendMessage
      _hide();
      return false;
    }
    return false;
  }

  return {
    get visible()      { return _visible; },
    get activeIndex()  { return _activeIndex; },

    /** Initialize event listeners (call once on page load). */
    init() {
      if (_initialized) return;
      _initialized = true;

      // Wire up all composer/slash DOM bindings for the chat composer.
      _initDOMBindings(_chatCfg);
    },

    /**
     * Attach the autocomplete to a second composer (e.g. the new-session page).
     * `config` overrides element ids and provides `fetchSkills` / `onSend`.
     */
    attach(config) {
      const cfg = Object.assign({}, _chatCfg, config);
      _initDOMBindings(cfg);
      return {
        /** Programmatic input handler (call from the input event if needed). */
        update: (value) => { _cfg = cfg; _update(value); },
        hide:   _hide,
        get visible() { return _visible; },
      };
    },

    /** Called on every `input` event — decide whether to show/hide/update. */
    update: _update,

    /** Open dropdown with all skills (triggered by / button). */
    openAll: _openAll,

    /** Toggle dropdown visibility (used by / button). */
    toggle: _toggle,

    /** Hide the dropdown. */
    hide: _hide,

    /** Reload session-scoped skill list when the active session changes. */
    loadForSession: _loadForSession,

    /** True when `name` is a user-invocable skill for the active session (sync, cached). */
    isValidCommand: _isValidCommand,

    /** Render user message text, highlighting a leading valid slash command. */
    renderUserMessageHtml: _renderUserMessageHtml,

    /** Handle keyboard nav inside the dropdown. Returns true if event was consumed. */
    handleKey: _handleKey,
  };
})();

Clacky.SkillAC = SkillAC;
