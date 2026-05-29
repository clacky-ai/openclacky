---
name: Bug report
about: Create a report to help us improve
title: ''
labels: bug
assignees: windy

---

## What happened

Briefly describe the issue: what you were doing, what you expected, and what actually happened. Screenshots, error messages, or a short screen recording are very welcome.

Please also include:

- **OpenClacky version** (required, e.g. `0.x.y`)
- Environment if relevant: OS (macOS / Linux / Windows / WSL / Docker), browser & version, model in use, whether you're behind a proxy/VPN.

## Session zip (strongly recommended)

The session zip contains the full context of the conversation and is the most useful artifact for us to reproduce and fix the issue.

How to download:

1. Open the OpenClacky Web UI and go to the session (chat page) where the bug happened.
2. Look at the status bar right above the input box — it shows the run status, the current **session ID** (a short hash like `7fd88060`), working directory, model, task count, and cost.
3. Click the session ID. Your browser will download `clacky-session-7fd88060.zip`.
4. Drag the zip into this issue as an attachment.

> Privacy note: the zip contains your full conversation with the AI, related file paths, and some file contents. Please review it before uploading and remove anything sensitive). If you'd rather not share it publicly, feel free to send it to the maintainers privately instead.
