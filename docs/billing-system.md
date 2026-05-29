# Billing System

## Overview

The Billing System provides persistent tracking of API usage and costs across all
sessions. It records every LLM API call with token counts and calculated costs,
storing them in monthly JSONL files for easy querying and analysis.

## Design Principles

- **Non-blocking** — Billing persistence is fire-and-forget; failures never interrupt agent flow
- **Minimal footprint** — JSONL format, one file per month, no database dependency
- **Privacy-first** — Data stored locally in `~/.clacky/billing/`, never uploaded
- **Accurate costing** — Uses the same `ModelPricing` module as real-time display

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Agent                                   │
│  CostTracker module                                             │
│    └── track_cost()                                             │
│          ├── Calculate cost (ModelPricing)                      │
│          ├── Update UI (real-time)                              │
│          └── persist_billing_record() ──────┐                   │
└─────────────────────────────────────────────┼───────────────────┘
                                              │
                                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Billing Module                               │
│  lib/clacky/billing/                                            │
│    ├── billing_record.rb   (data structure)                     │
│    └── billing_store.rb    (JSONL persistence)                  │
└─────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Storage                                      │
│  ~/.clacky/billing/                                             │
│    ├── 2026-05.jsonl                                            │
│    ├── 2026-04.jsonl                                            │
│    └── ...                                                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Components

### BillingRecord (`lib/clacky/billing/billing_record.rb`)

A Struct representing a single API call:

| Field | Type | Description |
|-------|------|-------------|
| `id` | String | UUID, auto-generated |
| `session_id` | String | Associated session |
| `timestamp` | Time | When the call was made |
| `model` | String | Model name (e.g., "claude-sonnet-4.5") |
| `prompt_tokens` | Integer | Input tokens |
| `completion_tokens` | Integer | Output tokens |
| `cache_read_tokens` | Integer | Tokens read from cache |
| `cache_write_tokens` | Integer | Tokens written to cache |
| `cost_usd` | Float | Calculated cost in USD |
| `cost_source` | Symbol | `:api`, `:price`, or `:estimated` |

### BillingStore (`lib/clacky/billing/billing_store.rb`)

Handles persistence and querying:

```ruby
store = Clacky::Billing::BillingStore.new

# Append a record
store.append(record)

# Query with filters
records = store.query(from: 1.week.ago, model: "claude-sonnet-4.5", limit: 100)

# Get summary statistics
summary = store.summary(period: :month)
# => { total_cost: 12.34, total_tokens: 500000, by_model: {...}, ... }

# Daily breakdown for charts
daily = store.daily_breakdown(days: 30)
# => [{ date: "2026-05-01", cost: 1.23, tokens: 50000, requests: 42 }, ...]
```

---

## Storage Format

Records are stored as JSON Lines (one JSON object per line):

```jsonl
{"id":"abc123","session_id":"def456","timestamp":"2026-05-22T15:30:00+08:00","model":"claude-sonnet-4.5","prompt_tokens":1500,"completion_tokens":500,"cache_read_tokens":1000,"cache_write_tokens":0,"cost_usd":0.0045,"cost_source":"price"}
{"id":"abc124","session_id":"def456","timestamp":"2026-05-22T15:31:00+08:00","model":"claude-sonnet-4.5","prompt_tokens":2000,"completion_tokens":800,"cache_read_tokens":1500,"cache_write_tokens":0,"cost_usd":0.0052,"cost_source":"price"}
```

**Why JSONL?**
- Append-only writes (no file locking needed)
- Easy to parse line-by-line (memory efficient)
- Human-readable for debugging
- Simple monthly rotation

---

## API Endpoints

### GET /api/billing/summary

Returns aggregated statistics for a time period.

**Query Parameters:**
- `period` — `day`, `week`, `month`, `year`, or `all` (default: `month`)

**Response:**
```json
{
  "period": "month",
  "from": "2026-05-01T00:00:00+08:00",
  "to": "2026-05-22T15:30:00+08:00",
  "total_cost": 12.3456,
  "total_tokens": 500000,
  "prompt_tokens": 350000,
  "completion_tokens": 150000,
  "cache_read_tokens": 200000,
  "cache_write_tokens": 50000,
  "by_model": {
    "claude-sonnet-4.5": { "cost": 10.00, "requests": 100 },
    "deepseek-v4-flash": { "cost": 2.34, "requests": 50 }
  },
  "by_day": {
    "2026-05-22": 1.23,
    "2026-05-21": 2.34
  },
  "record_count": 150
}
```

### GET /api/billing/daily

Returns daily cost breakdown for charting.

**Query Parameters:**
- `days` — Number of days (default: 30, max: 90)

**Response:**
```json
{
  "days": [
    { "date": "2026-05-22", "cost": 1.2345, "tokens": 50000, "requests": 42 },
    { "date": "2026-05-21", "cost": 2.3456, "tokens": 80000, "requests": 65 }
  ]
}
```

### GET /api/billing/records

Returns raw billing records.

**Query Parameters:**
- `limit` — Max records (default: 100, max: 500)
- `model` — Filter by model name
- `session_id` — Filter by session ID

**Response:**
```json
{
  "records": [
    { "id": "...", "timestamp": "...", "model": "...", "cost_usd": 0.01, ... }
  ],
  "count": 100
}
```

---

## CLI Command

```bash
# Show current month's billing
clacky billing

# Show specific period
clacky billing --period week
clacky billing --period day
clacky billing --period all

# Output as JSON (for scripting)
clacky billing --json
```

**Sample Output:**
```
📊 Billing Summary (month)
──────────────────────────────────────────────────

  💰 Total Cost:       $12.3456
  📝 Total Tokens:     500,000
  📥 Prompt Tokens:    350,000
  📤 Completion:       150,000
  🗄️  Cache Read:       200,000
  📝 Cache Write:      50,000
  🔢 API Requests:     150

📈 By Model:
──────────────────────────────────────────────────
  claude-sonnet-4.5
    Cost: $10.0000  |  Requests: 100
  deepseek-v4-flash
    Cost: $2.3456  |  Requests: 50

📅 Recent Daily Usage:
──────────────────────────────────────────────────
  2026-05-22  $1.2345  ████████████
  2026-05-21  $2.3456  ████████████████████████

──────────────────────────────────────────────────
  Data stored in: ~/.clacky/billing/
```

---

## Web UI

The Billing panel is accessible from the sidebar under "My Data":

- **Summary cards** — Total cost, tokens, API requests
- **Token breakdown** — Prompt, completion, cache read/write
- **By Model table** — Cost and request count per model
- **Daily chart** — Visual bar chart of recent usage with detailed tooltips
- **Period selector** — Filter by day/week/month/year/all

### Daily Chart Tooltips

Hover over any bar in the daily chart to see detailed information:
- Date and total cost
- Input tokens (prompt)
- Output tokens (completion)
- Cache read tokens with hit rate percentage
- Cache write tokens
- Number of API requests

---

## Currency Settings

The Web UI supports multiple currencies for cost display:

| Currency | Symbol | Default Exchange Rate |
|----------|--------|----------------------|
| USD | $ | 1.0 (base) |
| CNY | ¥ | 6.7944 (customizable) |

### Configuration

1. Go to **Settings** page
2. Find the **Currency** section
3. Select `$ USD` or `¥ CNY`
4. When CNY is selected, you can customize the exchange rate

### Custom Exchange Rate

When CNY is selected, an exchange rate input field appears:
- Default rate: 6.7944 (1 USD = 6.7944 CNY)
- Enter any positive number to customize
- Changes take effect immediately
- Rate is saved to browser localStorage

### Scope

Currency settings apply to:
- Billing panel (total cost, model costs, daily chart)
- Session info bar (top cost display)
- Token usage lines (per-API-call cost)
- Task completion messages

**Note:** CLI always displays costs in USD (API's native currency).

### Implementation

Currency preference is stored in browser `localStorage`:
- `clacky-currency`: Currency code ("USD" or "CNY")
- `clacky-exchange-rate`: Custom exchange rate (number)

```javascript
// Access currency utilities from Billing module
Billing.getCurrency()       // "USD" or "CNY"
Billing.getCurrencySymbol() // "$" or "¥"
Billing.convertCost(usd)    // Convert USD to selected currency
Billing.getExchangeRate()   // Get current exchange rate
```

---

## Integration with CostTracker

The billing system hooks into `Agent::CostTracker#track_cost`:

```ruby
def track_cost(usage, raw_api_usage: nil)
  # ... existing cost calculation ...
  
  # Persist billing record (skip for subagents to avoid double-counting)
  unless @is_subagent
    persist_billing_record(usage, iteration_cost)
  end
  
  token_data
end
```

**Key behaviors:**
- Subagent costs are NOT recorded separately (parent agent merges them)
- Unknown model costs (nil) are skipped
- Persistence failures are logged but never raise

---

## Data Retention

- Records are stored indefinitely by default
- Monthly files can be manually deleted from `~/.clacky/billing/`
- Future: `BillingStore#cleanup(before: 1.year.ago)` for automated retention

---

## Future Enhancements

- [ ] Export to CSV/JSON
- [ ] Budget alerts (daily/monthly limits)
- [ ] Cost comparison across models
- [ ] Session-level cost breakdown in UI
- [x] i18n support for billing labels (English/Chinese)
- [x] Currency settings (USD/CNY)
- [ ] Dynamic exchange rate updates
- [ ] More currency options (EUR, JPY, etc.)
