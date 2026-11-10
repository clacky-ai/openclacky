# Secretary

An assistant you can hand work to: it answers simple questions on the spot, runs the slow parts in the background, and comes back when there is a result or a decision to make.

> This extension is **on by default**. Pick **Secretary** when starting a session and the **Work** tab appears in the side panel.

## What suits it

- Research that needs reading docs, searching, or comparing options
- Execution that produces files, code changes, or cleaned-up data
- Work that has to wait for someone else's reply
- A routine summary at a fixed time each morning or evening

## Using it

State the goal, what "done" looks like, and any known constraints, for example:

> Bring this project's README up to date — cover deployment and local development, don't touch the code.

The secretary decides whether the work needs a background run:

- **Simple questions** are answered directly and never show up in **Work**.
- **Longer work** becomes a work item handed to a background worker, and the conversation continues with you immediately.

## The Work panel

Each item is a card with a title, status and creation time. The list stays in creation order, so status changes never move a card around.

Statuses:

| Status | Meaning |
| --- | --- |
| Waiting to start | Queued, not started yet |
| Your secretary is working on this | Running in the background |
| Waiting for an event or checkpoint | Awaiting an external reply, or a scheduled re-check |
| Needs input from your secretary | Needs information, a decision or authorization |
| Paused | You or the secretary paused it |
| Completed | A deliverable or interim result is ready |
| Something needs attention | Execution failed; review it with the secretary |
| Cancelled | Stopped for good |

Card actions:

- **Discuss with secretary** pre-fills "About “{title}”, I would like to add:" into the composer, so you can keep talking.
- **Open execution history** jumps to the worker session with the full run.
- **Details** expands the objective, constraints and change history.

The **Recurring plans** section below lists scheduled runs (daily / weekdays), the next run time and the plan text. To change one, click **Discuss with secretary** and describe the change in a sentence.

## How background work runs

1. The secretary writes the objective, background, authorization boundaries and acceptance criteria into a task and hands it to the worker.
2. The worker executes in **its own session** using existing tools, under your current permissions and confirmation settings.
3. When it reaches a checkpoint it reports back: completed, needs a decision, or waiting on an external event.
4. The secretary relays the outcome to you; if a decision is required it asks first, then forwards your answer.

An existing item can take further requests in the same session — no need to start a new one.

## Notes

- Background runs never block the conversation: interrupt, change requirements, or cancel at any time.
- The worker does not widen its own authorization. If a step needs new permission or falls outside scope, it comes back to ask.
- **Completed** means this round delivered a result, not that you accepted it — send feedback to keep refining.
- Recurring plans depend on the local service running; nothing fires while the machine or server is down.

## Extension info

- Extension ID: `secretary`
- Contributes: the **Secretary** agent, the hidden **Secretary Worker** agent, the `delegate_work` / `manage_work` / `yield_work` tools, the **Work** panel, and `/api/ext/secretary/work`
