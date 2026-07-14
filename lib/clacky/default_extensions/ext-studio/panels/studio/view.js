// Extension & Creation — full-page workspace mounted from the sidebar.
// One rail entry opens a page (#ext/ext-studio) with two top tabs:
//   • Extensions — local extension picker + verify (debug) + pack/publish
//   • Skills     — cloud/local skills, publish, iterate, create new
// Backend: extension side is /api/ext/ext-studio/; skill side reuses the host
// APIs /api/creator/skills and /api/my-skills/:name/publish.

(function () {
  const STUDIO_I18N = {
    en: {
      "nav.entry": "Extension & Creation",
      "ws.title": "Extension & Creation",
      "tab.extensions": "Extensions",
      "tab.skills": "Skills",
      "ext.debug.section": "Debug",
      "ext.publish.section": "Publish",
      "debug.tab": "Debug",
      "publish.tab": "Publish",
      "picker.label": "Extension package",
      "picker.empty": "No local extensions. Ask the AI to scaffold one.",
      "detail.version": "Version",
      "detail.layer": "Layer",
      "detail.origin": "Origin",
      "detail.units": "Contributed units",
      "detail.noUnits": "No units",
      "btn.recheck": "Re-check",
      "btn.checking": "Checking…",
      "verify.ok": "All checks passed.",
      "verify.errors": "{{n}} error(s)",
      "verify.warnings": "{{n}} warning(s)",
      "verify.hint": "Hint",
      "hint.reload": "After fixing, reload this page to apply changes.",
      "publish.status": "Status",
      "publish.status.draft": "Draft",
      "publish.status.published": "Published",
      "publish.changelog": "Changelog",
      "publish.changelog.placeholder": "What changed in this version?",
      "publish.force": "Publish a new version (already published)",
      "btn.publish": "Publish to marketplace",
      "btn.publishing": "Publishing…",
      "btn.pack": "Pack (.zip)",
      "btn.packing": "Packing…",
      "publish.needLicense": "Publishing requires an activated user license.",
      "publish.done": "Published {{id}} {{ver}} — {{status}}",
      "publish.already": "Already published. Enable \"publish a new version\" to ship.",
      "published.title": "Your published extensions",
      "published.empty": "You haven't published anything yet.",
      "btn.unpublish": "Unpublish",
      "published.confirm": "Unpublish {{id}} from the marketplace?",
      "err.generic": "Something went wrong: {{msg}}",
      "err.version_conflict": "Version {{ver}} has already been published. Please enter a higher version number above and try again.",
      "err.invalid_version": "Invalid version. Use format like 1.0.0.",
      "pub.version.label": "Version",

      "publish.confirm.title": "Publish to the marketplace?",
      "publish.confirm.body": "\"{{id}}\" will be packed and uploaded to the extension marketplace, where anyone can discover and install it. Make sure it's ready to share publicly.",
      "publish.confirm.ok": "Publish",
      "publish.confirm.cancel": "Cancel",
      "bind.title": "Authorize this device",
      "bind.body": "Publishing requires a platform account. We'll open the OpenClacky authorization page — approve there, and this device will be linked to your account.",
      "bind.starting": "Opening authorization page…",
      "bind.pending": "Waiting for you to approve in the browser…",
      "bind.code": "Verification code: {{code}}",
      "bind.openLink": "Open authorization page",
      "bind.success": "Device authorized. Publishing now…",
      "bind.failed": "Authorization failed: {{msg}}",
      "bind.denied": "Authorization was denied.",
      "bind.expired": "Authorization expired. Please try again.",
      "bind.cancel": "Cancel",

      "pub.title.new": "Publish to the marketplace",
      "pub.title.update": "Publish a new version",
      "pub.intro": "\"{{name}}\" will be packed and uploaded to the extension marketplace, where anyone can discover and install it.",
      "pub.version.new": "First release · v{{ver}}",
      "pub.version.update": "v{{prev}} → v{{ver}}",
      "pub.version.missing": "No version in ext.yml — add a \"version\" field before publishing.",
      "pub.units": "Includes: {{units}}",
      "pub.notes.label": "Release notes (optional)",
      "pub.notes.placeholder": "What changed in this version? (README.md / CHANGELOG.md ship inside the package)",
      "pub.readme.ok": "README.md detected",
      "pub.readme.missing": "No README.md — consider adding one so users understand your extension.",
      "pub.btn.publish": "Publish v{{ver}}",
      "pub.btn.publishing": "Publishing…",
      "pub.btn.done": "Done",
      "pub.btn.cancel": "Cancel",
      "pub.progress.packing": "Packing…",
      "pub.progress.uploading": "Uploading to marketplace…",
      "pub.done": "Published {{id}} v{{ver}} — {{status}}",
      "pub.success": "Published successfully",
      "pub.done.close": "Done",
      "pub.retry": "Try again",
      "extlist.section.cloud": "Published Extensions",
      "extlist.section.cloudHint": "Live on the marketplace",
      "extlist.section.local": "Local Extensions",
      "extlist.section.localHint": "Ready to publish",
      "extlist.cloud.empty": "No extensions published yet.",
      "extlist.local.empty": "No local extensions. Create one below.",
      "extlist.badge.published": "Published",
      "extlist.badge.draft": "Draft",
      "extlist.badge.local": "Not published",
      "extlist.verify.ok": "Checks passed",
      "extlist.verify.errors": "{{n}} error(s)",
      "extlist.verify.warnings": "{{n}} warning(s)",
      "extlist.btn.publish": "Publish to Marketplace",
      "extlist.btn.update": "Update",
      "extlist.btn.pack": "Pack (.zip)",
      "extlist.btn.packing": "Packing…",
      "extlist.btn.unpublish": "Unpublish",
      "extlist.btn.iterate": "Iterate",
      "extlist.btn.delete": "Delete",
      "extlist.delete.confirm": "Delete local extension \"{{id}}\"? This cannot be undone.",
      "extlist.iterate.seed": "Iterate on extension {{id}}",
      "extlist.changelog.prompt": "Changelog (optional):",
      "extlist.overwrite.confirm": "\"{{id}}\" is already published. Publish a new version?",
      "extlist.unpublish.confirm": "Unpublish {{id}} from the marketplace?",
      "extlist.publishing": "Publishing…",
      "extlist.needLicense": "Publishing requires an activated user license.",
      "extlist.newExt.label": "Create a new extension",
      "extlist.newExt.hint": "Opens an AI session that scaffolds and builds it for you.",
      "extlist.newExt.btn": "Create New Extension",
      "extlist.newExt.seed": "I want to build a new OpenClacky extension. Help me get started: ask me what the extension should do, then scaffold it and build it out step by step.",
      "unit.panel": "panel",
      "unit.panels": "panels",
      "unit.agent": "agent",
      "unit.agents": "agents",
      "unit.api": "API",
      "unit.apis": "APIs",
      "unit.skill": "skill",
      "unit.skills": "skills",

      "meta.section": "Extension Info",
      "meta.edit.title": "Edit Extension Info",
      "meta.edit": "Edit",
      "meta.name.label": "Display name",
      "meta.desc.label": "Description",
      "meta.save": "Save",
      "meta.saving": "Saving…",
      "meta.saved": "Saved",
      "meta.save.err": "Save failed: {{msg}}",

      "entry.warn.title": "Access entry point not configured",
      "entry.warn.body": "This extension has UI panels but no entry point is set. Users won't know how to open it after installing.",
      "entry.warn.setup": "Set up entry point",
      "entry.warn.skip": "Ignore and continue",
      "entry.hint": "Choose where users can open this extension after installing it.",
      "entry.none": "This extension has no UI panels — no entry points needed.",
      "entry.unset": "Not configured — click Edit to set up.",
      "entry.slot.label": "Slot",
      "entry.kind.panel": "Panel",
      "entry.add": "Add entry point",
      "entry.remove": "Remove",

      "slot.sidebar.nav": "Sidebar nav",
      "slot.sidebar.nav.top": "Sidebar nav (top)",
      "slot.sidebar.nav.bottom": "Sidebar nav (bottom)",
      "slot.sidebar.footer": "Sidebar footer",
      "slot.main.workspace": "Main workspace",
      "slot.session.aside": "Session aside",
      "slot.settings.tabs": "Settings tab",
      "skills.section.cloud": "Cloud Skills",
      "skills.section.cloudHint": "Published to the platform",
      "skills.section.local": "Local Skills",
      "skills.section.localHint": "Ready to publish",
      "skills.cloud.empty": "No skills published yet.",
      "skills.cloud.locked": "Become a creator to upload and publish skills.",
      "skills.local.empty": "All local skills are already published.",
      "skills.badge.published": "Published",
      "skills.badge.unpublished": "Not published",
      "skills.changed": "Has local changes",
      "skills.hasLocalChanges": "Local SKILL.md is newer than the last upload",
      "skills.downloads": "Downloads",
      "skills.btn.publish": "Publish",
      "skills.btn.update": "Update",
      "skills.btn.upToDate": "Up to date",
      "skills.btn.iterate": "Iterate",
      "skills.iterate.prompt": "Update skill:",
      "skills.shadow.label": "Local override",
      "skills.shadow.tooltip": "Local copy shadows a same-named brand skill",
      "skills.newSkill.label": "Create a new skill with /skill-creator",
      "skills.newSkill.btn": "Create New Skill",
      "skills.promo.text": "Publish your skills & build your own brand.",
      "skills.promo.link": "Learn more →",
      "skills.locked": "Creator license required to publish cloud skills.",
      "skills.publishing": "Publishing…",
    },
    zh: {
      "nav.entry": "扩展与创作",
      "ws.title": "扩展与创作",
      "tab.extensions": "扩展",
      "tab.skills": "创作",
      "ext.debug.section": "调试",
      "ext.publish.section": "发布",
      "debug.tab": "调试",
      "publish.tab": "发布",
      "picker.label": "扩展包",
      "picker.empty": "本地暂无扩展。让 AI 帮你生成一个。",
      "detail.version": "版本",
      "detail.layer": "层级",
      "detail.origin": "来源",
      "detail.units": "贡献单元",
      "detail.noUnits": "暂无单元",
      "btn.recheck": "重新检查",
      "btn.checking": "检查中…",
      "verify.ok": "全部检查通过。",
      "verify.errors": "{{n}} 个错误",
      "verify.warnings": "{{n}} 个警告",
      "verify.hint": "提示",
      "hint.reload": "修复问题后，刷新页面即可生效。",
      "publish.status": "状态",
      "publish.status.draft": "草稿",
      "publish.status.published": "已发布",
      "publish.changelog": "更新说明",
      "publish.changelog.placeholder": "这个版本改了什么？",
      "publish.force": "发布新版本（已发布过）",
      "btn.publish": "发布到市场",
      "btn.publishing": "发布中…",
      "btn.pack": "打包 (.zip)",
      "btn.packing": "打包中…",
      "publish.needLicense": "发布需要已激活的用户授权。",
      "publish.done": "已发布 {{id}} {{ver}} — {{status}}",
      "publish.already": "已发布过。勾选「发布新版本」后再试。",
      "published.title": "你发布的扩展",
      "published.empty": "你还没有发布任何扩展。",
      "btn.unpublish": "下架",
      "published.confirm": "确定要从市场下架 {{id}} 吗？",
      "err.generic": "出错了：{{msg}}",
      "err.version_conflict": "版本 {{ver}} 已发布过，请在上方输入更高的版本号后重试。",
      "err.invalid_version": "版本号格式不对，请使用如 1.0.0 的格式。",
      "pub.version.label": "版本号",

      "publish.confirm.title": "确定发布到市场？",
      "publish.confirm.body": "「{{id}}」将被打包并上传到扩展市场，任何人都能发现并安装它。请确认它已准备好公开分享。",
      "publish.confirm.ok": "发布",
      "publish.confirm.cancel": "取消",
      "bind.title": "授权此设备",
      "bind.body": "发布需要平台账号。我们将打开 OpenClacky 授权页面——在那里确认后，此设备就会关联到你的账号。",
      "bind.starting": "正在打开授权页面…",
      "bind.pending": "等待你在浏览器中确认授权…",
      "bind.code": "验证码：{{code}}",
      "bind.openLink": "打开授权页面",
      "bind.success": "设备已授权，正在发布…",
      "bind.failed": "授权失败：{{msg}}",
      "bind.denied": "授权被拒绝。",
      "bind.expired": "授权已过期，请重试。",
      "bind.cancel": "取消",

      "pub.title.new": "发布到市场",
      "pub.title.update": "发布新版本",
      "pub.intro": "「{{name}}」将被打包并上传到扩展市场，任何人都能发现并安装它。",
      "pub.version.new": "首次发布 · v{{ver}}",
      "pub.version.update": "v{{prev}} → v{{ver}}",
      "pub.version.missing": "ext.yml 里没有 version — 请先补上 version 字段再发布。",
      "pub.units": "包含：{{units}}",
      "pub.notes.label": "更新说明（可选）",
      "pub.notes.placeholder": "这个版本改了什么？（README.md / CHANGELOG.md 会随包一起发布）",
      "pub.readme.ok": "已检测到 README.md",
      "pub.readme.missing": "未找到 README.md — 建议补一份，方便用户了解你的扩展。",
      "pub.btn.publish": "发布 v{{ver}}",
      "pub.btn.publishing": "发布中…",
      "pub.btn.done": "完成",
      "pub.btn.cancel": "取消",
      "pub.progress.packing": "打包中…",
      "pub.progress.uploading": "上传到市场…",
      "pub.done": "已发布 {{id}} v{{ver}} — {{status}}",
      "pub.success": "已发布成功",
      "pub.done.close": "完成",
      "pub.retry": "重试",
      "extlist.section.cloud": "已发布扩展",
      "extlist.section.cloudHint": "已上架到市场",
      "extlist.section.local": "本地扩展",
      "extlist.section.localHint": "可发布",
      "extlist.cloud.empty": "还没有发布任何扩展。",
      "extlist.local.empty": "本地暂无扩展，在下方新建一个。",
      "extlist.badge.published": "已发布",
      "extlist.badge.draft": "草稿",
      "extlist.badge.local": "未发布",
      "extlist.verify.ok": "检查通过",
      "extlist.verify.errors": "{{n}} 个错误",
      "extlist.verify.warnings": "{{n}} 个警告",
      "extlist.btn.publish": "发布到市场",
      "extlist.btn.update": "更新到市场",
      "extlist.btn.pack": "打包(.zip)",
      "extlist.btn.packing": "打包中…",
      "extlist.btn.unpublish": "下架",
      "extlist.btn.iterate": "迭代",
      "extlist.btn.delete": "删除",
      "extlist.delete.confirm": "确定要删除本地扩展「{{id}}」吗？此操作不可恢复。",
      "extlist.iterate.seed": "迭代扩展 {{id}}",
      "extlist.changelog.prompt": "更新说明（可选）：",
      "extlist.overwrite.confirm": "「{{id}}」已经发布过了。要发布新版本吗？",
      "extlist.unpublish.confirm": "确定要从市场下架 {{id}} 吗？",
      "extlist.publishing": "发布中…",
      "extlist.needLicense": "发布需要已激活的用户授权。",
      "extlist.newExt.label": "新建扩展",
      "extlist.newExt.hint": "打开一个 AI 会话，帮你生成并开发它。",
      "extlist.newExt.btn": "新建扩展",
      "extlist.newExt.seed": "我想开发一个新的 OpenClacky 扩展。请引导我开始：先问清楚这个扩展要做什么，然后帮我搭好骨架并一步步开发出来。",
      "unit.panel": "个面板",
      "unit.panels": "个面板",
      "unit.agent": "个 Agent",
      "unit.agents": "个 Agent",
      "unit.api": "个 API",
      "unit.apis": "个 API",
      "unit.skill": "个技能",
      "unit.skills": "个技能",

      "meta.section": "扩展信息",
      "meta.edit.title": "编辑扩展信息",
      "meta.edit": "编辑",
      "meta.name.label": "显示名称",
      "meta.desc.label": "描述",
      "meta.save": "保存",
      "meta.saving": "保存中…",
      "meta.saved": "已保存",
      "meta.save.err": "保存失败：{{msg}}",

      "entry.section": "访问入口",
      "entry.warn.title": "未配置访问入口",
      "entry.warn.body": "该扩展包含 UI 面板，但尚未设置访问入口。安装后用户可能不知道如何打开它。",
      "entry.warn.setup": "去设置",
      "entry.warn.skip": "忽略，继续发布",
      "entry.hint": "选择用户安装扩展后可以从哪里打开它。",
      "entry.none": "该扩展没有 UI 面板，无需配置访问入口。",
      "entry.unset": "尚未配置 — 点击编辑设置。",
      "entry.slot.label": "挂载位置",
      "entry.kind.panel": "面板",
      "entry.add": "添加入口",
      "entry.remove": "删除",

      "slot.sidebar.nav": "侧边栏导航",
      "slot.sidebar.nav.top": "侧边栏导航（顶部）",
      "slot.sidebar.nav.bottom": "侧边栏导航（底部）",
      "slot.sidebar.footer": "侧边栏底部",
      "slot.main.workspace": "主工作区",
      "slot.session.aside": "会话侧栏",
      "slot.settings.tabs": "设置页标签",
      "skills.section.cloud": "云端 Skills",
      "skills.section.cloudHint": "已发布到平台",
      "skills.section.local": "本地 Skills",
      "skills.section.localHint": "可发布",
      "skills.cloud.empty": "还没有发布任何 skill。",
      "skills.cloud.locked": "成为创作者后才能上传并发布 skill。",
      "skills.local.empty": "所有本地 skill 都已发布。",
      "skills.badge.published": "已发布",
      "skills.badge.unpublished": "未发布",
      "skills.changed": "有本地改动",
      "skills.hasLocalChanges": "本地 SKILL.md 比上次上传更新",
      "skills.downloads": "下载量",
      "skills.btn.publish": "发布",
      "skills.btn.update": "更新",
      "skills.btn.upToDate": "已是最新",
      "skills.btn.iterate": "迭代",
      "skills.iterate.prompt": "更新 skill：",
      "skills.shadow.label": "本地覆盖",
      "skills.shadow.tooltip": "本地副本覆盖了同名品牌 skill",
      "skills.newSkill.label": "用 /skill-creator 创建新 skill",
      "skills.newSkill.btn": "创建新 Skill",
      "skills.promo.text": "发布你的 skill，打造自己的品牌。",
      "skills.promo.link": "了解更多 →",
      "skills.locked": "发布云端 skill 需要创作者授权。",
      "skills.publishing": "发布中…",
    },
  };

  function t(key, vars) {
    const lang = (typeof I18n !== "undefined" && I18n.lang && I18n.lang()) || "en";
    const dict = STUDIO_I18N[lang] || STUDIO_I18N.en;
    let str = dict[key] != null ? dict[key] : (STUDIO_I18N.en[key] != null ? STUDIO_I18N.en[key] : key);
    if (vars) Object.keys(vars).forEach((k) => { str = str.split("{{" + k + "}}").join(vars[k]); });
    return str;
  }

  function api(path) { return `/api/ext/ext-studio${path}`; }

  async function getJson(path) {
    const res = await fetch(api(path));
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
    return data;
  }

  async function postJson(path, body) {
    const res = await fetch(api(path), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body || {}),
    });
    const data = await res.json();
    if (!res.ok) {
      const err = new Error(data.error || `Request failed (${res.status})`);
      err.status = res.status;
      err.data = data;
      throw err;
    }
    return data;
  }

  async function downloadPack(ext_id) {
    const res = await fetch(api("/pack"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ext_id }),
    });
    if (!res.ok) {
      let msg = `Request failed (${res.status})`;
      try { msg = (await res.json()).error || msg; } catch (_e) {}
      throw new Error(msg);
    }
    const blob = await res.blob();
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement("a");
    a.href     = url;
    a.download = `${ext_id}.zip`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }

  // Skills tab talks to host-owned endpoints (not the ext prefix). We surface
  // the HTTP status so the caller can treat 403 as "locked" rather than error.
  async function getHost(path) {
    const res = await fetch(path);
    let data = {};
    try { data = await res.json(); } catch (_e) {}
    return { status: res.status, ok: res.ok, data };
  }

  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach((k) => {
      if (k === "class") node.className = attrs[k];
      else if (k === "text") node.textContent = attrs[k];
      else if (k.startsWith("on") && typeof attrs[k] === "function") node.addEventListener(k.slice(2), attrs[k]);
      else node.setAttribute(k, attrs[k]);
    });
    (children || []).forEach((c) => { if (c) node.appendChild(typeof c === "string" ? document.createTextNode(c) : c); });
    return node;
  }

  // ── Shared: modal dialog ───────────────────────────────────────────────
  // A minimal overlay modal used by the publish-confirm and device-binding
  // flows. Returns the body element so callers can drive it live (bind flow),
  // plus a close() handle. Footer buttons wire straight to callbacks.
  function openModal({ title, body, buttons }) {
    const overlay = el("div", { class: "studio-modal-overlay" });
    const box = el("div", { class: "studio-modal" });
    const bodyEl = el("div", { class: "studio-modal-body" });
    if (typeof body === "string") bodyEl.textContent = body; else if (body) bodyEl.appendChild(body);

    const footer = el("div", { class: "studio-modal-footer" });
    const close = () => { if (overlay.parentNode) overlay.parentNode.removeChild(overlay); };
    (buttons || []).forEach((b) => {
      footer.appendChild(el("button", {
        class: "studio-btn" + (b.primary ? " studio-btn-primary" : ""),
        text: b.label,
        onclick: () => { if (!b.keepOpen) close(); if (b.onClick) b.onClick(); },
      }));
    });

    box.appendChild(el("h3", { class: "studio-modal-title", text: title }));
    box.appendChild(bodyEl);
    box.appendChild(footer);
    overlay.appendChild(box);
    document.body.appendChild(overlay);
    return { overlay, bodyEl, footer, close };
  }

  function confirmModal({ title, body, okLabel, cancelLabel }) {
    return new Promise((resolve) => {
      openModal({
        title,
        body,
        buttons: [
          { label: cancelLabel, onClick: () => resolve(false) },
          { label: okLabel, primary: true, onClick: () => resolve(true) },
        ],
      });
    });
  }

  // ── Shared: device-binding flow ────────────────────────────────────────
  // Runs the RFC 8628 device-authorization flow: opens the platform's
  // verification page and polls until approval. Resolves true once this device
  // is bound to a platform account, false on cancel/denial/expiry.
  function runBindingFlow() {
    return new Promise((resolve) => {
      let polling = false;
      let popup = null;

      const status = el("p", { class: "studio-modal-status", text: t("bind.body") });
      const codeLine = el("p", { class: "studio-modal-code" });
      const link = el("a", { class: "studio-modal-link", target: "_blank", rel: "noopener", text: t("bind.openLink") });
      link.style.display = "none";

      const modal = openModal({
        title: t("bind.title"),
        body: el("div", null, [status, codeLine, link]),
        buttons: [{ label: t("bind.cancel"), keepOpen: false, onClick: () => { polling = false; resolve(false); } }],
      });

      function finish(ok) { polling = false; modal.close(); resolve(ok); }

      async function poll(deviceCode, intervalMs) {
        while (polling) {
          await new Promise((r) => setTimeout(r, intervalMs));
          if (!polling) return;
          let data;
          try { data = await postJson("/binding/poll", { device_code: deviceCode }); }
          catch (_e) { continue; }
          if (data.status === "approved") { status.textContent = t("bind.success"); setTimeout(() => finish(true), 600); return; }
          if (data.status === "pending") continue;
          const msg = data.status === "denied" ? t("bind.denied")
            : data.status === "expired" ? t("bind.expired")
            : t("bind.failed", { msg: data.error || data.status || "" });
          status.textContent = msg;
          return;
        }
      }

      (async () => {
        status.textContent = t("bind.starting");
        popup = window.open("about:blank", "_blank");
        let data;
        try { data = await postJson("/binding/start", {}); }
        catch (e) {
          if (popup && !popup.closed) popup.close();
          status.textContent = t("bind.failed", { msg: e.message });
          return;
        }
        const url = data.verification_uri_complete || data.verification_uri;
        codeLine.textContent = data.user_code ? t("bind.code", { code: data.user_code }) : "";
        if (url) { link.href = url; link.style.display = ""; }
        status.textContent = t("bind.pending");
        if (popup && !popup.closed) popup.location.href = url; else if (url) window.open(url, "_blank");
        polling = true;
        poll(data.device_code, (data.interval || 5) * 1000);
      })();
    });
  }

  // Publish an extension, transparently running the device-binding flow when the
  // backend reports the device isn't bound yet (HTTP 428), then retrying once.
  // Returns the publish response, or null if the user cancelled binding.
  async function publishWithBinding(body) {
    try {
      return await postJson("/publish", body);
    } catch (e) {
      if (e.status === 428 && e.data && e.data.needs_binding) {
        const bound = await runBindingFlow();
        if (!bound) return null;
        return await postJson("/publish", body);
      }
      throw e;
    }
  }

  function isSemver(v) {
    return /^\d+\.\d+\.\d+$/.test(v);
  }

  // Unified publish flow: one modal that walks the creator from a release form
  // (version + notes) through progress → device binding (if needed) → done.
  // The creator owns the version; if it conflicts with the latest published
  // version they can bump it inline — the modal writes it back to ext.yml
  // before uploading. `prevVersionOrPromise` may be a value or a Promise.
  // Resolves true when a publish succeeded, false otherwise.
  function checkEntryPoints(ext) {
    const hasPanels = (ext.units || []).some((u) => u.kind === "panel");
    const hasEntries = Array.isArray(ext.entry_points) && ext.entry_points.length > 0;
    if (!hasPanels || hasEntries) return Promise.resolve(true);

    return new Promise((resolve) => {
      const overlay = el("div", { class: "studio-modal-overlay" });
      const modal = el("div", { class: "studio-modal", style: "max-width:400px" });
      overlay.appendChild(modal);
      document.body.appendChild(overlay);

      function close(result) { document.body.removeChild(overlay); resolve(result); }

      modal.appendChild(el("h3", { class: "studio-modal-title", text: t("entry.warn.title") }));
      modal.appendChild(el("p", { style: "font-size:13px;color:var(--color-text-secondary);margin:0 0 20px", text: t("entry.warn.body") }));

      const footer = el("div", { class: "studio-modal-footer" });
      const skipBtn = el("button", { class: "studio-btn studio-btn-ghost", text: t("entry.warn.skip") });
      skipBtn.addEventListener("click", () => close(true));
      const setupBtn = el("button", { class: "studio-btn studio-btn-primary", text: t("entry.warn.setup") });
      setupBtn.addEventListener("click", () => { close(false); openMetaEditModal(ext, () => store.reload()); });
      footer.appendChild(skipBtn);
      footer.appendChild(setupBtn);
      modal.appendChild(footer);
    });
  }

  function runPublishFlow(ext, prevVersionOrPromise) {
    return checkEntryPoints(ext).then((proceed) => {
      if (!proceed) return false;
      return new Promise((resolve) => {
      let currentVersion = ext.version || "";
      let isUpdate = false;

      const verField = el("div", { class: "studio-field" });
      verField.appendChild(el("label", { class: "studio-label", text: t("pub.version.label") }));
      const verInput = el("input", { class: "studio-input", type: "text", value: currentVersion, placeholder: "1.0.0" });
      verInput.addEventListener("input", () => {
        currentVersion = verInput.value.trim();
        const valid = isSemver(currentVersion);
        verInput.classList.toggle("studio-input-error", !!currentVersion && !valid);
        publishBtn.disabled = !valid;
        publishBtn.textContent = valid ? t("pub.btn.publish", { ver: currentVersion }) : t("pub.btn.publish", { ver: currentVersion || "?" });
        if (currentVersion && !valid) {
          setProgress(t("err.invalid_version"), true);
        } else {
          status.style.display = "none";
        }
      });
      verField.appendChild(verInput);

      const notesField = el("div", { class: "studio-field" });
      notesField.appendChild(el("label", { class: "studio-label", text: t("pub.notes.label") }));
      const notes = el("textarea", { class: "studio-textarea", rows: "4", placeholder: t("pub.notes.placeholder") });
      notesField.appendChild(notes);

      const status = el("p", { class: "studio-modal-status" });
      status.style.display = "none";

      const bodyChildren = [
        el("p", { class: "studio-modal-intro", text: t("pub.intro", { name: ext.name }) }),
        verField,
        notesField,
        status,
      ];

      let done = false;
      const modal = openModal({
        title: t("pub.title.new"),
        body: el("div", null, bodyChildren),
        buttons: [
          { label: t("pub.btn.cancel"), keepOpen: false, onClick: () => { if (!done) resolve(false); } },
          {
            label: currentVersion ? t("pub.btn.publish", { ver: currentVersion }) : t("pub.btn.publish", { ver: "?" }),
            primary: true,
            keepOpen: true,
            onClick: () => submit(),
          },
        ],
      });

      const publishBtn = modal.footer.querySelector(".studio-btn-primary");
      const cancelBtn = modal.footer.querySelector(".studio-btn:not(.studio-btn-primary)");
      if (!currentVersion) publishBtn.disabled = true;

      Promise.resolve(prevVersionOrPromise).then((prevVersion) => {
        if (done || !prevVersion) return;
        isUpdate = true;
        const titleEl = modal.overlay.querySelector(".studio-modal-title");
        if (titleEl) titleEl.textContent = t("pub.title.update");
        if (prevVersion !== currentVersion) {
          currentVersion = prevVersion;
          verInput.value = currentVersion;
          publishBtn.disabled = false;
          publishBtn.textContent = t("pub.btn.publish", { ver: currentVersion });
        }
      });

      function setProgress(msg, isError) {
        status.style.display = "";
        status.textContent = msg;
        status.className = "studio-modal-status" + (isError ? " studio-modal-status-error" : "");
      }

      function resetButtons() {
        publishBtn.disabled = !currentVersion;
        publishBtn.textContent = currentVersion ? t("pub.btn.publish", { ver: currentVersion }) : t("pub.btn.publish", { ver: "?" });
        cancelBtn.disabled = false;
        notes.disabled = false;
        verInput.disabled = false;
      }

      async function submit() {
        if (done || publishBtn.disabled) return;
        const ver = currentVersion;
        if (!ver) return;
        if (!isSemver(ver)) {
          setProgress(t("err.invalid_version", { ver }), true);
          verInput.classList.add("studio-input-error");
          verInput.focus();
          verInput.select();
          return;
        }

        publishBtn.disabled = true;
        publishBtn.textContent = t("pub.btn.publishing");
        cancelBtn.disabled = true;
        notes.disabled = true;
        verInput.disabled = true;
        status.style.display = "none";

        try {
          if (ver !== ext.version) {
            await postJson("/set_version", { ext_id: ext.id, version: ver });
          }

          const data = await publishWithBinding({
            ext_id: ext.id,
            force: isUpdate,
            changelog: notes.value.trim(),
          });

          if (data === null) { resetButtons(); return; }
          if (!data.ok) throw new Error(data.error || "Publish failed");

          done = true;
          const successLabel = el("span", { class: "studio-pub-success", text: t("pub.success") });
          modal.footer.insertBefore(successLabel, modal.footer.firstChild);
          cancelBtn.style.display = "none";
          publishBtn.disabled = false;
          publishBtn.textContent = t("pub.btn.done");
          publishBtn.onclick = () => { modal.close(); resolve(true); };
        } catch (e) {
          const msg = e.message || "";
          const isConflict = /must be greater than/i.test(msg);
          if (isConflict) {
            setProgress(t("err.version_conflict", { ver }), true);
            verInput.classList.add("studio-input-error");
            verInput.disabled = false;
            verInput.focus();
            verInput.select();
            verInput.addEventListener("input", () => verInput.classList.remove("studio-input-error"), { once: true });
          } else {
            setProgress(t("err.generic", { msg }), true);
          }
          resetButtons();
        }
      }
    });
  }); }

  // Both tabs care about "which local extension am I working on", so we keep a
  // tiny page-level store and let each tab subscribe to changes.
  const store = {
    extensions: [],
    selectedId: null,
    loaded: false,
    listeners: new Set(),
    subscribe(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); },
    notify() { this.listeners.forEach((fn) => fn()); },
    selected() { return this.extensions.find((e) => e.id === this.selectedId) || null; },
    async reload() {
      const data = await getJson("/extensions");
      this.extensions = data.extensions || [];
      this.loaded = true;
      if (!this.selectedId || !this.extensions.some((e) => e.id === this.selectedId)) {
        this.selectedId = this.extensions.length ? this.extensions[0].id : null;
      }
      this.notify();
    },
  };

  function renderPicker(onChange) {
    const wrap = el("div", { class: "studio-field" });
    wrap.appendChild(el("label", { class: "studio-label", text: t("picker.label") }));
    if (!store.extensions.length) {
      wrap.appendChild(el("p", { class: "studio-empty", text: t("picker.empty") }));
      return wrap;
    }
    const select = el("select", { class: "studio-select" });
    store.extensions.forEach((e) => {
      const opt = el("option", { value: e.id, text: `${e.name} (${e.id})` });
      if (e.id === store.selectedId) opt.selected = true;
      select.appendChild(opt);
    });
    select.addEventListener("change", () => { store.selectedId = select.value; store.notify(); if (onChange) onChange(); });
    wrap.appendChild(select);
    return wrap;
  }

  // ── Debug tab ──────────────────────────────────────────────────────────
  function createDebugPanel() {
    let container = null;
    let unsub = null;
    let summaryFadeTimer = null;

    async function runVerify() {
      const ext = store.selected();
      if (!ext) return;
      const status = container.querySelector(".studio-verify-status");
      if (status) status.textContent = t("btn.checking");
      try {
        const data = await postJson("/verify", { ext_id: ext.id });
        renderVerify(data);
      } catch (e) {
        renderError(e);
      } finally {
        if (status) status.textContent = t("btn.recheck");
      }
    }

    function renderVerify(data) {
      const box = container.querySelector(".studio-verify");
      if (!box) return;
      box.innerHTML = "";
      const errs = (data.issues || []).filter((i) => i.level === "error");
      const warns = (data.issues || []).filter((i) => i.level === "warning");

      const summary = container.querySelector(".studio-verify-summary");
      if (summary) {
        clearTimeout(summaryFadeTimer);
        summary.textContent = "";
        if (data.ok && !warns.length) {
          summary.textContent = "✓ " + t("verify.ok");
          summary.className = "studio-verify-summary studio-verify-ok";
          summaryFadeTimer = setTimeout(() => { summary.textContent = ""; }, 3000);
        } else {
          const parts = [];
          if (errs.length) parts.push(t("verify.errors", { n: errs.length }));
          if (warns.length) parts.push(t("verify.warnings", { n: warns.length }));
          summary.textContent = parts.join(" · ");
          summary.className = "studio-verify-summary studio-verify-fail";
        }
      }

      (data.issues || []).forEach((i) => {
        const item = el("div", { class: "studio-issue studio-issue-" + i.level });
        item.appendChild(el("div", { class: "studio-issue-code", text: `${i.code}${i.unit ? " · " + i.unit : ""}` }));
        item.appendChild(el("div", { class: "studio-issue-msg", text: i.message }));
        if (i.file) item.appendChild(el("div", { class: "studio-issue-file", text: i.file }));
        if (i.hint) item.appendChild(el("div", { class: "studio-issue-hint", text: t("verify.hint") + ": " + i.hint }));
        box.appendChild(item);
      });
    }

    function renderError(e) {
      const box = container.querySelector(".studio-verify");
      const summary = container.querySelector(".studio-verify-summary");
      if (summary) { summary.textContent = t("err.generic", { msg: e.message }); summary.className = "studio-verify-summary studio-verify-fail"; }
      if (box) { box.innerHTML = ""; }
    }

    function renderDetail() {
      const ext = store.selected();
      if (!ext) return;
      container.appendChild(buildExtInfoCard(ext, () => openMetaEditModal(ext, () => store.reload().then(rebuild))));
    }

    function rebuild() {
      if (!container) return;
      container.innerHTML = "";
      container.appendChild(renderPicker(() => { rebuild(); runVerify(); }));

      if (!store.selected()) {
        container.appendChild(el("p", { class: "studio-hint", text: t("hint.reload") }));
        return;
      }

      renderDetail();

      const bar = el("div", { class: "studio-actions" });
      bar.appendChild(el("button", { class: "studio-btn studio-btn-primary studio-verify-status", text: t("btn.recheck"), onclick: runVerify }));
      bar.appendChild(el("span", { class: "studio-verify-summary" }));
      container.appendChild(bar);

      container.appendChild(el("div", { class: "studio-verify" }));
      container.appendChild(el("p", { class: "studio-hint", text: t("hint.reload") }));

      runVerify();
    }

    return {
      async attach(root) {
        container = el("div", { class: "studio-panel" });
        root.appendChild(container);
        unsub = store.subscribe(rebuild);
        container.appendChild(el("p", { class: "studio-hint", text: "…" }));
        try { if (!store.loaded) await store.reload(); rebuild(); }
        catch (e) { renderError(e); }
      },
      destroy() { if (unsub) unsub(); },
    };
  }

  // ── Publish tab ──────────────────────────────────────────────────────────

  const PANEL_SLOTS = [
    { value: "sidebar.nav",        labelKey: "slot.sidebar.nav" },
    { value: "sidebar.nav.top",    labelKey: "slot.sidebar.nav.top" },
    { value: "sidebar.nav.bottom", labelKey: "slot.sidebar.nav.bottom" },
    { value: "sidebar.footer",     labelKey: "slot.sidebar.footer" },
    { value: "main.workspace",     labelKey: "slot.main.workspace" },
    { value: "session.aside",      labelKey: "slot.session.aside" },
    { value: "settings.tabs",      labelKey: "slot.settings.tabs" },
  ];

  function buildExtInfoCard(ext, onEdit) {
    const card = el("div", { class: "studio-detail" });

    const head = el("div", { class: "studio-detail-head" });
    head.appendChild(el("h4", { class: "studio-detail-name", text: ext.name || ext.id }));
    const editBtn = el("button", { class: "studio-btn studio-btn-ghost studio-btn-sm", text: t("meta.edit") });
    editBtn.addEventListener("click", onEdit);
    head.appendChild(editBtn);
    card.appendChild(head);

    if (ext.description) card.appendChild(el("p", { class: "studio-detail-desc", text: ext.description }));

    const infoRow = el("div", { class: "studio-info-row" });
    infoRow.appendChild(el("span", { class: "studio-info-label", text: t("detail.version") }));
    infoRow.appendChild(el("span", { class: "studio-info-value", text: ext.version || "—" }));
    card.appendChild(infoRow);

    const panelUnits = (ext.units || []).filter((u) => u.kind === "panel");
    if (panelUnits.length) {
      card.appendChild(el("div", { class: "studio-label studio-section-label", text: t("entry.section") }));
      const eps = Array.isArray(ext.entry_points) && ext.entry_points.length ? ext.entry_points : null;
      if (eps) {
        const chips = el("div", { class: "studio-units" });
        eps.forEach((ep) => {
          const slotDef = PANEL_SLOTS.find((s) => s.value === ep.slot);
          const label = slotDef ? t(slotDef.labelKey) : (ep.slot || ep.kind);
          chips.appendChild(el("span", { class: "studio-unit-chip", text: label }));
        });
        card.appendChild(chips);
      } else {
        card.appendChild(el("p", { class: "studio-empty", text: t("entry.unset") }));
      }
    }

    card.appendChild(el("div", { class: "studio-label studio-section-label", text: t("detail.units") }));
    if (!(ext.units || []).length) {
      card.appendChild(el("p", { class: "studio-empty", text: t("detail.noUnits") }));
    } else {
      const list = el("div", { class: "studio-units" });
      ext.units.forEach((u) => list.appendChild(el("span", { class: "studio-unit-chip", text: u.kind })));
      card.appendChild(list);
    }

    return card;
  }

  function openMetaEditModal(ext, onSaved) {
    let entries = Array.isArray(ext.entry_points) ? ext.entry_points.map((ep) => ({ ...ep })) : [];
    const panelUnits = (ext.units || []).filter((u) => u.kind === "panel");

    const overlay = el("div", { class: "studio-modal-overlay" });
    overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });

    const modal = el("div", { class: "studio-modal" });
    overlay.appendChild(modal);
    document.body.appendChild(overlay);

    function close() { document.body.removeChild(overlay); }

    modal.appendChild(el("h3", { class: "studio-modal-title", text: t("meta.edit.title") }));

    const nameField = el("div", { class: "studio-field" });
    nameField.appendChild(el("label", { class: "studio-label", text: t("meta.name.label") }));
    const nameInput = el("input", { class: "studio-input", value: ext.name || "" });
    nameField.appendChild(nameInput);
    modal.appendChild(nameField);

    const descField = el("div", { class: "studio-field" });
    descField.appendChild(el("label", { class: "studio-label", text: t("meta.desc.label") }));
    const descInput = el("textarea", { class: "studio-textarea", rows: "5", text: ext.description || "" });
    descField.appendChild(descInput);
    modal.appendChild(descField);

    if (panelUnits.length) {
      const entryField = el("div", { class: "studio-field" });
      entryField.appendChild(el("label", { class: "studio-label", text: t("entry.section") }));
      entryField.appendChild(el("p", { class: "studio-hint", style: "margin:0 0 8px", text: t("entry.hint") }));

      const listEl = el("div", { class: "studio-entry-list" });

      function renderEntryList() {
        listEl.innerHTML = "";
        entries.forEach((ep, idx) => {
          const row = el("div", { class: "studio-entry-row" });

          const slotSel = el("select", { class: "studio-select" });
          PANEL_SLOTS.forEach(({ value, labelKey }) => {
            const opt = el("option", { value, text: t(labelKey) });
            if (ep.slot === value) opt.selected = true;
            slotSel.appendChild(opt);
          });
          if (!ep.slot) entries[idx].slot = PANEL_SLOTS[0].value;
          slotSel.addEventListener("change", () => { entries[idx].slot = slotSel.value; });

          const removeBtn = el("button", { class: "studio-btn studio-btn-ghost studio-btn-sm", text: "✕" });
          removeBtn.title = t("entry.remove");
          removeBtn.addEventListener("click", () => { entries.splice(idx, 1); renderEntryList(); });

          row.appendChild(slotSel);
          row.appendChild(removeBtn);
          listEl.appendChild(row);
        });

        const addBtn = el("button", { class: "studio-btn studio-btn-ghost studio-btn-sm", text: `+ ${t("entry.add")}` });
        addBtn.addEventListener("click", () => {
          const du = panelUnits[0];
          entries.push({ panel_id: du ? du.id : "", slot: PANEL_SLOTS[0].value });
          renderEntryList();
        });
        listEl.appendChild(addBtn);
      }

      renderEntryList();
      entryField.appendChild(listEl);
      modal.appendChild(entryField);
    }

    const statusEl = el("span", { class: "studio-form-status" });
    const footer = el("div", { class: "studio-modal-footer" });
    const cancelBtn = el("button", { class: "studio-btn studio-btn-ghost", text: t("pub.btn.cancel"), onclick: close });
    const saveBtn = el("button", { class: "studio-btn studio-btn-primary", text: t("meta.save") });

    saveBtn.addEventListener("click", async () => {
      saveBtn.disabled = true;
      saveBtn.textContent = t("meta.saving");
      statusEl.textContent = "";
      try {
        const payload = entries.map((ep) => ({ unit_id: ep.panel_id, slot: ep.slot }));
        await postJson("/set_meta", {
          ext_id: ext.id,
          name: nameInput.value.trim(),
          description: descInput.value.trim(),
          entry_points: payload,
        });
        close();
        if (onSaved) onSaved();
      } catch (e) {
        saveBtn.disabled = false;
        saveBtn.textContent = t("meta.save");
        statusEl.textContent = t("meta.save.err", { msg: e.message });
      }
    });

    footer.appendChild(statusEl);
    footer.appendChild(cancelBtn);
    footer.appendChild(saveBtn);
    modal.appendChild(footer);
  }

  function createPublishPanel() {
    let container = null;
    let unsub = null;

    function feedback(msg, kind) {
      const box = container.querySelector(".studio-feedback");
      if (box) { box.className = "studio-feedback studio-feedback-" + (kind || "info"); box.textContent = msg; }
    }

    async function doPublish() {
      const ext = store.selected();
      if (!ext) return;
      const prevVersionPromise = getJson("/published")
        .then((data) => {
          const match = (data.extensions || []).find((e) => e.id === ext.id);
          return match ? match.version : null;
        })
        .catch(() => null);
      const ok = await runPublishFlow(ext, prevVersionPromise);
      if (ok) loadPublished();
    }

    async function doPack() {
      const ext = store.selected();
      if (!ext) return;
      const btn = container.querySelector(".studio-pack-btn");
      const orig = btn ? btn.textContent : null;
      if (btn) { btn.disabled = true; btn.textContent = t("btn.packing"); }
      try {
        await downloadPack(ext.id);
      } catch (e) {
        feedback(t("err.generic", { msg: e.message }), "error");
      } finally {
        if (btn) { btn.disabled = false; btn.textContent = orig; }
      }
    }

    async function loadPublished() {
      const box = container.querySelector(".studio-published");
      if (!box) return;
      box.innerHTML = "";
      box.appendChild(el("div", { class: "studio-label", text: t("published.title") }));
      try {
        const data = await getJson("/published");
        const exts = data.extensions || [];
        if (!exts.length) { box.appendChild(el("p", { class: "studio-empty", text: t("published.empty") })); return; }
        exts.forEach((e) => {
          const card = el("div", { class: "studio-skill-card" });
          const head = el("div", { class: "studio-skill-head" });
          head.appendChild(el("span", { class: "studio-skill-name", text: e.name || e.id }));
          const statusKind = e.status === "draft" ? "local" : "published";
          head.appendChild(el("span", { class: `studio-skill-badge studio-skill-badge-${statusKind}`, text: e.status === "draft" ? t("extlist.badge.draft") : t("extlist.badge.published") }));
          if (e.version) head.appendChild(el("span", { style: "font-size:11px;color:var(--color-text-muted);", text: "v" + e.version }));
          const unpubBtn = el("button", { class: "studio-btn studio-btn-danger studio-btn-sm", text: t("btn.unpublish") });
          unpubBtn.style.marginLeft = "auto";
          unpubBtn.addEventListener("click", async () => {
            if (!window.confirm(t("published.confirm", { id: e.id }))) return;
            unpubBtn.disabled = true;
            try { await postJson("/unpublish", { ext_id: e.id }); loadPublished(); }
            catch (err) { unpubBtn.disabled = false; feedback(t("err.generic", { msg: err.message }), "error"); }
          });
          head.appendChild(unpubBtn);
          card.appendChild(head);
          box.appendChild(card);
        });
      } catch (e) {
        box.appendChild(el("p", { class: "studio-empty", text: t("err.generic", { msg: e.message }) }));
      }
    }

    function rebuild() {
      if (!container) return;
      container.innerHTML = "";
      container.appendChild(renderPicker(rebuild));

      const ext = store.selected();
      if (!ext) return;

      container.appendChild(buildExtInfoCard(ext, () => openMetaEditModal(ext, () => store.reload().then(rebuild))));

      const bar = el("div", { class: "studio-actions" });
      bar.appendChild(el("button", { class: "studio-btn studio-btn-primary studio-publish-btn", text: t("btn.publish"), onclick: doPublish }));
      bar.appendChild(el("button", { class: "studio-btn studio-btn-ghost studio-pack-btn", text: t("btn.pack"), onclick: doPack }));
      container.appendChild(bar);

      container.appendChild(el("div", { class: "studio-feedback" }));
      container.appendChild(el("div", { class: "studio-published" }));

      loadPublished();
    }

    return {
      async attach(root) {
        container = el("div", { class: "studio-panel" });
        root.appendChild(container);
        unsub = store.subscribe(rebuild);
        try { if (!store.loaded) await store.reload(); rebuild(); }
        catch (e) { container.appendChild(el("p", { class: "studio-empty", text: t("err.generic", { msg: e.message }) })); }
      },
      destroy() { if (unsub) unsub(); },
    };
  }

  function _skeletonHtml() {
    return Array.from({ length: 3 }).map(() => `
      <div class="studio-skill-card" style="pointer-events:none">
        <div class="studio-skill-head">
          <span class="skel" style="display:inline-block;height:1rem;width:40%"></span>
          <span class="skel" style="display:inline-block;height:1.2rem;width:3.5rem;border-radius:4px;"></span>
        </div>
        <div class="studio-skill-meta" style="margin-top:6px">
          <span class="skel" style="display:inline-block;height:0.85rem;width:20%"></span>
        </div>
        <div class="studio-actions">
          <span class="skel" style="display:inline-block;height:1.75rem;width:5rem;border-radius:6px;"></span>
          <span class="skel" style="display:inline-block;height:1.75rem;width:4rem;border-radius:6px;"></span>
        </div>
      </div>`).join("");
  }

  // ── Extensions tab (full-page): cloud + local extension cards ──────────────
  // Reuses backend endpoints GET /published (cloud), the shared `store` (local,
  // GET /extensions), POST /publish|/pack|/unpublish, and POST /develop to open
  // an AI build session. Mirrors the Skills tab layout.
  function createExtensionsPanel() {
    let container = null;
    let cloud = [];

    function licensed() {
      return !(typeof Brand !== "undefined" && Brand.branded && !Brand.userLicensed);
    }

    async function reload() {
      await store.reload();
      try {
        const data = await getJson("/published");
        cloud = data.extensions || [];
      } catch (_e) {
        cloud = [];
      }
    }

    function createExtension(idea) {
      if (idea === null) return;  // user cancelled the prompt
      const prompt = idea.trim() ? idea.trim() : null;
      postJson("/develop", { idea: prompt })
        .then((data) => { if (data && data.session_id) window.Clacky.Router.navigate("session", { id: data.session_id }); })
        .catch((e) => alert(t("err.generic", { msg: e.message })));
    }

    function badge(text, kind) {
      return el("span", { class: "studio-skill-badge studio-skill-badge-" + kind, text });
    }

    function formatUnitCounts(counts) {
      if (!counts || typeof counts !== "object") return "";
      return Object.keys(counts).map((kind) => {
        const n = parseInt(counts[kind], 10);
        if (!n) return null;
        return `${n} ${t("unit." + kind + (n > 1 ? "s" : ""))}`;
      }).filter(Boolean).join(" · ");
    }

    function cloudCard(ext) {
      const card = el("div", { class: "studio-skill-card" });
      const head = el("div", { class: "studio-skill-head" });
      head.appendChild(el("span", { class: "studio-skill-name", text: ext.name || ext.id }));
      const isDraft = ext.status === "draft";
      head.appendChild(badge(isDraft ? t("extlist.badge.draft") : t("extlist.badge.published"), isDraft ? "local" : "published"));
      card.appendChild(head);

      const meta = el("div", { class: "studio-skill-meta" });
      if (ext.version) meta.appendChild(el("span", { text: "v" + ext.version }));
      card.appendChild(meta);

      const actions = el("div", { class: "studio-actions" });
      actions.appendChild(el("button", { class: "studio-btn studio-btn-primary", text: t("extlist.btn.iterate"), onclick: () => createExtension(t("extlist.iterate.seed", { id: ext.id })) }));
      const un = el("button", { class: "studio-btn studio-btn-ghost studio-btn-sm", text: t("extlist.btn.unpublish") });
      un.addEventListener("click", async () => {
        if (!window.confirm(t("extlist.unpublish.confirm", { id: ext.id }))) return;
        un.disabled = true;
        try { await postJson("/unpublish", { ext_id: ext.id }); await reload(); rebuild(); }
        catch (e) { un.disabled = false; alert(t("err.generic", { msg: e.message })); }
      });
      actions.appendChild(un);
      card.appendChild(actions);
      return card;
    }

    function localCard(ext) {
      const cloudEntry = cloud.find((c) => c.id === ext.id);
      const published = !!cloudEntry;
      const card = el("div", { class: "studio-skill-card" });
      const head = el("div", { class: "studio-skill-head" });
      head.appendChild(el("span", { class: "studio-skill-name", text: `${ext.name} (${ext.id})` }));
      head.appendChild(badge(published ? t("extlist.badge.published") : t("extlist.badge.local"), published ? "published" : "local"));
      if (ext.error_count) head.appendChild(badge("✕ " + t("extlist.verify.errors", { n: ext.error_count }), "changed"));
      else if (ext.warning_count) head.appendChild(badge("● " + t("extlist.verify.warnings", { n: ext.warning_count }), "changed"));
      else head.appendChild(badge("✓ " + t("extlist.verify.ok"), "published"));
      card.appendChild(head);
      if (ext.description) card.appendChild(el("p", { class: "studio-skill-desc", text: ext.description }));

      const meta = el("div", { class: "studio-skill-meta" });
      if (ext.version) meta.appendChild(el("span", { text: "v" + ext.version }));
      const unitsText = formatUnitCounts(ext.unit_counts);
      if (unitsText) meta.appendChild(el("span", { text: unitsText }));
      card.appendChild(meta);

      const actions = el("div", { class: "studio-actions" });
      const pub = el("button", { class: "studio-btn studio-btn-primary", text: published ? t("extlist.btn.update") : t("extlist.btn.publish") });
      pub.disabled = !!ext.error_count;
      pub.title = ext.error_count ? t("extlist.verify.errors", { n: ext.error_count }) : "";
      pub.addEventListener("click", () => doPublish(ext, cloudEntry ? cloudEntry.version : null));
      actions.appendChild(pub);

      actions.appendChild(el("button", { class: "studio-btn", text: t("extlist.btn.iterate"), onclick: () => createExtension(t("extlist.iterate.seed", { id: ext.id })) }));
      const packBtn = el("button", { class: "studio-btn studio-btn-ghost", text: t("extlist.btn.pack") });
      packBtn.addEventListener("click", () => doPack(ext, packBtn));
      actions.appendChild(packBtn);
      card.appendChild(actions);

      if (!published) {
        const delBtn = el("button", { class: "studio-btn studio-btn-danger", text: t("extlist.btn.delete") });
        delBtn.addEventListener("click", () => doDelete(ext, delBtn));
        actions.appendChild(delBtn);
      }
      return card;
    }

    async function doPack(ext, btn) {
      const orig = btn ? btn.textContent : null;
      if (btn) { btn.disabled = true; btn.textContent = t("extlist.btn.packing"); }
      try {
        await downloadPack(ext.id);
      } catch (e) {
        alert(t("err.generic", { msg: e.message }));
      } finally {
        if (btn) { btn.disabled = false; btn.textContent = orig; }
      }
    }

    async function doDelete(ext, btn) {
      if (!confirm(t("extlist.delete.confirm", { id: ext.id }))) return;
      btn.disabled = true;
      try {
        const res = await fetch("/api/ext/ext-studio/local", {
          method: "DELETE",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ ext_id: ext.id }),
        });
        let data = {};
        try { data = await res.json(); } catch (_e) {}
        if (!res.ok) throw new Error(data?.error || `Error ${res.status}`);
        await reload(); rebuild();
      } catch (e) {
        alert(t("err.generic", { msg: e.message }));
        btn.disabled = false;
      }
    }

    async function doPublish(ext, prevVersion) {
      const ok = await runPublishFlow(ext, prevVersion);
      if (ok) { await reload(); rebuild(); }
    }

    function section(titleKey, hintKey, items, cardFn, emptyKey) {
      const box = el("div", { class: "studio-skill-section" });
      const head = el("div", { class: "studio-skill-section-head" });
      head.appendChild(el("span", { class: "studio-label", text: t(titleKey) }));
      head.appendChild(el("span", { class: "studio-skill-hint", text: t(hintKey) }));
      box.appendChild(head);
      if (!items.length) {
        box.appendChild(el("p", { class: "studio-empty", text: t(emptyKey) }));
      } else {
        items.forEach((s) => box.appendChild(cardFn(s)));
      }
      return box;
    }

    function rebuild() {
      if (!container) return;
      container.innerHTML = "";

      const newBox = el("div", { class: "studio-skill-promo" });
      newBox.appendChild(el("p", { class: "studio-skill-promo-text", text: t("extlist.newExt.label") }));
      newBox.appendChild(el("p", { class: "studio-skill-hint", text: t("extlist.newExt.hint") }));
      const newBar = el("div", { class: "studio-actions" });
      newBar.appendChild(el("button", { class: "studio-btn studio-btn-primary", text: t("extlist.newExt.btn"), onclick: () => createExtension(t("extlist.newExt.seed")) }));
      newBox.appendChild(newBar);
      container.appendChild(newBox);

      container.appendChild(section("extlist.section.cloud", "extlist.section.cloudHint", cloud, cloudCard, "extlist.cloud.empty"));
      container.appendChild(section("extlist.section.local", "extlist.section.localHint", store.extensions, localCard, "extlist.local.empty"));
    }

    return {
      async attach(root) {
        container = el("div", { class: "studio-panel" });
        root.appendChild(container);
        container.innerHTML = _skeletonHtml();
        try { await reload(); rebuild(); }
        catch (e) { container.innerHTML = ""; container.appendChild(el("p", { class: "studio-empty", text: t("err.generic", { msg: e.message }) })); }
      },
    };
  }

  // ── Skills tab ────────────────────────────────────────────────────────────
  // Reuses host endpoints: GET /api/creator/skills (403 => locked / not a
  // creator), POST /api/my-skills/:name/publish. "Create / iterate" opens a
  // new session via Sessions.startWith with the /skill-creator command.
  function createSkillsPanel() {
    let container = null;
    let cloud = [];
    let local = [];
    let locked = false;

    async function reload() {
      const r = await getHost("/api/creator/skills");
      if (!r.ok) throw new Error(r.data.error || `Request failed (${r.status})`);
      locked = r.data.licensed === false;
      cloud = r.data.cloud_skills || [];
      local = r.data.local_skills || [];
    }

    async function publish(name, force) {
      const url = `/api/my-skills/${encodeURIComponent(name)}/publish${force ? "?force=true" : ""}`;
      const res = await fetch(url, { method: "POST" });
      let data = {};
      try { data = await res.json(); } catch (_e) {}
      return { ok: res.ok && !!data.ok, already_exists: !!data.already_exists, error: data.error || null };
    }

    function createSkill(skill) {
      const command = skill ? `/skill-creator ${t("skills.iterate.prompt")}${skill}` : "/skill-creator";
      Sessions.startWith(command, { source: "manual" })
        .catch((e) => alert(t("err.generic", { msg: e.message })));
    }

    function badge(text, kind) {
      return el("span", { class: "studio-skill-badge studio-skill-badge-" + kind, text });
    }

    function cloudCard(skill) {
      const card = el("div", { class: "studio-skill-card" });
      const head = el("div", { class: "studio-skill-head" });
      head.appendChild(el("span", { class: "studio-skill-name", text: skill.name }));
      head.appendChild(badge(t("skills.badge.published"), "published"));
      if (skill.has_local_changes) head.appendChild(badge("● " + t("skills.changed"), "changed"));
      card.appendChild(head);
      if (skill.description) card.appendChild(el("p", { class: "studio-skill-desc", text: skill.description }));

      const meta = el("div", { class: "studio-skill-meta" });
      if (skill.version) meta.appendChild(el("span", { text: "v" + skill.version }));
      if (typeof skill.download_count === "number") meta.appendChild(el("span", { text: t("skills.downloads") + ": " + skill.download_count }));
      card.appendChild(meta);

      const actions = el("div", { class: "studio-actions" });
      if (skill.local_present && skill.has_local_changes) {
        const btn = el("button", { class: "studio-btn studio-btn-primary", text: t("skills.btn.update") });
        btn.disabled = locked;
        btn.title = locked ? t("skills.locked") : "";
        btn.addEventListener("click", () => doPublish(skill.name, btn, true));
        actions.appendChild(btn);
      } else if (skill.local_present) {
        const up = el("button", { class: "studio-btn", text: t("skills.btn.upToDate") });
        up.disabled = true;
        actions.appendChild(up);
      }
      if (skill.local_present) {
        actions.appendChild(el("button", { class: "studio-btn", text: t("skills.btn.iterate"), onclick: () => createSkill(skill.name) }));
      }
      card.appendChild(actions);
      return card;
    }

    function localCard(skill) {
      const card = el("div", { class: "studio-skill-card" });
      const head = el("div", { class: "studio-skill-head" });
      head.appendChild(el("span", { class: "studio-skill-name", text: skill.name }));
      head.appendChild(badge(t("skills.badge.unpublished"), "local"));
      if (skill.shadowing_brand) head.appendChild(badge("⚡ " + t("skills.shadow.label"), "shadow"));
      card.appendChild(head);
      if (skill.description) card.appendChild(el("p", { class: "studio-skill-desc", text: skill.description }));

      const actions = el("div", { class: "studio-actions" });
      const btn = el("button", { class: "studio-btn studio-btn-primary", text: t("skills.btn.publish") });
      btn.disabled = locked;
      btn.title = locked ? t("skills.locked") : "";
      btn.addEventListener("click", () => doPublish(skill.name, btn, false));
      actions.appendChild(btn);
      card.appendChild(actions);
      return card;
    }

    async function doPublish(name, btn, isUpdate) {
      if (btn.disabled) return;
      btn.disabled = true;
      const label = btn.textContent;
      btn.textContent = t("skills.publishing");
      try {
        let result = await publish(name, isUpdate);
        if (!result.ok && result.already_exists && !isUpdate) {
          if (window.confirm(`"${name}" already exists on the platform. Overwrite?`)) {
            result = await publish(name, true);
          } else {
            btn.disabled = false;
            btn.textContent = label;
            return;
          }
        }
        if (!result.ok) throw new Error(result.error || "Publish failed");
        btn.textContent = "✓";
        await reload();
        rebuild();
      } catch (e) {
        btn.disabled = false;
        btn.textContent = label;
        alert(t("err.generic", { msg: e.message }));
      }
    }

    function section(titleKey, hintKey, items, cardFn, emptyKey) {
      const box = el("div", { class: "studio-skill-section" });
      const head = el("div", { class: "studio-skill-section-head" });
      head.appendChild(el("span", { class: "studio-label", text: t(titleKey) }));
      head.appendChild(el("span", { class: "studio-skill-hint", text: t(hintKey) }));
      box.appendChild(head);
      if (!items.length) {
        box.appendChild(el("p", { class: "studio-empty", text: t(emptyKey) }));
      } else {
        items.forEach((s) => box.appendChild(cardFn(s)));
      }
      return box;
    }

    function rebuild() {
      if (!container) return;
      container.innerHTML = "";

      if (locked) {
        const promo = el("div", { class: "studio-skill-promo" });
        promo.appendChild(el("p", { class: "studio-skill-promo-text", text: t("skills.promo.text") }));
        promo.appendChild(el("p", { class: "studio-empty", text: t("skills.locked") }));
        container.appendChild(promo);
      }

      const newBox = el("div", { class: "studio-skill-promo" });
      newBox.appendChild(el("p", { class: "studio-skill-promo-text", text: t("skills.newSkill.btn") }));
      newBox.appendChild(el("p", { class: "studio-skill-hint", text: t("skills.newSkill.label") }));
      const newBar = el("div", { class: "studio-actions" });
      newBar.appendChild(el("button", { class: "studio-btn studio-btn-primary", text: t("skills.newSkill.btn"), onclick: () => createSkill(null) }));
      newBox.appendChild(newBar);
      container.appendChild(newBox);

      const cloudEmptyKey = locked ? "skills.cloud.locked" : "skills.cloud.empty";
      container.appendChild(section("skills.section.cloud", "skills.section.cloudHint", cloud, cloudCard, cloudEmptyKey));
      container.appendChild(section("skills.section.local", "skills.section.localHint", local, localCard, "skills.local.empty"));
    }

    return {
      async attach(root) {
        container = el("div", { class: "studio-panel" });
        root.appendChild(container);
        container.innerHTML = _skeletonHtml();
        try { await reload(); rebuild(); }
        catch (e) { container.innerHTML = ""; container.appendChild(el("p", { class: "studio-empty", text: t("err.generic", { msg: e.message }) })); }
      },
    };
  }

  // ── Full-page workspace: top tabs (Extensions / Skills) ────────────────────
  const WS_ID = "ext-studio";

  function renderWorkspace(root) {
    root.innerHTML = "";
    const page = el("div", { class: "studio-page" });
    root.appendChild(page);

    const header = el("div", { class: "studio-page-head" });
    header.appendChild(el("h2", { class: "studio-page-title", text: t("ws.title") }));
    page.appendChild(header);

    const tabsBar = el("div", { class: "studio-tabs" });
    const body = el("div", { class: "studio-tab-body" });
    page.appendChild(tabsBar);
    page.appendChild(body);

    const tabs = [
      { id: "extensions", label: t("tab.extensions"), build: buildExtensionsTab },
      { id: "skills", label: t("tab.skills"), build: buildSkillsTab },
    ];
    let active = null;

    function select(id) {
      active = id;
      Array.from(tabsBar.children).forEach((b) => b.classList.toggle("studio-tab-active", b.dataset.tab === id));
      body.innerHTML = "";
      const tab = tabs.find((t2) => t2.id === id);
      if (tab) tab.build(body);
    }

    tabs.forEach((tab) => {
      const btn = el("button", { class: "studio-tab", text: tab.label });
      btn.dataset.tab = tab.id;
      btn.addEventListener("click", () => select(tab.id));
      tabsBar.appendChild(btn);
    });

    select("extensions");
  }

  function buildExtensionsTab(root) {
    createExtensionsPanel().attach(root);
  }

  function buildSkillsTab(root) {
    createSkillsPanel().attach(root);
  }

  function navRow(labelKey, onClick) {
    const item = el("div", { class: "task-item task-item-summary" });
    item.innerHTML =
      '<div class="task-row">' +
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" ' +
             'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
             'stroke-linejoin="round" class="task-icon">' +
          '<path d="M12 2L2 7l10 5 10-5-10-5z"/>' +
          '<path d="M2 17l10 5 10-5"/>' +
          '<path d="M2 12l10 5 10-5"/>' +
        '</svg>' +
        '<div class="task-info"><span class="task-name"></span></div>' +
      '</div>';
    const nameEl = item.querySelector(".task-name");
    nameEl.textContent = t(labelKey);
    document.addEventListener("langchange", () => { nameEl.textContent = t(labelKey); });
    item.addEventListener("click", onClick);
    return item;
  }

  Clacky.ext.ui.registerWorkspace(WS_ID, {
    title: t("ws.title"),
    render(container) { renderWorkspace(container); },
  });

  Clacky.ext.ui.mount("sidebar.nav.bottom", function () {
    return navRow("nav.entry", function () { Clacky.ext.ui.openWorkspace(WS_ID); });
  }, { workspace: WS_ID });

  // Extension-developer session tools: debug + publish, as aside tabs. These
  // are session-scoped (the panel is bound to the ext-developer profile in
  // ext.yml), so they only appear inside a dev session's aside, not the
  // full-page workspace.
  Clacky.ext.ui.mount("session.aside", {
    render(container) { createDebugPanel().attach(container); },
  }, { tab: { id: "ext-debug", label: () => t("ext.debug.section") }, order: 10 });

  Clacky.ext.ui.mount("session.aside", {
    render(container) { createPublishPanel().attach(container); },
  }, { tab: { id: "ext-publish", label: () => t("ext.publish.section") }, order: 20 });

  const style = document.createElement("style");
  style.textContent = `
    .studio-panel { padding: 16px; font-size: 13px; color: var(--color-text-secondary); }
    .studio-page .studio-panel { padding: 0; }
    .studio-field { margin-bottom: 14px; }
    .studio-label { display: block; font-size: 12px; font-weight: 600; color: var(--color-text-tertiary); margin-bottom: 6px; }
    .studio-field { display: flex; flex-direction: column; gap: 6px; margin-bottom: 16px; }
    .studio-label { font-size: 12px; font-weight: 500; color: var(--color-text-secondary); }
    .studio-select, .studio-textarea { width: 100%; box-sizing: border-box; background: var(--color-bg-input); border: 1px solid var(--color-border-primary); border-radius: var(--radius-sm); padding: 7px 8px; color: var(--color-text-primary); font-size: 13px; font-family: inherit; }
    .studio-select { appearance: none; -webkit-appearance: none; padding-right: 28px; background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath d='M2 4l4 4 4-4' stroke='%23888' stroke-width='1.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E"); background-repeat: no-repeat; background-position: right 8px center; }
    .studio-select:focus, .studio-textarea:focus { border-color: var(--color-accent-primary); outline: none; }
    .studio-empty { color: var(--color-text-muted); font-size: 12px; margin: 4px 0; }
    .studio-hint { color: var(--color-text-tertiary); font-size: 12px; line-height: 1.5; margin: 10px 0 0; }
    .studio-detail { border: 1px solid var(--color-border-primary); border-radius: var(--radius-sm); padding: 12px; margin-bottom: 14px; background: var(--color-bg-secondary); }
    .studio-detail-name { margin: 0; font-size: 14px; color: var(--color-text-primary); }
    .studio-detail-desc { margin: 4px 0 0; font-size: 12px; color: var(--color-text-secondary); line-height: 1.5; }
    .studio-units { display: flex; flex-wrap: wrap; gap: 6px; }
    .studio-unit-chip { display: inline-flex; background: var(--color-bg-hover); color: var(--color-text-primary); border: 1px solid var(--color-border-primary); border-radius: var(--radius-sm); padding: 2px 8px; font-size: 12px; }
    .studio-actions { display: flex; align-items: center; gap: 8px; margin: 12px 0 0; }
    .studio-skill-promo .studio-actions { margin: 12px 0 0; }
    .studio-btn { padding: 7px 14px; border-radius: var(--radius-sm); border: 1px solid var(--color-border-primary); background: transparent; color: var(--color-text-secondary); cursor: pointer; font-size: 13px; font-weight: 500; }
    .studio-btn:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
    .studio-btn-primary { background: var(--color-button-primary); color: var(--color-button-primary-text); border-color: transparent; }
    .studio-btn-primary:hover { background: var(--color-button-primary-hover); color: var(--color-button-primary-text); }
    .studio-btn-primary:disabled { opacity: 0.6; cursor: default; }
    .studio-btn-danger { color: var(--color-error); border-color: var(--color-error-border); }
    .studio-btn-danger:hover { background: var(--color-error-bg); color: var(--color-error); }
    .studio-btn-ghost { color: var(--color-text-secondary); font-weight: 500; }
    .studio-btn-ghost:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
    .studio-verify { margin-top: 8px; }
    .studio-verify-summary { font-size: 13px; font-weight: 600; }
    .studio-verify-ok { color: var(--color-success); font-size: 12px; font-weight: 600; }
    .studio-verify-fail { color: var(--color-error); font-size: 12px; font-weight: 600; }
    .studio-verify > *:first-child { margin-bottom: 8px; }
    .studio-issue { border-left: 3px solid var(--color-border-primary); padding: 6px 10px; margin-bottom: 8px; background: var(--color-bg-secondary); border-radius: 0 var(--radius-sm) var(--radius-sm) 0; }
    .studio-issue-error { border-left-color: var(--color-error); }
    .studio-issue-warning { border-left-color: var(--color-warning, var(--color-text-tertiary)); }
    .studio-issue-code { font-size: 11px; font-family: monospace; color: var(--color-text-tertiary); margin-bottom: 2px; }
    .studio-issue-msg { font-size: 12px; color: var(--color-text-primary); line-height: 1.4; }
    .studio-issue-file { font-size: 11px; font-family: monospace; color: var(--color-text-muted); margin-top: 2px; }
    .studio-issue-hint { font-size: 11px; color: var(--color-text-secondary); margin-top: 4px; font-style: italic; }
    .studio-check { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--color-text-secondary); margin-bottom: 12px; cursor: pointer; }
    .studio-feedback { font-size: 12px; margin: 6px 0 0; line-height: 1.4; }
    .studio-feedback-success { color: var(--color-success); }
    .studio-feedback-error { color: var(--color-error); }
    .studio-feedback-warn { color: var(--color-warning, var(--color-text-secondary)); }
    .studio-published { margin-top: 16px; border-top: 1px solid var(--color-border-primary); padding-top: 12px; }
    .studio-published-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 0; font-size: 12px; border-bottom: 1px solid var(--color-border-primary); }
    .studio-published-name { display: flex; align-items: center; gap: 6px; color: var(--color-text-primary); }
    .studio-page { width: 100%; }
    .studio-page-head { margin-bottom: 20px; }
    .studio-page-title { margin: 0; font-size: 22px; font-weight: 600; color: var(--color-text-primary); }
    .studio-tabs { display: flex; gap: 4px; border-bottom: 1px solid var(--color-border-primary); margin-bottom: 24px; }
    .studio-tab { padding: 8px 16px; border: none; background: transparent; color: var(--color-text-tertiary); cursor: pointer; font-size: 14px; font-weight: 500; border-bottom: 2px solid transparent; margin-bottom: -1px; }
    .studio-tab:hover { color: var(--color-text-primary); }
    .studio-tab-active { color: var(--color-text-primary); border-bottom-color: var(--color-accent-primary); }
    .studio-ext-block { margin-bottom: 20px; }
    .studio-block-title { font-size: 13px; font-weight: 600; color: var(--color-text-secondary); padding: 8px 0 0; }
    .studio-skill-section { margin-bottom: 28px; }
    .studio-skill-section-head { display: flex; align-items: baseline; gap: 10px; margin-bottom: 12px; }
    .studio-skill-hint { font-size: 11px; color: var(--color-text-muted); }
    .studio-skill-card { border: 1px solid var(--color-border-primary); border-radius: var(--radius-md, 8px); padding: 12px; margin: 0 0 10px; background: var(--color-bg-secondary); }
    .studio-skill-head { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; }
    .studio-skill-name { font-size: 14px; font-weight: 600; color: var(--color-text-primary); }
    .studio-skill-badge { font-size: 11px; padding: 1px 8px; border-radius: 10px; }
    .studio-skill-badge-published { background: var(--color-success-bg, var(--color-bg-hover)); color: var(--color-success); }
    .studio-skill-badge-local { background: var(--color-bg-hover); color: var(--color-text-tertiary); }
    .studio-skill-badge-changed { background: var(--color-warning-bg, var(--color-bg-hover)); color: var(--color-warning, var(--color-text-secondary)); }
    .studio-skill-badge-shadow { background: var(--color-bg-hover); color: var(--color-text-secondary); }
    .studio-skill-desc { margin: 6px 0 6px; font-size: 12px; color: var(--color-text-secondary); line-height: 1.5; }
    .studio-skill-meta { display: flex; gap: 12px; font-size: 11px; color: var(--color-text-muted); margin-top: 6px; }
    .studio-skill-promo { border: 1px solid var(--color-border-primary); border-radius: var(--radius-md, 8px); padding: 16px 18px; margin: 0 0 24px; background: var(--color-bg-secondary); }
    .studio-skill-promo-text { margin: 0 0 4px; font-size: 14px; font-weight: 600; color: var(--color-text-primary); }
    .studio-modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; z-index: 9999; animation: studio-overlay-in 0.15s ease; }
    .studio-modal { background: var(--color-bg-primary, var(--color-bg-secondary)); border: 1px solid var(--color-border-primary); border-radius: var(--radius-md, 8px); padding: 28px 28px 22px; width: 520px; max-width: calc(100vw - 40px); box-shadow: 0 12px 40px rgba(0,0,0,0.35); animation: studio-modal-in 0.2s cubic-bezier(0.34,1.4,0.64,1); }
    @keyframes studio-overlay-in { from { opacity: 0; } to { opacity: 1; } }
    @keyframes studio-modal-in { from { opacity: 0; transform: scale(0.93) translateY(6px); } to { opacity: 1; transform: scale(1) translateY(0); } }
    .studio-modal-title { margin: 0 0 16px; font-size: 16px; font-weight: 600; color: var(--color-text-primary); }
    .studio-modal-intro { margin: 0 0 16px; font-size: 13px; color: var(--color-text-secondary); line-height: 1.6; }
    .studio-pub-meta { display: flex; align-items: center; gap: 10px; background: var(--color-bg-secondary); border: 1px solid var(--color-border-primary); border-radius: var(--radius-sm, 6px); padding: 10px 14px; margin-bottom: 16px; }
    .studio-pub-version { font-size: 13px; font-weight: 600; color: var(--color-text-primary); font-family: monospace; }
    .studio-pub-units { font-size: 12px; color: var(--color-text-tertiary); }
    .studio-pub-units::before { content: "·"; margin-right: 10px; }
    .studio-modal-body { font-size: 13px; color: var(--color-text-secondary); line-height: 1.6; }
    .studio-modal-status { margin: 0 0 8px; font-size: 13px; color: var(--color-text-secondary); line-height: 1.6; }
    .studio-modal-status-error { color: var(--color-error); }
    .studio-input { width: 100%; box-sizing: border-box; background: var(--color-bg-input); border: 1px solid var(--color-border-primary); border-radius: var(--radius-sm); padding: 7px 10px; color: var(--color-text-primary); font-size: 13px; font-family: monospace; }
    .studio-input:focus { border-color: var(--color-accent-primary); outline: none; }
    .studio-input-error { border-color: var(--color-error) !important; }
    .studio-modal-code { margin: 0 0 8px; font-size: 13px; font-family: monospace; color: var(--color-text-primary); }
    .studio-modal-link { display: inline-block; font-size: 13px; color: var(--color-accent-primary); }
    .studio-modal-footer { display: flex; justify-content: flex-end; gap: 8px; margin-top: 20px; padding-top: 16px; border-top: 1px solid var(--color-border-primary); }
    .studio-pub-success { margin-right: auto; font-size: 13px; font-weight: 500; color: var(--color-success); }
    .studio-section { margin-bottom: 20px; }
    .studio-detail-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 6px; }
    .studio-info-row { display: flex; align-items: baseline; gap: 8px; margin: 8px 0 0; }
    .studio-info-label { font-size: 12px; color: var(--color-text-tertiary); flex-shrink: 0; }
    .studio-info-value { font-size: 13px; color: var(--color-text-primary); }
    .studio-section-label { margin-top: 10px; margin-bottom: 6px; }
    .studio-detail-head .studio-detail-name { margin: 0; }
    .studio-form-status { font-size: 12px; color: var(--color-text-tertiary); }
    .studio-entry-list { display: flex; flex-direction: column; gap: 8px; margin-bottom: 8px; }
    .studio-entry-row { display: flex; align-items: stretch; gap: 8px; }
    .studio-entry-arrow { font-size: 12px; color: var(--color-text-tertiary); flex-shrink: 0; }
    .studio-entry-row .studio-select { flex: 1; width: auto; padding: 6px 28px 6px 8px; }
    .studio-entry-row .studio-select:focus { border-color: var(--color-accent-primary); outline: none; }
    .studio-btn-sm { padding: 4px 10px; font-size: 12px; }
    .studio-entry-row .studio-btn-sm { padding: 0 10px; }
  `;
  document.head.appendChild(style);
})();
