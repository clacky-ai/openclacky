// ── Official panel: time_machine ──────────────────────────────────────────
//
// Vertical timeline of the session's tasks (mounted in session.aside tab slot).
// Clicking a past row opens a right-side drawer with the diff details — the
// 288px aside is too narrow to host both a file list and a unified diff, so
// the drawer escapes to ~720px / 90vw and overlays everything.
//
// Backed by:
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
      .tm-mini-btn.primary:hover { background: var(--color-accent-hover); border-color: var(--color-accent-hover); }
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

      /* ── Drawer ───────────────────────────────────────────────────────── */
      .tm-drawer-mask {
        position: fixed; inset: 0; background: rgba(0, 0, 0, 0.4);
        z-index: 1000; opacity: 0; transition: opacity 0.2s;
      }
      .tm-drawer-mask.open { opacity: 1; }
      .tm-drawer {
        position: fixed; top: 0; right: 0; bottom: 0;
        width: min(720px, 90vw);
        background: var(--color-bg-primary);
        border-left: 1px solid var(--color-border-primary);
        box-shadow: -4px 0 24px rgba(0, 0, 0, 0.15);
        z-index: 1001;
        display: flex; flex-direction: column;
        transform: translateX(100%);
        transition: transform 0.25s cubic-bezier(0.2, 0.8, 0.2, 1);
      }
      .tm-drawer.open { transform: translateX(0); }

      .tm-drawer-head { flex: none; padding: 14px 18px; display: flex; align-items: center; gap: 10px; border-bottom: 1px solid var(--color-border-secondary); }
      .tm-drawer-title-wrap { flex: 1; min-width: 0; }
      .tm-drawer-title { font-size: 14px; color: var(--color-text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 500; }
      .tm-drawer-time { font-size: 11px; color: var(--color-text-tertiary); margin-top: 2px; }
      .tm-drawer-close { flex: none; padding: 4px 10px; font-size: 12px; cursor: pointer; border: 1px solid var(--color-border-primary); border-radius: var(--radius-sm); background: var(--color-bg-secondary); color: var(--color-text-secondary); }
      .tm-drawer-close:hover { background: var(--color-bg-hover); }
      .tm-restore-btn { flex: none; padding: 5px 14px; font-size: 12px; cursor: pointer; border: 1px solid transparent; border-radius: var(--radius-sm); background: var(--color-accent-primary); color: var(--color-text-inverse); }
      .tm-restore-btn:hover { background: var(--color-accent-hover); }
      .tm-restore-btn:disabled { opacity: 0.5; cursor: default; }

      .tm-confirm-row { flex: none; display: flex; gap: 8px; padding: 10px 18px; align-items: center; background: var(--color-bg-secondary); border-bottom: 1px solid var(--color-border-secondary); }
      .tm-confirm-msg { flex: 1; font-size: 12px; color: var(--color-text-secondary); }
      .tm-confirm-btn { padding: 4px 12px; cursor: pointer; border: 1px solid var(--color-border-primary); border-radius: var(--radius-sm); background: var(--color-bg-secondary); font-size: 12px; }
      .tm-confirm-btn.go { background: var(--color-accent-primary); color: var(--color-text-inverse); border-color: transparent; }
      .tm-confirm-btn:disabled { opacity: 0.5; cursor: default; }

      .tm-drawer-body { flex: 1; min-height: 0; display: flex; }
      .tm-files { flex: 0 0 220px; overflow: auto; border-right: 1px solid var(--color-border-secondary); padding: 6px 0; }
      .tm-file { padding: 7px 14px; font-size: 12px; cursor: pointer; display: flex; align-items: center; gap: 8px; }
      .tm-file:hover { background: var(--color-bg-hover); }
      .tm-file.active { background: var(--color-accent-soft); }
      .tm-file-tag { flex: none; font-size: 9px; padding: 1px 6px; border-radius: var(--radius-sm); }
      .tm-file-tag.added    { background: var(--color-success-soft, #1f6e2c33); color: var(--color-success, #4eb965); }
      .tm-file-tag.modified { background: var(--color-accent-soft);                color: var(--color-accent-primary); }
      .tm-file-tag.deleted  { background: var(--color-error-soft, #b03a3a33);     color: var(--color-error); }
      .tm-file-path { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--color-text-secondary); }

      .tm-diff-wrap { flex: 1; min-width: 0; display: flex; flex-direction: column; }
      .tm-diff-path { flex: none; padding: 8px 16px; font-size: 11px; color: var(--color-text-tertiary); border-bottom: 1px solid var(--color-border-secondary); font-family: ui-monospace, monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; direction: rtl; text-align: left; }
      .tm-diff-path:empty { display: none; }
      .tm-diff { flex: 1; min-width: 0; overflow: auto; padding: 10px 0; font-family: ui-monospace, monospace; font-size: 12px; line-height: 1.55; }
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

    detailsBtn.addEventListener("click", (e) => { e.stopPropagation(); openDrawer(state, task); });
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
    patch.split("\n").forEach((line) => {
      let cls = "tm-diff-line";
      if (line.startsWith("+++") || line.startsWith("---")) cls += " meta";
      else if (line.startsWith("@@"))                       cls += " hunk";
      else if (line.startsWith("+"))                        cls += " add";
      else if (line.startsWith("-"))                        cls += " del";
      wrap.appendChild(el("div", { class: cls, text: line || " " }));
    });
    return wrap;
  }

  async function loadFileDiff(state, rel) {
    state.diffEl.replaceChildren(el("div", { class: "tm-diff-loading", text: t("tm.diff.loading", "正在读取差异…") }));
    try {
      const res = await api(state.sessionId, `/${state.selected}/diff?path=${encodeURIComponent(rel)}`);
      if (!res.ok) {
        state.diffEl.replaceChildren(el("div", { class: "tm-diff-stub", text: res.error || t("tm.diff.fail", "读取差异失败") }));
        return;
      }
      if (res.binary) {
        state.diffEl.replaceChildren(el("div", { class: "tm-diff-stub", text: t("tm.diff.binary", "二进制文件，跳过逐行对比。") }));
        return;
      }
      state.diffEl.replaceChildren(renderDiffText(res.patch));
    } catch (_e) {
      state.diffEl.replaceChildren(el("div", { class: "tm-diff-stub", text: t("tm.diff.fail", "读取差异失败") }));
    }
  }

  function openDrawer(state, task) {
    state.selected = task.task_id;

    state.drawerTitleEl.textContent = task.summary;
    state.drawerTimeEl.textContent = task.started_at ? relTime(task.started_at) : "";
    state.confirmRow.style.display = "none";
    state.restoreBtn.disabled = false;
    state.filesEl.replaceChildren(el("div", { class: "tm-diff-loading", text: t("tm.diff.loading", "正在读取改动…") }));
    state.diffEl.replaceChildren();
    state.diffPathEl.textContent = "";

    state.maskEl.style.display = "block";
    state.drawerEl.style.display = "flex";
    requestAnimationFrame(() => {
      state.maskEl.classList.add("open");
      state.drawerEl.classList.add("open");
    });

    loadDrawerFiles(state, task.task_id);
  }

  async function loadDrawerFiles(state, taskId) {
    let res;
    try {
      res = await api(state.sessionId, `/${taskId}/diff`);
    } catch (_e) {
      state.filesEl.replaceChildren(el("div", { class: "tm-diff-stub", text: t("tm.diff.fail", "读取改动失败") }));
      return;
    }
    if (state.selected !== taskId) return;
    if (!res.ok) {
      state.filesEl.replaceChildren(el("div", { class: "tm-diff-stub", text: res.error || t("tm.diff.fail", "读取改动失败") }));
      return;
    }
    const files = res.files || [];
    if (files.length === 0) {
      state.filesEl.replaceChildren(el("div", { class: "tm-diff-stub", text: t("tm.diff.noFiles", "没有文件改动。") }));
      return;
    }
    const tagText = { added: t("tm.tag.added", "新增"), modified: t("tm.tag.modified", "修改"), deleted: t("tm.tag.deleted", "删除") };
    const fileNodes = files.map((f) => {
      const basename = f.path.split("/").pop();
      const node = el("div", { class: "tm-file", title: f.path },
        el("span", { class: `tm-file-tag ${f.status}`, text: tagText[f.status] || f.status }),
        el("span", { class: "tm-file-path", text: basename }),
      );
      node.addEventListener("click", () => {
        state.filesEl.querySelectorAll(".tm-file.active").forEach((n) => n.classList.remove("active"));
        node.classList.add("active");
        state.diffPathEl.textContent = f.path;
        if (f.binary) {
          state.diffEl.replaceChildren(el("div", { class: "tm-diff-stub", text: t("tm.diff.binary", "二进制文件，跳过逐行对比。") }));
        } else {
          loadFileDiff(state, f.path);
        }
      });
      return node;
    });
    state.filesEl.replaceChildren(...fileNodes);
    fileNodes[0].click();
  }

  function closeDrawer(state) {
    state.maskEl.classList.remove("open");
    state.drawerEl.classList.remove("open");
    setTimeout(() => {
      state.maskEl.style.display = "none";
      state.drawerEl.style.display = "none";
    }, 250);
    state.selected = null;
  }

  async function performRestore(state) {
    state.restoreBtn.disabled = true;
    state.footEl.textContent = t("tm.restoring", "正在恢复…");
    try {
      const res = await api(state.sessionId, "/switch", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ task_id: state.selected }),
      });
      if (res.ok) {
        state.footEl.textContent = res.message || t("tm.restored", "已恢复");
        closeDrawer(state);
        await loadHistory(state);
      } else {
        state.footEl.textContent = res.error || t("tm.restoreFailed", "恢复失败");
        state.restoreBtn.disabled = false;
      }
    } catch (_e) {
      state.footEl.textContent = t("tm.restoreFailed", "恢复失败");
      state.restoreBtn.disabled = false;
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

  // The drawer is global — only one can be open at a time across mounts, and
  // it lives on document.body so it can escape the narrow aside column.
  function buildDrawer() {
    if (document.getElementById("tm-drawer-root")) {
      return {
        mask: document.querySelector(".tm-drawer-mask"),
        drawer: document.getElementById("tm-drawer-root"),
        title: document.querySelector(".tm-drawer-title"),
        time: document.querySelector(".tm-drawer-time"),
        restore: document.querySelector(".tm-restore-btn"),
        close: document.querySelector(".tm-drawer-close"),
        confirmRow: document.querySelector(".tm-confirm-row"),
        confirmYes: document.querySelector(".tm-confirm-btn.go"),
        confirmNo: document.querySelector(".tm-confirm-btn:not(.go)"),
        files: document.querySelector(".tm-files"),
        diff: document.querySelector(".tm-diff"),
        diffPath: document.querySelector(".tm-diff-path"),
      };
    }

    const mask = el("div", { class: "tm-drawer-mask" });
    const titleEl = el("div", { class: "tm-drawer-title" });
    const timeEl = el("div", { class: "tm-drawer-time" });
    const restoreBtn = el("button", { class: "tm-restore-btn", type: "button", text: t("tm.restore.go", "回到这里") });
    const closeBtn = el("button", { class: "tm-drawer-close", type: "button", text: t("tm.detail.close", "关闭") });
    const head = el("div", { class: "tm-drawer-head" },
      el("div", { class: "tm-drawer-title-wrap" }, titleEl, timeEl),
      restoreBtn, closeBtn,
    );

    const confirmYes = el("button", { class: "tm-confirm-btn go", type: "button", text: t("tm.restore.confirm", "确认恢复") });
    const confirmNo  = el("button", { class: "tm-confirm-btn", type: "button", text: t("tm.restore.cancel", "取消") });
    const confirmRow = el("div", { class: "tm-confirm-row" },
      el("span", { class: "tm-confirm-msg", text: t("tm.restore.msg", "回到这一步会把文件恢复到当时的状态。") }),
      confirmYes, confirmNo,
    );
    confirmRow.style.display = "none";

    const filesEl = el("div", { class: "tm-files" });
    const diffPathEl = el("div", { class: "tm-diff-path" });
    const diffEl  = el("div", { class: "tm-diff" });
    const diffWrap = el("div", { class: "tm-diff-wrap" }, diffPathEl, diffEl);
    const body = el("div", { class: "tm-drawer-body" }, filesEl, diffWrap);

    const drawer = el("div", { id: "tm-drawer-root", class: "tm-drawer" }, head, confirmRow, body);
    drawer.style.display = "none";
    mask.style.display = "none";

    document.body.appendChild(mask);
    document.body.appendChild(drawer);

    return { mask, drawer, title: titleEl, time: timeEl, restore: restoreBtn, close: closeBtn,
             confirmRow, confirmYes, confirmNo, files: filesEl, diff: diffEl, diffPath: diffPathEl };
  }

  Clacky.ext.ui.mount("session.aside", (ctx) => {
    if (!ctx || !ctx.sessionId) return null;

    const list = el("div", { class: "tm-list" });
    const foot = el("div", { class: "tm-foot", text: t("tm.foot", "每完成一步会自动存档。点击想回到的版本即可恢复。") });
    const root = el("div", { class: "tm-panel", "data-panel": "tm" }, list, foot);

    const d = buildDrawer();

    const state = {
      sessionId: ctx.sessionId,
      tasks: [],
      selected: null,
      expanded: null,
      panelEl: root, listEl: list, footEl: foot,
      maskEl: d.mask, drawerEl: d.drawer,
      drawerTitleEl: d.title, drawerTimeEl: d.time,
      restoreBtn: d.restore, filesEl: d.files, diffEl: d.diff, diffPathEl: d.diffPath, confirmRow: d.confirmRow,
    };

    // Re-bind the global drawer's controls to this mount's state. (The drawer
    // is shared across mounts but only one is interactive at a time.)
    const onClose = () => closeDrawer(state);
    const onRestoreClick = () => {
      d.confirmRow.style.display = "flex";
      d.restore.disabled = true;
    };
    const onCancelClick = () => {
      d.confirmRow.style.display = "none";
      d.restore.disabled = false;
    };
    const onGoClick = () => performRestore(state);
    const onMaskClick = () => closeDrawer(state);
    const onKey = (e) => { if (e.key === "Escape" && d.drawer.classList.contains("open")) closeDrawer(state); };

    d.close.onclick = onClose;
    d.restore.onclick = onRestoreClick;
    d.confirmNo.onclick = onCancelClick;
    d.confirmYes.onclick = onGoClick;
    d.mask.onclick = onMaskClick;
    document.addEventListener("keydown", onKey);

    _activeState = state;
    _hookWs();

    loadHistory(state);
    return root;
  }, {
    panel: "time_machine",
    order: 20,
    tab: { id: "tm", label: () => t("tm.tab") },
  });
})();
