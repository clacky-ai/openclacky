# Computer Use

Let the AI operate your desktop the way a person would: take a screenshot to see the screen, then click and type. Use it for things the terminal and browser cannot reach.

> This extension is **off by default**. Click **Enable** in Extensions to turn it on.

## What it is good for

- Native apps, System Settings, installers
- Dialogs, menu bars and file pickers
- Anything else that can only be done by clicking on screen

For web automation, prefer the built-in browser capability — it is faster and more reliable. Fall back to Computer Use only when the browser cannot do the job.

## Setup

**macOS**

In **System Settings → Privacy & Security**, grant the app running Clacky (your terminal or the Clacky app):

- **Screen Recording** (for screenshots)
- **Accessibility** (to control mouse and keyboard)

You may need to restart that app after granting.

**Windows**

Run Clacky inside **WSL**, from a logged-in desktop session (not a background service or SSH session). Otherwise screenshots come back black and input goes nowhere.

> Plain Linux is not supported.

## How to use

Once enabled, just describe the task in plain language, for example:

- "Open System Settings and turn the display brightness all the way up"
- "In the file picker that just opened, select report.pdf on the Desktop"

The AI takes a screenshot first, clicks and types by coordinates, and re-checks the screen after each step.

## Troubleshooting

Ask the AI to "run the computer-use doctor check". It verifies permissions and environment and tells you what is missing.

## Notes

- Avoid using the mouse and keyboard while the AI is working, so you don't interfere with each other.
- Keep an eye on each step for sensitive actions such as payments or deletions.
