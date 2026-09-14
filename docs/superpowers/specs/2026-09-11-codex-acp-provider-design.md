# Codex ACP Provider Design

## Purpose

OpenClacky currently treats every configured model as a remote LLM API identified by a model name, base URL, and API key. Codex is different: it is a local agent runtime with its own authentication, conversation identity, approval flow, tools, and streamed events. The client must nevertheless present Codex in the same provider picker used for existing model cards, both during first-run setup and later in Settings.

This design adds a protocol-neutral agent-runtime extension point to core and ships Codex as a bundled extension implemented through Agent Client Protocol (ACP). Existing API-key providers and saved sessions remain compatible.

This is a bundled, default-enabled client extension rather than a separately installed marketplace extension. It is loaded early enough to contribute its provider descriptor before first-run onboarding, so `ChatGPT` appears directly in the existing model configuration provider dropdown. Core owns only the generic provider/runtime contracts; the bundled extension owns every Codex-specific behavior. User-facing product copy says ChatGPT; `codex`, Codex ACP, Codex CLI, and `CODEX_HOME` remain implementation names and compatibility identifiers.

A marketplace-only extension cannot guarantee that Codex is visible during first-run setup, while hard-coding Codex into core would couple provider-specific authentication and lifecycle behavior to the client. Bundling and enabling the extension by default preserves zero-install setup and a clean runtime boundary at the same time.

## Decision Summary

The first implementation uses this chain:

```text
OpenClacky Web UI
  -> OpenClacky session/runtime SPI
  -> bundled Codex provider extension
  -> codex-acp 1.11.0 over stdio NDJSON
  -> Codex CLI `app-server` (verified with 0.153.4)
  -> ChatGPT account
```

The key decisions are:

- Use ACP instead of implementing the Codex App Server protocol directly. `codex-acp` already translates authentication, model configuration, session operations, approvals, tool events, and streamed output into a provider-neutral protocol.
- Add a thin core runtime SPI and provider contribution type. Do not implement the feature with `contributes.patches` monkey-patches.
- Put Codex-specific startup, authentication, home-directory preparation, event mapping, and diagnostics in a bundled default extension.
- Use an application-managed `CODEX_HOME` for sessions, state databases, caches, and logs. Reuse an existing file-backed Codex login only through a validated `auth.json` symlink and rebuild the managed config from a strict allowlist of model preferences; do not reuse the whole user Codex home.
- Start with codex-acp's safer `read-only` mode, then map each OpenClacky permission mode to an advertised adapter mode after session creation. Never select `agent-full-access` automatically.
- Pin the version pair `@agentclientprotocol/codex-acp@1.11.0` and `@openai/codex@0.153.4`. For every launch path, verify the published adapter bundle by SHA-256, require the exact Codex package version, and patch the adapter's unconditional project trust assignment to `untrusted`, so project-local config, hooks, and exec policies cannot become an out-of-sandbox code-execution path. The prototype uses double-pinned `npx` with npm package-integrity verification, or an explicit operator-trusted packaging path; production packaging must lock and attest the full dependency tree and platform binary.

`codex-acp` is itself an adapter that starts Codex App Server. ACP therefore does not bypass the official Codex runtime; it gives OpenClacky a stable, reusable client-side contract and avoids duplicating Codex-specific event translation in Ruby. OpenAI describes App Server as its first-class Codex integration surface, while the [ACP architecture](https://agentclientprotocol.com/get-started/architecture) standardizes multi-agent client integration over JSON-RPC and stdio. OpenClacky deliberately uses the published [Codex ACP adapter](https://www.npmjs.com/package/@agentclientprotocol/codex-acp) because its product boundary is a provider/agent picker that can later host other ACP agents. Codex-specific `_meta` fields remain available to the extension so the design does not force every agent into only the lowest common subset. See OpenAI's [App Server integration guidance](https://openai.com/index/unlocking-the-codex-harness/) for the underlying Codex runtime trade-offs.

## User Experience

### First-run setup

The existing provider dropdown gains a `ChatGPT` entry. Its descriptor marks it as an agent runtime and as not requiring a base URL or API key.

When selected:

- Base URL, API key, API format, and provider-key help are hidden.
- Base URL and API Key fields are hidden. The model field becomes a required runtime-backed selector after ChatGPT connects and model discovery completes.
- Selecting ChatGPT starts the shared ACP connection in the background. The connection panel distinguishes `Starting`, `Connected`, `Not connected` (a live runtime that reported no account), and actionable dependency/version errors without requiring a user-visible conversation or first prompt.
- If a reusable Codex login is already available, the user can continue without signing in again.
- Otherwise, `Connect with ChatGPT` starts ACP's `chat-gpt` authentication method, opens the system browser, and the page polls status until the account is connected.
- After authentication, OpenClacky discovers the account's ACP-advertised models through a temporary, non-user-visible session and closes that discovery session immediately. The user's current Codex preference is preselected when it remains available.
- `Continue` is enabled only after the user has selected the model they normally want to use. It saves a credentialless runtime card whose display model is that selection, then follows the existing onboarding completion flow without sending the OpenClacky-specific `/onboard` skill command to Codex.

The OpenClacky AI Keys device-login card remains unchanged. Its secondary action uses provider-neutral copy (`Choose another provider (API or ChatGPT)`), and ChatGPT appears in that normal provider list rather than behind a dedicated setup path.

### Settings

The Add Model dialog uses the same provider descriptor behavior. Selecting ChatGPT hides API-key-only fields, starts or reuses the shared ACP connection, and loads a required model selector from a temporary discovery session. Saving validates that the selected model is still advertised and stores it as the normal default for future ChatGPT sessions.

ChatGPT model cards show the provider name, the user's selected default model (for example, `gpt-5.6-sol`), connection state, and a `Test` action that checks ACP process readiness plus authentication. The placeholder `ChatGPT default` is not normal user-facing state; existing cards that still contain it are upgraded after successful discovery. Each new ACP session starts with the card's selected default when that value is still advertised. The session model picker may temporarily switch the active session without changing the saved default for other sessions. Removing the card removes only OpenClacky's model configuration. It does not log out the shared ChatGPT account or delete the source Codex home's `auth.json` (`$CODEX_HOME`, or `~/.codex` when unset).

When ChatGPT is the default runtime, Settings projects its declared image-input capability into the existing Visual Understanding row as a read-only primary capability: `configured: true`, `source: auto`, and `primary: true`. This does not create or persist an OCR sidecar. Image generation, video generation, audio generation, speech transcription, and video understanding remain unchanged and are not inferred from the ChatGPT login because those paths require separate media adapters and API credentials.

### Session behavior

Creating an OpenClacky session with a Codex card creates the local host session immediately; the first prompt creates or resumes its ACP session in that workspace and applies the card's selected default model before the prompt. Connection and model discovery have already happened during setup or Settings, so the user does not need to send a sacrificial first message to make ChatGPT appear connected or populate model choices. Prompts, supported image attachments, cancellation, streamed assistant output, tool activity, usage, and permission requests are mapped into the existing OpenClacky session UI. The sidebar and session URL remain owned by OpenClacky.

`session/new` and `session/resume` are side-effectful bootstrap operations: codex-acp may refresh Skills, create or load a Codex thread, enumerate models, and refresh account state before returning the authoritative session ID. They therefore do not inherit the five-second timeout used by short control requests. OpenClacky waits for their response and uses its generation-scoped Stop/cancel watchdog to terminate a stuck ACP process; abandoning the JSON-RPC request while the adapter continued would lose a late session ID and create a duplicate thread on retry.

If a saved ACP thread can no longer be resumed, or is already owned by another live OpenClacky session, the runtime starts a fresh Codex thread for the current turn. The local transcript remains readable, but it is not replayed into the new thread; OpenClacky emits a visible warning so this loss of runtime-context continuity is never silent.

Features that require internals unique to `Clacky::Agent` are capability-gated for ACP sessions. ACP-native model selection has its own runtime capability and reuses only the existing model-picker presentation; it remains distinct from OpenClacky's static provider sub-model overlays. The effective ACP reasoning level is visible but read-only because version 1 does not expose a reasoning-selection runtime capability. OpenClacky-specific Skill autocomplete and `/new` project initialization are omitted, and Fork controls are hidden, for runtime sessions rather than sending unsupported host commands as ordinary Codex prompts. The first version does not expose Time Machine branching, OpenClacky idle compression, or OpenClacky goal loops on Codex sessions. Unsupported capabilities, forks, and live API/runtime provider switches return `409 Conflict`; malformed runtime-card fields and forged runtime IDs return `422 Unprocessable Content`. Switching between API and runtime cards, or between runtime provider cards, requires a new session.

Runtime-native model selection also fails closed across concurrency boundaries. If a prompt starts after the HTTP handler's initial status check, the runtime raises the host-owned busy error and the endpoint returns `409 Conflict`; a model selection that returns `false` is not persisted or broadcast as a successful change.

## Core Extension Boundary

### Provider contributions

`ext.yml` gains a `contributes.providers` array. A provider descriptor is presentation and configuration metadata; it does not contain credentials or execute code.

The bundled Codex descriptor has this conceptual shape:

```yaml
contributes:
  providers:
    - id: codex
      name: ChatGPT
      name_key: provider.name.codex
      runtime_id: codex
      auth_mode: runtime
      credential_fields: []
      dynamic_models: discovery
      capabilities:
        vision: true
```

`Clacky::ProviderRegistry` merges the existing built-in `Providers::PRESETS` with enabled extension descriptors. Extension IDs cannot silently override a built-in provider or another winning descriptor; collisions are verifier errors. `GET /api/providers` projects the combined registry and preserves the current response fields for old UI clients.

### Runtime contributions

`ext.yml` also gains `contributes.agent_runtimes`:

```yaml
contributes:
  agent_runtimes:
    - id: codex
      adapter: runtime.rb
      class: Clacky::DefaultExtensions::Codex::Runtime
```

The loader resolves and validates the adapter path inside the extension directory. `Clacky::AgentRuntimeRegistry` lazily requires the adapter, resolves the declared class, and builds a runtime session only when a selected model card contains the matching `runtime_id`.

Runtime extensions are process-lifetime components in version 1. Enabling, disabling, or upgrading an `agent_runtimes` contribution requires an OpenClacky restart; Ruby classes are not hot-unloaded.

### Runtime session contract

Core provides a host-session facade that owns OpenClacky metadata, pending-input FIFO, normalized transcript, history replay, task counters, and persistence. A provider runtime remains deliberately small:

- `capabilities` describes protocol cancel, image input, and optional provider features;
- `run(input, generation:)` blocks until the provider's true turn-completion barrier;
- `cancel(reason:)` performs cooperative protocol cancellation;
- `dump_state` returns a secret-free provider resume reference;
- `close` releases provider-owned session resources.

The runtime factory receives a context containing session ID, UI sink, absolute working directory, permission mode, and optional persisted runtime state. `RuntimeInput` contains the existing content, files, reference context, display text, and timestamp fields; the provider converts it into its wire format.

The existing `Clacky::Agent` remains the default execution object and is not rewritten around ACP. For compatibility, the server continues to keep either `Clacky::Agent` or the host runtime-session facade in its existing agent slot. The facade supplies the common metadata/history/queue methods current registry code expects, while the provider SPI stays limited to turn execution. Agent-specific call sites check declared capabilities before invoking optional behavior.

## Model Configuration Contract

A saved Codex runtime card contains no secret, generated ID, or fake endpoint. Its display model is the ACP-advertised default explicitly selected by the user:

```yaml
runtime_models:
  - provider_id: codex
    type: default
    runtime_id: codex
    display_model: gpt-5.6-sol
    remark: ""
```

Runtime cards are persisted under a separate top-level `runtime_models` array in `config.yml`; API-backed cards remain under the existing `models` key. New OpenClacky versions combine both arrays in memory and generate their stable runtime IDs exactly as they do today. Older versions ignore the unknown `runtime_models` key instead of treating a credentialless card as an API model, which makes downgrade behavior safe.

`AgentConfig#models_configured?` accepts a structurally marked runtime card even when `api_key`, `base_url`, and `model` are empty. Provider/runtime validity is enforced by the registries when cards are created, tested, and used to construct or restore a session. API-backed cards keep the existing validation rules. Create and update endpoints derive `runtime_id` from the selected provider descriptor; the browser cannot register an arbitrary Ruby runtime class.

Runtime-backed cards are never passed to `Clacky::Client`. Session construction selects the runtime factory before any API client is built.

For backward compatibility, a runtime card whose provider and runtime IDs are both exactly `codex` may retain the legacy placeholders `Codex default` or `ChatGPT default` until the next successful discovery. Discovery then replaces only those recognized placeholders with the validated selected model. Stable card IDs, provider/runtime IDs, real ACP model names, and user remarks are never rewritten by that migration.

## ACP Client and Lifecycle

### Transport

The generic Ruby ACP client uses JSON-RPC 2.0 objects separated by newlines on stdio. It never uses shell parsing. Process creation uses an argv array through `Open3.popen3`, a fixed working directory, and a controlled environment.

One managed ACP connection is shared by Codex runtime sessions in an OpenClacky server process. It owns:

- monotonically increasing request IDs;
- a mutex-protected pending-request table;
- a dedicated stdout reader thread;
- serialized stdin writes;
- bounded stderr capture with secret redaction;
- notification routing by ACP `sessionId`;
- inbound client-request dispatch, initially `session/request_permission` only;
- process-exit propagation to all waiting requests and live sessions;
- restart on the next operation after an unexpected exit, without replaying an in-flight turn.

OpenClacky advertises ACP protocol version 1 and only capabilities it implements. It advertises no filesystem or terminal client methods, so the agent executes through Codex App Server rather than asking OpenClacky to act as a terminal proxy.

### Startup and authentication

On first use the Codex extension:

1. prepares the managed home;
2. resolves a pinned-compatible launcher;
3. starts the verified `codex-acp` through the OpenClacky bootstrap with `CODEX_HOME` set to the managed home, a forced random-name permission profile in `CODEX_CONFIG`, and `INITIAL_AGENT_MODE=read-only`;
4. sends `initialize` with OpenClacky client metadata;
5. checks `initialize.result.agentCapabilities._meta.authStatus`, caches the asynchronous `_auth/status_update` notification when supported, and otherwise uses the adapter's deprecated `authentication/status` extension method as a compatibility fallback;
6. exposes advertised `chat-gpt` authentication through its extension API.

The authentication HTTP API starts the long-running ACP `authenticate` request on a background thread and returns immediately. The status begins as `unknown` until a push notification or legacy fallback result arrives; `authMethods` alone never proves that the user is logged in. Browser polling reads OpenClacky's cached status and never returns an auth URL, token, refresh token, or raw adapter stderr.

### Session creation and restoration

A new runtime session sends:

```json
{
  "method": "session/new",
  "params": {
    "cwd": "/absolute/workspace",
    "mcpServers": []
  }
}
```

The returned ACP session ID is persisted under:

```yaml
runtime:
  id: codex
  version: 1
  state:
    session_id: external-acp-session-id
    model: effective-model-if-reported
    reasoning_effort: effective-effort-if-reported
```

No credentials, launch environment, or auth metadata are stored in OpenClacky session files. On restore, the extension starts or reuses its ACP connection and calls `session/resume` with the persisted ID, current absolute workspace, and an empty MCP list. Resume intentionally does not replay provider history because OpenClacky already restores its own normalized transcript. If the external session is missing or incompatible, the local transcript remains readable and the next prompt creates a replacement ACP session with an explicit warning; it does not pretend the old Codex context was restored.

### Turn configuration

After discovery, `session/new`, or `session/resume`, the extension reads `configOptions`. Discovery exposes the advertised model values and current default to the configuration UI, then closes its temporary session. A new user session applies the model saved on its ChatGPT card when that value is still advertised; a restored session reapplies its own saved effective value first so historical sessions retain their model choice. A successful `session/set_config_option` response or `config_option_update` replaces the complete cached option set, including mode, collaboration mode, model, reasoning effort, and fast mode. OpenClacky never hard-codes a catalog or assumes an unavailable value is accepted.

The extension maps OpenClacky permission modes only to modes advertised by codex-acp. `confirm_all`, `confirm_edits`, and `confirm_safes` prefer `read-only`, whose adapter label is "Ask for approval" and whose Codex sandbox is workspace-write without network. `auto_approve` prefers `agent`, whose adapter label is "Approve for me" and which can auto-review operations. Unmapped modes, including OpenClacky's `plan_only`, retain the launcher's initial `read-only` mode; version 1 does not claim a true plan-only equivalent. The extension never selects `agent-full-access` automatically. Any permission request the adapter does send remains mediated by ACP, and network or out-of-workspace access is not silently granted.

### Prompt, steering, and cancel

Text becomes an ACP text content block. OpenClacky reference context is serialized as clearly labelled text. Data-URL image attachments become ACP image blocks only when the initialized agent advertises image prompt support. Existing local files and directories become ACP `resource_link` blocks with `file:` URIs; attachments that cannot be represented fail before the prompt starts.

The initial prompt uses `session/prompt`. The original JSON-RPC response is the only turn-completion barrier; message chunks, final-looking text, and sending a cancellation do not mark the session idle. Each ACP session is single-flight, while independent sessions may run concurrently. Reader-thread events carry the host generation explicitly so late updates from a cancelled turn cannot mutate the replacement turn.

ACP v1 has no standard live-steering method. Version 1 therefore keeps OpenClacky's FIFO semantics: input received during a live Codex turn is queued and sent as a new `session/prompt` after the current prompt response. The adapter-specific `_session/steering` extension is deferred until the host can own its background-turn completion semantics safely.

`interrupt` sends the `session/cancel` notification and waits for the in-flight prompt to reach its protocol completion barrier before allowing a replacement prompt on the same ACP session. If the adapter acknowledges cancellation normally, OpenClacky retains that ACP session; if the prompt never reaches the barrier within the grace period, it restarts only the matching connection generation and discards the damaged external session. Cancellation before a prompt was sent closes the partially opened session. Any pending permission request is answered with ACP's `cancelled` outcome.

## Event and History Mapping

ACP `session/update` notifications map as follows:

| ACP update | OpenClacky behavior |
| --- | --- |
| `agent_message_chunk` | Append to a message-ID buffer and emit a keyed assistant delta; finalize one persisted assistant message at turn completion. |
| `agent_thought_chunk` | Show bounded reasoning-summary progress; do not persist private chain-of-thought as an assistant message. |
| `tool_call` | Emit a tool item keyed by `toolCallId` and retain its title, kind, input, and locations. |
| `tool_call_update` | Update the matching keyed tool item; persist compact formatted output, completion status, and command exit code so failures remain visibly failed in live UI and history replay. |
| `plan` | Map entries to the existing task/todo presentation when possible; otherwise show a non-blocking progress summary. |
| `usage_update` and prompt usage | Update token/context metadata and aggregate runtime counters. |
| `config_option_update` | Refresh the runtime session's effective model and reasoning metadata. |
| `session_info_update` | Accept an ACP title only while the OpenClacky session still has an autogenerated name; surface Codex retry metadata as a visible warning without exposing raw provider details. |
| unknown update | Ignore safely and log only update type plus adapter version. |

Existing WebSocket event types remain valid. Keyed assistant and tool fields are additive, and the frontend retains positional fallback behavior for `Clacky::Agent` events and older session history.

The runtime maintains an OpenClacky `MessageHistory` mirror for sidebar naming, history replay, search, exports, and offline readability. Codex remains authoritative for model context; the mirror is display and persistence data, not replayed back into an already-restored ACP thread.

## Permission Mapping

For `session/request_permission`, the runtime formats the tool title, kind, locations, and safe summary for OpenClacky's confirmation UI. The default choice is rejection.

Version 1 maps the boolean confirmation to ACP options without inventing an option ID:

- `Yes` selects the first advertised allow option, preferring an allow-once kind.
- `No`, dismissal, timeout, disconnect, or interrupt selects the first advertised reject option, preferring reject-once.
- If the required side has no matching advertised option, the response is `cancelled`.

Permission requests are correlated by JSON-RPC request ID and `toolCallId`, so overlapping tools cannot consume one another's answers.

## Managed Codex Home and Login Reuse

ChatCut 0.3.13 does not directly set its internal agent to the user's entire `~/.codex`. It creates a managed home, copies and rewrites configuration, links `auth.json`, and links user plugin and skill directories while keeping sessions and state databases separate.

OpenClacky uses a narrower policy. Its managed home is:

```text
macOS: ~/Library/Application Support/OpenClacky/codex
POSIX: ${XDG_DATA_HOME:-~/.local/share}/openclacky/codex
```

The directory is created with mode `0700`. Sessions, SQLite state, caches, logs, and installation metadata stay there.

The source home is the launch environment's existing `CODEX_HOME`, falling back to `~/.codex`. Before creating a lock, directory, or config file, OpenClacky resolves existing ancestors and rejects source and managed homes that are identical, nested in either direction, or aliases of the same directory. OpenClacky may create `managed/auth.json` as a symlink to `source/auth.json` only when all of these checks pass:

- platform supports safe file symlinks;
- the source path is a regular file and not itself a symlink;
- the file is owned by the current user when ownership is available;
- group and other permission bits are zero;
- the resolved source is inside the selected source Codex home;
- the managed destination does not contain an unrelated regular file.

If the checks fail or the symlink cannot be created, OpenClacky does not copy credentials. ACP uses its own browser login in the managed home. Windows defaults to independent login rather than copying a refresh token.

OpenClacky never copies or links the source `config.toml`. It accepts a config no larger than 1 MiB (reading one additional sentinel byte to detect overflow) from a same-user regular file inside a validated, non-writable source home. The file is opened with no-follow/non-blocking flags where the platform supports them, then ownership, type, permissions, identity, size, and content are checked on that same descriptor. OpenClacky reconstructs a mode-`0600` managed config from only the top-level string keys `model`, `model_reasoning_effort`, and `service_tier`; values must be simple, unescaped basic or literal strings and pass strict model-token or enum validation. Duplicate allowlisted keys, unsupported quoted/dotted root keys, multiline root statements, malformed preference assignments, or unsafe input fall back to the base config. The importer stops at the first table, so nested preferences are ignored rather than imported. Plugins, skills, rules, hooks, MCP definitions, custom providers, notifications, OTEL exporters, OAuth files, history, and databases are never imported. The managed config also selects Codex's `auto` credential store. A per-launch, unpredictable permission profile denies reads of the managed and source Codex homes, `~/.clacky`, common cloud/SSH/container credential paths, git/netrc/npm credentials, and shell startup files; login-shell initialization is disabled and sensitive environment variables are removed. This prevents unexpected code execution, recursive OpenClacky integrations, telemetry leakage, and session collisions while preserving the user's first-session model choice and allowing Codex to refresh the linked login through its own auth subsystem.

Removing a model card or stopping OpenClacky only unlinks or closes OpenClacky-owned resources. It never follows the auth symlink for recursive cleanup and never modifies the source Codex home. Because a shared auth file can still be refreshed by either Codex process, the UI labels it as a reused Codex login rather than an isolated credential.

## Launcher and Version Policy

The extension resolves launchers in this order:

1. an explicit pinned adapter entry point configured for development or enterprise packaging;
2. a packaged managed Node runtime and exact `codex-acp` entry point when present;
3. double-pinned `npx -y --package=@agentclientprotocol/codex-acp@1.11.0 --package=@openai/codex@0.153.4 -- node <bootstrap>` for the prototype when `npx` is available.

An implicitly discovered global `codex-acp` is inspected only to return an actionable diagnostic and is never executed. This prevents a matching version string or package file on `PATH` from silently becoming trusted code.

It does not run an unversioned `npx ...@latest`. The Ruby launcher always passes an argv array rather than evaluating a command string through a shell. Explicitly configured, packaged, and `npx` launch paths enter a small bootstrap that verifies the exact published adapter bundle digest, changes its session-root trust assignment from `trusted` to `untrusted`, materializes the verified result inside the mode-`0700` managed home, and resolves only Codex `0.153.4`. This disables project-local config, hooks, and exec policies even though codex-acp 1.11.0 otherwise trusts every ACP session root. `CLACKY_CODEX_PATH` is the only Codex executable override; ordinary `PATH` discovery is intentionally ignored, and the explicit override must report the exact pinned version. Although the adapter declares `@openai/codex ^0.153.4`, the launcher supplies the exact package to `npx` and rejects a drifted packaged dependency. Exact name/version checks do not prove artifact contents, so explicit overrides are an operator trust boundary and production bundles require complete attestation.

The npm fallback requires Node.js 20 or newer, needs network access on first resolution, and relies on npm's integrity-checked local cache afterward. The initial platform package is currently over 100 MB, so the prototype allows up to five minutes for a cold ACP start. This branch does not yet contain OpenClacky-managed Node or adapter artifacts. `CLACKY_CODEX_ACP_PATH` may select the exact pinned JavaScript entry point for development or controlled packaging, but it passes through the same adapter digest and Codex-version verification plus bootstrap patch; the operator remains responsible for the explicitly selected Codex artifact. Production packaging must pin, patch, and attest its managed artifacts. Missing Node/npx or an incompatible/untrusted installed pair produces an actionable status response. A production release may replace the npm fallback without changing the provider, runtime, or ACP contracts.

## Security and Failure Behavior

- The ACP child does not inherit OpenClacky's configured model API keys. `OPENAI_API_KEY` and `CODEX_API_KEY` are explicitly removed unless a future user-selected API-key auth method supplies them.
- Managed launches fail closed when the adapter bundle digest or the expected trust marker differs. Project roots are explicitly untrusted, so repository-local `.codex` MCP servers, hooks, and exec policies are disabled; an empty ACP `mcpServers` list alone is not treated as a security boundary.
- Workspaces that overlap protected credential paths are rejected before `session/new` or `session/resume`. The forced permission profile disables login shells and denies direct model reads of both linked credentials and common local secret locations.
- stdout is protocol-only. stderr is bounded, redacted, and never returned verbatim to the browser.
- Auth files, account tokens, browser-login internals, and environment values are absent from model cards, session files, logs, errors, and WebSocket events.
- Short control requests use method-specific timeouts. Side-effectful session-open requests wait for their authoritative result and are interrupted through generation-scoped process cancellation; long-running authentication and prompt requests use their own liveness/cancellation policy rather than one global short deadline. Malformed lines, unknown IDs, oversized messages, and process exits fail waiting operations without hanging the server.
- A runtime health test verifies process startup, ACP initialize compatibility, and authentication state. Model availability is validated only when a real session returns `configOptions`; the health test does not create a session or run a billable prompt.
- An authentication failure leaves existing API-key providers and sessions usable.
- An ACP crash marks only affected Codex sessions as errored. It does not terminate the OpenClacky server.
- Permission prompts default to reject and are cancelled during disconnect, interrupt, or shutdown.
- On POSIX, shutdown sends protocol cancellation/close where possible, closes stdio, and then terminates the OpenClacky-owned process group. Windows-specific child-process-tree containment still requires packaging work and platform verification before release.

## Compatibility

- Existing provider presets, API responses, model cards, and sessions have no `runtime_id` and continue through `Clacky::Client` and `Clacky::Agent` unchanged.
- A saved card is treated as runtime-backed only when its `runtime_id` matches the selected provider descriptor. This preserves older API cards whose historical `provider_id` happens to collide with a newly contributed runtime provider ID.
- Runtime-backed cards live under `runtime_models`; an older OpenClacky ignores that unknown top-level key instead of constructing `Clacky::Client` with empty API credentials.
- New provider-response fields are optional. Older frontends continue rendering provider name, model, and URL fields.
- Extension manifests without `providers` or `agent_runtimes` load unchanged.
- A client version that does not understand a saved runtime model reports it as unavailable instead of treating it as a custom empty API provider.
- Ruby implementation code remains compatible with Ruby 2.6 through Ruby 4.0 and uses no new runtime gem dependency.
- The first version is a local Web UI prototype. Terminal CLI/TUI model setup does not offer runtime providers until it has an equivalent browser-auth status experience. The current Docker image does not bundle Node, npm/npx, or codex-acp, and headless/remote browser authentication is not yet supported.

## Scope and Non-goals

Version 1 includes:

- provider and runtime extension contributions;
- a generic stdio ACP client sufficient for Codex;
- the bundled Codex extension;
- safe managed-home preparation and existing-login reuse;
- safe import of model, reasoning-effort, and service-tier preferences;
- ChatGPT browser authentication and status polling;
- session-scoped model/reasoning discovery, ACP-native model selection, read-only reasoning display, and effective-value persistence;
- new/resume/prompt/cancel session lifecycle;
- text and image input;
- local file and directory resource links;
- streamed assistant, tool, plan, usage, and permission mapping;
- local transcript persistence and restore;
- onboarding and Settings integration;
- ChatGPT user-facing naming and automatic primary visual-understanding display;
- unit, contract, server, frontend-architecture, and fake-ACP integration specs.

Version 1 does not include:

- copying ChatCut's Codex policy wrappers or unsafe permission defaults;
- direct implementation of the Codex App Server wire protocol;
- full reuse of the user's Codex home, plugins, skills, MCP servers, hooks, rules, or session database;
- API-key or custom-gateway Codex auth in the UI;
- automatic media sidecars for image generation, video generation, audio generation, speech transcription, or video understanding;
- a hard-coded Codex model catalog (configuration-time choices always come from ACP discovery);
- adapter-specific live steering;
- automatic logout of a shared Codex credential;
- bundling or publishing production platform binaries;
- ACP filesystem, terminal, elicitation, native subagent-session, background-task, or goal extensions;
- Time Machine, OpenClacky idle compression, OpenClacky static sub-model overlays, or channel/cron execution for Codex sessions.

## Acceptance Scenarios

1. On a fresh OpenClacky install, the provider picker includes ChatGPT beside existing providers; selecting it removes the base URL and API-key requirements.
2. With a valid and securely permissioned file-backed `~/.codex/auth.json`, opening ChatGPT setup or a configured Settings card starts ACP and shows connected through a managed-home symlink without reading or copying token contents.
3. With no reusable login, `Connect with ChatGPT` opens browser authentication through ACP, status polling completes, and the model selector is populated without creating a user-visible conversation.
4. A source Codex home containing MCP commands, plugins, hooks, custom providers, notifications, or telemetry configuration exposes only valid top-level `model`, `model_reasoning_effort`, and `service_tier` preferences to OpenClacky's reconstructed managed config; repository-local `.codex` config, hooks, and exec policies remain disabled by the verified adapter patch.
5. Creating a ChatGPT model card requires choosing one ACP-advertised model, preselects the validated source preference when available, and persists that choice as the card's display model without credentials or a static `ChatGPT default` label.
6. Before any user prompt, a configured ChatGPT card shows connected and exposes the discovered model list; its temporary discovery session has been closed and does not appear in the OpenClacky sidebar.
7. Sending the first prompt establishes a Codex ACP session, applies the card's selected default, accepts the adapter's effective values, streams one assistant message, displays keyed tool progress, and persists the session model, reasoning effort, and ACP session ID without credentials. The session model picker can switch only that session without changing the card default.
8. A permission request defaults to rejection, maps Yes/No to an option actually advertised by the agent, and is cancelled safely on interrupt.
9. Interrupt sends ACP `session/cancel`, returns the OpenClacky session to idle, preserves completed output, and does not leave a blocked permission waiter.
10. Restarting OpenClacky resumes the saved ACP session ID without replaying duplicate provider history and retains the local transcript. A missing external ACP session produces a warning and a fresh external session on the next prompt.
11. Existing API-key model create, edit, test, default selection, session restore, steering, and deletion specs continue to pass unchanged.
12. Missing or incompatible codex-acp/Node dependencies produce an actionable provider status while the rest of OpenClacky remains operational.
13. Logs, API responses, session JSON, HTTP payloads, and WebSocket payloads contain no auth token, refresh token, API key, or raw auth file content.
14. The complete RSpec suite passes on the feature branch, and all new Ruby files parse under Ruby 2.6-compatible syntax.
15. With ChatGPT selected as the default runtime, Settings shows Visual Understanding as automatically supplied by the selected primary model while leaving the other five media rows unchanged.

## Assumptions

- ACP protocol version 1 remains supported by `@agentclientprotocol/codex-acp` 1.11.0.
- `codex-acp` 1.11.0 continues to use stdio newline-delimited JSON and declares a compatible `@openai/codex` dependency range; OpenClacky independently supplies and verifies exact version 0.153.4.
- ACP session configuration continues to advertise model and reasoning choices rather than requiring OpenClacky to hard-code the complete Codex model catalog.
- Browser authentication is available on the local machine running OpenClacky. Headless and remote login flows can be added through ACP device-code elicitation later.
- Production distribution will decide whether to bundle standalone adapter binaries or require a managed Node runtime before this branch is released.
