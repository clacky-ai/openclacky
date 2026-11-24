---
# Maintenance note: Do not relax the installed-gem source restriction.
# After context compression, previously inspected host files may be
# mistaken for extension edit targets.
name: ext-develop
name_zh: 扩展开发
description_zh: 开发、调试和发布扩展。
description: Build, debug, or publish an OpenClacky extension.
agent: ext-developer
---

# Extension Development

## Before designing or editing

Identify what the user wants and Confirm the proposed behavior, affected files, and visible result with the user before scaffolding or editing.

## Capability → reference

| Need | Read |
|---|---|
| Container model, source layers, scaffold, reload, verification, publishing | [Extension System Overview](https://www.openclacky.com/docs/extension-system) |
| Manifest metadata, panels, agents, tools, skill restrictions, field validation | [ext.yml Manifest](https://www.openclacky.com/docs/ext-manifest) |
| Slots, agent scope, tab lifecycle/badges, subscriptions, replay, Composer, Aside, Modal, Workspace | [Web UI Extensions](https://www.openclacky.com/docs/extend-webui) |
| Extension-owned backend, route parameters, persistent data, session/project helpers, public endpoints | [HTTP API Extensions](https://www.openclacky.com/docs/extend-api) |
| Host sessions/history, files, recovery, billing, media, development UI helpers | [Calling Host APIs](https://www.openclacky.com/docs/extend-host-api) |
| Agent persona and configuration | [Agent Configuration](https://www.openclacky.com/docs/agent-config) |
| Skill authoring and invocation | [Skills](https://www.openclacky.com/docs/how-to-use-a-skill) |
| IM adapters, optional file delivery and buffered output | [Channel Adapters](https://www.openclacky.com/docs/extend-channel-adapter) |
| Tool-call/lifecycle hooks and persistent custom events | [Hooks](https://www.openclacky.com/docs/extend-shell-hooks) |
| Explicitly requested runtime patches | [Runtime Patches](https://www.openclacky.com/docs/extend-patches) |

Read the pages needed for this task, not every reference indiscriminately. This index
routes lookups; field lists, signatures, and code examples belong in those pages.

## Working boundaries

- Develop in `~/.clacky/ext/local/<id>/`. Never edit installed/builtin packages or
  gem source to customize a user's extension. 
- Reuse the documented host APIs and theme conventions. 
- Keep data outside the extension package using the documented persistence facility.
  Validate input and get consent for destructive or paid operations.
- Verification is evidence, not a prediction: distinguish manifest checks, tests,
  actual UI/API behavior, and anything still awaiting user verification.
- Local development does not imply marketplace publication.

## Scaffold

1. Agree on the smallest implementation. A panel may reuse a host API without a new
   backend; a capability composed from existing tools may only need a skill.
   A user's ordinary app work does not need an extension container, and a project-only
   skill can live in that project's `.clacky/skills/`.
2. Run `clacky ext new <id>` for a runnable skeleton. Use `--full` only when the task
   needs the broader examples. Read generated files before changing them.
3. Implement the approved behavior against the referenced contracts. Keep manifest
   paths, unit ids, and actual files aligned; do not retain unused scaffold features.
4. Adapt the scaffold's tests to the real behavior and run them. If a backend has no
   tests, add them instead of treating missing tests as permission to skip verification.
   Cover invalid input and failures as well as the successful response; apply
   **Engineering checks** to the implementation.
5. Run `clacky ext verify`; resolve errors and review warnings using its actual
   `code`, `file`, and `hint`. Verify the visible feature or endpoint afterward.
6. Follow **Handoff** below.

## Debug & verify

1. Reproduce the reported symptom; inspect the actual local container and relevant
   reference before proposing a fix.
2. Run `clacky ext verify` and read its structured findings. Use `clacky ext list`
   to identify the resolved layer and accidental shadowing. Do not maintain a second
   hardcoded list of accepted keys in this skill.
3. For invisible panels, check documented slots, tab options, manifest associations,
   and the browser error stack. For API failures, check the request method/path,
   handler contract, status, and logs. For stale behavior, check the reload matrix.
4. Fix the root cause within the agreed scope, rerun relevant tests and verification,
   then check the reported behavior and the affected **Engineering checks**. Do not widen
   scope to unrelated warnings without discussing them with the user.
5. Follow **Handoff** below.

## Publish (only on explicit request)

1. Read the overview's current publishing requirements and command options.
2. Confirm the target local container, intended marketplace status, device binding,
   and version. Do not bypass authentication, ownership, or encrypted-content limits.
3. Run tests and verification. If `README.md` is missing, ask whether to write usage
   instructions before proceeding; derive them from the actual implemented behavior.
4. Publish only the approved target/version/status. Updating an existing extension
   requires manually choosing a greater version in `ext.yml`; `--force` does not
   increment it. Explain failures instead of guessing alternate publish behavior.
5. Report the actual version and status returned. Unpublishing also needs explicit
   approval; it is not routine cleanup.

## Handoff

- State what changed, what passed, and what the user still needs to check.
- After extension edits, use the development UI helpers documented in **Calling Host
  APIs** to send the reload hint once, and to open the aside when the extension ships
  a panel there. Use the injected service/session context, not a guessed host, port,
  or session id.
- A new panel does not appear on screen after the reload: it waits in the aside's
  "New tab" list. Name the panel and tell the user they need to pick it there.
- These HTTP helpers are not browser control. If the user will test the browser, keep
  that boundary and report UI checks as pending; do not treat it as permission to inspect
  their tabs. Honor a separate request not to send UI-helper broadcasts.
- A successful UI-helper response only acknowledges a broadcast. If no matching UI
  is connected, ask for manual refresh. Verify required Ruby reloads separately;
  neither UI helper restarts the server.
- Stop at the approved outcome. Do not publish or perform other release actions as
  an automatic wrap-up.
