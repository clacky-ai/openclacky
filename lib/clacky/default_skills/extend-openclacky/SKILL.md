---
name: extend-openclacky
description: Customize, fix, override or extend openclacky itself — change a built-in tool's behavior, intercept/audit/block tool calls, plug in a new IM channel (Slack, in-house IM…), or add UI to the Web UI (panel, button, settings tab). Trigger on "patch openclacky", "block dangerous commands", "audit tool use", "add Slack channel", "extend the web ui", "改 openclacky 内置", "拦截工具调用", "扩展 web 界面". Do NOT trigger for ordinary feature work in the user's own project that doesn't touch openclacky.
---

# Extending Openclacky

Openclacky ships one unified extension mechanism — an **extension container**
declared by a single `ext.yml`. It survives `gem update` and never requires
editing the gem source.

**Never tell the user to `bundle show openclacky` and edit the gem.**

## The one entry point

Every extension lives in a container directory:

```
~/.clacky/ext/local/<id>/
  ext.yml         # single manifest — declares everything the container contributes
  panels/…        # WebUI panels (JS)
  api/handler.rb  # HTTP API backend
  skills/…        # AI skills
  agents/…        # agent profiles + prompts
  channels/…      # IM adapters
  patches/…       # runtime method patches
  hooks/…         # shell hooks
```

Scaffold with:
```bash
clacky ext new <id>            # minimal hello-panel starter
clacky ext new <id> --full     # kitchen-sink example with every contributes type
```

The ext.yml `contributes:` map declares which of these 7 types the container
provides. A container may use one, several, or all.

## Pick what to add to `contributes:`

| User wants to… | contributes: field |
|---|---|
| Add a **WebUI panel / button / settings tab / data visualisation** | `panels:` |
| Add an **HTTP API backend** (routes under `/api/ext/<id>/…`) | `api:` (a single `handler.rb`) |
| **Change behavior of a built-in method** in openclacky (e.g. `WebSearch#execute` timeout) | `patches:` |
| **Audit / block / observe** tool calls (block `rm -rf /`, log every shell command) | `hooks:` |
| Plug openclacky into a **new IM platform** (Slack, in-house IM, custom webhook) | `channels:` |
| Add a **new AI skill** (SKILL.md) | `skills:` |
| Bundle a **custom agent profile** with its own panels + skills | `agents:` |

## Authoritative documentation

Read the relevant reference doc with `web_fetch` before writing code —
don't guess field names, hook events, adapter methods, or the `Clacky.ext`
WebUI contract.

- Extension containers (ext.yml overview) → https://www.openclacky.com/docs/extend
- Panels (WebUI) → https://www.openclacky.com/docs/extend-webui
- API backends → https://www.openclacky.com/docs/extend-api
- Patches → https://www.openclacky.com/docs/extend-patches
- Shell Hooks → https://www.openclacky.com/docs/extend-shell-hooks
- Channel Adapters → https://www.openclacky.com/docs/extend-channel-adapter

## WebUI host services live under `Clacky.*`

The single public API surface for WebUI extensions is `window.Clacky`.
All host services are exposed as properties on it — reach for them there,
not through bare globals or `window.Xxx`:

```js
Clacky.Sessions.on("switched", handler);   // active session store
Clacky.Router.go("session");                // top-level view routing
Clacky.I18n.t("some.key");                  // translations
Clacky.Modal.confirm("Delete?");            // dialogs
Clacky.Notify.info("Saved");                // toasts
Clacky.Auth.passed;                          // auth state
Clacky.Workspace.list(dir);                 // working-directory files
Clacky.Skills.list();                       // skill catalog
Clacky.Backup.load();                       // backup/restore state
Clacky.WS.send({ type: "..." });            // send a WebSocket message to the agent
```

Rules:

- Prefer `Clacky.Xxx.method(...)` — this is the recommended, forward-stable form.
- `window.Clacky.Xxx.method(...)` works too and is fine in defensive code.
- **Never** write `window.Sessions` / `typeof window.Sessions` / `"Sessions" in window`
  — bare host names are `const` bindings, not `window` properties, so those checks
  return `undefined` / `false` even though the module is loaded.
- The bare form (`Sessions.on(...)`) still works for backwards compatibility
  but is not the pattern to teach or generate.

## Execution playbook

1. **Identify** which `contributes:` fields the user's intent needs (use the table above; ask if genuinely ambiguous).
2. **Read the doc(s)** for those fields. The doc is the contract.
3. **Scaffold** with `clacky ext new <id>` (or `--full` if the user wants every type wired up as a reference).
4. **Edit** `ext.yml` to declare the fields, and fill in the referenced files (panel view.js, api handler.rb, patches/xxx.rb, etc.).
5. **Verify** with `clacky ext verify`. Surface any error/skip lines to the user verbatim.
6. **Reload** the WebUI page (for panel/api changes take effect on next request — no restart needed).

## Persisting user data

If an API backend needs to persist **user data** that must survive uninstall +
reinstall (team info, saved config, history), store it via `data_path(...)` in
`handler.rb` — it returns a path under `~/.clacky/ext-data/<id>/`, **outside**
the package tree:

```ruby
File.write(data_path("teams.json"), JSON.generate(teams))
teams = JSON.parse(File.read(data_path("teams.json")))
```

- **Never** write user data into the package dir (`ext_dir` / `File.join(ext_dir, ...)`)
  — uninstall deletes the whole package, so anything there is lost, and a
  reinstall starts empty. That is a data-loss bug.
- Package-internal writes are fine only for **disposable** runtime artifacts
  (caches, downloaded wallpapers) that are meant to vanish on uninstall.
- Uninstall keeps `~/.clacky/ext-data/<id>/` by default; the user opts in to
  deleting it via a checkbox. Reinstalling the same extension reconnects to it.

## When NOT to use this skill

- The user is building features in their own application that just *use* openclacky — that's normal coding, no extension container needed.
- The user wants a brand-new tool/skill for *their* project — use `.clacky/skills/` or `.clacky/tools/` in their project, not a gem-level container.
- The change can be made via `clacky config set ...` — prefer config over patches.
