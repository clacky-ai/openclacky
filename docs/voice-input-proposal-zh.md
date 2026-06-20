# OpenClacky 语音输入集成方案

> 语言：中文 | Language: zh-CN
> 英文方案：待撰写 (voice-input-proposal-en.md)
>
> 将语音输入从 Tampermonkey 油猴脚本迁移为 OpenClacky 原生功能，提 PR 贡献官方。

## 1. 目标

在 OpenClacky Web UI 中提供**开箱即用的语音输入**能力：

- 默认使用 Google Web Speech API（浏览器内置，零配置）
- 高级用户可切换 DashScope / 科大讯飞等 ASR 引擎
- 快捷键、退出词、提示音等全部可自定义

## 2. 架构总览

```
┌─────────────────────────────────────────────────────────┐
│                    前端 (voice.js)                        │
│                                                           │
│  voice-core.js (纯逻辑)    UI  (按钮/动画/快捷键)          │
│  ├─ processAsrResult()     ├─ 麦克风按钮 + pulse 动画     │
│  ├─ isVoiceExitCommand()   ├─ 提示音 (SIRI base64 WAV)    │
│  └─ matchVoiceShortcut()   └─ 快捷键 Ctrl+Shift+Z/S/R     │
│                                                           │
│  AsrDriver 接口                                           │
│  ├─ GoogleDriver    纯浏览器，不需后端                      │
│  ├─ DashScopeDriver 浏览器 → WebSocket → 后端代理          │
│  └─ IflytekDriver   (未来扩展)                             │
│                                                           │
├─────────────────────────────────────────────────────────┤
│                    后端 (http_server.rb)                   │
│                                                           │
│  GET /api/asr/proxy → Upgrade: websocket                  │
│  ├─ 读取用户 asr_provider + api_key 配置                   │
│  ├─ 连接到对应 ASR 服务商                                   │
│  └─ 双向透明转发 (不做协议转换)                              │
│                                                           │
│  AsrProxy (Ruby)                                          │
│  ├─ dashscope → wss://dashscope.aliyuncs.com/...           │
│  └─ iflytek   → (未来扩展)                                 │
└─────────────────────────────────────────────────────────┘
```

**核心设计原则**：
- **前端驱动层适配**：Google/DashScope 的差异在各自驱动内部消解，对外暴露统一的 `onText(text)` 回调
- **后端透明转发**：Proxy 只负责加 Auth header 转发 WebSocket，不做协议转换
- **voice-core 无 DOM 依赖**：纯逻辑可单独测试（已有 84 条用例全部通过）

## 3. ASR 驱动对比

| | Google（默认） | DashScope |
|---|---|---|
| 实现位置 | 纯浏览器 | 浏览器 → 后端代理 |
| 需要后端？ | 否 | 是 |
| 需要 API Key？ | 否 | 是 |
| 中文识别质量 | 中等 | 优秀 |
| 中英混合 | 中等 | 优秀 |
| 流式结果 | ✅ | ✅ |
| 用户操作 | 零配置直接用 | 配 API Key + 选 DashScope |

> Google 的 `webkitSpeechRecognition` 开启 `interimResults: true` 后行为和 DashScope 的流式中间结果一致——都是累积型逐字更新。前端 voice-core 无需感知驱动差异。

## 4. 前端设计

### 4.1 设计原则

- **自包含**：voice.js 不依赖项目其他模块，参考 `notify.js` 的 IIFE 模式
- **遵循 i18n 规范**：所有用户可见文本走 `data-i18n` / `I18n.t()`，翻译键统一在 `i18n.js` 中添加（详见 [`docs/i18n-guide-zh.md`](i18n-guide-zh.md)）
- **遵循 CSS 规范**：使用项目已有的 CSS 变量（`--color-accent-primary` 等），不新增颜色常量

### 4.1.5 两种语音模式

语音输入支持两种交互模式，通过 `Voice.setVoiceMode()` 切换：

| 模式 | 激活方式 | 按钮外观 | 行为 |
|------|---------|---------|------|
| **点击发送 (Push-to-Talk)** | 默认；快捷键 `Ctrl+Shift+Z` 或点击麦克风 | 录音时红色 + pulse 脉冲动画 | 点击开关，一句一发（push, speak, stop, click send） |
| **自动发送 (Hands-free)** | 快捷键 `Ctrl+Shift+M` 或调用 `Voice.setVoiceMode(true)` | 录音时蓝色 + 呼吸灯动画（2s 循环） | 持续监听，静默 `silence_timeout_ms` 后自动提交并自动续听 |

**模式切换逻辑**：
- 从 push-to-talk 切换到 Hands-free：若当前未录音则自动开始录音，进入持续监听
- 从 Hands-free 切换到 push-to-talk：若当前正在录音则停止
- 切换快捷键 `Ctrl+Shift+M`（可在 `voice-config.yml` → `shortcuts.voice_mode` 自定义）

**UI 指示器**：
- 按钮 `title` 属性根据当前模式动态显示：「语音输入」/「点击发送 — 逐条识别」/「自动发送 — 连续对话」
- 呼吸动画（`@keyframes voice-breathe`）仅在 Hands-free 录音时显示，区别于 push-to-talk 的单次脉冲

```js
// voice.js — 语音输入模块，IIFE 自包含，暴露 Voice 全局对象
// 加载方式：index.html 中 <script src="/voice.js"></script>
// 不需要语音功能时，删除该行即可
```

### 4.2 Voice 公开 API

`window.Voice` 是唯一对外入口。所有方法均可在控制台、外部脚本、浏览器自动化（CDP evaluate）中直接调用。

| API | 类型 | 说明 |
|-----|------|------|
| `Voice.toggle()` | method | 切换录音状态（开→关、关→开）；pulse 动画跟随状态 |
| `Voice.start()` | method | 开始录音；如果已在录音则无操作 |
| `Voice.stop()` | method | 停止录音，返回本次识别的完整文本 |
| `Voice.setVoiceMode(on)` | method | 开启/关闭语音交互模式：开启后每次识别完自动重启监听，形成连续对话循环 |
| `Voice.listening` | getter | 是否正在录音（只读 boolean） |
| `Voice.voiceMode` | getter | 是否处于语音交互模式（只读 boolean） |
| `Voice.engine` | getter | 当前 ASR 引擎名称，如 `"google"` / `"dashscope"` |

> **设计意图**：Voice 不提供 `onText` 事件注册——识别结果直接写入输入框并触发 Send，与键盘输入行为一致。外部集成只需读取 `listening`/`voiceMode` 状态、调用 `setVoiceMode()` 切换模式。

**典型集成场景**：

| 场景 | 如何集成 |
|------|----------|
| **TTS 防回声闭环** | TTS 播报前读 `Voice.listening` 决定是否暂停 → 播完后调 `Voice.start()` 恢复监听 |
| **CDP 自动化操控** | `browser evaluate` 执行 `window.Voice.setVoiceMode(true)` / `Voice.listening` 轮询 |
| **voice-mode-prompt 动态注入** | 检查 `Voice.voiceMode` 决定是否在 system prompt 中追加语音模式指令 |
| **外部状态指示器** | 轮询 `Voice.listening` 驱动自定义 UI 指示灯 |
| **一键静音** | 程序入口或外部按钮直接调 `Voice.stop()` |

### 4.3 配置项 (voice-config.yml)

配置文件位于 `~/.clacky/voice-config.yml`（示例参考 `docs/voice-config.example.yml`），前端通过 `/api/voice/config` 获取（api_key 不会返回前端）。

```yaml
# ── ASR engine ──────────────────────────────────────────
asr:
  provider: google        # google | dashscope
  api_key: ""             # DashScope API key（仅服务端，不暴露前端）

# ── Keyboard shortcuts ──────────────────────────────────
shortcuts:
  toggle:
    modifiers: [Control, Shift]
    key: z
  stop:
    modifiers: [Control, Shift]
    key: s
  start:
    modifiers: [Control, Shift]
    key: r
  voice_mode:             # 切换 push-to-talk / 连续对话
    modifiers: [Control, Shift]
    key: m

# ── Voice exit commands ─────────────────────────────────
exit_words:
  - stop listening
  - exit voice
  - goodbye

# ── Voice behavior ──────────────────────────────────────
silence_timeout_ms: 1500          # 静默超时后自动提交 (ms)
voice_mode_restart_delay_ms: 300  # voice mode 下自动重启延迟 (ms)
language: en-US                    # BCP-47 语言标签

# ── Sound effects ───────────────────────────────────────
sound:
  start: default             # 录音开始音效 (default | none | 文件名)
  stop: default              # 录音停止音效
  volume: 0.4                # 音量 0.0 ~ 1.0
```

### 4.4 UI 设计

麦克风按钮置于输入框旁（`#input-bar` 中，`#btn-send` 左侧）：

```
┌──────────────────────────────────────────────────────────┐
│  [textarea]                                    [🎤] [→]  │
│                                                          │
│  未激活: 灰色                                             │
│  Push-to-talk 录音中: 红色 + pulse 脉冲动画                │
│  Hands-free 录音中:   蓝色 + 呼吸灯动画 (2s 循环)          │
│  hover: 品牌主色                                           │
└──────────────────────────────────────────────────────────┘
```

Settings → Voice tab 界面（所有标签使用 i18n key，由 `I18n.t()` 渲染）：

```
┌─ Settings ──────────────────────────────────┐
│  [Models] [UI] [Voice] [General] [About]    │
│                                              │
│  ── settings.voice.engine ───────────────   │
│  Engine  [settings.voice.engine.google ▼]     │
│          Google / DashScope / ...            │
│                                              │
│  ── DashScope (选中时展开) ──────────────    │
│  settings.voice.apiKey  [••••••••••••••••]   │
│  Proxy URL [ws://localhost:8765]             │
│                                              │
│  ── settings.voice.shortcuts ────────────   │
│  settings.voice.shortcut.toggle  [Ctrl+Shift+Z] [Edit]  │
│  settings.voice.shortcut.stop    [Ctrl+Shift+S] [Edit]  │
│  settings.voice.shortcut.start   [Ctrl+Shift+R] [Edit]  │
│                                              │
│  ── settings.voice.exitWords ────────────   │
│  [结束语音交互, 退出语音交互, 关闭语音, 再见] │
│                                              │
│  ── settings.voice.sound ────────────────   │
│  Start [settings.voice.sound.default ▼]      │
│  Stop  [settings.voice.sound.default ▼]      │
└──────────────────────────────────────────────┘
```

### 4.5 voice-core.js

从油猴脚本提取的纯逻辑模块（无 DOM 依赖，可单元测试）：

- `processAsrResult(state, text)` — ASR 文本累积 + 句子边界检测
- `isVoiceExitCommand(text)` — 退出命令匹配
- `createInitialState()` — 初始空状态
- `matchVoiceShortcut(e)` — 快捷键判断

**句子边界检测算法**（适配 paraformer-realtime-v2 无 is_end 特性）：
同一 VAD 片段内文本逐字增长 → 新 VAD 片段时文本从长变短 → 检测到长度突降 ≤ 旧长度50% → 判定为新句子，旧句入队。

### 4.6 CSS

添加到 `app.css`，约50行：

```css
/* Voice button */
#btn-voice { ... }
#btn-voice:hover { color: var(--color-accent-primary); }

/* Pulse animation (push-to-talk) */
@keyframes voice-pulse { ... }
#btn-voice.pulse {
  animation: voice-pulse 0.4s ease-out;
}

/* Breathing animation (Hands-free mode) */
@keyframes voice-breathe {
  0%   { box-shadow: 0 0 0 0 rgba(74, 158, 255, 0.4); }
  50%  { box-shadow: 0 0 12px 4px rgba(74, 158, 255, 0.3); }
  100% { box-shadow: 0 0 0 0 rgba(74, 158, 255, 0); }
}
#btn-voice.mode-voice {
  animation: voice-breathe 2s ease-in-out infinite;
}
```

## 5. 后端设计

### 5.1 路由

```
GET /api/asr/proxy
  → Upgrade: websocket
  → 读取配置 → 连接上游 ASR 服务 → 双向转发
```

### 5.2 AsrProxy（Ruby）

```ruby
module Clacky
  module AsrProxy
    def self.handle(ws)
      config = load_config  # 从 settings 读 provider + api_key
      upstream = case config[:provider]
      when "dashscope"
        connect_dashscope(config[:api_key])
      when "iflytek"
        connect_iflytek(config[:api_key])
      end
      relay(ws, upstream)  # 双向透明转发
    end
  end
end
```

**不需要新依赖**：`websocket ~> 1.2` 已在 gemspec 中。

### 5.3 安全考虑

- API Key 仅存在服务端 localStorage 对应文件中，不返回给前端
- 前端通过 Settings UI 提交 API Key 到后端 `/api/config/asr` 设置接口（只写不读）
- 前端只能看到 `has_api_key: true/false`

## 6. 改动清单

### 新增文件

| 文件 | 说明 |
|------|------|
| `lib/clacky/web/voice.js` | 语音模块（~400行） |
| `lib/clacky/web/voice-core.js` | 纯逻辑模块（~90行） |
| `lib/clacky/asr_proxy.rb` | 后端 ASR 代理（~80行） |
### 修改文件

| 文件 | 改动 | 行数 |
|------|------|------|
| `lib/clacky/web/index.html` | +1 `<script src="/voice.js">` | +1 |
| `lib/clacky/web/app.css` | +voice 按钮/动画样式 | +50 |
| `lib/clacky/server/http_server.rb` | +`/api/asr/proxy` 路由 + WebSocket 升级 | +30 |

**总计改动**：约 570 行新代码 + 80 行修改。

## 7. 实现步骤

### Phase 1：前端核心（voice.js + voice-core.js + CSS）

1. 将 voice-core.js 逻辑移入项目
2. 编写 voice.js（参考 notify.js 模式）
3. 添加 CSS 样式
4. 在 index.html 加 script 标签
5. 实现 Google 驱动（默认）

### Phase 2：后端代理

1. 实现 `AsrProxy` Ruby 模块
2. 在 http_server.rb 加 `/api/asr/proxy` WebSocket 路由
3. 实现 DashScope 驱动
4. 添加 API Key 管理接口

### Phase 3：配置化

1. Settings Voice tab UI
2. 快捷键录制/编辑
3. 退出词自定义
4. 提示音选择和自定义
5. i18n 翻译键

### Phase 4：测试与 PR

1. voice-core 单元测试
2. 端到端功能测试
3. 编写 PR 描述（英文）
4. 提交 PR 到 openclacky 主仓库

## 8. 兼容性

### Google 驱动

- Chrome：✅ 内置 `webkitSpeechRecognition`
- Edge：✅ 同上
- Firefox：❌ 不支持（降级提示用户切换引擎）
- Safari：✅ `SpeechRecognition`（macOS）

### DashScope 驱动

- 所有浏览器：✅ 通过 WebSocket + 后端代理

### 快捷键

- 传统快捷键 `Ctrl+Shift+Z` 在所有桌面浏览器正常工作
- Mac 用户：`Cmd+Shift+Z`（检测 `metaKey` 自动适配）

## 9. 与现有功能的交互

| 功能 | 交互方式 |
|------|----------|
| **TTS 语音播报** | `Voice.setVoiceMode()` — 开启/关闭持续监听 |
| **voice-mode-prompt** | 读取 `Voice.listening` 状态，TTS 播完自动恢复监听 |
| **离线模式** | 自动降级到 Google 驱动（离线也可用） |
| **移动端** | 响应式布局，麦克风按钮自动适配 |

---

> 作者：朱朱 (via 啸哥)
> 日期：2026-06-20
> 相关文件：`~/.clacky/zhuzhu/voice/` (油猴脚本原型)
