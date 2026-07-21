---
name: ext-develop
description: Build, debug, or publish an OpenClacky extension — scaffold a new one from an idea, fix a broken/invisible panel/api/skill/agent, or ship it to the marketplace. Trigger on create/start extension, plugin, panel, ext verify error, "won't load", "not showing up", publish/ship/unpublish an extension.
agent: ext-developer
---

# Extension Development

Build an OpenClacky extension end to end — scaffold, edit, verify, hot-reload, and
(only when asked) publish. Prefer editing real files and verifying over describing.

## The extension model (ground truth)

An extension is one directory with a single `ext.yml` manifest declaring
`contributes:`. Nothing is nested — units reference each other by id. It survives
`gem update` and never requires editing gem source.

Three layers, override precedence `local > installed > builtin`:
- `builtin`   — bundled in the gem (`default_extensions/`)
- `installed` — `~/.clacky/ext/installed/<id>/` (from `ext install`)
- `local`     — `~/.clacky/ext/local/<id>/` (where users develop; `ext new` lands here)

Seven `contributes:` types (use one, several, or all):
- `panels`   — WebUI panels (a `view.js`, no build step, no React, no iframe)
- `api`      — one backend file `api/handler.rb`, mounted at `/api/ext/<id>/`
- `skills`   — a `SKILL.md` under `skills/<id>/` (prompt-only capability)
- `agents`   — a `system_prompt.md`; can reference `panels: [id]` and `skills: [id]`
- `channels` — an IM adapter
- `patches`  — monkey-patch a real class (advanced, supply-chain risk)
- `hooks`    — lifecycle hooks like `before_tool_use` (advanced)

Hot reload is per-request: after editing `view.js`, `handler.rb`, or a `SKILL.md`,
the user just reloads the WebUI page — no server restart. Editing `ext.yml` also
applies on the next load.

## Hard rules — never break these

- ❌ **Never edit the gem source.** Do NOT `bundle show openclacky` and change files
  in there. Everything lives in `~/.clacky/ext/local/<id>/` and survives `gem update`.
- ❌ **Never `restart the server` to apply a change.** Hot reload is per-request —
  the user just reloads the WebUI page. If you're telling them to restart, you're wrong.
- ❌ **Never declare success on "it should work."** A task is done only when
  `clacky ext verify` is clean AND the user reloaded and saw it work. Run verify —
  don't imagine its output.
- ❌ **Never add `patches:` or `hooks:` unless the user explicitly asks.** They run
  arbitrary Ruby and carry supply-chain risk. Default to `panels`/`api`/`skills`/`agents`.
- ❌ **Never publish on your own initiative.** Publishing is opt-in — see **Publish**.
- ❌ **Never write `window.Sessions` / `"Sessions" in window` in `view.js`.** Host
  services are `const` bindings, not `window` properties — such checks return
  `undefined`/`false` even when loaded. Always use `Clacky.Sessions.*` etc.
- ✅ **Always work in the `local` layer** (`~/.clacky/ext/local/<id>/`). `ext new` lands
  there; that's the only layer you edit.

## Which section do I need?

Pick exactly ONE and follow it top to bottom. Don't blend the three.

- Starting a new extension from an idea → **Scaffold**.
- Something is broken, `verify` errors, or a change didn't show up → **Debug & verify**.
- The user explicitly wants to share/ship it to others → **Publish** (optional; skip
  it entirely for extensions the user only runs themselves).

**Reference: the contracts** is not a path — it's the field/slot/event/API ground truth
you consult from whichever path you're on.

---

## Reference: the contracts

Read the relevant reference doc with `web_fetch` before writing code — don't guess field
names, hook events, adapter methods, or the `Clacky.ext` WebUI contract.

### Authoritative documentation

- Extension system overview → https://www.openclacky.com/docs/extension-system
- **ext.yml manifest — every field (names, avatar, title_zh, order, …)** → https://www.openclacky.com/docs/ext-manifest
- Panels (WebUI) → https://www.openclacky.com/docs/extend-webui
- API backends → https://www.openclacky.com/docs/extend-api
- Agents (prompt, avatar, panels/skills wiring) → https://www.openclacky.com/docs/agent-config
- Channel adapters → https://www.openclacky.com/docs/extend-channel-adapter
- Patches → https://www.openclacky.com/docs/extend-patches
- Shell hooks → https://www.openclacky.com/docs/extend-shell-hooks

### WebUI panels: the `Clacky.ext` contract

A panel is a plain `view.js` (no build step, no React, no iframe). It reaches the host
**only** through `window.Clacky` — everything else on the page is off-limits. There are
exactly three capabilities:

```js
Clacky.ext.ui.mount(slot, spec, opts)     // inject UI into a named slot
Clacky.ext.subscribe(event, handler)      // observe host store events (read-only)
Clacky.ext.api.register(name, fn)         // expose a named data source; api.resolve(name)
```

**`ui.mount(slot, spec, opts)`** — `spec` is either `(container, ctx, runtime) => …` or
`{ create?, render }`. The render function:
- gets a host-owned `container` DOM element — append into it, **or** return a Node / HTML
  string and the host appends for you;
- returning a **function** registers it as a teardown callback;
- returning **`null`/`undefined` renders nothing** — but returning `null` from a wrong
  signature (e.g. `(ctx) => …` instead of `(container, ctx) => …`) is the #1 cause of a
  red "crashed" placeholder. Match the signature exactly.

`ctx` carries `{ sessionId, agentProfile }`. `opts`: `order` (lower renders first,
default 100), `tab: { id, label, badge? }` (**required** for tabbed slots — `session.aside`
is tabbed), `agents: [profile]` (override auto scope), `workspace: id` (for nav items).

**Valid slot names** (mounting into any other name silently renders nothing, warned once):

```
header.left  header.right
sidebar.nav.top  sidebar.nav  sidebar.nav.bottom  sidebar.footer
main.workspace
session.banner  session.composer  session.aside      (session.aside is tabbed)
settings.tabs  settings.body
```

Agent scope is automatic: mounts into `session.*` / `settings.*` slots only show for the
panel's owning agent(s); all other slots (`sidebar.*`, `header.*`, `main.workspace`) are
global chrome. You rarely set `agents:` by hand.

**Per-session state** — for `session.aside/banner/composer`, pass `{ create(ctx), render }`:
`create` runs once per session and returns a runtime (put timers/recorders/subscriptions
there), `render(container, ctx, runtime)` runs on each show, and `runtime.dispose()` runs
when the session leaves. State survives tab switches; use this instead of module globals.

**Full-page workspace** — `Clacky.ext.ui.registerWorkspace(id, { title, render })` takes
over the main area with its own `#ext/<id>` URL; open it with `Clacky.ext.ui.openWorkspace(id)`,
typically from a `sidebar.nav` item mounted with `opts.workspace: id`.

**Safe mode** — `?pure=true` makes the whole registry a no-op; never rely on side effects
outside these calls.

### Other host services under `Clacky.*`

Beyond `Clacky.ext`, the host exposes stores as properties on `window.Clacky`. Use them
instead of bare globals:

```js
Clacky.Sessions.on("switched", handler);   // active session store
Clacky.Router.go("session");                // top-level view routing
Clacky.Router.navigate("session", { id }); // navigate with params
Clacky.I18n.t("some.key");                  // translations
Clacky.Modal.confirm("Delete?");            // dialogs
Clacky.Notify.info("Saved");                // toasts
Clacky.Auth.passed;                          // auth state
Clacky.Workspace.list(dir);                 // working-directory files
Clacky.Skills.list();                       // skill catalog
Clacky.WS.send({ type: "..." });            // send a WebSocket message to the agent
```

- Prefer `Clacky.Xxx.method(...)` — the recommended, forward-stable form. Never test with
  `window.Sessions` / `"Sessions" in window` (see Hard rules).

### API backend: the `Clacky::ApiExtension` contract

`api/handler.rb` subclasses `Clacky::ApiExtension`. Routes mount under
`/api/ext/<ext_id>/`. This base class already wires up auth, JSON envelopes, timeouts, and
path params — you only write business logic. Full surface:

```ruby
class MyExt < Clacky::ApiExtension
  timeout 30                              # class-wide default (max 600s)

  get "/summary" do
    json(count: session_manager.list.size)   # json(key: val) → 200 JSON
  end

  post "/items/:id" do                    # :id → params["id"]
    body = json_body                      # parsed request JSON (Hash)
    q    = query["page"]                  # query string params
    File.write(data_path("items", "#{params['id']}.json"), body.to_json)  # persistence
    json({ ok: true }, status: 201)
  end

  get "/export", timeout: 60 do
    send_data(bytes, content_type: "text/csv", filename: "out.csv")
  end
end
```

Response helpers: `json` / `text(str)` / `send_data(bytes, content_type:, filename:)` /
`error!(msg, status:)`. Request: `params` (path), `query`, `json_body`, `req`.

- **`data_path(*parts)`** is the **official way to persist user data** — it returns a path
  under `~/.clacky/ext-data/<id>/`, **outside** the package tree, so it survives reloads,
  `gem update`, and even uninstall/reinstall (uninstall keeps it by default; the user opts
  in to deleting it via a checkbox). **Never** write user data into the extension's code
  dir (`ext_dir` / `File.join(ext_dir, ...)`) — uninstall deletes the whole package, so
  anything there is lost. Package-internal writes are only for disposable caches.
- Host context (white-listed): `session_manager`, `registry`, `agent_config`, `config`
  (from ext.yml), `logger`, `ext_id`, `ext_dir`.
- Drive sessions from the backend: `create_session(prompt:, profile:, …)`,
  `submit_task(session_id, prompt)`, `dispatch_to_session(session_id, prompt)` (runs a
  side task on a fork and returns its reply without touching the conversation).
- Public (no-auth) endpoints: call `public_endpoint("/path")` in the class **and** set
  `public: true` at ext.yml top level — both are required.

### Patches & hooks (advanced — only when asked)

- **Patch** (`contributes.patches: [{ target, file, fingerprint?, on_mismatch }]`):
  overrides a method via `Module#prepend` without editing gem source. `target` is
  `"Clacky::Tools::WebSearch#execute"` (`#` = instance, `.` = class). `fingerprint` is a
  SHA of the original method source; on drift the patch is disabled (`on_mismatch: disable`,
  default) or warned (`warn`).
- **Hook** (`contributes.hooks: [{ event, file }]`): registers a lifecycle callback. Valid
  `event` values (exactly these): `before_tool_use after_tool_use on_tool_error on_start
  on_complete on_iteration session_rollback`. A `before_tool_use` hook returning
  `{ action: :deny, reason: "…" }` **blocks** the tool call — this is how you audit or
  gate dangerous commands.

## Scaffold

Turn a plain-language idea into a working skeleton, then read the generated files.

### 1 — Understand the idea

Figure out what it should DO and which contributes types it needs. Ask one clarifying
question only if genuinely ambiguous. Common mappings:

| User wants to… | contributes: field |
|---|---|
| Show X in a side panel / add a button / dashboard | `panels:` (+ `api:` if it needs a backend or an external service) |
| A capability the AI can invoke (summarize, translate, format) | `skills:` |
| A specialized assistant with its own personality/tools | `agents:` (usually bundling its own panels/skills) |
| Connect to Slack / an in-house IM | `channels:` |
| Change behavior of a built-in method | `patches:` |
| Audit / block / observe tool calls | `hooks:` |

Keep it minimal — most useful extensions are one panel + one handler, or one skill.
Do NOT add `patches` or `hooks` unless the user explicitly asks; they run arbitrary
Ruby and carry supply-chain risk.

**Appearance & naming are manifest fields, not separate features.** When the user wants a
custom logo/avatar for an agent, a Chinese (or other-language) display name, a panel tab
label, or ordering, those are optional keys in `ext.yml` — e.g. agent `avatar:` (image
path), `title` / `title_zh`, `description` / `description_zh`, `order`. Never say it can't
be done; set the field and check the full list in the ext.yml manifest doc.

### 2 — Generate the skeleton

Pick a lowercase, hyphenated id derived from the idea (e.g. `weather-panel`).

```
clacky ext new <id>
```

This creates `~/.clacky/ext/local/<id>/` with a working hello panel + handler:
- `ext.yml` — the manifest
- `panels/hello/view.js` — a panel that pings the backend
- `api/handler.rb` — a `Clacky::ApiExtension` subclass mounted at `/api/ext/<id>/`

Use `--full` only when the user needs the kitchen-sink reference exercising all seven
contributes types — it's a lot to read, so prefer the plain scaffold otherwise.

### 3 — Read what was generated

Always read the generated `ext.yml`, `view.js`, and `handler.rb` before editing. This
is your starting point; you'll reshape it to match the idea.

### 4 — Reshape to the idea

Before editing, re-read the contract for whatever the idea needs (panel / API / patch /
hook) in **Reference: the contracts** above — don't guess field names, slot names, hook
events, or the `Clacky.ext` surface.

The scaffold ships a working "hello" panel that pings its backend. Turn it into the real
feature by editing those three files. Below is a concrete before → after for a tiny
"add a note" panel — use it as the shape to copy, not the literal content.

**`ext.yml`** — rename the panel id/view to the feature; add `skills:`/`agents:` only if needed:

```yaml
contributes:
  api: api/handler.rb
  panels:
    - id: notes                       # was: hello
      view: panels/notes/view.js      # was: panels/hello/view.js
      attach: ["*"]
```

**`panels/notes/view.js`** — keep the `Clacky.ext.ui.mount(...)` wrapper and host CSS
classes; swap the body for the real UI, POST to your own route:

```js
Clacky.ext.ui.mount("session.aside", function (ctx) {
  var el = document.createElement("div");
  el.style.padding = "16px";
  var input = document.createElement("input");
  input.className = "form-input";                 // reuse host theme
  var btn = document.createElement("button");
  btn.className = "btn-primary";
  btn.textContent = "Save note";
  btn.addEventListener("click", async function () {
    await fetch("/api/ext/<id>/notes", {          // relative to your mount
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: input.value }),
    });
    Clacky.Notify.info("Saved");                  // host toast, not window.alert
  });
  el.append(input, btn);
  return el;
}, { tab: { id: "notes", label: () => "Notes" }, order: 500 });
```

**`api/handler.rb`** — stay a `Clacky::ApiExtension` subclass; add the route the panel
calls. Persist user data with `data_path` (lands in `~/.clacky/ext-data/<id>/`, survives
reloads, `gem update`, and uninstall/reinstall), never into the code dir:

```ruby
class <Prefix>Ext < Clacky::ApiExtension
  post "/notes" do            # matches /api/ext/<id>/notes
    text = json_body["text"].to_s
    File.write(data_path("notes.txt"), "#{text}\n", mode: "a")
    json(saved: true)
  end
end
```

Rules while reshaping:
- Keep the panel `view:` path and the on-disk `view.js` path in sync — mismatched paths
  are the #1 cause of a `loader.error`.
- Routes in `handler.rb` are **relative** to `/api/ext/<id>/`; the `view.js` `fetch` must
  match. A mismatch is a silent 404, not a verify error.
- Persist state with `data_path(...)`, never by writing into the extension's code dir.
- The `ui.mount` render signature is `(container, ctx, runtime)` — `container` is the first
  argument, not `ctx`. Writing a shorter `(ctx) => ...` signature shifts every argument, so
  session checks misbehave. Returning `null` is safe (renders nothing); only a **thrown
  exception** shows the red crashed-panel box.
- Reuse host CSS classes (`btn-primary`, `btn-secondary`, `form-input`, `form-textarea`,
  `form-label`) and host services (`Clacky.Notify`, `Clacky.Modal`) instead of raw
  `alert`/`confirm`, so the panel inherits the theme.
- A skill is a `SKILL.md` under `skills/<id>/`; an agent is a `system_prompt.md` that can
  reference `panels: [id]` and `skills: [id]`. Add those blocks to `ext.yml` only if the
  idea needs them.

### 5 — Confirm it loads

Run `clacky ext verify` and confirm the new units resolve with no errors, then have the
user reload the WebUI page. If verify reports problems, go to **Debug & verify**.

## When NOT to build an extension

- The user is building features in their own app that just *use* openclacky — that's
  normal coding, no extension container needed.
- The user wants a tool/skill for *their own* project — use `.clacky/skills/` or
  `.clacky/tools/` in their project, not a gem-level container.
- The change can be made via `clacky config set ...` — prefer config over patches.

---

## Debug & verify

Your primary instrument is `clacky ext verify` — a compiler for extensions: every issue
is structured with a `code`, `message`, the offending `file`, and a `hint`.

**Top 5 things that break — check these first:**

| Symptom | Almost always | Fix |
|---|---|---|
| Red error box where the panel should be | `ui.mount` render signature is wrong / returned `null` | signature is `(container, ctx, runtime)` — not `(ctx)` |
| Panel doesn't appear at all | `slot` name typo (silent) or no `attach:` | use a valid slot; set `attach: ["*"]` or an agent id |
| Frontend `fetch` gets 404 | route in `handler.rb` ≠ path in `view.js` fetch | routes are relative to `/api/ext/<id>/` |
| `loader.error` on verify | `ext.yml` `view:` path ≠ the on-disk `view.js` path | make the two match exactly |
| Edited a file, nothing changed | page not reloaded (or edited `ext.yml`) | reload the WebUI page — hot reload is per-request |


### 1 — Run verify

```
clacky ext verify
```

Read the output line by line. `[OK]` confirms a resolved unit; `[ERR]` blocks a load;
`[WARN]` is advisory. Each issue looks like:

```
[ERR] <ext> <unit> (<code>) — <message> [<file>]
         hint: <how to fix>
```

**Always trust the `hint` first.** The line below tells you the fix per code; do the
smallest change, re-run verify, repeat until clean — fix ONE issue at a time.

### 2 — Fix by error code

- **`loader.error`** → a file the manifest points at is missing, or `ext.yml` isn't valid
  YAML. **Do:** open the `file` path in the error; make sure it exists and the path in
  `ext.yml` matches it exactly. (skill → `SKILL.md` under `skills/<id>/`; agent → its
  `prompt` file; panel → its `view` file; api → `api/handler.rb`.)
- **`schema.unknown_contributes`** → a top-level key under `contributes:` is misspelled.
  **Do:** fix the spelling to one of `panels api skills agents channels patches hooks`.
- **`schema.unknown_key`** → an unknown **top-level** key in `ext.yml`. **Do:** fix the
  spelling. Allowed top-level keys: `id name title description version origin author
  homepage license public license_required keywords contributes`.
- **`schema.unknown_field`** → a unit has a field not allowed for its type. **Do:** delete
  or rename that field. Allowed fields per type (this is the authoritative list — do not
  invent others):
  - panel: `id title title_zh description description_zh view order attach entry_points`
  - api: `id handler`
  - skill: `id dir protected`
  - agent: `id title title_zh description description_zh order prompt panels skills avatar`
  - channel: `id platform adapter`
  - patch: `target file fingerprint on_mismatch`
  - hook: `event file`
- **`schema.bad_attach`** → a panel `attach:` entry isn't a valid token. **Do:** set it to
  an agent id or `"*"` (all).
- **`ref.missing_panel`** → an agent's `panels: [id]` names a panel that doesn't exist.
  **Do:** fix the id, or use `<ext_id>/<panel_id>` to point at another extension's panel.
- **`ref.missing_skill`** → an agent's `skills: [id]` names a skill that doesn't exist.
  **Do:** fix the id, or add the `SKILL.md`.
- **`ref.missing_attach_agent`** → a panel's `attach:` names a nonexistent agent.
  **Do:** fix the agent id.
- **`override`** (warning) → a higher layer is shadowing a lower one
  (`local > installed > builtin`). **Do:** usually intentional — leave it; confirm with the
  user only if the shadowing is a surprise.

Fix one issue, re-run verify, repeat until clean.

### 3 — "It verifies but doesn't show up"

If verify is clean but a change isn't visible:
- **Hot reload is per-request.** After editing `view.js`, `handler.rb`, or a `SKILL.md`,
  the user must **reload the WebUI page** — no restart, but a stale tab won't update on
  its own. Editing `ext.yml` also applies on the next load.
- **Panel not appearing?** In order: (1) the `slot` name in `ui.mount` must be one of the
  valid slots — a typo like `session.aisde` silently renders nothing (check the browser
  console for a "unknown slot" warning); (2) check the panel's `attach:` (or the agent
  that references it via `panels: [id]`) — a panel with no `attach` and no referencing
  agent has nothing to mount onto; (3) a red error box means the render function threw
  or returned `null` from a wrong signature — open the console for the stack.
- **API 404?** Routes are relative to `/api/ext/<ext_id>/`. Confirm the handler subclasses
  `Clacky::ApiExtension` and the route pattern matches what `view.js` fetches.
- **Skill not triggering?** The AI selects skills by their `description`. Make the
  description concrete about WHEN to use it.

### 4 — Confirm the fix

End with a clean `clacky ext verify` and have the user reload to confirm the behavior
actually works — don't declare success on "should work."

---

## Publish (optional)

Publishing is **not** a required step. Many extensions are built for the user's own use —
scaffold, verify, and reload is the whole job. Only publish when the user explicitly asks
to share, ship, or list the extension for others. Never publish on your own initiative or
as a "wrap up" of the build.

The **Extension & Creation panel** has a Publish button — prefer it for a
guided flow. Use the CLI below for scripted/CI publishing.

### Before publishing

- The extension must live in the **local** layer (`~/.clacky/ext/local/<id>/`). Only local
  containers can be packed; encrypted (`SKILL.md.enc`) containers are rejected.
- Publishing requires the device to be **bound to a platform account** (it attributes the
  extension to that account). If it isn't bound, tell the user to authorize the device
  first — don't try to work around it.
- Run `clacky ext verify` one last time and confirm no errors.

### Publish (first time)

```
clacky ext publish <id>
```

Packs the local container into a zip and uploads it. On success: `Published <id>
v<version> → status=<status>`. Options:
- `--status draft` — publish as a draft (not visible on the public marketplace). Omit or
  use `--status published` to go live.
- `--changelog "..."` — release notes for this version.

### Publish a new version

If already published, a plain `publish` fails with `Error: <id> already published. Re-run
with --force to publish a new version.` Re-run with `--force` (and ideally a `--changelog`);
the patch version auto-increments on the platform side.

```
clacky ext publish <id> --force --changelog "Fixed the weather refresh bug"
```

### List your published extensions

```
clacky ext published
```

Shows each extension with its latest version, status, and unit summary.

### Unpublish

```
clacky ext unpublish <id>
```

Soft-deletes (takes down) one of your published extensions. Confirm with the user first —
it removes it from the marketplace.

### Wrap up

After a successful publish, tell the user the version and status in plain terms, and
mention they can run `clacky ext published` to see it, or bump a new version anytime with
`--force`.
