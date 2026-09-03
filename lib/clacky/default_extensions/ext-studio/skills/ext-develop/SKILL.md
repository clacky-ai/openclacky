---
# Maintenance note: Do not relax the installed-gem source restriction.
# After context compression, previously inspected host files may be
# mistaken for extension edit targets.
name: ext-develop
description: Build, debug, or publish an OpenClacky extension — scaffold a new one from an idea, fix a broken/invisible panel/api/skill/agent, or ship it to the marketplace. Trigger on create/start extension, plugin, panel, ext verify error, "won't load", "not showing up", publish/ship/unpublish an extension.
agent: ext-developer
---

# Extension Development

Use this skill to guide the workflow, not as a second API manual. The online
references below own the detailed contracts, examples, and reload behavior. The local
engineering checks below remain mandatory even when those references cannot be fetched.

## Before designing or editing

1. Identify what the user wants and the smallest capability set that can provide it.
   Check existing host services and shared panels before building a replacement.
2. For behavior-only discussion, apply **Engineering checks** without enumerating APIs.
   Before specifying or implementing an interface, fetch its capability reference below;
   read the overview when container/scaffold/reload behavior is relevant. Reuse verified
   text still in context. Check truncation and missing details using **Documentation
   fallback**; a successful response does not prove the needed contract was retrieved.
   Use the article's contract/examples, not the documentation site's navigation, page
   styles or scripts. Those belong to a different application, not the extension host.
3. Confirm the proposed behavior, affected files, and visible result with the user
   before scaffolding or editing. Do not publish, restart, or add privileged behavior
   merely because implementation was approved.

### Documentation fallback

1. Fetch the relevant official URL directly; a web search is not required. For truncated
   output, read the returned `temp_file` for the needed section. For HTML pages, `web_fetch`
   saves extracted text with whitespace collapsed, not original HTML: line-based reading
   may still return one long line. One targeted text extraction is enough to check a
   detail. Do not write helper scripts or try to reconstruct code formatting from that
   text; lost newlines can change the meaning of code comments and examples.
   A no-file-change task includes temporary files such as `/tmp/*.py`: only read the
   tool-returned cache, do not create a script or reformatted copy elsewhere.
2. If the needed contract is still missing, truncated, or ambiguous, stop this lookup.
   Report it as unverified; no match on a page does not prove the method or its namespace
   absent, private, or unsupported. Do not inventory other APIs to infer an answer.
   Do not retry extraction or probe other extensions/the running host to fill the gap.
   Ask permission to open the official documentation in a new browser tab. If already
   authorized for this task's documentation lookup, do not ask again for each page.
3. After consent, use the available `browser` tool to read only the relevant official
   documentation. Do not navigate, inspect, or close unrelated tabs. Read beyond truncated
   snapshots as needed; opening a page alone does not verify its contents. If browser setup
   is required, ask whether the user wants to use `browser-setup`; never enable it silently
   or bypass a disabled browser. If the tool is unavailable, do not invent another browser
   control mechanism or install one without approval.
4. If the user declines or the browser cannot retrieve the reference, ask the user to
   supply the documentation or designate a separate source checkout matching the running
   version and permit read-only inspection. Do not search installed OpenClacky gem source.
   Reading a checkout does not authorize modifying it to make an extension work.
5. If still blocked, end with only **Unverified detail**, **Reference checked**, and
   **Evidence or permission needed next**. For example: "I could not verify this method
   from this page; please provide its source." Do not turn that into "the object does
   not exist" followed by a disclaimer. Clarifying the user's goal may continue, but
   implementation against that contract must wait. Resolve version differences before
   relying on a contract; version metadata is allowed, installed implementation source is not.

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
  gem source to customize a user's extension. Do not search or read installed OpenClacky
  gem implementation source, even to resolve missing documentation; version metadata is
  allowed. Confirm intentional id overrides.
- Do not add hooks or patches without an explicit request; they execute arbitrary Ruby.
- Reuse the documented host APIs and theme conventions. Do not guess methods from
  similarly named libraries or manipulate host internals.
- Keep data outside the extension package using the documented persistence facility.
  Validate input and get consent for destructive or paid operations.
- Choose the reload procedure from the overview's contribution-specific table.
  Do not claim that every change hot-reloads, or restart the server without consent.
- Verification is evidence, not a prediction: distinguish manifest checks, tests,
  actual UI/API behavior, and anything still awaiting user verification.
- Local development does not imply marketplace publication.

## Engineering checks

Apply these when proposing the design and again against the actual code before handoff.
Do not count a promise to follow a rule as evidence that the implementation follows it.

1. **Access and side effects:** identify files, sessions, credentials, and external
   destinations involved. Refuse unauthorized access or disclosure; never bypass host
   authentication. Keep secrets out of frontend code and logs. Validate inputs and paths,
   keep persistent data outside the package, and ensure destructive changes or private-data
   transfers require specific approval rather than general permission to build.
2. **Request budget:** check every fetch, loop, timer, retry, and worker. Prefer events and
   cached reads; do not repeatedly fetch full histories. Default to no added threads;
   necessary concurrency must be bounded. No tight loops or sub-second polling. Necessary
   polling must use a coarse interval, prevent overlap, pause when hidden or finished, and
   have bounded retries and request duration. Check the failure path as well as success.
3. **Lifecycle and cost:** verify rerenders and session switches do not multiply listeners,
   timers, or requests; disposal releases them and stale responses cannot affect a new
   session. Hidden cached panels must pause unnecessary work without waiting for disposal.
   A tab/session switch does not prove disposal occurred; verify unsubscribe/visibility
   contracts instead of using assumed disposal as a substitute for cleanup.
   Model/media calls need explicit approval, including recurring scope; mounting, refresh,
   and history replay must not initiate paid or destructive actions or external sends.
   Read-only billing queries are not model invocations, but still need request limits.
4. **Host reuse and evidence:** reuse host capabilities and `btn-*` / `form-*`,
   `Clacky.Modal`, and `var(--color-*)`; use scoped, prefixed custom styles where needed.
   For basic inputs use `form-input` / `form-textarea`. Confirm custom property names in
   the relevant reference or generated scaffold, not by their plausible spelling; do not
   invent fallback token names. If a token is unverified, omit the color override and
   inherit host styling, rather than adding a guessed token with hardcoded fallback colors.
   Prefix tab ids with the extension id to avoid collisions.
   Check light/dark appearance for UI work. Do not add unrequested hooks or patches or
   modify installed packages. Test the applicable boundaries above with controlled data;
   do not use real destructive, disclosure, or paid operations just to prove a safeguard.
   Report which checks were exercised, which were code review only, and which remain open.

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
  APIs** to show the refresh button once; also open the aside for a session-aside panel.
  Use the injected service/session context, not a guessed host, port, or session id.
- These HTTP helpers are not browser control. If the user will test the browser, keep
  that boundary and report UI checks as pending; do not treat it as permission to inspect
  their tabs. Honor a separate request not to send UI-helper broadcasts.
- A successful UI-helper response only acknowledges a broadcast. If no matching UI
  is connected, ask for manual refresh. Verify required Ruby reloads separately;
  neither UI helper restarts the server.
- Stop at the approved outcome. Do not publish or perform other release actions as
  an automatic wrap-up.
