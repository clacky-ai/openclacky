// ── Billing · view — dashboard rendering, charts, tooltips, DOM wiring ─────
//
// Owns every render function (stats, heatmap, trend, breakdowns, sessions),
// tooltip binding. Reads through BillingStore.state
// and currency helpers; period / model / share go through store actions.
//
// Augments the `Billing` facade with onPanelShow.
//
// Depends on: BillingStore, I18n, Share (optional).
// ───────────────────────────────────────────────────────────────────────────

const BillingView = (() => {

  // ── Loading / error ───────────────────────────────────────────────────────

  function _onLoading(payload) {
    const container = document.getElementById("billing-content");
    if (!container) return;

    if (payload.isFirstLoad) {
      container.innerHTML = _renderSkeleton();
      return;
    }
    const existing = container.querySelector(".billing-dashboard");
    if (existing && !existing.querySelector(".billing-skel-overlay")) {
      const topBar = existing.querySelector(".billing-top-bar");
      const topBarH = topBar ? topBar.offsetHeight + 20 : 0;
      existing.insertAdjacentHTML("beforeend", `<div class="billing-skel-overlay" style="top:${topBarH}px">${_renderSkeletonBody()}</div>`);
    }
  }

  function _onError(payload) {
    const container = document.getElementById("billing-content");
    if (container) container.innerHTML = `<div class="billing-error">${I18n.t("billing.error") || "Failed to load billing data"}: ${payload.message}</div>`;
  }

  function _onActionError(payload) {
    alert(payload.message);
  }

  // ── Skeletons ─────────────────────────────────────────────────────────────

  function _renderSkeletonBody() {
    return `
      <div class="billing-stats-row">
        ${[0,1,2,3].map(() => `
          <div class="billing-stat-card">
            <div class="skel skel-icon"></div>
            <div class="billing-stat-content">
              <div class="skel skel-value"></div>
              <div class="skel skel-label"></div>
            </div>
          </div>
        `).join("")}
      </div>
      <div class="billing-heatmap-row">
        <div class="billing-chart-card billing-heatmap-card">
          <div class="skel skel-heatmap"></div>
        </div>
        <div class="billing-chart-card billing-trend-card">
          <div class="skel skel-block-sm"></div>
        </div>
      </div>
      <div class="billing-bottom-grid">
        <div class="billing-section"><div class="skel skel-block"></div></div>
        <div class="billing-section"><div class="skel skel-block"></div></div>
      </div>
    `;
  }

  function _renderSkeleton() {
    return `
      <div class="billing-dashboard billing-skeleton">
        <div class="billing-top-bar">
          <div class="billing-title-row">
            <div class="skel skel-title"></div>
            <div class="skel skel-subtitle"></div>
          </div>
          <div class="billing-controls">
            <div class="skel skel-tabs"></div>
            <div class="skel skel-select"></div>
          </div>
        </div>
        <div class="billing-stats-row">
          ${[0,1,2,3].map(() => `
            <div class="billing-stat-card">
              <div class="skel skel-icon"></div>
              <div class="billing-stat-content">
                <div class="skel skel-value"></div>
                <div class="skel skel-label"></div>
              </div>
            </div>
          `).join("")}
        </div>
        <div class="billing-heatmap-row">
          <div class="billing-chart-card billing-heatmap-card">
            <div class="skel skel-heatmap"></div>
          </div>
          <div class="billing-chart-card billing-trend-card">
            <div class="skel skel-block-sm"></div>
          </div>
        </div>
        <div class="billing-bottom-grid">
          <div class="billing-section"><div class="skel skel-block"></div></div>
          <div class="billing-section"><div class="skel skel-block"></div></div>
        </div>
      </div>
    `;
  }

  // ── Main render ─────────────────────────────────────────────────────────────

  function _render() {
    const container = document.getElementById("billing-content");
    const summary = BillingStore.state.summary;
    if (!container || !summary) return;

    const periods = ["day", "week", "month", "year", "all"];
    const periodBtns = periods.map(p =>
      `<button class="segmented-control__btn ${p === BillingStore.state.currentPeriod ? 'active' : ''}" data-period="${p}">${_periodLabel(p)}</button>`
    ).join("");

    const allModels = BillingStore.state.allModels;
    const models = allModels.length > 0 ? allModels : (summary.by_model ? Object.keys(summary.by_model) : []);
    const modelOptions = [`<option value="all">${I18n.t("billing.allModels") || "All Models"}</option>`]
      .concat(models.filter(m => m).map(m => `<option value="${_esc(m)}" ${m === BillingStore.state.currentModel ? "selected" : ""}>${_esc(m)}</option>`))
      .join("");

    container.innerHTML = `
      <div class="billing-dashboard">
        <div class="billing-top-bar">
          <div class="billing-title-row">
            <h2>${I18n.t("billing.title") || "Usage"}</h2>
            <span class="billing-subtitle">${_getSummaryHint()}</span>
          </div>
          <div class="billing-controls">
            <div class="segmented-control">${periodBtns}</div>
            <select id="billing-model-filter" class="billing-model-filter">${modelOptions}</select>
            <button id="billing-share-btn" class="billing-share-btn" title="${I18n.t('billing.share.tooltip') || 'Share scorecard'}">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><polyline points="16 6 12 2 8 6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><line x1="12" y1="2" x2="12" y2="15" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
              ${I18n.t('billing.share.btn') || 'Share scorecard'}
            </button>
          </div>
        </div>

        <div class="billing-disclaimer">
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.4"/><path d="M8 7v4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="5" r="0.7" fill="currentColor"/></svg>
          ${I18n.t("billing.disclaimer")}
        </div>

        <div class="billing-stats-row">
          <div class="billing-stat-card">
            <div class="billing-stat-icon billing-stat-icon-cost">
              <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="10" cy="10" r="8" stroke="currentColor" stroke-width="1.5"/><path d="M10 6v1m0 6v1M7.5 10a2.5 2.5 0 0 0 2.5 2.5c1.38 0 2.5-.56 2.5-1.25S11.38 10 10 10c-1.38 0-2.5-.56-2.5-1.25S8.62 7.5 10 7.5A2.5 2.5 0 0 1 12.5 10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
            </div>
            <div class="billing-stat-content">
              <div class="billing-stat-value">${Billing.getCurrencySymbol()}${_formatCost(Billing.convertCost(summary.total_cost))}</div>
              <div class="billing-stat-label">${I18n.t("billing.totalCost") || "Total Cost"}</div>
            </div>
          </div>
          <div class="billing-stat-card">
            <div class="billing-stat-icon billing-stat-icon-tokens">
              <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg"><rect x="3" y="11" width="3" height="6" rx="1" fill="currentColor" opacity=".4"/><rect x="8.5" y="7" width="3" height="10" rx="1" fill="currentColor" opacity=".7"/><rect x="14" y="3" width="3" height="14" rx="1" fill="currentColor"/></svg>
            </div>
            <div class="billing-stat-content">
              <div class="billing-stat-value">${_formatCompact(summary.total_tokens)}</div>
              <div class="billing-stat-label">${I18n.t("billing.totalTokens") || "Total Tokens"}</div>
            </div>
          </div>
          <div class="billing-stat-card">
            <div class="billing-stat-icon billing-stat-icon-requests">
              <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M10 3a7 7 0 1 1 0 14A7 7 0 0 1 10 3Z" stroke="currentColor" stroke-width="1.5"/><path d="M10 7v3l2 2" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
            </div>
            <div class="billing-stat-content">
              <div class="billing-stat-value">${_formatNumber(summary.record_count)}</div>
              <div class="billing-stat-label">${I18n.t("billing.requests") || "Requests"}</div>
            </div>
          </div>
          <div class="billing-stat-card">
            <div class="billing-stat-icon billing-stat-icon-cache">
              <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M10 2L3 11h6l-1 7 8-10h-6l1-6z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/></svg>
            </div>
            <div class="billing-stat-content">
              <div class="billing-stat-value">${_getCacheHitRate()}%</div>
              <div class="billing-stat-label">${I18n.t("billing.cacheHit") || "Cache Hit"}</div>
            </div>
          </div>
        </div>

        <div class="billing-heatmap-row">
          ${_renderHeatmap()}
          ${_renderCostTrend()}
        </div>

        <div class="billing-bottom-grid">
          ${_renderTokenBreakdown()}
          ${_renderModelBreakdown()}
        </div>

        <div class="billing-chart-row">
          ${_renderCombinedChart()}
        </div>
      </div>
    `;

    document.querySelectorAll(".segmented-control__btn").forEach(btn => {
      btn.addEventListener("click", (e) => Billing.setPeriod(e.target.dataset.period));
    });

    document.getElementById("billing-model-filter")?.addEventListener("change", (e) => {
      Billing.setModel(e.target.value);
    });

    document.getElementById("billing-share-btn")?.addEventListener("click", _openScorecardShare);

    _bindChartTooltip();
    _bindHeatmapTooltip();
    _bindTrendTooltip();
  }

  // ── Scorecard ───────────────────────────────────────────────────────────────

  function _scorecardStatsFor(summary, periodKey) {
    return {
      key:          periodKey,
      period:       _periodLabel(periodKey),
      cacheHitRate: _cacheHitRateOf(summary),
      costStr:      `${Billing.getCurrencySymbol()}${_formatCost(Billing.convertCost(summary.total_cost || 0))}`,
      tokensStr:    _formatCompact(summary.total_tokens || 0),
      requests:     _formatNumber(summary.record_count || 0)
    };
  }

  function _cacheHitRateOf(summary) {
    const prompt = summary.prompt_tokens || 0;
    const cacheRead = summary.cache_read_tokens || 0;
    return prompt === 0 ? "0" : Math.min((cacheRead / prompt) * 100, 100).toFixed(1);
  }

  function _heatmapDays() {
    return (BillingStore.state.daily || []).map((d) => ({
      date:   d.date,
      tokens: (d.prompt_tokens || 0) + (d.completion_tokens || 0),
      cost:   d.cost || 0
    }));
  }

  function _openScorecardShare() {
    const summary = BillingStore.state.summary;
    if (!summary || typeof Share === "undefined" || !Share.openScorecard) return;
    const currentPeriod = BillingStore.state.currentPeriod;

    const periods = {};
    periods[currentPeriod] = _scorecardStatsFor(summary, currentPeriod);

    Share.openScorecard({
      periods:       periods,
      defaultPeriod: currentPeriod,
      heatmap:       _heatmapDays(),
      period:        periods[currentPeriod].period,
      cacheHitRate:  periods[currentPeriod].cacheHitRate,
      costStr:       periods[currentPeriod].costStr,
      tokensStr:     periods[currentPeriod].tokensStr,
      requests:      periods[currentPeriod].requests
    });

    const others = ["day", "week", "month"].filter((p) => p !== currentPeriod);
    others.forEach((p) => {
      Billing.fetchSummary(p)
        .then((summary) => {
          if (Share.addScorecardPeriod) Share.addScorecardPeriod(p, _scorecardStatsFor(summary, p));
        })
        .catch(() => {});
    });
  }

  // ── Tooltips ─────────────────────────────────────────────────────────────────

  function _bindChartTooltip() {
    const container = document.getElementById("billing-chart-container");
    const tooltip = document.getElementById("billing-tooltip");
    if (!container || !tooltip) return;

    container.addEventListener("mousemove", (e) => {
      const group = e.target.closest(".billing-bar-group");
      if (!group) {
        tooltip.style.display = "none";
        return;
      }

      const date = group.dataset.date;
      const total = group.dataset.total;
      const cacheHit = group.dataset.cacheHit;
      const cacheMiss = group.dataset.cacheMiss;
      const output = group.dataset.output;

      tooltip.innerHTML = `
        <div class="tooltip-header">
          <span class="tooltip-date">${date}</span>
          <span class="tooltip-total-value">${total} tokens</span>
        </div>
        <div class="tooltip-row">
          <span class="tooltip-dot tooltip-total"></span>
          <span class="tooltip-label">${I18n.t("billing.totalTokens") || "Total Tokens"}</span>
          <span class="tooltip-value">${total}</span>
        </div>
        <div class="tooltip-row">
          <span class="tooltip-dot tooltip-cache-hit"></span>
          <span class="tooltip-label">${I18n.t("billing.inputCacheHit") || "Input (Hit)"}</span>
          <span class="tooltip-value">${cacheHit}</span>
        </div>
        <div class="tooltip-row">
          <span class="tooltip-dot tooltip-cache-miss"></span>
          <span class="tooltip-label">${I18n.t("billing.inputCacheMiss") || "Input (Miss)"}</span>
          <span class="tooltip-value">${cacheMiss}</span>
        </div>
        <div class="tooltip-row">
          <span class="tooltip-dot tooltip-output"></span>
          <span class="tooltip-label">${I18n.t("billing.output") || "Output"}</span>
          <span class="tooltip-value">${output}</span>
        </div>
      `;
      tooltip.style.display = "block";
      tooltip.style.visibility = "hidden";
      const rect = tooltip.getBoundingClientRect();
      const ovfX = e.clientX + 15 + rect.width - window.innerWidth;
      const ovfY = e.clientY - 10 + rect.height - window.innerHeight;
      tooltip.style.left = ovfX > 0 ? `${e.clientX - 15 - rect.width}px` : `${e.clientX + 15}px`;
      tooltip.style.top = ovfY > 0 ? `${e.clientY - 10 - rect.height}px` : `${e.clientY - 10}px`;
      tooltip.style.visibility = "visible";
    });

    container.addEventListener("mouseleave", () => {
      tooltip.style.display = "none";
      tooltip.style.visibility = "";
    });
  }

  function _bindHeatmapTooltip() {
    const grid = document.getElementById("billing-heat-grid");
    const tooltip = document.getElementById("billing-tooltip");
    if (!grid || !tooltip) return;

    grid.addEventListener("mousemove", (e) => {
      const cell = e.target.closest(".billing-heat-cell");
      if (!cell || cell.classList.contains("is-empty") || !cell.dataset.date) {
        tooltip.style.display = "none";
        return;
      }

      tooltip.innerHTML = `
        <div class="tooltip-header">
          <span class="tooltip-date">${cell.dataset.date}</span>
        </div>
        <div class="tooltip-row">
          <span class="tooltip-dot tooltip-total"></span>
          <span class="tooltip-label">${I18n.t("billing.totalTokens") || "Total Tokens"}</span>
          <span class="tooltip-value">${cell.dataset.tokens}</span>
        </div>
        <div class="tooltip-row">
          <span class="tooltip-label">${I18n.t("billing.cost") || "Cost"}</span>
          <span class="tooltip-value">${cell.dataset.cost}</span>
        </div>
      `;
      tooltip.style.display = "block";
      tooltip.style.left = `${e.clientX + 15}px`;
      tooltip.style.top = `${e.clientY - 10}px`;
    });

    grid.addEventListener("mouseleave", () => {
      tooltip.style.display = "none";
    });
  }

  function _bindTrendTooltip() {
    const svg = document.querySelector(".billing-trend-svg");
    const tooltip = document.getElementById("billing-tooltip");
    if (!svg || !tooltip) return;

    svg.addEventListener("mousemove", (e) => {
      const dot = e.target.closest(".billing-trend-dot");
      if (!dot) {
        tooltip.style.display = "none";
        return;
      }
      tooltip.innerHTML = `
        <div class="tooltip-header">
          <span class="tooltip-date">${dot.dataset.date}</span>
        </div>
        <div class="tooltip-row">
          <span class="tooltip-label">${I18n.t("billing.cost") || "Cost"}</span>
          <span class="tooltip-value">${dot.dataset.cost}</span>
        </div>
      `;
      tooltip.style.display = "block";
      tooltip.style.visibility = "hidden";
      const rect = tooltip.getBoundingClientRect();
      const ovf = e.clientX + 15 + rect.width - window.innerWidth;
      tooltip.style.left = ovf > 0 ? `${e.clientX - 15 - rect.width}px` : `${e.clientX + 15}px`;
      tooltip.style.top = `${e.clientY - 10}px`;
      tooltip.style.visibility = "visible";
    });

    svg.addEventListener("mouseleave", () => {
      tooltip.style.display = "none";
      tooltip.style.visibility = "";
    });
  }

  // ── Section renderers ────────────────────────────────────────────────────────

  function _getSummaryHint() {
    const summary = BillingStore.state.summary;
    const cost = Billing.convertCost(summary.total_cost || 0);
    const tokens = summary.total_tokens || 0;
    return `${_formatCompact(tokens)} tokens · ${Billing.getCurrencySymbol()}${_formatCost(cost)}`;
  }

  function _getCacheHitRate() {
    return _cacheHitRateOf(BillingStore.state.summary);
  }

  function _formatCompact(num) {
    if (num == null || num === 0) return "0";
    if (num >= 1000000) return (num / 1000000).toFixed(1) + "M";
    if (num >= 1000) return (num / 1000).toFixed(1) + "K";
    return num.toLocaleString();
  }

  function _renderTokenBreakdown() {
    const summary = BillingStore.state.summary;
    const totalTokens = summary.total_tokens || 0;
    const promptTokens = summary.prompt_tokens || 0;
    const completionTokens = summary.completion_tokens || 0;
    const cacheReadTokens = summary.cache_read_tokens || 0;
    const cacheMissTokens = Math.max(promptTokens - cacheReadTokens, 0);

    return `
      <div class="billing-section billing-token-section">
        <h3>${I18n.t("billing.tokenBreakdown") || "Token Breakdown"}</h3>
        <div class="billing-token-bars">
          <div class="billing-token-bar-item">
            <div class="billing-token-bar-header">
              <span class="billing-token-bar-label">${I18n.t("billing.totalTokens") || "Total Tokens"}</span>
              <span class="billing-token-bar-value">${_formatCompact(totalTokens)}</span>
            </div>
            <div class="billing-token-bar-track">
              <div class="billing-token-bar-fill billing-bar-total" style="width: 100%"></div>
            </div>
          </div>
          <div class="billing-token-bar-item">
            <div class="billing-token-bar-header">
              <span class="billing-token-bar-label">${I18n.t("billing.inputCacheHit") || "Input (Hit)"}</span>
              <span class="billing-token-bar-value">${_formatCompact(cacheReadTokens)}</span>
            </div>
            <div class="billing-token-bar-track">
              <div class="billing-token-bar-fill billing-bar-cache-read" style="width: ${_getTokenPercent(cacheReadTokens, totalTokens)}%"></div>
            </div>
          </div>
          <div class="billing-token-bar-item">
            <div class="billing-token-bar-header">
              <span class="billing-token-bar-label">${I18n.t("billing.inputCacheMiss") || "Input (Miss)"}</span>
              <span class="billing-token-bar-value">${_formatCompact(cacheMissTokens)}</span>
            </div>
            <div class="billing-token-bar-track">
              <div class="billing-token-bar-fill billing-bar-cache-miss" style="width: ${_getTokenPercent(cacheMissTokens, totalTokens)}%"></div>
            </div>
          </div>
          <div class="billing-token-bar-item">
            <div class="billing-token-bar-header">
              <span class="billing-token-bar-label">${I18n.t("billing.output") || "Output"}</span>
              <span class="billing-token-bar-value">${_formatCompact(completionTokens)}</span>
            </div>
            <div class="billing-token-bar-track">
              <div class="billing-token-bar-fill billing-bar-completion" style="width: ${_getTokenPercent(completionTokens, totalTokens)}%"></div>
            </div>
          </div>
        </div>
      </div>
    `;
  }

  function _getTokenPercent(value, total) {
    if (!total || total === 0) return 0;
    return Math.min((value / total) * 100, 100).toFixed(1);
  }

  function _renderModelBreakdown() {
    const summary = BillingStore.state.summary;
    const hasData = summary.by_model && Object.keys(summary.by_model).length > 0;

    if (!hasData) {
      return `
        <div class="billing-section billing-model-section">
          <h3>${I18n.t("billing.byModel") || "By Model"}</h3>
          <div class="billing-model-empty">${I18n.t("billing.noData") || "No data"}</div>
        </div>
      `;
    }

    const entries = Object.entries(summary.by_model)
      .filter(([_, data]) => (typeof data === "object" ? data.cost : data) > 0)
      .sort((a, b) => (b[1].cost || b[1]) - (a[1].cost || a[1]));

    const totalCost = entries.reduce((sum, [, data]) => sum + (typeof data === "object" ? data.cost : data), 0) || 1;

    const rows = entries.map(([model, data]) => {
      const cost = typeof data === "object" ? data.cost : data;
      const requests = typeof data === "object" ? data.requests : 0;
      const percent = ((cost / totalCost) * 100).toFixed(1);
      return `
        <div class="billing-model-row">
          <div class="billing-model-info">
            <span class="billing-model-name">${_esc(model)}</span>
            <span class="billing-model-meta">${requests} ${I18n.t("billing.requests") || "requests"}</span>
          </div>
          <div class="billing-model-bar-track">
            <div class="billing-model-bar-fill" style="width: ${percent}%"></div>
          </div>
          <div class="billing-model-cost">${Billing.getCurrencySymbol()}${_formatCost(Billing.convertCost(cost))}</div>
        </div>
      `;
    }).join("");

    return `
      <div class="billing-section billing-model-section">
        <h3>${I18n.t("billing.byModel") || "By Model"}</h3>
        <div class="billing-model-list">
          ${rows}
        </div>
      </div>
    `;
  }

  function _renderHeatmap() {
    const days = _heatmapDays();
    if (!days || days.length === 0) {
      return `<div class="billing-chart-card billing-chart-wide"><div class="billing-chart-empty">${I18n.t("billing.noData") || "No data available"}</div></div>`;
    }

    const maxTok = Math.max(...days.map(d => d.tokens), 1);
    const firstDow = new Date(days[0].date + "T00:00:00").getDay();
    const cells = [];
    for (let i = 0; i < firstDow; i++) cells.push('<div class="billing-heat-cell is-empty"></div>');
    days.forEach((d) => {
      const ratio = d.tokens / maxTok;
      const lvl = d.tokens === 0 ? 0 : ratio >= 0.75 ? 5 : ratio >= 0.5 ? 4 : ratio >= 0.25 ? 3 : ratio >= 0.08 ? 2 : 1;
      const costStr = `${Billing.getCurrencySymbol()}${_formatCost(Billing.convertCost(d.cost))}`;
      cells.push(`<div class="billing-heat-cell" data-level="${lvl}" data-date="${d.date}" data-tokens="${_formatCompact(d.tokens)}" data-cost="${costStr}"></div>`);
    });

    const dowLabels = (I18n.t("billing.heatmap.dow") || "S,M,T,W,T,F,S").split(",");
    const dowHeader = dowLabels.map(l => `<span class="billing-heat-dow">${_esc(l)}</span>`).join("");

    return `
      <div class="billing-chart-card billing-heatmap-card">
        <div class="billing-chart-header">
          <h4>${I18n.t("billing.heatmap.title") || "Activity"}</h4>
          <div class="billing-heat-legend">
            <span>${I18n.t("billing.heatmap.less") || "Less"}</span>
            <span class="billing-heat-cell" data-level="1"></span>
            <span class="billing-heat-cell" data-level="2"></span>
            <span class="billing-heat-cell" data-level="3"></span>
            <span class="billing-heat-cell" data-level="4"></span>
            <span class="billing-heat-cell" data-level="5"></span>
            <span>${I18n.t("billing.heatmap.more") || "More"}</span>
          </div>
        </div>
        <div class="billing-heat-dow-row">${dowHeader}</div>
        <div class="billing-heat-grid" id="billing-heat-grid">${cells.join("")}</div>
      </div>
    `;
  }

  function _renderCostTrend() {
    const daily = BillingStore.state.daily;
    if (!daily || daily.length < 2) {
      return `<div class="billing-chart-card billing-trend-card"><div class="billing-chart-empty">${I18n.t("billing.noData") || "No data available"}</div></div>`;
    }

    const days = daily.slice(-30);
    const costs = days.map(d => Billing.convertCost(d.cost || 0));
    const maxCost = Math.max(...costs, 0.0001);
    const minCost = Math.min(...costs);

    const pad = { top: 20, right: 16, bottom: 22, left: 48 };
    const w = 400;
    const h = 140;
    const plotW = w - pad.left - pad.right;
    const plotH = h - pad.top - pad.bottom;

    const range = maxCost - minCost || 1;
    const xStep = days.length > 1 ? plotW / (days.length - 1) : plotW;
    const points = costs.map((c, i) => {
      const x = pad.left + i * xStep;
      const y = pad.top + plotH - ((c - minCost) / range) * plotH;
      return `${x},${y}`;
    }).join(" ");

    const areaPoints = costs.length > 0
      ? `${pad.left},${pad.top + plotH} ${points} ${pad.left + (costs.length - 1) * xStep},${pad.top + plotH}`
      : "";

    const yTicks = 4;
    const yLabels = Array.from({ length: yTicks + 1 }, (_, i) => {
      const val = minCost + (range / yTicks) * i;
      const y = pad.top + plotH - ((val - minCost) / range) * plotH;
      return { val, y };
    });

    const showEvery = days.length > 20 ? 10 : days.length > 10 ? 5 : days.length > 5 ? 3 : 1;
    const xLabels = [];
    let lastX = -50;
    days.forEach((d, i) => {
      if (i % showEvery !== 0 && i !== days.length - 1) return;
      const x = pad.left + i * xStep;
      if (x - lastX < 40) return;
      lastX = x;
      xLabels.push({ date: d.date.slice(5), x });
    });

    const currencySymbol = Billing.getCurrencySymbol();

    return `
      <div class="billing-chart-card billing-trend-card">
        <div class="billing-chart-header">
          <h4>${I18n.t("billing.costTrend") || "Cost Trend"}</h4>
        </div>
        <div class="billing-trend-chart">
          <svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="xMidYMid meet" class="billing-trend-svg">
            ${yLabels.map(l => `
              <line x1="${pad.left}" y1="${l.y}" x2="${w - pad.right}" y2="${l.y}" class="billing-trend-grid-line" />
              <text x="${pad.left - 6}" y="${l.y + 4}" class="billing-trend-y-label">${currencySymbol}${_formatCost(l.val)}</text>
            `).join("")}
            ${xLabels.map(l => `
              <text x="${l.x}" y="${h - 4}" class="billing-trend-x-label">${l.date}</text>
            `).join("")}
            <defs>
              <linearGradient id="billing-trend-grad" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stop-color="#4f46e5" stop-opacity="0.15" />
                <stop offset="100%" stop-color="#4f46e5" stop-opacity="0.02" />
              </linearGradient>
            </defs>
            <polygon points="${areaPoints}" fill="url(#billing-trend-grad)" class="billing-trend-area" />
            <polyline points="${points}" fill="none" class="billing-trend-line" />
            ${costs.map((c, i) => {
              const cx = pad.left + i * xStep;
              const cy = pad.top + plotH - ((c - minCost) / range) * plotH;
              return `<circle cx="${cx}" cy="${cy}" r="3" class="billing-trend-dot" data-date="${days[i].date}" data-cost="${currencySymbol}${_formatCost(c)}" />`;
            }).join("")}
          </svg>
        </div>
      </div>
    `;
  }

  function _renderCombinedChart() {
    const daily = BillingStore.state.daily;
    if (!daily || daily.length === 0) {
      return `<div class="billing-chart-card billing-chart-wide"><div class="billing-chart-empty">${I18n.t("billing.noData") || "No data available"}</div></div>`;
    }

    const recentDays = daily.slice(-14);
    const maxInput = Math.max(...recentDays.map(d => d.prompt_tokens || 0), 1);
    const maxOutput = Math.max(...recentDays.map(d => d.completion_tokens || 0), 1);
    const maxVal = Math.max(maxInput, maxOutput);

    const chartHeight = 120;

    const chartBars = recentDays.map((d, i) => {
      const cacheHit = d.cache_read_tokens || 0;
      const totalPrompt = d.prompt_tokens || 0;
      const cacheMiss = Math.max(totalPrompt - cacheHit, 0);
      const output = d.completion_tokens || 0;
      const totalInput = totalPrompt;
      const totalTokens = totalInput + output;

      const cacheHitPx = Math.max((cacheHit / maxVal) * chartHeight, cacheHit > 0 ? 2 : 0);
      const cacheMissPx = Math.max((cacheMiss / maxVal) * chartHeight, cacheMiss > 0 ? 2 : 0);
      const outputPx = Math.max((output / maxVal) * chartHeight, output > 0 ? 2 : 0);
      const date = d.date.slice(5);
      const showLabel = i % 2 === 0 || i === recentDays.length - 1;

      const tooltipData = `data-date="${d.date}" data-total="${_formatCompact(totalTokens)}" data-cache-hit="${_formatCompact(cacheHit)}" data-cache-miss="${_formatCompact(cacheMiss)}" data-output="${_formatCompact(output)}"`;

      return `
        <div class="billing-bar-group" ${tooltipData}>
          <div class="billing-bar-pair">
            <div class="billing-input-stack">
              <div class="billing-cache-hit" style="height: ${cacheHitPx}px"></div>
              <div class="billing-cache-miss" style="height: ${cacheMissPx}px"></div>
            </div>
            <div class="billing-output-bar" style="height: ${outputPx}px"></div>
          </div>
          ${showLabel ? `<span class="billing-bar-date">${date}</span>` : '<span class="billing-bar-date"></span>'}
        </div>
      `;
    }).join("");

    return `
      <div class="billing-chart-card billing-chart-wide">
        <div class="billing-chart-header">
          <h4>${I18n.t("billing.dailyUsage") || "Usage Details"}</h4>
          <div class="billing-chart-legends">
            <span class="billing-chart-legend">
              <span class="billing-legend-dot billing-legend-total"></span>
              ${I18n.t("billing.totalTokens") || "Total Tokens"}
            </span>
            <span class="billing-chart-legend">
              <span class="billing-legend-dot billing-legend-cache-hit"></span>
              ${I18n.t("billing.inputCacheHit") || "Input (Hit)"}
            </span>
            <span class="billing-chart-legend">
              <span class="billing-legend-dot billing-legend-cache-miss"></span>
              ${I18n.t("billing.inputCacheMiss") || "Input (Miss)"}
            </span>
            <span class="billing-chart-legend">
              <span class="billing-legend-dot billing-legend-output"></span>
              ${I18n.t("billing.output") || "Output"}
            </span>
          </div>
        </div>
        <div class="billing-combined-chart" id="billing-chart-container">
          ${chartBars}
        </div>
      </div>
      <div class="billing-chart-tooltip" id="billing-tooltip"></div>
    `;
  }

  function _renderSessionList() {
    const sessions = BillingStore.state.sessions;
    if (!sessions || sessions.length === 0) {
      return `
        <div class="billing-sessions-section">
          <h3>${I18n.t("billing.sessions") || "Sessions"}</h3>
          <div class="billing-sessions-empty">${I18n.t("billing.noSessions") || "No session data"}</div>
        </div>
      `;
    }

    const rows = sessions.map((s, index) => {
      const sessionId = s.session_id || "unknown";
      const isDeleted = s.is_deleted;
      const sessionName = s.session_name || sessionId;
      const displayName = isDeleted ? (I18n.t("billing.deletedSessions") || "已删除会话") : (sessionName.length > 25 ? sessionName.slice(0, 25) + "..." : sessionName);
      const totalCost = Billing.convertCost(s.total_cost || 0);
      const totalTokens = s.total_tokens || 0;
      const promptTokens = s.prompt_tokens || 0;
      const cacheHit = s.cache_read_tokens || 0;
      const cacheMiss = Math.max(promptTokens - cacheHit, 0);
      const completionTokens = s.completion_tokens || 0;
      const requests = s.requests || 0;
      const models = (s.models || []).join(", ");
      const lastRequest = s.last_request ? new Date(s.last_request).toLocaleString() : "-";
      const rowClass = isDeleted ? "billing-session-row billing-session-deleted" : "billing-session-row";

      return `
        <div class="${rowClass}" data-session-id="${_esc(sessionId)}">
          <div class="billing-cell billing-cell-index">${index + 1}</div>
          <div class="billing-cell billing-cell-session" data-tooltip="${_esc(sessionName)}" data-tooltip-pos="top">
            <span class="billing-cell-main">${_esc(displayName)}</span>
            <span class="billing-cell-sub">${requests} ${I18n.t("billing.requests") || "req"} · ${_esc(models)}</span>
          </div>
          <div class="billing-cell billing-cell-number billing-cell-total">${_formatCompact(totalTokens)}</div>
          <div class="billing-cell billing-cell-number billing-cell-hit">${_formatCompact(cacheHit)}</div>
          <div class="billing-cell billing-cell-number billing-cell-miss">${_formatCompact(cacheMiss)}</div>
          <div class="billing-cell billing-cell-number billing-cell-output">${_formatCompact(completionTokens)}</div>
          <div class="billing-cell billing-cell-cost">${Billing.getCurrencySymbol()}${_formatCost(totalCost)}</div>
          <div class="billing-cell billing-cell-time">${lastRequest}</div>
          <div class="billing-session-numbers-row">
            <span class="billing-cell-number">${_formatCompact(totalTokens)} tok</span>
            <span class="billing-cell-number billing-cell-hit">${_formatCompact(cacheHit)} hit</span>
            <span class="billing-cell-number billing-cell-output">${_formatCompact(completionTokens)} out</span>
            <span class="billing-cell-cost">${Billing.getCurrencySymbol()}${_formatCost(totalCost)}</span>
            <span class="billing-cell-time">${lastRequest}</span>
          </div>
        </div>
      `;
    }).join("");

    return `
      <div class="billing-sessions-section">
        <h3>${I18n.t("billing.sessions") || "Sessions"}</h3>
        <div class="billing-sessions-header">
          <span class="billing-cell billing-cell-index">#</span>
          <span class="billing-cell billing-cell-session">${I18n.t("billing.sessionId") || "Session"}</span>
          <span class="billing-cell billing-cell-number">${I18n.t("billing.headerTotal") || "总消耗"}</span>
          <span class="billing-cell billing-cell-number">${I18n.t("billing.headerHit") || "命中"}</span>
          <span class="billing-cell billing-cell-number">${I18n.t("billing.headerMiss") || "未命中"}</span>
          <span class="billing-cell billing-cell-number">${I18n.t("billing.headerOutput") || "输出"}</span>
          <span class="billing-cell billing-cell-cost">${I18n.t("billing.cost") || "Cost"}</span>
          <span class="billing-cell billing-cell-time">${I18n.t("billing.lastRequest") || "Time"}</span>
        </div>
        <div class="billing-sessions-list">
          ${rows}
        </div>
      </div>
    `;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  function _formatCost(cost) {
    if (cost == null || cost === 0) return "0.0000";
    return cost.toFixed(4);
  }

  function _formatNumber(num) {
    if (num == null || num === 0) return "0";
    return num.toLocaleString();
  }

  function _periodLabel(period) {
    const labels = {
      day: I18n.t("billing.period.day") || "Today",
      week: I18n.t("billing.period.week") || "This Week",
      month: I18n.t("billing.period.month") || "This Month",
      year: I18n.t("billing.period.year") || "This Year",
      all: I18n.t("billing.period.all") || "All Time"
    };
    return labels[period] || period;
  }

  function _esc(str) {
    if (!str) return "";
    const div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }

  function _subscribe() {
    Billing.on("billing:loading", _onLoading);
    Billing.on("billing:changed", _render);
    Billing.on("billing:error", _onError);
    Billing.on("billing:actionError", _onActionError);
    document.addEventListener("currencychange", () => Billing.refreshView());
  }

  return { init: _subscribe };
})();

BillingView.init();
