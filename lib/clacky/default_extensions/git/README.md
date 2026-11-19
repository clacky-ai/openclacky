## How to open

- Session side panel → the **Git** tab.
- Status: on by default.
- Requires: the session's working directory is a Git repository.

## How to use

### Choosing what to look at

Use the scope dropdown at the top:

| Scope | What it shows |
|---|---|
| Last turn | Only what the AI changed in its last round (most common) |
| Uncommitted | Everything changed since the last commit |
| Unstaged / Staged | Changes split by the Git index |
| Committed | Commits on the current branch vs. the base branch |
| Unpushed commits | Commits not yet pushed, one by one |
| Branch | Compare against any branch |

### Reading the diff

- **File tree** on the left lists every changed file. Drag to resize (double-click to reset) or hide it.
- **Go to file** filters the list by name.
- **Diff layout**: auto / side-by-side / inline.
- **Wrap lines** for files with long lines.
- Unchanged code is collapsed into "N unchanged lines" — click to expand.
- Very large files load on demand — click to render them.

### Working with a single file

- **Discard this file's changes** with the undo button in the file header; confirm to throw them away (not recoverable).
- **More menu / right-click**: copy path, copy relative path, open in editor, add to chat, open containing folder, download.

## Notes

- Want the AI to keep working on a file? Use **Add to chat** to drop it into the input box.
- To review or roll back at the step level, use the **Time Machine** extension.
