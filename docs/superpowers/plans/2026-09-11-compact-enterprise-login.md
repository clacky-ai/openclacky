# Compact Enterprise Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use box:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the enterprise login entry in first-run setup to one low-emphasis footer link while preserving personal onboarding and the complete enterprise device-login capability.

**Architecture:** Keep the existing enterprise authorization state machine and server APIs unchanged. Replace only the onboarding choice presentation and its show/hide state transitions, then validate the complete client feature set with focused and full RSpec runs before publishing the branch to the official repository as a pull request.

**Tech Stack:** Static HTML, CSS, browser JavaScript, Ruby 2.6-compatible client runtime, RSpec, GitHub CLI.

---

### Task 1: Specify the compact entry in WebUI tests

**Files:**
- Modify: `spec/clacky/web/enterprise_device_login_ui_spec.rb`

- [ ] **Step 1: Replace the card expectation with footer-link expectations**

Update the first example so it requires a link-styled button after the manual configuration section and rejects the old enterprise card:

```ruby
it "renders enterprise login as a compact footer link with a staged platform URL form" do
  expect(index).to include('id="setup-btn-enterprise-login"')
  expect(index).to include('class="setup-enterprise-link"')
  expect(index).not_to include('id="setup-enterprise-card"')
  expect(index.index('id="setup-btn-enterprise-login"')).to be >
    index.index('id="setup-manual-section"')
  expect(index).to include('id="setup-enterprise-form"')
  expect(index).to include('id="setup-enterprise-source"')
  expect(index).to include('value="https://www.openclacky.com"')
  expect(index).to include('id="setup-enterprise-cancel"')
  expect(i18n).to include('"onboard.enterprise.btn":             "Enterprise user? Sign in →"')
  expect(i18n).to include('"onboard.enterprise.source.label":')
end
```

- [ ] **Step 2: Update the branded-mode expectation**

Replace the enterprise-card assertion with:

```ruby
expect(setup_step).to include('$("setup-btn-enterprise-login").style.display')
```

- [ ] **Step 3: Run the focused spec and confirm the intended failure**

Run:

```bash
mise exec ruby@3.4.9 -- bundle exec rspec spec/clacky/web/enterprise_device_login_ui_spec.rb
```

Expected: FAIL because the old full enterprise card is still rendered and the compact link class/order do not exist.

### Task 2: Replace the enterprise card with a footer link

**Files:**
- Modify: `lib/clacky/web/index.html`
- Modify: `lib/clacky/web/app.css`
- Modify: `lib/clacky/web/i18n.js`

- [ ] **Step 1: Remove the full enterprise card**

Delete the `setup-enterprise-card` block, but keep `setup-enterprise-form` as the hidden form used after the user chooses enterprise login.

- [ ] **Step 2: Add the compact link after manual configuration**

After the closing `setup-manual-section` element, add:

```html
<button id="setup-btn-enterprise-login" type="button" class="setup-enterprise-link">
  <span data-i18n="onboard.enterprise.btn">Enterprise user? Sign in →</span>
</button>
```

- [ ] **Step 3: Replace card CSS with low-emphasis link CSS**

Remove `.setup-enterprise-card`, `.setup-enterprise-login-btn`, and its hover rule. Add:

```css
.setup-enterprise-link {
  display: block;
  width: 100%;
  margin-top: 0.375rem;
  padding: 0.5rem;
  border: 0;
  background: transparent;
  color: var(--color-text-tertiary);
  font-size: 0.75rem;
  text-align: center;
  cursor: pointer;
}
.setup-enterprise-link:hover {
  color: var(--color-accent-primary);
}
.setup-enterprise-form {
  margin-top: 0.625rem;
}
```

- [ ] **Step 4: Tighten the localized link copy**

Keep the enterprise form and success keys, remove the unused enterprise title/lead keys, and set:

```javascript
"onboard.enterprise.btn":             "Enterprise user? Sign in →",
```

```javascript
"onboard.enterprise.btn":             "企业用户？登录企业账号 →",
```

### Task 3: Preserve correct onboarding state transitions

**Files:**
- Modify: `lib/clacky/web/components/onboard.js`
- Test: `spec/clacky/web/enterprise_device_login_ui_spec.rb`

- [ ] **Step 1: Show the compact link in the initial key step**

In `_showSetupStep`, initialize the enterprise elements as follows while preserving the existing personal and branded behavior:

```javascript
$("setup-device-block").style.display = "";
$("setup-device-card").style.display = _branded ? "none" : "";
$("setup-btn-enterprise-login").style.display = "";
$("setup-enterprise-form").style.display = "none";
$("setup-device-pending").style.display = "none";
$("setup-device-success").style.display = "none";
$("setup-manual-toggle").style.display = "";
$("setup-manual-section").style.display = "none";
```

- [ ] **Step 2: Collapse personal choices when enterprise login opens**

Use the existing enterprise button handler to hide the personal card, manual controls, and footer link before showing and focusing the enterprise form:

```javascript
if (enterpriseBtn) enterpriseBtn.addEventListener("click", () => {
  $("setup-device-card").style.display = "none";
  $("setup-manual-toggle").style.display = "none";
  $("setup-manual-section").style.display = "none";
  $("setup-btn-enterprise-login").style.display = "none";
  $("setup-enterprise-form").style.display = "";
  $("setup-enterprise-source").focus();
});
```

- [ ] **Step 3: Restore the compact choice layout after cancel or failure**

Update `_restoreDeviceChoices` to restore the personal card only when unbranded, collapse the manual form, and show the footer link:

```javascript
function _restoreDeviceChoices() {
  $("setup-device-pending").style.display = "none";
  $("setup-device-success").style.display = "none";
  $("setup-enterprise-form").style.display = "none";
  $("setup-device-card").style.display = _branded ? "none" : "";
  $("setup-manual-toggle").style.display = "";
  $("setup-manual-section").style.display = "none";
  $("setup-btn-enterprise-login").style.display = "";
}
```

- [ ] **Step 4: Hide all choices during pending and success states**

In `_showDevicePending` and `_showDeviceSuccess`, hide `setup-btn-enterprise-login`, `setup-manual-toggle`, and `setup-manual-section`. Do not change the request payload, polling loop, validated persistence sequence, or enterprise-specific success copy.

- [ ] **Step 5: Run the focused WebUI spec**

Run:

```bash
mise exec ruby@3.4.9 -- bundle exec rspec spec/clacky/web/enterprise_device_login_ui_spec.rb
```

Expected: all examples pass, including the selector regression check.

### Task 4: Verify the complete enterprise client behavior

**Files:**
- Test: `spec/clacky/web/enterprise_device_login_ui_spec.rb`
- Test: `spec/clacky/server/http_server_enterprise_device_login_spec.rb`
- Test: `spec/clacky/server/http_server_enterprise_license_spec.rb`
- Test: `spec/clacky/server/http_server_spec.rb`
- Test: `spec/clacky/web/platform_source_ui_spec.rb`
- Test: `spec/clacky/platform_http_client_host_spec.rb`

- [ ] **Step 1: Run all enterprise-focused specs**

Run:

```bash
mise exec ruby@3.4.9 -- bundle exec rspec \
  spec/clacky/web/enterprise_device_login_ui_spec.rb \
  spec/clacky/server/http_server_enterprise_device_login_spec.rb \
  spec/clacky/server/http_server_enterprise_license_spec.rb \
  spec/clacky/web/platform_source_ui_spec.rb \
  spec/clacky/platform_http_client_host_spec.rb \
  spec/clacky/server/http_server_spec.rb
```

Expected: all examples pass, including dynamic enterprise model switching and rejection of models outside the enterprise allowlist.

- [ ] **Step 2: Run the full client test suite**

Run:

```bash
mise exec ruby@3.4.9 -- bundle exec rspec
```

Expected: all tests pass. If the known terminal background-output timing example fails, rerun it in isolation and report it separately rather than treating it as an enterprise-login regression.

- [ ] **Step 3: Check diff integrity and Ruby compatibility-sensitive syntax**

Run:

```bash
git diff --check
rg -n "filter_map|\.then|def .* =|[a-z_]+:" lib/clacky/agent.rb lib/clacky/identity.rb lib/clacky/platform_http_client.rb lib/clacky/server/http_server.rb lib/clacky/server/session_registry.rb
```

Expected: `git diff --check` is silent; manually confirm every changed runtime construct remains Ruby 2.6 compatible.

### Task 5: Re-run the first-user browser flow

**Files:**
- Runtime state: `/Users/seng/.clacky`
- Recovery backup: `/Users/seng/.Trash/clacky-before-new-user-test-20260910`

- [ ] **Step 1: Stop the local client**

Resolve and terminate only the processes listening on `127.0.0.1:7070`, then verify the port is closed.

- [ ] **Step 2: Clear the current test profile recoverably**

Move the current `/Users/seng/.clacky` directory to an unused, explicitly named folder in `/Users/seng/.Trash`. Do not touch the existing `clacky-before-new-user-test-20260910` backup.

- [ ] **Step 3: Start the local development client**

Run:

```bash
mise exec ruby@3.4.9 -- bundle exec ruby bin/openclacky server --host 127.0.0.1 --port 7070
```

Expected: `http://127.0.0.1:7070` responds and `/api/onboard/status` reports `key_setup`.

- [ ] **Step 4: Inspect the fresh onboarding UI**

Open `http://127.0.0.1:7070/#new`, choose Chinese, and confirm the personal AI Keys card is primary while enterprise login appears only as the footer link. Open and cancel the enterprise form once, then verify the personal layout returns without a saved platform source.

### Task 6: Commit and submit the official pull request

**Files:**
- Review all changed files under `lib/clacky/`, `spec/clacky/`, and the two approved design/plan documents.

- [ ] **Step 1: Audit the branch diff**

Run:

```bash
git status --short
git diff --stat upstream/main...HEAD
git diff --stat
git diff --check
```

Exclude unrelated generated files or dependency-lock changes that are not required by the enterprise client feature.

- [ ] **Step 2: Commit the tested implementation**

Stage only the enterprise client implementation and its tests, then commit:

```bash
git commit -m "feat: add enterprise device login"
```

- [ ] **Step 3: Push the feature branch to the fork**

Run:

```bash
git push -u origin feat/enterprise-device-login
```

Expected: the branch is available as `RLBox:feat/enterprise-device-login`.

- [ ] **Step 4: Create the upstream pull request**

Run:

```bash
gh pr create \
  --repo clacky-ai/openclacky \
  --base main \
  --head RLBox:feat/enterprise-device-login \
  --title "feat: add enterprise device login" \
  --body-file /tmp/openclacky-enterprise-device-login-pr.md
```

The PR body must summarize the compact personal-first entry, staged enterprise platform source, enterprise license display, Gateway-managed model catalog, security boundaries, test evidence, and the upstream `openclacky.com` single-model device-grant limitation.

- [ ] **Step 5: Verify the published PR**

Run:

```bash
gh pr view --repo clacky-ai/openclacky --json number,title,url,state,headRefName,baseRefName
```

Expected: an open PR from `RLBox:feat/enterprise-device-login` into `main` with the requested title.
