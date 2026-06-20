// voice.js — Voice input module for OpenClacky
//
// Adds a microphone button next to the send button in the chat input bar.
// Config is fetched from /api/voice/config on init (single source of truth:
// ~/.clacky/voice-config.yml on the server). No localStorage settings remain.
//
// ASR Providers:
//   - google   (default) — browser-native Web Speech API, zero config
//   - dashscope           — Alibaba Cloud paraformer-realtime-v2
//                            via backend WebSocket proxy /api/asr/proxy
//                            (requires api_key in voice-config.yml#asr)
//
// Public API (const Voice, global scope):
//   Voice.toggle()       — toggle recording on/off
//   Voice.start()        — start recording (async for dashscope, sync for google)
//   Voice.stop()         — stop recording
//   Voice.setVoiceMode() — enable/disable continuous conversation mode
//   Voice.listening      — read-only boolean, is mic active
//   Voice.voiceMode      — read-only boolean, is continuous mode on
//
// Depends on: voice-core.js (processAsrResult,
//             matchVoiceShortcut, createInitialState).
//             I18n (i18n.js) for tooltip text — optional, guarded.
// ─────────────────────────────────────────────────────────────────────────
const Voice = (() => {
  "use strict";

  // ── Server-side voice config (fetched on init) ────────────────────────
  let _voiceConfig = null;  // cached from /api/voice/config

  async function _loadVoiceConfig() {
    try {
      const res = await fetch("/api/voice/config");
      if (!res.ok) return {};
      const data = await res.json();
      _voiceConfig = data.config || {};
      return _voiceConfig;
    } catch (_) {
      return {};
    }
  }

  function _cfg(path, fallback) {
    // path like "asr.provider" or "shortcuts.toggle.key"
    const keys = path.split(".");
    let obj = _voiceConfig || {};
    for (const k of keys) {
      if (obj == null) return fallback;
      obj = obj[k];
    }
    return obj != null ? obj : fallback;
  }

  // ── Internal state ────────────────────────────────────────────────────
  let _listening   = false;
  let _voiceMode   = false;
  let _engine      = null;    // active ASR engine (strategy object — see Engine interface)
  let _gen          = 0;      // generation counter — bumped to ignore stale results
  let _asrState    = null;    // voice-core state object
  let _silenceTimer = null;
  let _btn          = null;

  // ── Sound playback (fetches from /api/voice/sound) ────────────────────
  const _soundCache = { start: null, stop: null };

  async function _loadSound(type) {
    if (_soundCache[type]) return _soundCache[type];
    try {
      const res = await fetch("/api/voice/sound?type=" + type);
      if (res.status === 204) return null; // "none"
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      _soundCache[type] = url;
      return url;
    } catch (_) {
      return null;
    }
  }

  function _playSound(type) {
    const src = _soundCache[type];
    if (src === null) return; // cached "none" → skip

    if (src) {
      // Already loaded
      const a = new Audio(src);
      a.volume = _cfg("sound.volume", 0.4);
      a.play().catch(() => {});
      return;
    }

    // Not loaded yet — load and play
    _loadSound(type).then(url => {
      if (!url) return;
      const a = new Audio(url);
      a.volume = _cfg("sound.volume", 0.4);
      a.play().catch(() => {});
    });
  }

  // ── UI: create microphone button ─────────────────────────────────────
  function _createButton() {
    if (document.getElementById("btn-voice")) return;

    const bar = document.getElementById("input-bar");
    if (!bar) return;

    const btn = document.createElement("button");
    btn.id = "btn-voice";
    btn.setAttribute("data-i18n-title", "voice.btn.toggle");
    btn.title = "Voice input";
    btn.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/>
      <path d="M19 10v2a7 7 0 0 1-14 0v-2"/>
      <line x1="12" y1="19" x2="12" y2="23"/>
      <line x1="8" y1="23" x2="16" y2="23"/>
    </svg>`;

    btn.addEventListener("click", () => Voice.toggle());

    // Insert before send button
    const sendBtn = document.getElementById("btn-send");
    if (sendBtn) {
      bar.insertBefore(btn, sendBtn);
    } else {
      bar.appendChild(btn);
    }

    _btn = btn;

    // Apply i18n if available
    if (typeof I18n !== "undefined" && I18n.applyAll) {
      I18n.applyAll();
    }
  }

  function _updateBtnTitle() {
    if (!_btn) return;
    if (_listening) {
      if (_voiceMode) {
        _btn.setAttribute("data-i18n-title", "voice.btn.voiceMode");
        _btn.title = "Hands-free — auto-send, mic stays open";
      } else {
        _btn.setAttribute("data-i18n-title", "voice.btn.pushToTalk");
        _btn.title = "Push to talk — click to send";
      }
    } else {
      _btn.setAttribute("data-i18n-title", "voice.btn.toggle");
      _btn.title = "Voice input";
    }
    // Re-apply i18n if available
    if (typeof I18n !== "undefined" && I18n.applyAll) {
      I18n.applyAll();
    }
  }

  function _updateBtnUI() {
    if (!_btn) return;
    _updateBtnTitle();

    // Clear all state classes
    _btn.classList.remove("pulse", "mode-voice");

    if (_listening) {
      if (_voiceMode) {
        // Voice mode: green/blue breathing
        _btn.style.color = "var(--color-accent-primary, #4a9eff)";
        _btn.classList.add("mode-voice");
      } else {
        // Push-to-talk: red pulse
        _btn.style.color = "var(--color-danger, #e74c3c)";
        void _btn.offsetWidth; // force reflow
        _btn.classList.add("pulse");
        _btn.addEventListener("animationend", () => _btn.classList.remove("pulse"), { once: true });
      }
    } else {
      _btn.style.color = "";
    }
  }

  function _pulse() {
    // Delegate to _updateBtnUI which handles both pulse (push-to-talk) and
    // breathing (voice mode) animations based on current mode.
    _updateBtnUI();
  }

  // ── Shared result sink ────────────────────────────────────────────────
  // All engines feed recognized text here. Centralizes voice-core sentence
  // boundary processing + input update + silence timer reset, so engines only
  // care about *producing* text, not how it's displayed.
  function _emitResult(text) {
    if (!text) return;
    if (typeof processAsrResult !== "undefined") {
      _asrState = processAsrResult(_asrState || createInitialState(), text);
      _updateInput(_asrState.display);
    } else {
      _updateInput(text);
    }
    _resetSilenceTimer();
  }

  // ─────────────────────────────────────────────────────────────────────
  // Engine interface (strategy pattern). Each ASR provider implements:
  //
  //   start()   → Promise<bool>  Acquire mic, begin streaming. Resolves false
  //                              on failure (caller aborts). Stale-result
  //                              guarding via _gen is each engine's concern.
  //   stop()    → void           Stop capture, release all resources, send no
  //                              further results.
  //   onSend()  → void           Called after the user/auto sends. The engine
  //                              decides how to refresh its transcript buffer
  //                              for the next utterance WITHOUT stopping the
  //                              mic. This is where Google vs DashScope differ.
  //
  // Adding a new provider = add one factory function returning this shape.
  // The control flow (start/stop/send/voiceMode) never branches on provider.
  // ─────────────────────────────────────────────────────────────────────

  // ── Google Web Speech engine ──────────────────────────────────────────
  function _createGoogleEngine() {
    let rec = null;

    function _build() {
      const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
      if (!SpeechRecognition) return null;

      const r = new SpeechRecognition();
      r.continuous     = true;
      r.interimResults = true;
      r.lang           = _cfg("language", "zh-CN");

      const myGen = _gen;  // snapshot generation so stale results are ignored

      r.onresult = (event) => {
        if (!_listening) return;     // Ignore late results after stop()
        if (_gen !== myGen) return;  // Stale recognition — generation moved on
        let transcript = "";
        for (let i = 0; i < event.results.length; i++) {
          transcript += event.results[i][0].transcript;
        }
        _emitResult(transcript);
      };

      r.onerror = (event) => {
        if (event.error === "no-speech" || event.error === "aborted") return;
        console.warn("[Voice] Google Speech error:", event.error);
        stop();
      };

      r.onend = () => {
        if (!_listening) return;
        // Google auto-stops after silence; restart if still in voice mode
        if (_voiceMode) {
          _finalizeCurrent();
          setTimeout(() => { if (_voiceMode) start(); }, _cfg("voice_mode_restart_delay_ms", 300));
        } else {
          stop();
        }
      };

      return r;
    }

    return {
      async start() {
        rec = _build();
        if (!rec) {
          console.warn("[Voice] Google Speech Recognition not available in this browser");
          return false;
        }
        rec.start();
        return true;
      },
      stop() {
        if (rec) {
          try { rec.stop(); } catch (_) {}
          rec = null;
        }
      },
      onSend() {
        // Google continuous=true accumulates ALL results across the session,
        // so to clear the transcript buffer we tear down and rebuild a fresh
        // recognition instance. Bump _gen FIRST so the old instance's pending
        // onresult callbacks are discarded; the new instance snapshots the
        // bumped _gen and keeps working normally.
        if (!rec) return;
        _gen++;
        rec.onend = null;
        rec.onresult = null;
        try { rec.stop(); } catch (_) {}
        rec = _build();
        if (rec) rec.start();
      }
    };
  }

  // ── DashScope ASR engine (via backend WebSocket proxy) ────────────────
  function _createDashScopeEngine() {
    let ws        = null;
    let audioCtx  = null;
    let stream    = null;
    let processor = null;
    let taskId    = "";

    function _release() {
      if (processor) { try { processor.disconnect(); } catch (_) {} processor = null; }
      if (audioCtx)  { try { audioCtx.close(); } catch (_) {} audioCtx = null; }
      if (stream)    { stream.getTracks().forEach(t => t.stop()); stream = null; }
    }

    return {
      async start() {
        const myGen = _gen;  // snapshot generation so stale results are ignored

        // 1. Microphone access
        try {
          stream = await navigator.mediaDevices.getUserMedia({
            audio: { sampleRate: 16000, channelCount: 1, echoCancellation: true }
          });
        } catch (err) {
          console.warn("[Voice] Microphone access denied:", err.message);
          return false;
        }

        // 2. Connect to backend ASR proxy
        const wsUrl = ((location.protocol === "https:") ? "wss://" : "ws://") +
                      location.host + "/api/asr/proxy?provider=dashscope";
        ws = new WebSocket(wsUrl);
        taskId = "task-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8);

        const openPromise = new Promise((resolve, reject) => {
          const timeout = setTimeout(() => reject(new Error("DashScope connection timeout")), 5000);
          ws.onopen = () => {
            clearTimeout(timeout);
            const runTask = {
              header: { action: "run-task", task_id: taskId, streaming: "duplex" },
              payload: {
                task_group: "audio",
                task: "asr",
                function: "recognition",
                model: "paraformer-realtime-v2",
                parameters: {
                  format: "pcm",
                  sample_rate: 16000,
                  language_hints: [ (_cfg("language", "zh-CN") || "zh-CN").split("-")[0], "en" ]
                },
                input: {}
              }
            };
            ws.send(JSON.stringify(runTask));
            resolve();
          };
          ws.onerror = () => { clearTimeout(timeout); reject(new Error("WebSocket error")); };
        });

        try {
          await openPromise;
        } catch (err) {
          console.warn("[Voice] DashScope connection failed:", err.message);
          _release();
          if (ws) { try { ws.close(); } catch (_) {} ws = null; }
          return false;
        }

        // 3. Incoming ASR results
        ws.onmessage = (event) => {
          if (!_listening) return;     // Ignore late results after stop()
          if (_gen !== myGen) return;  // Stale recognition — generation moved on
          try {
            const msg = JSON.parse(event.data);
            const action = msg.header && (msg.header.event || msg.header.action);
            if (action === "result-generated") {
              const text = (msg.payload && msg.payload.output && msg.payload.output.sentence && msg.payload.output.sentence.text) || "";
              _emitResult(text);
            } else if (action === "task-failed") {
              console.error("[Voice] DashScope task failed:", (msg.header && msg.header.error_message));
              stop();
            }
          } catch (_) { /* ignore non-JSON */ }
        };

        ws.onclose = (event) => {
          ws = null;
          if (_listening && event.code !== 1000) {
            console.warn("[Voice] DashScope disconnected unexpectedly (code " + event.code + ")");
            stop();
          }
        };

        // 4. Audio capture -> PCM16 -> WebSocket
        audioCtx = new AudioContext({ sampleRate: 16000 });
        const source = audioCtx.createMediaStreamSource(stream);
        processor = audioCtx.createScriptProcessor(4096, 1, 1);
        processor.onaudioprocess = (e) => {
          if (!ws || ws.readyState !== WebSocket.OPEN) return;
          const inputData = e.inputBuffer.getChannelData(0);
          const pcm16 = new Int16Array(inputData.length);
          for (let i = 0; i < inputData.length; i++) {
            const s = Math.max(-1, Math.min(1, inputData[i]));
            pcm16[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
          }
          ws.send(pcm16.buffer);
        };
        source.connect(processor);
        processor.connect(audioCtx.destination);

        return true;
      },
      stop() {
        _release();
        if (ws && ws.readyState === WebSocket.OPEN) {
          try {
            ws.send(JSON.stringify({
              header: { action: "finish-task", task_id: taskId, streaming: "duplex" },
              payload: { input: {} }
            }));
          } catch (_) {}
          try { ws.close(); } catch (_) {}
        }
        ws = null;
        taskId = "";
      },
      onSend() {
        // DashScope uses a SINGLE long-lived WebSocket whose onmessage closure
        // snapshotted myGen at connect time and is never rebuilt. So we must
        // NOT bump _gen here — doing so would make _gen !== myGen permanently
        // true and discard every subsequent result (the "mic lit but dead
        // after first send" bug). Clearing _asrState (done by the caller) is
        // sufficient to drop residual text. Nothing to do here.
      }
    };
  }

  // ── Engine factory (the ONLY place provider is mapped to an engine) ────
  function _createEngine() {
    const provider = _cfg("asr.provider", "google");
    switch (provider) {
      case "dashscope": return _createDashScopeEngine();
      case "google":
      default:          return _createGoogleEngine();
    }
  }

  // ── Input field helpers ───────────────────────────────────────────────
  function _getInput() {
    return document.getElementById("user-input");
  }

  function _updateInput(text) {
    const input = _getInput();
    if (!input) return;
    input.value = text;
    input.dispatchEvent(new Event("input", { bubbles: true }));
  }

  // ── Exit word detection ───────────────────────────────────────────────
  function _isExitCommand(text) {
    const exitWords = _cfg("exit_words", []);
    if (!exitWords.length) return false;
    // DashScope may add punctuation and combine multiple utterances into one
    // sentence (e.g. "拜拜，拜拜。" → split by separators, match each segment).
    const segments = text.split(/[，,、\s]+/);
    return segments.some(seg => {
      const stripped = seg.trim().replace(/^[。！？；：….!?;:]+|[。！？；：…,.!?;:]+$/g, "");
      return exitWords.some(w => stripped === w);
    });
  }

  function _finalizeCurrent() {
    const input = _getInput();
    if (!input || !input.value.trim()) return;
    const text = input.value.trim();

    // Check for exit command
    if (_isExitCommand(text)) {
      _updateInput("");
      // Just stop the mic — don't change voice mode (only manual toggle should)
      stop();
      return;
    }

    // Auto-send in voice mode
    if (_voiceMode) {
      const sendBtn = document.getElementById("btn-send");
      if (sendBtn) sendBtn.click();
    }

    // Reset accumulated ASR state after send to prevent stale text
    // from reappearing in subsequent recognition results.
    _asrState = (typeof createInitialState !== "undefined") ? createInitialState() : null;
  }

  // ── Silence timer ─────────────────────────────────────────────────────
  function _resetSilenceTimer() {
    if (_silenceTimer) clearTimeout(_silenceTimer);
    _silenceTimer = setTimeout(() => {
      if (!_listening) return;
      _finalizeCurrent();
    }, _cfg("silence_timeout_ms", 1500));
  }

  // ── Public API ────────────────────────────────────────────────────────
  async function start() {
    if (_listening) return;

    // Bump generation so any pending/stale callbacks from a previously-stopped
    // recognition are ignored (each engine snapshots _gen at start).
    _gen++;

    // Clear input from previous recording
    _updateInput("");

    // Build the engine for the configured provider and start it. All
    // provider-specific logic lives behind the engine interface — no branching
    // on provider name here.
    _engine = _createEngine();
    const ok = await _engine.start();
    if (!ok) { _engine = null; return; }

    _asrState = (typeof createInitialState !== "undefined") ? createInitialState() : null;

    _listening = true;
    _playSound("start");
    _updateBtnUI();
    _pulse();
    _resetSilenceTimer();
  }

  function stop() {
    if (!_listening) return;
    _listening = false;

    _playSound("stop");
    _updateBtnUI();

    if (_silenceTimer) { clearTimeout(_silenceTimer); _silenceTimer = null; }

    // Finalize any remaining text
    if (_asrState && _asrState.interim) {
      _finalizeCurrent();
    }

    // Stop the active engine (releases all provider resources).
    if (_engine) {
      _engine.stop();
      _engine = null;
    }

    _asrState = null;
  }

  function toggle() {
    _listening ? stop() : start();
    _pulse();
  }

  function setVoiceMode(on) {
    _voiceMode = !!on;

    if (on && !_listening) {
      start();
    } else if (!on && _listening) {
      stop();
    }

    _updateBtnUI();
  }

  function _toggleVoiceMode() {
    setVoiceMode(!_voiceMode);
  }

  // ── Shortcut handling ─────────────────────────────────────────────────
  document.addEventListener("keydown", (e) => {
    // Don't capture when user is typing in an input (except our own textarea)
    if (e.target.tagName === "INPUT" && e.target.id !== "user-input") return;
    if (e.target.tagName === "TEXTAREA" && e.target.id !== "user-input") return;

    const shortcuts = _cfg("shortcuts", null);

    let action = null;
    if (typeof matchVoiceShortcut !== "undefined") {
      action = matchVoiceShortcut(e, shortcuts);
    } else {
      // Fallback inline check (when voice-core.js not loaded)
      if (shortcuts) {
        const MOD_MAP = { Control: "ctrlKey", Shift: "shiftKey", Alt: "altKey", Meta: "metaKey" };
        const k = (e.key || "").toLowerCase();
        for (const [act, sc] of Object.entries(shortcuts)) {
          if (!sc || !sc.key || k !== String(sc.key).toLowerCase()) continue;
          const req = sc.modifiers || [];
          const allMods = ["Control", "Shift", "Alt", "Meta"];
          let match = true;
          for (const mod of allMods) {
            const pressed = !!(e[MOD_MAP[mod]] || false);
            if (pressed !== req.includes(mod)) { match = false; break; }
          }
          if (match) { action = act; break; }
        }
      }
    }

    if (action === "toggle")  { e.preventDefault(); toggle(); }
    else if (action === "stop")   { e.preventDefault(); stop(); }
    else if (action === "start")  { e.preventDefault(); start(); }
    else if (action === "voice_mode") { e.preventDefault(); _toggleVoiceMode(); }
  });

  // ── Initialisation ────────────────────────────────────────────────────
  async function init() {
    await _loadVoiceConfig();
    _createButton();

    // Preload sounds
    _loadSound("start");
    _loadSound("stop");

    // When user clicks Send while recording, ask the active engine to refresh
    // its transcript buffer for the next utterance (without stopping the mic).
    // Each engine decides HOW: Google rebuilds its recognition instance and
    // bumps _gen; DashScope keeps its long-lived WebSocket and does nothing
    // (relying on the _asrState reset below). Same behavior for push-to-talk
    // and voice mode — the only difference is whether _finalizeCurrent
    // auto-sends. Capturing phase ensures this runs before sessions.js's
    // _sendMessage.
    const sendBtn = document.getElementById("btn-send");
    if (sendBtn) {
      sendBtn.addEventListener("click", () => {
        if (!_listening || !_engine) return;
        _engine.onSend();
        _asrState = (typeof createInitialState !== "undefined") ? createInitialState() : null;
      }, true);
    }

    // Restore voice-mode (in-memory only; session-based)
    // If browser extension sets window.__zhuzhu.setVoiceMode, honor it.
    // Otherwise default to off — voice mode is opt-in per session.
  }

  // Wait for DOM
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  // ── Exports ───────────────────────────────────────────────────────────
  return {
    toggle,
    start,
    stop,
    setVoiceMode,
    get listening()  { return _listening; },
    get voiceMode()  { return _voiceMode; }
  };
})();
