# 设计草案：通用事件通道（emit）与 background 技能调用

状态：**草案，待 review**。本文只描述设计，不含实现。

调研基线：`VERSION = 1.5.5`，工作副本 `~/workspace/openclacky-all/openclacky`。

---

## 目录

- [背景](#背景)
- [提案一：UIInterface#emit 通用事件通道](#提案一uiinterfaceemit-通用事件通道)
- [提案二：invoke_skill background](#提案二invoke_skill-background)
- [两者的依赖关系](#两者的依赖关系)
- [风险与回滚](#风险与回滚)
- [待决问题](#待决问题)

---

## 背景

两个需求：

1. 让 `invoke_skill` 原生支持 `background`（不阻塞主循环，后台跑子 agent）。
2. 让扩展能够发出自定义事件。

调研后结论：**需求 2 是需求 1 的前置**。后台子 agent 若无法向外发事件，用户在它运行期间只能干等，background 的价值大打折扣。因此建议拆成两个 PR，提案一先行。

---

## 提案一：UIInterface#emit 通用事件通道

### 现状问题

`lib/clacky/ui_interface.rb` 定义的是**固定方法签名接口**，每类事件一个具名方法：

```ruby
def show_assistant_message(content, files:); end
def show_subagent_start(skill: nil, iterations: nil, cost_usd: nil); end
def show_tool_call(name, args); end
def show_progress(...); end
# ...
```

后果：扩展想新增一种事件类型，必须修改 `UIInterface` 并同步全部实现。当前有 **8 个 UI 实现**：

| 文件 | 定义 phase_start | 定义 emit |
|---|---|---|
| `lib/clacky/server/web_ui_controller.rb` | ✅ | ✅ |
| `lib/clacky/json_ui_controller.rb` | — | ✅ |
| `lib/clacky/ui2/ui_controller.rb` | ✅ | — |
| `lib/clacky/null_ui_controller.rb` | — | — |
| `lib/clacky/plain_ui_controller.rb` | — | — |
| `lib/clacky/rich_ui/rich_ui_controller.rb` | — | — |
| `lib/clacky/rich_ui_controller.rb` | — | — |
| `lib/clacky/server/channel/channel_ui_controller.rb` | — | — |

对扩展而言这是一个封闭接口。

### 关键依据：抽象已自发出现两次，且签名一致

`web_ui_controller.rb:446`

```ruby
def emit(type, **data)
  event = { type: type, session_id: @session_id }.merge(data)
  if (pid = Thread.current[:clacky_phase_id]) && !data.key?(:phase_id)
    event[:phase_id] = pid
  end
  @broadcaster.call(@session_id, event)
end
```

`json_ui_controller.rb:21`

```ruby
def emit(type, **data)
  event = { type: type }.merge(data)
  @mutex.synchronize do
    @output.puts(JSON.generate(event))
    @output.flush
  end
end
```

两处独立演化出**完全相同的签名** `emit(type, **data)`，只是投递目标不同（broadcaster / stdout）。这是应当提炼为公共契约的强信号。目前 `emit` 未出现在 `UIInterface` 中，扩展无法依赖它。

### 设计

在 `UIInterface` 增加默认空实现：

```ruby
# Emit a structured event. Unknown event types are silently dropped by UIs
# that don't understand them — this is what makes the channel extensible.
def emit(type, **data); end
```

要点：

- **零破坏**。`UIInterface` 全部方法本就是空实现默认值，未实现 `emit` 的 6 个 UI 自动获得 no-op，静默丢弃未知事件——正是前向兼容所需语义。
- **两处已有实现自然满足契约**，无需改写行为，只需确认签名一致。
- **命名空间约定**：建议扩展事件统一带前缀（如 `ext.<name>.<event>`），避免与内置类型冲突。此约定需写入文档，不做运行时强制。

### 附带发现：phase 分组是线程局部的

`web_ui_controller.rb:228`

```ruby
def phase_start(kind:, label: nil)
  pid = SecureRandom.uuid
  Thread.current[:clacky_phase_id] = pid
  # ...
end
```

phase_id 存于 `Thread.current`，而 `emit` 会自动将其注入事件（`:448-450`）。

含义：**并行子 agent 各占一个线程时，其发出的事件会自动携带各自的分组 ID，无需手动透传 `subagent_id`。** 这为提案二的 UI 分栏提供了现成载体。`UIInterface#phase_start` 已有默认实现（`ui_interface.rb:166`，返回一个 UUID），未实现的 UI 同样安全。

### 影响面

新增一个默认 no-op 方法；可选地为两处已有实现补充注释说明其契约来源。不改变任何现有行为。

---

## 提案二：invoke_skill background

### 入口现状

`lib/clacky/tools/invoke_skill.rb` 共 117 行，参数仅 `skill_name`、`task`。执行时按技能配置分叉：

- `fork_agent?` 为真 → 走 subagent（`agent/skill_manager.rb:580 execute_skill_with_subagent`）
- 否则 → `enqueue_injection`（`agent.rb:1442`）延迟注入

新增一个 `background: false` 布尔参数，入口改动面很小。

**当前执行模型是彻底串行的**：`agent.rb:1117` 的工具循环为 `tool_calls.each_with_index`，即使 LLM 单轮返回多个工具调用，也是逐个执行、前一个完成才开始下一个。加上 `run_detached` 的同步阻塞（见下文），**当前不存在任何形式的后台或并发子 agent**。

### 硬约束：tool_call 必须配对 tool_result

LLM 的工具调用是请求-响应配对的，每个 `tool_call` 必须有对应的 `tool_result` 才能继续对话；Bedrock / Anthropic 对消息顺序尤其严格（`invoke_skill.rb` 内已有注释专门警告此点）。

因此 `background: true` **必须立即返回一个 tool_result**（形如「已启动，handle=xxx」），真实结果稍后通过其他通道回到对话。这就需要明确定义**收割机制**。

### 收割机制的两个候选

**方案 A：下一轮 turn 自动注入**

复用现有 `@pending_injections`（`agent.rb:1442-1444`）。后台任务完成后把结果排入队列，下一轮 turn 自动注入上下文。

- 优点：复用成熟通道；对 LLM 透明，无需新工具；不增加模型的认知负担。
- 缺点：LLM 无法主动等待——若它下一步就需要结果，只能空转一轮。

**方案 B：新增 `wait_for` 工具**

后台任务返回 handle，LLM 显式调用 `wait_for(handle)` 阻塞取结果。

- 优点：控制力强，可表达「先并发启动 N 个，再一起等」的模式，这是真并行的关键。
- 缺点：多一个工具；LLM 可能忘记调用，导致任务结果永远无人收割（需兜底：turn 结束时强制收割未取结果）。

倾向：**若目标是真并行，方案 B 更契合**；方案 A 更适合「发射后不管」的通知类任务。两者不互斥，可先做 A 再加 B。

### 必须先修的并发缺陷

**`@pending_subagent_transcript` 是单数槽位**（`agent.rb:113`），消费点 `agent.rb:1404`：

```ruby
private def attach_pending_subagent_transcript(response)
  transcript = @pending_subagent_transcript
  return unless transcript
  @pending_subagent_transcript = nil

  skill_call = Array(response[:tool_calls]).find { |tc| (tc[:name] || tc.dig(:function, :name)) == "invoke_skill" }
  target_id = skill_call && skill_call[:id]
  return unless target_id

  @history.attach_to_tool_result(target_id, :subagent_transcript, transcript)
end
```

两个缺陷：

1. 单槽位——多个后台子 agent 先后完成会互相覆盖，先完成者的轨迹丢失。
2. `find { ... }` 只取**第一个** `invoke_skill` 调用——同一轮内有多个 `invoke_skill` 时必然张冠李戴，把 A 的轨迹挂到 B 的结果上。

修法：改为按 `tool_call_id` 索引的 map，写入时携带发起调用的 id，消费时精确匹配。此缺陷在当前串行场景下也存在（同一轮多次 `invoke_skill` 即可触发），**可作为独立 bugfix 先行提交**。

### 其余并发注意点（已核实）

| 项 | 结论 |
|---|---|
| `check_stale!`（`agent.rb:1103`） | **不是障碍**。`@task_thread`（`time_machine.rb:81`）是实例变量，子 agent 在自己线程 `run` 时认领自身线程，子之间不互杀。**铁律：子线程绝不能回写父 history** |
| `ToolRegistry`（`agent.rb:84`）、`@todos`（`agent.rb:91`） | 每实例自建，天然隔离 |
| `Tools::Terminal::SessionManager`（`session_manager.rb:51`） | 唯一类级单例，自带 `@mutex` |
| 线程模型 | LLM 调用是 Faraday 同步阻塞 IO，GVL 在 IO 等待时释放 → `Thread.new` 即可真并行，**不需要 async 重构**。`web_search.rb:175` 已有 `Thread.new + Queue` fan-out 先例 |
| 工作目录 | 工具走 `working_dir` 注入，无 `Dir.chdir` 全局污染（`agent.rb:1205` 有注释说明） |
| 成本累加 | `skill_manager.rb:660` 的 `@total_cost += subagent_cost` 是非原子读-改-写，并行下需加锁 |
| UI 混流 | `fork_subagent` 默认继承父 `@ui`（`agent.rb:1668`）；多个后台 agent 同时输出会交错，需靠提案一的 phase 分组隔离，或改用 `NullUIController` |

### 现成原型（注意：不含并发）

`agent.rb:1577 run_detached` 提供了「fork + NullUI + run + 只回收结果与成本、完全不碰父 history」的**执行体**原型，可作为 background 执行体的基础。

**但必须澄清：`run_detached` 目前完全是同步阻塞的，不存在任何后台执行能力。**

- `agent.rb:1589` 的 `result = subagent.run(task)` 会阻塞调用线程直到子 agent 跑完，无 `Thread.new`、无队列。
- 全仓唯一调用方 `extension/api_extension.rb:372` 写作 `{ text: agent.run_detached(...) }`，直接取返回值作文本使用，是同步语义的直接证据。
- 方法名中的 "detached" 与其 system prompt 中的 "background analysis" 指的是**与主对话历史脱钩**（结果不写入父 history），属于**可见性**概念，**不是时间上的并发**。此命名易被误读，建议在实现 background 时一并澄清或重命名。

因此提案二需要新建的是**调度与结果回流通路**，而非在既有能力上做增强。

---

## 两者的依赖关系

```
提案一（emit 通用通道）         ← 独立可用，先行
        │
        ├── 后台任务进度可见（否则用户干等）
        │
提案二（background 调用）       ← 依赖提案一
        │
        └── 前置 bugfix：pending_subagent_transcript 单槽位 + find 误匹配
```

建议拆分为三个 PR：

1. **bugfix**：`pending_subagent_transcript` 改 map，修同轮多次 `invoke_skill` 的错配（当前串行即可复现，独立有价值）
2. **feature**：`UIInterface#emit` 通用事件通道（零破坏，不涉并发，易被接受）
3. **feature**：`invoke_skill(background:)` + 收割机制（依赖前两个）

---

## 风险与回滚

| 风险 | 评估 | 缓解 |
|---|---|---|
| 新增 `emit` 破坏现有 UI | 极低。默认 no-op，现有两处实现签名已一致 | 无需缓解 |
| 扩展事件类型与内置冲突 | 中 | 约定 `ext.` 前缀命名空间，写入文档 |
| 后台任务结果无人收割 | 中（方案 B 特有） | turn 结束时强制收割兜底 |
| 并行破坏消息顺序 | 高（若实现不当） | 铁律：子线程只返回结果，由父线程统一写入 history |
| 成本统计竞态 | 低 | `@total_cost` 累加加锁 |

三个 PR 均为增量改动，回滚即 revert，无数据迁移。

---

## 待决问题

1. 收割机制选方案 A（自动注入）还是 B（`wait_for` 工具）？
2. 后台任务的上下文策略：深拷贝父 history（保 prompt cache，成本乘 N）还是空上下文播种（省 token、强隔离）？
3. 并发上限与超时策略如何设定？
4. 三个 PR 是提交到上游，还是先在自有环境验证后再提？
