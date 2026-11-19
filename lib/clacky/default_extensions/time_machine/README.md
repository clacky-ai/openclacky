## How to open

- Session side panel → the **History** tab, showing a timeline of tasks.
- Status: on by default.
- Requires: nothing. Snapshots are automatic and independent of Git.

## How to use

### Reading the timeline

- The step marked **Current** is the version your workspace is on right now.
- Each step shows how many files changed and when it finished.

### Seeing what a step changed

1. Click a step on the timeline to expand it and see its main changed files.
2. Click **View details** for a two-pane view: file list on the left, line-by-line diff on the right.
3. Tags next to each file show the kind of change: **Added / Created / Modified / Deleted**.
4. Click **Back** to return to the timeline.

### Going back to an earlier step

1. Expand the target step and click **Go back here**.
2. The panel first lists the files that will be affected so you can check them.
3. Click **Confirm** and the workspace files are restored to how they were at that step.

If you keep working after going back, the new work grows as a **Branch** — the original history is kept and you can still switch back to it.

## Notes

- ⚠️ Going back overwrites the current changes in those files. Review the list before confirming.
- To review changes from a Git perspective — by commit or branch — use the **Git** extension.
