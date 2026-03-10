---
name: im-bridge
description: |
  Connect open-clacky to IM platforms (Feishu/Lark, WeCom).
  Trigger on: "im setup", "im start", "im stop", "im status", "im logs", "im doctor",
  "start bridge", "stop bridge", "bridge status", "setup feishu", "setup wecom".
  Subcommands: setup, start, stop, status, logs [N], reconfigure, doctor.
argument-hint: "setup | start | stop | status | logs [N] | reconfigure | doctor"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
  - Glob
---

# IM Bridge Skill

You are managing the open-clacky IM bridge.

User config is stored at `~/.clacky/im-bridge/config.env`.
Logs are at `~/.clacky/im-bridge/logs/bridge.log`.

First, locate the skill directory:
- Use Glob with pattern `**/default_skills/im-bridge/SKILL.md` to find its path
- Derive SKILL_DIR from the result (parent of SKILL.md)
- Store SKILL_DIR mentally for all subsequent file references

## Command Parsing

Map user intent to subcommand:

| User says | Subcommand |
|---|---|
| `setup`, `configure`, `setup feishu`, `setup wecom` | setup |
| `start`, `start bridge` | start |
| `stop`, `stop bridge` | stop |
| `status`, `bridge status` | status |
| `logs`, `logs 200` | logs |
| `reconfigure`, `reconfig`, `modify config` | reconfigure |
| `doctor`, `diagnose` | doctor |

Extract optional numeric argument for `logs` (default 50).

## Config Check

Before any subcommand except `setup` and `doctor`, check if `~/.clacky/im-bridge/config.env` exists.

If it does NOT exist:
- Tell the user "No configuration found" and automatically start the `setup` wizard.

## Subcommands

### `setup`

Run an interactive setup wizard using AskUserQuestion. Collect **one field at a time**. After each answer, confirm the value back to the user before moving on.

**Step 1 — Choose platform**

Ask:
> **Which IM platform would you like to connect?**
>
> 1. Feishu / Lark — supported
> 2. WeCom (Enterprise WeChat) — supported
>
> Enter a number:

If user selects 3, inform them it's not yet supported and ask if they want to proceed with 1 or 2.

---

### Platform: Feishu (option 1)

**Step 2 — Collect Feishu credentials (one at a time)**

2a. **App ID**

Ask with this exact context inline:

> **How to get your App ID:**
> 1. Open https://open.feishu.cn/app (Lark international: https://open.larksuite.com/app)
> 2. If you have an existing app, click its name to enter; otherwise click **"Create Enterprise Self-Built App"** on the left, fill in the app name (e.g. "AI Assistant") and confirm
> 3. Inside the app, click **"Credentials & Basic Info"** in the left menu
> 4. Copy the **App ID** (format: `cli_xxxxxxxxxx`)
>
> Enter your **App ID** (format: `cli_xxxxxxxxxx`):

Confirm the entered value back. If format doesn't match `cli_`, warn the user but allow proceeding.

2b. **App Secret**

Ask with this context inline:

> **How to get your App Secret:**
> On the same page (Credentials & Basic Info), click the eye icon next to **App Secret** to reveal it, then copy.
>
> Enter your **App Secret** (32-character string):

Confirm back (masked, show only last 4 chars).

2c. **Complete Feishu app configuration**

After collecting App ID and App Secret, tell the user their app still needs to be configured before the bridge can work. Ask them to complete the following steps, and tell them to reply "done" when finished:

> Your Feishu app still needs a few more steps before the bridge can receive messages. Please complete the following, then reply "done" to continue:
>
> **Step A — Enable Bot capability**
> 1. Click **"Add App Capabilities"** in the left menu
> 2. Find the **"Bot"** card and click **"+ Add"**
>
> **Step B — Add permissions**
> 1. Click **"Permission Management"** in the left menu
> 2. Click **"Enable Permissions"**, select **"Messages & Groups"** on the left
> 3. Search and enable: `im:message`, `im:message:send_as_bot`, `im:message.p2p_msg:readonly`
> 4. Click **"Confirm"**
>
> **Step C — Configure event subscription (long connection)**
> 1. Click **"Events & Callbacks"** in the left menu
> 2. Under "Event Configuration", click the pencil icon next to **"Subscription Method"** → select **"Long Connection"** → save
> 3. Click **"Add Event"**, search and add `im.message.receive_v1`
> 4. Save
>
> **Step D — Publish the app**
> 1. Click **"Version Management & Release"** in the left menu
> 2. Click **"Create Version"** in the top right, fill in version number (e.g. `1.0.0`) and release notes
> 3. Scroll to the bottom and click **"Save"**, then confirm publish
> 4. Personal Feishu accounts: no review required, takes effect immediately. Enterprise accounts: requires admin approval.
>
> **Important**: The bot can only send and receive messages after the app is approved.

2d. **Domain**

Ask:
> **Which version are you using?**
>
> 1. Feishu (China)
> 2. Lark (International)
>
> Enter 1 or 2 (default: 1):

If `1`, use `https://open.feishu.cn`. If `2`, use `https://open.larksuite.com`.

2e. **Allowed User IDs**

Ask with context:

> **Allowed user IDs (optional)**
>
> You can restrict which users can interact with this AI bot. To find your own Open ID:
> 1. After publishing, open the Feishu app — you'll get a notification from "Developer Assistant". Click **"Open App"** to make the bot appear in your message list
> 2. Send any message to the bot (e.g. "hello")
> 3. Go back to the Feishu Open Platform → your app → **"Log Search"** → **"Event Log"** tab
> 4. Set a time range and click **"Query"**, find the `im.message.receive_v1` event and expand it
> 5. Copy the value of `sender.sender_id.open_id` (format: `ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`)
>
> Or enter "skip" to allow all users. You can add restrictions later via `/im-bridge reconfigure`.
>
> Enter allowed Open IDs (comma-separated, or "skip"):

**Step 3 — Permission Mode**

Ask:
> **Permission mode**
>
> 1. `auto_approve` (recommended) — AI executes all operations automatically, no confirmation needed. Best for IM use.
> 2. `confirm_safes` — AI will ask you before performing high-risk operations.
>
> Enter 1 or 2 (default: 1):

Accept `1` or `2`. Default to `auto_approve` if user types `1` or anything unrecognized.

**Step 4 — Write config and validate**

1. Show summary table with all settings (mask secrets to last 4 chars)
2. Ask user to confirm by showing:
   > Is the above configuration correct? Type "confirm" to save:
3. Only proceed if user inputs "confirm", "yes", or "y".
4. Use Bash to create directories: `mkdir -p ~/.clacky/im-bridge/{logs,runtime}`
5. Use Write to create `~/.clacky/im-bridge/config.env`
6. Use Bash to set permissions: `chmod 600 ~/.clacky/im-bridge/config.env`
7. Validate Feishu credentials:
   ```bash
   DOMAIN="${FEISHU_DOMAIN:-https://open.feishu.cn}"
   curl -s -X POST "${DOMAIN}/open-apis/auth/v3/tenant_access_token/internal" \
     -H "Content-Type: application/json" \
     -d "{\"app_id\":\"${APP_ID}\",\"app_secret\":\"${APP_SECRET}\"}"
   ```
   Check for `"code":0` in the response. If validation fails, explain and ask if they want to re-enter credentials.
8. On success, tell the user: "Configuration complete! Run `/im-bridge start` to start the bridge."

Feishu config file format:
```
IM_ENABLED_PLATFORMS=feishu
IM_PERMISSION_MODE=auto_approve
IM_FEISHU_APP_ID=cli_xxx
IM_FEISHU_APP_SECRET=xxx
IM_FEISHU_DOMAIN=https://open.feishu.cn
IM_FEISHU_ALLOWED_USERS=ou_xxx,ou_yyy
```

---

### Platform: WeCom (option 2)

**Step 2 — Collect WeCom credentials**

2a. **Bot ID**

Ask:
> **How to create a WeCom API bot and get the Bot ID:**
> 1. Open the WeCom client → Workbench → Smart Bot
> 2. Click **"Create Bot"** to enter the creation page
> 3. Scroll to the bottom and click the **"API Mode"** link
> 4. Select **"Long Connection"** as the connection type
> 5. Fill in the bot **name** and **description** (both required), then confirm
> 6. After creation, the **Bot ID** is shown on the right side of the page — copy it
>
> Enter your **Bot ID**:

Confirm the entered value back.

2b. **Secret**

Ask:
> **How to get the Secret:**
> On the same page under the **API Configuration** section, find the **Secret** row and click **"Click to Reveal"** to display and copy it.
>
> Enter your **Secret**:

Confirm back (masked, show only last 4 chars).

**Step 3 — Permission Mode**

Same as Feishu Step 3.

**Step 4 — Write config and validate**

1. Show summary table with all settings (mask secrets to last 4 chars)
2. Ask user to confirm by showing:
   > Is the above configuration correct? Type "confirm" to save:
3. Only proceed if user inputs "confirm", "yes", or "y".
4. Use Bash to create directories: `mkdir -p ~/.clacky/im-bridge/{logs,runtime}`
5. Use Write to create `~/.clacky/im-bridge/config.env`
6. Use Bash to set permissions: `chmod 600 ~/.clacky/im-bridge/config.env`
7. No API validation needed for WeCom (credentials are verified on WebSocket connect).
8. Tell the user: "Configuration complete! Run `/im-bridge start` to start the bridge."

WeCom config file format:
```
IM_ENABLED_PLATFORMS=wecom
IM_PERMISSION_MODE=auto_approve
IM_WECOM_BOT_ID=xxx
IM_WECOM_SECRET=xxx
```

### `start`

Check config exists first.

Run: `bash "${SKILL_DIR}/scripts/daemon.sh" start`

Show the output. If it fails:
- Suggest: Run `/im-bridge doctor` to diagnose
- Show recent logs: `/im-bridge logs`

### `stop`

Run: `bash "${SKILL_DIR}/scripts/daemon.sh" stop`

### `status`

Run: `bash "${SKILL_DIR}/scripts/daemon.sh" status`

### `logs`

Extract line count N from arguments (default 50).
Run: `bash "${SKILL_DIR}/scripts/daemon.sh" logs N`

### `reconfigure`

1. Read current config from `~/.clacky/im-bridge/config.env`
2. Parse `IM_ENABLED_PLATFORMS` to determine which platforms are currently enabled
3. Show current settings in a table (mask secrets), including which platforms are currently enabled
4. Build the options menu dynamically:
   - Option 1: "Add a new platform" — only show if there are platforms not yet enabled (e.g. if only feishu is enabled, show "Add new platform (e.g. WeCom)"; if both are enabled, omit this option)
   - Option 2: "Update existing platform credentials"
   - Option 3: "Change permission mode"
   - Option 4: "Change allowed user list" — only show if Feishu is enabled (WeCom has no allowed users setting)
5. Ask what the user wants to do with the dynamically built menu

**If user chooses "Add a new platform":**
- Show only platforms not yet in `IM_ENABLED_PLATFORMS` (e.g. if feishu is enabled, show: 1. WeCom)
- Ask which platform to add
- Collect credentials for the new platform following the same steps as in `setup`
- Append the new platform to `IM_ENABLED_PLATFORMS` (comma-separated) and add its keys to the config
- Write config atomically (write to .tmp, rename)
- Remind: "Run `/im-bridge stop` then `/im-bridge start` to apply changes."

**If user chooses other options:**
- Collect the new value(s)
- For Feishu credential changes: show the relevant credential steps from the setup wizard inline (same instructions as Step 2a/2b above)
- Update config atomically (write to .tmp, rename)
- Re-validate changed Feishu credentials if app_id or app_secret changed
- Remind: "Run `/im-bridge stop` then `/im-bridge start` to apply changes."

### `doctor`

Diagnose the IM bridge by checking the following, one at a time:

1. **Binary**: Run `which clacky-im-bridge` — if missing, suggest `gem install openclacky`
2. **Config**: Check if `~/.clacky/im-bridge/config.env` exists and is readable — if missing, suggest `/im-bridge setup`
3. **Config permissions**: Run `stat ~/.clacky/im-bridge/config.env` — warn if not 600
4. **Enabled platforms**: Read config and check `IM_ENABLED_PLATFORMS` is set and each platform's required keys are present
5. **Feishu API** (if feishu enabled): Validate credentials with a token request — report success or HTTP error. WeCom has no equivalent REST auth endpoint — credentials are verified at WebSocket connect time, so skip API check for WeCom
6. **Daemon**: Check if the PID in `~/.clacky/im-bridge/runtime/bridge.pid` is a running process
7. **Recent errors**: Read the last 100 lines of `~/.clacky/im-bridge/logs/bridge.log` — summarize any ERROR lines and suggest fixes

Report a clear pass/fail for each check and give specific remediation steps for failures.

## Security Notes

- Always mask secrets in output (show only last 4 characters)
- Never start the daemon without valid config
- Config file should always be `chmod 600`
