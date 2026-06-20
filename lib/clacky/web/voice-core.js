/**
 * voice-core.js — Voice input pure-logic module
 *
 * Extracted from the Tampermonkey voice script. No DOM dependencies,
 * fully unit-testable with Node.js.
 *
 * Aliyun paraformer-realtime-v2 behavior:
 *   - is_end is never true (all results are cumulative intermediates)
 *   - begin_time is always 0, unusable for boundary detection
 *   - Text only grows within a VAD segment
 *   - Text resets (long→short) when a new VAD segment starts
 *
 * Strategy: detect sentence boundaries by text-length collapse.
 */

/**
 * Process a single ASR recognition result. Manages sentence boundary
 * detection and text accumulation.
 *
 * @param {{interim:string, queue:string, maxLen:number}} state
 * @param {string} text - the latest accumulated recognition text
 * @returns {{interim:string, queue:string, maxLen:number, display:string}}
 */
function processAsrResult(state, text) {
  let { interim, queue, maxLen } = state;

  if (!text) {
    return { interim, queue, maxLen, display: queue ? queue + "\n" + interim : interim };
  }

  // Sentence boundary: text length collapses to ≤ 50% of previous max
  // Use <= (not <) to catch equal-length short sentences (e.g. "hi"→"ok")
  if (maxLen > 0 && text.length <= maxLen * 0.5) {
    if (interim.trim()) {
      queue = (queue ? queue + " " : "") + interim;
    }
    maxLen = text.length;
  } else if (text.length > maxLen) {
    maxLen = text.length;
  }

  interim = text;
  const display = queue ? queue + "\n" + interim : interim;

  return { interim, queue, maxLen, display };
}

/**
 * Create initial empty state.
 * @returns {{interim:string, queue:string, maxLen:number}}
 */
function createInitialState() {
  return { interim: "", queue: "", maxLen: 0 };
}

/**
 * Match a keyboard event against configurable voice shortcuts.
 *
 * @param {{ctrlKey?:boolean, shiftKey?:boolean, altKey?:boolean, metaKey?:boolean, key?:string}} e
 * @param {{toggle?:{modifiers:string[],key:string}, stop?:{modifiers:string[],key:string}, start?:{modifiers:string[],key:string}}} [shortcuts]
 *        modifiers: subset of ["Control","Shift","Alt","Meta"]. Absent/empty = no modifier required.
 * @returns {'toggle'|'stop'|'start'|null}
 */
function matchVoiceShortcut(e, shortcuts) {
  if (!shortcuts) {
    shortcuts = {
      toggle: { modifiers: ["Control", "Shift"], key: "z" },
      stop:   { modifiers: ["Control", "Shift"], key: "s" },
      start:  { modifiers: ["Control", "Shift"], key: "r" }
    };
  }

  const MOD_MAP = { Control: "ctrlKey", Shift: "shiftKey", Alt: "altKey", Meta: "metaKey" };
  const k = (e.key || "").toLowerCase();

  for (const [action, sc] of Object.entries(shortcuts)) {
    if (!sc || !sc.key) continue;
    if (k !== String(sc.key).toLowerCase()) continue;

    // All required modifiers must be pressed, all others must NOT be pressed
    const req = sc.modifiers || [];
    const allMods = ["Control", "Shift", "Alt", "Meta"];
    let match = true;
    for (const mod of allMods) {
      const prop = MOD_MAP[mod];
      const pressed = !!(e[prop] || false);
      const required = req.includes(mod);
      if (pressed !== required) { match = false; break; }
    }
    if (match) return action;
  }
  return null;
}

// CommonJS export for Node.js testing; in the browser these are loaded
// via a <script> tag and become global functions referenced by voice.js.
if (typeof module !== "undefined" && module.exports) {
  module.exports = { processAsrResult, createInitialState, matchVoiceShortcut };
}
