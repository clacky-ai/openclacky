// ── Share · view — themes, receipt Canvas, floating print stage ──────────
//
// Renders the scorecard as a thermal receipt on Canvas, plays it out of a
// floating print stage (optionally starting in a pending state while stats
// load), owns the theme picker + download, and exposes the public entry
// points (openStage / openScorecard / openScorecardPending /
// resolveScorecardPending / cancelScorecardPending / closeStage /
// maybePromptOnComplete / init) on the `Share` facade.
//
// All data — brand identity, scorecard stats, frequency cap, telemetry —
// lives in ShareStore; the view reads it through Share.state and drives state
// changes through store actions.
//
// Depends on: ShareStore, qrcode, I18n, Modal.
// ───────────────────────────────────────────────────────────────────────────

const ShareView = (() => {
  const THEME_KEY = "clacky-share-theme";

  const THEMES = {
    dusk:   { labelKey: "share.theme.dusk",   bg: ["#f472b6", "#60a5fa"] },
    sky:    { labelKey: "share.theme.sky",    bg: ["#7dd3fc", "#818cf8"] },
    mint:   { labelKey: "share.theme.mint",   bg: ["#a7f3d0", "#34d399"] },
    sunset: { labelKey: "share.theme.sunset", bg: ["#fdba74", "#f43f5e"] }
  };
  const THEME_ORDER = ["dusk", "sky", "mint", "sunset"];

  function _themeGradientCss(t) {
    return "linear-gradient(135deg, " + t.bg[0] + ", " + t.bg[1] + ")";
  }

  function _themeId() {
    const saved = localStorage.getItem(THEME_KEY);
    return THEMES[saved] ? saved : "dusk";
  }
  function _theme() { return THEMES[_themeId()]; }
  function _setTheme(id) { if (THEMES[id]) localStorage.setItem(THEME_KEY, id); }

  function _brandName() { return Share.state.brand.name; }
  function _shareUrl()  { return Share.state.shareUrl(); }
  function _scorecard() { return Share.state.scorecard; }
  function _scorePeriod() { return Share.state.scorePeriod; }
  function _curStats()  { return Share.state.curStats(); }

  // ── Share copy (i18n + brand interpolation) ───────────────────────────


  function _scorecardVars() {
    const s = _curStats();
    return {
      brand:        _brandName(),
      period:       s.period,
      cacheHitRate: s.cacheHitRate,
      cost:         s.costStr,
      tokens:       s.tokensStr,
      requests:     s.requests
    };
  }

  function _scorecardGoldenLine() {
    const rate = parseFloat(_curStats().cacheHitRate) || 0;
    const key = rate >= 90 ? "high" : rate >= 60 ? "mid" : "low";
    return I18n.t("share.scorecard.golden." + key, _scorecardVars());
  }

  // ── Scorecard poster — thermal-receipt style ─────────────────────────
  //
  // Rows are laid out and measured before painting, so the paper ends up
  // exactly as tall as the data needs. Ink is always black on cream paper —
  // the theme only tints the backdrop the receipt sits on.

  const RECEIPT = {
    paper:  "#ffffff",
    ink:    "#1b1917",
    soft:   "rgba(27,25,23,0.60)",
    faint:  "rgba(27,25,23,0.34)",
    rule:   "rgba(27,25,23,0.30)",
    width:  600,
    padX:   46,
    padY:   46,
    margin: 56,
    tooth:  10
  };

  const MONO = "'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace";
  const SANS = "-apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";

  const RECEIPT_ROW_H = {
    title: 58, tagline: 30, rule: 30, kv: 36,
    hero: 178, head: 30, model: 46, brand: 46, sign: 34
  };

  function _brandReceiptRows(copy) {
    const url = (_shareUrl() || "").replace(/^https?:\/\//, "").replace(/\/$/, "");
    const line = (copy || "").trim() || I18n.t("share.poster.tagline", { brand: _brandName() });

    const rows = [
      { t: "title",   text: _brandName() },
      { t: "tagline", text: I18n.t("share.receipt.tagline") },
      { t: "rule" },
      { t: "note", text: line, strong: true, size: 21, lh: 32 },
      { t: "rule" },
      { t: "note", text: I18n.t("share.scorecard.receipt.brandLine", { brand: _brandName() }), size: 16, lh: 22 }
    ];
    if (url) rows.push({ t: "note", text: url, size: 16, lh: 22 });
    rows.push({ t: "sign", text: I18n.t("share.scorecard.receipt.sign", { brand: _brandName() }) });
    return rows;
  }

  function _receiptRows(copy) {
    const s = _curStats();
    if (!s) return _brandReceiptRows(copy);

    const rows = [
      { t: "title",   text: I18n.t("share.scorecard.receipt.title") },
      { t: "tagline", text: I18n.t("share.scorecard.receipt.tagline", { brand: _brandName() }) },
      { t: "rule" },
      { t: "kv", label: I18n.t("share.scorecard.receipt.date"),   value: s.dateStr || "-" },
      { t: "kv", label: I18n.t("share.scorecard.receipt.issued"), value: s.issuedAt || "-" },
      { t: "rule" },
      {
        t: "hero",
        label:  I18n.t("share.scorecard.receipt.totalLabel"),
        amount: s.costStr || "-",
        sub:    I18n.t("share.scorecard.receipt.totalSub")
      },
      { t: "rule" },
      {
        t: "head",
        label: I18n.t("share.scorecard.receipt.modelsHead"),
        value: I18n.t("share.scorecard.receipt.costHead")
      }
    ];

    (s.models || []).forEach((m) => rows.push({ t: "model", name: m.name, value: m.cost }));

    rows.push({ t: "rule" });
    rows.push({ t: "kv", label: I18n.t("share.scorecard.receipt.tokensHead"), value: s.tokensStr || "0", strong: true });
    rows.push({ t: "kv", label: I18n.t("share.scorecard.receipt.input"),      value: s.inputTokensStr || "-" });
    rows.push({ t: "kv", label: I18n.t("share.scorecard.receipt.output"),     value: s.outputTokensStr || "-" });
    rows.push({ t: "kv", label: I18n.t("share.scorecard.receipt.cache"),      value: (s.cacheHitRate || "0") + "%" });
    rows.push({ t: "kv", label: I18n.t("share.scorecard.receipt.sessions"),   value: s.requests || "0" });
    rows.push({ t: "rule" });
    rows.push({
      t: "note",
      text: (copy || "").trim() || _scorecardGoldenLine(),
      strong: true, size: 18, lh: 26
    });

    const url = (_shareUrl() || "").replace(/^https?:\/\//, "").replace(/\/$/, "");
    rows.push({ t: "brand", text: _brandName() });
    rows.push({ t: "note", text: I18n.t("share.scorecard.receipt.brandLine", { brand: _brandName() }), size: 16, lh: 22 });
    if (url) rows.push({ t: "note", text: url, size: 16, lh: 22 });
    rows.push({ t: "sign", text: I18n.t("share.scorecard.receipt.sign", { brand: _brandName() }) });

    return rows;
  }

  function _receiptRowHeight(ctx, r) {
    if (r.t !== "note") return RECEIPT_ROW_H[r.t] || 30;
    ctx.font = "400 " + (r.size || 17) + "px " + MONO + ", " + SANS;
    return _wrapLines(ctx, r.text, RECEIPT.width - RECEIPT.padX * 2).length * (r.lh || 24) + 8;
  }

  function _scorecardLayers(copy) {
    const t = _theme();
    const rows = _receiptRows(copy);

    const measure = document.createElement("canvas").getContext("2d");
    rows.forEach((r) => { r.h = _receiptRowHeight(measure, r); });

    const W = RECEIPT.width + RECEIPT.margin * 2;
    const paperH = RECEIPT.padY * 2 + rows.reduce((sum, r) => sum + r.h, 0);
    const H = paperH + RECEIPT.margin * 2;

    const backdrop = document.createElement("canvas");
    backdrop.width = W;
    backdrop.height = H;
    _paintBackground(backdrop.getContext("2d"), W, H, t);

    const paper = document.createElement("canvas");
    paper.width = W;
    paper.height = H;
    const ctx = paper.getContext("2d");

    _paintReceiptPaper(ctx, RECEIPT.margin, RECEIPT.margin, RECEIPT.width, paperH);

    const box = {
      left:  RECEIPT.margin + RECEIPT.padX,
      right: RECEIPT.margin + RECEIPT.width - RECEIPT.padX,
      cx:    W / 2,
      y:     RECEIPT.margin + RECEIPT.padY
    };
    rows.forEach((r) => { box.y = _paintReceiptRow(ctx, r, box); });

    return {
      backdrop: backdrop,
      paper: paper,
      W: W,
      H: H,
      paperTop: RECEIPT.margin,
      paperBottom: RECEIPT.margin + paperH
    };
  }

  function _flattenLayers(layers) {
    const out = document.createElement("canvas");
    out.width = layers.W;
    out.height = layers.H;
    const ctx = out.getContext("2d");
    ctx.drawImage(layers.backdrop, 0, 0);
    ctx.drawImage(layers.paper, 0, 0);
    return out;
  }

  function _buildScorecardPoster(copy) {
    return _flattenLayers(_scorecardLayers(copy)).toDataURL("image/png");
  }

  function _paintReceiptPaper(ctx, x, y, w, h) {
    ctx.save();
    ctx.shadowColor = "rgba(8,10,18,0.32)";
    ctx.shadowBlur = 30;
    ctx.shadowOffsetY = 14;
    _receiptPath(ctx, x, y, w, h, RECEIPT.tooth);
    ctx.fillStyle = RECEIPT.paper;
    ctx.fill();
    ctx.restore();
  }

  function _receiptPath(ctx, x, y, w, h, tooth) {
    ctx.beginPath();
    ctx.moveTo(x, y + tooth);
    for (let px = 0; px < w; px += tooth) {
      const step = Math.min(tooth, w - px);
      ctx.lineTo(x + px + step / 2, y);
      ctx.lineTo(x + px + step, y + tooth);
    }
    ctx.lineTo(x + w, y + h - tooth);
    for (let px = w; px > 0; px -= tooth) {
      const step = Math.min(tooth, px);
      ctx.lineTo(x + px - step / 2, y + h);
      ctx.lineTo(x + px - step, y + h - tooth);
    }
    ctx.closePath();
  }

  function _paintReceiptRow(ctx, r, box) {
    const left = box.left;
    const right = box.right;
    const cx = box.cx;
    const y = box.y;

    switch (r.t) {
      case "title":
        ctx.textAlign = "center";
        ctx.fillStyle = RECEIPT.ink;
        ctx.font = "700 38px " + SANS;
        _drawTracked(ctx, r.text, cx, y + 34, 7);
        break;

      case "tagline":
        ctx.textAlign = "center";
        ctx.fillStyle = RECEIPT.soft;
        ctx.font = "400 17px " + MONO + ", " + SANS;
        ctx.fillText(r.text, cx, y + 20);
        break;

      case "rule":
        _dashedRule(ctx, left, right, y + r.h / 2);
        break;

      case "kv":
        ctx.font = (r.strong ? "700 21px " : "500 21px ") + MONO + ", " + SANS;
        ctx.textAlign = "left";
        ctx.fillStyle = r.strong ? RECEIPT.ink : RECEIPT.soft;
        ctx.fillText(_ellipsize(ctx, r.label, right - left - 110), left, y + 25);
        ctx.textAlign = "right";
        ctx.fillStyle = RECEIPT.ink;
        ctx.fillText(r.value, right, y + 25);
        break;

      case "hero":
        ctx.textAlign = "center";
        ctx.fillStyle = RECEIPT.soft;
        ctx.font = "500 19px " + MONO + ", " + SANS;
        _drawTracked(ctx, r.label, cx, y + 24, 4);
        ctx.fillStyle = RECEIPT.ink;
        ctx.font = "800 " + _fitTextSize(ctx, r.amount, right - left, "800", [76, 64, 54, 46, 38], SANS) + "px " + SANS;
        ctx.fillText(r.amount, cx, y + 118);
        ctx.fillStyle = RECEIPT.soft;
        ctx.font = "400 16px " + MONO + ", " + SANS;
        ctx.fillText(r.sub, cx, y + 152);
        break;

      case "head":
        ctx.font = "500 16px " + MONO + ", " + SANS;
        ctx.fillStyle = RECEIPT.faint;
        ctx.textAlign = "left";
        ctx.fillText(r.label, left, y + 18);
        ctx.textAlign = "right";
        ctx.fillText(r.value, right, y + 18);
        break;

      case "model": {
        ctx.font = "700 22px " + MONO + ", " + SANS;
        const valueW = ctx.measureText(r.value).width;
        ctx.textAlign = "left";
        ctx.fillStyle = RECEIPT.ink;
        ctx.fillText(_ellipsize(ctx, r.name, right - left - valueW - 20), left, y + 30);
        ctx.textAlign = "right";
        ctx.fillText(r.value, right, y + 30);
        break;
      }

      case "brand":
        ctx.textAlign = "center";
        ctx.fillStyle = RECEIPT.ink;
        ctx.font = "700 26px " + SANS;
        _drawTracked(ctx, r.text, cx, y + 30, 2);
        break;

      case "note": {
        ctx.textAlign = "center";
        ctx.fillStyle = r.strong ? RECEIPT.ink : RECEIPT.soft;
        ctx.font = "400 " + (r.size || 17) + "px " + MONO + ", " + SANS;
        let lineY = y + 20;
        _wrapLines(ctx, r.text, RECEIPT.width - RECEIPT.padX * 2).forEach((line) => {
          ctx.fillText(line, cx, lineY);
          lineY += (r.lh || 24);
        });
        break;
      }

      case "sign":
        ctx.textAlign = "center";
        ctx.fillStyle = RECEIPT.faint;
        ctx.font = "400 15px " + MONO + ", " + SANS;
        _drawTracked(ctx, r.text, cx, y + 20, 2);
        break;
    }

    return y + r.h;
  }

  function _dashedRule(ctx, x1, x2, y) {
    ctx.save();
    ctx.setLineDash([7, 6]);
    ctx.lineWidth = 2;
    ctx.strokeStyle = RECEIPT.rule;
    ctx.beginPath();
    ctx.moveTo(x1, y);
    ctx.lineTo(x2, y);
    ctx.stroke();
    ctx.restore();
  }

  function _drawTracked(ctx, text, cx, baseline, spacing) {
    const chars = Array.from(String(text || ""));
    if (!chars.length) return;
    const widths = chars.map((c) => ctx.measureText(c).width);
    const total = widths.reduce((a, b) => a + b, 0) + spacing * (chars.length - 1);
    ctx.textAlign = "center";
    let x = cx - total / 2;
    chars.forEach((c, i) => {
      ctx.fillText(c, x + widths[i] / 2, baseline);
      x += widths[i] + spacing;
    });
  }

  function _fitTextSize(ctx, text, maxWidth, weight, sizes, family) {
    for (let i = 0; i < sizes.length; i++) {
      ctx.font = weight + " " + sizes[i] + "px " + family;
      if (ctx.measureText(text).width <= maxWidth || i === sizes.length - 1) return sizes[i];
    }
    return sizes[sizes.length - 1];
  }

  function _ellipsize(ctx, text, maxWidth) {
    const value = String(text == null ? "" : text);
    if (ctx.measureText(value).width <= maxWidth) return value;
    let out = value;
    while (out.length > 1 && ctx.measureText(out + "…").width > maxWidth) out = out.slice(0, -1);
    return out + "…";
  }


  function _wrapLines(ctx, text, maxWidth) {
    const out = [];
    for (const para of String(text).split("\n")) {
      let line = "";
      for (const ch of para) {
        if (ctx.measureText(line + ch).width > maxWidth && line) {
          out.push(line);
          line = ch;
        } else {
          line += ch;
        }
      }
      out.push(line);
    }
    return out;
  }


  function _paintBackground(ctx, W, H, t) {
    const grad = ctx.createLinearGradient(0, 0, W, H);
    grad.addColorStop(0, t.bg[0]);
    grad.addColorStop(1, t.bg[1]);
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, W, H);
  }

  // ── Download ──────────────────────────────────────────────────────────

  function _posterFilename() {
    return `${_brandName().toLowerCase()}-${_scorecard() ? "scorecard" : "share"}.png`;
  }

  function _downloadPoster(copy) {
    const a = document.createElement("a");
    a.href = _buildScorecardPoster(copy);
    a.download = _posterFilename();
    a.click();
  }


  // ── Floating print stage ──────────────────────────────────────────────
  //
  // Sequence: white receipt feeds out of a top slot → tears off → themed
  // backdrop and controls fade in behind/below it.

  let _stage = null;
  let _canvas = null;
  let _layers = null;
  let _printRaf = 0;
  let _redrawTimer = 0;

  const PRINT_MS = 1400;
  const TEAR_MS = 700;

  function openStage(opts) {
    if (_stage) closeStage();
    const pending = !!(opts && opts.pending);

    const o = document.createElement("div");
    o.className = "share-stage" + (pending ? " is-pending" : "");

    const themeDots = THEME_ORDER.map((id) =>
      '<button type="button" class="share-theme-dot-btn' + (id === _themeId() ? " is-active" : "") +
      '" data-theme="' + id + '" style="background:' + _themeGradientCss(THEMES[id]) + '"' +
      ' title="' + _esc(I18n.t(THEMES[id].labelKey)) + '"></button>'
    ).join("");

    o.innerHTML =
      '<div class="share-panel">' +
        '<div class="share-stage-paper">' +
          '<div class="share-stage-warmup">' +
            '<span class="share-warmup-head"></span>' +
            '<span class="share-warmup-tongue"></span>' +
            '<span class="share-warmup-label">' + _esc(I18n.t("share.stage.loading")) + '</span>' +
          '</div>' +
          '<canvas class="share-stage-backdrop"></canvas>' +
          '<canvas class="share-stage-canvas"></canvas>' +
        '</div>' +
        '<div class="share-stage-controls">' +
          '<span class="share-row-label">' + _esc(I18n.t("share.theme.label")) + '</span>' +
          '<div class="share-theme-dots">' + themeDots + '</div>' +
          '<button type="button" class="share-btn-ghost" data-act="close">' + _esc(I18n.t("share.action.close")) + '</button>' +
          '<button type="button" class="share-btn-primary" data-act="download">' + _esc(I18n.t("share.action.download")) + '</button>' +
        '</div>' +
      '</div>';

    document.body.appendChild(o);
    _stage = o;
    _canvas = o.querySelector(".share-stage-canvas");

    if (!pending) {
      _layers = _scorecardLayers(null);
      _runPrint();
    }

    const redraw = (delay) => {
      clearTimeout(_redrawTimer);
      _redrawTimer = setTimeout(() => {
        if (!_stage) return;
        _layers = _scorecardLayers(null);
        _renderStill();
      }, delay || 0);
    };

    o.querySelectorAll(".share-theme-dot-btn").forEach((dot) => {
      dot.onclick = () => {
        const id = dot.getAttribute("data-theme");
        _setTheme(id);
        o.querySelectorAll(".share-theme-dot-btn").forEach((d) => {
          d.classList.toggle("is-active", d === dot);
        });
        redraw(0);
      };
    });

    o.querySelector('[data-act="download"]').onclick = () => {
      _downloadPoster(null);
      Share.telemetry("share_download", { type: _scorecard() ? "scorecard" : "share" });
    };

    o.querySelector('[data-act="close"]').onclick = () => closeStage();
    document.addEventListener("keydown", _onStageKeydown);

    if (!pending) Share.telemetry("share_open", { type: _scorecard() ? "scorecard" : "share" });
    requestAnimationFrame(() => o.classList.add("open"));
  }

  function _syncCanvasSize() {
    if (!_canvas || !_layers) return;
    if (_canvas.width !== _layers.W) _canvas.width = _layers.W;
    if (_canvas.height !== _layers.H) _canvas.height = _layers.H;
  }

  function _runPrint() {
    if (!_canvas || !_layers || !_stage) return;
    _syncCanvasSize();

    const o = _stage;
    const ctx = _canvas.getContext("2d");
    const top = _layers.paperTop;
    const paperH = _layers.paperBottom - top;
    const start = performance.now();

    // Thermal printers feed paper downward: the receipt slides out of a slot
    // at the top, so its lower edge appears first and the title arrives last.
    const frame = (now) => {
      const progress = Math.min(1, (now - start) / PRINT_MS);
      const eased = 1 - Math.pow(1 - progress, 2.2);
      const L = paperH * eased;

      ctx.clearRect(0, 0, _layers.W, _layers.H);
      if (L > 1) {
        const srcY = _layers.paperBottom - L;
        const srcH = Math.min(_layers.H - srcY, L + RECEIPT.margin);
        ctx.drawImage(_layers.paper, 0, srcY, _layers.W, srcH, 0, top, _layers.W, srcH);
      }

      if (progress < 1) {
        _paintPrintHead(ctx, top);
        _printRaf = requestAnimationFrame(frame);
        return;
      }
      _printRaf = 0;
      _renderStill();
      _tearOff(o);
    };

    _printRaf = requestAnimationFrame(frame);
  }

  function _tearOff(o) {
    o.classList.add("is-tearing");
    setTimeout(() => {
      if (_stage !== o) return;
      o.classList.remove("is-tearing");
      o.classList.add("is-printed");
    }, TEAR_MS);
  }

  function _renderStill() {
    if (!_canvas || !_layers || !_stage) return;
    _syncCanvasSize();
    const ctx = _canvas.getContext("2d");
    ctx.clearRect(0, 0, _layers.W, _layers.H);
    ctx.drawImage(_layers.paper, 0, 0);

    const bd = _stage.querySelector(".share-stage-backdrop");
    if (bd.width !== _layers.W) bd.width = _layers.W;
    if (bd.height !== _layers.H) bd.height = _layers.H;
    bd.getContext("2d").drawImage(_layers.backdrop, 0, 0);
  }

  function _paintPrintHead(ctx, y) {
    const W = _layers.W;
    const x0 = RECEIPT.margin - 14;
    const w = RECEIPT.width + 28;

    const shade = ctx.createLinearGradient(0, y, 0, y + 36);
    shade.addColorStop(0, "rgba(8,10,18,0.18)");
    shade.addColorStop(1, "rgba(8,10,18,0)");
    ctx.fillStyle = shade;
    ctx.fillRect(RECEIPT.margin, y, RECEIPT.width, 36);

    ctx.save();
    ctx.fillStyle = "#1b1917";
    ctx.shadowColor = "rgba(8,10,18,0.35)";
    ctx.shadowBlur = 10;
    ctx.shadowOffsetY = 3;
    ctx.fillRect(Math.max(0, x0), y - 8, Math.min(W, w), 8);
    ctx.restore();
  }



  function _onStageKeydown(e) {
    if (e.key === "Escape") closeStage();
  }

  function closeStage() {
    if (!_stage) return;
    const o = _stage;
    _stage = null;
    _canvas = null;
    _layers = null;
    if (_printRaf) { cancelAnimationFrame(_printRaf); _printRaf = 0; }
    clearTimeout(_redrawTimer);
    document.removeEventListener("keydown", _onStageKeydown);
    Share.clearScorecard();
    o.classList.remove("open");
    setTimeout(() => o.remove(), 220);
  }



  function openScorecard(stats) {
    Share.setScorecard(stats);
    openStage();
  }

  // Shows the stage at once with a warming-up printer while stats are fetched.
  function openScorecardPending() {
    openStage({ pending: true });
  }

  // Returns false when the pending stage was closed before the stats arrived.
  function resolveScorecardPending(stats) {
    if (!_stage || !_stage.classList.contains("is-pending")) return false;
    Share.setScorecard(stats);
    _stage.classList.remove("is-pending");
    _layers = _scorecardLayers(null);
    _runPrint();
    Share.telemetry("share_open", { type: "scorecard" });
    return true;
  }

  function cancelScorecardPending() {
    if (_stage && _stage.classList.contains("is-pending")) closeStage();
  }


  function maybePromptOnComplete() {
    const { prompt } = Share.consumeSuccess();
    if (!prompt) return;

    Modal.toast(I18n.t("share.prompt.message", { brand: _brandName() }), "success", {
      duration: 8000,
      action: {
        label: I18n.t("share.prompt.action"),
        onClick: openStage
      }
    });
  }

  function _esc(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function init() {
    Share.hydrateBrand();
  }

  const api = {
    init, openStage, openScorecard, closeStage, maybePromptOnComplete,
    openScorecardPending, resolveScorecardPending, cancelScorecardPending
  };

  return { api };
})();

Object.assign(Share, ShareView.api);

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => Share.init());
} else {
  Share.init();
}
