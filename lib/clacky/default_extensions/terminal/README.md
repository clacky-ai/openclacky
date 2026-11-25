## How to open

- Tab bar of the session side panel → **+** (new tab) → **Official › Terminal**.
- Status: off by default. Enable **Terminal** under **Extensions › All › Official** first.
- Requires: the app is opened on this machine; a LAN or remote address cannot use it.

## How to use

### Opening and closing

- One shell per session, started in that session's working directory — the folder the AI works in. Falls back to your home directory when the session has none.
- Switching to another tab or another session leaves the shell running. Come back and everything it printed meanwhile is replayed.
- Closing the tab with × does not kill the shell. Add **Terminal** again and you are back in the same one.
- Typing `exit` (or `Ctrl+D`) ends the shell, and the tab closes itself. Adding **Terminal** again gives you a fresh shell.

### Everyday commands

| Goal | How |
|---|---|
| Run a command / install dependencies | Type it, same as your own terminal |
| Stop the running command | `Ctrl+C` |
| Suspend it to the background | `Ctrl+Z` |
| Clear the screen | `clear` or `Ctrl+L` |
| Change directory | `cd`. The session's working directory, the one the AI uses, does not follow |

## Notes

- The terminal runs commands on the machine Clacky itself runs on, which is why it is off by default and answers local requests only.
- At most 6 shells at once across sessions. At the limit, the least recently used shell that no page is attached to is reaped.
- A shell with no page attached for over an hour is reaped the next time a terminal opens, so that open starts a new one.
- Shells live in the Clacky process: restarting Clacky ends them, and the tab closes itself instead of leaving a dead pane.
- Not available on Windows yet — the panel says it could not start a terminal.

## Third-party

`vendor/` ships [xterm.js](https://github.com/xtermjs/xterm.js) 5.5.0 with its fit addon (0.10.0), MIT licensed — see `vendor/LICENSE`.
