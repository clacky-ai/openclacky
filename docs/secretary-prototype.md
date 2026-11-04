# Secretary prototype

This version uses ordinary sessions: one secretary conversation owns a set of
background worker sessions. No extra daemon, database or extension installation
is required. The built-in `secretary` extension supplies the two profiles, three
model tools, API and Work panel. The server supplies persistence and coordination.

## Try it

Restart the server from this checkout (`bundle exec ruby bin/openclacky server`),
refresh the Web UI, and create a **生活秘书 / Secretary** session. Open its
**工作事项** side panel.

1. Say: “帮我查一下杭州适合带父母去的景点，整理一份建议，交给工作助手做。”
2. While it works, continue chatting with the secretary. The worker has a separate
   session, and the secretary receives its result when available.
3. Try: “准备一条约张三下周吃饭的邀请，优先周四。先给我草稿，我来发送。”
4. When the work requests your input, tell the secretary “我发出去了，请等待回复”,
   then relay “张三说只有周五有空”. The panel’s discussion button inserts a work
   session reference into the normal composer; it does not submit automatically.
5. Change requirements, pause, cancel or resume by talking to the secretary.
   Completed/cancelled items require new delegation.
6. Restart while waiting. The card and wait survive. A run interrupted while
   executing becomes “需要处理”; it is not blindly replayed.

## Scope

- Workers use their profile's normal tools and existing permission checks. Work
  coordination does not impose a separate read-only allowlist. The built-in worker
  can create files; additional integrations depend on its configured tools.
- Automatic incoming association requires an exact `reply_to`, channel and chat
  match. Telegram and Feishu normalize reply references. No heuristic matching
  or autonomous outbound messaging is included. Other replies can be relayed
  manually through the secretary conversation; never invent a sent message ID.
- `check_at` accepts future ISO8601 timestamps including an explicit UTC offset.
  A deadline wakes the worker to assess next steps; it does not authorize sending.
- This is a single-server local store. Do not run two servers against the same
  sessions directory. CLI conversations do not host the coordinator.
- The default background capacity leaves one slot available when the configured
  maximum is greater than one. A maximum of one cannot provide simultaneous
  foreground/background execution.

## Persistence and execution

`<sessions_dir>/work/state.json` contains cards, per-card result outboxes, and
threaded incoming events. Writes are mutex-protected atomic replacements with
mode 0600. Cards and result notifications are saved together. Active work and
pending notifications protect their associated sessions from automatic cleanup.
Explicit deletion of sessions is not a work cancellation API: cancel work first.

The coordinator runs once per second. It delivers pending secretary notifications
before dispatching queued workers. Only one execution per session is admitted.
Waiting uses no worker thread. A generation check rejects tools from an execution
whose requirements changed, was cancelled or already yielded. `yield_work` stops
execution even if the model returned additional tool calls in the same batch.

Notifications carry an event ID. The secretary history is persisted before outbox
acknowledgement; a replay checks history for that ID. This guarantees durable
receipt within retained history, not exactly-once model reasoning or external
side effects. External side effects still require tool-specific retry/idempotency handling.

The host captures recent verbatim user messages (with original message IDs) at
delegation and injects current card summaries into secretary turns. It does not
copy the entire parent conversation. Older necessary context must be supplied
explicitly; external replies are labelled separately from owner instructions.

## Extension API

Server-attached tools access `agent.work_service`; API handlers access
`work_service`. The service implements delegation, management and yielding without
requiring extensions to access the HTTP server's private execution methods.

- Secretary: `delegate_work`, `manage_work` (list/get/update/reply/pause/cancel).
- Worker: `yield_work` (completed/needs_input/waiting_event).
- UI: read-only `GET /api/ext/secretary/work?session_id=...`. All changes go
  through the secretary's tools in the main conversation.

## Presentation boundary

WorkService submits both worker tasks and secretary wakeups through the shared
`run_session_task` entry point. It does not call `Agent#run`, access agent UI,
render messages, or rewrite old history for presentation. `display_message` names
worker input/turns; `reference_contexts` holds model-only work data.

Work reports are ordinary session inputs: `display_message` becomes `display_text`
for friendly live display and history replay. Full work data uses the existing
reference-context path. No new hidden-turn API or rollback semantics are needed.

The panel owns English/Chinese strings and responds to the host language event.
Server-generated messages use Ruby i18n and the locale captured at delegation;
stored history, user text and worker results retain their original language.

The coordinator emits transient `ext.work.changed` invalidations scoped to the
owner session. The extension subscribes through `Clacky.ext`, fetches the durable
card snapshot, and shares it between the existing `session.aside` and
`session.composer` slots. Mount and reconnect also refresh. The composer slot
shows ongoing/waiting/decision counts while the normal session remains idle and
available for conversation. No extra global WS message flags or host rendering
branches are added. Panel actions use the existing Composer session-reference
API and preserve drafts. Historical prototype notifications are left untouched;
there is no string-based history repair.

## Recurring secretary work

The existing cron-task-creator skill and cron-task API own all plan management.
The secretary supplies owner_session_id from CLACKY_SESSION_ID, a friendly title,
a self-contained content prompt, cron when creating
through POST /api/cron-tasks. The API validates the owner and saves an execution
target. Existing GET/PATCH/DELETE/RUN routes manage the same plan; PATCH preserves
its target. The global API remains the user's management surface; the skill selects
plans by target.owner_session_id before changing them. Duplicate creates cannot
overwrite a secretary plan; use PATCH or a distinct name. manage_work remains
limited to individual work cards; there are no schedule-management tool actions.

For example, ask the secretary to prepare a morning report at 09:00 and an evening
report at 20:00 in server-local time. Specify sources and report scope; the prototype
has no automatic mailbox/calendar access. Each occurrence creates a fresh worker
session and durable work card; results return through the ordinary outbox and
friendly display_text path. Workers receive the plan instruction, occurrence time
and up to 50 recent work summaries. The work aside shows plans and their next due
time; changes are discussed in the existing conversation. Existing cron-task
management APIs also list/manage these plans; Run Now follows the work-card path.

Plans and prompts reuse schedules.yml and tasks/*.md. Next occurrence timestamps
are saved atomically. A restored process or resumed sandbox catches up only the
latest missed occurrence. A secretary occurrence is deduplicated by plan ID and
scheduled UTC instant in the work store, including when the plan cursor failed to
save after card creation. One unfinished card per plan is allowed: queued, running,
waiting, paused, failed and decision-needed work blocks the next occurrence until
resolved or cancelled. Pausing/deleting a plan does not cancel existing cards;
re-enabling or changing its timing starts from the next future occurrence.

Schedules use server-local time. Legacy plans without a cursor
begin tracking at the first scheduler tick (no invented pre-upgrade backlog).
Existing cron DOM/DOW AND semantics are retained. Receipt-based crash deduplication
is provided by secretary work cards; ordinary cron sessions keep their existing
execution path and do not gain an exactly-once execution guarantee.

No external wakeup service is introduced. Cron cannot execute while the sandbox is
paused; once something resumes it, due scanning continues. Existing yield_work
and check_at behavior is unchanged. Email subscriptions and cloud lifecycle APIs
remain outside this change.

## Custom secretary profiles

Use the existing user-agent directory and agent picker. No separate identity
store or management page is required. For example, create
`~/.clacky/agents/my-secretary/profile.yml`:

```yaml
name: my-secretary
title: My secretary
title_zh: 我的秘书
base_agent: secretary
```

In the same directory, write `system_prompt.md` with the user's responsibilities,
preferences and output expectations. The loader composes the secretary extension's
shared rules followed by this file. Existing base rules, global `SOUL.md` and
`USER.md` continue to load normally. The profile uses the secretary's declared
tool set and Work panel. `base_agent` can reference any agent contributed by an
enabled extension (for example `coding` or a third-party agent), not just
`secretary`. Only one direct reference is supported: no chains, user-only bases
or arbitrary cross-container tool merging. Base disabled-skill restrictions are
retained; custom profiles may disable additional skills. Skills scoped to the
base agent and panels attached to it also remain available. Extensions can use
`agent.agent_profile.based_on?(id)` to recognize customized profiles.

Restart the service after upgrading, then refresh the WebUI. The custom agent
appears in the existing new-conversation picker. Conversations retain the custom
profile name and keep work isolated by owner session. Scheduled work can belong
to these conversations too; workers use the configured work_agent profile.

Prompt edits follow ordinary profile behavior: new/restored agent instances load
current files. Already loaded instances are not hot-updated. This feature adds no
prompt snapshots, identity-specific memory, new session fields or outbound tools.

## Choosing a worker

An agent opts into delegation with `work_agent: <profile-id>` in its extension
agent declaration or user `profile.yml`. The built-in secretary sets
`work_agent: secretary-worker`. Custom `base_agent` profiles inherit this setting;
an explicit value overrides it and an empty string disables delegation.
The target must be an available profile. Its normal built-in and declared
extension tools load without an additional work-specific allowlist.

Third-party tools can call `agent.work_service.delegate`, `manage`, and
`yield_work`. A worker must report its outcome through `yield_work` (or its own
tool calling that service method). The service commits the outcome and returns
`end_turn: true`. Any tool can return this generic flag to finish the current turn
after recording its result; remaining tool calls in the batch are settled without
execution. The flag does not itself schedule a wakeup or pause a work card.
Work sessions retain revision/cancellation checks regardless of profile name.

## Handoffs, session status and alerts

`yield_work` uses `needs_input` for a question to the main agent and
`waiting_event` for an external reply or timed checkpoint. The main agent answers
from existing information/authorization when possible; otherwise it asks the user
and relays the answer. Legacy `needs_user` / `waiting_reply` calls and stored
`waiting_user` / `waiting_reply` cards remain readable and normalize to the new names.

Ending a tool turn does not imply awaiting an answer. `completed` and
`waiting_event` leave the worker session idle; `needs_input` leaves it
awaiting_feedback. The work card retains the durable outcome/wait state.
Worker turns do not alert the user directly. Delegation and reply/update handoffs
return `notify_user: false` to suppress completion alerts and done markers; an
explicit user question in the same owner turn takes precedence. Main-agent reports
retain normal notification behavior. The composer shows background work and task
titles without pretending the main agent is still executing.
