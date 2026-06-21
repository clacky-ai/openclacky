# OpenClacky Voice Input Integration

> Language: EN | 中文版本：[voice-input-proposal-zh.md](voice-input-proposal-zh.md)

## 1. Goals

Provide **out-of-the-box voice input** in the OpenClacky Web UI:

- Default: Google Web Speech API (browser-native, zero configuration)
- Advanced: switch to DashScope or other ASR engines
- Fully customizable: shortcuts, exit words, sound effects

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Frontend (voice.js)                    │
│                                                           │
│  voice-core.js (pure logic)    UI (button/animation/shortcuts) │
│  ├─ processAsrResult()         ├─ Mic button + pulse anim  │
│  ├─ matchVoiceShortcut()       ├─ Sound effects (WAV)     │
│  └─ createInitialState()       └─ Shortcuts Ctrl+Shift+Z/S/R/M │
│                                ├─ _isExitCommand() (exit words) │
│                                                           │
│  ASR Driver interface                                    │
│  ├─ GoogleDriver    Browser-only, no backend needed       │
│  └─ DashScopeDriver Browser → WebSocket → backend proxy  │
│                                                           │
├─────────────────────────────────────────────────────────┤
│                    Backend (http_server.rb)               │
│                                                           │
│  GET /api/asr/proxy → Upgrade: websocket                 │
│  ├─ Read user asr_provider + api_key config               │
│  ├─ Connect to the corresponding ASR provider             │
│  └─ Bidirectional transparent relay (no protocol conversion) │
│                                                           │
│  AsrProxy (Ruby)                                         │
│  └─ dashscope → wss://dashscope.aliyuncs.com/...         │
└─────────────────────────────────────────────────────────┘
```

**Core design principles**:
- **Frontend driver adaptation**: Google/DashScope differences are absorbed inside their respective engine factories, unified through the private `_emitResult()` function into the input box
- **Backend transparent relay**: The proxy only adds Auth headers and forwards WebSocket; no protocol translation
- **voice-core is DOM-free**: pure logic, independently testable (84 test cases, all passing)
- **Integration with existing features**: TTS reads `Voice.listening` before playback to decide whether to pause the mic, calls `Voice.start()` after; voice-mode-prompt checks `Voice.voiceMode` to decide whether to inject voice-mode instructions

## 3. ASR Driver Comparison

| | Google (default) | DashScope |
|---|---|---|
| Implementation | Browser-only | Browser → backend proxy |
| Backend needed? | No | Yes |
| API Key needed? | No | Yes |
| Chinese recognition | Moderate | Excellent |
| Chinese-English mixed | Moderate | Excellent |
| Streaming results | ✅ | ✅ |
| User setup | Zero config | Configure API Key + select DashScope |

> Google's `webkitSpeechRecognition` with `interimResults: true` behaves identically to DashScope's streaming intermediate results — both are cumulative incremental updates. voice-core does not need to distinguish between drivers.

## 4. Frontend Design

### 4.1 Design Principles

- **Self-contained**: voice.js has no dependencies on other project modules; uses IIFE pattern, exposing a single `Voice` global object
- **i18n compliance**: all user-visible text uses `data-i18n` / `I18n.t()`; translation keys are added in `i18n.js`
- **CSS compliance**: uses existing CSS variables (`--color-accent-primary`, etc.); does not introduce new color constants

### 4.1.5 Two Voice Modes

Voice input supports two interaction modes, toggled via `Voice.setVoiceMode()`:

| Mode | Activation | Button appearance | Behavior |
|------|-----------|-------------------|----------|
| **Push-to-Talk** | Default; shortcut `Ctrl+Shift+Z` or click mic | Red + pulse animation while recording | Click to start, speak, click to stop, then manually send |
| **Hands-free** | Shortcut `Ctrl+Shift+M` or `Voice.setVoiceMode(true)` | Blue + breathing animation (2s loop) while recording | Continuous listening; auto-send after `silence_timeout_ms` silence, then auto-restart |

**Mode switching logic**:
- Push-to-Talk → Hands-free: auto-starts recording if not already recording, enters continuous listening
- Hands-free → Push-to-Talk: stops recording if currently active
- Toggle shortcut `Ctrl+Shift+M` (configurable via `voice-config.yml` → `shortcuts.voice_mode`)

**UI indicator**:
- Button `title` attribute dynamically shows: "Voice input" / "Push-to-Talk — per-utterance" / "Hands-free — continuous"
- Breathing animation (`@keyframes voice-breathe`) only shows during Hands-free recording, distinct from the single pulse of push-to-talk

```js
// voice.js — Voice input module, IIFE, self-contained, exposes the Voice global object
// Loaded via: <script src="/voice.js"></script> in index.html
// To disable voice: remove that line
```

### 4.2 Voice Public API

`window.Voice` is the sole public entry point. All methods are callable from the console, external scripts, and browser automation (CDP evaluate).

| API | Type | Description |
|-----|------|-------------|
| `Voice.toggle()` | method | Toggle recording state (on→off, off→on); pulse animation follows state |
| `Voice.start()` | method | Start recording; no-op if already recording |
| `Voice.stop()` | method | Stop recording; recognized text remains in the input box |
| `Voice.setVoiceMode(on)` | method | Enable/disable continuous conversation mode: when enabled, auto-restarts listening after each recognition, forming a continuous conversation loop |
| `Voice.listening` | getter | Whether currently recording (read-only boolean) |
| `Voice.voiceMode` | getter | Whether in continuous conversation mode (read-only boolean) |

> **Design intent**: Voice does not provide `onText` event registration — recognition results are written directly to the input box. In Hands-free mode, Send is triggered automatically; in Push-to-Talk mode, the user sends manually. Both modes integrate seamlessly with keyboard-based input workflows. External integrations only need to read `listening`/`voiceMode` state and call `setVoiceMode()` to switch modes.

**Typical integration scenarios**:

| Scenario | How to integrate |
|----------|-----------------|
| **TTS anti-echo loop** | Read `Voice.listening` before TTS playback to decide whether to pause → call `Voice.start()` after playback to resume |
| **CDP automation** | `browser evaluate` → `window.Voice.setVoiceMode(true)` / poll `Voice.listening` |
| **voice-mode-prompt injection** | Check `Voice.voiceMode` to decide whether to append voice-mode instructions to the system prompt |
| **External status indicator** | Poll `Voice.listening` to drive custom UI indicators |
| **One-click mute** | Call `Voice.stop()` from app entry or external button |

### 4.3 Configuration (voice-config.yml)

Config file location: `~/.clacky/voice-config.yml` (example: `docs/voice-config.example.yml`). The frontend fetches non-sensitive config via `/api/voice/config` (`api_key` is never returned to the frontend).

```yaml
# ── ASR engine ──────────────────────────────────────────
asr:
  provider: google        # google | dashscope
  api_key: ""             # DashScope API key (server-side only, never exposed to frontend)

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
  voice_mode:             # Toggle push-to-talk / continuous conversation
    modifiers: [Control, Shift]
    key: m

# ── Voice exit commands ─────────────────────────────────
exit_words:
  - stop listening
  - exit voice
  - goodbye

# ── Voice behavior ──────────────────────────────────────
silence_timeout_ms: 1500          # Auto-submit after silence in Hands-free mode (ms)
voice_mode_restart_delay_ms: 300  # Auto-restart delay in voice mode (ms)
language: en-US                    # BCP-47 language tag
default_mode: push-to-talk         # Initial voice mode: push-to-talk | hands-free

# ── Sound effects ───────────────────────────────────────
sound:
  start: default             # Recording start sound (default | none | filename)
  stop: default              # Recording stop sound
  volume: 0.4                # Volume 0.0 ~ 1.0
```

### 4.4 UI Design

The mic button sits next to the input box (in `#input-bar`, to the left of `#btn-send`):

```
┌──────────────────────────────────────────────────────────┐
│  [textarea]                                    [🎤] [→]  │
│                                                          │
│  Idle: gray                                              │
│  Push-to-Talk recording: red + pulse animation            │
│  Hands-free recording:   blue + breathing anim (2s loop)  │
│  Hover: brand accent color                                │
└──────────────────────────────────────────────────────────┘
```

> **Voice configuration**: All voice-related settings (ASR engine, API Key, shortcuts, exit words, sound effects, etc.) are managed via `~/.clacky/voice-config.yml`. The frontend fetches non-sensitive config through `/api/voice/config`. No Settings UI panel is provided yet — edit the YAML file directly.

### 4.5 voice-core.js

Pure logic module (no DOM dependencies, unit-testable):

- `processAsrResult(state, text)` — ASR text accumulation + sentence boundary detection
- `createInitialState()` — initial empty state
- `matchVoiceShortcut(e, shortcuts)` — keyboard shortcut matching

> Exit word detection (`_isExitCommand`) is implemented in voice.js, not in voice-core.js.

### 4.6 CSS

Button styles and animations are defined in `app.css`, using existing CSS variables. Recording state toggles `.pulse` (push-to-talk) or `.mode-voice` (hands-free breathing) classes.

## 5. Backend Design

### 5.1 Routes

```
GET /api/asr/proxy
  → Upgrade: websocket
  → Read config → connect upstream ASR service → bidirectional relay
```

### 5.2 AsrProxy

`Clacky::AsrProxy` completes the browser WebSocket handshake, then connects to the upstream ASR provider and relays bidirectionally with no protocol translation. No new dependencies required (`websocket` already in gemspec).

### 5.3 Security Considerations

- The API Key is stored only in the server-side `~/.clacky/voice-config.yml` and is never returned to the frontend
- The frontend can only fetch non-sensitive config via `/api/voice/config`; the `api_key` field is always filtered out

## 6. File Structure

```
lib/clacky/
├── web/
│   ├── voice.js              # Voice module (~650 lines)
│   └── voice-core.js         # Pure logic module (~100 lines)
└── asr_proxy.rb              # Backend ASR proxy (~260 lines)
```

Modified files: `index.html` (+2 script tags), `app.css` (+button/animation styles), `http_server.rb` (+routes + WebSocket upgrade).
