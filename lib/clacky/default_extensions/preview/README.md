## How to open

- Session side panel → the **Preview** tab; type an address in the bar and press Enter.
- Click an HTML file or a `localhost` link in the chat — the panel opens and loads it automatically.
- Status: on by default.

## How to use

### What the address bar accepts

- Workspace file paths, e.g. `index.html`, `dist/report.html`
- Local dev servers, e.g. `localhost:3000`, `http://127.0.0.1:5173`
- Regular URLs, e.g. `https://example.com`

### Toolbar

| Button | What it does |
|---|---|
| ← / → | Back / forward |
| ⟳ | Reload (click after the AI changes code to see the result) |
| ↗ | Open in a new browser tab |
| More | Zoom in / zoom out / reset to 100% |

## Notes

- Pages run in an isolated origin and cannot read Clacky's own data, while clicks, forms and logins in local Rails, React or Vue apps still work normally.
- If a file is missing or the server is not running, a friendly notice is shown instead of a blank page. Check the path or start your dev server.
- When you follow links inside the page, the address bar stays in sync.
