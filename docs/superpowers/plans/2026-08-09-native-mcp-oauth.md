# Native Remote MCP OAuth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use box:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add provider-neutral OAuth 2.1 support for remote MCP servers to OpenClacky, including secure credentials, CLI lifecycle commands, automatic refresh, and transport integration.

**Architecture:** OAuth metadata/session logic is isolated from MCP JSON-RPC transport. A credential store persists per-server grants outside `mcp.json`; an authorization manager discovers metadata, performs DCR and PKCE, and supplies valid bearer tokens. HTTP transport accepts an authorization provider and retries exactly once after an authenticated 401.

**Tech Stack:** Ruby 2.6+, Thor, Net::HTTP, WEBrick, JSON, RSpec.

---

### Task 1: OAuth configuration and capability contract

**Files:**
- Create: `lib/clacky/mcp/oauth/config.rb`
- Create: `spec/clacky/mcp/oauth/config_spec.rb`
- Modify: `lib/clacky/mcp/client.rb`
- Modify: `lib/clacky/mcp/skill_provider.rb`
- Modify: `lib/clacky/mcp/registry.rb`

- [ ] **Step 1: Write failing configuration specs**

Cover `auth: {type: oauth}`, explicit resource parsing, default resource equal to MCP URL, rejection of OAuth on non-HTTPS resources, and preservation of static-header servers.

- [ ] **Step 2: Verify RED**

Run: `bundle exec rspec spec/clacky/mcp/oauth/config_spec.rb`
Expected: FAIL because `Clacky::Mcp::OAuth::Config` is undefined.

- [ ] **Step 3: Implement minimal configuration parsing**

Add a value object with `enabled?`, `resource`, and validation. Pass parsed OAuth configuration from registry specs into HTTP client construction without provider-specific constants.

- [ ] **Step 4: Verify GREEN**

Run: `bundle exec rspec spec/clacky/mcp/oauth/config_spec.rb spec/clacky/mcp/skill_provider_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add lib spec && git commit -m "feat(mcp): define remote oauth configuration"`

### Task 2: Secure OAuth credential store

**Files:**
- Create: `lib/clacky/mcp/oauth/credential_store.rb`
- Create: `spec/clacky/mcp/oauth/credential_store_spec.rb`

- [ ] **Step 1: Write failing credential specs**

Cover deterministic per-server lookup, mode-0600 writes, atomic replacement, refresh-token rotation, deletion, malformed-file recovery, and absence of token values from `inspect`.

- [ ] **Step 2: Verify RED**

Run: `bundle exec rspec spec/clacky/mcp/oauth/credential_store_spec.rb`
Expected: FAIL because the store is undefined.

- [ ] **Step 3: Implement the file-backed store**

Persist JSON below `~/.clacky/mcp/oauth/`, sanitize server names for paths, serialize writes with a lock file, write to a same-directory temporary file, chmod 0600, fsync, and rename atomically.

- [ ] **Step 4: Verify GREEN**

Run: `bundle exec rspec spec/clacky/mcp/oauth/credential_store_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add lib spec && git commit -m "feat(mcp): store oauth credentials securely"`

### Task 3: Metadata discovery, DCR, and PKCE authorization

**Files:**
- Create: `lib/clacky/mcp/oauth/http_client.rb`
- Create: `lib/clacky/mcp/oauth/authorization_manager.rb`
- Create: `spec/clacky/mcp/oauth/authorization_manager_spec.rb`
- Create: `spec/support/oauth_mcp_server.rb`

- [ ] **Step 1: Write failing authorization specs**

Use a local HTTPS-capable fixture abstraction to test challenge parsing, RFC 9728 protected-resource discovery, RFC 8414 authorization-server discovery, DCR request fields, S256 PKCE, loopback-only callbacks, state verification, code exchange, denied consent, bounded responses, and redacted errors.

- [ ] **Step 2: Verify RED**

Run: `bundle exec rspec spec/clacky/mcp/oauth/authorization_manager_spec.rb`
Expected: FAIL because the manager is undefined.

- [ ] **Step 3: Implement authorization manager**

Generate a random loopback port and state, register `application_type: native`, open the system browser, capture the callback, exchange the code, persist expiry and refresh credentials, and validate all remote endpoints as HTTPS.

- [ ] **Step 4: Verify GREEN**

Run: `bundle exec rspec spec/clacky/mcp/oauth/authorization_manager_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add lib spec && git commit -m "feat(mcp): authorize remote servers with pkce"`

### Task 4: Token refresh session

**Files:**
- Create: `lib/clacky/mcp/oauth/session.rb`
- Create: `spec/clacky/mcp/oauth/session_spec.rb`

- [ ] **Step 1: Write failing session specs**

Cover valid-token reuse, refresh within a one-minute expiry skew, refresh-token rotation, concurrent refresh serialization, invalid-grant cleanup, missing-login errors, one forced refresh, and secret-redacted exceptions.

- [ ] **Step 2: Verify RED**

Run: `bundle exec rspec spec/clacky/mcp/oauth/session_spec.rb`
Expected: FAIL because `Session` is undefined.

- [ ] **Step 3: Implement the session**

Expose `authorization_headers` and `invalidate!`; refresh through the token endpoint when needed and persist only successful responses.

- [ ] **Step 4: Verify GREEN**

Run: `bundle exec rspec spec/clacky/mcp/oauth/session_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add lib spec && git commit -m "feat(mcp): refresh oauth sessions automatically"`

### Task 5: HTTP transport authentication integration

**Files:**
- Modify: `lib/clacky/mcp/http_transport.rb`
- Modify: `lib/clacky/mcp/client.rb`
- Modify: `spec/clacky/mcp/http_transport_spec.rb`

- [ ] **Step 1: Write failing transport specs**

Cover bearer injection without mutating static headers, proactive refresh use, exactly one invalidate-and-retry on 401, no retry for non-authenticated servers, no retry after the second 401, and redacted transport errors.

- [ ] **Step 2: Verify RED**

Run: `bundle exec rspec spec/clacky/mcp/http_transport_spec.rb`
Expected: FAIL because transport has no authorization provider.

- [ ] **Step 3: Integrate OAuth session**

Accept an optional authorization provider, merge its headers per request, capture the 401 challenge, invalidate once, retry the same body once, and preserve MCP session headers and existing static-header behavior.

- [ ] **Step 4: Verify GREEN**

Run: `bundle exec rspec spec/clacky/mcp/http_transport_spec.rb spec/clacky/mcp/skill_provider_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add lib spec && git commit -m "feat(mcp): authenticate remote http transports"`

### Task 6: MCP OAuth CLI

**Files:**
- Create: `lib/clacky/mcp/cli_commands.rb`
- Create: `spec/clacky/mcp/cli_commands_spec.rb`
- Modify: `lib/clacky/cli.rb`
- Modify: `lib/clacky.rb`

- [ ] **Step 1: Write failing CLI specs**

Cover `mcp capabilities --json`, `mcp login SERVER`, `mcp status SERVER --json`, `mcp logout SERVER`, unknown servers, non-OAuth servers, and output that contains status metadata but no tokens.

- [ ] **Step 2: Verify RED**

Run: `bundle exec rspec spec/clacky/mcp/cli_commands_spec.rb`
Expected: FAIL because `Clacky::Mcp::CliCommands` is undefined.

- [ ] **Step 3: Implement and register the Thor subcommand**

Expose `remote_oauth: true` as a capability, authorize configured servers, report connected/expired/disconnected states, and delete credentials on logout.

- [ ] **Step 4: Verify GREEN**

Run: `bundle exec rspec spec/clacky/mcp/cli_commands_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add lib spec && git commit -m "feat(mcp): add oauth lifecycle commands"`

### Task 7: Documentation and complete verification

**Files:**
- Modify: `docs/mcp-architecture.md`
- Modify: `docs/mcp.example.json`
- Modify: `README.md`
- Modify: `README_CN.md`
- Create: `spec/clacky/mcp/oauth/integration_spec.rb`

- [ ] **Step 1: Write the end-to-end integration spec**

Exercise login callback, credential persistence, MCP initialize/tools list/tool call, expiry refresh, 401 retry, status, and logout against the local fixture.

- [ ] **Step 2: Verify the integration RED then GREEN**

Run before final wiring: `bundle exec rspec spec/clacky/mcp/oauth/integration_spec.rb`; confirm the expected missing wiring failure. Complete wiring and rerun for PASS.

- [ ] **Step 3: Document configuration and security behavior**

Add a generic OAuth MCP example, CLI instructions, credential location, HTTPS and loopback rules, and automatic refresh behavior in English and Chinese user-facing documentation.

- [ ] **Step 4: Run full verification**

Run: `bundle exec rspec`, `bundle exec rubocop`, and `bundle exec rake build`.
Expected: zero test failures, zero lint errors, and a successfully built gem.

- [ ] **Step 5: Commit**

Run: `git add docs README.md README_CN.md spec lib && git commit -m "docs(mcp): document remote oauth connections"`

### Task 8: Upstream PR preparation

**Files:**
- Inspect: all files changed from `upstream/main`

- [ ] **Step 1: Perform structured self-review**

Run: `git diff upstream/main...HEAD`, inspect every changed file for provider-specific code, token leakage, compatibility regressions, unsupported Ruby syntax, debug output, and missing tests.

- [ ] **Step 2: Run clean-room verification**

Run the full test, lint, build, and gem-content checks from a clean checkout of the branch.

- [ ] **Step 3: Push the feature branch**

Run: `git push -u origin feature/mcp-oauth`.

- [ ] **Step 4: Create the upstream PR**

Run `gh pr create --repo clacky-ai/openclacky --base main --head RLBox:feature/mcp-oauth` with a summary of protocol support, security boundaries, tests, and ChatCut as an external validation case.

- [ ] **Step 5: Inspect PR state**

Run: `gh pr view --repo clacky-ai/openclacky --json url,state,headRefName,baseRefName,statusCheckRollup`.
Expected: an OPEN PR targeting `main` from `feature/mcp-oauth`, with the URL recorded for handoff.
