# OpenClacky Rich UI 模式 — 操作方式与界面展示内容

> 源码目录: `lib/clacky/rich_ui/`
> 基于 RubyRich 库构建的终端 TUI 界面

---

## 一、整体架构

`lib/clacky/rich_ui` 是 OpenClacky 的终端 TUI 界面模块，基于 `RubyRich` 库构建，实现了完整的终端用户交互界面。核心入口是 `RichUIController`（`rich_ui_controller.rb`），它通过 `RichAgentShell` 管理布局、组件、事件和生命周期。

---

## 二、界面布局（7层分区）

界面由 `RichAgentShell#build_layout` 定义的分区布局：

| 区域 | 名称 | 说明 |
|------|------|------|
| 第1行 | **Header** | 顶部标题栏，显示`OpenClacky`的标题/副标题 |
| 主体左 | **Transcript** | 对话记录视口，显示用户消息、助手回复、工具调用等 |
| 主体右 | **Sidebar** | 侧边栏（36列宽），包含 Work / Tasks / Context 三个面板 |
| 主体底部 | **ThinkingLive** | 实时思考展示区（动态出现/消失，高度0或6行） |
| 第6行起 | **Composer** | 输入编辑器，含 Framed 边框标题"Composer" |
| 最后1行 | **Status** | 底部状态栏，显示当前模式、模型、任务数、花费等 |

---

## 三、侧边栏（Sidebar）—— 三个信息面板

侧边栏（`RichSidebar`，`components/sidebar.rb`）支持多种显示模式，通过 F1-F4 快捷键切换：

- **F1 → Work 面板**：显示计划描述、最近最多8条工具活动（带状态标记）、任务数和花费统计
- **F2 → Tasks 面板**：显示当前任务清单（来自 `update_todos`），带完成进度（如 `3/5 done`），状态标记：
  - `✓`（绿色）= 已完成
  - `●`（蓝色）= 进行中
  - `!`（红色）= 失败
  - `○`（灰色）= 待处理
- **F3 → Auto 模式**：自动显示所有有内容的面板
- **F4 → Context 面板**：显示 Token 用量详情（prompt / output / total / cost）

侧边栏面板由 `components/sidebar_panels.rb` 实现：
- `RichWorkPanel`：工作进度面板
- `RichTasksPanel`：任务列表面板
- `RichContextPanel`：上下文/Token 信息面板

---

## 四、底部状态栏（Status Bar）

`RichStatusView`（`components/status_view.rb`）在终端最底部渲染一行状态信息：

- **空闲状态**：显示模式名称 + "idle" + 模型名 + 任务数 + 花费 + "Ctrl+C quit"
- **工作中**：显示旋转动画 spinner + 当前工具名（如 "web_search…"）+ 模型/延迟 + 任务数 + 花费
- **Ctrl+C 警告**：红色提示 "Press Ctrl+C again to exit"
- 延迟信息会附在模型名后（格式：`model_name (1.2s)`）

---

## 五、对话区域（Transcript）—— 操作方式与展示

### 5.1 消息展示

- **用户消息**：直接显示在对话区
- **助手回复**：Markdown 格式渲染（支持代码块、表格、列表等）
  - 长文本（≥240字符）触发**流式渲染**：每次6字符、间隔0.03秒逐块出现
  - 文件摘要自动附加在回复末尾（如 `Files - path/to/file.rb`）
- **系统消息**：普通 info / 警告 warning / 错误 error 分颜色展示
- **欢迎横幅**：首次启动时显示 `WelcomeBanner`，包含工作目录、模式等信息；若有历史会话则显示 "recent session" 分隔符和最近用户消息

### 5.2 思考过程展示（两阶段）

1. **实时阶段**：`ThinkingLiveView`（`components/thinking_live_view.rb`）动态出现（占据6行），逐字流式渲染思考内容，带旋转 spinner 和耗时计时器，完成后再停留约0.6秒
2. **折叠阶段**：思考内容以折叠块形式保留在对话区（标记为 "Xs"），按 Ctrl+O 可展开查看

### 5.3 工具调用展示

每种工具调用过程分三步可视化：

- **开始**：在对话区插入一个 `running` 状态条目，显示工具名和参数（经截断处理，如 `web_search("query...")`、`web_fetch(hostname)`）
- **完成**：更新条目状态为 `done`（绿色 `[OK]`），附上输出内容
- **出错**：更新条目状态为 `error`（红色 `[Error]`），附上错误信息

同时工具活动会同步到侧边栏 Work 面板（最多记录12条）。

### 5.4 Diff 展示

通过 `show_diff` 方法，使用 `Diffy` 库生成统一格式 diff，截断到50行可见（超出部分提示隐藏行数），附加统计信息（如 `+5, -3, 2 hunks`）。

### 5.5 Token 用量展示

`show_token_usage` 在对话区显示 prompt/output/total token 数和成本估算，同时同步到侧边栏 Context 面板。

### 5.6 文本选择与复制

`ViewportSelection`（`extensions/viewport_selection.rb`）扩展了 `RubyRich::Viewport`，支持：

- **鼠标选择**：左键拖拽选中文本，反色高亮
- **右键复制**：将选中的文本复制到系统剪贴板
- **多平台剪贴板支持**：Linux（wl-copy / xclip / xsel）、macOS（pbcopy）、Windows、以及通过 OSC 52 终端协议回退

### 5.7 表格渲染优化

`MarkdownTableAdapter`（`extensions/markdown_table_adapter.rb`）扩展了 RubyRich 的 Markdown 转换器，使表格能自适应终端宽度：通过计算列的自然宽度，在超出终端宽度时按比例压缩列宽，并将长文本自动换行。

---

## 六、输入区域（Composer）—— 操作方式

### 6.1 基础操作

- **文本输入**：单行编辑器，`Shift+Enter` 换行
- **历史导航**：上/下箭头浏览历史消息
- **Vim 滚动**：输入`/vim`切换，可以在单行模式下 `j`/`k` 滚动对话区
- **清空**：`Ctrl+C` 首次中断当前任务，再次退出；`Esc` 多层取消（见下文）

### 6.2 斜杠命令

内置命令通过 `/` 触发下拉菜单：

| 命令 | 说明 |
|------|------|
| `/clear` | 清空输出并重启会话 |
| `/config` | 打开模型配置对话框 |
| `/undo` | 恢复之前的任务状态 |
| `/help` | 显示帮助信息 |
| `/exit` | 退出应用 |
| `/model` | 切换 LLM 模型 |

技能（Skills）的斜杠命令也动态注册到 Composer 菜单中，描述截断到50字符。

### 6.3 Esc 多层取消栈

按 `Esc` 时按优先级逐层处理：

1. 关闭打开的对话框（如有）
2. 关闭斜杠菜单（如有）
3. 中断正在运行的任务
4. 清空输入框文本（Composer 原生行为）

---

## 七、对话框系统

RichUI 提供三种对话框，均以阻塞模式运行（调用 `show_blocking_dialog`）：

### 7.1 审批对话框（ApprovalDialog）

文件：`components/dialogs/approval_dialog.rb`

工具执行前的安全确认，展示：
- **工具名** + 分类徽章（File/Shell/Network/Paid，不同颜色）
- **风险等级**：Low（绿色）、Medium（黄色）、High（黄色）、Critical（红色），带 `●○○○` 形式的进度条
- **工具信息**和参数详情
- 三个操作按钮：`Approve`（批准）、`Deny`（拒绝）、`Always allow`（始终允许——指纹白名单）

导航：`←`/`→` 或 `h`/`l` 切换选项，`Enter` 确认，`Esc` 拒绝。

### 7.2 配置菜单对话框（ConfigMenuDialog）

文件：`components/dialogs/config_menu_dialog.rb`

`/config` 命令打开，用于模型管理：
- 列出所有已配置模型（显示 API Key 掩码、类型标签）
- 操作：切换模型 / 添加新模型 / 编辑当前模型 / 删除模型 / 关闭
- 添加模型时先选择 Provider（预配置 vs 自定义），再填写 API Key、Model 名、Base URL 表单
- 添加/编辑后可进行连接测试验证

导航：`↑`/`↓` 或 `j`/`k` 移动，`Enter` 选择，`q`/`Esc` 取消。

### 7.3 表单对话框（FormDialog）

文件：`components/dialogs/form_dialog.rb`

通用表单输入，用于模型编辑等场景：
- 支持多字段（带标签、默认值、占位符、密码掩码）
- 焦点字段显示 `➜` 标记
- 导航：`↑`/`↓`/`Tab`/`Shift+Tab` 切换字段，`Enter` 提交，`Esc` 取消

### 7.4 模型切换对话框

`/model` 命令触发，两步操作：
1. 从可用模型列表中选择目标模型
2. 选择应用范围：仅本次会话 / 永久保存

---

## 八、键盘快捷键总览

| 快捷键 | 范围 | 功能 |
|--------|------|------|
| `Ctrl+C` | 全局（1秒内） | 中断当前任务 |
| `Ctrl+C` | 全局（1秒后） | 退出程序 |
| `Ctrl+M` | 全局（2秒内） | 切换权限模式（confirm_safes ↔ confirm_all） |
| `Tab` | 全局 | 切换权限模式 + 重新聚焦 Composer |
| `F1` | 全局 | 侧边栏 → Work 面板 |
| `F2` | 全局 | 侧边栏 → Tasks 面板 |
| `F3` | 全局 | 侧边栏 → Auto 模式 |
| `F4` | 全局 | 侧边栏 → Context 面板 |
| `Esc` | 全局 | 多层取消（对话框→菜单→中断→清空输入） |
| `Shift+Enter` | Composer | 换行 |
| `↑`/`↓` | Composer | 历史消息导航 |
| `j`/`k` | Composer（单行模式） | 滚动对话区 |
| `Ctrl+O` | Transcript | 展开/折叠思考块 |
| 鼠标左键拖拽 | Transcript | 选择文本 |
| 鼠标右键 | Transcript | 复制选中文本 |

---

## 九、辅助模块

| 模块 | 文件 | 功能 |
|------|------|------|
| **ViewRenderer** | `view_renderer.rb` | 工具输出格式化（`[OK]`/`[Error]`）、参数截断、工具活动标签生成、Diff 统计解析、思考文本提取、API Key 掩码、配置菜单选项构建、模型表单验证 |
| **EntryTracker** | `entry_tracker.rb` | 轻量 ID 追踪器，维护工具调用栈（push/pop），确保工具调用与结果正确配对 |
| **LayoutAdapter** | `layout_adapter.rb` | 布局适配器，提供 `clear_output` 清空对话区 |
| **ProgressHandleAdapter** | `progress_handle_adapter.rb` | 包装 RubyRich 的进度处理器，提供 `update` / `finish` / `cancel` 接口 |
| **BaseComponent** | `components/base_component.rb` | 组件基类，提供 `muted`/`colored`/`status_marker`/`truncate`/`theme` 等共享渲染方法 |
| **TranscriptPlain** | `extensions/transcript_plain.rb` | 扩展 Transcript，支持 `plain: true` 标记的纯文本条目（用于欢迎横幅等） |
| **MarkdownTableAdapter** | `extensions/markdown_table_adapter.rb` | 猴子补丁扩展 Kramdown 到 RubyRich 的表格转换，实现终端宽度自适应表格换行 |
| **ViewportSelection** | `extensions/viewport_selection.rb` | 扩展视口，支持文本选择与多平台剪贴板复制 |

---

## 十、关键渲染常量

| 常量 | 值 | 说明 |
|------|-----|------|
| `STREAMING_MARKDOWN_THRESHOLD` | 240 字符 | 超过后触发流式渲染 |
| `STREAMING_MARKDOWN_CHUNK_SIZE` | 6 字符/块 | 流式渲染块大小 |
| `STREAMING_MARKDOWN_DELAY` | 0.03 秒 | 流式渲染间隔 |
| 思考流式块大小 | 3 字符/块 | 思考内容流式显示块大小 |
| 思考流式延迟 | 0.008 秒 | 思考内容流式显示间隔 |
| `SKILL_DESC_MAX` | 50 字符 | 技能描述在菜单中的截断长度 |
| 工具活动记录上限 | 12 条 | 侧边栏 Work 面板最大记录数 |
| Diff 可见行数 | 50 行 | `show_diff` 默认最大显示行数 |
| 工具标签截断 | 40 字符 | 工具调用参数标签的截断长度 |

---

## 十一、源文件清单

```
lib/clacky/rich_ui/
├── rich_ui_controller.rb            # 核心控制器（824行）
├── view_renderer.rb                 # 视图渲染辅助模块（291行）
├── entry_tracker.rb                 # 条目ID追踪器
├── layout_adapter.rb                # 布局适配器
├── progress_handle_adapter.rb       # 进度处理器适配器
├── shell/
│   └── rich_agent_shell.rb          # Rich模式下的AgentShell
├── components/
│   ├── base_component.rb            # 基础组件模块
│   ├── sidebar.rb                   # 侧边栏
│   ├── sidebar_panels.rb            # 侧边栏面板（Work/Tasks/Context）
│   ├── status_view.rb               # 状态视图（底部状态栏）
│   ├── thinking_live_view.rb        # 实时思考视图
│   └── dialogs/
│       ├── approval_dialog.rb       # 审批对话框
│       ├── form_dialog.rb           # 表单对话框
│       └── config_menu_dialog.rb    # 配置菜单对话框
└── extensions/
    ├── markdown_table_adapter.rb    # Markdown表格适配器
    ├── transcript_plain.rb          # 纯文本转录扩展
    └── viewport_selection.rb        # 视口文本选择扩展
```

## 十二、生命周期

1. `RichUIController#initialize` — 初始化配置、创建 `RichAgentShell`、`LayoutAdapter`、`EntryTracker`，绑定回调
2. `initialize_and_show_banner` — 设置 `running=true`，展示欢迎横幅或历史会话
3. `start` → `start_input_loop` → `@shell.start` — 进入终端事件循环
4. 用户提交输入 → `on_submit` 回调 → `@input_callback` → CLI → Agent
5. Agent 响应 → `show_assistant_message`（思考流式 + Markdown 渲染）
6. 工具调用 → `show_tool_call` / `show_tool_result` / `show_tool_error`
7. 任务完成 → `show_complete`、更新状态栏和侧边栏
8. `stop` — 退出事件循环，可选清屏