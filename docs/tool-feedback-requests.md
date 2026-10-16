# Business tool feedback requests

Extensions can attach a `feedback_request` hash to a successful business tool result in an
`after_tool_use` hook. Check `agent.tool_feedback_requests?` before using this contract on
runtimes that may predate it. No extra model-issued `ask_user` call is required.

The descriptor uses the existing Ask fields (`question` or `questions`, `options`, and `context`).
An optional `auto_reply` describes how to continue when Auto expires. Business context may contain
an application-owned card identity so clients retain a specialized picker instead of a generic
question. Descriptors are extension-owned; they are removed from the ordinary tool result.

The host stages the latest descriptor and finishes normal tool execution, validation, and the
closing assistant reply before showing the feedback request. Manual mode ends with the existing
`awaiting_user_feedback`/`queue_paused` result. Auto uses the existing configured countdown;
intervention hands control back, while timeout continues the same task with a system-injected
instruction. It does not create a displayed user message or click a default option in a client.
Explicit user constraints still apply to the automatic instruction.

Requests and resolutions are persisted as `ext.clacky.feedback.requested` and
`ext.clacky.feedback.resolved` milestones. Replay translates them into existing `request_feedback`
and `feedback_countdown` events. A replayed resolution includes the original `context` so clients
can match the business request even after the live countdown ID has gone away. Live reconnects
restore the business feedback descriptor before the existing deadline snapshot. Ordinary Ask
countdowns keep their existing live-replay behavior.

This extends the existing wait lifecycle; it does not provide restart-persistent scheduling.
