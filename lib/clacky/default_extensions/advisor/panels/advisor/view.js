// ── Advisor recommendations bar + settings toggle ─────────────────────
//
// session.composer slot: recommendation card above the input box. The ✕
// button dismisses the card for the rest of this page lifetime — purely
// local, no server call, so a page refresh brings recommendations back.
// The ⏻ button turns the advisor off globally (persisted to advisor.yml);
// a toast reminds the user it can be re-enabled in Settings. Clicking an
// option fills the input box so the user can review (or edit) before
// sending. Nothing is executed automatically.
//
// settings.tabs + settings.body: an "Advisor" tab with a master on/off
// switch, persisted to ~/.clacky/advisor.yml via /api/ext/advisor/*.
// Turning it off hides the card immediately (shared state below) and stops
// the hooks from generating recommendations on future rounds; turning it
// back on is always one click away.
//
// i18n: this extension owns its strings — the plugin dictionary below is
// the single source of truth, so the host i18n.js is never touched.
//
// Native DOM + textContent everywhere so LLM output can never inject HTML.
// ─────────────────────────────────────────────────────────────────────────

(() => {
  if (!window.Clacky || !Clacky.ext || !Clacky.ext.subscribe) return;

  const DICT = {
    en: {
      "advisor.title":          "Next suggestions",
      "advisor.dismiss":        "Dismiss this round",
      "advisor.off":            "Turn off suggestions",
      "advisor.offHint":        "Suggestions turned off. Re-enable anytime in Settings.",
      "advisor.goSettings":     "Open Settings",
      "advisor.pending":        "Generating suggestions…",
      "advisor.error":          "Failed to generate suggestions",
      "advisor.empty":          "No suggestions available, try again later",
      "advisor.settingsTab":    "Suggestions",
      "advisor.settingsTitle":  "Work Suggestions",
      "advisor.settingsDesc":   "Recommends next steps after each task round. Turn off to stop generating; re-enable anytime.",
      "advisor.settingsEnabled": "Enable work suggestions",
      "advisor.settingsHint":   "Recommends next steps after each round",
      "advisor.sendNow":        "Send now",
      "advisor.settingsFailed": "Operation failed, please retry",
    },
    zh: {
      "advisor.title":          "接下来建议",
      "advisor.dismiss":        "收起本次",
      "advisor.off":            "关闭工作建议",
      "advisor.offHint":        "已关闭工作建议，可在设置页重新打开",
      "advisor.goSettings":     "去设置",
      "advisor.pending":        "正在生成建议…",
      "advisor.error":          "建议生成失败",
      "advisor.empty":          "未能生成建议，请稍后重试",
      "advisor.settingsTab":    "工作建议",
      "advisor.settingsTitle":  "工作建议",
      "advisor.settingsDesc":   "每轮任务结束后推荐下一步工作。关闭后不再生成建议，可随时重新打开。",
      "advisor.settingsEnabled": "启用工作建议",
      "advisor.settingsHint":   "每轮任务结束后推荐下一步工作",
      "advisor.sendNow":        "直接发送",
      "advisor.settingsFailed": "操作失败，请重试",
    },
  };

  function t(key, fallback) {
    const lang = (typeof I18n !== "undefined" && I18n.lang) ? I18n.lang() : "zh";
    const v = (DICT[lang] && DICT[lang][key]) || DICT.en[key];
    return v || fallback;
  }

  if (!document.getElementById("advisor-card-style")) {
    const style = document.createElement("style");
    style.id = "advisor-card-style";
    style.textContent = `
      .advisor-card { border: 1px solid var(--color-border-primary); border-radius: var(--radius-md); padding: 10px 12px; background: var(--color-bg-card); }
      .advisor-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 4px; }
      .advisor-title { font-size: 12px; font-weight: 500; color: var(--color-text-tertiary); }
      .advisor-actions { display: flex; align-items: center; gap: 2px; }
      .advisor-close, .advisor-off { flex: none; width: 18px; height: 18px; display: inline-flex; align-items: center; justify-content: center; border: none; border-radius: var(--radius-sm); background: transparent; color: var(--color-text-tertiary); cursor: pointer; font-size: 11px; line-height: 1; padding: 0; }
      .advisor-close:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
      .advisor-off:hover { background: var(--color-bg-hover); color: var(--color-error, #c0392b); }
      .advisor-option { position: relative; display: flex; align-items: center; gap: 8px; width: 100%; text-align: left; padding: 3px 8px; border: none; border-radius: var(--radius-sm); background: transparent; cursor: pointer; font: inherit; }
      .advisor-option:hover { background: var(--color-bg-hover); }
      .advisor-option-main { flex: 1; min-width: 0; padding-right: 28px; display: block; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 13px; color: var(--color-text-secondary); line-height: 1.4; }
      .advisor-option-sep { color: var(--color-text-muted, var(--color-text-tertiary)); }
      .advisor-option-reason { color: var(--color-text-tertiary); }
      .advisor-option-send { position: absolute; right: 6px; top: 50%; transform: translateY(-50%); width: 22px; height: 22px; display: inline-flex; align-items: center; justify-content: center; border: none; border-radius: var(--radius-sm); background: transparent; color: var(--color-text-secondary); cursor: pointer; opacity: 0; transition: opacity 0.12s; padding: 0; }
      .advisor-option:hover .advisor-option-send { opacity: 1; }
      .advisor-option-send:hover { background: var(--color-accent-primary); color: #fff; }
      .advisor-card-text { font-size: 12px; color: var(--color-text-secondary); white-space: pre-wrap; }
      .advisor-error { font-size: 12px; color: var(--color-error, #c0392b); background: var(--color-error-bg, #fef2f2); padding: 6px 8px; border-radius: var(--radius-sm); white-space: pre-wrap; }
      .advisor-pending { font-size: 12px; color: var(--color-text-tertiary); display: flex; align-items: center; gap: 8px; }
      .advisor-spinner { width: 12px; height: 12px; flex: none; border: 2px solid var(--color-border-strong, #c9c9c2); border-top-color: transparent; border-radius: 50%; animation: advisor-spin 0.8s linear infinite; }
      @keyframes advisor-spin { to { transform: rotate(360deg); } }
      .advisor-settings-desc { font-size: 13px; color: var(--color-text-secondary); line-height: 1.5; margin: 0 0 12px; }
    `;
    document.head.appendChild(style);
  }

  function parseOptions(content) {
    const options = [];
    (content || "").split("\n").forEach((line) => {
      const m = line.match(/^\s*[-*]\s*\[([^\]]+)\]\s*(.*)$/);
      if (m) {
        options.push({ action: m[1].trim(), reason: m[2].trim() });
      } else if (line.trim()) {
        // Tolerate models that skip the [action] wrapper — the whole line
        // still becomes a clickable option.
        options.push({ action: line.trim(), reason: "" });
      }
    });
    return options;
  }

  function fillInput(text) {
    const input = document.getElementById("user-input");
    if (!input) return;
    input.value = text;
    // Match the host's auto-grow behaviour (sessions.js input handler): a raw
    // value assignment never fires the input event, so multi-line fills would
    // otherwise stay at one-line height with the rest clipped.
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, 200) + "px";
    input.focus();
  }

  // Fill the composer and send immediately. _sendMessage clears the input
  // after dispatching, so no cleanup is needed here.
  function sendNow(text) {
    const input = document.getElementById("user-input");
    const btn = document.getElementById("btn-send");
    if (!input || !btn) return;
    input.value = text;
    input.style.height = "auto";
    btn.click();
  }

  function renderOptions(slot, options) {
    options.slice(0, 3).forEach((opt) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "advisor-option";

      const main = document.createElement("span");
      main.className = "advisor-option-main";

      const action = document.createElement("span");
      action.className = "advisor-option-action";
      action.textContent = opt.action;
      main.appendChild(action);

      if (opt.reason) {
        const sep = document.createElement("span");
        sep.className = "advisor-option-sep";
        sep.textContent = " · ";
        const reason = document.createElement("span");
        reason.className = "advisor-option-reason";
        reason.textContent = opt.reason;
        main.appendChild(sep);
        main.appendChild(reason);
      }
      btn.appendChild(main);

      btn.addEventListener("click", () => fillInput(opt.action));

      // One-click send — revealed on hover so the row stays clean.
      const send = document.createElement("span");
      send.className = "advisor-option-send";
      send.setAttribute("role", "button");
      send.tabIndex = 0;
      send.title = t("advisor.sendNow", "直接发送");
      send.setAttribute("aria-label", send.title);
      send.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="12" height="12"><line x1="5" y1="12" x2="19" y2="12"/><polyline points="12 5 19 12 12 19"/></svg>';
      send.addEventListener("click", (e) => {
        e.stopPropagation();
        sendNow(opt.action);
      });
      btn.appendChild(send);

      slot.appendChild(btn);
    });
  }

  // Module-level state, shared by the card and the settings switch.
  // dismissed: the user hit ✕ — hide the card for this page lifetime and
  // ignore incoming events until a refresh (or the settings switch turns
  // the advisor back on).
  const state = { mode: "hidden", options: [], fallback: "", errorMessage: "", dismissed: false };

  function dismiss() {
    state.dismissed = true;
    state.mode = "hidden";
    redraw();
  }

  // Global off: POST the disable endpoint (persisted in advisor.yml) and
  // hide the card; the toast tells the user where to re-enable.
  function turnOff() {
    fetch("/api/ext/advisor/disable", { method: "POST" })
      .then((r) => { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
      .then((d) => {
        state.dismissed = true;
        state.mode = "hidden";
        redraw();
        if (window.Clacky && Clacky.Modal && Clacky.Modal.toast) {
          Clacky.Modal.toast(t("advisor.offHint", "已关闭工作建议，可在设置页重新打开"), {
            type: "success",
            action: {
              label: t("advisor.goSettings", "去设置"),
              onClick: () => {
                location.hash = "#settings";
                setTimeout(() => {
                  const b = document.querySelector('#settings-tabs .settings-tab[data-tab="advisor"]');
                  if (b) b.click();
                }, 200);
              },
            },
          });
        }
      })
      .catch((err) => {
        console.warn("[Advisor] disable failed:", err);
        if (window.Clacky && Clacky.Modal && Clacky.Modal.toast) {
          Clacky.Modal.toast(t("advisor.settingsFailed", "操作失败，请重试"), "error");
        }
      });
  }

  // Build the current card from `state`. Returns null when hidden — the host
  // treats a null result as "render nothing", which clears the slot.
  function renderContent() {
    if (state.dismissed || state.mode === "hidden") return null;

    const slot = document.createElement("div");
    slot.className = "advisor-card";
    const head = document.createElement("div");
    head.className = "advisor-head";
    const title = document.createElement("div");
    title.className = "advisor-title";
    title.textContent = t("advisor.title", "接下来建议");
    head.appendChild(title);

    const actions = document.createElement("div");
    actions.className = "advisor-actions";

    // ⏻ global off — persists in advisor.yml; a toast points back to Settings.
    const off = document.createElement("button");
    off.type = "button";
    off.className = "advisor-off";
    off.title = t("advisor.off", "关闭工作建议");
    off.setAttribute("aria-label", off.title);
    off.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="12" height="12"><path d="M18.36 6.64a9 9 0 1 1-12.73 0"/><line x1="12" y1="2" x2="12" y2="12"/></svg>';
    off.addEventListener("click", turnOff);
    actions.appendChild(off);

    // ✕ dismiss this round — local only, back after a page refresh.
    const close = document.createElement("button");
    close.type = "button";
    close.className = "advisor-close";
    close.title = t("advisor.dismiss", "收起本次");
    close.setAttribute("aria-label", close.title);
    close.textContent = "✕";
    close.addEventListener("click", dismiss);
    actions.appendChild(close);

    head.appendChild(actions);
    slot.appendChild(head);

    if (state.mode === "pending") {
      const row = document.createElement("div");
      row.className = "advisor-pending";

      const spinner = document.createElement("div");
      spinner.className = "advisor-spinner";
      row.appendChild(spinner);
      row.appendChild(document.createTextNode(t("advisor.pending", "正在生成建议…")));

      slot.appendChild(row);
      return slot;
    }

    if (state.mode === "error") {
      const row = document.createElement("div");
      row.className = "advisor-error";
      row.textContent = state.errorMessage;
      slot.appendChild(row);
      return slot;
    }

    if (state.options.length > 0) {
      renderOptions(slot, state.options);
    } else {
      const text = document.createElement("div");
      text.className = "advisor-card-text";
      text.textContent = state.fallback;
      slot.appendChild(text);
    }
    return slot;
  }

  // Re-render this slot through the host. The container renderSlot passes to
  // the mount callback is a fresh wrap created per pass, so holding onto it
  // across events would paint into detached DOM — going through the host each
  // time keeps the rendered card attached (and honors the agent scope).
  function redraw() {
    const el = document.querySelector('[data-slot="session.composer"]');
    if (el && typeof Clacky.ext.renderSlot === "function") {
      Clacky.ext.renderSlot("session.composer", el);
    }
    // The card pushes the message stream up; scroll to the bottom so the
    // last message stays visible instead of being hidden under it.
    if (!state.dismissed && state.mode !== "hidden") {
      requestAnimationFrame(() => {
        const m = document.getElementById("messages");
        if (m) m.scrollTop = m.scrollHeight;
      });
    }
  }

  Clacky.ext.subscribe("ext.advisor.pending", () => {
    if (state.dismissed) return;
    state.mode = "pending";
    redraw();
  });
  Clacky.ext.subscribe("ext.advisor.recommendations", (payload) => {
    if (state.dismissed) return;
    const content = (payload && (payload.content || payload.advice)) || "";
    const opts = parseOptions(content);
    state.mode = "options";
    state.options = opts;
    state.fallback = opts.length > 0 ? "" : content;
    redraw();
  });
  Clacky.ext.subscribe("ext.advisor.done", (payload) => {
    if (state.dismissed) return;
    const reason = payload && payload.reason;
    if (reason === "error" || reason === "empty") {
      state.mode = "error";
      state.errorMessage = (reason === "error" && payload && payload.message)
        ? t("advisor.error", "建议生成失败") + "：" + payload.message
        : t("advisor.empty", "未能生成建议，请稍后重试");
    } else {
      state.mode = "hidden";
    }
    redraw();
  });

  Clacky.ext.ui.mount("session.composer", () => renderContent(), { order: 200 });

  // ── Settings tab: master on/off switch ─────────────────────────────────

  function settingsTab() {
    const btn = document.createElement("button");
    btn.className = "settings-tab";
    btn.dataset.tab = "advisor";
    btn.textContent = t("advisor.settingsTab", "工作建议");
    return btn;
  }

  function settingsBody() {
    const panel = document.createElement("div");
    panel.className = "settings-tab-content";
    panel.dataset.tabContent = "advisor";
    // Native tabs hide inactive bodies via inline display:none; without this
    // the panel shows on top of the default (Models) tab after a page refresh.
    panel.style.display = "none";

    const section = document.createElement("section");
    section.className = "settings-section";
    const title = document.createElement("div");
    title.className = "settings-section-title";
    title.textContent = t("advisor.settingsTitle", "工作建议");
    section.appendChild(title);

    const desc = document.createElement("p");
    desc.className = "advisor-settings-desc";
    desc.textContent = t("advisor.settingsDesc",
      "每轮任务结束后推荐下一步工作。关闭后不再生成建议，可随时重新打开。");
    section.appendChild(desc);

    const card = document.createElement("div");
    card.className = "backup-auto-card";
    const row = document.createElement("div");
    row.className = "backup-auto-row";
    const toggle = document.createElement("label");
    toggle.className = "toggle-switch";
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    const slider = document.createElement("span");
    slider.className = "toggle-slider";
    toggle.appendChild(checkbox);
    toggle.appendChild(slider);
    const label = document.createElement("span");
    label.className = "backup-auto-label";
    label.textContent = t("advisor.settingsEnabled", "启用工作建议");
    const hint = document.createElement("span");
    hint.className = "backup-auto-hint";
    hint.textContent = t("advisor.settingsHint", "每轮任务结束后推荐下一步工作");
    row.appendChild(toggle);
    row.appendChild(label);
    row.appendChild(hint);
    card.appendChild(row);
    section.appendChild(card);
    panel.appendChild(section);

    fetch("/api/ext/advisor/status")
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => {
        if (d && typeof d.enabled === "boolean") checkbox.checked = d.enabled;
      })
      .catch(() => {});

    checkbox.addEventListener("change", () => {
      const target = checkbox.checked ? "enable" : "disable";
      checkbox.disabled = true;
      fetch(`/api/ext/advisor/${target}`, { method: "POST" })
        .then((r) => {
          if (!r.ok) throw new Error("HTTP " + r.status);
          return r.json();
        })
        .then((d) => {
          checkbox.checked = !!d.enabled;
          // Reflect the change on the open composer card immediately.
          state.dismissed = !d.enabled;
          redraw();
        })
        .catch((err) => {
          console.warn("[Advisor] toggle failed:", err);
          checkbox.checked = !checkbox.checked;
          if (window.Clacky && Clacky.Modal && Clacky.Modal.toast) {
            Clacky.Modal.toast(t("advisor.settingsFailed", "操作失败，请重试"), "error");
          }
        })
        .then(() => { checkbox.disabled = false; });
    });

    return panel;
  }

  // Settings is global app chrome, not a session view — a plain mount is
  // always visible there (settings.tabs/body are not session-scoped slots).
  Clacky.ext.ui.mount("settings.tabs", () => settingsTab(), { order: 300 });
  Clacky.ext.ui.mount("settings.body", () => settingsBody(), { order: 300 });

  // Re-render on language switch: host data-i18n only covers static DOM, the
  // advisor tab/body/card are built dynamically so they must re-run.
  document.addEventListener("langchange", () => {
    const active = document.querySelector("#settings-tabs .settings-tab.active");
    const activeTab = active ? active.dataset.tab : null;
    if (typeof Clacky.ext.refreshSlots === "function") Clacky.ext.refreshSlots();
    if (activeTab) {
      const btn = document.querySelector(`#settings-tabs .settings-tab[data-tab="${activeTab}"]`);
      const panel = document.querySelector(`#settings-body .settings-tab-content[data-tab-content="${activeTab}"]`);
      if (btn) btn.classList.add("active");
      if (panel) { panel.classList.add("active"); panel.style.display = ""; }
    }
  });

  // The host re-renders slots on session switch, not on script injection —
  // a panel script loaded after the last render pass would never paint until
  // the next switch. Force one refresh pass so late-loaded scripts still
  // render. No-op when the slot is not in the DOM or the profile is hidden.
  if (typeof Clacky.ext.refreshSlots === "function") Clacky.ext.refreshSlots();
})();
