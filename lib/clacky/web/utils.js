// Cross-browser IME composition guard for Enter-to-submit inputs.
//
// Problem: pressing Enter to confirm an IME composition (e.g. selecting a
// Chinese candidate) must NOT trigger submit. Different browsers signal this
// differently:
//   - Chrome / Firefox / Edge: e.isComposing === true on the confirming Enter
//   - Older browsers: e.keyCode === 229
//   - Safari: fires compositionend ~5ms BEFORE keydown, so isComposing is
//     already false. We need a recent compositionend timestamp to suppress.
//
// Reference: https://bugs.webkit.org/show_bug.cgi?id=165004
//
// Usage:
//   IME.bindEnter(inputEl, () => submit());
//
// Or low-level for handlers that already own a keydown listener:
//   const ime = IME.track(inputEl);
//   inputEl.addEventListener("keydown", e => {
//     if (e.key === "Enter" && !ime.isComposing(e)) submit();
//   });
const IME = (() => {
  const SAFARI_GUARD_MS = 20;

  function track(inputEl) {
    let lastCompositionEnd = -Infinity;
    const onEnd = () => { lastCompositionEnd = Date.now(); };
    inputEl.addEventListener("compositionend", onEnd);

    return {
      isComposing(e) {
        if (e.isComposing || e.keyCode === 229) return true;
        return Date.now() - lastCompositionEnd <= SAFARI_GUARD_MS;
      },
      dispose() {
        inputEl.removeEventListener("compositionend", onEnd);
      }
    };
  }

  function bindEnter(inputEl, handler, options = {}) {
    const ime = track(inputEl);
    const onKey = (e) => {
      if (e.key !== "Enter") return;
      if (options.allowShift !== true && e.shiftKey) return;
      if (ime.isComposing(e)) return;
      e.preventDefault();
      handler(e);
    };
    inputEl.addEventListener("keydown", onKey);
    return () => {
      inputEl.removeEventListener("keydown", onKey);
      ime.dispose();
    };
  }

  return { track, bindEnter };
})();

// Compact, non-interactive Markdown for short previews. Only inline formatting
// is emitted; raw HTML and images cannot introduce active content.
const MarkdownPreview = (() => {
  function render(text) {
    if (!text) return "";
    if (typeof marked === "undefined") return escapeHtml(text);

    const renderer = new marked.Renderer();
    renderer.html = renderer.image = renderer.checkbox = () => "";
    renderer.hr = renderer.br = () => " ";
    renderer.link = function({ tokens }) { return this.parser.parseInline(tokens); };
    renderer.paragraph = renderer.heading = function({ tokens }) {
      return this.parser.parseInline(tokens) + " ";
    };
    renderer.blockquote = renderer.listitem = function({ tokens }) {
      return this.parser.parse(tokens).trim() + " ";
    };
    renderer.list = function({ items }) {
      return items.map(item => this.listitem(item)).join("");
    };
    renderer.table = function({ header, rows }) {
      return [header, ...rows].map(row => row.map(cell => this.parser.parseInline(cell.tokens)).join(" ")).join(" ") + " ";
    };
    renderer.code = function({ text }) { return `<code>${escapeHtml(text)}</code> `; };
    try {
      return marked.parse(text, { gfm: true, breaks: false, renderer }).trim();
    } catch (_) {
      return escapeHtml(text);
    }
  }

  return { render };
})();

// Gradient tile with the label's first character; `seed` keeps the colour
// stable when the label is localized.
function letterIcon(label, seed) {
  const text = label || "?";
  const letter = text[0].toUpperCase();
  const cjk = /[\u3400-\u9fff]/.test(letter);
  const fontSize = cjk ? 14 : 16;
  const fontWeight = cjk ? 500 : 700;
  const colors = [
    ["#6366f1","#818cf8"], ["#8b5cf6","#a78bfa"], ["#ec4899","#f472b6"],
    ["#f59e0b","#fbbf24"], ["#10b981","#34d399"], ["#3b82f6","#60a5fa"],
    ["#ef4444","#f87171"], ["#14b8a6","#2dd4bf"],
  ];
  const idx = (seed || text).charCodeAt(0) % colors.length;
  const [c1, c2] = colors[idx];
  const gid = `eg-${idx}-${Math.random().toString(36).slice(2,7)}`;
  const safe = letter.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return `<span class="extension-emoji"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" class="extension-default-icon"><defs><linearGradient id="${gid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="${c1}"/><stop offset="100%" stop-color="${c2}"/></linearGradient></defs><rect width="32" height="32" rx="8" fill="url(#${gid})"/><text x="16" y="22" text-anchor="middle" font-family="system-ui,sans-serif" font-size="${fontSize}" font-weight="${fontWeight}" fill="white">${safe}</text></svg></span>`;
}

const Tooltip = (() => {
  const GAP = 8;
  let el = null;
  let _hideTimer = null;

  function _el() {
    if (!el) el = document.getElementById("tooltip");
    return el;
  }

  function show(anchor) {
    const tip = _el();
    if (!tip) return;
    clearTimeout(_hideTimer);

    const text = anchor.getAttribute("data-tooltip");
    if (!text) return;
    if (anchor.hasAttribute("data-tooltip-overflow") && anchor.scrollWidth <= anchor.clientWidth) return;

    const pos = anchor.getAttribute("data-tooltip-pos") || "top";
    tip.textContent = text;
    tip.setAttribute("data-pos", pos);
    tip.style.display = "block";
    // Measure from the left edge: leaving the previous anchor's `left` in place
    // shrinks the available width, so a tip next to the right edge wraps early.
    tip.style.left = "0px";
    tip.style.top = "0px";

    const r = anchor.getBoundingClientRect();
    const tw = tip.offsetWidth;
    const th = tip.offsetHeight;

    let top, left;
    if (pos === "bottom") {
      top  = r.bottom + GAP;
      left = r.left + r.width / 2 - tw / 2;
    } else if (pos === "left") {
      top  = r.top + r.height / 2 - th / 2;
      left = r.left - tw - GAP;
    } else if (pos === "right") {
      top  = r.top + r.height / 2 - th / 2;
      left = r.right + GAP;
    } else {
      top  = r.top - th - GAP;
      left = r.left + r.width / 2 - tw / 2;
    }

    left = Math.max(6, Math.min(left, window.innerWidth  - tw - 6));
    top  = Math.max(6, Math.min(top,  window.innerHeight - th - 6));

    tip.style.left = `${left}px`;
    tip.style.top  = `${top}px`;
    requestAnimationFrame(() => tip.classList.add("visible"));
  }

  function hide() {
    const tip = _el();
    if (!tip) return;
    tip.classList.remove("visible");
    _hideTimer = setTimeout(() => { tip.style.display = "none"; }, 120);
  }

  // Anchor that was clicked; stays silent until the pointer leaves it so the
  // tip does not cover the menu or popover the click just opened.
  let _suppressed = null;

  function init() {
    document.addEventListener("mouseover", (e) => {
      const anchor = e.target.closest("[data-tooltip]");
      if (anchor && anchor !== _suppressed) show(anchor);
    });
    document.addEventListener("mouseout", (e) => {
      const anchor = e.target.closest("[data-tooltip]");
      if (!anchor) return;
      if (anchor.contains(e.relatedTarget)) return;
      if (anchor === _suppressed) _suppressed = null;
      hide();
    });
    document.addEventListener("pointerdown", (e) => {
      const anchor = e.target.closest && e.target.closest("[data-tooltip]");
      _suppressed = anchor || null;
      hide();
    }, true);
  }

  return { init, show, hide };
})();
