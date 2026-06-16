// billing.js — Billing panel logic
// Handles displaying billing summary, daily breakdown, and usage statistics.

const Billing = (() => {
  let _summary = null;
  let _daily = [];
  let _sessions = []; // 会话列表
  let _allModels = []; // 保存完整的模型列表
  let _currentPeriod = "day";
  let _currentModel = "all";
  let _clearPopupVisible = false;

  // ── Currency Settings ─────────────────────────────────────────────────────
  const CURRENCY_STORAGE_KEY = "clacky-currency";
  const EXCHANGE_RATE_STORAGE_KEY = "clacky-exchange-rate";
  const DEFAULT_USD_TO_CNY_RATE = 6.7944; // Default exchange rate: 1 USD ≈ 6.7944 CNY

  function _getCurrency() {
    try { return localStorage.getItem(CURRENCY_STORAGE_KEY) || "USD"; } catch (_) { return "USD"; }
  }

  function _getExchangeRate() {
    try {
      const rate = localStorage.getItem(EXCHANGE_RATE_STORAGE_KEY);
      if (rate) {
        const parsed = parseFloat(rate);
        if (!isNaN(parsed) && parsed > 0) return parsed;
      }
    } catch (_) {}
    return DEFAULT_USD_TO_CNY_RATE;
  }

  function _setExchangeRate(rate) {
    try {
      if (rate && !isNaN(rate) && rate > 0) {
        localStorage.setItem(EXCHANGE_RATE_STORAGE_KEY, rate.toString());
        document.dispatchEvent(new CustomEvent("currencychange"));
      }
    } catch (_) {}
  }

  function _convertCost(usdCost) {
    const currency = _getCurrency();
    if (currency === "CNY") {
      return usdCost * _getExchangeRate();
    }
    return usdCost;
  }

  function _getCurrencySymbol() {
    return _getCurrency() === "CNY" ? "¥" : "$";
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  function open() {
    _load();
    // Listen for currency changes
    document.removeEventListener("currencychange", _onCurrencyChange);
    document.addEventListener("currencychange", _onCurrencyChange);
  }

  function _onCurrencyChange() {
    if (_summary) _render();
  }

  // ── Data Loading ────────────────────────────────────────────────────────────

  async function _load() {
    const container = document.getElementById("billing-content");
    if (!container) return;

    const isFirstLoad = !_summary;
    if (isFirstLoad) {
      container.innerHTML = _renderSkeleton();
    } else {
      const existing = container.querySelector(".billing-dashboard");
      if (existing && !existing.querySelector(".billing-skel-overlay")) {
        const topBar = existing.querySelector(".billing-top-bar");
        const topBarH = topBar ? topBar.offsetHeight + 20 : 0;
        existing.insertAdjacentHTML("beforeend", `<div class="billing-skel-overlay" style="top:${topBarH}px">${_renderSkeletonBody()}</div>`);
      }
    }

    try {
      const modelParam = (_currentModel && _currentModel !== "all") ? `&model=${encodeURIComponent(_currentModel)}` : "";
      const [summaryRes, dailyRes, sessionsRes] = await Promise.all([
        fetch(`/api/billing/summary?period=${_currentPeriod}${modelParam}`),
        fetch(`/api/billing/daily?days=30${modelParam}`),
        fetch(`/api/billing/sessions?period=${_currentPeriod}${modelParam}&limit=100`)
      ]);

      _summary = await summaryRes.json();
      const dailyData = await dailyRes.json();
      _daily = dailyData.days || [];

      const sessionsData = await sessionsRes.json();
      _sessions = sessionsData.sessions || [];

      // 保存完整模型列表（仅在未筛选时更新）
      if (!_currentModel || _currentModel === "all") {
        _allModels = _summary.by_model ? Object.keys(_summary.by_model) : [];
      }

      _render();
    } catch (e) {
      container.innerHTML = `<div class="billing-error">${I18n.t("billing.error") || "Failed to load billing data"}: ${e.message}</div>`;
    }
  }

  // ── Rendering ───────────────────────────────────────────────────────────────

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
        <div class="billing-chart-card billing-chart-wide billing-heatmap-card">
          <div class="skel skel-heatmap"></div>
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
          <div class="billing-chart-card billing-chart-wide billing-heatmap-card">
            <div class="skel skel-heatmap"></div>
          </div>
        </div>
        <div class="billing-bottom-grid">
          <div class="billing-section"><div class="skel skel-block"></div></div>
          <div class="billing-section"><div class="skel skel-block"></div></div>
        </div>
      </div>
    `;
  }

  function _render() {
    const container = document.getElementById("billing-content");
    if (!container || !_summary) return;

    // Period button group
    const periods = ["day", "week", "month", "year", "all"];
    const periodBtns = periods.map(p => 
      `<button class="billing-period-btn ${p === _currentPeriod ? 'active' : ''}" data-period="${p}">${_periodLabel(p)}</button>`
    ).join("");

    // Model filter options (使用完整模型列表)
    const models = _allModels.length > 0 ? _allModels : (_summary.by_model ? Object.keys(_summary.by_model) : []);
    const modelOptions = [`<option value="all">${I18n.t("billing.allModels") || "All Models"}</option>`]
      .concat(models.map(m => `<option value="${_esc(m)}" ${m === _currentModel ? "selected" : ""}>${_esc(m)}</option>`))
      .join("");

    container.innerHTML = `
      <div class="billing-dashboard">
        <div class="billing-top-bar">
          <div class="billing-title-row">
            <h2>${I18n.t("billing.title") || "Usage"}</h2>
            <span class="billing-subtitle">${_getSummaryHint()}</span>
          </div>
          <div class="billing-controls">
            <div class="billing-period-group">${periodBtns}</div>
            <select id="billing-model-filter" class="billing-model-filter">${modelOptions}</select>
            <button id="billing-share-btn" class="billing-share-btn" title="${I18n.t('billing.share.tooltip') || 'Share scorecard'}">
              📤 ${I18n.t('billing.share.btn') || 'Share scorecard'}
            </button>
            <div class="billing-clear-container">
              <button id="billing-clear-btn" class="billing-clear-btn" title="${I18n.t('billing.clearData') || 'Clear Data'}">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><polyline points="3 6 5 6 21 6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M10 11v6M14 11v6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
              </button>
              <div id="billing-clear-popup" class="billing-clear-popup" style="display: none;">
                <button id="billing-clear-today" class="billing-clear-option">${I18n.t('billing.clearToday') || 'Clear Today'}</button>
                <button id="billing-clear-all" class="billing-clear-option billing-clear-danger">${I18n.t('billing.clearAll') || 'Clear All'}</button>
              </div>
            </div>
          </div>
        </div>

        <div class="billing-stats-row">
          <div class="billing-stat-card billing-stat-primary">
            <div class="billing-stat-icon billing-stat-icon-cost">
              <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="10" cy="10" r="8" stroke="currentColor" stroke-width="1.5"/><path d="M10 6v1m0 6v1M7.5 10a2.5 2.5 0 0 0 2.5 2.5c1.38 0 2.5-.56 2.5-1.25S11.38 10 10 10c-1.38 0-2.5-.56-2.5-1.25S8.62 7.5 10 7.5A2.5 2.5 0 0 1 12.5 10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
            </div>
            <div class="billing-stat-content">
              <div class="billing-stat-value">${_getCurrencySymbol()}${_formatCost(_convertCost(_summary.total_cost))}</div>
              <div class="billing-stat-label">${I18n.t("billing.totalCost") || "Total Cost"}</div>
            </div>
          </div>
          <div class="billing-stat-card">
            <div class="billing-stat-icon billing-stat-icon-tokens">
              <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg"><rect x="3" y="11" width="3" height="6" rx="1" fill="currentColor" opacity=".4"/><rect x="8.5" y="7" width="3" height="10" rx="1" fill="currentColor" opacity=".7"/><rect x="14" y="3" width="3" height="14" rx="1" fill="currentColor"/></svg>
            </div>
            <div class="billing-stat-content">
              <div class="billing-stat-value">${_formatCompact(_summary.total_tokens)}</div>
              <div class="billing-stat-label">${I18n.t("billing.totalTokens") || "Total Tokens"}</div>
            </div>
          </div>
          <div class="billing-stat-card">
            <div class="billing-stat-icon billing-stat-icon-requests">
              <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M10 3a7 7 0 1 1 0 14A7 7 0 0 1 10 3Z" stroke="currentColor" stroke-width="1.5"/><path d="M10 7v3l2 2" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
            </div>
            <div class="billing-stat-content">
              <div class="billing-stat-value">${_formatNumber(_summary.record_count)}</div>
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
        </div>

        <div class="billing-bottom-grid">
          ${_renderTokenBreakdown()}
          ${_renderModelBreakdown()}
        </div>

        <div class="billing-chart-row">
          ${_renderCombinedChart()}
        </div>

        <div class="billing-sessions-row">
          ${_renderSessionList()}
        </div>
      </div>
    `;

    // Bind period button handlers
    document.querySelectorAll(".billing-period-btn").forEach(btn => {
      btn.addEventListener("click", (e) => {
        _currentPeriod = e.target.dataset.period;
        _load();
      });
    });

    // Bind model filter handler
    document.getElementById("billing-model-filter")?.addEventListener("change", (e) => {
      _currentModel = e.target.value;
      _load();
    });

    // Bind clear button handlers
    _bindClearHandlers();

    // Bind scorecard share button
    document.getElementById("billing-share-btn")?.addEventListener("click", _openScorecardShare);

    // Bind chart tooltip handlers
    _bindChartTooltip();
    _bindHeatmapTooltip();
  }

  // Builds the per-period scorecard numbers from a raw summary object, using
  // the same currency / formatting conventions as the billing dashboard.
  function _scorecardStatsFor(summary, periodKey) {
    const prompt = summary.prompt_tokens || 0;
    const cacheRead = summary.cache_read_tokens || 0;
    const rate = prompt === 0 ? "0" : ((cacheRead / prompt) * 100).toFixed(1);
    return {
      key:          periodKey,
      period:       _periodLabel(periodKey),
      cacheHitRate: rate,
      costStr:      `${_getCurrencySymbol()}${_formatCost(_convertCost(summary.total_cost || 0))}`,
      tokensStr:    _formatCompact(summary.total_tokens || 0),
      requests:     _formatNumber(summary.record_count || 0)
    };
  }

  // Daily token totals for the heatmap (GitHub-contribution style), oldest →
  // newest. Each entry: { date: "YYYY-MM-DD", tokens: <total> }.
  function _heatmapDays() {
    return (_daily || []).map((d) => ({
      date:   d.date,
      tokens: (d.prompt_tokens || 0) + (d.completion_tokens || 0),
      cost:   d.cost || 0
    }));
  }

  function _openScorecardShare() {
    if (!_summary || typeof Share === "undefined" || !Share.openScorecard) return;
    const modelParam = (_currentModel && _currentModel !== "all") ? `&model=${encodeURIComponent(_currentModel)}` : "";

    // Open instantly with the period the dashboard already has, then fetch the
    // other periods in the background and hot-swap them in (no blocking await).
    const periods = {};
    periods[_currentPeriod] = _scorecardStatsFor(_summary, _currentPeriod);

    Share.openScorecard({
      periods:       periods,
      defaultPeriod: _currentPeriod,
      heatmap:       _heatmapDays(),
      period:        periods[_currentPeriod].period,
      cacheHitRate:  periods[_currentPeriod].cacheHitRate,
      costStr:       periods[_currentPeriod].costStr,
      tokensStr:     periods[_currentPeriod].tokensStr,
      requests:      periods[_currentPeriod].requests
    });

    const others = ["day", "week", "month"].filter((p) => p !== _currentPeriod);
    others.forEach((p) => {
      fetch(`/api/billing/summary?period=${p}${modelParam}`)
        .then((r) => r.json())
        .then((summary) => {
          if (Share.addScorecardPeriod) Share.addScorecardPeriod(p, _scorecardStatsFor(summary, p));
        })
        .catch(() => {});
    });
  }

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

      // Position tooltip following mouse
      tooltip.style.left = `${e.clientX + 15}px`;
      tooltip.style.top = `${e.clientY - 10}px`;
    });

    container.addEventListener("mouseleave", () => {
      tooltip.style.display = "none";
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

  function _bindClearHandlers() {
    const clearBtn = document.getElementById("billing-clear-btn");
    const clearPopup = document.getElementById("billing-clear-popup");
    const clearToday = document.getElementById("billing-clear-today");
    const clearAll = document.getElementById("billing-clear-all");

    if (!clearBtn || !clearPopup) return;

    // Toggle popup on button click
    clearBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      _clearPopupVisible = !_clearPopupVisible;
      clearPopup.style.display = _clearPopupVisible ? "flex" : "none";
    });

    // Clear today
    clearToday?.addEventListener("click", async (e) => {
      e.stopPropagation();
      await _clearData("today");
    });

    // Clear all
    clearAll?.addEventListener("click", async (e) => {
      e.stopPropagation();
      await _clearData("all");
    });

    // Close popup when clicking outside
    document.addEventListener("click", _closeClearPopup);
  }

  function _closeClearPopup(e) {
    const clearPopup = document.getElementById("billing-clear-popup");
    const clearBtn = document.getElementById("billing-clear-btn");
    if (!clearPopup || !clearBtn) return;

    // Check if click is outside popup and button
    if (!clearPopup.contains(e.target) && !clearBtn.contains(e.target)) {
      _clearPopupVisible = false;
      clearPopup.style.display = "none";
    }
  }

  async function _clearData(scope) {
    const clearPopup = document.getElementById("billing-clear-popup");
    if (clearPopup) {
      clearPopup.style.display = "none";
      _clearPopupVisible = false;
    }

    try {
      const res = await fetch(`/api/billing/clear?scope=${scope}`, { method: "DELETE" });
      const data = await res.json();
      if (res.ok) {
        // Reload data after clearing
        _load();
      } else {
        alert(data.error || "Failed to clear data");
      }
    } catch (e) {
      alert(`Error clearing data: ${e.message}`);
    }
  }

  // Helper functions for new UI
  function _getSummaryHint() {
    const cost = _convertCost(_summary.total_cost || 0);
    const tokens = _summary.total_tokens || 0;
    return `${_formatCompact(tokens)} tokens · ${_getCurrencySymbol()}${_formatCost(cost)}`;
  }

  function _getCacheHitRate() {
    const prompt = _summary.prompt_tokens || 0;
    const cacheRead = _summary.cache_read_tokens || 0;
    if (prompt === 0) return "0";
    return ((cacheRead / prompt) * 100).toFixed(1);
  }

  function _formatCompact(num) {
    if (num == null || num === 0) return "0";
    if (num >= 1000000) return (num / 1000000).toFixed(1) + "M";
    if (num >= 1000) return (num / 1000).toFixed(1) + "K";
    return num.toLocaleString();
  }

  function _renderTokenBreakdown() {
    const totalTokens = _summary.total_tokens || 0;
    const promptTokens = _summary.prompt_tokens || 0;
    const completionTokens = _summary.completion_tokens || 0;
    const cacheReadTokens = _summary.cache_read_tokens || 0;
    const cacheMissTokens = promptTokens - cacheReadTokens;

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
    const hasData = _summary.by_model && Object.keys(_summary.by_model).length > 0;
    
    if (!hasData) {
      return `
        <div class="billing-section billing-model-section">
          <h3>${I18n.t("billing.byModel") || "By Model"}</h3>
          <div class="billing-model-empty">${I18n.t("billing.noData") || "No data"}</div>
        </div>
      `;
    }

    const entries = Object.entries(_summary.by_model)
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
          <div class="billing-model-cost">${_getCurrencySymbol()}${_formatCost(_convertCost(cost))}</div>
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
      const costStr = `${_getCurrencySymbol()}${_formatCost(_convertCost(d.cost))}`;
      cells.push(`<div class="billing-heat-cell" data-level="${lvl}" data-date="${d.date}" data-tokens="${_formatCompact(d.tokens)}" data-cost="${costStr}"></div>`);
    });

    const dowLabels = (I18n.t("billing.heatmap.dow") || "S,M,T,W,T,F,S").split(",");
    const dowHeader = dowLabels.map(l => `<span class="billing-heat-dow">${_esc(l)}</span>`).join("");

    return `
      <div class="billing-chart-card billing-chart-wide billing-heatmap-card">
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

  function _renderCombinedChart() {
    if (!_daily || _daily.length === 0) {
      return `<div class="billing-chart-card billing-chart-wide"><div class="billing-chart-empty">${I18n.t("billing.noData") || "No data available"}</div></div>`;
    }

    const recentDays = _daily.slice(-14);
    // Max values for scaling
    const maxInput = Math.max(...recentDays.map(d => d.prompt_tokens || 0), 1);
    const maxOutput = Math.max(...recentDays.map(d => d.completion_tokens || 0), 1);    const maxVal = Math.max(maxInput, maxOutput);

    // Chart height in pixels
    const chartHeight = 120;

    // Generate bars: each date has Input (stacked: cache hit + cache miss) and Output
    const chartBars = recentDays.map((d, i) => {
      const cacheHit = d.cache_read_tokens || 0;        // 命中缓存
      const totalPrompt = d.prompt_tokens || 0;         // 全部输入token
      const cacheMiss = totalPrompt - cacheHit;         // 未命中缓存 = 全部输入 - 命中
      const output = d.completion_tokens || 0;
      const totalInput = totalPrompt;
      const totalTokens = totalInput + output;

      // Calculate heights in pixels
      const cacheHitPx = Math.max((cacheHit / maxVal) * chartHeight, cacheHit > 0 ? 2 : 0);
      const cacheMissPx = Math.max((cacheMiss / maxVal) * chartHeight, cacheMiss > 0 ? 2 : 0);
      const outputPx = Math.max((output / maxVal) * chartHeight, output > 0 ? 2 : 0);
      const date = d.date.slice(5);
      const showLabel = i % 2 === 0 || i === recentDays.length - 1;

      // Tooltip data attributes for custom tooltip
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
    if (!_sessions || _sessions.length === 0) {
      return `
        <div class="billing-section billing-sessions-section">
          <h3>${I18n.t("billing.sessions") || "Sessions"}</h3>
          <div class="billing-sessions-empty">${I18n.t("billing.noSessions") || "No session data"}</div>
        </div>
      `;
    }

    const rows = _sessions.map((s, index) => {
      const sessionId = s.session_id || "unknown";
      const isDeleted = s.is_deleted;
      const sessionName = s.session_name || sessionId;
      const displayName = isDeleted ? (I18n.t("billing.deletedSessions") || "已删除会话") : (sessionName.length > 25 ? sessionName.slice(0, 25) + "..." : sessionName);
      const totalCost = _convertCost(s.total_cost || 0);
      const totalTokens = s.total_tokens || 0;
      const promptTokens = s.prompt_tokens || 0;
      const cacheHit = s.cache_read_tokens || 0;
      const cacheMiss = promptTokens - cacheHit;
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
          <div class="billing-cell billing-cell-number">${_formatCompact(totalTokens)}</div>
          <div class="billing-cell billing-cell-number billing-cell-hit">${_formatCompact(cacheHit)}</div>
          <div class="billing-cell billing-cell-number billing-cell-miss">${_formatCompact(cacheMiss)}</div>
          <div class="billing-cell billing-cell-number">${_formatCompact(completionTokens)}</div>
          <div class="billing-cell billing-cell-cost">${_getCurrencySymbol()}${_formatCost(totalCost)}</div>
          <div class="billing-cell billing-cell-time">${lastRequest}</div>
          <div class="billing-session-numbers-row">
            <span class="billing-cell-number">${_formatCompact(totalTokens)} tok</span>
            <span class="billing-cell-number billing-cell-hit">${_formatCompact(cacheHit)} hit</span>
            <span class="billing-cell-number">${_formatCompact(completionTokens)} out</span>
            <span class="billing-cell-cost">${_getCurrencySymbol()}${_formatCost(totalCost)}</span>
            <span class="billing-cell-time">${lastRequest}</span>
          </div>
        </div>
      `;
    }).join("");

    return `
      <div class="billing-section billing-sessions-section">
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

  // ── Helpers ─────────────────────────────────────────────────────────────────

  function _formatCost(cost) {
    if (cost == null || cost === 0) return "0.0000";
    return cost.toFixed(4);
  }

  function _formatNumber(num) {
    if (num == null || num === 0) return "0";
    return num.toLocaleString();
  }

  function _periodLabelShort(period) {
    const labels = {
      day: I18n.t("billing.period.day") || "Today",
      week: I18n.t("billing.period.weekShort") || "Week",
      month: I18n.t("billing.period.monthShort") || "Month",
      year: I18n.t("billing.period.yearShort") || "Year",
      all: I18n.t("billing.period.allShort") || "All"
    };
    return labels[period] || period;
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

  // ── Expose Public API ───────────────────────────────────────────────────────

  return { 
    open,
    // Expose currency utilities for other modules
    getCurrency: _getCurrency,
    convertCost: _convertCost,
    getCurrencySymbol: _getCurrencySymbol,
    getExchangeRate: _getExchangeRate
  };
})();
