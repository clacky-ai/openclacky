/**
 * voice-core.js — Voice input pure-logic module
 *
 * Extracted from the Tampermonkey voice script. No DOM dependencies,
 * fully unit-testable with Node.js.
 *
 * Sentence boundary strategies (dual):
 *   1. end_time (DashScope) — paraformer-realtime-v2 returns sentence.end_time:
 *        end_time === 0 → interim (still changing)
 *        end_time > 0    → final (stable, corrected)
 *   2. text-length collapse (Google fallback) — when isSentenceEnd is undefined,
 *      detect boundaries by text-length drop to ≤50% of previous max.
 */

/**
 * Process a single ASR recognition result. Manages sentence boundary
 * detection and text accumulation.
 *
 * @param {{interim:string, queue:string, maxLen:number}} state
 * @param {string} text - the latest accumulated recognition text
 * @param {boolean} [isSentenceEnd] - DashScope: sentence.end_time > 0.
 *        When undefined, falls back to text-length collapse (Google).
 * @returns {{interim:string, queue:string, maxLen:number, display:string}}
 */
function processAsrResult(state, text, isSentenceEnd) {
  let { interim, queue, maxLen } = state || { interim: "", queue: "", maxLen: 0 };

  if (!text) {
    return { interim, queue, maxLen, display: queue && interim ? queue + "\n" + interim : (queue || interim) };
  }

  // ── DashScope: precise boundary via end_time ─────────────────────────
  if (isSentenceEnd !== undefined) {
    if (isSentenceEnd) {
      // Sentence complete → enqueue, clear interim
      if (text.trim()) {
        queue = (queue ? queue + "\n" : "") + text;
      }
      interim = "";
    } else {
      // Interim → update display only, don't enqueue
      interim = text;
    }
    const display = queue && interim ? queue + "\n" + interim : (queue || interim);
    return { interim, queue, maxLen: maxLen || 0, display };
  }

  // ── Google fallback: text-length collapse ─────────────────────────────
  // Sentence boundary: text length collapses to ≤ 50% of previous max
  if (maxLen > 0 && text.length <= maxLen * 0.5) {
    if (interim.trim()) {
      queue = (queue ? queue + " " : "") + interim;
    }
    maxLen = text.length;
  } else if (text.length > maxLen) {
    maxLen = text.length;
  }

  interim = text;
  const display = queue && interim ? queue + "\n" + interim : (queue || interim);

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
