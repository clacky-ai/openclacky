// share.js — Share hooks for spreading the word at peak-delight moments.
//
// Two entry points, one shared UI:
//   Share.openModal()              — always-available header button
//   Share.maybePromptOnComplete()  — fires after a task succeeds, gated by
//                                    a frequency cap (first + 5th success,
//                                    then a 7-day cooldown after dismissal)
//
// Brand-aware: when this install is white-labelled, ALL share content
// (product name, landing link, QR target, logo) switches to the brand's
// values. It NEVER leaks "OpenClacky" / openclacky.com into a branded build.
//
// Depends on: qrcode (vendor/qrcode/qrcode.min.js), I18n, Modal.toast.
// ─────────────────────────────────────────────────────────────────────────
const Share = (() => {
  const DEFAULT_NAME     = "OpenClacky";
  const DEFAULT_HOMEPAGE = "https://www.openclacky.com/";

  const COUNT_KEY    = "clacky-share-success-count";
  const COOLDOWN_KEY = "clacky-share-cooldown-until";
  const COOLDOWN_MS  = 7 * 24 * 60 * 60 * 1000;
  const PROMPT_AT    = [1, 5]; // success counts that trigger an auto-prompt

  const THEME_KEY = "clacky-share-theme"; // remembers last picked poster style
  const DRAFT_KEY = "clacky-share-draft"; // remembers last hand-edited text

  // Poster themes: each is a palette the canvas renderers read from, so the
  // layout stays shared and only colors change. Order = picker order.
  const THEMES = {
    geek: {
      labelKey: "share.theme.geek", style: "geek",
      bg: ["#0f172a", "#1e293b"], scoreBg: ["#0b1220", "#13243b"],
      title: "#ffffff", tagline: "#f1f5f9", period: "#7dd3fc",
      hero: "#38bdf8", metric: "#ffffff", metricLabel: "#cbd5e1",
      golden: "#fcd34d", brand: "#e2e8f0", scan: "#94a3b8", swatch: "#1e293b",
      grid: "rgba(125,211,252,0.06)",
      heat: { empty: "rgba(255,255,255,0.06)", scale: ["#0e3a52", "#0a6e96", "#1aa3d6", "#38bdf8", "#7dd3fc"] },
      glows: [
        { x: 0.20, y: 0.18, r: 0.55, color: "rgba(56,189,248,0.22)" },
        { x: 0.85, y: 0.42, r: 0.50, color: "rgba(168,85,247,0.18)" },
        { x: 0.50, y: 0.92, r: 0.60, color: "rgba(14,165,233,0.14)" }
      ]
    },
    light: {
      labelKey: "share.theme.light", style: "light",
      bg: ["#f8fafc", "#e2e8f0"], scoreBg: ["#ffffff", "#eef2f7"],
      title: "#0f172a", tagline: "#475569", period: "#0284c7",
      hero: "#0284c7", metric: "#0f172a", metricLabel: "#64748b",
      golden: "#b45309", brand: "#334155", scan: "#94a3b8", swatch: "#e2e8f0",
      grid: "rgba(2,132,199,0.05)",
      heat: { empty: "rgba(2,132,199,0.08)", scale: ["#bae6fd", "#7dd3fc", "#38bdf8", "#0ea5e9", "#0369a1"] },
      glows: [
        { x: 0.18, y: 0.16, r: 0.55, color: "rgba(125,211,252,0.40)" },
        { x: 0.88, y: 0.38, r: 0.50, color: "rgba(196,181,253,0.38)" },
        { x: 0.55, y: 0.95, r: 0.60, color: "rgba(167,243,208,0.34)" }
      ]
    },
    warm: {
      labelKey: "share.theme.warm", style: "warm",
      bg: ["#fff1eb", "#ffd9c0"], scoreBg: ["#fff5f0", "#ffe0cc"],
      title: "#7c2d12", tagline: "#9a3412", period: "#ea580c",
      hero: "#ea580c", metric: "#7c2d12", metricLabel: "#c2410c",
      golden: "#be123c", brand: "#9a3412", scan: "#c2410c", swatch: "#ffd9c0",
      grid: "rgba(234,88,12,0.05)",
      heat: { empty: "rgba(234,88,12,0.08)", scale: ["#fed7aa", "#fdba74", "#fb923c", "#f97316", "#c2410c"] },
      glows: [
        { x: 0.16, y: 0.18, r: 0.58, color: "rgba(251,146,60,0.45)" },
        { x: 0.90, y: 0.40, r: 0.52, color: "rgba(244,114,182,0.38)" },
        { x: 0.52, y: 0.94, r: 0.62, color: "rgba(250,204,21,0.40)" }
      ]
    }
  };
  const THEME_ORDER = ["geek", "light", "warm"];

  function _themeId() {
    const saved = localStorage.getItem(THEME_KEY);
    return THEMES[saved] ? saved : "geek";
  }
  function _theme() { return THEMES[_themeId()]; }
  function _setTheme(id) { if (THEMES[id]) localStorage.setItem(THEME_KEY, id); }

  // Brand info, hydrated once from /api/brand/status. Falls back to defaults
  // (un-branded OpenClacky) until the fetch resolves or if it fails.
  let _brand = { name: DEFAULT_NAME, homepageUrl: DEFAULT_HOMEPAGE, logoUrl: null };

  // Current scorecard stats, set by openScorecard() before building the
  // scorecard poster / copy. Null in plain product-share mode.
  // Shape: { periods: { day|week|month: {period,cacheHitRate,costStr,...} },
  //          defaultPeriod, heatmap: [{date,tokens}], ...flat fallback }
  let _scorecard = null;
  // Currently selected scorecard period key (day | week | month).
  let _scorePeriod = null;
  // Set while a scorecard modal is open; lets billing hot-swap in late-arriving
  // period data and re-render the period switcher.
  let _rerenderPeriods = null;

  // ── Brand source (single source of truth) ─────────────────────────────
  async function _hydrateBrand() {
    try {
      const res = await fetch("/api/brand/status");
      if (!res.ok) return;
      const data = await res.json();
      if (data && data.branded) {
        _brand = {
          name:        (data.product_name || "").trim() || DEFAULT_NAME,
          // Branded builds must NEVER fall back to openclacky.com. If the brand
          // has no homepage configured, we simply show no link / QR.
          homepageUrl: (data.homepage_url || "").trim() || null,
          logoUrl:     (data.logo_url || "").trim() || null
        };
      }
    } catch (_e) { /* keep defaults */ }
  }

  // ── Share copy (i18n + brand interpolation) ───────────────────────────
  // Candidate variants per platform; the UI shuffles among them and lets the
  // user hand-edit before posting. Product mode shares one generic pool
  // (`share.copy.*`); scorecard mode has per-platform pools with live numbers.
  function _candidatesFor(platform) {
    if (_scorecard) {
      const list = I18n.tList("share.scorecard.copy." + platform, _scorecardVars());
      return list.length ? list : [_scorecardCopy("copylink")];
    }
    const list = I18n.tList("share.copy", { brand: _brand.name });
    return list.length ? list : [I18n.t("share.copy.1", { brand: _brand.name })];
  }

  function _pickCopy(platform, exclude) {
    const list = _candidatesFor(platform).map((s) => s.trim());
    if (list.length <= 1) return list[0] || "";
    let pick = list[Math.floor(Math.random() * list.length)];
    if (exclude != null) {
      let guard = 0;
      while (pick === exclude && guard++ < 8) {
        pick = list[Math.floor(Math.random() * list.length)];
      }
    }
    return pick;
  }

  function _shareUrl() {
    return _brand.homepageUrl; // null when branded build has no homepage
  }

  // ── Scorecard copy (per-platform, numbers from stats) ─────────────────
  // Returns the stats object for the currently-selected period, falling back
  // to the flat fields billing.js passes for back-compat.
  function _curStats() {
    if (_scorecard.periods && _scorePeriod && _scorecard.periods[_scorePeriod]) {
      return _scorecard.periods[_scorePeriod];
    }
    return _scorecard;
  }

  function _scorecardVars() {
    const s = _curStats();
    return {
      brand:        _brand.name,
      period:       s.period,
      cacheHitRate: s.cacheHitRate,
      cost:         s.costStr,
      tokens:       s.tokensStr,
      requests:     s.requests
    };
  }

  function _scorecardCopy(platform) {
    return I18n.t("share.scorecard.copy." + platform + ".1", _scorecardVars()).trim();
  }

  // Pick a dynamic golden line based on how strong the numbers are.
  function _scorecardGoldenLine() {
    const rate = parseFloat(_curStats().cacheHitRate) || 0;
    const key = rate >= 90 ? "high" : rate >= 60 ? "mid" : "low";
    return I18n.t("share.scorecard.golden." + key, _scorecardVars());
  }

  // ── Frequency cap (C2: first + 5th, 7-day cooldown after dismissal) ────
  function _successCount() {
    return parseInt(localStorage.getItem(COUNT_KEY) || "0", 10) || 0;
  }

  function _bumpSuccessCount() {
    const n = _successCount() + 1;
    localStorage.setItem(COUNT_KEY, String(n));
    return n;
  }

  function _inCooldown() {
    const until = parseInt(localStorage.getItem(COOLDOWN_KEY) || "0", 10) || 0;
    return Date.now() < until;
  }

  function _startCooldown() {
    localStorage.setItem(COOLDOWN_KEY, String(Date.now() + COOLDOWN_MS));
  }

  // ── QR code (reuses qrcode-generator) ─────────────────────────────────
  // Draws the QR for `url` onto a canvas 2d context at (x, y) sized `sizePx`.
  function _drawQrToCanvas(ctx, url, x, y, sizePx) {
    const qr = qrcode(0, "M");
    qr.addData(url);
    qr.make();
    const count = qr.getModuleCount();
    const quiet = 2;
    const total = count + quiet * 2;
    const module = sizePx / total;

    ctx.fillStyle = "#ffffff";
    ctx.fillRect(x, y, sizePx, sizePx);
    ctx.fillStyle = "#1a1a1a";
    for (let r = 0; r < count; r++) {
      for (let c = 0; c < count; c++) {
        if (qr.isDark(r, c)) {
          ctx.fillRect(
            x + (c + quiet) * module,
            y + (r + quiet) * module,
            Math.ceil(module),
            Math.ceil(module)
          );
        }
      }
    }
  }

  // ── Poster (pure-frontend Canvas, zero token, instant) ────────────────
  // Returns a data URL (PNG). `copy` is the live editor text, drawn as the
  // poster's main line so the poster matches exactly what the user will post.
  function _buildPoster(copy) {
    const W = 720, H = 1080;
    const t = _theme();
    const canvas = document.createElement("canvas");
    canvas.width = W;
    canvas.height = H;
    const ctx = canvas.getContext("2d");

    // Background.
    _paintBackground(ctx, W, H, t, t.bg);

    // Brand name.
    ctx.fillStyle = t.title;
    ctx.textAlign = "center";
    ctx.font = "700 60px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
    ctx.fillText(_brand.name, W / 2, 150);

    // Main line = the live editor text (so poster === shared text).
    const text = (copy || "").trim() || I18n.t("share.poster.tagline", { brand: _brand.name });
    ctx.fillStyle = t.tagline;
    _drawAutoText(ctx, text, W / 2, 250, W - 120, 480 - 250);

    // QR code (only when there's a URL to point at).
    const url = _shareUrl();
    if (url) {
      const qrSize = 300;
      const qrX = (W - qrSize) / 2;
      const qrY = 560;
      ctx.fillStyle = "#ffffff";
      _roundRect(ctx, qrX - 24, qrY - 24, qrSize + 48, qrSize + 48, 22);
      ctx.fill();
      _drawQrToCanvas(ctx, url, qrX, qrY, qrSize);

      ctx.fillStyle = t.scan;
      ctx.font = "400 28px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
      ctx.fillText(I18n.t("share.poster.scan"), W / 2, qrY + qrSize + 80);

      ctx.fillStyle = t.scan;
      ctx.font = "400 24px -apple-system, sans-serif";
      ctx.fillText(url.replace(/^https?:\/\//, "").replace(/\/$/, ""), W / 2, H - 60);
    }

    return canvas.toDataURL("image/png");
  }

  // ── Scorecard poster (B-line: spend / cache-hit bragging card) ────────
  // Hero = the cache-hit rate (the delight number). Brand is a footer chip.
  function _buildScorecardPoster(copy) {
    const W = 720, H = 1080;
    const t = _theme();
    const canvas = document.createElement("canvas");
    canvas.width = W;
    canvas.height = H;
    const ctx = canvas.getContext("2d");

    _paintBackground(ctx, W, H, t, t.scoreBg);

    ctx.textAlign = "center";

    // Title + period.
    ctx.fillStyle = t.title;
    ctx.font = "700 48px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
    ctx.fillText(I18n.t("share.scorecard.poster.title"), W / 2, 110);

    const s = _curStats();
    const showHeat = _scorePeriod === "month" && _scorecard.heatmap && _scorecard.heatmap.length > 0;

    ctx.fillStyle = t.period;
    ctx.font = "400 28px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
    ctx.fillText(s.period, W / 2, 162);

    // Hero: cache hit rate.
    ctx.fillStyle = t.hero;
    ctx.font = "800 150px -apple-system, 'PingFang SC', sans-serif";
    ctx.fillText(s.cacheHitRate + "%", W / 2, 348);

    ctx.fillStyle = t.tagline;
    ctx.font = "400 32px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
    ctx.fillText(I18n.t("share.scorecard.poster.cacheLabel"), W / 2, 408);

    // Secondary metrics: cost + tokens.
    ctx.fillStyle = t.metric;
    ctx.font = "700 48px -apple-system, 'PingFang SC', sans-serif";
    ctx.fillText(s.costStr, W / 2 - 160, 494);
    ctx.fillText(s.tokensStr, W / 2 + 160, 494);
    ctx.fillStyle = t.metricLabel;
    ctx.font = "400 26px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
    ctx.fillText(I18n.t("share.scorecard.poster.costLabel"), W / 2 - 160, 534);
    ctx.fillText(I18n.t("share.scorecard.poster.tokensLabel"), W / 2 + 160, 534);

    // Monthly heatmap (calendar style). Pushes everything below down.
    let cursorY = 574;
    if (showHeat) {
      cursorY = _drawHeatmap(ctx, W, 552, t);
    }

    // Golden line = live editor text (poster matches what gets posted).
    const goldenTop = showHeat ? cursorY + 14 : 614;
    const goldenH = showHeat ? 78 : 110;
    const line = (copy || "").trim() || _scorecardGoldenLine();
    ctx.fillStyle = t.golden;
    _drawAutoText(ctx, line, W / 2, goldenTop, W - 120, goldenH);

    // QR + brand chip (gated: branded builds with no homepage show neither).
    const url = _shareUrl();
    const qrSize = showHeat ? 152 : 230;
    const qrY = goldenTop + goldenH + (showHeat ? 14 : 30);
    if (url) {
      const qrX = (W - qrSize) / 2;
      ctx.fillStyle = "#ffffff";
      _roundRect(ctx, qrX - 16, qrY - 16, qrSize + 32, qrSize + 32, 16);
      ctx.fill();
      _drawQrToCanvas(ctx, url, qrX, qrY, qrSize);

      ctx.fillStyle = t.brand;
      ctx.font = "600 28px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
      ctx.fillText(_brand.name, W / 2, qrY + qrSize + (showHeat ? 40 : 52));
      if (!showHeat) {
        ctx.fillStyle = t.scan;
        ctx.font = "400 23px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
        ctx.fillText(I18n.t("share.scorecard.poster.scan"), W / 2, qrY + qrSize + 86);
      }
    } else {
      ctx.fillStyle = t.brand;
      ctx.font = "600 34px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
      ctx.fillText(_brand.name, W / 2, qrY + 40);
    }

    return canvas.toDataURL("image/png");
  }

  // Draws a GitHub-contribution-style heatmap of daily token usage. Cells are
  // laid out in columns of 7 (one week per column), oldest → newest. Color
  // Draws a calendar-style heatmap of daily token usage: 7 columns (Sun→Sat),
  // one week per row, aligned to real weekdays. Color ramps with usage via the
  // theme's `heat` scale. Returns the Y just below it.
  function _drawHeatmap(ctx, W, top, t) {
    const days = _scorecard.heatmap;
    const heat = t.heat || { empty: "rgba(255,255,255,0.08)", scale: ["#9be9a8", "#40c463", "#30a14e", "#216e39", "#0a4020"] };
    const cols = 7;
    const gap = 6;
    const cell = 30;
    const gridW = cols * cell + (cols - 1) * gap;
    const x0 = (W - gridW) / 2;

    // Title above the grid.
    ctx.textAlign = "center";
    ctx.fillStyle = t.metricLabel;
    ctx.font = "400 24px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
    ctx.fillText(I18n.t("share.scorecard.poster.heatmapLabel"), W / 2, top);

    const gridTop = top + 18;
    const maxTok = Math.max.apply(null, days.map((d) => d.tokens).concat([1]));

    // Weekday offset of the first day so columns line up with real weekdays.
    const firstDow = days.length ? new Date(days[0].date + "T00:00:00").getDay() : 0;
    let maxRow = 0;

    days.forEach((d, i) => {
      const slot = firstDow + i;
      const col = slot % cols;
      const row = Math.floor(slot / cols);
      if (row > maxRow) maxRow = row;
      const x = x0 + col * (cell + gap);
      const y = gridTop + row * (cell + gap);
      let color = heat.empty;
      if (d.tokens > 0) {
        const ratio = d.tokens / maxTok;
        const idx = ratio >= 0.75 ? 4 : ratio >= 0.5 ? 3 : ratio >= 0.25 ? 2 : ratio >= 0.08 ? 1 : 0;
        color = heat.scale[idx];
      }
      ctx.fillStyle = color;
      _roundRect(ctx, x, y, cell, cell, 6);
      ctx.fill();
    });

    return gridTop + (maxRow + 1) * (cell + gap) - gap;
  }

  // Draws `text` centered at cx, fitting within (maxWidth × maxHeight) starting
  // at startY. Picks the largest font (from a descending ladder) whose wrapped
  // lines fit the height, honoring explicit "\n" breaks. Vertically centers.
  function _drawAutoText(ctx, text, cx, startY, maxWidth, maxHeight) {
    const sizes = [40, 36, 32, 28, 24, 20];
    let chosen = null;
    for (const size of sizes) {
      ctx.font = "500 " + size + "px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
      const lh = Math.round(size * 1.4);
      const lines = _wrapLines(ctx, text, maxWidth);
      if (lines.length * lh <= maxHeight || size === sizes[sizes.length - 1]) {
        chosen = { size, lh, lines };
        break;
      }
    }
    ctx.font = "500 " + chosen.size + "px -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif";
    const totalH = chosen.lines.length * chosen.lh;
    let y = startY + (maxHeight - totalH) / 2 + chosen.lh * 0.75;
    for (const line of chosen.lines) {
      ctx.fillText(line, cx, y);
      y += chosen.lh;
    }
  }

  // Wraps text into lines fitting maxWidth, honoring explicit "\n" breaks.
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

  function _roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // Paints a richer-than-flat poster background: base diagonal gradient, soft
  // radial color glows, and a faint grid. Deterministic (no randomness) so the
  // poster is reproducible and white-label safe.
  function _paintBackground(ctx, W, H, t, base) {
    const baseGrad = ctx.createLinearGradient(0, 0, W, H);
    baseGrad.addColorStop(0, base[0]);
    baseGrad.addColorStop(1, base[1]);
    ctx.fillStyle = baseGrad;
    ctx.fillRect(0, 0, W, H);

    const diag = Math.sqrt(W * W + H * H);
    (t.glows || []).forEach((g) => {
      const cx = g.x * W, cy = g.y * H, radius = g.r * diag * 0.5;
      const rg = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius);
      rg.addColorStop(0, g.color);
      rg.addColorStop(1, "rgba(0,0,0,0)");
      ctx.fillStyle = rg;
      ctx.fillRect(0, 0, W, H);
    });

    if (t.grid) {
      ctx.strokeStyle = t.grid;
      ctx.lineWidth = 1;
      const step = 48;
      ctx.beginPath();
      for (let x = step; x < W; x += step) { ctx.moveTo(x, 0); ctx.lineTo(x, H); }
      for (let y = step; y < H; y += step) { ctx.moveTo(0, y); ctx.lineTo(W, y); }
      ctx.stroke();
    }

    // Subtle top sheen for depth.
    const sheen = ctx.createLinearGradient(0, 0, 0, H * 0.35);
    sheen.addColorStop(0, t.style === "geek" ? "rgba(255,255,255,0.06)" : "rgba(255,255,255,0.18)");
    sheen.addColorStop(1, "rgba(255,255,255,0)");
    ctx.fillStyle = sheen;
    ctx.fillRect(0, 0, W, H * 0.35);
  }

  // ── Platform actions ──────────────────────────────────────────────────
  function _copy(str) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(str).then(
        () => Modal.toast(I18n.t("share.copied"), "success"),
        () => _copyFallback(str)
      );
    } else {
      _copyFallback(str);
    }
  }

  function _copyFallback(str) {
    const ta = document.createElement("textarea");
    ta.value = str;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand("copy"); Modal.toast(I18n.t("share.copied"), "success"); }
    catch (_e) { Modal.toast(I18n.t("share.copyFailed"), "error"); }
    finally { ta.remove(); }
  }

  // Append the landing URL (when present) to a body of share text.
  function _withUrl(body) {
    const url = _shareUrl();
    return url ? `${body} ${url}`.trim() : body;
  }

  function _toWeibo(text) {
    const url = _shareUrl() || "";
    const share = "https://service.weibo.com/share/share.php?url=" +
      encodeURIComponent(url) + "&title=" + encodeURIComponent(text);
    window.open(share, "_blank", "noopener,noreferrer");
  }

  // ── Poster sharing helpers ────────────────────────────────────────────
  function _posterFilename() {
    return `${_brand.name.toLowerCase()}-${_scorecard ? "scorecard" : "share"}.png`;
  }

  function _downloadPoster(copy) {
    const a = document.createElement("a");
    a.href = _scorecard ? _buildScorecardPoster(copy) : _buildPoster(copy);
    a.download = _posterFilename();
    a.click();
  }

  function _saveDraft(text) {
    try { localStorage.setItem(DRAFT_KEY, text); } catch (_e) { /* quota, ignore */ }
  }
  function _loadDraft() {
    try { return localStorage.getItem(DRAFT_KEY) || ""; } catch (_e) { return ""; }
  }

  // ── Modal UI ──────────────────────────────────────────────────────────
  let _overlay = null;
  let _activePlatform = "weibo";

  const PLATFORMS = ["weibo", "xhs", "wechat", "bilibili"];

  function _telemetry(event, extra) {
    if (typeof fetch === "undefined") return;
    const body = JSON.stringify({ event: event, extra: extra || {} });
    fetch("/api/telemetry", { method: "POST", headers: { "Content-Type": "application/json" }, body: body }).catch(() => {});
  }

  function openModal() {
    // Tear down a stale overlay without clearing scorecard state (closeModal
    // nulls _scorecard, which openScorecard has just set).
    if (_overlay) { _overlay.remove(); _overlay = null; }

    const hasUrl = !!_shareUrl();
    const titleKey    = _scorecard ? "share.scorecard.modal.title"    : "share.modal.title";
    const subtitleKey = _scorecard ? "share.scorecard.modal.subtitle" : "share.modal.subtitle";

    _activePlatform = "weibo";

    const o = document.createElement("div");
    o.className = "share-overlay";

    const themeChips = THEME_ORDER.map((id) => {
      const th = THEMES[id];
      const on = id === _themeId() ? " is-active" : "";
      return '<button type="button" class="share-theme-chip' + on + '" data-theme="' + id + '"' +
        ' style="background:' + th.swatch + '" title="' + _esc(I18n.t(th.labelKey)) + '">' +
        '<span class="share-theme-name">' + _esc(I18n.t(th.labelKey)) + '</span></button>';
    }).join("");

    const platformTabs = PLATFORMS.map((p) => {
      const on = p === _activePlatform ? " is-active" : "";
      return '<button type="button" class="share-platform' + on + '" data-platform="' + p + '">' +
        _esc(I18n.t("share.platform." + p)) + '</button>';
    }).join("");

    // Scorecard period switcher slot (filled by renderPeriodTabs below; can be
    // re-rendered when billing hot-swaps in more periods asynchronously).

    o.innerHTML =
      '<div class="share-modal" role="dialog" aria-modal="true">' +
        '<button type="button" class="share-close" aria-label="Close">&times;</button>' +
        '<h3 class="share-title">' + _esc(I18n.t(titleKey, { brand: _brand.name })) + '</h3>' +
        '<p class="share-subtitle">' + _esc(I18n.t(subtitleKey)) + '</p>' +
        '<div class="share-body">' +
          '<div class="share-poster-wrap"><img class="share-poster-img" alt="poster"/></div>' +
          '<div class="share-controls">' +
            '<div class="share-theme-row">' +
              '<span class="share-row-label">' + _esc(I18n.t("share.theme.label")) + '</span>' +
              '<div class="share-theme-chips">' + themeChips + '</div>' +
            '</div>' +
            '<div class="share-periods-slot"></div>' +
            '<div class="share-platforms">' + platformTabs + '</div>' +
            '<div class="share-editor">' +
              '<div class="share-editor-head">' +
                '<span class="share-row-label">' + _esc(I18n.t("share.editor.label")) + '</span>' +
                '<button type="button" class="share-shuffle" data-act="shuffle">🎲 ' + _esc(I18n.t("share.action.shuffle")) + '</button>' +
              '</div>' +
              '<textarea class="share-text" rows="4"></textarea>' +
            '</div>' +
            '<div class="share-actions">' +
              '<button type="button" class="share-btn-primary" data-act="primary"></button>' +
              '<button type="button" class="share-btn-secondary" data-act="copytext">' + _esc(I18n.t("share.action.copyText")) + '</button>' +
              '<button type="button" class="share-btn-secondary" data-act="download">' + _esc(I18n.t("share.action.download")) + '</button>' +
              (hasUrl ? '<button type="button" class="share-btn-secondary" data-act="copylink">' + _esc(I18n.t("share.action.copyLink")) + '</button>' : '') +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>';

    document.body.appendChild(o);
    _overlay = o;

    const img = o.querySelector(".share-poster-img");
    const textarea = o.querySelector(".share-text");

    const renderPoster = () => {
      const copy = (textarea.value || "").trim();
      try { img.src = _scorecard ? _buildScorecardPoster(copy) : _buildPoster(copy); }
      catch (_e) { o.querySelector(".share-poster-wrap").style.display = "none"; }
    };

    // Seed the editor: prefer the user's last hand-edited draft (product mode
    // only — scorecard text carries live numbers and shouldn't be stale).
    const draft = _scorecard ? "" : _loadDraft();
    textarea.value = draft || _pickCopy(_activePlatform);
    renderPoster();

    textarea.addEventListener("input", () => {
      if (!_scorecard) _saveDraft(textarea.value);
      renderPoster();
    });

    const setActivePlatform = (p) => {
      _activePlatform = p;
      o.querySelectorAll(".share-platform").forEach((b) => {
        b.classList.toggle("is-active", b.getAttribute("data-platform") === p);
      });
      textarea.value = _pickCopy(p);
      if (!_scorecard) _saveDraft(textarea.value);
      _updatePrimaryLabel(o);
      renderPoster();
    };

    o.querySelectorAll(".share-platform").forEach((b) => {
      b.onclick = () => setActivePlatform(b.getAttribute("data-platform"));
    });

    o.querySelectorAll(".share-theme-chip").forEach((chip) => {
      chip.onclick = () => {
        _setTheme(chip.getAttribute("data-theme"));
        o.querySelectorAll(".share-theme-chip").forEach((c) => {
          c.classList.toggle("is-active", c === chip);
        });
        renderPoster();
      };
    });

    const renderPeriodTabs = () => {
      const slot = o.querySelector(".share-periods-slot");
      if (!slot) return;
      const order = ["day", "week", "month"];
      const avail = _scorecard && _scorecard.periods ? _scorecard.periods : {};
      const keys = order.filter((p) => avail[p]);
      if (keys.length <= 1) { slot.innerHTML = ""; return; }
      slot.innerHTML = '<div class="share-periods">' + keys.map((p) => {
        const on = p === _scorePeriod ? " is-active" : "";
        return '<button type="button" class="share-period' + on + '" data-period="' + p + '">' +
          _esc(I18n.t("share.scorecard.period." + p)) + '</button>';
      }).join("") + '</div>';
      slot.querySelectorAll(".share-period").forEach((b) => {
        b.onclick = () => {
          _scorePeriod = b.getAttribute("data-period");
          slot.querySelectorAll(".share-period").forEach((x) => {
            x.classList.toggle("is-active", x === b);
          });
          textarea.value = _pickCopy(_activePlatform);
          renderPoster();
        };
      });
    };
    renderPeriodTabs();
    _rerenderPeriods = renderPeriodTabs;

    const close = () => closeModal();
    o.querySelector(".share-close").onclick = close;
    o.addEventListener("click", (e) => { if (e.target === o) close(); });

    o.querySelectorAll("[data-act]").forEach((btn) => {
      const act = btn.getAttribute("data-act");
      if (act === "shuffle") {
        btn.onclick = () => {
          textarea.value = _pickCopy(_activePlatform, textarea.value.trim());
          if (!_scorecard) _saveDraft(textarea.value);
          renderPoster();
        };
      } else {
        btn.onclick = () => _handleAction(act, textarea);
      }
    });

    _updatePrimaryLabel(o);
    _telemetry("share_open", { type: _scorecard ? "scorecard" : "share" });
    requestAnimationFrame(() => o.classList.add("open"));
  }

  // Primary button label/behavior depends on the active platform: Weibo gets
  // a real one-click jump; image-first platforms (xhs/wechat/bilibili) get
  // "download poster + copy text".
  function _updatePrimaryLabel(o) {
    const btn = o.querySelector('[data-act="primary"]');
    if (!btn) return;
    btn.textContent = _activePlatform === "weibo"
      ? I18n.t("share.action.toWeibo")
      : I18n.t("share.action.downloadAndCopy");
  }

  function _handleAction(act, textarea) {
    const text = (textarea && textarea.value || "").trim();
    switch (act) {
      case "copytext":
        _copy(_withUrl(text));
        break;
      case "download":
        _downloadPoster(text);
        _telemetry("share_download", { platform: _activePlatform, type: _scorecard ? "scorecard" : "share" });
        break;
      case "copylink":
        _copy(_shareUrl());
        break;
      case "primary":
        _primaryShare(text);
        break;
    }
  }

  function _primaryShare(text) {
    switch (_activePlatform) {
      case "weibo":
        _toWeibo(text);
        break;
      default:
        _downloadPoster(text);
        _copy(_withUrl(text));
        _telemetry("share_download", { platform: _activePlatform, type: _scorecard ? "scorecard" : "share" });
        Modal.toast(I18n.t("share.hint." + _activePlatform), "info");
        break;
    }
  }

  function closeModal() {
    if (!_overlay) return;
    const o = _overlay;
    _overlay = null;
    _scorecard = null;
    _scorePeriod = null;
    _rerenderPeriods = null;
    o.classList.remove("open");
    setTimeout(() => o.remove(), 200);
  }

  // ── Scorecard entry (B-line) ──────────────────────────────────────────
  // Opens the share modal in "scorecard" mode with live billing numbers.
  // stats: { period, cacheHitRate, costStr, tokensStr, requests }
  function openScorecard(stats) {
    _scorecard = stats || null;
    _scorePeriod = _scorecard
      ? (_scorecard.defaultPeriod && _scorecard.periods && _scorecard.periods[_scorecard.defaultPeriod]
          ? _scorecard.defaultPeriod
          : (_scorecard.periods ? Object.keys(_scorecard.periods)[0] : null))
      : null;
    openModal();
  }

  // Called by billing when a period's numbers arrive after the modal already
  // opened (instant-open path). Merges them and re-renders the switcher.
  function addScorecardPeriod(key, stats) {
    if (!_scorecard || !_overlay) return;
    if (!_scorecard.periods) _scorecard.periods = {};
    _scorecard.periods[key] = stats;
    if (_rerenderPeriods) _rerenderPeriods();
  }

  // ── Auto-prompt at peak-delight moments ───────────────────────────────
  // Called from ws-dispatcher on a successful `complete` event (the active
  // session the user is watching — onboarding runs in its own panel, never
  // emitting this for the chat view). Shows a gentle toast, not a modal,
  // so we never interrupt the moment.
  function maybePromptOnComplete() {
    const n = _bumpSuccessCount();
    if (_inCooldown()) return;
    if (!PROMPT_AT.includes(n)) return;

    Modal.toast(I18n.t("share.prompt.message", { brand: _brand.name }), "success", {
      duration: 8000,
      action: {
        label: I18n.t("share.prompt.action"),
        onClick: openModal
      }
    });
    // Any prompt (taken or ignored) starts the cooldown so we stay quiet
    // for the next 7 days regardless.
    _startCooldown();
  }

  function _esc(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  // ── Init ──────────────────────────────────────────────────────────────
  function init() {
    _hydrateBrand();
    const btn = document.getElementById("share-toggle-header");
    if (btn) btn.addEventListener("click", openModal);
  }

  return { init, openModal, openScorecard, addScorecardPeriod, closeModal, maybePromptOnComplete };
})();

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => Share.init());
} else {
  Share.init();
}
