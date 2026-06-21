# OpenClacky 语音输入集成方案

> 语言：中文 | 英文版本：[voice-input-proposal.md](voice-input-proposal.md)

## 1. 目标

在 OpenClacky Web UI 中提供**开箱即用的语音输入**能力：

- 默认使用 Google Web Speech API（浏览器内置，零配置）
- 高级用户可切换 DashScope 等 ASR 引擎
- 快捷键、退出词、提示音等全部可自定义

## 2. 架构总览

```
┌─────────────────────────────────────────────────────────┐
│                    前端 (voice.js)                        │
│                                                           │
│  voice-core.js (纯逻辑)    UI  (按钮/动画/快捷键)          │
│  ├─ processAsrResult()     ├─ 麦克风按钮 + pulse 动画     │
│  ├─ matchVoiceShortcut()   ├─ 提示音 (SIRI base64 WAV)    │
│  └─ createInitialState()   └─ 快捷键 Ctrl+Shift+Z/S/R/M   │
│                             ├─ _isExitCommand() (退出词)   │
│                                                           │
│  AsrDriver 接口                                           │
│  ├─ GoogleDriver    纯浏览器，不需后端                      │
│  └─ DashScopeDriver 浏览器 → WebSocket → 后端代理          │
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
│  └─ dashscope → wss://dashscope.aliyuncs.com/...           │
└─────────────────────────────────────────────────────────┘
```

**核心设计原则**：
- **前端驱动层适配**：Google/DashScope 的差异在各自引擎工厂内部消解，通过私有 `_emitResult()` 统一汇入输入框
- **后端透明转发**：Proxy 只负责加 Auth header 转发 WebSocket，不做协议转换
- **voice-core 无 DOM 依赖**：纯逻辑可单独测试（已有 84 条用例全部通过）
- **与现有功能协作**：TTS 播报前读 `Voice.listening` 决定是否暂停麦克风，播完后调 `Voice.start()` 恢复；voice-mode-prompt 读 `Voice.voiceMode` 决定是否注入语音模式指令

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

- **自包含**：voice.js 不依赖项目其他模块，采用 IIFE 模式，暴露单一全局对象 `Voice`
- **遵循 i18n 规范**：所有用户可见文本走 `data-i18n` / `I18n.t()`，翻译键统一在 `i18n.js` 中添加
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
| `Voice.stop()` | method | 停止录音；已识别的文本保留在输入框中 |
| `Voice.setVoiceMode(on)` | method | 开启/关闭语音交互模式：开启后每次识别完自动重启监听，形成连续对话循环 |
| `Voice.listening` | getter | 是否正在录音（只读 boolean） |
| `Voice.voiceMode` | getter | 是否处于语音交互模式（只读 boolean） |

> **设计意图**：Voice 不提供 `onText` 事件注册——识别结果直接写入输入框。在 hands-free 模式下自动触发 Send，push-to-talk 模式下由用户手动发送，两种模式均与键盘输入行为衔接。外部集成只需读取 `listening`/`voiceMode` 状态、调用 `setVoiceMode()` 切换模式。

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
silence_timeout_ms: 1500          # 自动发送模式下静默超时后自动提交 (ms)
voice_mode_restart_delay_ms: 300  # voice mode 下自动重启延迟 (ms)
language: en-US                    # BCP-47 语言标签
default_mode: push-to-talk         # 初始语音模式：push-to-talk（点击发送）| hands-free（自动发送）

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

> **语音配置**：所有语音相关配置（ASR 引擎、API Key、快捷键、退出词、音效等）通过 `~/.clacky/voice-config.yml` 管理。前端通过 `/api/voice/config` 获取非敏感配置。暂未提供 Settings UI 面板，直接编辑 YAML 文件即可。

### 4.5 voice-core.js

纯逻辑模块（无 DOM 依赖，可单元测试）：

- `processAsrResult(state, text)` — ASR 文本累积 + 句子边界检测
- `createInitialState()` — 初始空状态
- `matchVoiceShortcut(e, shortcuts)` — 快捷键判断

> 退出词检测（`_isExitCommand`）实现在 voice.js 中，不在 voice-core.js。

### 4.6 CSS

按钮样式和动画定义在 `app.css` 中，使用项目已有的 CSS 变量。录音时触发 `.pulse`（push-to-talk 脉冲）或 `.mode-voice`（hands-free 呼吸灯）类名切换动画。

## 5. 后端设计

### 5.1 路由

```
GET /api/asr/proxy
  → Upgrade: websocket
  → 读取配置 → 连接上游 ASR 服务 → 双向转发
```

### 5.2 AsrProxy

`Clacky::AsrProxy` 负责完成浏览器 WebSocket 握手后，连接到上游 ASR 服务商并双向透明转发，不做协议转换。无需新依赖（`websocket` 已在 gemspec 中）。

### 5.3 安全考虑

- API Key 仅存在服务端 `~/.clacky/voice-config.yml` 中，不返回给前端
- 前端只能通过 `/api/voice/config` 获取非敏感配置，`api_key` 字段始终过滤

## 6. 文件结构

```
lib/clacky/
├── web/
│   ├── voice.js              # 语音模块（~650 行）
│   └── voice-core.js         # 纯逻辑模块（~100 行）
└── asr_proxy.rb              # 后端 ASR 代理（~260 行）
```

修改涉及：`index.html`（+2 script 标签）、`app.css`（+按钮/动画样式）、`http_server.rb`（+路由 + WebSocket 升级）。

