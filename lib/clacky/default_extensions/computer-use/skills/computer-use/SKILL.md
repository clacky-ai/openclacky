---
name: computer-use
description: Drive the desktop — macOS, or the Windows desktop through WSL — when a task needs a native app, dialog, menu bar, file picker or anything the terminal and browser tools cannot reach. Screenshot first, then click and type by coordinates read from that image.
---

# Computer Use (macOS and Windows)

GUI control goes through the script bundled with this skill. The `computer-use` extension is
off by default, so if you are reading this the user has switched it on.

## Platform support

| Host | Backend | Needs |
|---|---|---|
| macOS | CoreGraphics + Quartz events | Screen Recording and Accessibility grants |
| Windows | PowerShell agent launched from inside WSL | WSL running in an interactive desktop session |

On Windows the script only works from a WSL shell on the same machine: it reaches the
Windows desktop through WSL interop, which inherits the logged-on user's session. Run
from a service, an SSH session or anything on session 0 and `doctor` will say so —
screenshots come back black and input goes nowhere. This does not work on plain Linux
without Windows, and there is no macOS-side fallback for it.

Everything below is the same on both platforms. Key combos keep the macOS spelling
(`cmd`, `shift`), so `cmd` means the Windows key on Windows.

## When to use it

- Native apps, dialogs, menu bars, installers, file pickers, System Settings.
- Anything on screen that `terminal` cannot reach and `browser` cannot automate.
- For web automation prefer the `browser` tool while it works. If it fails because remote
  debugging is unavailable, fall back here immediately — do not open `chrome://inspect` or run
  the browser-setup skill unless the user asks for it.

## Workflow

1. Bring the target app forward if another window may cover it:

   ```bash
   ruby <skill_dir>/bin/computer.rb activate "WorkBuddy"
   ```

   It needs no extra permission on either platform. If the name does not match (localized
   app names differ), it prints what is actually frontmost — take a screenshot
   to see the real window order instead of guessing.

2. Screenshot — with a labelled grid when you will need to click precise spots:

   ```bash
   ruby <skill_dir>/bin/computer.rb screenshot --grid
   ```

   It prints `image WxH scale S origin (x,y)` and writes a sidecar `.json` next
   to the PNG. The grid image is the one to read: its magenta lines and pixel
   labels give exact coordinates, so prefer it over writing your own crop or
   PIL overlay scripts. `--grid 100` sets a denser step; the default is 200.

3. Read that PNG with the `read` tool — it is attached to the conversation as an
   image. Need to read small text, or click inside a region? Crop and upscale it
   first, with `--grid`:

   ```bash
   ruby <skill_dir>/bin/computer.rb zoom 400,300,900,600 --grid --out /tmp/clacky-shot-2.png
   ```

   Always pass `--grid`: its labels are in the zoomed image's own pixel space,
   ready to feed straight into `click`, so you never convert coordinates
   yourself. Hand-converting a downscaled image is the usual source of
   misclicks — do not do it. `zoom` also pads the region it captures, so the
   `origin (x,y)` it prints is not the region you asked for; the grid labels are
   what to trust, not the origin.

   Note: the read tool downscales every image to 800px wide by default. That is
   fine for `--grid` captures; pass `image_max_width: 0` only when reading a
   `screenshot --original` capture, since re-downscaling would defeat it.

4. Act, always passing the image you are looking at:

   ```bash
   ruby <skill_dir>/bin/computer.rb click 812 430 --from /tmp/clacky-shot-1.png
   ruby <skill_dir>/bin/computer.rb type "hello world"
   ruby <skill_dir>/bin/computer.rb key "cmd+s"
   ```

   `--from` accepts the grid copy too (`shot-1-grid.png`); it resolves back to
   the capture's sidecar automatically.

   `type` and `key` go to whatever holds the focus, and the script cannot tell
   where that is — a `key` aimed at a field that never got focus lands on another
   panel and fails silently. Screenshot to confirm the focus is where you mean
   it, and `click` the field once before typing or sending. If a field ignores
   `type` altogether (common with IME-backed native inputs), paste instead —
   `pbcopy` on macOS, `clip` on Windows — then `key "cmd+v"`.

5. Screenshot again to verify the result.

## Locating elements

Follow this order and do not invent your own image-processing pipeline (no PIL
scripts, no pixel counting):

1. Plain screenshot for overall layout.
2. `--grid` when you need to click something and coordinates are not obvious.
3. `zoom` on a region to read small text, `zoom --grid` when it must be clicked.
4. `screenshot --original` (read with `image_max_width: 0`) when small detail
   is needed across many regions at once and zooming one by one costs more
   rounds — full resolution costs many more tokens, so prefer zoom first.
5. Only then click, using the coordinates read off the image you last looked at.

## Coordinates

- `X Y` are pixels **of the image you last looked at**, origin at its top-left corner.
- Always pass `--from <that png>`. Without it the script falls back to the most recent
  screenshot if it is under 120 seconds old; otherwise it fails and you must screenshot again.
- Never carry coordinates over from an older screenshot — the window may have moved.

## Commands

| Command | Notes |
|---|---|
| `screenshot [--out PATH] [--display N] [--max-width W] [--grid [STEP]]` | prints image size, scale, display origin; `--grid` blends labelled pixel lines |
| `zoom x1,y1,x2,y2 [--out PATH] [--grid [STEP]]` | crop + upscale for reading small text |
| `click X Y [--from IMG] [--button left/right/middle] [--count 1-3] [--mods cmd,shift]` | |
| `move X Y [--from IMG]` | |
| `drag X1 Y1 X2 Y2 [--from IMG]` | |
| `scroll X Y --dx N --dy N [--from IMG]` | |
| `type "text"` | types into the focused field |
| `key "cmd+shift+t" [--repeat N]` | |
| `hold "shift" --duration 1.5` | holds modifiers while other actions run |
| `cursor` | the pointer position: Windows reads it, macOS reports `unknown` |
| `activate "AppName" [--wait SECONDS]` | brings an app to the front, no automation grant needed |
| `doctor` | platform, backend and permission self-check |

## Safety

- Ask the user before changing system, browser or application settings, and before anything
  destructive (deleting files, sending messages, installing software).
- Exit codes: `0` ok · `2` permission missing or backend unusable · `3` screenshot state
  missing or stale · `4` disabled by `~/.clacky/computer.yml`.
- On a permission error, relay the System Settings → Privacy & Security grant it asks for and
  wait for the user. Do not retry in a loop.
