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
  let _recognition = null;    // Google SpeechRecognition instance (Google provider)
  let _gen          = 0;      // generation counter — bumped on restart to ignore stale results
  let _dsWs        = null;    // DashScope WebSocket connection
  let _dsAudioCtx  = null;    // DashScope AudioContext
  let _dsStream    = null;    // DashScope MediaStream
  let _dsProcessor = null;    // DashScope ScriptProcessorNode
  let _dsTaskId    = "";      // DashScope task ID
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

  // ── Google Web Speech driver ──────────────────────────────────────────
  function _getGoogleRecognition() {
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognition) return null;

    const rec = new SpeechRecognition();
    rec.continuous   = true;
    rec.interimResults = true;
    rec.lang         = _cfg("language", "zh-CN");

    var myGen = _gen;  // snapshot generation so stale results are ignored

    rec.onresult = (event) => {
      if (!_listening) return;  // Ignore late results after stop()
      if (_gen !== myGen) return; // Stale recognition — generation moved on

      // Build full transcript from all results
      let transcript = "";
      for (let i = 0; i < event.results.length; i++) {
        transcript += event.results[i][0].transcript;
      }

      // Feed through voice-core for sentence boundary detection
      if (typeof processAsrResult !== "undefined") {
        _asrState = processAsrResult(_asrState || createInitialState(), transcript);
        _updateInput(_asrState.display);
      } else {
        _updateInput(transcript);
      }

      _resetSilenceTimer();
    };

    rec.onerror = (event) => {
      if (event.error === "no-speech" || event.error === "aborted") return;
      console.warn("[Voice] Google Speech error:", event.error);
      stop();
    };

    rec.onend = () => {
      if (!_listening) return;
      // Google auto-stops after silence; restart if still in voice mode
      if (_voiceMode) {
        _finalizeCurrent();
        setTimeout(() => { if (_voiceMode) start(); }, _cfg("voice_mode_restart_delay_ms", 300));
      } else {
        stop();
      }
    };

    return rec;
  }

  // ── DashScope ASR driver (via backend WebSocket proxy) ─━��━━━━━━━━━━━━━
  async function _startDashScope() {
    // 1. Request microphone access
    try {
      _dsStream = await navigator.mediaDevices.getUserMedia({
        audio: { sampleRate: 16000, channelCount: 1, echoCancellation: true }
      });
    } catch (err) {
      console.warn("[Voice] Microphone access denied:", err.message);
      return false;
    }

    // 2. Connect to backend ASR proxy
    const wsUrl = ((location.protocol === "https:") ? "wss://" : "ws://") +
                  location.host + "/api/asr/proxy?provider=dashscope";
    _dsWs = new WebSocket(wsUrl);
    _dsTaskId = "task-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8);

    const openPromise = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error("DashScope connection timeout"));
      }, 5000);

      _dsWs.onopen = () => {
        clearTimeout(timeout);
        // Send run-task message
        const runTask = {
          header: { action: "run-task", task_id: _dsTaskId, streaming: "duplex" },
          payload: {
            task_group: "audio",
            task: "asr",
            function: "recognition",
            model: "paraformer-realtime-v2",
            parameters: {
              format: "pcm",
              sample_rate: 16000,
              language_hints: [ (_cfg("language", "zh-CN") || "zh-CN").split("-")[0] ]
            }
          }
        };
        _dsWs.send(JSON.stringify(runTask));
        resolve();
      };

      _dsWs.onerror = () => {
        clearTimeout(timeout);
        reject(new Error("WebSocket error"));
      };
    });

    try {
      await openPromise;
    } catch (err) {
      console.warn("[Voice] DashScope connection failed:", err.message);
      _cleanupDashScope();
      return false;
    }

    // 3. Handle incoming ASR results
    _dsWs.onmessage = (event) => {
      if (!_listening) return;  // Ignore late results after stop()

      try {
        const msg = JSON.parse(event.data);
        const action = msg.header && (msg.header.event || msg.header.action);

        if (action === "result-generated") {
          const text = (msg.payload && msg.payload.output && msg.payload.output.sentence && msg.payload.output.sentence.text) || "";
          if (!text) return;

          // Feed through voice-core for sentence boundary detection
          if (typeof processAsrResult !== "undefined") {
            _asrState = processAsrResult(_asrState || createInitialState(), text);
            _updateInput(_asrState.display);
          } else {
            _updateInput(text);
          }

          _resetSilenceTimer();
        } else if (action === "task-failed") {
          console.error("[Voice] DashScope task failed:", (msg.header && msg.header.error_message));
          Voice.stop();
        }
      } catch (_) {
        // Ignore parse errors on non-JSON messages
      }
    };

    _dsWs.onclose = (event) => {
      _dsWs = null;
      if (_listening && event.code !== 1000) {
        console.warn("[Voice] DashScope disconnected unexpectedly (code " + event.code + ")");
        Voice.stop();
      }
    };

    // 4. Start audio capture -> PCM16 -> WebSocket
    _dsAudioCtx = new AudioContext({ sampleRate: 16000 });
    var source = _dsAudioCtx.createMediaStreamSource(_dsStream);
    _dsProcessor = _dsAudioCtx.createScriptProcessor(4096, 1, 1);

    _dsProcessor.onaudioprocess = function(e) {
      if (!_dsWs || _dsWs.readyState !== WebSocket.OPEN) return;
      var inputData = e.inputBuffer.getChannelData(0);
      var pcm16 = new Int16Array(inputData.length);
      for (var i = 0; i < inputData.length; i++) {
        var s = Math.max(-1, Math.min(1, inputData[i]));
        pcm16[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
      }
      _dsWs.send(pcm16.buffer);
    };

    source.connect(_dsProcessor);
    _dsProcessor.connect(_dsAudioCtx.destination);

    return true;
  }

  function _stopDashScope() {
    // Stop audio capture
    if (_dsProcessor) {
      try { _dsProcessor.disconnect(); } catch (_) {}
      _dsProcessor = null;
    }
    if (_dsAudioCtx) {
      try { _dsAudioCtx.close(); } catch (_) {}
      _dsAudioCtx = null;
    }
    if (_dsStream) {
      _dsStream.getTracks().forEach(function(t) { t.stop(); });
      _dsStream = null;
    }

    // Send finish-task and close WebSocket
    if (_dsWs && _dsWs.readyState === WebSocket.OPEN) {
      try {
        var finishMsg = {
          header: { action: "finish-task", task_id: _dsTaskId, streaming: "duplex" },
          payload: { input: {} }
        };
        _dsWs.send(JSON.stringify(finishMsg));
      } catch (_) {}
      try { _dsWs.close(); } catch (_) {}
    }
    _dsWs = null;
    _dsTaskId = "";
  }

  function _cleanupDashScope() {
    _stopDashScope();
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
    const trimmed = text.trim();
    return exitWords.some(w => trimmed === w);
  }

  function _finalizeCurrent() {
    const input = _getInput();
    if (!input || !input.value.trim()) return;
    const text = input.value.trim();

    // Check for exit command
    if (_isExitCommand(text)) {
      _updateInput("");
      stop();
      setVoiceMode(false);
      return;
    }

    // Auto-send in voice mode
    if (_voiceMode) {
      const sendBtn = document.getElementById("btn-send");
      if (sendBtn) sendBtn.click();
    }
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

    // Clear input from previous recording
    _updateInput("");

    var provider = _cfg("asr.provider", "google");

    if (provider === "dashscope") {
      var ok = await _startDashScope();
      if (!ok) return;
    } else {
      // Google Web Speech (default)
      var rec = _getGoogleRecognition();
      if (!rec) {
        console.warn("[Voice] Google Speech Recognition not available in this browser");
        return;
      }
      _recognition = rec;
      _recognition.start();
    }

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

    // Stop ASR engine (provider-specific)
    if (_recognition) {
      try { _recognition.stop(); } catch (_) {}
      _recognition = null;
    }
    if (_dsWs) {
      _stopDashScope();
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
          if (!sc || !sc.key || k !== sc.key.toLowerCase()) continue;
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

    // When user clicks send in push-to-talk mode, restart the recognition
    // instance to get a fresh transcript buffer (Google continuous=true
    // accumulates all results across the session; restarting gives a clean
    // slate without stopping the mic).  Capturing phase ensures this runs
    // before sessions.js's _sendMessage.
    const sendBtn = document.getElementById("btn-send");
    if (sendBtn) {
      sendBtn.addEventListener("click", () => {
        if (!_listening || !_recognition) return;
        // Bump generation to invalidate pending/stale onresult callbacks
        // from the current recognition, then restart a fresh session.
        _gen++;
        _recognition.onend = null;
        _recognition.onresult = null;
        try { _recognition.stop(); } catch (_) {}
        _recognition = null;
        var newRec = _getGoogleRecognition();
        if (newRec) {
          _recognition = newRec;
          _asrState = (typeof createInitialState !== "undefined") ? createInitialState() : null;
          _recognition.start();
        }
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
