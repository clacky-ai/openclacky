# RichUI Controller 重构方案

> 目标：向 UI2 的 MVC 分层、组件化、id-based 内容管理经验学习，将 `lib/clacky/rich_ui_controller.rb`（2336 行，12+ 个类）重构为结构清晰、职责单一、可维护的模块化架构。

---

## 一、现状诊断

### 1.1 核心问题

| 问题 | 现状 | 影响 |
|------|------|------|
| **单文件过大** | 2336 行，12+ 个类（Shell、Sidebar、3 个 Panel、StatusView、ThinkingLiveView、UIController、3 个 Dialog、2 个 Adapter） | 代码冲突率高、代码审查困难、新人上手成本大 |
| **无 MVC 分层** | 渲染逻辑、布局坐标、业务状态、事件回调全部混在一起 | 无法单元测试渲染逻辑，改一处可能牵全身 |
| **无组件系统** | 所有输出都是内联字符串拼接（`"#{AnsiCode.color(:green)}✓#{reset}"`） | 样式泄漏、难以统一维护、无法复用 |
| **Monkey Patch 集中** | `RubyRich::Viewport`、`RubyRich::Transcript`、`RubyRich::Markdown::TerminalRenderer` 的 patch 挤在文件顶部 | Patch 与业务代码纠缠，升级 gem 时风险集中 |
| **深度耦合 gem 内部** | 大量 `instance_variable_get(:@callbacks)`、`instance_variable_set(:@on_interrupt, nil)` | RubyRich 内部重构即崩溃，属于脆弱的外部依赖 |
| **对话框内嵌** | `ConfigMenuDialog`、`FormDialog`、`ApprovalDialog` 定义在同一个文件 | 对话框逻辑膨胀会进一步加剧文件体积 |
| **无 id-based 内容管理** | 依赖 `ruby_rich` 的 `transcript.store.entries`，没有自己的 OutputBuffer | 无法精确 `replace`/`remove` 非尾部内容，缺少 commit 防重复机制 |
| **主题硬编码** | `RubyRich::Theme.whale_dark` 写死在 `RichUIController#initialize` | 用户无法切换主题，与 UI2 的主题系统不互通 |
| **Progress 是适配器** | `ProgressHandleAdapter` 只是包装 ruby_rich 原生 handle，没有 UI2 的 v2 语义（owned handle、stack、quiet_on_fast_finish） | 并发 progress 竞争、fast-finish 不支持 |

### 1.2 与 UI2 的关键差距

```
UI2 架构（已成熟）                    RichUI 架构（待重构）
─────────────────────────────────    ─────────────────────────────────
UIController  （协调层，薄）           RichUIController （协调+渲染+布局，厚）
  ├── ViewRenderer  （视图调度）       └── 无对应层，直接操作字符串
  │     ├── MessageComponent           └── 无组件，内联拼接
  │     ├── ToolComponent              └── 无组件，内联拼接
  │     └── CommonComponent            └── 无组件，内联拼接
  ├── LayoutManager  （布局引擎）      └── 无对应层，依赖 RubyRich::Layout
  │     └── OutputBuffer  （id-based） └── 无对应层，依赖 transcript.entries
  ├── ScreenBuffer   （ANSI 原语）     └── 无对应层，由 ruby_rich 封装
  ├── InputArea      （输入编辑器）     └── RubyRich::Composer（外部，但通过 ivar 侵入）
  └── ThemeManager   （主题系统）       └── 硬编码 Theme.whale_dark
```

---

## 二、重构目标

1. **文件拆分**：单文件 → 多文件模块化，每个类独立文件
2. **MVC 分层**：引入 `ViewRenderer` + `Components` + `LayoutAdapter` 层
3. **组件化**：提取 Panel、Dialog、Status 为独立 Component
4. **解耦 gem**：将 monkey patch 移入 `extensions/`；减少 `instance_variable_get`
5. **id-based 内容管理**（可选增强）：在 RubyRich Transcript 之上封装轻量 id 追踪层
6. **主题互通**：复用或桥接 UI2 的 `ThemeManager`，允许 `--theme` 生效

---

## 三、目标目录结构

```
lib/clacky/
├── rich_ui.rb                              # 入口文件（类似 ui2.rb）
├── rich_ui/
│   ├── rich_ui_controller.rb               # 薄 Controller（原 2336 行 → 目标 < 300 行）
│   ├── layout_adapter.rb                   # 布局协调（替代原 LayoutAdapter）
│   ├── progress_handle_adapter.rb          # Progress 适配（已有，保留）
│   │
│   ├── components/                         # 视图组件（类似 ui2/components/）
│   │   ├── base_component.rb               # 基类：提供 muted、colored、truncate 等
│   │   ├── message_component.rb            # 消息渲染（user/assistant/system）
│   │   ├── tool_component.rb               # 工具调用/结果/错误渲染
│   │   ├── common_component.rb             # 进度/成功/错误/警告渲染
│   │   ├── welcome_banner.rb               # 欢迎横幅（复用 UI2 或独立实现）
│   │   ├── thinking_live_view.rb           # 思考区（原 ThinkingLiveView）
│   │   ├── status_view.rb                  # 底部状态栏（原 RichStatusView）
│   │   ├── sidebar.rb                      # 侧边栏容器（原 RichSidebar）
│   │   ├── sidebar_panels.rb               # WorkPanel/TasksPanel/ContextPanel
│   │   └── dialogs/                        # 对话框组件
│   │       ├── base_dialog.rb              # 公共 wait/finish/key 协议
│   │       ├── config_menu_dialog.rb       # 模型配置菜单
│   │       ├── form_dialog.rb              # 表单输入
│   │       └── approval_dialog.rb          # 审批确认
│   │
│   ├── extensions/                         # 对 ruby_rich 的扩展（替代顶部 monkey patch）
│   │   ├── viewport_selection.rb           # Viewport 文本选择与剪贴板
│   │   ├── transcript_plain.rb             # Transcript plain 模式
│   │   └── markdown_table_adapter.rb       # TerminalRenderer 表格适配
│   │
│   └── shell/                              # RichAgentShell 及其配置
│       └── rich_agent_shell.rb             # 继承 RubyRich::AgentShell
│
└── cli.rb                                  # 修改 require 路径
```

---

## 四、分阶段实施计划

### Phase 1：文件拆分与目录搭建（低风险，纯移动）

**目标**：将 2336 行的单文件按类拆分到多个文件，行为零变化。

| 步骤 | 操作 |
|------|------|
| 1.1 | 新建 `lib/clacky/rich_ui/` 目录及子目录 |
| 1.2 | 将 `RichAgentShell` 移入 `rich_ui/shell/rich_agent_shell.rb` |
| 1.3 | 将 `RichSidebar` + 3 个 Panel 移入 `rich_ui/components/sidebar.rb` 和 `sidebar_panels.rb` |
| 1.4 | 将 `ThinkingLiveView` 移入 `rich_ui/components/thinking_live_view.rb` |
| 1.5 | 将 `RichStatusView` 移入 `rich_ui/components/status_view.rb` |
| 1.6 | 将 3 个 Dialog 移入 `rich_ui/components/dialogs/*.rb`，提取 `BaseDialog` |
| 1.7 | 将 `LayoutAdapter`、`ProgressHandleAdapter` 移入 `rich_ui/` 根目录 |
| 1.8 | 新建 `lib/clacky/rich_ui.rb` 入口文件，统一 require |
| 1.9 | 修改 `cli.rb`：`require_relative "rich_ui_controller"` → `require_relative "rich_ui"` |

**验证**：运行 `--ui=rich`，功能完全一致。

---

### Phase 2：Monkey Patch 外移与解耦（中风险）

**目标**：将文件顶部的 monkey patch 转为显式扩展模块，降低耦合。

#### 2.1 Viewport 选择扩展

**现状**：
```ruby
class RubyRich::Viewport
  alias_method :clacky_handle_event_without_text_selection, :handle_event
  def handle_event(event_data, layout = nil)
    # ... 30+ 行 ...
  end
end
```

**重构后**：`lib/clacky/rich_ui/extensions/viewport_selection.rb`
```ruby
module Clacky::RichUI::Extensions::ViewportSelection
  def self.apply!
    RubyRich::Viewport.class_eval do
      # patch here
    end
  end
end

# 在 rich_ui.rb 入口显式调用：
Clacky::RichUI::Extensions::ViewportSelection.apply!
```

好处：
- Patch 代码与业务逻辑物理隔离
- `apply!` 显式调用，升级 gem 时一目了然哪里可能冲突
- 可添加 `apply?` 检查（`method_defined?`）避免重复加载

#### 2.2 Markdown 表格扩展

同样移入 `extensions/markdown_table_adapter.rb`，显式 `apply!`。

#### 2.3 减少 `instance_variable_get`

**现状**（多处）：
```ruby
clacky = @shell.instance_variable_get(:@clacky_controller)
status = clacky.instance_variable_get(:@status)
```

**重构后**：在 `RichAgentShell` 中提供正式的 accessor：
```ruby
class RichAgentShell < RubyRich::AgentShell
  attr_accessor :clacky_controller, :status, :work_label
  # ...
end
```

`RichStatusView` 改为：
```ruby
def render
  clacky = @shell.clacky_controller
  return [""] unless clacky
  status = clacky.status
  # ...
end
```

---

### Phase 3：引入 ViewRenderer 组件层（中风险）

**目标**：仿照 UI2 的 `ViewRenderer` + `Components`，将字符串拼接逻辑提取为可测试的组件。

#### 3.1 新建 BaseComponent

```ruby
# lib/clacky/rich_ui/components/base_component.rb
module Clacky::RichUI::Components
  class BaseComponent
    def muted(text)
      "#{RubyRich::AnsiCode.color(:black, true)}#{text}#{RubyRich::AnsiCode.reset}"
    end

    def colored(text, color)
      "#{RubyRich::AnsiCode.color(color, true)}#{text}#{RubyRich::AnsiCode.reset}"
    end

    def truncate(text, limit = 40)
      # ...
    end
  end
end
```

#### 3.2 提取 Sidebar Panels 为组件

原 `RichWorkPanel#render` 内联拼接：
```ruby
def render
  lines = []
  lines << @plan unless @plan.empty?
  # ...
  lines.join("\n")
end
```

重构后：
```ruby
class SidebarWorkPanel < BaseComponent
  def render(plan:, activities:, tasks:, cost:)
    lines = []
    lines << plan if plan && !plan.empty?
    # ...
    lines << muted("#{tasks} tasks · $#{cost.round(4)}")
    lines.join("\n")
  end
end
```

Panel 类只保留 **状态存储**，渲染委托给 Component。

#### 3.3 提取 Dialog 渲染为组件

`ApprovalDialog` 的 `render_content`、`render_choices`、`category_badge`、`colored`、`muted` 全部使用 `BaseComponent` 方法。

重构后结构：
```ruby
class ApprovalDialog
  # 保留：事件循环、wait/finish、key binding（这些是交互逻辑）
  # 移除：render_content 中的字符串拼接 → 交给 ApprovalDialogRenderer
end

class ApprovalDialogRenderer < BaseComponent
  def render(tool_name:, message:, params:, risk:, category:, selected_index:)
    # 纯渲染逻辑，无副作用，可单元测试
  end
end
```

---

### Phase 4：Controller 瘦身与主题互通（中风险）

#### 4.1 Controller 只保留协调逻辑

目标：
```ruby
class RichUIController
  include Clacky::UIInterface

  def initialize(config = {})
    @config = config
    @shell = RichAgentShell.new(...)
    @renderer = ViewRenderer.new        # ← 新增
    @sidebar = @shell.sidebar            # ← 由 Shell 提供
    @progress_stack = []                 # ← 为未来 v2 做准备
    wire_callbacks
  end

  def show_tool_call(name, args)
    output = @renderer.render_tool_call(name: name, args: args)
    # ... 交给 ruby_rich 展示
  end
end
```

#### 4.2 复用 UI2 ThemeManager（可选）

**方案 A（桥接）**：RichUI 继续使用 `RubyRich::Theme`，但将 `whale_dark` 等主题映射到 UI2 的 theme name。

**方案 B（统一）**：RichUI 的组件接受 UI2 的 `ThemeManager.current_theme`，在渲染时调用 `theme.format_symbol(:user)` 而非直接使用 `RubyRich::AnsiCode`。

推荐 **方案 A**（低侵入），在 `BaseComponent` 中提供主题桥接：
```ruby
def theme
  @theme ||= RubyRich::Theme.whale_dark
end
```

---

### Phase 5：id-based 内容管理（可选增强，高风险）

UI2 的 `OutputBuffer` 是其架构精髓，但 RichUI 依赖 `ruby_rich` 的 `Transcript` + `Viewport`，强行替换成本高。

**推荐做法**：在 RichUI 中引入轻量 **EntryTracker** 而非完整 OutputBuffer。

```ruby
# lib/clacky/rich_ui/entry_tracker.rb
class EntryTracker
  # 追踪 ruby_rich 返回的 message_id / block_id
  # 提供：
  # - register(id, type:) → 记录 id
  # - update(id, content) → 调用 @shell.append_to_message(id, content)
  # - remove(id) → 调用 @shell.transcript.remove_entry(id)
  # - current_tool_id → 栈顶 tool_call id
end
```

这样 `show_tool_call` / `show_tool_result` 不再依赖 `@tool_ids.pop`（栈语义脆弱），而是显式通过 id 追踪。

---

## 五、关键设计决策

### 决策 1：是否保留 Monkey Patch？

**结论**：保留功能，但移入 `extensions/` 目录并显式 `apply!`。

理由：
- RubyRich gem 未提供扩展点，不 patch 无法实现选择复制
- 集中管理后，升级 gem 时只需检查 `extensions/` 目录

### 决策 2：Dialog 是否使用 RubyRich 原生 Dialog？

**结论**：继续使用自研 Dialog（`ConfigMenuDialog` 等），但渲染层提取为 Component。

理由：
- RubyRich 原生 Dialog 能力有限，当前自研 Dialog 已实现阻塞 wait、自定义 key binding
- 提取 Renderer 后，Dialog 的交互逻辑与渲染样式解耦

### 决策 3：Sidebar 面板是否拆分为独立文件？

**结论**：3 个 Panel（Work/Tasks/Context）合并为 `sidebar_panels.rb`，但各自为独立类。

理由：
- 每个 Panel 只有 ~50 行，独立文件过于细碎
- 合并后仍保持类级独立，便于后续提取 Component

### 决策 4：是否引入 ProgressHandle v2？

**结论**：当前先保留 `ProgressHandleAdapter` 桥接，但为未来预留接口。

理由：
- ruby_rich 的 `start_progress` / `update` / `finish` 语义与 UI2 不同，强行对齐改动面大
- 可在 `RichUIController` 中预留 `@progress_stack`，后续再实现真正的 stack 语义

---

## 六、验证清单

重构完成后，以下功能必须 1:1 保留：

- [ ] `--ui=rich` 正常启动，显示欢迎横幅
- [ ] 用户输入 → Agent 响应 完整流程
- [ ] 工具调用卡片（开始/结束/错误）
- [ ] Thinking 思考区实时流式显示
- [ ] 右侧 Sidebar（Work/Tasks/Context 面板及 F1-F4 切换）
- [ ] 底部状态栏（spinner、mode、model、任务数、花费）
- [ ] 鼠标选择 + 右键复制
- [ ] Markdown 表格自适应宽度
- [ ] `/config` 对话框（菜单 + 表单）
- [ ] 工具审批对话框（ApprovalDialog）
- [ ] 模型切换对话框
- [ ] Ctrl+C 中断、Esc 取消层级、Tab 切换 mode
- [ ] `--theme` 参数生效（或至少不报错）

---

## 七、估算工作量

| Phase | 工作量 | 风险 |
|-------|--------|------|
| Phase 1：文件拆分 | 2-3 小时 | 低（纯移动，加 require） |
| Phase 2：Patch 外移 + 解耦 | 3-4 小时 | 中（需仔细验证 ivar 替换） |
| Phase 3：ViewRenderer + Components | 4-6 小时 | 中（渲染逻辑提取，需逐条对比输出） |
| Phase 4：Controller 瘦身 + 主题 | 2-3 小时 | 中 |
| Phase 5：EntryTracker（可选） | 4-6 小时 | 高（涉及 ruby_rich 内部 id 机制） |
| **合计（不含 Phase 5）** | **11-16 小时** | |

---

## 八、立即可以动手的第一步

如果现在就启动重构，建议按以下顺序：

1. **新建目录结构**：`mkdir -p lib/clacky/rich_ui/{components/dialogs,extensions,shell}`
2. **Phase 1 文件拆分**：将类逐个剪切到新文件，原文件保留为兼容 shim（`require_relative "rich_ui"`）
3. **跑通测试**：`bundle exec ruby ./bin/openclacky agent --ui=rich`，确认无 require 错误
4. **逐步替换**：每移一个类，验证一次，不积压

---

*方案制定日期：2026-06-11*
*参考基准：UI2 架构（`lib/clacky/ui2/` 目录，docs/ui2-architecture.md）*
