// ── Official panel: time_machine ──────────────────────────────────────────
//
// Vertical timeline of the session's tasks (mounted in session.aside tab slot).
// Clicking a past row expands an inline card (top files + actions). "View
// details" swaps the whole panel to a two-pane detail view - file list on the
// left, unified diff on the right - mirroring the Git tab layout inside the
// aside (the aside widens to fit the diff, same as the Files/Git tabs).
//// Backed by:
//   GET  /api/sessions/:id/time_machine                  — task list
//   GET  /api/sessions/:id/time_machine/:tid/diff        — files this task touched
//   GET  /api/sessions/:id/time_machine/:tid/diff?path=… — unified diff for one file
//   POST /api/sessions/:id/time_machine/switch           — restore working tree
//
// Switching rewrites files on disk, so it always goes through an inline confirm.
// All user-supplied / backend-supplied text is rendered with textContent — no
// innerHTML on dynamic content.
// ───────────────────────────────────────────────────────────────────────────

(() => {
  if (!window.Clacky || !Clacky.ext) return;

  // The currently mounted panel's state, refreshed on every mount. A single WS
  // hook (registered once below) reloads it when the active session completes a
  // task, so new snapshots appear without a manual refresh. Kept as a closure
  // singleton because WS.onEvent has no unsubscribe and the panel re-mounts on
  // each session switch.
  let _activeState = null;
  let _wsHooked = false;

  function _hookWs() {
    if (_wsHooked || typeof WS === "undefined") return;
    _wsHooked = true;
    WS.onEvent((ev) => {
      if (ev && ev.type === "complete" && _activeState &&
          ev.session_id === _activeState.sessionId) {
        loadHistory(_activeState);
      }
    });
  }

  const t = (k, fallback) => {
    const v = (typeof I18n !== "undefined") ? I18n.t(k) : null;
    return (v && v !== k) ? v : fallback;
  };

  const DIFF_ASIDE_WIDTH = 860;
  const MAX_DIFF_LINES = 3000;
  const ICON_BACK = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12H5"/><path d="M12 19l-7-7 7-7"/></svg>';
  const ICON_CLOSE = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M18 6L6 18M6 6l12 12"/></svg>';

  if (!document.getElementById("tm-panel-style")) {
    const style = document.createElement("style");
    style.id = "tm-panel-style";
    style.textContent = `
      .tm-panel { display: flex; flex-direction: column; flex: 1; min-height: 0; }
      .tm-list { flex: 1; min-height: 0; overflow: auto; padding: 12px 14px; }
      .tm-rail { position: relative; }
      .tm-rail::before {
        content: ""; position: absolute;
        left: 14.5px; top: 6px; bottom: 6px;
        width: 1px; background: var(--color-border-primary);
        z-index: 0;
      }
      .tm-loading, .tm-empty, .tm-error { color: var(--color-text-tertiary); padding: 16px; font-size: 12px; text-align: center; }
      .tm-error { color: var(--color-error); }

      .tm-item { position: relative; padding: 9px 12px 9px 28px; border-radius: var(--radius-md); cursor: pointer; margin-bottom: 8px; z-index: 1; }
      .tm-item:hover { background: var(--color-bg-hover); }
      .tm-item.current { background: var(--color-accent-soft); cursor: default; }
      .tm-item.active { background: var(--color-bg-hover); outline: 1px solid var(--color-accent-primary); }
      .tm-item.undone { cursor: pointer; }

      .tm-item::before {
        content: ""; position: absolute; left: 11px; top: 14px;
        width: 8px; height: 8px; border-radius: 50%;
        background: var(--color-bg-primary);
        border: 1px solid var(--color-border-strong);
        box-sizing: border-box;
        z-index: 2;
      }
      .tm-item:hover::before { background: var(--color-bg-hover); }
      .tm-item.current::before {
        background: var(--color-accent-primary);
        border-color: var(--color-accent-primary);
        box-shadow: 0 0 0 3px var(--color-accent-soft);
      }
      .tm-item.undone::before { border-color: var(--color-text-muted); opacity: 0.6; }

      .tm-item.empty .tm-title { color: var(--color-text-muted); }
      .tm-item.empty .tm-time { color: var(--color-text-muted); opacity: 0.7; }

      .tm-head { display: flex; align-items: center; gap: 6px; }
      .tm-badge { flex: none; font-size: 10px; padding: 0 6px; border-radius: var(--radius-pill); }
      .tm-badge.now { background: var(--color-accent-primary); color: var(--color-text-inverse); }
      .tm-badge.branch { background: var(--color-bg-hover); color: var(--color-text-tertiary); }
      .tm-title { font-size: 13px; color: var(--color-text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .tm-item.undone .tm-title { color: var(--color-text-muted); text-decoration: line-through; }
      .tm-time { font-size: 11px; color: var(--color-text-tertiary); margin-top: 2px; }
      .tm-change-count { font-size: 11px; color: var(--color-text-tertiary); margin-left: 4px; }

      .tm-mini { margin: 0 0 8px 28px; padding: 8px 10px; border: 1px solid var(--color-border-secondary); border-radius: var(--radius-md); background: var(--color-bg-secondary); display: flex; flex-direction: column; gap: 6px; }
      .tm-mini-files { display: flex; flex-direction: column; gap: 2px; }
      .tm-mini-file { font-size: 11px; color: var(--color-text-secondary); display: flex; gap: 6px; align-items: center; overflow: hidden; }
      .tm-mini-file-tag { flex: none; font-size: 9px; padding: 0 5px; border-radius: var(--radius-sm); }
      .tm-mini-file-tag.added    { background: var(--color-success-soft, #1f6e2c33); color: var(--color-success, #4eb965); }
      .tm-mini-file-tag.modified { background: var(--color-accent-soft);                color: var(--color-accent-primary); }
      .tm-mini-file-tag.deleted  { background: var(--color-error-soft, #b03a3a33);     color: var(--color-error); }
      .tm-mini-file-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .tm-mini.undone .tm-mini-files .tm-mini-file-name { text-decoration: line-through; color: var(--color-text-tertiary); }
      .tm-mini.undone .tm-mini-files .tm-mini-file-tag  { opacity: 0.6; }
      .tm-mini-more { font-size: 11px; color: var(--color-text-tertiary); padding-left: 4px; }
      .tm-mini-empty { font-size: 11px; color: var(--color-text-tertiary); padding: 4px 0; }
      .tm-mini-actions { display: flex; gap: 6px; margin-top: 2px; justify-content: flex-end; align-items: center; }
      .tm-mini-btn { padding: 4px 10px; font-size: 11px; line-height: 16px; cursor: pointer; border: 1px solid var(--color-border-primary); border-radius: var(--radius-sm); background: var(--color-bg-primary); color: var(--color-text-secondary); }
      .tm-mini-btn:hover { background: var(--color-bg-hover); }
      .tm-mini-btn.primary { background: var(--color-accent-primary); color: var(--color-text-inverse); border-color: var(--color-accent-primary); }
      .tm-mini-btn.primary:hover { background: var(--color-button-primary-hover); border-color: var(--color-button-primary-hover); }
      .tm-mini-btn:disabled { opacity: 0.5; cursor: default; }

      .tm-mini-confirm {
        display: flex; flex-direction: column; gap: 6px;
        padding: 8px; margin-top: 2px;
        border: 1px solid var(--color-border-secondary);
        border-radius: var(--radius-sm);
        background: var(--color-bg-primary);
      }
      .tm-mini-confirm-msg { font-size: 11px; color: var(--color-text-secondary); line-height: 16px; }
      .tm-mini-confirm-msg strong { color: var(--color-text-primary); font-weight: 500; }
      .tm-mini-confirm-files { display: flex; flex-direction: column; gap: 2px; max-height: 140px; overflow: auto; }
      .tm-mini-confirm-loading { font-size: 11px; color: var(--color-text-tertiary); padding: 4px 0; }

      .tm-foot { flex: none; padding: 8px 14px; font-size: 11px; color: var(--color-text-tertiary); border-top: 1px solid var(--color-border-secondary); }

      /* ── Detail view (in-aside, mirrors the Git tab layout) ───────────── */
      .tm-detail { display: none; flex: 1; min-height: 0; flex-direction: column; }
      .tm-panel.in-detail .tm-list { display: none; }
      .tm-panel.in-detail .tm-detail { display: flex; }

      .tm-detail-head { flex: none; display: flex; align-items: center; gap: 8px; padding: 10px 10px 10px 6px; border-bottom: 1px solid var(--color-border-secondary); }
      .tm-detail-back { flex: none; display: inline-flex; align-items: center; justify-content: center; width: 24px; height: 24px; border: none; border-radius: var(--radius-sm); background: transparent; color: var(--color-text-secondary); cursor: pointer; }
      .tm-detail-back:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
      .tm-detail-title-wrap { flex: 1; min-width: 0; }
      .tm-detail-title { font-size: 13px; color: var(--color-text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 500; }
      .tm-detail-time { font-size: 11px; color: var(--color-text-tertiary); margin-top: 2px; }
      .tm-detail-restore { flex: none; padding: 5px 12px; font-size: 12px; cursor: pointer; border: 1px solid transparent; border-radius: var(--radius-sm); background: var(--color-accent-primary); color: var(--color-text-inverse); white-space: nowrap; }
      .tm-detail-restore:hover { background: var(--color-button-primary-hover); }
      .tm-detail-restore:disabled { opacity: 0.5; cursor: default; }
      .tm-detail-restore.armed { background: var(--color-error, #b03a3a); }

      .tm-detail-body { flex: 1; min-height: 0; display: flex; }
      .tm-detail-files { flex: 1; min-width: 0; overflow: auto; padding: 6px 6px; }
      .tm-panel.has-detail-diff .tm-detail-files { flex: 0 0 232px; border-right: 1px solid var(--color-border-primary); }
      .tm-detail-diff { display: none; flex: 1; min-width: 0; min-height: 0; flex-direction: column; }
      .tm-panel.has-detail-diff .tm-detail-diff { display: flex; }

      .tm-detail-diff-head { flex: none; display: flex; align-items: center; gap: 8px; padding: 6px 8px 6px 12px; border-bottom: 1px solid var(--color-border-secondary); }
      .tm-detail-diff-path { flex: 1; min-width: 0; font-family: ui-monospace, monospace; font-size: 11.5px; color: var(--color-text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .tm-detail-diff-close { flex: none; display: inline-flex; align-items: center; justify-content: center; width: 20px; height: 20px; border: none; border-radius: var(--radius-sm); background: transparent; color: var(--color-text-tertiary); cursor: pointer; }
      .tm-detail-diff-close:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
      .tm-file { padding: 6px 8px; font-size: 12px; cursor: pointer; display: flex; align-items: center; gap: 8px; border-radius: var(--radius-sm); }
      .tm-file:hover { background: var(--color-bg-hover); }
      .tm-file.active { background: var(--color-accent-soft); }
      .tm-file-tag { flex: none; font-size: 9px; padding: 1px 6px; border-radius: var(--radius-sm); }
      .tm-file-tag.added    { background: var(--color-success-soft, #1f6e2c33); color: var(--color-success, #4eb965); }
      .tm-file-tag.modified { background: var(--color-accent-soft);                color: var(--color-accent-primary); }
      .tm-file-tag.deleted  { background: var(--color-error-soft, #b03a3a33);     color: var(--color-error); }
      .tm-file-path { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--color-text-secondary); }

      .tm-diff { flex: 1; min-height: 0; overflow: auto; padding: 10px 0; font-family: ui-monospace, monospace; font-size: 12px; line-height: 1.55; }
      .tm-diff-stub, .tm-diff-loading { color: var(--color-text-tertiary); padding: 20px; text-align: center; }
      .tm-diff-line { white-space: pre; padding: 0 16px; min-width: max-content; }
      .tm-diff-line.add { background: var(--color-success-soft, #1f6e2c33); color: var(--color-success, #4eb965); }
      .tm-diff-line.del { background: var(--color-error-soft, #b03a3a33);   color: var(--color-error); }
      .tm-diff-line.hunk { color: var(--color-text-tertiary); margin-top: 6px; }
      .tm-diff-line.meta { color: var(--color-text-tertiary); }
    `;
    document.head.appendChild(style);
  }

  function el(tag, attrs, ...kids) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (k === "class") node.className = v;
        else if (k === "text") node.textContent = v;
        else if (k.startsWith("on") && typeof v === "function") node.addEventListener(k.slice(2), v);
        else node.setAttribute(k, v);
      }
    }
    kids.forEach((c) => { if (c == null) return; node.appendChild(typeof c === "string" ? document.createTextNode(c) : c); });
    return node;
  }

  async function api(sessionId, suffix, opts) {
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/time_machine${suffix}`, opts);
    return res.json();
  }

  function relTime(ts) {
    if (!ts) return "";
    const now = Date.now() / 1000;
    const d = Math.max(0, now - ts);
    if (d < 60)        return t("tm.justNow", "刚刚");
    if (d < 3600)      return `${Math.floor(d / 60)} ${t("tm.minAgo", "分钟前")}`;
    if (d < 86400)     return `${Math.floor(d / 3600)} ${t("tm.hourAgo", "小时前")}`;
    if (d < 86400 * 7) return `${Math.floor(d / 86400)} ${t("tm.dayAgo", "天前")}`;
    const dt = new Date(ts * 1000);
    return dt.toLocaleString();
  }

  // The diff pane needs horizontal room; widen the aside once when a diff is
  // first opened (same trick as the Files/Git tabs, still user-resizable).
  function ensureAsideWidth() {
    const aside = document.getElementById("session-aside");
    if (!aside) return;
    let w = 0;
    try {
      w = parseFloat(getComputedStyle(aside).getPropertyValue("--session-aside-width")) || 0;
    } catch (_e) { w = 0; }
    if (w < DIFF_ASIDE_WIDTH) {
      aside.style.setProperty("--session-aside-width", DIFF_ASIDE_WIDTH + "px");
      try { localStorage.setItem("clacky.aside.width", String(DIFF_ASIDE_WIDTH)); } catch (_e) { /* non-fatal */ }
    }
  }

  function renderTimeline(state) {
    const { listEl, tasks } = state;
    listEl.replaceChildren();

    const rail = el("div", { class: "tm-rail" });
    listEl.appendChild(rail);

    const ordered = tasks.slice().reverse();
    ordered.forEach((task) => {
      const isCurrent = task.status === "current";
      const isEmpty = !isCurrent && (task.change_count || 0) === 0;

      const row = el("div", { class: `tm-item ${task.status}`, "data-task": String(task.task_id) });
      if (isEmpty) row.classList.add("empty");
      if (state.expanded === task.task_id) row.classList.add("active");

      const head = el("div", { class: "tm-head" });
      head.appendChild(el("div", { class: "tm-title", text: task.summary }));
      if (isCurrent) {
        head.appendChild(el("span", { class: "tm-badge now", text: t("tm.badge.current", "当前") }));
      }
      if (task.has_branches) {
        head.appendChild(el("span", { class: "tm-badge branch", text: t("tm.badge.branch", "分支") }));
      }
      row.appendChild(head);

      const meta = el("div", { class: "tm-time" });
      if (task.started_at) meta.appendChild(document.createTextNode(relTime(task.started_at)));
      if (!isCurrent) {
        const cc = task.change_count || 0;
        meta.appendChild(el("span", { class: "tm-change-count",
          text: cc === 0 ? ` · ${t("tm.noChanges", "无改动")}` : ` · ${cc} ${t("tm.changedFiles", "个文件")}`
        }));
      }
      row.appendChild(meta);

      if (!isCurrent) {
        row.addEventListener("click", () => toggleInline(state, task));
      }
      rail.appendChild(row);

      if (state.expanded === task.task_id) {
        rail.appendChild(buildInline(state, task));
      }
    });
  }

  function buildInline(state, task) {
    const isEmpty = (task.change_count || 0) === 0;
    const isUndone = task.status === "undone";
    const filesWrap = el("div", { class: "tm-mini-files" },
      isEmpty
        ? el("div", { class: "tm-mini-empty", text: t("tm.diff.noChangesInTask", "本步无文件改动。") })
        : el("div", { class: "tm-mini-empty", text: t("tm.diff.loading", "正在读取改动…") }));
    const detailsBtn = el("button", { class: "tm-mini-btn", type: "button", text: t("tm.viewDetails", "查看详情") });
    if (isEmpty) detailsBtn.disabled = true;
    const restoreBtn = el("button", { class: "tm-mini-btn primary", type: "button", text: t("tm.restore.go", "回到这里") });
    const actions = el("div", { class: "tm-mini-actions" }, detailsBtn, restoreBtn);
    const card = el("div", { class: `tm-mini ${isUndone ? "undone" : ""}` }, filesWrap, actions);

    detailsBtn.addEventListener("click", (e) => { e.stopPropagation(); openDetail(state, task); });
    restoreBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      openConfirm(state, task, actions);
    });

    if (!isEmpty) loadInlineFiles(state, task, filesWrap);
    return card;
  }

  function openConfirm(state, task, actions) {
    const msg = el("div", { class: "tm-mini-confirm-msg" });
    msg.appendChild(document.createTextNode(t("tm.restore.previewLoading", "正在分析将受影响的文件…")));
    const filesBox = el("div", { class: "tm-mini-confirm-files" });
    const confirmYes = el("button", { class: "tm-mini-btn primary", type: "button", text: t("tm.restore.confirm", "确认回到这里") });
    confirmYes.disabled = true;
    const confirmNo  = el("button", { class: "tm-mini-btn", type: "button", text: t("tm.restore.cancel", "取消") });
    const confirmActions = el("div", { class: "tm-mini-actions" }, confirmNo, confirmYes);
    const box = el("div", { class: "tm-mini-confirm" }, msg, filesBox, confirmActions);
    actions.replaceWith(box);

    confirmNo.addEventListener("click", (ev) => { ev.stopPropagation(); box.replaceWith(actions); });
    confirmYes.addEventListener("click", async (ev) => {
      ev.stopPropagation();
      confirmYes.disabled = true; confirmNo.disabled = true;
      await performRestoreInline(state, task.task_id);
    });

    loadRestorePreview(state, task.task_id, msg, filesBox, confirmYes);
  }

  async function loadRestorePreview(state, taskId, msg, filesBox, confirmBtn) {
    let res;
    try { res = await api(state.sessionId, `/${taskId}/restore_preview`); }
    catch (_e) {
      msg.replaceChildren(document.createTextNode(t("tm.restore.previewFail", "无法预览受影响文件。仍将继续操作。")));
      confirmBtn.disabled = false;
      return;
    }
    if (state.expanded !== taskId) return;
    const changes = (res && res.ok && Array.isArray(res.changes)) ? res.changes : [];
    confirmBtn.disabled = false;

    if (changes.length === 0) {
      msg.replaceChildren(document.createTextNode(t("tm.restore.previewEmpty", "当前工作区与目标状态一致，回到这里不会修改任何文件。")));
      return;
    }

    msg.replaceChildren();
    const tpl = t("tm.restore.previewMsg", "以下 %d 个文件会被恢复，当前的修改将被覆盖：");
    msg.appendChild(document.createTextNode(tpl.replace("%d", String(changes.length))));

    const tagText = {
      create: t("tm.tag.created", "新建"),
      modify: t("tm.tag.modified", "修改"),
      delete: t("tm.tag.deleted", "删除"),
    };
    const statusClass = { create: "added", modify: "modified", delete: "deleted" };
    const shown = changes.slice(0, 5);
    const nodes = shown.map((f) => el("div", { class: "tm-mini-file", title: f.path },
      el("span", { class: `tm-mini-file-tag ${statusClass[f.action] || ""}`, text: tagText[f.action] || f.action }),
      el("span", { class: "tm-mini-file-name", text: f.path }),
    ));
    if (changes.length > shown.length) {
      nodes.push(el("div", { class: "tm-mini-more",
        text: t("tm.moreFiles", "还有 %d 个").replace("%d", changes.length - shown.length) }));
    }
    filesBox.replaceChildren(...nodes);
  }

  async function loadInlineFiles(state, task, filesWrap) {
    const taskId = task.task_id;
    const isUndone = task.status === "undone";
    let res;
    try { res = await api(state.sessionId, `/${taskId}/diff`); }
    catch (_e) {
      filesWrap.replaceChildren(el("div", { class: "tm-mini-empty", text: t("tm.diff.fail", "读取改动失败") }));
      return;
    }
    if (state.expanded !== taskId) return;
    if (!res.ok) {
      filesWrap.replaceChildren(el("div", { class: "tm-mini-empty", text: res.error || t("tm.diff.fail", "读取改动失败") }));
      return;
    }
    const files = res.files || [];
    if (files.length === 0) {
      filesWrap.replaceChildren(el("div", { class: "tm-mini-empty", text: t("tm.diff.noFiles", "没有文件改动。") }));
      return;
    }
    const tagText = { added: t("tm.tag.added", "新增"), modified: t("tm.tag.modified", "修改"), deleted: t("tm.tag.deleted", "删除") };
    const undoneHint = t("tm.undone.fileHint", "该步骤已被撤销，此改动已不在工作区");
    const shown = files.slice(0, 3);
    const nodes = shown.map((f) => el("div",
      { class: "tm-mini-file", title: isUndone ? `${f.path} — ${undoneHint}` : f.path },
      el("span", { class: `tm-mini-file-tag ${f.status}`, text: tagText[f.status] || f.status }),
      el("span", { class: "tm-mini-file-name", text: f.path.split("/").pop() }),
    ));
    if (files.length > shown.length) {
      nodes.push(el("div", { class: "tm-mini-more", text: `… ${t("tm.moreFiles", "还有 %d 个").replace("%d", files.length - shown.length)}` }));
    }
    filesWrap.replaceChildren(...nodes);
  }

  function toggleInline(state, task) {
    state.expanded = (state.expanded === task.task_id) ? null : task.task_id;
    renderTimeline(state);
  }

  async function performRestoreInline(state, taskId) {
    state.footEl.textContent = t("tm.restoring", "正在恢复…");
    try {
      const res = await api(state.sessionId, "/switch", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ task_id: taskId }),
      });
      if (res.ok) {
        state.footEl.textContent = res.message || t("tm.restored", "已恢复");
        state.expanded = null;
        closeDetail(state);
        await loadHistory(state);
      } else {
        state.footEl.textContent = res.error || t("tm.restoreFailed", "恢复失败");
      }
    } catch (_e) {
      state.footEl.textContent = t("tm.restoreFailed", "恢复失败");
    }
  }

  function renderDiffText(patch) {
    const wrap = el("div");
    if (!patch || patch.trim() === "") {
      wrap.appendChild(el("div", { class: "tm-diff-stub", text: t("tm.diff.same", "这一步没有改动这个文件的内容。") }));
      return wrap;
    }
    const lines = patch.split("\n");
    const shown = Math.min(lines.length, MAX_DIFF_LINES);
    for (let i = 0; i < shown; i++) {
      const line = lines[i];
      let cls = "tm-diff-line";
      if (line.startsWith("+++") || line.startsWith("---")) cls += " meta";
      else if (line.startsWith("@@"))                       cls += " hunk";
      else if (line.startsWith("+"))                        cls += " add";
      else if (line.startsWith("-"))                        cls += " del";
      wrap.appendChild(el("div", { class: cls, text: line || " " }));
    }
    if (lines.length > shown) {
      wrap.appendChild(el("div", { class: "tm-diff-stub",
        text: t("tm.diff.truncated", "差异过大，仅显示前 %d 行").replace("%d", String(shown)) }));
    }
    return wrap;
  }

  async function loadFileDiff(state, taskId, rel) {
    state.detailDiffEl.replaceChildren(el("div", { class: "tm-diff-loading", text: t("tm.diff.loading", "正在读取差异…") }));
    try {
      const res = await api(state.sessionId, `/${taskId}/diff?path=${encodeURIComponent(rel)}`);
      if (state.detailSelected !== rel) return;
      if (!res.ok) {
        state.detailDiffEl.replaceChildren(el("div", { class: "tm-diff-stub", text: res.error || t("tm.diff.fail", "读取差异失败") }));
        return;
      }
      if (res.binary) {
        state.detailDiffEl.replaceChildren(el("div", { class: "tm-diff-stub", text: t("tm.diff.binary", "二进制文件，跳过逐行对比。") }));
        return;
      }
      state.detailDiffEl.replaceChildren(renderDiffText(res.patch));
    } catch (_e) {
      state.detailDiffEl.replaceChildren(el("div", { class: "tm-diff-stub", text: t("tm.diff.fail", "读取差异失败") }));
    }
  }

  // ── Detail view (in-aside) ────────────────────────────────────────────────
  // Mirrors the Git tab: file list on the left, diff on the right. The restore
  // button uses the same two-step armed confirm as the Git tab's revert.

  let detailRestoreTimer = null;

  function disarmDetailRestore(state) {
    if (detailRestoreTimer) { clearTimeout(detailRestoreTimer); detailRestoreTimer = null; }
    const btn = state.detailRestoreEl;
    if (!btn) return;
    btn.classList.remove("armed");
    btn.textContent = t("tm.restore.go", "回到这里");
  }

  function armDetailRestore(state) {
    disarmDetailRestore(state);
    state.detailRestoreEl.classList.add("armed");
    state.detailRestoreEl.textContent = t("tm.restore.confirm", "确认回到这里");
    detailRestoreTimer = setTimeout(() => disarmDetailRestore(state), 4000);
  }

  function onDetailRestoreClick(state) {
    if (!state.detailTask) return;
    if (state.detailRestoreEl.classList.contains("armed")) {
      disarmDetailRestore(state);
      performRestoreInline(state, state.detailTask.task_id);
    } else {
      armDetailRestore(state);
    }
  }

  function openDetail(state, task) {
    state.view = "detail";
    state.detailTask = task;
    state.detailSelected = null;
    disarmDetailRestore(state);
    state.panelEl.classList.add("in-detail");
    state.panelEl.classList.remove("has-detail-diff");
    state.detailTitleEl.textContent = task.summary;
    state.detailTimeEl.textContent = task.started_at ? relTime(task.started_at) : "";
    state.detailRestoreEl.disabled = false;
    state.detailFilesEl.replaceChildren(el("div", { class: "tm-diff-loading", text: t("tm.diff.loading", "正在读取改动…") }));
    state.detailDiffPathEl.textContent = "";
    state.detailDiffEl.replaceChildren();
    loadDetailFiles(state, task);
  }

  function closeDetail(state) {
    state.view = "timeline";
    state.detailTask = null;
    state.detailSelected = null;
    disarmDetailRestore(state);
    state.panelEl.classList.remove("in-detail", "has-detail-diff");
  }

  function closeDetailDiff(state) {
    state.detailSelected = null;
    state.panelEl.classList.remove("has-detail-diff");
    state.detailDiffPathEl.textContent = "";
    state.detailDiffEl.replaceChildren();
    state.detailFilesEl.querySelectorAll(".tm-file.active").forEach((n) => n.classList.remove("active"));
  }

  async function loadDetailFiles(state, task) {
    const taskId = task.task_id;
    let res;
    try {
      res = await api(state.sessionId, `/${taskId}/diff`);
    } catch (_e) {
      state.detailFilesEl.replaceChildren(el("div", { class: "tm-diff-stub", text: t("tm.diff.fail", "读取改动失败") }));
      return;
    }
    if (state.view !== "detail" || !state.detailTask || state.detailTask.task_id !== taskId) return;
    if (!res.ok) {
      state.detailFilesEl.replaceChildren(el("div", { class: "tm-diff-stub", text: res.error || t("tm.diff.fail", "读取改动失败") }));
      return;
    }
    const files = res.files || [];
    if (files.length === 0) {
      state.detailFilesEl.replaceChildren(el("div", { class: "tm-diff-stub", text: t("tm.diff.noFiles", "没有文件改动。") }));
      return;
    }
    const tagText = { added: t("tm.tag.added", "新增"), modified: t("tm.tag.modified", "修改"), deleted: t("tm.tag.deleted", "删除") };
    const fileNodes = files.map((f) => {
      const basename = f.path.split("/").pop();
      const node = el("div", { class: "tm-file", title: f.path },
        el("span", { class: `tm-file-tag ${f.status}`, text: tagText[f.status] || f.status }),
        el("span", { class: "tm-file-path", text: basename }),
      );
      node.addEventListener("click", () => selectDetailFile(state, task, f, node));
      return node;
    });
    state.detailFilesEl.replaceChildren(...fileNodes);
    selectDetailFile(state, task, files[0], fileNodes[0]);
  }

  function selectDetailFile(state, task, f, node) {
    state.detailSelected = f.path;
    state.detailFilesEl.querySelectorAll(".tm-file.active").forEach((n) => n.classList.remove("active"));
    node.classList.add("active");
    state.panelEl.classList.add("has-detail-diff");
    ensureAsideWidth();
    state.detailDiffPathEl.textContent = f.path;
    if (f.binary) {
      state.detailDiffEl.replaceChildren(el("div", { class: "tm-diff-stub", text: t("tm.diff.binary", "二进制文件，跳过逐行对比。") }));
    } else {
      loadFileDiff(state, task.task_id, f.path);
    }
  }

  async function loadHistory(state) {
    state.listEl.replaceChildren(el("div", { class: "tm-loading", text: t("tm.loading", "正在读取历史…") }));
    let data;
    try {
      data = await api(state.sessionId, "");
    } catch (_e) {
      state.listEl.replaceChildren(el("div", { class: "tm-error", text: t("tm.error", "读取历史失败") }));
      return;
    }
    state.tasks = (data && data.tasks) || [];
    if (state.tasks.length === 0) {
      state.listEl.replaceChildren(el("div", { class: "tm-empty", text: t("tm.empty", "还没有可回到的版本。") }));
      return;
    }
    renderTimeline(state);
  }

  Clacky.ext.ui.mount("session.aside", {
    create(ctx) {
      const list = el("div", { class: "tm-list" });
      const foot = el("div", { class: "tm-foot", text: t("tm.foot", "每完成一步会自动存档。点击想回到的版本即可恢复。") });

      const backBtn = el("button", { class: "tm-detail-back", type: "button", title: t("tm.detail.back", "返回") });
      backBtn.innerHTML = ICON_BACK;
      const detailTitleEl = el("div", { class: "tm-detail-title" });
      const detailTimeEl = el("div", { class: "tm-detail-time" });
      const detailRestoreEl = el("button", { class: "tm-detail-restore", type: "button", text: t("tm.restore.go", "回到这里") });
      const detailHead = el("div", { class: "tm-detail-head" },
        backBtn,
        el("div", { class: "tm-detail-title-wrap" }, detailTitleEl, detailTimeEl),
        detailRestoreEl,
      );

      const detailFilesEl = el("div", { class: "tm-detail-files" });
      const diffCloseBtn = el("button", { class: "tm-detail-diff-close", type: "button", title: t("tm.diff.close", "关闭") });
      diffCloseBtn.innerHTML = ICON_CLOSE;
      const detailDiffPathEl = el("span", { class: "tm-detail-diff-path" });
      const detailDiffEl = el("div", { class: "tm-diff" });
      const detailDiff = el("div", { class: "tm-detail-diff" },
        el("div", { class: "tm-detail-diff-head" }, detailDiffPathEl, diffCloseBtn),
        detailDiffEl,
      );
      const detailBody = el("div", { class: "tm-detail-body" }, detailFilesEl, detailDiff);
      const detail = el("div", { class: "tm-detail" }, detailHead, detailBody);

      const root = el("div", { class: "tm-panel", "data-panel": "tm" }, list, detail, foot);

      const state = {
        sessionId: ctx.sessionId,
        tasks: [],
        expanded: null,
        view: "timeline",
        detailTask: null,
        detailSelected: null,
        panelEl: root, listEl: list, footEl: foot,
        detailTitleEl, detailTimeEl, detailRestoreEl, detailFilesEl, detailDiffPathEl, detailDiffEl,
      };

      backBtn.addEventListener("click", () => closeDetail(state));
      detailRestoreEl.addEventListener("click", () => onDetailRestoreClick(state));
      diffCloseBtn.addEventListener("click", () => closeDetailDiff(state));

      _activeState = state;
      _hookWs();

      loadHistory(state);

      return {
        state,
        root,
        dispose() {
          if (detailRestoreTimer) { clearTimeout(detailRestoreTimer); detailRestoreTimer = null; }
          if (_activeState === state) _activeState = null;
        },
      };
    },
    render(container, ctx, runtime) {
      container.appendChild(runtime.root);
      _activeState = runtime.state;
    },
  }, {    order: 40,
    tab: { id: "tm", label: () => t("tm.tab") },
  });
})();
