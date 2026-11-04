# Git

A friendly review panel for changes: see exactly which files and lines the AI touched, and review them like a pull request.

> The session's working directory must be a Git repository.

## Opening it

Switch to the **Git** tab in the session's side panel.

## Choosing what to look at

Use the scope dropdown at the top:

| Scope | What it shows |
|---|---|
| Last turn | Only what the AI changed in its last round (most common) |
| Uncommitted | Everything changed since the last commit |
| Unstaged / Staged | Changes split by the Git index |
| Committed | Commits on the current branch vs. the base branch |
| Unpushed commits | Commits not yet pushed, one by one |
| Branch | Compare against any branch |

## Reading the diff

- **File tree** on the left lists every changed file. Drag to resize (double-click to reset) or hide it.
- **Go to file** filters the list by name.
- **Diff layout**: auto / split / unified — click to switch.
- **Wrap** long lines when needed.
- Unchanged code collapses into "N unchanged lines"; click to expand.
- Very large diffs load on demand — click to show them.

## File actions

- **Discard changes**: the revert button on a file header discards that file's changes after a second confirmation. This cannot be undone.
- **More menu / right-click**: copy path, copy relative path, open in editor, add to chat, reveal in folder, download.

## Tips

- Want the AI to keep working on a file? Use **Add to chat** to reference it in the input box.
- To look back at a single step or roll everything back, pair this with the **Time Machine** extension.
