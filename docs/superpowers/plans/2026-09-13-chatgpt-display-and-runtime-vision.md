# ChatGPT Display Name and Runtime Vision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use box:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Present the bundled Codex ACP integration as ChatGPT and show Visual Understanding as automatically supplied by the ChatGPT primary runtime, without enabling any other media sidecar.

**Architecture:** Keep every compatibility and implementation identifier (`codex`, Codex ACP, Codex CLI, and `CODEX_HOME`) unchanged. Change only product-facing metadata/copy plus the legacy placeholder display value, and reuse the existing runtime vision capability projection for the Settings OCR endpoint. The other five media kinds continue through the existing API-key sidecar path unchanged.

**Tech Stack:** Ruby 2.6-compatible application code, RSpec, vanilla JavaScript/i18n, YAML extension manifest.

---

### Task 1: Lock the ChatGPT product-name contract

**Files:**
- Modify: `spec/clacky/default_extensions_codex_spec.rb`
- Modify: `spec/clacky/web/runtime_provider_ui_spec.rb`
- Modify: `spec/clacky/agent_config_spec.rb`
- Modify: `spec/clacky/cli_spec.rb`
- Modify: `spec/clacky/default_extensions/codex/runtime_spec.rb`
- Modify: `lib/clacky/default_extensions/codex/ext.yml`
- Modify: `lib/clacky/default_extensions/codex/runtime.rb`
- Modify: `lib/clacky/web/i18n.js`
- Modify: `lib/clacky/web/index.html`
- Modify: `lib/clacky/cli.rb`
- Modify: `lib/clacky/agent_config.rb`

- [x] **Step 1: Write failing product-name and migration assertions**

Update the bundled provider expectations to require:

```ruby
expect(provider.spec).to include(
  "name" => "ChatGPT",
  "name_key" => "provider.name.codex",
  "runtime_id" => "codex",
  "display_model" => "ChatGPT default"
)
```

Update the Web UI assertions to require the exact English and Chinese onboarding strings `Choose another provider (API or ChatGPT)` and `选择其他服务商（API 或 ChatGPT）`, plus the exact localized provider value `ChatGPT`. Add this assertion to the runtime-model load example:

```ruby
expect(runtime).to include(
  "provider_id" => "codex",
  "runtime_id" => "codex",
  "display_model" => "ChatGPT default"
)
```

- [x] **Step 2: Run the focused specs and verify RED**

Run:

```bash
bundle exec rspec spec/clacky/default_extensions_codex_spec.rb spec/clacky/default_extensions/codex/runtime_spec.rb spec/clacky/web/runtime_provider_ui_spec.rb spec/clacky/agent_config_spec.rb spec/clacky/cli_spec.rb
```

Expected: failures show the old `Codex`, `Codex (ChatGPT)`, and `Codex default` display values.

- [x] **Step 3: Apply the minimal product-name implementation**

Set the bundled extension and provider display names to `ChatGPT`, set `display_model` to `ChatGPT default`, and change user-facing onboarding, CLI, health, authentication-result, resume-warning, and retry-warning copy from Codex to ChatGPT. Keep `id`, `runtime_id`, the `provider.name.codex` i18n key, package/process names, classes, directories, routes, environment variables, and explicit Codex ACP/CLI diagnostics unchanged.

While parsing persisted runtime cards, normalize only this exact legacy case:

```ruby
if sanitized["provider_id"] == "codex" &&
   sanitized["runtime_id"] == "codex" &&
   sanitized["display_model"] == "Codex default"
  sanitized["display_model"] = "ChatGPT default"
end
```

- [x] **Step 4: Run the focused specs and verify GREEN**

Run the same focused RSpec command. Expected: all examples pass.

### Task 2: Project ChatGPT primary vision into Settings

**Files:**
- Modify: `spec/clacky/server/http_server_runtime_spec.rb`
- Modify: `lib/clacky/server/http_server.rb`

- [x] **Step 1: Write the failing endpoint behavior test**

Add a runtime-provider example that dispatches `GET /api/config/ocr` and asserts:

```ruby
expect(parsed_body(res).fetch("ocr")).to include(
  "configured" => true,
  "source" => "auto",
  "primary" => true,
  "provider" => "codex",
  "model" => "ChatGPT default"
)
```

Also assert that `GET /api/config/media` still returns `model: nil` for image, video, audio, STT, and video understanding defaults.

- [x] **Step 2: Run the endpoint spec and verify RED**

Run:

```bash
bundle exec rspec spec/clacky/server/http_server_runtime_spec.rb
```

Expected: the OCR response is currently `source: off`, `configured: false`.

- [x] **Step 3: Reuse the runtime vision projection in the OCR endpoint**

Preserve a configured custom OCR sidecar, otherwise prefer the runtime capability payload:

```ruby
state = @agent_config.ocr_state
runtime_vision = runtime_vision_payload(@agent_config, nil)
state = runtime_vision if runtime_vision && state["source"] != "custom"
```

Extend the existing runtime payload, without persistence, to include the shape already consumed by Settings:

```ruby
{
  "configured" => true,
  "source" => "auto",
  "provider" => card["provider_id"],
  "primary" => true,
  "model" => effective_model,
  "available" => []
}
```

Do not change media derivation, media adapters, credentials, or any of the other five media-kind defaults.

- [x] **Step 4: Run the endpoint spec and verify GREEN**

Run the same focused RSpec command. Expected: all examples pass.

### Task 3: Synchronize user documentation and verify the branch

**Files:**
- Modify: `README.md`
- Modify: `README_CN.md`
- Modify: `README_JA.md`
- Modify: `docs/superpowers/specs/2026-09-11-codex-acp-provider-design.md`

- [x] **Step 1: Update product-facing documentation**

Use `ChatGPT` for the provider name and `ChatGPT default` for its placeholder model. Retain `Codex ACP`, `Codex CLI`, `.codex`, and `CODEX_HOME` wherever they identify the underlying integration or filesystem contract. Document that only Visual Understanding is automatically supplied by the primary runtime.

- [x] **Step 2: Run syntax and diff checks**

Run:

```bash
ruby -c lib/clacky/agent_config.rb
ruby -c lib/clacky/server/http_server.rb
node --check lib/clacky/web/i18n.js
git diff --check
```

Expected: each syntax command reports success and `git diff --check` prints nothing.

- [x] **Step 3: Run the complete test suite**

Run:

```bash
bundle exec rspec
```

Expected: zero failures.

- [x] **Step 4: Commit only scoped files**

Stage the files listed in this plan, explicitly excluding the pre-existing user-owned `Gemfile.lock`, then commit:

```bash
git commit -m "feat: present Codex runtime as ChatGPT"
```

- [x] **Step 5: Restart and verify port 7777**

Restart the branch server on port 7777, confirm `/api/providers` exposes `name: ChatGPT`, confirm `/api/config/ocr` exposes primary automatic vision, and verify the Settings page renders ChatGPT plus the read-only Visual Understanding message.
