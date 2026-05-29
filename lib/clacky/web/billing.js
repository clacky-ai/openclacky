// billing.js — Billing panel logic
// Handles displaying billing summary, daily breakdown, and usage statistics.

const Billing = (() => {
  let _summary = null;
  let _daily = [];
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

    container.innerHTML = `<div class="billing-loading">${I18n.t("billing.loading") || "Loading billing data..."}</div>`;

    try {
      const modelParam = (_currentModel && _currentModel !== "all") ? `&model=${encodeURIComponent(_currentModel)}` : "";
      const [summaryRes, dailyRes] = await Promise.all([
        fetch(`/api/billing/summary?period=${_currentPeriod}${modelParam}`),
        fetch(`/api/billing/daily?days=30${modelParam}`)
      ]);

      _summary = await summaryRes.json();
      const dailyData = await dailyRes.json();
      _daily = dailyData.days || [];

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
            <div class="billing-clear-container">
              <button id="billing-clear-btn" class="billing-clear-btn" title="${I18n.t('billing.clearData') || 'Clear Data'}">
                🗑️
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
            <div class="billing-stat-icon">💰</div>
            <div class="billing-stat-content">
              <div class="billing-stat-value">${_getCurrencySymbol()}${_formatCost(_convertCost(_summary.total_cost))}</div>
              <div class="billing-stat-label">${I18n.t("billing.totalCost") || "Total Cost"}</div>
            </div>
          </div>
          <div class="billing-stat-card">
            <div class="billing-stat-icon">📊</div>
            <div class="billing-stat-content">
              <div class="billing-stat-value">${_formatCompact(_summary.total_tokens)}</div>
              <div class="billing-stat-label">${I18n.t("billing.totalTokens") || "Total Tokens"}</div>
            </div>
          </div>
          <div class="billing-stat-card">
            <div class="billing-stat-icon">🔄</div>
            <div class="billing-stat-content">
              <div class="billing-stat-value">${_formatNumber(_summary.record_count)}</div>
              <div class="billing-stat-label">${I18n.t("billing.requests") || "Requests"}</div>
            </div>
          </div>
          <div class="billing-stat-card">
            <div class="billing-stat-icon">⚡</div>
            <div class="billing-stat-content">
              <div class="billing-stat-value">${_getCacheHitRate()}%</div>
              <div class="billing-stat-label">${I18n.t("billing.cacheHit") || "Cache Hit"}</div>
            </div>
          </div>
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

    // Bind chart tooltip handlers
    _bindChartTooltip();
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
          <span class="tooltip-total">${total} tokens</span>
        </div>
        <div class="tooltip-row">
          <span class="tooltip-dot tooltip-cache-hit"></span>
          <span class="tooltip-label">${I18n.t("billing.inputCacheHit") || "Input (Cache Hit)"}</span>
          <span class="tooltip-value">${cacheHit}</span>
        </div>
        <div class="tooltip-row">
          <span class="tooltip-dot tooltip-cache-miss"></span>
          <span class="tooltip-label">${I18n.t("billing.inputCacheMiss") || "Input (Cache Miss)"}</span>
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
    return `
      <div class="billing-section billing-token-section">
        <h3>${I18n.t("billing.tokenBreakdown") || "Token Breakdown"}</h3>
        <div class="billing-token-bars">
          <div class="billing-token-bar-item">
            <div class="billing-token-bar-header">
              <span class="billing-token-bar-label">${I18n.t("billing.inputCacheHit") || "Input (Cache Hit)"}</span>
              <span class="billing-token-bar-value">${_formatCompact(_summary.cache_read_tokens)}</span>
            </div>
            <div class="billing-token-bar-track">
              <div class="billing-token-bar-fill billing-bar-cache-read" style="width: ${_getTokenPercent('cache_read')}%"></div>
            </div>
          </div>
          <div class="billing-token-bar-item">
            <div class="billing-token-bar-header">
              <span class="billing-token-bar-label">${I18n.t("billing.inputCacheMiss") || "Input (Cache Miss)"}</span>
              <span class="billing-token-bar-value">${_formatCompact(_summary.prompt_tokens)}</span>
            </div>
            <div class="billing-token-bar-track">
              <div class="billing-token-bar-fill billing-bar-prompt" style="width: ${_getTokenPercent('prompt')}%"></div>
            </div>
          </div>
          <div class="billing-token-bar-item">
            <div class="billing-token-bar-header">
              <span class="billing-token-bar-label">${I18n.t("billing.output") || "Output"}</span>
              <span class="billing-token-bar-value">${_formatCompact(_summary.completion_tokens)}</span>
            </div>
            <div class="billing-token-bar-track">
              <div class="billing-token-bar-fill billing-bar-completion" style="width: ${_getTokenPercent('completion')}%"></div>
            </div>
          </div>
        </div>
      </div>
    `;
  }

  function _getTokenPercent(type) {
    const total = _summary.total_tokens || 1;
    const value = _summary[type + '_tokens'] || 0;
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

  function _renderCombinedChart() {
    if (!_daily || _daily.length === 0) {
      return `<div class="billing-chart-card billing-chart-wide"><div class="billing-chart-empty">${I18n.t("billing.noData") || "No data available"}</div></div>`;
    }

    const recentDays = _daily.slice(-14);
    // Max values for scaling
    const maxInput = Math.max(...recentDays.map(d => (d.prompt_tokens || 0) + (d.cache_read_tokens || 0)), 1);
    const maxOutput = Math.max(...recentDays.map(d => d.completion_tokens || 0), 1);
    const maxVal = Math.max(maxInput, maxOutput);

    // Chart height in pixels
    const chartHeight = 120;

    // Generate bars: each date has Input (stacked: cache hit + cache miss) and Output
    const chartBars = recentDays.map((d, i) => {
      const cacheHit = d.cache_read_tokens || 0;        // 命中缓存
      const cacheMiss = d.prompt_tokens || 0;           // 未命中缓存（实际发送的prompt）
      const output = d.completion_tokens || 0;
      const totalInput = cacheHit + cacheMiss;
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
              <span class="billing-legend-dot billing-legend-cache-hit"></span>
              ${I18n.t("billing.inputCacheHit") || "Input (Cache Hit)"}
            </span>
            <span class="billing-chart-legend">
              <span class="billing-legend-dot billing-legend-cache-miss"></span>
              ${I18n.t("billing.inputCacheMiss") || "Input (Cache Miss)"}
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
