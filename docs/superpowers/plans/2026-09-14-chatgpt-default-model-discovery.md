# ChatGPT Default Model Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use box:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect ChatGPT and load its ACP-advertised model catalog before the first user prompt, require a normal default-model choice when creating the model card, and apply that default to new ChatGPT sessions.

**Architecture:** The bundled Codex extension adds an authenticated discovery operation that opens a temporary ACP session, reads the model `configOptions`, and always closes the session. Onboarding and Settings use this operation to populate their existing model selectors; the selected model is persisted as the runtime card's `display_model`, while per-session model switches remain session-local.

**Tech Stack:** Ruby 2.6-compatible stdlib, RSpec, vanilla JavaScript Web UI, ACP v1 over stdio NDJSON.

---

### Task 1: Add temporary ACP model discovery

**Files:**
- Modify: `lib/clacky/default_extensions/codex/runtime.rb`
- Modify: `lib/clacky/default_extensions/codex/api/handler.rb`
- Test: `spec/clacky/default_extensions/codex/runtime_spec.rb`
- Test: `spec/clacky/default_extensions_codex_spec.rb`

- [x] **Step 1: Write failing runtime discovery tests**

Add examples proving that discovery starts the shared connection, rejects an unauthenticated account, extracts the model option's current value and flattened choices, and closes the temporary ACP session even when parsing fails:

```ruby
result = connection.discover_models(working_dir: Dir.pwd)
expect(result).to include(
  ok: true,
  status: "connected",
  default_model: "gpt-5.6-sol",
  models: %w[gpt-6-astra gpt-5.6-sol]
)
expect(client.requests.map(&:first)).to include("session/new", "session/close")
expect(connection).not_to have_bound_sessions
```

- [x] **Step 2: Run the focused tests and verify RED**

Run:

```bash
BUNDLE_FROZEN=true bundle exec rspec \
  spec/clacky/default_extensions/codex/runtime_spec.rb \
  spec/clacky/default_extensions_codex_spec.rb
```

Expected: failures because `discover_models` and `POST /discover` do not exist.

- [x] **Step 3: Implement connection-owned discovery**

Add a discovery mutex and a public operation with this contract:

```ruby
def discover_models(working_dir: Dir.pwd)
  # 1. ensure_client and confirm status_snapshot is authenticated
  # 2. request session/new with absolute cwd and an empty MCP list
  # 3. extract id == "model" from configOptions
  # 4. return only bounded string values and the currentValue
  # 5. request session/close in ensure whenever a session id was returned
end
```

The result must contain only `ok`, `status`, `authenticated`, `default_model`, `models`, and a safe `message`. It must never bind the temporary session to a runtime, persist its session ID, or expose ACP metadata.

- [x] **Step 4: Expose discovery through the bundled extension**

Add `Runtime.discover_models(working_dir: Dir.pwd)` and a same-origin endpoint:

```ruby
post "/discover", timeout: 310, same_origin: true do
  json(Clacky::DefaultExtensions::Codex::Runtime.discover_models)
end
```

- [x] **Step 5: Run the focused tests and verify GREEN**

Run the command from Step 2. Expected: all examples pass.

### Task 2: Persist and apply the selected default model

**Files:**
- Modify: `lib/clacky/server/http_server.rb`
- Modify: `lib/clacky/runtime_session.rb`
- Modify: `lib/clacky/default_extensions/codex/runtime.rb`
- Modify: `lib/clacky/default_extensions/codex/ext.yml`
- Test: `spec/clacky/server/http_server_runtime_spec.rb`
- Test: `spec/clacky/runtime_session_spec.rb`
- Test: `spec/clacky/default_extensions/codex/runtime_spec.rb`
- Test: `spec/clacky/default_extensions_codex_spec.rb`

- [x] **Step 1: Write failing persistence and session-default tests**

Cover these cases:

```ruby
post_json "/api/config/models", {
  provider_id: "codex",
  display_model: "gpt-5.6-sol",
  type: "default"
}
expect(saved_runtime_card["display_model"]).to eq("gpt-5.6-sol")
```

- missing or blank `display_model` returns `422`;
- a value absent from fresh discovery returns `422`;
- PATCH may change only to an advertised model;
- legacy `Codex default` and `ChatGPT default` cards can migrate to the discovered default;
- a new runtime session receives the card default in its runtime context;
- a restored session's saved model wins over the card default;
- a new ACP session calls `session/set_config_option` for the card default before its first prompt.

- [x] **Step 2: Run the focused tests and verify RED**

Run:

```bash
BUNDLE_FROZEN=true bundle exec rspec \
  spec/clacky/server/http_server_runtime_spec.rb \
  spec/clacky/runtime_session_spec.rb \
  spec/clacky/default_extensions/codex/runtime_spec.rb \
  spec/clacky/default_extensions_codex_spec.rb
```

Expected: failures around runtime-card field validation and default propagation.

- [x] **Step 3: Change the runtime-card contract**

Remove the static placeholder from the provider descriptor and mark dynamic models as discovery-backed:

```yaml
dynamic_models: discovery
```

Accept `display_model` only for runtime-card create/update. Before mutation, discover the current model catalog and require exact membership. Preserve the existing credentialless allowlist and keep `display_model` as the only persisted default-model field.

- [x] **Step 4: Propagate the card default to the runtime**

Add the selected default to the runtime context:

```ruby
context = {
  # existing entries
  default_model: @config.current_model && @config.current_model["display_model"]
}
```

The Codex runtime stores that value separately from restored session state. During session configuration it applies restored `model` first; otherwise it applies the card default, but only if ACP advertises the value.

- [x] **Step 5: Run the focused tests and verify GREEN**

Run the command from Step 2. Expected: all examples pass.

### Task 3: Require model selection in Onboarding and Settings

**Files:**
- Modify: `lib/clacky/web/index.html`
- Modify: `lib/clacky/web/features/model-tester/store.js`
- Modify: `lib/clacky/web/components/onboard.js`
- Modify: `lib/clacky/web/settings.js`
- Modify: `lib/clacky/web/i18n.js`
- Modify: `lib/clacky/web/app.css`
- Modify: `spec/clacky/web/runtime_provider_ui_spec.rb`
- Modify: `spec/clacky/web/syntax_spec.rb`

- [x] **Step 1: Write failing UI source-contract tests**

Assert that:

```ruby
expect(runtime_store).to include('runtimeRequest(provider, "discover", { method: "POST" })')
expect(onboard).to include("display_model: selectedModel")
expect(settings).to include("display_model: selectedModel")
```

Also require configured runtime cards to initiate connection instead of passive-only status, require the save/continue button to stay disabled until discovery succeeds and a model is selected, and keep API-provider fields unchanged.

- [x] **Step 2: Run the UI tests and verify RED**

Run:

```bash
BUNDLE_FROZEN=true bundle exec rspec \
  spec/clacky/web/runtime_provider_ui_spec.rb \
  spec/clacky/web/syntax_spec.rb
```

Expected: failures because discovery and runtime model selection are absent.

- [x] **Step 3: Add the shared discovery helper**

Extend `RuntimeProvider`:

```javascript
function discover(provider) {
  return runtimeRequest(provider, "discover", { method: "POST" });
}
```

Normalize `models` to unique non-empty strings and select `default_model` only when it belongs to that list.

- [x] **Step 4: Reuse the existing model comboboxes for runtime providers**

Keep the Model field visible while hiding Base URL, API Key, and API Format. Make the runtime model input selection-only after discovery; populate its dropdown from the returned catalog and preselect the returned default or the existing card model.

Update the runtime hint to explain that this is the default for new conversations. Disable Save/Continue while disconnected, discovering, empty, or holding a value outside the discovered catalog.

- [x] **Step 5: Save the selected model and eagerly connect cards**

Include the selected `display_model` in runtime create/update payloads. When a configured ChatGPT card renders, call connect once for the shared provider, then discover; render `Starting` during the operation and `Connected` afterward. If an existing card contains a recognized placeholder, PATCH it to the discovered default after successful validation.

- [x] **Step 6: Run the UI tests and verify GREEN**

Run the command from Step 2. Expected: all examples pass and JavaScript syntax checks succeed.

### Task 4: Verify the complete change and update PR evidence

**Files:**
- Modify: `README.md`
- Modify: `README_CN.md`
- Modify: `README_JA.md`
- Modify: `docs/superpowers/plans/2026-09-14-chatgpt-default-model-discovery.md`

- [x] **Step 1: Update setup documentation**

Replace the statement that the actual model appears only after the first message. Document that setup connects ChatGPT, loads the account's model list, and requires a default selection before saving.

- [x] **Step 2: Run focused regression suites**

Run:

```bash
BUNDLE_FROZEN=true bundle exec rspec \
  spec/clacky/default_extensions/codex/runtime_spec.rb \
  spec/clacky/default_extensions_codex_spec.rb \
  spec/clacky/server/http_server_runtime_spec.rb \
  spec/clacky/runtime_session_spec.rb \
  spec/clacky/web/runtime_provider_ui_spec.rb \
  spec/clacky/web/syntax_spec.rb
```

Expected: zero failures.

- [x] **Step 3: Run the complete project verification**

Run:

```bash
BUNDLE_FROZEN=true bundle exec rspec
git diff --check
```

Expected: zero RSpec failures and no whitespace errors.

Observed on 2026-09-14: all 4,570 non-MCP examples passed; the complete
4,574-example run retained the same four pre-existing fake-MCP initialize
timeouts reproduced before implementation. `git diff --check` passed.

- [x] **Step 4: Perform live local verification**

On port 7777, verify that opening Settings without sending a message shows ChatGPT connected, the model card displays the selected real model, Add Model requires a choice from the discovered list, and no discovery conversation appears in the sidebar.

- [x] **Step 5: Commit the cohesive implementation**

Stage implementation, tests, and synchronized documentation while excluding the user's pre-existing `Gemfile.lock` change:

```bash
git add README.md README_CN.md README_JA.md docs/superpowers \
  lib/clacky/default_extensions/codex lib/clacky/runtime_session.rb \
  lib/clacky/server/http_server.rb lib/clacky/web spec/clacky
git commit -m "fix: configure ChatGPT before first prompt"
```
