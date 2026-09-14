# Codex ACP Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use box:executing-plans to implement this plan task-by-task.

**Goal:** Add `Codex (ChatGPT)` to OpenClacky's existing model-provider picker and run Codex-backed sessions through ACP without requiring an API key, base URL, or preselected model.

**Architecture:** Core gains protocol-neutral provider and agent-runtime registries plus a host-owned runtime session facade. A bundled, default-enabled Codex extension contributes the provider descriptor and implements managed login state, the pinned codex-acp launcher, and ACP event translation. API-backed models continue through `Clacky::Client` and `Clacky::Agent` unchanged; runtime cards are persisted separately under `runtime_models` for downgrade safety.

**Tech Stack:** Ruby 2.6-compatible stdlib (`Open3`, `JSON`, `Thread`, `Monitor`/`Mutex`), RSpec, existing vanilla JavaScript Web UI, ACP v1 over stdio NDJSON, `@agentclientprotocol/codex-acp@1.11.0` with Node.js 20+ for the prototype launcher.

---

## Task 1: Add provider and runtime extension contributions

**Files:**

- Modify: `lib/clacky/extension/loader.rb`
- Modify: `lib/clacky/extension/verifier.rb`
- Test: `spec/clacky/extension_loader_spec.rb`
- Test: `spec/clacky/extension_verifier_spec.rb`
- Test: `spec/clacky/extension_kitchen_sink_spec.rb`

- [x] Write loader specs for valid `contributes.providers` and `contributes.agent_runtimes`, missing required fields, and a runtime adapter path that does not exist.
- [x] Run `bundle exec rspec spec/clacky/extension_loader_spec.rb` and confirm the new examples fail because the contributions are not recognized.
- [x] Extend `ExtensionLoader::Result`, `#units`, `#resolve_units`, and unit builders. Provider units accept only presentation/configuration fields; runtime units expose a validated `adapter_abs` inside the extension directory.
- [x] Write verifier specs for the two schemas, unknown keys, missing provider runtime references, provider collisions, and runtime ID collisions.
- [x] Run `bundle exec rspec spec/clacky/extension_verifier_spec.rb spec/clacky/extension_kitchen_sink_spec.rb` and confirm the new examples fail.
- [x] Extend verifier allowlists and whole-result reference/collision checks without changing existing extension manifests.
- [x] Run all three spec files and commit with `feat: add provider runtime extension contributions`.

## Task 2: Introduce provider and agent-runtime registries

**Files:**

- Create: `lib/clacky/provider_registry.rb`
- Create: `lib/clacky/agent_runtime_registry.rb`
- Modify: `lib/clacky.rb`
- Test: `spec/clacky/provider_registry_spec.rb`
- Test: `spec/clacky/agent_runtime_registry_spec.rb`

- [x] Write provider-registry specs that preserve every legacy preset field, merge enabled extension descriptors in manifest order, return defensive copies, reject duplicate IDs, and resolve `runtime_id` from a provider ID.
- [x] Run `bundle exec rspec spec/clacky/provider_registry_spec.rb` and confirm it fails because the registry is absent.
- [x] Implement `Clacky::ProviderRegistry` over `Providers::PRESETS` and extension units. Do not add Codex to `PRESETS`.
- [x] Write runtime-registry specs for lazy adapter loading, exact class resolution, unknown runtime IDs, adapter load failures, duplicate IDs, and injected test factories.
- [x] Run `bundle exec rspec spec/clacky/agent_runtime_registry_spec.rb` and confirm it fails.
- [x] Implement `Clacky::AgentRuntimeRegistry`, require both registries from `lib/clacky.rb`, rerun both specs, and commit with `feat: add provider and agent runtime registries`.

## Task 3: Persist credentialless runtime cards safely

**Files:**

- Modify: `lib/clacky/agent_config.rb`
- Test: `spec/clacky/agent_config_spec.rb`
- Test: `spec/clacky/agent_config_reload_spec.rb`
- Test: `spec/clacky/agent_config_model_id_spec.rb`

- [x] Write specs loading a mixed `models` plus `runtime_models` config, assigning runtime-only IDs, selecting a runtime default, round-tripping only the runtime allowlist, and preserving all legacy formats.
- [x] Run the three focused spec files and confirm the runtime examples fail.
- [x] Parse both arrays into the in-memory model list, mark runtime cards internally, and serialize them back into separate top-level arrays. Never persist `id`, auth state, token fields, `api_key`, `base_url`, or a fake `model` for runtime cards.
- [x] Write reload specs proving `(runtime_id, provider_id)` restores runtime identity and two credentialless cards do not collide through `(nil, nil)` model lookup.
- [x] Implement runtime-aware lookup/reload and ensure API-derived sidecar/lite-model helpers ignore runtime cards.
- [x] Run the focused specs and commit with `feat: persist agent runtime model cards`.

## Task 4: Expose runtime providers through existing model APIs

**Files:**

- Modify: `lib/clacky/server/http_server.rb`
- Modify: `spec/support/http_server_spec_helpers.rb`
- Test: `spec/clacky/server/http_server_spec.rb`

- [x] Add injectable provider/runtime registries to the HTTP server test helper.
- [x] Write API specs proving `GET /api/providers` is backward compatible and includes the Codex runtime fields, while `GET /api/config` exposes a display label but no secret fields.
- [x] Write CRUD specs proving `POST /api/config/models` can save `{provider_id: "codex"}` without key/model/URL, derives `runtime_id` server-side, rejects a spoofed or unknown runtime, and still rejects incomplete API-backed models.
- [x] Write test/probe specs proving a runtime card invokes runtime health status and never constructs `Clacky::Client`.
- [x] Run the focused API examples and confirm they fail.
- [x] Route provider listing, create/update/delete/default selection, and test behavior through the registries while preserving legacy response shapes.
- [x] Run `bundle exec rspec spec/clacky/server/http_server_spec.rb` and commit with `feat: support runtime providers in model APIs`.

## Task 5: Add a reusable ACP v1 stdio client

**Files:**

- Create: `lib/clacky/acp/client.rb`
- Create: `lib/clacky/acp/process_transport.rb`
- Modify: `lib/clacky.rb`
- Create: `spec/support/fake_acp_agent.rb`
- Create: `spec/clacky/acp/client_spec.rb`
- Create: `spec/clacky/acp/process_transport_spec.rb`

- [x] Build a fake newline-delimited JSON-RPC agent that can initialize, stream notifications, issue reverse permission requests, complete prompts, reject malformed requests, and exit on demand.
- [x] Write client specs for monotonic request IDs, concurrent pending requests, serialized writes, notifications by session ID, reverse request dispatch, method-specific timeouts, malformed/oversized output, EOF propagation, and redacted bounded stderr.
- [x] Run the ACP specs and confirm they fail because the client is absent.
- [x] Implement the protocol client with a dedicated reader thread and no shell parsing. Long prompt/auth requests remain cancellable rather than inheriting a global short timeout.
- [x] Write process-transport specs for controlled environment variables, exact argv, process-group ownership, graceful stdin close, and forced cleanup fallback.
- [x] Implement transport lifecycle, run the ACP specs repeatedly to catch races, and commit with `feat: add ACP stdio client`.

## Task 6: Ship the bundled Codex extension shell and safe managed home

**Files:**

- Create: `lib/clacky/default_extensions/codex/ext.yml`
- Create: `lib/clacky/default_extensions/codex/runtime.rb`
- Create: `lib/clacky/default_extensions/codex/codex_home.rb`
- Create: `lib/clacky/default_extensions/codex/launcher.rb`
- Create: `lib/clacky/default_extensions/codex/api/handler.rb`
- Test: `spec/clacky/default_extensions_codex_spec.rb`
- Test: `spec/clacky/default_extensions_spec.rb`

- [x] Write manifest specs proving Codex is a built-in, default-enabled provider/runtime contribution visible before onboarding.
- [x] Write managed-home specs covering mode `0700`, secure same-user `auth.json` symlink reuse, rejection of symlinked/world-readable/out-of-home sources, no credential-copy fallback, and no inheritance of config/plugins/skills/MCP/history.
- [x] Write launcher specs for an explicit verified path, a packaged managed Node entry point, rejection/diagnostics for implicitly discovered installed adapters, the Node 20+ double-pinned npx fallback, a sanitized environment, and actionable missing/incompatible dependency states.
- [x] Run the focused specs and confirm they fail.
- [x] Implement the manifest, home manager, launcher, and an extension API shell whose status payload cannot contain token/auth-file contents.
- [x] Run the focused specs and commit with `feat: add bundled Codex provider extension`.

## Task 7: Implement Codex authentication and ACP session runtime

**Files:**

- Modify: `lib/clacky/default_extensions/codex/runtime.rb`
- Modify: `lib/clacky/default_extensions/codex/api/handler.rb`
- Create: `spec/clacky/default_extensions/codex/runtime_spec.rb`
- Modify: `spec/clacky/default_extensions_codex_spec.rb`

- [x] Write initialize/auth specs for ACP version 1, `agentCapabilities._meta.authStatus`, cached `_auth/status_update`, the deprecated status fallback, advertised `chat-gpt` auth, asynchronous authenticate, duplicate-login exclusion, and failure cleanup.
- [x] Write session specs for `session/new`, transcript-safe `session/resume`, missing external-session fallback, complete `configOptions` replacement, persisted effective model/effort, and advertised permission-mode mapping.
- [x] Write prompt specs for text/image blocks, single-flight enforcement, completion only on the original prompt response, cancellation notification, late-event generation fences, and FIFO follow-up instead of `_session/steering`.
- [x] Write event specs for assistant chunks, bounded thought summaries, keyed tool calls/updates, plans, usage, session info, unknown updates, and asynchronous permission decisions defaulting to reject.
- [x] Run the focused runtime specs and confirm they fail.
- [x] Implement authentication, ACP lifecycle, event normalization, secret-free `dump_state`, `cancel`, and `close`, then commit with `feat: implement Codex ACP runtime`.

## Task 8: Add the host runtime-session facade

**Files:**

- Create: `lib/clacky/runtime_session.rb`
- Modify: `lib/clacky.rb`
- Test: `spec/clacky/runtime_session_spec.rb`

- [x] Inventory the common methods used by `SessionRegistry`, `HttpServer`, and history replay, and encode only those host responsibilities in facade specs.
- [x] Write specs for metadata, `MessageHistory`, pending-input CRUD/FIFO, current runtime display info, task counters, capability checks, normalized event persistence, secret-free serialization, and unsupported agent-only operations.
- [x] Run `bundle exec rspec spec/clacky/runtime_session_spec.rb` and confirm it fails.
- [x] Implement the facade around a provider runtime without emulating private `Clacky::Agent` internals. Unsupported Time Machine, sub-model, skill/slash, fork, idle-compression, channel, and scheduler operations return explicit capability failures.
- [x] Run the focused spec and commit with `feat: add host runtime session facade`.

## Task 9: Integrate runtime sessions with server lifecycle

**Files:**

- Modify: `lib/clacky/server/http_server.rb`
- Modify: `lib/clacky/server/session_registry.rb`
- Modify: `lib/clacky/agent/session_serializer.rb`
- Create: `spec/clacky/server/http_server_runtime_spec.rb`
- Modify: `spec/clacky/server/http_server_input_queue_spec.rb`
- Modify: `spec/clacky/server/session_registry_spec.rb`

- [x] Write creation/restoration specs proving runtime selection happens before `Clacky::Client`, legacy session files still restore unchanged, runtime state resumes without provider-history replay, and an unavailable runtime leaves the local transcript readable.
- [x] Write supervisor specs proving `run_agent_task` remains the status/epoch/persistence boundary, ACP events carry explicit generations, and idle compression is disabled for runtime sessions.
- [x] Write cancellation/replacement specs proving `session/cancel` is sent first, a second prompt cannot start before the old prompt response, permission waiters are cancelled, and timeout fallback cannot produce two live prompts.
- [x] Write registry specs proving close/cancel happens outside the registry mutex, mixed Agent/runtime eviction is safe, and fork rejects runtime sessions instead of copying an external session ID.
- [x] Run the focused runtime/server specs and confirm they fail.
- [x] Add the runtime branch to build, restore, run, interrupt, replay, delete, shutdown, and capability-gated endpoints while preserving the legacy branch byte-for-byte where practical.
- [x] Run the focused server/session specs and commit with `feat: integrate agent runtimes with sessions`.

## Task 10: Add Codex to onboarding and Settings provider selection

**Files:**

- Modify: `lib/clacky/web/index.html`
- Modify: `lib/clacky/web/components/onboard.js`
- Modify: `lib/clacky/web/settings.js`
- Modify: `lib/clacky/web/features/model-tester/store.js`
- Modify: `lib/clacky/web/components/model-picker.js`
- Modify: `lib/clacky/web/features/new-session/view.js`
- Modify: `lib/clacky/web/i18n.js`
- Create: `spec/clacky/web/runtime_provider_ui_spec.rb`
- Modify: `spec/clacky/web/syntax_spec.rb`

- [x] Write UI source-contract specs for provider-ID selection, hiding model/base URL/key/API format, runtime status states, login polling termination, credentialless save payload, `display_model` fallback, and restoring API fields when switching back.
- [x] Write onboarding specs proving runtime selection skips the API model tester and `/onboard` skill command, but completes normal onboarding and opens the session.
- [x] Write Settings specs proving add/test/remove/default actions use the same model-card UI, `_modalSelectedProviderId` takes precedence over URL matching, and runtime-to-API editing cannot retain stale credentials.
- [x] Run the UI and syntax specs and confirm they fail.
- [x] Add reusable runtime-provider field/status rendering to the existing forms and provider cards. Do not create a second Codex-only settings page.
- [x] Run `bundle exec rspec spec/clacky/web/runtime_provider_ui_spec.rb spec/clacky/web/syntax_spec.rb` and commit with `feat: add Codex to model provider UI`.

## Task 11: Verify compatibility, diagnostics, and documentation

**Files:**

- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-09-11-codex-acp-provider-design.md`
- Modify: relevant existing specs discovered by the full suite only when they encode intended behavior

- [x] Add user-facing setup and troubleshooting for Node 20+, pinned prototype fallback, managed `CODEX_HOME`, safe source Codex-home `auth.json` reuse, browser login, and the fact that the actual model appears after session creation.
- [x] Run the focused extension, config, ACP, runtime, server, and Web UI specs.
- [x] Run `bundle exec rspec` and fix every regression without weakening existing assertions.
- [x] Run `ruby -c` on every new Ruby source file using the project Ruby and run `git diff --check`.
- [x] Manually launch the Web UI in an isolated home, verify Codex is offered by the existing provider API/dropdown, complete a real ACP handshake with the exact pinned adapter/Codex pair, verify the not-connected state, and persist a credentialless Codex model card.
- [ ] Release gate: with an authenticated account, verify reusable-login and browser-login states, send a text prompt, interrupt a turn, restart OpenClacky, and resume the ACP session.
- [x] Review logs, config YAML, session JSON, HTTP payloads, and WebSocket events for credentials or raw adapter stderr.
- [x] Commit final documentation/compatibility fixes with `docs: document Codex ACP provider setup`.
