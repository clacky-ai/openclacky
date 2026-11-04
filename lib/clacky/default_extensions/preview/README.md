# Preview

A built-in mini browser: view and interact with pages the AI built, or your local dev server, right next to the chat — no window switching.

## Opening it

- **Easiest**: click an HTML file or a `localhost` link in the chat. The Preview panel opens and loads it automatically.
- **Manually**: switch to the **Preview** tab in the session's side panel, type an address and press Enter.

The address bar accepts:

- Workspace file paths, e.g. `index.html`, `dist/report.html`
- Local dev servers, e.g. `localhost:3000`, `http://127.0.0.1:5173`
- Regular URLs, e.g. `https://example.com`

## Toolbar

| Button | What it does |
|---|---|
| ← / → | Back / forward |
| ⟳ | Reload (click after the AI changes code to see the result) |
| ↗ | Open in a new browser tab |
| More | Zoom in / zoom out / reset to 100% |

## Tips

- Pages run in an isolated origin and cannot read Clacky's own data, while clicks, forms and logins in local Rails, React or Vue apps still work normally.
- If a file is missing or the server is not running, a friendly notice is shown instead of a blank page. Check the path or start your dev server.
- When you follow links inside the page, the address bar stays in sync.
