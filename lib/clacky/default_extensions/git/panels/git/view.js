// ── Official panel: changes (git, made friendly) ──────────────────────────
//
// "改动 / Changes": a non-technical view of what the AI changed, backed by the
// built-in git API (GET/POST /api/sessions/:id/git/*). Mounted as a tab in the
// "session.aside" slot, attached to agents via `attach: [coding]` in ext.yml.
//
// Deliberately hides git jargon: no porcelain status codes (M/??), no
// branch/ahead/behind unless the branch is NOT the main line (main/master) —
// then it's surfaced as a gentle notice. The only write is a zero-input
// "save version" that auto-generates the commit message.
//
// Native DOM + textContent on all git output (paths, branch) so nothing can
// inject. tab.badge tracks the number of changed files.
// ───────────────────────────────────────────────────────────────────────────

(() => {
  if (!window.Clacky || !Clacky.ext) return;

  const MAIN_BRANCHES = { main: true, master: true };
  const t = (k, fallback) => {
    const v = (typeof I18n !== "undefined") ? I18n.t(k) : null;
    return (v && v !== k) ? v : fallback;
  };

  if (!document.getElementById("changes-panel-style")) {
    const style = document.createElement("style");
    style.id = "changes-panel-style";
    style.textContent = `
      .changes-panel { display: flex; flex-direction: column; flex: 1; min-height: 0; }
      .changes-summary { flex: none; padding: 14px 16px 10px; border-bottom: 1px solid var(--color-border-secondary); }
      .changes-summary .h { font-size: 13px; color: var(--color-text-secondary); }
      .changes-summary .h b { color: var(--color-text-primary); }
      .changes-summary .sub { font-size: 12px; color: var(--color-text-tertiary); margin-top: 3px; }
      .changes-branch { display: flex; align-items: center; gap: 6px; margin-top: 8px; padding: 5px 8px; border-radius: var(--radius-sm); background: var(--color-warning-bg); color: var(--color-warning); font-size: 11.5px; }
      .changes-branch code { font-family: ui-monospace, monospace; font-weight: 600; }
      .changes-list { flex: 1; min-height: 0; overflow: auto; padding: 6px 8px; }
      .change-row { display: flex; align-items: center; gap: 8px; padding: 7px 8px; border-radius: var(--radius-sm); }
      .change-row:hover { background: var(--color-bg-hover); }
      .change-tag { flex: none; font-size: 11px; padding: 1px 7px; border-radius: var(--radius-pill); font-weight: 500; }
      .change-tag.add { background: var(--color-success-bg); color: var(--color-success); }
      .change-tag.mod { background: #eff6ff; color: #2563eb; }
      .change-tag.del { background: var(--color-error-bg); color: var(--color-error); }
      .change-path { font-size: 13px; color: var(--color-text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .change-dir { color: var(--color-text-tertiary); }
      .changes-foot { flex: none; padding: 12px 16px; border-top: 1px solid var(--color-border-primary); }
      .changes-save-btn { width: 100%; padding: 9px; border: none; border-radius: var(--radius-md); background: var(--color-accent-primary); color: var(--color-text-inverse); font-size: 13px; font-weight: 500; cursor: pointer; }
      .changes-save-btn:hover:not(:disabled) { background: var(--color-accent-hover); }
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

  function renderFiles(files) {
    const list = el("div", { class: "changes-list" });
    files.forEach((f) => {
      const kind = classify(f);
      const { dir, name } = splitPath(f.path);
      const path = el("span", { class: "change-path" });
      if (dir) path.appendChild(el("span", { class: "change-dir", text: dir }));
      path.appendChild(document.createTextNode(name));
      list.appendChild(el("div", { class: "change-row" },
        el("span", { class: `change-tag ${kind}`, text: TAG_LABEL[kind]() }),
        path,
      ));
    });
    return list;
  }

  async function refresh(sessionId, root, body, ctx) {
    body.replaceChildren(el("div", { class: "changes-loading", text: t("changes.loading", "正在读取改动…") }));

    let status;
    try {
      status = await api(sessionId, "status");
    } catch (_e) {
      body.replaceChildren(el("div", { class: "changes-error", text: t("changes.error", "读取改动失败") }));
      return;
    }
    if (!status.repo) {
      if (ctx && ctx.setBadge) ctx.setBadge(null);
      body.replaceChildren(el("div", { class: "changes-empty", text: t("changes.noRepo", "这个项目还没有启用版本管理。") }));
      return;
    }

    const files = status.files || [];
    if (ctx && ctx.setBadge) ctx.setBadge(files.length || null);

    const count = files.length;
    const summary = el("div", { class: "changes-summary" });
    const h = el("div", { class: "h" });
    if (count === 0) {
      h.textContent = t("changes.cleanTitle", "暂无改动");
    } else {
      h.appendChild(document.createTextNode(t("changes.changedPre", "AI 改了 ")));
      h.appendChild(el("b", { text: `${count} ${t("changes.filesUnit", "个文件")}` }));
    }
    summary.appendChild(h);
    summary.appendChild(el("div", { class: "sub", text: t("changes.sub", "由 Git 管理 · 自上次存档以来") }));

    const branch = (status.branch || "").trim();
    if (branch && !MAIN_BRANCHES[branch.toLowerCase()]) {
      const note = el("div", { class: "changes-branch" });
      note.appendChild(document.createTextNode(t("changes.branchPre", "当前分支：")));
      note.appendChild(el("code", { text: branch }));
      summary.appendChild(note);
    }

    const hint = el("div", { class: "changes-hint" });
    const saveBtn = el("button", { class: "changes-save-btn", type: "button", text: t("changes.save.btn", "存档当前版本") });
    saveBtn.disabled = count === 0;
    saveBtn.addEventListener("click", async () => {
      saveBtn.disabled = true;
      hint.textContent = t("changes.save.saving", "正在存档…");
      try {
        const paths = files.map((f) => f.path);
        const res = await api(sessionId, "commit", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ message: autoMessage(), files: paths }),
        });
        if (res.ok) {
          hint.textContent = t("changes.save.done", "已存档，可在「时光机」里回到这个版本");
          refresh(sessionId, root, body, ctx);
        } else {
          hint.textContent = res.error || t("changes.save.failed", "存档失败");
          saveBtn.disabled = false;
        }
      } catch (_e) {
        hint.textContent = t("changes.save.failed", "存档失败");
        saveBtn.disabled = false;
      }
    });

    body.replaceChildren(
      summary,
      count === 0 ? el("div", { class: "changes-empty", text: t("changes.clean", "工作区是干净的，没有未存档的改动。") }) : renderFiles(files),
      el("div", { class: "changes-foot" }, saveBtn, hint),
    );
  }

  Clacky.ext.ui.mount("session.aside", (container, ctx) => {
    if (!ctx || !ctx.sessionId) return;
    const body = el("div", { class: "changes-panel" });
    const root = el("div", { class: "changes-root", "data-panel": "changes" }, body);
    container.appendChild(root);
    refresh(ctx.sessionId, root, body, ctx);

    // The agent only touches files during a round, so re-pull git status when
    // it finishes one. The returned function is the ext teardown, run when the
    // session switches away (otherwise the stale subscription would leak).
    const unsubscribe = Clacky.ext.subscribe("session:complete", (payload) => {
      if (payload && payload.sessionId === ctx.sessionId) {
        refresh(ctx.sessionId, root, body, ctx);
      }
    });
    return unsubscribe;
  }, {
    order: 10,
    tab: { id: "changes", label: () => t("changes.tab") },
  });
})();
