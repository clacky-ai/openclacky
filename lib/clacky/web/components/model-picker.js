// ── ModelPicker — shared model dropdown component ─────────────────────────
// Renders the model list (vendor badge, price ratio, vision/remark/sub
// decorations, latency cell, sub-model toggle) plus the sub-model variant
// panel, benchmark button and generation footer. Session-specific actions
// (switching card/sub-model, running the benchmark request, opening media
// config) are injected as callbacks so the same component powers both the
// session info bar and the #new landing page.
const ModelPicker = (() => {
  // Price-ratio badges for the submodel rows. Ratios come from
  // GET /api/model_prices (backed by Clacky::ModelPricing), so the local
  // pricing table stays the single source of truth - no hardcoded JS prices.
  const _priceCache = new Map(); // model name -> { in, out, label } | null

  function _fmtRatio(ratio) {
    if (ratio >= 10) return Math.round(ratio) + "x";
    const s = ratio >= 1 ? ratio.toFixed(1) : ratio.toFixed(2);
    return s.replace(/\.?0+$/, "") + "x";
  }

  // Cache of the most recent benchmark results, keyed by model_id. Kept at
  // closure scope so the numbers survive closing & reopening the dropdown.
  let _benchCache = {};        // { [model_id]: { ttft_ms, ok, error, ts } }
  let _benchInFlight = false;  // prevent double-click spam

  // Vendor badge: brand-colored tile with the provider's mark, shown before
  // each model name. Model family wins over provider prefix ("or-gemini-…"
  // matches Gemini before the "or-" OpenRouter rule). Rules carry a real
  // brand SVG where the path stays legible at badge size; the rest (and any
  // unknown model) fall back to the provider initial on a brand-colored tile.
  const _VENDOR_RULES = [
    { re: /claude|anthropic/i,   label: "A", color: "#D97757",
      svg: '<path d="M17.3041 3.541h-3.6718l6.696 16.918H24Zm-10.6082 0L0 20.459h3.7442l1.3693-3.5527h7.0052l1.3693 3.5528h3.7442L10.5363 3.5409Zm-.3712 10.2232 2.2914-5.9456 2.2914 5.9456Z"/>' },
    { re: /deepseek/i,           label: "D", color: "#4D6BFE", viewBox: "0 1.5 27 20.5",
      svg: '<path d="M26.5174 3.39471C26.235 3.2567 26.1137 3.52006 25.9487 3.65346C25.8923 3.69659 25.8446 3.75294 25.7969 3.80469C25.3846 4.24516 24.9027 4.53439 24.2737 4.49989C23.3536 4.44814 22.5682 4.73737 21.8735 5.44119C21.7258 4.57349 21.2353 4.0554 20.4889 3.72304C20.0985 3.55054 19.7034 3.37746 19.4297 3.00197C19.2388 2.73459 19.1865 2.43673 19.091 2.14289C19.0301 1.96579 18.9697 1.78466 18.7656 1.75418C18.5442 1.71968 18.4574 1.90541 18.3705 2.06067C18.0232 2.69549 17.8887 3.39471 17.9019 4.10313C17.9324 5.6965 18.6051 6.96556 19.9421 7.86834C20.0939 7.97184 20.133 8.07535 20.0852 8.22658C19.9938 8.53766 19.8857 8.83955 19.7903 9.15063C19.7293 9.34901 19.6384 9.39271 19.4257 9.30588C18.692 8.9994 18.0583 8.54571 17.4982 7.99772C16.5477 7.07827 15.6881 6.06336 14.6162 5.26869C14.3644 5.08296 14.1125 4.91045 13.8521 4.746C12.7584 3.68394 13.9952 2.81164 14.2816 2.70814C14.5812 2.60003 14.3857 2.22857 13.4179 2.23317C12.4502 2.2372 11.5646 2.56151 10.4359 2.99335C10.2708 3.05832 10.0972 3.10547 9.91951 3.14457C8.8954 2.95022 7.83162 2.90709 6.72069 3.03245C4.62877 3.26533 2.95777 4.25436 1.72954 5.94261C0.254043 7.97184 -0.0932678 10.2777 0.33167 12.6824C0.778458 15.2171 2.07225 17.3153 4.06008 18.9558C6.12152 20.6567 8.49577 21.4905 11.2047 21.3306C12.8498 21.2358 14.6812 21.0155 16.7473 19.2669C17.2682 19.5262 17.8151 19.6297 18.7219 19.7074C19.4205 19.7723 20.0933 19.6729 20.6143 19.5648C21.4302 19.3923 21.3739 18.6367 21.0789 18.4981C18.6874 17.3843 19.2124 17.8374 18.7351 17.4706C19.9501 16.033 21.8063 13.4776 22.379 9.99821C22.4353 9.61409 22.5072 9.073 22.4986 8.76192C22.494 8.57216 22.5377 8.49856 22.7545 8.47671C23.3536 8.40771 23.935 8.24383 24.4692 7.94999C26.0188 7.10357 26.6439 5.71318 26.7911 4.04678C26.8129 3.79204 26.7865 3.52869 26.5174 3.39471ZM13.0143 18.3946C10.6964 16.5724 9.5722 15.9726 9.10816 15.9985C8.67402 16.0244 8.75222 16.5212 8.84768 16.8449C8.94773 17.1646 9.07768 17.3849 9.25996 17.6655C9.38589 17.8512 9.47272 18.1272 9.13404 18.3348C8.38766 18.7965 7.08985 18.1796 7.0289 18.1491C5.51833 17.2595 4.25559 16.0853 3.36546 14.4793C2.50581 12.9337 2.0067 11.2753 1.92447 9.50542C1.90262 9.07818 2.02855 8.92695 2.45406 8.84932C3.01413 8.74582 3.59144 8.72397 4.15093 8.80619C6.51656 9.15178 8.53027 10.2092 10.2185 11.8848C11.1822 12.8388 11.9114 13.979 12.6623 15.0929C13.461 16.2757 14.3201 17.4027 15.4144 18.3268C15.8008 18.6505 16.109 18.8966 16.404 19.0783C15.5144 19.1778 14.0297 19.1991 13.0143 18.3958V18.3946ZM14.1252 11.2489C14.1252 11.0591 14.277 10.9079 14.4679 10.9079C14.511 10.9079 14.5501 10.9165 14.5852 10.9292C14.6329 10.9464 14.6766 10.9723 14.7111 11.0114C14.7721 11.0718 14.8066 11.158 14.8066 11.2489C14.8066 11.4386 14.6548 11.5899 14.4639 11.5899C14.273 11.5899 14.1252 11.4386 14.1252 11.2489ZM17.5759 13.0188C17.3545 13.1096 17.1331 13.1873 16.9203 13.1959C16.5903 13.2131 16.2303 13.0791 16.0348 12.9153C15.7312 12.6605 15.5139 12.5179 15.423 12.0734C15.3839 11.8837 15.4057 11.5899 15.4402 11.4214C15.5185 11.0585 15.4316 10.8257 15.1757 10.614C14.9676 10.4415 14.7025 10.3938 14.4115 10.3938C14.3029 10.3938 14.2034 10.3461 14.1292 10.3076C14.0079 10.2472 13.9078 10.096 14.0033 9.91023C14.0338 9.84985 14.1815 9.70322 14.216 9.67734C14.6111 9.45251 15.0665 9.52612 15.488 9.6946C15.8784 9.85445 16.174 10.1477 16.5989 10.5623C17.033 11.0631 17.1112 11.2011 17.3585 11.5772C17.554 11.871 17.7317 12.1729 17.8536 12.5185C17.9272 12.7341 17.8317 12.9107 17.5759 13.0188Z"/>' },
    { re: /glm|zhipu|bigmodel/i, label: "Z", color: "#131212", viewBox: "0 0 32 27",
      svg: '<path d="M16.5376 0.0307374L14.3326 3.13223C14.1617 3.37577 13.9331 3.57415 13.6667 3.71001C13.4004 3.84586 13.1045 3.91504 12.8048 3.9115H0.787598V0.015152H16.5376V0.0307374Z"/><path d="M31.5 0.0321655L12.6 26.5273H0L18.9 0.0321655H31.5Z"/><path d="M14.9624 26.5272L17.1832 23.4101C17.3564 23.1689 17.5856 22.9723 17.8513 22.8368C18.1171 22.7012 18.4119 22.6306 18.7109 22.6308H30.7124V26.5272H14.9624Z"/>' },
    { re: /gemini/i,             label: "G", color: "#3B78E7",
      svg: '<path d="M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"/>' },
    { re: /gpt|openai/i,         label: "O", color: "#10A37F" },
    { re: /minimax/i,            label: "M", color: "#F2402A",
      svg: '<path style="fill:none;stroke:currentColor;stroke-width:2.4;stroke-linecap:round" d="M4 9.5V14.5M8 6V18M12 3V21M16 6V18M20 9.5V14.5"/>' },
    { re: /qwen|tongyi/i,        label: "Q", color: "#615CED" },
    { re: /kimi|moonshot/i,      label: "K", color: "#111827" },
    { re: /grok|xai/i,           label: "X", color: "#111827",
      svg: '<path d="M14.234 10.162 22.977 0h-2.072l-7.591 8.824L7.251 0H.258l9.168 13.343L.258 24H2.33l8.016-9.318L16.749 24h6.993zm-2.837 3.299-.929-1.329L3.076 1.56h3.182l5.965 8.532.929 1.329 7.754 11.09h-3.182z"/>' },
    { re: /doubao/i,             label: "D", color: "#3370FF" },
    { re: /ark|volces/i,         label: "V", color: "#0F6BFF" },
    { re: /llama/i,              label: "L", color: "#0866FF" },
    { re: /mistral/i,            label: "M", color: "#F26B1D",
      svg: '<path d="M17.143 3.429v3.428h-3.429v3.429h-3.428V6.857H6.857V3.43H3.43v13.714H0v3.428h10.286v-3.428H6.857v-3.429h3.429v3.429h3.429v-3.429h3.428v3.429h-3.428v3.428H24v-3.428h-3.43V3.429z"/>' },
    { re: /hunyuan/i,            label: "H", color: "#0052FF" },
    { re: /ernie|wenxin/i,       label: "E", color: "#2932E1" },
    { re: /^or-|openrouter/i,    label: "R", color: "#5A6B7B" },
  ];

  function vendorBadge(name) {
    const s = String(name || "").trim();
    const rule = _VENDOR_RULES.find(r => r.re.test(s));
    const el = document.createElement("span");
    el.className = "sib-vendor-badge";
    el.style.setProperty("--vendor-color", rule ? rule.color : "#7A8B99");
    if (rule && rule.svg) {
      el.innerHTML = '<svg viewBox="' + (rule.viewBox || "0 0 24 24") + '" aria-hidden="true">' + rule.svg + '</svg>';
    } else {
      el.textContent = rule ? rule.label : (s.charAt(0).toUpperCase() || "?");
    }
    return el;
  }

  // Fetches ratios for names not yet cached. Rows simply stay blank when
  // the request fails (offline, unknown model).
  async function loadPriceRatios(names) {
    const missing = Array.from(new Set(names.filter(Boolean).filter((n) => !_priceCache.has(n))));
    if (!missing.length) return;
    try {
      const res = await fetch("/api/model_prices?models=" + encodeURIComponent(missing.join(",")));
      if (!res.ok) return;
      const data = await res.json();
      missing.forEach((n) => {
        const p = data && data.prices && data.prices[n];
        _priceCache.set(n, p ? { in: p.in, out: p.out, label: _fmtRatio(p.ratio) } : null);
      });
    } catch (e) {
      /* network error - leave prices hidden */
    }
  }

  function getPrice(name) {
    return _priceCache.get(name) || null;
  }

  // Render one latency cell based on a cached result.
  //   undefined    → empty slot
  //   { ok:true }  → "812ms" in green/amber/red per threshold
  //   { ok:false } → "✕" with error in tooltip
  //   { pending:true } → "…" spinner-ish marker
  function fillLatencyCell(el, entry) {
    el.className = "sib-model-latency";
    el.textContent = "";
    el.removeAttribute("title");
    if (!entry) return;
    if (entry.pending) {
      el.textContent = "…";
      el.classList.add("is-pending");
      return;
    }
    if (!entry.ok) {
      el.textContent = "✕";
      el.classList.add("is-err");
      el.title = entry.error || "failed";
      return;
    }
    const ms = entry.ttft_ms;
    // Same thresholds as the sib-signal status bar — keep them aligned.
    let cls = "is-bad";
    if      (ms <= 2000)   cls = "is-ok";
    else if (ms <= 60000)  cls = "is-ok";
    else if (ms <= 120000) cls = "is-warn";
    el.classList.add(cls);
    el.textContent = ms >= 1000 ? (ms / 1000).toFixed(1) + "s" : ms + "ms";
    if (typeof I18n !== "undefined") {
      el.title = I18n.t("sib.bench.latencyTooltip", {
        ttft: el.textContent,
        time: new Date(entry.ts).toLocaleTimeString(),
      });
    } else {
      el.title = `TTFT ${el.textContent} · tested ${new Date(entry.ts).toLocaleTimeString()}`;
    }
  }

  // ── Sub-model variant panel ─────────────────────────────────────────────
  let _activeSubmodelAnchor = null;

  function closeSubmodelPanel() {
    const panel = document.getElementById("sib-submodel-panel");
    if (panel) panel.style.display = "none";
    if (_activeSubmodelAnchor) {
      const btn = _activeSubmodelAnchor.querySelector(".sib-submodel-toggle");
      if (btn) btn.setAttribute("aria-expanded", "false");
      _activeSubmodelAnchor.classList.remove("submodel-open");
      _activeSubmodelAnchor = null;
    }
  }

  function _renderSubmodelPanel(panel, subInfo, onSwitchSubModel) {
    panel.innerHTML = "";

    const header = document.createElement("div");
    header.className = "sib-submodel-panel-header";
    header.textContent = I18n.t("sib.variant.header");
    if (subInfo.cardModel) {
      const cardName = document.createElement("span");
      cardName.className = "sib-submodel-panel-model";
      cardName.textContent = subInfo.cardModel;
      header.appendChild(cardName);
    }
    panel.appendChild(header);

    const cardDefault = subInfo.cardModel;
    subInfo.options.forEach(name => {
      const row = document.createElement("div");
      row.className = "sib-submodel-row";
      row.dataset.subModel = name;

      const isActive = subInfo.current
        ? name === subInfo.current
        : name === cardDefault;
      if (isActive) row.classList.add("current");

      const nameEl = document.createElement("span");
      nameEl.className = "sib-submodel-row-name";
      nameEl.appendChild(vendorBadge(name));
      const nameText = document.createElement("span");
      nameText.className = "sib-submodel-row-text";
      nameText.textContent = name;
      nameEl.appendChild(nameText);
      row.appendChild(nameEl);

      const rightBox = document.createElement("span");
      rightBox.style.cssText = "display:inline-flex;align-items:center;gap:0.375rem;flex-shrink:0;";

      const priceEl = document.createElement("span");
      priceEl.className = "sib-model-price";
      rightBox.appendChild(priceEl);

      if (name === cardDefault) {
        const tag = document.createElement("span");
        tag.className = "sib-submodel-default-tag";
        tag.textContent = I18n.t("sib.variant.default");
        rightBox.appendChild(tag);
      }
      row.appendChild(rightBox);

      row.addEventListener("click", (ev) => {
        ev.stopPropagation();
        const passName = (name === cardDefault) ? null : name;
        onSwitchSubModel(passName, name);
      });
      panel.appendChild(row);
    });

    _fillSubmodelPrices(panel);
  }

  // Ratio text fills in asynchronously once /api/model_prices responds
  // (cached afterwards, so re-opening the panel shows prices instantly).
  async function _fillSubmodelPrices(panel) {
    const rows = Array.from(panel.querySelectorAll(".sib-submodel-row"));
    await loadPriceRatios(rows.map((r) => r.dataset.subModel));
    rows.forEach((row) => {
      const price = _priceCache.get(row.dataset.subModel);
      const el = row.querySelector(".sib-model-price");
      if (!price || !el || el.textContent) return;
      el.textContent = price.label;
      el.title = I18n.t("sib.price.tip", { in: price.in, out: price.out });
    });
  }

  function _toggleSubmodelPanel(container, anchorRow, btn, subInfo, onSwitchSubModel) {
    const panel = document.getElementById("sib-submodel-panel");
    if (!panel || !container) return;

    if (panel.parentElement !== document.body) {
      document.body.appendChild(panel);
    }

    const isOpen = panel.style.display !== "none" && _activeSubmodelAnchor === anchorRow;
    if (isOpen) {
      closeSubmodelPanel();
      return;
    }

    _renderSubmodelPanel(panel, subInfo, onSwitchSubModel);

    // Reset any prior position so measurements are accurate.
    panel.style.left = "0px";
    panel.style.top = "0px";
    panel.style.display = "block";
    panel.style.visibility = "hidden";

    const dropRect = container.getBoundingClientRect();
    const btnRect = btn.getBoundingClientRect();
    const panelRect = panel.getBoundingClientRect();
    const gap = 6;
    const margin = 8;
    const vw = window.innerWidth;
    const vh = window.innerHeight;

    // Prefer right of dropdown; flip to left if we'd overflow viewport.
    let left = dropRect.right + gap;
    if (left + panelRect.width > vw - margin) {
      left = dropRect.left - panelRect.width - gap;
    }
    if (left < margin) left = margin;

    let top = btnRect.top - 6;
    if (top + panelRect.height > vh - margin) {
      top = vh - margin - panelRect.height;
    }
    if (top < margin) top = margin;

    panel.style.left = `${left}px`;
    panel.style.top = `${top}px`;
    panel.style.visibility = "";

    _activeSubmodelAnchor = anchorRow;
    anchorRow.classList.add("submodel-open");
    btn.setAttribute("aria-expanded", "true");
  }

  // ── Benchmark runner ────────────────────────────────────────────────────
  async function _runBenchmark(container, btn, label, hint, onBenchmark) {
    if (_benchInFlight) return;
    _benchInFlight = true;
    btn.disabled = true;
    const origLabel = label.textContent;
    const _t = (key, vars) => (typeof I18n !== "undefined") ? I18n.t(key, vars) : key;
    label.textContent = _t("sib.bench.running");
    hint.textContent = "";

    // Mark every row as pending so the user sees instant feedback.
    container.querySelectorAll(".sib-model-option").forEach(opt => {
      const id = opt.dataset.modelId;
      if (!id) return;
      _benchCache[id] = { pending: true };
      fillLatencyCell(opt.querySelector(".sib-model-latency"), _benchCache[id]);
    });

    const t0 = performance.now();
    try {
      const results = await onBenchmark();
      const now = Date.now();
      (results || []).forEach(r => {
        _benchCache[r.model_id] = {
          ok: !!r.ok,
          ttft_ms: r.ttft_ms,
          error: r.error,
          ts: now,
        };
        const opt = container.querySelector(`.sib-model-option[data-model-id="${CSS.escape(r.model_id)}"]`);
        if (opt) fillLatencyCell(opt.querySelector(".sib-model-latency"), _benchCache[r.model_id]);
      });

      const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
      hint.textContent = _t("sib.bench.done", { t: elapsed });
    } catch (e) {
      console.error("Benchmark failed:", e);
      hint.textContent = _t("sib.bench.failed", { msg: e.message });
      container.querySelectorAll(".sib-model-option").forEach(opt => {
        const id = opt.dataset.modelId;
        if (id && _benchCache[id] && _benchCache[id].pending) {
          _benchCache[id] = undefined;
          fillLatencyCell(opt.querySelector(".sib-model-latency"), undefined);
        }
      });
    } finally {
      _benchInFlight = false;
      btn.disabled = false;
      label.textContent = origLabel;
    }
  }

  // ── Generation footer ───────────────────────────────────────────────────
  function _renderFooter(container, mediaCaps, onConfigureMedia) {
    const kinds = ["image", "video", "audio"];
    const footer = document.createElement("div");
    footer.className = "sib-gen-footer";

    const list = document.createElement("span");
    list.className = "sib-gen-list";
    kinds.forEach(k => {
      const cap = mediaCaps[k] || {};
      const ok = !!cap.configured;
      const chip = document.createElement("span");
      chip.className = "sib-gen-chip " + (ok ? "is-ok" : "is-off");
      chip.textContent = (ok ? "✓ " : "") + I18n.t(`sib.gen.kind.${k}`);
      chip.title = ok
        ? I18n.t("sib.gen.okTip", { model: cap.model || "" })
        : I18n.t("sib.gen.offTip");
      list.appendChild(chip);
    });
    footer.appendChild(list);

    const configBtn = document.createElement("button");
    configBtn.type = "button";
    configBtn.className = "sib-gen-config";
    configBtn.textContent = I18n.t("sib.gen.config");
    configBtn.title = I18n.t("sib.gen.offTip");
    configBtn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      onConfigureMedia();
    });
    footer.appendChild(configBtn);

    container.appendChild(footer);
  }

  // ── Main entry point ────────────────────────────────────────────────────
  // opts:
  //   models           [{id, model, type, remark, base_url, api_key_masked, ...}]
  //   currentId        id of the currently-selected model
  //   onSelect(model)  selection callback (required)
  //   mediaCaps        {vision, image, video, audio} — enables vision badge + footer
  //   subInfo          {options, current, cardModel} — enables sub-model panel
  //   onSwitchSubModel (name|null, displayName) — required when subInfo given
  //   onBenchmark      async () => [{model_id, ok, ttft_ms, error}] — enables ⚡
  //   onConfigureMedia () => void — required when mediaCaps given
  async function populate(container, opts) {
    const {
      models, currentId, onSelect,
      mediaCaps, subInfo, onSwitchSubModel,
      onBenchmark, onConfigureMedia,
    } = opts;

    container.innerHTML = "";

    // Benchmark floating button (top-right of dropdown).
    if (onBenchmark) {
      const bench = document.createElement("div");
      bench.className = "sib-model-bench";
      const btnLabel   = (typeof I18n !== "undefined") ? I18n.t("sib.bench.btn")     : "Benchmark";
      const btnTooltip = (typeof I18n !== "undefined") ? I18n.t("sib.bench.tooltip") : "Test response latency for every configured model";
      bench.innerHTML = `
        <button type="button" class="sib-bench-btn" title="${btnTooltip}">⚡ <span class="sib-bench-label">${btnLabel}</span></button>
        <span class="sib-bench-hint"></span>
      `;
      container.appendChild(bench);

      const benchBtn   = bench.querySelector(".sib-bench-btn");
      const benchLabel = bench.querySelector(".sib-bench-label");
      const benchHint  = bench.querySelector(".sib-bench-hint");
      benchBtn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        _runBenchmark(container, benchBtn, benchLabel, benchHint, onBenchmark);
      });
    }

    // Model rows.
    const _nameCounts = models.reduce((acc, m) => {
      acc[m.model] = (acc[m.model] || 0) + 1;
      return acc;
    }, {});

    models.forEach(m => {
      const opt = document.createElement("div");
      opt.className = "sib-model-option";
      opt.dataset.modelId = m.id;
      if (m.id === currentId) opt.classList.add("current");

      const left = document.createElement("span");
      left.className = "sib-model-name";

      const nameLine = document.createElement("span");
      nameLine.className = "sib-model-name-main";
      // When a non-default quick-switch model is active, show only that
      // model's name (avoid the long "main → quick-switch" truncated string).
      const hasActiveOverride =
        m.id === currentId &&
        subInfo && subInfo.current &&
        subInfo.current !== subInfo.cardModel;
      const displayName = hasActiveOverride ? subInfo.current : m.model;
      nameLine.appendChild(vendorBadge(displayName));
      const nameText = document.createElement("span");
      nameText.className = "sib-model-name-text";
      nameText.textContent = displayName;
      nameLine.appendChild(nameText);
      left.appendChild(nameLine);

      // Vision status for the active model only.
      if (m.id === currentId && mediaCaps && mediaCaps.vision) {
        const ok = !!mediaCaps.vision.configured;
        const vis = document.createElement("span");
        vis.className = "sib-model-vision " + (ok ? "is-ok" : "is-missing");
        vis.textContent = ok ? I18n.t("sib.vision.ok") : I18n.t("sib.vision.missing");
        vis.title = ok ? I18n.t("sib.vision.okTip") : I18n.t("sib.vision.missingTip");
        nameLine.appendChild(vis);
      }

      // Distinguish rows that would otherwise look identical.
      const remark = (m.remark || "").trim();
      if (remark || _nameCounts[m.model] > 1) {
        left.classList.add("has-sub");
        const host = (() => {
          try { return new URL(m.base_url).host; } catch { return m.base_url || ""; }
        })();
        const subBits = [remark, host, m.api_key_masked].filter(Boolean);
        if (subBits.length) {
          const subLine = document.createElement("span");
          subLine.className = "sib-model-name-sub";
          subLine.textContent = subBits.join(" · ");
          left.appendChild(subLine);
          opt.title = `${m.model} · ${subBits.join(" · ")}`;
        }
      }

      opt.appendChild(left);

      const right = document.createElement("span");
      right.className = "sib-model-right";

      if (m.id === currentId) {
        const check = document.createElement("span");
        check.className = "sib-model-check";
        check.innerHTML =
          '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">' +
          '<path d="M3 8.5L6.5 12L13 4.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>' +
          '</svg>';
        right.appendChild(check);
      }

      if (m.type === "default") {
        const badge = document.createElement("span");
        badge.className = `model-badge ${m.type}`;
        badge.textContent = m.type;
        right.appendChild(badge);
      }

      if (onBenchmark) {
        const lat = document.createElement("span");
        lat.className = "sib-model-latency";
        fillLatencyCell(lat, _benchCache[m.id]);
        right.appendChild(lat);
      }

      const hasSubModels =
        m.id === currentId &&
        subInfo && subInfo.options &&
        subInfo.options.length > 1;

      if (hasSubModels && onSwitchSubModel) {
        const toggleBtn = document.createElement("button");
        toggleBtn.type = "button";
        toggleBtn.className = "sib-submodel-toggle";
        toggleBtn.title = I18n.t("sib.variant.header");
        toggleBtn.setAttribute("aria-expanded", "false");
        toggleBtn.innerHTML =
          '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">' +
          '<path d="M6 3.5L10.5 8 6 12.5" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>' +
          '</svg>';
        right.appendChild(toggleBtn);

        toggleBtn.addEventListener("click", (ev) => {
          ev.stopPropagation();
          _toggleSubmodelPanel(container, opt, toggleBtn, subInfo, onSwitchSubModel);
        });
      }

      opt.appendChild(right);

      opt.addEventListener("click", () => onSelect(m));
      container.appendChild(opt);
    });

    // Generation footer.
    if (mediaCaps && onConfigureMedia) {
      _renderFooter(container, mediaCaps, onConfigureMedia);
    }
  }

  return {
    vendorBadge,
    loadPriceRatios,
    getPrice,
    populate,
    closeSubmodelPanel,
  };
})();
