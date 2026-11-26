## How to open

- Tab bar of the session side panel → **+** (new tab) → **Official › Side chat**.
- Select a passage in the main conversation → the floating bar → **Side chat**: the panel opens with that passage quoted in the composer.
- Status: on by default. Turn it off under **Extensions › All › Official**; the tab then disappears and the API stops answering.
- Uses the session's own model, so a configured provider is all it needs.

## How to use

### Asking without interrupting the task

The panel is a read-only branch of the conversation you are in: it inherits the whole thread, including the tool calls the AI already ran, so it can explain what it just did, why a command failed, or what a diff changed.

- Nothing you ask here reaches the main conversation, the project files or the AI's task — ask as much as you like.
- The main thread keeps running while you read and ask; it is not paused and does not scroll.
- The branch may read files, search and browse, but it cannot write files, run commands, or trigger anything that would need your confirmation. If something needs changing, it tells you and you ask for it in the main chat.

### Quoting a passage

1. Select text inside one message in the main conversation.
2. Click **Side chat** on the floating bar — the passage is added to the panel as a quote chip.
3. Add your question and send. Entering through the bar rebuilds the branch against the conversation as it stands now, so the quote and everything around it are current.

You can also attach a file with the paperclip or by dropping it on the panel, as in the main composer — a screenshot of the bug, a log, a spec.

### Everyday actions

| Goal | How |
|---|---|
| Stop an answer | Click the stop button where send was |
| Close the panel | × on its tab. The branch stays alive; add the tab again to pick it up |
| Ask about another session | Switch sessions — each one has its own branch |

## Notes

- At most 6 branches at once across sessions. A branch nobody has been attached to for an hour is reaped the next time a panel opens — there is no timer, so an idle branch lingers until then.
- Branches live in the Clacky process: restarting Clacky ends them and the panel says the side chat expired — send again to start a new one.
- Reloading the page does not replay the panel's history. Asking again reattaches to the same branch, so the context is still there even though the earlier answers are not shown.
- Model calls made here are billed to the session the panel belongs to, so the cost shows up in that session's usage.
- The panel is a narrow column by default; drag the divider to widen it. The width is remembered per session.
