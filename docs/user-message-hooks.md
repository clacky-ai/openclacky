# User Message Hooks

`before_user_message` uses the same `HookManager` registration, callback order,
mutable arguments, and verdicts as `before_tool_use`. Ruby extensions can register
it through `contributes.hooks` and `ExtensionHookRegistry`, or use
`agent.add_hook(:before_user_message)` directly.

The callback receives `(message, agent)`. The message contains `content` and the
input options: `files`, `reference_contexts`, `display_text`, `created_at`, and
`references_display`. Optional values may be absent or nil. Session metadata is
available from the owning agent. Mutations are visible to subsequent hooks.
Set `display_text` explicitly when the displayed text should differ from the
content passed to the model.

- `nil` or `{ action: :allow }`: continue with the modified message.
- `{ action: :deny, reason: "..." }`: show the reason and stop default processing.
  The caller receives `{ status: :success, queue_paused: true }`.
- `{ action: :handled, result: run_result }`: skip default processing and return
  `run_result` unchanged. The extension supplies the existing Agent run-result
  contract, including `status` and any required queue/feedback flags.

The first deny or handled verdict stops the hook chain. Exceptions retain the
existing hook behavior: log the error and continue to the next hook.

The hook runs before goal command dispatch, attachment processing, or history
insertion. Queued messages are checked when consumed; steering messages are
checked at loop checkpoints. A terminal verdict on steering stops the active
loop and preserves unprocessed queue entries. Normal cleanup still runs.
Intercepted input does not run completion hooks, memory updates, or goal
continuation. Direct intercepted input does not run `on_start` either.

Denied and handled messages are not automatically stored in model history.
Extensions that need a pending request must retain it themselves. UI messages
already shown by the caller are not retracted and are not persisted by this hook.

## Extension-Owned Feedback

The following example is registered on one agent. It keeps pending state in the
extension and reuses the existing UI interface. It emits a question card, not a
tool execution: no tool hooks or tool-result messages are synthesized. The hook
does not persist the card or its pending state across restarts.

```ruby
pending = nil
agent.add_hook(:before_user_message) do |message, owner|
  if pending && message[:content] == "Confirm"
    message.replace(pending)
    pending = nil
    next { action: :allow }
  end

  pending ||= message.dup
  owner.ui.show_tool_call("ask_user", question: "Continue?",
                                    options: ["Confirm", "Review again"])
  {
    action: :handled,
    result: { status: :success, awaiting_user_feedback: true, queue_paused: true }
  }
end
```

The next answer passes through the same hook. A real extension should apply its
own content policy and answer parsing, and scope pending state to the session.

## Shell Hooks

Shell hooks receive `{ "event": "before_user_message", "user_message": { ... } }`
on stdin. The existing command protocol applies: exit 0 allows, exit 2 denies
with stdout as the reason. `type: rewrite` remains specific to `before_tool_use`;
message mutation and handled results use Ruby callbacks.
