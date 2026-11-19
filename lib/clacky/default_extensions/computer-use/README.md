## How to open

- **In the chat**: once enabled, just describe the task in the conversation — there is no separate panel.
- Status: off by default. Enable **Computer Use** under **Extensions › All › Official** first.
- Requires: the system permissions described in **Before you start** below.

## Before you start

### macOS

In **System Settings → Privacy & Security**, grant the app running Clacky (your terminal or the Clacky app):

- **Screen Recording** (for screenshots)
- **Accessibility** (to control mouse and keyboard)

You may need to restart that app after granting.

### Windows

Run Clacky inside **WSL**, from a logged-in desktop session (not a background service or SSH session). Otherwise screenshots come back black and input goes nowhere.

Plain Linux is not supported.

## How to use

### What it is good for

- Native apps, System Settings, installers
- Dialogs, menu bars and file pickers
- Anything else that can only be done by clicking on screen

For web automation, prefer the built-in browser capability — it is faster and more reliable. Fall back to Computer Use only when the browser cannot do the job.

### Describing a task

Just state the goal in plain language, for example:

- "Open System Settings and turn the display brightness all the way up"
- "In the file picker that just opened, select report.pdf on the Desktop"

The AI takes a screenshot first, clicks and types by coordinates, and re-checks the screen after each step.

### When permissions or the environment get in the way

Ask the AI to "run the computer-use doctor check". It verifies permissions and environment and tells you what is missing.

## Notes

- Avoid using the mouse and keyboard while the AI is working, so you don't interfere with each other.
- Keep an eye on each step for sensitive actions such as payments or deletions.
