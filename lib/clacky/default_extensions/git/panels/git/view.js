// ── Official panel: changes (git, made friendly) ──────────────────────────
//
// "改动 / Changes": a non-technical view of what the AI changed, backed by the
// built-in git API (GET/POST /api/sessions/:id/git/*). Mounted as a tab in the
// "session.aside" slot, attached to agents via `attach: [coding]` in ext.yml.
//
// Layout mirrors the Files tab: changed files on the left (each with a
// checkbox), clicking a file shows its diff on the right and widens the aside
// to make room. "Save snapshot" prompts for an editable message (pre-filled
// with a timestamped default) and commits only the checked files. Each file
// can also be reverted to its HEAD state via a two-step inline confirm
// (first click arms a red "Discard?" button, second click fires POST
// /git/restore) - the same pattern the Time Machine uses for its
// destructive switch, no blocking dialog needed.
//
// Deliberately hides git jargon: no porcelain status codes (M/??), no
// branch/ahead/behind unless the branch is NOT the main line (main/master) -
// then it's surfaced as a gentle notice.
//
// Native DOM + textContent on all git output (paths, branch, diff) so nothing
// can inject. tab.badge tracks the number of changed files.
// ───────────────────────────────────────────────────────────────────────────

(() => {
  if (!window.Clacky || !Clacky.ext) return;

  const MAIN_BRANCHES = { main: true, master: true };
  const DIFF_ASIDE_WIDTH = 860;
  const MAX_DIFF_LINES = 3000;
  const ICON_CLOSE = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M18 6L6 18M6 6l12 12"/></svg>';
  const ICON_REVERT = '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7v6h6"/><path d="M21 17a9 9 0 0 0-15-6.7L3 13"/></svg>';
  const t = (k, fallback) => {
    const v = (typeof I18n !== "undefined") ? I18n.t(k) : null;
    return (v && v !== k) ? v : fallback;
  };

  if (!document.getElementById("changes-panel-style")) {
    const style = document.createElement("style");
    style.id = "changes-panel-style";
    style.textContent = `
      .changes-panel { display: flex; flex-direction: column; flex: 1; min-height: 0; }
      .changes-summary { flex: none; padding: 10px 12px 8px; border-bottom: 1px solid var(--color-border-secondary); }
      .changes-summary .h { font-size: 13px; color: var(--color-text-secondary); }
      .changes-summary .h b { color: var(--color-text-primary); }
      .changes-summary .sub { font-size: 12px; color: var(--color-text-tertiary); margin-top: 2px; }
      .changes-branch { display: flex; align-items: center; gap: 6px; margin-top: 8px; padding: 5px 8px; border-radius: var(--radius-sm); background: var(--color-warning-bg); color: var(--color-warning); font-size: 11.5px; }
      .changes-branch code { font-family: ui-monospace, monospace; font-weight: 600; }
      .cg-body { flex: 1; min-height: 0; display: flex; }
      .cg-list-pane { flex: 1; min-width: 0; display: flex; flex-direction: column; min-height: 0; }
      .changes-panel.has-diff .cg-list-pane { flex: 0 0 232px; border-right: 1px solid var(--color-border-primary); }
      .cg-listbar { flex: none; display: flex; align-items: center; gap: 6px; padding: 6px 10px; border-bottom: 1px solid var(--color-border-secondary); font-size: 11px; color: var(--color-text-secondary); user-select: none; }
      .cg-listbar .cg-check { cursor: pointer; }
      .cg-count { margin-left: auto; color: var(--color-text-tertiary); }
      .cg-check { flex: none; margin: 0; }
      .changes-list { flex: 1; min-height: 0; overflow: auto; padding: 4px 6px; }
      .change-row { display: flex; align-items: center; gap: 7px; padding: 6px 6px; border-radius: var(--radius-sm); cursor: pointer; }
      .change-row:hover { background: var(--color-bg-hover); }
      .change-row.active { background: var(--color-accent-soft); }
      .change-tag { flex: none; font-size: 11px; padding: 1px 7px; border-radius: var(--radius-pill); font-weight: 500; }
      .change-tag.add { background: var(--color-success-bg); color: var(--color-success); }
      .change-tag.mod { background: #eff6ff; color: #2563eb; }
      .change-tag.del { background: var(--color-error-bg); color: var(--color-error); }
      .change-path { font-size: 13px; color: var(--color-text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .change-dir { color: var(--color-text-tertiary); }
      .change-revert { flex: none; display: inline-flex; visibility: hidden; align-items: center; justify-content: center; height: 22px; min-width: 22px; padding: 0 4px; margin-left: auto; border: none; border-radius: var(--radius-sm); background: transparent; color: var(--color-text-tertiary); font-size: 11px; cursor: pointer; }
      .change-row:hover .change-revert { visibility: visible; }
      .change-revert:hover { background: var(--color-error-bg); color: var(--color-error); }
      .change-revert.armed { visibility: visible; background: var(--color-error-bg); color: var(--color-error); font-weight: 600; }
      .cg-diff-pane { display: none; flex: 1; min-width: 0; min-height: 0; flex-direction: column; }
      .changes-panel.has-diff .cg-diff-pane { display: flex; }
      .cg-diff-head { flex: none; display: flex; align-items: center; gap: 8px; padding: 6px 8px 6px 12px; border-bottom: 1px solid var(--color-border-secondary); }
      .cg-diff-path { flex: 1; min-width: 0; font-family: ui-monospace, monospace; font-size: 11.5px; color: var(--color-text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .cg-diff-close { flex: none; display: inline-flex; align-items: center; justify-content: center; width: 20px; height: 20px; border: none; border-radius: var(--radius-sm); background: transparent; color: var(--color-text-tertiary); cursor: pointer; }
      .cg-diff-close:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
      .cg-diff-revert { flex: none; display: inline-flex; align-items: center; gap: 5px; padding: 3px 10px; border: 1px solid var(--color-error, #b03a3a); border-radius: var(--radius-sm); background: transparent; color: var(--color-error); font-size: 11px; cursor: pointer; white-space: nowrap; }
      .cg-diff-revert:hover { background: var(--color-error-bg); }
      .cg-diff-revert.armed { background: var(--color-error, #b03a3a); border-color: var(--color-error, #b03a3a); color: #fff; font-weight: 600; }
      .cg-diff-revert:disabled { opacity: 0.5; cursor: default; }
      .cg-diff { flex: 1; min-height: 0; overflow: auto; padding: 8px 0; font-family: ui-monospace, monospace; font-size: 11.5px; line-height: 1.6; }
      .cg-diff-line { white-space: pre; padding: 0 12px; min-width: max-content; }
      .cg-diff-line.add { background: var(--color-success-soft, #1f6e2c33); color: var(--color-success, #4eb965); }
      .cg-diff-line.del { background: var(--color-error-soft, #b03a3a33); color: var(--color-error); }
      .cg-diff-line.hunk { color: var(--color-text-tertiary); margin-top: 6px; }
      .cg-diff-line.meta { color: var(--color-text-tertiary); }
      .cg-diff-stub { color: var(--color-text-tertiary); padding: 20px 12px; text-align: center; }
      .changes-foot { flex: none; padding: 10px 12px; border-top: 1px solid var(--color-border-primary); }
      .changes-save-btn { width: 100%; padding: 9px; border: none; border-radius: var(--radius-md); background: var(--color-accent-primary); color: var(--color-text-inverse); font-size: 13px; font-weight: 500; cursor: pointer; }
      .changes-save-btn:hover:not(:disabled) { background: var(--color-button-primary-hover); }
      .changes-save-btn:disabled { opacity: 0.5; cursor: default; }
      .changes-hint { text-align: center; font-size: 11px; color: var(--color-text-tertiary); margin-top: 7px; min-height: 1em; }
      .changes-empty, .changes-loading, .changes-error { color: var(--color-text-tertiary); padding: 16px; font-size: 12px; text-align: center; }
      .changes-error { color: var(--color-error); }
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
    kids.forEach((c) => node.appendChild(typeof c === "string" ? document.createTextNode(c) : c));
    return node;
  }

  async function api(sessionId, action, opts) {
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/git/${action}`, opts);
    return res.json();
  }

  // Map a porcelain status entry to a friendly kind without exposing codes.
  function classify(f) {
    if (f.untracked) return "add";
    const code = `${f.x || ""}${f.y || ""}`;
    if (code.includes("D")) return "del";
    if (code.includes("A")) return "add";
    return "mod";
  }

  const TAG_LABEL = {
    add: () => t("changes.tag.add", "新增"),
    mod: () => t("changes.tag.mod", "修改"),
    del: () => t("changes.tag.del", "删除"),
  };

  function splitPath(path) {
    const i = path.lastIndexOf("/");
    return i < 0 ? { dir: "", name: path } : { dir: path.slice(0, i + 1), name: path.slice(i + 1) };
  }

  function autoMessage() {
    const d = new Date();
    const pad = (n) => String(n).padStart(2, "0");
    const stamp = `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
    return `${t("changes.save.prefix", "手动存档")} · ${stamp}`;
  }

  // The diff pane needs horizontal room; widen the aside once when a diff is
  // first opened (same trick as the Files tab, still user-resizable after).
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

  // ── Panel state ─────────────────────────────────────────────────────────
  // The skeleton is built once per mount; refresh() only updates the summary,
  // the file list and the badge. `checked` / `selected` survive refreshes so a
  // re-render (e.g. after the agent finishes a round) doesn't wipe the user's
  // selection. Files that disappear drop out of the sets; new files start
  // checked.

  const state = {
    sessionId: null,
    files: [],
    checked: new Set(),
    allPaths: new Set(),
    selected: null,
    els: null,
    ctx: null,
  };

  function checkedCount() {
    return state.files.filter((f) => state.checked.has(f.path)).length;
  }

  function updateFoot() {
    if (!state.els) return;
    const { saveBtn, allCheck, countLabel } = state.els;
    const total = state.files.length;
    const n = checkedCount();

    if (countLabel) {
      countLabel.textContent = total
        ? t("changes.select.count", "已选 {{n}}/{{total}}")
            .replace("{{n}}", String(n)).replace("{{total}}", String(total))
        : "";
    }
    if (allCheck) {
      allCheck.disabled = total === 0;
      allCheck.checked = total > 0 && n === total;
      allCheck.indeterminate = n > 0 && n < total;
    }
    if (saveBtn) {
      saveBtn.disabled = n === 0;
      saveBtn.textContent = (n === 0 || n === total)
        ? t("changes.save.btn", "存档当前版本")
        : t("changes.save.btnN", "存档选中的 {{n}} 个文件").replace("{{n}}", String(n));
    }
  }

  function syncRowChecks() {
    if (!state.els) return;
    state.els.listEl.querySelectorAll(".change-row").forEach((row) => {
      const check = row.querySelector(".cg-check");
      if (check) check.checked = state.checked.has(row.dataset.path);
    });
  }

  function highlightSelected() {
    if (!state.els) return;
    state.els.listEl.querySelectorAll(".change-row.active").forEach((r) => r.classList.remove("active"));
    if (!state.selected) return;
    const row = state.els.listEl.querySelector(`.change-row[data-path="${CSS.escape(state.selected)}"]`);
    if (row) row.classList.add("active");
  }

  function renderList() {
    if (!state.els) return;
    disarmRevert();
    const list = state.els.listEl;
    list.replaceChildren();
    if (!state.files.length) {
      list.appendChild(el("div", { class: "changes-empty", text: t("changes.clean", "工作区是干净的，没有未存档的改动。") }));
      return;
    }
    state.files.forEach((f) => {
      const kind = classify(f);
      const { dir, name } = splitPath(f.path);
      const path = el("span", { class: "change-path" });
      if (dir) path.appendChild(el("span", { class: "change-dir", text: dir }));
      path.appendChild(document.createTextNode(name));

      const check = el("input", { class: "cg-check", type: "checkbox" });
      check.checked = state.checked.has(f.path);
      check.addEventListener("click", (e) => e.stopPropagation());
      check.addEventListener("change", () => {
        if (check.checked) state.checked.add(f.path);
        else state.checked.delete(f.path);
        updateFoot();
      });

      const revert = el("button", { class: "change-revert" });
      revert.type = "button";
      revert.title = t("changes.restore.title", "撤销此文件的改动");
      revert.innerHTML = ICON_REVERT;
      revert.addEventListener("click", (e) => {
        e.stopPropagation();
        onRevertClick(revert, f.path);
      });

      const row = el("div", { class: "change-row" }, check,
        el("span", { class: `change-tag ${kind}`, text: TAG_LABEL[kind]() }), path, revert);
      row.dataset.path = f.path;
      row.title = f.path;
      row.addEventListener("click", () => selectFile(f.path));
      list.appendChild(row);
    });
    highlightSelected();
  }

  function renderDiffText(diffText) {
    const { diffCanvas } = state.els;
    diffCanvas.replaceChildren();
    if (!diffText || !diffText.trim()) {
      diffCanvas.appendChild(el("div", { class: "cg-diff-stub", text: t("changes.diff.same", "这个文件的内容没有变化。") }));
      return;
    }
    if (/^Binary files .* differ$/m.test(diffText)) {
      diffCanvas.appendChild(el("div", { class: "cg-diff-stub", text: t("changes.diff.binary", "二进制文件，无法逐行对比。") }));
      return;
    }
    const lines = diffText.split("\n");
    const shown = Math.min(lines.length, MAX_DIFF_LINES);
    const frag = document.createDocumentFragment();
    for (let i = 0; i < shown; i++) {
      const line = lines[i];
      let cls = "cg-diff-line";
      if (line.startsWith("@@")) cls += " hunk";
      else if (line.startsWith("+") && !line.startsWith("+++")) cls += " add";
      else if (line.startsWith("-") && !line.startsWith("---")) cls += " del";
      else if (line.startsWith("diff --git") || line.startsWith("index ") ||
               line.startsWith("---") || line.startsWith("+++")) cls += " meta";
      frag.appendChild(el("div", { class: cls, text: line || " " }));
    }
    diffCanvas.appendChild(frag);
    if (lines.length > MAX_DIFF_LINES) {
      diffCanvas.appendChild(el("div", { class: "cg-diff-stub",
        text: t("changes.diff.truncated", "差异过大，仅显示前 {{n}} 行").replace("{{n}}", String(MAX_DIFF_LINES)) }));
    }
  }

  async function loadDiff(path) {
    const { diffPathEl, diffCanvas } = state.els;
    diffPathEl.textContent = path;
    diffCanvas.replaceChildren(el("div", { class: "cg-diff-stub", text: t("changes.diff.loading", "正在读取差异…") }));
    let res;
    try {
      res = await api(state.sessionId, `diff?file=${encodeURIComponent(path)}`);
    } catch (_e) {
      if (state.selected === path) {
        diffCanvas.replaceChildren(el("div", { class: "cg-diff-stub", text: t("changes.diff.fail", "读取差异失败") }));
      }
      return;
    }
    if (state.selected !== path) return;
    renderDiffText(res.diff || "");
  }

  function selectFile(path) {
    if (state.selected === path) return;
    state.selected = path;
    state.els.panelEl.classList.add("has-diff");
    highlightSelected();
    ensureAsideWidth();
    loadDiff(path);
  }

  function closeDiff() {
    if (!state.els) return;
    state.selected = null;
    state.els.panelEl.classList.remove("has-diff");
    state.els.diffPathEl.textContent = "";
    state.els.diffCanvas.replaceChildren();
    highlightSelected();
  }

  async function doCommit(sessionId, ctx) {
    const { saveBtn, hint } = state.els;
    const paths = state.files.filter((f) => state.checked.has(f.path)).map((f) => f.path);
    if (!paths.length) return;

    const message = await Modal.prompt(t("changes.save.promptMsg", "给这个版本写句说明"), autoMessage());
    if (message == null) return;

    saveBtn.disabled = true;
    hint.textContent = t("changes.save.saving", "正在存档…");
    try {
      const res = await api(sessionId, "commit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: message, files: paths }),
      });
      if (res.ok) {
        hint.textContent = t("changes.save.done", "已存档");
        refresh(sessionId, ctx);
      } else {
        hint.textContent = res.error || t("changes.save.failed", "存档失败");
        saveBtn.disabled = false;
      }
    } catch (_e) {
      hint.textContent = t("changes.save.failed", "存档失败");
      saveBtn.disabled = false;
    }
  }

  // ── Revert (single file, destructive) ────────────────────────────────────
  // Two-step inline confirm: the first click arms the button into a red
  // "Discard?" for a few seconds, the second click fires the request. Arming
  // a button disarms any other, so at most one confirm is ever pending.

  let revertArmed = null;
  let revertTimer = null;
  let revertPrevHtml = null;

  function disarmRevert() {
    if (revertTimer) { clearTimeout(revertTimer); revertTimer = null; }
    const btn = revertArmed;
    revertArmed = null;
    if (!btn || !btn.isConnected) return;
    btn.classList.remove("armed");
    btn.innerHTML = revertPrevHtml;
  }

  function armRevert(btn) {
    disarmRevert();
    revertArmed = btn;
    revertPrevHtml = btn.innerHTML;
    btn.classList.add("armed");
    btn.replaceChildren(document.createTextNode(t("changes.restore.confirm", "确认丢弃？")));
    revertTimer = setTimeout(disarmRevert, 4000);
  }

  function onRevertClick(btn, path) {
    if (btn.classList.contains("armed")) {
      disarmRevert();
      doRevert(path);
    } else {
      armRevert(btn);
    }
  }

  async function doRevert(path) {
    const { hint } = state.els;
    hint.textContent = t("changes.restore.doing", "正在撤销…");
    let res;
    try {
      res = await api(state.sessionId, "restore", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ file: path }),
      });
    } catch (_e) {
      hint.textContent = t("changes.restore.failed", "撤销失败");
      return;
    }
    if (!res.ok) {
      hint.textContent = res.error || t("changes.restore.failed", "撤销失败");
      return;
    }
    hint.textContent = t("changes.restore.done", "已撤销：{{path}}").replace("{{path}}", path);
    refresh(state.sessionId, state.ctx);
  }

  function renderNotice(message, cls) {
    if (!state.els) return;
    closeDiff();
    state.els.h.textContent = "";
    state.els.sub.textContent = "";
    state.els.branchNote.style.display = "none";
    state.els.listEl.replaceChildren(el("div", { class: cls, text: message }));
    state.files = [];
    state.allPaths = new Set();
    state.checked = new Set();
    updateFoot();
  }

  async function refresh(sessionId, ctx) {
    if (!state.els) return;
    const { h, sub, branchNote, branchCode } = state.els;

    let status;
    try {
      status = await api(sessionId, "status");
    } catch (_e) {
      renderNotice(t("changes.error", "读取改动失败"), "changes-error");
      return;
    }
    if (!status.repo) {
      if (ctx && ctx.setBadge) ctx.setBadge(null);
      renderNotice(t("changes.noRepo", "这个项目还没有启用版本管理。"), "changes-empty");
      return;
    }

    state.sessionId = sessionId;
    const files = status.files || [];

    const prevChecked = state.checked;
    const prevAll = state.allPaths;
    state.files = files;
    state.allPaths = new Set(files.map((f) => f.path));
    // Keep prior choices; files that just appeared default to checked.
    state.checked = new Set(files.map((f) => f.path)
      .filter((p) => prevChecked.has(p) || !prevAll.has(p)));

    if (ctx && ctx.setBadge) ctx.setBadge(files.length || null);

    const count = files.length;
    if (count === 0) {
      h.textContent = t("changes.cleanTitle", "暂无改动");
    } else {
      h.replaceChildren(
        document.createTextNode(t("changes.changedPre", "AI 改了 ")),
        el("b", { text: `${count} ${t("changes.filesUnit", "个文件")}` }),
      );
    }
    sub.textContent = t("changes.sub", "由 Git 管理 · 自上次存档以来");

    const branch = (status.branch || "").trim();
    if (branch && !MAIN_BRANCHES[branch.toLowerCase()]) {
      branchCode.textContent = branch;
      branchNote.style.display = "flex";
    } else {
      branchNote.style.display = "none";
    }

    renderList();
    updateFoot();

    if (state.selected) {
      if (state.allPaths.has(state.selected)) {
        loadDiff(state.selected);
      } else {
        closeDiff();
      }
    }
  }

  // The badge must be live from the moment the tab bar renders, not only after
  // the tab body is lazily opened. These track the mounted body so the badge's
  // subscriptions can also refresh the visible panel once it has been opened.
  let activeRoot = null;
  let activeBody = null;
  let activeSessionId = null;

  async function refreshBadge(sessionId, ctx) {
    if (!ctx || !ctx.setBadge) return;
    let status;
    try {
      status = await api(sessionId, "status");
    } catch (_e) {
      ctx.setBadge(null);
      return;
    }
    ctx.setBadge(status.repo ? ((status.files || []).length || null) : null);
  }

  // One status fetch per change event: refresh the body if it's already open
  // (refresh() also updates the badge), otherwise just update the badge.
  function onFilesChanged(sessionId, ctx) {
    if (activeSessionId === sessionId && activeRoot && activeBody) {
      refresh(sessionId, ctx);
    } else {
      refreshBadge(sessionId, ctx);
    }
  }

  Clacky.ext.ui.mount("session.aside", (container, ctx) => {
    if (!ctx || !ctx.sessionId) return;

    const h = el("div", { class: "h" });
    const sub = el("div", { class: "sub" });
    const branchCode = el("code");
    const branchNote = el("div", { class: "changes-branch" });
    branchNote.appendChild(document.createTextNode(t("changes.branchPre", "当前分支：")));
    branchNote.appendChild(branchCode);
    branchNote.style.display = "none";

    const allCheck = el("input", { class: "cg-check", type: "checkbox" });
    allCheck.addEventListener("change", () => {
      state.checked = allCheck.checked ? new Set(state.files.map((f) => f.path)) : new Set();
      syncRowChecks();
      updateFoot();
    });
    const countLabel = el("span", { class: "cg-count" });
    const listbar = el("div", { class: "cg-listbar" }, allCheck,
      el("span", { text: t("changes.select.all", "全选") }), countLabel);

    const listEl = el("div", { class: "changes-list" });
    const listPane = el("div", { class: "cg-list-pane" }, listbar, listEl);

    const diffPathEl = el("span", { class: "cg-diff-path" });
    const diffRevert = el("button", { class: "cg-diff-revert", type: "button",
      title: t("changes.restore.title", "撤销此文件的改动") });
    diffRevert.innerHTML = ICON_REVERT;
    diffRevert.appendChild(document.createTextNode(t("changes.restore.diffBtn", "撤销改动")));
    diffRevert.addEventListener("click", () => {
      if (state.selected) onRevertClick(diffRevert, state.selected);
    });
    const diffClose = el("button", { class: "cg-diff-close", type: "button", title: t("workspace.closeTab", "关闭") });
    diffClose.innerHTML = ICON_CLOSE;
    diffClose.addEventListener("click", closeDiff);
    const diffCanvas = el("div", { class: "cg-diff" });
    const diffPane = el("div", { class: "cg-diff-pane" },
      el("div", { class: "cg-diff-head" }, diffPathEl, diffRevert, diffClose), diffCanvas);

    const saveBtn = el("button", { class: "changes-save-btn", type: "button", text: t("changes.save.btn", "存档当前版本") });
    const hint = el("div", { class: "changes-hint" });

    const panel = el("div", { class: "changes-panel" },
      el("div", { class: "changes-summary" }, h, sub, branchNote),
      el("div", { class: "cg-body" }, listPane, diffPane),
      el("div", { class: "changes-foot" }, saveBtn, hint));
    saveBtn.addEventListener("click", () => doCommit(ctx.sessionId, ctx));

    const root = el("div", { class: "changes-root", "data-panel": "changes" }, panel);
    container.appendChild(root);

    state.sessionId = ctx.sessionId;
    state.ctx = ctx;
    state.files = [];
    state.checked = new Set();
    state.allPaths = new Set();
    state.selected = null;
    state.els = { panelEl: panel, h, sub, branchNote, branchCode, allCheck, countLabel,
                   listEl, diffPathEl, diffCanvas, saveBtn, hint };

    activeRoot = root;
    activeBody = panel;
    activeSessionId = ctx.sessionId;
    refresh(ctx.sessionId, ctx);
  }, {
    order: 30,
    tab: {
      id: "changes",
      label: () => t("changes.tab"),
      // Runs eagerly when the tab bar renders (before the user opens the tab):
      // prime the badge, then keep it in sync as the agent finishes rounds or
      // files are saved from the workspace viewer. The returned teardown is run
      // on the next render pass / session switch.
      onAttach(ctx) {
        if (!ctx || !ctx.sessionId) return;
        const sid = ctx.sessionId;
        refreshBadge(sid, ctx);
        const onChange = (payload) => {
          if (payload && payload.sessionId === sid) onFilesChanged(sid, ctx);
        };
        const unsubscribeComplete = Clacky.ext.subscribe("session:complete", onChange);
        const unsubscribeFileSaved = Clacky.ext.subscribe("workspace:fileSaved", onChange);
        return () => {
          unsubscribeComplete();
          unsubscribeFileSaved();
          if (activeSessionId === sid) {
            activeRoot = null;
            activeBody = null;
            activeSessionId = null;
            state.els = null;
            state.selected = null;
          }
        };
      },
    },
  });
})();
