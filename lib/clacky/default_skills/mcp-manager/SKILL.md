---
name: mcp-manager
description: |
  Manage MCP (Model Context Protocol) servers for openclacky: add, list, probe, remove,
  reconfigure. Edits ~/.clacky/mcp.json so the user never writes JSON by hand.
  Trigger on: add mcp, install mcp, setup mcp, configure mcp, mcp list, mcp remove,
  mcp probe, mcp reconfigure.
argument-hint: "add | list | probe <name> | remove <name> | reconfigure <name>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskFollowupQuestion
---

# MCP Manager Skill

Manage MCP servers for openclacky. The user's MCP configuration lives at
`~/.clacky/mcp.json` (the same format Claude Desktop and Cursor use). You never
ask the user to edit it by hand — you do it for them through the local clacky
HTTP API.

---

## Command Parsing

| User says | Subcommand |
|---|---|
| `add mcp`, `install mcp`, `connect <something>`, "I want clacky to read my files / access github / query my db / search the web" | `add` |
| `mcp list`, `mcp status`, "what mcps do I have" | `list` |
| `mcp probe <name>`, "what tools does <name> have" | `probe` |
| `mcp remove <name>`, `mcp delete <name>` | `remove` |
| `mcp reconfigure <name>`, `mcp fix <name>` | `reconfigure` |

If the intent is unclear, default to **`add`** — it's the most common ask.

---

## Server Coordinates

All API calls go to the local clacky server. The host and port are exposed via
environment variables:

```bash
HOST="${CLACKY_SERVER_HOST:-127.0.0.1}"
PORT="${CLACKY_SERVER_PORT:-7070}"
BASE="http://${HOST}:${PORT}"
```

All write operations require requests to come from `127.0.0.1` or `::1`. They
will, because we're running locally.

---

## API Cheat Sheet

| Action | Call |
|---|---|
| List configured servers | `curl -s ${BASE}/api/mcp` |
| Add a server | `curl -s -X POST ${BASE}/api/mcp -H 'Content-Type: application/json' -d '{...}'` |
| Update a server | `curl -s -X PUT ${BASE}/api/mcp/<name> -H 'Content-Type: application/json' -d '{...}'` |
| Remove a server | `curl -s -X DELETE ${BASE}/api/mcp/<name>` |
| Probe tools | `curl -s -X POST ${BASE}/api/mcp/<name>/probe` |

Request body for create/update — **stdio** (local process, default):

```json
{
  "name": "filesystem",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Documents"],
  "env": { "API_KEY": "xxx" },
  "description": "Read/write files in ~/Documents"
}
```

Request body for create/update — **http** (remote server, streamable-http):

```json
{
  "name": "linear",
  "type": "http",
  "url":  "https://mcp.linear.app/sse",
  "headers": { "Authorization": "Bearer lin_api_xxx" },
  "description": "Linear issues and projects"
}
```

If `type` is omitted but `url` is present, the server treats it as `http`.

---

## Known-Good Server Catalog

When the user describes what they want, match it to one of these and propose it.
Each entry: package, what it does, required params, recommended `description`.

### 1. `filesystem` — read/write local files
- **When**: "read my files", "access my desktop", "browse my code"
- **Command**: `npx`
- **Args**: `["-y", "@modelcontextprotocol/server-filesystem", "<ABSOLUTE_PATH>"]`
- **Required**: absolute directory path (ask user; default to `~/Documents`)
- **Tools**: read_file, write_file, list_directory, search_files, etc.

### 2. `github` — GitHub repos, issues, PRs
- **When**: "access github", "manage my repos", "read my issues"
- **Command**: `npx`
- **Args**: `["-y", "@modelcontextprotocol/server-github"]`
- **Env**: `{ "GITHUB_PERSONAL_ACCESS_TOKEN": "<TOKEN>" }`
- **Required**: PAT from https://github.com/settings/tokens (recommend `repo` scope)

### 3. `fetch` — fetch HTTP URLs as markdown
- **When**: "fetch web pages", "read articles by url"
- **Command**: `uvx`
- **Args**: `["mcp-server-fetch"]`
- **Required**: nothing
- **Note**: needs Python `uv` installed (`brew install uv`)

### 4. `memory` — persistent knowledge graph
- **When**: "remember things across sessions", "give clacky long-term memory"
- **Command**: `npx`
- **Args**: `["-y", "@modelcontextprotocol/server-memory"]`
- **Required**: nothing

### 5. `postgres` — query a Postgres database
- **When**: "query my database", "connect to postgres"
- **Command**: `npx`
- **Args**: `["-y", "@modelcontextprotocol/server-postgres", "<DATABASE_URL>"]`
- **Required**: DATABASE_URL like `postgresql://user:pass@host:5432/dbname`

### 6. `slack` — Slack messages
- **When**: "read slack", "send slack messages"
- **Command**: `npx`
- **Args**: `["-y", "@modelcontextprotocol/server-slack"]`
- **Env**: `{ "SLACK_BOT_TOKEN": "xoxb-...", "SLACK_TEAM_ID": "T..." }`
- **Required**: bot token and team id (Slack admin → app config)

### 7. `brave-search` — web search via Brave API
- **When**: "search the web", "give clacky search"
- **Command**: `npx`
- **Args**: `["-y", "@modelcontextprotocol/server-brave-search"]`
- **Env**: `{ "BRAVE_API_KEY": "<KEY>" }`
- **Required**: free API key from https://api.search.brave.com/

### 8. `puppeteer` — browser automation
- **When**: "automate the browser", "scrape with js"
- **Command**: `npx`
- **Args**: `["-y", "@modelcontextprotocol/server-puppeteer"]`
- **Required**: nothing (downloads Chromium on first run)

### Custom (anything else)
If the user names a package or path you don't recognize, take the spec from them
verbatim and pass it through. Always confirm `command`, `args`, and `env` back
in plain language before saving.

### Remote / HTTP servers (streamable-http)
Some MCP servers are hosted services and don't ship as a CLI — you connect over
HTTPS instead. **Trigger when** the user gives you a URL ending in `/mcp`,
`/sse`, or hosted on `*.mcp.*` / `mcp.*.app`, or says "the server is at
https://...".

- **Type**: `http`
- **Required**: `url` (the streamable-http endpoint)
- **Optional**: `headers` — typically `{ "Authorization": "Bearer <token>" }`

Examples of remote MCP servers in the wild:
- Linear: `https://mcp.linear.app/sse` (Bearer API key)
- Cloudflare: `https://<workers-subdomain>.workers.dev/mcp` (Bearer token)
- GitHub Copilot: `https://api.githubcopilot.com/mcp/` (OAuth, advanced)

When the user pastes a URL, ask:
1. What service is this? (so you can pick a `name` and `description`)
2. Does it need an authorization header? If yes, paste the token.

Save with `type: "http"`. The local clacky never spawns a process for these —
it just POSTs JSON-RPC over HTTPS.

> ⚠️ Wrapping a regular CLI tool: if the user gives you a CLI command that is
> **not** a stdio MCP server (e.g. `mcp-cli`, `some-api-cli login`), do NOT save
> it as a stdio MCP entry — it won't speak JSON-RPC over stdin. Tell them: *"This
> looks like a regular CLI, not an MCP server. Does the service offer an HTTPS
> endpoint instead?"*

---

## Subcommand: `add` — the primary flow

Goal: the user describes what they want, you produce a working MCP entry +
confirm it works. Keep questions minimal.

### Step 1 — Identify intent
- If the user's first message already names a server (e.g. "add filesystem"),
  pick that catalog entry directly.
- Otherwise, ask **one** open question: *"What would you like Clacky to be
  able to do? (e.g. read your files, access GitHub, search the web)"*
- Match their answer to the catalog. If multiple match, present 2–3 options
  with one-line descriptions and let them pick.

### Step 2 — Environment preflight
Before asking for parameters, check the runtime is installed:

```bash
# For npx-based servers
which npx >/dev/null 2>&1 || echo "MISSING_NPX"

# For uvx-based servers
which uvx >/dev/null 2>&1 || echo "MISSING_UVX"
```

If missing, tell the user how to install (`brew install node` for npx,
`brew install uv` for uvx) and stop. Do not proceed.

### Step 3 — Collect parameters
Ask only for the **business-meaningful** params from the catalog entry:
- For `filesystem`: which directory? Default offer: `~/Documents`. Resolve `~`
  to an absolute path before saving.
- For `github`/`brave-search`/`slack`: tell them where to get the token, then
  ask them to paste it.
- For `postgres`: ask for the connection URL.

Never invent values. If you don't have a sensible default, ask.

### Step 4 — Confirm
Show the user the spec you're about to save, in plain language:

> I'll add a server called **filesystem** that runs `npx -y @modelcontextprotocol/server-filesystem /Users/me/Documents`. It'll let me read and write files in your Documents folder. OK?

For secrets (tokens, passwords), echo only the last 4 characters: `***...abcd`.

### Step 5 — Save
For stdio:
```bash
curl -s -X POST ${BASE}/api/mcp \
  -H 'Content-Type: application/json' \
  -d '{
        "name":        "filesystem",
        "command":     "npx",
        "args":        ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Documents"],
        "description": "Read/write files in ~/Documents"
      }'
```

For http:
```bash
curl -s -X POST ${BASE}/api/mcp \
  -H 'Content-Type: application/json' \
  -d '{
        "name":        "linear",
        "type":        "http",
        "url":         "https://mcp.linear.app/sse",
        "headers":     { "Authorization": "Bearer lin_api_xxx" },
        "description": "Linear issues and projects"
      }'
```

If the response has `"ok": false`, show the error and ask the user how to
proceed (retry, edit, abort).

### Step 6 — Probe
Immediately verify the server starts and exposes tools:

```bash
curl -s -X POST ${BASE}/api/mcp/filesystem/probe
```

- **`ok: true`**: extract `tools[]`, summarize for the user. Example:
  > Done. **filesystem** is working — Clacky now has 11 new tools (read_file, write_file, list_directory, ...). Try asking me to *list files in your Documents folder*.
- **`ok: false`**: show the error verbatim and offer common fixes:
  - "command not found" → wrong runtime, suggest re-running with correct one
  - "ENOENT" / "no such file" → bad path, ask for a valid one
  - timeout → package may be downloading on first run; suggest retrying
  - auth-related → token wrong/expired, offer `reconfigure`

### Step 7 — Hint at next steps
End with a one-line nudge: how the user can use the new MCP next. Examples:
- filesystem: "Try: *list the files in my Documents folder*"
- github: "Try: *show me my open PRs*"
- fetch: "Try: *fetch https://news.ycombinator.com and summarize*"

---

## Subcommand: `list`

```bash
curl -s ${BASE}/api/mcp
```

Render as a short table. If `configured: false`, say so and offer to run `add`.

```
| Name         | Command | Args summary           | Has env |
|--------------|---------|------------------------|---------|
| filesystem   | npx     | @modelcontextprotocol… | no      |
| github       | npx     | @modelcontextprotocol… | yes     |
```

Don't show full args if they contain absolute paths — collapse them with `…`.

---

## Subcommand: `probe <name>`

```bash
curl -s -X POST ${BASE}/api/mcp/<name>/probe
```

If `ok: true`, list every tool with a one-line description. If `ok: false`, run
the same error-fixing flow as in `add` step 6.

---

## Subcommand: `remove <name>`

1. Confirm with the user first: *"Remove **<name>**? Its tools will no longer
   be available to Clacky. (Y/n)"*
2. On yes:
   ```bash
   curl -s -X DELETE ${BASE}/api/mcp/<name>
   ```
3. Confirm completion in one line.

---

## Subcommand: `reconfigure <name>`

1. Fetch current spec from `/api/mcp` and show it back.
2. Ask which fields to change (path / token / args).
3. Build the new spec and `PUT /api/mcp/<name>`.
4. Probe to verify, same as `add` step 6.

---

## General Rules

- **Never write directly to `~/.clacky/mcp.json`.** Always go through the API.
- **Never echo full secrets.** Mask all but last 4 chars of tokens/URLs.
- **One question at a time.** Don't dump a form on the user.
- **Stop on errors.** Don't proceed past a failed preflight or probe.
- **Quote real error messages.** Don't paraphrase API errors — users may need to
  google them.
- **Stay in scope.** If the user wants to write/edit a non-MCP file or do
  unrelated work, hand back to the main agent.
