// ── Official panel: changes (git review, made friendly) ───────────────────
//
// "改动 / Changes": a Codex-style review surface for what the AI changed.
// Left pane is a collapsible file tree with per-file +/- counts; right pane is
// one continuous diff stream in status order, with dual line numbers, syntax
// highlighting (hljs) and collapsed gaps between hunks.
//
// There is deliberately no commit button: the agent writes better commit
// messages than a timestamp prompt can, and the Time Machine already covers
// "go back to that state". The only write path is a guarded single-file
// revert (two-step inline confirm, same pattern as the Time Machine's
// destructive switch).
//
// Git jargon stays hidden: no porcelain codes, no ahead/behind. Raw output is
// rendered with textContent everywhere except the hljs spans, which the
// highlighter escapes itself.
// ───────────────────────────────────────────────────────────────────────────

(() => {
  if (!window.Clacky || !Clacky.ext) return;

  const FULL_CONTEXT = 999999;
  const MAX_RENDER_LINES = 8000;
  // Whole-stream budget, not per file. Comparing against a long-lived branch
  // can mean 900 files; laying all of them out at once locks the tab up, so
  // files past the budget render a one-line placeholder that loads on click.
  const VIEW_BUDGET_LINES = 3000;
  const SIDE_WIDTH_KEY = "clacky.git.sideWidth";
  const LAYOUT_KEY = "clacky.git.diffLayout";
  // Below this diff-pane width two columns squeeze the code too hard, so the
  // "auto" layout falls back to the single-column stream.
  const SPLIT_MIN_WIDTH = 640;
  const LAYOUT_MODES = ["auto", "split", "unified"];
  const SIDE_MIN_W = 140;
  const DIFF_MIN_W = 200;
  const LANG_BY_EXT = {
    js: "javascript", mjs: "javascript", cjs: "javascript", jsx: "javascript",
    ts: "typescript", tsx: "typescript", rb: "ruby", rake: "ruby", gemspec: "ruby",
    py: "python", go: "go", rs: "rust", java: "java", kt: "kotlin", swift: "swift",
    c: "c", h: "c", cc: "cpp", cpp: "cpp", hpp: "cpp", m: "objectivec", mm: "objectivec",
    cs: "csharp", php: "php", sh: "bash", bash: "bash", zsh: "bash",
    yml: "yaml", yaml: "yaml", json: "json", md: "markdown", markdown: "markdown",
    html: "xml", erb: "xml", vue: "xml", htm: "xml", xml: "xml",
    css: "css", scss: "scss", less: "less", sql: "sql",
    toml: "ini", ini: "ini", conf: "ini", cfg: "ini", env: "ini",
    diff: "diff", patch: "diff", dockerfile: "dockerfile",
  };

  const ICON_REFRESH = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36L21 8"/><path d="M21 3v5h-5"/></svg>';
  const ICON_COPY = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>';
  const ICON_UNFOLD = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 9l4-4 4 4"/><path d="M16 15l-4 4-4-4"/></svg>';
  const ICON_COLLAPSE = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 13l5-5 5 5"/><path d="M7 19l5-5 5 5"/></svg>';
  const ICON_MORE = '<svg viewBox="0 0 24 24" width="15" height="15" fill="currentColor"><circle cx="5" cy="12" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="19" cy="12" r="1.7"/></svg>';
  const ICON_OPEN_WITH = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 4h6v6"/><path d="M20 4l-8 8"/><path d="M18 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h5"/></svg>';
  const ICON_REVERT = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7v6h6"/><path d="M21 17a9 9 0 0 0-15-6.7L3 13"/></svg>';
  const ICON_FOLDER = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>';
  const ICON_DOWNLOAD = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="M7.5 11l4.5 4.5 4.5-4.5"/><path d="M5 20h14"/></svg>';
  const ICON_ADD_TO_CHAT = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h6"/><path d="M16 5h6"/><path d="M19 2v6"/></svg>';
  const ICON_COPY_REL = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/><path d="M12 19l3-3"/></svg>';
    const ICON_CHEVRON = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18l6-6-6-6"/></svg>';
  const ICON_CARET_DOWN = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>';
  const ICON_ARROW_RIGHT = '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12h15"/><path d="M13 6l6 6-6 6"/></svg>';
  const ICON_CHECK = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12.5l5 5L20 6.5"/></svg>';
  const ICON_BRANCH = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="5" r="2.2"/><circle cx="6" cy="19" r="2.2"/><circle cx="18" cy="8" r="2.2"/><path d="M6 7.2v9.6"/><path d="M18 10.2c0 3.4-3 4.6-6 5.2"/></svg>';
  const ICON_SEARCH = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M16 16l4.5 4.5"/></svg>';
  const ICON_LAYOUT = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M12 4v16"/></svg>';
  const ICON_LAYOUT_UNIFIED = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 12h18"/></svg>';

  const t = (k, fallback) => {
    const v = (typeof I18n !== "undefined") ? I18n.t(k) : null;
    return (v && v !== k) ? v : fallback;
  };
  const fill = (text, vars) => {
    let out = text;
    Object.keys(vars).forEach((k) => { out = out.split(`{{${k}}}`).join(String(vars[k])); });
    return out;
  };

  const LAYOUT_LABELS = {
    auto: () => t("changes.layout.auto", "自动"),
    split: () => t("changes.layout.split", "并排"),
    unified: () => t("changes.layout.unified", "行内"),
  };

  if (!document.getElementById("changes-panel-style")) {
    const style = document.createElement("style");
    style.id = "changes-panel-style";
    style.textContent = `
      .changes-root { container-type: inline-size; display: flex; flex-direction: column; flex: 1; min-height: 0; background: var(--color-bg-primary); }
      .cg-bar { flex: none; display: flex; align-items: center; gap: 8px; padding: 0 8px 0 12px; height: 38px; border-bottom: 1px solid var(--color-border-primary); }
      .cg-bar-stats { display: flex; align-items: center; gap: 7px; min-width: 0; font-family: ui-monospace, monospace; font-size: 12px; font-weight: 600; }
      .cg-bar-add { color: var(--color-success, #2f9e44); }
      .cg-bar-del { color: var(--color-error, #c92a2a); }
      .cg-scope { flex: none; display: inline-flex; align-items: center; gap: 6px; height: 26px; padding: 0 9px 0 10px; border: 1px solid var(--color-border-primary); border-radius: var(--radius-pill); background: transparent; color: var(--color-text-secondary); font-family: inherit; font-size: 12.5px; cursor: pointer; }
      .cg-scope:hover, .cg-scope.is-open { background: var(--color-bg-hover); color: var(--color-text-primary); }
      .cg-scope-label { max-width: 170px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .cg-scope > .cg-caret { display: inline-flex; opacity: 0.65; }
      /* The scope the diff is pinned to (a commit subject, say) rides inside
         the pill; it is long, so it truncates before the +/- counts do. */
      .cg-scope-subject { flex: 0 1 auto; min-width: 0; max-width: 320px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--color-text-tertiary); font-weight: 400; }
      .cg-scope > .cg-bar-add, .cg-scope > .cg-bar-del { flex: none; }
      .cg-compare { flex: 0 1 auto; min-width: 0; font-size: 12.5px; }
      .cg-compare .cg-scope-head, .cg-compare .cg-scope-base { min-width: 0; max-width: 150px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .cg-compare .cg-compare-arrow { display: inline-flex; color: var(--color-text-tertiary); opacity: 0.8; }
      .cg-scope-menu { position: fixed; z-index: 80; min-width: 196px; padding: 7px; border: 1px solid var(--color-border-primary); border-radius: 12px; background: var(--color-bg-primary); box-shadow: 0 14px 38px rgba(0, 0, 0, 0.16), 0 2px 6px rgba(0, 0, 0, 0.06); }
      .cg-scope-item { display: flex; align-items: center; gap: 8px; height: 32px; padding: 0 10px; border-radius: 7px; font-size: 13px; color: var(--color-text-primary); cursor: pointer; white-space: nowrap; }
      .cg-scope-item:hover, .cg-scope-item.is-open { background: var(--color-bg-hover); }
      .cg-scope-item .cg-scope-check { margin-left: auto; display: inline-flex; opacity: 0; color: var(--color-text-primary); }
      .cg-scope-item.is-checked .cg-scope-check { opacity: 1; }
      .cg-scope-item .cg-scope-arrow { margin-left: auto; display: inline-flex; color: var(--color-text-tertiary); }
      .cg-scope-sep { height: 1px; margin: 6px 8px; background: var(--color-border-secondary); }
      .cg-scope-sub { position: fixed; z-index: 81; width: 340px; max-height: 420px; display: flex; flex-direction: column; padding: 6px; border: 1px solid var(--color-border-primary); border-radius: 14px; background: var(--color-bg-primary); box-shadow: 0 18px 46px rgba(0, 0, 0, 0.18), 0 2px 8px rgba(0, 0, 0, 0.06); }
      .cg-scope-search { flex: none; display: flex; align-items: center; gap: 8px; height: 34px; padding: 0 8px; color: var(--color-text-tertiary); }
      .cg-scope-search input { flex: 1; min-width: 0; border: none; background: transparent; color: var(--color-text-primary); font-family: inherit; font-size: 13px; outline: none; }
      .cg-scope-group { flex: none; padding: 8px 10px 6px; font-size: 11.5px; color: var(--color-text-tertiary); }
      .cg-scope-list { flex: 1; min-height: 0; overflow: auto; }
      .cg-scope-branch { display: flex; align-items: center; gap: 8px; height: 32px; padding: 0 10px; border-radius: 7px; font-size: 13px; color: var(--color-text-primary); cursor: pointer; }
      .cg-scope-branch:hover, .cg-scope-branch.is-active { background: var(--color-bg-hover); }
      .cg-scope-branch .cg-scope-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .cg-scope-branch .cg-scope-remote { flex: none; font-size: 10.5px; color: var(--color-text-tertiary); }
      .cg-scope-branch .cg-scope-check { display: inline-flex; opacity: 0; color: var(--color-text-primary); }
      .cg-scope-branch.is-checked .cg-scope-check { opacity: 1; }
      .cg-scope-commit { display: flex; align-items: center; gap: 8px; height: 32px; padding: 0 10px; border-radius: 7px; font-size: 13px; color: var(--color-text-primary); cursor: pointer; }
      .cg-scope-commit:hover, .cg-scope-commit.is-checked { background: var(--color-bg-hover); }
      .cg-scope-commit .cg-scope-subject { flex: 1; min-width: 0; max-width: none; color: var(--color-text-primary); }
      .cg-scope-commit .cg-scope-sha { flex: none; font-family: ui-monospace, monospace; font-size: 11px; color: var(--color-text-tertiary); }
      .cg-scope-commit .cg-scope-check { flex: none; display: inline-flex; opacity: 0; color: var(--color-text-primary); }
      .cg-scope-commit.is-checked .cg-scope-check { opacity: 1; }
      .cg-scope-empty { padding: 10px; font-size: 12px; color: var(--color-text-tertiary); }
      .cg-bar-spacer { flex: 1; }
      .cg-icon-btn { flex: none; display: inline-flex; align-items: center; justify-content: center; width: 26px; height: 26px; padding: 0; border: none; border-radius: var(--radius-sm); background: transparent; color: var(--color-text-secondary); cursor: pointer; }
      .cg-icon-btn:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
      .cg-icon-btn.is-on { background: var(--color-bg-hover); color: var(--color-accent-primary); }
      .cg-body { flex: 1; min-height: 0; display: flex; }
      .cg-side { flex: none; width: 264px; min-width: 0; display: flex; flex-direction: column; border-right: 1px solid var(--color-border-primary); background: var(--color-bg-secondary, transparent); }
      .cg-resizer { flex: none; position: relative; z-index: 3; width: 7px; margin-right: -7px; cursor: col-resize; touch-action: none; }
      .cg-resizer::after { content: ""; position: absolute; top: 0; bottom: 0; left: 0; width: 1px; background: transparent; transition: background-color var(--transition-base); }
      .cg-resizer:hover::after, .cg-resizer.is-active::after { background: var(--color-accent-primary); }
      .changes-root.is-resizing { cursor: col-resize; user-select: none; }
      .changes-root.is-resizing .cg-stream { pointer-events: none; }
      .cg-side-head { flex: none; padding: 10px; border-bottom: 1px solid var(--color-border-secondary); }
      .cg-filter { width: 100%; box-sizing: border-box; height: 30px; padding: 0 10px; border: 1px solid var(--color-border-primary); border-radius: var(--radius-md, 8px); background: var(--color-bg-primary); color: var(--color-text-primary); font-family: inherit; font-size: 12.5px; outline: none; }
      .cg-filter::placeholder { color: var(--color-text-tertiary); }
      .cg-filter:focus { border-color: var(--color-accent-primary); }
      .cg-tree { flex: 1; min-height: 0; overflow: auto; padding: 6px 6px 16px; }
      .cg-dir-row { display: flex; align-items: center; gap: 6px; padding: 6px 8px; border-radius: var(--radius-sm); cursor: pointer; color: var(--color-text-secondary); font-size: 12.5px; user-select: none; }
      .cg-dir-row:hover { background: var(--color-bg-hover); }
      .cg-dir-row .cg-caret { flex: none; width: 12px; height: 12px; display: inline-flex; align-items: center; justify-content: center; transition: transform 0.12s ease; }
      .cg-dir-row.closed .cg-caret { transform: rotate(0deg); }
      .cg-dir-row:not(.closed) .cg-caret { transform: rotate(90deg); }
      .cg-dir-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-family: ui-monospace, monospace; }
      .cg-icon { flex: none; width: 16px; height: 16px; display: inline-flex; align-items: center; justify-content: center; color: var(--color-text-secondary); }
      .cg-icon svg { display: block; }
      .cg-file-row { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: var(--radius-sm); cursor: pointer; font-size: 12.5px; }
      .cg-file-row:hover { background: var(--color-bg-hover); }
      .cg-file-row.active { background: var(--color-accent-soft); }
      .cg-file-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-family: ui-monospace, monospace; color: var(--color-text-primary); }
      .cg-file-row .cg-tag { flex: none; font-size: 10px; font-weight: 700; letter-spacing: 0.02em; }
      .cg-tag.add { color: var(--color-success, #2f9e44); }
      .cg-tag.del { color: var(--color-error, #c92a2a); }
      .cg-tag.mod { color: var(--color-accent-primary); }
      .cg-file-stat { flex: none; display: inline-flex; gap: 4px; font-family: ui-monospace, monospace; font-size: 11px; }
      .cg-file-stat .a { color: var(--color-success, #2f9e44); }
      .cg-file-stat .d { color: var(--color-error, #c92a2a); }
      .cg-main { flex: 1; min-width: 0; min-height: 0; position: relative; display: flex; flex-direction: column; }
      .cg-stream { flex: 1; min-height: 0; overflow: auto; position: relative; }
      .cg-file-head { position: sticky; top: 0; z-index: 2; display: flex; align-items: center; gap: 8px; padding: 6px 10px; background: var(--color-bg-secondary, var(--color-bg-primary)); border-bottom: 1px solid var(--color-border-secondary); box-shadow: 0 -1px 0 var(--color-border-primary); cursor: pointer; }
      /* The top rule is a shadow, not a border: a stuck header's rule must be
         clipped by the scroll box, otherwise it doubles with the toolbar's
         bottom border when the pane is scrolled to a file. */
      .cg-file-head-path { flex: 1; min-width: 0; font-family: ui-monospace, monospace; font-size: 11.5px; color: var(--color-text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .cg-file-head-stat { flex: none; display: inline-flex; gap: 5px; font-family: ui-monospace, monospace; font-size: 11px; }
      .cg-file-head-stat .a { color: var(--color-success, #2f9e44); }
      .cg-file-head-stat .d { color: var(--color-error, #c92a2a); }
      .cg-revert { flex: none; display: inline-flex; align-items: center; gap: 4px; height: 22px; padding: 0 7px; border: none; border-radius: var(--radius-sm); background: transparent; color: var(--color-text-tertiary); font-size: 11px; cursor: pointer; opacity: 0; }
      .cg-file:hover .cg-revert, .cg-revert.armed { opacity: 1; }
      .cg-revert:hover { background: var(--color-error-bg); color: var(--color-error); }
      .cg-revert.armed { background: var(--color-error, #c92a2a); color: #fff; font-weight: 600; }
      .cg-head-more { flex: none; width: 22px; height: 22px; color: var(--color-text-secondary); }
      .cg-head-more:hover, .cg-head-more.is-open { background: var(--color-bg-hover); color: var(--color-text-primary); }
      .cg-fh-caret { flex: none; display: inline-flex; color: var(--color-text-tertiary); transform: rotate(90deg); transition: transform 0.12s ease; }
      .cg-file.is-collapsed .cg-fh-caret { transform: none; }
      .cg-file.is-collapsed .cg-lines { display: none; }
      .cg-lines { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11.5px; line-height: 1.55; padding-bottom: 2px; }
      .cg-line { display: flex; align-items: flex-start; white-space: pre-wrap; overflow-wrap: anywhere; }
      .cg-line.add { background: var(--color-success-soft, rgba(47, 158, 68, 0.12)); }
      .cg-line.del { background: var(--color-error-soft, rgba(201, 42, 42, 0.12)); }
      .cg-ln { flex: none; width: 42px; padding: 0 6px; text-align: right; color: var(--color-text-tertiary); user-select: none; font-size: 10.5px; opacity: 0.75; }
      .cg-code { flex: 1; min-width: 0; padding: 0 12px 0 6px; color: var(--color-text-primary); }
      .cg-line.add .cg-ln, .cg-line.del .cg-ln { opacity: 0.9; }
      .cg-line.split { white-space: normal; }
      .cg-half { flex: 1 1 0; min-width: 0; display: flex; align-items: flex-start; white-space: pre-wrap; overflow-wrap: anywhere; }
      .cg-half.old { border-right: 1px solid var(--color-border-secondary); }
      .cg-half .cg-ln { width: 36px; }
      .cg-half.add { background: var(--color-success-soft, rgba(47, 158, 68, 0.12)); }
      .cg-half.del { background: var(--color-error-soft, rgba(201, 42, 42, 0.12)); }
      .cg-half.blank { background: var(--color-bg-secondary, rgba(127, 127, 127, 0.06)); }
      .cg-fold { display: flex; align-items: center; gap: 7px; padding: 3px 10px 3px 96px; margin: 2px 0; color: var(--color-text-tertiary); font-size: 11px; font-family: ui-monospace, monospace; background: var(--color-bg-secondary, transparent); border-top: 1px dashed var(--color-border-secondary); border-bottom: 1px dashed var(--color-border-secondary); cursor: pointer; }
      .cg-fold:hover { color: var(--color-accent-primary); background: var(--color-accent-soft); }
      .cg-fold .cg-fold-arrow { font-size: 10px; }
      .cg-note { padding: 10px 14px; color: var(--color-text-tertiary); font-size: 11.5px; }
      .cg-lazy { padding: 10px 14px; margin: 4px 12px 8px; color: var(--color-text-secondary); font-size: 11.5px;
        border: 1px dashed var(--color-border-default); border-radius: 6px; cursor: pointer; user-select: none; }
      .cg-lazy:hover { color: var(--color-text-primary); border-color: var(--color-border-strong); }
      .cg-lazy.is-static { cursor: default; }
      .cg-empty, .cg-error { padding: 24px 16px; text-align: center; color: var(--color-text-tertiary); font-size: 12px; }
      .cg-error { color: var(--color-error); }
      .cg-side-empty { padding: 10px; color: var(--color-text-tertiary); font-size: 11.5px; }
      @container (max-width: 900px) {
        .cg-side { width: 220px; }
        .cg-scope-label { max-width: 110px; }
        .cg-scope-subject { max-width: 170px; }
        .cg-compare .cg-scope-head, .cg-compare .cg-scope-base { max-width: 96px; }
      }
      @container (max-width: 700px) {
        .cg-side { width: 190px; }
        /* The pill keeps its content width - stretching it turns a short scope
           name into a bar-wide capsule. It may still shrink when a commit
           subject is long: that subject truncates instead of disappearing. */
        .cg-scope { max-width: 100%; }
        .cg-scope-subject { max-width: none; }
      }
      @container (max-width: 520px) {
        .cg-side { width: 156px; }
        .cg-compare .cg-scope-head, .cg-compare .cg-scope-base { max-width: 84px; }
      }
      @container (max-width: 460px) {
        /* Too narrow for the scope pill and the compare pill on one line:
           the toolbar wraps and the pills take the full second row. */
        .cg-bar { height: auto; min-height: 38px; flex-wrap: wrap; padding-block: 6px; row-gap: 6px; }
        .cg-bar-stats { order: 2; flex: 1 0 100%; }
        .cg-scope-subject { max-width: 180px; }
        .cg-compare .cg-scope-head, .cg-compare .cg-scope-base { max-width: 62px; }
      }
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

  function fileIconEl(name) {
    const view = window.Clacky && Clacky.WorkspaceView;
    if (!view || !view.fileIcon) return null;
    const span = el("span", { class: "cg-icon" });
    span.innerHTML = view.fileIcon(name);
    return span;
  }

  function folderIconEl(open) {
    const view = window.Clacky && Clacky.WorkspaceView;
    if (!view || !view.iconFolder) return null;
    const span = el("span", { class: "cg-icon" });
    span.innerHTML = open ? view.iconFolderOpen : view.iconFolder;
    return span;
  }

  function clampSideWidth(width, bodyEl) {
    const bodyW = bodyEl.getBoundingClientRect().width;
    const max = Math.max(SIDE_MIN_W, bodyW - DIFF_MIN_W);
    return Math.round(Math.min(Math.max(width, SIDE_MIN_W), max));
  }

  // The tree keeps a fixed pixel width once the user drags it; without a
  // stored width it falls back to the container-query defaults.
  function setupSideResizer(root, body, side) {
    const handle = el("div", { class: "cg-resizer", role: "separator",
      "aria-orientation": "vertical", tabindex: "0",
      title: t("changes.resizeTree", "拖动调整文件树宽度（双击复位）") });

    let startX = 0;
    let startW = 0;
    let desired = 0;

    const stored = () => {
      try { return parseInt(localStorage.getItem(SIDE_WIDTH_KEY), 10) || 0; } catch (_e) { return 0; }
    };
    const persist = (w) => {
      desired = Math.round(w);
      try { localStorage.setItem(SIDE_WIDTH_KEY, String(desired)); } catch (_e) { /* ignore */ }
    };
    const applyDesired = () => {
      if (!desired) return;
      side.style.width = clampSideWidth(desired, body) + "px";
    };

    const onMove = (e) => {
      side.style.width = clampSideWidth(startW + (e.clientX - startX), body) + "px";
    };
    const stop = () => {
      handle.classList.remove("is-active");
      root.classList.remove("is-resizing");
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerup", stop);
      document.removeEventListener("pointercancel", stop);
      persist(parseFloat(side.style.width));
    };

    handle.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      startX = e.clientX;
      startW = side.getBoundingClientRect().width;
      handle.classList.add("is-active");
      root.classList.add("is-resizing");
      document.addEventListener("pointermove", onMove);
      document.addEventListener("pointerup", stop);
      document.addEventListener("pointercancel", stop);
      handle.setPointerCapture(e.pointerId);
    });

    handle.addEventListener("dblclick", () => {
      desired = 0;
      side.style.removeProperty("width");
      try { localStorage.removeItem(SIDE_WIDTH_KEY); } catch (_e) { /* ignore */ }
    });

    handle.addEventListener("keydown", (e) => {
      if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
      e.preventDefault();
      const base = side.getBoundingClientRect().width;
      const next = clampSideWidth(base + (e.key === "ArrowLeft" ? -16 : 16), body);
      persist(next);
      applyDesired();
    });

    // The panel mounts before it is laid out, so the saved width is applied on
    // the first observer tick — and re-clamped whenever the aside is resized.
    desired = stored();
    if (typeof ResizeObserver !== "undefined") {
      const ro = new ResizeObserver(() => {
        if (!body.isConnected) { ro.disconnect(); return; }
        if (body.getBoundingClientRect().width > 0) applyDesired();
      });
      ro.observe(body);
    } else {
      requestAnimationFrame(applyDesired);
    }

    return handle;
  }

  async function api(sessionId, action, opts) {
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/git/${action}`, opts);
    return res.json();
  }

  function scopeQuery() {
    const parts = [`scope=${encodeURIComponent(state.scope)}`];
    if (state.scope === "branch" && state.base) {
      parts.push(`base=${encodeURIComponent(state.base)}`);
    } else if (state.scope === "committed" && state.commit) {
      parts.push(`base=${encodeURIComponent(state.commit)}`);
    }
    return parts.join("&");
  }

  function classify(f) {
    if (f.untracked) return "add";
    const code = `${f.x || ""}${f.y || ""}`;
    if (code.includes("D")) return "del";
    if (code.includes("A")) return "add";
    return "mod";
  }

  const TAG_LABEL = {
    add: () => t("changes.tag.add", "A"),
    mod: () => t("changes.tag.mod", "M"),
    del: () => t("changes.tag.del", "D"),
  };

  function langFor(path) {
    const base = path.split("/").pop().toLowerCase();
    if (base === "dockerfile") return "dockerfile";
    if (base === "gemfile" || base === "rakefile" || base === "podfile") return "ruby";
    const ext = base.includes(".") ? base.split(".").pop() : "";
    return LANG_BY_EXT[ext] || null;
  }

  // One hljs pass per line: multi-line constructs (block comments, heredocs)
  // lose their state, but it keeps rendering linear and predictable on files
  // with thousands of changed lines.
  function highlightLine(text, lang) {
    if (!lang || !window.hljs || !hljs.getLanguage) return null;
    if (!hljs.getLanguage(lang)) return null;
    try {
      return hljs.highlight(text, { language: lang, ignoreIllegals: true }).value;
    } catch (_e) {
      return null;
    }
  }

  // ── diff parsing ────────────────────────────────────────────────────────
  // [{ oldStart:, oldCount:, newStart:, newCount:, lines: [...] }]
  function parseHunks(text) {
    const hunks = [];
    let hunk = null;
    let oldNo = 0;
    let newNo = 0;
    const raw = text.split("\n");
    for (let i = 0; i < raw.length; i++) {
      const line = raw[i];
      if (line.startsWith("@@")) {
        const m = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(line);
        if (!m) { hunk = null; continue; }
        oldNo = parseInt(m[1], 10);
        newNo = parseInt(m[3], 10);
        hunk = {
          oldStart: oldNo,
          oldCount: m[2] === undefined ? 1 : parseInt(m[2], 10),
          newStart: newNo,
          newCount: m[4] === undefined ? 1 : parseInt(m[4], 10),
          lines: [],
        };
        hunks.push(hunk);
        continue;
      }
      if (!hunk) continue;
      if (line.startsWith("\\")) continue;
      if (line.startsWith("+")) {
        hunk.lines.push({ type: "add", oldNo: null, newNo: newNo++, text: line.slice(1) });
      } else if (line.startsWith("-")) {
        hunk.lines.push({ type: "del", oldNo: oldNo++, newNo: null, text: line.slice(1) });
      } else if (line.startsWith(" ")) {
        hunk.lines.push({ type: "ctx", oldNo: oldNo++, newNo: newNo++, text: line.slice(1) });
      }
    }
    return hunks;
  }

  const state = {
    sessionId: null,
    ctx: null,
    els: null,
    files: [],
    records: new Map(),      // path -> { file, full, expanded }
    collapsedDirs: new Set(),
    filter: "",
    activePath: null,
    renderTruncated: 0,
    budget: 0,
    // Which slice of history the panel shows. `branch` compares the current
    // HEAD against a branch the user picked in the compare pill; `committed`
    // compares it against a commit picked from the menu. Both start out on the
    // server's default base (the upstream) and keep their pick separately, so
    // switching scopes never loses the other one.
    scope: "worktree",
    base: "",
    commit: "",
    branch: "",
    branches: null,
    commits: null,
    note: null,
    // Diff layout: "unified" (one column, the default), "split" (always
    // side-by-side) or "auto" (side-by-side when the pane is wide enough).
    layout: "unified",
    // True while re-rendering bodies after a layout change, so the render
    // budget is not charged twice for the same lines.
    reflow: false,
    layoutMenu: null,
    ro: null,
  };

  // ── tree ────────────────────────────────────────────────────────────────
  function buildTree(files) {
    const root = { name: "", path: "", dirs: new Map(), files: [] };
    files.forEach((f) => {
      const parts = f.path.split("/");
      let node = root;
      for (let i = 0; i < parts.length - 1; i++) {
        const name = parts[i];
        if (!node.dirs.has(name)) {
          node.dirs.set(name, {
            name: name,
            path: parts.slice(0, i + 1).join("/"),
            dirs: new Map(),
            files: [],
          });
        }
        node = node.dirs.get(name);
      }
      node.files.push(f);
    });
    return root;
  }

  function matchesFilter(file) {
    return !state.filter || file.path.toLowerCase().includes(state.filter);
  }

  // ── context menu ────────────────────────────────────────────────────────
  function closeFileMenu() {
    document.querySelectorAll(".cg-file-menu").forEach((n) => n.remove());
    document.querySelectorAll(".cg-head-more.is-open").forEach((b) => b.classList.remove("is-open"));
  }

  function menuEntry(path) {
    return { path: path, name: path.split("/").pop() || path };
  }

  function copyToClipboard(text) {
    navigator.clipboard.writeText(text).then(() => Modal.toast(text, "info"));
  }

  async function copyAbsPath(path) {
    const entry = menuEntry(path);
    let target = Clacky.Workspace.absPath(path);
    try {
      target = await Clacky.Workspace.displayPath(entry);
    } catch (_e) { /* fall back to the absolute path */ }
    copyToClipboard(target);
  }

  function addToChat(path) {
    if (typeof Sessions === "undefined" || typeof Sessions.attachWorkspaceFile !== "function") return;
    const entry = menuEntry(path);
    Sessions.attachWorkspaceFile({
      type: "file",
      name: entry.name,
      path: Clacky.Workspace.absPath(path),
    });
  }

  async function revealInFinder(path) {
    try {
      await Clacky.Workspace.revealFile(menuEntry(path));
    } catch (_e) {
      Modal.toast(t("workspace.revealFailed", "无法打开文件位置"), "error");
    }
  }

  async function downloadPath(path) {
    const entry = menuEntry(path);
    try {
      const blob = await Clacky.Workspace.fetchFileBlob(entry);
      const url = URL.createObjectURL(blob);
      const a = el("a", { href: url, download: entry.name });
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } catch (_e) {
      Modal.toast(t("workspace.downloadFailed", "下载失败"), "error");
    }
  }

  function openInEditor(path) {
    Clacky.Workspace.openWithDefault(menuEntry(path)).catch((err) => {
      const reason = err && err.message ? ": " + err.message : "";
      Modal.toast(t("workspace.openWithFailed", "无法用默认应用打开") + reason, "error");
    });
  }

  // items: [action, icon, label, run, disabled]
  function buildMenu(items) {
    const menu = el("div", { class: "session-context-menu cg-file-menu" });
    items.forEach(([action, icon, label, run, disabled]) => {
      const item = el("div", {
        class: "session-actions-menu-item" + (disabled ? " session-actions-menu-item--disabled" : ""),
        "data-action": action
      });
      const iconEl = el("span", { class: "session-actions-menu-icon" });
      iconEl.innerHTML = icon;
      item.appendChild(iconEl);
      item.appendChild(el("span", { class: "session-actions-menu-label", text: label }));
      item.addEventListener("click", () => {
        if (disabled) return;
        closeFileMenu();
        run();
      });
      menu.appendChild(item);
    });
    menu.addEventListener("contextmenu", (e) => e.preventDefault());
    return menu;
  }

  // Drops the menu at a viewport point and keeps it inside the window.
  // align "right" pins the menu's right edge to x (used by header buttons).
  function placeMenu(menu, x, y, align) {
    document.body.appendChild(menu);
    menu.style.position = "fixed";
    const w = menu.offsetWidth;
    const h = menu.offsetHeight;
    let left = align === "right" ? x - w : x;
    let top = y;
    left = Math.min(Math.max(8, left), Math.max(8, window.innerWidth - w - 8));
    top = Math.min(Math.max(8, top), Math.max(8, window.innerHeight - h - 8));
    menu.style.left = left + "px";
    menu.style.top = top + "px";
    setTimeout(() => {
      document.addEventListener("click", closeFileMenu, { once: true });
    }, 0);
  }

  function openFileMenu(ev, path, isDir) {
    closeFileMenu();

    const items = [];
    if (!isDir) {
      items.push(["addtochat", ICON_ADD_TO_CHAT, t("workspace.addToChat", "添加到聊天"), () => addToChat(path)]);
    }
    items.push(["reveal", ICON_FOLDER, t("workspace.revealInFinder", "打开所在文件夹"), () => revealInFinder(path)]);
    items.push(["copypath", ICON_COPY, t("workspace.copyPath", "复制路径"), () => copyAbsPath(path)]);
    items.push(["copyrelpath", ICON_COPY_REL, t("workspace.copyRelPath", "复制相对路径"), () => copyToClipboard(path)]);
    if (!isDir) {
      items.push(["download", ICON_DOWNLOAD, t("workspace.download", "下载"), () => downloadPath(path)]);
    }

    placeMenu(buildMenu(items), ev.clientX, ev.clientY);
  }

  function openHeadMenu(anchor, file) {
    closeFileMenu();
    const record = state.records.get(file.path);
    const collapsed = !!(record && record.collapsed);
    const foldLabel = collapsed
      ? t("changes.menu.expandFile", "展开文件")
      : t("changes.menu.collapseFile", "折叠文件");

    const items = [
      ["copypath", ICON_COPY, t("changes.menu.copyPath", "复制路径"), () => copyAbsPath(file.path)],
      ["openineditor", ICON_OPEN_WITH, t("changes.menu.openInEditor", "在编辑器中打开"), () => openInEditor(file.path)],
      [collapsed ? "expand" : "collapse", collapsed ? ICON_UNFOLD : ICON_COLLAPSE, foldLabel,
        () => setFileCollapsed(file.path, !collapsed)]
    ];

    anchor.classList.add("is-open");
    const r = anchor.getBoundingClientRect();
    placeMenu(buildMenu(items), r.right, r.bottom + 4, "right");
  }

  function renderTree() {
    const tree = state.els.tree;
    tree.replaceChildren();
    const filtered = state.files.filter(matchesFilter);
    const root = buildTree(filtered);
    state.els.sideEmpty.style.display = (state.files.length && !filtered.length) ? "" : "none";
    if (!filtered.length) return;

    // A path that is only a chain of single-child directories (`a/b/c/file.js`)
    // is folded into one row, so a deep tree does not push the filename out of
    // view. The row's path stays the deepest directory's path.
    const foldChain = (dir) => {
      let node = dir;
      let label = dir.name;
      while (node.files.length === 0 && node.dirs.size === 1) {
        node = Array.from(node.dirs.values())[0];
        label += "/" + node.name;
      }
      return { node: node, label: label };
    };

    const walk = (node, depth) => {
      const dirs = Array.from(node.dirs.values()).sort((a, b) => a.name.localeCompare(b.name));
      dirs.forEach((dir) => {
        const chain = foldChain(dir);
        const closed = !state.filter && state.collapsedDirs.has(chain.node.path);
        const row = el("div", { class: "cg-dir-row" + (closed ? " closed" : "") });
        row.style.paddingLeft = `${8 + depth * 12}px`;
        row.title = chain.node.path;
        const caret = el("span", { class: "cg-caret" });
        caret.innerHTML = ICON_CHEVRON;
        row.appendChild(caret);
        row.appendChild(folderIconEl(!closed));
        row.appendChild(el("span", { class: "cg-dir-name", text: chain.label }));
        row.addEventListener("click", () => {
          if (state.filter) return;
          if (state.collapsedDirs.has(chain.node.path)) state.collapsedDirs.delete(chain.node.path);
          else state.collapsedDirs.add(chain.node.path);
          renderTree();
        });
        row.addEventListener("contextmenu", (ev) => {
          ev.preventDefault();
          openFileMenu(ev, chain.node.path, true);
        });
        tree.appendChild(row);
        if (!closed) walk(chain.node, depth + 1);
      });

      node.files
        .slice()
        .sort((a, b) => a.path.localeCompare(b.path))
        .forEach((file) => {
          const kind = classify(file);
          const name = file.path.split("/").pop();
          const row = el("div", { class: "cg-file-row" + (file.path === state.activePath ? " active" : "") });
          row.style.paddingLeft = `${10 + depth * 12}px`;
          row.dataset.path = file.path;
          row.title = file.path;
          row.appendChild(el("span", { class: `cg-tag ${kind}`, text: TAG_LABEL[kind]() }));
          const icon = fileIconEl(name);
          if (icon) row.appendChild(icon);
          row.appendChild(el("span", { class: "cg-file-name", text: name }));
          const stat = el("span", { class: "cg-file-stat" });
          if (file.add) stat.appendChild(el("span", { class: "a", text: `+${file.add}` }));
          if (file.del) stat.appendChild(el("span", { class: "d", text: `-${file.del}` }));
          row.appendChild(stat);
          row.addEventListener("click", () => {
            focusFile(file.path);
          });
          row.addEventListener("contextmenu", (ev) => {
            ev.preventDefault();
            openFileMenu(ev, file.path, false);
          });
          tree.appendChild(row);
        });
    };
    walk(root, 0);
  }

  // ── diff stream ─────────────────────────────────────────────────────────
  function buildFileSection(file) {
    const kind = classify(file);
    const section = el("section", { class: "cg-file" });
    section.dataset.path = file.path;

    const revert = el("button", { class: "cg-revert", type: "button",
      title: t("changes.restore.title", "撤销此文件的改动") });
    revert.innerHTML = ICON_REVERT;
    revert.addEventListener("click", (e) => {
      e.stopPropagation();
      onRevertClick(revert, file.path);
    });

    const more = el("button", { class: "cg-icon-btn cg-head-more", type: "button",
      title: t("changes.menu.more", "更多"), "aria-label": t("changes.menu.more", "更多") });
    more.innerHTML = ICON_MORE;
    more.addEventListener("click", (e) => {
      e.stopPropagation();
      if (more.classList.contains("is-open")) {
        closeFileMenu();
        return;
      }
      openHeadMenu(more, file);
    });

    const stat = el("span", { class: "cg-file-head-stat" });
    const head = el("div", { class: "cg-file-head" });
    const caret = el("span", { class: "cg-fh-caret" });
    caret.innerHTML = ICON_CHEVRON;
    head.appendChild(caret);
    const icon = fileIconEl(file.path.split("/").pop());
    if (icon) head.appendChild(icon);
    head.appendChild(el("span", { class: "cg-file-head-path", text: file.path }));
    head.appendChild(stat);
    head.appendChild(revert);
    head.appendChild(more);
    section.appendChild(head);
    section.appendChild(el("div", { class: "cg-lines" }));
    updateHeadStat(section, file);
    const record = state.records.get(file.path);
    section.classList.toggle("is-collapsed", !!(record && record.collapsed));

    section.addEventListener("click", (e) => {
      if (e.target.closest(".cg-fold")) {
        expandFile(file.path);
        return;
      }
      if (e.target.closest("button") || !e.target.closest(".cg-file-head")) return;
      if (String(window.getSelection() || "")) return;
      setFileCollapsed(file.path);
    });
    renderFileBody(section, file);
    return section;
  }

  function updateHeadStat(section, file) {
    const stat = section.querySelector(".cg-file-head-stat");
    if (!stat) return;
    stat.replaceChildren();
    stat.appendChild(el("span", { class: "a", text: `+${file.add}` }));
    stat.appendChild(el("span", { class: "d", text: `-${file.del}` }));
  }

  // ── diff layout ─────────────────────────────────────────────────────────
  function effectiveLayout() {
    if (state.layout !== "auto") return state.layout;
    const pane = state.els && state.els.stream ? state.els.stream.clientWidth : 0;
    return pane >= SPLIT_MIN_WIDTH ? "split" : "unified";
  }

  function applyLayoutButton() {
    const btn = state.els && state.els.layoutBtn;
    if (!btn) return;
    const split = effectiveLayout() === "split";
    btn.innerHTML = split ? ICON_LAYOUT : ICON_LAYOUT_UNIFIED;
    btn.classList.toggle("is-on", state.layout !== "unified");
    btn.title = fill(t("changes.layout.hint", "差异视图布局：{{mode}}"), { mode: LAYOUT_LABELS[state.layout]() });
    btn.setAttribute("aria-label", btn.title);
  }

  function reflowBodies() {
    if (!state.els || !state.els.stream) return;
    state.reflow = true;
    state.files.forEach((file) => {
      const section = state.els.stream.querySelector(`section.cg-file[data-path="${CSS.escape(file.path)}"]`);
      if (section) renderFileBody(section, file);
    });
    state.reflow = false;
    applyLayoutButton();
  }

  function closeLayoutMenu() {
    if (state.layoutMenu) {
      state.layoutMenu.remove();
      state.layoutMenu = null;
    }
  }

  function setLayout(mode) {
    if (LAYOUT_MODES.indexOf(mode) < 0) return;
    state.layout = mode;
    try { localStorage.setItem(LAYOUT_KEY, mode); } catch (_e) { /* private mode */ }
    closeLayoutMenu();
    reflowBodies();
  }

  function openLayoutMenu(anchor) {
    const wasOpen = !!state.layoutMenu;
    closeLayoutMenu();
    if (wasOpen) return;
    closeScopeMenu();

    const menu = el("div", { class: "cg-scope-menu", "data-menu": "layout" });
    LAYOUT_MODES.forEach((mode) => {
      const row = el("div", { class: "cg-scope-item" + (state.layout === mode ? " is-checked" : ""),
        "data-layout": mode });
      row.appendChild(el("span", { text: LAYOUT_LABELS[mode]() }));
      const check = el("span", { class: "cg-scope-check" });
      check.innerHTML = ICON_CHECK;
      row.appendChild(check);
      row.addEventListener("click", (ev) => {
        ev.stopPropagation();
        setLayout(mode);
      });
      menu.appendChild(row);
    });

    menu.addEventListener("click", (ev) => ev.stopPropagation());
    document.body.appendChild(menu);
    state.layoutMenu = menu;
    positionMenu(menu, anchor);
    setTimeout(() => document.addEventListener("click", closeLayoutMenu, { once: true }), 0);
  }

  function codeSpan(line, lang) {
    const code = el("span", { class: "cg-code" });
    if (!line) return code;
    const html = highlightLine(line.text, lang);
    if (html != null) code.innerHTML = html;
    else code.textContent = line.text === "" ? " " : line.text;
    return code;
  }

  function splitHalf(line, side, lang) {
    const half = el("span", { class: `cg-half ${side}` + (line ? ` ${line.type}` : " blank") });
    const no = line ? (side === "old" ? line.oldNo : line.newNo) : null;
    half.appendChild(el("span", { class: "cg-ln", text: no == null ? "" : String(no) }));
    half.appendChild(codeSpan(line, lang));
    return half;
  }

  // A unified hunk is a flat run of ctx/del/add lines; side-by-side needs the
  // deleted block and the added block that follows it turned into rows.
  function splitPairs(hunkLines) {
    const rows = [];
    let i = 0;
    while (i < hunkLines.length) {
      if (hunkLines[i].type === "ctx") {
        rows.push([hunkLines[i], hunkLines[i]]);
        i++;
        continue;
      }
      const dels = [];
      const adds = [];
      while (i < hunkLines.length && hunkLines[i].type === "del") dels.push(hunkLines[i++]);
      while (i < hunkLines.length && hunkLines[i].type === "add") adds.push(hunkLines[i++]);
      const n = Math.max(dels.length, adds.length);
      for (let k = 0; k < n; k++) rows.push([dels[k] || null, adds[k] || null]);
    }
    return rows;
  }

  function renderFileBody(section, file) {
    const lines = section.querySelector(".cg-lines");
    lines.replaceChildren();
    const record = state.records.get(file.path) || {};
    const full = record.full;
    const kind = classify(file);

    if (file.binary) {
      lines.appendChild(el("div", { class: "cg-note", text: t("changes.diff.binary", "二进制文件，无法逐行对比。") }));
      return;
    }
    if (!file.diff || !file.diff.trim()) {
      if (record.lazyPending) {
        renderLazy(section, file);
        return;
      }
      lines.appendChild(el("div", { class: "cg-note",
        text: kind === "add" ? t("changes.diff.emptyNew", "空的文件。") : t("changes.diff.same", "这个文件的内容没有变化。") }));
      return;
    }

    const hunks = parseHunks(file.diff);
    if (!hunks.length) {
      lines.appendChild(el("div", { class: "cg-note", text: t("changes.diff.same", "这个文件的内容没有变化。") }));
      return;
    }

    const limit = (full || record.loaded) ? MAX_RENDER_LINES : Math.min(MAX_RENDER_LINES, state.budget);
    if (limit <= 0) {
      renderLazy(section, file);
      return;
    }

    const lang = langFor(file.path);
    const split = effectiveLayout() === "split";
    let prevEnd = 1;
    let rendered = 0;
    const frag = document.createDocumentFragment();

    for (let h = 0; h < hunks.length; h++) {
      const hunk = hunks[h];
      const gap = hunk.oldStart - prevEnd;
      if (!full && gap > 0) {
        const fold = el("div", { class: "cg-fold" });
        fold.appendChild(el("span", { class: "cg-fold-arrow", text: "⋯" }));
        fold.appendChild(el("span", { text: fill(t("changes.fold", "{{n}} 行未修改"), { n: gap }) }));
        fold.title = t("changes.foldHint", "点击展开");
        frag.appendChild(fold);
      }
      if (split) {
        const pairs = splitPairs(hunk.lines);
        for (let i = 0; i < pairs.length; i++) {
          if (rendered >= MAX_RENDER_LINES) break;
          const row = el("div", { class: "cg-line split" });
          row.appendChild(splitHalf(pairs[i][0], "old", lang));
          row.appendChild(splitHalf(pairs[i][1], "new", lang));
          frag.appendChild(row);
          rendered++;
        }
      } else {
        for (let i = 0; i < hunk.lines.length; i++) {
          if (rendered >= MAX_RENDER_LINES) break;
          const line = hunk.lines[i];
          const row = el("div", { class: `cg-line ${line.type}` });
          row.appendChild(el("span", { class: "cg-ln", text: line.oldNo == null ? "" : String(line.oldNo) }));
          row.appendChild(el("span", { class: "cg-ln", text: line.newNo == null ? "" : String(line.newNo) }));
          row.appendChild(codeSpan(line, lang));
          frag.appendChild(row);
          rendered++;
        }
      }
      if (rendered >= MAX_RENDER_LINES) break;
      prevEnd = hunk.oldStart + hunk.oldCount;
    }

    lines.appendChild(frag);
    if (!full && !record.loaded && !state.reflow) state.budget -= rendered;
    if (file.truncated || rendered >= limit) {
      lines.appendChild(el("div", { class: "cg-note", text: t("changes.diff.truncated", "差异过大，仅显示前 {{n}} 行").replace("{{n}}", String(limit)) }));
    }
  }

  // Placeholder for a file whose diff is withheld (too big a payload) or whose
  // slot fell past the render budget. Clicking pulls just this file.
  function renderLazy(section, file) {
    const lines = section.querySelector(".cg-lines");
    const record = state.records.get(file.path) || {};
    const canLoad = state.scope !== "lastTurn" || !!(record.raw && record.raw.trim());
    const box = el("div", { class: `cg-lazy${canLoad ? "" : " is-static"}`,
      text: canLoad
        ? t("changes.diff.lazy", "改动较大，点按加载此文件的差异")
        : t("changes.diff.skipped", "差异过大，未在此处显示") });
    if (canLoad) {
      box.addEventListener("click", (e) => {
        e.stopPropagation();
        loadFileDiff(file.path);
      });
    }
    lines.appendChild(box);
  }

  async function loadFileDiff(path) {
    const record = state.records.get(path);
    if (!record || record.loading) return;
    const section = state.els.stream.querySelector(`section.cg-file[data-path="${CSS.escape(path)}"]`);
    if (!section) return;

    if (state.scope === "lastTurn") {
      if (!record.raw || !record.raw.trim()) return;
      record.file.diff = record.raw;
      record.loaded = true;
      renderFileBody(section, record.file);
      return;
    }

    record.loading = true;
    const box = section.querySelector(".cg-lazy");
    if (box) box.textContent = t("changes.diff.loading", "加载差异…");
    try {
      const res = await api(state.sessionId, `diff?file=${encodeURIComponent(path)}&context=3&${scopeQuery()}`);
      if (res && typeof res.diff === "string") {
        record.file.diff = res.diff;
        record.raw = res.diff;
        record.loaded = true;
        renderFileBody(section, record.file);
      }
    } catch (_e) {
      Modal.toast(t("changes.diff.fail", "读取差异失败"), "error");
      renderLazy(section, record.file);
    } finally {
      record.loading = false;
    }
  }

  const EMPTY_BY_SCOPE = {
    lastTurn: () => t("changes.scope.emptyLastTurn", "上一轮没有改动记录。"),
    worktree: () => t("changes.empty", "自上次提交以来没有改动。"),
    unstaged: () => t("changes.scope.emptyUnstaged", "工作区没有未暂存的改动。"),
    staged: () => t("changes.scope.emptyStaged", "暂存区没有改动。"),
    committed: () => t("changes.scope.emptyCommitted", "当前分支相对基线没有提交。"),
    branch: () => t("changes.scope.emptyCommitted", "当前分支相对基线没有提交。"),
  };

  function renderStream() {
    const stream = state.els.stream;
    stream.replaceChildren();
    state.records = new Map();
    state.renderTruncated = 0;
    state.budget = VIEW_BUDGET_LINES;
    if (!state.files.length) {
      const text = state.note === "noBase"
        ? t("changes.scope.noBase", "没有可比较的基线分支。")
        : (EMPTY_BY_SCOPE[state.scope] || EMPTY_BY_SCOPE.worktree)();
      stream.appendChild(el("div", { class: "cg-empty", text }));
      return;
    }
    const frag = document.createDocumentFragment();
    state.files.forEach((file) => {
      state.records.set(file.path, { file: file, full: false, raw: file.diff,
        lazyPending: !!file.lazy });
      frag.appendChild(buildFileSection(file));
    });
    stream.appendChild(frag);
    updateActiveRow();
  }

  function focusFile(path) {
    const section = state.els.stream.querySelector(`section.cg-file[data-path="${CSS.escape(path)}"]`);
    state.activePath = path;
    if (section) {
      setFileCollapsed(path, false);
      // +1 lands the header just inside the scroll box so the stub of the
      // previous file's last row cannot show above it.
      state.els.stream.scrollTop = section.offsetTop + 1;
      updateActiveRow();
      if (section.querySelector(".cg-lazy")) loadFileDiff(path);
    }
    highlightTreeRow();
  }

  function highlightTreeRow() {
    state.els.tree.querySelectorAll(".cg-file-row").forEach((row) => {
      row.classList.toggle("active", row.dataset.path === state.activePath);
    });
  }

  function updateActiveRow() {
    const stream = state.els.stream;
    const sections = stream.querySelectorAll("section.cg-file");
    if (!sections.length) return;
    const atBottom = stream.scrollTop + stream.clientHeight >= stream.scrollHeight - 2;
    const top = stream.scrollTop + 1;
    let current = sections[0];
    if (atBottom) {
      // The last section can be shorter than the viewport, so it can never reach
      // the top edge; without this the row above would stay highlighted.
      current = sections[sections.length - 1];
    } else {
      for (let i = 0; i < sections.length; i++) {
        if (sections[i].offsetTop <= top + 30) current = sections[i];
        else break;
      }
    }
    if (current.dataset.path !== state.activePath) {
      state.activePath = current.dataset.path;
      highlightTreeRow();
    }
  }

  async function expandFile(path) {
    const record = state.records.get(path);
    if (!record) return;
    if (record.full) return;
    // Turn snapshots only carry three lines of context; git cannot reproduce
    // them, so the collapsed gaps stay collapsed in that scope.
    if (state.scope === "lastTurn") return;
    const section = state.els.stream.querySelector(`section.cg-file[data-path="${CSS.escape(path)}"]`);
    if (!section) return;
    if (record.loading) return;
    const token = record.token || 0;
    record.loading = true;
    try {
      const res = await api(state.sessionId, `diff?file=${encodeURIComponent(path)}&context=${FULL_CONTEXT}&${scopeQuery()}`);
      // Cancelled by collapseAll while the request was in flight.
      if ((record.token || 0) !== token) return;
      if (res && typeof res.diff === "string") {
        record.file.diff = res.diff;
        record.full = true;
        renderFileBody(section, record.file);
      }
    } catch (_e) {
      Modal.toast(t("changes.diff.fail", "读取差异失败"), "error");
    } finally {
      record.loading = false;
    }
  }

  function setExpandState(on) {
    const btn = state.els.expandBtn;
    if (!btn) return;
    btn.classList.toggle("is-on", on);
    const label = on ? t("changes.collapseAll", "收起全部") : t("changes.expandAll", "展开全部");
    btn.title = label;
    btn.setAttribute("aria-label", label);
  }

  function expandAll() {
    setExpandState(true);
    state.records.forEach((record, path) => {
      if (record.full || record.lazyPending || !record.file.diff) return;
      expandFile(path);
    });
  }

  // Whole-section fold: the header stays as a one-line summary, the diff body
  // is hidden by CSS so the parsed rows are kept and unfold instantly.
  function setFileCollapsed(path, collapsed) {
    const record = state.records.get(path);
    if (!record) return;
    const next = collapsed == null ? !record.collapsed : !!collapsed;
    if (next === !!record.collapsed) return;
    record.collapsed = next;
    const section = state.els.stream.querySelector(`section.cg-file[data-path="${CSS.escape(path)}"]`);
    if (section) section.classList.toggle("is-collapsed", next);
  }

  function collapseAll() {
    setExpandState(false);
    state.records.forEach((record, path) => {
      record.token = (record.token || 0) + 1;
      if (!record.full) return;
      record.full = false;
      record.file.diff = record.raw;
      const section = state.els.stream.querySelector(`section.cg-file[data-path="${CSS.escape(path)}"]`);
      if (section) renderFileBody(section, record.file);
    });
  }

  // ── revert (single file, destructive) ──────────────────────────────────
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
    try {
      const res = await api(state.sessionId, "restore", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ file: path }),
      });
      if (res.ok) {
        Modal.toast(fill(t("changes.restore.done", "已撤销：{{path}}"), { path: path }), "success");
        refresh(state.sessionId, state.ctx);
      } else {
        Modal.toast(res.error || t("changes.restore.failed", "撤销失败"), "error");
      }
    } catch (_e) {
      Modal.toast(t("changes.restore.failed", "撤销失败"), "error");
    }
  }

  // ── toolbar actions ────────────────────────────────────────────────────
  async function copyPatch() {
    const text = state.files.map((f) => f.diff || "").filter(Boolean).join("\n");
    if (!text) return;
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(text);
      } else {
        copyViaTextarea(text);
      }
      Modal.toast(t("changes.copied", "已复制补丁"), "success");
    } catch (_e) {
      try {
        copyViaTextarea(text);
        Modal.toast(t("changes.copied", "已复制补丁"), "success");
      } catch (_e2) {
        Modal.toast(t("changes.copyFail", "复制失败"), "error");
      }
    }
  }

  function copyViaTextarea(text) {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.top = "-1000px";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand("copy");
    document.body.removeChild(ta);
    if (!ok) throw new Error("copy failed");
  }

  // ── refresh ────────────────────────────────────────────────────────────
  function renderNotice(message, cls) {
    if (!state.els) return;
    state.files = [];
    state.records = new Map();
    state.els.stats.replaceChildren();
    state.els.tree.replaceChildren();
    state.els.stream.replaceChildren(el("div", { class: cls, text: message }));
  }

  async function refresh(sessionId, ctx) {
    if (!state.els) return;
    closeScopeMenu();
    let data;
    try {
      data = await api(sessionId, `review?${scopeQuery()}`);
    } catch (_e) {
      renderNotice(t("changes.error", "读取改动失败"), "cg-error");
      return;
    }
    if (!data.repo) {
      if (ctx && ctx.setBadge) ctx.setBadge(null);
      renderNotice(t("changes.noRepo", "这个项目还没有启用版本管理。"), "cg-empty");
      return;
    }

    state.sessionId = sessionId;
    state.files = data.files || [];
    state.note = data.note || null;
    state.branch = data.branch || "";
    // A fresh "branch" scope has no pick yet: adopt the base the server
    // resolved (upstream / origin/main) so the compare pill shows a real name
    // instead of a placeholder. "committed" never does this - its base is the
    // upstream, not one of the commits listed in the menu.
    if (state.scope === "branch" && !state.base && data.base) state.base = data.base;
    if (ctx && ctx.setBadge) ctx.setBadge(state.files.length || null);

    renderStats(data);
    renderTree();
    renderStream();

    // The pill names the head of the unpushed range, so the list has to be
    // there even when the menu was never opened.
    if (state.scope === "committed" && !state.commits) {
      loadCommits().then(() => {
        if (state.sessionId === sessionId && state.scope === "committed") renderStats(data);
      });
    }
  }

  async function loadCommits() {
    if (state.commits) return state.commits;
    try {
      const data = await api(state.sessionId, "log?limit=60&unpushed=1");
      state.commits = (data && data.commits) || [];
    } catch (_e) {
      state.commits = [];
    }
    return state.commits;
  }

  const SCOPE_LABELS = {
    lastTurn: () => t("changes.scope.lastTurn", "上一轮"),
    worktree: () => t("changes.scope.worktree", "未提交"),
    unstaged: () => t("changes.scope.unstaged", "未暂存"),
    staged: () => t("changes.scope.staged", "已暂存"),
    committed: () => t("changes.scope.committed", "已提交"),
    branch: () => t("changes.scope.branch", "分支"),
  };

  // The pill always names the scope; what it is compared against rides in the
  // muted subject (a commit) or in the separate compare pill (a branch).
  function scopeLabel() {
    const fn = SCOPE_LABELS[state.scope] || SCOPE_LABELS.worktree;
    return fn();
  }

  // What the pill names: the commit the user picked, or - with no pick - the
  // size of the unpushed range the counts add up, so the text and the numbers
  // never describe different things.
  function scopeSubject() {
    if (state.scope !== "committed") return "";
    const all = state.commits || [];
    if (!state.commit) {
      if (!all.length) return "";
      return fill(t("changes.scope.commitCount", "{{n}} 个提交"), { n: all.length });
    }
    const hit = all.find((c) => c.hash === state.commit);
    return hit ? hit.subject : state.commit.slice(0, 8);
  }

  function renderStats(data) {
    const stats = state.els.stats;
    stats.replaceChildren();

    const scopeBtn = el("button", { class: "cg-scope", type: "button",
      title: t("changes.scope.title", "查看范围") });
    scopeBtn.appendChild(el("span", { class: "cg-scope-label", text: scopeLabel() }));
    const caret = el("span", { class: "cg-caret" });
    caret.innerHTML = ICON_CARET_DOWN;
    scopeBtn.appendChild(caret);
    const subject = scopeSubject();
    if (subject) {
      scopeBtn.appendChild(el("span", { class: "cg-scope-subject", text: subject, title: subject }));
    }
    if (state.files.length) {
      scopeBtn.appendChild(el("span", { class: "cg-bar-add", text: `+${data.add || 0}` }));
      scopeBtn.appendChild(el("span", { class: "cg-bar-del", text: `−${data.del || 0}` }));
    }
    scopeBtn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      openScopeMenu(scopeBtn);
    });
    stats.appendChild(scopeBtn);

    const compare = comparePill(data);
    if (compare) stats.appendChild(compare);
  }

  // `head → base`: which pair of branches is on screen. Only the right-hand
  // side is a picker - the left one is whatever HEAD points at, so it stays
  // plain text rather than pretending to be selectable.
  function comparePill(data) {
    if (state.scope !== "branch") return null;
    const head = state.branch || "HEAD";
    const base = state.base || data.base || t("changes.compare.unset", "选择对比分支");
    const btn = el("button", { class: "cg-scope cg-compare", type: "button",
      title: t("changes.compare.title", "选择对比分支") });
    btn.appendChild(el("span", { class: "cg-scope-head", text: head }));
    const arrow = el("span", { class: "cg-compare-arrow" });
    arrow.innerHTML = ICON_ARROW_RIGHT;
    btn.appendChild(arrow);
    btn.appendChild(el("span", { class: "cg-scope-base", text: base }));
    const caret = el("span", { class: "cg-caret" });
    caret.innerHTML = ICON_CARET_DOWN;
    btn.appendChild(caret);
    btn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      openRefMenu(btn, "branches", (name) => applyScope("branch", name));
    });
    return btn;
  }

  // ── scope selector ──────────────────────────────────────────────────────
  // The pill above the file tree switches which slice of history is on screen.
  // "已提交" opens a second-level list of commits (the comparison base defaults
  // to the upstream); "分支" is a plain row - picking it swaps the toolbar to
  // the `head → base` compare pill, where the base is chosen.
  let scopeMenuEl = null;
  let refMenuEl = null;
  let refAnchor = null;
  let refSearch = "";

  function closeRefMenu() {
    if (refMenuEl) {
      refMenuEl.remove();
      refMenuEl = null;
    }
    if (refAnchor) {
      refAnchor.classList.remove("is-open");
      refAnchor = null;
    }
    if (scopeMenuEl) {
      scopeMenuEl.querySelectorAll(".cg-scope-item.is-open").forEach((r) => r.classList.remove("is-open"));
    }
  }

  function closeScopeMenu() {
    closeRefMenu();
    if (scopeMenuEl) {
      scopeMenuEl.remove();
      scopeMenuEl = null;
    }
    document.querySelectorAll(".cg-scope.is-open").forEach((b) => b.classList.remove("is-open"));
  }

  function scopeMenuItems() {
    return [
      { scope: "lastTurn" },
      { sep: true },
      { scope: "worktree" },
      { scope: "unstaged" },
      { scope: "staged" },
      { sep: true },
      { scope: "committed", submenu: "commits" },
      { scope: "branch" },
    ];
  }

  function positionMenu(menu, anchor) {
    const r = anchor.getBoundingClientRect();
    menu.style.top = r.bottom + 6 + "px";
    menu.style.left = r.left + "px";
    requestAnimationFrame(() => {
      const m = menu.getBoundingClientRect();
      if (m.right > window.innerWidth - 8) menu.style.left = Math.max(8, window.innerWidth - m.width - 8) + "px";
      if (m.bottom > window.innerHeight - 8) menu.style.top = Math.max(8, r.top - m.height - 6) + "px";
    });
  }

  function openScopeMenu(anchor) {
    const wasOpen = anchor.classList.contains("is-open");
    closeScopeMenu();
    if (wasOpen) return;

    anchor.classList.add("is-open");
    const menu = el("div", { class: "cg-scope-menu" });
    scopeMenuItems().forEach((item) => {
      if (item.sep) {
        menu.appendChild(el("div", { class: "cg-scope-sep" }));
        return;
      }
      const row = el("div", { class: "cg-scope-item", "data-scope": item.scope });
      row.appendChild(el("span", { text: SCOPE_LABELS[item.scope]() }));
      if (item.submenu) {
        const arrow = el("span", { class: "cg-scope-arrow" });
        arrow.innerHTML = ICON_CHEVRON;
        row.appendChild(arrow);
      } else if (state.scope === item.scope) {
        row.classList.add("is-checked");
        const check = el("span", { class: "cg-scope-check" });
        check.innerHTML = ICON_CHECK;
        row.appendChild(check);
      }
      const openSub = () => {
        if (item.submenu === "commits") {
          openRefMenu(row, "commits", (hash) => applyScope("committed", hash), { side: menu });
        } else {
          closeRefMenu();
        }
      };
      row.addEventListener("mouseenter", () => {
        openSub();
        menu.querySelectorAll(".cg-scope-item").forEach((r) => {
          r.classList.toggle("is-open", r === row && !!item.submenu);
        });
      });
      row.addEventListener("click", (ev) => {
        ev.stopPropagation();
        if (item.submenu) openSub();
        else applyScope(item.scope, "");
      });
      menu.appendChild(row);
    });

    menu.addEventListener("click", (ev) => ev.stopPropagation());
    document.body.appendChild(menu);
    scopeMenuEl = menu;
    positionMenu(menu, anchor);
    setTimeout(() => document.addEventListener("click", closeScopeMenu, { once: true }), 0);
  }

  // The submenu hangs off the row that opened it: aligned to that row (not to
  // the top of the parent menu, which would look detached from the hovered
  // item) and flipped to the left when it would overflow the viewport.
  function positionSubmenu(sub, menu, anchorRow) {
    const m = menu.getBoundingClientRect();
    const r = (anchorRow || menu).getBoundingClientRect();
    sub.style.top = r.top + "px";
    sub.style.left = m.right + 6 + "px";
    requestAnimationFrame(() => {
      const s = sub.getBoundingClientRect();
      if (s.right > window.innerWidth - 8) sub.style.left = Math.max(8, m.left - s.width - 6) + "px";
      if (s.bottom > window.innerHeight - 8) sub.style.top = Math.max(8, window.innerHeight - s.height - 8) + "px";
    });
  }

  // A dropdown list of refs: branches when choosing a comparison base, commits
  // when pinning "committed" to something other than the upstream. Both share
  // the search box and row styling; only the row content differs.
  function renderRefList(listEl, kind, onPick) {
    listEl.replaceChildren();
    const q = refSearch.trim().toLowerCase();
    const all = kind === "branches" ? state.branches : state.commits;
    if (!all) {
      const text = kind === "branches"
        ? t("changes.scope.loadingBranches", "正在读取分支…")
        : t("changes.scope.loadingCommits", "正在读取提交…");
      listEl.appendChild(el("div", { class: "cg-scope-empty", text: text }));
      return;
    }
    const rows = all.filter((item) => {
      const hay = kind === "branches" ? item.name : `${item.subject} ${item.short}`;
      return !q || hay.toLowerCase().includes(q);
    });
    if (!rows.length) {
      let text;
      if (kind === "branches") text = t("changes.scope.noBranches", "没有匹配的分支");
      else if (!all.length) text = t("changes.scope.noUnpushed", "没有未推送的提交");
      else text = t("changes.scope.noCommits", "没有匹配的提交");
      listEl.appendChild(el("div", { class: "cg-scope-empty", text: text }));
      return;
    }
    rows.forEach((item) => {
      if (kind === "branches") {
        const checked = state.scope === "branch" && state.base === item.name;
        const row = el("div", { class: "cg-scope-branch" + (checked ? " is-checked" : ""), "data-branch": item.name });
        const icon = el("span", {});
        icon.innerHTML = ICON_BRANCH;
        row.appendChild(icon);
        row.appendChild(el("span", { class: "cg-scope-name", text: item.name }));
        const check = el("span", { class: "cg-scope-check" });
        check.innerHTML = ICON_CHECK;
        row.appendChild(check);
        row.addEventListener("click", (ev) => {
          ev.stopPropagation();
          onPick(item.name);
        });
        listEl.appendChild(row);
        return;
      }

      // Every row reviews that commit on its own: the panel answers "what did
      // this commit change", which is what picking a commit in the list means.
      const checked = state.commit === item.hash;
      const row = el("div", { class: "cg-scope-commit" + (state.scope === "committed" && checked ? " is-checked" : "") });
      row.appendChild(el("span", { class: "cg-scope-subject", text: item.subject, title: item.subject }));
      row.appendChild(el("span", { class: "cg-scope-sha", text: item.short }));
      const check = el("span", { class: "cg-scope-check" });
      check.innerHTML = ICON_CHECK;
      row.appendChild(check);
      row.addEventListener("click", (ev) => {
        ev.stopPropagation();
        onPick(item.hash);
      });
      listEl.appendChild(row);
    });
  }

  async function openRefMenu(anchor, kind, onPick, opts) {
    const o = opts || {};
    const wasOpen = !!(refMenuEl && refMenuEl.dataset.kind === kind && anchor.classList.contains("is-open"));
    if (o.side) closeRefMenu();
    else closeScopeMenu();
    if (wasOpen) return;
    refSearch = "";

    const sub = el("div", { class: "cg-scope-sub", "data-kind": kind });
    const searchWrap = el("div", { class: "cg-scope-search" });
    const searchIcon = el("span", {});
    searchIcon.innerHTML = ICON_SEARCH;
    searchWrap.appendChild(searchIcon);
    const placeholder = kind === "branches"
      ? t("changes.scope.searchBranch", "搜索分支")
      : t("changes.scope.searchCommit", "搜索提交");
    const input = el("input", { type: "search", placeholder: placeholder });
    searchWrap.appendChild(input);
    const list = el("div", { class: "cg-scope-list" });
    const group = kind === "branches"
      ? t("changes.scope.branch", "分支")
      : t("changes.scope.unpushedCommits", "未推送的提交");
    sub.appendChild(searchWrap);
    sub.appendChild(el("div", { class: "cg-scope-group", text: group }));
    sub.appendChild(list);
    sub.addEventListener("click", (ev) => ev.stopPropagation());
    document.body.appendChild(sub);
    refMenuEl = sub;
    refAnchor = anchor;
    anchor.classList.add("is-open");
    if (o.side) positionSubmenu(sub, o.side, anchor);
    else positionMenu(sub, anchor);
    setTimeout(() => document.addEventListener("click", closeScopeMenu, { once: true }), 0);

    input.addEventListener("input", () => {
      refSearch = input.value;
      renderRefList(list, kind, onPick);
    });
    renderRefList(list, kind, onPick);
    setTimeout(() => input.focus(), 0);

    const cached = kind === "branches" ? state.branches : state.commits;
    if (!cached) {
      if (kind === "branches") {
        try {
          const data = await api(state.sessionId, "branches");
          state.branches = (data && data.branches) || [];
        } catch (_e) {
          state.branches = [];
        }
      } else {
        await loadCommits();
      }
      if (refMenuEl === sub) renderRefList(list, kind, onPick);
    }
  }

  function applyScope(scope, value) {
    state.scope = scope;
    if (scope === "branch") state.base = value || "";
    else if (scope === "committed") state.commit = value || "";
    state.note = null;
    closeScopeMenu();
    if (state.sessionId) refresh(state.sessionId, state.ctx);
  }

  // ── mount ──────────────────────────────────────────────────────────────
  let activeRoot = null;
  let activeBody = null;
  let activeSessionId = null;

  async function refreshBadge(sessionId, ctx) {
    if (!ctx || !ctx.setBadge) return;
    let data;
    try {
      data = await api(sessionId, "review");
    } catch (_e) {
      ctx.setBadge(null);
      return;
    }
    ctx.setBadge(data.repo ? ((data.files || []).length || null) : null);
  }

  function onFilesChanged(sessionId, ctx) {
    if (activeSessionId === sessionId && activeRoot && activeBody) {
      refresh(sessionId, ctx);
    } else {
      refreshBadge(sessionId, ctx);
    }
  }

  Clacky.ext.ui.mount("session.aside", (container, ctx) => {
    if (!ctx || !ctx.sessionId) return;

    const stats = el("div", { class: "cg-bar-stats" });
    const expandBtn = el("button", { class: "cg-icon-btn", type: "button",
      title: t("changes.expandAll", "展开全部"),
      "aria-label": t("changes.expandAll", "展开全部") });
    expandBtn.innerHTML = ICON_UNFOLD;
    expandBtn.addEventListener("click", () => {
      if (expandBtn.classList.contains("is-on")) collapseAll();
      else expandAll();
    });

    const refreshBtn = el("button", { class: "cg-icon-btn", type: "button",
      title: t("changes.refresh", "刷新"),
      "aria-label": t("changes.refresh", "刷新") });
    refreshBtn.innerHTML = ICON_REFRESH;
    refreshBtn.addEventListener("click", () => refresh(ctx.sessionId, ctx));

    const copyBtn = el("button", { class: "cg-icon-btn", type: "button",
      title: t("changes.copy", "复制补丁"),
      "aria-label": t("changes.copy", "复制补丁") });
    copyBtn.innerHTML = ICON_COPY;
    copyBtn.addEventListener("click", copyPatch);

    const layoutBtn = el("button", { class: "cg-icon-btn", type: "button" });
    layoutBtn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      openLayoutMenu(layoutBtn);
    });

    const bar = el("div", { class: "cg-bar" },
      stats,
      el("span", { class: "cg-bar-spacer" }),
      layoutBtn, copyBtn, expandBtn, refreshBtn);

    const filter = el("input", { class: "cg-filter", type: "search",
      placeholder: t("changes.filter", "筛选文件…") });
    filter.addEventListener("input", () => {
      state.filter = filter.value.trim().toLowerCase();
      renderTree();
    });
    const sideEmpty = el("div", { class: "cg-side-empty", text: t("changes.noMatch", "没有匹配的文件") });
    sideEmpty.style.display = "none";
    const tree = el("div", { class: "cg-tree" });
    const side = el("div", { class: "cg-side" },
      el("div", { class: "cg-side-head" }, filter), tree, sideEmpty);

    const stream = el("div", { class: "cg-stream" });
    const main = el("div", { class: "cg-main" }, stream);
    const body = el("div", { class: "cg-body" }, side, main);
    const root = el("div", { class: "changes-root", "data-panel": "changes" }, bar, body);
    container.appendChild(root);
    body.insertBefore(setupSideResizer(root, body, side), main);

    if (state.sessionId && state.sessionId !== ctx.sessionId) {
      state.scope = "worktree";
      state.base = "";
      state.commit = "";
      state.branch = "";
      state.branches = null;
      state.commits = null;
    }
    state.sessionId = ctx.sessionId;
    state.ctx = ctx;
    state.els = { root: root, stats: stats, tree: tree, stream: stream, sideEmpty: sideEmpty,
      expandBtn: expandBtn, layoutBtn: layoutBtn };

    try {
      const saved = localStorage.getItem(LAYOUT_KEY);
      if (saved && LAYOUT_MODES.indexOf(saved) >= 0) state.layout = saved;
    } catch (_e) { /* private mode */ }
    applyLayoutButton();

    if (state.ro) state.ro.disconnect();
    if (typeof ResizeObserver !== "undefined") {
      let lastSplit = effectiveLayout() === "split";
      state.ro = new ResizeObserver(() => {
        const now = effectiveLayout() === "split";
        if (now === lastSplit) return;
        lastSplit = now;
        reflowBodies();
      });
      state.ro.observe(stream);
    }

    let scrollRaf = null;
    stream.addEventListener("scroll", () => {
      if (scrollRaf) return;
      scrollRaf = requestAnimationFrame(() => {
        scrollRaf = null;
        updateActiveRow();
      });
    });

    activeRoot = root;
    activeBody = body;
    activeSessionId = ctx.sessionId;
    refresh(ctx.sessionId, ctx);
  }, {
    order: 30,
    tab: {
      id: "changes",
      label: () => t("changes.tab", "改动"),
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
            state.records = new Map();
            state.files = [];
          }
        };
      },
    },
  });
})();
