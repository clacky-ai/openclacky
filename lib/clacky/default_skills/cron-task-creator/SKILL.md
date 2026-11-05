---
name: cron-task-creator
name_zh: 定时任务
description_zh: 创建和管理定时自动任务，支持按天、周、小时执行，可随时编辑、启停或删除。
description: 'Create, manage, and run scheduled automated tasks (cron jobs) in Clacky. Use this skill whenever the user wants to create a new automated task or cron job, set up recurring automation, schedule something to run daily/weekly/hourly, view all scheduled tasks, edit an existing task prompt or cron schedule, enable or disable a task, delete a task, check task run history or logs, or run a task immediately via the WebUI. Trigger on phrases like cron, scheduled task, run every day, automate this; 定时任务, 每天自动, 定时执行.'
disable-model-invocation: false
user-invocable: true
---


# Cron Task Creator

Create and manage scheduled tasks through the existing cron-task API. This skill
supports both ordinary tasks and secretary work; they share plan management but
have different execution and result destinations.

## Determine the task type

For an **existing plan**, GET its saved metadata first. Its saved target determines
its type, regardless of which conversation is currently managing it:

| Saved plan | Execution | Result/history |
|---|---|---|
| No target (including older plans) | Ordinary agent session | Tasks run history and execution session |
| target.type = secretary_work | Work card and worker session | Owning secretary conversation and work card |

Do not convert an old ordinary task to secretary work because it is opened from a
secretary conversation. PATCH preserves the target. Do not recreate a plan just
to edit it. Moving an existing plan to another execution type or owner is not a
PATCH capability; explain this if the user requests it and establish the intended
replacement before creating/deleting anything.

For a **new plan**:

- In an ordinary conversation, create an ordinary task as before.
- In a known secretary conversation, create secretary work by default, unless the
  user explicitly requests an independent ordinary task.
- CLACKY_SESSION_ID exists for ordinary sessions too; its presence alone does not
  identify a secretary. Use the current agent role, not the task title (e.g.
  "morning report"), to choose the default.
- Secretary workers currently support read/research work. Do not silently send a
  task requiring writes, shell execution, email sending or booking to a worker
  that cannot perform it. Explain the mismatch and clarify the intended execution
  or report-only scope. Ordinary tasks retain their existing tools/permissions.

Both types use server-local cron time. Only ask for missing requirements; do not
introduce an extra confirmation when the user's intent is already clear.

## API and storage

Base URL: `http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}`.
Use the server's configured authentication if required; do not print credentials.

| Operation | Endpoint |
|---|---|
| List plans | GET /api/cron-tasks |
| Create | POST /api/cron-tasks |
| Edit or enable/disable | PATCH /api/cron-tasks/:name |
| Delete | DELETE /api/cron-tasks/:name |
| Run once now | POST /api/cron-tasks/:name/run |
| Ordinary run history | GET /api/cron-runs?task=:name |
| Secretary work history | GET /api/ext/secretary/work?session_id=:owner |

Prompts are stored in `~/.clacky/tasks/<name>.md`; plans are stored in
`~/.clacky/schedules.yml`. Use the API for changes rather than editing these files.
GET returns name, title, content, cron, enabled, next_run, last_run and optional target.
`name` is a stable ASCII identifier; `title` is the human-readable label. Names are
global, not per conversation. Always inspect the response and handle errors before
reporting success.

## 1. List and select

```bash
curl -s "http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/cron-tasks"
```

For "all my scheduled tasks", show both types. For "this secretary's plans",
filter target.owner_session_id to the actual current CLACKY_SESSION_ID. When the
user names an existing plan, resolve it from the list, including ordinary plans.
If names/titles are ambiguous, clarify before mutating. Do not select another
secretary's similarly named plan by accident; an explicit request to manage a
particular existing plan may refer to a different conversation.

Display the plan's `title` when present, falling back to `name`, together with time,
enabled state, next run and result destination. Include ordinary last_run status when
available; do not interpret a secretary plan's empty cron last_run as "never executed".
Use its work history below. The existing WebUI Tasks panel remains the global
management surface; the secretary Work panel shows that conversation's plans and work.

## 2. Create

Gather the objective, frequency, sources and required output. Write a self-contained
prompt: each execution starts a fresh session. Include needed paths/URLs, report
scope, language and output requirements. Secretary workers receive recent work
summaries, but do not automatically have mailbox/calendar access or the full
conversation. Do not promise unavailable sources or actions.

Choose a distinct lowercase `name` using `[a-z0-9_-]` — it becomes the task file
name and API path. Also set a short `title` in the user's language; this is what the
Tasks panel and cron sessions display. Check existing names first. Do not use POST
to overwrite a plan; use PATCH when editing the intended plan.

Ordinary task payload (the existing format remains valid):

```json
{
  "name": "daily_file_summary",
  "title": "Daily file summary",
  "content": "Read the specified project notes and write the requested daily summary to the agreed output path. Include the actual paths and acceptance criteria here.",
  "cron": "0 9 * * *",
  "enabled": true
}
```

For secretary work, use the same payload fields and add:

```json
{
  "name": "morning_report",
  "title": "Morning report",
  "content": "Summarize current work progress, completed items, blockers and decisions needed. Report in the user's requested language through the secretary.",
  "cron": "0 9 * * *",
  "enabled": true,
  "owner_session_id": "<actual current CLACKY_SESSION_ID>"
}
```

Read the actual session ID from the terminal environment; never submit the
placeholder or guess an ID. The API validates that the owner is a secretary.
Omit owner_session_id for ordinary tasks. Do not send a raw target hash.
For secretary notifications, use the existing X-Lang header (zh/en) when the
user's language is known.

Serialize the selected payload into a temporary JSON file, preserving literal
user text. Then POST it with `Content-Type: application/json` and
`--data-binary @<payload-file>`; do not interpolate user content into shell code.
The API requires a cron expression, even for a plan initially disabled.

After success, confirm the time and destination:

- Ordinary: the task runs in an independent session; results are available in
  Tasks / the execution session (plus any output explicitly requested).
- Secretary: each occurrence creates work and reports back to its owning
  secretary conversation. The Work panel shows progress.

Do not tell users that an ordinary task will report to the current conversation.

## 3. Edit

Read the selected plan, retain its type and owner, and PATCH only requested fields:

```json
{"cron": "0 18 * * *"}
```

```json
{"content": "Updated self-contained instructions"}
```

The supported fields are title, content, cron and enabled. Omitted fields remain
intact; an empty title clears it and falls back to name. Neither owner_session_id
nor target is editable through this endpoint. Report the actual changed fields
after success. Editing an ordinary task from a secretary conversation leaves it
ordinary; editing secretary work from another conversation leaves its result
destination unchanged.

## 4. Enable or disable

PATCH `{"enabled": false}` to pause future occurrences, or
`{"enabled": true}` to enable them. Re-enabling starts from the next future slot;
it does not backfill the disabled period.

For both types, disabling a plan does not interrupt an execution already created.
For secretary work, if the user also wants an existing work item paused/cancelled,
handle that separately through the owning secretary's work-management path.
manage_work manages work cards, not cron plans.

## 5. Delete

DELETE the selected plan by its exact name. An explicit deletion request already
authorizes deletion; clarify only if the intended plan is ambiguous. Explain that
removing the plan stops future occurrences, not existing executions or their
history. Do not cancel a work card merely because its plan was deleted.

## 6. History and results

Use the saved type, not the current conversation, to choose the history source:

- Ordinary: GET /api/cron-runs with task set to the plan's name. Show statuses and
  link/reference the returned execution session. Logs under ~/.clacky/logger/
  can help diagnose failures if run metadata is insufficient.
- Secretary: GET /api/ext/secretary/work with session_id set to the saved
  target.owner_session_id. Select cards whose schedule_name equals the plan name.
  Show scheduled_at, status and progress; use the card's session_id for execution
  details. Results return to the saved owner. Do not use cron-run history as the
  source of completion status for these plans.

Missing records are not evidence of success or failure. Describe what is known.

## 7. Run now

POST /api/cron-tasks/:name/run for either type. This does not change the recurrence.

- Ordinary: the API prepares an execution session. Open the returned session in
  the existing UI to start/view the pending run. Do not claim completion from 202.
- Secretary: the API queues a work card and returns its worker session. The result
  will return to the saved secretary owner, even if requested from another chat.
  If 409 reports an unfinished previous work or unavailable owner, explain the
  blocker; do not bypass it by creating an ordinary task or a duplicate plan.

## Timing and templates

The server checks schedules roughly once per minute and must be running/resumed.
Cron does not wake a paused sandbox. Tracked missed occurrences collapse to the
latest one. Older plans without a stored cursor begin tracking when first loaded;
do not promise recovery of a pre-upgrade backlog.

For secretary plans, only one unfinished work item per plan is allowed. A waiting,
paused, failed or decision-needed item blocks the next occurrence until resolved
or cancelled. Ordinary plans retain their existing execution behavior; do not
apply this worker restriction to them.

| Expression | Meaning in server-local time |
|---|---|
| 0 9 * * 1-5 | Weekdays at 09:00 |
| 0 9 * * * | Daily at 09:00 |
| 0 20 * * * | Daily at 20:00 |
| 0 */2 * * * | Every two hours |
| */30 * * * * | Every 30 minutes |
| 0 9 1 * * | First day of each month at 09:00 |

Offer templates appropriate to the selected execution type. Research digests,
work-progress reports and competitor monitoring can fit secretary workers.
File-writing reports, backups and shell-based checks use ordinary task capabilities
and permissions. Include actual inputs and output requirements before creating a
template-derived task; a template is not proof that a data source is connected.
