# Time Machine

Every time the AI finishes a step, your workspace is snapshotted automatically. Broke something? Jump back to any earlier step.

## Opening it

Switch to the **History** tab in the session's side panel to see a timeline of tasks.

- The step marked **Current** is the version your workspace is on right now.
- Each step shows how many files changed and when it finished.

## Seeing what a step changed

1. Click a step on the timeline to expand it and see its main changed files.
2. Click **View details** for a two-pane view: file list on the left, line-by-line diff on the right.
3. Tags next to each file show the kind of change: **Added / Created / Modified / Deleted**.
4. Click **Back** to return to the timeline.

## Going back to an earlier step

1. Expand the target step and click **Go back here**.
2. The panel first lists the files that will be affected so you can check them.
3. Click **Confirm** and the workspace files are restored to how they were at that step.

> ⚠️ Going back overwrites the current changes in those files. Review the list before confirming.

If you keep working after going back, the new work grows as a **Branch** — the original history is kept and you can still switch back to it.

## Tips

- Snapshots are automatic: no manual saving, and no Git required.
- To review changes from a Git perspective — by commit or branch — use the **Git** extension.
