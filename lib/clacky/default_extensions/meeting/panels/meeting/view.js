// Meeting Mode — WebUI Extension
// Records audio, transcribes via STT, displays live captions,
// detects wake words to trigger agent, and runs background annotations.

(function () {
  const ANNOTATE_INTERVAL_MS = 120000;
  // error_type the meeting API returns when the active model provider has no
  // speech-to-text model — a settings gap the user can close in one click.
  const STT_NOT_CONFIGURED = "stt_not_configured";
  // Wake phrases must be "greeting + name", never a bare product word.
  // Bare "clacky" / "小克" are too easily tripped by casual mentions of the
  // brand or STT hallucinations pulled from the meeting vocabulary.
  // Reduplicated Chinese calls ("小克小克", "克拉奇克拉奇") are natural
  // attention-getters and count as wake too.
  const WAKE_PATTERNS = [
    /@clacky\b/i,
    /\b(hey|hi|hello|ok|okay|yo)[\s,，]+clacky\b/i,
    /(你好|嘿|喂|哎|请问)[\s,，]*小[克客可刻课氪]/,
    /(你好|嘿|喂|哎|请问)[\s,，]*克拉奇/,
    /小[克客可刻课氪][\s,，]*小[克客可刻课氪]/,
    /克拉奇[\s,，]*克拉奇/,
  ];
  const WAKE_STRIP = [
    /@clacky/gi,
    /\b(hey|hi|hello|ok|okay|yo)[\s,，]+clacky\b/gi,
    /(你好|嘿|喂|哎|请问)[\s,，]*小[克客可刻课氪]/g,
    /(你好|嘿|喂|哎|请问)[\s,，]*克拉奇/g,
    /小[克客可刻课氪][\s,，]*小[克客可刻课氪]/g,
    /克拉奇[\s,，]*克拉奇/g,
  ];

  // Self-contained i18n: extensions can't register keys into the host I18n
  // dictionary, so we keep our own table and pick the language via I18n.lang().
  const MEETING_I18N = {
    en: {
      "tab.label": "Meeting Assistant",
      "btn.start": "Start Recording",
      "btn.stop": "Summarize Notes",
      "btn.resume": "Resume Recording",
      "btn.starting": "Starting…",
      "btn.resuming": "Reconnecting…",
      "btn.mute": "Mute",
      "btn.unmute": "Unmute",
      "btn.mute.hint": "Temporarily stop recording (mic off)",
      "btn.silence": "Stop Voice",
      "btn.silence.hint": "Stop the current voice playback",
      "btn.interrupt": "Interrupt",
      "btn.interrupt.hint": "Cancel the current answer",
      "btn.cancel": "Discard",
      "btn.cancel.hint": "Discard this recording without generating notes",
      "hint.wake": 'Say "Hey Clacky" or "@clacky" to ask a question during the meeting.',
      "hero.title": "Meeting Assistant",
      "hero.desc": "Live captions while you talk; notes are summarized when the meeting ends.",
      "hero.resumeTitle": "Meeting in progress",
      "vocab.desc": "Names, products and jargon here are recognized more accurately.",
      "hint.resume": "Resume recording to continue (microphone access required again).",
      "status.recording": "Recording",
      "status.transcribing": "Transcribing…",
      "status.listening": "Listening… ({{n}}s)",
      "status.thinking": "Thinking…",
      "status.speaking": "Playing…",
      "status.muted": "Muted",
      "vocab.label": "Meeting vocabulary (proper nouns)",
      "vocab.placeholder": "Type a term, press Enter",
      "vocab.save": "Save vocabulary",
      "vocab.saved": "Saved",
      "vocab.saveFailed": "Save failed",
      "annotations.title": "Annotations",
      "captions.title": "Live captions",
      "anno.decision": "Decision",
      "anno.action": "To-do",
      "anno.question": "Question",
      "captions.empty": "Waiting for speech…",
      "annotations.empty": "Decisions and to-dos are picked out every 2 minutes",
      "stt.failed": "⚠ Transcription failed: {{msg}}",
      "stt.notConfigured": "No speech-to-text model yet, so this recording can't be transcribed.",
      "stt.goSettings": "Open settings",
      "alert.noSession": "No active session",
      "alert.startFailed": "Failed to start meeting: {{msg}}",
      "end.displayMessage": "🛑 Meeting ended — generating meeting minutes…",
      "alert.cancelConfirm": "Discard this recording? The transcript will not be summarized.",
      "end.cancelled": "Recording discarded",
    },
    zh: {
      "tab.label": "会议助理",
      "btn.start": "开始记录",
      "btn.stop": "总结记录",
      "btn.resume": "继续录音",
      "btn.starting": "正在启动…",
      "btn.resuming": "正在恢复…",
      "btn.mute": "静音",
      "btn.unmute": "解除静音",
      "btn.mute.hint": "临时暂停录音（关闭麦克风）",
      "btn.silence": "停止播报",
      "btn.silence.hint": "停止当前语音播放",
      "btn.interrupt": "打断",
      "btn.interrupt.hint": "取消当前回答",
      "btn.cancel": "取消",
      "btn.cancel.hint": "放弃这次录音，不生成纪要",
      "hint.wake": "会议中说「你好小克」「小克小克」或「@clacky」即可向我提问。",
      "hero.title": "会议助理",
      "hero.desc": "边开会边出字幕，会议结束后自动整理成纪要。",
      "hero.resumeTitle": "会议仍在进行中",
      "vocab.desc": "人名、产品名、行业术语加在这里，识别会更准确。",
      "hint.resume": "点击「继续录音」接着记录（需要重新授权麦克风）。",
      "status.recording": "录音中",
      "status.transcribing": "识别中…",
      "status.listening": "正在听你说…（{{n}}s）",
      "status.thinking": "思考中…",
      "status.speaking": "播放中…",
      "status.muted": "已静音",
      "vocab.label": "会议词汇（专有名词）",
      "vocab.placeholder": "输入词汇后回车添加",
      "vocab.save": "保存词汇",
      "vocab.saved": "已保存",
      "vocab.saveFailed": "保存失败",
      "annotations.title": "标注",
      "captions.title": "实时字幕",
      "anno.decision": "决策",
      "anno.action": "待办",
      "anno.question": "问题",
      "captions.empty": "正在等待发言…",
      "annotations.empty": "每 2 分钟自动提取决策和待办",
      "stt.failed": "⚠ 识别失败：{{msg}}",
      "stt.notConfigured": "还没有配置语音识别模型，无法转写录音。",
      "stt.goSettings": "去设置",
      "alert.noSession": "没有进行中的会话",
      "alert.startFailed": "开启会议失败：{{msg}}",
      "end.displayMessage": "🛑 会议结束 — 正在生成会议纪要…",
      "alert.cancelConfirm": "取消后这次录音会被丢弃，不会生成纪要。确定取消吗？",
      "end.cancelled": "已丢弃这次录音",
    },
  };

  function t(key, vars) {
    const lang = (typeof I18n !== "undefined" && I18n.lang && I18n.lang()) || "en";
    const dict = MEETING_I18N[lang] || MEETING_I18N.en;
    let str = dict[key] != null ? dict[key] : (MEETING_I18N.en[key] != null ? MEETING_I18N.en[key] : key);
    if (vars) Object.keys(vars).forEach((k) => { str = str.split("{{" + k + "}}").join(vars[k]); });
    return str;
  }

  // ── Layer 1: module-level (page lifetime) ────────────────────────────
  // A registry of all live meeting sessions on this page so the module-level
  // `session:assistant-message` subscription and the `langchange` listener
  // can dispatch to whichever session the event is about, without any of
  // them holding a reference to the module `state` (there is no module state).
  const _sessionsById = new Map();

  // When the agent produces a reply during meeting mode we dispatch it to the
  // matching per-session runtime — every session's meeting has its own
  // "expecting speech" flag and its own audio player.
  Clacky.ext.subscribe("session:assistant-message", function (payload) {
    const sess = payload && payload.sessionId && _sessionsById.get(payload.sessionId);
    if (sess) sess.onAssistantMessage(payload);
  });

  // Re-render every live meeting on language switch so labels follow the
  // host language.
  document.addEventListener("langchange", function () {
    _sessionsById.forEach((sess) => sess.rerender());
  });

  // ── Layer 2/3: per-session runtime ──────────────────────────────────
  // Everything below is instantiated fresh by `create(ctx)` each time a
  // session shows the meeting tab for the first time; state stays alive
  // until the session leaves the sidebar (or the page unloads).
  function createMeetingSession(ctx) {

  // VAD (voice activity detection) — slice on natural speech pauses instead
  // of a fixed timer, so a sentence is never cut mid-word.
  //
  // The cutoff is relative to a running estimate of the room's noise floor: a
  // fixed RMS value bakes in one microphone gain, and laptop mics differ by
  // 20 dB or more. VAD_MIN_RMS is only the floor for a digitally silent room.
  const VAD_TICK_MS = 50;               // analyser poll interval
  const VAD_MIN_RMS = 0.004;            // never treat anything quieter as speech
  const VAD_NOISE_FACTOR = 3.0;         // speech must clear the floor by 3x
  const VAD_SILENCE_HOLD_MS = 600;      // pause this long => end of utterance
  const VAD_MIN_SPEECH_MS = 500;        // ignore utterances shorter than this
  const VAD_MIN_SPEECH_TICKS = 8;       // ≈400ms of real speech energy required
  // Only a backstop: normal sentences end on the 600ms silence hold long
  // before this. Cutting mid-sentence loses words and reads badly, and
  // DeepSeek takes up to 120s (8MiB) per chunk, so keep the ceiling high.
  const VAD_MAX_SEGMENT_MS = 30000;     // force-cut a very long monologue

  let state = {
    active: false,
    sessionId: ctx.sessionId,
    meetingId: null,
    mediaRecorder: null,
    annotateTimer: null,
    transcripts: [],
    annotations: [],
    sttError: null,
    audioCtx: null,
    vadTimer: null,
    stream: null,
    vocabulary: "",
    conversationUntil: 0,
    expectingSpeech: false,
    asking: false,
    phase: "idle", // idle | listening | transcribing | conversation | thinking | speaking
    phaseTimer: null,
    transcribing: 0, // count of in-flight STT requests
    container: null,
    resumable: false,
    startedAt: 0,
    micMuted: false,
    ttsAudio: null,
  };

  function apiUrl(path) {
    return `/api/ext/meeting${path}`;
  }

  async function postJson(path, body) {
    const res = await fetch(apiUrl(path), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok) {
      const err = new Error(data.error || `Request failed (${res.status})`);
      err.code = data.error_type || null;
      throw err;
    }
    return data;
  }

  function currentSessionId() {
    return state.sessionId || (window.Clacky && Clacky.ext && Clacky.ext.context.sessionId) || null;
  }

  // After a page refresh the browser forgets everything but the backend still
  // has the meeting. Probe for it and, if found, restore captions and offer a
  // "Resume Recording" button (mic access can't survive a refresh).
  async function probeActiveMeeting(container) {
    const sessionId = currentSessionId();
    if (!sessionId || state.active) return;
    try {
      const res = await fetch(apiUrl("/active/" + encodeURIComponent(sessionId)));
      const data = await res.json();
      if (!data || !data.active) return;
      state.sessionId = sessionId;
      state.meetingId = data.meeting_id;
      state.resumable = true;
      state.transcripts = (data.transcript || []).map((e) => ({
        ts: e.ts ? Date.parse(e.ts) || Date.now() : Date.now(),
        text: String(e.text || "").trim(),
      })).filter((e) => e.text);
    } catch (_e) {
      // probing is best-effort; ignore failures
    }
    renderUI(container);
  }

  // Tap → mic permission → server round trip can take a second or two, so the
  // start button shows a spinner instead of looking dead.
  function setStartBtnBusy(btn, busy, label) {
    if (!btn) return;
    btn.disabled = busy;
    btn.classList.toggle("is-busy", busy);
    btn.innerHTML = (busy ? SPINNER_SVG : MIC_SVG) + "<span></span>";
    btn.querySelector("span").textContent = label;
  }

  async function startMeeting(container, btn) {
    const sessionId = currentSessionId();
    if (!sessionId) {
      alert(t("alert.noSession"));
      return;
    }

    const idleLabel = state.resumable ? t("btn.resume") : t("btn.start");
    setStartBtnBusy(btn, true, t(state.resumable ? "btn.resuming" : "btn.starting"));

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
          channelCount: 1,
        },
      });
      // Resuming an in-progress meeting (after a page refresh): keep the
      // existing meeting_id so new captions append to the same transcript.
      if (!(state.resumable && state.meetingId)) {
        const data = await postJson("/start", { session_id: sessionId });
        state.meetingId = data.meeting_id;
      }
      state.active = true;
      state.sessionId = sessionId;
      // Resumed meetings count from the first caption we still have.
      state.startedAt = (state.resumable && state.transcripts.length && state.transcripts[0].ts) || Date.now();
      state.resumable = false;
      state.stream = stream;

      startVadRecording(stream);

      state.annotateTimer = setInterval(() => runAnnotate(), ANNOTATE_INTERVAL_MS);

      renderUI(container);
    } catch (err) {
      console.error("[meeting] start failed:", err);
      setStartBtnBusy(btn, false, idleLabel);
      alert(t("alert.startFailed", { msg: err.message }));
    }
  }

  // Records continuously and cuts a segment only when speech is followed by a
  // sustained pause (or the segment grows too long). Each segment is a fresh,
  // self-contained webm so the STT backend can always decode it.
  function startVadRecording(stream) {
    const mime = getSupportedMime();
    const AudioCtx = window.AudioContext || window.webkitAudioContext;
    const audioCtx = new AudioCtx();
    state.audioCtx = audioCtx;
    // We only get here after two awaits (mic permission + /start), so the
    // context can come up suspended even though the click was a gesture. A
    // suspended context still feeds the MediaRecorder but leaves the analyser
    // reporting pure silence, which reads as "user never spoke".
    if (audioCtx.state === "suspended") {
      audioCtx.resume().catch((e) => console.warn("[meeting] audioCtx.resume failed:", e));
    }
    const source = audioCtx.createMediaStreamSource(stream);
    const analyser = audioCtx.createAnalyser();
    analyser.fftSize = 1024;
    source.connect(analyser);
    const buf = new Float32Array(analyser.fftSize);

    let recorder = null;
    let chunks = [];
    let hadSpeech = false;
    let speechTicks = 0;
    let noiseFloor = 0.002;
    let segmentStart = 0;
    let silenceStart = 0;

    function newRecorder() {
      const r = new MediaRecorder(stream, mime ? { mimeType: mime } : {});
      chunks = [];
      hadSpeech = false;
      speechTicks = 0;
      segmentStart = performance.now();
      silenceStart = 0;
      r.ondataavailable = (e) => { if (e.data && e.data.size > 0) chunks.push(e.data); };
      r.onstop = () => {
        const captured = chunks;
        const spoke = speechTicks >= VAD_MIN_SPEECH_TICKS;
        const dur = performance.now() - segmentStart;
        if (state.active) newRecorder();
        // Once the meeting is torn down the transcript is already cleared, so
        // a tail segment must not be shipped to STT.
        if (state.active && spoke && dur >= VAD_MIN_SPEECH_MS && captured.length) {
          sendAudioChunk(new Blob(captured, mime ? { type: mime } : {}));
        }
      };
      r.start(200); // emit chunks every 200ms so a cut loses nothing
      recorder = r;
      state.mediaRecorder = r;
    }

    function rms() {
      analyser.getFloatTimeDomainData(buf);
      let sum = 0;
      for (let i = 0; i < buf.length; i++) sum += buf[i] * buf[i];
      return Math.sqrt(sum / buf.length);
    }

    function tick() {
      if (!state.active) return;
      const now = performance.now();
      const level = rms();

      // Fast down, slow up: a quiet gap drops the floor immediately while
      // speech lifts it only slightly, so it settles on the background level
      // instead of chasing the speaker.
      noiseFloor += (level - noiseFloor) * (level < noiseFloor ? 0.25 : 0.002);
      const threshold = Math.max(VAD_MIN_RMS, noiseFloor * VAD_NOISE_FACTOR);

      if (level >= threshold) {
        speechTicks++;
        hadSpeech = true;
        silenceStart = 0;
      } else if (hadSpeech) {
        if (silenceStart === 0) silenceStart = now;
        else if (now - silenceStart >= VAD_SILENCE_HOLD_MS) {
          if (recorder.state === "recording") recorder.stop();
        }
      }

      if (now - segmentStart >= VAD_MAX_SEGMENT_MS && recorder.state === "recording") {
        recorder.stop();
      }
    }

    newRecorder();
    // setInterval, not requestAnimationFrame: rAF stops firing while the tab
    // is hidden or the window is fully covered — exactly when a meeting runs —
    // which would leave the recorder on one endless segment.
    if (state.vadTimer) clearInterval(state.vadTimer);
    state.vadTimer = setInterval(tick, VAD_TICK_MS);
  }

  // Releases the microphone and forgets everything about the live meeting.
  // Shared by "summarize" and "discard" — the difference is only whether /end
  // (generate notes) or /cancel (throw the transcript away) gets called.
  async function teardownRecording() {
    state.active = false;
    if (state.vadTimer) clearInterval(state.vadTimer);
    if (state.mediaRecorder && state.mediaRecorder.state !== "inactive") {
      state.mediaRecorder.stop();
    }
    if (state.stream) {
      state.stream.getTracks().forEach((t) => t.stop());
    }
    if (state.audioCtx) {
      try { await state.audioCtx.close(); } catch (_) {}
    }
    clearInterval(state.annotateTimer);

    state.mediaRecorder = null;
    state.annotateTimer = null;
    state.transcripts = [];
    state.annotations = [];
    state.sttError = null;
    state.audioCtx = null;
    state.vadTimer = null;
    state.stream = null;
    state.conversationUntil = 0;
    state.expectingSpeech = false;
    state.asking = false;
    state.startedAt = 0;
    state.transcribing = 0;
    state.resumable = false;
    stopStatusTicker();
  }

  async function stopMeeting(container) {
    const sid = state.sessionId;
    const mid = state.meetingId;
    await teardownRecording();

    try {
      await postJson("/end", {
        session_id: sid,
        meeting_id: mid,
        display_message: t("end.displayMessage"),
      });
    } catch (err) {
      console.error("[meeting] end failed:", err);
    }

    renderUI(container);
  }

  async function cancelMeeting(container) {
    const message = t("alert.cancelConfirm");
    const ok = window.Clacky && Clacky.Modal && Clacky.Modal.confirm
      ? await Clacky.Modal.confirm(message)
      : window.confirm(message);
    if (!ok) return;

    const sid = state.sessionId;
    const mid = state.meetingId;
    await teardownRecording();

    try {
      await postJson("/cancel", { session_id: sid, meeting_id: mid });
    } catch (err) {
      console.error("[meeting] cancel failed:", err);
    }
    state.meetingId = null;

    if (window.Clacky && Clacky.Modal && Clacky.Modal.toast) Clacky.Modal.toast(t("end.cancelled"), "info");
    renderUI(container);
  }

  const MIN_AUDIO_BYTES = 2000; // drop near-empty blobs before hitting STT
  const WAV_SAMPLE_RATE = 16000;

  // DeepSeek ASR decodes only 16 kHz PCM WAV / Ogg Opus, and browsers record
  // webm/opus (Chrome) or mp4/aac (Safari) — neither is accepted. Decoding
  // through Web Audio covers both, so one path serves every browser.
  let transcodeCtx = null;

  async function toWav16k(blob) {
    try {
      if (!transcodeCtx) transcodeCtx = new (window.AudioContext || window.webkitAudioContext)();
      const decoded = await transcodeCtx.decodeAudioData(await blob.arrayBuffer());
      const frames = Math.ceil(decoded.duration * WAV_SAMPLE_RATE);
      if (!frames) return null;

      const offline = new OfflineAudioContext(1, frames, WAV_SAMPLE_RATE);
      const source = offline.createBufferSource();
      source.buffer = decoded;
      source.connect(offline.destination);
      source.start();
      const pcm = (await offline.startRendering()).getChannelData(0);

      const buffer = new ArrayBuffer(44 + pcm.length * 2);
      const view = new DataView(buffer);
      const writeTag = (offset, tag) => {
        for (let i = 0; i < tag.length; i++) view.setUint8(offset + i, tag.charCodeAt(i));
      };
      writeTag(0, "RIFF");
      view.setUint32(4, 36 + pcm.length * 2, true);
      writeTag(8, "WAVE");
      writeTag(12, "fmt ");
      view.setUint32(16, 16, true);
      view.setUint16(20, 1, true); // PCM
      view.setUint16(22, 1, true); // mono
      view.setUint32(24, WAV_SAMPLE_RATE, true);
      view.setUint32(28, WAV_SAMPLE_RATE * 2, true);
      view.setUint16(32, 2, true);
      view.setUint16(34, 16, true);
      writeTag(36, "data");
      view.setUint32(40, pcm.length * 2, true);
      for (let i = 0, offset = 44; i < pcm.length; i++, offset += 2) {
        const s = Math.max(-1, Math.min(1, pcm[i]));
        view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
      }
      return new Blob([buffer], { type: "audio/wav" });
    } catch (err) {
      // Keep the original container: the gateway falls back to Gemini for it.
      console.warn("[meeting] wav transcode failed, sending original:", err);
      return null;
    }
  }

  async function sendAudioChunk(blob) {
    // teardownRecording() stops the recorder, which still fires a last onstop.
    if (!state.active) return;
    if (state.micMuted) return;
    if (!blob || blob.size < MIN_AUDIO_BYTES) return; // too little audio to be speech

    const wav = await toWav16k(blob);
    if (!state.active || state.micMuted) return;
    const payload = wav || blob;
    const mimeType = wav ? "audio/wav" : blob.type;

    const buf = await payload.arrayBuffer();
    const bytes = new Uint8Array(buf);
    let binary = "";
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    const base64 = btoa(binary);

    // A cancel or restart while STT is running must not leak into the new round.
    const meetingId = state.meetingId;
    const stale = () => state.meetingId !== meetingId;

    state.transcribing++;
    updateStatus();
    try {
      const result = await postJson("/transcribe", {
        session_id: state.sessionId,
        meeting_id: meetingId,
        audio_base64: base64,
        mime_type: mimeType,
        vocabulary: state.vocabulary,
      });
      if (stale()) return;

      if (result.text && result.text.trim()) {
        const entry = { ts: Date.now(), text: result.text.trim() };
        state.transcripts.push(entry);
        checkWakeWord(entry.text);
        updateCaptions();
      }
      if (state.sttError) {
        state.sttError = null;
        updateSttError();
      }
    } catch (e) {
      if (stale()) return;
      console.error("STT failed:", e.message);
      state.sttError = { code: e.code || null, message: e.message };
      updateSttError();
    } finally {
      if (!stale()) {
        state.transcribing = Math.max(0, state.transcribing - 1);
        updateStatus();
      }
    }
  }

  const CONVERSATION_WINDOW_MS = 30000; // after a wake word, keep listening this long without re-triggering
  const MIN_QUESTION_CHARS = 4;
  const WAKE_ONLY_TAIL = /^\s*[?？!！。.,，]?\s*$/;

  function stripWake(text) {
    let out = text;
    for (const re of WAKE_STRIP) out = out.replace(re, " ");
    return out.replace(/[\s\p{P}]+/gu, " ").trim();
  }

  function checkWakeWord(text) {
    const triggered = WAKE_PATTERNS.some((p) => p.test(text));
    const inConversation = state.conversationUntil && Date.now() < state.conversationUntil;

    if (!triggered && !inConversation) return;

    const question = stripWake(text);
    // Wake phrase alone (no real question in the same segment): arm listening
    // but don't dispatch — the next segment will be treated as the question.
    if (triggered && WAKE_ONLY_TAIL.test(question.replace(/[\s\p{P}]/gu, ""))) {
      state.conversationUntil = Date.now() + CONVERSATION_WINDOW_MS;
      state.expectingSpeech = true;
      return;
    }
    const meaningful = question.replace(/[^\p{L}\p{N}]/gu, "");
    if (meaningful.length < MIN_QUESTION_CHARS) return;

    state.conversationUntil = Date.now() + CONVERSATION_WINDOW_MS;
    state.expectingSpeech = true;
    // A new question supersedes any in-flight answer: stop the current TTS
    // playback right away; the backend `/ask` handler will interrupt the
    // running agent turn before submitting the new one.
    stopTts();
    state.asking = true;
    postJson("/ask", {
      session_id: state.sessionId,
      meeting_id: state.meetingId,
      question: question,
    }).catch((e) => {
      state.asking = false;
      console.error("[meeting] ask failed:", e.message);
    });
  }

  async function runAnnotate() {
    if (!state.active) return;
    try {
      const result = await postJson("/annotate", {
        session_id: state.sessionId,
        meeting_id: state.meetingId,
      });
      if (result.annotations && result.annotations.length > 0) {
        state.annotations.push(...result.annotations);
        updateAnnotations();
      }
    } catch (_) {}
  }

  // Single source of truth for the header status line. Priority high→low:
  // speaking > thinking > conversation(countdown) > transcribing > listening.
  function updateStatus() {
    const el = document.getElementById("meeting-status");
    if (!el) { updateControls(); return; }
    const now = Date.now();
    const inConversation = state.conversationUntil && now < state.conversationUntil;
    let text, cls;
    if (state.micMuted) {
      text = t("status.muted");
      cls = "muted";
    } else if (state.phase === "speaking") {
      text = t("status.speaking");
      cls = "speaking";
    } else if (state.asking) {
      text = t("status.thinking");
      cls = "thinking";
    } else if (inConversation) {
      const left = Math.ceil((state.conversationUntil - now) / 1000);
      text = t("status.listening", { n: left });
      cls = "listening";
    } else if (state.transcribing > 0) {
      text = t("status.transcribing");
      cls = "transcribing";
    } else {
      text = t("status.recording");
      cls = "recording";
    }
    el.textContent = text;
    const bar = el.closest(".meeting-bar");
    if (bar) bar.dataset.state = cls;
    const clock = document.getElementById("meeting-clock");
    if (clock && state.startedAt) clock.textContent = fmtClock(now - state.startedAt);
    updateControls();
  }

  function fmtClock(ms) {
    const sec = Math.max(0, Math.floor(ms / 1000));
    const h = Math.floor(sec / 3600);
    const mm = String(Math.floor((sec % 3600) / 60)).padStart(2, "0");
    const ss = String(sec % 60).padStart(2, "0");
    return h ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
  }

  function startStatusTicker() {
    stopStatusTicker();
    updateStatus();
    state.phaseTimer = setInterval(updateStatus, 500);
  }

  function stopStatusTicker() {
    if (state.phaseTimer) {
      clearInterval(state.phaseTimer);
      state.phaseTimer = null;
    }
  }

  // Lands on the exact row that fixes it (Settings → Models → Speech-to-Text)
  // instead of the top of the settings page; the row keeps a short outline so
  // the eye finds it after the tab renders.
  function openSttSettings() {
    location.hash = "#settings";
    let tries = 0;
    let tabClicked = false;
    const attempt = () => {
      tries += 1;
      const tab = document.querySelector('#settings-tabs .settings-tab[data-tab="models"]');
      if (tab && !tabClicked) {
        tab.click();
        tabClicked = true;
      }
      const row = document.querySelector('#media-rows .media-row[data-kind="stt"]');
      if (row) {
        row.scrollIntoView({ block: "center", behavior: "smooth" });
        row.classList.add("is-flash");
        setTimeout(() => row.classList.remove("is-flash"), 1800);
        return;
      }
      if (tries < 40) setTimeout(attempt, 100);
    };
    attempt();
  }

  function updateSttError() {
    const el = document.getElementById("meeting-stt-error");
    if (!el) return;
    const err = state.sttError;
    if (!err) {
      el.textContent = "";
      el.dataset.sig = "";
      el.style.display = "none";
      el.classList.remove("is-actionable");
      return;
    }
    // Failing every segment (~10s) must not rebuild the block under the
    // pointer: the same message stays put.
    const sig = err.code === STT_NOT_CONFIGURED ? err.code : "msg:" + err.message;
    if (el.dataset.sig === sig && el.style.display !== "none") return;
    el.dataset.sig = sig;
    el.innerHTML = "";
    el.style.display = "";
    el.classList.toggle("is-actionable", err.code === STT_NOT_CONFIGURED);

    if (err.code === STT_NOT_CONFIGURED) {
      const text = document.createElement("span");
      text.textContent = t("stt.notConfigured");
      const action = document.createElement("button");
      action.type = "button";
      action.className = "meeting-stt-error-action";
      action.textContent = t("stt.goSettings");
      action.addEventListener("click", openSttSettings);
      el.append(text, action);
      return;
    }

    el.textContent = t("stt.failed", { msg: err.message });
  }

  function updateCaptions() {
    const el = document.getElementById("meeting-captions");
    if (!el) return;
    const recent = state.transcripts.slice(-20);
    if (!recent.length) {
      el.innerHTML = `<div class="meeting-empty"><span class="meeting-wave"><i></i><i></i><i></i><i></i></span>${escHtml(t("captions.empty"))}</div>`;
      return;
    }
    el.innerHTML = recent
      .map((c) => {
        const time = new Date(c.ts).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
        return `<div class="meeting-caption"><span class="meeting-ts">${time}</span><span class="meeting-caption-text">${escHtml(c.text)}</span></div>`;
      })
      .join("");
    const count = document.getElementById("meeting-captions-count");
    if (count) count.textContent = state.transcripts.length || "";
    el.scrollTop = el.scrollHeight;
  }

  function updateAnnotations() {
    const el = document.getElementById("meeting-annotations");
    if (!el) return;
    const recent = state.annotations.slice(-10);
    if (!recent.length) {
      el.innerHTML = `<div class="meeting-empty">${escHtml(t("annotations.empty"))}</div>`;
      return;
    }
    el.innerHTML = recent
      .map((a) => {
        const type = ["decision", "action"].includes(a.type) ? a.type : "question";
        return `<div class="meeting-annotation"><span class="meeting-anno-tag meeting-anno-${type}">${escHtml(t("anno." + type))}</span><span>${escHtml(a.text)}</span></div>`;
      })
      .join("");
  }

  const svg = (body, size) =>
    `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" ` +
    `stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
  const MIC_SVG = svg('<path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" x2="12" y1="19" y2="22"/>', 18);
  const CHAT_SVG = svg('<path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/>', 14);
  const MICOFF_SVG = svg('<line x1="2" x2="22" y1="2" y2="22"/><path d="M18.89 13.23A7.12 7.12 0 0 0 19 12v-2"/><path d="M5 10v2a7 7 0 0 0 12 5"/><path d="M15 9.34V5a3 3 0 0 0-5.68-1.33"/><path d="M9 9v3a3 3 0 0 0 5.12 2.12"/><line x1="12" x2="12" y1="19" y2="22"/>', 16);
  const STOP_SVG = svg('<rect x="6" y="6" width="12" height="12" rx="2"/>', 14);
  const VOLX_SVG = svg('<path d="M11 5 6 9H2v6h4l5 4V5Z"/><line x1="22" x2="16" y1="9" y2="15"/><line x1="16" x2="22" y1="9" y2="15"/>', 14);
  const HAND_SVG = svg('<circle cx="12" cy="12" r="10"/><path d="m4.9 4.9 14.2 14.2"/>', 14);
  const SPINNER_SVG = svg('<path d="M21 12a9 9 0 1 1-9-9"/>', 18);
  const X_SVG = svg('<path d="M18 6 6 18"/><path d="m6 6 12 12"/>', 12);

  function escHtml(s) {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }

  function getSupportedMime() {
    const types = ["audio/webm;codecs=opus", "audio/webm", "audio/ogg;codecs=opus", "audio/mp4"];
    for (const t of types) {
      if (MediaRecorder.isTypeSupported(t)) return t;
    }
    return "";
  }

  function renderUI(container) {
    if (!container) return;
    container.replaceChildren();

    const wrapper = document.createElement("div");
    wrapper.className = "meeting-panel";

    if (!state.active) {
      // Hero card: icon, title, one-line description, full-width start button.
      const hero = document.createElement("div");
      hero.className = "meeting-hero";
      hero.innerHTML =
        `<div class="meeting-hero-icon">${MIC_SVG}</div>` +
        `<div class="meeting-hero-title"></div>` +
        `<p class="meeting-hero-desc"></p>`;
      hero.querySelector(".meeting-hero-title").textContent =
        state.resumable ? t("hero.resumeTitle") : t("hero.title");
      hero.querySelector(".meeting-hero-desc").textContent =
        state.resumable ? t("hint.resume") : t("hero.desc");

      const btn = document.createElement("button");
      btn.className = "meeting-btn meeting-btn-start";
      btn.innerHTML = MIC_SVG + "<span></span>";
      btn.querySelector("span").textContent = state.resumable ? t("btn.resume") : t("btn.start");
      btn.onclick = () => startMeeting(container, btn);
      hero.appendChild(btn);
      wrapper.appendChild(hero);

      if (!state.resumable) {
        const hint = document.createElement("div");
        hint.className = "meeting-tip";
        hint.innerHTML = `${CHAT_SVG}<span></span>`;
        hint.querySelector("span").textContent = t("hint.wake");
        wrapper.appendChild(hint);
      }

      // Vocabulary can only be set before a meeting starts; once a meeting is
      // in progress (resume state), hide the editor since changes won't apply.
      if (!state.resumable) {
        const vocabSection = document.createElement("div");
        vocabSection.className = "meeting-vocab-section";

        const vocabLabel = document.createElement("label");
        vocabLabel.className = "meeting-vocab-label";
        vocabLabel.textContent = t("vocab.label");
        vocabSection.appendChild(vocabLabel);

        const vocabDesc = document.createElement("p");
        vocabDesc.className = "meeting-vocab-desc";
        vocabDesc.textContent = t("vocab.desc");
        vocabSection.appendChild(vocabDesc);

        const savedHint = document.createElement("span");
        savedHint.className = "meeting-vocab-saved";

        const parseTerms = (s) =>
          String(s || "").split(/[,，]/).map((x) => x.trim()).filter(Boolean);

        const box = document.createElement("div");
        box.className = "meeting-vocab-box";

        const input = document.createElement("input");
        input.type = "text";
        input.className = "meeting-vocab-tag-input";
        input.placeholder = t("vocab.placeholder");

        const persist = async (terms) => {
          const value = terms.join(", ");
          state.vocabulary = value;
          try {
            await postJson("/vocabulary", { vocabulary: value });
            savedHint.textContent = t("vocab.saved");
            setTimeout(() => { savedHint.textContent = ""; }, 2000);
          } catch (err) {
            savedHint.textContent = t("vocab.saveFailed");
          }
        };

        const renderTags = () => {
          box.querySelectorAll(".meeting-vocab-tag").forEach((el) => el.remove());
          const terms = parseTerms(state.vocabulary);
          terms.forEach((term, i) => {
            const tag = document.createElement("span");
            tag.className = "meeting-vocab-tag";
            const label = document.createElement("span");
            label.textContent = term;
            const x = document.createElement("button");
            x.type = "button";
            x.className = "meeting-vocab-tag-x";
            x.innerHTML = X_SVG;
            x.setAttribute("aria-label", "remove " + term);
            x.onclick = () => {
              const next = parseTerms(state.vocabulary);
              next.splice(i, 1);
              persist(next);
              renderTags();
            };
            tag.appendChild(label);
            tag.appendChild(x);
            box.insertBefore(tag, input);
          });
        };

        const addTerm = (raw) => {
          const term = String(raw || "").trim();
          if (!term) return;
          const terms = parseTerms(state.vocabulary);
          if (terms.includes(term)) { input.value = ""; return; }
          terms.push(term);
          persist(terms);
          input.value = "";
          renderTags();
        };

        input.addEventListener("keydown", (e) => {
          if (e.key === "Enter" || e.key === ",") {
            e.preventDefault();
            addTerm(input.value);
          } else if (e.key === "Backspace" && !input.value) {
            const terms = parseTerms(state.vocabulary);
            if (terms.length) { terms.pop(); persist(terms); renderTags(); }
          }
        });
        input.addEventListener("blur", () => addTerm(input.value));
        box.onclick = () => input.focus();

        box.appendChild(input);
        renderTags();
        vocabSection.appendChild(box);
        vocabSection.appendChild(savedHint);

        wrapper.appendChild(vocabSection);
      }

      // When resuming after a refresh, show the captions captured so far.
      if (state.resumable && state.transcripts.length) {
        const captions = document.createElement("div");
        captions.id = "meeting-captions";
        captions.className = "meeting-captions";
        wrapper.appendChild(captions);
        wrapper._restoreCaptions = true;
      }
    } else {
      // Status bar: pulsing dot · status · elapsed clock | controls.
      const bar = document.createElement("div");
      bar.className = "meeting-bar";
      bar.innerHTML =
        `<span class="meeting-recording-dot"></span>` +
        `<span id="meeting-status" class="meeting-status"></span>` +
        `<span id="meeting-clock" class="meeting-clock"></span>` +
        `<span class="meeting-bar-actions"></span>`;
      const actions = bar.querySelector(".meeting-bar-actions");

      const mkBtn = (id, cls, icon, label, hint, onclick) => {
        const b = document.createElement("button");
        b.type = "button";
        if (id) b.id = id;
        b.className = "meeting-btn " + cls;
        b.innerHTML = icon + "<span></span>";
        b.querySelector("span").textContent = label;
        if (hint) b.setAttribute("data-tooltip", hint);
        b.onclick = onclick;
        return b;
      };

      const stopTtsBtn = mkBtn("meeting-stop-tts", "meeting-btn-ghost", VOLX_SVG, t("btn.silence"), t("btn.silence.hint"), stopTts);
      stopTtsBtn.style.display = state.phase === "speaking" ? "" : "none";
      const interruptBtn = mkBtn("meeting-interrupt-btn", "meeting-btn-ghost", HAND_SVG, t("btn.interrupt"), t("btn.interrupt.hint"), interruptAsk);
      interruptBtn.style.display = state.asking ? "" : "none";

      // Mute is icon-only; the label lives in the tooltip / aria-label.
      const muteBtn = document.createElement("button");
      muteBtn.type = "button";
      muteBtn.id = "meeting-mute-btn";
      muteBtn.className = "meeting-icon-btn";
      muteBtn.onclick = toggleMic;

      // Secondary to the red primary: throwing the recording away is
      // destructive, so it asks for confirmation first.
      const cancelBtn = mkBtn("meeting-cancel-btn", "meeting-btn-ghost", X_SVG, t("btn.cancel"), t("btn.cancel.hint"), () => cancelMeeting(container));
      const stopBtn = mkBtn(null, "meeting-btn-stop", STOP_SVG, t("btn.stop"), null, () => stopMeeting(container));

      actions.append(stopTtsBtn, interruptBtn, muteBtn, cancelBtn, stopBtn);
      wrapper.appendChild(bar);

      const tip = document.createElement("div");
      tip.className = "meeting-tip meeting-tip-compact";
      tip.innerHTML = `${CHAT_SVG}<span></span>`;
      tip.querySelector("span").textContent = t("hint.wake");
      wrapper.appendChild(tip);

      const sttError = document.createElement("div");
      sttError.id = "meeting-stt-error";
      sttError.className = "meeting-stt-error";
      sttError.style.display = "none";
      wrapper.appendChild(sttError);

      const section = (title, listId, listCls, countId) => {
        const sec = document.createElement("section");
        sec.className = "meeting-section";
        const h = document.createElement("div");
        h.className = "meeting-section-title";
        h.innerHTML = "<span></span>" + (countId ? `<span id="${countId}" class="meeting-count"></span>` : "");
        h.firstChild.textContent = title;
        const list = document.createElement("div");
        list.id = listId;
        list.className = listCls;
        sec.append(h, list);
        return sec;
      };
      wrapper.appendChild(section(t("captions.title"), "meeting-captions", "meeting-captions", "meeting-captions-count"));
      wrapper.appendChild(section(t("annotations.title"), "meeting-annotations", "meeting-annotations"));
    }

    container.appendChild(wrapper);

    if (state.active) {
      updateCaptions();
      updateAnnotations();
      updateSttError();
      startStatusTicker();
    } else {
      stopStatusTicker();
      if (wrapper._restoreCaptions) updateCaptions();
    }
  }

  // Strip markdown so TTS reads clean prose, not symbols.
  function plainText(md) {
    return String(md)
      .replace(/```[\s\S]*?```/g, " ")
      .replace(/`([^`]*)`/g, "$1")
      .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/[*_#>~]/g, "")
      .replace(/\s+/g, " ")
      .trim();
  }

  async function speakAnswer(content) {
    const text = plainText(content);
    if (!text) return;
    try {
      const data = await postJson("/speak", { text: text });
      if (!data.audio_base64) return;
      const audio = new Audio(`data:${data.mime_type || "audio/wav"};base64,${data.audio_base64}`);
      state.ttsAudio = audio;
      state.phase = "speaking";
      updateStatus();
      const clear = () => {
        if (state.ttsAudio === audio) state.ttsAudio = null;
        state.phase = "idle";
        updateStatus();
      };
      audio.onended = clear;
      audio.onerror = clear;
      audio.play().catch(clear);
    } catch (e) {
      state.phase = "idle";
      updateStatus();
      console.error("[meeting] TTS failed:", e.message);
    }
  }

  function stopTts() {
    const a = state.ttsAudio;
    if (!a) return;
    try { a.pause(); a.currentTime = 0; } catch (_) {}
    state.ttsAudio = null;
    if (state.phase === "speaking") {
      state.phase = "idle";
      updateStatus();
    }
  }

  function toggleMic() {
    if (!state.stream) return;
    const tracks = state.stream.getAudioTracks();
    if (!tracks.length) return;
    state.micMuted = !state.micMuted;
    tracks.forEach((t) => { t.enabled = !state.micMuted; });
    updateStatus();
    updateControls();
  }

  function interruptAsk() {
    stopTts();
    state.asking = false;
    state.expectingSpeech = false;
    state.conversationUntil = 0;
    try {
      if (Clacky.WS && typeof Clacky.WS.send === "function") {
        Clacky.WS.send({ type: "interrupt", session_id: state.sessionId });
      }
    } catch (e) {
      console.error("[meeting] interrupt send failed:", e && e.message);
    }
    updateStatus();
    updateControls();
  }

  function updateControls() {
    if (!state.container) return;
    const muteBtn = state.container.querySelector("#meeting-mute-btn");
    if (muteBtn) {
      const label = state.micMuted ? t("btn.unmute") : t("btn.mute");
      const want = state.micMuted ? "off" : "on";
      if (muteBtn.dataset.mic !== want) {
        muteBtn.innerHTML = state.micMuted ? MICOFF_SVG : MIC_SVG;
        muteBtn.dataset.mic = want;
      }
      muteBtn.setAttribute("data-tooltip", state.micMuted ? label : label + " · " + t("btn.mute.hint"));
      muteBtn.setAttribute("aria-label", label);
      muteBtn.classList.toggle("is-muted", state.micMuted);
    }
    const stopTtsBtn = state.container.querySelector("#meeting-stop-tts");
    if (stopTtsBtn) stopTtsBtn.style.display = state.phase === "speaking" ? "" : "none";
    const interruptBtn = state.container.querySelector("#meeting-interrupt-btn");
    if (interruptBtn) interruptBtn.style.display = state.asking ? "" : "none";
  }

    // Handler dispatched from the module-level assistant-message subscription.
    //  - if we're expecting speech (a wake-word triggered ask), speak it and
    //    keep `asking` locked until playback ends (or fails).
    //  - otherwise release `asking` immediately.
    function onAssistantMessage(payload) {
      if (!state.active || !state.expectingSpeech) {
        state.asking = false;
        updateStatus();
        return;
      }
      state.expectingSpeech = false;
      speakAnswer(payload && payload.content);
    }

    // Register into the module registry so cross-session events reach us.
    _sessionsById.set(ctx.sessionId, {
      onAssistantMessage,
      rerender() { if (state.container) renderUI(state.container); },
    });

    // Kick off vocabulary + resume probe eagerly so the tab is ready even
    // before the user first opens it (create runs on first render).
    fetch(apiUrl("/vocabulary"))
      .then((r) => r.json())
      .then((d) => {
        state.vocabulary = (d && d.vocabulary) || "";
        if (state.container) renderUI(state.container);
      })
      .catch(() => null)
      .then(() => probeActiveMeeting(state.container));

    return {
      state,
      // Every tab activation gets a fresh empty container; wire it into state
      // and paint the current state onto it.
      attach(container) {
        state.container = container;
        renderUI(container);
      },
      // Session left the sidebar for good — release recorder / audio / timers.
      dispose() {
        _sessionsById.delete(ctx.sessionId);
        state.active = false;
        if (state.vadTimer) clearInterval(state.vadTimer);
        try { if (state.mediaRecorder && state.mediaRecorder.state !== "inactive") state.mediaRecorder.stop(); } catch (_) {}
        if (state.stream) state.stream.getTracks().forEach((t) => t.stop());
        if (state.audioCtx) { try { state.audioCtx.close(); } catch (_) {} }
        clearInterval(state.annotateTimer);
        stopStatusTicker();
        stopTts();
      },
    };
  }

  Clacky.ext.ui.mount("session.aside", {
    create(ctx) { return createMeetingSession(ctx); },
    render(container, ctx, runtime) { runtime.attach(container); },
  }, {
    tab: { id: "meeting", label: () => t("tab.label") },
    order: 60,
  });

  // Inject minimal styles
  const style = document.createElement("style");
  style.textContent = `
    .meeting-panel { padding: 16px; font-size: 13px; color: var(--color-text-secondary); container-type: inline-size; }
    .meeting-btn { display: inline-flex; align-items: center; justify-content: center; gap: 6px; padding: 7px 14px; border-radius: var(--radius-md); border: 1px solid transparent; cursor: pointer; font-size: 13px; font-weight: 500; font-family: inherit; transition: background .15s, border-color .15s, color .15s; }
    .meeting-btn-start { background: var(--color-button-primary); color: var(--color-button-primary-text); }
    .meeting-btn-start:hover { background: var(--color-button-primary-hover); }
    .meeting-btn-start:disabled { cursor: default; opacity: .72; }
    .meeting-btn-start:disabled:hover { background: var(--color-button-primary); }
    .meeting-btn.is-busy svg { animation: meeting-spin .7s linear infinite; }
    .meeting-btn-stop { background: var(--color-error); color: #fff; height: 32px; padding: 0 12px; }
    .meeting-btn-stop:hover { filter: brightness(0.94); }
    .meeting-btn-ghost { background: transparent; color: var(--color-text-secondary); border-color: var(--color-border-primary); height: 32px; padding: 0 10px; }
    .meeting-btn-ghost:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
    .meeting-icon-btn { display: inline-flex; align-items: center; justify-content: center; width: 32px; height: 32px; border-radius: var(--radius-md); border: 1px solid var(--color-border-primary); background: transparent; color: var(--color-text-secondary); cursor: pointer; transition: background .15s, color .15s, border-color .15s; }
    .meeting-icon-btn:hover { background: var(--color-bg-hover); color: var(--color-text-primary); }
    .meeting-icon-btn.is-muted { color: var(--color-error); border-color: var(--color-error-border); background: var(--color-error-bg); }
    .meeting-hero { display: flex; flex-direction: column; align-items: center; text-align: center; padding: 24px 20px 20px; border: 1px solid var(--color-border-primary); border-radius: var(--radius-lg); background: var(--color-bg-secondary); }
    .meeting-hero-icon { width: 44px; height: 44px; border-radius: 50%; display: flex; align-items: center; justify-content: center; color: var(--color-accent-primary); background: var(--color-accent-soft); margin-bottom: 12px; }
    .meeting-hero-icon svg { width: 22px; height: 22px; }
    .meeting-hero-title { font-size: 15px; font-weight: 600; color: var(--color-text-primary); }
    .meeting-hero-desc { margin: 6px 0 16px; font-size: 12px; line-height: 1.6; color: var(--color-text-tertiary); max-width: 26em; }
    .meeting-hero .meeting-btn-start { width: 100%; height: 38px; }
    .meeting-tip { display: flex; align-items: flex-start; gap: 8px; margin-top: 10px; padding: 9px 12px; border-radius: var(--radius-md); background: var(--color-bg-hover); font-size: 12px; line-height: 1.6; color: var(--color-text-secondary); }
    .meeting-tip svg { flex: none; margin-top: 3px; color: var(--color-text-tertiary); }
    .meeting-vocab-section { margin-top: 24px; }
    .meeting-vocab-label { display: block; font-size: 13px; font-weight: 600; color: var(--color-text-primary); }
    .meeting-vocab-desc { margin: 3px 0 10px; font-size: 12px; line-height: 1.5; color: var(--color-text-tertiary); }
    .meeting-vocab-box { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; width: 100%; box-sizing: border-box; background: var(--color-bg-input); border: 1px solid var(--color-border-primary); border-radius: var(--radius-md); padding: 7px 8px; cursor: text; min-height: 40px; transition: border-color .15s; }
    .meeting-vocab-box:focus-within { border-color: var(--color-accent-primary); }
    .meeting-vocab-tag { display: inline-flex; align-items: center; gap: 2px; background: var(--color-bg-hover); color: var(--color-text-primary); border-radius: var(--radius-sm); padding: 3px 3px 3px 9px; font-size: 12px; line-height: 1.4; }
    .meeting-vocab-tag-x { display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; background: none; border: none; border-radius: 4px; color: var(--color-text-muted); cursor: pointer; padding: 0; }
    .meeting-vocab-tag-x:hover { color: var(--color-text-primary); background: var(--color-border-primary); }
    .meeting-vocab-tag-input { flex: 1; min-width: 100px; background: none; border: none; outline: none; color: var(--color-text-primary); font-size: 12px; font-family: inherit; padding: 3px 2px; }
    .meeting-vocab-tag-input::placeholder { color: var(--color-text-muted); }
    .meeting-vocab-saved { display: block; font-size: 12px; color: var(--color-success); margin-top: 6px; min-height: 16px; }
    .meeting-bar { display: flex; align-items: center; gap: 8px; padding: 10px 10px 10px 14px; border: 1px solid var(--color-border-primary); border-radius: var(--radius-lg); background: var(--color-bg-secondary); }
    .meeting-recording-dot { position: relative; width: 8px; height: 8px; border-radius: 50%; background: var(--color-error); flex: none; }
    .meeting-recording-dot::after { content: ""; position: absolute; inset: -4px; border-radius: 50%; background: var(--color-error); opacity: .25; animation: meeting-ring 1.6s ease-out infinite; }
    @keyframes meeting-spin { to { transform: rotate(360deg); } }
    @keyframes meeting-ring { 0% { transform: scale(.5); opacity: .45; } 100% { transform: scale(1.4); opacity: 0; } }
    .meeting-bar[data-state="muted"] .meeting-recording-dot { background: var(--color-text-muted); }
    .meeting-bar[data-state="muted"] .meeting-recording-dot::after { display: none; }
    .meeting-status { font-size: 13px; font-weight: 500; color: var(--color-text-primary); white-space: nowrap; }
    .meeting-bar[data-state="thinking"] .meeting-status, .meeting-bar[data-state="listening"] .meeting-status { color: var(--color-accent-primary); }
    .meeting-bar[data-state="speaking"] .meeting-status { color: var(--color-success); }
    .meeting-bar[data-state="muted"] .meeting-status { color: var(--color-text-tertiary); }
    .meeting-clock { font-size: 12px; color: var(--color-text-tertiary); font-variant-numeric: tabular-nums; }
    .meeting-bar-actions { margin-left: auto; display: flex; align-items: center; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
    .meeting-tip-compact { padding: 7px 10px; font-size: 12px; }
    .meeting-stt-error { background: var(--color-error-bg); color: var(--color-error); border: 1px solid var(--color-error-border); border-radius: var(--radius-md); padding: 8px 10px; margin-top: 10px; font-size: 12px; line-height: 1.4; }
    .meeting-stt-error.is-actionable { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; }
    .meeting-stt-error-action { flex: none; margin-left: auto; background: transparent; border: 1px solid var(--color-error-border); border-radius: 6px; color: var(--color-error); font-family: inherit; font-size: 12px; line-height: 1.4; padding: 2px 8px; cursor: pointer; }
    .meeting-stt-error-action:hover { background: color-mix(in srgb, var(--color-error) 10%, transparent); }
    .meeting-section { margin-top: 20px; }
    .meeting-section-title { display: flex; align-items: center; gap: 6px; margin-bottom: 8px; font-size: 13px; font-weight: 600; color: var(--color-text-primary); }
    .meeting-count { font-size: 12px; font-weight: 400; color: var(--color-text-muted); }
    .meeting-captions { max-height: 320px; overflow-y: auto; overflow-x: hidden; margin: 0 -8px; padding: 0 8px; display: flex; flex-direction: column; gap: 2px; }
    .meeting-caption { display: flex; gap: 10px; padding: 5px 8px; margin: 0 -8px; border-radius: var(--radius-sm); line-height: 1.6; color: var(--color-text-primary); }
    .meeting-caption:hover { background: var(--color-bg-hover); }
    .meeting-caption:last-child .meeting-caption-text { font-weight: 500; }
    .meeting-ts { flex: none; padding-top: 2px; font-size: 11px; color: var(--color-text-muted); font-variant-numeric: tabular-nums; }
    .meeting-caption-text { min-width: 0; word-break: break-word; }
    .meeting-annotations { display: flex; flex-direction: column; gap: 6px; }
    .meeting-annotation { display: flex; align-items: flex-start; gap: 8px; font-size: 12px; line-height: 1.6; color: var(--color-text-primary); }
    .meeting-anno-tag { flex: none; padding: 0 6px; border-radius: 4px; font-size: 11px; line-height: 18px; margin-top: 1px; }
    .meeting-anno-decision { color: var(--color-accent-primary); background: var(--color-accent-soft); }
    .meeting-anno-action { color: var(--color-success); background: var(--color-success-bg); }
    .meeting-anno-question { color: var(--color-warning); background: var(--color-warning-bg); }
    .meeting-empty { display: flex; align-items: center; justify-content: center; gap: 8px; padding: 18px 12px; border: 1px dashed var(--color-border-primary); border-radius: var(--radius-md); color: var(--color-text-muted); font-size: 12px; text-align: center; }
    .meeting-wave { display: inline-flex; align-items: center; gap: 2px; height: 12px; }
    .meeting-wave i { width: 2px; height: 4px; border-radius: 1px; background: currentColor; animation: meeting-wave 1.2s ease-in-out infinite; }
    .meeting-wave i:nth-child(2) { animation-delay: .15s; }
    .meeting-wave i:nth-child(3) { animation-delay: .3s; }
    .meeting-wave i:nth-child(4) { animation-delay: .45s; }
    @keyframes meeting-wave { 0%, 100% { height: 4px; } 50% { height: 12px; } }
    /* Narrow panels (aside can shrink to 296px): drop the discard label and
       give the controls their own row instead of squeezing the status. */
    @container (max-width: 360px) {
      .meeting-bar { flex-wrap: wrap; row-gap: 8px; }
      .meeting-bar-actions { margin-left: 0; width: 100%; justify-content: flex-start; }
      #meeting-cancel-btn { padding: 0 8px; }
      #meeting-cancel-btn span { display: none; }
    }
  `;
  document.head.appendChild(style);
})();
