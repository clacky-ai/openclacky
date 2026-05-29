# MCP Support — Design Notes

OpenClacky speaks the **Model Context Protocol** (MCP) so users can plug in
the same servers they already use with Claude Desktop, Cursor, etc. The
config format is identical (`mcpServers` map in `mcp.json`), but the
internal architecture is different — designed to keep main-context tokens
flat as users add more servers.

## The problem with naive MCP integration

Every MCP server exposes its tool catalog as JSON Schema. The traditional
approach is to splat **all** tool schemas into the system prompt:

- A typical GitHub server alone is ~6 000 tokens.
- Three or four servers easily push the system prompt past 30 000 tokens.
- Every turn pays that cost; cache misses on the system prompt are very
  expensive.

OpenClacky avoids this entirely.

## The approach: one constant tool, on-demand catalogs

### 1. A single bridge tool: `mcp_call`

When `mcp.json` is non-empty, the agent registers exactly **one** extra
tool — `mcp_call(server, tool, arguments)`. Its JSON schema is constant
regardless of how many servers exist or how many tools they each expose.
The system-prompt footprint is fixed at ~80 tokens.

If the user has zero MCP servers configured, `mcp_call` is **not**
registered. Zero-MCP users pay nothing.

### 2. Each MCP server becomes a virtual Skill

For every server in `mcp.json`, the registry synthesizes a
`Clacky::Mcp::VirtualSkill` exposed to the agent as:

- identifier: `mcp:<server>`
- slash command: `/mcp-<server>`
- `fork_agent: true` (runs in a subagent)
- description: the `description` field from `mcp.json` (or a default)

These appear in the same Skills section the main agent already scans, so
discovery costs are negligible — about 50 tokens per server (one-line
description), regardless of how many actual tools that server exposes.

### 3. Tool catalogs land in the subagent — as a user message

When the main agent decides to use a server, it calls
`invoke_skill("mcp:<server>", "<task>")`. That forks a subagent and the
VirtualSkill's content (a markdown body listing every tool with its full
`inputSchema`) is injected as the **first user message** in the subagent's
history.

Why a user message and not the system prompt:

- The subagent inherits the parent's tool registry verbatim, which
  preserves prompt-cache keys.
- Tool schemas in user messages still benefit from Anthropic's tiered
  prompt caching, but they don't pollute the parent's cached prefix.
- The subagent has full type information for everything it can call,
  exactly when it needs it.

### 4. Lazy startup, idle reaping

`Mcp::Registry` does **not** spawn server processes at boot. The first
`call_tool` (or first time a subagent fetches the catalog) triggers
`ensure_started`. A background reaper shuts servers down after five
minutes of inactivity. This keeps the "no gateway" promise — MCP is just
local processes the agent talks to over stdio.

## Token-budget summary

| Scenario | Main-context cost |
| --- | --- |
| 0 MCP servers configured | 0 |
| `N` servers, no calls in flight | ~80 + 50·N tokens |
| Active call | 0 in main; full schemas land only in the relevant subagent |

Add a tenth server? Main system prompt grows by ~50 tokens. Compare to
naive integration: ~6 000 × 10 ≈ 60 000 tokens up front.

## Files

- `lib/clacky/mcp/client.rb` — stdio JSON-RPC 2.0 client
- `lib/clacky/mcp/registry.rb` — config loading, lazy starts, idle reaping
- `lib/clacky/mcp/virtual_skill.rb` — synthesized Skill per server
- `lib/clacky/tools/mcp_call.rb` — the single bridge tool
- `docs/mcp.example.json` — example `mcp.json`

## Configuration paths

Servers are loaded from these files (later wins on conflict):

1. `~/.clacky/mcp.json` (global)
2. `<project>/.clacky/mcp.json` (per-project, when a working dir is set)

Format matches Claude Desktop / Cursor:

```json
{
  "mcpServers": {
    "<name>": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-…"],
      "env": { "OPTIONAL_VAR": "value" },
      "description": "Optional human-readable line shown to the agent."
    }
  }
}
```

`description` is OpenClacky-specific and recommended — it's what the main
agent sees when deciding whether to call into a given server.
