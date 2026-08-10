# Remote MCP OAuth and Extension Fallback Design

## Purpose

OpenClacky extensions need to connect users to OAuth-protected remote MCP servers without embedding access tokens in `mcp.json`. ChatCut is the first integration, but the client capability must remain provider-neutral.

The delivery has two independently usable versions:

1. A pure ChatCut extension that works on current OpenClacky releases by registering a local stdio bridge. The bridge owns OAuth and forwards MCP traffic to ChatCut's hosted Streamable HTTP endpoint.
2. Native OpenClacky remote MCP OAuth. Once present, the same extension detects it and registers ChatCut as a direct HTTP MCP server; on older clients it falls back to the bridge.

## User Experience

Installing the ChatCut extension adds setup, status, and disconnect skills. Setup examines the installed OpenClacky capability instead of asking the user which mode to use.

- On a client with native OAuth support, setup writes a direct HTTP server entry with `auth.type: oauth`, then runs the native login command.
- On an older client, setup writes a stdio server entry pointing at the extension bridge. The bridge opens the browser when authorization is first required.
- Both modes expose the same `mcp:chatcut` virtual skill and the same remote ChatCut tools and playbooks.
- Setup merges the `chatcut` entry without overwriting other MCP servers. Disconnect removes only the entry owned by the extension and deletes only ChatCut credentials.
- A newly registered MCP is used from a new session on current clients. Native hot reload may be added independently and is not required for protocol correctness.

## Shared Configuration Contract

Native mode uses a direct remote server:

```json
{
  "mcpServers": {
    "chatcut": {
      "type": "http",
      "url": "https://api.chatcut.io/api/external-mcp/mcp",
      "auth": {
        "type": "oauth",
        "resource": "https://api.chatcut.io/api/external-mcp/mcp"
      },
      "description": "Edit and create videos through ChatCut"
    }
  }
}
```

Fallback mode uses the installed extension bridge:

```json
{
  "mcpServers": {
    "chatcut": {
      "command": "ruby",
      "args": ["/absolute/extension/path/bridge/chatcut_mcp_bridge.rb"],
      "description": "Edit and create videos through ChatCut"
    }
  }
}
```

The extension records its selected mode and managed configuration fingerprint under `~/.clacky/ext-data/chatcut/`. It does not silently replace a user-managed `chatcut` entry that differs from the recorded fingerprint.

## Extension Bridge

The bridge is a provider-specific compatibility adapter distributed with the extension. It speaks MCP JSON-RPC over stdin/stdout toward OpenClacky and Streamable HTTP toward ChatCut.

The bridge performs OAuth protected-resource discovery, authorization-server discovery, dynamic client registration, Authorization Code with PKCE S256, loopback callback handling, access-token injection, refresh-token rotation, and one refresh-and-retry after a 401. It stores credentials in a mode-0600 JSON file below `~/.clacky/ext-data/chatcut/`; stdout remains protocol-only and diagnostics go to stderr with secrets redacted.

The bridge validates that discovered authorization endpoints are HTTPS and belong to the authorization server advertised by the protected resource. Its callback binds only to `127.0.0.1`, uses a random available port, verifies `state`, and applies timeouts and response-size limits.

## Native OpenClacky OAuth

Native OAuth adds a provider-neutral authorization layer around HTTP MCP transport:

- `clacky mcp login SERVER`, `status SERVER`, and `logout SERVER` commands.
- OAuth metadata discovery from a 401 `WWW-Authenticate` challenge or an explicit resource URL.
- Dynamic Client Registration and Authorization Code with PKCE for public native clients.
- A credential store outside `mcp.json`, with mode-0600 files as the portable baseline.
- Automatic bearer injection, proactive refresh near expiry, and one refresh-and-retry after a 401.
- Secret-safe exceptions and logs.

The HTTP transport remains responsible only for MCP HTTP semantics. An OAuth session supplies headers and handles authorization-specific retries. Static `headers` remain supported for non-OAuth servers.

## Capability Detection

The native client exposes capability detection through `clacky mcp capabilities --json`. The extension selects native mode only when the response includes `remote_oauth: true`. Absence of the command, invalid JSON, or a false value selects bridge mode.

This avoids version string comparisons and permits backports. The bridge remains installed even in native mode so downgrading OpenClacky and rerunning setup produces a working fallback.

## Security and Failure Behavior

- Tokens, authorization codes, PKCE verifiers, client secrets, and refresh tokens never appear in `mcp.json`, agent prompts, or stdout protocol frames.
- OAuth is refused for non-HTTPS remote resources and authorization endpoints; loopback HTTP is allowed only for the local callback.
- A mismatched OAuth `state`, missing code, registration failure, denied consent, invalid refresh response, or malformed metadata produces an actionable error without leaking secrets.
- Concurrent processes serialize credential updates and write through a temporary file followed by an atomic rename.
- Refresh-token rotation replaces the stored refresh token only after a successful token response.
- A user-managed conflicting MCP entry is preserved and setup stops with a clear conflict message.

## Compatibility and Distribution

The extension package contains Ruby source, skills, manifest, icon, tests, and documentation only. It does not bundle FFmpeg or copy ChatCut's Codex plugin. ChatCut playbooks are loaded from the MCP server through `list_skills` and `load_skill`.

The OpenClacky change remains generic and carries no ChatCut constants, UI labels, endpoints, or business logic.

## Acceptance Scenarios

1. On an unmodified current OpenClacky build, extension setup installs a stdio `chatcut` entry without disturbing another MCP entry.
2. First bridge use opens ChatCut authorization, persists protected credentials, lists ChatCut tools, and keeps stdout valid JSON-RPC.
3. An expired access token is refreshed without user action, with rotated refresh credentials persisted.
4. On a native-OAuth OpenClacky build, extension setup installs a direct HTTP entry and does not invoke the bridge.
5. Native `mcp login`, `status`, and `logout` work against a standards-compliant local test authorization server.
6. Native MCP calls inject the bearer token, refresh once after 401, and never expose tokens in errors.
7. Downgrading to a client without the capability and rerunning setup changes the extension-managed entry back to bridge mode.
8. Disconnect removes the managed ChatCut entry and ChatCut credentials while preserving unrelated MCP configuration.

## Assumptions

- ChatCut continues to support MCP protocol version `2024-11-05`, Dynamic Client Registration, PKCE S256, refresh tokens, `list_skills`, and `load_skill` as documented in its WorkBuddy integration.
- The first release uses a protected file credential store for portability. OS keychain integration can be added behind the same store interface later.
- Publishing the standalone extension repository is separate from the OpenClacky upstream PR; both artifacts are committed and testable locally before publication.
