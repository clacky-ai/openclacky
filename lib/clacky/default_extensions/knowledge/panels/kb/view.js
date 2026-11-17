// Knowledge Base - full-page workspace mounted from the sidebar (below
// Creator Center). Opens at #ext/knowledge:
//   • root folders on the left (a book, a project…); the right side shows
//     the selected root with sub-folders of any depth and a breadcrumb
//   • "Add data source" → upload one file into the current folder (converted,
//     previewed in the host editor, saved on Import) / import a folder via
//     the browser's folder picker, keeping its sub-folder structure
//   • rename / move documents, create / rename / delete folders
//   • click a document → host Markdown editor (edit + live preview)
//   • "Recall test" → modal running the same BM25 index the agent uses
// Backend: /api/ext/knowledge/ (api/handler.rb).

(function () {
  const WS_ID = "knowledge";

  const KB_I18N = {
    en: {
      "nav.entry": "Knowledge Base",
      "ws.title": "Knowledge Base",
      "ws.sub": "Documents the Knowledge Base agent consults before answering",
      "btn.add": "Add data source",
      "btn.recall": "Recall test",
      "add.files": "Upload files",
      "add.files.desc": "Markdown, TXT, PDF, Word",
      "add.folder": "Import folder",
      "add.folder.desc": "Import every supported file in a folder",
      "off": "The knowledge base is switched off, so the agent is not using these documents right now.",
      "close": "Close",
      "filter.all": "All",
      "filter.placeholderIn": "Search this folder",
      "sort.tip": "Sort by",
      "sort.name": "Default",
      "sort.time": "Last updated",
      "roots.title": "Knowledge bases",
      "root.new": "New knowledge base",
      "unfiled": "Unfiled",
      "add.needRoot": "Create or open a knowledge base first",
      "empty.title": "No documents yet",
      "empty.desc": "Create a knowledge base first — one per book or project — then upload files or import a folder into it. PDF and Word are converted to text automatically.",
      "empty.filter": "No documents match.",
      "empty.folder": "Nothing here yet. Upload files, import a folder or create a folder.",
      "docs": "{{n}} docs",
      "chars": "{{n}} chars",
      "delete": "Delete",
      "deleted": "Moved to trash",
      "confirm.delete": "Delete “{{title}}”? The file is moved to the trash and can be restored.",
      "saved": "Saved",
      "rename": "Rename",
      "title": "Title",
      "save": "Save",
      "cancel": "Cancel",
      "create": "Create",
      "move": "Move to…",
      "move.tip": "Move to another folder",
      "move.title": "Move “{{title}}” to",
      "move.here": "Move here",
      "move.current": "Current",
      "moved": "Moved to {{where}}",
      "folder.new": "New folder",
      "folder.name": "Folder name",
      "confirm.deleteFolder": "Delete the folder “{{name}}” and the {{n}} document(s) in it? Everything is moved to the trash and can be restored.",
      "confirm.deleteEmptyFolder": "Delete the empty folder “{{name}}”?",
      "busy.preview": "Converting…",
      "preview.title": "Preview: {{title}}",
      "preview.import": "Import",
      "preview.parsed": "Text recognised from PDF / Word may contain mistakes — check and fix it, then import.",
      "preview.hint": "Check the content, then import.",
      "preview.where": "It will be saved in “{{where}}”.",
      "busy.folder": "Importing {{i}}/{{n}}…",
      "done": "Imported {{n}} document(s).",
      "done.parsed": "PDF / Word text is recognised automatically and may contain mistakes — open a document to check it.",
      "failed.title": "{{n}} file(s) could not be imported",
      "failed.ok": "OK",
      "folder.title": "Import folder",
      "folder.hint": "{{n}} file(s) found. They will be imported into “{{where}}” with their folder structure; untick any you don't want.",
      "folder.skipped": "{{n}} other file(s) skipped (unsupported or hidden).",
      "folder.start": "Import {{n}}",
      "recall.title": "Recall test",
      "recall.ph": "Type a question the way a user would ask it…",
      "recall.btn": "Search",
      "recall.empty": "Enter a question to start testing",
      "recall.empty.sub": "Results show the matching passages and their scores",
      "recall.none": "Nothing matched. Try other wording, or add a document that covers it.",
      "recall.hint": "The top {{k}} results are given to the AI when it answers.",
      "recall.injected": "Used",
      "recall.score": "Score",
      "recall.score.tip": "Relevance {{score}}\nHigher means a closer match. Ranking only, not a percentage.",
      "recall.history": "Recent searches",
      "recall.history.clear": "Clear",
      "loadFailed": "Failed to load: {{msg}}",
    },
    zh: {
      "nav.entry": "知识库",
      "ws.title": "知识库",
      "ws.sub": "知识库 Agent 回答前会先查阅这里的资料",
      "btn.add": "添加数据源",
      "btn.recall": "召回测试",
      "add.files": "上传文件",
      "add.files.desc": "支持 Markdown、TXT、PDF、Word",
      "add.folder": "导入文件夹",
      "add.folder.desc": "导入文件夹内所有支持的文件",
      "off": "知识库目前处于关闭状态，AI 回答时不会参考这些资料。",
      "close": "关闭",
      "filter.all": "全部",
      "filter.placeholderIn": "在当前目录中搜索",
      "sort.tip": "排序方式",
      "sort.name": "默认",
      "sort.time": "更新时间",
      "roots.title": "知识库",
      "root.new": "新建知识库",
      "unfiled": "未归档",
      "add.needRoot": "请先新建或选择一个知识库",
      "empty.title": "还没有资料",
      "empty.desc": "先新建一个知识库（如一本书、一个项目），再往里上传文件或导入文件夹。PDF 和 Word 会自动转成文字。",
      "empty.filter": "没有符合条件的资料。",
      "empty.folder": "这里还没有内容，可以上传文件、导入文件夹或新建目录。",
      "docs": "{{n}} 篇",
      "chars": "{{n}} 字",
      "delete": "删除",
      "deleted": "已移到回收站",
      "confirm.delete": "删除「{{title}}」？文件会移到回收站，可以恢复。",
      "saved": "已保存",
      "rename": "重命名",
      "title": "标题",
      "save": "保存",
      "cancel": "取消",
      "create": "创建",
      "move": "移到…",
      "move.tip": "移到其他文件夹",
      "move.title": "将「{{title}}」移到",
      "move.here": "移到这里",
      "move.current": "当前位置",
      "moved": "已移到「{{where}}」",
      "folder.new": "新建目录",
      "folder.name": "名称",
      "confirm.deleteFolder": "删除「{{name}}」及其中 {{n}} 篇资料？会一起移到回收站，可以恢复。",
      "confirm.deleteEmptyFolder": "删除空的「{{name}}」？",
      "busy.preview": "正在转换…",
      "preview.title": "预览：{{title}}",
      "preview.import": "导入",
      "preview.parsed": "PDF / Word 的文字是自动识别的，可能有错字，确认或修改后再导入。",
      "preview.hint": "确认内容无误后点击导入。",
      "preview.where": "将保存到「{{where}}」。",
      "busy.folder": "正在导入 {{i}}/{{n}}…",
      "done": "已导入 {{n}} 篇资料。",
      "done.parsed": "PDF / Word 的文字是自动识别的，可能有错字，点开资料即可修改。",
      "failed.title": "{{n}} 个文件导入失败",
      "failed.ok": "知道了",
      "folder.title": "导入文件夹",
      "folder.hint": "找到 {{n}} 个文件，将按原文件夹结构导入到「{{where}}」，不需要的可以取消勾选。",
      "folder.skipped": "另有 {{n}} 个不支持或隐藏的文件已跳过。",
      "folder.start": "导入 {{n}} 个",
      "recall.title": "召回测试",
      "recall.ph": "按用户的问法输入一个问题…",
      "recall.btn": "检索",
      "recall.empty": "输入问题开始检索测试",
      "recall.empty.sub": "结果将展示匹配的资料片段和分数",
      "recall.none": "没有命中。换个说法试试，或补充能回答这个问题的资料。",
      "recall.hint": "排在前 {{k}} 的结果会在回答时提供给 AI。",
      "recall.injected": "会使用",
      "recall.score": "分数",
      "recall.score.tip": "相关度 {{score}}\n越高越相关。只用来排序，不是百分比。",
      "recall.history": "搜索历史",
      "recall.history.clear": "清空",
      "loadFailed": "加载失败：{{msg}}",
    },
  };

  function isZh() {
    const lang = (typeof I18n !== "undefined" && I18n.lang && I18n.lang()) || "en";
    return String(lang).startsWith("zh");
  }

  function t(key, vars) {
    const dict = KB_I18N[isZh() ? "zh" : "en"];
    let str = dict[key] != null ? dict[key] : (KB_I18N.en[key] != null ? KB_I18N.en[key] : key);
    if (vars) Object.keys(vars).forEach((k) => { str = str.split("{{" + k + "}}").join(vars[k]); });
    return str;
  }

  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach((k) => {
      const v = attrs[k];
      if (v == null || v === false) return;
      if (k === "class") node.className = v;
      else if (k === "text") node.textContent = v;
      else if (k.startsWith("on") && typeof v === "function") node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v === true ? "" : v);
    });
    (children || []).forEach((c) => { if (c) node.appendChild(typeof c === "string" ? document.createTextNode(c) : c); });
    return node;
  }

  function toast(msg, type) {
    if (window.Clacky && Clacky.Modal && Clacky.Modal.toast) Clacky.Modal.toast(msg, type || "info");
  }

  function confirmBox(msg) {
    if (window.Clacky && Clacky.Modal && Clacky.Modal.confirm) return Clacky.Modal.confirm(msg);
    return Promise.resolve(window.confirm(msg));
  }

  // ── API ────────────────────────────────────────────────────────────────
  const API = "/api/ext/knowledge";

  async function call(method, path, body) {
    const opts = { method };
    if (body instanceof FormData) opts.body = body;
    else if (body !== undefined) {
      opts.headers = { "Content-Type": "application/json" };
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(API + path, opts);
    let data = {};
    try { data = await res.json(); } catch (_e) { /* non-JSON error page */ }
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
  }

  const q = (path) => encodeURIComponent(path);

  // Backend errors are English; show the common import ones in the UI language.
  const ERRORS = [
    [/^empty file/, { en: "The file is empty", zh: "文件是空的" }],
    [/^file too large/, { en: "Larger than 50 MB", zh: "文件超过 50MB" }],
    [/^unsupported file type/, { en: "Unsupported file type", zh: "不支持的文件类型" }],
    [/^no text found/, { en: "No text found (scanned document?)", zh: "没有识别到文字，可能是扫描件" }],
    [/^parse failed/, { en: "Could not read this file", zh: "无法读取文件内容" }],
    [/^no supported files/, { en: "No supported files in this folder", zh: "文件夹里没有可导入的文件" }],
    [/^too many files/, { en: "Too many files (max 500)", zh: "文件太多（最多 500 个）" }],
    [/^already exists/, { en: "A folder with this name already exists", zh: "已有同名文件夹" }],
  ];
  function errText(msg) {
    const zh = t("ws.title") === "知识库";
    const hit = ERRORS.find(([re]) => re.test(String(msg)));
    return hit ? hit[1][zh ? "zh" : "en"] : msg;
  }

  // ── Icons (lucide) ─────────────────────────────────────────────────────
  const ICON = {
    book: '<path d="M12 7v14"/><path d="M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z"/>',
    file: '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 13H8"/><path d="M16 17H8"/><path d="M16 13h-2"/>',
    upload: '<path d="M12 3v12"/><path d="m17 8-5-5-5 5"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>',
    folder: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
    plus: '<path d="M5 12h14"/><path d="M12 5v14"/>',
    search: '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
    zap: '<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>',
    target: '<circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>',
    trash: '<path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/>',
    pencil: '<path d="M21.17 6.81a1 1 0 0 0-3.98-3.98L3.84 16.17a2 2 0 0 0-.5.83l-1.32 4.35a.5.5 0 0 0 .62.62l4.35-1.32a2 2 0 0 0 .83-.5z"/><path d="m15 5 4 4"/>',
    chevron: '<path d="m6 9 6 6 6-6"/>',
    chevronRight: '<path d="m9 18 6-6-6-6"/>',
    folderPlus: '<path d="M12 10v6"/><path d="M9 13h6"/><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
    move: '<path d="M2 9V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H20a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-1"/><path d="M2 13h10"/><path d="m9 16 3-3-3-3"/>',
    inbox: '<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
    history: '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l4 2"/>',
    sort: '<path d="m21 16-4 4-4-4"/><path d="M17 20V4"/><path d="m3 8 4-4 4 4"/><path d="M7 4v16"/>',
    check: '<path d="M20 6 9 17l-5-5"/>',
  };

  function svg(name, cls, size) {
    const s = size || 16;
    const span = document.createElement("span");
    span.innerHTML =
      `<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" ` +
      'stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"' +
      (cls ? ` class="${cls}"` : "") + ">" + ICON[name] + "</svg>";
    return span.firstChild;
  }

  // ── Page ───────────────────────────────────────────────────────────────
  // Left: root folders (a book, a project…) + "New folder". Right: the
  // selected root, any depth below it, with a breadcrumb. state.folder is the
  // full path being viewed ("书/第一章"); "" = loose files at the very top
  // (only shown as "Unfiled" when such files exist); null = nothing yet.

  // Sorting: "name" = the default order (natural, chapter-aware), "time" =
  // newest first. Remembered across visits; folders and documents stay in
  // their own group either way.
  const SORT_KEY = "clacky-kb-sort";
  const state = { data: null, folder: null, filter: "", busy: null, lastQuery: "", sort: loadSort() };
  function loadSort() {
    try { return localStorage.getItem(SORT_KEY) === "time" ? "time" : "name"; } catch (_e) { return "name"; }
  }
  function setSort(v) {
    state.sort = v;
    try { localStorage.setItem(SORT_KEY, v); } catch (_e) { /* private mode */ }
    renderPage();
  }

  // Recent recall-test queries, newest first, so a question can be re-run
  // without retyping it. Kept per browser, not per knowledge base.
  const HISTORY_KEY = "clacky-kb-recall-history";
  const HISTORY_MAX = 8;
  function loadHistory() {
    try {
      const list = JSON.parse(localStorage.getItem(HISTORY_KEY) || "[]");
      return Array.isArray(list) ? list.filter((q) => typeof q === "string" && q.trim()).slice(0, HISTORY_MAX) : [];
    } catch (_e) {
      return [];
    }
  }
  function saveHistory(list) {
    try { localStorage.setItem(HISTORY_KEY, JSON.stringify(list.slice(0, HISTORY_MAX))); } catch (_e) { /* private mode */ }
  }
  function rememberQuery(q) {
    const v = q.trim();
    if (!v) return;
    saveHistory([v, ...loadHistory().filter((old) => old !== v)]);
  }
  let root = null;
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  // Natural order for chapter names: "第2章" < "第10章", and Chinese numerals
  // count too ("第二章" < "第十章") instead of sorting by pinyin.
  const CN_DIGIT = { 零: 0, 〇: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  const CN_UNIT = { 十: 10, 百: 100, 千: 1000 };
  const cnToNum = (m) => {
    let total = 0;
    let cur = 0;
    for (const ch of m) {
      if (ch in CN_DIGIT) cur = cur * 10 + CN_DIGIT[ch];
      else { total += (cur || 1) * CN_UNIT[ch]; cur = 0; }
    }
    return String(total + cur);
  };
  const sortKey = (s) => s.replace(/[零〇一二两三四五六七八九十百千]+/g, cnToNum);
  const byName = (a, b) => collator.compare(sortKey(a), sortKey(b));

  const parentOf = (f) => (f.includes("/") ? f.slice(0, f.lastIndexOf("/")) : "");
  const nameOf = (f) => f.slice(f.lastIndexOf("/") + 1);
  const rootOf = (f) => f.split("/")[0];
  const within = (f, top) => f === top || f.startsWith(top + "/");
  const loc = (f) => (f ? f.split("/").join(" / ") : t("unfiled"));

  function childFolders(parent) {
    return state.data.folders
      .filter((f) => f && parentOf(f) === parent)
      .sort((a, b) => byName(nameOf(a), nameOf(b)));
  }

  // Depth-first list of every folder, in tree order.
  function folderOrder() {
    const out = [];
    const walk = (p) => childFolders(p).forEach((f) => { out.push(f); walk(f); });
    walk("");
    return out;
  }

  const unfiled = () => state.data.entries.filter((e) => e.folder === "");
  const entriesIn = (f) => state.data.entries.filter((e) => (f === "" ? e.folder === "" : within(e.folder, f)));
  const latest = (list) => list.reduce((m, e) => (e.updated_at > m ? e.updated_at : m), "");
  // Uploads / imports / new sub-folders need a root to land in.
  const canAdd = () => !!state.folder;

  function render(container) {
    root = container;
    renderPage();
    loadEntries().then(renderPage).catch((e) => {
      if (!root) return;
      root.replaceChildren(el("div", { class: "kb-page" }, [el("div", { class: "kb-error", text: t("loadFailed", { msg: e.message }) })]));
    });
    return () => { root = null; closeMenus(); };
  }

  async function loadEntries() {
    state.data = await call("GET", "/entries");
    // The folder being viewed may have been renamed / deleted meanwhile.
    let f = state.folder;
    while (f && !state.data.folders.includes(f)) f = parentOf(f);
    if (f === "" && !unfiled().length) f = null;
    if (f == null) {
      const first = childFolders("")[0];
      f = first != null ? first : (unfiled().length ? "" : null);
    }
    state.folder = f;
    return state.data;
  }

  async function reload() {
    await loadEntries().catch(() => {});
    renderPage();
  }

  function go(f) {
    state.folder = f;
    state.filter = "";
    renderPage();
  }

  function renderPage() {
    if (!root) return;
    const page = el("div", { class: "kb-page" });

    const recallBtn = el("button", { class: "kb-btn kb-btn-ghost", type: "button", onclick: openRecall },
      [svg("target", null, 15), t("btn.recall")]);
    page.appendChild(el("div", { class: "kb-head" }, [
      el("div", { class: "kb-head-text" }, [
        el("h2", { class: "kb-title", text: t("ws.title") }),
        el("p", { class: "kb-sub", text: t("ws.sub") }),
      ]),
      el("div", { class: "kb-head-actions" }, [recallBtn, addSourceButton()]),
    ]));

    const data = state.data;
    if (data && data.switched_off) page.appendChild(el("div", { class: "kb-warn", text: t("off") }));

    if (!data) page.appendChild(el("div", { class: "kb-skeleton" }));
    else if (state.folder == null) page.appendChild(emptyState());
    else page.appendChild(el("div", { class: "kb-body" }, [rootNav(), docPane()]));

    root.replaceChildren(page);
  }

  function emptyState() {
    return el("div", { class: "kb-empty" }, [
      el("div", { class: "kb-empty-icon" }, [svg("book", null, 28)]),
      el("div", { class: "kb-empty-title", text: t("empty.title") }),
      el("div", { class: "kb-empty-desc", text: t("empty.desc") }),
      el("div", { class: "kb-empty-actions" }, [
        el("button", { class: "kb-btn kb-btn-primary", type: "button", onclick: () => createFolder("") }, [svg("folderPlus", null, 15), t("root.new")]),
      ]),
    ]);
  }

  // Left: a full-width "New folder" button on top, then the root folders as
  // plain rows (grey background on hover or when selected). Hover a root to
  // rename / delete it.
  function rootNav() {
    const nav = el("nav", { class: "kb-nav", "aria-label": t("roots.title") }, [
      el("button", { class: "kb-nav-new", type: "button", onclick: () => createFolder("") }, [svg("plus", null, 16), t("root.new")]),
    ]);
    const cur = state.folder ? rootOf(state.folder) : state.folder;
    const item = (f, label, actions) => {
      const row = el("div", { class: "kb-nav-item" + (cur === f ? " active" : ""), role: "button", tabindex: "0" }, [
        el("span", { class: "kb-nav-name", text: label, "data-tooltip": label, "data-tooltip-overflow": true }),
        el("span", { class: "kb-nav-count", text: String(entriesIn(f).length) }),
        actions ? el("span", { class: "kb-nav-acts" }, actions) : null,
      ]);
      row.addEventListener("click", () => go(f));
      row.addEventListener("keydown", (ev) => { if (ev.key === "Enter" && ev.target === row) go(f); });
      nav.appendChild(row);
    };
    childFolders("").forEach((f) => item(f, f, [
      actBtn("pencil", t("rename"), () => renameFolder(f)),
      actBtn("trash", t("delete"), () => removeFolder(f), "kb-row-del"),
    ]));
    if (unfiled().length) item("", t("unfiled"), null);
    return nav;
  }

  // Right: breadcrumb, then this folder's sub-folders and documents.
  // Typing in the search box searches this folder and everything below it.
  function docPane() {
    const input = el("input", { class: "kb-filter-input", type: "search", value: state.filter, placeholder: t("filter.placeholderIn") });
    const list = el("div", { class: "kb-list" });
    input.addEventListener("input", () => { state.filter = input.value; drawRows(list); });
    const newFolder = canAdd()
      ? el("button", { class: "kb-btn kb-btn-ghost kb-btn-sm", type: "button", onclick: () => createFolder(state.folder) },
        [svg("folderPlus", null, 15), t("folder.new")])
      : null;
    const pane = el("section", { class: "kb-main" }, [
      el("div", { class: "kb-toolbar" }, [
        crumbs(),
        el("div", { class: "kb-toolbar-right" }, [el("label", { class: "kb-filter" }, [svg("search", "kb-filter-icon", 14), input]), newFolder, sortButton()]),
      ]),
      list,
    ]);
    drawRows(list);
    return pane;
  }

  // Which order the rows are in; a compact dropdown so the toolbar stays one
  // line. Same menu mechanism (and single open menu) as "Add data source".
  function sortButton() {
    const cur = state.sort === "time" ? "sort.time" : "sort.name";
    const btn = el("button", { class: "kb-btn kb-btn-ghost kb-btn-sm", type: "button", "aria-label": t("sort.tip") },
      [svg("sort", null, 15), el("span", { text: t(cur) })]);
    const holder = el("div", { class: "kb-menu-holder" }, [btn]);
    btn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      if (openMenu) { closeMenus(); return; }
      const item = (v, label) => el("button", { type: "button", class: "kb-sort-item", onclick: () => { closeMenus(); setSort(v); } }, [
        el("span", { class: "kb-sort-label", text: label }),
        state.sort === v ? svg("check", "kb-sort-check", 15) : null,
      ]);
      openMenu = el("div", { class: "kb-menu kb-sort-menu" }, [item("name", t("sort.name")), item("time", t("sort.time"))]);
      openMenu.addEventListener("click", (e) => e.stopPropagation());
      holder.appendChild(openMenu);
    });
    return holder;
  }

  function crumbs() {
    const nav = el("div", { class: "kb-crumbs" });
    if (!state.folder) {
      nav.appendChild(el("span", { class: "kb-crumb kb-crumb-cur", text: t("unfiled") }));
      return nav;
    }
    const parts = state.folder.split("/");
    parts.forEach((p, i) => {
      const f = parts.slice(0, i + 1).join("/");
      if (i) nav.appendChild(el("span", { class: "kb-crumb-sep" }, [svg("chevronRight", null, 14)]));
      nav.appendChild(i === parts.length - 1
        ? el("span", { class: "kb-crumb kb-crumb-cur", text: p, "data-tooltip": p, "data-tooltip-overflow": true })
        : el("button", { type: "button", class: "kb-crumb", text: p, "data-tooltip": p, "data-tooltip-overflow": true, onclick: () => go(f) }));
    });
    return nav;
  }

  function drawRows(list) {
    const f = state.filter.trim().toLowerCase();
    const here = state.folder;
    let folders = [];
    let docs;
    if (f) {
      docs = entriesIn(here).filter((e) =>
        e.title.toLowerCase().includes(f) || (e.source || "").toLowerCase().includes(f) || e.folder.toLowerCase().includes(f));
    } else {
      folders = here ? childFolders(here) : [];
      docs = state.data.entries.filter((e) => e.folder === here);
    }
    if (state.sort === "time") {
      // Newest first. Folders carry the newest timestamp inside them, so an
      // untouched folder sinks; ties fall back to the natural name order.
      const newest = (ta, tb) => (ta === tb ? 0 : ta < tb ? 1 : -1);
      folders.sort((a, b) => newest(latest(entriesIn(a)), latest(entriesIn(b))) || byName(nameOf(a), nameOf(b)));
      docs.sort((a, b) => newest(a.updated_at || "", b.updated_at || "") || byName(a.title, b.title));
    } else {
      docs.sort((a, b) => byName(a.title, b.title)); // folders already come back sorted
    }
    list.replaceChildren();
    if (!folders.length && !docs.length) {
      list.appendChild(el("div", { class: "kb-list-empty", text: t(f ? "empty.filter" : "empty.folder") }));
      return;
    }
    folders.forEach((d) => list.appendChild(folderRow(d)));
    docs.forEach((e) => list.appendChild(docRow(e, !!f)));
  }

  function actBtn(icon, label, fn, extra) {
    const b = el("button", { type: "button", class: "kb-row-act" + (extra ? " " + extra : ""), "aria-label": label, "data-tooltip": label }, [svg(icon, null, 15)]);
    b.addEventListener("click", (ev) => { ev.stopPropagation(); fn(); });
    return b;
  }

  // Right edge of a row: the timestamp sits flush right; on hover the row's
  // actions fade in on top of it (the time keeps its box, so nothing shifts).
  function rowEnd(timeText, actions) {
    return el("span", { class: "kb-row-end" }, [
      el("span", { class: "kb-row-time", text: timeText }),
      el("span", { class: "kb-row-acts" }, actions),
    ]);
  }

  function rowEl(children, onOpen) {
    const row = el("div", { class: "kb-row", role: "button", tabindex: "0" }, children);
    row.addEventListener("click", onOpen);
    row.addEventListener("keydown", (ev) => { if (ev.key === "Enter" && ev.target === row) onOpen(); });
    return row;
  }

  function folderRow(d) {
    const inside = entriesIn(d);
    return rowEl([
      svg("folder", "kb-row-icon", 18),
      el("div", { class: "kb-row-main" }, [el("div", { class: "kb-row-title", text: nameOf(d) })]),
      el("span", { class: "kb-row-num", text: t("docs", { n: inside.length }) }),
      rowEnd(fmtDate(latest(inside)), [
        actBtn("pencil", t("rename"), () => renameFolder(d)),
        actBtn("trash", t("delete"), () => removeFolder(d), "kb-row-del"),
      ]),
    ], () => go(d));
  }

  // In search results, documents from sub-folders show where they live.
  function docRow(e, showWhere) {
    const sub = showWhere && e.folder !== state.folder
      ? e.folder.slice(state.folder ? state.folder.length + 1 : 0).split("/").join(" / ") : "";
    const line = [sub, e.source].filter(Boolean).join(" · ");
    return rowEl([
      svg("file", "kb-row-icon", 18),
      el("div", { class: "kb-row-main" }, [
        el("div", { class: "kb-row-title", text: e.title }),
        line ? el("div", { class: "kb-row-source", text: line }) : null,
      ]),
      el("span", { class: "kb-row-num", text: t("chars", { n: e.chars.toLocaleString() }) }),
      rowEnd(fmtDate(e.updated_at), [
        actBtn("pencil", t("rename"), () => renameEntry(e)),
        actBtn("move", t("move.tip"), () => moveEntry(e)),
        actBtn("trash", t("delete"), () => removeEntry(e), "kb-row-del"),
      ]),
    ], () => openEntry(e.path));
  }

  // Row timestamp: "11月16日 17:24" (zh) / "Nov 16, 17:24" (en); the year is
  // only shown when it is not the current one.
  function fmtDate(iso) {
    const d = new Date(iso);
    if (!iso || isNaN(d)) return "";
    const pad = (n) => String(n).padStart(2, "0");
    const clock = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    const sameYear = d.getFullYear() === new Date().getFullYear();
    if (isZh()) {
      const day = `${d.getMonth() + 1}月${d.getDate()}日`;
      return `${sameYear ? "" : d.getFullYear() + "年"}${day} ${clock}`;
    }
    const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    const day = `${MON[d.getMonth()]} ${d.getDate()}`;
    return `${sameYear ? day : day + ", " + d.getFullYear()} ${clock}`;
  }

  // ── Rename / move / folders ────────────────────────────────────────────
  // Small one-field dialog (host form styles); onSubmit throws to stay open.
  function promptBox({ title, label, value, okText, onSubmit }) {
    const { overlay, box, close } = modal("kb-modal-sm");
    const input = el("input", { class: "form-input", type: "text", value: value || "", maxlength: "200" });
    const ok = el("button", { class: "kb-btn kb-btn-primary", type: "submit", text: okText || t("save") });
    const form = el("form", { class: "kb-meta-form" }, [
      el("label", { class: "form-group" }, [el("span", { class: "form-label", text: label }), input]),
      el("div", { class: "kb-modal-foot kb-pick-foot" }, [
        el("button", { class: "kb-btn kb-btn-ghost", type: "button", text: t("cancel"), onclick: close }),
        ok,
      ]),
    ]);
    const sync = () => { ok.disabled = !input.value.trim(); };
    input.addEventListener("input", sync);
    sync();
    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const v = input.value.trim();
      if (!v) return;
      ok.disabled = true;
      try {
        await onSubmit(v);
        close();
      } catch (err) {
        ok.disabled = false;
        toast(errText(err.message), "error");
      }
    });
    box.append(modalHeader(title, close), form);
    document.body.appendChild(overlay);
    input.focus();
    input.select();
  }

  function renameEntry(e) {
    promptBox({
      title: t("rename"), label: t("title"), value: e.title,
      onSubmit: async (title) => {
        const cur = (await call("GET", `/entry?path=${q(e.path)}`)).entry;
        await call("POST", "/entry", { path: cur.path, title, source: cur.source, body: cur.body });
        toast(t("saved"), "success");
        await reload();
      },
    });
  }

  // parent "" = a new root folder (left column); otherwise a sub-folder.
  function createFolder(parent) {
    const isRoot = !parent;
    promptBox({
      title: t(isRoot ? "root.new" : "folder.new"), label: t("folder.name"), okText: t("create"),
      onSubmit: async (name) => {
        const res = await call("POST", "/folder", { parent, name });
        if (isRoot) state.folder = res.folder;
        await reload();
      },
    });
  }

  function renameFolder(d) {
    promptBox({
      title: t("rename"), label: t("folder.name"), value: nameOf(d),
      onSubmit: async (name) => {
        const res = await call("POST", "/folder/rename", { folder: d, name });
        if (state.folder && within(state.folder, d)) state.folder = res.folder + state.folder.slice(d.length);
        toast(t("saved"), "success");
        await reload();
      },
    });
  }

  async function removeFolder(d) {
    const n = entriesIn(d).length;
    const msg = n ? t("confirm.deleteFolder", { name: nameOf(d), n }) : t("confirm.deleteEmptyFolder", { name: nameOf(d) });
    if (!(await confirmBox(msg))) return;
    try {
      await call("DELETE", `/folder?folder=${q(d)}`);
      if (state.folder && within(state.folder, d)) state.folder = parentOf(d) || null;
      toast(t("deleted"), "success");
      await reload();
    } catch (err) { toast(errText(err.message), "error"); }
  }

  // Pick a destination in any root's folder tree; the current folder is
  // shown but can't be picked, and documents always go into some folder.
  function moveEntry(e) {
    const { overlay, box, close } = modal("kb-modal-sm");
    let target = null;
    const ok = el("button", { class: "kb-btn kb-btn-primary", type: "button", text: t("move.here"), disabled: true });
    const rows = folderOrder().map((f) => {
      const depth = f.split("/").length - 1;
      const here = f === e.folder;
      const row = el("button", {
        type: "button", class: "kb-pick-folder", disabled: here, title: loc(f),
        style: `padding-left:${10 + Math.min(depth, 6) * 18}px`,
      }, [
        svg(depth ? "folder" : "book", "kb-pick-icon", 15),
        el("span", { class: "kb-nav-name", text: nameOf(f) }),
        here ? el("span", { class: "kb-nav-count", text: t("move.current") }) : null,
      ]);
      row.addEventListener("click", () => {
        target = f;
        rows.forEach((r) => r.classList.toggle("active", r === row));
        ok.disabled = false;
      });
      return row;
    });
    ok.addEventListener("click", async () => {
      if (target == null) return;
      ok.disabled = true;
      try {
        await call("POST", "/move", { path: e.path, folder: target });
        close();
        toast(t("moved", { where: loc(target) }), "success");
        await reload();
      } catch (err) {
        ok.disabled = false;
        toast(errText(err.message), "error");
      }
    });
    box.append(
      modalHeader(t("move.title", { title: e.title }), close),
      el("div", { class: "kb-pick-list kb-move-list" }, rows),
      el("div", { class: "kb-modal-foot kb-pick-foot" }, [
        el("button", { class: "kb-btn kb-btn-ghost", type: "button", text: t("cancel"), onclick: close }),
        ok,
      ]),
    );
    document.body.appendChild(overlay);
  }

  async function removeEntry(e) {
    if (!(await confirmBox(t("confirm.delete", { title: e.title })))) return;
    try {
      await call("DELETE", `/entry?path=${q(e.path)}`);
      toast(t("deleted"), "success");
      await reload();
    } catch (err) { toast(err.message, "error"); }
  }

  // ── Add data source ────────────────────────────────────────────────────
  let openMenu = null;
  function closeMenus() {
    if (openMenu) { openMenu.remove(); openMenu = null; }
  }
  document.addEventListener("click", closeMenus);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeMenus(); });

  function addSourceButton() {
    // Busy state lives inside the button so the list below never shifts.
    // Disabled until a root folder is open: every document lives in one.
    const off = !!state.busy || !(state.data && canAdd());
    const btn = el("button", { class: "kb-btn kb-btn-primary", type: "button", disabled: off, "aria-busy": state.busy ? "true" : null,
      title: state.data && !canAdd() && !state.busy ? t("add.needRoot") : null },
      state.busy
        ? [el("span", { class: "kb-spinner kb-spinner-on-accent" }), state.busy]
        : [svg("plus", null, 15), t("btn.add"), svg("chevron", "kb-chevron", 14)]);
    const holder = el("div", { class: "kb-menu-holder" }, [btn]);
    btn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      if (openMenu) { closeMenus(); return; }
      const item = (icon, label, desc, fn) => el("button", {
        type: "button", class: "kb-menu-item",
        onclick: () => { closeMenus(); fn(); },
      }, [
        el("span", { class: "kb-menu-icon" }, [svg(icon, null, 16)]),
        el("span", { class: "kb-menu-text" }, [
          el("span", { class: "kb-menu-label", text: label }),
          el("span", { class: "kb-menu-desc", text: desc }),
        ]),
      ]);
      openMenu = el("div", { class: "kb-menu" }, [
        item("upload", t("add.files"), t("add.files.desc"), pickFiles),
        item("folder", t("add.folder"), t("add.folder.desc"), pickFolder),
      ]);
      openMenu.addEventListener("click", (e) => e.stopPropagation());
      holder.appendChild(openMenu);
    });
    return holder;
  }

  function setBusy(text) {
    state.busy = text;
    renderPage();
  }

  function pickFiles() {
    const input = el("input", { type: "file", accept: ".md,.markdown,.txt,.pdf,.doc,.docx,.wps" });
    input.addEventListener("change", () => {
      const file = (input.files || [])[0];
      if (file) previewFile(file);
    });
    input.click();
  }

  // Single-file upload: convert first, let the user check / fix the text in
  // the host editor, and only save when they press Import. Cancel = discard.
  async function previewFile(file) {
    const folder = state.folder;
    setBusy(t("busy.preview"));
    const form = new FormData();
    form.append("file", file, file.name);
    let doc;
    try {
      doc = await call("POST", "/preview", form);
    } catch (e) {
      setBusy(null);
      showFailures([{ file: file.name, error: e.message }]);
      return;
    }
    setBusy(null);
    if (!window.CodeEditor) return;
    window.CodeEditor.open({
      content: doc.body,
      title: t("preview.title", { title: doc.title }),
      filename: "entry.md",
      language: "markdown",
      onSave: async (body) => {
        await call("POST", "/entry", { folder, title: doc.title, source: doc.source, body });
        await reload();
        toast(t("done", { n: 1 }), "success");
      },
    });
    const overlay = document.getElementById("code-editor-overlay");
    const save = overlay && overlay.querySelector(".code-editor-save");
    if (save) save.textContent = t("preview.import");
    const status = overlay && overlay.querySelector(".code-editor-status");
    if (status) status.textContent = (doc.parsed ? t("preview.parsed") : t("preview.hint")) + " " + t("preview.where", { where: loc(folder) });
  }

  // Folder import: the browser's own folder picker reads the folder on the
  // user's machine (works for cloud deployments too). Supported files are
  // uploaded one by one and saved straight away, no per-file preview. The
  // picked folder lands inside the current one with its structure intact.
  const FOLDER_EXTS = /\.(md|markdown|txt|pdf|doc|docx|wps)$/i;
  const MAX_FOLDER_FILES = 500;

  function pickFolder() {
    const input = el("input", { type: "file", webkitdirectory: true, multiple: true });
    input.addEventListener("change", () => {
      const all = Array.from(input.files || []);
      if (all.length) previewFolder(all);
    });
    input.click();
  }

  // Path inside the picked folder (parts[0] is the folder itself) and the
  // knowledge-base folder the file goes to: <current>/<picked>/<sub>/….
  function folderItem(f, base) {
    const parts = (f.webkitRelativePath || f.name).split("/");
    return { file: f, rel: parts.join("/"), folder: [base, ...parts.slice(0, -1)].filter(Boolean).join("/") };
  }

  // Show what will be imported; nothing is uploaded until the user confirms.
  function previewFolder(all) {
    const base = state.folder;
    const items = all.filter((f) => {
      const parts = (f.webkitRelativePath || f.name).split("/");
      return FOLDER_EXTS.test(f.name) && !parts.some((p) => p.startsWith("."));
    }).map((f) => folderItem(f, base)).sort((a, b) => byName(a.rel, b.rel));
    if (!items.length) { toast(errText("no supported files in this folder"), "error"); return; }
    if (items.length > MAX_FOLDER_FILES) { toast(errText("too many files"), "error"); return; }

    const { overlay, box, close } = modal();
    const picked = new Set(items);
    const go = el("button", { class: "kb-btn kb-btn-primary", type: "button" });
    const sync = () => {
      go.textContent = t("folder.start", { n: picked.size });
      go.disabled = picked.size === 0;
    };
    const rows = items.map((it) => {
      const cb = el("input", { type: "checkbox", checked: true });
      cb.addEventListener("change", () => { if (cb.checked) picked.add(it); else picked.delete(it); sync(); });
      return el("label", { class: "kb-pick" }, [
        cb,
        el("span", { class: "kb-pick-name", text: it.rel, title: it.rel }),
      ]);
    });
    const skipped = all.length - items.length;
    go.addEventListener("click", () => {
      const chosen = items.filter((it) => picked.has(it));
      close();
      importFolder(chosen, [base, (all[0].webkitRelativePath || "").split("/")[0]].filter(Boolean).join("/"));
    });
    sync();
    box.append(
      modalHeader(t("folder.title"), close),
      el("p", { class: "kb-pick-hint", text: t("folder.hint", { n: items.length, where: loc(base) }) + (skipped ? " " + t("folder.skipped", { n: skipped }) : "") }),
      el("div", { class: "kb-pick-list" }, rows),
      el("div", { class: "kb-modal-foot kb-pick-foot" }, [
        el("button", { class: "kb-btn kb-btn-ghost", type: "button", text: t("cancel"), onclick: close }),
        go,
      ]),
    );
    document.body.appendChild(overlay);
  }

  // `top` = the imported folder's new location; shown once the import ends.
  async function importFolder(items, top) {
    let ok = 0;
    let parsed = false;
    const failed = [];
    for (let i = 0; i < items.length; i++) {
      const { file: f, rel, folder } = items[i];
      setBusy(t("busy.folder", { i: i + 1, n: items.length }));
      const form = new FormData();
      form.append("file", f, f.name);
      form.append("folder", folder);
      try {
        await call("POST", "/upload", form);
        ok += 1;
        if (!/\.(md|markdown|txt)$/i.test(f.name)) parsed = true;
      } catch (e) {
        failed.push({ file: rel, error: e.message });
      }
    }
    state.busy = null;
    if (ok && top) {
      state.folder = top;
      state.filter = "";
    }
    await reload();
    if (ok) toast(t("done", { n: ok }) + (parsed ? " " + t("done.parsed") : ""), "success");
    if (failed.length) showFailures(failed);
  }

  function showFailures(failed) {
    const { overlay, box, close } = modal("kb-modal-sm");
    const ok = el("button", { class: "kb-btn kb-btn-primary", type: "button", text: t("failed.ok"), onclick: close });
    box.append(
      modalHeader(t("failed.title", { n: failed.length }), close),
      el("div", { class: "kb-fail-list" }, failed.map((f) => el("div", { class: "kb-fail" }, [
        el("div", { class: "kb-fail-file", text: f.file }),
        el("div", { class: "kb-fail-err", text: errText(f.error) }),
      ]))),
      el("div", { class: "kb-modal-foot" }, [ok]),
    );
    document.body.appendChild(overlay);
  }

  // ── Edit (host Markdown editor: source + live preview) ─────────────────
  async function openEntry(path) {
    let entry;
    try {
      entry = (await call("GET", `/entry?path=${q(path)}`)).entry;
    } catch (e) {
      toast(t("loadFailed", { msg: e.message }), "error");
      return;
    }
    if (!window.CodeEditor) return;
    window.CodeEditor.open({
      content: entry.body,
      title: entry.title,
      filename: "entry.md",
      language: "markdown",
      onSave: async (body) => {
        await call("POST", "/entry", {
          path: entry.path, title: entry.title, source: entry.source, body,
        });
        toast(t("saved"), "success");
        await reload();
      },
    });
  }

  // ── Modal helpers ──────────────────────────────────────────────────────
  function modal(extraClass) {
    const box = el("div", { class: "kb-modal " + (extraClass || ""), role: "dialog", "aria-modal": "true" });
    const overlay = el("div", { class: "modal-overlay kb-overlay" }, [box]);
    const onKey = (e) => { if (e.key === "Escape") close(); };
    function close() {
      overlay.remove();
      document.removeEventListener("keydown", onKey);
    }
    overlay.addEventListener("mousedown", (e) => { if (e.target === overlay) close(); });
    document.addEventListener("keydown", onKey);
    return { overlay, box, close };
  }

  function modalHeader(title, close) {
    return el("div", { class: "kb-modal-head" }, [
      el("h3", { class: "kb-modal-title", text: title }),
      el("button", { type: "button", class: "modal-close-btn", "aria-label": t("close"), onclick: close }),
    ]);
  }

  // ── Recall test ────────────────────────────────────────────────────────
  function openRecall() {
    const { overlay, box, close } = modal("kb-modal-recall");
    const input = el("input", { class: "kb-recall-input", type: "search", placeholder: t("recall.ph"), value: state.lastQuery });
    const btn = el("button", { class: "kb-btn kb-btn-primary", type: "submit", disabled: !state.lastQuery.trim() },
      [svg("zap", null, 15), t("recall.btn")]);

    // Recent searches: dropped under the field, opened by the clock button or
    // by clicking into the field — not by the focus we do on open, which would
    // cover the results the user just asked for.
    const menu = el("div", { class: "kb-recall-history" });
    let open = false;
    const hide = () => { open = false; menu.classList.remove("open"); };
    const show = () => {
      const list = loadHistory();
      if (!list.length) return;
      menu.replaceChildren(
        el("div", { class: "kb-recall-hist-head" }, [
          el("span", { text: t("recall.history") }),
          el("button", {
            type: "button", class: "kb-recall-hist-clear", text: t("recall.history.clear"),
            onclick: (ev) => { ev.preventDefault(); saveHistory([]); hide(); },
          }),
        ]),
        ...list.map((q) => el("button", {
          type: "button", class: "kb-recall-hist-item",
          onclick: (ev) => {
            ev.preventDefault();
            input.value = q;
            input.dispatchEvent(new Event("input"));
            hide();
            run();
          },
        }, [svg("history", "kb-recall-hist-icon", 15), el("span", { class: "kb-recall-hist-text", text: q })])),
      );
      open = true;
      menu.classList.add("open");
    };
    const histBtn = el("button", {
      type: "button", class: "kb-recall-hist-btn", "aria-label": t("recall.history"),
      "data-tooltip": t("recall.history"), "data-tooltip-pos": "bottom",
      onclick: (ev) => { ev.preventDefault(); ev.stopPropagation(); if (open) hide(); else show(); },
    }, [svg("history", null, 16)]);

    const field = el("div", { class: "kb-recall-field" }, [svg("search", "kb-recall-icon", 16), input, histBtn, menu]);
    const form = el("form", { class: "kb-recall-form" }, [field, btn]);
    const results = el("div", { class: "kb-recall-results" });
    box.append(modalHeader(t("recall.title"), close), form, results);

    // Clicking anywhere else closes the dropdown; it also unhooks itself once
    // the modal is gone.
    const onDocDown = (ev) => {
      if (!overlay.isConnected) { document.removeEventListener("mousedown", onDocDown); return; }
      if (!field.contains(ev.target)) hide();
    };
    document.addEventListener("mousedown", onDocDown);

    const placeholder = (title, sub) => results.replaceChildren(el("div", { class: "kb-recall-empty" }, [
      el("div", { class: "kb-recall-empty-icon" }, [svg("inbox", null, 36)]),
      el("div", { class: "kb-recall-empty-title", text: title }),
      sub ? el("div", { class: "kb-recall-empty-sub", text: sub }) : null,
    ]));

    async function run() {
      const query = input.value.trim();
      state.lastQuery = input.value;
      if (!query) return;
      rememberQuery(query);
      btn.disabled = true;
      results.replaceChildren(el("div", { class: "kb-recall-loading" }, [el("span", { class: "kb-spinner" })]));
      try {
        const data = await call("POST", "/search", { query, limit: 10 });
        if (!data.hits.length) placeholder(t("recall.none"));
        else drawHits(results, data);
      } catch (e) {
        results.replaceChildren(el("div", { class: "kb-error", text: e.message }));
      } finally {
        btn.disabled = !input.value.trim();
      }
    }

    input.addEventListener("input", () => { btn.disabled = !input.value.trim(); hide(); });
    input.addEventListener("click", () => { if (!open) show(); });
    input.addEventListener("keydown", (ev) => {
      // Escape closes just the dropdown; the modal's own Escape still applies.
      if (ev.key === "Escape" && open) { ev.preventDefault(); ev.stopPropagation(); hide(); }
    });
    form.addEventListener("submit", (ev) => { ev.preventDefault(); run(); });

    document.body.appendChild(overlay);
    if (state.lastQuery.trim()) run();
    else placeholder(t("recall.empty"), t("recall.empty.sub"));
    setTimeout(() => input.focus(), 30);
  }

  function drawHits(wrap, data) {
    wrap.replaceChildren(el("div", { class: "kb-recall-hint", text: t("recall.hint", { k: data.top_k }) }));
    const max = Math.max(...data.hits.map((h) => h.score), 0.0001);
    data.hits.forEach((h, i) => {
      const used = i < data.top_k;
      const score = h.score.toFixed(2);
      const text = h.text.replace(/\n{2,}/g, "\n");
      const hitText = el("div", { class: "kb-hit-text", text });
      const card = el("button", {
        type: "button", class: "kb-hit" + (used ? " used" : ""), "aria-expanded": "false",
      }, [
        el("div", { class: "kb-hit-head" }, [
          el("span", { class: "kb-hit-rank", text: String(i + 1) }),
          el("span", { class: "kb-hit-title", text: h.title }),
          h.folder ? el("span", { class: "kb-tag kb-hit-folder", text: loc(h.folder), title: loc(h.folder) }) : null,
          used ? el("span", { class: "kb-tag kb-tag-accent", text: t("recall.injected") }) : null,
          el("span", { class: "kb-spacer" }),
          el("span", {
            class: "kb-hit-score",
            "data-tooltip": t("recall.score.tip", { score }),
            "data-tooltip-pos": "bottom",
          }, [
            el("span", { class: "kb-hit-bar" }, [el("span", { style: `width:${Math.round((h.score / max) * 100)}%` })]),
            el("span", { text: score }),
          ]),
          el("span", { class: "kb-hit-toggle" }, [svg("chevron", null, 14)]),
        ]),
        hitText,
      ]);
      // Clicking shows the whole document in place instead of jumping to the
      // editor: the snippet is only an excerpt, and leaving the modal loses the
      // results the user is still comparing.
      let expanded = false;
      let body = null;
      const setBody = (value) => { hitText.textContent = value; };
      card.addEventListener("click", async () => {
        if (expanded) {
          expanded = false;
          card.classList.remove("expanded");
          card.setAttribute("aria-expanded", "false");
          setBody(text);
          return;
        }
        if (body !== null) {
          expanded = true;
          card.classList.add("expanded");
          card.setAttribute("aria-expanded", "true");
          setBody(body);
          return;
        }
        hitText.replaceChildren(el("span", { class: "kb-spinner" }));
        try {
          body = (await call("GET", `/entry?path=${q(h.path)}`)).entry.body;
          expanded = true;
          card.classList.add("expanded");
          card.setAttribute("aria-expanded", "true");
          setBody(body);
        } catch (e) {
          setBody(text);
          toast(t("loadFailed", { msg: e.message }), "error");
        }
      });
      wrap.appendChild(card);
    });
  }

  // ── Sidebar entry + workspace registration ─────────────────────────────
  function navRow() {
    const item = el("div", { class: "task-item task-item-summary" });
    const row = el("div", { class: "task-row" });
    row.appendChild(svg("book", "task-icon"));
    const name = el("span", { class: "task-name", text: t("nav.entry") });
    row.appendChild(el("div", { class: "task-info" }, [name]));
    item.appendChild(row);
    document.addEventListener("langchange", () => { name.textContent = t("nav.entry"); });
    item.addEventListener("click", () => Clacky.ext.ui.openWorkspace(WS_ID));
    return item;
  }

  document.addEventListener("langchange", () => { if (root && root.isConnected) renderPage(); });

  Clacky.ext.ui.registerWorkspace(WS_ID, { title: t("ws.title"), render });
  // order 110: right below Creator Center (default order 100).
  Clacky.ext.ui.mount("sidebar.nav.bottom", navRow, { workspace: WS_ID, order: 110 });

  const ACCENT = "var(--color-accent-primary)";
  const style = document.createElement("style");
  style.textContent = `
    .kb-page { width: 100%; max-width: 1120px; margin: 0 auto; padding: 8px 4px 32px; display: flex; flex-direction: column; }
    .kb-head { display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; margin-bottom: 24px; }
    .kb-title { margin: 0; font-size: 1.375rem; font-weight: 600; letter-spacing: -0.01em; color: var(--color-text-primary); }
    .kb-sub { margin: 4px 0 0; font-size: 0.8125rem; color: var(--color-text-tertiary); }
    .kb-head-actions { display: flex; align-items: center; gap: 8px; flex-shrink: 0; }
    .kb-btn { display: inline-flex; align-items: center; gap: 6px; height: 34px; padding: 0 14px; border-radius: 8px; font-size: 0.8125rem; font-weight: 500; cursor: pointer; border: 1px solid transparent; transition: background .15s, border-color .15s, color .15s; white-space: nowrap; }
    .kb-btn:disabled { opacity: .5; cursor: default; }
    .kb-btn[aria-busy="true"]:disabled { opacity: .85; cursor: progress; }
    .kb-btn-primary { background: ${ACCENT}; color: #fff; }
    .kb-btn-primary:not(:disabled):hover { filter: brightness(1.06); }
    .kb-btn-ghost { background: var(--color-bg-primary); color: var(--color-text-secondary); border-color: var(--color-border-primary); }
    .kb-btn-ghost:hover { color: var(--color-text-primary); background: var(--color-bg-hover); }
    .kb-chevron { margin-left: 2px; opacity: .8; }
    .kb-menu-holder { position: relative; }
    .kb-menu { position: absolute; right: 0; top: calc(100% + 6px); z-index: 50; width: 288px; padding: 6px; background: var(--color-bg-primary); border: 1px solid var(--color-border-primary); border-radius: 12px; box-shadow: var(--shadow-lg, 0 12px 32px rgba(0,0,0,.12)); animation: kb-pop .12s ease-out; }
    @keyframes kb-pop { from { opacity: 0; transform: translateY(-4px); } to { opacity: 1; transform: none; } }
    .kb-menu-item { display: flex; align-items: flex-start; gap: 10px; width: 100%; padding: 9px 10px; border: none; background: transparent; border-radius: 8px; cursor: pointer; text-align: left; color: inherit; font: inherit; }
    .kb-menu-item:hover { background: var(--color-bg-hover); }
    .kb-menu-icon { display: flex; align-items: center; justify-content: center; width: 30px; height: 30px; border-radius: 8px; flex-shrink: 0; color: ${ACCENT}; background: color-mix(in srgb, ${ACCENT} 10%, transparent); }
    .kb-menu-text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
    .kb-menu-label { font-size: 0.8125rem; font-weight: 500; color: var(--color-text-primary); }
    .kb-menu-desc { font-size: 0.75rem; color: var(--color-text-tertiary); }
    .kb-sort-menu { width: 168px; padding: 4px; }
    .kb-sort-item { display: flex; align-items: center; justify-content: space-between; gap: 8px; width: 100%; padding: 7px 9px; border: none; background: transparent; border-radius: 7px; cursor: pointer; text-align: left; color: var(--color-text-primary); font: inherit; font-size: 0.8125rem; }
    .kb-sort-item:hover { background: var(--color-bg-hover); }
    .kb-sort-check { color: ${ACCENT}; flex-shrink: 0; }
    .kb-spinner { width: 14px; height: 14px; border-radius: 50%; border: 2px solid var(--color-border-primary); border-top-color: ${ACCENT}; animation: kb-spin .7s linear infinite; flex-shrink: 0; }
    .kb-spinner-on-accent { border-color: rgba(255, 255, 255, 0.35); border-top-color: #fff; }
    @keyframes kb-spin { to { transform: rotate(360deg); } }
    .kb-warn { font-size: 0.8125rem; color: var(--color-warning, #b54708); background: color-mix(in srgb, var(--color-warning, #f79009) 10%, transparent); border-radius: 10px; padding: 10px 14px; margin-bottom: 16px; }
    .kb-error { color: var(--color-error); font-size: 0.8125rem; padding: 12px 0; }
    .kb-skeleton { height: 160px; border-radius: 12px; background: var(--color-bg-secondary); }
    .kb-empty { display: flex; flex-direction: column; align-items: center; text-align: center; padding: 72px 24px; border: 1px dashed var(--color-border-primary); border-radius: 14px; }
    .kb-empty-icon { display: flex; align-items: center; justify-content: center; width: 56px; height: 56px; border-radius: 14px; color: ${ACCENT}; background: color-mix(in srgb, ${ACCENT} 10%, transparent); margin-bottom: 16px; }
    .kb-empty-title { font-size: 0.9375rem; font-weight: 600; color: var(--color-text-primary); }
    .kb-empty-desc { font-size: 0.8125rem; color: var(--color-text-tertiary); margin-top: 6px; max-width: 360px; line-height: 1.6; }
    .kb-empty-actions { display: flex; gap: 8px; margin-top: 20px; }
    .kb-body { display: grid; grid-template-columns: 232px minmax(0, 1fr); gap: 20px; align-items: start; }
    .kb-main { min-width: 0; }
    .kb-nav { position: sticky; top: 8px; min-width: 0; max-height: calc(100vh - 180px); overflow: auto; display: flex; flex-direction: column; gap: 2px; }
    .kb-nav-new { display: flex; align-items: center; gap: 8px; width: 100%; height: 34px; padding: 0 12px; margin-bottom: 4px; border: none; border-radius: 10px; background: transparent; color: var(--color-text-secondary); font: inherit; font-size: 0.875rem; cursor: pointer; transition: background .12s, color .12s; }
    .kb-nav-new svg { color: var(--color-text-tertiary); }
    .kb-nav-new:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
    .kb-nav-item { position: relative; display: flex; align-items: center; gap: 8px; height: 34px; padding: 0 8px 0 12px; border-radius: 10px; color: var(--color-text-secondary); font-size: 0.875rem; cursor: pointer; outline: none; transition: background .12s, color .12s; }
    .kb-nav-item:hover, .kb-nav-item:focus-visible { background: var(--color-bg-hover); color: var(--color-text-primary); }
    .kb-nav-item.active { background: var(--color-bg-hover); color: var(--color-text-primary); font-weight: 500; }
    .kb-nav-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .kb-nav-count { flex: none; font-size: 0.75rem; font-weight: 400; color: var(--color-text-tertiary); font-variant-numeric: tabular-nums; }
    .kb-nav-acts { display: none; flex: none; }
    .kb-nav-item:hover .kb-nav-count, .kb-nav-item:focus-within .kb-nav-count { display: none; }
    .kb-nav-item:hover .kb-nav-acts, .kb-nav-item:focus-within .kb-nav-acts { display: flex; }
    .kb-nav-acts .kb-row-act { width: 24px; height: 24px; opacity: 1; }
    .kb-toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; min-height: 32px; margin-bottom: 8px; flex-wrap: wrap; }
    .kb-toolbar-right { display: flex; align-items: center; gap: 8px; }
    .kb-btn-sm { height: 32px; padding: 0 10px; }
    .kb-crumbs { display: flex; align-items: center; gap: 2px; flex: 1; min-width: 0; font-size: 0.9375rem; overflow: hidden; overflow: clip; overflow-clip-margin: 8px; }
    .kb-crumb { max-width: 220px; padding: 3px 6px; border: none; border-radius: 6px; background: none; font: inherit; color: var(--color-text-tertiary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; cursor: pointer; flex-shrink: 1; }
    .kb-crumbs > .kb-crumb:first-child { margin-left: -6px; }
    button.kb-crumb:hover { color: var(--color-text-primary); background: var(--color-bg-hover); }
    .kb-crumb-cur { color: var(--color-text-primary); font-weight: 600; cursor: default; }
    .kb-crumb-sep { display: flex; color: var(--color-text-tertiary); opacity: .6; flex: none; }
    .kb-filter { position: relative; display: flex; align-items: center; width: 17.5rem; }
    .kb-filter-icon { position: absolute; left: 0.625rem; color: var(--color-text-tertiary); pointer-events: none; }
    .kb-filter-input { width: 100%; height: 2rem; padding: 0 0.625rem 0 1.875rem; border-radius: 8px; border: 1px solid var(--color-border-primary); background: var(--color-bg-primary); color: var(--color-text-primary); font-size: 0.8125rem; outline: none; }
    .kb-filter-input:focus { border-color: ${ACCENT}; box-shadow: 0 0 0 3px color-mix(in srgb, ${ACCENT} 15%, transparent); }
    .kb-list { display: flex; flex-direction: column; border: 1px solid var(--color-border-primary); border-radius: 12px; overflow: hidden; background: var(--color-bg-primary); box-shadow: 0 1px 2px rgba(16, 24, 40, .04); }
    .kb-list-empty { padding: 56px 16px; text-align: center; font-size: 0.8125rem; color: var(--color-text-tertiary); }
    .kb-row { display: grid; grid-template-columns: 20px minmax(0, 1fr) 64px auto; align-items: center; gap: 12px; min-height: 52px; padding: 8px 12px 8px 16px; cursor: pointer; transition: background .12s; outline: none; }
    .kb-row + .kb-row { border-top: 1px solid var(--color-border-primary); }
    .kb-row:hover, .kb-row:focus-visible { background: var(--color-bg-hover); }
    .kb-row-icon { color: var(--color-text-tertiary); }
    .kb-row-main { min-width: 0; }
    .kb-row-title { font-size: 0.875rem; color: var(--color-text-primary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .kb-row-source { font-size: 0.75rem; color: var(--color-text-tertiary); margin-top: 1px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .kb-row-num { font-size: 0.75rem; color: var(--color-text-tertiary); text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
    .kb-row-end { position: relative; display: flex; align-items: center; justify-content: flex-end; min-width: 82px; }
    .kb-row-time { font-size: 0.75rem; color: var(--color-text-tertiary); text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
    .kb-row-acts { position: absolute; right: 0; top: 50%; transform: translateY(-50%); display: flex; justify-content: flex-end; gap: 2px; opacity: 0; }
    .kb-row-act { display: flex; align-items: center; justify-content: center; width: 26px; height: 26px; border: none; border-radius: 7px; background: transparent; color: var(--color-text-tertiary); cursor: pointer; transition: background .12s, color .12s; }
    .kb-row:hover .kb-row-acts, .kb-row:focus-within .kb-row-acts { opacity: 1; }
    .kb-row:hover .kb-row-time, .kb-row:focus-within .kb-row-time { opacity: 0; }
    .kb-row-act:hover { color: var(--color-text-primary); background: color-mix(in srgb, var(--color-text-primary) 8%, transparent); }
    .kb-row-act.kb-row-del:hover { color: var(--color-error); background: var(--color-error-bg); }
    .kb-tag { font-size: 0.6875rem; line-height: 1; padding: 4px 7px; border-radius: 6px; background: var(--color-bg-secondary); color: var(--color-text-secondary); white-space: nowrap; }
    .kb-tag-accent { color: ${ACCENT}; background: color-mix(in srgb, ${ACCENT} 10%, transparent); }
    @media (max-width: 768px) {
      .kb-head { flex-direction: column; align-items: stretch; }
      .kb-body { grid-template-columns: minmax(0, 1fr); gap: 16px; }
      .kb-nav { position: static; flex-direction: row; overflow-x: auto; }
      .kb-nav-new, .kb-nav-item { flex: none; width: auto; margin: 0; }
      .kb-toolbar-right { width: 100%; }
      .kb-filter { flex: 1; width: auto; }
      .kb-row { grid-template-columns: 20px minmax(0, 1fr) auto; }
      .kb-row-num, .kb-row-time { display: none; }
      .kb-row-acts { position: static; transform: none; opacity: 1; }
      .kb-row-end { min-width: 0; }
    }
    .kb-overlay { z-index: 120; }
    .kb-modal { width: min(92vw, 640px); max-height: 86vh; display: flex; flex-direction: column; background: var(--color-bg-primary); border: 1px solid var(--color-border-primary); border-radius: 16px; box-shadow: var(--shadow-lg, 0 24px 60px rgba(0,0,0,.18)); padding: 20px 24px 24px; animation: modal-box-in var(--transition-slow, .2s); }
    .kb-modal-sm { width: min(92vw, 440px); }
    .kb-modal-recall { height: min(86vh, 720px); }
    .kb-modal-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; }
    .kb-modal-title { margin: 0; font-size: 1.0625rem; font-weight: 600; color: var(--color-text-primary); }
    .kb-modal-foot { display: flex; justify-content: flex-end; margin-top: 16px; }
    .kb-fail-list { display: flex; flex-direction: column; gap: 8px; overflow: auto; }
    .kb-fail { padding: 10px 12px; border-radius: 10px; background: var(--color-bg-secondary); }
    .kb-fail-file { font-size: 0.8125rem; font-weight: 500; color: var(--color-text-primary); word-break: break-all; }
    .kb-fail-err { font-size: 0.75rem; color: var(--color-error); margin-top: 2px; }
    .kb-pick-hint { margin: 0 0 12px; font-size: 0.8125rem; color: var(--color-text-secondary); }
    .kb-pick-list { display: flex; flex-direction: column; overflow: auto; border: 1px solid var(--color-border-primary); border-radius: 10px; }
    .kb-pick-icon { flex: none; opacity: .7; }
    .kb-pick { display: flex; align-items: center; gap: 10px; padding: 8px 12px; cursor: pointer; font-size: 0.8125rem; }
    .kb-pick + .kb-pick { border-top: 1px solid var(--color-border-primary); }
    .kb-pick:hover { background: var(--color-bg-secondary); }
    .kb-pick input { margin: 0; accent-color: ${ACCENT}; flex: none; }
    .kb-pick-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--color-text-primary); }
    .kb-move-list { max-height: 50vh; padding: 4px; gap: 1px; }
    .kb-pick-folder { display: flex; align-items: center; gap: 8px; width: 100%; min-height: 34px; padding-right: 12px; border: none; border-radius: 7px; background: transparent; font: inherit; font-size: 0.8125rem; color: var(--color-text-primary); text-align: left; cursor: pointer; }
    .kb-pick-folder:not(:disabled):hover { background: var(--color-bg-hover); }
    .kb-pick-folder.active { background: color-mix(in srgb, ${ACCENT} 10%, transparent); color: ${ACCENT}; }
    .kb-pick-folder:disabled { cursor: default; color: var(--color-text-tertiary); }
    .kb-pick-foot { gap: 8px; }
    .kb-pick-foot .kb-btn:disabled { opacity: .5; cursor: not-allowed; }
    .kb-recall-form { display: flex; gap: 10px; }
    .kb-recall-field { position: relative; flex: 1; display: flex; align-items: center; }
    .kb-recall-icon { position: absolute; left: 12px; color: var(--color-text-tertiary); pointer-events: none; }
    .kb-recall-input { width: 100%; height: 40px; padding: 0 2.5rem 0 38px; border-radius: 10px; border: 1px solid var(--color-border-primary); background: var(--color-bg-primary); color: var(--color-text-primary); font-size: 0.875rem; outline: none; }
    .kb-recall-input::-webkit-search-cancel-button,
    .kb-recall-input::-webkit-search-decoration { -webkit-appearance: none; appearance: none; }
    .kb-recall-input:focus { border-color: ${ACCENT}; box-shadow: 0 0 0 3px color-mix(in srgb, ${ACCENT} 15%, transparent); }
    .kb-recall-form .kb-btn { height: 40px; padding: 0 16px; border-radius: 10px; }
    .kb-recall-hist-btn { position: absolute; right: 6px; z-index: 1; display: flex; align-items: center; justify-content: center; width: 1.75rem; height: 1.75rem; border: none; border-radius: 7px; background: none; color: var(--color-text-secondary); cursor: pointer; transition: background .15s, color .15s; }
    .kb-recall-hist-btn:hover { background: color-mix(in srgb, var(--color-accent-primary) 8%, transparent); color: var(--color-accent-primary); }
    .kb-recall-history { position: absolute; left: 0; right: 0; top: calc(100% + 6px); z-index: 8; display: none; flex-direction: column; padding: 6px; background: var(--color-bg-primary); border: 1px solid var(--color-border-primary); border-radius: 10px; box-shadow: 0 12px 28px rgba(0, 0, 0, .14); }
    .kb-recall-history.open { display: flex; }
    .kb-recall-hist-head { display: flex; align-items: center; justify-content: space-between; padding: 2px 8px 6px; font-size: 0.75rem; color: var(--color-text-tertiary); }
    .kb-recall-hist-clear { border: none; padding: 0; background: none; font: inherit; color: var(--color-text-tertiary); cursor: pointer; }
    .kb-recall-hist-clear:hover { color: var(--color-accent-primary); }
    .kb-recall-hist-item { display: flex; align-items: center; gap: 10px; height: 2.125rem; padding: 0 8px; border: none; border-radius: 7px; background: none; font: inherit; font-size: 0.875rem; color: var(--color-text-primary); text-align: left; cursor: pointer; }
    .kb-recall-hist-item:hover { background: color-mix(in srgb, var(--color-accent-primary) 8%, transparent); }
    .kb-recall-hist-icon { flex: none; color: var(--color-text-tertiary); }
    .kb-recall-hist-text { min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
    .kb-recall-results { flex: 1; min-height: 0; overflow: auto; margin: 16px -4px 0; padding: 0 4px; display: flex; flex-direction: column; gap: 10px; }
    .kb-recall-empty { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; padding: 32px 16px; color: var(--color-text-tertiary); }
    .kb-recall-empty-icon { opacity: .45; margin-bottom: 14px; }
    .kb-recall-empty-title { font-size: 0.9375rem; color: var(--color-text-secondary); }
    .kb-recall-empty-sub { font-size: 0.8125rem; margin-top: 6px; }
    .kb-recall-loading { flex: 1; display: flex; align-items: center; justify-content: center; }
    .kb-recall-hint { font-size: 0.75rem; color: var(--color-text-tertiary); }
    .kb-hit { display: block; width: 100%; text-align: left; font: inherit; color: inherit; background: var(--color-bg-primary); border: 1px solid var(--color-border-primary); border-radius: 12px; padding: 12px 14px; cursor: pointer; transition: border-color .12s, background .12s; }
    .kb-hit:hover { background: var(--color-bg-hover); }
    .kb-hit:not(.used) { opacity: .7; }
    .kb-hit-head { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; min-width: 0; }
    .kb-hit-rank { display: inline-flex; align-items: center; justify-content: center; width: 20px; height: 20px; border-radius: 6px; font-size: 0.6875rem; font-weight: 600; background: var(--color-bg-secondary); color: var(--color-text-tertiary); flex-shrink: 0; }
    .kb-hit.used .kb-hit-rank { background: color-mix(in srgb, ${ACCENT} 12%, transparent); color: ${ACCENT}; }
    .kb-hit-title { font-size: 0.875rem; font-weight: 500; color: var(--color-text-primary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
    .kb-hit-folder { max-width: 220px; overflow: hidden; text-overflow: ellipsis; flex-shrink: 1; }
    .kb-spacer { flex: 1; }
    .kb-hit-score { display: inline-flex; align-items: center; gap: 6px; font-size: 0.75rem; color: var(--color-text-tertiary); font-variant-numeric: tabular-nums; flex-shrink: 0; }
    .kb-hit-bar { width: 48px; height: 4px; border-radius: 2px; background: var(--color-bg-secondary); overflow: hidden; }
    .kb-hit-bar > span { display: block; height: 100%; background: ${ACCENT}; border-radius: 2px; }
    .kb-hit-text { font-size: 0.8125rem; color: var(--color-text-secondary); line-height: 1.65; white-space: pre-wrap; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
    .kb-hit.expanded .kb-hit-text { display: block; -webkit-line-clamp: unset; overflow: visible; }
    .kb-hit-toggle { display: flex; flex: none; color: var(--color-text-tertiary); transition: transform .18s ease, color .15s; }
    .kb-hit:hover .kb-hit-toggle { color: var(--color-text-secondary); }
    .kb-hit.expanded .kb-hit-toggle { transform: rotate(180deg); }
  `;
  document.head.appendChild(style);
})();
