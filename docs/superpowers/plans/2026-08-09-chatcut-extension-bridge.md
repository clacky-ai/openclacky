# ChatCut Extension Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use box:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone ChatCut extension that works on existing OpenClacky clients through an OAuth-aware stdio bridge and automatically switches to native OAuth when available.

**Architecture:** A setup command owns conflict-safe MCP configuration, capability detection, and cleanup. A focused Ruby bridge composes OAuth discovery/session classes with an MCP HTTP forwarder while keeping stdout protocol-only. Extension skills call the setup command and delegate all video work to `mcp:chatcut` and ChatCut's remote playbooks.

**Tech Stack:** Ruby 2.6+, Net::HTTP, WEBrick, JSON, minitest, OpenClacky `ext.yml` and MCP configuration.

---

### Task 1: Standalone extension skeleton

**Files:**
- Create: `openclacky-chatcut/ext.yml`
- Create: `openclacky-chatcut/README.md`
- Create: `openclacky-chatcut/LICENSE`
- Create: `openclacky-chatcut/Rakefile`
- Create: `openclacky-chatcut/test/test_helper.rb`

- [ ] **Step 1: Write a manifest validation test**

Create a minitest that loads `ext.yml`, asserts `id == "chatcut"`, and asserts the three skill directories exist.

- [ ] **Step 2: Run the test to verify RED**

Run: `ruby -Itest test/manifest_test.rb`
Expected: FAIL because `ext.yml` does not exist.

- [ ] **Step 3: Add the minimal extension skeleton**

Declare `chatcut-setup`, `chatcut`, and `chatcut-disconnect` under `contributes.skills`, add MIT project metadata for original adapter code, and add a Rake test task.

- [ ] **Step 4: Run the test to verify GREEN**

Run: `ruby -Itest test/manifest_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add . && git commit -m "chore: scaffold chatcut extension"`

### Task 2: Conflict-safe MCP configuration

**Files:**
- Create: `openclacky-chatcut/lib/chatcut_extension/configurator.rb`
- Create: `openclacky-chatcut/bin/chatcut-extension`
- Create: `openclacky-chatcut/test/configurator_test.rb`

- [ ] **Step 1: Write failing configuration tests**

Cover merging a bridge entry while preserving another server, selecting native mode from `{"remote_oauth":true}`, falling back when the command is absent, refusing to replace an unowned conflicting `chatcut` entry, and disconnecting only an owned entry.

- [ ] **Step 2: Verify RED**

Run: `ruby -Itest test/configurator_test.rb`
Expected: FAIL because `ChatcutExtension::Configurator` is undefined.

- [ ] **Step 3: Implement the configurator and executable**

Implement `setup`, `status`, and `disconnect`. Probe `clacky mcp capabilities --json`; native mode writes `type`, `url`, and `auth`, while fallback writes `command` and absolute bridge path. Save a SHA-256 fingerprint of the managed entry under the extension data directory and chmod configuration/state files to 0600.

- [ ] **Step 4: Verify GREEN**

Run: `ruby -Itest test/configurator_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add bin lib test && git commit -m "feat: configure chatcut mcp with native fallback"`

### Task 3: OAuth discovery and credential storage

**Files:**
- Create: `openclacky-chatcut/lib/chatcut_bridge/credential_store.rb`
- Create: `openclacky-chatcut/lib/chatcut_bridge/oauth_client.rb`
- Create: `openclacky-chatcut/test/credential_store_test.rb`
- Create: `openclacky-chatcut/test/oauth_client_test.rb`

- [ ] **Step 1: Write failing OAuth unit tests**

Test mode-0600 atomic persistence, protected-resource and authorization-server discovery, PKCE S256 calculation, state mismatch rejection, successful code exchange, refresh-token rotation, and redacted HTTP errors using a local WEBrick server.

- [ ] **Step 2: Verify RED**

Run: `ruby -Itest test/credential_store_test.rb test/oauth_client_test.rb`
Expected: FAIL because the bridge classes are undefined.

- [ ] **Step 3: Implement minimal OAuth classes**

Use `SecureRandom.urlsafe_base64`, SHA-256 PKCE, loopback callbacks on `127.0.0.1`, `Net::HTTP`, bounded JSON reads, endpoint HTTPS validation, and atomic JSON writes. Return an authorization header without logging credential values.

- [ ] **Step 4: Verify GREEN**

Run: `ruby -Itest test/credential_store_test.rb test/oauth_client_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add lib test && git commit -m "feat: add chatcut bridge oauth session"`

### Task 4: MCP stdio-to-HTTP bridge

**Files:**
- Create: `openclacky-chatcut/lib/chatcut_bridge/http_forwarder.rb`
- Create: `openclacky-chatcut/lib/chatcut_bridge/server.rb`
- Create: `openclacky-chatcut/bridge/chatcut_mcp_bridge.rb`
- Create: `openclacky-chatcut/test/http_forwarder_test.rb`
- Create: `openclacky-chatcut/test/server_test.rb`

- [ ] **Step 1: Write failing bridge tests**

Test JSON-RPC line forwarding, SSE `data:` extraction, session-id propagation, bearer injection, proactive refresh, a single refresh-and-retry on 401, notification handling, protocol-only stdout, and redacted diagnostics.

- [ ] **Step 2: Verify RED**

Run: `ruby -Itest test/http_forwarder_test.rb test/server_test.rb`
Expected: FAIL because forwarder and server classes are undefined.

- [ ] **Step 3: Implement the bridge**

Read one JSON-RPC object per stdin line, POST it to ChatCut, emit response objects as compact JSON lines, send diagnostics only to stderr, preserve `Mcp-Session-Id`, and use the OAuth client for authorization.

- [ ] **Step 4: Verify GREEN**

Run: `ruby -Itest test/http_forwarder_test.rb test/server_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add bridge lib test && git commit -m "feat: bridge chatcut remote mcp over stdio"`

### Task 5: Skills, packaging, and local installation

**Files:**
- Create: `openclacky-chatcut/skills/chatcut-setup/SKILL.md`
- Create: `openclacky-chatcut/skills/chatcut/SKILL.md`
- Create: `openclacky-chatcut/skills/chatcut-disconnect/SKILL.md`
- Create: `openclacky-chatcut/test/skills_test.rb`

- [ ] **Step 1: Write failing skill contract tests**

Assert setup runs the extension executable, chatcut invokes `mcp:chatcut` and instructs the subagent to use `list_skills`/`load_skill`, and disconnect runs conflict-safe cleanup.

- [ ] **Step 2: Verify RED**

Run: `ruby -Itest test/skills_test.rb`
Expected: FAIL because the skills do not exist.

- [ ] **Step 3: Write the three skills and local install instructions**

Keep host-specific instructions in setup/disconnect and all editing knowledge remote. Document the local symlink into `~/.clacky/ext/local/chatcut` and the requirement to start a new session after first registration.

- [ ] **Step 4: Verify GREEN and package**

Run: `bundle exec rake test` and `bundle exec ruby bin/clacky ext verify` from the OpenClacky worktree with the symlink installed.
Expected: all extension tests pass and verifier reports no ChatCut errors.

- [ ] **Step 5: Commit**

Run: `git add skills test README.md && git commit -m "feat: add chatcut setup and editing skills"`

### Task 6: End-to-end fallback and native-mode verification

**Files:**
- Create: `openclacky-chatcut/test/integration/setup_modes_test.rb`
- Create: `openclacky-chatcut/test/integration/bridge_mcp_test.rb`

- [ ] **Step 1: Write integration tests**

Run setup against fake old/new `clacky` executables, launch the bridge against a local OAuth/MCP fixture, complete the callback programmatically, call `initialize`, `tools/list`, and `tools/call`, expire the token, and verify refresh.

- [ ] **Step 2: Run and fix only implementation defects**

Run: `bundle exec rake test`
Expected: all tests pass with no token values in captured stdout/stderr.

- [ ] **Step 3: Create the authorized local symlink**

Run: `ln -sfn /Users/seng/Documents/GitHub/clacky/openclacky-chatcut ~/.clacky/ext/local/chatcut`
Expected: the symlink resolves to the standalone repository.

- [ ] **Step 4: Verify with local OpenClacky**

Run: `bundle exec ruby bin/clacky ext verify` and inspect `bundle exec ruby bin/clacky ext list`.
Expected: ChatCut and all three skills are resolved without errors.

- [ ] **Step 5: Commit**

Run: `git add test && git commit -m "test: verify chatcut bridge fallback modes"`
