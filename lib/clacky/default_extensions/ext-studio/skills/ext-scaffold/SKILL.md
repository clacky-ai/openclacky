---
name: ext-scaffold
description: Scaffold a new OpenClacky extension from an idea. Use when the user wants to create, start, or bootstrap a new extension, plugin, panel, agent, or skill container. Maps the idea to the right contributes types and generates a working skeleton in the local layer.
---

# Extension Scaffold

Turn a plain-language idea into a working extension skeleton, then read the generated
files so you know what you're working with.

## Step 1 — Understand the idea

Figure out what the extension should DO and which contributes types it needs. Ask one
clarifying question only if it's genuinely ambiguous. Common mappings:

- "Show me X in a side panel / add a button / dashboard" → **panel** (+ **api** if it
  needs a backend or to call an external service).
- "A capability the AI can invoke" (summarize, translate, format) → **skill**.
- "A specialized assistant with its own personality/tools" → **agent** (usually
  bundling its own panels/skills).
- "Connect to Slack / an in-house IM" → **channel**.

Keep it minimal. Most useful extensions are one panel + one handler, or one skill.
Do NOT add `patches` or `hooks` unless the user explicitly asks — they run arbitrary
Ruby and carry supply-chain risk.

## Step 2 — Generate the skeleton

Pick a lowercase, hyphenated id derived from the idea (e.g. `weather-panel`).

```
clacky ext new <id>
```

This creates `~/.clacky/ext/local/<id>/` with a working hello panel + handler:
- `ext.yml` — the manifest
- `panels/hello/view.js` — a panel that pings the backend
- `api/handler.rb` — a `Clacky::ApiExtension` subclass mounted at `/api/ext/<id>/`

Use `--full` only if the user needs the kitchen-sink reference exercising all seven
contributes types — it's a lot to read, so prefer the plain scaffold otherwise.

## Step 3 — Read what was generated

Always read the generated `ext.yml`, `view.js`, and `handler.rb` before editing. This
is your starting point; you'll reshape it to match the idea.

## Step 4 — Reshape to the idea

Edit the files into real, working code:
- Rename the panel id and `view.js` path to match the feature.
- Update `ext.yml` `contributes:` — add `skills:`/`agents:` blocks if needed. A skill
  is a `SKILL.md` under `skills/<id>/`; an agent is a `system_prompt.md` that can
  reference `panels: [id]` and `skills: [id]`.
- In `view.js`, reuse host CSS classes (`btn-primary`, `btn-secondary`, `form-input`,
  `form-textarea`, `form-label`) so the panel inherits the theme automatically.
- In `handler.rb`, define routes relative to the `/api/ext/<id>/` mount.
- To persist **user data** (config, saved records, history), write it via
  `data_path("file.json")` — it lands in `~/.clacky/ext-data/<id>/`, outside the
  package, so uninstall/reinstall preserves it. **Never** write user data into
  the package dir (`ext_dir`); the whole package is deleted on uninstall, so
  data there is lost. Package-internal writes are only for disposable caches.

## Step 5 — Confirm it loads

Run `clacky ext verify` and confirm the new units resolve with no errors. Then tell
the user to reload the WebUI page — panels and api changes are live on the next request,
no restart needed.

If verify reports problems, switch to debugging (the ext-debug skill covers this).
