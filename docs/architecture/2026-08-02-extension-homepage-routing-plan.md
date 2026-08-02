# 扩展首页路由实施计划

> **给执行人员：**实施时必须使用 `box-executing-plans` 技能，按复选框逐项执行和验证。

**目标：**让 `/#new` 自动进入用户选中的扩展首页；没有明确选择且只有一个候选时，自动进入该候选。

**架构：**在现有 `Clacky.ext` 扩展注册中心增加首页候选、用户选择和解析能力。Router 仍是唯一导航入口，只在处理现有 welcome/`#new` 页面时查询实际首页；命中扩展后复用已有 `ext-workspace` 路由，否则继续显示原生页面。

**技术栈：**原生 JavaScript WebUI、Ruby、RSpec、现有 `Clacky.ext` 工作区注册中心和 Hash Router。

---

## 文件职责

- 修改 `lib/clacky/web/core/ext.js`：注册首页候选、保存明确选择、解析实际首页。
- 修改 `lib/clacky/web/app.js`：在 welcome 分支中执行一次首页解析。
- 修改 `lib/clacky/web/index.html`：顶部 Logo 进入 `welcome`，不再进入不存在的 `chat` 路由。
- 修改 `lib/clacky/web/settings.js`：在设置中显示默认首页选择器。
- 修改 `lib/clacky/web/i18n.js`：增加中英文界面文案。
- 修改 `spec/clacky/web/extension_architecture_spec.rb`：约束扩展公开协议。
- 新增 `spec/clacky/web/homepage_routing_spec.rb`：覆盖路由和回退规则。
- 修改 `lib/clacky/default_extensions/ext-studio/skills/ext-develop/SKILL.md`：记录扩展接入方式。

正式实现只修改 `openclacky`。本机安装的 `qingshi-workbench` 只作为临时测试样本，不提交、
不打包、不发布。

## 任务一：增加宿主管理的首页候选协议

**涉及文件：**

- `lib/clacky/web/core/ext.js`
- `spec/clacky/web/extension_architecture_spec.rb`

- [ ] 先在扩展架构规格中增加失败用例，要求公开以下能力：

```javascript
Clacky.ext.ui.registerHomepage(workspaceId, definition)
Clacky.ext.ui.homepageCandidates()
Clacky.ext.ui.selectHomepage(workspaceId)
Clacky.ext.ui.resolveHomepage()
```

- [ ] 用例必须验证：只有已经通过 `registerWorkspace` 注册的工作区，才能成为首页候选。

- [ ] 运行规格，确认新增用例先失败：

```bash
bundle exec rspec spec/clacky/web/extension_architecture_spec.rb
```

- [ ] 在 `Clacky.ext` 内增加私有状态：

```javascript
const _homepageCandidates = {};
const HOMEPAGE_STORAGE_KEY = "clacky-default-homepage";
const NATIVE_HOMEPAGE = "native";
```

- [ ] 实现 `registerHomepage`：校验工作区存在，从宿主工作区注册信息中取得扩展 ID，记录中英文名称，不执行导航。

- [ ] 实现 `homepageCandidates`：返回候选信息副本，避免扩展修改宿主内部状态。

- [ ] 实现 `selectHomepage`：只接受 `native` 或当前有效候选，并写入浏览器本地存储。

- [ ] 实现 `resolveHomepage`，规则如下：

```javascript
if (PURE) return { type: "native" };

const saved = localStorage.getItem(HOMEPAGE_STORAGE_KEY);
if (saved === NATIVE_HOMEPAGE) return { type: "native" };
if (saved && _homepageCandidates[saved]) {
  return { type: "workspace", workspaceId: saved };
}

const candidates = Object.keys(_homepageCandidates);
return candidates.length === 1
  ? { type: "workspace", workspaceId: candidates[0] }
  : { type: "native" };
```

- [ ] 不得把“唯一候选自动使用”的结果写入本地存储；只有用户操作才能形成明确偏好。

- [ ] 重新运行扩展架构规格，确认通过。

- [ ] 提交该阶段：

```bash
git add lib/clacky/web/core/ext.js spec/clacky/web/extension_architecture_spec.rb
git commit -m "feat(webui): add extension homepage registry"
```

## 任务二：让现有 `/#new` 通过 Router 解析首页

**涉及文件：**

- 新增 `spec/clacky/web/homepage_routing_spec.rb`
- 修改 `lib/clacky/web/app.js`
- 修改 `lib/clacky/web/index.html`

- [ ] 新增失败用例，确认 `#new` 仍映射到 `welcome`，首页解析只发生在 welcome 分支。

- [ ] 新增失败用例，确认顶部 Logo 调用 `Router.navigate('welcome')`，并移除不存在的 `chat` 目标。

- [ ] 运行新规格，确认先失败：

```bash
bundle exec rspec spec/clacky/web/homepage_routing_spec.rb
```

- [ ] 在 Router 的 welcome 分支开头加入解析：

```javascript
const homepage = window.Clacky?.ext?.ui?.resolveHomepage?.();
if (homepage?.type === "workspace" && homepage.workspaceId) {
  await _apply("ext-workspace", { id: homepage.workspaceId });
  return;
}
```

- [ ] 未命中扩展时保留现有原生逻辑：设置 `#new`、显示 welcome 容器并调用 `NewSessionView.onPanelShow()`。

- [ ] 把顶部品牌区域的点击目标改为：

```html
onclick="Router.navigate('welcome')"
```

- [ ] 运行路由、扩展架构和 JavaScript 语法规格：

```bash
bundle exec rspec \
  spec/clacky/web/homepage_routing_spec.rb \
  spec/clacky/web/extension_architecture_spec.rb \
  spec/clacky/web/syntax_spec.rb
```

- [ ] 提交该阶段：

```bash
git add lib/clacky/web/app.js lib/clacky/web/index.html spec/clacky/web/homepage_routing_spec.rb
git commit -m "feat(webui): resolve extension homepage from new route"
```

## 任务三：增加默认首页设置

**涉及文件：**

- `lib/clacky/web/settings.js`
- `lib/clacky/web/i18n.js`
- `spec/clacky/web/homepage_routing_spec.rb`

- [ ] 先增加失败用例，要求设置页面读取 `homepageCandidates()` 并通过 `selectHomepage()` 保存选择。

- [ ] 用例必须要求设置中包含“OpenClacky 原生页面”选项。

- [ ] 增加中英文文案：

```javascript
"settings.homepage.label":  "Default homepage",
"settings.homepage.native": "OpenClacky native page",
```

```javascript
"settings.homepage.label":  "默认首页",
"settings.homepage.native": "OpenClacky 原生页面",
```

- [ ] 在现有基础设置区域中渲染单选下拉框，不新增顶级设置页面。

- [ ] 没有候选时隐藏该设置；存在候选时列出原生页面和全部有效候选。

- [ ] 根据当前语言显示候选的英文或中文名称。

- [ ] 用户切换选项时调用 `selectHomepage`，但不立即强制跳页；下次进入首页时生效。

- [ ] 运行相关规格：

```bash
bundle exec rspec spec/clacky/web/homepage_routing_spec.rb spec/clacky/web/syntax_spec.rb
```

- [ ] 提交该阶段：

```bash
git add lib/clacky/web/settings.js lib/clacky/web/i18n.js spec/clacky/web/homepage_routing_spec.rb
git commit -m "feat(webui): add default homepage setting"
```

## 任务四：更新扩展开发说明

**涉及文件：**

- `lib/clacky/default_extensions/ext-studio/skills/ext-develop/SKILL.md`
- `spec/clacky/web/extension_architecture_spec.rb`

- [ ] 在规格中要求扩展开发说明包含 `registerHomepage` 示例。

- [ ] 在工作区注册示例后增加：

```javascript
Clacky.ext.ui.registerHomepage("my-workbench", {
  title: "My Workbench",
  titleZh: "我的工作台",
});
```

- [ ] 明确说明：唯一候选自动使用；多个候选由宿主让用户选择；扩展不得自行改写 `/#new`。

- [ ] 运行完整测试：

```bash
bundle exec rspec
```

- [ ] 提交该阶段：

```bash
git add lib/clacky/default_extensions/ext-studio/skills/ext-develop/SKILL.md spec/clacky/web/extension_architecture_spec.rb
git commit -m "docs(extension): document homepage candidates"
```

## 任务五：用青狮工作台做本地临时验收

本任务只验证宿主能力，不属于正式交付。

**临时测试文件：**

- `~/.clacky/ext/installed/qingshi-workbench/panels/workbench/view.js`

- [ ] 修改前记录当前文件版本和 Git 外部备份位置，确保可以恢复。

- [ ] 在现有 `registerWorkspace(HOME_WORKSPACE, ...)` 后临时加入：

```javascript
Clacky.ext.ui.registerHomepage(HOME_WORKSPACE, {
  title: "Lawyer AI Workbench",
  titleZh: "律师 AI 工作台",
});
```

- [ ] 按仓库约定启动本地客户端：

```bash
bundle exec ruby bin/clacky server
```

- [ ] 验证没有候选时，`/#new` 显示原生页面。

- [ ] 启用青狮临时候选后，验证 `/#new` 自动变成 `/#ext/qingshi-workbench`。

- [ ] 在其他页面点击顶部 Logo，验证仍回到青狮工作台。

- [ ] 临时再注册第二个候选，验证未明确选择时回到原生页面，并可在设置中选择。

- [ ] 明确选择原生首页，移除第二个候选，验证唯一候选不会覆盖用户选择。

- [ ] 使用 `?pure=true#new`，验证始终显示原生页面。

- [ ] 停止本地服务。测试改动不得加入 `openclacky` Git 提交，不得打包或发布第三方扩展。

## 完成标准

- `bundle exec rspec` 全部通过；
- `/#new` 在零候选、唯一候选、多候选和明确选择四种状态下符合设计；
- Logo 与直接访问 `/#new` 使用同一解析结果；
- 纯净模式始终能进入原生页面；
- `openclacky` 提交中不包含任何 `qingshi-workbench` 文件。
